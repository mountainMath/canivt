# High-level entry point: turn a catalogue number (or a custom identifier for a
# locally-deposited .ivt) into a connection to the parsed Parquet, downloading
# and decoding under the hood and caching both the raw .ivt (ivt cache) and the
# parsed Parquet (data cache).

#' Get a StatCan IVT table as a Parquet connection
#'
#' One-stop accessor: given a Beyond 20/20 catalogue number, this looks the
#' product up in the [statcan_ivt_catalogue()], downloads its `.ivt` (cached in
#' the ivt cache), decodes it with [read_ivt()], writes the tidy table to Parquet
#' (cached in the data cache) and returns an Arrow connection to that Parquet so
#' the data can be queried lazily (e.g. with `dplyr`) without loading it all into
#' memory.
#'
#' `catalogue` may also be a **custom identifier** for an `.ivt` file you have
#' placed in the ivt cache yourself (as `<id>.ivt` directly in
#' [ivt_cache_dir("ivt")][ivt_cache_dir], or as the only `.ivt` in a `<id>/`
#' subfolder). Such files are used directly, with no catalogue lookup or
#' download — handy for tables that are not on the public index, or for local
#' experiments.
#'
#' @param catalogue A StatCan catalogue number (e.g. `"98-10-0241-01"`,
#'   `"95F0436XCB2001003"`) or a custom identifier matching a local `.ivt` in the
#'   ivt cache. Matching against the catalogue is case- and punctuation-
#'   insensitive.
#' @param geo_attributes Passed to [read_ivt()]: decode the full family-2
#'   geography attribute table (slower) so geographies can be labelled by name.
#' @param labels Passed to [ivt_write_parquet()]: write labelled columns
#'   (`TRUE`, default) or the compact integer-id table.
#' @param dim_names Passed to [ivt_write_parquet()]: name the data-dimension
#'   columns by the full dimension label (`"label"`, default) or the terse
#'   structural slug (`"slug"`).
#' @param language Passed to [ivt_write_parquet()]: output labels and
#'   label-derived column names in English (`"en"`, default) or French (`"fr"`).
#' @param refresh Re-download and re-parse even if cached outputs exist.
#' @param quiet Suppress progress messages.
#' @return An [arrow::open_dataset()] connection to the Parquet file. The Parquet
#'   path is attached as `attr(., "path")`; the resolved catalogue row (if any)
#'   as `attr(., "catalogue_row")`; the member-level table ([ivt_members()],
#'   read from the `_members.parquet` sidecar when present) as
#'   `attr(., "members")` -- [collect_ivt()] uses it to convert dimension
#'   columns into full-level factors.
#' @seealso [statcan_ivt_catalogue()], [read_ivt()]
#' @export
get_statcan_ivt <- function(catalogue, geo_attributes = FALSE, labels = TRUE,
                            dim_names = c("slug", "label"), language = "en",
                            refresh = FALSE, quiet = FALSE) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    cli::cli_abort("Package {.pkg arrow} is required to open the parsed Parquet.")
  }
  dim_names <- match.arg(dim_names)
  language <- ivt_norm_lang(language)
  catalogue <- as.character(catalogue)
  key <- ivt_catalogue_key(catalogue)
  # the language marker lets the English and French Parquets of one table coexist
  parquet <- file.path(ivt_cache_dir("data"),
                       paste0(key, "_", language, ".parquet"))

  if (!refresh && file.exists(parquet)) {
    return(ivt_parquet_connection(parquet, NULL))
  }

  # 1. Custom local file in the ivt cache takes precedence over the catalogue.
  ivt_path <- ivt_find_cached_ivt(catalogue)
  row <- NULL

  # 2. Otherwise resolve via the catalogue and download.
  if (is.na(ivt_path)) {
    row <- ivt_lookup_catalogue(catalogue, quiet = quiet)
    ivt_path <- statcan_ivt_download(row$download_url, key = key,
                                     overwrite = refresh, quiet = quiet)
  } else if (!quiet) {
    cli::cli_inform("Using local IVT {.path {ivt_path}}")
  }

  # 3. Decode and cache the tidy table as Parquet.
  if (!quiet) cli::cli_inform("Decoding {.path {ivt_path}}")
  tab <- read_ivt(ivt_path, geo_attributes = geo_attributes)
  ivt_write_parquet(tab, path = parquet, labels = labels, dim_names = dim_names,
                    language = language)

  ivt_parquet_connection(parquet, row)
}

#' List the canivt cache contents
#'
#' Lists the raw `.ivt` inputs (in the ivt cache) and the parsed data Parquets
#' (in the data cache), one row per file, enriched with catalogue metadata
#' (matched product number, title, census year, topic) when the file's cache key
#' matches a product in the [statcan_ivt_catalogue()]. The member sidecars
#' (`_members.parquet`) and the catalogue cache itself are infrastructure and are
#' not listed.
#'
#' @param catalogue A catalogue tibble (from [statcan_ivt_catalogue()]) used to
#'   enrich the listing. `NULL` (default) reads the **cached** catalogue if one
#'   exists and skips enrichment otherwise — it never triggers a scrape, so this
#'   function works offline.
#' @return A tibble with one row per cached file: `kind` (`"ivt"` or
#'   `"parquet"`), `key` (the cache key — the catalogue number for downloaded
#'   tables, the folder/file name otherwise), `language` (`"en"`/`"fr"` for a
#'   language-marked Parquet, `NA` for `.ivt` files and old unmarked Parquets),
#'   `path`, `bytes`, `modified`, and the catalogue columns `catalogue`, `title`,
#'   `census_year`, `topic` (`NA` when the key matches no product).
#' @seealso [get_statcan_ivt()], [statcan_ivt_catalogue()]
#' @export
list_ivt_cache <- function(catalogue = NULL) {
  ivt_dir  <- ivt_cache_dir("ivt",  create = FALSE)
  data_dir <- ivt_cache_dir("data", create = FALSE)
  norm <- function(p) normalizePath(p, winslash = "/", mustWork = FALSE)

  # raw .ivt inputs: <ivt_dir>/<key>/<file>.ivt, or a flat <key>.ivt. The key is
  # the per-table folder name (the .ivt inside can be named differently), or the
  # file stem when it sits directly in the cache root.
  ivt_files <- list.files(ivt_dir, pattern = "\\.ivt$", full.names = TRUE,
                          recursive = TRUE, ignore.case = TRUE)
  ivt_key <- vapply(ivt_files, function(f)
    if (norm(dirname(f)) == norm(ivt_dir)) tools::file_path_sans_ext(basename(f))
    else basename(dirname(f)), "")

  # parsed data Parquets: <data_dir>/<key>[_en|_fr].parquet. Drop the member
  # sidecars and the catalogue cache (not data tables).
  pq <- list.files(data_dir, pattern = "\\.parquet$", full.names = TRUE,
                   ignore.case = TRUE)
  pq <- pq[!grepl("_members\\.parquet$", pq, ignore.case = TRUE)]
  pq <- pq[basename(pq) != "statcan_ivt_catalogue.parquet"]
  pq_stem <- tools::file_path_sans_ext(basename(pq))
  pq_lang <- rep(NA_character_, length(pq)); pq_key <- pq_stem
  m <- regmatches(pq_stem, regexec("^(.*)_(en|fr)$", pq_stem, ignore.case = TRUE))
  for (i in seq_along(pq)) if (length(m[[i]]) == 3L) {
    pq_key[i] <- m[[i]][2]; pq_lang[i] <- tolower(m[[i]][3])
  }

  df <- data.frame(
    kind     = c(rep("ivt", length(ivt_files)), rep("parquet", length(pq))),
    key      = c(unname(ivt_key), pq_key),
    language = c(rep(NA_character_, length(ivt_files)), pq_lang),
    path     = c(ivt_files, pq),
    stringsAsFactors = FALSE)

  # file stats + catalogue enrichment columns, typed and 0-row-safe (rep(., n))
  n <- nrow(df)
  info <- file.info(df$path)
  df$bytes       <- if (n) info$size  else numeric(0)
  df$modified    <- if (n) info$mtime else as.POSIXct(character(0))
  df$catalogue   <- rep(NA_character_, n)
  df$title       <- rep(NA_character_, n)
  df$census_year <- rep(NA_integer_, n)
  df$topic       <- rep(NA_character_, n)

  if (n) {
    if (is.null(catalogue)) catalogue <- ivt_cached_catalogue(data_dir)
    if (!is.null(catalogue) && nrow(catalogue) &&
        "catalogue" %in% names(catalogue)) {
      cat_norm <- ivt_catalogue_norm(catalogue$catalogue)
      key_norm <- ivt_catalogue_norm(df$key)
      idx <- match(key_norm, cat_norm)                       # exact first
      for (i in which(is.na(idx))) {                         # then prefix
        h <- which(startsWith(cat_norm, key_norm[i]))
        if (length(h)) idx[i] <- h[1L]
      }
      df$catalogue   <- catalogue$catalogue[idx]
      df$title       <- catalogue$title[idx]
      df$census_year <- catalogue$census_year[idx]
      df$topic       <- catalogue$topic[idx]
    }
  }

  df <- df[order(df$key, df$kind, df$language), , drop = FALSE]
  tibble::as_tibble(df[c("kind", "key", "language", "catalogue", "title",
                         "census_year", "topic", "bytes", "modified", "path")])
}

# The cached catalogue tibble read directly from the data cache (no scrape), or
# NULL when there is no cache / arrow is unavailable.
ivt_cached_catalogue <- function(data_dir = ivt_cache_dir("data", create = FALSE)) {
  cf <- file.path(data_dir, "statcan_ivt_catalogue.parquet")
  if (!file.exists(cf) || !requireNamespace("arrow", quietly = TRUE)) return(NULL)
  tryCatch(tibble::as_tibble(arrow::read_parquet(cf)), error = function(e) NULL)
}

# Open the Parquet and attach provenance attributes (plus the member-level
# sidecar, when one was written, so collect_ivt() finds it on the connection
# and on any dplyr query built from it).
ivt_parquet_connection <- function(parquet, row) {
  ds <- arrow::open_dataset(parquet)
  attr(ds, "path") <- parquet
  attr(ds, "catalogue_row") <- row
  attr(ds, "members") <- ivt_read_members(ivt_members_path(parquet))
  ds
}

# A filesystem-safe cache key for a catalogue number / custom id.
ivt_catalogue_key <- function(catalogue) {
  gsub("[^A-Za-z0-9._-]+", "_", catalogue)
}

# Normalise a catalogue number for matching (drop punctuation, upper-case).
ivt_catalogue_norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", x))

# Find a locally-deposited .ivt for a custom identifier; NA if none.
ivt_find_cached_ivt <- function(id) {
  cache <- ivt_cache_dir("ivt", create = FALSE)
  flat <- list.files(cache, pattern = "\\.ivt$", full.names = TRUE,
                     ignore.case = TRUE)
  sub <- list.files(file.path(cache, id), pattern = "\\.ivt$",
                    full.names = TRUE, ignore.case = TRUE)
  cands <- c(file.path(cache, paste0(id, c(".ivt", ".IVT"))),
             flat[ivt_catalogue_norm(tools::file_path_sans_ext(basename(flat))) ==
                    ivt_catalogue_norm(id)],
             sub)
  cands <- cands[file.exists(cands)]
  if (length(cands)) cands[1] else NA_character_
}

# Resolve a catalogue number to its catalogue row (errors if not found).
ivt_lookup_catalogue <- function(catalogue, quiet = FALSE) {
  catl <- statcan_ivt_catalogue(quiet = quiet)
  want <- ivt_catalogue_norm(catalogue)
  norm <- ivt_catalogue_norm(catl$catalogue)
  hit <- which(norm == want)
  if (!length(hit)) hit <- which(startsWith(norm, want))
  if (!length(hit)) {
    cli::cli_abort(c(
      "No IVT product matches catalogue {.val {catalogue}}.",
      i = "It is also not a local .ivt in the ivt cache ({.path {ivt_cache_dir('ivt', create = FALSE)}}).",
      i = "See {.fn statcan_ivt_catalogue} for the available products."
    ))
  }
  if (length(hit) > 1L) {
    cli::cli_warn(c(
      "Catalogue {.val {catalogue}} matches {length(hit)} products; using the first.",
      i = "Matches: {.val {catl$catalogue[hit]}}"
    ))
  }
  catl[hit[1L], , drop = FALSE]
}

#' Download a StatCan IVT by its direct-download URL
#'
#' Downloads a `.ivt` (or its containing `.zip`) from a resolved
#' [statcan_ivt_resolve_url()] URL into the ivt cache and returns the local
#' `.ivt` path. The payload is sniffed: a `.zip` is unzipped, a raw IVT is kept
#' as-is.
#'
#' @param download_url A direct-download URL (a b2020 `.zip` or a
#'   `Download.cfm?PID=` endpoint).
#' @param key Cache key used to name the per-table folder under the ivt cache.
#' @param overwrite Re-download even if a `.ivt` already exists.
#' @param quiet Suppress the download message.
#' @return Path to the local `.ivt` file.
#' @export
statcan_ivt_download <- function(download_url, key, overwrite = FALSE,
                                 quiet = FALSE) {
  dest_dir <- file.path(ivt_cache_dir("ivt"), key)
  dir.create(dest_dir, showWarnings = FALSE, recursive = TRUE)

  existing <- list.files(dest_dir, pattern = "\\.ivt$", full.names = TRUE,
                         ignore.case = TRUE)
  if (length(existing) && !overwrite) return(existing[1])

  if (!quiet) cli::cli_inform("Downloading {.url {download_url}}")
  tmp <- tempfile(fileext = ".bin")
  on.exit(unlink(tmp), add = TRUE)
  utils::download.file(download_url, tmp, mode = "wb", quiet = quiet)

  sig <- readBin(tmp, "raw", n = 4L)
  is_zip <- length(sig) >= 2L && sig[1] == as.raw(0x50) && sig[2] == as.raw(0x4B)
  if (is_zip) {
    files <- utils::unzip(tmp, exdir = dest_dir)
    ivt <- grep("\\.ivt$", files, value = TRUE, ignore.case = TRUE)
    if (!length(ivt)) cli::cli_abort("No .ivt file found in the downloaded archive.")
    return(ivt[1])
  }
  if (!identical(as.integer(sig), c(4L, 0L, 32L, 0L))) {
    cli::cli_warn("Downloaded payload lacks the IVT {.val 04 00 20 00} signature.")
  }
  out <- file.path(dest_dir, paste0(key, ".ivt"))
  file.copy(tmp, out, overwrite = TRUE)
  out
}
