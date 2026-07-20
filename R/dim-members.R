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
      # L >= 2: field NAMES can be two characters ("DQ"/"QD", the data-quality flag
      # column) -- the old `>= 3` threshold silently DROPPED them, under-counting the
      # dictionary (CRO0163850_CT7 read 5 fields for a 6-column codebook).
      if (b[i] == 0x02L && L >= 2L && L <= 40L && i + 1L + L <= length(b)) {
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
  # scan is reserved for the (future) nameless-geography case. EXCEPTION: when the
  # marker resolves but is the LAST directory entry, the member arrays precede it --
  # the older `04 00 20 00` survey tables' singleton reference dimension stores its
  # one member as a `81 02 01 00` value block BEFORE the name marker (ucr's "Year" ->
  # "2006"). Recover it directly rather than declaring the dimension unresolved.
  if (named && mk >= nrow(dir) && mk > 0L) {
    vb <- ivt_f2_dim_value_block_labels(raw, dir, setdiff(seq_len(nrow(dir)), mk))
    if (length(vb) == cnt)
      return(tibble::tibble(member_id = seq_len(cnt), ordinal = seq_len(cnt),
                            label_en = vb))
    return(NULL)
  }
  # A named dimension whose doubled-name marker does NOT resolve (mk == 0) is not
  # necessarily unreadable: the `02 00 20 00` survey reference-period dimension
  # (Health Statistics "ANNUAL" years) carries no `81 02 02 00` name marker at all,
  # only a member CODE array (the years). Fall through to the whole-directory run
  # scan (mk == 0 already scans every entry) rather than bailing -- the run-count
  # self-check (exactly `cnt` clean records) rejects a spurious match, so a
  # genuinely unreadable dimension still returns NULL below.

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

# Per-member DESCRIPTION prose -- the `_Description` field of the dimension's field
# dictionary, as stored by the older `02 00 20 00` survey tables: a FULL-LENGTH text
# block rather than the modern `84 01`-bitmap member note. Each block reuses the
# plain-array header `[01 01][u16 len-4][01]` but its payload is a single latin1 prose
# string (the indicator definition, e.g. the TFR's "... the number of children born
# per 1,000 women during their reproductive period."), often NUL-padded to the block
# length. Told from a member LABEL block (`[01 01][u16][01][00][strlen]<text>`) by its
# first payload byte being printable text -- not the `0x00` of the label's nested
# Pascal length -- and required to be prose (>= 20 chars with whitespace). EN vs FR by
# content score; each language's blocks map to members in directory (member) order.
# Returns list(en, fr), each length `cnt` (NA where absent), or NULL.
ivt_f2_dim_prose_texts <- function(raw, dir, cnt) {
  n <- length(raw); texts <- character(0)
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 16L || off < 0L || off + len > n) next
    if (raw[off + 1L] != as.raw(0x01L) || raw[off + 2L] != as.raw(0x01L)) next
    if (isTRUE(rd_u16(raw, off + 2L) != len - 4L)) next   # plain-array payload len
    if (raw[off + 5L] != as.raw(0x01L)) next              # single-record marker
    if (as.integer(raw[off + 6L]) < 32L) next             # a LABEL's 0x00 Pascal length
    payload <- raw[(off + 6L):(off + len)]
    z <- which(payload == as.raw(0x00L))                  # stop at trailing NUL padding
    if (length(z)) payload <- payload[seq_len(z[1L] - 1L)]
    txt <- trimws(raw_to_latin1(payload))
    # FOOTNOTE prose ("Footnote N ..." / "Renvoi N ...") is excluded -- those are the
    # member footnotes, already surfaced as scoped footnote records.
    if (nchar(txt) >= 20L && grepl("[[:space:]]", txt) &&
        !grepl("^(Footnote|Renvoi|FOOTNOTE|RENVOI)\\b", txt))
      texts <- c(texts, txt)
  }
  if (!length(texts)) return(NULL)
  sc <- vapply(texts, ivt_f2_frscore, 0)
  # POSITIONAL member mapping, but only when unambiguous: member 1 for a singleton
  # dimension (the facet/quantity indicator's definition, the common case) or exactly
  # one text per member (dense). A sparser multi-member set carries no in-block member
  # index, so it is dropped rather than mis-aligned onto the wrong member.
  map1 <- function(v) {
    if (!length(v)) return(rep(NA_character_, cnt))
    if (cnt == 1L) return(v[1L])
    if (length(v) == cnt) return(v)
    NULL
  }
  en <- map1(texts[sc <= 0]); fr <- map1(texts[sc > 0])
  if (is.null(en) || is.null(fr)) return(NULL)
  if (all(is.na(en)) && all(is.na(fr))) return(NULL)
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
  runs <- ivt_f2_dir_member_arrays(
    raw, dir, cnt, rows = rows, max_keep = 8L,
    accept = function(t) {
      if (any(grepl("[[:cntrl:]]", t)) || !all(nzchar(t))) return(NULL)
      t
    })
  if (length(runs)) return(runs)
  # The older `04 00 20 00` survey tables store a singleton reference dimension's
  # member (ucr2.2_3-2006's "Year" -> "2006") NOT as a `[01 01]` member array but as
  # per-member `81 02 01 00` VALUE blocks, which the array reader above cannot see.
  # Recover them positionally: one label per such block, in directory order.
  vb <- ivt_f2_dim_value_block_labels(raw, dir, rows)
  if (length(vb) == cnt) list(vb) else list()
}

# Single member labels stored as `81 02 01 00` VALUE blocks (one per member), told
# apart from the same-tagged field-NAME / schema block by structure: a value block's
# trailing `[u8 strlen][latin-1 string]` reaches the block's END exactly, whereas a
# field-dictionary block ("Code", "Description", ...) carries schema bytes after its
# name. Returns the labels in directory order (may be empty). Used only as the
# member-run fallback for dimensions with no `[01 01]`/`[81 01]` member array.
ivt_f2_dim_value_block_labels <- function(raw, dir, rows) {
  n <- length(raw); out <- character(0)
  for (r in rows) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 8L || len > 512L || off + len > n) next
    if (as.integer(raw[off + 1L]) != 0x81L || as.integer(raw[off + 2L]) != 0x02L ||
        as.integer(raw[off + 3L]) != 0x01L) next
    # the member value occupies the block tail: a [strlen][string] ending at off+len.
    end <- off + len
    found <- NA_character_
    for (p in (off + 5L):(end - 1L)) {
      k <- as.integer(raw[p])
      if (k >= 1L && k <= 40L && p + k == end) {
        s <- as.integer(raw[(p + 1L):(p + k)])
        if (all(s >= 32L & s <= 126L | s >= 160L)) {     # printable latin-1
          found <- raw_to_latin1(raw[(p + 1L):(p + k)]); break
        }
      }
    }
    if (!is.na(found) && !grepl("[[:cntrl:]]", found)) out <- c(out, found)
  }
  out
}
