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
#' @return Path to the downloaded `.ivt` file.
#' @export
ivt_download <- function(pid, dest_dir = NULL, lang = c("en", "fr"),
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
  utils::download.file(url, zip, mode = "wb", quiet = quiet)
  files <- utils::unzip(zip, exdir = dest_dir)

  ivt <- grep("\\.ivt$", files, value = TRUE, ignore.case = TRUE)
  if (!length(ivt)) {
    cli::cli_abort("No .ivt file found in the downloaded archive for {pid8}.")
  }
  ivt[1]
}

# Normalise a product id to the 8-digit table id used by the b2020 endpoint.
ivt_pid8 <- function(pid) {
  digits <- gsub("[^0-9]", "", as.character(pid))
  if (nchar(digits) < 8L) {
    cli::cli_abort("{.arg pid} {.val {pid}} does not contain an 8-digit table id.")
  }
  substr(digits, 1L, 8L)
}
