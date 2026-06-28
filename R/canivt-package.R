#' @keywords internal
"_PACKAGE"

#' Download and read a StatCan IVT table in one step
#'
#' Convenience wrapper that [ivt_download()]s a table by product id and then
#' [read_ivt()]s it.
#'
#' @inheritParams ivt_download
#' @param ... Passed to [ivt_download()].
#' @return An `ivt` object (see [read_ivt()]).
#' @examples
#' \dontrun{
#' tab <- ivt_read_table("98100241")
#' ivt_write_parquet(tab, "98100241.parquet")
#' ivt_write_metadata(tab, "98100241_metadata")
#' }
#' @export
ivt_read_table <- function(pid, dest_dir = NULL, lang = c("en", "fr"), ...) {
  path <- ivt_download(pid, dest_dir = dest_dir, lang = match.arg(lang), ...)
  read_ivt(path)
}
