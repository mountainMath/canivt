# Geo snapshot harness (refactor-plan.md §7.1) -- shared capture logic.
#
# The §7 geography consolidation ("recover-then-specialize") moves the six geo
# readers behind a single Stage-1 recovery + dispatcher. Every migration step must
# reproduce the geography read BYTE-IDENTICALLY. This helper captures a stable
# digest of both read paths plus the exact set + order of canivt_* warnings each
# emits, so `test-geo-snapshot.R` (opt-in, like the corpus ledger) can assert the
# read never drifts. It is also the source of truth for regenerating the fixture
# (see scratchpad/geo-snapshot.R / the regen block at the foot of the test file).
#
# The two paths:
#   - ivt_f2_geo_light(raw, n_geo)  -- the metadata / default `metadata$geographies`
#   - ivt_f2_geographies(raw)       -- the read_ivt(geo_attributes = TRUE) full path
# The corpus ledger only ever exercises the LIGHT path, so the full path is
# otherwise UNGUARDED -- this harness is the only regression net for it. (The
# stride-walk + reverse-root fallback is now unreached by the corpus -- 98100013
# used to reach it but reads cleanly through the directory path since the footnote
# text blocks are skipped -- yet is retained as a loud fallback for future
# genuinely-irregular layouts.)

# Normalize a warning-set string for comparison: NA (path not captured, or an
# empty warning set stored as "") both read as "".
geo_snap_nastr <- function(x) if (length(x) != 1L || is.na(x)) "" else x

# canivt_* subclasses of a condition, most-specific first (drops the plain
# "warning"/"condition" tail and any non-canivt classes).
geo_snap_warn_classes <- function(w) {
  cl <- class(w)
  cl[grepl("^canivt", cl)]
}

# Run one geo read, muffling + recording its canivt_* warnings in emission order
# (the most-specific subclass of each). An error is recorded verbatim so a read
# that starts erroring is caught as a change rather than aborting the sweep.
geo_snap_capture <- function(expr) {
  warns <- character(0)
  val <- withCallingHandlers(
    tryCatch(expr,
             error = function(e) structure(list(message = conditionMessage(e)),
                                           class = "geo_snap_error")),
    warning = function(w) {
      cw <- geo_snap_warn_classes(w)
      if (length(cw)) warns[[length(warns) + 1L]] <<- cw[[1L]]
      invokeRestart("muffleWarning")
    }
  )
  list(value = val, warnings = warns)
}

# Capture both read paths for one table's raw bytes. `do_full` gates the ~30 s
# full-attribute scan (only the tables in GEO_SNAP_FULL below).
geo_snap_one <- function(raw, do_full = TRUE) {
  # n_geo is a precondition of the read, not part of the snapshot; suppress its
  # (descriptor-parse) warnings here -- they are captured where they matter, when
  # the memoized descriptor compute REPLAYS them inside the light read below.
  n_geo <- suppressWarnings(
    tryCatch(ivt_f2_geo_count(raw), error = function(e) NA_integer_))
  light <- geo_snap_capture(ivt_f2_geo_light(raw, n_geo))
  full  <- if (do_full) geo_snap_capture(ivt_f2_geographies(raw)) else NULL
  list(n_geo = n_geo, light = light, full = full)
}

# The tables whose FULL path is captured. The plan's five validation tables
# (§7.4) -- the ones the corpus ledger never touches -- plus the cheap small
# schema'd / flow tables, but NOT the giant uid-only tables (each ~30 s for no
# extra coverage over the light path).
GEO_SNAP_FULL <- c(
  "98100013", "98100023", "98100478", "98100662", "1003011",
  "98100241", "98100077", "98100129", "98100174",
  "98-10-0459-01", "98-10-0460-01", "98-10-0466-01",
  "99-012-X2011032", "98-400-X2016325", "98-400-X2016391", "98-400-X2016327",
  # custom / bare tables: the full path now decodes these (§7.3 shared dispatch;
  # previously it returned an all-NA tibble). Guard the fix.
  "CRO0163850_CT6", "CRO0166131_CT1_1", "CMHC2016_movers_T1", "CBP2007DA",
  # the two custom exports whose geography is now recovered by the Stage 3
  # assemble-then-decipher net (EO3278 chunked no-schema; EO2654 geo dim named
  # in the header + a short-directory read).
  "EO3278_T1_CDCSD", "EO2654_2011_Van",
  # a 2001 CMA profile (cheap, complete full read; guards its geography names).
  "95f0491xcb01004",
  # the 2021 pop-count tables 98100019 (FSA) / 98100010 (FED): their directory
  # carries per-member footnote TEXT blocks in its tail that used to inflate the
  # attribute value-block count and defeat the regular-layout gate (FSA +1, FED
  # +37), forcing the lossy stride-walk. Those blocks are now recognized and
  # skipped (ivt_f2_dir_is_text_block), so the full read is complete -- guard it.
  "98100019", "98100010"
)

# Collapse one table's capture to the committed-fixture row: a deterministic hash
# of each read's returned value + the DISTINCT warning classes (first-appearance
# order). NA hash means "path not captured" (full path of a non-GEO_SNAP_FULL
# table).
#
# Warnings are deduplicated deliberately: a memoized compute (§3) REPLAYS its
# recorded warnings on every cache hit, so the raw multiset counts how many times
# a path touched the memo -- an implementation artifact that shifts with benign
# structural refactors. The invariant the harness pins is WHICH fallback classes
# fired (a new one appearing / an old one vanishing), not the replay count, so it
# stores the distinct classes only.
geo_snap_digest <- function(one) {
  hash_or_na <- function(cap) if (is.null(cap)) NA_character_ else rlang::hash(cap$value)
  warns_str  <- function(cap) if (is.null(cap)) NA_character_ else paste(unique(cap$warnings), collapse = "|")
  list(
    n_geo          = one$n_geo,
    light_hash     = hash_or_na(one$light),
    light_warnings = warns_str(one$light),
    full_hash      = hash_or_na(one$full),
    full_warnings  = warns_str(one$full)
  )
}
