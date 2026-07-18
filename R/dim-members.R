# Unified per-dimension member reader (PROTOTYPE, refactor-plan.md §8 exploration).
#
# The insight behind this file: EVERY dimension -- geography AND data -- stores its
# codebook the same way (dimdir.R): a `81 02 <nfields> 00` field dictionary naming
# its columns in one shared vocabulary ("Code / English Desc / Desc Francais / ...
# / UID/IDU / Level"), followed by the member-value runs. So a SINGLE reader can
# turn any dimension into a member tibble, with geography stopping being a special
# metadata path.
#
# The load-bearing subtlety (measured across the corpus): the field dictionary is a
# faithful MANIFEST of the dimension's logical columns, but columns have TWO storage
# disciplines, so the number of dense value runs is fewer than the field count:
#   - DENSE columns (Code / English Desc / Desc Francais): one slot per member,
#     power-of-two padded, NA for absent -- always present when declared. "Code" is
#     the member ordinal (a distinct framing, not one of the two label runs).
#   - SPARSE, bitmap-gated columns (_Description / _ItemNotes, the member notes): a
#     `84 01` member bitmap (`ivt_f2_footnote_bitmap()`) selects which members carry a
#     value, then ONLY those texts are stored (popcount = record count). When no member
#     carries one, the bitmap AND the text block vanish entirely -- so the column
#     physically disappears though the dictionary still names it. Measured 1:1 across
#     the corpus: a `_Description`/`_ItemNotes` field in the dictionary <=> exactly the
#     EN+FR `84 01` bitmaps in the directory; no such field <=> no bitmap. (These
#     member notes are what `ivt_f2_dir_footnotes()` already decodes; a fuller reader
#     could scatter them into a per-member column here.)
# So the run -> column mapping is NOT positional against the dictionary; each clean
# DENSE run's ROLE is inferred (ordinal vs label vs uid), the dictionary supplying the
# vocabulary and the EN-before-FR schema order (`ivt_f2_dim_dict_en_first()`).

# The field dictionary for ANY dimension's block directory (generalised from the
# geography-only `ivt_f2_geo_field_schema()`). Scans the directory for the
# `81 02 <nfields> 00` block and returns its ordered `[02][len][name]` field names
# (latin-1), or NULL. "Code" is dropped by the i=5 header skip because it uses a
# different framing (it is the ordinal, not a stored value run).
ivt_f2_dim_field_schema <- function(raw, dir) {
  if (is.null(dir) || !nrow(dir)) return(NULL)
  n <- length(raw)
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 8L || len > 4000L || off + len > n) next
    if (as.integer(raw[off + 1L]) != 0x81L || as.integer(raw[off + 2L]) != 0x02L) next
    b <- as.integer(raw[(off + 1L):(off + len)]); out <- character(0)
    i <- 5L                                            # skip the 81 02 <nfields> 00 header
    while (i < length(b) - 1L) {                       # scan the [02][len][name] records
      L <- b[i + 1L]
      if (b[i] == 0x02L && L >= 3L && L <= 40L && i + 1L + L <= length(b)) {
        nm <- raw_to_latin1(as.raw(b[(i + 2L):(i + 1L + L)]))
        if (!grepl("[[:cntrl:]]", nm)) { out <- c(out, nm); i <- i + 2L + L; next }
      }
      i <- i + 1L
    }
    if (length(out) >= 2L) return(out)
  }
  NULL
}

# One dimension's members as a tibble, read positionally from its slot directory.
# Columns: `member_id` (1..count, the stored order), `ordinal` (the member-ordinal
# block when present, else member_id), `label_en` / `label_fr` (the two member-label
# runs, EN/FR by the dictionary schema order), and `uid` when the dictionary names a
# `UID/IDU` field and a code-like run carries it. Geography-specific columns (level,
# data quality) are NOT surfaced here yet -- this prototype covers the data-dimension
# and simple-schema geography case, to prove the shared reader reproduces the
# validated labels before the geography specializers are migrated onto it.
#
# Returns NULL when the dimension's directory / marker does not resolve (the caller
# keeps the existing per-reader fallback).
ivt_f2_dim_members <- function(raw, k, slots = NULL, d = NULL, include_notes = TRUE) {
  if (is.null(d)) d <- ivt_f2_descriptor(raw)
  if (is.null(d) || k < 1L || k > length(d$dims)) return(NULL)
  if (is.null(slots)) slots <- ivt_f2_dim_slots(raw, m = length(d$dims))
  dir <- ivt_f2_dim_dir(raw, k, slots)
  if (is.null(dir)) return(NULL)
  ivt_f2_dim_members_from_dir(raw, d$dims[[k]], dir, include_notes = include_notes)
}

# The reader core, addressed by an already-resolved (dimension descriptor, block
# directory) pair -- so the label adapter (`ivt_f2_dim_dir_label1()`) and the
# k-addressed entry point above share ONE path. `include_notes = FALSE` skips the
# sparse member-notes walk for the label hot path (which discards it).
ivt_f2_dim_members_from_dir <- function(raw, dim, dir, include_notes = TRUE) {
  if (is.null(dir)) return(NULL)
  cnt <- as.integer(dim$count)
  if (is.na(cnt) || cnt < 1L) return(NULL)
  nm <- dim$name
  named <- !is.null(nm) && !is.na(nm) && nzchar(nm)
  fields <- ivt_f2_dim_field_schema(raw, dir)
  mk <- if (named) ivt_f2_dir_marker_entry(raw, nm, dir) else 0L
  # a named dimension whose doubled-name marker does not resolve yields NULL (the
  # caller falls back), exactly as the former label reader did -- the whole-directory
  # scan is reserved for the (future) nameless-geography case.
  if (named && (mk == 0L || mk >= nrow(dir))) return(NULL)

  # --- collect the clean member-value runs (length cnt) ---
  runs <- ivt_f2_dim_member_runs(raw, dir, cnt, mk)
  if (!length(runs)) return(NULL)

  # --- classify each run by role ---
  ord <- NULL; text_runs <- list()
  for (t in runs) {
    iv <- suppressWarnings(as.integer(t))
    if (!anyNA(iv) && identical(sort(iv), seq_len(cnt))) {
      if (is.null(ord)) ord <- iv                      # the ordinal (Code) run
      next
    }
    text_runs[[length(text_runs) + 1L]] <- t
  }
  if (!length(text_runs)) return(NULL)

  # EN vs FR by the dictionary schema (English Desc before Desc Francais); the loud
  # content-score fallback only when the dimension carries no schema block.
  label_en <- text_runs[[1L]]; label_fr <- NULL
  if (length(text_runs) >= 2L) {
    en_first <- ivt_f2_dim_dict_en_first(raw, dir)
    if (is.na(en_first)) en_first <- ivt_f2_label_lang_fallback(nm, text_runs[[1L]], text_runs[[2L]])
    label_en <- if (en_first) text_runs[[1L]] else text_runs[[2L]]
    label_fr <- if (en_first) text_runs[[2L]] else text_runs[[1L]]
  }

  # a uid run, when the dictionary NAMES a UID/IDU field and a further run is code-like
  uid <- NULL
  if (!is.null(fields) && any(grepl("UID|IDU", toupper(fields))) && length(text_runs) > 2L) {
    for (t in text_runs[-(1:2)]) {
      if (all(!grepl("\\s", t)) && any(grepl("[0-9]", t))) { uid <- t; break }
    }
  }

  out <- tibble::tibble(
    member_id = seq_len(cnt),
    ordinal   = if (is.null(ord)) seq_len(cnt) else ord,
    label_en  = label_en)
  if (!is.null(label_fr)) out$label_fr <- label_fr
  if (!is.null(uid))      out$uid <- uid
  # the sparse, bitmap-gated `_Description`/`_ItemNotes` member-notes column
  if (include_notes) {
    notes <- ivt_f2_dim_member_notes(raw, dir, cnt)
    if (!is.null(notes)) {
      out$notes_en <- notes$en
      if (!all(is.na(notes$fr))) out$notes_fr <- notes$fr
    }
  }
  attr(out, "fields") <- fields
  attr(out, "name_fr") <- if (!is.null(label_fr)) ivt_f2_total_name(label_fr) else NA_character_
  out
}

# The sparse, bitmap-gated member-notes column (`_Description` / `_ItemNotes`) for one
# dimension, scattered into per-member EN/FR vectors. The dimension's footnote region
# opens with a `84 01` member bitmap (`ivt_f2_footnote_bitmap()`; an EN copy then an
# identical FR copy) listing which members carry a note, in member order; the first
# `popcount(bitmap)` footnote texts per language are those member notes, assigned to
# the bitmapped members in order (the remaining texts are DIMENSION notes, which
# annotate the whole dimension and are NOT a member column). This mirrors the
# member-note linkage of `ivt_f2_dir_footnotes()` exactly, materialized as a column
# rather than a footnote record. Returns list(en, fr), each a length-`cnt` character
# vector (NA where the member carries no note), or NULL when the dimension has no
# member bitmap / no member note. The byte prefilter keeps it cheap on big directories.
ivt_f2_dim_member_notes <- function(raw, dir, cnt) {
  members <- integer(0); seen_bitmap <- FALSE
  seq_lang <- c(en = 0L, fr = 0L)
  en <- rep(NA_character_, cnt); fr <- rep(NA_character_, cnt)
  any_note <- FALSE
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    win <- raw[(off + 1L):min(length(raw), off + len)]
    if (length(win) >= 6L && win[1] == as.raw(0x84L) && win[2] == as.raw(0x01L)) {
      if (!seen_bitmap) { members <- ivt_f2_footnote_bitmap(win); seen_bitmap <- TRUE }
      next
    }
    if (len < 24L) next
    if (!length(grepRaw("Footnote", win, fixed = TRUE)) &&
        !length(grepRaw("Renvoi", win, fixed = TRUE)) &&
        !length(grepRaw("FOOTNOTE", win, fixed = TRUE)) &&
        !length(grepRaw("RENVOI", win, fixed = TRUE))) next
    for (f in ivt_footnote_texts(raw, off, off + len)) {
      seq_lang[f$language] <- seq_lang[f$language] + 1L
      i <- seq_lang[[f$language]]
      if (i <= length(members) && members[i] >= 1L && members[i] <= cnt) {
        if (f$language == "en") en[members[i]] <- f$text else fr[members[i]] <- f$text
        any_note <- TRUE
      }
    }
  }
  if (!seen_bitmap || !length(members) || !any_note) return(NULL)
  list(en = en, fr = fr)
}

# The clean member-value runs of one dimension (length exactly `cnt`), in storage
# order, from the rows after its doubled-name marker (or the whole directory when the
# marker did not resolve). Chunked (>256-member) dimensions reuse the geography/label
# chunk assembler. Runs are strict-first (`ivt_f2_dir_member_arrays()`), rejecting
# control-character / empty records so footnote and definition blocks (which the
# Pascal scanner reads as ~cnt-length runs) are excluded.
ivt_f2_dim_member_runs <- function(raw, dir, cnt, mk) {
  if (cnt > 256L && mk > 0L) {
    ck <- ivt_f2_dim_dir_label_chunks(raw, cnt, dir, mk)
    return(if (is.null(ck)) list() else ck)
  }
  rows <- if (mk > 0L && mk < nrow(dir)) (mk + 1L):nrow(dir) else seq_len(nrow(dir))
  ivt_f2_dir_member_arrays(
    raw, dir, cnt, rows = rows, max_keep = 8L,
    accept = function(t) {
      if (any(grepl("[[:cntrl:]]", t)) || !all(nzchar(t))) return(NULL)
      t
    })
}
