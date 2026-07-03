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
  if (is.na(name) || !nzchar(name)) return(NULL)
  for (d in dims) {
    a <- d$name
    if (is.null(a) || is.na(a) || !nzchar(a)) next
    k <- min(nchar(a), nchar(name))
    if (k >= 4L && substr(a, 1L, k) == substr(name, 1L, k)) return(d)
  }
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
  data_dims <- if (!is.null(d) && length(d$dims) > 1L) d$dims[-1L] else list()
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
# 8-byte entries `[u32 off][u16 len][u16 len]` (null `(0,0)` slots tolerated). Returns
# a two-column matrix (off, len), or NULL when `ptr` is not a well-formed table.
ivt_f2_read_dir_at <- function(raw, ptr, max_entries = 100000L) {
  n <- length(raw)
  if (is.na(ptr) || ptr < 1L || ptr + 8L > n) return(NULL)
  offs <- integer(0); lens <- integer(0)
  for (i in seq_len(max_entries)) {
    base <- as.integer(ptr) + (i - 1L) * 8L
    if (base + 8L > n) break
    off <- rd_u32(raw, base); a <- rd_u16(raw, base + 4L); b <- rd_u16(raw, base + 6L)
    if (is.na(off) || is.na(a) || is.na(b)) break
    if (off == 0 && a == 0) next                       # null slot
    if (a != b || a <= 0L || off < 1 || off > n) break # end of table
    offs <- c(offs, off); lens <- c(lens, a)
  }
  if (!length(offs)) return(NULL)
  cbind(off = offs, len = lens)
}

# Decode the block directory a header `slot` points at (`slot` holds the directory's
# start offset). Kept for the family detector / legacy callers.
ivt_f2_read_block_dir <- function(raw, slot, max_entries = 8000L) {
  ivt_f2_read_dir_at(raw, rd_u32(raw, slot), max_entries)
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
  d <- ivt_f2_dim_dir(raw, 1L)                         # geography = dimension 1
  if (!is.null(d)) return(d)
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
#       and absent members are skipped entirely (the bitstream's per-member coding
#       is not yet decoded; the caller re-aligns the dense values with the NA
#       pattern of the entry's plain siblings). The one-byte marker before the
#       records is 0x80 or 0x01 (semantics unknown; both observed).
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
# content sniffing, no `d0 ± k*2G` stride: the block starts come from the header
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
  pick <- function(a, b) {                           # return list(en, fr)
    diff <- which(a != b)
    if (ivt_f2_frscore(a[diff]) <= ivt_f2_frscore(b[diff])) list(en = a, fr = b)
    else list(en = b, fr = a)
  }
  # schema field stem -> output column, by prefix in either direction (stems may be
  # stored truncated, e.g. GEO_LEVEL_DES vs GEO_LEVEL); same rule as ivt_f2_geo_slot_map.
  stem_col <- function(stem) {
    hit <- which(startsWith(stem, IVT_F2_ATTR_FIELD) | startsWith(IVT_F2_ATTR_FIELD, stem))
    if (length(hit)) names(IVT_F2_ATTR_FIELD)[hit[1L]] else NA_character_
  }
  pr <- lapply(seq_len(npair), function(k) pick(vals[[2L * k - 1L]], vals[[2L * k]]))
  out <- list(geo_label = pr[[1L]]$en, geo_label_fr = pr[[1L]]$fr)
  for (i in seq_along(schema)) {
    if (i + 1L > npair) break
    col <- stem_col(schema[i])                       # schema stem -> output column
    if (is.na(col)) next
    out[[col]] <- pr[[i + 1L]]$en
    if (col == "geo_name") out[["geo_name_fr"]] <- pr[[i + 1L]]$fr
  }
  out
}

ivt_f2_geo_schema <- function(raw, tail_bytes = 600000L) {
  # Preferred: follow the file's own metadata directory (a header pointer -> a table
  # of block offsets/lengths) to the *exact* dictionary block, so its start comes
  # from the file rather than a scan. `ivt_f2_geo_dict_block()` confirms the block by
  # its `GEO_NAME_EN` field name, so a directory slot that means something else on a
  # given layout is skipped. Works on the small chunked tables (98-10-0013 / -0478).
  blk <- ivt_f2_geo_dict_block(raw)
  n <- length(raw)
  if (!is.null(blk)) {
    s <- raw_to_latin1(raw[(blk[["off"]] + 1L):min(n, blk[["off"]] + blk[["len"]])])
  } else {
    # Fallback (the big tail-codebook tables, whose dictionary is routed through a
    # deeper pointer chain we do not decode yet): the dictionary sits near the
    # codebook pointer but off-centre (~14 KB before to ~16 KB after), so search a
    # generous window *centred* on it, anchored by the `GEO_NAME_EN` field name --
    # not the old `[cb-8000, EOF]` half-window, which missed a dictionary lying more
    # than 8 KB before the pointer and scanned ~18 MB on the big files.
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
  hit <- which(vapply(markers$name, function(nm) {
    if (is.na(nm)) return(FALSE)
    k <- min(nchar(nm), nchar(geo$name))
    k >= 4L && substr(nm, 1L, k) == substr(geo$name, 1L, k)
  }, logical(1)))
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
# geographies in 98-10-0241). Prefers the schema-driven, content-free path
# (`ivt_f2_geo_simple_schema()`); falls back to the content-based array detector
# (`ivt_geo_arrays()`) for layouts without the marker/schema. Returns NULL when no
# single length-`n_geo` name block exists -- the large family-2 tables (tens of
# thousands of geographies) store the attributes attribute-major in 256-member
# chunks, so their names need the slower `ivt_f2_geo_attributes()` path (via
# read_ivt(geo_attributes = TRUE)) instead.
ivt_f2_geo_simple <- function(raw, n_geo, tail_bytes = 200000L) {
  if (is.na(n_geo) || n_geo < 1L) return(NULL)
  start <- max(0L, length(raw) - tail_bytes)
  blocks <- ivt_find_member_blocks(raw, start, min_records = 3L)
  if (!length(blocks)) return(NULL)
  sd <- ivt_f2_geo_simple_schema(raw, n_geo, blocks, start)
  if (!is.null(sd)) return(sd)
  ga <- ivt_geo_arrays(blocks, n_geo)
  if (is.null(ga$names)) return(NULL)
  ivt_fallback(paste(
    "Geography names were located by content (clean length-{n_geo} member",
    "blocks in the codebook tail), not read positionally from a directory or",
    "schema."))
  list(name = ga$names$texts,
       dguid = if (!is.null(ga$dguids)) ga$dguids$texts else NULL)
}

# Light geography labels (name + uid) for the metadata path, family-agnostic and
# located from the metadata, not the content. Layouts, in priority order:
#   1. the inline "name (code) flag" codebook -> the pre-DGUID tables (1991, 2006,
#      2011, 2016); positional from the dim-1 block directory, else marker-anchored;
#      bilingual names + character GEOUIDs;
#   2. single-chunk schema'd tables (98-10-0241/0077) -> the directory-driven
#      positional attribute read (`ivt_f2_geo_attrs_dir()`, untrimmed), with the
#      single-block schema/content readers (`ivt_f2_geo_simple()`) as fallback;
#      names + DGUIDs;
#   3. the fast DGUID scan -> the large chunked modern tables (98-10-0023/0129):
#      uid only (names need the slower read_ivt(geo_attributes = TRUE) path).
# Returns list(geo_name, geo_uid) where either element may be NULL.
ivt_f2_geo_light <- function(raw, n_geo) {
  # 2. the marker-anchored combined-block parser is tried before the content-based
  #    single-block detector: it returns NULL for the schema'd DGUID tables (no
  #    combined block), so they fall through to the schema/content path below, but
  #    it wins for the schema-absent tables (1991/2006/2011/2016) -- including the
  #    single-block 2016 case whose uid the content detector cannot recover (no
  #    DGUID array; the uid is the bare code inside the combined block).
  inl <- ivt_f2_geo_inline(raw)
  if (!is.null(inl) && (is.na(n_geo) || nrow(inl) == n_geo))
    return(list(geo_name = inl$geo_name, geo_uid = inl$geouid))
  # 1. single-chunk schema'd tables (98-10-0241/0077/0662): the directory-driven
  #    positional attribute read is cheap here (one group of one chunk) and fully
  #    metadata-addressed; trim = FALSE keeps the hierarchy indentation the
  #    single-block reader preserves. GEO_NAME can carry legitimate NA holes
  #    (98-10-0662's derived aggregate member has no attributes at all) -- label
  #    by the display Member Name then, which every member carries. Larger tables
  #    skip this (the full read costs ~20 s on a 63k-geography codebook; the DGUID
  #    scan below is 3x faster).
  if (!is.na(n_geo) && n_geo <= 256L) {
    at <- ivt_f2_geo_attrs_dir(raw, trim = FALSE)
    if (!is.null(at) && nrow(at) == n_geo) {
      nm <- if (!anyNA(at$geo_name)) at$geo_name else at$geo_label
      if (!anyNA(nm)) return(list(geo_name = nm, geo_uid = at$dguid))
    }
  }
  # 1b. schema-named single block (2021 DGUID) or the content-based array detector
  simple <- ivt_f2_geo_simple(raw, n_geo)
  if (!is.null(simple)) {
    geo_uid <- if (length(simple$dguid) == n_geo) simple$dguid
               else ivt_f2_geo_dguids(raw)
    return(list(geo_name = simple$name, geo_uid = geo_uid))
  }
  # 4. chunked DGUID tables (0023/0129): uid only via the fast DGUID scan
  list(geo_name = NULL, geo_uid = ivt_f2_geo_dguids(raw))
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

# Clean attribute blocks from the codebook tail: member arrays only — drop the
# tiny garbage byte-runs the block scanner picks up and the consecutive-integer
# member-ordinal delimiter blocks, both of which would shift positional indexing.
#
# The full 256-member chunks are always kept. A chunk group's LAST chunk is a
# partial (`n_geo mod 256` members) and can fall below any fixed size floor — e.g.
# 98-10-0013's last group ends in a 71-member partial, so the old blunt
# `length(t) >= 150` floor silently dropped the trailing DGUID/name/code partials
# and undercounted that group (5,376 of 5,447 geographies). Instead of a magic
# size, a partial is recognised *structurally*: a small but clean member-array
# block (no control bytes, no single repeated byte, low fraction / not an ordinal
# delimiter) that **immediately follows a full member block** — i.e. it trails its
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
  is_clean <- function(t) mean(grepl("[½¾¼÷×Þþ{}]", t)) < 0.3 && !is_ord(t)
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
# schema's GEO_NAME (the short geographic name, which for code-only geographies —
# census tracts, unnamed dissemination areas — is the bare code "9320001.00").
# Each is stored as a pair of same-attribute block runs, one per language; the two
# language runs are laid down back to back (G blocks each). We recover both, in
# English and French.
#
# Anchoring is drop-tolerant. The trailing *partial* chunk of a code-valued run
# (GEO_NAME on a census-tract table) is sometimes lost to the block scanner
# (special bytes after the last short block), which would shift a fixed offset. So
# we anchor on GEO_TYPE_DESC's first block (`type0 = d0 - (dguid_slot-1)*2G`) —
# reliable because every attribute from GEO_TYPE_DESC through DGUID is full text/
# code that keeps its partial — and walk BACKWARD through GEO_NAME (2 runs) then
# the display pair (2 runs), inspecting each code run's last-block length to detect
# a dropped partial. The two text display runs are always full.
IVT_F2_FR_TOK <- paste0("(^|[ '-])(et|de|des|du|de-la|la|le|les|aux?|sur|sous|",
                        "ouest|est|nord|sud|sainte?|île|rivière|lac|baie)([ '-]|$)")
IVT_F2_EN_TOK <- paste0("(^|[ '-])(and|of|west|east|north|south|saint|island|",
                        "river|lake|bay)([ '-]|$)")
IVT_F2_ACCENT <- "[^àâäçéèêëîïôöùûüÀÂÄÇÉÈÊËÎÏÔÖÙÛÜœ]"

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
    d <- which(!is.na(r$da) & !is.na(r$db) & r$da != r$db)
    a_en <- ivt_f2_frscore(r$da[d]) <= ivt_f2_frscore(r$db[d])
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
# order with its exact offset and length. There are no `d0 ± k*2G` strides, no
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
  d <- ivt_f2_geo_block_dir(raw); if (is.null(d)) return(NULL)
  schema <- ivt_f2_geo_schema(raw); if (is.null(schema) || !length(schema)) return(NULL)
  n_geo <- ivt_f2_geo_count(raw); if (is.na(n_geo) || n_geo < 1L) return(NULL)
  # value blocks in directory (logical) order, ordinal- and framing-filtered. The
  # run-scanner CLASSIFIES the entries (so the gate below sees the same block set
  # as always); the strict header-driven parse then supplies the VALUES where it
  # applies, preserving explicit empty records as NA holes (absent members, e.g.
  # 98-10-0662's aggregate member 26) and flagging bit-headed dense arrays, both of
  # which the run-scanner silently fragments or packs.
  vb <- vector("list", nrow(d)); k <- 0L
  for (r in seq_len(nrow(d))) {
    t <- ivt_f2_dir_entry_records(raw, d[r, "off"], d[r, "len"])
    if (length(t) >= 3L && !ivt_f2_is_ordinal(t)) {
      e <- ivt_f2_dir_entry_members(raw, d[r, "off"], d[r, "len"])
      if (is.null(e)) e <- list(values = t, dense = FALSE, strict = FALSE)
      else e$strict <- TRUE
      if (trim) e$values <- trimws(e$values)
      k <- k + 1L; vb[[k]] <- e
    }
  }
  length(vb) <- k
  sizes <- ivt_f2_geo_group_sizes(n_geo)
  nattr <- length(schema) + 1L                       # display Member Name + schema fields
  if (k != 2L * nattr * sum(sizes)) return(NULL)     # irregular layout -> fall back
  starts <- cumsum(c(1L, head(sizes, -1L) * 256L))   # member start per group
  stem_col <- function(stem) {
    hit <- which(startsWith(stem, IVT_F2_ATTR_FIELD) | startsWith(IVT_F2_ATTR_FIELD, stem))
    if (length(hit)) names(IVT_F2_ATTR_FIELD)[hit[1L]] else NA_character_
  }
  cols <- c("geo_label", "geo_label_fr", "geo_name", "geo_name_fr", "dguid",
            "geo_level", "geo_type", "geo_type_abbr", "prov_abbr", "alt_geo_code",
            "pr_code", "dqf_code", "dqf_note", "dqf_note_strict", "tnr_short_form")
  out <- setNames(rep(list(rep(NA_character_, n_geo)), length(cols)), cols)
  pos <- 1L
  for (gi in seq_along(sizes)) {
    G <- sizes[gi]; s <- starts[gi]
    M <- min(G * 256L, n_geo - s + 1L)
    chunk_sz <- pmin(256L, M - 256L * (seq_len(G) - 1L))
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
      col <- if (a == 1L) "geo_label" else stem_col(schema[a - 1L])
      if (is.na(col)) next                            # unmapped field (e.g. TNR_LONG_FORM)
      dd <- which(!is.na(va) & !is.na(vbv) & va != vbv)
      a_en <- ivt_f2_frscore(va[dd]) <= ivt_f2_frscore(vbv[dd])
      en <- if (a_en) va else vbv; fr <- if (a_en) vbv else va
      idx <- s:(s + M - 1L)
      out[[col]][idx] <- en
      if (a == 1L) out[["geo_label_fr"]][idx] <- fr
      if (col == "geo_name") out[["geo_name_fr"]][idx] <- fr
      if (col == "dqf_note")                          # per-slot provenance (see below)
        out[["dqf_note_strict"]][idx] <- place(if (a_en) pa else pb, strict_only = TRUE)
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
#' Name) and `geo_label_fr`, `geo_name` (the schema GEO_NAME — a bare code for
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
# <type_abbr> is a short geography-type abbreviation ("T", the accented "MÉ", ...),
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
IVT_HDR_DESCRIPTOR_PTR <- 32L   # u32 → dimension descriptor block
IVT_HDR_TITLE_FR_PTR   <- 40L   # u32 → French title (0 in the modern inline format)
IVT_HDR_TITLE_EN_PTR   <- 48L   # u32 → English title (0 in the modern inline format)
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
# "MÉ"; and an optional trailing parenthesised group carries the non-response rate
# that the 2016 single-census-year tables append (e.g. "Canada (01) 20000 ( 4.0%)").
IVT_F2_INLINE_PAT <- paste0(
  "^(.*) \\(([0-9A-Za-z.]+)\\)\\s+(?:[^0-9\\s]\\S*\\s+)?([0-9]+)",
  "(?:\\s*\\([^)]*\\))?\\s*$")

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
  geo <- ivt_f2_geo_dim(d$dims)
  if (is.null(geo) || is.null(geo$name) || is.na(geo$name)) return(NULL)
  is_geo_mk <- function(nm) {
    if (is.na(nm)) return(FALSE)
    k <- min(nchar(nm), nchar(geo$name))
    k >= 4L && substr(nm, 1L, k) == substr(geo$name, 1L, k)
  }
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
ivt_f2_geo_inline_dir <- function(raw) {
  if (!is.null(ivt_f2_geo_schema(raw))) return(NULL)   # modern layout: not inline
  d <- ivt_f2_dim_dir(raw, 1L)
  if (is.null(d)) return(NULL)
  n_geo <- ivt_f2_geo_count(raw)
  if (is.na(n_geo) || n_geo < 1L) return(NULL)
  sizes <- ivt_f2_geo_group_sizes(n_geo)
  total <- sum(sizes)
  # chunk value blocks in directory (logical) order; classification by the
  # run-scanner, values strict-first (see ivt_f2_dir_entry_members). Dense values
  # are usable as-is: if a dense block skipped absent members its record count
  # misses the chunk size below and we fall back.
  vb <- vector("list", nrow(d)); k <- 0L
  for (r in seq_len(nrow(d))) {
    t <- ivt_f2_dir_entry_records(raw, d[r, "off"], d[r, "len"])
    if (length(t) >= 3L && length(t) <= 256L && !ivt_f2_is_ordinal(t)) {
      e <- ivt_f2_dir_entry_members(raw, d[r, "off"], d[r, "len"])
      k <- k + 1L
      vb[[k]] <- if (is.null(e)) t else e$values
    }
  }
  length(vb) <- k
  chunk_of <- function(gi) {                           # expected sizes of group gi's chunks
    first <- sum(sizes[seq_len(gi - 1L)])              # global chunk index of chunk 1 - 1
    vapply(seq_len(sizes[gi]), function(j)
      min(256L, n_geo - (first + j - 1L) * 256L), 1L)
  }
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
  walk <- function(R) {
    if (k < R * total) return(NULL)
    runs <- rep(list(character(0)), R)
    pos <- 1L
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
    runs <- walk(R)
    if (!is.null(runs)) break
  }
  if (is.null(runs)) return(NULL)
  # run roles by content: the combined runs parse as "name (code) flag"
  prate <- vapply(runs, function(v) {
    nn <- v[!is.na(v)]
    if (!length(nn)) 0 else mean(grepl(IVT_F2_INLINE_PAT, nn))
  }, 0)
  cmb <- which(prate >= 0.8)
  if (!length(cmb)) return(NULL)
  # English combined run by frscore over the members where the two copies differ
  comb <- if (length(cmb) == 1L) runs[[cmb[1L]]] else {
    a <- runs[[cmb[1L]]]; b <- runs[[cmb[2L]]]
    dd <- which(!is.na(a) & !is.na(b) & a != b)
    if (ivt_f2_frscore(a[dd]) <= ivt_f2_frscore(b[dd])) a else b
  }
  m <- regmatches(comb, regexec(IVT_F2_INLINE_PAT, comb))
  okm <- vapply(m, function(gg) length(gg) >= 4L, logical(1))
  nm <- fl <- rep(NA_character_, n_geo); cd <- nm
  nm[okm] <- vapply(m[okm], `[`, "", 2L)
  cd[okm] <- vapply(m[okm], `[`, "", 3L)
  fl[okm] <- vapply(m[okm], `[`, "", 4L)
  # a positional code array (a non-combined run equal to the parsed codes) is
  # preferred as the uid -- it also cross-validates the run alignment
  codes <- cd
  for (rr in setdiff(seq_along(runs), cmb)) {
    v <- trimws(runs[[rr]])
    ok <- okm & !is.na(v)
    if (sum(ok) && all(v[ok] == cd[ok])) { codes <- v; break }
  }
  g <- tibble::tibble(member_id = seq_len(n_geo), geo_name = trimws(nm),
                      geouid = codes, dqf_code = fl)
  ivt_f2_check_geo_count(raw, nrow(g))
  g
}

#' Geography table for an inline-codebook (pre-DGUID) family-2 IVT.
#'
#' Returns a tibble with one row per geography (member order) and columns
#' `geo_name` (often a bilingual "EN | FR" label), `geouid` (bare geographic code,
#' character) and `dqf_code` (data-quality flag). Primary read: positionally from
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
  g <- ivt_f2_geo_inline_dir(raw)
  if (!is.null(g)) return(g)
  region <- ivt_f2_geo_marker_region(raw)
  if (is.null(region)) return(NULL)
  blocks <- ivt_find_member_blocks(raw, max(0L, region[1] - 50L), min_records = 3L)
  blocks <- Filter(function(b) b$start >= region[1] && b$start < region[2], blocks)
  blocks <- blocks[order(vapply(blocks, function(b) b$start, 1))]
  pat <- IVT_F2_INLINE_PAT
  is_inline <- vapply(blocks, function(b)
    length(b$texts) >= 16L && mean(grepl(pat, b$texts)) > 0.8, logical(1))
  seen <- new.env(hash = TRUE, parent = emptyenv())
  nm <- character(0); cd <- character(0); fl <- character(0)
  for (b in blocks[is_inline]) {
    m <- regmatches(b$texts, regexec(pat, b$texts))
    for (gg in m) {
      if (length(gg) < 4L) next
      code <- gg[3]
      if (!is.null(seen[[code]])) next
      seen[[code]] <- TRUE
      nm <- c(nm, gg[2]); cd <- c(cd, code); fl <- c(fl, gg[4])
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
  g <- tibble::tibble(member_id = seq_along(cd), geo_name = trimws(nm),
                      geouid = cd, dqf_code = fl)
  ivt_f2_check_geo_count(raw, nrow(g))
  g
}

# Validate a decoded geography count against the header's declared count. The
# header dimension descriptor states the geography member count explicitly
# (`ivt_f2_header_geo_count()`), so we never have to trust the parser's own tally:
# a mismatch means the codebook stitch dropped or duplicated a chunk.
ivt_f2_check_geo_count <- function(raw, got) {
  want <- ivt_f2_geo_count(raw)
  if (!is.na(want) && !is.na(got) && got != want) {
    cli::cli_warn(c(
      "Decoded {got} geographies but the header declares {want}.",
      i = "The geography codebook stitch may have dropped or duplicated a chunk."
    ))
  }
  invisible(want)
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
#' @keywords internal
#' @noRd
ivt_f2_geographies <- function(raw) {
  g <- ivt_f2_geo_inline(raw)
  if (!is.null(g)) {
    names(g)[names(g) == "geouid"] <- "geo_uid"
  } else {
    g <- ivt_f2_geo_attributes(raw)
    names(g)[names(g) == "dguid"] <- "geo_uid"
  }
  front <- intersect(c("member_id", "geo_label", "geo_name", "geo_uid"), names(g))
  g[, c(front, setdiff(names(g), front))]
}

# --- Header dimension descriptor ----------------------------------------------
#
# The fixed header field @32 (u32) points at a descriptor block that explicitly
# declares the table's dimensions — present in BOTH the modern and legacy formats,
# so it is the reliable source of dimension metadata (the legacy format has no
# inline "Variable List" text). Layout of the descriptor:
#   +16 u16  number of dimensions
#   +52      first dimension record, then one record per dimension. Each record
#            stores its display name TWICE back-to-back ("GeographyGeography"),
#            preceded by a 0x01 separator; this **doubled name** is the reliable
#            anchor. The count/type framing bytes immediately before the separator
#            vary by dimension, so we read them relative to the doubled name rather
#            than scanning for a fixed "<type> 01" marker:
#            • normal record  `[count][type][01]<name><name>`  (type @ sep-1,
#              count @ sep-2; geography type 0x10 carries a u16 count at sep-3..-2,
#              member counts > 255)
#            • period / facet record  `[type][count][01][01]<name><name>` — the
#              reference-period dimension (type 0x0e, e.g. "Year (2)" in tables
#              spanning two censuses) is type-first with a doubled 0x01, which is
#              exactly why a rigid "<known type> 01 <upper>" scan silently dropped
#              it (and the table's 7th dimension with it).
#            • <type> is a storage/classification tag, NOT a fixed dimension
#              identity: 0x10/0x08 geography, 0x07 age-type, 0x02 gender/sex-type
#              or a small categorical, 0x03/0x04/0x05 generic ordinal/categorical,
#              0x0e reference period. (In 98-10-0241 type 0x02 is "Statistics".)
#   later    "FACET04" + the English title (the legacy file appends "1991 Census…")
# Validated: dims recovered exact on 98-10-0023 (63404/128/3), 1003011
# (41859/110/3), 98-10-0241 (166 + 6 data dims) and 98-10-0077 (174 + 6 data dims
# incl. the "Year (2)" reference period).

#' Parse the header dimension descriptor.
#' @return list(n_dim, dims = list(name, count, type), title) or NULL.
#' @keywords internal
#' @noRd
ivt_f2_descriptor <- function(raw) {
  n <- length(raw)
  D <- rd_u32(raw, IVT_HDR_DESCRIPTOR_PTR)
  if (is.na(D) || D < 1 || D + 18 > n) return(NULL)
  D <- as.integer(D)
  ndim <- rd_u16(raw, D + 16L)
  win <- min(D + 4000L, n)
  v <- as.integer(raw[(D + 1L):win])               # v[k] is byte D+k-1
  # the dimension records sit between the fixed header and the "FACET04" title;
  # bound the search there so stray 0x01 bytes in later binary do not match.
  txt <- intToUtf8(ifelse(v >= 32L & v <= 126L, v, 46L))
  facet <- regexpr("FACET04", txt)
  Lend <- if (facet > 0) facet - 1L else length(v)

  # Walk the bounded region; a dimension record is a 0x01 whose following printable
  # run is a doubled string (the first copy may be truncated -- the longest
  # matching prefix wins). Read count/type from the bytes just before the 0x01.
  # The name may start with an uppercase letter OR a digit ("1995 Household
  # Income (3)" in the 1996 table 95F0250XDB96001 -- the uppercase-only anchor
  # silently dropped that dimension, and the 2-dimension layout then decoded
  # misindexed cells that even passed the page pre-flight).
  dims <- list()
  k <- 4L
  while (k <= Lend - 1L && length(dims) < ndim) {
    if (v[k] == 0x01L &&
        ((v[k + 1L] >= 65L && v[k + 1L] <= 90L) ||
         (v[k + 1L] >= 48L && v[k + 1L] <= 57L))) {
      e <- k + 1L
      while (e <= length(v) && v[e] >= 32L && v[e] <= 126L) e <- e + 1L
      run <- v[(k + 1L):(e - 1L)]; rl <- length(run); half <- NA_integer_
      for (p in seq.int(rl %/% 2L, 1L)) {
        if (identical(run[1:p], run[(p + 1L):(2L * p)])) { half <- p; break }
      }
      if (!is.na(half) && half >= 2L) {
        if (v[k - 1L] == 0x01L) {                  # period/facet double-01 framing
          type <- v[k - 3L]; count <- v[k - 2L]
        } else {
          type <- v[k - 1L]
          # the geography descriptor stores its (large) member count as a 16-bit
          # little-endian value; the type byte tags the storage width: 0x10 (modern
          # DGUID geography, e.g. 63404 in 98-10-0023; 57523 in the 2006 DA table)
          # and 0x0d (the 2011 census-tract geography, 5447) carry a u16, whereas
          # the small family-1 geography (type 0x08, <=255) and the data dimensions
          # carry a u8. Reading 0x0d as u8 misread 2011's 5447 geographies as 21.
          count <- if (type %in% c(0x10L, 0x0dL)) v[k - 3L] + v[k - 2L] * 256L
                   else v[k - 2L]
        }
        dims[[length(dims) + 1L]] <- list(name = trimws(intToUtf8(run[1:half])),
                                          count = count, type = type)
        k <- e; next
      }
    }
    k <- k + 1L
  }

  title <- regmatches(txt, regexpr("FACET04[^.]*", txt))
  title <- if (length(title)) trimws(sub("FACET04", "", title)) else NA_character_
  list(n_dim = ndim, dims = dims, title = title)
}

# Geography is the first descriptor dimension (the page/row dimension) in every
# observed layout. Identify it positionally, NOT by a magic type byte: the
# geography descriptor *type* varies by format — 0x10 in the modern 2021 family-2
# files (count stored as u16) but 0x08 in the family-1 reference table (count u8) —
# so a `type == 0x10` filter silently fails on other layouts (it falls through to
# the wrong fixed-offset count, e.g. 16383 for 98-10-0241). The count's byte width
# is still handled by `ivt_f2_descriptor()`.
ivt_f2_geo_dim <- function(dims) if (length(dims)) dims[[1L]] else NULL

# Geography member count, from the descriptor's geography record. Reliable for any
# dimensionality; the fixed-offset u16 `ivt_f2_header_geo_count()` is only correct
# for 3-dimension tables (it reads 16320 instead of 63404 for the 4-dimension
# 98-10-0129). Falls back to the fixed-offset reader when the descriptor cannot be
# parsed.
ivt_f2_geo_count <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  geo <- ivt_f2_geo_dim(if (is.null(d)) NULL else d$dims)
  if (is.null(geo)) return(ivt_f2_header_geo_count(raw))
  as.integer(geo$count)
}

# The non-geography data dimensions, in descriptor (outer -> inner) order: their
# member `counts` (which drive the presence-bitmap nesting and the dense value
# order) and a short column `slug` for each. Geography is the first dimension
# (`ivt_f2_geo_dim()`, identified positionally), so the data dimensions are simply
# the rest. Slugs are a purely structural convenience: each is the lower-cased
# leading word of the dimension's metadata name (e.g. "Marital status" ->
# "marital"), falling back to "dim<i>", made unique. No code branches on a
# dimension's name or descriptor type byte -- dimensions are interchangeable and
# everything the decoder needs (geography position, member counts, value layout)
# is derived structurally. The human-readable labels come from the codebook at
# `tidy` time. Returns empty vectors when no descriptor / no data dimensions.
ivt_f2_data_dims <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || length(d$dims) < 2L) return(list(counts = integer(0), slugs = character(0)))
  data <- d$dims[-1L]
  if (!length(data)) return(list(counts = integer(0), slugs = character(0)))
  counts <- vapply(data, `[[`, 1L, "count")
  slugs <- vapply(seq_along(data), function(i) ivt_dim_slug(data[[i]]$name, i + 1L), "")
  if (anyDuplicated(slugs)) slugs <- make.unique(slugs, sep = "")
  list(counts = as.integer(counts), slugs = slugs)
}

# Generic, name-agnostic column slug for a dimension at 1-based descriptor position
# `i`: dimension 1 is geography (the structural outermost dimension) -> "geo"; any
# other dimension takes the lower-cased leading alphabetic word of its metadata
# name, or "dim<i>" when that is not a clean word. This is presentation only -- no
# decoder logic depends on the result.
ivt_dim_slug <- function(name, i) {
  if (i == 1L) return("geo")
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
