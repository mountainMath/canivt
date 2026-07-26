#' Read a family-2 Beyond 20/20 IVT file
#'
#' The second container family (single contiguous page directory; e.g. the 2021
#' table 98-10-0023, Age x Gender across Canada down to dissemination areas).
#' This reader decodes every cell exactly (validated cell-for-cell against the
#' StatCan CSV for all 63,404 geographies of 98-10-0023) and attaches the table
#' identity, dimension names, geography DGUIDs and the data-dimension member
#' labels from the codebook (~18 MB from EOF). Geography *names* are not yet
#' decoded for this family, so [ivt_tidy()] labels geography by its DGUID (the
#' canonical StatCan geography key) and labels Age/Gender by their member names.
#'
#' @keywords internal
#' @noRd
NULL

# Parse the header "Variable List" into (name, count) pairs (modern format only;
# the legacy format has none). The Variable List is in DISPLAY order, which need
# not match the descriptor's storage order (in 98-10-0241 they differ), so it is
# matched to descriptor dimensions by count, not position. Names can themselves
# contain commas (e.g. "Age (in single years), average age and median age (128)"),
# but each entry ends in a "(<count>[<flags>])" hint (e.g. "(13)", "(3C)"), so we
# split only after those hints and read the count from each. Returns a data frame
# (name, count) or NULL when there is no inline Variable List.
ivt_f2_vl_pairs <- function(raw) {
  head <- ivt_header_text(raw)
  m <- regmatches(head, regexec("Variable List:?[ \t]*([^\r\n]+)", head))[[1]]
  if (length(m) < 2L) return(NULL)
  marked <- gsub("(\\([0-9]+[A-Za-z]*\\))[ \t]*,[ \t]*", "\\1@@DIM@@", m[2])
  parts <- trimws(strsplit(marked, "@@DIM@@", fixed = TRUE)[[1]])
  parts <- parts[nzchar(parts)]
  if (!length(parts)) return(NULL)
  count <- suppressWarnings(as.integer(
    sub(".*\\(([0-9]+)[A-Za-z]*\\)[ \t]*$", "\\1", parts)))
  name <- trimws(sub("[ \t]*\\([0-9]+[A-Za-z]*\\)[ \t]*$", "", parts))
  data.frame(name = name, count = count, stringsAsFactors = FALSE)
}

# The plaintext "Variables:" enumeration block that the custom-order exports
# (ord-08035) carry INSTEAD of a binary `81 02 02 00` member codebook. Member
# labels are a numbered text list per dimension:
#
#   Variables:
#
#   Tenure (4)
#   1. Total - Tenure
#   2. Owner
#   ...
#   Note: 1) Tenure refers to ...       <- interspersed footnote paragraphs
#
#   Selected characteristics (76)
#   1. Total - Gender of the population
#   ...
#
# Returns a list of list(name, count, labels) -- one per dimension whose member
# numbers run 1..k contiguously (spurious "(N)"-ending prose lines are rejected
# by that gate) -- or NULL when there is no such block. This is a text heuristic
# and only ever consulted as the last member-label fallback (a dimension whose
# binary codebook resolves never reaches it), so it does not touch the standard
# tables (which carry a "Variable List:" name line, not a "Variables:" list).
ivt_f2_varlist_members <- function(raw) {
  n <- length(raw)
  txt <- raw_to_latin1(raw[seq_len(min(n, 65536L))])
  m <- regexpr("\r\nVariables:\r\n", txt, fixed = TRUE)
  if (m < 0L) return(NULL)
  lines <- strsplit(substring(txt, m + attr(m, "match.length")), "\r\n", fixed = TRUE)[[1]]
  hdr_re <- "^(.+) \\(([0-9]+)[A-Za-z]?\\)$"
  mem_re <- "^([0-9]+)\\.[ \t]+(.*)$"
  out <- list(); cur <- NULL
  flush <- function() {
    if (!is.null(cur) && length(cur$labels) &&
        identical(cur$ids, seq_along(cur$ids)))            # members run 1..k
      out[[length(out) + 1L]] <<- cur[c("name", "count", "labels")]
  }
  for (ln in lines) {
    mm <- regmatches(ln, regexec(mem_re, ln))[[1]]
    if (length(mm) == 3L && !is.null(cur)) {               # "N. label"
      cur$ids <- c(cur$ids, as.integer(mm[2]))
      cur$labels <- c(cur$labels, trimws(mm[3]))
      next
    }
    hm <- regmatches(ln, regexec(hdr_re, ln))[[1]]
    if (length(hm) == 3L) {                                # "<Name> (<count>)"
      flush()
      cur <- list(name = trimws(hm[2]), count = as.integer(hm[3]),
                  labels = character(0), ids = integer(0))
    }
  }
  flush()
  if (length(out)) out else NULL
}

# Best VL member-label match for a descriptor dimension: an entry with the same
# member count, else the one sharing the most significant (>3-char) name tokens
# (display names differ from the descriptor's -- "Selected characteristics" vs
# "Characteristics"). Labels are padded/truncated to the descriptor count (the VL
# can under-list, e.g. ord-08035 enumerates 76 of 79 characteristics). NULL when
# nothing matches.
ivt_f2_varlist_match <- function(vlm, dim) {
  if (is.null(vlm)) return(NULL)
  norm_tok <- function(s) {
    t <- strsplit(tolower(gsub("[^A-Za-z ]", " ", s)), " +")[[1]]
    t[nchar(t) > 3L]
  }
  dtok <- norm_tok(dim$name)
  score <- vapply(vlm, function(e)
    2L * length(intersect(dtok, norm_tok(e$name))) + (e$count == dim$count),
    integer(1))
  if (max(score) <= 0L) return(NULL)
  labs <- vlm[[which.max(score)]]$labels
  length(labs) <- dim$count
  labs
}

# Full display name for a descriptor dimension. Geography is always "Geography";
# every other dimension takes the Variable-List entry whose count uniquely matches
# (the VL is the only source of the untruncated name), falling back to the
# descriptor's own (possibly truncated) display name when there is no inline VL or
# the count match is ambiguous.
ivt_f2_dim_name <- function(dim, is_geo, vl) {
  if (is_geo) return("Geography")
  if (!is.null(vl)) {
    hit <- which(vl$count == dim$count)
    if (length(hit) == 1L) return(vl$name[hit])
  }
  dim$name
}

# Uniform dimension model, driven by the header descriptor (present in BOTH
# formats). Every dimension is described the same way: `name`, `count`, `type`
# (0x07 age-type, 0x02 gender/sex-type; geography is the first dimension,
# identified positionally rather than by type byte), `is_geography`, and, for
# the non-geography data dimensions, the decoded member `members` (labels). The
# member labels are attached by matching the descriptor's member count to the
# label blocks (`ivt_f2_dim_member_labels()`), so 98-10-0241's six data dimensions,
# Age/Gender (2021) and Age/Sex (1991) are handled identically. Full dimension
# names come from the Variable List (by count) when present, otherwise the
# descriptor's (truncated) display name. Data dimensions additionally carry
# `ordinal` (the codebook member-ordinal block, when the slot directory stores
# one) so member order is available for factor levels (`ivt_members()`), and the
# FRENCH copies `members_fr` (the Desc Francais label block) + `name_fr` (the
# French dimension name, from the French "Total - ..." member) -- both read
# through the slot directory's dictionary-schema order, NULL/NA when only the
# English-only scan fallbacks resolve.
ivt_f2_dimensions <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(list())
  gd <- ivt_f2_geo_dim_index(raw, d)
  # primary: read each dimension's label pair positionally from its header slot
  # directory (dimdir.R) -- keyed by dimension INDEX, so same-name and same-count
  # dimensions cannot collide, and no tail-window scan is needed.
  dirlab <- ivt_f2_dim_dir_labels(raw)
  # the member-ordinal blocks (dimdir.R): the codebook's stored member order,
  # kept on each dimension so factor levels can honour it (collect_ivt()). A
  # dimension without an ordinal block (NULL) is ordered by member id.
  dirord <- ivt_f2_dim_dir_ordinals(raw)
  # scan fallbacks, computed only for dimensions the slot directories miss: the
  # name-anchored marker labels (so two dimensions of the same member count --
  # e.g. 98-10-0662's 6-member "French used at work" / "English used at work" --
  # get their own labels rather than collapsing onto one count key), then the
  # count-keyed block heuristics.
  data_idx <- setdiff(seq_along(d$dims), gd)
  miss <- data_idx[vapply(data_idx, function(i)
    is.null(dirlab) || length(dirlab) < i || is.null(dirlab[[i]]) ||
      is.null(dirlab[[i]]$en),
    logical(1))]
  labels <- list(); name_lut <- list()
  if (length(miss)) {
    miss_names <- vapply(d$dims[miss], `[[`, "", "name")
    ivt_fallback(paste(
      "Member labels for {length(miss_names)} dimension{?s} ({.val {miss_names}})",
      "did not resolve from the header slot directories; falling back to the",
      "codebook marker / count-keyed label scans."))
    want <- vapply(d$dims[data_idx], `[[`, 1L, "count")
    labels <- ivt_f2_dim_member_labels(raw, want = want)      # count-keyed fallback
    by_name <- ivt_f2_marker_labels(raw)
    name_lut <- stats::setNames(lapply(by_name, `[[`, "labels"),
                                vapply(by_name, `[[`, "", "name"))
  }
  # last resort: the plaintext "Variables:" enumeration (custom-order exports have
  # no binary member codebook). Computed only when the binary paths missed a dim.
  vlm <- if (length(miss)) ivt_f2_varlist_members(raw) else NULL
  vl <- ivt_f2_vl_pairs(raw)
  lapply(seq_along(d$dims), function(i) {
    dim <- d$dims[[i]]
    is_geo <- i == gd                       # the geography dimension (dimdir.R)
    dl <- if (!is.null(dirlab) && length(dirlab) >= i) dirlab[[i]] else NULL
    members <- if (is_geo) NULL else {
      m <- dl$en                            # slot-directory English labels (primary)
      if (is.null(m)) m <- name_lut[[dim$name]]
      if (is.null(m)) m <- labels[[as.character(dim$count)]]
      if (is.null(m)) m <- ivt_f2_varlist_match(vlm, dim)  # plaintext Variables:
      m
    }
    # The type-00 sub-A cluster recovers a chunked industry axis the positional
    # readers under-read; its PROVISIONAL member labels (suba.R) are built in the
    # recovered slot-map order, so prefer them whenever they cover the whole axis --
    # this GUARANTEES the labels align with the decoded member ids (the positional
    # reader may order its labels differently from the reconciled slot map).
    suba <- attr(d, "suba", exact = TRUE)   # not the `suba_unverified` flag
    if (!is_geo && !is.null(suba) && !is.null(suba$labels) &&
        length(suba$labels) == dim$count)
      members <- suba$labels
    # French member labels + the French dimension name come from the slot
    # directory's second (Desc Francais) block; the scan fallbacks are English
    # only, so these are NULL/NA on a dimension the directories miss.
    members_fr <- if (is_geo) NULL else dl$fr
    name_fr <- if (is_geo || is.null(dl)) NA_character_ else dl$name_fr
    # `dl$name_fr` already covers both sources: the "Total - <name>" member and,
    # where that is absent (the 02-gen survey facet/quantity dimensions), the
    # doubled-name marker entry read from the dimension's own slot directory
    # (dim-members.R). No whole-file marker scan is needed here.
    ordinal <- if (!is_geo && !is.null(dirord) && length(dirord) >= i)
      dirord[[i]] else NULL
    # per-member `_Description` prose (the indicator definition), when the dimension
    # carries it; NULL/absent otherwise so existing outputs are unchanged.
    description    <- if (is_geo || is.null(dl)) NULL else dl$desc_en
    description_fr <- if (is_geo || is.null(dl)) NULL else dl$desc_fr
    list(name = ivt_f2_dim_name(dim, is_geo, vl), name_fr = name_fr,
         count = dim$count, type = dim$type, is_geography = is_geo,
         members = members, members_fr = members_fr, ordinal = ordinal,
         description = description, description_fr = description_fr)
  })
}

ivt_f2_dimension_names <- function(raw) {
  dims <- ivt_f2_dimensions(raw)
  if (length(dims)) vapply(dims, `[[`, "", "name") else "Geography"
}

# Table identity for the legacy format, read from the out-of-line title blocks
# that header u32 @48/@40 point at (framing `01 01 <u16 len>` then
# "<product_id>\r\n<title>"). The modern format keeps this inline (ivt_table_info).
# The two pointers are NOT fixed language slots: 1003011 and 95F0170X store the
# English blob at @48, but 98F0172X stores the French one there -- so the
# language is assigned per pair by content (`ivt_f2_frscore()` on the titles,
# the same pick `ivt_f2_master_identity()` uses).
ivt_f2_legacy_identity <- function(raw) {
  rd <- function(ptr) {
    off <- rd_u32(raw, ptr)
    if (is.na(off) || off < 1 || off + 4 > length(raw)) return(NA_character_)
    len <- rd_u16(raw, as.integer(off) + 2L)
    if (len < 1L || off + 4L + len > length(raw)) return(NA_character_)
    raw_to_latin1(raw[(as.integer(off) + 5L):(as.integer(off) + 4L + len)])
  }
  split2 <- function(t) {
    if (is.na(t)) return(c(NA_character_, NA_character_))
    p <- strsplit(t, "\r\n", fixed = TRUE)[[1]]
    c(if (length(p) >= 1) trimws(p[1]) else NA_character_,
      if (length(p) >= 2) trimws(p[2]) else NA_character_)
  }
  e <- split2(rd(IVT_HDR_TITLE_EN_PTR)); f <- split2(rd(IVT_HDR_TITLE_FR_PTR))
  if (!ivt_f2_pick_en(e[2], f[2])$en_first) {          # NA / equal titles: no swap
    tmp <- e; e <- f; f <- tmp
  }
  list(product_id = e[1], title_en = e[2], title_fr = f[2], universe = NA_character_)
}

# Identity read from the MASTER directory (dimdir.R) when neither the inline
# "Product ID:" text (modern tables) nor the out-of-line `@40`/`@48` title blocks
# (legacy exports) exist: the 1981 profile vintage zeroes both header pointers
# but stores the same `01 01 <u16 len>`-framed "<product_id>\r\n<title>" blobs
# as master-directory entries (EN and FR -- entries 4 and 11 on
# 97-570-X1981004). Candidates are the multi-line framed text entries whose
# first line is short (the product id); EN vs FR by `ivt_f2_frscore()` on the
# title line. Returns the `ivt_f2_legacy_identity()` shape, or NULL when the
# master directory is absent or lists no identity blob.
ivt_f2_master_identity <- function(raw) {
  md <- ivt_f2_master_dir(raw)
  if (is.null(md)) return(NULL)
  cand <- list()
  for (r in seq_len(nrow(md))) {
    off <- md[r, "off"]; len <- md[r, "len"]
    if (len < 12L || off + 4L > length(raw)) next
    if (as.integer(raw[off + 1L]) != 0x01L ||
        as.integer(raw[off + 2L]) != 0x01L) next
    tl <- rd_u16(raw, off + 2L)
    if (is.na(tl) || tl < 8L || off + 4L + tl > length(raw)) next
    t <- raw_to_latin1(raw[(off + 5L):(off + 4L + tl)])
    p <- trimws(strsplit(t, "\r\n", fixed = TRUE)[[1]])
    p <- p[nzchar(p)]
    if (length(p) < 2L) next
    # Two shapes: the 1981 profile blob is a bare "<product_id>\r\n<title>" (short
    # first line = the id); the `02 00 20 00` survey blob is LABELLED
    # "Title:\r\n<title>\r\nSource:\r\n<source>" -- the "Title:"/"Titre:" line is a
    # label, NOT a product id (there is none), so drop it and keep the next line as
    # the title.
    if (grepl("^(Title|Titre)\\s*:?$", p[1L], ignore.case = TRUE)) {
      cand[[length(cand) + 1L]] <- c(NA_character_, p[2L])
    } else if (nchar(p[1L]) <= 40L) {
      cand[[length(cand) + 1L]] <- c(p[1L], p[2L])
    }
  }
  if (!length(cand)) return(NULL)
  sc <- vapply(cand, function(p) ivt_f2_frscore(p[2]), 0)
  en <- cand[[which.min(sc)]]
  fr <- if (length(cand) > 1L) cand[[which.max(sc)]] else NULL
  list(product_id = en[1], title_en = en[2],
       title_fr = if (!is.null(fr) && !identical(fr, en)) fr[2] else NA_character_,
       universe = NA_character_)
}

# Footnotes for the legacy format. Unlike the modern framed "Footnote N" / "Renvoi
# N" records, the legacy notes block is one text blob (header `01 01 <u16 len>`)
# with sections; the footnotes are "(N) <text>" lines under a "Footnotes" section
# header ("Footnote(s)" on the 1991 profile exports), ending at the next section
# header ("Abbreviations"). The blob is located
# from the MASTER directory (dimdir.R): it is the entry the header EN title
# pointer (`@48`) also addresses, so the parse is bounded to exactly that section;
# the trailing `tail_bytes` window survives as the fallback when the master
# directory does not resolve. Validated against 1003011 (40 footnotes, 1..40).
ivt_f2_legacy_footnotes <- function(raw, tail_bytes = 200000L) {
  span <- NULL
  md <- ivt_f2_master_dir(raw)
  en <- rd_u32(raw, IVT_HDR_TITLE_EN_PTR)
  if (!is.null(md)) {
    if (!is.na(en) && en > 0) {
      r <- which(md[, "off"] == en)
      if (length(r) == 1L)
        span <- c(md[r, "off"] + 1L, min(length(raw), md[r, "off"] + md[r, "len"]))
    }
    if (is.null(span)) {
      # In the legacy layout the `@48` pointer targets the small out-of-line
      # TITLE block, not the notes blob (1003011: en = 1458, no entry matches),
      # so locate the notes entry within the master directory by its
      # "Footnotes" section header, largest entries first (the two big entries
      # are the EN/FR identity/notes blobs). Still directory-bounded: only the
      # directory's own entries are searched, never a raw byte window.
      for (r in order(md[, "len"], decreasing = TRUE)) {
        off <- md[r, "off"]; ln <- md[r, "len"]
        if (ln < 64L || off + ln > length(raw)) next
        txt <- raw_to_latin1(raw[(off + 1L):(off + ln)])
        if (grepl("(^|\r\n)Footnote(s|\\(s\\))\r\n", txt)) { span <- c(off + 1L, off + ln); break }
      }
    }
  }
  fellback <- is.null(span)
  if (is.null(span)) span <- c(max(1L, length(raw) - tail_bytes + 1L), length(raw))
  lines <- strsplit(raw_to_latin1(raw[span[1]:span[2]]), "\r\n", fixed = TRUE)[[1]]
  lines <- trimws(lines)
  # the section header is "Footnotes" on the 1991 crosstab exports (1003011) but
  # "Footnote(s)" on the 1991 profile exports (98F0172X / 95F0170X)
  fh <- which(lines %in% c("Footnotes", "Footnote(s)"))
  if (!length(fh)) return(list())
  out <- list()
  for (i in (fh[length(fh)] + 1L):length(lines)) {
    L <- lines[i]
    if (!nzchar(L)) next
    m <- regmatches(L, regexec("^\\(([0-9]+)\\)\\s*(.*)$", L))[[1]]
    if (length(m) != 3L) break             # reached the next section header
    out[[length(out) + 1L]] <- list(language = "en",
                                    number = as.integer(m[2]), text = trimws(m[3]))
  }
  if (fellback && length(out)) {
    ivt_fallback(paste(
      "The master directory did not resolve the notes blob; the legacy",
      "footnotes were parsed from a trailing {tail_bytes}-byte window."))
  }
  out
}

# The legacy "(N)" footnotes (`ivt_f2_legacy_footnotes()`) are a table-wide numbered
# note list; a member CITES a note by embedding its number as a "(N)" marker in the
# member label (the 1991/2001 profiles: `"1307 Other non-university ... (19) (20)"`
# cites notes 19 and 20; `"2604 Average value of dwelling (26) $"` cites 26 before a
# unit suffix). This parses those references from the member labels of every
# dimension (geography included -- its names come from `geo_names`), returning a
# data frame (dimension, member_id, note). Only numeric parens whose value is a
# valid footnote number (1..n_notes) are references -- so the leading profile line
# number (not parenthesised) and non-numeric parentheticals like
# "(non-institutional)" are ignored, and a modern table (whose data-dim labels carry
# no numeric parens at all) yields nothing. `dims` is the metadata dimension list.
ivt_f2_note_refs <- function(dims, geo_names, n_notes) {
  if (is.na(n_notes) || n_notes < 1L) return(NULL)
  rows <- list()
  for (d in dims) {
    labs <- if (isTRUE(d$is_geography)) geo_names else d$members
    if (!length(labs)) next
    for (mid in seq_along(labs)) {
      L <- labs[[mid]]
      if (is.na(L) || !nzchar(L)) next
      nums <- regmatches(L, gregexpr("\\(([0-9]+)\\)", L))[[1]]
      if (!length(nums)) next
      nums <- as.integer(gsub("[()]", "", nums))
      nums <- unique(nums[!is.na(nums) & nums >= 1L & nums <= n_notes])
      for (nn in nums)
        rows[[length(rows) + 1L]] <- data.frame(dimension = d$name,
                                                member_id = mid, note = nn)
    }
  }
  if (!length(rows)) return(NULL)
  do.call(rbind, rows)
}

# Attach the parsed "(N)" member references to the legacy footnote records: a note
# cited by members becomes scope = "member" (with `dimension`, `member_refs` = the
# cited member ids, and `member_id` when a single member cites it); a note no member
# cites stays scope = "table" (a general table note). Only records still carrying an
# unresolved scope (NA -- the legacy path) are touched, so modern bitmap-attributed
# notes are never overwritten. This is QUIET (not an `ivt_fallback()`): the "(N)"
# marker is the file's OWN footnote-reference notation (the pre-DGUID analogue of the
# modern member bitmap -- Beyond 20/20 renders it as the superscript link), so
# reading it is the PRIMARY linkage read, not a heuristic fallback for a failed
# positional one, and it self-validates (every ref resolves to an existing note
# 1..n_notes) -- exactly like the quiet label-indentation `parent_id`/`depth`
# derivation. Every corpus legacy note cites members of a single dimension; a note
# spanning several dimensions keeps `dimension = NA` (member_refs still lists them).
ivt_f2_attach_legacy_refs <- function(footnotes, dims, geo_names) {
  if (!length(footnotes)) return(footnotes)
  n_notes <- suppressWarnings(max(vapply(footnotes, `[[`, 0L, "number"), na.rm = TRUE))
  refs <- ivt_f2_note_refs(dims, geo_names, n_notes)
  lapply(footnotes, function(f) {
    if (!is.na(f$scope)) return(f)                 # keep already-attributed notes
    r <- if (is.null(refs)) NULL else refs[refs$note == f$number, , drop = FALSE]
    if (is.null(r) || !nrow(r)) { f$scope <- "table"; return(f) }
    dref <- unique(r$dimension)
    f$scope <- "member"
    f$member_refs <- sort(unique(r$member_id))
    f$dimension <- if (length(dref) == 1L) dref else NA_character_
    f$member_id <- if (nrow(r) == 1L) r$member_id[[1]] else NA_integer_
    f
  })
}

# Canonical geography column order, shared by `metadata$geographies` and the
# full attribute table (`ivt_f2_geographies()`): the KEY columns first
# (member_id, display label, schema name, uid -- the documented leading
# schema), then the French copies, then the attribute set. Columns a vintage
# does not store are skipped; decoded columns outside the set (the flow sides
# geo_res_*/geo_work_*, has_data) follow in their own order.
IVT_GEO_COLS <- c("member_id", "geo_label", "geo_name", "geo_uid",
                  "geo_label_fr", "geo_name_fr", "geo_level", "geo_type",
                  "geo_type_abbr", "prov_abbr", "alt_geo_code", "pr_code",
                  "dqf_code", "dqf_note", "dqf_note_truncated", "tnr_short_form")

ivt_geo_col_order <- function(nms)
  c(intersect(IVT_GEO_COLS, nms), setdiff(nms, IVT_GEO_COLS))

# Read the full codebook metadata for ANY supported family. The descriptor-driven
# dimension model and the codebook member/footnote scans are format-agnostic; only
# the geography layout differs, and that is keyed off the header (`inline` for the
# pre-DGUID legacy layout) and the geography codebook's shape:
#   - inline (legacy, e.g. 1991): no DGUID array; key by member id only. Names and
#     GEOUIDs come from read_ivt(geo_attributes = TRUE) via ivt_f2_geographies().
#   - single clean codebook (the small family-1 reference tables, e.g. 166
#     geographies in 98-10-0241): names + DGUIDs are one block each (`geo_simple`).
#   - chunked codebook (the large family-2 tables): DGUIDs via the fast scan, names
#     only via read_ivt(geo_attributes = TRUE).
# `geographies` is a uniform list with `member_id`, an optional `geo_name`, and an
# optional `geo_uid` (the DGUID, or the bare GEOUID for pre-DGUID tables).
ivt_f2_metadata <- function(raw, dir = NULL) {
  # `inline` (the out-of-line title pointers) tags the legacy *export* format, which
  # only governs identity/footnote storage; geography is resolved uniformly below
  # (`ivt_f2_geo_light()`), since the pre-DGUID inline geography codebook also occurs
  # in modern-export files (e.g. the 2006/2011 census tables).
  inline <- ivt_f2_geo_is_inline(raw)
  # The older `02 00 20 00` survey generation carries no reliable inline identity
  # text (its `ivt_header_text()` scan hits binary and `ivt_table_info()` returns
  # garbage); identity lives ONLY in the master-directory "Title:" blob, resolved
  # in the fallback below. Skip the inline readers for it.
  gen02 <- length(raw) >= 1L && as.integer(raw[1L]) == 2L
  info <- if (gen02) list(product_id = NA_character_, title_en = NA_character_,
                          title_fr = NA_character_, universe = NA_character_)
          else if (inline) ivt_f2_legacy_identity(raw) else ivt_table_info(raw)
  if (is.na(info$product_id) && is.na(info$title_en)) {
    # the 1981 profile vintage AND the 02-gen survey files store identity as
    # master-directory text blobs; `ivt_f2_master_identity()` handles both the
    # bare "<product_id>\r\n<title>" (1981) and the labelled
    # "Title:\r\n<title>\r\nSource:\r\n<source>" (02-gen) shapes.
    mi <- ivt_f2_master_identity(raw)
    if (!is.null(mi)) info <- mi
  }
  dims <- ivt_f2_dimensions(raw)
  n_geo <- ivt_f2_geo_count(raw)
  # `n_geo == 0`: the table has NO geography dimension (the survey generations'
  # regional dimensions carry no geographic identifiers and stay ordinary data
  # dimensions -- ivt_f2_geo_dim_index() returned 0). Skip the geography read;
  # `geographies` is left an empty member table.
  if (!is.na(n_geo) && n_geo == 0L) {
    g <- list()
  } else {
    g <- ivt_f2_geo_light(raw, n_geo)
    g <- ivt_f2_geo_fill_label(g)
    g <- ivt_f2_flag_dqf_note_truncation(g)
    ivt_f2_check_geo_count(raw, length(g$geo_uid))
    ivt_f2_check_geo_names(g$geo_name)
  }
  # pack every decoded per-member geography column (bilingual labels/names, uid,
  # aggregation level, geography type / municipal status, quality flag + note,
  # non-response rate, ...), member_id first and all-NA columns dropped -- the
  # attribute set varies by vintage and only what the file stores is exposed.
  # A column is OMITTED (not stored as a NULL slot) when undecoded, so the result
  # is always RECTANGULAR (every present column has `member_id` length) and can be
  # coerced with `tibble::as_tibble()` / `as.data.frame()`. Callers test presence
  # with `geographies[["geo_name"]]` etc., which returns NULL for an absent column
  # just as it did for the old NULL slot -- the uid-only chunked tables
  # (98-10-0023, the 2021 residence x work flow crosstabs) legitimately carry no
  # `geo_name` on the default path (names via read_ivt(geo_attributes = TRUE)).
  n_members <- if (!is.null(g$geo_uid)) length(g$geo_uid)
               else if (!is.null(g$geo_name)) length(g$geo_name)
               else if (!is.na(n_geo)) as.integer(n_geo) else 0L
  # The ROSTER is the descriptor's member count, not the codebook reader's tally.
  # `cells$geo` carries member ids 1..n_geo whatever the codebook yielded, so a
  # short read must leave those members present-but-unlabelled rather than absent,
  # or a join against the cells silently loses them. The shortfall is already LOUD
  # (`ivt_f2_check_geo_count()` above); this only keeps the table addressable.
  # Never the other way round -- a read LONGER than declared is left alone so the
  # extra members stay visible next to the warning.
  if (!is.na(n_geo) && n_geo > n_members) n_members <- as.integer(n_geo)
  geographies <- list(member_id = seq_len(n_members))
  for (col in ivt_geo_col_order(setdiff(names(g), "member_id"))) {
    v <- g[[col]]
    if (is.null(v)) next
    if (length(v) < n_members) length(v) <- n_members     # pad short columns to NA
    # all-NA attribute columns are dropped; geo_name / geo_uid are kept even
    # all-NA (their presence is the path marker downstream consumers key on)
    if (!col %in% c("geo_name", "geo_uid") && all(is.na(v))) next
    geographies[[col]] <- v
  }
  list(
    product_id        = info$product_id,
    title_en          = info$title_en,
    title_fr          = info$title_fr,
    universe          = info$universe,
    dimensions        = dims,                                  # uniform per-dim model
    dimension_names   = vapply(dims, `[[`, "", "name"),
    dimension_names_fr = vapply(dims, function(d)
                          if (is.null(d$name_fr)) NA_character_ else d$name_fr, ""),
    dimension_counts  = vapply(dims, `[[`, NA_integer_, "count"),
    geographies       = geographies,
    n_geographies     = if (!is.na(n_geo)) n_geo else {
                          if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
                          ivt_f2_geography_count(raw, dir)
                        },
    footnotes         = if (inline)
                          ivt_f2_attach_legacy_refs(
                            ivt_f2_footnote_finalize(ivt_f2_legacy_footnotes(raw)),
                            dims, if (!is.null(geographies[["geo_name"]]))
                                    geographies[["geo_name"]]
                                  else geographies[["geo_label"]])
                        else ivt_f2_footnotes(raw, dims),
    # the data-quality-flag legend (dimdir.R; NULL when the table carries none)
    dqf_legend        = ivt_f2_dqf_legend(raw)
  )
}

# Ensure every footnote record carries the uniform field set (language, number,
# text, scope, dimension, member_id) and renumber `number` per language over the
# final ordered list. Keeps the output rectangular across every producing path
# (dir / table / tail-scan / legacy), so write.R and `as_tibble()` never see a
# ragged list. `default_scope` tags records a path cannot attribute (the tail
# scan, the legacy "(N)" list) -- NA there rather than a guessed scope.
ivt_f2_footnote_finalize <- function(fns, default_scope = NA_character_) {
  if (!length(fns)) return(fns)
  counts <- c(en = 0L, fr = 0L)
  lapply(fns, function(f) {
    lang <- f$language
    counts[[lang]] <<- counts[[lang]] + 1L
    member_id <- if (is.null(f$member_id)) NA_integer_ else f$member_id
    # `member_refs` is the full set of member ids a note annotates (within
    # `dimension`); modern member notes annotate exactly one (so it mirrors
    # member_id), the legacy "(N)" notes can annotate many (attached later).
    refs <- if (!is.null(f$member_refs)) f$member_refs
            else if (!is.na(member_id)) member_id else integer(0)
    list(language = lang, number = counts[[lang]], text = f$text,
         scope = if (is.null(f$scope)) default_scope else f$scope,
         dimension = if (is.null(f$dimension)) NA_character_ else f$dimension,
         member_id = member_id, member_refs = refs)
  })
}

# Footnotes for the modern (framed "Footnote N"/"Renvoi N") format, attributed to a
# scope. Table-level (cube) notes come from the master-directory identity blob
# (`ivt_f2_table_footnotes()`); dimension- and member-level notes from the
# per-dimension slot directories (`ivt_f2_dir_footnotes()`, dimdir.R), which list
# each footnote as an entry of the dimension it annotates and split member vs
# dimension scope via the member bitmap. Every record carries `scope`
# ("table"/"dimension"/"member"), `dimension` and `member_id`. Falls back to the
# tail text-scan when the slot table is absent, or when the directories resolve but
# list no footnotes while the scan finds some (an unknown layout storing them
# elsewhere degrades gracefully rather than silently losing footnotes).
ivt_f2_footnotes <- function(raw, dims = NULL) {
  dim_names <- if (length(dims)) vapply(dims, `[[`, "", "name") else NULL
  tbl <- ivt_f2_table_footnotes(raw)
  fn <- ivt_f2_dir_footnotes(raw, dim_names = dim_names)
  if (length(fn)) return(ivt_f2_footnote_finalize(c(tbl, fn)))
  sc <- ivt_footnotes(raw, max(0L, length(raw) - 200000L))
  if (length(sc)) {
    ivt_fallback(paste(
      "The per-dimension slot directories list no footnotes but the tail text",
      "scan found {length(sc)}; using the scanned footnotes (no dimension",
      "attribution)."))
  }
  ivt_f2_footnote_finalize(c(tbl, sc))
}

# Output column name per data dimension. `datacols` is the cells' data-column
# order (the structural slugs, in descriptor order). `dim_names` selects "slug"
# (keep the terse structural names, e.g. `age`/`tenure`) or "label" (the full
# English dimension name from the metadata -- Variable List, count-stripped --
# e.g. `Age of primary household maintainer`). Both `ivt_tidy()` and
# `ivt_members()` name columns through this, so the tidy output and the level
# sidecar always agree. Names are made unique so two dimensions sharing a leading
# word (slug) or a display name (label) stay distinct. `language` picks the label:
# "fr" uses each dimension's French name (`name_fr`), falling back to the English
# name when the file carries none (e.g. the Statistics dimension).
ivt_data_colnames <- function(datacols, meta, dim_names = c("slug", "label"),
                              language = "en") {
  dim_names <- match.arg(dim_names)
  if (dim_names == "slug" || !length(datacols)) return(datacols)
  data_dims <- Filter(function(d) !d$is_geography, meta$dimensions)
  nm <- datacols
  for (j in seq_along(datacols)) {
    if (j > length(data_dims)) break
    d <- data_dims[[j]]
    v <- if (language == "fr" && !is.null(d$name_fr) && !is.na(d$name_fr) &&
             nzchar(d$name_fr)) d$name_fr else d$name
    if (!is.null(v) && !is.na(v) && nzchar(v)) nm[j] <- v      # else keep the slug
  }
  make.unique(nm, sep = "")
}

# Normalise a language argument to "en" or "fr". Accepts en/eng/english and
# fr/fra/fre/french/francais (case-insensitive); errors on anything else.
ivt_norm_lang <- function(language = "en") {
  l <- tolower(trimws(as.character(language)[1]))
  if (l %in% c("en", "eng", "english")) return("en")
  if (l %in% c("fr", "fra", "fre", "french", "francais", "fran\u00e7ais")) return("fr")
  cli::cli_abort(c(
    "Unknown {.arg language} value {.val {language}}.",
    i = 'Use {.val en} / {.val eng} for English or {.val fr} / {.val fra} for French.'))
}

# Label a decoded cell table (any family): geography by name and/or uid, each data
# dimension by its member name. Cells are keyed by 1-based member ids (`geo`, plus
# one column per data dimension), so labels join by direct indexing. Data columns
# are named by `dim_names` (the full dimension label by default, the terse
# structural slug when "slug"). `language` selects English ("en") or French
# ("fr") labels throughout -- geography names, member labels and the data column
# names -- falling back to English wherever the file carries no French copy (the
# language-neutral `geo_uid` is unaffected).
ivt_f2_tidy <- function(x, trim_labels = TRUE, dim_names = c("slug", "label"),
                        language = "en", depth = FALSE) {
  dim_names <- match.arg(dim_names)
  cells <- x$cells
  meta <- x$metadata
  fix <- if (trim_labels) trimws else identity
  geo <- meta$geographies
  # language-aware geography getter: the French copy (`<key>_fr`) when
  # language == "fr" and it is present, else the English column.
  gval <- function(key) {
    if (language == "fr" && !is.null(geo[[paste0(key, "_fr")]]))
      geo[[paste0(key, "_fr")]] else geo[[key]]
  }
  # geography columns, included only when decoded: `geo_label` (display Member
  # Name), `geo_name` (schema GEO_NAME) + `geo_level` come from the full attribute
  # table (read_ivt(geo_attributes = TRUE)), `geo_uid` from the light path (DGUID;
  # legacy files have none until geo_attributes = TRUE). If nothing is available,
  # fall back to the bare member id.
  out <- tibble::tibble(.rows = nrow(cells))
  if (!is.null(geo[["geo_label"]])) out$geo_label <- fix(gval("geo_label"))[cells$geo]
  if (!is.null(geo[["geo_name"]]))  out$geo_name  <- fix(gval("geo_name"))[cells$geo]
  if (!is.null(geo[["geo_uid"]]))   out$geo_uid   <- geo[["geo_uid"]][cells$geo]
  if (!is.null(geo[["geo_level"]])) out$geo_level <- fix(gval("geo_level"))[cells$geo]
  # origin-destination flow tables (2011 NHS) decode geography as two geographies:
  # place of residence (`geo_res_*`) and place of work (`geo_work_*`).
  for (side in c("geo_res_name", "geo_res_uid", "geo_work_name", "geo_work_uid")) {
    if (!is.null(geo[[side]]))
      out[[side]] <- if (grepl("_uid$", side)) geo[[side]][cells$geo]
                     else fix(gval(side))[cells$geo]
  }
  # bare member-id fallback -- only when the table HAS a geography dimension
  # (a survey table without one has no `geo` cells column at all)
  if (ncol(out) == 0L && !is.null(cells[["geo"]])) out$geo <- cells$geo
  # the non-geography data columns of `cells` line up with the non-geography
  # dimensions in declaration order; label each from its dimension's member list.
  datacols <- setdiff(names(cells), c("geo", "value"))
  data_dims <- Filter(function(d) !d$is_geography, meta$dimensions)
  outnames <- ivt_data_colnames(datacols, meta, dim_names, language)
  for (j in seq_along(datacols)) {
    col <- datacols[j]
    d <- if (j <= length(data_dims)) data_dims[[j]] else NULL
    labs <- if (is.null(d)) NULL
      else if (language == "fr" && !is.null(d$members_fr) &&
               length(d$members_fr) == length(d$members)) d$members_fr
      else d$members
    out[[outnames[j]]] <- if (!is.null(labs)) fix(labs)[cells[[col]]] else cells[[col]]
    # optional per-member hierarchy depth, read from the label indentation of the
    # (untrimmed) member list -- a `<col>_depth` integer column right after the
    # dimension. Opt-in so default output, parquet and members sidecar are unchanged.
    if (depth && !is.null(labs))
      out[[paste0(outnames[j], "_depth")]] <- ivt_label_depth(labs)[cells[[col]]]
  }
  out$value <- cells$value
  out
}
