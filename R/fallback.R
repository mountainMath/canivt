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
  # every fallback carries the umbrella class (subclass first), so a caller's
  # custom class can never opt a path out of the canivt_fallback contract --
  # ivt_quietly() muffling, strict-mode upgrade, and the corpus ledger's
  # fallback assertions all key on it.
  class <- union(class, "canivt_fallback")
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

# A LOUD notice of a FAITHFUL-but-lossy read: the container itself stores a value
# truncated (a fixed-width record length cap), so our read is byte-exact yet the
# value is incomplete through no fault of the decoder. Unlike `ivt_fallback()` this
# is NOT a heuristic/content path -- the bytes we return are exactly what the file
# holds -- so strict mode does NOT upgrade it to an error (strict mode refuses
# risky reads, and there is nothing risky here, only a source limitation). It is
# classed so callers can detect it (e.g. cross-reference the companion flag column)
# or muffle it.
ivt_source_truncation <- function(msg, class, .envir = parent.frame()) {
  cli::cli_warn(msg, class = c(class, "canivt_source_truncation"), .envir = .envir)
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

# --- Graceful offline handling -------------------------------------------------
# The download / catalogue functions reach the network. CRAN's checks (and the
# `\donttest` examples they run) may execute without internet, so a connection
# failure must NOT abort with an error there. Every network access is funnelled
# through a helper that raises a classed `canivt_offline` error on failure; each
# exported entry point wraps its body in `ivt_offline_grace()`, which turns that
# one condition into an informative warning and an invisible `NULL` return.
# Internal cross-calls use the non-grace `_impl` cores so the signal reaches the
# right boundary; any error that is NOT a connection failure propagates normally.

ivt_offline_abort <- function(resource, parent = NULL) {
  cli::cli_abort(
    c("Could not reach {.url {resource}}.",
      i = "Check your internet connection; the resource may also be unavailable."),
    class = "canivt_offline", parent = parent, call = NULL)
}

# Wrap an exported network function's body. A `canivt_offline` condition becomes
# a warning + `invisible(NULL)`; everything else (including argument/usage errors)
# is left to propagate.
ivt_offline_grace <- function(expr) {
  tryCatch(
    expr,
    canivt_offline = function(cnd) {
      cli::cli_warn(conditionMessage(cnd), class = "canivt_offline_warning")
      invisible(NULL)
    })
}

# Download `url` to `destfile`, converting any connection failure (an error, or a
# non-zero status / missing file from `download.file()`) into `canivt_offline`.
# `headers` is passed through (e.g. the Borealis API key).
ivt_download_to <- function(url, destfile, quiet = FALSE, headers = NULL) {
  args <- list(url = url, destfile = destfile, mode = "wb", quiet = quiet)
  if (!is.null(headers)) args$headers <- headers
  status <- tryCatch(
    suppressWarnings(do.call(utils::download.file, args)),
    error = function(e) ivt_offline_abort(url, parent = e))
  if (!identical(as.integer(status), 0L) || !file.exists(destfile))
    ivt_offline_abort(url)
  invisible(destfile)
}
