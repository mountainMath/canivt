#' Download a Beyond 20/20 IVT table from Statistics Canada
#'
#' Fetches and unzips the `.ivt` for a StatCan data table from the public
#' Beyond 20/20 endpoint
#' (`https://www150.statcan.gc.ca/n1/<lang>/tbl/b2020/<pid>.zip`).
#'
#' @param pid StatCan product id, e.g. `"98100241"` or `9810024101`. Any
#'   trailing version digits are dropped to the 8-digit table id.
#' @param dest_dir Directory to download into (created if needed). Defaults to a
#'   per-table folder under the IVT cache ([ivt_cache_dir("ivt")][ivt_cache_dir],
#'   i.e. option `canivt.ivt_cache` or [tempdir()] when unset).
#' @param lang `"en"` (default) or `"fr"` endpoint.
#' @param overwrite Re-download even if the `.ivt` already exists. Default
#'   `FALSE`.
#' @param quiet Suppress the download progress bar. Default `FALSE`.
#' @return Path to the downloaded `.ivt` file, or `NULL` (invisibly, with a
#'   warning) if the endpoint could not be reached.
#' @examples
#' # Downloads from Statistics Canada. Returns NULL with a warning if offline
#' # (no error), so no try() is needed.
#' \donttest{
#' path <- ivt_download("98100241", dest_dir = tempdir())
#' if (!is.null(path)) ivt <- read_ivt(path)
#' }
#' @export
ivt_download <- function(pid, dest_dir = NULL, lang = c("en", "fr"),
                         overwrite = FALSE, quiet = FALSE) {
  ivt_offline_grace(
    ivt_download_impl(pid, dest_dir = dest_dir, lang = match.arg(lang),
                      overwrite = overwrite, quiet = quiet))
}

# Core download (raises `canivt_offline` on a connection failure); the exported
# ivt_download() wraps this in ivt_offline_grace(), internal callers use it
# directly so the offline signal reaches their own grace boundary.
ivt_download_impl <- function(pid, dest_dir = NULL, lang = c("en", "fr"),
                              overwrite = FALSE, quiet = FALSE) {
  lang <- match.arg(lang)
  pid8 <- ivt_pid8(pid)
  if (is.null(dest_dir)) dest_dir <- file.path(ivt_cache_dir("ivt"), pid8)
  dir.create(dest_dir, showWarnings = FALSE, recursive = TRUE)

  existing <- list.files(dest_dir, pattern = "\\.ivt$", full.names = TRUE,
                         ignore.case = TRUE)
  if (length(existing) && !overwrite) return(existing[1])

  url <- sprintf("https://www150.statcan.gc.ca/n1/%s/tbl/b2020/%s.zip",
                 lang, pid8)
  zip <- file.path(dest_dir, paste0(pid8, ".zip"))
  if (!quiet) cli::cli_inform("Downloading {.url {url}}")
  ivt_download_to(url, zip, quiet = quiet)
  files <- utils::unzip(zip, exdir = dest_dir)

  ivt <- grep("\\.ivt$", files, value = TRUE, ignore.case = TRUE)
  if (!length(ivt)) {
    cli::cli_abort("No .ivt file found in the downloaded archive for {pid8}.")
  }
  ivt[1]
}

# Store a freshly-downloaded payload in `dest_dir` and return the `.ivt` path.
# Sniffs the file signature: a `.zip` (PK\003\004) is unzipped and its first
# `.ivt` returned; a raw payload is copied to `out_name` (a missing IVT
# `04 00 20 00` signature only warns). Shared by statcan_ivt_download() and
# borealis_ivt_download().
ivt_store_download <- function(tmp, dest_dir, out_name) {
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
  out <- file.path(dest_dir, out_name)
  file.copy(tmp, out, overwrite = TRUE)
  out
}

# Normalise a product id to the 8-digit table id used by the b2020 endpoint.
ivt_pid8 <- function(pid) {
  digits <- gsub("[^0-9]", "", as.character(pid))
  if (nchar(digits) < 8L) {
    cli::cli_abort("{.arg pid} {.val {pid}} does not contain an 8-digit table id.")
  }
  substr(digits, 1L, 8L)
}
