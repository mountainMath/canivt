#' IVT container: geography index and page directory
#'
#' Reverse-engineered layout of the 2021-era StatCan Beyond 20/20 `.ivt` format
#' (reference table 98-10-0241). Per-geography page directories live at
#' `IVT_IDX0 + n * IVT_IDX_STRIDE`; directory `n` (0-based) is geography member
#' `n + 1`. Each directory holds up to 288 page-directory entries
#' `[u32 offset][u16 size][u16 size]`, positional over the outer dimensions.
#'
#' @keywords internal
#' @noRd
NULL

IVT_IDX0 <- 37167          # first page-directory offset
IVT_IDX_STRIDE <- 0x1000   # 4096 bytes between per-geography directories
IVT_PAGES_PER_GEO <- 288L  # 9 age x 16 hhtype x 2 period-windows

# Dimension member counts (innermost = tenure), and period-window split.
IVT_DIM <- list(age = 9L, hh = 16L, period = 13L, stat = 3L, hi = 6L, ten = 7L)
IVT_WINDOW_PERIODS <- c(8L, 5L)  # window 0 -> periods 0..7, window 1 -> 8..12

# An index entry is valid when both size fields agree and the offset points into
# the data region (not the header / not past EOF).
ivt_entry_valid <- function(off, s1, s2, n) {
  s1 == s2 && s1 > 0 && off > 1e6 && off < n
}

#' Count the geographies (valid page directories) in an IVT raw vector.
#' @keywords internal
#' @noRd
ivt_geography_count <- function(raw) {
  n <- length(raw)
  g <- 0L
  repeat {
    b <- IVT_IDX0 + g * IVT_IDX_STRIDE
    if (b + 8 > n) break
    off <- rd_u32(raw, b)
    s1 <- rd_u16(raw, b + 4L)
    s2 <- rd_u16(raw, b + 6L)
    if (!ivt_entry_valid(off, s1, s2, n)) break
    g <- g + 1L
  }
  g
}

# Map metadata Member ID (1-based) <-> geography directory index (0-based).
ivt_geo_member_id <- function(geo_index) geo_index + 1L

#' List all non-empty pages for one geography (0-based index).
#'
#' Returns a data frame with one row per page: directory slot `k`, byte `offset`
#' and `size`, the 4 header bytes, and the positional coordinate
#' (`age`, `hh`, `window`), all 0-based.
#' @keywords internal
#' @noRd
ivt_geo_pages <- function(raw, geo_index) {
  n <- length(raw)
  base <- IVT_IDX0 + geo_index * IVT_IDX_STRIDE
  k <- 0:(IVT_PAGES_PER_GEO - 1L)
  o <- base + 8L * k
  off <- vapply(o, function(x) rd_u32(raw, x), numeric(1))
  s1 <- vapply(o, function(x) rd_u16(raw, x + 4L), integer(1))
  s2 <- vapply(o, function(x) rd_u16(raw, x + 6L), integer(1))
  keep <- s1 == s2 & s1 > 0 & off > 1e6 & off < n
  k <- k[keep]; off <- off[keep]; sz <- s1[keep]
  h0 <- as.integer(raw[off + 1L])
  data.frame(
    k = k, offset = off, size = sz,
    h0 = h0,
    age = k %/% 32L,
    hh = (k %/% 2L) %% IVT_DIM$hh,
    window = k %% 2L
  )
}

# Header byte 0 encodes the value layout:
#   low nibble  0x4 -> int32, 0x2 -> int16
#   high nibble 0x8 -> values follow presence, 0xa -> 0xFF run + 2-byte prefix
ivt_page_is_int16 <- function(h0) bitwAnd(h0, 0x0F) == 0x02
ivt_page_has_sep  <- function(h0) bitwAnd(h0, 0xF0) == 0xA0

# 0-based offset where a page's dense value run begins.
ivt_value_start <- function(raw, off, h0, presence_len = 256L) {
  p <- off + 4L + presence_len
  if (!ivt_page_has_sep(h0)) return(p)
  while (as.integer(raw[p + 1L]) == 0xFF) p <- p + 1L
  p + 2L
}
