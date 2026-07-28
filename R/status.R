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
#'   themselves. Its header is `[form][02][W]` (+ a `[u16 count]` when
#'   `form == 02`) followed by a two-byte `[01][W]` array intro, so the code
#'   array starts at byte 5 (form 01) or byte 7 (form 02). Codes are `W` bits
#'   wide, MSB-first and -- like the mask -- NOT pair-swapped, addressed at the
#'   SAME padded presence-grid bit as the presence record.
#'
#'   `W` is a STORAGE choice, not a dialect: it changes how many bits a code
#'   occupies, never what the code means.
#'
#'   What a code MEANS is **declared per file**, by the status legend at header
#'   slot 698 (`ivt_f2_status_legend()`): symbol plus bilingual wording, one
#'   record per code, in code order. There is no universal vocabulary: seven
#'   distinct legends over the 115 corpus tables that declare one. The NDM
#'   census tables number `..` / `X` / `...` as 1 / 2 / 3; the profile,
#'   `98-400-X` and 2021-custom lineage puts `-` (default missing value) first
#'   and shifts all three up by one; the Borealis survey lineage declares eight
#'   or nine codes including `0 s`, `®` and `z`; and the Borealis justice tables
#'   decline to distinguish, naming codes 2--8 `#2`..`#8`, all "Missing value".
#'   Code `0` is always a value or a genuine
#'   zero, and code `1` is always the file's own "nothing here": at a padded
#'   grid position it is filler, at a real cell it is whatever symbol the legend
#'   names it. Every corpus table that writes a `0xa` array declares a legend
#'   (47 / 47); `IVT_STATUS_VOCAB` survives only as a LOUD fallback for a file
#'   that does not.
#'
#'   The three "incompatible packings" once recorded here (98-10-0655/0658 at
#'   the grid index, 98-10-0040 packing tighter, 98-10-0128 in per-member
#'   sub-blocks) were all the same thing read without the sparse rebuild: the
#'   dropped all-zero words shift everything after them. Rebuild the block first
#'   and one rule covers the corpus.
#'
#'   The evidence, all corpus-wide unless noted. Structural: the length gate
#'   below passes on 1,273,173 / 1,273,173 `0xa` pages; a PRESENT cell carries
#'   code 0 at every width; code 1 covers the decoder's padding set exactly
#'   (166,965,381 cells, computed from descriptor/slot geometry alone) at every
#'   width, and lands on a real cell only 68,850 times; and two files
#'   (`ord-08035_ct1_2021`, `SP_U649IE_optab13`) mix `W = 2` and `W = 4` pages,
#'   so the width cannot be carrying meaning. Published: over ten NDM tables
#'   every symbol count matches the code count in BOTH directions -- `..` on
#'   98-10-0002 (612, all code 1, on `W = 1` and `W = 2` pages) and 98-10-0013
#'   (330), none on 98-10-0010 (0); `x` on 98-10-0023 (913,992), 98-10-0040
#'   (10), 98-10-0128 (389,888), 98-10-0129 (1,485,120), 98-10-0478 (6,853);
#'   `...` on 98-10-0655 (2,600), 98-10-0658 (1,348), 98-10-0040 (49),
#'   98-10-0128 (1,466,488), 98-10-0002 (735), 98-10-0013 (212). (`E` and `r`
#'   attach to cells that carry values, so they are not in this array at all.)
#'
#'   The formerly uninterpreted codes 4/5/7/8 -- 2,106,327 absent cells over 13
#'   tables whose published symbol counts are unobtainable (98-400-X2016203's
#'   viewer is retired; the Borealis deposits ship the `.ivt` alone) -- are read
#'   from those files' own legends and need no external truth at all. The same
#'   legends reproduce every one of the published counts above, which is what
#'   validates the per-file numbering rather than the other way round.
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

# The FALLBACK reason-code vocabulary of the `0xa` status array, used only where
# the file declares no legend of its own (`ivt_f2_status_legend()` below is the
# primary, metadata-driven path). It is the NDM census lineage's legend, the one
# validated cell-exact in both directions against ten published tables; it is
# NOT universal -- the 2016 `98-400-X` and Borealis survey lineages number the
# same symbols differently -- so supplying it is a loud fallback.
#
# Code 0, absent from this table, is a value or a genuine zero. Code 1 is
# "nothing here", and which nothing depends on the GRID, not on the code: at a
# padded grid position -- one the layout says is no cell at all -- it is filler,
# and at a real cell it is the legend's first symbol. The caller separates the
# two with the padding set it already computes from the descriptor and slot
# geometry.
IVT_STATUS_VOCAB <- c(                               # codes 1, 2, 3
  "not available",                                   # `..`
  "suppressed",                                      # `x`
  "not applicable")                                  # `...`
IVT_STATUS_SYMBOLS <- c("..", "x", "...")

# Codes a `W = 8` array can express -- the size of the caller's code tally, not
# a claim that any code up to 255 occurs (the corpus tops out at 9).
IVT_STATUS_NCODE <- 256L

# The header slot addressing the status legend's 8-byte entry array. Slot 712
# (`ivt_f2_dqf_legend()`) is a DIFFERENT legend -- the per-cell data-quality
# flags A-E / R / P -- laid out the same way.
IVT_HDR_STATUS_LEGEND <- 698L

# The file's OWN statement of what its `0xa` reason codes mean.
#
# Header slot `@698` points at an 8-byte entry array `[u32 off][u16 len][u16
# len]`, exactly like a block directory. Entry 0 is the code INDEX array,
# `[04 02][u16 n_codes][u16 per_code]` followed by `n_codes * per_code` u32
# entry indices: `per_code` records per code, English first, French (where
# stored) second. Code `k` is therefore whatever record index
# `(k - 1) * per_code + 1` names -- the numbering is the file's, not a constant,
# which is why the same symbol sits at code 2 in one lineage and code 3 in the
# next.
#
# Each record is `[82 01 | 02 01][u16][flag bytes][u8 sym_len incl NUL][symbol]
# [00][u16 text_len][text]`, latin-1. The flag run is 1, 5 or 7 bytes long
# depending on the vintage, so the symbol is found structurally rather than at a
# fixed offset: the first position that carries a plausible length byte, closes
# its symbol with the NUL the length promises, holds printable bytes either
# side, and declares a text that FITS the record. A record may carry a second
# string after the first (the survey lineage appends its default-missing-value
# wording), so the text is bounded by the record, not required to fill it.
#
# Returns a tibble with `code` / `symbol` / `text_en` / `text_fr`, or NULL where
# the slot addresses no index array (the pre-legend generations write 0 there).
ivt_f2_status_legend <- function(raw) {
  n <- length(raw)
  base <- rd_u32(raw, IVT_HDR_STATUS_LEGEND)
  if (is.na(base) || base < 1024 || base + 8 > n) return(NULL)
  ent <- function(k) {
    if (k < 0 || base + k * 8 + 6 > n) return(NULL)
    o <- rd_u32(raw, base + k * 8L); l <- rd_u16(raw, base + k * 8L + 4L)
    if (is.na(o) || is.na(l) || l < 6L || o < 0 || o + l > n) return(NULL)
    list(off = o, len = l, v = as.integer(raw[(o + 1L):(o + l)]))
  }
  ix <- ent(0L)
  if (is.null(ix) || ix$v[1] != 0x04L || ix$v[2] != 0x02L) return(NULL)
  nc <- ix$v[3] + 256L * ix$v[4]
  per <- ix$v[5] + 256L * ix$v[6]
  if (nc < 1L || nc > 64L || per < 1L || per > 4L) return(NULL)
  u <- ix$v[-(1:6)]
  if (length(u) != 4L * per * nc) return(NULL)      # length gate: the whole array
  idx <- vapply(seq_len(per * nc), function(i)
    sum(u[(4L * i - 3L):(4L * i)] * c(1, 256, 65536, 16777216)), 0)

  # One legend record -> symbol + text, or NULL.
  rec <- function(k) {
    e <- ent(k)
    if (is.null(e)) return(NULL)
    w <- e$v; ll <- e$len
    if (!(w[1] == 0x82L || w[1] == 0x02L) || w[2] != 0x01L) return(NULL)
    for (i in 5:min(32L, ll - 3L)) {
      sl <- w[i]
      if (is.na(sl) || sl < 1L || sl > 16L || i + sl + 3L > ll) next
      if (w[i + sl] != 0x00L) next                   # the promised terminator
      if (sl > 1L && any(w[(i + 1L):(i + sl - 1L)] < 0x20L)) next   # printable
      tl <- w[i + sl + 1L] + 256L * w[i + sl + 2L]
      if (is.na(tl) || tl < 1L) next
      # the text must FIT the record (a dropped trailing NUL leaves it one short,
      # and a second appended string leaves room to spare)
      if (i + sl + 2L + tl > ll + 1L) next
      if (w[i + sl + 3L] < 0x20L) next               # text starts printable
      sym <- if (sl > 1L) raw[(e$off + i + 1L):(e$off + i + sl - 1L)] else raw(0)
      txt <- raw[(e$off + i + sl + 3L):(e$off + min(i + sl + 2L + tl, ll))]
      txt <- txt[txt != as.raw(0L)]
      return(list(sym = raw_to_latin1(sym), txt = raw_to_latin1(txt)))
    }
    NULL
  }
  recs <- lapply(idx, rec)
  pick <- function(k, j) {
    if (j > per) return(NA_character_)
    r <- recs[[per * (k - 1L) + j]]
    if (is.null(r)) NA_character_ else r$txt
  }
  sym <- vapply(seq_len(nc), function(k) {
    r <- recs[[per * (k - 1L) + 1L]]
    if (is.null(r)) NA_character_ else r$sym
  }, "")
  out <- tibble::tibble(
    code    = seq_len(nc),
    symbol  = sym,
    text_en = vapply(seq_len(nc), pick, "", 1L),
    text_fr = vapply(seq_len(nc), pick, "", 2L))
  if (all(is.na(out$text_en))) return(NULL)
  out
}

# Read the status tail of one page. Returns a list with `kind`:
#
#   "none"       the page carries no status tail (dense page, unrecognised
#                marker, or no bytes past the value run)
#   "status"     a `0xa` self-describing reason-code array; `codes` holds one
#                code per padded grid position when the header parses, and is
#                NULL otherwise
#   "unreadable" a tail is present but the index does not account for it
#   "mask"       decoded; `mask_bytes` holds the reconstructed 1-bit absent mask
#
# plus `nan_words` (mask words whose bytes are NaN-shaped, so one status bit may
# have been destroyed by the writer) and `extra_words` (index bits addressing
# words past the mask -- the undecoded second block).
ivt_page_status <- function(raw, off, lay, size = NA_integer_, nvf = NULL) {
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
  # The value decode needs the same popcount; the caller passes it in so the
  # record is counted once per page rather than once per reader.
  if (is.null(nvf)) nvf <- ivt_f2_record_popcount(raw, off + 4L, rb)
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
  sel <- ivt_bits_pairswap_all(reg)
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
#
# A word is `w` bytes and the destinations are word-aligned, so the scatter is a
# column assignment on a `w`-row matrix rather than two index vectors as long as
# the written region.
ivt_status_scatter <- function(wi, tail, w, nbytes) {
  nw <- nbytes %/% w
  keep <- wi < nw
  buf <- matrix(0L, w, nw)
  if (any(keep))
    buf[, wi[keep] + 1L] <- matrix(tail, nrow = w)[, keep, drop = FALSE]
  c(as.vector(buf), integer(nbytes - nw * w))
}

# Decode a `0xa` self-describing status array. `codes` comes back with one code
# per padded grid position (`lay$grid$bit` order) at EVERY declared width; on a
# header this does not recognise the page is reported present-but-unread
# (`codes = NULL`) rather than guessed at. Interpreting the codes is the
# caller's job -- `IVT_STATUS_VOCAB` covers 1..3, and anything above that is
# counted and reported, never translated.
ivt_status_array <- function(wi, tail, w, tr, lay) {
  out <- list(kind = "status", nan_words = 0L, extra_words = 0L, codes = NULL)
  blk <- ivt_status_scatter(wi, tail, w, (max(wi) + 1L) * w)
  if (length(blk) < 8L) return(out)
  form <- blk[1L]; wid <- blk[3L]
  if (!form %in% c(1L, 2L) || blk[2L] != 0x02L) return(out)
  a0 <- if (form == 1L) 5L else 7L                # 0-based start of the code array
  if (blk[a0 - 1L] != 0x01L || blk[a0] != wid) return(out)  # the `[01][W]` intro
  if (!wid %in% IVT_STATUS_WIDTHS) return(out)
  out$status_form <- form; out$status_width <- wid
  gb <- lay$grid$bit
  need <- (a0 * 8L + (max(gb) + 1L) * wid + 7L) %/% 8L      # bytes the array spans
  # The index's reach is the epistemic boundary here exactly as it is for the
  # mask: an unwritten word INSIDE it is the file declaring those cells code 0,
  # a cell past it is one the file gave no bit to classify. Corpus-wide the
  # index always reaches the whole array.
  if (need > tr * 8L * w) return(out)
  if (need > length(blk)) blk <- c(blk, integer(need - length(blk)))
  ca <- lay$grid$code                             # precomputed for the whole table
  if (is.null(ca)) ca <- ivt_status_code_addr(gb)
  ca <- ca[[as.character(wid)]]
  out$codes <- bitwAnd(bitwShiftR(blk[a0 + ca$byte + 1L], ca$sh), ca$mask)
  out
}

# Code widths the array declares. A page uses the narrowest that holds its
# largest code, so the width is a STORAGE choice and carries no meaning of its
# own -- one file mixes several.
IVT_STATUS_WIDTHS <- c(1L, 2L, 4L, 8L)

# Read bit positions `bit` (0-based, or a cell grid) of a reconstructed mask:
# MSB-first, and -- unlike the presence record and every codebook bitmap -- NOT
# byte-pair-swapped.
ivt_mask_bits <- function(bytes, bit) {
  a <- ivt_bit_addr(bit)
  bitwAnd(bitwShiftR(bytes[a$bidx], a$bsh), 1L) == 1L
}

# Where each grid cell's status code sits, at each declared width: the byte it
# starts in (0-based, from the array's own start) and the shift and mask that
# lift it out. Every width divides 8 and the array starts byte-aligned, so a
# code never straddles a byte -- one shift and one mask reads it, instead of one
# bit read per bit of the width. A function of the grid bits alone, so the
# layout carries the whole table (`ivt_layout()`) and no page recomputes it.
ivt_status_code_addr <- function(bit) {
  out <- lapply(IVT_STATUS_WIDTHS, function(w) {
    b <- bit * w
    list(byte = b %/% 8L, sh = 8L - w - b %% 8L, mask = bitwShiftL(1L, w) - 1L)
  })
  names(out) <- as.character(IVT_STATUS_WIDTHS)
  out
}
