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
# SCHEMA of columns that MAY exist, not a manifest of stored runs. "Code" is the
# member ordinal (a different framing, not a value run); "_Description"/"_ItemNotes"
# usually bleed into the footnote region and are not clean runs. So the run -> column
# mapping is NOT 1:1 with the dictionary; each clean run's ROLE is inferred (ordinal
# vs label vs uid), the dictionary supplying the vocabulary and the EN-before-FR
# schema order (`ivt_f2_dim_dict_en_first()`), never a positional guess.

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
ivt_f2_dim_members <- function(raw, k, slots = NULL, d = NULL) {
  if (is.null(d)) d <- ivt_f2_descriptor(raw)
  if (is.null(d) || k < 1L || k > length(d$dims)) return(NULL)
  if (is.null(slots)) slots <- ivt_f2_dim_slots(raw, m = length(d$dims))
  dir <- ivt_f2_dim_dir(raw, k, slots)
  if (is.null(dir)) return(NULL)
  ivt_f2_dim_members_from_dir(raw, d$dims[[k]], dir)
}

# The reader core, addressed by an already-resolved (dimension descriptor, block
# directory) pair -- so the label adapter (`ivt_f2_dim_dir_label1()`) and the
# k-addressed entry point above share ONE path.
ivt_f2_dim_members_from_dir <- function(raw, dim, dir) {
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
  attr(out, "fields") <- fields
  attr(out, "name_fr") <- if (!is.null(label_fr)) ivt_f2_total_name(label_fr) else NA_character_
  out
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
