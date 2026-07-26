#' Header per-dimension directory slot table
#'
#' The fixed header carries one 14-byte record per descriptor dimension (in
#' descriptor order, geography = dimension 1) at `@824 + 14*(k-1)`:
#'
#'     [u32 dir_ptr][u32 alloc][u32 n_entries][u16 flag]
#'
#' `dir_ptr` points at that dimension's **block directory** -- a table of the
#' familiar 8-byte entries `[u32 off][u16 len][u16 len]` (the same shape as the
#' page directory) -- either directly, or (the big chunked geography directories,
#' e.g. 98-10-0023's 6,244 entries) via a small struct whose first u32 is the
#' directory pointer. `n_entries` is the entry count (the decoded table may run
#' up to a few entries short when null slots are skipped), which makes the slot
#' self-validating.
#'
#' All four fields are resolved except one flag; the decoder reads `dir_ptr` and
#' `n_entries`, and cross-checks with `alloc`:
#'  - `alloc` (@+4, once the `?` field): the block directory's power-of-two
#'    ALLOCATED slot capacity, `== nextpow2(n_entries)` on 243/243 corpus slots
#'    (n_entries is the used count). `ivt_f2_dim_dir_impl()` uses it to validate
#'    n_entries -- a slot whose `alloc != nextpow2(n_entries)` is a misread and is
#'    rejected before the directory is read.
#'  - `flag` (@+12): 0 on 240/243 corpus slots, 1 on exactly the three
#'    double-indirection chunked-DGUID GEOGRAPHY directories (98-10-0023/-0129/-0174).
#'    `ivt_f2_dim_dir_impl()` uses it to DIRECT the indirection-depth order (flag != 0
#'    -> try `slot -> struct -> directory` first; else the direct read first),
#'    replacing the old direct-first trial-and-error with a metadata-driven choice.
#'    The precise semantic is still inferred from three same-valued cases and
#'    unproven, so the other depth stays a fallback and the `n_entries` check gates
#'    every candidate -- a mis-flag reorders attempts, it cannot mis-read. The one
#'    residual.
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
#' TWO THINGS THIS TABLE IS NOT (both have bitten a decode, keep them in mind):
#'
#'  - **`n_entries` is a BLOCK count, NOT the member count.** The members live
#'    *inside* one or two of the blocks (the EN and FR label arrays, each a single
#'    entry holding every member); the rest of the `n_entries` blocks are
#'    member-count-independent (schema, doubled-name marker, ordinal array, note
#'    blocks, `84 01` note bitmap, `04 01` separators). There is no relation
#'    between the two numbers -- ucr2.2_3-2006: Offence 24 entries / 30 members,
#'    Geography 12 / 1, Year 4 / 1. The member count comes from the DESCRIPTOR,
#'    reconciled against the member ARRAY (`ivt_f2_dir_member_count()` counts the
#'    records inside the `01 01`/`81 01` block), NEVER from `n_entries`. Passing
#'    `n_entries` as the count mis-nests the layout (the first UCR attempt decoded
#'    24 cells against a 30-bit presence record).
#'  - **A dimension's blocks are individually addressed, NOT one contiguous
#'    region.** Each `[off, off+len)` is exact, but the blocks are frequently
#'    non-adjacent and INTERLEAVED across dimensions (98-10-0241's seven dimensions'
#'    `[min, max)` envelopes overlap; the chunked geography of 98-10-0023 is split
#'    into non-adjacent regions whose envelope brackets the small data dims). So a
#'    dimension's codebook is the exact SET of its `n_entries` blocks -- never treat
#'    `[min off, max off+len)` as one dimension's byte range, and do not assume the
#'    blocks tile without gaps.
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
                     alloc = rd_u32(raw, s + 4L),
                     n_entries = rd_u32(raw, s + 8L),
                     # the u16 @+12 flag: 1 on the double-indirection chunked-geography
                     # directories (dir_ptr -> struct -> directory), 0 on the direct ones.
                     # Read defensively so a slot truncated at EOF still yields ptr/alloc/n.
                     flag = if (s + 14L <= n) rd_u16(raw, s + 12L) else NA_integer_)
  }
  out
}

# Resolve dimension k's block directory from its header slot. Three header fields
# drive it, all metadata: `alloc` (@+4) VETOES a misread slot up front
# (alloc != nextpow2(n_entries)); `n_entries` (@+8) validates the decode (the
# parsed table must reach it, up to 4 skipped null slots, and not run past it, so a
# slot whose pointer means something else on some layout is rejected rather than
# misread); and `flag` (@+12) directs which of the two indirection depths (slot ->
# directory, vs slot -> struct -> directory) to try FIRST -- the double-indirection
# chunked-geography directories carry flag != 0. Returns the (off, len) entry
# matrix, or NULL.
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
  # Cross-check n_entries against the slot's `alloc` field (@+4): the block
  # directory is allocated a power-of-two number of slots and `alloc ==
  # nextpow2(n_entries)` holds on every corpus slot (243/243, all vintages). A slot
  # whose bytes do not satisfy this is a misread (its pointer means something else
  # on an unknown layout), so reject it rather than trust its n_entries -- the
  # caller then falls back. Guarded on a PRESENT (non-zero) alloc so that should a
  # future vintage leave the field zero, the check simply abstains rather than
  # wrongly vetoing a good slot.
  if (!is.null(sl$alloc) && !is.na(sl$alloc) && sl$alloc > 0L &&
      sl$alloc != ivt_f2_nextpow2(sl$n_entries)) return(NULL)
  want <- as.integer(sl$n_entries)
  ok <- function(d) !is.null(d) && nrow(d) <= want && nrow(d) >= max(1L, want - 4L)
  # A directory can be COMPLETE yet shorter than the 4-null tolerance: the earlier
  # `02 00 20 00` survey generation (PRSIC1dec1999's "Employment size ranges") lays
  # out its `want` slots with several INTERIOR null holes (14 real entries across 19
  # slots -> 5 holes). Accept such a read when EVERY one of the `want` declared slots
  # is either a well-formed entry we captured or an explicit `(0,0)` null -- the
  # directory is then fully accounted for (a wrong pointer would show garbage slots,
  # so this cannot admit a misread). `n` bounds the scan.
  n <- length(raw)
  complete_with_holes <- function(d, p) {
    if (is.null(d) || nrow(d) > want) return(FALSE)
    holes <- 0L
    for (i in seq_len(want)) {
      base <- as.integer(p) + (i - 1L) * 8L
      if (base + 8L > n) return(FALSE)
      off <- rd_u32(raw, base); a <- rd_u16(raw, base + 4L)
      if (is.na(off) || is.na(a)) return(FALSE)
      if (off == 0L && a == 0L) holes <- holes + 1L
    }
    nrow(d) + holes == want
  }
  # The two indirection depths: DIRECT (slot -> directory) and INDIRECT (slot ->
  # one-u32 struct -> directory). The slot's `flag` (@+12) is METADATA that says
  # which layout this is: flag != 0 is the double-indirection chunked-geography
  # directory (98-10-0023/-0129/-0174), flag 0 the direct one. Use it to try the
  # declared depth FIRST -- so the big chunked geography's directory is located by
  # the file's own flag rather than by a direct read that must first fail the
  # n_entries check. The other depth stays as a fallback (the flag's precise
  # semantic is inferred, not proven, so a mis-flag still cannot mis-read: `ok()`
  # gates every candidate), and a NA/absent flag keeps the historical direct-first
  # order. `alloc` above already vetoed a misread slot before we get here.
  direct_ptr   <- sl$ptr
  indirect_ptr <- rd_u32(raw, sl$ptr)               # the indirection struct's first u32
  indirect_first <- !is.null(sl$flag) && !is.na(sl$flag) && sl$flag != 0L
  ptrs <- if (indirect_first) c(indirect_ptr, direct_ptr) else c(direct_ptr, indirect_ptr)
  # strict read first (max_entries = want + 4, honouring the end-of-table sentinel),
  # then the relaxed read (bounded to `want`) for exports whose blocks store an
  # ALLOCATED len2 > len the strict sentinel would stop on (cro0172986_ct.7/8).
  # A read that reaches the DECLARED n_entries wins outright at its precedence
  # rank; a SHORT read (n_entries allows up to 4 skipped null slots) is kept only
  # as the best-so-far and returned after every candidate has been tried -- the
  # `02 00 20 00` survey directories mix `used < allocated` entries mid-table
  # (00060117's reference dimension: strict stops at entry 2 of 4, hiding the
  # member code array that sizes the dimension), so an early truncated read must
  # not shadow a later complete one.
  best <- NULL
  for (relaxed in c(FALSE, TRUE)) {
    cap <- if (relaxed) want else want + 4L
    for (p in ptrs) {
      if (is.na(p) || p < 1L) next
      d <- ivt_f2_read_dir_at(raw, p, max_entries = cap, relaxed = relaxed)
      if (is.null(d) || nrow(d) > want) next
      if (nrow(d) >= want || complete_with_holes(d, p)) return(d)
      if (!ok(d)) next
      if (is.null(best) || nrow(d) > nrow(best)) best <- d
    }
  }
  best
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
  # The survey generations' dictionary uses different field vocabularies --
  # "Label" (EN) / "Etiquette" (FR) (00060117's Quantifier, stored in a schema
  # CONTINUATION block without the `81 02` tag), or the single-letter fields
  # "E" / "F" right after "Code" (tb611996's dimensions: Pascal records
  # `01 45` / `01 46` inside the `.. 22 00` schema block) -- so this second
  # pass scans every short entry and drops the tag gate. Same structural rule:
  # the language of the two member-label blocks is the dictionary's field order.
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; ln <- dir[r, "len"]
    if (ln < 12L || ln > 400L || off + ln > length(raw)) next
    win <- raw[(off + 1L):(off + ln)]
    txt <- raw_to_latin1(win)
    ie <- regexpr("\\bLabel\\b", txt)
    ifr <- regexpr("\\bEtiquette\\b", txt, ignore.case = TRUE)
    if (ie > 0L && ifr > 0L) return(ie < ifr)
    # PRSIC1dec1999's "English Label" / "Etiquette" pair: the EN field name is
    # immediately followed by binary bytes that decode to word chars ("English
    # Labelco", "...nd"), breaking the `\bLabel\b` trailing boundary above, so
    # anchor on the "English Label" phrase (leading boundary only).
    ie <- regexpr("English Label", txt)
    ifr <- regexpr("\\bEtiquette\\b", txt, ignore.case = TRUE)
    if (ie > 0L && ifr > 0L) return(ie < ifr)
    ie <- regexpr("Description_E", txt)                # 00060208-style field pair
    ifr <- regexpr("Description_F", txt)
    if (ie > 0L && ifr > 0L) return(ie < ifr)
    # EMPLOY1-style "Desc" / "Descf" pair ("_Description" has no word boundary
    # before "Desc", so it cannot shadow the standalone field name)
    ie <- regexpr("\\bDesc\\b", txt)
    ifr <- regexpr("\\bDescf\\b", txt)
    if (ie > 0L && ifr > 0L) return(ie < ifr)
    # the remaining survey-generation vocabularies live inside a tagged
    # `81 02 <n> 00 22 00` schema block; the tag gate keeps member-label text
    # (a language-of-instruction dimension's "English"/"French" members, say)
    # from ever matching these looser word pairs
    if (ln >= 8L && win[1] == as.raw(0x81) && win[2] == as.raw(0x02) &&
        win[5] == as.raw(0x22) && win[6] == as.raw(0x00)) {
      # the `04`-gen "Description" / "Description_FRA" pair (LFHR/agriculture/
      # justice: h2530002, table_5_c/_6_c, 00040200/07/31, ucr2.2). Leading
      # boundary only: the field-struct bytes after a name can decode to word
      # chars ("Descriptionarge" -- the "English Labelco" phenomenon above), so
      # a trailing `\b` misses bled names. The lookbehind excludes the sparse
      # "_Description" notes field; the English position is any occurrence that
      # is not the "Description_FRA" field itself.
      ifr <- regexpr("Description_FRA", txt)
      if (ifr > 0L) {
        starts <- gregexpr("(?<![_A-Za-z])Description", txt, perl = TRUE)[[1L]]
        en_pos <- setdiff(starts[starts > 0L], ifr)
        if (length(en_pos)) return(min(en_pos) < ifr)
      }
      # the accs justice-survey "English" / "French" | "Francais" pair
      # (leading-boundary only, bleed-tolerant as above)
      ie <- regexpr("(?<![A-Za-z])English", txt, perl = TRUE)
      ifr <- regexpr("(?<![A-Za-z])(French|Fran[\u00e7c]ais)", txt, perl = TRUE)
      if (ie > 0L && ifr > 0L) return(ie < ifr)
      # the single-letter E/F fields (the Pascal pair `01 45`/`01 46` is too
      # short to trust outside the tagged block)
      pe <- grepRaw(as.raw(c(0x01, 0x45)), win, fixed = TRUE)
      pf <- grepRaw(as.raw(c(0x01, 0x46)), win, fixed = TRUE)
      if (length(pe) && length(pf)) return(pe[1] < pf[1])
    }
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
  nm <- dim$name
  if (is.null(nm) || is.na(nm) || !nzchar(nm)) return(NULL)
  # delegate to the unified per-dimension member reader (dim-members.R): it collects
  # the clean member-value runs, isolates the ordinal (Code) run, and assigns the two
  # label runs EN/FR by the dictionary schema order -- the same logic this function
  # used to carry inline, now shared with the geography read. Repackage its tibble as
  # the historical `list(en, fr, name_fr)` the label consumers expect.
  m <- ivt_f2_dim_members_from_dir(raw, dim, dir, include_notes = FALSE)
  if (is.null(m) || is.null(m[["label_en"]])) return(NULL)
  # the per-member `_Description` prose (the indicator definition on the facet /
  # quantity dimension of the 02-gen survey tables); NULL on dimensions that carry none.
  sk <- ivt_f2_dim_slot_keep(dim, as.integer(dim$count))
  desc <- ivt_f2_dim_prose_texts(raw, dir, sk$n)
  if (!is.null(desc) && !is.null(sk$keep) && length(desc$en) == sk$n)
    desc <- list(en = desc$en[sk$keep], fr = desc$fr[sk$keep])
  list(en = m[["label_en"]],
       fr = m[["label_fr"]],                         # NULL when the column is absent
       name_fr = attr(m, "name_fr", exact = TRUE),
       desc_en = if (!is.null(desc)) desc$en else NULL,
       desc_fr = if (!is.null(desc)) desc$fr else NULL)
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
    # footnote / note TEXT blobs (`[01 01][u16 len-4][01]<latin1, no NUL>`) reuse
    # the plain-array tag and can shed prose fragments that pass as a short
    # member run (00060123's 2-member ANNUAL grabbed two footnote halves) --
    # the same structural recognizer the geography attribute walk uses
    if (ivt_f2_dir_is_text_block(raw, dir[r, "off"], len)) next
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
# The 2016 custom-extract lineage (CRO0163850 / CRO0166131) frames its
# per-dimension name marker with sub-code `81 02 01 00` (not `02`), storing the
# name TWICE as `<display name>[01 .. 32]<full description>` -- a short display
# label, then a `0x32`-tagged separator, then the long description. Locate that
# entry in a slot directory and return list(row, name = the display label), or
# NULL. The `0x32`-before-the-second-copy signature is required so this cannot
# match a one-field schema block (`81 02 01 00` "Code" ...): a genuine name
# marker always carries the doubled name. Used only as a fallback where the
# standard `81 02 02 00` marker is absent, so the validated `02` corpus is
# untouched.
ivt_f2_dir_name_marker01 <- function(raw, dir) {
  n <- length(raw)
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 20L || len > 4000L || off < 0L || off + len > n) next
    b <- as.integer(raw[(off + 1L):(off + 4L)])
    if (!(b[1L] == 0x81L && b[2L] == 0x02L && b[3L] == 0x01L && b[4L] == 0x00L)) next
    seg <- as.integer(raw[(off + 1L):(off + len)])
    pr <- seg >= 32L & seg <= 126L
    rl <- rle(pr); ends <- cumsum(rl$lengths); starts <- ends - rl$lengths + 1L
    runs <- which(rl$values & rl$lengths >= 3L)
    if (length(runs) < 2L) next                        # need the name + its copy
    e1 <- ends[runs[1L]]                               # last byte of the display name
    s2 <- starts[runs[2L]]                             # first byte of the copy
    if (s2 > e1 + 6L) next                             # the copy follows closely
    # the separator between the two names starts 0x01 and ends in the 0x32 copy
    # tag; 0x32 is itself printable ('2'), so it merges onto the copy's run --
    # the separator therefore runs from just past name1 up to and INCLUDING s2.
    sep <- seg[(e1 + 1L):s2]
    if (sep[1L] != 0x01L || sep[length(sep)] != 0x32L) next
    return(list(row = r, name = trimws(intToUtf8(seg[starts[runs[1L]]:e1]))))
  }
  NULL
}

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
  if (!length(named)) {                               # no 81 02 02 00 marker:
    m01 <- ivt_f2_dir_name_marker01(raw, dir)         # try the 01-subcode variant
    return(if (is.null(m01)) 0L else m01$row)
  }
  for (i in seq_along(named))                         # disambiguate by name
    if (ivt_f2_name_match(named_at[i], nm) ||
        (!is.na(nm) && nchar(nm) >= 8L && grepl(nm, named_at[i], fixed = TRUE)))
      return(named[i])
  0L
}

# The display name from dimension k's slot-directory name marker (standard
# `81 02 02 00`, else the `81 02 01 00` variant), read positionally -- no
# descriptor required, so it is safe to call from within the descriptor parse
# (pass `slots`). Returns the name or NA.
ivt_f2_dim_marker_name <- function(raw, k, slots) {
  dir <- ivt_f2_dim_dir(raw, k, slots)
  if (is.null(dir)) return(NA_character_)
  mk <- ivt_f2_dir_marker_entry(raw, NA_character_, dir)
  if (mk <= 0L || mk > nrow(dir)) return(NA_character_)
  off <- dir[mk, "off"]; len <- dir[mk, "len"]
  m <- ivt_f2_codebook_dim_markers(raw[(off + 1L):min(length(raw), off + len)], 0L)
  got <- m$name[!is.na(m$name) & nchar(m$name) >= 3L]
  if (length(got)) {
    nm <- got[1L]
    # the survey-generation `81 02 02 00 56 00` name marker doubles the name with
    # a '2' separator per language ("Year2YearAnnées2Années"); the doubled-name
    # splitter does not fire on it, so clean it to the leading name here (the same
    # `ivt_f2_02_name_clean()` the `02`-gen name reader applies). Gated on the
    # `56 00` sub-marker so ordinary names carrying a '2' are untouched.
    if (off + 5L <= length(raw) && as.integer(raw[off + 5L]) == 0x56L)
      nm <- ivt_f2_02_name_clean(nm)
    return(nm)
  }
  m01 <- ivt_f2_dir_name_marker01(raw, dir[mk, , drop = FALSE])
  if (!is.null(m01)) m01$name else NA_character_
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
# `ivt_f2_descriptor()`). Two shapes are reconciled:
#
# (1) DOUBLE-01-framed records: their byte shape is shared between the
# reference-period record [type][count][01][01] ("Year (2)": 0e 02 01 01) and
# the profile lineage's 1-member "Values" placeholder (00 20 01 01), whose count
# is NOT stored at that position -- reading 32 there made 97-570-X1981004's
# layout mis-nest.
#
# (2) COUNT == 0 records: a real dimension always has >= 1 member, so a zero
# descriptor count is always a framing misread. The older `04 00 20 00` survey
# tables (UCR / justice / LFHR lineage, single-area single-year cuts) frame a
# trivial reference dimension's count where the previous block's tail bytes sit,
# yielding 0 -- e.g. ucr2.2_3-2006's "Year" (member "2006") reads `00 20 01`,
# count byte 0.
#
# The dimension's own slot-directory member block decides: when the descriptor
# count exceeds the block's stored slot count (impossible -- slots only pad
# upward) OR is zero, the real member count replaces it. A count-0 dimension
# whose codebook stores no member array at all (the trivial single-member
# reference dimension: no `[01 01]` array, no ordinal block) defaults to 1,
# LOUDLY. Dimensions whose directory does not resolve, and positive counts the
# codebook cannot contradict, are left untouched, so every validated table is
# byte-identical through this.
ivt_f2_dim_count_reconcile <- function(raw, dims) {
  slots <- ivt_f2_dim_slots(raw, m = length(dims))
  if (is.null(slots)) return(dims)
  dims <- ivt_f2_dim_slot_declared(raw, dims, slots)
  dims <- ivt_f2_dim_slot_expand(raw, dims, slots)
  # A CHUNKED dimension (a >256-member geography / profile / classification) reads
  # WRONG on the generic descriptor path -- the codebook stores it as 256-member
  # chunks and the descriptor either caps at the first block (count == 256: the 2001
  # F-series 95F03xx/95f04xx, the 2006 97-554 crosstabs) OR reports the CHUNK COUNT
  # in place of the member count (the 1991 enumeration-area census tables, byte-0
  # == 0x04: N9101/PID=128 geography descriptor count 52 == its 52 full 256-member
  # chunks, true member count 13372). Recover the true count from the chunk-run
  # geometry (`ivt_f2_slot_chunked_count()`), which is AUTHORITATIVE and SELF-GATING:
  # it returns NA unless the codebook physically stores >= 2 full 256-member arrays
  # plus a consistent trailing partial, so a single-chunk (<= 256-member) dimension
  # is never touched and no count is fabricated -- the members it counts are all
  # present in the file. Trust it over the descriptor whenever it exceeds the stated
  # count (never when it is equal or smaller: a correctly-read chunked count, or a
  # descriptor OVER-count, is left to the double-01 reconcile below). This is the
  # generic-path analogue of the recovery already wired into `ivt_f2_descriptor_02()`
  # for the byte-0 == 0x02 generation; without it the layout under-spans the page
  # directory and the file preflight-rejects. LOUD (canivt_chunked_count).
  for (k in seq_along(dims)) {
    c0 <- as.integer(dims[[k]]$count)
    if (is.na(c0) || isTRUE(dims[[k]]$double01)) next
    dir <- ivt_f2_dim_dir(raw, k, slots)
    cc <- tryCatch(ivt_f2_slot_chunked_count(raw, dir), error = function(e) NA_integer_)
    if (!is.na(cc) && cc > c0) {
      nm <- dims[[k]]$name; if (is.null(nm) || is.na(nm)) nm <- "?"
      ivt_fallback(sprintf(paste(
        "Dimension %d (\"%s\") descriptor count %d is contradicted by a chunked",
        "codebook; its true member count (%d) was recovered from the chunk-run",
        "geometry."), k, nm, c0, cc), class = "canivt_chunked_count")
      dims[[k]]$count <- as.integer(cc)
      # a chunk run that reaches PAST the declared slot table means that table was
      # block-local after all -- drop the slot positions it supplied (no corpus
      # table takes this branch; it keeps the two witnesses from disagreeing silently)
      dims[[k]]$slots <- NULL; dims[[k]]$slot_used <- NULL; dims[[k]]$declared <- NULL
    }
  }
  # UNDER-DECLARED counts, caught by the dimension's own DECLARED SLOT ALLOCATION.
  # The `81 02 <alloc> 16 00` member-code block states how many slots the container
  # allocated for the dimension, and the whole page geometry is padded to it: the
  # allocation is `nextpow2(members)` on every validated table, never wildly larger
  # (measured across the corpus: `alloc <= 2 * nextpow2(count)` everywhere). So an
  # allocation FOUR times the power-of-two capacity the descriptor count needs is
  # not slack -- it is the file declaring more members than the descriptor record
  # was read to hold (the SP3/RHUXA9 profile lineage: Geography read as 5 members,
  # allocated 32, with 30 labels in its codebook). The replacement count is the
  # codebook member array's own length (`ivt_f2_dir_member_count()`), not the
  # allocation: the array is the members themselves. Gated hard -- the allocation
  # must be 4x over, the codebook must hold MORE members than declared, and they
  # must fit the allocation -- so a merely generous allocation, a deleted slot
  # (handled above by `ivt_f2_dim_slot_expand()`) or an over-long label array (the
  # accs "Offences" block, 64 label records for 40 members, allocated 64) never
  # fires. This runs BEFORE the double-01 reconcile below and covers those records
  # too: the SP3/RHUXA9 geography record is itself double-01 framed (`1e 05 01 01`),
  # and its "5" is not a member count at all -- the allocation is what exposes it,
  # where the double-01 rule alone keeps any positive count the slot table can hold.
  # LOUD (canivt_underdeclared_count).
  for (k in seq_along(dims)) {
    c0 <- as.integer(dims[[k]]$count)
    if (is.na(c0) || c0 < 1L || isTRUE(dims[[k]]$declared)) next
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) next
    alloc <- ivt_f2_dim_slot_alloc(raw, k, c0, slots)
    if (is.na(alloc) || alloc < 4L * ivt_f2_nextpow2(c0)) next
    mc <- ivt_f2_dir_member_count(raw, dims[[k]]$name, dir)
    if (is.na(mc$count) || mc$count <= c0 || mc$count > alloc) next
    nm <- dims[[k]]$name; if (is.null(nm) || is.na(nm)) nm <- "?"
    ivt_fallback(sprintf(paste(
      "Dimension %d (\"%s\") declares %d members but allocates %d slots; its",
      "codebook member array holds %d members -- using that count."),
      k, nm, c0, alloc, mc$count), class = "canivt_underdeclared_count")
    dims[[k]]$count <- as.integer(mc$count)
  }
  amb <- which(vapply(dims, function(d)
    !isTRUE(d$declared) &&
      (isTRUE(d$double01) || identical(as.integer(d$count), 0L)), logical(1)))
  if (!length(amb)) return(dims)
  for (k in amb) {
    zero <- identical(as.integer(dims[[k]]$count), 0L)
    fix_zero <- function() {                          # count-0 last resort: 1, loud
      nm <- dims[[k]]$name; if (is.null(nm) || is.na(nm)) nm <- "?"
      ivt_fallback(sprintf(paste0(
        "Dimension %d (\"%s\") has a zero descriptor count and no codebook ",
        "member array; defaulting to a single member."),
        k, nm), class = "canivt_zero_count")
      dims[[k]]$count <<- 1L
    }
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) { if (zero) fix_zero(); next }
    mc <- ivt_f2_dir_member_count(raw, dims[[k]]$name, dir)
    if (is.na(mc$slots) || mc$slots < 1L) { if (zero) fix_zero(); next }
    # keep a positive descriptor count the codebook cannot contradict (<= slots);
    # replace it when it OVER-counts (the profile "Values" placeholder read
    # 0x20 = 32 vs 1 real slot) OR is ZERO (the geography placeholder
    # `00 00 01 01` of the 2016 custom-extract lineage, whose real count -- 1 for
    # a single-geography crosstab like CRO0166131_CT.1.1, 16 for CT.7's provinces
    # -- lives only in its codebook attribute arrays).
    if (dims[[k]]$count >= 1L && dims[[k]]$count <= mc$slots) next
    if (!is.na(mc$count) && mc$count >= 1L) dims[[k]]$count <- mc$count
    else if (zero) fix_zero()
  }
  dims
}

# DECLARED slot positions, from the dimension's own member-code block
# (`ivt_f2_dim_slot_table()`: the 22-bit-per-slot mid-section of
# `[81 02][u16 alloc][16 00]`). This is the file STATING which of its allocated
# slots hold members and which of those are LIVE -- the third and strongest count
# witness, and the only one that gives slot POSITIONS:
#
#  - a USED-but-not-LIVE slot is a DELETED member. It keeps its codebook entry
#    (label + code) but addresses no cells, so the member count is the LIVE count
#    while the codebook arrays still store one record per USED slot. This is what
#    the `ivt_f2_dim_slot_expand()` margin heuristic below could only approximate:
#    it widened the count to the physical extent, which kept the page geometry
#    right but emitted the deleted slot as a phantom member (the accs lineage's
#    second "Company"). The declared table names the deleted slot exactly
#    (accs "Sex": slot 4 of 6 -- confirmed empty in the decode), so the geometry
#    stays extent-6 via `$slots` while the dimension reports its true 5 members.
#  - USED slots need not start at 1 or be contiguous: LFHR `Table-210`'s
#    10-member "Education level" occupies slots 10..19 of its 32, and
#    `table_5_c`'s 215 "Offences" skip slot 98. The presence bitmap addresses
#    members BY SLOT, so laying those out as `1..n` mis-assigns every member above
#    the hole. `$slots` is the fix, consumed by `ivt_layout()` exactly as the
#    time-series slot flags already are.
#
# Gated on the code array parsing BYTE-EXACTLY (`codes_ok`) and on the dimension
# owning exactly ONE such block -- a chunked codebook stores several block-local
# ones, none of which describes the whole dimension, and those return NULL. Not a
# fallback and therefore NOT loud: nothing is inferred, the values are read from a
# declaration in the file. `$slot_used` travels with them so the codebook readers
# can subset their per-USED-slot arrays back to the live members.
ivt_f2_dim_slot_declared <- function(raw, dims, slots) {
  for (k in seq_along(dims)) {
    dir <- tryCatch(ivt_f2_dim_dir(raw, k, slots), error = function(e) NULL)
    if (is.null(dir)) next
    st <- tryCatch(ivt_f2_dim_slot_table(raw, dir), error = function(e) NULL)
    if (is.null(st) || !isTRUE(st$codes_ok)) {
      st <- ivt_f2_dim_time_declared(raw, dir)
      if (is.null(st)) next
    }
    live <- st$live; used <- st$used
    if (!length(live)) next
    dense <- identical(live, seq_along(live)) && length(used) == length(live)
    if (dense && identical(as.integer(dims[[k]]$count), length(live))) next
    dims[[k]]$count <- length(live)
    dims[[k]]$double01 <- FALSE
    dims[[k]]$declared <- TRUE
    if (!dense) {
      dims[[k]]$slots <- live
      if (length(used) > length(live)) dims[[k]]$slot_used <- used
    }
  }
  dims
}

# The same declaration for a dimension whose members are declared in the
# TIME-SERIES member table `[81 02][u16 alloc][08 00]` instead of the `16 00`
# member-code block. A reference-period dimension carries one or the other, never
# both: the time table stores `alloc` pair-swapped slot flags plus one u24 date
# per populated slot, so it names the same two things the `16 00` mid-section
# does -- how many members there are, and at which SLOTS they sit.
#
# It is a declaration, not an inference, and the dates are what validate it: a
# block is only accepted when every populated slot resolves to a plausible date
# and `ivt_f2_time_members()` therefore returns generated labels. A run of bytes
# that merely looks like a flag array cannot pass that.
#
# Why it is needed: the descriptor's count for such a dimension can be pure
# garbage. `SP3_RHUXA9_801` (SLID low-income, 1980-2002) declares its four data
# dimensions honestly in `16 00` blocks (1/5/2/7) but reads "Date" as **3386** --
# a 237,020-cell cartesian in a 16.7 KB file. Its time table declares 23 annual
# members, which is the count the pages actually fit. There are no deleted slots
# here (used == live), so this returns the same shape the `16 00` reader does,
# with `deleted` empty.
ivt_f2_dim_time_declared <- function(raw, dir) {
  tm <- tryCatch(ivt_f2_time_members(raw, dir), error = function(e) NULL)
  if (is.null(tm) || is.null(tm$labels) || anyNA(tm$labels)) return(NULL)
  if (length(tm$slots) != tm$count) return(NULL)
  list(used = tm$slots, live = tm$slots, deleted = integer(0))
}

# DELETED-SLOT expansion: a dimension's physical slot EXTENT can exceed the
# descriptor's logical member count when a member slot was DELETED but retained
# its label in the codebook. The adult-criminal-court survey lineage's
# `accs-...-decision` table declares "Sex (5)" -- Total/Males/Females/Company/
# Unknown -- but its member-label array carries SIX records (a second, deleted
# "Company"/"Sociétés" slot). The page directory addresses members BY SLOT and
# pads to `nextpow2(extent)`, so the whole page geometry needs the larger
# extent-6 nesting; laid out on the descriptor's 5 it loses the last real member
# (its window sits past the count) and mis-nests every stride above it -- which is
# what made this lineage LOOK like the LFHR "doubled-window" survey directory
# (the phantom x2 stride is really this un-modelled deleted slot). The deleted
# slot decodes EMPTY (no page addresses it), so expanding to the physical extent
# is loss-free. Read the extent from the codebook member-label array
# (`ivt_f2_slot_member_count()`, which counts the dense/plain label records), and
# expand only by a SMALL margin (a footnote-text block would over-count by far
# more than a deleted slot or two, so `<= 2` rejects it) on a genuine multi-member
# dimension. LOUD (`canivt_deleted_slot`): a count beyond the descriptor's stated
# one is supplied from the codebook, so strict mode surfaces it.
#
# This is now the FALLBACK for dimensions whose declared slot table
# (`ivt_f2_dim_slot_declared()`, which runs first and states the deleted slots
# exactly) cannot be read -- a chunked codebook, or a code array that does not
# parse byte-exactly. Dimensions the declaration already resolved are skipped.
ivt_f2_dim_slot_expand <- function(raw, dims, slots) {
  for (k in seq_along(dims)) {
    c0 <- as.integer(dims[[k]]$count)
    if (is.na(c0) || c0 < 3L || isTRUE(dims[[k]]$double01) ||
        isTRUE(dims[[k]]$declared)) next
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) next
    ext <- ivt_f2_slot_member_count(raw, dir)
    if (is.na(ext) || ext <= c0 || ext - c0 > 2L) next
    nm <- dims[[k]]$name; if (is.null(nm) || is.na(nm)) nm <- "?"
    ivt_fallback(sprintf(paste0(
      "Dimension %d (\"%s\") declares %d members but its codebook holds %d member ",
      "slots (a deleted member retains its label); using the physical extent %d ",
      "for the page geometry (the deleted slot decodes empty)."),
      k, nm, c0, ext, ext), class = "canivt_deleted_slot")
    dims[[k]]$count <- ext
  }
  dims
}

# Which descriptor dimension is geography? Dimension 1 on almost every layout,
# but NOT the profile-table lineage (97-570-X1981004 / 98F0172X / 95F0170X: a
# 1-member "Values" placeholder first, geography LAST) nor the Business Patterns
# geography-last vintages (Dec08+: a data dimension first, geography LAST). The
# identification stays metadata-driven, never positional: dimension 1 is accepted
# outright only when its slot directory carries a geography codebook signature
# (`ivt_f2_dir_is_geo()`: a GEO_NAME attribute schema, or inline "<name> (<code>)
# <flag>" member blocks -- or, for the Business Patterns lineage, a codebook of
# bare numeric GEOUIDs, `ivt_f2_dir_has_bare_codes()`). Otherwise every dimension
# is probed for that signature, falling back to dimension 1. No decoder logic
# branches on this beyond which dimension gets the geography role (slug / labels
# / codebook); the cell decode itself is dimension-agnostic.
ivt_f2_geo_dim_index <- function(raw, d = NULL)
  ivt_memo(raw, "geo_dim_index", function() ivt_f2_geo_dim_index_impl(raw, d))

ivt_f2_geo_dim_index_impl <- function(raw, d = NULL) {
  if (is.null(d)) d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(1L)
  if (length(d$dims) == 1L) return(1L)
  slots <- ivt_f2_dim_slots(raw, m = length(d$dims))
  if (is.null(slots)) return(1L)
  is_geo_dim <- function(k) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    !is.null(dir) && (ivt_f2_dir_is_geo(raw, dir) ||
                        ivt_f2_dir_has_bare_codes(raw, dir))
  }
  # fast path: a >1-member dimension 1 that looks like geography (every ordinary
  # table). Only when dimension 1 is NOT geographic -- the profile "Values"
  # placeholder or a Business Patterns data-dim-first order -- do we probe.
  cnt1 <- suppressWarnings(as.integer(d$dims[[1L]]$count))
  if (!is.na(cnt1) && cnt1 > 1L && is_geo_dim(1L)) return(1L)
  for (k in seq_along(d$dims)) if (is_geo_dim(k)) return(k)
  # header-name fallback: no dimension carries a decodable geography SIGNATURE
  # (a schema-less chunked geography codebook -- e.g. EO3278/EO2654, whose members
  # are attribute-major name/code runs with no GEO_NAME schema and no inline
  # pattern). The descriptor still NAMES the dimension, so when exactly one is
  # called "Geography" / "Geographie" / "G\u00e9ographie" (the header's own label, like
  # any other dimension name), trust it. Gated to exactly one match so an ordinary
  # table -- where this never fires, dimension 1 having matched above -- is
  # untouched.
  dim_name <- function(x) { nm <- x$name; if (is.null(nm) || is.na(nm)) "" else nm }
  # The pre-DGUID `02 00 20 00` survey products (Health Statistics 1999,
  # Census of Agriculture 1996, Small Area Business 1996) name their geographic
  # dimension explicitly ("REGION", "Provinces", "Geography") but carry no UID /
  # GEO_NAME schema and no inline pattern, so no dimension matches a geography
  # SIGNATURE -- the header name is the only geography evidence the file gives.
  geo_named <- which(vapply(d$dims, function(x)
    grepl("^\\s*(geograph|g\u00e9ograph|region|r\u00e9gion|province)",
          dim_name(x), ignore.case = TRUE), logical(1)))
  # The `02 00 20 00` survey generation has NO geography dimension in the
  # package's sense: its regional dimensions ("REGION", "GEOGRAPHY", "Provinces")
  # carry no standard geographic identifiers (no UID/DGUID, no GEO_NAME schema,
  # no inline "<name> (<code>)" members), so they are ordinary data dimensions
  # -- labelled by their own member arrays like any other -- and the table has
  # no geography column. Return 0 (no geography); every consumer treats the
  # table as all-data-dimensions.
  if (isTRUE(d$gen02)) return(0L)
  # only OVERRIDE the dimension-1 default (and warn) when the header names a
  # NON-first dimension "Geography" -- when dimension 1 itself is so named, the
  # default already returns it, so this stays silent and changes nothing.
  if (length(geo_named) == 1L && geo_named != 1L) {
    nm <- dim_name(d$dims[[geo_named]])
    ivt_fallback(paste0(
      "No dimension carries a decodable geography codebook signature; the ",
      "geography dimension was identified by its header name (\"", nm, "\")."),
      class = "canivt_geo_by_name")
    return(geo_named)
  }
  1L
}

# Does this dimension's slot directory hold a bare-numeric-code geography
# codebook? The Business Patterns lineage stores its Dissemination-Area GEOUIDs
# as dense `[len][ascii-digits]` records (`ivt_f2_scan_digit_records()`) with no
# GEO_NAME schema and no inline pattern, so `ivt_f2_dir_is_geo()` misses them.
# TRUE once the directory's blocks yield `min_codes` such codes (a data
# dimension's member codes carry "<code> - <label>" text, never bare digits, so
# the threshold separates them cleanly). Cheap: stops at the first block that
# pushes the running count over the threshold, and scans at most `max_blocks`.
ivt_f2_dir_has_bare_codes <- function(raw, dir, min_codes = 100L, max_blocks = 8L) {
  n <- length(raw); tot <- 0L
  for (r in seq_len(min(nrow(dir), max_blocks))) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 8L || off + len > n) next
    tot <- tot + length(ivt_f2_scan_digit_records(raw, off, len))
    if (tot >= min_codes) return(TRUE)
  }
  FALSE
}

# Does this dimension slot directory hold a GEOGRAPHY codebook? Identified from the
# dimension's own FIELD DICTIONARY first (metadata-driven, section 8.4) -- a `81 02` block
# is geography when it names (a) the modern DGUID attribute `GEO_NAME`, (b) the
# origin-destination flow schema (`POR/POW` / `LDR/LDT`, Place Of Residence/Work), or
# (c) a `UID/IDU` uid column TOGETHER with a `Level/Niveau` or `Geo Code` column --
# all geography-specific field names a data-dimension dictionary (which names Code /
# English Desc / Desc Francais / _Description / _ItemNotes) never carries. Only when
# no dictionary declares geography does it fall back to (d) the CONTENT probe: a
# member array whose records parse as the inline combined format ("<name> (<code>)
# [<type>] <flag>", IVT_F2_INLINE_PAT) -- for the schema-thin vintages whose dict is
# not slot-reachable. Only the first few member arrays are strict-parsed; name/code
# sibling arrays that do not match the pattern are skipped, not disqualifying.
ivt_f2_dir_is_geo <- function(raw, dir, max_member_entries = 6L) {
  n <- length(raw); tried <- 0L
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 8L || off < 0 || off + len > n) next
    b0 <- as.integer(raw[off + 1L]); b1 <- as.integer(raw[off + 2L])
    if (b0 == 0x81L && b1 == 0x02L && len <= 4000L) {
      txt <- raw_to_latin1(raw[(off + 1L):(off + len)])
      if (grepl("GEO_NAME", txt, fixed = TRUE)) return(TRUE)
      # metadata-driven: the field dictionary declares geography-specific columns.
      uid_field <- grepl("UID", txt, fixed = TRUE) || grepl("IDU", txt, fixed = TRUE)
      lvl_field <- grepl("Niveau", txt, fixed = TRUE) ||
        grepl("Level", txt, fixed = TRUE) || grepl("Geo Code", txt, fixed = TRUE)
      if (grepl("POR/POW", txt, fixed = TRUE) || grepl("LDR/LDT", txt, fixed = TRUE) ||
          (uid_field && lvl_field)) return(TRUE)
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
  lay <- ivt_f2_chunk_layout(cnt)
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
  ei <- 1L
  nonempty <- function(x) sum(!is.na(x) & nzchar(trimws(x)))
  take_run <- function(need) {
    # consume the next blocks whose record counts match `need` (in order),
    # skipping non-matching framing entries between runs. A partial final chunk
    # may be stored either at its true length OR padded to a full 256-slot block
    # with trailing empty records (Canadian Business Patterns: NAICS(929)'s last
    # chunk is 161 real members in a 256-slot block); accept such a block when
    # its NON-empty count equals the wanted size and slice it to that size.
    fits <- function(v, want)
      length(v) == want ||
      (want < 256L && length(v) == 256L && nonempty(v) == want)
    run <- character(0)
    for (want in need) {
      while (ei <= length(vals) && !fits(vals[[ei]], want)) ei <<- ei + 1L
      if (ei > length(vals)) return(NULL)
      run <- c(run, vals[[ei]][seq_len(want)]); ei <<- ei + 1L
    }
    run
  }
  for (grp in lay$groups) {
    need <- grp$chunk
    ra <- take_run(need); if (is.null(ra)) return(NULL)
    rb <- take_run(need); if (is.null(rb)) return(NULL)
    a <- c(a, ra); b <- c(b, rb)
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
  # the block stores one ordinal per USED slot; deleted slots are dropped and the
  # survivors re-ranked, so the result stays a permutation of 1..count
  sk <- ivt_f2_dim_slot_keep(dim, cnt); scnt <- sk$n
  cand <- ivt_f2_dir_member_arrays(
    raw, dir, scnt, rows = seq_len(nrow(dir)),
    accept = function(t) {
      iv <- suppressWarnings(as.integer(t))
      if (anyNA(iv) || !identical(sort(iv), seq_len(scnt))) return(NULL)
      iv
    })
  if (!length(cand)) return(NULL)
  iv <- cand[[length(cand)]]                         # the LAST permutation wins
  if (!is.null(sk$keep)) iv <- as.integer(rank(iv[sk$keep], ties.method = "first"))
  iv
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
    lab <- ivt_f2_dim_dir_label1(raw, d$dims[[k]], dir)
    # A dimension whose member ARRAYS do not resolve can still declare its French
    # NAME in the doubled-name marker entry of that same directory (the Business
    # Patterns / sub-A code-named dimensions, 801's profile dimensions). Keep that
    # name -- the consumers gate members on `$en`, which stays NULL here, so this
    # only ever adds the name.
    if (is.null(lab)) {
      fr <- ivt_f2_dim_name_fr_dir(raw, d$dims[[k]]$name, dir)
      if (!is.na(fr)) lab <- list(name_fr = fr)
    }
    out[[k]] <- lab
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
