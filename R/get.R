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
                            refresh = FALSE, quiet = FALSE) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    cli::cli_abort("Package {.pkg arrow} is required to open the parsed Parquet.")
  }
  catalogue <- as.character(catalogue)
  key <- ivt_catalogue_key(catalogue)
  parquet <- file.path(ivt_cache_dir("data"), paste0(key, ".parquet"))

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
  ivt_write_parquet(tab, path = parquet, labels = labels)

  ivt_parquet_connection(parquet, row)
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
