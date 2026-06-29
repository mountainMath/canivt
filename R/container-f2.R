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

# Default geos-per-page / presence-record size for the original 3-dimension
# reference tables (98-10-0023, 1003011: 4 geos/page, 64-byte records). Both are
# now *computed* per file from the header descriptor (`ivt_f2_geos_per_page()`,
# `ivt_f2_rec_bytes()`) so arbitrary-dimension tables decode; these remain only as
# fallbacks when the descriptor is unavailable.
IVT_F2_GEOS_PER_PAGE <- 4L
IVT_F2_REC_BYTES     <- 64L                  # one presence record per geography
IVT_F2_PRESENCE_LEN  <- IVT_F2_GEOS_PER_PAGE * IVT_F2_REC_BYTES  # 256

# A family-2 page marker is `[b0] 01 [b2] [b3]` where b0's high nibble is 0x8 or
# 0xa (the plain vs 0xFF-run variants, as in family 1) and its low nibble is the
# value-width code (2/4/8). Markers seen in 98-10-0023: 88 01 20 08, a8 01 41 08,
# a2 01 03 09.
ivt_f2_marker_b0 <- c(0x82L, 0x84L, 0x88L, 0xa2L, 0xa4L, 0xa8L)
ivt_f2_marker_b3 <- c(0x08L, 0x09L)
ivt_f2_is_marker_byte0 <- function(b) b %in% ivt_f2_marker_b0

# Whole-marker test at a 0-based page offset.
ivt_f2_is_marker <- function(raw, off) {
  as.integer(raw[off + 1L]) %in% ivt_f2_marker_b0 &&
    as.integer(raw[off + 2L]) == 0x01L &&
    as.integer(raw[off + 4L]) %in% ivt_f2_marker_b3
}

# Per-page value parameters. The dense value run starts at
#   vstart = 4 (marker) + presence_len + trailer
# where `presence_len = rec_bytes * geos_per_page` and `trailer` is a short pad/
# 0xFF run whose length depends only on the marker's first byte. Storing the
# trailer (rather than an absolute vstart) makes the offset independent of the
# table's dimensionality: it reproduces the validated absolute starts for the
# 256-byte presence section of the 3-dimension tables, and generalises to the
# n-dimension tables (e.g. 98-10-0129, presence_len = 128*2 = 256) automatically.
# The marker low nibble is the value-width code (0x8 -> 8-byte float64, 0x4 ->
# int32, 0x2 -> int16); the high nibble (0x8 vs 0xa) only changes the trailer
# length. Validated cell-exact against the StatCan CSV for every page type:
#   0x88 -> float64, trailer 4  (-> off+264 at presence_len 256)
#   0xa8 -> float64, trailer 10 (-> off+270)
#   0xa2 -> int16,   trailer 34 (-> off+294)   (98-10-0129)
#   0xa4 -> int32,   trailer 18 (-> off+278)   (98-10-0129)
#   0x84 -> int32,   trailer 8  (-> off+268)
#   0x82 -> int16,   trailer 16 (-> off+276)
IVT_F2_PAGE_TRAILER <- c(
  `136` = 4L,   # 0x88 float64
  `168` = 10L,  # 0xa8 float64
  `162` = 34L,  # 0xa2 int16
  `164` = 18L,  # 0xa4 int32
  `132` = 8L,   # 0x84 int32
  `130` = 16L   # 0x82 int16
)

# Resolve a page's value parameters from its marker's first byte and the page's
# presence-section length. Unknown markers fall back to a minimal (4-byte) trailer
# with the width implied by the low nibble, and a warning, so a new variant
# degrades loudly rather than silently.
ivt_f2_page_params <- function(marker0, presence_len = IVT_F2_PRESENCE_LEN) {
  w  <- bitwAnd(marker0, 0x0FL)
  tr <- IVT_F2_PAGE_TRAILER[[as.character(marker0)]]
  if (is.null(tr)) {
    cli::cli_warn("Unrecognised family-2 page marker byte {.val {sprintf('0x%02x', marker0)}}; assuming plain layout.")
    tr <- 4L
    if (!w %in% c(2L, 4L, 8L)) w <- 8L
  }
  list(vstart = 4L + presence_len + tr,
       width  = if (w %in% c(2L, 4L, 8L)) w else 8L,
       float  = w == 8L,
       trailer = tr)
}

# A directory record is valid when both size fields agree, the size is positive,
# and the offset points at a page marker inside the data region.
ivt_f2_entry_valid <- function(raw, o, n) {
  if (o + 8L > n) return(FALSE)
  s1 <- rd_u16(raw, o + 4L)
  s2 <- rd_u16(raw, o + 6L)
  if (s1 != s2 || s1 <= 0L) return(FALSE)
  off <- rd_u32(raw, o)                      # u32 at o
  if (off < 1e5 || off + 4 > n) return(FALSE)
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
  if (is.null(anchor)) anchor <- ivt_f2_dir_anchor_scan(raw)
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
