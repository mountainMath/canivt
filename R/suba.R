# The type-00 "sub-A" provincial SIC/NAIC cluster (Canadian Business Patterns,
# 1997-2002; byte 0 == 0x02, NO geography dimension, three plain data dimensions
# PROV/CAN|CA/CMA x INDUSTRY x EMPCLASS). These files decode with the standard
# unified layout EXCEPT for two facts that are NOT in any declared allocation and
# so cannot be derived by `ivt_layout()`:
#
#  1. The outer (geography-like PROV/CMA) directory stride is a physical CONSTANT
#     -- 16 windows for the industry straddle -- present in EVERY file regardless
#     of geo count (13 provinces or 141 CA/CMA) or how many windows a geography
#     actually uses. It is HALF the declared industry allocation model would
#     predict (industry declares 1024 -> 8 windows) and the same 16 whether the
#     industry axis is 19 dense divisions (PROVIND, one window used) or 322 chunked
#     SIC groups (PROVSIC3, windows {0,1,2,3,13}). No candidate rule
#     (nextpow2(empclass) / nextpow2(ceil(entries/geo)) / a constant) can be told
#     apart on the corpus, so the stride is MEASURED from the file's own page
#     directory rather than derived.
#  2. The industry codebook UNDER-declares its member count (the descriptor and the
#     positional label reader both stop at the first chunk, 161 of 321), the detail
#     members occupy a contiguous slot run at a file-specific offset (right-aligned
#     to a window boundary for the multi-chunk SIC files, left-aligned at 0 for the
#     single-chunk DIVISIONS file -- no unified analytic rule), and a separate
#     grand-"Total" member sits alone at a high window (slot 13*128+7 on PROVSIC3).
#
# There is NO ground truth for these tables (Borealis carries only the .ivt plus
# documentation PDFs; Odesi only .ivt; the open Canadian Business Counts CSVs are a
# different vintage AND classification). The cell VALUES are validated GROUND-TRUTH-
# FREE by a reconciliation identity (the industry-"Total" page equals the sum of the
# detail industries per geography x employment-size; the geography "Canada" total
# equals the sum of the provinces), which this module ENFORCES as a decode gate:
# the sub-A geometry is adopted only if it reconciles, else the file is left
# UNSUPPORTED. What reconciliation CANNOT verify is the industry axis LABEL
# assignment (which SIC code attaches to which decoded member -- a uniform relabel
# leaves the sums unchanged), so the industry labels are surfaced PROVISIONAL: the
# values are solid, the code->member mapping is the standard B2020 storage-order
# convention but unverified. Everything here is LOUD (`canivt_suba*` fallbacks);
# `options(canivt.strict = TRUE)` upgrades them to errors.
#
# The whole path is engaged ONLY through `ivt_f2_suba_annotate()`, which is a no-op
# unless the tight signature holds AND the standard model mis-strides AND the
# reconciliation gate passes -- so no other corpus table is touched.

# Measure the outer directory stride S (entry slots allocated per geography) AND
# the window slots each geography populates, from the page directory itself.
#
# The directory TILES: every geography gets S consecutive entry slots and writes
# the same window slots inside them, because the industry axis is laid out
# identically for every province. So the populated entry indices, read modulo a
# candidate S, must fall into `geo_count` groups with an IDENTICAL residue set.
# That periodicity is the measurement, and unlike the progression 0, S, 2S, .. it
# replaces, it does not assume window 0 is populated -- which is exactly what
# defeated the previous rule: `PROVSIC4dec1997` lays its industry windows at slots
# 3..13 of each 16-slot group, leaving every entry the progression looked for
# blank. It is also strictly tighter: the same file's spurious S=4 "progression"
# (13 consecutive groups, but residue sets {3}, {0,1,2,3}, {0,1}, ..) is rejected,
# as is `PROVSIC4-2`'s, where the old rule returned 4 against a true stride of 16.
#
# Entries beyond the directory's own extent (`geo_count * S`) are codebook or text
# bytes that coincidentally parse as an entry -- PROVIND has 6 of them, ~7x past
# its 13-block directory. They are ignored, but only when clearly separated: a
# directory that RESUMES immediately past the extent means S is too small, which
# is what distinguishes `PRNAIC6dec2000`'s true stride of 8 from the 4 the old rule
# reported. Only entries below `2 * extent` are ever scanned, so the candidate
# sweep stays cheap.
#
# Returns `list(stride, windows)` -- `windows` the 0-based window slots every
# geography populates -- or NULL when no clean tiling is found.
ivt_f2_suba_dir_stride <- function(raw, idx0, geo_count, n = length(raw)) {
  if (is.na(geo_count) || geo_count < 2L) return(NULL)
  avail <- (n - idx0) %/% 8L
  if (avail < geo_count) return(NULL)
  hits <- integer(0); scanned <- 0L
  extend <- function(lim) {
    lim <- min(as.integer(lim), avail)
    if (lim <= scanned) return(invisible(NULL))
    add <- integer(lim - scanned); na <- 0L
    for (k in scanned:(lim - 1L)) {
      en <- ivt_dir_entry(raw, idx0 + k * 8L, n)
      if (!is.null(en) && en$marker) { na <- na + 1L; add[na] <- k }
    }
    hits <<- c(hits, add[seq_len(na)]); scanned <<- lim
    invisible(NULL)
  }
  for (S in c(4L, 8L, 16L, 32L, 64L, 128L, 256L)) {
    ext <- geo_count * S
    if (ext > avail) break
    extend(min(2L * ext, avail))
    inside <- hits[hits < ext]
    if (!length(inside)) next
    grp <- inside %/% S
    # allow a couple of wholly-empty (suppressed) geographies
    if (length(unique(grp)) < geo_count - 2L) next
    res <- split(inside %% S, grp)
    w <- sort(unique(res[[1L]]))
    if (!all(vapply(res, function(z) identical(sort(unique(z)), w), logical(1)))) next
    beyond <- hits[hits >= ext]
    if (length(beyond)) next          # the directory continues: S is too small
    return(list(stride = S, windows = w))
  }
  NULL
}

# Decode-probe every page under a MEASURED stride S using the model layout's
# in-page grid (`lay0`, whose in-page nesting is correct -- only its directory
# stride was wrong). Returns one row per non-zero cell: geography index `g`
# (0-based, directory order), the global 1-based industry slot `ind` (window *
# ipc1 + in-page position), the innermost `emp` member (1-based) and the `val`.
# NULL if nothing decodes.
ivt_f2_suba_probe <- function(raw, idx0, lay0, S, geo_count, n = length(raw)) {
  ipc1 <- lay0$ipc[1L]
  acc <- vector("list", geo_count * length(0:(S - 1L)))
  ai <- 0L
  for (g in 0:(geo_count - 1L)) for (w in 0:(S - 1L)) {
    o <- idx0 + (g * S + w) * 8L
    if (o + 8L > n) next
    en <- ivt_dir_entry(raw, o, n)
    if (is.null(en) || !en$marker) next
    pg <- tryCatch(ivt_decode_page(raw, en$off, lay0, size = en$size),
                   error = function(e) NULL)
    if (is.null(pg)) next
    ai <- ai + 1L
    acc[[ai]] <- data.frame(g = g,
                            ind = w * ipc1 + pg$tuples[, 1L],   # 1-based global slot
                            emp = pg$tuples[, 2L],
                            val = pg$vals)
  }
  if (ai == 0L) return(NULL)
  do.call(rbind, acc[seq_len(ai)])
}

# The industry dimension's member CODES and full labels, and whether the codebook
# carries an explicit grand-"Total" member. Reads every `01 01`-framed member array
# in the dimension's block directory (the descriptor / positional reader stops at
# the first chunk), takes each member's leading whitespace-delimited token as its
# code, and de-duplicates across the EN/FR copies keeping the FIRST-seen full label
# (the English chunk precedes its French copy in directory order). Numeric-coded
# members are the detail industries (returned sorted by code, with their full
# labels aligned); a "Total"/"Ensemble"-type single token flags the separate total
# member. The labels are PROVISIONAL -- see suba.R's header.
ivt_f2_suba_industry_codes <- function(raw, dim_idx, slots_tbl) {
  dir <- tryCatch(ivt_f2_dim_dir(raw, dim_idx, slots_tbl), error = function(e) NULL)
  if (is.null(dir)) return(NULL)
  code_label <- list(); has_total <- FALSE
  for (r in seq_len(nrow(dir))) {
    e <- tryCatch(ivt_f2_dir_entry_members(raw, dir[r, "off"], dir[r, "len"]),
                  error = function(e) NULL)
    if (is.null(e)) next
    v <- e$values[!is.na(e$values)]
    if (!length(v) || ivt_f2_is_ordinal(v)) next
    tok <- sub("\\s.*$", "", trimws(v))
    if (any(grepl("^(total|ensemble)$", tok, ignore.case = TRUE))) has_total <- TRUE
    for (i in seq_along(v)) {
      code <- tok[i]
      if (!grepl("^[0-9]+$", code)) next          # detail industries are numeric-coded
      if (is.null(code_label[[code]])) code_label[[code]] <- trimws(v[i])
    }
  }
  codes <- names(code_label)
  if (!length(codes)) return(NULL)
  ord <- order(codes)
  list(detail = codes[ord],
       detail_labels = unlist(code_label[codes[ord]], use.names = FALSE),
       has_total = has_total)
}

# The sub-A recognizer + annotator. Returns `d` UNCHANGED unless every gate holds:
# byte0 == 0x02, exactly three dimensions, no geography dimension, the middle
# dimension straddles, a MEASURED directory stride that the standard model does not
# already produce, and -- decisively -- a decode that RECONCILES. When it does, the
# industry dimension is annotated with its recovered member count and slot map (for
# the chunked SIC files) and the descriptor carries `attr(d, "suba")` with the
# measured stride (which `ivt_layout_impl()` honours) and a provisional-labels flag.
# LOUD: `canivt_suba` on engagement, and `canivt_suba_labels` to mark the industry
# axis labels unverified.
ivt_f2_suba_annotate <- function(raw, d) {
  if (is.null(d) || length(raw) < 8L) return(d)
  if (as.integer(raw[1L]) != 0x02L) return(d)
  if (length(d$dims) != 3L) return(d)
  gd <- tryCatch(ivt_f2_geo_dim_index(raw, d), error = function(e) 1L)
  if (gd != 0L) return(d)                       # only the no-geography cluster
  lay0 <- tryCatch(ivt_layout_impl(raw, d), error = function(e) NULL)
  if (is.null(lay0) || lay0$straddle != 2L || length(lay0$ipc) < 2L) return(d)

  geo_count <- suppressWarnings(as.integer(d$dims[[1L]]$count))
  idx0 <- ivt_idx0(raw); n <- length(raw)
  ds <- ivt_f2_suba_dir_stride(raw, idx0, geo_count, n)
  if (is.null(ds)) {
    # In this cluster the outer directory stride is a NON-DECLARED physical
    # constant, so the model's stride is only ever believed once the page
    # directory confirms it. With two or more outer members the directory MUST
    # tile; finding no tiling means the outer geometry is unverified and the file
    # must not decode on the assumed one. A single outer member (`EDDTAB16`,
    # geography count 1) has no stride to measure and so nothing to verify -- it
    # is left alone.
    if (!is.na(geo_count) && geo_count > 1L) attr(d, "suba_unverified") <- TRUE
    return(d)
  }
  S <- ds$stride
  model_stride <- lay0$estride[length(lay0$estride)]  # outer (geography) stride
  # The standard model is already correct only if it strides the same AND its
  # window enumeration reaches every window the directory actually populates.
  # `PROVSIC4dec1997` strides 16 exactly as the model does, but its industry
  # members start at window 3 and run to window 13, where the model -- sizing the
  # window count from the member count alone, `ceil(1255/128) = 10` -- enumerates
  # 0..9. Reading only that prefix silently drops the top four windows and the
  # grand-total member: 41,260 cells on an industry axis running 419..1254, whose
  # aggregate identities miss by millions. The directory's own residues are the
  # witness for how far the axis reaches, so they gate the early return too.
  if (S == model_stride && max(ds$windows) < lay0$ent_counts[1L]) return(d)

  probe <- ivt_f2_suba_probe(raw, idx0, lay0, S, geo_count, n)
  if (is.null(probe) || !nrow(probe)) return(d)
  ipc1 <- lay0$ipc[1L]
  straddle_count <- lay0$counts[2L]
  occ <- sort(unique(probe$ind))

  emit <- function(kind, provisional) {
    ivt_fallback(sprintf(paste(
      "Type-00 sub-A provincial Business-Patterns table (%s): the outer directory",
      "stride (%d) is a non-declared physical constant measured from the page",
      "directory, and the industry axis is decoded under a reconciliation gate."),
      kind, S), class = "canivt_suba")
    if (provisional)
      ivt_fallback(paste(
        "The industry axis LABELS are PROVISIONAL: cell values reconcile exactly,",
        "but the code->member assignment (standard B2020 storage order) is",
        "unverified against ground truth."), class = "canivt_suba_labels")
  }

  # Recover the industry codebook: the detail member codes (the descriptor / label
  # reader stop at the first chunk) and whether a grand-"Total" member exists.
  slots_tbl <- ivt_f2_dim_slots(raw, m = 3L)
  ic <- ivt_f2_suba_industry_codes(raw, 2L, slots_tbl)

  # DENSE case (DIVISIONS/SECTORS): the descriptor count already matches the
  # codebook (no under-read) and every occupied slot falls inside it -- members sit
  # dense from window 0, no separate total to reconcile. A wrong stride would
  # scatter slots past the member count, so that IS the gate. Only a stride
  # override is needed; the descriptor count/labels are reused as-is.
  if ((is.null(ic) || length(ic$detail) <= straddle_count) && max(occ) <= straddle_count) {
    attr(d, "suba") <- list(stride = S, kind = "dense", provisional = FALSE)
    emit("dense divisions", FALSE)
    return(d)
  }

  # CHUNKED case: the codebook stores D detail members (> the descriptor count) plus
  # a grand-total. The detail members occupy a contiguous D-slot run; the total sits
  # at one of a few file-specific positions -- FIRST (member 1, immediately below the
  # run -- the PAWNKX vintage / the dense DIVISIONS convention), CONTIGUOUS-LAST
  # (just past the run), FAR (alone at a high window -- the OWUF3P vintage), or FIRST
  # BUT DETACHED: the total alone in window 0 with the detail run right-aligned to
  # the last occupied slot, a whole empty gap between them (`PROVSIC4-2` totals at
  # slot 1 with detail at 417..1670; `CACMA3-2` at 87..416; `PROVSIC2june1998` at
  # 20..95). Anchoring the run on `min(occ)` cannot see that shape, so it is anchored
  # on `max(occ)` instead. Enumerate the candidate placements and keep every one
  # whose detail industries sum EXACTLY to the total page per geography x
  # employment-size; the real grand total dominates every cell, so among the
  # survivors pick the total slot with the largest aggregate. If none reconciles, the
  # file is left UNSUPPORTED.
  if (is.null(ic) || !ic$has_total) return(d)
  D <- length(ic$detail)
  offset <- min(occ)                                  # 1-based lowest occupied slot
  hi <- max(occ)
  # the detail aggregate depends only on the RANGE, and the FAR sweep below reuses
  # one range across up to a few hundred candidates -- memoize it
  det_cache <- new.env(parent = emptyenv())
  det_sum <- function(rng) {
    key <- paste0(min(rng), ":", max(rng))
    if (is.null(det_cache[[key]])) {
      det <- probe[probe$ind %in% rng, ]
      det_cache[[key]] <- if (nrow(det)) aggregate(val ~ g + emp, det, sum) else NA
    }
    det_cache[[key]]
  }
  recon <- function(det_range, tslot) {               # exact-reconcile test
    tot <- probe[probe$ind == tslot, ]
    ds <- det_sum(det_range)
    if (!nrow(tot) || !is.data.frame(ds)) return(NA_real_)
    ts <- aggregate(val ~ g + emp, tot, sum)
    mm <- merge(ds, ts, by = c("g", "emp"), suffixes = c(".d", ".t"))
    if (!nrow(mm) || nrow(mm) != nrow(ts) || any(mm$val.d != mm$val.t)) return(NA_real_)
    sum(tot$val)                                      # aggregate (for tie-break)
  }
  # each candidate: the member-ordered slot vector (total's position varies) + the
  # detail cell range + the total slot
  cands <- list(
    # total FIRST (member 1 at `offset`), detail members 2..D+1 above it
    list(pos = offset + 0:D,         det = (offset + 1L):(offset + D), tot = offset),
    # total CONTIGUOUS-LAST (member D+1 just past the detail run)
    list(pos = offset + 0:D,         det = offset:(offset + D - 1L),   tot = offset + D))
  if (hi - D + 1L > offset)                           # total FIRST, run DETACHED
    cands[[length(cands) + 1L]] <-
      list(pos = c(offset, (hi - D + 1L):hi), det = (hi - D + 1L):hi, tot = offset)
  for (far in sort(unique(occ[occ > offset + D])))    # total FAR (isolated window)
    cands[[length(cands) + 1L]] <-
      list(pos = c(offset:(offset + D - 1L), far), det = offset:(offset + D - 1L), tot = far)

  best <- NULL; best_agg <- -Inf
  for (cd in cands) {
    agg <- recon(cd$det, cd$tot)
    if (!is.na(agg) && agg > best_agg) { best <- cd; best_agg <- agg }
  }
  if (is.null(best)) return(d)
  total_first <- best$tot == offset
  # provisional member labels in member-id order (matching `best$pos`): the total
  # takes the end the reconciliation placed it at.
  labels <- if (total_first) c("Total", ic$detail_labels)
            else c(ic$detail_labels, "Total")
  d$dims[[2L]]$count <- as.integer(D + 1L)
  d$dims[[2L]]$slots <- as.integer(best$pos)
  attr(d, "suba") <- list(stride = S, kind = "chunked", provisional = TRUE,
                          total_first = total_first, labels = labels)
  emit("chunked SIC/NAIC", TRUE)
  d
}
