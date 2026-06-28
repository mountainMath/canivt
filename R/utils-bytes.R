#' Low-level byte helpers for reading IVT files
#'
#' IVT files store integers as little-endian and frequently start value runs on
#' odd (unaligned) byte offsets. All offsets in this package are 0-based to match
#' the binary layout; the helpers convert to R's 1-based raw indexing internally.
#'
#' @keywords internal
#' @noRd
NULL

# Read one little-endian unsigned 16-bit integer at 0-based offset `off`.
rd_u16 <- function(raw, off) {
  as.integer(raw[off + 1L]) + as.integer(raw[off + 2L]) * 256L
}

# Read one little-endian unsigned 32-bit integer at 0-based offset `off`.
# Returned as a double so values above .Machine$integer.max are exact.
rd_u32 <- function(raw, off) {
  b <- as.numeric(raw[off + 1:4])
  b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
}

# Read `n` little-endian signed integers of `size` bytes (2 or 4) from a
# contiguous byte range starting at 0-based offset `off`. Vectorised.
rd_int_run <- function(raw, off, n, size) {
  if (n == 0L) return(integer(0))
  chunk <- raw[(off + 1L):(off + n * size)]
  readBin(chunk, what = integer(), n = n, size = size,
          signed = TRUE, endian = "little")
}

# Read a length-prefixed ("Pascal") string at 0-based `off`: one length byte
# followed by that many latin-1 text bytes. Returns NULL if it is not a
# plausible label (bad length or non-text bytes).
rd_pascal <- function(raw, off, max_len = 250L) {
  if (off + 1L > length(raw)) return(NULL)
  len <- as.integer(raw[off + 1L])
  if (len < 1L || len > max_len) return(NULL)
  if (off + 1L + len > length(raw)) return(NULL)
  bytes <- raw[(off + 2L):(off + 1L + len)]
  if (!all(is_label_byte(bytes))) return(NULL)
  list(text = raw_to_latin1(bytes), len = len, end = off + 1L + len)
}

# Bytes allowed inside a member label: printable ASCII, common whitespace, and
# latin-1 accented characters (French place names).
is_label_byte <- function(bytes) {
  v <- as.integer(bytes)
  (v >= 32L & v < 127L) | v %in% c(9L, 10L, 13L) | (v >= 160L & v <= 255L)
}

raw_to_latin1 <- function(bytes) {
  bytes <- as.raw(bytes)
  bytes[bytes == as.raw(0L)] <- as.raw(0x20)  # NUL -> space (rawToChar rejects NUL)
  s <- rawToChar(bytes)
  Encoding(s) <- "latin1"
  enc2utf8(s)
}
