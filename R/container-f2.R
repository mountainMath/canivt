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

# Per-page parameters keyed by the marker's first byte: where the dense value run
# starts (offset from the page) and how each value is stored. The marker low
# nibble is the value-width code (0x8 -> 8-byte float64, 0x4 -> int32, 0x2 ->
# int16); the value run follows the 256-byte presence section and a
# marker-specific 0xFF trailer. The `vstart` values were established empirically
# and validated cell-exact against the StatCan CSV for every page type present.
#   0x88 -> float64 @ off+264 (4-byte trailer)
#   0xa8 -> float64 @ off+270 (10-byte trailer)
#   0xa2 -> int16   @ off+294 (34-byte trailer)
IVT_F2_PAGE_PARAMS <- list(
  # 2021-era float64 / int16 pages (98-10-0023)
  `136` = list(vstart = 264L, width = 8L, float = TRUE),    # 0x88
  `168` = list(vstart = 270L, width = 8L, float = TRUE),    # 0xa8
  `162` = list(vstart = 294L, width = 2L, float = FALSE),   # 0xa2
  # 1991-era int32 / int16 pages (1003011)
  `132` = list(vstart = 268L, width = 4L, float = FALSE),   # 0x84
  `130` = list(vstart = 276L, width = 2L, float = FALSE)    # 0x82
)

# Resolve a page's value parameters from its marker's first byte. Unknown markers
# fall back to a plain float64 page (off+264) with the width implied by the low
# nibble, and a warning, so a new variant degrades loudly rather than silently.
ivt_f2_page_params <- function(marker0) {
  p <- IVT_F2_PAGE_PARAMS[[as.character(marker0)]]
  if (!is.null(p)) return(p)
  w <- bitwAnd(marker0, 0x0FL)
  cli::cli_warn("Unrecognised family-2 page marker byte {.val {sprintf('0x%02x', marker0)}}; assuming plain layout.")
  list(vstart = 264L, width = if (w %in% c(2L, 4L, 8L)) w else 8L, float = w == 8L)
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

# Number of geographies in a family-2 file (page count * geos-per-page).
ivt_f2_geography_count <- function(raw, dir = NULL) {
  if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
  if (is.null(dir)) return(0L)
  dir$n_pages * IVT_F2_GEOS_PER_PAGE
}
