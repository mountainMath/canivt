#' IVT container family 2: single contiguous page directory
#'
#' The second Beyond 20/20 container family (e.g. the 2021 table 98-10-0023,
#' Age x Gender) shares the `04 00 20 00` signature but, unlike family 1
#' (per-geography page directories at a fixed stride), stores **one contiguous
#' page directory** of 8-byte records `[u32 page_offset][u16 size][u16 size]`.
#' The directory is in **geography member-id order** and each page holds a fixed
#' block of `IVT_F2_GEOS_PER_PAGE` geographies. A page is
#' `[4-byte marker][presence section][trailer][dense value run]`:
#'
#' - marker `88 01 20 08` (plain) or `a8 01 41 08` (the `0xa8` variant);
#' - presence section = `IVT_F2_GEOS_PER_PAGE` x 64-byte records, one per geo,
#'   in value-run order (see `decode-f2.R` for the byte-pair-swap decode);
#' - trailer: a short `0xFF` run whose length depends on the marker, so the dense
#'   value run starts at `page_offset + 264` (`88`) or `+ 270` (`a8`);
#' - value run: dense little-endian float64, one per present cell, in the same
#'   order as the presence records.
#'
#' @keywords internal
#' @noRd
NULL

# Default geos-per-page for the original 3-dimension reference tables
# (98-10-0023, 1003011: 4 geos/page). It is *computed* per file from the header
# descriptor (`ivt_f2_geos_per_page()`; the presence-record size comes from
# `ivt_f2_bit_layout()`) so arbitrary-dimension tables decode; this remains only
# as the fallback when the descriptor is unavailable.
IVT_F2_GEOS_PER_PAGE <- 4L

# A family-2 page marker is `[b0] 01 [b2] [b3]` where b0's high nibble is 0x8 or
# 0xa (the plain vs 0xFF-run variants, as in family 1) and its low nibble is the
# value-width code (2/4/8). Markers seen in 98-10-0023: 88 01 20 08, a8 01 41 08,
# a2 01 03 09.
#
# The fourth byte `b3` ENCODES the size of an auxiliary head block between the
# trailer and the dense value run: `32 * (b3 - 8)` bytes (see
# `ivt_value_trailer()`, decode.R). `0x08`/`0x09` are the modern values (no
# head / the 32-byte block formerly attributed to the 0xa2 marker); the 2006
# census vintage (97-563-XCB2006072) uses `0x0a`/`0x0c` (64/128-byte heads,
# whose pages also append per-(geo, outer-dim) suppression-mask records AFTER
# the value run -- see ivt-format.md "The b3 head block and suppression tails").
#
# A ZERO high nibble is the DENSE page variant (the 1991 profile tables
# 98F0172X / 95F0170X): `[b0] 01 [u16 count]` followed immediately by `count`
# little-endian values, one per in-page grid position in grid order (absent
# cells stored as literal zeros; `count` may exceed the grid for zero padding).
# No presence record, no trailer, no head -- bytes 3-4 are the value COUNT, not
# b2/b3, so the whole-marker test cannot constrain them beyond count > 0.
ivt_f2_marker_b0 <- c(0x82L, 0x84L, 0x88L, 0xa2L, 0xa4L, 0xa8L)
ivt_f2_marker_b0_dense <- c(0x02L, 0x04L, 0x08L)
ivt_f2_marker_b3 <- c(0x08L, 0x09L, 0x0aL, 0x0cL)
ivt_f2_is_marker_byte0 <- function(b) b %in% ivt_f2_marker_b0

# Whole-marker test at a 0-based page offset.
ivt_f2_is_marker <- function(raw, off) {
  b0 <- as.integer(raw[off + 1L])
  if (as.integer(raw[off + 2L]) != 0x01L) return(FALSE)
  if (b0 %in% ivt_f2_marker_b0_dense) return(rd_u16(raw, off + 2L) > 0L)
  b0 %in% ivt_f2_marker_b0 && as.integer(raw[off + 4L]) %in% ivt_f2_marker_b3
}

# The per-page value parameters (value width, trailer, value-run start) are
# derived structurally from the marker in `ivt_value_trailer()` (decode.R): the
# low nibble is the width code, the high nibble selects the pad formula. The
# former hard-coded six-marker trailer table lived here; the formula reproduces
# it exactly.

# A directory record is valid when both size fields agree, the size is positive,
# and the offset points at a page marker past the fixed header region. (The
# floor used to be a hard-coded 1e5, a content guess from the big census files;
# it silently truncated the directory of small files -- 98-400-X2016387's pages
# start at ~7 KB, so the perfectly valid header pointer was rejected and the
# marker-scan fallback found only the 6 of 22 pages above 100 KB.)
ivt_f2_entry_valid <- function(raw, o, n) {
  if (o + 8L > n) return(FALSE)
  s1 <- rd_u16(raw, o + 4L)
  s2 <- rd_u16(raw, o + 6L)
  if (s1 != s2 || s1 <= 0L) return(FALSE)
  off <- rd_u32(raw, o)                      # u32 at o
  if (off < 1024L || off + 4 > n) return(FALSE)
  ivt_f2_is_marker(raw, off)
}

# Header field (0-based): u16 pointer to the page-directory start. The file states
# where the directory is, so we do not have to scan for page markers to find it.
IVT_HDR_DIR_PTR <- 558L

# The directory anchor from the header pointer, when it validates.
ivt_f2_dir_anchor_header <- function(raw) {
  n <- length(raw)
  if (n < IVT_HDR_DIR_PTR + 2L) return(NULL)
  off <- rd_u16(raw, IVT_HDR_DIR_PTR)
  if (off > 0L && ivt_f2_entry_valid(raw, off, n)) off else NULL
}

# Fallback only: locate a directory record by scanning for the first page marker
# and the record that points at it (used if the header pointer is absent/invalid).
ivt_f2_dir_anchor_scan <- function(raw) {
  n <- length(raw)
  win <- min(n, 600000L)
  v <- as.integer(raw[1:win])
  mk <- which(v[1:(win - 3L)] %in% ivt_f2_marker_b0 &
                v[2:(win - 2L)] == 0x01L & v[4:win] %in% ivt_f2_marker_b3) - 1L
  mk <- mk[mk >= 1e5]
  if (!length(mk)) return(NULL)
  target <- mk[1]
  tb <- c(bitwAnd(target, 0xFF), bitwAnd(bitwShiftR(target, 8L), 0xFF),
          bitwAnd(bitwShiftR(target, 16L), 0xFF), bitwAnd(bitwShiftR(target, 24L), 0xFF))
  m <- win - 3L
  hit <- which(v[1:m] == tb[1] & v[2:(m + 1L)] == tb[2] &
                 v[3:(m + 2L)] == tb[3] & v[4:(m + 3L)] == tb[4]) - 1L
  for (h in hit) if (ivt_f2_entry_valid(raw, h, n)) return(h)
  NULL
}

# Locate the page directory from the header pointer (falling back to a marker
# scan), then grow the maximal contiguous run of valid 8-byte records around the
# anchor. Returns NULL when no family-2 directory is present.
ivt_f2_find_directory <- function(raw) {
  n <- length(raw)
  anchor <- ivt_f2_dir_anchor_header(raw)
  if (is.null(anchor)) {
    anchor <- ivt_f2_dir_anchor_scan(raw)
    if (!is.null(anchor)) {
      ivt_fallback(paste(
        "The header page-directory pointer (@558) did not validate;",
        "the page directory was located by a marker scan instead."))
    }
  }
  if (is.null(anchor)) return(NULL)

  lo <- anchor
  while (lo - 8L >= 0L && ivt_f2_entry_valid(raw, lo - 8L, n)) lo <- lo - 8L
  hi <- anchor
  while (ivt_f2_entry_valid(raw, hi + 8L, n)) hi <- hi + 8L

  k <- 0:((hi - lo) %/% 8L)
  o <- lo + 8L * k
  offsets <- vapply(o, function(x) rd_u32(raw, x), numeric(1))
  list(lo = lo, hi = hi, offsets = offsets, n_pages = length(offsets))
}

# Geographies per page = geography member count / page count. Each contiguous
# page holds a fixed block of geographies; the block size is 4 for the 3-dimension
# reference tables and 2 for the 4-dimension 98-10-0129, so it must be computed,
# not assumed. Falls back to the historical default if the descriptor is absent.
ivt_f2_geos_per_page <- function(raw, dir = NULL) {
  if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
  if (is.null(dir) || dir$n_pages == 0L) return(IVT_F2_GEOS_PER_PAGE)
  gc <- ivt_f2_geo_count(raw)
  if (is.na(gc)) return(IVT_F2_GEOS_PER_PAGE)
  as.integer(round(gc / dir$n_pages))
}

# Number of geographies in a family-2 file. Prefer the header descriptor's
# geography member count (reliable for any dimensionality); fall back to
# page count * geos-per-page.
ivt_f2_geography_count <- function(raw, dir = NULL) {
  gc <- ivt_f2_geo_count(raw)
  if (!is.na(gc)) return(gc)
  if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
  if (is.null(dir)) return(0L)
  dir$n_pages * ivt_f2_geos_per_page(raw, dir)
}
