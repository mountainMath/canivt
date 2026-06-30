#' IVT container: page-directory anchor and the legacy geography counter
#'
#' The unified decoder (`decode.R`) addresses the page directory positionally from
#' `ivt_idx0(raw)` (the header pointer) using descriptor-derived strides, so it no
#' longer needs the reverse-engineered per-geography geometry that used to live
#' here. What remains is the directory anchor and the legacy 0x1000-stride
#' geography counter (kept only for the family detector / regression checks).
#'
#' @keywords internal
#' @noRd
NULL

IVT_IDX0_DEFAULT <- 37167L # fallback first page-directory offset (98-10-0241)
IVT_IDX_STRIDE <- 0x1000   # 4096 bytes; the per-geography directory stride of the
                           # large 2021 family-1 tables (not universal -- 98-10-0662
                           # uses 0x80 -- so only the legacy counter relies on it)

# First page-directory offset. The file states it in the header
# (u16 @ IVT_HDR_DIR_PTR = 558), so we read it rather than hard-coding the
# reverse-engineered constant. Validate the pointer by checking its first entry is
# a real page-directory record (sizes agree, offset points at a page marker) --
# this works regardless of file size, unlike a fixed large-offset floor (small
# tables such as 98-10-0662 have page offsets well under 1e6). Falls back to the
# constant when the header pointer is absent or does not validate.
ivt_idx0 <- function(raw) {
  n <- length(raw)
  if (n >= IVT_HDR_DIR_PTR + 2L) {
    off <- rd_u16(raw, IVT_HDR_DIR_PTR)
    if (off > 0L && off + 8L <= n) {
      e <- rd_u32(raw, off); s1 <- rd_u16(raw, off + 4L); s2 <- rd_u16(raw, off + 6L)
      if (s1 == s2 && s1 > 0L && e > 0L && e + 4L <= n && ivt_f2_is_marker(raw, e))
        return(off)
    }
  }
  IVT_IDX0_DEFAULT
}

# An index entry is valid when both size fields agree and the offset points into
# the data region (not the header / not past EOF). Used only by the legacy counter.
ivt_entry_valid <- function(off, s1, s2, n) {
  s1 == s2 && s1 > 0 && off > 1e6 && off < n
}

#' Legacy 0x1000-stride geography counter.
#'
#' Counts contiguous valid page directories at the historical `IVT_IDX_STRIDE`.
#' Correct for the large 2021 family-1 tables (e.g. 166 for 98-10-0241), but only
#' a heuristic in general -- it reads 348 for 98-10-0077 (whose real per-geography
#' stride is 0x2000) and 0 for small tables -- so the decoder uses the descriptor
#' geography count (`ivt_f2_geo_count()`) instead. Retained for the family detector
#' and regression tests.
#' @keywords internal
#' @noRd
ivt_geography_count <- function(raw) {
  n <- length(raw)
  idx0 <- ivt_idx0(raw)
  g <- 0L
  repeat {
    b <- idx0 + g * IVT_IDX_STRIDE
    if (b + 8 > n) break
    off <- rd_u32(raw, b)
    s1 <- rd_u16(raw, b + 4L)
    s2 <- rd_u16(raw, b + 6L)
    if (!ivt_entry_valid(off, s1, s2, n)) break
    g <- g + 1L
  }
  g
}
