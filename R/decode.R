#' Decode IVT page values into cells
#'
#' Each page stores a positional, dimension-padded presence bitmap followed by a
#' dense run of unaligned little-endian integers (base-5 rounded). Presence rows
#' are 32 bytes = one Period; within a row Statistics occupy 8-byte blocks and
#' Housing indicators sit within a block, with adjacent housing bytes swapped
#' (`hi ^ 1`); each presence byte's bits 7..1 flag Tenure members 0..6. Values
#' are dense in (period, stat, housing, tenure) order. See `container.R`.
#'
#' @keywords internal
#' @noRd
NULL

# Group grids (one per period window). Rows are in the exact value order:
# period-row outer, statistics middle, housing innermost. Precomputed so the
# per-page hot loop stays vectorised.
.ivt_group_grid <- function(nrows) {
  g <- expand.grid(hi = 0:5, st = 0:2, r = 0:(nrows - 1L),
                   KEEP.OUT.ATTRS = FALSE)
  g$byte_idx <- g$r * 32L + g$st * 8L + bitwXor(g$hi, 1L)
  g
}
IVT_GRID <- list(.ivt_group_grid(8L), .ivt_group_grid(5L))  # window 0, window 1

# Decode one page to a data frame of (period, stat, hi, tenure, value), all
# 0-based member indices. age/hh are constant per page and added by the caller.
ivt_decode_page <- function(raw, off, size, h0, window) {
  width <- if (ivt_page_is_int16(h0)) 2L else 4L
  grid <- IVT_GRID[[window + 1L]]
  vstart <- ivt_value_start(raw, off, h0)

  # presence bytes for each group (presence begins at off + 4)
  pres <- as.integer(raw[off + 4L + grid$byte_idx + 1L])

  # bits 7..1 -> tenure 0..6, group-major / tenure-inner flatten
  ng <- length(pres)
  bit <- 7L - rep(0:6, times = ng)           # tenure t uses bit (7 - t)
  pres_rep <- rep(pres, each = 7L)
  present <- bitwAnd(bitwShiftR(pres_rep, bit), 1L) == 1L

  period <- rep(window * 8L + grid$r, each = 7L)[present]
  st <- rep(grid$st, each = 7L)[present]
  hi <- rep(grid$hi, each = 7L)[present]
  ten <- rep(0:6, times = ng)[present]

  nv <- sum(present)
  vals <- rd_int_run(raw, vstart, nv, width)
  list(period = period, stat = st, hi = hi, ten = ten, value = vals)
}

#' Decode every cell of one geography (0-based index) to a tibble.
#'
#' Columns are 1-based member indices (`geo`, `age`, `hh`, `period`, `stat`,
#' `hi`, `tenure`) matching the StatCan metadata Member IDs, plus `value`.
#' @keywords internal
#' @noRd
ivt_decode_geography <- function(raw, geo_index) {
  pages <- ivt_geo_pages(raw, geo_index)
  parts <- vector("list", nrow(pages))
  for (i in seq_len(nrow(pages))) {
    pg <- ivt_decode_page(raw, pages$offset[i], pages$size[i],
                          pages$h0[i], pages$window[i])
    n <- length(pg$value)
    if (n == 0L) next
    parts[[i]] <- list(
      age = rep.int(pages$age[i] + 1L, n),
      hh = rep.int(pages$hh[i] + 1L, n),
      period = pg$period + 1L,
      stat = pg$stat + 1L,
      hi = pg$hi + 1L,
      tenure = pg$ten + 1L,
      value = pg$value
    )
  }
  parts <- parts[!vapply(parts, is.null, logical(1))]
  if (length(parts) == 0L) {
    return(tibble::tibble(
      geo = integer(), age = integer(), hh = integer(), period = integer(),
      stat = integer(), hi = integer(), tenure = integer(), value = integer()))
  }
  cat_col <- function(name) unlist(lapply(parts, `[[`, name), use.names = FALSE)
  tibble::tibble(
    geo = ivt_geo_member_id(geo_index),
    age = cat_col("age"), hh = cat_col("hh"), period = cat_col("period"),
    stat = cat_col("stat"), hi = cat_col("hi"), tenure = cat_col("tenure"),
    value = cat_col("value")
  )
}
