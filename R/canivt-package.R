#' @keywords internal
"_PACKAGE"

#' Download and read a StatCan IVT table in one step
#'
#' Convenience wrapper that [ivt_download()]s a table by product id and then
#' [read_ivt()]s it.
#'
#' @inheritParams ivt_download
#' @param missing Passed to [read_ivt()]: when `TRUE`, also decode each page's
#'   cell-status block, adding `$missing` (which absent cells are suppressed,
#'   not applicable, and so on, per the file's own legend).
#' @param ... Passed to [ivt_download()].
#' @return An `ivt` object (see [read_ivt()]), or `NULL` (invisibly, with a
#'   warning) if the table could not be downloaded (e.g. offline).
#' @examples
#' # Downloads from Statistics Canada. Returns NULL with a warning if offline
#' # (no error), so no try() is needed.
#' \donttest{
#' tab <- ivt_read_table("98100241")
#' if (!is.null(tab)) {
#'   ivt_write_parquet(tab, file.path(tempdir(), "98100241.parquet"))
#'   ivt_write_metadata(tab, file.path(tempdir(), "98100241_metadata"))
#' }
#' }
#' @export
ivt_read_table <- function(pid, dest_dir = NULL, lang = c("en", "fr"),
                           missing = FALSE, ...) {
  ivt_offline_grace({
    path <- ivt_download_impl(pid, dest_dir = dest_dir, lang = match.arg(lang), ...)
    read_ivt(path, missing = missing)
  })
}
