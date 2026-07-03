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

# First page-directory offset. The file states it in the header at
# IVT_HDR_DIR_PTR = 558 -- but the u16 field holds only the LOW 16 BITS of the
# offset (the directory start modulo 65536): tables whose directory sits past
# 64 KiB wrap (98-10-0013's directory is at 44761 + 1*65536 -- its cell decode
# was silently EMPTY under the unwrapped read; the 1996 table 95F0250XDB96001
# needs k = 2). Recover the true start as the smallest offset with that residue
# whose entry validates as a real page-directory record (sizes agree, offset
# points at a page marker) -- for every table whose directory sits below 64 KiB
# this is k = 0, the plain u16 read. Falls back to the historical constant when
# no candidate validates (the page pre-flight then rejects the file rather than
# decode from a wrong base).
ivt_idx0 <- function(raw) {
  n <- length(raw)
  if (n >= IVT_HDR_DIR_PTR + 2L) {
    lo <- rd_u16(raw, IVT_HDR_DIR_PTR)
    for (k in 0:max(0L, (n - lo) %/% 65536L)) {
      off <- lo + k * 65536L
      if (off <= 0L || off + 8L > n) next
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
