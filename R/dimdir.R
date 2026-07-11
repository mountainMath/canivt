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
# header is too short. `m` (the dimension count) can be passed by callers that
# already hold the descriptor -- REQUIRED for the calls made from inside
# `ivt_f2_descriptor()` itself (the count reconciliation), which must not
# re-enter the descriptor parse.
ivt_f2_dim_slots <- function(raw, m = NULL) {
  if (is.null(m)) {
    d <- ivt_f2_descriptor(raw)
    # the 32-dim cap mirrors ivt_f2_decodable(): unsupported container variants
    # misread the descriptor as hundreds of dimensions. Judge by the recovered
    # dimension records, not the header count field (unreliable on some vintages,
    # e.g. 95F0200XDB96003 reads 1026 with 4 clean dimensions).
    m <- if (is.null(d)) 0L else length(d$dims)
  }
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
#
# Memoized per (raw, k): each dimension's directory is consumed by the label,
# ordinal, footnote AND geography readers, so it is decoded once. The result is
# a pure function of the bytes and k (`slots` is deterministic given the
# dimension count, so it does not key the cache).
ivt_f2_dim_dir <- function(raw, k, slots = NULL)
  ivt_memo(raw, paste0("dim_dir_", k),
           function() ivt_f2_dim_dir_impl(raw, k, slots))

ivt_f2_dim_dir_impl <- function(raw, k, slots = NULL) {
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
  if (ok(d)) return(d)
  # some exports (the 2006 custom-order crosstabs cro0172986_ct.7/8) store an
  # ALLOCATED len2 > len that the strict end-of-table sentinel treats as a stop,
  # truncating the read. Retry admitting any `len2 >= len`, but bounded to the
  # slot's declared entry count so the relaxed rule cannot run on into garbage.
  d <- ivt_f2_read_dir_at(raw, sl$ptr, max_entries = want, relaxed = TRUE)
  if (ok(d)) return(d)
  d <- ivt_f2_read_dir_at(raw, rd_u32(raw, sl$ptr), max_entries = want, relaxed = TRUE)
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
  mk <- ivt_f2_dir_marker_entry(raw, nm, dir)
  if (mk == 0L || mk >= nrow(dir)) return(NULL)
  # a data dimension with more than 256 members stores its label blocks CHUNKED,
  # exactly like the chunked geography codebook (98-400-X2016203's 825-member
  # "Selected characteristics": 256-member chunks in growing groups, per group
  # the EN chunk run then the FR chunk run, the trailing partial chunk as a
  # dense block) -- the single-block read below cannot assemble those.
  if (cnt > 256L) {
    ck <- ivt_f2_dim_dir_label_chunks(raw, cnt, dir, mk)
    if (!is.null(ck)) {
      en_first <- ivt_f2_dim_dict_en_first(raw, dir)
      if (is.na(en_first)) en_first <- ivt_f2_label_lang_fallback(nm, ck[[1L]], ck[[2L]])
      en <- if (en_first) ck[[1L]] else ck[[2L]]
      fr <- if (en_first) ck[[2L]] else ck[[1L]]
      return(list(en = en, fr = fr, name_fr = ivt_f2_total_name(fr)))
    }
  }
  # the EN/FR member blocks are the first two member-array entries after it
  cand <- ivt_f2_dir_member_arrays(
    raw, dir, cnt, rows = (mk + 1L):nrow(dir), max_keep = 2L,
    accept = function(t) {
      if (identical(t, as.character(seq_len(cnt)))) return(NULL)  # ordinal block
      if (any(grepl("[[:cntrl:]]", t)) || !all(nzchar(t))) return(NULL)  # garbage
      t
    })
  if (!length(cand)) return(NULL)
  if (length(cand) == 1L)
    return(list(en = cand[[1L]], fr = NULL, name_fr = NA_character_))
  # assign languages by the dictionary schema order (English Desc / Desc Francais)
  en_first <- ivt_f2_dim_dict_en_first(raw, dir)
  if (is.na(en_first)) en_first <- ivt_f2_label_lang_fallback(nm, cand[[1L]], cand[[2L]])
  en <- if (en_first) cand[[1L]] else cand[[2L]]
  fr <- if (en_first) cand[[2L]] else cand[[1L]]
  list(en = en, fr = fr, name_fr = ivt_f2_total_name(fr))
}

# Walk a dimension slot directory's entries for candidate member arrays of
# exactly `cnt` records, calling `accept(t)` on each candidate's values and
# collecting up to `max_keep` accepted results (in directory order). Shared by
# the label and ordinal readers, which differ only in the rows they walk and
# the predicate they accept with.
#
# Values are read STRICT-FIRST: the byte-exact entry parse
# (`ivt_f2_dir_entry_members()`, with the power-of-two slot padding trimmed
# back to `cnt`) supplies them whenever the entry carries a value-block
# framing -- the Pascal run-scanner can misread leading framing bytes as
# records (98-10-0077's Ages) and fragments dense blocks, so it is only the
# fallback. The scanner path keeps its established shape: the largest block of
# cnt..cnt+8 records, sliced to the trailing `cnt`.
ivt_f2_dir_member_arrays <- function(raw, dir, cnt, rows, accept,
                                     max_keep = .Machine$integer.max) {
  out <- list()
  for (r in rows) {
    len <- dir[r, "len"]
    if (len <= 8L || len < cnt + 4L) next          # separators / tiny framing
    t <- NULL
    e <- tryCatch(ivt_f2_dir_entry_members(raw, dir[r, "off"], len),
                  error = function(e) NULL)
    if (!is.null(e)) {
      v <- e$values
      if (!e$dense && length(v) > cnt && all(is.na(v[(cnt + 1L):length(v)])))
        v <- v[seq_len(cnt)]                       # pow-2 slot padding
      if (length(v) == cnt && !anyNA(v)) t <- v
    }
    if (is.null(t)) {                              # run-scanner fallback
      win <- raw[(dir[r, "off"] + 1L):min(length(raw), dir[r, "off"] + len)]
      b <- ivt_find_member_blocks(win, 0L, min_records = 1L)
      if (!length(b)) next
      sz <- vapply(b, function(x) length(x$texts), 1L)
      bi <- which(sz >= cnt & sz <= cnt + 8L)      # + slack for leading framing
      if (!length(bi)) next
      tt <- b[[bi[length(bi)]]]$texts
      t <- tt[(length(tt) - cnt + 1L):length(tt)]  # trailing `cnt` records
    }
    v <- accept(t)
    if (is.null(v)) next
    out[[length(out) + 1L]] <- v
    if (length(out) >= max_keep) break
  }
  out
}

# Language order of a dimension's two member-label blocks when the dictionary
# schema block is absent: decided by content score (`ivt_f2_pick_en()`), loudly
# -- the schema order (English Desc before Desc Francais) is the primary read.
# This is the LOUD counterpart to the geography paths' SILENT primary use of the
# same score: here a schema order exists to prefer, so content scoring is a
# fallback and warns; there block order genuinely varies per group, so it is the
# correct primary read (the philosophy is stated once at `ivt_f2_pick_en()`).
ivt_f2_label_lang_fallback <- function(nm, a, b) {
  en_first <- ivt_f2_pick_en(a, b)$en_first
  ivt_fallback(paste(
    "Dimension {.val {nm}} carries no English Desc/Desc Fran schema block;",
    "its English vs French label blocks were told apart by content score,",
    "not the schema order."))
  en_first
}

# Index of the directory entry holding a dimension's doubled-name marker block.
# Identified STRUCTURALLY: within a slot directory already validated by index +
# `n_entries`, the marker is the entry that OPENS with `81 02 02 00` and carries a
# printable name. Across the whole corpus there is never more than one such entry
# per directory (152 of 155 dimension directories have exactly one; the other 3 --
# the ord-08035 custom export -- have none, exactly where the descriptor name also
# fails to recover), so the marker resolves WITHOUT the descriptor name. That
# demotes the five-heuristic `ivt_f2_descriptor_name()` recovery from load-bearing
# to a mere cross-check for label reads: a dimension whose name is misread still
# gets its labels as long as its slot directory carries the (unique) named marker.
# Some directories also carry a small (len ~16) `81 02 02 00` stub with no name --
# excluded because it yields no printable run. The descriptor name is kept only to
# disambiguate the (never-yet-observed) case of >1 named marker in one directory --
# prefix-matched, or a verbatim >=8-char hit for the SHORT/LONG cro name pair
# ("Characteristics" / "Selected Characteristics"). 0 when no named marker exists
# -- the caller then treats the directory as not resolving this dimension.
ivt_f2_dir_marker_entry <- function(raw, nm, dir) {
  named <- integer(0); named_at <- character(0)
  for (r in seq_len(nrow(dir))) {
    len <- dir[r, "len"]; off <- dir[r, "off"]
    if (len < 12L || len > 4000L) next
    if (off + 4L > length(raw) ||
        as.integer(raw[off + 1L]) != 0x81L || as.integer(raw[off + 2L]) != 0x02L ||
        as.integer(raw[off + 3L]) != 0x02L || as.integer(raw[off + 4L]) != 0x00L) next
    m <- ivt_f2_codebook_dim_markers(raw[(off + 1L):min(length(raw), off + len)], 0L)
    if (!nrow(m)) next
    got <- m$name[!is.na(m$name) & nchar(m$name) >= 3L]
    if (!length(got)) next
    named <- c(named, r); named_at <- c(named_at, got[1L])
  }
  if (length(named) == 1L) return(named[1L])          # the corpus case: unique
  if (!length(named)) return(0L)
  for (i in seq_along(named))                         # disambiguate by name
    if (ivt_f2_name_match(named_at[i], nm) ||
        (!is.na(nm) && nchar(nm) >= 8L && grepl(nm, named_at[i], fixed = TRUE)))
      return(named[i])
  0L
}

# The stored member-slot count and real (non-empty) member count of one
# dimension, read from its slot directory: the first member-array entry
# (`[01 01][u16 payload][u16 n_slots]`) after the dimension's doubled-name
# marker, strict-parsed (`ivt_f2_dir_entry_members()`). `slots` is the block's
# slot count (power-of-two padded at the tail, padding slots are explicit empty
# records -> NA), `count` the last non-empty slot. Used by the descriptor's
# count reconciliation: a descriptor count can never exceed `slots`, so a
# larger one was misread from framing bytes. list(slots, count), NA when the
# directory stores no such block.
ivt_f2_dir_member_count <- function(raw, nm, dir) {
  none <- list(slots = NA_integer_, count = NA_integer_)
  if (is.null(nm) || is.na(nm) || !nzchar(nm)) return(none)
  mk <- ivt_f2_dir_marker_entry(raw, nm, dir)
  if (mk == 0L || mk >= nrow(dir)) return(none)
  for (r in (mk + 1L):nrow(dir)) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 8L || off + len > length(raw)) next
    if (as.integer(raw[off + 1L]) != 0x01L || as.integer(raw[off + 2L]) != 0x01L)
      next
    mem <- tryCatch(ivt_f2_dir_entry_members(raw, off, len),
                    error = function(e) NULL)
    v <- mem$values
    if (is.null(v) || !length(v)) next
    real <- if (all(is.na(v))) 0L else max(which(!is.na(v)))
    return(list(slots = length(v), count = real))
  }
  none
}

# Reconcile descriptor dimension counts against the codebook (called from
# `ivt_f2_descriptor()`). Only the double-01-framed records are reconciled:
# their byte shape is shared between the reference-period record
# [type][count][01][01] ("Year (2)": 0e 02 01 01) and the profile lineage's
# 1-member "Values" placeholder (00 20 01 01), whose count is NOT stored at
# that position -- reading 32 there made 97-570-X1981004's layout mis-nest.
# The dimension's own slot-directory member block decides: when the descriptor
# count exceeds the block's stored slot count (impossible -- slots only pad
# upward), the real member count replaces it. Dimensions whose directory does
# not resolve, and counts the codebook cannot contradict, are left untouched,
# so every validated table is byte-identical through this.
ivt_f2_dim_count_reconcile <- function(raw, dims) {
  amb <- which(vapply(dims, function(d) isTRUE(d$double01), logical(1)))
  if (!length(amb)) return(dims)
  slots <- ivt_f2_dim_slots(raw, m = length(dims))
  if (is.null(slots)) return(dims)
  for (k in amb) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) next
    mc <- ivt_f2_dir_member_count(raw, dims[[k]]$name, dir)
    if (is.na(mc$slots) || mc$slots < 1L) next
    if (dims[[k]]$count <= mc$slots) next        # codebook cannot contradict it
    if (!is.na(mc$count) && mc$count >= 1L) dims[[k]]$count <- mc$count
  }
  dims
}

# Which descriptor dimension is geography? Dimension 1 in every layout except
# the profile-table lineage (97-570-X1981004 / 98F0172X / 95F0170X), which
# stores a 1-member "Values" placeholder first and geography LAST. The
# identification stays metadata-driven: a real geography can never have a
# single member alongside other dimensions, so dimension 1 is accepted outright
# unless its count is 1 -- then each dimension's slot directory is probed for a
# geography codebook signature (`ivt_f2_dir_is_geo()`): the geography attribute
# schema (a dictionary block naming GEO_NAME, modern DGUID tables) or inline
# combined-format member blocks ("<name> (<code>) <flag>", the pre-DGUID
# codebook). Falls back to dimension 1 (the positional rule) when nothing
# resolves. No decoder logic branches on this beyond which dimension gets the
# geography role (slug/labels/codebook); the cell decode itself is
# dimension-agnostic.
ivt_f2_geo_dim_index <- function(raw, d = NULL)
  ivt_memo(raw, "geo_dim_index", function() ivt_f2_geo_dim_index_impl(raw, d))

ivt_f2_geo_dim_index_impl <- function(raw, d = NULL) {
  if (is.null(d)) d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(1L)
  cnt1 <- suppressWarnings(as.integer(d$dims[[1L]]$count))
  if (is.na(cnt1) || cnt1 > 1L || length(d$dims) == 1L) return(1L)
  slots <- ivt_f2_dim_slots(raw, m = length(d$dims))
  if (is.null(slots)) return(1L)
  for (k in seq_along(d$dims)) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (!is.null(dir) && ivt_f2_dir_is_geo(raw, dir)) return(k)
  }
  1L
}

# Does this dimension slot directory hold a GEOGRAPHY codebook? TRUE when it
# lists (a) a dictionary/schema block naming the GEO_NAME attribute (the modern
# DGUID layout's geography attribute schema -- data-dimension dictionaries name
# Code / English Desc / Desc Francais instead), or (b) a member array whose
# records parse as the inline combined geography format ("<name> (<code>)
# [<type>] <flag>", IVT_F2_INLINE_PAT). Only the first few member arrays are
# strict-parsed; name/code sibling arrays that do not match the pattern are
# skipped, not disqualifying.
ivt_f2_dir_is_geo <- function(raw, dir, max_member_entries = 6L) {
  n <- length(raw); tried <- 0L
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 8L || off < 0 || off + len > n) next
    b0 <- as.integer(raw[off + 1L]); b1 <- as.integer(raw[off + 2L])
    if (b0 == 0x81L && b1 == 0x02L && len <= 4000L) {
      txt <- raw_to_latin1(raw[(off + 1L):(off + len)])
      if (grepl("GEO_NAME", txt, fixed = TRUE)) return(TRUE)
    } else if (b0 == 0x01L && b1 == 0x01L && len >= 24L &&
               tried < max_member_entries) {
      tried <- tried + 1L
      mem <- tryCatch(ivt_f2_dir_entry_members(raw, off, len),
                      error = function(e) NULL)
      v <- mem$values
      v <- if (is.null(v)) character(0) else trimws(v[!is.na(v)])
      v <- v[nzchar(v)]
      if (length(v) >= 3L) {
        probe <- utils::head(v, 32L)
        if (sum(grepl(IVT_F2_INLINE_PAT, probe, perl = TRUE)) >=
            max(3L, 0.6 * length(probe)))
          return(TRUE)
      }
    }
  }
  FALSE
}

# Assemble a >256-member data dimension's two label runs from its slot
# directory: chunks of 256 members (last partial) in growing groups of G chunks
# (`ivt_f2_geo_group_sizes()`, the same 1, 1, 2, 4, ... sequence the chunked
# geography codebook uses), each group storing its G language-A chunk blocks
# then its G language-B blocks, in directory order after the doubled-name
# marker entry. Blocks are strict-parsed (`ivt_f2_dir_entry_members()`; the
# trailing partial chunk is a dense `81 01` block, which the parser also
# handles); a candidate entry is consumed only when its record count equals
# the next expected chunk size, so interleaved framing blocks are skipped
# structurally. Returns list(a, b) (the two runs in storage order; language
# assignment is the caller's job) or NULL when the chunk walk does not close.
# Validated on 98-400-X2016203's "Selected characteristics (825)": 3 groups
# (1, 1, 2 chunks), EN/FR runs of 256 + 256 + 256 + 57, every label exact
# against the B2020 viewer's row list.
ivt_f2_dim_dir_label_chunks <- function(raw, cnt, dir, mk) {
  sizes <- ivt_f2_geo_group_sizes(cnt)
  chunk_len <- function(k) min(256L, cnt - 256L * (k - 1L))
  vals <- list()
  for (r in (mk + 1L):nrow(dir)) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 12L || off + len > length(raw)) next
    b0 <- as.integer(raw[off + 1L]); b1 <- as.integer(raw[off + 2L])
    if (!(b1 == 0x01L && (b0 == 0x01L || b0 == 0x81L))) next
    mem <- tryCatch(ivt_f2_dir_entry_members(raw, off, len),
                    error = function(e) NULL)
    if (is.null(mem$values) || !length(mem$values)) next
    vals[[length(vals) + 1L]] <- mem$values
  }
  a <- character(0); b <- character(0)
  ei <- 1L; k <- 0L
  take_run <- function(need) {
    # consume the next blocks whose record counts match `need` (in order),
    # skipping non-matching framing entries between runs
    run <- character(0)
    for (want in need) {
      while (ei <= length(vals) && length(vals[[ei]]) != want) ei <<- ei + 1L
      if (ei > length(vals)) return(NULL)
      run <- c(run, vals[[ei]]); ei <<- ei + 1L
    }
    run
  }
  for (G in sizes) {
    need <- vapply(k + seq_len(G), chunk_len, 1L)
    ra <- take_run(need); if (is.null(ra)) return(NULL)
    rb <- take_run(need); if (is.null(rb)) return(NULL)
    a <- c(a, ra); b <- c(b, rb)
    k <- k + G
  }
  if (length(a) != cnt || length(b) != cnt) return(NULL)
  list(a, b)
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
  cand <- ivt_f2_dir_member_arrays(
    raw, dir, cnt, rows = seq_len(nrow(dir)),
    accept = function(t) {
      iv <- suppressWarnings(as.integer(t))
      if (anyNA(iv) || !identical(sort(iv), seq_len(cnt))) return(NULL)
      iv
    })
  if (length(cand)) cand[[length(cand)]] else NULL   # the LAST permutation wins
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
  gd <- ivt_f2_geo_dim_index(raw, d)
  out <- vector("list", length(d$dims))
  for (k in setdiff(seq_along(d$dims), gd)) {
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
  gd <- ivt_f2_geo_dim_index(raw, d)
  out <- vector("list", length(d$dims))
  for (k in setdiff(seq_along(d$dims), gd)) {
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
# c(start, end) or NULL when the geography dimension's directory does not resolve.
ivt_f2_geo_dir_span <- function(raw) {
  d <- ivt_f2_dim_dir(raw, ivt_f2_geo_dim_index(raw))
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
      en_first <- ivt_f2_pick_en(a, b)$en_first
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

# Decode a footnote member bitmap (the `84 01`-framed dense record that precedes a
# dimension's MEMBER footnotes) into the 1-based member positions it flags. Format
# is the standard dense value block: `[84 01][u16 nbits][ceil(nbits/16)*2-byte
# bitstream][int32 values]`. The bitstream is read with the presence convention --
# byte-pair-swapped, then MSB-first -- so a set bit at 0-based position p means
# member p+1 carries a footnote (the trailing int32s are block-index framing, not
# used). Returns integer(0) for a non-bitmap window.
ivt_f2_footnote_bitmap <- function(win) {
  if (length(win) < 6L ||
      win[1] != as.raw(0x84L) || win[2] != as.raw(0x01L)) return(integer(0))
  nbits <- as.integer(win[3]) + 256L * as.integer(win[4])
  nby <- ceiling(nbits / 16) * 2L                    # bitstream padded to u16
  if (nbits < 1L || 4L + nby > length(win)) return(integer(0))
  bm <- as.integer(win[5:(4L + nby)])
  which(ivt_bits_pairswap_msb(bm, seq_len(nbits) - 1L))
}

# Footnotes read from the per-dimension slot directories, each attributed to its
# owning dimension AND, within the dimension, to a scope: a MEMBER note (annotates
# one member) or a DIMENSION note (annotates the whole dimension -- geography
# included). The linkage is structural: each dimension's footnote region opens with
# a `84 01` member bitmap (an EN copy and an identical FR copy) listing which
# members carry a member note, in member order; the footnote text entries then
# follow in that same order -- the first `popcount(bitmap)` per language are the
# member notes (assigned to the bitmapped members in order), the rest are dimension
# notes. Validated against StatCan's own WDS footnote links (dimensionPositionId /
# memberId) on 98-10-0241/0023/0129/0077 -- every (dimension, member) target exact.
# Each record carries `scope` ("member"/"dimension"), `dimension` (the full display
# name when `dim_names` is given, else the descriptor name) and `member_id` (the
# 1-based member id for member notes, NA otherwise). `number` keeps the established
# semantics (position within its language, in slot/directory order). Returns NULL
# when the slot table is absent (caller falls back to the tail scan); an empty list
# when the directories resolve but carry no footnotes.
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
    members <- integer(0); seen_bitmap <- FALSE
    seq_lang <- c(en = 0L, fr = 0L)                  # member-notes seen, per language
    dim_name <- if (k <= length(dim_names)) dim_names[[k]] else NA_character_
    for (r in seq_len(nrow(dir))) {
      len <- dir[r, "len"]
      off <- dir[r, "off"]
      win <- raw[(off + 1L):min(length(raw), off + len)]
      # the member bitmap opens the footnote region (EN then an identical FR copy);
      # take the member set from the first one encountered.
      if (length(win) >= 6L && win[1] == as.raw(0x84L) && win[2] == as.raw(0x01L)) {
        if (!seen_bitmap) { members <- ivt_f2_footnote_bitmap(win); seen_bitmap <- TRUE }
        next
      }
      if (len < 24L) next                            # too short to frame a footnote
      # cheap byte prefilter: the text-run isolation is too slow to run over every
      # entry of a 6,000-block geography directory. Both footnote framings: the
      # modern "Footnote N"/"Renvoi N" and the 1981 profile "FOOTNOTE:"/"RENVOI :".
      if (!length(grepRaw("Footnote", win, fixed = TRUE)) &&
          !length(grepRaw("Renvoi", win, fixed = TRUE)) &&
          !length(grepRaw("FOOTNOTE", win, fixed = TRUE)) &&
          !length(grepRaw("RENVOI", win, fixed = TRUE))) next
      fns <- ivt_footnote_texts(raw, off, off + len)
      for (f in fns) {
        counts[f$language] <- counts[f$language] + 1L
        seq_lang[f$language] <- seq_lang[f$language] + 1L
        i <- seq_lang[[f$language]]
        is_member <- i <= length(members)
        out[[length(out) + 1L]] <- list(
          language = f$language, number = counts[[f$language]], text = f$text,
          scope = if (is_member) "member" else "dimension",
          dimension = dim_name,
          member_id = if (is_member) members[[i]] else NA_integer_)
      }
    }
  }
  if (!resolved) return(NULL)
  out
}

# Table-level (cube) footnotes: the notes that annotate the whole table rather than
# any one dimension. They are stored in the master-directory identity blob (the
# same EN/FR sections that carry the product id + title), framed with the modern
# "Footnote N"/"Renvoi N" markers -- NOT in any dimension slot directory. The
# marker sits mid-blob (after the "Product ID / Title / Footnotes :" preamble), so
# it is located by a numbered-marker regex (which ignores the bare "Footnotes :"
# section header that empty-note tables still carry). scope = "table", with no
# dimension / member. Returns list() when the table carries none.
ivt_f2_table_footnotes <- function(raw) {
  md <- ivt_f2_master_dir(raw)
  if (is.null(md)) return(list())
  marker <- "(Footnote|Renvoi)[[:space:]]*([0-9]+)[[:space:]]*[\r\n]"
  out <- list()
  for (r in seq_len(nrow(md))) {
    off <- md[r, "off"]; len <- md[r, "len"]
    if (len < 24L || off + len > length(raw)) next
    txt <- raw_to_latin1(raw[(off + 1L):(off + len)])
    m <- gregexpr(marker, txt, perl = TRUE)[[1]]
    if (m[1] == -1L) next
    starts <- as.integer(m); ml <- attr(m, "match.length")
    for (i in seq_along(starts)) {
      lang <- if (substr(txt, starts[i], starts[i] + 7L) == "Footnote") "en" else "fr"
      body_start <- starts[i] + ml[i]
      body_end <- if (i < length(starts)) starts[i + 1L] - 1L else nchar(txt)
      body <- trimws(gsub("[[:space:]]+", " ",
                          gsub("\u00a0", " ", substr(txt, body_start, body_end))))
      if (nzchar(body))
        out[[length(out) + 1L]] <- list(language = lang, text = body,
          scope = "table", dimension = NA_character_, member_id = NA_integer_)
    }
  }
  out
}
