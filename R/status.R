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
#' - `0xa` -> a self-describing status ARRAY carrying the reason codes
#'   themselves, decoded here at `W = 2`. Its header is
#'   `[form][02][W]` (+ a `[u16 count]` when `form == 02`) followed by a
#'   two-byte `[01][W]` array intro, so the code array starts at byte 5 (form
#'   01) or byte 7 (form 02). Codes are `W` bits wide, MSB-first and -- like the
#'   mask -- NOT pair-swapped, addressed at the SAME padded presence-grid bit as
#'   the presence record. The `W = 2` vocabulary is `0` value or genuine zero,
#'   `1` filler (a padded grid position that is no cell at all), `2` = `x`
#'   suppressed, `3` = `...` not available.
#'
#'   The three "incompatible packings" once recorded here (98-10-0655/0658 at
#'   the grid index, 98-10-0040 packing tighter, 98-10-0128 in per-member
#'   sub-blocks) were all the same thing read without the sparse rebuild: the
#'   dropped all-zero words shift everything after them. Rebuild the block first
#'   and one rule covers the corpus.
#'
#'   Four independent checks, all corpus-wide: the length gate below passes on
#'   1,273,173 / 1,273,173 `0xa` pages; a PRESENT cell carries code 0 on every
#'   decoded page; code 1 falls exactly on the grid positions the decoder drops
#'   as padding (10.6M cells, zero off-diagonal, and the padding set is computed
#'   from descriptor/slot geometry alone); and the code 2/3 counts equal
#'   StatCan's published `x` / `...` counts on 98-10-0655 (2,600), 98-10-0658
#'   (1,348), 98-10-0040 (10/49), 98-10-0128 (389,888/1,466,488), 98-10-0023
#'   (913,992), 98-10-0129 (1,485,120) and 98-10-0478 (6,853).
#'
#'   `W = 1`, `4` and `8` occur too; their vocabularies are NOT validated (`W =
#'   1` demonstrably differs -- its code 1 lands on real cells), so those pages
#'   are counted and reported, never interpreted.
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
#' holds on **1,810,626 of 1,810,626 mask pages and 1,273,173 of 1,273,173
#' status-array pages of the 170-table corpus, 0 unreadable** (first measured
#' standalone at 20,322 / 20,322 tail-bearing pages). A page that fails it is
#' reported `"unreadable"` and contributes nothing rather than a guess.
#'
#' Unlike the presence record the mask bytes are **not** pair-swapped; they are
#' read MSB-first and addressed at the same padded presence-grid bit as the
#' presence record itself (`lay$grid$bit`) -- decisively, over the alternative of
#' packing by real-cell ordinal.
#'
#' **A dropped word is a statement, not a gap.** All-zero words are not written,
#' so the mask can stop well short of the grid -- but the index that addresses
#' those words is sized by the marker, and on every one of the corpus's
#' 1,810,626 mask pages it can address every word the grid spans. An unwritten
#' word inside that span is therefore the file declaring the word all-zero, i.e.
#' every absent cell it covers is MISSING. Only a word the index has no bit for
#' is genuinely unclassifiable, and `covered_bits` reports exactly that boundary
#' (`min(index words, mask words)`), so the caller's `beyond` count is a real
#' gap rather than a restatement of sparsity. Confirmed semantically by
#' `dev/mvalidate.R`: on the tables that report missings, coordinates whose
#' absent cells are all masked reproduce their own dimension's total to within
#' random rounding, while coordinates with unmasked absent cells fall short by
#' an amount that grows with how many of them there are.
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

# The `W = 2` reason-code vocabulary of the `0xa` status array, in code order
# (code 0 is the array's own 0). Only code 2 and 3 are missing values; code 1 is
# a padded grid position that is no cell at all.
IVT_STATUS_VOCAB <- c("suppressed", "unavailable")   # codes 2 and 3
IVT_STATUS_FILLER <- 1L

# Read the status tail of one page. Returns a list with `kind`:
#
#   "none"       the page carries no status tail (dense page, unrecognised
#                marker, or no bytes past the value run)
#   "status"     a `0xa` self-describing reason-code array; `codes` holds one
#                code per padded grid position when the array is decodable (a
#                validated `W = 2` vocabulary), and is NULL otherwise
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
  bad <- list(kind = "unreadable", nan_words = 0L, extra_words = 0L)
  if (tr <= 0L) return(bad)

  # THE INDEX IS THE WHOLE PRE-VALUE REGION, not a prefix of it: bits past the
  # last written word are simply zero. (Sizing it `rec_bytes / (8 * width)` --
  # exactly the words a full mask needs -- truncates the index on every page
  # that also carries the second block, and the length invariant then failed on
  # 6 of the 106 tables of the ledger it was first measured on.)
  reg <- as.integer(raw[off + 4L + rb + seq_len(tr)])
  sel <- ivt_bits_pairswap_msb(reg, seq.int(0L, tr * 8L - 1L))
  if (sum(sel) * w != tl) return(bad)
  wi <- which(sel) - 1L                           # 0-based word indices, ascending
  tail <- as.integer(raw[off + ts + seq_len(tl)])
  if (hi == 0xa0L) return(ivt_status_array(wi, tail, w, tr, lay))
  nw <- rb %/% w                                  # words the mask itself spans
  inmask <- wi < nw

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

  buf <- ivt_status_scatter(wi, tail, w, rb)
  # How far the mask SPEAKS -- which is the index's reach, not the last word the
  # page happens to write. A dropped word inside the index's span is the file
  # saying "no genuine zeros here" (so every absent cell there is missing); only
  # a word the index has no bit for is a cell the file could not classify. The
  # two are opposite in meaning and only the second is a gap, so `covered_bits`
  # measures the second. Corpus-wide the index always reaches the whole grid
  # (1,810,626 / 1,810,626 mask pages), so nothing is ever past it.
  cov_bits <- min(tr * 8L, nw) * w * 8L
  list(kind = "mask", mask_bytes = buf, nan_words = as.integer(nanw),
       extra_words = sum(!inmask), covered_bits = cov_bits)
}

# Scatter the written words back to the byte positions their index bits name,
# into a buffer of `nbytes` bytes. Words addressed past the end are dropped --
# the caller counts them (the mask's second block) or sizes the buffer to hold
# them (the status array). An unwritten word stays zero, which is the file's own
# statement about it, not a gap.
ivt_status_scatter <- function(wi, tail, w, nbytes) {
  buf <- integer(nbytes)
  keep <- wi < nbytes %/% w
  if (any(keep)) {
    dst <- rep(wi[keep] * w, each = w) + seq_len(w)
    src <- rep((which(keep) - 1L) * w, each = w) + seq_len(w)
    buf[dst] <- tail[src]
  }
  buf
}

# Decode a `0xa` self-describing status array. `codes` comes back with one code
# per padded grid position (`lay$grid$bit` order) at the validated `W = 2`; at
# every other width -- and on any header this does not recognise -- the page is
# reported present-but-uninterpreted (`codes = NULL`) rather than guessed at.
ivt_status_array <- function(wi, tail, w, tr, lay) {
  out <- list(kind = "status", nan_words = 0L, extra_words = 0L, codes = NULL)
  blk <- ivt_status_scatter(wi, tail, w, (max(wi) + 1L) * w)
  if (length(blk) < 8L) return(out)
  form <- blk[1L]; wid <- blk[3L]
  if (!form %in% c(1L, 2L) || blk[2L] != 0x02L) return(out)
  a0 <- if (form == 1L) 5L else 7L                # 0-based start of the code array
  if (blk[a0 - 1L] != 0x01L || blk[a0] != wid) return(out)  # the `[01][W]` intro
  out$status_form <- form; out$status_width <- wid
  if (wid != 2L) return(out)                      # vocabulary unvalidated elsewhere
  gb <- lay$grid$bit
  need <- (a0 * 8L + (max(gb) + 1L) * wid + 7L) %/% 8L      # bytes the array spans
  # The index's reach is the epistemic boundary here exactly as it is for the
  # mask: an unwritten word INSIDE it is the file declaring those cells code 0,
  # a cell past it is one the file gave no bit to classify. Corpus-wide the
  # index always reaches the whole array.
  if (need > tr * 8L * w) return(out)
  if (need > length(blk)) blk <- c(blk, integer(need - length(blk)))
  base <- a0 * 8L + gb * wid
  out$codes <- as.integer(ivt_mask_bits(blk, base)) * 2L +
    as.integer(ivt_mask_bits(blk, base + 1L))
  out
}

# Read bit positions `bit` (0-based) of a reconstructed mask: MSB-first, and --
# unlike the presence record and every codebook bitmap -- NOT byte-pair-swapped.
ivt_mask_bits <- function(bytes, bit)
  bitwAnd(bitwShiftR(bytes[bit %/% 8L + 1L], 7L - (bit %% 8L)), 1L) == 1L
