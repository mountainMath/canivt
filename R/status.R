#' The page cell-status tail: which absent cells are ZEROS and which are MISSING
#'
#' The value store keeps only non-zero cells, so an absent cell was long read as
#' a published zero. That is **false**: absence splits into genuine zeros and
#' true missings (`x` suppressed, `...`/`N` not available), and the file says
#' which is which in a block appended to the page AFTER the dense value run.
#'
#' Two forms, selected by the page marker's `b0` HIGH nibble:
#'
#' - `0x8` -> a bare **1-bit absent mask**, decoded here. It is a strict SUBSET
#'   of the absent cells: a masked absent cell is a genuine zero, an UNMASKED
#'   absent cell is MISSING. Where a table publishes no missings the two sets
#'   coincide and the mask looks like the presence complement, which is why it
#'   read as redundant for so long. Proven against the Beyond 20/20 viewer on
#'   97F0020XCB2001070 (gap exactly 4 on all 104 pages of geographies 1-13, where
#'   the viewer prints 2 `N` per earning member, and exactly 0 on all 8 pages of
#'   Nunavut, which publishes `0` at the same coordinates), and confirmed from
#'   the other side by the CMHC crosstabs (0 unflagged absent cells; their B20/20
#'   CSV exports publish no missings at all).
#' - `0xa` -> a self-describing `[form][02][W]` status array carrying the reason
#'   codes themselves (`W = 2`: 0 value/genuine zero, 1 filler, 2 = `x`, 3 =
#'   `...`). Its VOCABULARY is validated cell-exact against StatCan's published
#'   tables, but its ADDRESSING is not general (98-10-0655/0658 index at the
#'   padded presence-grid cell index, 98-10-0040 packs tighter, 98-10-0128 uses
#'   per-member sub-blocks), so it is NOT decoded -- reported as `"status"` and
#'   counted, never guessed at. See `inst/notes/ivt-format.md`.
#'
#' **The tail is a sparse array of `width`-byte words, addressed by an index
#' bitmap that occupies the WHOLE pre-value region.** That region is the `b2`
#' trailer plus the `32 * (b3 - 8)` head (`ivt_value_trailer()`) -- `b3` is in
#' effect an index-size code, since a page needs a bigger index exactly when it
#' has more words to address. The bitmap is read in the container's usual
#' convention (byte-pair-swapped, MSB-first) with one bit per word of the
#' reconstructed block; all-zero words are simply not written, and the trailing
#' bytes of the index are zero when fewer words are needed. Writing the selected
#' words back to their indexed positions rebuilds the block.
#'
#' The length invariant `popcount(index) * width == tail length` is the gate: it
#' holds on **1,810,627 of 1,810,627 mask pages of the 171-table corpus, 0
#' unreadable** (first measured standalone at 20,322 / 20,322 tail-bearing
#' pages). A page that fails it is reported `"unreadable"` and contributes
#' nothing rather than a guess.
#'
#' Unlike the presence record the mask bytes are **not** pair-swapped; they are
#' read MSB-first and addressed at the same padded presence-grid bit as the
#' presence record itself (`lay$grid$bit`) -- decisively, over the alternative of
#' packing by real-cell ordinal.
#'
#' Two known limits, both reported by the caller rather than hidden:
#'
#' - **The x87 signalling-NaN artefact.** On float64 (`width = 8`) pages a mask
#'   word of mostly-ones is NaN-shaped, and the writer's x87 load/store quiets it
#'   by forcing the top mantissa bit (LSB bit 51) to 1 -- destroying one status
#'   bit per affected word IN THE SOURCE FILE. It is not recoverable: the
#'   affected cell reads as masked (genuine zero) when it may have been missing.
#'   Measured over the float64/int32 tables of the corpus: 0 signalling NaNs
#'   survive in 63,582 `width = 8` mask words, against 374 of 94,893 (5.9% of
#'   the NaN-shaped ones) on `width = 4`, where no such quieting applies.
#'   Counted as `nan_words`.
#' - **A second, undecoded block.** On 8 corpus tables some `b3 == 0x0c` pages
#'   address words PAST the mask's `rec_bytes`, i.e. the same index also
#'   addresses a further array. Its content is packed flag words (`0x3333`,
#'   `0x1111`, `0x33FF`, all-ones -- nibbles confined to {0,1,3,7,b,f}, written
#'   as numbers in the page's own value type), but it is not a per-cell code
#'   array under any tested encoding, and its size correlates with no per-cell
#'   quantity. Counted as `extra_words` and reported loudly; see
#'   `inst/notes/ivt-format.md`, "The second tail block".
#'
#' @keywords internal
#' @noRd
NULL

# Read the status tail of one page. Returns a list with `kind`:
#
#   "none"       the page carries no status tail (dense page, unrecognised
#                marker, or no bytes past the value run)
#   "status"     a `0xa` self-describing reason-code array -- present but not
#                decoded (addressing not general)
#   "unreadable" a tail is present but the index does not account for it
#   "mask"       decoded; `mask_bytes` holds the reconstructed 1-bit absent mask
#
# plus `nan_words` (mask words whose bytes are NaN-shaped, so one status bit may
# have been destroyed by the writer) and `extra_words` (index bits addressing
# words past the mask -- the undecoded second block).
ivt_page_status <- function(raw, off, lay, size = NA_integer_) {
  none <- list(kind = "none", nan_words = 0L, extra_words = 0L)
  n <- length(raw)
  b0 <- as.integer(raw[off + 1L])
  if (b0 < 0x80L) return(none)                    # dense variant: no tail at all
  b2 <- as.integer(raw[off + 3L]); b3 <- as.integer(raw[off + 4L])
  w <- bitwAnd(b0, 0x0FL); hi <- bitwAnd(b0, 0xF0L)
  if (!w %in% IVT_MARKER_WIDTHS) return(none)
  tr <- tryCatch(ivt_value_trailer(b0, b2, b3), error = function(e) NA_integer_)
  if (is.na(tr)) return(none)
  rb <- lay$rec_bytes
  nvf <- ivt_f2_record_popcount(raw, off + 4L, rb)
  ts <- 4L + rb + tr + nvf * w                    # first byte past the value run
  if (is.na(size)) return(none)
  tl <- size - ts
  # `tl > 0` is required, not merely tolerated: a lineage that writes no tail at
  # all would otherwise read as "every absent cell is missing".
  if (tl <= 0L || off + ts + tl > n) return(none)
  if (hi == 0xa0L) return(list(kind = "status", nan_words = 0L, extra_words = 0L))
  if (tr <= 0L) return(list(kind = "unreadable", nan_words = 0L, extra_words = 0L))

  # THE INDEX IS THE WHOLE PRE-VALUE REGION, not a prefix of it: bits past the
  # last written word are simply zero. (Sizing it `rec_bytes / (8 * width)` --
  # exactly the words a full mask needs -- truncates the index on every page
  # that also carries the second block, and the length invariant then failed on
  # 6 of the 106 tables of the ledger it was first measured on.)
  reg <- as.integer(raw[off + 4L + rb + seq_len(tr)])
  sel <- ivt_bits_pairswap_msb(reg, seq.int(0L, tr * 8L - 1L))
  if (sum(sel) * w != tl)
    return(list(kind = "unreadable", nan_words = 0L, extra_words = 0L))
  wi <- which(sel) - 1L                           # 0-based word indices, ascending
  nw <- rb %/% w                                  # words the mask itself spans
  inmask <- wi < nw
  tail <- as.integer(raw[off + ts + seq_len(tl)])

  # Words whose bytes are NaN-shaped in the page's value type: the writer may
  # have quieted them, destroying the top mantissa bit. Counted over the MASK
  # words only (the second block is reported separately).
  nanw <- 0L
  if (any(inmask) && w %in% c(4L, 8L)) {
    m <- matrix(tail, nrow = w)[, inmask, drop = FALSE]
    nanw <- if (w == 8L)
      sum(bitwAnd(m[8L, ], 0x7FL) == 0x7FL & bitwAnd(m[7L, ], 0xF0L) == 0xF0L)
    else
      sum(bitwAnd(m[4L, ], 0x7FL) == 0x7FL & bitwAnd(m[3L, ], 0x80L) == 0x80L)
  }

  buf <- integer(rb)
  if (any(inmask)) {
    dst <- rep(wi[inmask] * w, each = w) + seq_len(w)
    src <- rep((which(inmask) - 1L) * w, each = w) + seq_len(w)
    buf[dst] <- tail[src]
  }
  # The last mask word the page actually WRITES. All-zero words are dropped by
  # the sparse index, so the mask can stop well short of the grid -- and every
  # cell past that point is "unmasked" for want of a word rather than because the
  # file called it missing. Legitimate where the trailing cells really are all
  # missing (nothing to flag as a zero), but it is also the shape a truncated
  # mask would take, and the two are indistinguishable from the bytes. The
  # caller counts how many reported missings fall past this bit and says so.
  last_bit <- if (any(inmask)) (max(wi[inmask]) + 1L) * w * 8L else 0L
  list(kind = "mask", mask_bytes = buf, nan_words = as.integer(nanw),
       extra_words = sum(!inmask), covered_bits = last_bit)
}

# Read bit positions `bit` (0-based) of a reconstructed mask: MSB-first, and --
# unlike the presence record and every codebook bitmap -- NOT byte-pair-swapped.
ivt_mask_bits <- function(bytes, bit)
  bitwAnd(bitwShiftR(bytes[bit %/% 8L + 1L], 7L - (bit %% 8L)), 1L) == 1L
