# wprobe-core.R -- read a `0xa` status array at ANY code width.
#
# The shipped decoder (R/status.R) stops at the validated `W = 2` vocabulary.
# These helpers deliberately go further so the wider codes can be MEASURED --
# they must never be wired into the package, only into the dev probes
# (dev/wprobe.R, dev/wcoord.R) that compare them against published tables.

# Codes at an arbitrary width: W bits MSB-first, NOT pair-swapped, at `bit`.
wp_codes <- function(blk, base, wid) {
  out <- integer(length(base))
  for (b in seq_len(wid))
    out <- out * 2L + as.integer(ivt_mask_bits(blk, base + b - 1L))
  out
}

# Read one page's status array at ANY width. Returns list(width, codes) or NULL.
wp_page <- function(raw, off, lay, size) {
  b0 <- as.integer(raw[off + 1L])
  if (bitwAnd(b0, 0xF0L) != 0xa0L) return(NULL)
  b2 <- as.integer(raw[off + 3L]); b3 <- as.integer(raw[off + 4L])
  w <- bitwAnd(b0, 0x0FL)
  if (!w %in% IVT_MARKER_WIDTHS) return(NULL)
  tr <- tryCatch(ivt_value_trailer(b0, b2, b3), error = function(e) NA_integer_)
  if (is.na(tr) || tr <= 0L) return(NULL)
  rb <- lay$rec_bytes
  nvf <- ivt_f2_record_popcount(raw, off + 4L, rb)
  ts <- 4L + rb + tr + nvf * w
  tl <- size - ts
  if (tl <= 0L || off + ts + tl > length(raw)) return(NULL)
  reg <- as.integer(raw[off + 4L + rb + seq_len(tr)])
  sel <- ivt_bits_pairswap_msb(reg, seq.int(0L, tr * 8L - 1L))
  if (sum(sel) * w != tl) return(NULL)
  wi <- which(sel) - 1L
  tail <- as.integer(raw[off + ts + seq_len(tl)])
  blk <- ivt_status_scatter(wi, tail, w, (max(wi) + 1L) * w)
  if (length(blk) < 8L) return(NULL)
  form <- blk[1L]; wid <- blk[3L]
  if (!form %in% c(1L, 2L) || blk[2L] != 0x02L) return(NULL)
  a0 <- if (form == 1L) 5L else 7L
  if (blk[a0 - 1L] != 0x01L || blk[a0] != wid) return(NULL)
  gb <- lay$grid$bit
  need <- (a0 * 8L + (max(gb) + 1L) * wid + 7L) %/% 8L
  if (need > tr * 8L * w) return(NULL)
  if (need > length(blk)) blk <- c(blk, integer(need - length(blk)))
  list(width = wid, form = form,
       codes = wp_codes(blk, a0 * 8L + gb * wid, wid),
       nvalues = nvf)
}

