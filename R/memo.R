#' Per-file memo for the expensive header parses
#'
#' The header-derived structures -- the dimension descriptor, the per-dimension
#' block directories, the derived layout, the geography dimension index and
#' count, the geography attribute schema, the page directory -- are pure
#' functions of the file bytes, but the call graph re-derives them many times
#' per read: the descriptor alone from ~13 sites (each re-running the codebook
#' count reconciliation, which strict-parses slot directories), and every
#' dimension's block directory at least three times (labels / ordinals /
#' footnotes). This memo caches them per raw vector, TRANSPARENTLY: no function
#' signature changes, so every internal remains directly callable with a plain
#' raw vector, exactly as the tests (and the detection gate) do.
#'
#' Design:
#' - ONE slot, holding the last raw vector seen. A hit requires
#'   `identical(raw, slot$raw)` -- byte-exact, so a doctored copy of a file can
#'   never reuse the original's parse (`identical()` short-circuits on the
#'   common same-object case, and on the first differing byte otherwise).
#' - Warnings raised during a memoized compute (e.g. the loud
#'   `canivt_descriptor_reloc` fallback) are RECORDED with the value and
#'   RE-RAISED on every cache hit, so memoization is semantically transparent:
#'   a loud read stays loud however often it is logically repeated, and
#'   `ivt_quietly()` / `expect_warning()` behave identically with or without a
#'   warm cache. Errors are never cached -- a throwing compute rethrows on
#'   every call, so strict mode stays strict.
#' - The public readers (`read_ivt()`, `ivt_metadata()`) clear the slot on
#'   exit, so no file's bytes are retained after a read completes.
#'
#' @keywords internal
#' @noRd
.canivt_memo <- new.env(parent = emptyenv())

# Return `compute()` for this (raw, what) pair, computing it at most once per
# raw vector. `what` is the cache key ("descriptor", "layout", "dim_dir_3", ...).
ivt_memo <- function(raw, what, compute) {
  slot <- .canivt_memo$slot
  if (is.null(slot) || !identical(slot$raw, raw)) {
    slot <- new.env(parent = emptyenv())
    slot$raw <- raw
    .canivt_memo$slot <- slot
  }
  if (exists(what, envir = slot, inherits = FALSE)) {
    e <- get(what, envir = slot, inherits = FALSE)
    for (w in e$warnings) warning(w)
    return(e$value)
  }
  ws <- list()
  # record without muffling: the warning propagates normally on the first
  # compute AND is replayed on every later hit.
  v <- withCallingHandlers(compute(),
                           warning = function(w) ws[[length(ws) + 1L]] <<- w)
  assign(what, list(value = v, warnings = ws), envir = slot)
  v
}

# Drop the memo slot (and with it the reference to the cached raw vector).
ivt_memo_clear <- function() {
  rm(list = ls(.canivt_memo, all.names = TRUE), envir = .canivt_memo)
  invisible(NULL)
}
