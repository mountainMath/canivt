#' Family-2 codebook: geography DGUIDs and data-dimension member labels
#'
#' The family-2 codebook (e.g. table 98-10-0023) lives in the last ~18 MB of the
#' file. Geography attributes (name, DGUID, level, classification code, ...) are
#' stored in member-ordered chunks of 256, with a full English copy followed by a
#' French copy, grouped by member range. The two data dimensions (Age, Gender)
#' sit at the very end as clean single blocks (EN and FR), each followed by a
#' "1..n" member-ordinal block.
#'
#' We extract three things here:
#' - the geography **DGUID** array, in 1-based member-id order (a fast vectorised
#'   scan; the canonical StatCan geography key);
#' - the **member labels** for each data dimension (Age, Gender);
#' - the full **geography attribute table** (name, level, type, geocodes, the
#'   data-quality flag and non-response rate) via `ivt_f2_geo_attributes()`, by
#'   parsing the attribute-major group structure of the codebook.
#'
#' All are validated cell-for-cell against the StatCan metadata for 98-10-0023:
#' every attribute (DGUID, name, level, type + type abbreviation, geocodes, quality
#' flag + note, non-response rate) and the Age/Gender labels are exact for all
#' 63,404 geographies. `dqf_note` (DQF_NOTE) is recovered via its 1:1 relationship
#' with DQF_CODE (`ivt_f2_derive_text()`) because its long concatenated text spans
#' multiple codebook blocks.
#'
#' @keywords internal
#' @noRd
NULL

# The DGUID string shape: a 4-digit year, an upper-case level letter, then the
# geographic code. The code may carry a dot -- census-tract DGUIDs embed the dotted
# CT number (e.g. `2021S05079320001.00`) -- so `.` is allowed after the level
# letter. The numeric attribute codes (ALT_GEO_CODE, PR_CODE) have a digit, not a
# letter, in position 5, so they never match. Shared by the byte scan and the
# block detector to keep them in lock-step.
IVT_F2_DGUID_RE <- "^[0-9]{4}[A-Z][0-9A-Z.]+$"

# Member-ordered geography DGUIDs, extracted by a fast vectorised scan for the
# Pascal-prefixed DGUID strings. A DGUID has the shape `<YYYY><level letter><code>`
# (e.g. `2021A000011124`), so we anchor on that STRUCTURE -- four leading digits
# then an upper-case level letter -- rather than the literal year "2021", which
# keeps the scan vintage-agnostic (2016/2021/...). DGUIDs are globally unique and
# laid down in member order (the EN copy first, then an identical FR copy, plus
# per-chunk repeats), so first-appearance de-duplication yields the geographies in
# 1-based member-id order. The scan is restricted to the geography dimension's
# marker region (`ivt_f2_geo_marker_region()`) when present, so a chance digit run
# in the value pages cannot masquerade as a DGUID. Returns a character vector
# (length = number of geographies).
ivt_f2_geo_dguids <- function(raw) {
  v <- as.integer(raw)
  n <- length(v)
  if (n < 5L) return(character(0))
  dig <- function(x) x >= 0x30L & x <= 0x39L        # ASCII '0'..'9'
  # positions where four digits are followed (the level letter check comes below)
  hit <- which(dig(v[1:(n - 4L)]) & dig(v[2:(n - 3L)]) &
               dig(v[3:(n - 2L)]) & dig(v[4:(n - 1L)]))
  if (!length(hit)) return(character(0))
  region <- ivt_f2_geo_marker_region(raw)
  if (!is.null(region)) hit <- hit[hit >= region[1] & hit < region[2]]
  if (!length(hit)) return(character(0))
  len <- v[hit - 1L]            # Pascal length byte
  c5  <- v[hit + 4L]            # 5th character (a level letter, e.g. A/S)
  ok <- !is.na(len) & len >= 9L & len <= 20L &
        !is.na(c5) & c5 >= 65L & c5 <= 90L & (hit - 1L) >= 1L
  hit <- hit[ok]; len <- len[ok]
  out <- character(length(hit)); k <- 0L
  seen <- new.env(hash = TRUE, parent = emptyenv(), size = 80000L)
  for (idx in seq_along(hit)) {
    i <- hit[idx]; L <- len[idx]
    if (i - 1L + L > n) next
    s <- intToUtf8(v[i:(i - 1L + L)])
    if (!is.null(seen[[s]])) next                       # already seen this DGUID
    if (!grepl(IVT_F2_DGUID_RE, s)) next                # reject stray digit-runs
    seen[[s]] <- TRUE
    k <- k + 1L; out[k] <- s
  }
  out[seq_len(k)]
}

# A codebook block is one DGUID array chunk when every entry has the DGUID shape
# `<YYYY><level letter><code>`. Vintage-agnostic (no "2021" literal): the numeric
# attribute codes (ALT_GEO_CODE, PR_CODE) carry no letter in position 5 and the
# name/description/note blocks carry spaces, so the DGUID chunks are the only
# all-`<4 digits + level letter>` blocks -- the structural anchor used to segment
# the codebook into attribute groups.
ivt_f2_is_dguid_block <- function(t)
  length(t) >= 2L && all(grepl(IVT_F2_DGUID_RE, t))

# Member-ordered geography DGUIDs read POSITIONALLY from the geography block
# directory -- the primary uid read for the chunked tables; the byte scan above is
# its fallback. The directory lists the codebook blocks in logical member order
# (which the byte-ascending scan cannot see: 98-10-0013's reverse-stored root chunk
# sits below the marker region, so the scan silently dropped members 1-256). The
# DGUID slot's blocks are found by a cheap O(1) probe per entry -- the plain
# value-block header `[01 01][u16 payload][u16 n_slots]` with a first (non-empty)
# record of DGUID shape; no other attribute stores DGUID-shaped strings (codes have
# a digit, not a level letter, in position 5) -- then only those blocks are strict-
# parsed. Consumed per group of `G` chunks as one language run of `G` blocks then
# the identical second-language run, exactly like every other attribute; the two
# copies must agree record-for-record (DGUIDs are language-invariant), every chunk
# must parse to its expected size, and every record must match the DGUID shape.
# Returns the n_geo-long uid vector (NA for members that carry no attributes), or
# NULL when the directory/probe does not resolve (the caller falls back to the
# scan, loudly).
ivt_f2_geo_dguids_dir <- function(raw) {
  ents <- ivt_f2_geo_entries(raw); if (is.null(ents)) return(NULL)
  d <- ents$dir                                          # cheap O(1) probe over entries
  n_geo <- ivt_f2_geo_count(raw)
  if (is.na(n_geo) || n_geo < 1L) return(NULL)
  n <- length(raw)
  # O(1) probe: a value-block header (plain `[01 01]` or bit-headed dense
  # `[81 01]` -- the trailing partial chunks may be stored dense, e.g.
  # 98-10-0013's 71-member last chunk) whose first non-empty record is
  # DGUID-shaped (an absent leading member in a plain array is an explicit
  # empty record `00 00`; walk past a few).
  probe <- function(off, len) {
    if (len < 8L || off + len > n) return(FALSE)
    b0 <- as.integer(raw[off + 1L])
    if (as.integer(raw[off + 2L]) != 0x01L || !(b0 %in% c(0x01L, 0x81L)))
      return(FALSE)
    end <- off + len
    if (b0 == 0x01L) {                              # plain: [u16 payload][u16 n_slots]
      pay <- rd_u16(raw, off + 2L)
      if (is.na(pay) || pay != len - 4L) return(FALSE)
      i <- off + 6L
      for (k in seq_len(16L)) {                     # skip leading empty records
        if (i + 1L > end) return(FALSE)
        L <- as.integer(raw[i + 1L])
        if (L > 0L) break
        i <- i + 2L
      }
    } else {                                        # dense: [u16 nbits][bitstream][80|01]
      nbits <- rd_u16(raw, off + 2L)
      if (is.na(nbits) || nbits < 1L || nbits > 8L * len) return(FALSE)
      i <- off + 4L + 2L * as.integer(ceiling(nbits / 16))
      if (i + 1L > end || !(as.integer(raw[i + 1L]) %in% c(0x80L, 0x01L)))
        return(FALSE)
      i <- i + 1L
      if (i + 1L > end) return(FALSE)
      L <- as.integer(raw[i + 1L])
    }
    if (L < 9L || L > 20L || i + 1L + L > end) return(FALSE)
    grepl(IVT_F2_DGUID_RE, raw_to_latin1(raw[(i + 2L):(i + 1L + L)]))
  }
  cand <- which(vapply(seq_len(nrow(d)),
                       function(r) probe(d[r, "off"], d[r, "len"]), TRUE))
  lay <- ivt_f2_chunk_layout(n_geo)
  if (length(cand) != 2L * lay$n_chunks) return(NULL)
  chunk_vals <- function(entry, want) {              # strict parse -> want-long chunk
    e <- ents$strict(entry)
    if (is.null(e)) return(NULL)
    v <- e$values
    if (!e$dense && length(v) > want && all(is.na(v[(want + 1L):length(v)])))
      v <- v[seq_len(want)]                          # trim the pow-2 slot padding
    # a dense chunk skips absent members entirely; it is positional only when no
    # member is absent, i.e. it parses to exactly the chunk size
    if (length(v) != want) return(NULL)
    if (!all(grepl(IVT_F2_DGUID_RE, v[!is.na(v)]))) return(NULL)
    v
  }
  out <- rep(NA_character_, n_geo)
  pos <- 1L
  for (grp in lay$groups) {
    G <- grp$G
    for (c in seq_len(G)) {
      a <- chunk_vals(cand[pos + c - 1L], grp$chunk[c])
      b <- chunk_vals(cand[pos + G + c - 1L], grp$chunk[c])
      if (is.null(a) || is.null(b) || !identical(a, b)) return(NULL)
      out[grp$start + 256L * (c - 1L) + seq_along(a) - 1L] <- a
    }
    pos <- pos + 2L * G
  }
  out
}

# Each dimension's member labels are anchored in the codebook by a doubled-name
# header marker -- the same `81 02 02 00` framing for every table -- that carries
# the dimension's display name (exactly as the header descriptor stores it) and
# sits immediately after that dimension's English member block (and before its
# "1..n" ordinal block). `ivt_f2_codebook_dim_markers()` returns those markers as
# (offset, name) so the labels can be located by NAME rather than by guessing from
# block adjacency. Validated on 98-10-0241 (7), 98-10-0077 (7), 98-10-0023 (2
# data-dim markers; geography sits earlier in the 18 MB codebook), 98-10-0662,
# 98-10-0129 and 1003011.
ivt_f2_codebook_dim_markers <- function(raw, search_start) {
  v <- as.integer(raw); n <- length(v)
  if (search_start >= n - 4L) return(data.frame(offset = integer(0), name = character(0)))
  # v is 1-indexed; clamp the low end so a 0 search_start (small files, where
  # length(raw) - tail_bytes underflows) does not put index 0 in reg and drop an
  # element, which would misalign the v[reg] / v[reg + 1L] comparison.
  reg <- max(1L, as.integer(search_start)):(n - 4L)
  off <- reg[v[reg] == 0x81L & v[reg + 1L] == 0x02L &
             v[reg + 2L] == 0x02L & v[reg + 3L] == 0x00L]
  if (!length(off)) return(data.frame(offset = integer(0), name = character(0)))
  # the name is the first printable run (length >= 3) after the marker + framing;
  # it stops at the 0x01 separator before the doubled copy, so it is a single name.
  nm <- vapply(off, function(m) {
    seg <- v[(m + 4L):min(n, m + 120L)]
    pr <- seg >= 32L & seg <= 126L
    r <- rle(pr); ends <- cumsum(r$lengths); starts <- ends - r$lengths + 1L
    for (k in which(r$values))
      if (r$lengths[k] >= 3L) return(trimws(intToUtf8(seg[starts[k]:ends[k]])))
    NA_character_
  }, "")
  data.frame(offset = off, name = nm, stringsAsFactors = FALSE)
}

# Match a codebook marker name to one of `dims` (descriptor records). The marker
# and the descriptor draw the name from the same doubled-name field, but one may be
# truncated harder than the other, so match when the shorter is a prefix of the
# longer (>= 4 shared characters). Returns the matched descriptor dimension or NULL.
ivt_f2_match_dim <- function(name, dims) {
  for (d in dims) if (ivt_f2_name_match(d$name, name)) return(d)
  NULL
}

# Member labels per data dimension, located by the codebook doubled-name markers
# (`ivt_f2_codebook_dim_markers()`). For each marker matched to a data dimension we
# take that dimension's English block -- the Pascal member block ending immediately
# before the marker -- and keep its trailing `count` records (the block can carry a
# few leading framing bytes the Pascal scan misreads as records, e.g. 98-10-0077's
# Ages). This is robust where the old ordinal/adjacency heuristics broke: it labels
# the 18-member Ages dimension whose English block has 2 leading garbage records,
# the 2-member reference-period "Year" dimension that has no trailing ordinal block,
# and -- because it keys on NAME -- two distinct same-count dimensions (98-10-0662's
# "French used at work" and "English used at work", both 6 members). Returns a list
# of list(name, count, labels), one per matched dimension, in codebook order.
ivt_f2_marker_labels <- function(raw, tail_bytes = 600000L) {
  d <- ivt_f2_descriptor(raw)
  data_dims <- if (!is.null(d) && length(d$dims) > 1L)
    d$dims[-ivt_f2_geo_dim_index(raw, d)] else list()
  if (!length(data_dims)) return(list())
  start <- max(0L, length(raw) - tail_bytes)
  markers <- ivt_f2_codebook_dim_markers(raw, start)
  if (!nrow(markers)) return(list())
  # min_records = 2 so a 2-member reference period (e.g. "Year": 2020 / 2015) is
  # captured; we only ever read the block immediately before a matched marker.
  blocks <- ivt_find_member_blocks(raw, start, min_records = 2L)
  if (!length(blocks)) return(list())
  blocks <- blocks[order(vapply(blocks, function(b) b$start, 1))]
  bstart <- vapply(blocks, function(b) b$start, 1)
  out <- list()
  for (mi in seq_len(nrow(markers))) {
    dd <- ivt_f2_match_dim(markers$name[mi], data_dims)
    if (is.null(dd)) next
    cnt <- as.integer(dd$count)
    bi <- which(bstart < markers$offset[mi])
    if (!length(bi)) next
    t <- blocks[[bi[length(bi)]]]$texts
    if (length(t) < cnt) next
    cand <- t[(length(t) - cnt + 1L):length(t)]
    if (identical(cand, as.character(seq_len(cnt)))) next   # an ordinal block
    if (ivt_f2_is_dguid_block(cand)) next                   # a DGUID block
    out[[length(out) + 1L]] <- list(name = dd$name, count = cnt, labels = cand)
  }
  out
}

# Member labels for the (non-geography) data dimensions, keyed by member count.
# The codebook lays down, per dimension, a French label block, its English twin, a
# doubled-name header marker, and the member "1..n" ordinal block (plus a
# "Code"/"English Desc" sub-header). We recover the ENGLISH label block three ways,
# in order of robustness:
#   - primary: the doubled-name header marker names its dimension, so the English
#     block is the one ending right before it (`ivt_f2_marker_labels()`). This is
#     name-anchored and count-exact, so it handles leading-garbage English blocks
#     and ordinal-less short dimensions the heuristics below miss.
#   - fallback 1: the block immediately preceding a "1..n" ordinal block of the same
#     length is that dimension's English member list.
#   - fallback 2: the LAST dimension is truncated at EOF and so has no trailing
#     ordinal block (e.g. 98-10-0241's Age); recover it as the English (second) half
#     of an adjacent same-length pair of clean, whitespace-bearing label blocks.
# We only look for the member counts the descriptor declares (`want`), so unrelated
# blocks of other lengths -- geography names/types, data-quality note text -- are
# never considered. (Counts can collide; the count-keyed result keeps the first
# match. `ivt_f2_dimensions()` resolves collisions per dimension by NAME via
# `ivt_f2_marker_labels()`.) Validated exact for Age/Gender (98-10-0023), Age/Sex
# (1991), the six 98-10-0241 data dimensions and all six 98-10-0077 dimensions
# (incl. the formerly-empty Ages-18 and Year-2).
ivt_f2_dim_member_labels <- function(raw, want = NULL, tail_bytes = 600000L) {
  if (is.null(want)) want <- ivt_f2_data_dims(raw)$counts
  want <- unique(as.integer(want[!is.na(want)]))
  if (!length(want)) return(list())
  out <- list()
  put <- function(L, t) {
    k <- as.character(L)
    if (L %in% want && is.null(out[[k]])) out[[k]] <<- t  # keep first (member order)
  }
  for (ml in ivt_f2_marker_labels(raw, tail_bytes)) put(ml$count, ml$labels)  # primary
  if (all(as.character(want) %in% names(out))) return(out)
  # heuristic fallbacks for any count the markers did not resolve (and for tables
  # without the doubled-name markers).
  start <- max(0L, length(raw) - tail_bytes)
  blocks <- ivt_find_member_blocks(raw, start, min_records = 3L)
  if (!length(blocks)) return(out)
  B <- blocks[order(vapply(blocks, function(b) b$start, 1))]
  texts <- lapply(B, `[[`, "texts")
  len <- lengths(texts)
  ords <- vapply(texts, function(t) identical(t, as.character(seq_len(length(t)))),
                 logical(1))
  # a "clean label" block: real member labels are indented single-line strings, so
  # they carry whitespace and never embed control characters or repeat a single byte
  # (the latter two are how value-page noise shows up in the Pascal block scan).
  spaced <- vapply(texts, function(t)
    !any(grepl("[\r\n\t]", t)) && !any(grepl("^(.)\\1*$", t)) &&
      mean(grepl("[[:space:]]", t)) > 0.5, logical(1))
  for (i in seq_along(B))                       # fallback 1: precedes its 1..n block
    if (i > 1L && ords[i] && len[i - 1L] == len[i]) put(len[i], texts[[i - 1L]])
  for (i in seq_along(B))                       # fallback 2: English half of a pair
    if (i > 1L && spaced[i] && spaced[i - 1L] && len[i] == len[i - 1L])
      put(len[i], texts[[i]])
  out
}

# The geography dimension carries its own **attribute schema** in the codebook: a
# named, ordered field list (`GEO_NAME`, `GEO_TYPE_DESC`, ..., `DGUID`, ...), one
# entry per attribute, each later laid down EN then FR -- the geography equivalent
# of the data dimensions' Variable List. Parsing it lets us address geography
# attribute arrays **by name** (GEO_NAME, DGUID) instead of sniffing their content
# (a "Canada" first entry, a "2021..." DGUID prefix), so nothing here depends on a
# census year or a country name. We read the ordered EN field stems; the same list
# names the attribute arrays in storage order. Returns a character vector of
# attribute names, or NULL when no schema is present (older / inline layouts).
# Note: this works in TEXT space (field names + order only) -- never byte offsets,
# which the latin-1 -> UTF-8 round-trip does not preserve 1:1.
# Legacy header-slot guesses for the geography block directory, kept only as the
# fallback behind the decoded per-dimension slot table (dimdir.R): `@824` is in
# fact dimension 1 (geography)'s slot in that table (stride 14, so `@852` is
# dimension 3's -- the old 4-aligned probing missed the odd slots), and `@712`
# points at the data-quality legend directory. Each is followed and confirmed by
# content (`GEO_NAME_EN`), so a slot that means something else is skipped.
IVT_F2_DIR_SLOTS <- c(824L, 572L, 712L)

# Decode a metadata block directory that STARTS at absolute offset `ptr`: a run of
# 8-byte entries `[u32 off][u16 len][u16 len]` (null `(0,0)` slots tolerated). The
# second length is normally a copy of the first; the 1991 profile exports (98F0172X
# / 95F0170X) store the 4-byte-ALIGNED allocation there (205 -> 208). That
# `len2 == len || len2 == 4*ceiling(len/4)` rule is the default: it doubles as the
# end-of-table sentinel (random trailing bytes rarely satisfy it), so relaxing it
# globally over-reads garbage on some tables. `relaxed = TRUE` accepts any `len2 >=
# len` (the block's true ALLOCATED size, which the 2006 custom-order crosstabs
# cro0172986_ct.7/8 store larger than the content: 3024 -> 3078, 367 -> 903) --
# used only by `ivt_f2_dim_dir()` as a bounded fallback (capped to the slot's
# declared entry count) when the strict read comes up short. The content length is
# always the first field. Returns a two-column matrix (off, len), or NULL when
# `ptr` is not a well-formed table.
ivt_f2_read_dir_at <- function(raw, ptr, max_entries = 100000L, relaxed = FALSE) {
  n <- length(raw)
  if (is.na(ptr) || ptr < 1L || ptr + 8L > n) return(NULL)
  offs <- integer(0); lens <- integer(0)
  for (i in seq_len(max_entries)) {
    base <- as.integer(ptr) + (i - 1L) * 8L
    if (base + 8L > n) break
    off <- rd_u32(raw, base); a <- rd_u16(raw, base + 4L); b <- rd_u16(raw, base + 6L)
    if (is.na(off) || is.na(a) || is.na(b)) break
    if (off == 0 && a == 0) next                       # null slot
    len2_ok <- if (relaxed) b >= a
               else b == a || b == (a + 3L) %/% 4L * 4L
    if (!len2_ok || a <= 0L || off < 1 || off > n) break   # end of table
    offs <- c(offs, off); lens <- c(lens, a)
  }
  if (!length(offs)) return(NULL)
  cbind(off = offs, len = lens)
}

# Does a decoded directory `d` list the geography dictionary block (`GEO_NAME_EN`)?
ivt_f2_dir_has_geo <- function(raw, d) {
  if (is.null(d)) return(FALSE)
  n <- length(raw)
  for (r in seq_len(nrow(d))) {
    off <- d[r, "off"]; ln <- d[r, "len"]
    if (off + ln > n) next
    if (grepl("GEO_NAME_EN", raw_to_latin1(raw[(off + 1L):(off + ln)]), fixed = TRUE))
      return(TRUE)
  }
  FALSE
}

# The geography codebook block directory: the block directory of DIMENSION 1 in
# the header per-dimension slot table (dimdir.R), which lists the geography
# codebook blocks in LOGICAL order with their exact offsets/lengths (and is
# validated against the slot's own entry count). `ivt_f2_dim_dir()` handles the
# two indirection depths (the slot points straight at the directory on the small
# chunked tables 98-10-0013 / -0478 / -0241, but at a small geography-dimension
# struct whose first u32 is the directory pointer on the big tail-codebook
# tables 98-10-0023 / -0174). When the slot table is absent, fall back to the
# legacy slot guesses, confirmed by content (the `GEO_NAME_EN` dictionary
# block). Returns the (off, len) matrix, or NULL. This logical order is what
# lets us read the reverse-stored root chunk positionally (`ivt_f2_geo_root_dir`).
ivt_f2_geo_block_dir <- function(raw) {
  gi <- ivt_f2_geo_dim_index(raw)
  d <- ivt_f2_dim_dir(raw, gi)                         # the geography dimension
  if (!is.null(d)) return(d)
  # the geography dimension's slot directory may OVER-declare its entry count --
  # some custom exports (EO2654: 109 declared vs 92 real, well-formed entries)
  # stop the run short of `n_entries - 4`, so the strict `ivt_f2_dim_dir()` gate
  # rejects the complete-but-short read. Retry a relaxed read bounded by the
  # declared count and accept a shorter natural-end directory HERE, in the
  # geography path, where the specializers + `ivt_f2_check_geo_count()` validate
  # the recovered member count downstream (a genuinely truncated read fails them
  # loudly, so this cannot silently drop geographies). LOUD.
  dsc <- ivt_f2_descriptor(raw)
  if (!is.null(dsc) && length(dsc$dims)) {
    slots <- ivt_f2_dim_slots(raw, m = length(dsc$dims))
    sl <- if (!is.null(slots) && gi <= length(slots)) slots[[gi]] else NULL
    if (!is.null(sl) && !is.na(sl$ptr) && sl$ptr >= 1L &&
        !is.na(sl$n_entries) && sl$n_entries >= 1L && sl$n_entries <= 1e6L) {
      want <- as.integer(sl$n_entries)
      dr <- ivt_f2_read_dir_at(raw, sl$ptr, max_entries = want, relaxed = TRUE)
      if (is.null(dr) || nrow(dr) < 1L)
        dr <- ivt_f2_read_dir_at(raw, rd_u32(raw, sl$ptr), max_entries = want, relaxed = TRUE)
      if (!is.null(dr) && nrow(dr) >= 1L) {
        ivt_fallback(paste(
          "The geography slot directory declared {want} entries but only",
          "{nrow(dr)} are well-formed; accepting the shorter directory (the",
          "recovered geography count is validated downstream)."),
          class = "canivt_geo_dir_short")
        return(dr)
      }
    }
  }
  for (slot in IVT_F2_DIR_SLOTS) {
    ptr <- rd_u32(raw, slot)
    if (is.na(ptr) || ptr < 1L) next
    d2 <- ivt_f2_read_dir_at(raw, ptr)                 # flat: slot -> directory
    if (!ivt_f2_dir_has_geo(raw, d2))                  # indirect: slot -> struct -> dir
      d2 <- ivt_f2_read_dir_at(raw, rd_u32(raw, ptr))
    if (ivt_f2_dir_has_geo(raw, d2)) {
      ivt_fallback(paste(
        "The per-dimension header slot table did not resolve the geography",
        "block directory; it was found by probing the legacy header slots."))
      return(d2)
    }
  }
  NULL
}

# Stage 1 of the geography read (refactor-plan.md §7): locate the geography
# dimension's block directory ONCE (`ivt_f2_geo_block_dir()`, exactly how the data
# dimensions are located) and expose a LAZY, memoized per-entry reader so every
# geography specializer recovers member arrays through the same walk rather than
# re-implementing "walk the directory, parse each value entry" six times. Returns
# NULL when no geography block directory resolves.
#
# The object exposes, over the `n` directory entries in member-id (logical) order:
#   $n            entry count;  $dir  the block-directory matrix (off/len columns)
#   $off(r) / $len(r)   the r-th entry's byte offset / length
#   $records(r)   run-scanner texts (`ivt_f2_dir_entry_records()`) -- how attrs_dir
#                 and inline_dir CLASSIFY entries (kept per §4/§7 risk register)
#   $strict(r)    strict header-driven parse (`ivt_f2_dir_entry_members()`):
#                 list(values, dense) or NULL
#   $values(r)    strict-first member array (`strict$values`, else `records`) --
#                 what flow_dir / custom consume
#   $dense(r)     `strict$dense`, or FALSE when there is no strict parse
# records() and strict() are computed on first touch and cached, so a reader that
# never needs the run-scanner (dguids_dir's O(1) probe over the 6,244-entry
# 98-10-0023 geography directory) never pays for it -- eagerly scanning every entry
# measured ~17 s, the regression the memo work in §3 exists to avoid.
ivt_f2_geo_entries <- function(raw) {
  d <- ivt_f2_geo_block_dir(raw)
  if (is.null(d)) return(NULL)
  n <- nrow(d)
  rec <- vector("list", n); str <- vector("list", n)
  got_rec <- logical(n);    got_str <- logical(n)
  # cache with single-bracket `x[r] <<- list(v)` (NOT `x[[r]] <<- v`): a NULL
  # strict parse assigned via `[[<-` would DELETE the slot and shrink the cache,
  # misaligning every later entry.
  records <- function(r) {
    if (!got_rec[r]) {
      rec[r] <<- list(ivt_f2_dir_entry_records(raw, d[r, "off"], d[r, "len"]))
      got_rec[r] <<- TRUE
    }
    rec[[r]]
  }
  strict <- function(r) {
    if (!got_str[r]) {
      str[r] <<- list(ivt_f2_dir_entry_members(raw, d[r, "off"], d[r, "len"]))
      got_str[r] <<- TRUE
    }
    str[[r]]
  }
  list(
    n = n, dir = d,
    off     = function(r) d[r, "off"],
    len     = function(r) d[r, "len"],
    records = records,
    strict  = strict,
    values  = function(r) { s <- strict(r); if (is.null(s)) records(r) else s$values },
    dense   = function(r) { s <- strict(r); if (is.null(s)) FALSE else s$dense }
  )
}

# Locate the geography attribute dictionary block ("GEO_NAME_EN ... DGUID_EN ...")
# by following the file's own metadata directories and confirming the block by its
# field name. Returns c(off, len) of the dictionary block, or NULL if no directory
# lists it (then `ivt_f2_geo_schema()` falls back to the codebook-anchored search).
ivt_f2_geo_dict_block <- function(raw) {
  d <- ivt_f2_geo_block_dir(raw)
  if (is.null(d)) return(NULL)
  n <- length(raw)
  for (r in seq_len(nrow(d))) {
    off <- d[r, "off"]; ln <- d[r, "len"]
    if (off + ln > n) next
    if (grepl("GEO_NAME_EN", raw_to_latin1(raw[(off + 1L):(off + ln)]), fixed = TRUE))
      return(c(off = unname(off), len = unname(ln)))
  }
  NULL
}

# Parse the member-array records inside one directory entry's byte window (the entry
# is [off, off+len)); returns the largest Pascal-record sub-block found there, or
# character(0). Bounded to the window so it is cheap even on the big files.
ivt_f2_dir_entry_records <- function(raw, off, len) {
  win <- raw[(off + 1L):min(length(raw), off + len)]
  b <- ivt_find_member_blocks(win, 0L, min_records = 3L)
  if (!length(b)) return(character(0))
  b[[which.max(vapply(b, function(x) length(x$texts), 1L))]]$texts
}

# Strict positional parse of one directory VALUE entry, driven by the entry's own
# block header (the two value-block framings, byte-exact):
#
#   [01 01][u16 payload_len][u16 n_slots] <records>   plain member array: exactly
#       `n_slots` records `[len][text][00]`, where an ABSENT member is stored as an
#       explicit EMPTY record `00 00` -- which the run-scanner above misreads as a
#       separator, splitting the array (98-10-0662 member 26, "Canada outside
#       Quebec and New Brunswick", carries no geography attributes) -- and long
#       records (e.g. the DQF_NOTE suppression texts) parse exactly where the
#       run-scanner fragments. Empties come back as NA so the member positions stay
#       aligned. `n_slots` is the chunk size padded to a power of two (91 members
#       -> 128 slots, trailing slots empty; the 256-member chunks of the big tables
#       carry n_slots = 256), so the caller trims the all-NA tail back to the
#       chunk size.
#   [81 01][u16 nbits][bitstream, u16-padded: 2*ceil(nbits/16) bytes][80|01]
#       <records>   bit-headed DENSE array: records are unterminated `[len][text]`
#       and absent members are skipped entirely, so the caller re-aligns the dense
#       values with the NA pattern of the entry's plain siblings. The bitstream is
#       NOT a per-member presence map (unlike the `[84 01]` footnote bitmap):
#       measured on 98-10-0662's dense arrays, `nbits` >> the member count and the
#       popcount == the records-region byte length + 1, i.e. it is a per-BYTE map
#       of the packed records region, not a per-member one -- so it cannot supply
#       member positions and the sibling NA pattern is the right alignment (see
#       refactor-plan.md §6.1). The one-byte marker before the records is 0x80 or
#       0x01 (semantics unknown; both observed).
#
# Returns list(values, dense) -- `values` with NA holes for a plain array, the
# packed values for a dense one -- or NULL when the entry does not carry either
# framing or does not parse exactly to its declared payload end (the caller falls
# back to the run-scanner). Validated byte-identical to the run-scanner on every
# clean array (no empties) of the chunked reference tables.
ivt_f2_dir_entry_members <- function(raw, off, len) {
  n <- length(raw)
  if (len < 8L || off + len > n) return(NULL)
  b0 <- as.integer(raw[off + 1L]); b1 <- as.integer(raw[off + 2L])
  if (b1 != 0x01L || !(b0 %in% c(0x01L, 0x81L))) return(NULL)
  u16 <- rd_u16(raw, off + 2L)
  vals <- character(512L); k <- 0L
  add <- function(x) { if (k == length(vals)) length(vals) <<- 2L * k
                       k <<- k + 1L; vals[k] <<- x }
  if (b0 == 0x01L) {                                   # plain, NUL-terminated
    if (is.na(u16) || u16 != len - 4L) return(NULL)
    n_slots <- rd_u16(raw, off + 4L)
    if (is.na(n_slots) || n_slots < 1L) return(NULL)
    i <- off + 6L; end <- off + len                    # payload [i, end)
    while (i < end && k < n_slots) {
      L <- as.integer(raw[i + 1L])
      if (L == 0L) {                                   # empty record: 00 00
        if (i + 2L > end || as.integer(raw[i + 2L]) != 0x00L) return(NULL)
        add(NA_character_); i <- i + 2L
      } else {
        if (i + 1L + L + 1L > end || as.integer(raw[i + 1L + L + 1L]) != 0x00L)
          return(NULL)
        add(raw_to_latin1(raw[(i + 2L):(i + 1L + L)])); i <- i + 2L + L
      }
    }
    if (k != n_slots || i != end) return(NULL)         # must parse exactly n_slots
    return(list(values = vals[seq_len(k)], dense = FALSE))
  }
  # 0x81: bit-headed dense array
  if (is.na(u16) || u16 < 1L || u16 > 8L * len) return(NULL)
  i <- off + 4L + 2L * as.integer(ceiling(u16 / 16))   # skip the u16-padded bitstream
  if (i + 1L > off + len || !(as.integer(raw[i + 1L]) %in% c(0x80L, 0x01L)))
    return(NULL)
  i <- i + 1L; end <- off + len
  while (i < end) {
    L <- as.integer(raw[i + 1L])
    if (L == 0L) break                                 # trailing padding
    if (i + 1L + L > end) break
    add(raw_to_latin1(raw[(i + 2L):(i + 1L + L)]))
    i <- i + 1L + L
  }
  if (k < 1L) return(NULL)
  list(values = vals[seq_len(k)], dense = TRUE)
}

# Directory-driven attributes for the ROOT geography chunk (members 1..rootN),
# read positionally from the metadata block directory's offsets/lengths.
#
# The codebook's first ("root") chunk is stored in reverse byte order (region A of
# the tail: the directory's offsets *decrease* through it, then jump up for the
# bulk), so the byte-ascending block scan that `ivt_f2_geo_attributes()` relies on
# reverses that chunk's logical block order. On 98-10-0013 (ADA) the root chunk also
# carries extra framing blocks, so the stride walk not only leaves `geo_type` /
# `geo_level` / `geo_type_abbr` NA but actively **scrambles** `prov_abbr` /
# `alt_geo_code` / `pr_code` (they read codes / French type text).
#
# The block directory lists every codebook block in LOGICAL order with its exact
# offset and length, and within a group the value blocks are laid down as a fixed
# positional sequence -- the display Member Name pair, then every schema field in
# schema order -- each stored EN then FR. So we read the value blocks (those whose
# record count is the chunk size `rootN`) in directory order, pair them, and map:
# pair 1 -> the display name; pair k+1 -> `ivt_f2_geo_schema()[k]`. No marker, no
# content sniffing, no `d0 +/- k*2G` stride: the block starts come from the header
# directory and the field identity from the schema position. Language within a pair
# is decided by `ivt_f2_frscore()` (EN-first here, but structurally, not by order).
# Returns a named list of `rootN`-long vectors keyed by OUTPUT attribute name
# (`ivt_f2_geo_attributes()` columns), or NULL when no directory / schema is present.
ivt_f2_geo_root_dir <- function(raw, n_geo) {
  d <- ivt_f2_geo_block_dir(raw); if (is.null(d)) return(NULL)
  schema <- ivt_f2_geo_schema(raw); if (is.null(schema) || !length(schema)) return(NULL)
  rootN <- min(256L, n_geo)
  npair_want <- length(schema) + 1L                 # display pair + one pair per field
  vals <- list()
  for (r in seq_len(nrow(d))) {
    t <- ivt_f2_dir_entry_records(raw, d[r, "off"], d[r, "len"])
    if (length(t) == rootN) vals[[length(vals) + 1L]] <- trimws(t)
    if (length(vals) >= 2L * npair_want) break
  }
  npair <- length(vals) %/% 2L
  if (npair < 2L) return(NULL)                       # need at least display + GEO_NAME
  pr <- lapply(seq_len(npair), function(k)
    ivt_f2_pick_en(vals[[2L * k - 1L]], vals[[2L * k]]))
  out <- list(geo_label = pr[[1L]]$en, geo_label_fr = pr[[1L]]$fr)
  for (i in seq_along(schema)) {
    if (i + 1L > npair) break
    col <- ivt_f2_stem_col(schema[i])                # schema stem -> output column
    if (is.na(col)) next
    out[[col]] <- pr[[i + 1L]]$en
    if (col == "geo_name") out[["geo_name_fr"]] <- pr[[i + 1L]]$fr
  }
  out
}

ivt_f2_geo_schema <- function(raw, tail_bytes = 600000L)
  ivt_memo(raw, paste0("geo_schema_", tail_bytes),
           function() ivt_f2_geo_schema_impl(raw, tail_bytes))

ivt_f2_geo_schema_impl <- function(raw, tail_bytes = 600000L) {
  # Preferred: follow the file's own metadata directory (a header pointer -> a table
  # of block offsets/lengths) to the *exact* dictionary block, so its start comes
  # from the file rather than a scan. `ivt_f2_geo_dict_block()` confirms the block by
  # its `GEO_NAME_EN` field name, so a directory slot that means something else on a
  # given layout is skipped. Works on the small chunked tables (98-10-0013 / -0478).
  blk <- ivt_f2_geo_dict_block(raw)
  n <- length(raw)
  via_window <- is.null(blk)
  if (!is.null(blk)) {
    s <- raw_to_latin1(raw[(blk[["off"]] + 1L):min(n, blk[["off"]] + blk[["len"]])])
  } else {
    # Last-resort content scan, for a layout whose geography block directory the
    # header slot table did not resolve. On the whole local corpus the slot-table
    # `ivt_f2_geo_dict_block()` above resolves EVERY schema'd table -- including the
    # big tail-codebook ones (98-10-0023 / -0174), since `ivt_f2_dim_dir()`'s
    # two-depth indirection landed -- so this branch never fires today (it used to
    # carry the stale note "routed through a deeper pointer chain we do not decode
    # yet"). Kept as a loud safety net for unseen files: the dictionary sits near
    # the codebook pointer but off-centre (~14 KB before to ~16 KB after), so search
    # a generous window *centred* on it, anchored by the `GEO_NAME_EN` field name.
    cb <- rd_u32(raw, IVT_HDR_CODEBOOK_PTR)
    if (!is.na(cb) && cb >= 1) {
      lo <- max(1L, as.integer(cb) - 131072L); hi <- min(n, as.integer(cb) + 131072L)
    } else {
      lo <- max(1L, n - tail_bytes + 1L); hi <- n
    }
    s <- raw_to_latin1(raw[lo:hi])
  }
  m <- regexpr("GEO_NAME_EN", s, fixed = TRUE)
  if (m < 1L) return(NULL)
  win <- substr(s, m, m + 600L)
  en <- regmatches(win, gregexpr("[A-Z][A-Z0-9_]*_EN", win))[[1]]
  if (!length(en)) return(NULL)
  if (via_window)
    ivt_fallback(paste(
      "The geography attribute schema (GEO_NAME_EN ...) was located by a content",
      "scan of a byte window around the codebook pointer, not through the header",
      "slot-table dictionary block -- the primary metadata path did not resolve it."))
  unique(sub("_EN$", "", en))
}

# Schema-driven, content-free geography for single-block tables: geography is just
# dimension 1, anchored by its codebook doubled-name marker exactly like the data
# dimensions (`ivt_f2_marker_labels()`); the attribute arrays that follow it are
# named by `ivt_f2_geo_schema()` and mapped to fields by **slot**, so no array is
# picked by its content. The arrays after the marker are an optional leading
# display-name pair plus every schema attribute laid down EN then FR; `lead` (0 or
# the 2-block display pair) is derived from the array/attribute counts rather than
# assumed. Returns list(name = GEO_NAME, dguid = DGUID) or NULL when the schema,
# the marker, or a consistent array layout is absent (then the caller falls back to
# the content-based detector). Validated: DGUIDs byte-identical to the legacy
# "2021..." scan on 98-10-0241 (166) and 98-10-0077 (174), with GEO_NAME the
# canonical short name field.
ivt_f2_geo_simple_schema <- function(raw, n_geo, blocks, search_start) {
  attrs <- ivt_f2_geo_schema(raw)
  if (is.null(attrs)) return(NULL)
  ni <- match("GEO_NAME", attrs); di <- match("DGUID", attrs)
  if (is.na(ni) || is.na(di)) return(NULL)
  d <- ivt_f2_descriptor(raw)
  geo <- ivt_f2_geo_dim(if (is.null(d)) NULL else d$dims)   # geography is dim 1
  if (is.null(geo)) return(NULL)
  markers <- ivt_f2_codebook_dim_markers(raw, search_start)
  hit <- which(vapply(markers$name, ivt_f2_name_match, logical(1), b = geo$name))
  if (!length(hit)) return(NULL)
  geomk <- markers$offset[hit[1]]
  after <- Filter(function(b) b$start > geomk && length(b$texts) == n_geo, blocks)
  after <- after[order(vapply(after, function(b) b$start, 1))]
  lead <- length(after) - 2L * length(attrs)             # optional display-name pair
  if (!(lead %in% c(0L, 2L)) || length(after) < 2L * length(attrs) + lead)
    return(NULL)
  en <- function(k) after[[lead + 2L * (k - 1L) + 1L]]$texts  # the k-th attr, EN copy
  list(name = en(ni), dguid = en(di))
}

# Cheap geography names + DGUIDs for tables whose geography codebook is a single
# clean block per attribute (the small family-1 reference tables, e.g. 166
# geographies in 98-10-0241), located schema-driven and content-free via
# `ivt_f2_geo_simple_schema()` (each attribute array addressed by its schema
# field name, not sniffed by content). Returns NULL when the schema does not
# resolve a single length-`n_geo` name block -- the large family-2 tables (tens
# of thousands of geographies) store the attributes attribute-major in 256-member
# chunks, so their names need the slower `ivt_f2_geo_attributes()` path (via
# read_ivt(geo_attributes = TRUE)) instead. (The former content-based array
# detector `ivt_geo_arrays()` -- with its "^2021"/"Canada" literals -- was
# retired 2026-07-11: a full-corpus branch trace showed no table ever reached it
# in `ivt_f2_geo_light()`; inline / attrs_dir / uid-only cover every file.)
ivt_f2_geo_simple <- function(raw, n_geo, tail_bytes = 200000L) {
  if (is.na(n_geo) || n_geo < 1L) return(NULL)
  start <- max(0L, length(raw) - tail_bytes)
  blocks <- ivt_find_member_blocks(raw, start, min_records = 3L)
  if (!length(blocks)) return(NULL)
  ivt_f2_geo_simple_schema(raw, n_geo, blocks, start)
}

# The metadata light path and the full `geo_attributes = TRUE` path are two
# deliberately-different CONTRACTS over the SAME dispatcher (`ivt_f2_geo_read()`
# below): the light default returns a list of per-member columns (`geo_label(_fr)`
# / `geo_name(_fr)` / `geo_uid` plus whatever attributes the layout stores),
# packed downstream into `metadata$geographies` with all-NA columns dropped; the
# full path keeps every column (incl. all-NA) as a tibble. `full` also selects the
# CHEAP readers (uid-only for the big chunked tables) over the ~30 s complete
# attribute scan. Not a merge candidate -- see refactor-plan.md §5.1.
#
# The single geography DISPATCHER (refactor-plan.md §7.3): one ordered specializer
# chain that both entry points share, run once. `full` selects only the SCHEMA
# step -- the cheap light readers (single-chunk `attrs_dir`, the schema-named
# single block, the uid-only DGUID scan) vs the comprehensive full attribute scan
# (`ivt_f2_geo_attributes()`, the read_ivt(geo_attributes = TRUE) path). Every
# other specializer -- origin-destination flow, the pre-DGUID inline codebook, the
# 2016 custom-extract lineage, the Business Patterns bare-code codebook -- is
# SHARED, so the full path now decodes custom / bare tables too (it previously fell
# to `ivt_f2_geo_attributes()`, which returns an all-NA tibble for a schema-less
# table -- a latent bug, since that path is not corpus-covered).
#
# Returns the winning specializer's NATIVE object (a tibble for inline/flow/attr
# readers, a list for the custom/bare/uid readers), with the uid column already
# renamed to `geo_uid`; the two wrappers apply their distinct contracts (§5.1:
# light = list with all-NA columns dropped; full = tibble keeping every column).
ivt_f2_geo_read <- function(raw, full = FALSE) {
  n_geo <- ivt_f2_geo_count(raw)
  # 1. inline family (flow -> pre-DGUID inline codebook -> marker-region scan). It
  #    returns NULL for the schema'd DGUID tables, so they fall through to the
  #    schema step; it wins for the schema-absent 1991/2006/2011/2016 vintages
  #    (incl. the single-block 2016 case whose uid is the bare code in the combined
  #    block). Light gates on the declared count; full accepts it unconditionally.
  g <- ivt_f2_geo_inline(raw)
  if (!is.null(g) && (full || is.na(n_geo) || nrow(g) == n_geo)) {
    names(g)[names(g) == "geouid"] <- "geo_uid"
    return(g)       # incl. dqf_code: on the 2016 tables its last digit marks
  }                 # wholly-suppressed geographies
  # 2. schema'd attribute codebook.
  if (full) {
    # the comprehensive attribute scan, but only when a geography schema exists --
    # otherwise a schema-less custom/bare table would be claimed here with an
    # all-NA table instead of reaching its specializer below.
    if (!is.null(ivt_f2_geo_schema(raw))) {
      g <- ivt_f2_geo_attributes(raw)
      names(g)[names(g) == "dguid"] <- "geo_uid"
      return(g)
    }
  } else {
    # single-chunk schema'd tables (98-10-0241/0077/0662): the directory-driven
    # positional attribute read is cheap here (one group of one chunk) and fully
    # metadata-addressed; trim = FALSE keeps the hierarchy indentation. GEO_NAME can
    # carry legitimate NA holes (98-10-0662's derived aggregate member has no
    # attributes); the display Member Name (`geo_label`), which every member
    # carries, must be complete for the read to be accepted. Bigger tables skip this
    # (~20 s on a 63k-geography codebook; the uid scan below is ~3x faster).
    if (!is.na(n_geo) && n_geo <= 256L) {
      at <- ivt_f2_geo_attrs_dir(raw, trim = FALSE)
      if (!is.null(at) && nrow(at) == n_geo &&
          (!anyNA(at$geo_label) || !anyNA(at$geo_name))) {
        names(at)[names(at) == "dguid"] <- "geo_uid"
        return(at)
      }
    }
    # schema-named single block (2021 DGUID) or the content-based array detector
    simple <- ivt_f2_geo_simple(raw, n_geo)
    if (!is.null(simple)) {
      geo_uid <- if (length(simple$dguid) == n_geo) simple$dguid
                 else ivt_f2_geo_uids(raw)
      return(list(geo_name = simple$name, geo_uid = geo_uid))
    }
  }
  # 3. the 2016 custom-extract lineage (CRO0163850 / CRO0166131): geography is
  #    structured like a data dimension (an `81 02 01 00` name marker then one
  #    combined-string member array, no GEO_NAME_EN schema, English only).
  cust <- ivt_f2_geo_custom(raw, n_geo)
  if (!is.null(cust)) return(cust)
  # 4. the Canadian Business Patterns lineage: a chunked codebook of bare numeric
  #    GEOUIDs (8-digit DA codes), no DGUID shape and no GEO_NAME schema.
  bare <- ivt_f2_geo_bare_codes(raw, n_geo)
  if (!is.null(bare)) return(bare)
  # 5. chunked DGUID tables (0023/0129/0013/...): the uid-only read is the primary
  #    for these (their names come from the read_ivt(geo_attributes = TRUE) path).
  #    A COMPLETE uid array is the expected outcome here, so it wins.
  uid <- ivt_f2_geo_uids(raw)
  if (length(uid) == n_geo) return(list(geo_name = NULL, geo_uid = uid))
  # 6. Stage 3 safety net (refactor-plan.md §7.4): nothing above claimed the
  #    layout AND the uid scan came up short -- rather than emit nameless
  #    geography, surface the codebook's own member strings VERBATIM (loud).
  combined <- ivt_f2_geo_combined(raw, ivt_f2_geo_entries(raw), n_geo)
  if (!is.null(combined)) return(combined)
  list(geo_name = NULL, geo_uid = uid)
}

# Assemble the geography codebook's member arrays into full member-length runs,
# positionally -- the SAME power-of-two-nested group/chunk geometry the schema'd
# `ivt_f2_geo_attrs_dir()` uses, but WITHOUT needing a schema to say how many
# attributes there are. The codebook stores `n_runs` parallel arrays (the display
# name, then each attribute, each stored EN then FR) interleaved within groups of
# `G` 256-member chunks (`ivt_f2_chunk_layout()`). We infer `n_runs` from the block
# count (`k / total_chunks`) and stitch each run across the groups. Returns a list
# of `n_geo`-long character vectors (one per run, in storage order), or NULL when
# the blocks do not divide evenly into whole runs (not a clean chunk roster).
# Blocks come from Stage 1 (`ents$values`, strict-first); a single-chunk table
# (`n_geo <= 256`, `total_chunks == 1`) degenerates to one run per block.
ivt_f2_geo_assemble_runs <- function(ents, n_geo) {
  blocks <- list()
  for (r in seq_len(ents$n)) {
    v <- ents$values(r); if (is.null(v)) next
    v <- trimws(v)
    if (length(v) < 3L || length(v) > 256L || ivt_f2_is_ordinal(v)) next
    if (all(is.na(v) | v == "")) next
    blocks[[length(blocks) + 1L]] <- v
  }
  k <- length(blocks); if (!k) return(NULL)
  lay <- ivt_f2_chunk_layout(n_geo); total <- lay$n_chunks
  if (k %% total != 0L) return(NULL)             # stray blocks -> not a clean roster
  n_runs <- k %/% total
  gstart <- cumsum(c(1L, utils::head(n_runs * lay$sizes, -1L)))  # block span/group = n_runs*G
  lapply(seq_len(n_runs) - 1L, function(run_j) {
    out <- rep(NA_character_, n_geo)
    for (gi in seq_along(lay$groups)) {
      grp <- lay$groups[[gi]]; G <- grp$G; bi <- gstart[gi] + run_j * G
      for (c in seq_len(G)) {
        t <- blocks[[bi + c - 1L]]; w <- grp$chunk[c]
        if (length(t) > w &&
            all(is.na(t[(w + 1L):length(t)]) | t[(w + 1L):length(t)] == ""))
          t <- t[seq_len(w)]                     # trim power-of-two slot padding
        idx <- grp$start + 256L * (c - 1L) + seq_along(t) - 1L
        ok <- idx <= grp$start + grp$size - 1L
        out[idx[ok]] <- t[ok]
      }
    }
    out
  })
}

# The geography dimension's field dictionary, when it carries one. Some exports
# (the EO custom lineage) store geography EXACTLY like a data dimension: a
# `81 02 <nfields> 00` dictionary block that NAMES its columns in order -- the same
# "Code / English Desc / Desc Francais / ..." vocabulary a data-dim dictionary uses
# (`ivt_f2_dim_dict_en_first()`), not the modern DGUID attribute schema
# (`GEO_NAME_EN` ...) that `ivt_f2_geo_schema()` recognises. Each stored column is a
# `[02][len][name]` record (the key "Code" field uses a different framing and is the
# member ordinal, not a stored run), so the `[02]` records name the value runs in
# storage order. Returns the ordered field names (latin-1, so "Desc Francais" and
# other accented names survive), or NULL when the geography directory carries no
# such dictionary. This makes the run -> column mapping METADATA-DRIVEN rather than
# a content guess (see `ivt_f2_geo_combined()`).
ivt_f2_geo_field_schema <- function(raw, ents) {
  if (is.null(ents) || is.null(ents$dir)) return(NULL)
  # geography's dictionary is read by the SAME generic reader every dimension uses
  # (dim-members.R) -- the whole point of the field dictionary is that geography and
  # data dimensions share it. `ents$dir` is the geography block-directory matrix.
  ivt_f2_dim_field_schema(raw, ents$dir)
}

# Assign the geography schema field names to member roles. The file's OWN field
# names decide -- the same principle as `ivt_f2_dim_dict_en_first()` reading
# "English Desc" / "Desc Francais". `UID`/`IDU` is the uid; a French description
# is `geo_name_fr`; any other description / name field is `geo_name`; every other
# field (Geo Code, Level, data-quality) is not surfaced. Returns an integer role
# per field: 1 name, 2 name_fr, 3 uid, NA otherwise.
ivt_f2_geo_field_roles <- function(fields) {
  vapply(fields, function(f) {
    u <- toupper(f)
    if (grepl("UID|IDU", u)) 3L
    else if (grepl("FRAN", u)) 2L                      # "Desc Francais" / "Français"
    else if (grepl("DESC|NAME|NOM", u)) 1L
    else NA_integer_
  }, integer(1), USE.NAMES = FALSE)
}

# Stage 3 of the geography read (refactor-plan.md §7.4): the last-resort catch-all,
# reached only when no specializer recognized the layout and the uid scan did not
# deliver a complete array. It follows the owner's directive -- locate the geography
# metadata like any other dimension (Stage 1 `ents`), recover each item positionally
# (`ivt_f2_geo_assemble_runs()`, the schema-free chunk assembler), THEN identify the
# columns -- PREFERRING the file's own field dictionary when it has one:
#   - if the geography directory carries a `81 02` field dictionary
#     (`ivt_f2_geo_field_schema()`) whose named columns match the assembled runs
#     one-to-one, the mapping is METADATA-DRIVEN: `geo_name` = the English
#     description field, `geo_name_fr` = the French one, `geo_uid` = the field the
#     file NAMES "UID/IDU" (`ivt_f2_geo_field_roles()`). No content guessing.
#   - otherwise the columns are deciphered heuristically: `geo_name` = the most
#     word-like run (letters + multi-word/near-unique; EN/FR pair by
#     `ivt_f2_frscore()`), `geo_uid` = a unique, space-free, digit-bearing code run;
#     and if NO run reads as a name, every run is joined per member into one
#     verbatim string (the directive's "entire member information as a string").
# LOUD (`canivt_geo_unparsed`, a strict-mode error): even the schema-mapped read is
# not the validated primary positional decode, so a consumer knows to inspect it.
# Returns a light-style column list, or NULL when the blocks are not a clean roster.
ivt_f2_geo_combined <- function(raw, ents, n_geo) {
  if (is.null(ents) || is.na(n_geo) || n_geo < 1L) return(NULL)
  runs <- ivt_f2_geo_assemble_runs(ents, n_geo)
  if (is.null(runs) || !length(runs)) return(NULL)
  # PRINCIPLED path: the geography dimension's own field dictionary names the runs.
  fields <- ivt_f2_geo_field_schema(raw, ents)
  if (!is.null(fields) && length(fields) == length(runs)) {
    roles <- ivt_f2_geo_field_roles(fields)
    ni <- which(roles == 1L); fi <- which(roles == 2L); ui <- which(roles == 3L)
    if (length(ni) >= 1L) {                            # a named-column layout
      name <- runs[[ni[1L]]]
      out <- list(geo_label = name, geo_name = name,
                  geo_uid = if (length(ui)) runs[[ui[1L]]] else rep(NA_character_, n_geo))
      if (length(fi)) out$geo_name_fr <- runs[[fi[1L]]]
      ivt_fallback(paste(
        "Geography layout unrecognized by every specializer; recovered {n_geo}",
        "member(s) by assembling the codebook's arrays positionally and mapping",
        "them to columns via the dimension's OWN field dictionary",
        "({paste(fields, collapse = ' / ')})."),
        class = "canivt_geo_unparsed")
      return(out)
    }
  }
  nn_of  <- function(v) v[!is.na(v) & nzchar(v)]
  spaces   <- function(v) { nn <- nn_of(v); if (!length(nn)) 0 else mean(grepl("[[:space:]]", nn)) }
  letters  <- function(v) { nn <- nn_of(v); if (!length(nn)) 0 else mean(grepl("[A-Za-z]", nn)) }
  distinct <- function(v) { nn <- nn_of(v); if (!length(nn)) 0 else length(unique(nn)) / n_geo }
  codelike <- function(v) { nn <- nn_of(v)                     # a bare identifier token
                            if (!length(nn)) 0
                            else mean(grepl("^[0-9A-Za-z-]+$", nn) & !grepl("[[:space:]]", nn)) }
  digits   <- function(v) { nn <- nn_of(v); if (!length(nn)) 0 else mean(grepl("[0-9]", nn)) }
  namelike <- function(v) { nn <- nn_of(v)                     # human display content
                            if (!length(nn)) 0
                            else mean(grepl("[[:space:]]|[[:lower:]]", nn)) }
  S <- vapply(runs, spaces, 0);   L <- vapply(runs, letters, 0)
  D <- vapply(runs, distinct, 0); C <- vapply(runs, codelike, 0)
  G <- vapply(runs, digits, 0);   N <- vapply(runs, namelike, 0)
  # UID run(s): fully-unique, uniform single-token codes with NO spaces and carrying
  # DIGITS (so a single-word NAME like "Canada" -- alphanumeric and unique but with
  # no digit -- and a mixed name/code display run like "Vancouver CMA (933)" beside
  # a bare DA code are not mistaken for the uid). Prefer a type-tagged code (letters,
  # e.g. "CD1001") over a bare numeric one.
  is_uid <- D > 0.9 & S < 0.01 & C > 0.9 & G > 0.9
  uid <- rep(NA_character_, n_geo)
  uid_runs <- integer(0)
  if (any(is_uid)) {
    cand <- which(is_uid)
    ui <- cand[which.max(L[cand])]
    uid <- runs[[ui]]; uid_runs <- ui
  }
  # NAME run(s): the display column(s) -- the most human-readable NON-uid run
  # (spaces / lower-case), or, when nothing reads as a name (all members are bare
  # codes), simply the first non-uid run. Two clearly-wordy runs are an EN/FR pair.
  geo_name <- geo_name_fr <- label <- NULL
  rest <- setdiff(seq_along(runs), uid_runs)
  if (length(rest)) {
    wordy <- rest[N[rest] > 0.5]
    if (length(wordy) >= 2L) {                                 # EN/FR display pair
      wordy <- wordy[order(N[wordy], decreasing = TRUE)][1:2]
      en <- wordy[1L]; fr <- wordy[2L]
      if (ivt_f2_frscore(nn_of(runs[[en]])) > ivt_f2_frscore(nn_of(runs[[fr]]))) {
        tmp <- en; en <- fr; fr <- tmp                         # en is the less-French copy
      }
      geo_name <- runs[[en]]; geo_name_fr <- runs[[fr]]; label <- runs[[en]]
    } else {
      ni <- if (length(wordy)) wordy[which.max(N[wordy])] else rest[which.max(N[rest])]
      if (N[ni] == 0) ni <- rest[1L]                           # no display content: first run
      geo_name <- runs[[ni]]; label <- runs[[ni]]
    }
  }
  deciphered <- !is.null(geo_name)                             # a run read as the name
  if (!deciphered) {                                           # LAST RESORT: verbatim string
    label <- do.call(paste, c(lapply(runs, function(r) ifelse(is.na(r), "", r)), sep = " | "))
    label <- trimws(gsub("(\\s\\|)+\\s*$", "", label))          # drop trailing empty fields
    geo_name <- label
  }
  ivt_fallback(paste(
    "Geography layout unrecognized by every specializer; recovered {n_geo}",
    "member(s) by assembling the codebook's own arrays positionally, then",
    if (deciphered) "deciphering the name/uid columns heuristically."
    else "joining every array per member into one verbatim string.",
    "Inspect the geography metadata."),
    class = "canivt_geo_unparsed")
  out <- list(geo_label = label, geo_name = geo_name, geo_uid = uid)
  if (!is.null(geo_name_fr)) out$geo_name_fr <- geo_name_fr
  out
}

ivt_f2_geo_light <- function(raw, n_geo) {
  g <- ivt_f2_geo_read(raw, full = FALSE)
  # the light contract: a list of per-member columns (all-NA columns dropped
  # downstream when packed into metadata$geographies). Drop the tibble scaffolding
  # (member_id) where a specializer returned a tibble; the uid column is already
  # `geo_uid`. The list-returning specializers pass through unchanged.
  if (is.data.frame(g)) g <- as.list(g[setdiff(names(g), "member_id")])
  g
}

# Extract the contiguous run of `[len][ascii-digits]` Pascal records that a
# Business Patterns geography chunk stores in its tail (after a packed 22-bit
# attribute field). `len` in 5..11 covers the 8-digit DA GEOUIDs with headroom.
# Scans byte-by-byte through the binary prefix, then reads the code array until
# the first non-record byte. Returns the codes in storage order, or character(0).
ivt_f2_scan_digit_records <- function(raw, off, len) {
  end <- off + len; i <- off
  acc <- vector("list", 2048L); k <- 0L; run <- FALSE
  while (i + 1L < end) {
    L <- as.integer(raw[i + 1L])
    if (L >= 5L && L <= 11L && i + 1L + L <= end &&
        all(raw[(i + 2L):(i + 1L + L)] >= as.raw(0x30) &
            raw[(i + 2L):(i + 1L + L)] <= as.raw(0x39))) {
      k <- k + 1L; acc[[k]] <- rawToChar(raw[(i + 2L):(i + 1L + L)])
      i <- i + 1L + L; run <- TRUE
    } else {
      if (run) break                    # end of the tail code array
      i <- i + 1L
    }
  }
  if (k == 0L) character(0) else unlist(acc[seq_len(k)], use.names = FALSE)
}

# Geography for the Canadian Business Patterns lineage (Business Register
# establishment counts by Dissemination Area, e.g. Dec07DA.ivt). Its geography
# codebook stores bare numeric GEOUIDs -- 8-digit DA codes like "59150001" -- as
# dense `[len][ascii-digits]` Pascal records in the tail of each `81 02 00 04`
# directory chunk (each chunk is a packed 22-bit attribute field then the code
# array), single language, with NO DGUID shape and NO GEO_NAME schema. The inline
# / schema / DGUID readers therefore all return NULL. Read the codes positionally
# from the geography dimension's slot directory (chunks are in member-id order,
# codes globally sorted), gated on recovering exactly `n_geo` unique all-numeric
# codes so no other table engages it. A DA carries no textual name, only the
# code, so `geo_name` is the code itself. LOUD (a content parse of the code
# records supplies the uids).
ivt_f2_geo_bare_codes <- function(raw, n_geo) {
  if (is.na(n_geo) || n_geo < 1L) return(NULL)
  ents <- ivt_f2_geo_entries(raw)                       # Stage 1 (shared locator)
  if (is.null(ents)) return(NULL)
  dir <- ents$dir                                       # its own digit-record scan
  n <- length(raw)
  parts <- vector("list", nrow(dir))
  for (r in seq_len(nrow(dir))) {
    off <- dir[r, "off"]; len <- dir[r, "len"]
    if (len < 8L || off + len > n) next
    parts[[r]] <- ivt_f2_scan_digit_records(raw, off, len)
  }
  codes <- unlist(parts, use.names = FALSE)
  if (length(codes) != n_geo || anyDuplicated(codes)) return(NULL)
  ivt_fallback(paste(
    "Geography decoded as bare numeric GEOUIDs from the codebook's",
    "[len][digits] code records (Business Patterns Dissemination-Area",
    "lineage); a DA has no name, so `geo_name` is the code."),
    "canivt_geo_bare_codes")
  list(geo_name = codes, geo_uid = codes)
}

# Geography for the 2016 custom-extract lineage (CRO0163850 / CRO0166131). Its
# geography dimension is laid out exactly like a DATA dimension -- a slot
# directory with the `81 02 01 00` name marker followed by a single English
# member-label array (no French copy, no GEO_NAME_EN schema) -- so every reader
# above (inline combined block, GEO_NAME_EN schema, DGUID scan) returns NULL. The
# member strings are combined "<name> <code> (  <gnr>%)" (e.g. "Canada 20000
# (  5.1%)", "Vancouver CMA 933 00001 (  5.7%)", "Newfoundland and Labrador (10)
# 00000 (  6.8%)"). Read that array positionally through the same slot-directory
# machinery the data dimensions use, then split each string into its name and its
# trailing geography code (the uid). Gated on the trailing "(  N%)" GNR signature
# so it engages only for this lineage; LOUD, as a content parse supplies the split.
ivt_f2_geo_custom <- function(raw, n_geo) {
  if (is.na(n_geo) || n_geo < 1L) return(NULL)
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(NULL)
  gi <- ivt_f2_geo_dim_index(raw, d)
  ents <- ivt_f2_geo_entries(raw)                       # Stage 1 (shared locator)
  if (is.null(ents)) return(NULL)
  dir <- ents$dir                                       # its own marker + member-array walk
  mk <- ivt_f2_dir_marker_entry(raw, d$dims[[gi]]$name, dir)
  if (mk <= 0L || mk >= nrow(dir)) return(NULL)
  cand <- ivt_f2_dir_member_arrays(
    raw, dir, n_geo, rows = (mk + 1L):nrow(dir), max_keep = 1L,
    accept = function(t) {
      if (any(grepl("[[:cntrl:]]", t)) || !all(nzchar(t))) return(NULL)
      t
    })
  if (!length(cand)) return(NULL)
  labels <- cand[[1L]]
  gnr <- "\\(\\s*[0-9][0-9.]*\\s*%\\)\\s*$"           # trailing GNR, the signature
  if (mean(grepl(gnr, labels)) < 0.5) return(NULL)    # not this lineage
  body <- trimws(sub(gnr, "", labels))                # "<name> <code>"
  code <- sub("^.*?([0-9][0-9 ]*[0-9]|[0-9])\\s*$", "\\1", body)
  code <- ifelse(code == body, NA_character_, gsub(" ", "", code))
  name <- trimws(sub("\\s+[0-9][0-9 ]*$", "", body))  # drop the trailing code
  ivt_fallback(paste(
    "Geography decoded from the 2016 custom-extract combined name array",
    "(\"<name> <code> (gnr%)\"); name and code split by content."),
    "canivt_geo_custom")
  list(geo_label = labels, geo_name = name,
       geo_uid = ifelse(is.na(code) | !nzchar(code), NA_character_, code))
}

# Backfill `geo_name` from the display `geo_label` for members that carry a label
# but no schema GEO_NAME. Synthetic AGGREGATE geographies -- 98-10-0662's member 26,
# "Canada outside Quebec and New Brunswick" -- are constructed at tabulation time and
# store only the human-readable display label; the schema attribute arrays (GEO_NAME,
# DGUID, level, type, ...) hold nothing for them, so those columns decode NA. The
# member has a real, meaningful name (the label), so we use it for `geo_name` rather
# than leave the row nameless downstream. This is metadata-driven -- the label is
# what the file stores for the member -- and applies to any table with such
# aggregates, not a hard-coded member. The uid / level / type genuinely have no value
# in the file and stay NA (an aggregate has no DGUID). Loud: the value is derived, not
# read from its own attribute slot. `g$geo_name_fr` is filled from `geo_label_fr` the
# same way when both are present.
ivt_f2_geo_fill_label <- function(g) {
  if (is.null(g$geo_name) || is.null(g$geo_label)) return(g)
  miss <- is.na(g$geo_name) & !is.na(g$geo_label)
  if (!any(miss)) return(g)
  g$geo_name[miss] <- g$geo_label[miss]
  if (!is.null(g$geo_name_fr) && !is.null(g$geo_label_fr)) {
    mf <- is.na(g$geo_name_fr) & !is.na(g$geo_label_fr)
    g$geo_name_fr[mf] <- g$geo_label_fr[mf]
  }
  ivt_fallback(paste(
    "{sum(miss)} geography member(s) carry a display label but no schema GEO_NAME",
    "(synthetic aggregate geographies); `geo_name` was derived from `geo_label`.",
    "Their `geo_uid`/`geo_level` remain NA -- an aggregate has none in the file."))
  g
}

# The DQF_NOTE suppression text is stored in a Pascal record whose length prefix
# is a SINGLE byte, so the container cannot hold a note longer than 252 chars
# (0xFC -- the maximum record length observed across the corpus). StatCan's own
# writer stores longer notes truncated at that ceiling (2,448 members on 98-10-0129,
# 90 on 98-10-0478). Confirmed at the byte level: a truncated record is
# `[FC][252 text bytes][00]`, the text cut mid-word, and the byte immediately after
# the 0x00 terminator opens the NEXT member's record (a fresh `[len][text]`) -- there
# is NO continuation record, so the tail is genuinely absent from the file, not
# something we fail to read. Our read is therefore byte-exact: this is a container
# limitation, not a decode gap -- but it IS silent data loss, so we mark which
# members carry a note sitting at the ceiling (presumed truncated -- the ceiling is
# the only signal the format offers; a complete note that happens to be exactly 252
# chars is an unavoidable false positive) and warn loudly
# (`ivt_f2_flag_dqf_note_truncation()`). The UNtruncated text is not in the .ivt but
# IS in StatCan's authoritative metadata (WDS `getCubeMetadata` `geoAttribute.valueEn`,
# or the table's CSV-download metadata) -- confirmed: 98-10-0478 CT 0010.00 is 252
# chars here vs the WDS's full 375. We do not fetch it (per the metadata-driven,
# no-external-ground-truth rule); the flag tells a consumer where to look if needed.
IVT_DQF_NOTE_CAP <- 252L

ivt_f2_dqf_note_truncated <- function(note) {
  if (is.null(note)) return(NULL)
  out <- nchar(note) >= IVT_DQF_NOTE_CAP
  out[is.na(note)] <- NA
  out
}

# Attach a `dqf_note_truncated` companion flag beside `dqf_note` (works on the
# geography list of the default path and the attribute tibble of
# `ivt_f2_geographies()`) and, when any note is truncated at the container ceiling,
# raise a loud classed notice. A no-op when the object carries no `dqf_note` -- most
# tables, and the uid-only default path of the big chunked tables (their notes are
# read only via `read_ivt(geo_attributes = TRUE)`).
ivt_f2_flag_dqf_note_truncation <- function(g) {
  note <- g[["dqf_note"]]
  if (is.null(note)) return(g)
  trunc <- ivt_f2_dqf_note_truncated(note)
  g[["dqf_note_truncated"]] <- trunc
  n <- sum(trunc, na.rm = TRUE)
  n_notes <- sum(!is.na(note)); cap <- IVT_DQF_NOTE_CAP
  if (n > 0L)
    ivt_source_truncation(c(
      paste("{n} of {n_notes} DQF_NOTE value(s) are stored TRUNCATED in the file at",
            "the container's {cap}-character single-byte record ceiling."),
      i = paste("The read is byte-exact -- this is a container limit, not a decode",
                "gap; `dqf_note_truncated` marks the affected geography members.")),
      class = "canivt_dqf_note_truncated")
  g
}

# The uid-only read: the positional block-directory parse first (it sees the
# logical member order the byte scan cannot -- 98-10-0013's reverse-stored root
# chunk sits below the marker region and the scan silently dropped members 1-256),
# the byte scan as the loud fallback.
ivt_f2_geo_uids <- function(raw) {
  uid <- ivt_f2_geo_dguids_dir(raw)
  if (!is.null(uid)) return(uid)
  ivt_fallback(paste(
    "The geography block directory did not resolve the DGUID member blocks;",
    "scanning the codebook bytes for DGUID-shaped strings instead."))
  ivt_f2_geo_dguids(raw)
}

# --- Full geography attribute table ------------------------------------------
#
# Each geography member carries ~11 attributes, stored in the codebook as
# member-ordered chunks of 256 grouped attribute-major: groups grow in size
# (1, 1, 2, 4, 8, ... 256-member chunks), and within a group every attribute is
# laid down as G English blocks (chunk 0..G-1) then G French blocks, in the schema
# field order. DGUID is the schema's DGUID slot, so a group's first block (NAME
# English chunk 0) is at `dguid_chunk0_block - dguid_slot*2*G`. The slot order and
# the DGUID slot both come from the file's schema (`ivt_f2_geo_slot_map()`), the
# group boundaries from `ivt_f2_geo_groups_chunked()` -- no year literal, no
# hard-coded slot table. Validated exact vs the StatCan metadata.

# Slot order of the 11 geography attributes (0-indexed); DGUID is slot 5. This is
# now only the FALLBACK order: the slot of each attribute is read from the file's
# own geography attribute schema (`ivt_f2_geo_schema()`) via `ivt_f2_geo_slot_map()`
# and this fixed table is used only when that schema field list is absent.
IVT_F2_ATTR_SLOTS <- c(
  geo_name = 0L, geo_type = 1L, geo_type_abbr = 2L, geo_level = 3L,
  prov_abbr = 4L, dguid = 5L, alt_geo_code = 6L, pr_code = 7L,
  dqf_code = 8L, dqf_note = 9L, tnr_short_form = 10L)

# Map each output attribute to its schema field stem. The codebook attribute schema
# (`ivt_f2_geo_schema()`) is the file's ordered field list, and a field's 0-based
# position in it IS that attribute's slot in the group layout, so the slots are read
# from the file rather than hard-coded. Field names may be stored truncated
# (`GEO_LEVEL_DES`, `TNR_SHORT_FOR`), so match by prefix in either direction.
IVT_F2_ATTR_FIELD <- c(
  geo_name = "GEO_NAME", geo_type = "GEO_TYPE_DESC", geo_type_abbr = "GEO_TYPE_ABBR",
  geo_level = "GEO_LEVEL", prov_abbr = "PROV_ABBR", dguid = "DGUID",
  alt_geo_code = "ALT_GEO_CODE", pr_code = "PR_CODE", dqf_code = "DQF_CODE",
  dqf_note = "DQF_NOTE", tnr_short_form = "TNR_SHORT")

# Output column for one schema field stem, by prefix match in either direction
# (stems may be stored truncated: GEO_LEVEL_DES vs GEO_LEVEL, TNR_SHORT_FOR).
# NA for a field outside the attribute set (e.g. TNR_LONG_FORM -- consumed
# positionally and skipped). `ivt_f2_geo_slot_map()` applies the same matching
# rule in the field -> slot direction.
ivt_f2_stem_col <- function(stem) {
  hit <- which(startsWith(stem, IVT_F2_ATTR_FIELD) | startsWith(IVT_F2_ATTR_FIELD, stem))
  if (length(hit)) names(IVT_F2_ATTR_FIELD)[hit[1L]] else NA_character_
}

# Slot index (0-based) of every geography attribute, read from the file's schema
# field list. Falls back to the fixed `IVT_F2_ATTR_SLOTS` order when the schema is
# absent or does not name every attribute. Validated to reproduce `IVT_F2_ATTR_SLOTS`
# exactly on 98-10-0023, 98-10-0129 and 98-10-0241.
ivt_f2_geo_slot_map <- function(raw) {
  schema <- ivt_f2_geo_schema(raw)
  if (is.null(schema) || !length(schema)) {
    ivt_fallback(paste(
      "No geography attribute schema (field list) was found; using the fixed",
      "2021-census attribute slot order."))
    return(IVT_F2_ATTR_SLOTS)
  }
  slots <- vapply(IVT_F2_ATTR_FIELD, function(field) {
    hit <- which(startsWith(schema, field) | startsWith(field, schema))
    if (length(hit)) hit[1L] - 1L else NA_integer_
  }, integer(1))
  names(slots) <- names(IVT_F2_ATTR_FIELD)
  if (anyNA(slots)) {                           # unexpected schema shape -> fallback
    ivt_fallback(paste(
      "The geography attribute schema does not name every expected attribute",
      "({.val {names(slots)[is.na(slots)]}}); using the fixed 2021-census",
      "attribute slot order."))
    return(IVT_F2_ATTR_SLOTS)
  }
  slots
}

# Clean attribute blocks from the codebook tail: member arrays only -- drop the
# tiny garbage byte-runs the block scanner picks up and the consecutive-integer
# member-ordinal delimiter blocks, both of which would shift positional indexing.
#
# The full 256-member chunks are always kept. A chunk group's LAST chunk is a
# partial (`n_geo mod 256` members) and can fall below any fixed size floor -- e.g.
# 98-10-0013's last group ends in a 71-member partial, so the old blunt
# `length(t) >= 150` floor silently dropped the trailing DGUID/name/code partials
# and undercounted that group (5,376 of 5,447 geographies). Instead of a magic
# size, a partial is recognised *structurally*: a small but clean member-array
# block (no control bytes, no single repeated byte, low fraction / not an ordinal
# delimiter) that **immediately follows a full member block** -- i.e. it trails its
# own attribute's full chunks. Garbage byte-runs cluster on their own and never
# trail a real member array, so they are still dropped.
ivt_f2_codebook_blocks <- function(raw, tail_bytes = 20000000L) {
  start <- max(0L, length(raw) - tail_bytes)
  blocks <- ivt_find_member_blocks(raw, start, min_records = 3L)
  blocks <- blocks[order(vapply(blocks, function(b) b$start, 1))]
  is_ord <- function(t) {
    iv <- suppressWarnings(as.integer(t))
    !anyNA(iv) && length(iv) >= 3L && all(diff(iv) == 1L)
  }
  is_clean <- function(t) mean(grepl("[\u00bd\u00be\u00bc\u00f7\u00d7\u00de\u00fe{}]", t)) < 0.3 && !is_ord(t)
  # a clean member array too short for the full-chunk floor -- kept only as a
  # trailing partial (see below): no control chars, not a repeated single byte,
  # mostly multi-character values.
  is_partial <- function(t)
    length(t) >= 8L && length(t) < 150L && is_clean(t) &&
    !any(grepl("[[:cntrl:]]", t)) && !any(grepl("^(.)\\1*$", t)) &&
    mean(nchar(t) >= 2L) > 0.8
  keep <- logical(length(blocks))
  prev_full <- FALSE
  for (i in seq_along(blocks)) {
    t <- blocks[[i]]$texts
    if (length(t) >= 150L && is_clean(t)) {
      keep[i] <- TRUE; prev_full <- TRUE
    } else if (prev_full && is_partial(t)) {
      keep[i] <- TRUE; prev_full <- TRUE        # trailing partial chunk
    } else {
      prev_full <- FALSE
    }
  }
  blocks[keep]
}

# Segment the codebook into member-ordered attribute groups -- WITHOUT a year
# literal or a pre-scanned DGUID array. The codebook stores geography
# attribute-major in groups of growing size (1, 1, 2, 4, ... chunks of `chunk`=256
# members); within a group every attribute is laid down as G English then G French
# blocks in schema order, so the group's DGUID slot is a run of 2G structurally
# identified DGUID blocks (G EN then G FR) that is contiguous in block order and
# separated from the neighbouring groups by their other attributes. We therefore
# find the DGUID blocks structurally (`ivt_f2_is_dguid_block()`), split them into
# contiguous-index runs (one per group, length 2G), and assign member ids
# DETERMINISTICALLY from the running 256-chunk total -- never read from DGUID
# content. Returns list(d0 = first DGUID-EN block index, G, starts = member ids),
# byte-identical to what the former "2021"-anchored `ivt_f2_geo_groups()` produced.
ivt_f2_geo_groups_chunked <- function(blocks, chunk = 256L) {
  is_dg <- vapply(blocks, function(b) ivt_f2_is_dguid_block(b$texts), logical(1))
  dgi <- which(is_dg)
  if (!length(dgi)) return(list())
  brk <- c(0L, which(diff(dgi) != 1L), length(dgi))   # contiguous-run boundaries
  groups <- list(); mem <- 1L
  for (i in seq_len(length(brk) - 1L)) {
    r <- dgi[(brk[i] + 1L):brk[i + 1L]]
    G <- length(r) %/% 2L                             # 2G blocks (G EN + G FR)
    if (G < 1L) next
    starts <- mem + (seq_len(G) - 1L) * chunk
    groups[[length(groups) + 1L]] <- list(d0 = r[1L], G = G, starts = starts)
    mem <- mem + G * chunk
  }
  groups
}

# Extract one attribute (English) across all members, given the parsed groups. The
# group start block `glo` is anchored on the group's DGUID-EN block (`g$d0`), which
# sits `dguid_slot` attributes into the group (2G blocks per attribute), so the
# anchor is derived from the schema's DGUID slot rather than a fixed offset.
ivt_f2_extract_attr <- function(blocks, groups, slot, n_geo, tnr = FALSE,
                                group1_name = FALSE, dguid_slot = 5L) {
  out <- rep(NA_character_, n_geo)
  ng <- length(groups)
  for (gi in seq_len(ng)) {
    g <- groups[[gi]]; G <- g$G
    glo <- g$d0 - dguid_slot * 2L * G
    base <- glo + slot * 2L * G
    # group 1 carries an extra leading NAME pair (header table of contents), so
    # its counted NAME English block sits at +G.
    if (group1_name && gi == 1L) base <- glo + G
    bis <- base + seq_len(G) - 1L
    if (tnr) {
      # DQF_NOTE (the slot before TNR) splits long text across a variable number
      # of blocks, so locate TNR by content: blocks of decimal-point numbers.
      bis <- integer(0); bi <- glo + 18L * G; lim <- glo + 26L * G
      while (length(bis) < G && bi <= length(blocks) && bi <= lim) {
        t <- blocks[[bi]]$texts
        if (mean(grepl("^[0-9]+\\.[0-9]+$", t)) > 0.5) bis <- c(bis, bi)
        bi <- bi + 1L
      }
    }
    for (c in seq_len(G)) {
      bi <- bis[c]
      if (is.na(bi) || bi < 1L || bi > length(blocks)) next
      t <- trimws(blocks[[bi]]$texts)
      s <- g$starts[c]
      idx <- s:(s + length(t) - 1L)
      good <- idx >= 1L & idx <= n_geo
      out[idx[good]] <- t[good]
    }
  }
  out
}

# --- Geography member names (display label + GEO_NAME), bilingual -------------
#
# Two NAME attributes sit at the FRONT of each codebook group, before the schema
# attributes: a display **Member Name** (the human-readable label StatCan shows,
# e.g. "0001.00 - Abbotsford - Mission" or "Newfoundland and Labrador") and the
# schema's GEO_NAME (the short geographic name, which for code-only geographies --
# census tracts, unnamed dissemination areas -- is the bare code "9320001.00").
# Each is stored as a pair of same-attribute block runs, one per language; the two
# language runs are laid down back to back (G blocks each). We recover both, in
# English and French.
#
# Anchoring is drop-tolerant. The trailing *partial* chunk of a code-valued run
# (GEO_NAME on a census-tract table) is sometimes lost to the block scanner
# (special bytes after the last short block), which would shift a fixed offset. So
# we anchor on GEO_TYPE_DESC's first block (`type0 = d0 - (dguid_slot-1)*2G`) --
# reliable because every attribute from GEO_TYPE_DESC through DGUID is full text/
# code that keeps its partial -- and walk BACKWARD through GEO_NAME (2 runs) then
# the display pair (2 runs), inspecting each code run's last-block length to detect
# a dropped partial. The two text display runs are always full.
IVT_F2_FR_TOK <- paste0("(^|[ '-])(et|de|des|du|de-la|la|le|les|aux?|sur|sous|",
                        "ouest|est|nord|sud|sainte?|nouveau|nouvelle|colombie|",
                        "\u00eele|rivi\u00e8re|lac|baie)([ '-]|$)")
IVT_F2_EN_TOK <- paste0("(^|[ '-])(and|of|new|west|east|north|south|saint|island|",
                        "river|lake|bay)([ '-]|$)")
IVT_F2_ACCENT <- "[^\u00e0\u00e2\u00e4\u00e7\u00e9\u00e8\u00ea\u00eb\u00ee\u00ef\u00f4\u00f6\u00f9\u00fb\u00fc\u00c0\u00c2\u00c4\u00c7\u00c9\u00c8\u00ca\u00cb\u00ce\u00cf\u00d4\u00d6\u00d9\u00db\u00dc\u0153]"

# A French-ness score over the members where two candidate name blocks differ:
# accented-character count + French-connective tokens - English tokens. Used per
# group to pick the English of the two language runs (the physical language order
# is EN-first in most groups but FR-first in the root group, so this is decided
# per group, not once per file). Ties mean the two runs are identical (code-only
# geographies), so either is correct.
ivt_f2_frscore <- function(v) {
  v <- v[!is.na(v)]
  if (!length(v)) return(0)
  sum(nchar(gsub(IVT_F2_ACCENT, "", v))) +
    sum(grepl(IVT_F2_FR_TOK, v, ignore.case = TRUE)) -
    sum(grepl(IVT_F2_EN_TOK, v, ignore.case = TRUE))
}

# Assign languages to a pair of parallel member-value runs (the EN and FR
# copies of one attribute / label block): English is the run with the lower
# French-ness score over the members where the two DIFFER -- identical members
# carry no signal, and a tie means the runs are identical (code-only
# geographies), so either assignment is correct (English first). This is the
# one shared implementation of the idiom formerly inlined at every
# language-pair site. Returns list(en, fr, en_first).
#
# LOUDNESS PHILOSOPHY (refactor-plan.md §5.3). Content scoring is the PRIMARY,
# correct language decider for the geography per-group paths (`geo_attrs_dir`,
# `geo_names`, `geo_root_dir`, `dqf_legend`) and is SILENT there by design: the
# physical block language order is not fixed per file -- most groups are EN-first
# but the geography root group is FR-first -- so there is no schema-declared order
# to prefer and nothing to warn about; frscore is the read, not a fallback from
# one. That is the opposite of `ivt_f2_dim_dir_label1()`, whose dictionary schema
# block (`English Desc` before `Desc Fran...`) DOES fix the order: there frscore
# is a genuine fallback for when the schema block is absent, so it warns
# (`ivt_f2_label_lang_fallback()`). Same function, different status by context.
ivt_f2_pick_en <- function(a, b) {
  d <- which(!is.na(a) & !is.na(b) & a != b)
  en_first <- ivt_f2_frscore(a[d]) <= ivt_f2_frscore(b[d])
  if (en_first) list(en = a, fr = b, en_first = TRUE)
  else list(en = b, fr = a, en_first = FALSE)
}

# Do two stored name copies refer to the same dimension? The descriptor and
# the codebook markers draw the name from the same doubled-name field, but
# either copy may be truncated (the first descriptor copy caps at ~14 chars),
# so match when the shorter is a prefix of the longer, sharing at least
# `min_chars` characters. NA/empty never matches.
ivt_f2_name_match <- function(a, b, min_chars = 4L) {
  if (is.null(a) || is.null(b) || is.na(a) || is.na(b) ||
      !nzchar(a) || !nzchar(b)) return(FALSE)
  k <- min(nchar(a), nchar(b))
  k >= min_chars && substr(a, 1L, k) == substr(b, 1L, k)
}

# Locate one group's four name runs (display EN/FR-order pair `da`/`db`, GEO_NAME
# pair `ga`/`gb`) as member-parallel value vectors. Returns NULL if the anchor
# falls out of range. Language is NOT assigned here (see `ivt_f2_geo_names()`).
ivt_f2_geo_name_runs <- function(blocks, g, dguid_slot, n_geo) {
  G <- g$G; ms <- g$starts[1]
  mcount <- min(256L * G, n_geo - ms + 1L)
  partial <- mcount - 256L * (G - 1L)
  type0 <- g$d0 - (dguid_slot - 1L) * 2L * G          # GEO_TYPE_DESC chunk 0
  if (type0 < 1L) return(NULL)
  blen <- function(bi)
    if (bi >= 1L && bi <= length(blocks)) length(blocks[[bi]]$texts) else NA_integer_
  # a code run drops its trailing partial iff there is a partial (< 256) and the
  # block ending the run is a full 256 (the partial that should sit there is gone).
  nb_code <- function(last)
    if (partial < 256L) (if (!is.na(blen(last)) && blen(last) == partial) G else G - 1L)
    else G
  gb_last <- type0 - 1L;   gb_n <- nb_code(gb_last); gb0 <- type0 - gb_n
  ga_last <- gb0 - 1L;     ga_n <- nb_code(ga_last); ga0 <- gb0 - ga_n
  db0 <- ga0 - G; da0 <- db0 - G                     # display runs are full text
  gather <- function(c0, nb) {
    vals <- rep(NA_character_, mcount)
    for (c in seq_len(nb)) {
      bi <- c0 + c - 1L
      if (bi < 1L || bi > length(blocks)) next
      t <- trimws(blocks[[bi]]$texts)
      idx <- 256L * (c - 1L) + seq_along(t)
      idx <- idx[idx <= mcount]
      vals[idx] <- t[seq_along(idx)]
    }
    vals
  }
  list(da = gather(da0, G), db = gather(db0, G),
       ga = gather(ga0, ga_n), gb = gather(gb0, gb_n), ms = ms, mcount = mcount)
}

# Bilingual geography member names for the chunked codebook: display Member Name
# (`geo_label`/`geo_label_fr`) and the schema GEO_NAME (`geo_name`/`geo_name_fr`).
# Per group we pick which language run is English by `ivt_f2_frscore()` over the
# members where the two runs differ. Returns a list of four member-ordered vectors.
ivt_f2_geo_names <- function(blocks, groups, dguid_slot, n_geo) {
  z <- rep(NA_character_, n_geo)
  out <- list(geo_label = z, geo_label_fr = z, geo_name = z, geo_name_fr = z)
  for (g in groups) {
    r <- ivt_f2_geo_name_runs(blocks, g, dguid_slot, n_geo)
    if (is.null(r)) next
    a_en <- ivt_f2_pick_en(r$da, r$db)$en_first
    idx <- r$ms + seq_len(r$mcount) - 1L
    out$geo_label[idx]    <- if (a_en) r$da else r$db
    out$geo_label_fr[idx] <- if (a_en) r$db else r$da
    out$geo_name[idx]     <- if (a_en) r$ga else r$gb
    out$geo_name_fr[idx]  <- if (a_en) r$gb else r$ga
  }
  out
}

# --- Directory-driven geography attributes (all groups, no strides) ----------
#
# The whole codebook is read POSITIONALLY from the file's own metadata block
# directory (`ivt_f2_geo_block_dir()`), which lists every codebook block in LOGICAL
# order with its exact offset and length. There are no `d0 +/- k*2G` strides, no
# byte-ascending block scan (so the reverse-stored root chunk needs no special
# override), and no content-location of TNR: every attribute is read by position.
#
# Layout in directory order: the codebook is a sequence of member groups whose chunk
# counts follow `ivt_f2_geo_group_sizes()` (1,1,2,4,8,... last trimmed). Within a
# group of `G` chunks, the value blocks are laid down as, for each attribute in the
# fixed order [display Member Name, then every schema field], an English run of the
# `G` chunks (0..G-1) followed by a French run of the `G` chunks -- i.e. exactly
# `2G` blocks per attribute, `2*(nfield+1)*G` per group. This regular block count is
# the self-consistency gate: if the parsed value-block total is not
# `2*(nfield+1)*sum(sizes)`, the directory is incomplete for this layout and the
# caller falls back to the stride path. Validated byte-identical to the stride path
# on 98-10-0023 (all 63,404 members, every attribute) and 98-10-0129 (which carries
# an extra TNR_LONG_FORM schema field, consumed positionally and skipped).

# Chunk-count sequence of the geography attribute groups, derived from the member
# count: two singleton chunk-groups then powers of two (1,1,2,4,8,...), the last
# group trimmed to the remaining chunks. Reproduces `ivt_f2_geo_groups_chunked()`'s
# G sequence (e.g. 63,404 members -> 1,1,2,4,8,16,32,64,120; 6,297 -> 1,1,2,4,8,9).
ivt_f2_geo_group_sizes <- function(n_geo, chunk = 256L) {
  total <- as.integer(ceiling(n_geo / chunk))
  if (total <= 1L) return(total)
  sizes <- c(1L, 1L)
  while (sum(sizes) < total) {
    nxt <- sizes[length(sizes)] * 2L
    if (sum(sizes) + nxt >= total) { sizes <- c(sizes, total - sum(sizes)); break }
    sizes <- c(sizes, nxt)
  }
  sizes
}

# Chunk-group geometry shared by the four codebook chunk walkers
# (`ivt_f2_geo_dguids_dir()`, `ivt_f2_geo_attrs_dir()`, `ivt_f2_geo_inline_dir()`
# and `ivt_f2_dim_dir_label_chunks()`). The chunked codebook stores a dimension's
# members in GROUPS of `G` 256-member chunks (`G` follows `ivt_f2_geo_group_sizes()`),
# and every attribute / language run within a group is `G` blocks; the four walkers
# differ only in how they consume and align those blocks (identical-copy check,
# skip-nonmatching, NA-hole + dense re-alignment, padding-trim + rotation + skip),
# not in this geometry. Returns per group:
#   G      chunk count;
#   start  1-based member id of the group's first member;
#   size   members in the group (<= G*256);
#   chunk  integer[G], members in each chunk (256 except a trailing partial).
# The member index of chunk `c` (1-based within the group) is
# `start + 256*(c-1) + (0 .. chunk[c]-1)`. Also carries `$sizes` (the group-size
# vector) and `$n_chunks` (= `sum(sizes)`).
ivt_f2_chunk_layout <- function(n, chunk = 256L) {
  sizes <- ivt_f2_geo_group_sizes(n, chunk)
  starts <- cumsum(c(1L, utils::head(sizes, -1L) * chunk))
  groups <- lapply(seq_along(sizes), function(gi) {
    G <- sizes[gi]; s <- starts[gi]
    M <- min(G * chunk, n - s + 1L)
    list(G = G, start = s, size = M,
         chunk = pmin(chunk, M - chunk * (seq_len(G) - 1L)))
  })
  list(sizes = sizes, n_chunks = sum(sizes), groups = groups)
}

# Is a member-array block a consecutive-integer ordinal delimiter (1,2,3,... or
# 2049,2050,...)?  These sit between groups and must be skipped so they don't shift
# positional block indexing.
ivt_f2_is_ordinal <- function(t) {
  iv <- suppressWarnings(as.integer(t))
  !anyNA(iv) && length(iv) >= 3L && all(diff(iv) == 1L)
}

# Directory-driven geography attribute table. Returns the same tibble as
# `ivt_f2_geo_attributes()`, or NULL to signal the caller to fall back to the stride
# path (no block directory, no schema, or a value-block total that does not match
# the regular `2*(nfield+1)*sum(sizes)` count -- e.g. a layout whose directory drops
# a trailing partial, which the stride path handles). `trim = FALSE` keeps the
# stored label whitespace (the single-block tables indent `geo_name` by hierarchy
# depth, which `ivt_label_depth()` reads; the metadata light path relies on it).
ivt_f2_geo_attrs_dir <- function(raw, trim = TRUE) {
  ents <- ivt_f2_geo_entries(raw); if (is.null(ents)) return(NULL)
  schema <- ivt_f2_geo_schema(raw); if (is.null(schema) || !length(schema)) return(NULL)
  n_geo <- ivt_f2_geo_count(raw); if (is.na(n_geo) || n_geo < 1L) return(NULL)
  # value blocks in directory (logical) order, ordinal- and framing-filtered. The
  # run-scanner CLASSIFIES the entries (so the gate below sees the same block set
  # as always); the strict header-driven parse then supplies the VALUES where it
  # applies, preserving explicit empty records as NA holes (absent members, e.g.
  # 98-10-0662's aggregate member 26) and flagging bit-headed dense arrays, both of
  # which the run-scanner silently fragments or packs. (Copy the cached strict
  # result into a fresh list -- ents$strict(r) is memoized, must not be mutated.)
  vb <- vector("list", ents$n); k <- 0L
  for (r in seq_len(ents$n)) {
    t <- ents$records(r)
    if (length(t) >= 3L && !ivt_f2_is_ordinal(t)) {
      s <- ents$strict(r)
      e <- if (is.null(s)) list(values = t, dense = FALSE, strict = FALSE)
           else list(values = s$values, dense = s$dense, strict = TRUE)
      if (trim) e$values <- trimws(e$values)
      k <- k + 1L; vb[[k]] <- e
    }
  }
  length(vb) <- k
  lay <- ivt_f2_chunk_layout(n_geo)
  nattr <- length(schema) + 1L                       # display Member Name + schema fields
  if (k != 2L * nattr * lay$n_chunks) return(NULL)   # irregular layout -> fall back
  cols <- c("geo_label", "geo_label_fr", "geo_name", "geo_name_fr", "dguid",
            "geo_level", "geo_type", "geo_type_abbr", "prov_abbr", "alt_geo_code",
            "pr_code", "dqf_code", "dqf_note", "dqf_note_strict", "tnr_short_form")
  out <- stats::setNames(rep(list(rep(NA_character_, n_geo)), length(cols)), cols)
  pos <- 1L
  for (grp in lay$groups) {
    G <- grp$G; s <- grp$start; M <- grp$size; chunk_sz <- grp$chunk
    # per-chunk absent-member pattern, from the plain arrays' NA holes; every
    # NA-carrying plain array of the chunk must agree, else the layout is not
    # understood and the caller falls back. Plain arrays are stored padded with
    # empty records to the next power of two of the chunk size -- trim the all-NA
    # tail back to the chunk size first.
    empt <- vector("list", G)
    for (c in seq_len(G)) {
      empt[[c]] <- integer(0)
      for (b in seq_len(2L * nattr)) {
        j <- pos + (b - 1L) * G + (c - 1L)
        e <- vb[[j]]
        if (is.null(e) || e$dense) next
        if (length(e$values) > chunk_sz[c] &&
            all(is.na(e$values[(chunk_sz[c] + 1L):length(e$values)]))) {
          e$values <- e$values[seq_len(chunk_sz[c])]
          vb[[j]] <- e
        }
        if (length(e$values) != chunk_sz[c] || !anyNA(e$values)) next
        pat <- which(is.na(e$values))
        if (length(empt[[c]]) && !identical(pat, empt[[c]])) return(NULL)
        empt[[c]] <- pat
      }
    }
    place <- function(bi, strict_only = FALSE) {     # G blocks -> M-long member vector
      v <- rep(NA_character_, M)
      for (c in seq_len(G)) {
        e <- vb[[bi + c - 1L]]; if (is.null(e)) next
        if (strict_only && !isTRUE(e$strict)) next
        t <- e$values
        if (e$dense && length(t) != chunk_sz[c]) {   # dense: re-align absent members
          if (length(t) != chunk_sz[c] - length(empt[[c]]) || !length(empt[[c]]))
            return(NULL)                             # cannot align -> bail out
          full <- rep(NA_character_, chunk_sz[c]); full[-empt[[c]]] <- t; t <- full
        }
        idx <- 256L * (c - 1L) + seq_along(t); ok <- idx <= M
        v[idx[ok]] <- t[ok]
      }
      v
    }
    for (a in seq_len(nattr)) {
      pa <- pos; pb <- pos + G; pos <- pos + 2L * G   # run A then run B (G chunks each)
      va <- place(pa); vbv <- place(pb)
      if (is.null(va) || is.null(vbv)) return(NULL)   # unalignable dense block
      col <- if (a == 1L) "geo_label" else ivt_f2_stem_col(schema[a - 1L])
      if (is.na(col)) next                            # unmapped field (e.g. TNR_LONG_FORM)
      p <- ivt_f2_pick_en(va, vbv)
      idx <- s:(s + M - 1L)
      out[[col]][idx] <- p$en
      if (a == 1L) out[["geo_label_fr"]][idx] <- p$fr
      if (col == "geo_name") out[["geo_name_fr"]][idx] <- p$fr
      if (col == "dqf_note")                          # per-slot provenance (see below)
        out[["dqf_note_strict"]][idx] <- place(if (p$en_first) pa else pb, strict_only = TRUE)
    }
  }
  # every member must be accounted for by the display name or the DGUID (an absent
  # member carries neither -- e.g. a derived aggregate -- but then it must be an NA
  # hole of the plain arrays, which the count below still covers via geo_label)
  ivt_f2_check_geo_count(raw, sum(!is.na(out$geo_label) | !is.na(out$dguid)))
  # DQF_NOTE: a slot whose block the STRICT entry parse decoded is positional per
  # member and taken as read (98-10-0662: all 91 exact incl. its bit-headed dense
  # arrays). Slots only the run-scanner could read are NOT trusted -- the scanner
  # fragments the long suppression texts and misaligns them (e.g. the reverse-stored
  # root chunk) -- and are re-derived from the per-DQF_CODE majority vote over the
  # strict slots (the note is a 1:1 function of the code). Every other attribute is
  # exact by position.
  strictv <- out$dqf_note_strict
  out$dqf_note <- strictv
  miss <- is.na(strictv) & !is.na(out$dqf_code)
  if (any(miss))
    out$dqf_note[miss] <- ivt_f2_derive_text(strictv, out$dqf_code)[miss]
  tibble::tibble(
    member_id      = seq_len(n_geo),
    geo_label      = out$geo_label,      geo_label_fr   = out$geo_label_fr,
    geo_name       = out$geo_name,       geo_name_fr    = out$geo_name_fr,
    dguid          = out$dguid,          geo_level      = out$geo_level,
    geo_type       = out$geo_type,       geo_type_abbr  = out$geo_type_abbr,
    prov_abbr      = out$prov_abbr,      alt_geo_code   = out$alt_geo_code,
    pr_code        = out$pr_code,        dqf_code       = out$dqf_code,
    dqf_note       = out$dqf_note,       tnr_short_form = out$tnr_short_form
  )
}

#' Full geography attribute table for a family-2 IVT (member-ordered).
#'
#' Returns a tibble with one row per geography (1-based member id) and columns for
#' the decoded codebook attributes: `geo_label` (the human-readable display Member
#' Name) and `geo_label_fr`, `geo_name` (the schema GEO_NAME -- a bare code for
#' census tracts / unnamed dissemination areas) and `geo_name_fr`, `dguid`,
#' `geo_level`, `geo_type_abbr`, `prov_abbr`, `alt_geo_code`, `pr_code`,
#' `dqf_code` (data-quality flag) and `tnr_short_form` (total non-response rate).
#' Validated exact vs the StatCan metadata: `geo_label` matches the "Member Name"
#' column for all 63,404 geographies of 98-10-0023 and all 6,297 census tracts of
#' 98-10-0478 (`geo_name` on the latter is the bare CT code).
#'
#' Two reads are available. The primary is the **directory-driven positional read**
#' (`ivt_f2_geo_attrs_dir()`): every attribute is read from the file's own metadata
#' block directory in logical order, with no strides, no reverse-root special case,
#' and no content-location of TNR. It applies whenever the block directory resolves
#' and lists the codebook regularly (validated byte-identical on 98-10-0023 /
#' -0129). The **stride fallback** below runs when the directory is absent or the
#' block count is irregular (a dropped trailing partial): it segments the groups
#' structurally (`ivt_f2_geo_groups_chunked()`), reads attributes by their schema
#' slot (`ivt_f2_geo_slot_map()`, no "2021" literal / hard-coded slot table),
#' content-locates TNR past the variable-span DQF_NOTE, and overrides the
#' reverse-stored root chunk positionally (`ivt_f2_geo_root_dir()`).
#'
#' @keywords internal
#' @noRd
ivt_f2_geo_attributes <- function(raw) {
  dir_tbl <- ivt_f2_geo_attrs_dir(raw)
  if (!is.null(dir_tbl)) return(dir_tbl)
  ivt_fallback(paste(
    "The geography block directory is absent or lists the codebook",
    "irregularly; reading the geography attributes via the legacy stride walk",
    "over content-scanned blocks."))
  n_geo <- ivt_f2_geo_count(raw)
  blocks <- ivt_f2_codebook_blocks(raw)
  groups <- ivt_f2_geo_groups_chunked(blocks)
  slots <- ivt_f2_geo_slot_map(raw)
  pull <- function(name, ...)
    ivt_f2_extract_attr(blocks, groups, slots[[name]], n_geo,
                        dguid_slot = slots[["dguid"]], ...)
  dguids <- pull("dguid")                       # DGUID is just its own schema slot
  ivt_f2_check_geo_count(raw, sum(!is.na(dguids)))
  dqf_code <- pull("dqf_code")
  # DQF_NOTE is a long concatenation of suppression statements that spans several
  # codebook blocks, so its direct slot extraction is only ~99.8%. It is a 1:1
  # function of DQF_CODE (decoded exactly), so recover it by per-key majority vote
  # over the raw extraction (`ivt_f2_derive_text()`) and look it up from the code.
  # (geo_type needs no such fix-up: accepting Windows-1252 label bytes in
  # `is_label_byte` makes its direct slot extraction exact.)
  dqf_note <- ivt_f2_derive_text(pull("dqf_note"), dqf_code)
  # The two NAME attributes (display Member Name + schema GEO_NAME) are recovered
  # bilingually by the drop-tolerant, per-group-language name reader rather than by
  # a fixed slot offset (GEO_NAME's trailing partial can be lost on census-tract
  # tables, and the root group stores the name languages in the opposite order).
  nm <- ivt_f2_geo_names(blocks, groups, slots[["dguid"]], n_geo)
  tbl <- tibble::tibble(
    member_id      = seq_len(n_geo),
    geo_label      = nm$geo_label,
    geo_label_fr   = nm$geo_label_fr,
    geo_name       = nm$geo_name,
    geo_name_fr    = nm$geo_name_fr,
    dguid          = dguids,
    geo_level      = pull("geo_level"),
    geo_type       = pull("geo_type"),
    geo_type_abbr  = pull("geo_type_abbr"),
    prov_abbr      = pull("prov_abbr"),
    alt_geo_code   = pull("alt_geo_code"),
    pr_code        = pull("pr_code"),
    dqf_code       = dqf_code,
    dqf_note       = dqf_note,
    tnr_short_form = pull("tnr_short_form", tnr = TRUE)
  )
  # The root chunk is reverse-stored, so the stride walk above leaves its NAME
  # attributes NA and, when the chunk carries extra framing blocks (98-10-0013 ADA),
  # scrambles prov_abbr / alt_geo_code / pr_code. Override members 1..rootN with the
  # positional read from the header block directory (offsets/lengths + schema order).
  # A no-op on tables whose stride walk already labels the root chunk (98-10-0478 CT:
  # byte-identical) and on tables with no directory (98-10-0023/-0174: returns NULL).
  rd <- ivt_f2_geo_root_dir(raw, n_geo)
  if (!is.null(rd)) {
    rootN <- length(rd$geo_label)
    for (col in intersect(names(rd), names(tbl)))
      tbl[[col]][seq_len(rootN)] <- rd[[col]]
  }
  tbl
}

# Recover a text attribute that is a 1:1 function of a reliable key, by per-key
# majority vote over the (mostly-correct) raw extraction.
ivt_f2_derive_text <- function(raw_vals, key) {
  ok <- !is.na(key) & !is.na(raw_vals) & nzchar(raw_vals)
  if (!any(ok)) return(raw_vals)
  lut <- tapply(raw_vals[ok], key[ok], function(x) names(which.max(table(x))))
  out <- as.character(lut[key])             # plain vector (drops the array dim/names)
  miss <- is.na(out)
  out[miss] <- raw_vals[miss]               # fall back to raw where no key
  out
}

# --- Inline-codebook geography (pre-DGUID layout, e.g. 1991, 2006, 2011) -------
#
# Tables older than the 2016 DGUID store geography differently from 98-10-0023:
# instead of a separate DGUID array plus a slotted attribute table, one block type
# per chunk packs everything into each entry as
#     "<name> (<GEOUID>) [<type_abbr>] <dqf_code>"
# where <name> is the (often bilingual "English | French") label, <GEOUID> is the
# bare geographic code (a shortened DGUID without the year and statistical-area-type
# prefix that 2016+ tables carry; it may be dotted, e.g. a census-tract code
# "0010001.00", or carry letters, so it is treated as character), an optional
# <type_abbr> is a short geography-type abbreviation ("T", the accented "ME", ...),
# and <dqf_code> is the data-quality flag. These blocks repeat per chunk and per
# language; the GEOUID is unique, so first-appearance de-duplication yields the
# geographies in member order. Crucially the parse is **anchored on the geography
# dimension's `81 02 02 00` doubled-name marker** (`ivt_f2_geo_marker_region()`),
# exactly as the data dimensions are anchored, so geography is *located* from the
# metadata, not by sniffing the whole file for a "Canada"/"2021" first entry; only
# the blocks in geography's own marker region are parsed. Validated exact on the
# member counts for 1003011 (1991, 41,859), 98-312-XCB2011033 (2011 census tracts,
# 5,447) and 97-563-XCB2006072 (2006 dissemination areas, 57,523); byte-identical to
# the former whole-file scan on 1991's names/GEOUIDs/flags.

# Fixed-header field offsets (0-based). The header carries a dimension descriptor
# pointer and, in the legacy export format, out-of-line title-string pointers.
IVT_HDR_DESCRIPTOR_PTR <- 32L   # u32 -> dimension descriptor block
IVT_HDR_TITLE_FR_PTR   <- 40L   # u32 -> French title (0 in the modern inline format)
IVT_HDR_TITLE_EN_PTR   <- 48L   # u32 -> English title (0 in the modern inline format)
IVT_DESC_GEO_COUNT     <- 52L   # u16 within the descriptor: geography member count

# Fixed header offsets (0-based) that map the file layout. Validated on the modern
# (98-10-0023) and legacy (1003011) reference tables.
IVT_HDR_GEO_FIELDS   <- 552L   # u32: geography field/attribute count (11 / 12)
IVT_HDR_CODEBOOK_PTR <- 572L   # u32: codebook region start

#' Map the file layout from the header alone (no marker scanning).
#'
#' The fixed header points at every major section, so the whole layout can be read
#' up front. Returns a list with the format `version` ("modern" 2016+/DGUID vs
#' "legacy" pre-DGUID, signalled by whether the out-of-line title pointers are
#' set), and byte offsets for the dimension `descriptor`, EN/FR `title` blocks
#' (legacy only), the geography `field_count`, the page `directory`, the
#' `value_pages` start, the `codebook` region, and `eof`. The variable section
#' table that follows (codebook sub-blocks, dimension member blocks, the notes
#' block) tags entries with a type byte (16 = member/data block, 15 = notes); those
#' offsets are format-specific and not part of this fixed-offset map.
#'
#' This is a DIAGNOSTIC / documentation entry point, not part of the decode path:
#' it is the reference implementation of the header map described in
#' `inst/notes/ivt-format.md` ("Header layout map") and is exercised by the header
#' regression tests. The decode path reads the same fields through its own
#' anchors (`ivt_idx0()`, `ivt_f2_descriptor()`, `ivt_f2_find_directory()`).
#'
#' @keywords internal
#' @noRd
ivt_f2_header_layout <- function(raw) {
  n <- length(raw)
  fr <- rd_u32(raw, IVT_HDR_TITLE_FR_PTR)
  en <- rd_u32(raw, IVT_HDR_TITLE_EN_PTR)
  legacy <- (!is.na(en) && en != 0) || (!is.na(fr) && fr != 0)
  dir <- ivt_f2_find_directory(raw)
  list(
    version         = if (legacy) "legacy" else "modern",
    descriptor      = rd_u32(raw, IVT_HDR_DESCRIPTOR_PTR),
    title_en        = if (legacy) en else NA_real_,
    title_fr        = if (legacy) fr else NA_real_,
    field_count     = rd_u32(raw, IVT_HDR_GEO_FIELDS),
    directory       = rd_u16(raw, IVT_HDR_DIR_PTR),
    n_pages         = if (!is.null(dir)) dir$n_pages else NA_integer_,
    value_pages     = if (!is.null(dir)) min(dir$offsets) else NA_real_,
    codebook        = rd_u32(raw, IVT_HDR_CODEBOOK_PTR),
    eof             = n
  )
}

# Geography member count, read straight from the header dimension descriptor
# (no need to count by parsing the codebook). Validated: 63,404 (98-10-0023),
# 41,859 (1003011).
ivt_f2_header_geo_count <- function(raw) {
  desc <- rd_u32(raw, IVT_HDR_DESCRIPTOR_PTR)
  if (is.na(desc) || desc < 1 || desc + IVT_DESC_GEO_COUNT + 2 > length(raw)) return(NA_integer_)
  rd_u16(raw, as.integer(desc) + IVT_DESC_GEO_COUNT)
}

# Does this file use the inline (pre-DGUID) geography codebook? This is read from
# the file header, not inferred from the codebook: the modern DGUID-era export
# inlines its identity text ("Product ID:", "Reference Period:") in the header and
# leaves the out-of-line title-string pointers (header u32 @40/@48) zero, whereas
# the legacy export stores titles out-of-line (those pointers are non-zero) and
# uses the inline "name (GEOUID) flag" geography codebook. Confirmed on both
# reference tables (98-10-0023 modern; 1003011 legacy).
ivt_f2_geo_is_inline <- function(raw) {
  if (length(raw) < IVT_HDR_TITLE_EN_PTR + 4L) return(FALSE)
  rd_u32(raw, IVT_HDR_TITLE_EN_PTR) != 0 || rd_u32(raw, IVT_HDR_TITLE_FR_PTR) != 0
}

# The inline geography entry: "<name> (<code>) [<type_abbr>] <dqf_code> [(<pct>%)]".
# The code group allows dots and letters (census-tract codes are dotted, e.g.
# "0010001.00") so GEOUIDs are read as character; the optional type-abbreviation
# token is any space-delimited run that does NOT start with a digit (so it is the
# abbreviation, not the numeric flag) -- this admits "T" and the accented Quebec
# "ME"; and an optional trailing parenthesised group carries the non-response rate
# that the 2016 single-census-year tables append (e.g. "Canada (01) 20000 ( 4.0%)").
# A comma may follow the code group: a few unorganised CSDs in the ord custom
# export invert the order to "<name> (<code>), <type_abbr> <flag>" (e.g. "Central
# Kootenay D (5903039), CSD 01010 ( 14.4%)"), so the code/name still resolve.
# The type-abbreviation token and the trailing group are CAPTURED (groups 3 and
# 5): the type is the geography's municipal / census-subdivision status and the
# trailing group, when it is a percentage, the total non-response rate -- both
# structural token positions of the combined record, exposed as geo_type_abbr /
# tnr_short_form.
IVT_F2_INLINE_PAT <- paste0(
  "^(.*) \\(([0-9A-Za-z.]+)\\)(?:,\\s*|\\s+)(?:([^0-9\\s]\\S*)\\s+)?([0-9]+)",
  "(?:\\s*\\(([^)]*)\\))?\\s*$")

# A second inline layout stores the code LAST, inside the trailing parentheses, with
# NO data-quality flag: "<name>[, <type_abbr>] (<code>)" -- the 2006 custom-order
# crosstabs (cro0172986_ct.7/8) use it (e.g. "East Kootenay, RD (5901)", "Elkford,
# DM (5901003)"). The name (which keeps its ", <type>" suffix as StatCan displays it)
# is everything before the final "(code)"; there is no flag. Tried only AFTER
# `IVT_F2_INLINE_PAT` (which the 1991/2006/2011 "<name> (<code>) <flag>" blocks match),
# so those vintages are unaffected.
IVT_F2_INLINE_PAT2 <- "^(.*?)\\s*\\(([0-9A-Za-z.]+)\\)\\s*$"

# A geography-type abbreviation stored as a NAME SUFFIX: the custom-order
# exports (cro/ord) append it to the display name as ", <ABBR>" ("East Kootenay,
# RD", "Elkford, DM", "British Columbia, PR") instead of the token position the
# census tables use. The abbreviation is a short upper-case token (accented
# caps admitted for the Quebec types, hyphen for "S-E"-style forms); the suffix is only
# READ, never stripped -- the stored display name (which StatCan shows with the
# suffix) stays the join key.
IVT_F2_TYPE_SUFFIX_PAT <- ",\\s*([A-Z\u00c0-\u00dc][A-Z\u00c0-\u00dc-]{0,3})$"

# The trailing parenthesised group as a total non-response rate: "  4.0%" /
# "  4,0 %" (the French copies use a comma decimal) -> "4.0" (the decimal-point
# form the modern schema'd tables store in TNR_SHORT_FORM). NA when the group is
# not a percentage.
ivt_f2_parse_tnr <- function(g) {
  m <- regmatches(g, regexec("^\\s*([0-9]+(?:[.,][0-9]+)?)\\s*%\\s*$", g,
                             perl = TRUE))
  vapply(m, function(x)
    if (length(x) >= 2L) gsub(",", ".", x[2], fixed = TRUE) else NA_character_, "")
}

# Parse a vector of inline geography member strings into name / code / flag /
# type / tnr columns, trying the flag-trailing form (`IVT_F2_INLINE_PAT`) first
# and the code-trailing form (`IVT_F2_INLINE_PAT2`) for whatever it misses.
# `type` is the geography-type abbreviation (municipal / CSD status), from the
# token position when present, else the ", <ABBR>" name suffix of the custom
# exports; `tnr` the trailing percentage (total non-response rate, 2016+).
# Returns a list of five character vectors (NA where a pattern / field is
# absent; `flag` and `tnr` are always NA for the second form).
ivt_f2_parse_inline <- function(v) {
  nm <- code <- fl <- ty <- tnr <- rep(NA_character_, length(v))
  # perl = TRUE: under the default TRE engine `\s` inside a bracket class is not
  # a whitespace escape ("[^0-9\\s]" reads as not-digit/backslash/'s'), which let
  # a leading space into the captured type token.
  m1 <- regmatches(v, regexec(IVT_F2_INLINE_PAT, v, perl = TRUE))
  ok1 <- vapply(m1, function(g) length(g) >= 6L, logical(1))
  if (any(ok1)) {
    nm[ok1]   <- vapply(m1[ok1], `[`, "", 2L)
    code[ok1] <- vapply(m1[ok1], `[`, "", 3L)
    ty[ok1]   <- trimws(vapply(m1[ok1], `[`, "", 4L))
    fl[ok1]   <- vapply(m1[ok1], `[`, "", 5L)
    tnr[ok1]  <- ivt_f2_parse_tnr(vapply(m1[ok1], `[`, "", 6L))
  }
  miss <- !ok1 & !is.na(v)
  if (any(miss)) {
    m2 <- regmatches(v[miss], regexec(IVT_F2_INLINE_PAT2, v[miss], perl = TRUE))
    ok2 <- vapply(m2, function(g) length(g) >= 3L, logical(1))
    idx <- which(miss)[ok2]
    nm[idx]   <- vapply(m2[ok2], `[`, "", 2L)
    code[idx] <- vapply(m2[ok2], `[`, "", 3L)
  }
  ty[!is.na(ty) & ty == ""] <- NA_character_
  # suffix-stored type (cro/ord): fill only where the token position carried none
  sfx <- is.na(ty) & !is.na(nm) & grepl(IVT_F2_TYPE_SUFFIX_PAT, nm, perl = TRUE)
  if (any(sfx))
    ty[sfx] <- sub(paste0("^.*", IVT_F2_TYPE_SUFFIX_PAT), "\\1", nm[sfx],
                   perl = TRUE)
  list(name = nm, code = code, flag = fl, type = ty, tnr = tnr)
}

# Recover a geography display name from its combined inline string by SUBTRACTING
# the structural tokens we already hold from the file's own dedicated arrays -- the
# geographic code (parenthesised) and the trailing data-quality flag / non-response
# rate. The positional regexes (`ivt_f2_parse_inline`) key on the code sitting at a
# FIXED position (just before the flag); this helper does not, so it recovers the
# two shapes those regexes miss:
#   * the code embedded MID-name on some dual-official-name CSDs
#     ("Kootenay Boundary D (5905052) / Rural Grand Forks, CSD 00000 (5.9%)");
#   * a code-only geography whose whole string is the bare code (1996 enumeration
#     areas: the display name IS the code, exactly as the named members already read).
# `code` is the member's uid (from the dedicated code array), so the subtraction is
# metadata-driven, not a content guess. Returns the remaining display text, or the
# code itself when nothing but the code (and the stripped tokens) remained. Used
# ONLY to fill members the positional parse left NA, so validated output is
# unchanged. Vectorised over `s` / `code`.
ivt_f2_inline_name_subtract <- function(s, code) {
  out <- s
  has <- !is.na(out) & !is.na(code) & nzchar(code)
  # drop the parenthesised code wherever it sits (code is digits/letters -> a
  # literal, so escape any regex metacharacters defensively before substituting)
  out[has] <- mapply(function(x, c)
    gsub(paste0("\\s*\\(\\Q", c, "\\E\\)\\s*"), " ", x, perl = TRUE),
    out[has], code[has], USE.NAMES = FALSE)
  # drop a trailing "(pct%)" then a trailing data-quality flag (a run of digits)
  out <- sub("\\s*\\([^)]*%\\)\\s*$", "", out, perl = TRUE)
  out <- sub("\\s+[0-9]+\\s*$", "", out, perl = TRUE)
  out <- trimws(gsub("\\s+", " ", out))
  empty <- !is.na(out) & (!nzchar(out) | out == code)     # code-only geography
  out[empty] <- code[empty]
  out
}

# Split the inline vintages' bilingual display names into their English and
# French halves. The combined block stores ONE display string per member, and
# geographies whose two official names differ carry both, joined by the
# vintage's separator -- " | " on the 1991 exports, " / " on the 1996-2016 ones
# ("Newfoundland | Terre-Neuve", "Prince Edward Island / Ile-du-Prince-Edouard").
# A name is a split candidate only when it carries exactly ONE separator outside
# parentheses (parenthesised qualifiers embed slashes: "(Ontario part / partie
# de l'Ontario)"). The two separators differ in how much they prove:
#   " | " is the 1991 exports' dedicated language separator -- a candidate
#         always splits;
#   " / " also joins DUAL English place names ("Kootenay Boundary B / Lower
#         Columbia-Old-Glory" is one official CSD name, not a language pair), so
#         a candidate splits only when its French half actually reads French --
#         `ivt_f2_frscore(fr) > frscore(en)` per member. Language-neutral pairs
#         ("Greater Sudbury / Grand Sudbury") stay combined, which matches how
#         a dual official name should be treated when the file gives no
#         language signal.
# Which half is English is decided ONCE PER RUN by `ivt_f2_frscore()` over all
# candidates (the halves' order is a property of the export, not of a member),
# so a single short name cannot flip languages. Returns list(en, fr); members
# that do not split return the whole string for both languages.
ivt_f2_split_bilingual <- function(nm) {
  en <- fr <- nm
  # positions of " | " / " / " at parenthesis depth 0, per name
  halves <- lapply(nm, function(s) {
    if (is.na(s) || !grepl(" [|/] ", s)) return(NULL)
    cs <- strsplit(s, "", fixed = TRUE)[[1]]
    depth <- cumsum((cs == "(") - (cs == ")"))
    sep <- which(cs %in% c("|", "/"))
    sep <- sep[sep > 1L & sep < length(cs) & cs[sep - 1L] == " " &
               cs[sep + 1L] == " " & depth[sep] == 0L]
    if (length(sep) != 1L) return(NULL)
    a <- trimws(substr(s, 1L, sep - 1L)); b <- trimws(substr(s, sep + 1L, nchar(s)))
    if (!nzchar(a) || !nzchar(b)) return(NULL)
    c(a, b, cs[sep])
  })
  hit <- which(!vapply(halves, is.null, logical(1)))
  if (!length(hit)) return(list(en = en, fr = fr))
  a <- vapply(halves[hit], `[`, "", 1L)
  b <- vapply(halves[hit], `[`, "", 2L)
  bar <- vapply(halves[hit], `[`, "", 3L) == "|"
  first_en <- ivt_f2_frscore(a) <= ivt_f2_frscore(b)   # per run, not per member
  ea <- if (first_en) a else b
  fb <- if (first_en) b else a
  # per-member acceptance: "|" always; "/" needs POSITIVE French evidence in
  # the FR half (accents / French tokens), not merely a less-English EN half --
  # "Kootenay Boundary E / West Boundary" must not split just because "West"
  # reads English. Language-neutral dual names stay combined (conservative:
  # e.g. "British Columbia / Colombie-Britannique" carries no scoring signal).
  keep <- bar | vapply(seq_along(ea), function(i) {
    s <- ivt_f2_frscore(fb[i])
    s > 0 && s > ivt_f2_frscore(ea[i])
  }, logical(1))
  en[hit[keep]] <- ea[keep]
  fr[hit[keep]] <- fb[keep]
  list(en = en, fr = fr)
}

# Byte range [start, end) of the geography dimension's codebook region, anchored on
# its `81 02 02 00` doubled-name marker (the same anchor used for every data
# dimension). Preferred bound: the geography block directory's own byte span
# (`ivt_f2_geo_dir_span()`, dimdir.R) -- the marker is searched only inside it and
# the region ends at the span end, so the bound comes from the file's metadata.
# Fallback (no directory): scan from the header's codebook pointer (@572) -- which
# keeps this correct for the large files whose geography codebook sits far from EOF
# (e.g. the 2006 table's marker at ~32 MB) -- and end at the next dimension marker
# (or EOF). Returns c(start, end) or NULL when the descriptor or marker is absent.
ivt_f2_geo_marker_region <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(NULL)
  geo <- ivt_f2_geo_dim(d$dims, ivt_f2_geo_dim_index(raw, d))
  if (is.null(geo) || is.null(geo$name) || is.na(geo$name)) return(NULL)
  is_geo_mk <- function(nm) ivt_f2_name_match(nm, geo$name)
  span <- ivt_f2_geo_dir_span(raw)
  if (!is.null(span) && span[2] > span[1]) {
    win <- raw[(span[1] + 1L):span[2]]
    markers <- ivt_f2_codebook_dim_markers(win, 0L)
    hit <- which(vapply(markers$name, is_geo_mk, logical(1)))
    if (length(hit)) return(c(span[1] + markers$offset[hit[1]], span[2]))
    # marker not inside the directory span -> fall through to the unbounded scan
  }
  cb <- rd_u32(raw, IVT_HDR_CODEBOOK_PTR)
  start <- if (is.na(cb) || cb < 1) 0L else max(0L, as.integer(cb) - 8000L)
  markers <- ivt_f2_codebook_dim_markers(raw, start)
  if (!nrow(markers)) return(NULL)
  hit <- which(vapply(markers$name, is_geo_mk, logical(1)))
  if (!length(hit)) return(NULL)
  geomk <- markers$offset[hit[1]]
  others <- markers$offset[markers$offset > geomk]
  c(geomk, if (length(others)) min(others) else length(raw))
}

# Positional (directory-driven) reader for the inline-codebook geography. The
# legacy layout stores, per group of `G` 256-member chunks (group sizes
# `ivt_f2_geo_group_sizes()`, same 1,1,2,4,... sequence as the modern chunked
# codebook), a fixed number `R` of attribute runs of `G` chunk blocks each, in
# directory order. The run roster varies by vintage:
#
#   1991 / 2011 (R = 4):  [combined "name (code) flag"] x 2 languages,
#                         [name array] (accent-stripped -- NOT the display name),
#                         [code array] (bare GEOUIDs)
#   2006 (R = 3):         [combined] x 2, [name array]      (no code array)
#   2016 98-400-X (R = 4): an extra leading run before the two combined runs
#
# so `R` is derived from the candidate-block count (blocks per chunk) and the run
# ROLES are detected by content: the two combined runs are the ones whose records
# parse as `IVT_F2_INLINE_PAT`, and a code array is any other run that equals the
# combined block's parsed codes (used positionally when present; the parsed code
# is the uid otherwise). Candidates are interleaved with framing entries,
# per-4-chunk index blocks (1024 records) and ordinal delimiters, all filtered
# structurally (record count in [3, 256], non-ordinal). Reading the runs in
# directory order gives the TRUE member order -- the byte-ascending block scan +
# first-appearance dedup of the regex fallback scrambles chunks stored out of
# byte order (on 1003011 the last ~2,435 members' codes were misordered; the
# directory read matches the StatCan Beyond 20/20 viewer's member list
# 41,859/41,859, names AND codes).
#
# The run-scanner classifies the candidate blocks; where the strict header-driven
# entry parse (`ivt_f2_dir_entry_members()`) applies, it supplies the VALUES --
# chunks whose records the scanner fragments (e.g. 98-312-XCB2011033's final
# 71-member partial, recovered 51/71 by the scanner) parse exactly, with the
# power-of-two slot padding trimmed back to the chunk size. Every chunk of every
# run must match its expected size, otherwise the reader bails and the caller
# falls back to the regex scan. Returns the `ivt_f2_geo_inline()` tibble or NULL.
# Origin-destination commuting-flow geography (the 2011 NHS 99-0xx-X flow tables,
# geography descriptor type 0x0f). Each geography MEMBER is a flow between two
# census subdivisions, stored as a paired combined string
#   "origin (origincode) type flag ( pct%) / dest (destcode) type flag ( pct%)"
# alongside a dedicated flow-code array whose records are the "origincode/destcode"
# uid. The generic inline reader (`ivt_f2_geo_inline_dir()`) does not fit this
# layout: each member chunk carries ~11 parallel arrays (two full-flow combined
# copies EN/FR, a code-less display copy, several per-side component arrays and the
# uid), more runs than its group walk assembles, and the " / " flow separator
# collides with the bilingual EN/FR split. Instead we anchor on the uid array --
# the one run that is unambiguous (records match `^code/code$`) -- read in block-
# directory (member) order, and attach the display label to each member by JOINING
# the combined records back on the two codes they carry (order-independent, self-
# validating: a flow label's own codes must name a known member). Gated tightly on
# a COMPLETE flow uid array (chunks summing exactly to the header geography count)
# so no other table engages this path. Loud fallback. Member order (residence-major,
# SGC-code ascending) is viewer-validated content-exact across all vintages -- see
# inst/notes/coverage.md; the viewer re-sorts within a residence for display.
ivt_f2_geo_flow_dir <- function(raw) {
  if (!is.null(ivt_f2_geo_schema(raw))) return(NULL)   # modern schema'd layout
  ents <- ivt_f2_geo_entries(raw)                       # Stage 1 (shared)
  if (is.null(ents)) return(NULL)
  n_geo <- ivt_f2_geo_count(raw)
  if (is.na(n_geo) || n_geo < 1L) return(NULL)
  # Codes are 3-9 digits: 7-digit CSDs (2011/2016 99-0xx/98-400 CSD flows),
  # 4-digit CDs (2016 98-400-X2016391) and 3-digit CMAs/CAs (98-400-X2016327).
  uid_re  <- "^[0-9]{3,9}/[0-9]{3,9}$"
  code2   <- "\\(([0-9]{3,9})\\).*?/.*?\\(([0-9]{3,9})\\)"   # the two codes in a flow record
  # collect the uid array in directory (member) order; keep every value block so the
  # label join below can draw a combined record from wherever it is stored.
  uids <- character(0)
  blocks <- list()
  # code -> single-CSD name, from the file's per-side component name arrays
  # ("Name (code) type flag"): the clean source for the code->name backfill of any
  # member whose combined record is missing or truncated in a tail partial chunk.
  name_dict <- new.env(hash = TRUE, parent = emptyenv())
  scan_blocks <- 0L                                       # blocks the strict parse could not read
  for (r in seq_len(ents$n)) {
    # BYTE-EXACT records first (`ivt_f2_dir_entry_members`, the two value-block
    # framings): the loose run-scanner fragments records in dense tail chunks -- how
    # a handful of names were silently lost before -- so it is only the fallback.
    e <- ents$strict(r)
    if (!is.null(e)) { t <- e$values }
    else { t <- ents$records(r); scan_blocks <- scan_blocks + 1L }
    if (length(t) < 3L || length(t) > 512L || ivt_f2_is_ordinal(t)) next
    tt <- trimws(t)
    nn <- tt[!is.na(tt) & nzchar(tt)]
    if (!length(nn)) next
    # uid chunks are clean 256-record arrays; combined-label chunks are sometimes
    # padded past 256 (a few tail members live only in those, hence the wider cap
    # -- harmless, the join below places a record only where its own codes match).
    if (length(t) <= 256L && mean(grepl(uid_re, nn)) >= 0.9) { uids <- c(uids, tt); next }
    if (any(grepl(" / ", tt, fixed = TRUE))) { blocks[[length(blocks) + 1L]] <- tt; next }
    # single-side name array: one "Name (code) type flag" per member (no " / ")
    if (mean(grepl("\\([0-9]{3,9}\\)", nn)) >= 0.8) {
      p <- ivt_f2_parse_inline(tt)
      ok <- !is.na(p$code) & !is.na(p$name) & !grepl("^[0-9)([:space:]]", p$name)
      for (i in which(ok)) if (is.null(name_dict[[p$code[i]]])) name_dict[[p$code[i]]] <- p$name[i]
    }
  }
  if (length(uids) != n_geo || !length(blocks)) return(NULL)   # not a flow codebook
  # member map: the uid array in directory order IS the codebook member order (the
  # same logical block-directory order the cell decoder pages geography in).
  member_of <- new.env(hash = TRUE, parent = emptyenv())
  for (i in seq_along(uids)) member_of[[uids[i]]] <- i
  label   <- rep(NA_character_, n_geo)
  lab_fr  <- rep(NA_character_, n_geo)
  # join every combined record to its member by the two codes it carries. This is
  # self-validating (a record only lands where its own codes name a known member),
  # so we can scan ALL blocks -- purity does not matter -- to maximise coverage.
  for (tt in blocks) {
    m <- regmatches(tt, regexec(code2, tt, perl = TRUE))
    key <- vapply(m, function(x) if (length(x) == 3L) paste0(x[2], "/", x[3]) else NA_character_, "")
    is_fr <- grepl("[0-9],[0-9]", tt)                     # comma decimals => French copy
    for (j in which(!is.na(key))) {
      mi <- member_of[[key[j]]]
      if (is.null(mi)) next
      if (is_fr[j]) { if (is.na(lab_fr[mi])) lab_fr[mi] <- tt[j] }
      else          { if (is.na(label[mi]))  label[mi]  <- tt[j] }
    }
  }
  # English label may be missing where only the French copy carried the member;
  # fall back to it so every member gets a display string.
  label[is.na(label)] <- lab_fr[is.na(label)]
  # A flow is a pair of geographies -- place of residence (the origin, before the
  # " / ") and place of work (the destination) -- the file's own POR/POW ("Place Of
  # Residence" / "Place Of Work", LDR/LDT in French) schema. Split both the uid and
  # the display label so each surfaces as its own geography (`geo_res_*`/`geo_work_*`);
  # keep the pair as `geo_uid` (member identity) and the combined string as `geo_label`.
  upart    <- strsplit(uids, "/", fixed = TRUE)
  res_uid  <- vapply(upart, function(x) if (length(x) >= 1L) x[1L] else NA_character_, "")
  work_uid <- vapply(upart, function(x) if (length(x) >= 2L) x[2L] else NA_character_, "")
  en <- ivt_f2_flow_sides(label);  fr <- ivt_f2_flow_sides(lab_fr)
  # backfill any side name the combined split missed (member's combined record was
  # missing/truncated) from the single-side name arrays, keyed by the code we hold.
  from_dict <- function(nm, code) {
    miss <- is.na(nm) & !is.na(code)
    if (any(miss)) nm[miss] <- vapply(code[miss], function(cc) {
      v <- name_dict[[cc]]; if (is.null(v)) NA_character_ else v }, "")
    nm
  }
  res_name  <- from_dict(en$res,  res_uid)
  work_name <- from_dict(en$work, work_uid)
  res_fr  <- fr$res;  res_fr[is.na(res_fr)]   <- res_name[is.na(res_fr)]
  work_fr <- fr$work; work_fr[is.na(work_fr)] <- work_name[is.na(work_fr)]
  join <- function(a, b) ifelse(is.na(a) & is.na(b), NA_character_,
            paste(ifelse(is.na(a), "", a), ifelse(is.na(b), "", b), sep = " / "))
  # complete geo_label (verbatim combined string) for the members whose combined
  # record was absent, from the recovered "name (code) / name (code)" halves.
  synth <- is.na(label) & !is.na(res_name) & !is.na(work_name)
  label[synth] <- paste0(res_name[synth], " (", res_uid[synth], ") / ",
                         work_name[synth], " (", work_uid[synth], ")")
  ivt_fallback(paste(
    "Origin-destination commuting-flow geography ({n_geo} flow members): decoded",
    "as two geographies -- place of residence (geo_res_*) and place of work",
    "(geo_work_*) -- with the pair kept as geo_uid. Labels are joined to each member",
    "by the codes they carry (a few tail members recovered from the per-side name",
    "arrays). Member order is residence-major, SGC-code ascending (viewer-validated",
    "content-exact across 2011/2016 flow tables; the viewer re-sorts for display)."),
    class = "canivt_geo_flow")
  # SAFETY CHECK: every flow member must resolve to a residence + work name AND code.
  # A residual gap means a codebook block was mis-parsed and silently dropped/truncated
  # a member -- surface it LOUDLY (strict-mode error) instead of emitting NA metadata,
  # the exact silent-truncation failure this reader is built to avoid.
  gaps <- sum(is.na(res_name) | is.na(work_name) | is.na(res_uid) | is.na(work_uid))
  if (gaps > 0L)
    ivt_fallback(c(
      paste("{gaps} of {n_geo} commuting-flow geographies did not fully decode",
            "(missing residence/work name or code) -- a codebook block was likely",
            "mis-parsed; those members carry NA geography metadata."),
      i = paste("{scan_blocks} block(s) fell back from the byte-exact parse to the",
                "run-scanner; inspect those in the geography codebook.")),
      class = "canivt_geo_flow_gap")
  tibble::tibble(member_id = seq_len(n_geo), geo_label = label,
                 geo_name = join(res_name, work_name),
                 geo_name_fr = join(res_fr, work_fr), geouid = uids,
                 geo_res_name = res_name, geo_res_name_fr = res_fr, geo_res_uid = res_uid,
                 geo_work_name = work_name, geo_work_name_fr = work_fr, geo_work_uid = work_uid)
}

# Split a flow's combined display string into its two side names: place of
# residence (the origin, before " / ") and place of work (the destination).
# Splitting on " / " can over-split a side whose own name carries a slash, so
# sides are re-merged greedily to one parenthesised code each; each side's name is
# the text before its "(code)".
ivt_f2_flow_sides <- function(label) {
  res <- rep(NA_character_, length(label)); work <- res
  for (i in seq_along(label)) {
    s <- label[i]; if (is.na(s)) next
    parts <- strsplit(s, " / ", fixed = TRUE)[[1]]
    sides <- character(0); cur <- ""
    for (p in parts) {
      cur <- if (nzchar(cur)) paste(cur, p, sep = " / ") else p
      if (grepl("\\([0-9]{3,9}\\)", cur)) { sides <- c(sides, cur); cur <- "" }
    }
    if (length(cur) && nzchar(cur)) sides <- c(sides, cur)
    nmn <- trimws(sub("\\s*\\([0-9]{3,9}\\).*$", "", sides))
    if (length(nmn) >= 1L) res[i]  <- nmn[1L]
    if (length(nmn) >= 2L) work[i] <- nmn[2L]
  }
  list(res = res, work = work)
}

ivt_f2_geo_inline_dir <- function(raw) {
  if (!is.null(ivt_f2_geo_schema(raw))) return(NULL)   # modern layout: not inline
  ents <- ivt_f2_geo_entries(raw)                       # Stage 1 (shared)
  if (is.null(ents)) return(NULL)
  n_geo <- ivt_f2_geo_count(raw)
  if (is.na(n_geo) || n_geo < 1L) return(NULL)
  lay <- ivt_f2_chunk_layout(n_geo)
  sizes <- lay$sizes
  total <- lay$n_chunks
  # chunk value blocks in directory (logical) order; classification by the
  # run-scanner, values strict-first (see ivt_f2_dir_entry_members). Dense values
  # are usable as-is: if a dense block skipped absent members its record count
  # misses the chunk size below and we fall back.
  vb <- vector("list", ents$n); k <- 0L
  for (r in seq_len(ents$n)) {
    t <- ents$records(r)
    if (length(t) >= 3L && length(t) <= 256L && !ivt_f2_is_ordinal(t)) {
      k <- k + 1L
      vb[[k]] <- ents$values(r)                        # strict-first, records fallback
    }
  }
  length(vb) <- k
  chunk_of <- function(gi) lay$groups[[gi]]$chunk       # expected sizes of group gi's chunks
  # assemble the R runs (trailing non-member candidates make k %/% total over-count
  # on tiny tables, so try R from the division estimate downward until a walk fits).
  # A run's chunks normally follow member order (partial chunk last), but the 2006
  # vintage stores the last group's PARTIAL chunk first within each run (sometimes
  # padded to a full 256 slots) -- accepted as a rotation, with the partial placed
  # back at its member position.
  fit <- function(bb, w) {
    bb <- lapply(seq_along(bb), function(j) {          # trim the empty-slot padding
      t <- bb[[j]]
      if (length(t) > w[j] && all(is.na(t[(w[j] + 1L):length(t)])))
        t[seq_len(w[j])] else t
    })
    if (identical(vapply(bb, length, 1L), w)) bb else NULL
  }
  # `skip` leading candidate blocks may precede the group runs (98-400-X2016120
  # carries two odd-sized auxiliary blocks, 185 and 232 records, BEFORE the
  # runs; 98-400-X2016328 carries the same two AFTER them, where the walk never
  # sees them). A wrong skip cannot fit spuriously: the partial chunks (record
  # count != 256) sit at fixed positions and misalign any shifted walk.
  walk <- function(R, skip = 0L) {
    if (k < skip + R * total) return(NULL)
    runs <- rep(list(character(0)), R)
    pos <- 1L + skip
    for (gi in seq_along(sizes)) {
      G <- sizes[gi]; want <- chunk_of(gi)
      for (rr in seq_len(R)) {
        b0 <- vb[pos:(pos + G - 1L)]; pos <- pos + G
        b <- fit(b0, want)
        if (is.null(b) && G > 1L && want[G] != want[1L]) {
          b <- fit(b0, c(want[G], want[seq_len(G - 1L)]))   # partial stored first
          if (!is.null(b)) b <- c(b[-1L], b[1L])
        }
        if (is.null(b)) return(NULL)
        runs[[rr]] <- c(runs[[rr]], unlist(b))
      }
    }
    runs
  }
  if (k < 2L * total) return(NULL)
  runs <- NULL
  for (R in seq.int(min(k %/% total, 6L), 2L, by = -1L)) {
    for (skip in 0:min(k - R * total, 8L)) {
      runs <- walk(R, skip)
      if (!is.null(runs)) break
    }
    if (!is.null(runs)) break
  }
  if (is.null(runs)) return(NULL)
  # run roles by content: the combined runs parse as "name (code) flag" (flag-last)
  # or "name, type (code)" (code-last) -- either counts (`ivt_f2_parse_inline`).
  prate <- vapply(runs, function(v) {
    nn <- v[!is.na(v)]
    if (!length(nn)) 0 else mean(!is.na(ivt_f2_parse_inline(nn)$code))
  }, 0)
  cmb <- which(prate >= 0.8)
  if (!length(cmb)) return(NULL)
  # English combined run by frscore over the members where the two copies differ;
  # the OTHER combined run (when a distinct one exists) is the French copy. On the
  # 1991/2006/2011 vintages the two combined runs are identical bilingual "EN | FR"
  # blocks, so geo_name_fr collapses to geo_name (French falls back to it in tidy).
  en_i <- cmb[1L]; fr_i <- NA_integer_
  if (length(cmb) >= 2L) {
    if (ivt_f2_pick_en(runs[[cmb[1L]]], runs[[cmb[2L]]])$en_first) {
      en_i <- cmb[1L]; fr_i <- cmb[2L]
    } else {
      en_i <- cmb[2L]; fr_i <- cmb[1L]
    }
  }
  pe <- ivt_f2_parse_inline(runs[[en_i]])
  nm <- pe$name; cd <- pe$code; fl <- pe$flag; ty <- pe$type; tnr <- pe$tnr
  length(nm) <- length(cd) <- length(fl) <- length(ty) <- length(tnr) <- n_geo
  nm_fr <- if (!is.na(fr_i)) ivt_f2_parse_inline(runs[[fr_i]])$name
           else rep(NA_character_, n_geo)
  length(nm_fr) <- n_geo
  okm <- !is.na(cd)
  # a positional code array (a non-combined run equal to the parsed codes) is
  # preferred as the uid -- it also cross-validates the run alignment
  codes <- cd
  for (rr in setdiff(seq_along(runs), cmb)) {
    v <- trimws(runs[[rr]])
    ok <- okm & !is.na(v)
    if (sum(ok) && all(v[ok] == cd[ok])) { codes <- v; break }
  }
  # recover the display name for members the positional parse missed -- the code is
  # embedded mid-name (some dual-name CSDs) or the member is a code-only enumeration
  # area -- by subtracting the tokens we hold from the dedicated arrays. Fills only
  # NA names, so validated tables are untouched; the fr copy from its own run.
  raw_en <- runs[[en_i]]; length(raw_en) <- n_geo
  miss <- is.na(nm) & !is.na(raw_en)
  if (any(miss)) {
    nm[miss] <- ivt_f2_inline_name_subtract(raw_en[miss], codes[miss])
    if (!is.na(fr_i)) {
      raw_fr <- runs[[fr_i]]; length(raw_fr) <- n_geo
      mf <- is.na(nm_fr) & !is.na(raw_fr)
      nm_fr[mf] <- ivt_f2_inline_name_subtract(raw_fr[mf], codes[mf])
    }
    ivt_fallback(paste(
      "{sum(miss)} geography display name(s) were recovered by subtracting the",
      "code / quality-flag tokens from the combined inline string (the positional",
      "parse found no name -- a mid-name code or a code-only geography)."))
  }
  g <- ivt_f2_inline_table(nm, nm_fr, codes, fl, ty, tnr)
  ivt_f2_check_geo_count(raw, nrow(g))
  g
}

# Assemble the inline geography tibble from the parsed combined-record fields:
#   geo_label      the stored combined display string, verbatim apart from
#                  whitespace trim (what the B2020 viewer shows -- the
#                  member-order join key for viewer validation);
#   geo_name(_fr)  its English / French halves (`ivt_f2_split_bilingual()`; the
#                  same string in both when the member has one name). When a
#                  DISTINCT French combined run exists AND its differing names
#                  actually read French, its split French half wins for
#                  geo_name_fr -- the aggregate-frscore gate keeps the custom
#                  exports' second run (an alternate ENGLISH display copy, e.g.
#                  cro's type-suffix-less duplicate) out of the French column;
#   geouid / dqf_code / geo_type_abbr / tnr_short_form  as parsed (the last two
#                  all-NA on vintages that store neither).
ivt_f2_inline_table <- function(nm, nm_fr, codes, fl, ty, tnr) {
  label <- trimws(nm)
  sp <- ivt_f2_split_bilingual(label)
  name_fr <- sp$fr
  lab_fr <- trimws(nm_fr)
  d <- which(!is.na(lab_fr) & !is.na(label) & lab_fr != label)
  if (length(d) && ivt_f2_frscore(lab_fr[d]) > ivt_f2_frscore(label[d]))
    name_fr[d] <- ivt_f2_split_bilingual(lab_fr[d])$fr
  tibble::tibble(member_id = seq_along(label), geo_label = label,
                 geo_name = sp$en, geo_name_fr = name_fr, geouid = codes,
                 geo_type_abbr = ty, dqf_code = fl, tnr_short_form = tnr)
}

#' Geography table for an inline-codebook (pre-DGUID) family-2 IVT.
#'
#' Returns a tibble with one row per geography (member order) and columns
#' `geo_label` (the stored display string, often a bilingual "EN | FR" /
#' "EN / FR" combined label), `geo_name` / `geo_name_fr` (its English and
#' French halves, split per run by `ivt_f2_split_bilingual()`), `geouid` (bare
#' geographic code, character), `geo_type_abbr` (the geography-type /
#' municipal-status abbreviation, where the vintage stores one), `dqf_code`
#' (data-quality flag) and `tnr_short_form` (the total non-response rate the
#' 2016+ exports append). Primary read: positionally from
#' the geography dimension's block directory (`ivt_f2_geo_inline_dir()` -- true
#' member order, no dedup). Fallback: the marker-region block scan + regex parse
#' with first-appearance dedup (which can misorder chunks stored out of byte
#' order). Returns NULL when there is no geography marker region (modern DGUID
#' layouts). Validated vs the StatCan member metadata for 1003011 (1991, all
#' 41,859 members exact incl. the tail the dedup path misordered),
#' 98-312-XCB2011033 (2011) and 97-563-XCB2006072 (2006).
#'
#' @keywords internal
#' @noRd
ivt_f2_geo_inline <- function(raw) {
  # Origin-destination flow geography FIRST: it is gated tightly (a complete
  # code/code uid array summing to the header geography count) so it returns NULL
  # for every non-flow table, but on the flow tables it must win over the plain
  # inline reader -- the latter latches onto the single-side name array (e.g. 239
  # unique CDs on 98-400-X2016391) and returns the wrong member count.
  g <- ivt_f2_geo_flow_dir(raw)                          # origin-destination flows
  if (!is.null(g)) return(g)
  g <- ivt_f2_geo_inline_dir(raw)
  if (!is.null(g)) return(g)
  # a geography attribute schema (GEO_NAME field list) means the modern DGUID
  # attribute-array codebook -- never the inline combined-record layout -- so
  # bail before the marker-region block scan. The directory readers above gate
  # on the same discriminator; without it the Pascal run-scanner walked the
  # whole multi-MB geography codebook of every large schema'd table (~17 s of
  # the 20 s metadata read on 98-10-0023) only to find no inline blocks.
  if (!is.null(ivt_f2_geo_schema(raw))) return(NULL)
  region <- ivt_f2_geo_marker_region(raw)
  if (is.null(region)) return(NULL)
  blocks <- ivt_find_member_blocks(raw, max(0L, region[1] - 50L), min_records = 3L)
  blocks <- Filter(function(b) b$start >= region[1] && b$start < region[2], blocks)
  blocks <- blocks[order(vapply(blocks, function(b) b$start, 1))]
  pat <- IVT_F2_INLINE_PAT
  is_inline <- vapply(blocks, function(b)
    length(b$texts) >= 16L && mean(grepl(pat, b$texts, perl = TRUE)) > 0.8,
    logical(1))
  seen <- new.env(hash = TRUE, parent = emptyenv())
  nm <- character(0); cd <- character(0); fl <- character(0)
  ty <- character(0); tnr <- character(0)
  for (b in blocks[is_inline]) {
    p <- ivt_f2_parse_inline(b$texts)
    for (i in which(!is.na(p$code))) {
      code <- p$code[i]
      if (!is.null(seen[[code]])) next
      seen[[code]] <- TRUE
      nm <- c(nm, p$name[i]); cd <- c(cd, code); fl <- c(fl, p$flag[i])
      ty <- c(ty, p$type[i]); tnr <- c(tnr, p$tnr[i])
    }
  }
  if (!length(cd)) return(NULL)
  # This path found real geographies that the positional directory read could
  # not: the regex + first-appearance-dedup scan is exactly the reader that
  # silently misordered thousands of members on 1991/2006/2011 before the
  # positional read replaced it, so its member ORDER cannot be trusted blindly.
  ivt_fallback(paste(
    "The inline geography codebook was parsed by the marker-region regex scan,",
    "not read positionally from the block directory; the member order of",
    "byte-order + dedup scans has been wrong before on chunked codebooks."))
  g <- ivt_f2_inline_table(nm, rep(NA_character_, length(nm)), cd, fl, ty, tnr)
  ivt_f2_check_geo_count(raw, nrow(g))
  g
}

# Validate a decoded geography count against the header's declared count. The
# header dimension descriptor states the geography member count explicitly
# (`ivt_f2_header_geo_count()`), so we never have to trust the parser's own tally:
# a mismatch means the codebook stitch dropped or duplicated a chunk. Raised
# through `ivt_fallback()` (subclass `canivt_geo_count`) so a short/duplicated
# read is an ERROR under `options(canivt.strict = TRUE)` -- 98-10-0013's scan
# path delivered 5,191 of 5,447 members with only a plain warning before this
# was classed.
ivt_f2_check_geo_count <- function(raw, got) {
  want <- ivt_f2_geo_count(raw)
  if (!is.na(want) && !is.na(got) && got != want) {
    ivt_fallback(c(
      "Decoded {got} geographies but the header declares {want}.",
      i = "The geography codebook stitch may have dropped or duplicated a chunk."
    ), class = "canivt_geo_count")
  }
  invisible(want)
}

# SAFETY NET against silent parser truncation: after every geography name-fill, no
# member should be nameless. A residual NA `geo_name` means a codebook block was
# mis-parsed and a member dropped or truncated -- surface it LOUDLY (`canivt_fallback`,
# a strict-mode ERROR) rather than emit a nameless geography, the failure mode the
# loud-fallback design exists to prevent. Every table in the corpus decodes a complete
# `geo_name`, so this never fires on a clean read; it is a tripwire for regressions and
# new vintages. `nvals` counts real members even when the count matches by coincidence.
ivt_f2_check_geo_names <- function(geo_name) {
  if (is.null(geo_name)) return(invisible(0L))
  nmiss <- sum(is.na(geo_name)); nvals <- length(geo_name)
  if (nmiss > 0L)
    ivt_fallback(c(
      paste("{nmiss} of {nvals} geographies decoded with no name -- a codebook",
            "block may have been mis-parsed and members dropped."),
      i = "The affected members carry NA geo_name; inspect the geography codebook."),
      class = "canivt_geo_name_gap")
  invisible(nmiss)
}

#' Decode the geography table, driven by the header metadata.
#'
#' Single metadata-driven entry point that consolidates the two codebook layouts:
#' it prefers the marker-anchored inline parser (`ivt_f2_geo_inline()`, the pre-DGUID
#' "name (code) flag" codebook found in 1991/2006/2011) and otherwise falls to the
#' modern DGUID attribute parser (`ivt_f2_geo_attributes()`), validates the row count
#' against the header, and returns a tibble whose leading columns are always
#' `member_id`, `geo_name` and `geo_uid` (the DGUID for 2016+ tables, the bare
#' GEOUID for older ones), followed by any layout-specific attribute columns.
#'
#' The FULL attribute table (the `read_ivt(geo_attributes = TRUE)` path): a tibble
#' keeping every column, including all-NA ones (a tested contract). Intentionally
#' distinct from the lean `ivt_f2_geo_light()` default -- see refactor-plan.md §5.1.
#'
#' @keywords internal
#' @noRd
# Lift a light-style geography column list (what the custom / bare / uid-only
# readers return -- the full path now reaches them via `ivt_f2_geo_read()`) to the
# full tibble contract: a 1-based `member_id` then the columns the reader actually
# produced. NULL columns (the uid-only reader's absent `geo_name`) are dropped, as
# they carry no member data.
ivt_f2_geo_list_to_tibble <- function(g) {
  g <- g[!vapply(g, is.null, logical(1))]
  n <- if (length(g)) max(lengths(g)) else 0L
  tibble::as_tibble(c(list(member_id = seq_len(n)), g))
}

ivt_f2_geographies <- function(raw) {
  g <- ivt_f2_geo_read(raw, full = TRUE)
  # the schema / inline / flow readers return a tibble already; the custom / bare /
  # uid readers return a list of columns -- lift it to a member-ordered tibble.
  if (!is.data.frame(g)) g <- ivt_f2_geo_list_to_tibble(g)
  g <- ivt_f2_flag_dqf_note_truncation(g)
  g[, ivt_geo_col_order(names(g))]
}

# --- Header dimension descriptor ----------------------------------------------
#
# The fixed header field @32 (u32) points at a descriptor block that explicitly
# declares the table's dimensions -- present in BOTH the modern and legacy formats,
# so it is the reliable source of dimension metadata (the legacy format has no
# inline "Variable List" text). Layout of the descriptor:
#   +16 u16  number of dimensions
#   +52      first dimension record, then one record per dimension. Each record
#            stores its display name TWICE back-to-back ("GeographyGeography"),
#            preceded by a 0x01 separator; this **doubled name** is the reliable
#            anchor. The count/type framing bytes immediately before the separator
#            vary by dimension, so we read them relative to the doubled name rather
#            than scanning for a fixed "<type> 01" marker:
#            - normal record  `[count][type][01]<name><name>`  (type @ sep-1,
#              count @ sep-2; geography type 0x10 carries a u16 count at sep-3..-2,
#              member counts > 255)
#            - period / facet record  `[type][count][01][01]<name><name>` -- the
#              reference-period dimension (type 0x0e, e.g. "Year (2)" in tables
#              spanning two censuses) is type-first with a doubled 0x01, which is
#              exactly why a rigid "<known type> 01 <upper>" scan silently dropped
#              it (and the table's 7th dimension with it).
#            - <type> is a storage/classification tag, NOT a fixed dimension
#              identity: 0x10/0x08 geography, 0x07 age-type, 0x02 gender/sex-type
#              or a small categorical, 0x03/0x04/0x05 generic ordinal/categorical,
#              0x0e reference period. (In 98-10-0241 type 0x02 is "Statistics".)
#   later    "FACET04" + the English title (the legacy file appends "1991 Census...")
# Validated: dims recovered exact on 98-10-0023 (63404/128/3), 1003011
# (41859/110/3), 98-10-0241 (166 + 6 data dims) and 98-10-0077 (174 + 6 data dims
# incl. the "Year (2)" reference period).

# The dimension-descriptor block opens with an invariant 9-byte signature on
# EVERY known layout (family-1, family-2, legacy and profile): `81 01 20 00 f0`
# then `.. .. 80 03` (`81 01` block marker, u16 len 0x20, then `f0<XX>00 80 03`;
# the fifth/sixth bytes vary `20`/`28`). The Canadian Business Patterns lineage
# closes the signature with `80 ff` instead of `80 03` (`f0 00 00 80 ff` /
# `f0 00 80 80 ff`), so b9 is accepted as either. This lets the descriptor be
# located structurally rather than trusting a single header pointer -- some
# custom-order exports (ord-08035, the cro crosstabs) point the `@32` field at
# the identity / title block instead, while still listing the descriptor in the
# master directory; Business Patterns points `@32` at a zero-filled slot and the
# descriptor is recovered only by this signature scan.
ivt_f2_is_descriptor <- function(raw, off) {
  if (is.null(off) || is.na(off) || off < 1L || off + 18L > length(raw)) return(FALSE)
  b <- as.integer(raw[(off + 1L):(off + 9L)])
  b[1] == 0x81L && b[2] == 0x01L && b[3] == 0x20L && b[4] == 0x00L &&
    b[5] == 0xf0L && b[8] == 0x80L && (b[9] == 0x03L || b[9] == 0xffL)
}

#' Locate the dimension-descriptor block.
#'
#' `@32` points at it on the standard tables. Custom-order exports point `@32` at
#' the title/identity block instead; the descriptor is then found from the master
#' directory (whose entries carry `(off, len)` in the same 8-byte shape as the
#' page directory) or, failing that, a signature scan -- both loud fallbacks.
#' @keywords internal
#' @noRd
ivt_f2_descriptor_offset <- function(raw) {
  n <- length(raw)
  D <- rd_u32(raw, IVT_HDR_DESCRIPTOR_PTR)
  if (ivt_f2_is_descriptor(raw, D)) return(as.integer(D))
  # The master directory is itself a positional, header-anchored structure and
  # every candidate is confirmed by the strict descriptor signature, so this
  # relocation is not a content heuristic and stays quiet (custom-order exports
  # legitimately point @32 at the identity block). Only the signature scan below,
  # a content search, is a loud fallback.
  md <- tryCatch(ivt_f2_master_dir(raw), error = function(e) NULL)
  if (!is.null(md)) {
    for (r in seq_len(nrow(md))) {
      off <- as.integer(md[r, "off"])
      if (ivt_f2_is_descriptor(raw, off)) return(off)
    }
  }
  hit <- ivt_f2_scan_descriptor(raw)
  if (!is.na(hit)) {
    ivt_fallback(
      "Descriptor pointer @32 does not resolve; located by signature scan.",
      "canivt_descriptor_reloc")
    return(hit)
  }
  if (!is.na(D) && D >= 1L && D + 18L <= n) as.integer(D) else NULL
}

# First offset whose 9-byte prefix is the descriptor signature, else NA.
ivt_f2_scan_descriptor <- function(raw) {
  n <- length(raw)
  hits <- which(raw[seq_len(n - 8L)] == as.raw(0x81) &
                raw[2:(n - 7L)]      == as.raw(0x01) &
                raw[3:(n - 6L)]      == as.raw(0x20) &
                raw[4:(n - 5L)]      == as.raw(0x00) &
                raw[5:(n - 4L)]      == as.raw(0xf0))
  for (h in hits) if (ivt_f2_is_descriptor(raw, h - 1L)) return(h - 1L)
  NA_integer_
}

# Extract a dimension name from the printable run that follows the `0x01`
# separator. The name is stored TWICE back-to-back; `first_record` allows the
# opening (geography) record to store its name once, followed by inline member
# text instead of a second copy (the ord-08035 custom export). `count` is the
# framing member count, used only by the last (prose-bleed) fallback. Returns
# the name or NA when the run is not a dimension name.
ivt_f2_descriptor_name <- function(run, first_record = FALSE, count = NA_integer_) {
  rl <- length(run)
  if (rl < 2L) return(NA_character_)
  # Standard layout: two identical copies. Largest p with run[1:p]==run[(p+1):2p];
  # the first copy may be truncated at a ~15-byte cap, so prefer the (complete)
  # tail when the first copy is capped and the tail strictly extends it.
  half <- NA_integer_
  for (p in seq.int(rl %/% 2L, 1L)) {
    if (identical(run[1:p], run[(p + 1L):(2L * p)])) { half <- p; break }
  }
  if (!is.na(half) && half >= 2L) {
    if (half >= 14L && rl > 2L * half) {
      # first copy capped at ~15 bytes; prefer the complete tail. On the 2001
      # F-series (97F0015X) French description prose bleeds onto the tail after
      # the name, so trim it at the end of the "(count)" the name ends with when
      # a framing count is available (tables whose tail has no "(count)", e.g.
      # the 2006 "Presence of income..." completion, are left whole).
      tail <- trimws(intToUtf8(run[(half + 1L):rl]))
      if (!is.na(count) && count >= 1L) {
        p <- regexpr(sprintf("(%d)", count), tail, fixed = TRUE)
        if (p > 0L) tail <- substr(tail, 1L, p + attr(p, "match.length") - 1L)
      }
      return(tail)
    }
    return(trimws(intToUtf8(run[1:half])))
  }
  # No exact double. Split at the first (lowercase|space) -> uppercase transition;
  # every accepted shape needs a genuine repeated-name signal so the lenient path
  # cannot swallow descriptor formats that interleave the name with description
  # prose (97F0015X: "Geographyle nomGeographyconnexes, c'est-a-dire ...").
  is_up <- run >= 65L & run <= 90L
  is_lo <- run >= 97L & run <= 122L
  b <- NA_integer_
  for (i in 2:rl) if (is_up[i] && (is_lo[i - 1L] || run[i - 1L] == 32L)) { b <- i; break }
  if (is.na(b)) return(NA_character_)
  name1 <- trimws(intToUtf8(run[1:(b - 1L)]))
  name2 <- trimws(intToUtf8(run[b:rl]))
  if (!nzchar(name1)) return(NA_character_)
  # (a) space-separated exact double ("Tenure Tenure").
  if (identical(tolower(name1), tolower(name2))) return(name1)
  namelike <- nchar(name2) <= 40L && !grepl("[^[:alnum:] ()/,.'-]", name2)
  # (b) short "variable" name then its longer display name -- the display name
  #     ENDS with the short name (a front qualifier is prepended: "Selected " +
  #     "Characteristics"). Requiring a suffix (not just any substring) rejects
  #     the "<first word> ... <first word> + prose" bleed of 97F0015X, where the
  #     boundary falls on an internal word space rather than the copy boundary.
  if (namelike && name1 != name2 && endsWith(name2, name1)) return(name2)
  # (c) a single clean Title-case name followed by inline member text -- only the
  #     opening geography record ("Geography" then "ORD 08588 (…)").
  if (!namelike && first_record &&
      grepl("^[A-Z][A-Za-z]+( [A-Z][A-Za-z]+)*$", name1)) return(name1)
  # (d) prose-bleed data dim with the copies NON-adjacent (2001 F-series
  #     97F0015X): French prose bleeds BETWEEN the two copies ("Sex (3)atif
  #     totSex (3) et les ..."), so the adjacent-double and split paths miss.
  #     The name ends in "(count)" and the framing count is known: take the
  #     shortest prefix that completes "(count)", de-truncating a capped first
  #     copy (A+B with A a prefix of B -> B), and accept only a clean
  #     title-case name so a stray "(count)" in prose cannot match.
  s <- intToUtf8(run)
  if (!is.na(count) && count >= 1L) {
    p <- regexpr(sprintf("(%d)", count), s, fixed = TRUE)
    if (p > 0L) {
      cand <- substr(s, 1L, p + attr(p, "match.length") - 1L)
      best <- cand
      for (a in seq_len(min(16L, nchar(cand) - 1L))) {
        A <- substr(cand, 1L, a); B <- substr(cand, a + 1L, nchar(cand))
        if (startsWith(B, A)) best <- B
      }
      if (grepl("^[A-Z][A-Za-z0-9 ()&,.'/-]*\\(\\d+\\)$", best)) return(trimws(best))
    }
  }
  # (e) prose-bleed geography record (no "(count)" to anchor on): French prose
  #     bleeds BETWEEN the two "Geography" copies ("Geographyle nomGeography
  #     connexes ..."). Recover it as the longest prefix that reoccurs later in
  #     the run, when that prefix is a clean title-case token. First record only.
  if (first_record) {
    rep <- ""
    for (kk in seq_len(nchar(s) %/% 2L)) {
      pfx <- substr(s, 1L, kk)
      if (regexpr(pfx, substr(s, kk + 1L, nchar(s)), fixed = TRUE) > 0L) rep <- pfx
    }
    if (nchar(rep) >= 3L && grepl("^[A-Z][A-Za-z]+$", rep)) return(rep)
  }
  NA_character_
}

#' Parse the header dimension descriptor.
#' @return list(n_dim, dims = list(name, count, type), title) or NULL.
#' @keywords internal
#' @noRd
# Build the dimension list directly from the header slot table (dimdir.R) when
# the descriptor region walk fails to recover it. The larger 2016 custom-extract
# crosstabs (the CMHC movers "Commuters"/"NOCs" tables) bleed a long footnote
# paragraph INTO the descriptor block, leaving the doubled-name walk almost
# nothing to anchor on -- but the header slot directories still list every
# dimension in order (slot k = descriptor dimension k), each resolving a name
# marker (`ivt_f2_dim_marker_name`) and a member array whose real length is the
# member count (`ivt_f2_dir_member_count`). Returns a `ndim`-long dims list, or
# NULL if any slot fails to yield a name + positive member count (so the caller
# keeps the walk's result rather than a partial rebuild). Type is a placeholder:
# the decoder is type-agnostic (it nests by count), and the geography stays
# dimension 1. Passes `slots` through so it never re-enters the descriptor parse.
ivt_f2_dims_from_slots <- function(raw, slots, ndim) {
  if (is.null(slots) || ndim < 2L || ndim > length(slots)) return(NULL)
  out <- vector("list", ndim)
  for (k in seq_len(ndim)) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) return(NULL)
    nm <- ivt_f2_dim_marker_name(raw, k, slots)
    if (is.na(nm) || !nzchar(nm)) return(NULL)
    mc <- ivt_f2_dir_member_count(raw, nm, dir)
    cnt <- suppressWarnings(as.integer(mc$count))
    if (is.na(cnt) || cnt < 1L) return(NULL)
    out[[k]] <- list(name = nm, count = cnt, type = 0L, double01 = FALSE)
  }
  out
}

ivt_f2_descriptor <- function(raw)
  ivt_memo(raw, "descriptor", function() ivt_f2_descriptor_impl(raw))

ivt_f2_descriptor_impl <- function(raw) {
  n <- length(raw)
  D <- ivt_f2_descriptor_offset(raw)
  if (is.null(D) || is.na(D) || D < 1 || D + 18 > n) return(NULL)
  D <- as.integer(D)
  ndim <- rd_u16(raw, D + 16L)

  # Walk a bounded byte region for dimension records; a record is a 0x01 whose
  # following printable run is the dimension name stored twice
  # (`ivt_f2_descriptor_name()` handles the standard doubling, truncated first
  # copies, space-separated / short+display pairs, and the single-name geography
  # record of the ord custom export). Read count/type from the bytes just before
  # the 0x01. The name may start with an uppercase letter OR a digit ("1995
  # Household Income (3)" in the 1996 table 95F0250XDB96001 -- the
  # uppercase-only anchor silently dropped that dimension).
  walk_records <- function(v, Lend, cap, lenient = FALSE) {
    dims <- list()
    k <- 4L
    while (k <= Lend - 1L && length(dims) < cap) {
      c1 <- v[k + 1L]
      # the standard walk anchors an UPPERCASE- or DIGIT-led name after the 0x01;
      # the accept-all pass also admits a lowercase-led name (the 2016 custom
      # extract's "charschars" dimension) -- the exact-count self-check below
      # keeps that from over-matching.
      namestart <- (c1 >= 65L && c1 <= 90L) || (c1 >= 48L && c1 <= 57L) ||
                   (lenient && c1 >= 97L && c1 <= 122L)
      # u16 member-count type tags (see the count block below). Also the set that
      # can open a no-`01` geography record (anchor B).
      geotypes <- c(0x10L, 0x0dL, 0x0aL, 0x0cL, 0x09L, 0x0fL, 0x0bL)
      # anchor A: the standard `[count][type] 01 <name>` framing (v[k] is the 0x01).
      # anchor B (lenient only): a large geography stored as `[count_lo][count_hi]
      # [geotype] <name>` with NO 0x01 separator -- the Canadian Business Patterns
      # descriptor (`2c c7 10 DADissemination Area...`, type 0x10, count 0xc72c =
      # 50988), whose geography record the standard 0x01 anchor cannot see. It
      # fires wherever that record sits -- first (Dec07: geography-first), last
      # (Dec08/2012+: geography-last) or middle (Dec10/11) as the tabulation order
      # varies year to year -- NOT gated to position. The tight framing (a u16
      # geography count with count_hi > 0, so >= 256) plus the exact-`ndim_auth`
      # adoption guard reject any spurious match, so it never fires on a table the
      # standard walk already reads.
      anchorA <- v[k] == 0x01L && namestart
      anchorB <- lenient && !anchorA && namestart && k >= 4L &&
                 v[k] %in% geotypes && v[k - 1L] > 0L &&
                 (v[k - 2L] + v[k - 1L] * 256L) <= 200000L
      if (anchorA || anchorB) {
        e <- k + 1L
        while (e <= length(v) && v[e] >= 32L && v[e] <= 126L) e <- e + 1L
        run <- v[(k + 1L):(e - 1L)]
       if (!lenient || length(run) >= 4L) {          # a 1-char "P" is not a name
        # count/type come from the framing bytes before the 0x01 (computed here so
        # the count can hint the name recovery -- some 2001 descriptors bleed
        # French prose into the name copies, see below).
        double01 <- anchorA && v[k - 1L] == 0x01L
        if (anchorB) {                             # no-01 geography: type at v[k]
          type <- v[k]; count <- v[k - 2L] + v[k - 1L] * 256L
        } else if (double01) {                     # period/facet double-01 framing
          type <- v[k - 3L]; count <- v[k - 2L]
        } else {
          type <- v[k - 1L]
          # the descriptor stores a (large) member count as a 16-bit little-endian
          # value `[count_lo][count_hi][type][01]`; the type byte tags the storage
          # width. u16 types: 0x10 (modern DGUID geography, e.g. 63404 in
          # 98-10-0023; 57523 in the 2006 DA table), 0x0d (the 2011 census-tract
          # geography, 5447; also the 1981/1991 profile geographies; the 2001
          # F-series 97F0015X's geography), 0x0a / 0x0c (the profile lineage's
          # characteristics / geography dimensions, e.g. 98F0172X's Profile(529)
          # and Geography(4063)) and 0x09 (the >256-member "Selected
          # characteristics"/detailed-classification data dimensions: 97F0020X's
          # Selected(282) and 98-10-0174's Mother tongue(331), both chunked
          # >256-member codebooks -- the u8 read took the low byte and got 1,
          # which mis-nested the layout) and 0x0f (the 2011 NHS commuting-flow
          # geography, an origin-destination flow enumeration, e.g. 17163 in
          # 99-012-X2011032 -- the u8 read got the high byte 67, collapsing the
          # 27 data pages to 201 cells) and 0x0b (the 2016 CMA/CA commuting-flow
          # geography, e.g. 1399 in 98-400-X2016327 -- the u8 read took the low
          # byte and got 5, collapsing the flow enumeration; framing bytes
          # `77 05 0b 01` = u16 0x0577). The small family-1 geography (type
          # 0x08, <=255) and the ordinary data dimensions carry a u8 count.
          # Reading 0x0d as u8 misread 2011's 5447 geographies as 21; 0x0a/0x0c
          # as u8 misread 98F0172X's dimensions as Profile(2)/Geography(15); 0x09
          # as u8 silently mis-decoded 98-10-0174's cells. (u16 is safe for a
          # small member of any of these types: count_hi is then 00.)
          count <- if (type %in% geotypes) v[k - 3L] + v[k - 2L] * 256L
                   else v[k - 2L]
        }
        nm <- ivt_f2_descriptor_name(run, first_record = length(dims) == 0L,
                                     count = count)
        if (is.na(nm) && lenient) {
          # the accept-all pass keeps every framed record even when the two name
          # copies do not relate (a <display><description> pair, e.g.
          # "CondoStat/Type" + "Condominium status and structural type"): the
          # clean name comes from the dimension's slot-directory name marker,
          # positionally; a leading crumb of the run is the last resort.
          nm <- ivt_f2_dim_marker_name(raw, length(dims) + 1L, slots_auth)
          if (is.na(nm)) nm <- trimws(substr(intToUtf8(run), 1L, 24L))
        }
        if (!is.na(nm)) {
          dims[[length(dims) + 1L]] <- list(name = nm,
                                            count = count, type = type,
                                            double01 = double01)
          k <- e; next
        }
       }
      }
      k <- k + 1L
    }
    dims
  }

  slots_auth <- NULL                               # set before the accept-all pass
  win <- min(D + 4000L, n)
  v <- as.integer(raw[(D + 1L):win])               # v[k] is byte D+k-1
  # the dimension records sit between the fixed header and the "FACET04" title;
  # bound the search there so stray 0x01 bytes in later binary do not match.
  txt <- intToUtf8(ifelse(v >= 32L & v <= 126L, v, 46L))
  facet <- regexpr("FACET04", txt)
  Lend <- if (facet > 0) facet - 1L else length(v)
  dims <- walk_records(v, Lend, ndim)

  # INVERTED layout (97-570-X1981002, 98-400-X2016019): the dimension records
  # PRECEDE the `81 01 20 00 f0 ...` signature block (which is followed by the
  # identity/title text instead), anchored after the same `81 02 03 00`
  # sub-header that follows the signature at D+14/15 on the standard profile
  # tables. When the forward walk recovers no usable records, retry the region
  # between the last `81 02 03 00` before D and D itself. Both anchors are
  # block signatures and the retry only wins when it recovers >= 2 doubled-name
  # records, so this stays structural (quiet, like the master-directory
  # relocation of the descriptor offset itself).
  if (length(dims) < 2L && D > 8L) {
    lo <- max(0L, D - 4096L)
    reg <- (lo + 1L):(D - 3L)
    sub <- reg[raw[reg] == as.raw(0x81) & raw[reg + 1L] == as.raw(0x02) &
               raw[reg + 2L] == as.raw(0x03) & raw[reg + 3L] == as.raw(0x00)]
    if (length(sub)) {
      sub <- sub[length(sub)] - 1L                 # 0-based offset of the last hit
      v2 <- as.integer(raw[(sub + 1L):D])          # bytes sub .. D-1
      dims2 <- walk_records(v2, length(v2), 32L)
      if (length(dims2) >= 2L) dims <- dims2
    }
  }

  # AUTHORITATIVE dimension count: the header n_dim field, corroborated by the
  # leading run of populated header slot-directory pointers (a 9-dimension custom
  # extract leaves dims 10-12 as null padding slots). When the strict name walk
  # recovers fewer records than that, the descriptor is the 2016 custom-extract
  # lineage (CRO0163850 / CRO0166131), which frames some dimension names as
  # unrelated <display><description> pairs the standard splitter drops (plus a
  # lowercase-led "chars" the anchor skips). Retry with the structural accept-all
  # walk and adopt it only if it recovers EXACTLY the authoritative count --
  # self-validating, and loud (a heuristic supplied the records).
  slots_auth <- ivt_f2_dim_slots(raw, m = 32L)
  ndim_auth <- ndim
  if (!is.null(slots_auth)) {
    # a populated slot has a plausible pointer and entry count; garbage slots
    # past the real dimensions carry huge random n_entries, so bound it.
    ok <- vapply(slots_auth, function(s) !is.na(s$ptr) && s$ptr > 0L &&
                   !is.na(s$n_entries) && s$n_entries > 0L && s$n_entries < 1e6L,
                 logical(1))
    lead <- if (!ok[1L]) 0L else {
      z <- which(!ok); if (length(z)) z[1L] - 1L else length(ok) }
    if (lead >= 2L) ndim_auth <- lead
  }
  if (length(dims) < ndim_auth && ndim_auth >= 2L && ndim_auth <= 32L) {
    lung <- walk_records(v, Lend, min(32L, ndim_auth + 4L), lenient = TRUE)
    if (length(lung) == ndim_auth) {
      ivt_fallback(sprintf(paste(
        "Descriptor: only %d of %d dimensions matched the standard doubled-name",
        "framing; recovered all %d via the structural accept-all walk (2016",
        "custom-extract lineage)."), length(dims), ndim_auth, ndim_auth),
        "canivt_descriptor_lenient")
      dims <- lung
    }
  }
  # Last resort: rebuild the whole descriptor from the header slot table. The
  # larger custom-extract crosstabs (the CMHC movers "Commuters"/"NOCs" tables)
  # bleed a long footnote paragraph INTO the descriptor region, so even the
  # accept-all walk finds almost no records -- but the slot directories still
  # cleanly list every dimension (slot k = descriptor dimension k). Adopted only
  # when it resolves EXACTLY the authoritative count (each slot must yield a name
  # + positive member count), so it cannot fire on a table the walk already read.
  if (length(dims) < ndim_auth && ndim_auth >= 2L && ndim_auth <= 32L) {
    built <- ivt_f2_dims_from_slots(raw, slots_auth, ndim_auth)
    if (!is.null(built)) {
      ivt_fallback(sprintf(paste(
        "Descriptor: the region walk recovered only %d of %d dimensions (a",
        "footnote bleeds into the descriptor block); rebuilt all %d from the",
        "header slot table."), length(dims), ndim_auth, ndim_auth),
        "canivt_descriptor_from_slots")
      dims <- built
    }
  }

  title <- regmatches(txt, regexpr("FACET04[^.]*", txt))
  title <- if (length(title)) trimws(sub("FACET04", "", title)) else NA_character_
  # The double-01-framed records are AMBIGUOUS: the genuine reference-period
  # record is [type][count][01][01]<name> ("Year (2)": 0e 02 01 01), but the
  # profile lineage's placeholder "Values" dimension shares the byte shape
  # (00 20 01 01 "ValuesValues") while its count is NOT at that position -- its
  # codebook stores exactly ONE member, and reading 0x20 as a count of 32 made
  # the whole layout mis-nest (97-570-X1981004 was rejected by the span rule as
  # "geography-last" when it is the ordinary layout with a 1-member outermost
  # dimension). Only the dimension's own slot-directory member block can decide,
  # so reconcile those counts against the codebook (dimdir.R); counts the
  # codebook cannot contradict (count <= stored member slots) are kept.
  dims <- ivt_f2_dim_count_reconcile(raw, dims)
  list(n_dim = ndim, dims = dims, title = title)
}

# The geography descriptor dimension record. Identified positionally as
# dimension `gd` (`ivt_f2_geo_dim_index()`, dimdir.R: dimension 1 in every
# layout except the profile-table lineage, which stores a 1-member "Values"
# placeholder first and geography LAST), NOT by a magic type byte: the
# geography descriptor *type* varies by format -- 0x10 in the modern 2021 family-2
# files (count stored as u16) but 0x08 in the family-1 reference table (count u8) --
# so a `type == 0x10` filter silently fails on other layouts (it falls through to
# the wrong fixed-offset count, e.g. 16383 for 98-10-0241). The count's byte width
# is still handled by `ivt_f2_descriptor()`.
ivt_f2_geo_dim <- function(dims, gd = 1L)
  if (length(dims) >= gd) dims[[gd]] else NULL

# Geography member count, from the descriptor's geography record. Reliable for any
# dimensionality; the fixed-offset u16 `ivt_f2_header_geo_count()` is only correct
# for 3-dimension tables (it reads 16320 instead of 63404 for the 4-dimension
# 98-10-0129). Falls back to the fixed-offset reader when the descriptor cannot be
# parsed.
ivt_f2_geo_count <- function(raw)
  ivt_memo(raw, "geo_count", function() ivt_f2_geo_count_impl(raw))

ivt_f2_geo_count_impl <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  geo <- if (is.null(d)) NULL
         else ivt_f2_geo_dim(d$dims, ivt_f2_geo_dim_index(raw, d))
  if (is.null(geo)) return(ivt_f2_header_geo_count(raw))
  as.integer(geo$count)
}

# The non-geography data dimensions, in descriptor (outer -> inner) order: their
# member `counts` (which drive the presence-bitmap nesting and the dense value
# order) and a short column `slug` for each. Geography is dimension
# `ivt_f2_geo_dim_index()` (dimension 1 outside the profile lineage), so the data
# dimensions are simply the rest. Slugs are a purely structural convenience: each
# is the lower-cased leading word of the dimension's metadata name (e.g.
# "Marital status" -> "marital"), falling back to "dim<i>", made unique. No code
# branches on a dimension's name or descriptor type byte -- dimensions are
# interchangeable and everything the decoder needs (geography position, member
# counts, value layout) is derived structurally. The human-readable labels come
# from the codebook at `tidy` time. Returns empty vectors when no descriptor /
# no data dimensions.
ivt_f2_data_dims <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || length(d$dims) < 2L) return(list(counts = integer(0), slugs = character(0)))
  gd <- ivt_f2_geo_dim_index(raw, d)
  idx <- setdiff(seq_along(d$dims), gd)
  data <- d$dims[idx]
  if (!length(data)) return(list(counts = integer(0), slugs = character(0)))
  counts <- vapply(data, `[[`, 1L, "count")
  nms <- vapply(data, function(d)
    if (is.null(d$name)) NA_character_ else as.character(d$name), "")
  list(counts = as.integer(counts), slugs = ivt_dim_slugs(nms, idx))
}

# Column names `ivt_decode()` assigns outside the data-dimension slugs: the
# geography member-id column (`ivt_layout()` slugs the geography dimension
# "geo") and the cell value column appended after the id columns. A data
# dimension whose leading word slugs to one of these -- "Value of dwelling" ->
# "value" is a real census dimension -- would collide silently: `out$value <-`
# overwrites the member-id column and `ivt_f2_tidy()`'s
# `setdiff(names, c("geo", "value"))` then drops the dimension entirely.
IVT_RESERVED_SLUGS <- c("geo", "value")

# Slugs for the data dimensions at descriptor positions `idx`, made unique
# against the reserved output names above AND each other (a colliding slug
# gets a numeric suffix: "value" -> "value1").
ivt_dim_slugs <- function(names, idx = seq_along(names)) {
  slugs <- vapply(seq_along(names), function(i) ivt_dim_slug(names[[i]], idx[i]), "")
  nres <- length(IVT_RESERVED_SLUGS)
  make.unique(c(IVT_RESERVED_SLUGS, slugs), sep = "")[-seq_len(nres)]
}

# Generic, name-agnostic column slug for a data dimension at 1-based descriptor
# position `i` (the geography dimension's "geo" slug is assigned by the caller,
# which knows which dimension that is): the lower-cased leading alphabetic word
# of its metadata name, or "dim<i>" when that is not a clean word. This is
# presentation only -- no decoder logic depends on the result.
ivt_dim_slug <- function(name, i) {
  w <- tolower(sub("^[^A-Za-z]*([A-Za-z]+).*$", "\\1", name))
  if (!nzchar(w) || !grepl("^[a-z]+$", w)) paste0("dim", i) else w
}

# Is this a family-2 file the decoder can actually handle? Several other Beyond
# 20/20 products (the "F"-series, 1981 census, custom CT extracts) share the
# `04 00 20 00` signature and even expose a page-directory-like structure, but
# their header descriptor is a different, undecoded layout: `ivt_f2_descriptor()`
# then reads a garbage dimension count (hundreds/thousands) and recovers zero data
# dimensions. Require a plausible descriptor with at least one positively-sized
# data dimension, so such files are rejected cleanly rather than crashing the
# decoder on an empty dimension list.
ivt_f2_decodable <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  # judge by the RECOVERED doubled-name dimension records, not the header count
  # field: the count misreads on some vintages whose dimensions parse fine (the
  # 1996 EA table 95F0200XDB96003 reads n_dim = 1026 with 4 clean dimensions),
  # and the truly incompatible variants recover no data dimensions at all.
  if (is.null(d) || length(d$dims) < 2L || length(d$dims) > 32L) return(FALSE)
  dd <- ivt_f2_data_dims(raw)
  if (!(length(dd$counts) >= 1L && all(!is.na(dd$counts) & dd$counts >= 1L)))
    return(FALSE)
  # the layout must resolve AND the first pages must decode consistently under
  # it (extent pre-flight) -- this is what rejects the incompatible 2001
  # "F"-series variant, whose descriptor parses but whose pages overrun.
  ivt_page_preflight(raw)
}
