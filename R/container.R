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
# needs k = 2). The low-16-bit unwrap + entry validation live in
# `ivt_f2_dir_anchor_header()` (container-f2.R), shared with the metadata-side
# page-directory finder. Falls back to the historical constant when no candidate
# validates (the page pre-flight then rejects the file rather than decode from a
# wrong base).
#
# NOTE: the DECODE path deliberately uses only the validated header pointer, not
# the marker SCAN (`ivt_f2_find_directory()`). The scan can LOCATE a directory the
# header pointer misses (the LFHR `Table-210`: @558 = 34997 but the directory is at
# 35197), but that lineage's 6-dim/long-timeseries directory has an irregular
# packing the positional stride model does not yet capture (validity alternates
# 8/12 valid entries per block; characteristics decode only 4 of 10; the in-page
# education dimension is off by one) -- so decoding from the scanned base would
# SILENTLY mis-decode. Until that geometry is understood, such files stay rejected
# by the pre-flight rather than routed through the scan here. (The scan remains in
# `ivt_f2_find_directory()` for the metadata-side page count, where a mis-modelled
# stride cannot corrupt cell values.)
ivt_idx0 <- function(raw) {
  anchor <- ivt_f2_dir_anchor_header(raw)
  if (!is.null(anchor)) anchor else IVT_IDX0_DEFAULT
}
