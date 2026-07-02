#' Loud fallbacks
#'
#' Every primary read in this package is positional: header pointers, block
#' directories, framed value entries. The content-heuristic paths (marker scans,
#' regex parses, count-keyed label matching, the legacy stride walk) survive only
#' as fallbacks -- and history shows they are exactly the paths that misread new
#' layouts *silently* (the byte-order dedup scan misordered thousands of
#' geography members on the 1991/2006/2011 tables before the positional readers
#' replaced it). So a fallback never engages quietly: `ivt_fallback()` raises a
#' classed warning (`canivt_fallback`, or the caller's `class`) naming the
#' affected read, and `options(canivt.strict = TRUE)` upgrades it to an error
#' (class `<class>_error`) for pipelines that would rather fail than risk
#' heuristically-read values on an unvalidated file.
#'
#' @keywords internal
#' @noRd
ivt_fallback <- function(msg, class = "canivt_fallback", .envir = parent.frame()) {
  if (isTRUE(getOption("canivt.strict", FALSE))) {
    cli::cli_abort(c(msg, i = paste(
      "Strict mode ({.code options(canivt.strict = TRUE)}) refuses",
      "heuristic/incomplete reads; unset it to fall back with a warning."
    )), class = paste0(class, "_error"), .envir = .envir)
  }
  cli::cli_warn(c(msg, i = paste(
    "The primary (positional, validated) read path could not supply this, so",
    "the result may be incomplete or heuristically read; treat the affected",
    "values with care. {.code options(canivt.strict = TRUE)} makes this an error."
  )), class = class, .envir = .envir)
  invisible(NULL)
}

# Run a speculative probe silently: format DETECTION (ivt_family) tries readers
# on files it may then reject, so a fallback engaging there is not yet a read of
# anything -- muffle the classed warning (and, under strict mode, treat the
# refused fallback as "not found"). Real reads go through the loud path.
ivt_quietly <- function(expr) {
  tryCatch(
    withCallingHandlers(expr,
                        canivt_fallback = function(w) invokeRestart("muffleWarning")),
    canivt_fallback_error = function(e) NULL)
}
