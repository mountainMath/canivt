#' IVT presence bitmap helpers (power-of-two nested layout)
#'
#' Shared primitives for the unified cell decoder (`decode.R`). A page's presence
#' section is a **power-of-two-nested positional bitmap** over the in-page
#' dimensions: each level is padded to the next power of two of (its member count
#' x the inner block size), the innermost dimension occupies the low bits, the
#' record is stored **byte-pair-swapped** (adjacent byte pairs swapped) and read
#' **MSB-first**. The dense value run walks the present cells in the same order
#' (descriptor order, innermost dimension fastest).
#'
#' These were first written for the family-2 container (hence the `ivt_f2_`
#' prefix) but are container-agnostic -- `ivt_layout()` uses them for the in-page
#' bitmap of every table, whichever dimension straddles the page boundary.
#'
#' @keywords internal
#' @noRd
NULL

# Next power of two >= x (x >= 1).
ivt_f2_nextpow2 <- function(x) as.integer(2^ceiling(log2(pmax(as.numeric(x), 1))))

# Power-of-two nested bit layout for the in-page dimensions (member `counts` in
# descriptor order, outermost first). Returns the per-dimension `stride` (bits
# advanced per unit increment of that dimension's index) and the whole record
# size `rec_bytes`.
ivt_f2_bit_layout <- function(counts) {
  k <- length(counts)
  if (k == 0L) return(list(stride = integer(0), rec_bytes = 0L))
  block <- integer(k)
  block[k] <- ivt_f2_nextpow2(counts[k])
  if (k > 1L) for (i in (k - 1L):1L) block[i] <- ivt_f2_nextpow2(counts[i] * block[i + 1L])
  stride <- integer(k); stride[k] <- 1L
  if (k > 1L) for (i in seq_len(k - 1L)) stride[i] <- block[i + 1L]
  list(stride = stride, rec_bytes = block[1L] %/% 8L)
}

# Enumerate every cell (the cartesian product of the in-page dimensions) in dense
# value order -- descriptor order, innermost dimension varying fastest -- and
# precompute each cell's bit index in the presence record. Returns the 1-based
# `tuples` matrix (one column per in-page dimension) and the integer `bit` vector.
#
# `pos` (optional): per-dimension 0-based SLOT positions, for dimensions whose
# members do not occupy contiguous bitmap slots. The survey generations address
# the presence bitmap by member SLOT, and a slot table can carry deleted holes
# (tb611996's reference periods sit at slots {0,1,3} -- slot 2 is a deleted
# member): tuples stay 1..count member ids, but each member's BIT comes from its
# slot position. NULL entries (or a NULL `pos`) mean the dense 0..count-1 default.
ivt_f2_cell_grid <- function(counts, stride, pos = NULL) {
  k <- length(counts); N <- prod(counts)
  tuples <- matrix(0L, N, k); bits <- matrix(0L, N, k); rin <- 1L
  for (i in k:1L) {
    idx <- rep(rep.int(0:(counts[i] - 1L), rep.int(rin, counts[i])), length.out = N)
    tuples[, i] <- idx
    p <- if (!is.null(pos) && length(pos) >= i && !is.null(pos[[i]])) pos[[i]]
         else 0:(counts[i] - 1L)
    bits[, i] <- p[idx + 1L]
    rin <- rin * counts[i]
  }
  list(tuples = tuples + 1L, bit = as.integer(bits %*% stride))
}

# Read bit positions `bit` (0-based) from a byte-pair-swapped, MSB-first
# bitstream (`bytes` as an integer vector of even length). THE bitmap
# convention of the container -- shared by the page presence records and the
# codebook member bitmaps (`ivt_f2_footnote_bitmap()`). Returns a logical
# vector aligned with `bit` (TRUE = bit set).
ivt_bits_pairswap_msb <- function(bytes, bit) {
  ev <- seq.int(1L, length(bytes), 2L); od <- ev + 1L
  sw <- bytes; sw[ev] <- bytes[od]; sw[od] <- bytes[ev]
  bitwAnd(bitwShiftR(sw[bit %/% 8L + 1L], 7L - (bit %% 8L)), 1L) == 1L
}

# Decode the presence of a single `rec_bytes`-byte record at 0-based offset `ps`:
# byte-pair-swap the record, then read each precomputed cell `bit` MSB-first.
# Returns a logical vector aligned with the cell grid (TRUE = cell present).
ivt_f2_record_present <- function(raw, ps, rec_bytes, bit)
  ivt_bits_pairswap_msb(as.integer(raw[(ps + 1L):(ps + rec_bytes)]), bit)
