# Catalogue of Beyond 20/20 IVT products deposited on the Borealis Dataverse
# (https://borealisdata.ca). Borealis hosts custom StatCan tabulations that
# complement the official StatCan datasets index (see catalogue.R); many are the
# same products mirrored (their filename matches a StatCan catalogue number) but
# ~3,000 are custom tabulations found nowhere else.
#
# Each Borealis file is uniquely identified by its numeric `file_id` (the atom of
# the download URL). Its filename is NOT globally unique: the same name is reused
# across datasets (e.g. one `CD1T29M3.IVT` per Labour Force Historical Review
# year), so the addressable `key` folds in the dataset's persistent id (DOI):
# `key = <doi-token>/<file-stem>`, e.g. `SP3/6DGOTF/CD1T29M3`. That distinguishes
# the editions and makes each file's provenance explicit.

# The Borealis Dataverse server and the constant part of its DOIs (stripped from
# the key token for brevity; non-Borealis DOIs, e.g. 10.7939 UAlberta deposits,
# keep their full shoulder).
BOREALIS_SERVER <- "borealisdata.ca"
BOREALIS_DOI_SHOULDER <- "10.5683/"

#' Catalogue of Borealis Dataverse Beyond 20/20 IVT products
#'
#' Searches the [Borealis Dataverse](https://borealisdata.ca) for every deposited
#' `.ivt` file and returns a tidy catalogue. Borealis hosts custom StatCan
#' tabulations that complement the official [statcan_ivt_catalogue()]; the two are
#' used together by [get_statcan_ivt()], which resolves a table against StatCan
#' first and falls back to Borealis.
#'
#' The search is slow (~90 s, thousands of files) so the full catalogue is cached
#' as a Parquet file in the data cache ([ivt_cache_dir("data")][ivt_cache_dir]);
#' pass `refresh = TRUE` to rebuild it. Reading the cache needs neither the
#' `dataverse` package nor an API key -- only a live search does.
#'
#' A **Borealis API key** is required to run the search. Get one from your
#' Borealis account (<https://borealisdata.ca/dataverseuser.xhtml?selectTab=apiTokenTab>)
#' and set it as the environment variable `BOREALIS_DATAVERSE_KEY` (e.g. in
#' `.Renviron`).
#'
#' @param refresh Re-run the live search even if a cached catalogue exists.
#' @param quiet Suppress per-batch progress messages.
#' @return A tibble with one row per `.ivt` file: `key` (the canonical
#'   `<doi-token>/<file-stem>` address), `file` (the deposited filename),
#'   `file_stem`, `file_id` (the numeric Borealis datafile id -- always unique),
#'   `dataset_doi`, `dataset_name`, `download_url`, `size_in_bytes`, `md5`,
#'   `published_at` and `file_type`.
#' @seealso [statcan_ivt_catalogue()], [get_statcan_ivt()], [borealis_ivt_download()]
#' @export
borealis_ivt_catalogue <- function(refresh = FALSE, quiet = FALSE) {
  cache_file <- file.path(ivt_cache_dir("data"), "borealis_ivt_catalogue.parquet")

  if (!refresh && file.exists(cache_file) &&
      requireNamespace("arrow", quietly = TRUE)) {
    catl <- tibble::as_tibble(arrow::read_parquet(cache_file))
    ivt_warn_stale_catalogue(cache_file, label = "Borealis",
                             refresh_call = "borealis_ivt_catalogue(refresh = TRUE)",
                             flag = "borealis_catalogue_stale_warned")
    return(catl)
  }

  raw <- borealis_ivt_search(quiet = quiet)
  catl <- borealis_tidy_catalogue(raw)
  if (requireNamespace("arrow", quietly = TRUE)) {
    arrow::write_parquet(catl, cache_file)
  }
  catl
}

# Run the paged Borealis file search for `.ivt` deposits, returning the raw
# `dataverse::dataverse_search` rows (requires the dataverse package + API key).
borealis_ivt_search <- function(quiet = FALSE) {
  borealis_require(needs_key = TRUE)
  key <- Sys.getenv("BOREALIS_DATAVERSE_KEY")
  page_size <- 1000L
  i <- 0L
  raw <- NULL
  repeat {
    batch <- dataverse::dataverse_search(
      c(name = "\\.IVT"), type = "file", key = key, server = BOREALIS_SERVER,
      start = i * page_size, per_page = page_size, verbose = FALSE)
    raw <- if (is.null(raw)) batch else rbind_common(raw, batch)
    i <- i + 1L
    if (!quiet) cli::cli_inform("Borealis search batch {i} ({nrow(batch)} files)")
    if (is.null(batch) || nrow(batch) < page_size) break
  }
  raw
}

# Turn the raw search rows into the tidy, `.ivt`-only catalogue. The search is a
# fuzzy full-text match on `name:\.IVT`, so it also returns stray .tab/.csv/.zip
# hits and bundles -- keep only files whose name actually ends in `.ivt`.
borealis_tidy_catalogue <- function(raw) {
  cols <- c("name", "file_id", "url", "size_in_bytes", "md5", "published_at",
            "file_type", "dataset_name", "dataset_persistent_id")
  for (cn in cols) if (is.null(raw[[cn]])) raw[[cn]] <- NA
  file <- trimws(as.character(raw$name))
  # a blank name should never happen on the search, but fall back to the file id
  file <- ifelse(nzchar(file), file, paste0(raw$file_id, ".ivt"))

  keep <- grepl("\\.ivt$", file, ignore.case = TRUE)
  file <- file[keep]
  raw  <- raw[keep, , drop = FALSE]

  dataset_doi <- sub("^doi:", "", as.character(raw$dataset_persistent_id))
  stem <- tools::file_path_sans_ext(file)

  tibble::tibble(
    key           = paste0(borealis_token(dataset_doi), "/", stem),
    file          = file,
    file_stem     = stem,
    file_id       = as.character(raw$file_id),
    dataset_doi   = dataset_doi,
    dataset_name  = as.character(raw$dataset_name),
    download_url  = as.character(raw$url),
    size_in_bytes = as.numeric(raw$size_in_bytes),
    md5           = as.character(raw$md5),
    published_at  = as.character(raw$published_at),
    file_type     = as.character(raw$file_type)
  )
}

#' Download a Borealis IVT file into the ivt cache
#'
#' Downloads one Borealis `.ivt` (identified by a one-row [borealis_ivt_catalogue()]
#' slice, or by a bare numeric `file_id`) from the Dataverse access API into the
#' ivt cache and returns the local `.ivt` path. Requires the Borealis API key
#' (`BOREALIS_DATAVERSE_KEY`).
#'
#' @param x A one-row tibble from [borealis_ivt_catalogue()], or a Borealis
#'   `file_id` (character/numeric).
#' @param key Cache key naming the per-table folder under the ivt cache. Defaults
#'   to the catalogue row's `key` (or the `file_id` when `x` is a bare id).
#' @param overwrite Re-download even if a `.ivt` already exists.
#' @param quiet Suppress the download message.
#' @return Path to the local `.ivt` file.
#' @seealso [borealis_ivt_catalogue()], [get_statcan_ivt()]
#' @export
borealis_ivt_download <- function(x, key = NULL, overwrite = FALSE,
                                  quiet = FALSE) {
  borealis_require(needs_key = TRUE)
  if (is.data.frame(x)) {
    stopifnot(nrow(x) == 1L)
    file_id <- x$file_id
    url     <- x$download_url
    out_name <- x$file
    if (is.null(key)) key <- x$key
  } else {
    file_id <- as.character(x)
    url     <- paste0("https://", BOREALIS_SERVER, "/api/access/datafile/", file_id)
    out_name <- paste0(file_id, ".ivt")
    if (is.null(key)) key <- file_id
  }

  dest_dir <- file.path(ivt_cache_dir("ivt"), ivt_catalogue_key(key))
  dir.create(dest_dir, showWarnings = FALSE, recursive = TRUE)

  existing <- list.files(dest_dir, pattern = "\\.ivt$", full.names = TRUE,
                         ignore.case = TRUE)
  if (length(existing) && !overwrite) return(existing[1])

  if (!quiet) cli::cli_inform("Downloading Borealis file {.val {file_id}} ({.url {url}})")
  tmp <- tempfile(fileext = ".bin")
  on.exit(unlink(tmp), add = TRUE)
  utils::download.file(url, tmp, mode = "wb", quiet = quiet,
                       headers = c("X-Dataverse-key" = Sys.getenv("BOREALIS_DATAVERSE_KEY")))
  ivt_store_download(tmp, dest_dir, basename(out_name))
}

# The DOI token used in `key`: the persistent id with the `doi:` scheme removed
# and, for native Borealis DOIs, the constant 10.5683 shoulder stripped for
# brevity (e.g. `10.5683/SP3/6DGOTF` -> `SP3/6DGOTF`). Non-Borealis DOIs keep
# their full shoulder so they stay unambiguous.
borealis_token <- function(dataset_doi) {
  sub(paste0("^", BOREALIS_DOI_SHOULDER), "", dataset_doi)
}

# Ensure the dataverse package (and, when needed, the API key) are available.
borealis_require <- function(needs_key = FALSE) {
  if (!requireNamespace("dataverse", quietly = TRUE)) {
    cli::cli_abort(c(
      "Package {.pkg dataverse} is required to query the Borealis Dataverse.",
      i = 'Install it with {.code install.packages("dataverse")}.'
    ))
  }
  if (needs_key && !nzchar(Sys.getenv("BOREALIS_DATAVERSE_KEY"))) {
    cli::cli_abort(c(
      "A Borealis Dataverse API key is required.",
      i = "Set it as the environment variable {.envvar BOREALIS_DATAVERSE_KEY} (e.g. in {.file .Renviron}).",
      i = "Create one at {.url https://borealisdata.ca/dataverseuser.xhtml?selectTab=apiTokenTab}."
    ))
  }
  invisible()
}

# rbind two data frames keeping only their shared columns (search batches can
# carry ragged nested columns across pages).
rbind_common <- function(a, b) {
  if (is.null(b) || !nrow(b)) return(a)
  common <- intersect(names(a), names(b))
  rbind(a[common], b[common])
}
