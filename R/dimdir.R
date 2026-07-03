#' Header per-dimension directory slot table
#'
#' The fixed header carries one 14-byte record per descriptor dimension (in
#' descriptor order, geography = dimension 1) at `@824 + 14*(k-1)`:
#'
#'     [u32 dir_ptr][u32 ?][u32 n_entries][2 bytes]
#'
#' `dir_ptr` points at that dimension's **block directory** -- a table of the
#' familiar 8-byte entries `[u32 off][u16 len][u16 len]` (the same shape as the
#' page directory) -- either directly, or (the big chunked geography directories,
#' e.g. 98-10-0023's 6,244 entries) via a small struct whose first u32 is the
#' directory pointer. `n_entries` is the entry count (the decoded table may run
#' up to a few entries short when null slots are skipped), which makes the slot
#' self-validating.
#'
#' Each dimension's directory lists that dimension's complete codebook in
#' LOGICAL order with exact offsets and lengths: its dictionary/schema block,
#' member-id table, member-ordinal block, the `81 02 02 00` doubled-name marker
#' block, then the EN member-label block, the FR member-label block, and that
#' dimension's footnotes (EN/FR pairs). This is the structure the tail-window
#' scans (`ivt_f2_marker_labels()`, `ivt_footnotes()`) reconstruct by content;
#' reading it positionally needs no windows and no adjacency heuristics, and
#' attributes each footnote to its owning dimension. Decoded and validated on
#' 98-10-0241, 98-10-0077 (7 dims), 98-10-0129 (4), 98-10-0023 and the 1991
#' legacy 1003011 (3): every data-dimension label block byte-identical to the
#' marker-anchored reader, every footnote set equal to the tail scan.
#'
#' The old `IVT_F2_DIR_SLOTS = c(824, 572, 712)` guesses were partial hits on
#' this table: `@824` is dimension 1 (geography); `@852` is dimension 3 (the
#' 4-byte-aligned probing missed the odd 14-byte-strided slots in between).
#'
#' @keywords internal
#' @noRd
NULL

IVT_HDR_DIM_SLOT0  <- 824L  # first per-dimension slot (dimension 1 = geography)
IVT_HDR_DIM_STRIDE <- 14L   # 14-byte slot records

# The per-dimension slot records, one per descriptor dimension. Returns a list of
# list(dim, slot, ptr, n_entries), or NULL when there is no descriptor / the
# header is too short.
ivt_f2_dim_slots <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  # the 32-dim cap mirrors ivt_f2_decodable(): unsupported container variants
  # misread the descriptor as hundreds of dimensions. Judge by the recovered
  # dimension records, not the header count field (unreliable on some vintages,
  # e.g. 95F0200XDB96003 reads 1026 with 4 clean dimensions).
  m <- if (is.null(d)) 0L else length(d$dims)
  if (m < 1L || m > 32L) return(NULL)
  n <- length(raw)
  out <- vector("list", m)
  for (k in seq_len(m)) {
    s <- IVT_HDR_DIM_SLOT0 + (k - 1L) * IVT_HDR_DIM_STRIDE
    if (s + 12L > n) return(NULL)
    out[[k]] <- list(dim = k, slot = s, ptr = rd_u32(raw, s),
                     n_entries = rd_u32(raw, s + 8L))
  }
  out
}

# Resolve dimension k's block directory from its header slot. The slot's
# `n_entries` field validates the decode: the parsed table must reach it (up to
# 4 skipped null slots) and not run past it, so a slot whose pointer means
# something else on some layout is rejected rather than misread. Tries the two
# indirection depths (slot -> directory, and slot -> struct -> directory).
# Returns the (off, len) entry matrix, or NULL.
ivt_f2_dim_dir <- function(raw, k, slots = NULL) {
  if (is.null(slots)) slots <- ivt_f2_dim_slots(raw)
  if (is.null(slots) || k < 1L || k > length(slots)) return(NULL)
  sl <- slots[[k]]
  if (is.na(sl$ptr) || sl$ptr < 1 || is.na(sl$n_entries) ||
      sl$n_entries < 1 || sl$n_entries > 1e6) return(NULL)
  want <- as.integer(sl$n_entries)
  ok <- function(d) !is.null(d) && nrow(d) <= want && nrow(d) >= max(1L, want - 4L)
  d <- ivt_f2_read_dir_at(raw, sl$ptr, max_entries = want + 4L)
  if (ok(d)) return(d)
  d <- ivt_f2_read_dir_at(raw, rd_u32(raw, sl$ptr), max_entries = want + 4L)
  if (ok(d)) d else NULL
}

# Which of a dimension's two member-label blocks is English, decided by a
# STRUCTURAL marker rather than by scoring the text. Every data dimension carries
# a dictionary/schema block (`81 02 <nfields> 00` ...) that names its columns --
# `Code`, `English Desc`, `Desc Francais`/`Desc fran` (1991), `_Description`,
# `_ItemNotes2` -- and the member-label blocks are laid down in that schema order.
# So the language of the two blocks is fixed by whether `English Desc` precedes
# `Desc Fran...` in the schema (it does on every validated table). Returns TRUE
# (English block first), FALSE (French first), or NA when no schema block is
# found (the caller then falls back to `ivt_f2_frscore()`).
ivt_f2_dim_dict_en_first <- function(raw, dir) {
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; ln <- dir[r, "len"]
    if (ln < 12L || ln > 400L || off + ln > length(raw)) next
    if (as.integer(raw[off + 1L]) != 0x81L) next
    txt <- raw_to_latin1(raw[(off + 1L):(off + ln)])
    # case-insensitive: 98-10-* store "Desc Francais", 1991 "Desc fran"
    ie <- regexpr("English Desc", txt, ignore.case = TRUE)
    ifr <- regexpr("Desc Fran", txt, ignore.case = TRUE)
    if (ie > 0L && ifr > 0L) return(ie < ifr)
  }
  NA
}

# The dimension name embedded in a "Total - <name>" member label (the first
# member of a dimension is almost always "Total - <dimension name>", in whichever
# language the block is). Used to recover the FRENCH dimension name, which the
# header Variable List (English only) does not carry. Returns NA when the first
# member is not a "Total - ..." label (e.g. the Statistics dimension, whose first
# member is "Number of private households" / "Nombre de menages prives").
ivt_f2_total_name <- function(labels) {
  if (!length(labels) || is.na(labels[1])) return(NA_character_)
  m <- regmatches(labels[1],
                  regexec("^\\s*Total\\s*[-\u2013\u2014]\\s*(.+?)\\s*$", labels[1]))[[1]]
  if (length(m) >= 2L && nzchar(trimws(m[2]))) trimws(m[2]) else NA_character_
}

# English AND French member labels for one data dimension, read positionally from
# its slot directory. The directory lists (among framing/separator entries) the
# dimension's doubled-name marker block followed by the two member-label blocks in
# dictionary-schema order (English Desc then Desc Francais). We take the first two
# clean member-array entries after the marker (each candidate's trailing `count`
# records; the block can carry a couple of leading framing bytes the Pascal scan
# misreads as records, e.g. 98-10-0077's Ages), then assign languages by the
# schema (`ivt_f2_dim_dict_en_first()`) -- a structural marker, not a content
# guess. `ivt_f2_frscore()` is used only when the schema block is absent (then a
# loud fallback fires). The marker entry is matched to the dimension NAME (prefix
# match), so a directory that belongs to something else on an unknown layout
# yields NULL rather than wrong labels. Returns `list(en, fr, name_fr)` (labels
# untrimmed, as stored; `fr`/`name_fr` NULL/NA when only one block is present) or
# NULL.
ivt_f2_dim_dir_label1 <- function(raw, dim, dir) {
  cnt <- as.integer(dim$count)
  if (is.na(cnt) || cnt < 1L) return(NULL)
  nm <- dim$name
  if (is.null(nm) || is.na(nm) || !nzchar(nm)) return(NULL)
  # locate the doubled-name marker entry (81 02 02 00 + this dimension's name)
  mk <- 0L
  for (r in seq_len(nrow(dir))) {
    len <- dir[r, "len"]
    if (len < 12L || len > 4000L) next
    win <- raw[(dir[r, "off"] + 1L):min(length(raw), dir[r, "off"] + len)]
    m <- ivt_f2_codebook_dim_markers(win, 0L)
    hit <- which(vapply(m$name, function(x) {
      if (is.na(x)) return(FALSE)
      j <- min(nchar(x), nchar(nm))
      j >= 4L && substr(x, 1L, j) == substr(nm, 1L, j)
    }, logical(1)))
    if (length(hit)) { mk <- r; break }
  }
  if (mk == 0L || mk >= nrow(dir)) return(NULL)
  # the EN/FR member blocks are the first two member-array entries after it
  cand <- list()
  for (r in (mk + 1L):nrow(dir)) {
    len <- dir[r, "len"]
    if (len <= 8L || len < cnt + 4L) next          # separators / tiny framing
    win <- raw[(dir[r, "off"] + 1L):min(length(raw), dir[r, "off"] + len)]
    b <- ivt_find_member_blocks(win, 0L, min_records = 1L)
    if (!length(b)) next
    sz <- vapply(b, function(x) length(x$texts), 1L)
    bi <- which(sz >= cnt & sz <= cnt + 8L)        # the member block (+ slack for
    if (!length(bi)) next                          #   leading framing misreads)
    t <- b[[bi[length(bi)]]]$texts
    t <- t[(length(t) - cnt + 1L):length(t)]       # trailing `count` records
    if (identical(t, as.character(seq_len(cnt)))) next   # an ordinal block
    if (any(grepl("[[:cntrl:]]", t)) || !all(nzchar(t))) next  # framing garbage
    cand[[length(cand) + 1L]] <- t
    if (length(cand) == 2L) break
  }
  if (!length(cand)) return(NULL)
  if (length(cand) == 1L)
    return(list(en = cand[[1L]], fr = NULL, name_fr = NA_character_))
  # assign languages by the dictionary schema order (English Desc / Desc Francais)
  en_first <- ivt_f2_dim_dict_en_first(raw, dir)
  if (is.na(en_first)) {
    diff <- which(cand[[1L]] != cand[[2L]])
    en_first <- ivt_f2_frscore(cand[[1L]][diff]) <= ivt_f2_frscore(cand[[2L]][diff])
    ivt_fallback(paste(
      "Dimension {.val {nm}} carries no English Desc/Desc Fran schema block;",
      "its English vs French label blocks were told apart by content score,",
      "not the schema order."))
  }
  en <- if (en_first) cand[[1L]] else cand[[2L]]
  fr <- if (en_first) cand[[2L]] else cand[[1L]]
  list(en = en, fr = fr, name_fr = ivt_f2_total_name(fr))
}

# The member-ordinal block for one data dimension, read positionally from its
# slot directory. Each dimension's directory lists (before the doubled-name
# marker and the EN/FR label blocks) a member-ordinal block: a Pascal member
# array whose records are the members' 1-based ordinals as text. It is the block
# `ivt_f2_dim_dir_label1()` explicitly skips; here it is the payload. A candidate
# must be a permutation of 1..count (this rejects label blocks that happen to be
# numeric, e.g. a reference-period dimension's "2020"/"2015" years); the LAST
# such entry wins (the member-id table can precede the ordinals with the same
# shape -- on every validated table both are the identity, so the choice is
# moot). Returns the integer ordinal of members 1..count, or NULL when the
# directory stores no ordinal block (e.g. the 2-member reference periods).
ivt_f2_dim_dir_ordinal1 <- function(raw, dim, dir) {
  cnt <- as.integer(dim$count)
  if (is.na(cnt) || cnt < 1L) return(NULL)
  cand <- NULL
  for (r in seq_len(nrow(dir))) {
    len <- dir[r, "len"]
    if (len <= 8L || len < cnt + 4L) next          # separators / tiny framing
    win <- raw[(dir[r, "off"] + 1L):min(length(raw), dir[r, "off"] + len)]
    b <- ivt_find_member_blocks(win, 0L, min_records = 1L)
    if (!length(b)) next
    sz <- vapply(b, function(x) length(x$texts), 1L)
    bi <- which(sz >= cnt & sz <= cnt + 8L)
    if (!length(bi)) next
    t <- b[[bi[length(bi)]]]$texts
    t <- t[(length(t) - cnt + 1L):length(t)]       # trailing `count` records
    iv <- suppressWarnings(as.integer(t))
    if (anyNA(iv) || !identical(sort(iv), seq_len(cnt))) next
    cand <- iv
  }
  cand
}

# Member ordinals for every dimension, read from the header slot table. Returns
# a list parallel to the descriptor dimensions (element k = dimension k's
# integer ordinal vector; geography and dimensions without an ordinal block are
# NULL), or NULL when the slot table itself is absent. A NULL element means the
# member order IS the stored order (ordinal = member id) -- the consumer
# defaults to `seq_along(members)`.
ivt_f2_dim_dir_ordinals <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || length(d$dims) < 2L) return(NULL)
  slots <- ivt_f2_dim_slots(raw)
  if (is.null(slots)) return(NULL)
  out <- vector("list", length(d$dims))
  for (k in 2:length(d$dims)) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) next
    out[[k]] <- ivt_f2_dim_dir_ordinal1(raw, d$dims[[k]], dir)
  }
  out
}

# English + French member labels for every dimension, read from the header slot
# table. Returns a list parallel to the descriptor dimensions (element k =
# dimension k's `list(en, fr, name_fr)`; geography and unresolved dimensions are
# NULL), or NULL when the slot table itself is absent. Unresolved dimensions fall
# back to the marker/count scans in `ivt_f2_dimensions()` (English only).
ivt_f2_dim_dir_labels <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || length(d$dims) < 2L) return(NULL)
  slots <- ivt_f2_dim_slots(raw)
  if (is.null(slots)) return(NULL)
  out <- vector("list", length(d$dims))
  for (k in 2:length(d$dims)) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) next
    out[[k]] <- ivt_f2_dim_dir_label1(raw, d$dims[[k]], dir)
  }
  out
}

# Byte span [start, end) covered by the geography dimension's block directory --
# the metadata-declared bound of the whole geography codebook (dictionary, member
# ids, ordinals, marker, label/attribute blocks, footnotes). Used to bound the
# content scans (`ivt_f2_geo_marker_region()`, and through it the DGUID byte scan)
# by the file's own metadata instead of a marker-to-marker window. Returns
# c(start, end) or NULL when dimension 1's directory does not resolve.
ivt_f2_geo_dir_span <- function(raw) {
  d <- ivt_f2_dim_dir(raw, 1L)
  if (is.null(d)) return(NULL)
  c(min(d[, "off"]), min(length(raw), max(d[, "off"] + d[, "len"])))
}

# --- Master directory + DQF legend --------------------------------------------
#
# Two more header slots point at block directories of the same 8-byte entry shape:
#
# `@544` -> the MASTER directory (at offset 992 on every known layout, also
# reachable via `@992`/`@1000` and `@12` with one indirection). Its ~10 entries
# cover whole-file sections in a stable order: [1] the FACET04 + EN title block,
# [2] the dimension descriptor (the same block `@32` points at), [3] a 15-byte EOF
# trailer, [4] the EN identity text (modern: the inline "Product ID: ... Title:
# ..." block; legacy/2016: the out-of-line title + notes blob the header EN title
# pointer `@48` also addresses), [5] the product-id string, [6-8] small framing
# blocks, [9] the FACET04 + FR title, [10/11] the FR identity/notes blob. Decoded
# on 98-10-0241/0023 (10 entries), 1003011 and 98-400-X2016387 (11).
#
# `@712` -> the DATA-QUALITY-FLAG LEGEND directory (2021 tables: 15 entries; the
# pre-DGUID tables carry a 1-entry 6-byte stub). Entry 1 is a u32 index list; each
# following entry is one legend record framed
#
#     [82 01][u16][flag bytes][02][code char][00][u16 text_len][text]
#
# (the FR records carry one extra flag dword; `text_len` counts a trailing NUL the
# entry length may drop). Records come in EN/FR pairs per code letter (A..E
# quality classes, R revised, P preliminary, ...), language per pair by
# `ivt_f2_frscore()`.

IVT_HDR_MASTER_SLOT <- 544L   # u32 -> the master (whole-file section) directory
IVT_HDR_DQF_SLOT    <- 712L   # u32 -> the data-quality-flag legend directory

# The master directory's (off, len) entries, or NULL.
ivt_f2_master_dir <- function(raw) {
  ptr <- rd_u32(raw, IVT_HDR_MASTER_SLOT)
  if (is.na(ptr) || ptr < 1L) return(NULL)
  d <- ivt_f2_read_dir_at(raw, ptr, max_entries = 24L)
  if (is.null(d) || nrow(d) < 3L) return(NULL)
  d
}

# The data-quality-flag legend: tibble(code, text_en, text_fr), or NULL when the
# table carries none (the pre-DGUID stub) or the slot does not decode.
ivt_f2_dqf_legend <- function(raw) {
  ptr <- rd_u32(raw, IVT_HDR_DQF_SLOT)
  if (is.na(ptr) || ptr < 1L) return(NULL)
  d <- ivt_f2_read_dir_at(raw, ptr, max_entries = 64L)
  if (is.null(d) || nrow(d) < 3L) return(NULL)         # the 1-entry stub
  parse1 <- function(off, len) {
    if (off + len > length(raw) || as.integer(raw[off + 1L]) != 0x82L) return(NULL)
    v <- as.integer(raw[(off + 1L):(off + len)])
    for (i in 5:min(14L, len - 5L)) {                  # find [02][code][00][u16 len]
      if (v[i] != 0x02L) next
      code <- v[i + 1L]
      if (code < 32L || code > 126L || v[i + 2L] != 0x00L) next
      tl <- v[i + 3L] + 256L * v[i + 4L]
      if (tl < 1L || i + 4L + tl > len + 1L) next      # +1: a dropped trailing NUL
      txt <- raw[(off + i + 5L):(off + min(i + 4L + tl, len))]
      txt <- txt[txt != as.raw(0)]
      return(list(code = intToUtf8(code), text = raw_to_latin1(txt)))
    }
    NULL
  }
  recs <- list()
  for (r in seq_len(nrow(d))) {
    p <- parse1(d[r, "off"], d[r, "len"])
    if (!is.null(p)) recs[[length(recs) + 1L]] <- p
  }
  if (length(recs) < 2L) return(NULL)
  code <- vapply(recs, `[[`, "", "code")
  text <- vapply(recs, `[[`, "", "text")
  out_code <- character(0); out_en <- character(0); out_fr <- character(0)
  i <- 1L
  while (i <= length(code)) {
    if (i < length(code) && code[i + 1L] == code[i]) {
      a <- text[i]; b <- text[i + 1L]
      en_first <- ivt_f2_frscore(a) <= ivt_f2_frscore(b)
      out_code <- c(out_code, code[i])
      out_en <- c(out_en, if (en_first) a else b)
      out_fr <- c(out_fr, if (en_first) b else a)
      i <- i + 2L
    } else {
      out_code <- c(out_code, code[i]); out_en <- c(out_en, text[i])
      out_fr <- c(out_fr, NA_character_)
      i <- i + 1L
    }
  }
  tibble::tibble(code = out_code, text_en = out_en, text_fr = out_fr)
}

# Footnotes read from the per-dimension slot directories, each attributed to its
# owning dimension (`dimension` = the full display name when `dim_names` is
# given, else the descriptor name). Every footnote is stored as an entry of the
# directory of the dimension it annotates -- the linkage the tail text-scan
# cannot provide. `number` keeps the established semantics (position within its
# language, here in slot/directory order). Returns NULL when the slot table is
# absent (caller falls back to the tail scan); an empty list when the
# directories resolve but carry no footnotes.
ivt_f2_dir_footnotes <- function(raw, dim_names = NULL) {
  slots <- ivt_f2_dim_slots(raw)
  if (is.null(slots)) return(NULL)
  if (is.null(dim_names)) {
    d <- ivt_f2_descriptor(raw)
    dim_names <- vapply(d$dims, function(x) x$name, "")
  }
  counts <- c(en = 0L, fr = 0L)
  out <- list()
  resolved <- FALSE
  for (k in seq_along(slots)) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) next
    resolved <- TRUE
    for (r in seq_len(nrow(dir))) {
      len <- dir[r, "len"]
      if (len < 24L) next                          # too short to frame a footnote
      win <- raw[(dir[r, "off"] + 1L):min(length(raw), dir[r, "off"] + len)]
      # cheap byte prefilter: the text-run isolation is too slow to run over every
      # entry of a 6,000-block geography directory.
      if (!length(grepRaw("Footnote", win, fixed = TRUE)) &&
          !length(grepRaw("Renvoi", win, fixed = TRUE))) next
      fns <- ivt_footnote_texts(raw, dir[r, "off"], dir[r, "off"] + len)
      for (f in fns) {
        counts[f$language] <- counts[f$language] + 1L
        out[[length(out) + 1L]] <- list(
          language = f$language, number = counts[[f$language]], text = f$text,
          dimension = if (k <= length(dim_names)) dim_names[[k]] else NA_character_)
      }
    }
  }
  if (!resolved) return(NULL)
  out
}
