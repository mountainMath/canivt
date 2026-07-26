# Marker-catalog harness (inst/notes/markers.md).
#
# Two jobs:
#   1. `IVT_MARKER_SET` -- the documented byte SETS, mirrored from markers.md.
#      test-markers.R asserts these equal the code constants, so the catalog and
#      the implementation cannot drift apart.
#   2. `ivt_marker_observe()` -- the per-file marker inventory. The opt-in corpus
#      sweep runs it over every ledger table and asserts every observed marker is
#      in `IVT_MARKER_SET`; a newly-imported vintage that uses an un-catalogued
#      marker fails LOUDLY (the whole point -- it flags the marker for us to
#      decode and document). It never asserts on anything it did not clearly
#      observe, so it cannot false-fail.

# The documented byte sets (§C/§D/§E/§F/§A of markers.md).
IVT_MARKER_SET <- list(
  # byte 0 is a container-generation tag (0x04 modern census/custom, 0x02 the
  # older split-definition survey products); the trailing three bytes are shared.
  file_sig_b0       = c(0x02L, 0x04L),
  file_sig_tail     = c(0x00L, 0x20L, 0x00L),
  page_b0           = c(0x82L, 0x84L, 0x88L, 0xa2L, 0xa4L, 0xa8L),  # plain + mask
  page_b0_dense     = c(0x02L, 0x04L, 0x08L),                       # high nibble 0
  page_b3           = c(0x08L, 0x09L, 0x0aL, 0x0bL, 0x0cL, 0x0dL, 0x0eL),
  widths            = c(2L, 4L, 8L),
  descriptor_b9     = c(0x03L, 0xffL),
  # NAME markers (§E) are `81 02 {01,02,03} 00`, but the `81 02` prefix is a
  # generic block header shared by other record types, so this is NOT a closed
  # set to validate against -- documented for reference only.
  name_marker_sub   = c(0x01L, 0x02L, 0x03L),
  value_frame_lead  = c(0x01L, 0x81L)           # 01 01 plain/text  |  81 01 dense
)

# --- Recognizer unit-test cases (synthetic bytes; no corpus needed) -----------
# Each case: a recognizer, a list of positive (match) and negative (no-match)
# inputs. Inputs are list(raw, off) or a bare raw vector (off = 0).
u16le <- function(n) as.raw(c(n %% 256L, n %/% 256L))

# a well-formed plain page marker [b0] 01 [b2] [b3] with a trailing body
mk_page <- function(b0, b2 = 0x00L, b3 = 0x08L)
  as.raw(c(b0, 0x01L, b2, b3, rep(0x00L, 8L)))

# a footnote text blob [01 01][u16 len-4][01]<text, no NUL>
mk_text_block <- function(txt = "Renvoi 1 - note") {
  body <- c(as.raw(0x01L), charToRaw(txt))
  c(as.raw(c(0x01L, 0x01L)), u16le(length(body)), body)
}

# the second §F blob variant: no [01] marker byte, and NUL-terminated -- the
# survey lineage's per-dimension documentation blob (the UCR "Mandatory reading")
mk_doc_block <- function(txt = "For more information ... <A HREF=\"x\">3302</A>") {
  body <- c(charToRaw(txt), as.raw(0x00L))
  c(as.raw(c(0x01L, 0x01L)), u16le(length(body)), body)
}

# a plain member array [01 01][u16 len-4][u16 n_slots]<[len]txt[00]...>
mk_member_array <- function(slots = c("Foo", "Bar")) {
  recs <- unlist(lapply(slots, function(s)
    c(as.raw(nchar(s)), charToRaw(s), as.raw(0x00L))), use.names = FALSE)
  payload <- c(u16le(length(slots)), recs)
  c(as.raw(c(0x01L, 0x01L)), u16le(length(payload)), payload)
}

# a descriptor signature 81 01 20 00 f0 .. .. 80 [b9]
mk_descriptor <- function(b9 = 0x03L)
  as.raw(c(0x81L, 0x01L, 0x20L, 0x00L, 0xf0L, 0x00L, 0x00L, 0x80L, b9, rep(0x00L, 10L)))

# a footnote member bitmap 84 01 [u16 nbits][bitstream]
mk_footnote_bitmap <- function(nbits = 8L)
  c(as.raw(c(0x84L, 0x01L)), u16le(nbits), as.raw(rep(0xffL, ceiling(nbits / 16) * 2L)))

# --- Per-file marker inventory ------------------------------------------------
# Walk the page directory contiguously (8-byte entries) and record the distinct
# page-marker bytes actually present, plus the descriptor b9 and whether footnote
# text blocks appear in the geography directory. Best-effort and bounded; returns
# a list of integer vectors / logicals, or partial fields when a structure does
# not resolve.
ivt_marker_observe <- function(raw, budget = 60000L) {
  n <- length(raw)
  obs <- list(file_sig = as.integer(raw[1:4]),
              page_b0 = integer(0), page_b3 = integer(0),
              dense = FALSE, descriptor_b9 = NA_integer_,
              text_block = FALSE)

  # descriptor signature byte 9
  doff <- tryCatch(ivt_f2_descriptor_offset(raw), error = function(e) NULL)
  if (!is.null(doff) && !is.na(doff) && doff + 9L <= n &&
      isTRUE(ivt_f2_is_descriptor(raw, doff)))
    obs$descriptor_b9 <- as.integer(raw[doff + 9L])

  # page markers: contiguous directory walk from idx0 over the layout's entry span
  idx0 <- tryCatch(ivt_idx0(raw), error = function(e) NA_integer_)
  lay  <- tryCatch(ivt_layout(raw), error = function(e) NULL)
  if (!is.na(idx0) && !is.null(lay)) {
    span <- prod(vapply(lay$ent_counts, ivt_f2_nextpow2, 1L))
    kmax <- min(as.integer(span) - 1L, budget)
    b0s <- integer(0); b3s <- integer(0); nulls <- 0L
    for (k in 0:max(0L, kmax)) {
      o <- idx0 + 8L * k
      if (o + 8L > n) break
      en <- ivt_dir_entry(raw, o, n)
      if (is.null(en)) { nulls <- nulls + 1L; if (nulls > 256L) break else next }
      nulls <- 0L
      off <- en$off
      if (off + 4L > n || as.integer(raw[off + 2L]) != 0x01L) next  # not a page head
      b0 <- as.integer(raw[off + 1L])
      b0s <- c(b0s, b0)
      if (b0 < 0x80L) obs$dense <- TRUE else b3s <- c(b3s, as.integer(raw[off + 4L]))
    }
    obs$page_b0 <- sort(unique(b0s))
    obs$page_b3 <- sort(unique(b3s))
  }

  # geography-directory framing: does this file carry §F footnote text blobs?
  # (Informational -- NOT a closure set. The `81 02 <sub> 00` prefix is a generic
  # block header shared by many record types, so its sub-codes are not closed;
  # only 01/02/03 are the NAME markers of §E. See markers.md.)
  ents <- tryCatch(ivt_f2_geo_entries(raw), error = function(e) NULL)
  if (!is.null(ents)) {
    for (r in seq_len(ents$n)) {
      if (ivt_f2_dir_is_text_block(raw, ents$off(r), ents$len(r))) {
        obs$text_block <- TRUE; break
      }
    }
  }
  obs
}

# Assert one file's inventory against the catalog. Returns a character vector of
# violations (empty = clean); the corpus test turns a non-empty result into a
# failure naming the offending marker so a new vintage is flagged, not swallowed.
ivt_marker_violations <- function(obs) {
  v <- character(0)
  add <- function(what, bad)
    if (length(bad)) v <<- c(v, sprintf("%s: %s", what,
      paste(sprintf("0x%02x", bad), collapse = " ")))
  if (!identical(obs$file_sig[2:4], IVT_MARKER_SET$file_sig_tail) ||
      !obs$file_sig[1L] %in% IVT_MARKER_SET$file_sig_b0)
    v <- c(v, paste("file signature:", paste(sprintf("0x%02x", obs$file_sig), collapse = " ")))
  add("page b0",  setdiff(obs$page_b0[obs$page_b0 >= 0x80L], IVT_MARKER_SET$page_b0))
  add("dense b0", setdiff(obs$page_b0[obs$page_b0 < 0x80L], IVT_MARKER_SET$page_b0_dense))
  add("page b3",  setdiff(obs$page_b3, IVT_MARKER_SET$page_b3))
  if (!is.na(obs$descriptor_b9))
    add("descriptor b9", setdiff(obs$descriptor_b9, IVT_MARKER_SET$descriptor_b9))
  v
}
