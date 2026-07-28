# The published table, not the store.
#
# An `.ivt` writes only non-zero cells, so its rows are not the rows StatCan
# publishes: the CSV carries the whole cartesian grid, writing the zeros out and
# flagging the cells that have no value with a symbol. `ivt_decode(complete =
# TRUE)` reproduces that, and the rule it applies is read off the file, not off
# the CSV:
#
#   * a cell with a stored value                 -> that value, no symbol
#   * absent, and the page's cell-status block   -> `value = NA`, plus the
#     names a reason for it                         `symbol`/`status` the file's
#                                                   own legend gives that code
#   * absent, and the page's mask says only         `value = NA`, symbol and
#     "not a zero"                               -> status `NA` (the mask states
#                                                   no reason)
#   * absent, and the file says nothing about    -> the published zero
#     it
#
# The last line is the one worth stating plainly, because "absent implies zero"
# is false for the STORE: it is true only once the page's own status block has
# been read and has declined to flag the cell. A page that writes no tail at all
# is a page with nothing to flag -- validated cell-for-cell against StatCan's
# published CSVs on tables covering every page class -- and a page whose tail
# cannot be read is counted and reported (`canivt_absent_unclassified`), never
# folded into the zeros in silence.

# Completion multiplies the row count by the grid/store ratio (~12x over the
# corpus, far more on a sparse table), so a table that decodes comfortably as a
# store can exhaust memory as a grid. Refuse up front with the numbers and the
# two ways out rather than dying in an allocation.
ivt_complete_budget <- function(lay, max_cells = getOption("canivt.max_cells",
                                                           1e8)) {
  ncell <- prod(as.numeric(lay$counts))
  if (is.finite(max_cells) && ncell > max_cells) {
    cli::cli_abort(c(
      "The complete grid of this table is {.val {format(ncell, big.mark = ',', scientific = FALSE)}} cells ({paste(lay$counts, collapse = ' x ')}), over the {.code canivt.max_cells} limit of {.val {format(max_cells, big.mark = ',', scientific = FALSE)}}.",
      i = "Read the stored (non-zero) cells only with {.code complete = FALSE}, or raise the limit with {.code options(canivt.max_cells = ...)}."
    ), class = "canivt_complete_too_large")
  }
  invisible(ncell)
}

# Assemble the completed grid. `full_md`/`full_v`/`full_cd` hold, per directory
# coordinate, the kept grid coordinates, their values (0 where absent and
# unremarked, NA where flagged) and their reason codes (0 none, -1 "missing,
# reason unstated" from a 1-bit mask, >0 a code from the file's own legend).
ivt_complete_cells <- function(full_md, full_v, full_cd, fi, lay, tally,
                               unk_tal = integer(IVT_STATUS_NCODE),
                               leg_declared = TRUE, legend = NULL) {
  m <- lay$n_dim
  if (fi == 0L) {
    out <- tibble::tibble(.rows = 0L)
    for (j in seq_len(m)) out[[lay$slugs[j]]] <- integer(0)
    out$value <- numeric(0)
    cdv <- integer(0)
  } else {
    cols <- do.call(rbind, full_md[seq_len(fi)])
    out <- tibble::tibble(.rows = nrow(cols))
    for (j in seq_len(m)) out[[lay$slugs[j]]] <- cols[, j]
    out$value <- unlist(full_v[seq_len(fi)], use.names = FALSE)
    cdv <- unlist(full_cd[seq_len(fi)], use.names = FALSE)
  }
  leg <- legend
  if (is.null(leg)) leg <- list(text_en = IVT_STATUS_VOCAB,
                                symbol = IVT_STATUS_SYMBOLS)
  # Only a positive code names a reason: 0 is "nothing to say" and -1 is a mask
  # bit, which says a cell is missing but never why.
  idx <- cdv; idx[idx <= 0L] <- NA_integer_
  sym <- leg$symbol[idx]; sta <- leg$text_en[idx]
  # A code the legend does not name is NOT guessed at (it is counted and
  # reported by `ivt_status_report()`); the cell keeps its NA value and stays
  # unlabelled.
  lvl_s <- unique(leg$symbol[!is.na(leg$symbol)])
  lvl_t <- unique(leg$text_en[!is.na(leg$text_en)])
  out$symbol <- factor(sym, levels = lvl_s)
  out$status <- factor(sta, levels = lvl_t)
  ivt_status_report(tally, unk_tal, leg_declared, sum(is.na(out$value)),
                    unclassified = FALSE)
  attr(out, "pages") <- tally
  attr(out, "legend") <- legend
  out
}

# The flagged subset of a completed grid, in the shape the sparse path's
# `"missing"` attribute has always had: coordinates, `symbol`, `status`. On the
# completed table this is a view, not a second decode.
ivt_flagged_cells <- function(cells) {
  i <- which(is.na(cells$value))
  out <- cells[i, setdiff(names(cells), "value"), drop = FALSE]
  out$symbol <- as.character(out$symbol)
  out$status <- as.character(out$status)
  attr(out, "pages") <- attr(cells, "pages", exact = TRUE)
  attr(out, "legend") <- attr(cells, "legend", exact = TRUE)
  out
}
