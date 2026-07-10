#' IVT container: the page-directory anchor
#'
#' The unified decoder (`decode.R`) addresses the page directory positionally from
#' `ivt_idx0(raw)` (the header pointer) using descriptor-derived strides, so it no
#' longer needs the reverse-engineered per-geography geometry that used to live
#' here (the legacy 0x1000-stride geography counter is retired; per-geography
#' directory strides are computed by `ivt_layout()`).
#'
#' @keywords internal
#' @noRd
NULL

IVT_IDX0_DEFAULT <- 37167L # fallback first page-directory offset (98-10-0241)

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
      if (off <= 0L) next
      en <- ivt_dir_entry(raw, off, n)
      if (!is.null(en) && en$marker) return(off)
    }
  }
  IVT_IDX0_DEFAULT
}
