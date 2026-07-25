# The structural page-marker model (decode.R) and the loud-fallback machinery
# (fallback.R). Pure unit tests -- no sample file needed.

test_that("the value trailer is derived structurally from the marker's b2/b3 bytes", {
  # b2 == 0x00, b3 == 0x08: the value run starts right after the presence record
  expect_equal(ivt_value_trailer(0x84L, 0x00L), 0L)
  expect_equal(ivt_value_trailer(0x88L, 0x00L), 0L)
  # trailer = 2*(b2 >> 4) + 2*(low nibble > 0): the historically constant pairs
  expect_equal(ivt_value_trailer(0x88L, 0x20L), 4L)   # float64
  expect_equal(ivt_value_trailer(0x84L, 0x40L), 8L)   # int32
  expect_equal(ivt_value_trailer(0x82L, 0x80L), 16L)  # int16
  expect_equal(ivt_value_trailer(0xa8L, 0x41L), 10L)  # float64
  expect_equal(ivt_value_trailer(0xa4L, 0x82L), 18L)  # int32
  # ... and 98-10-0013's varying b2 values (each anchored vs the StatCan CSV)
  expect_equal(ivt_value_trailer(0xa8L, 0x2aL), 6L)
  expect_equal(ivt_value_trailer(0xa8L, 0x30L), 6L)
  expect_equal(ivt_value_trailer(0xa8L, 0x31L), 8L)
  expect_equal(ivt_value_trailer(0xa8L, 0x4eL), 10L)
  expect_equal(ivt_value_trailer(0xa8L, 0x53L), 12L)
  expect_equal(ivt_value_trailer(0xa8L, 0x60L), 12L)
  expect_equal(ivt_value_trailer(0xa8L, 0x63L), 14L)
  # b3 encodes an auxiliary head block of 32*(b3 - 8) bytes before the run.
  # The corpus's 0xa2 pages are all `a2 01 03 09`: trailer 2 + head 32 = 34
  # (this reproduces the formerly hard-coded "+32 on 0xa2" constant).
  expect_equal(ivt_value_trailer(0xa2L, 0x03L, 0x09L), 34L)
  # The 2006 census vintage (97-563-XCB2006072): b3 = 0x0a / 0x0c heads on
  # trailer-less pages, verified against the page-size equation on all
  # 14,381 of its pages.
  expect_equal(ivt_value_trailer(0x84L, 0x00L, 0x0aL), 64L)
  expect_equal(ivt_value_trailer(0x84L, 0x00L, 0x0cL), 128L)
  expect_equal(ivt_value_trailer(0x82L, 0x00L, 0x0cL), 128L)
  # the head is a contiguous run of 32-byte blocks, so 0x0b/0x0d/0x0e fill the
  # span between the census vintages' 0x0a/0x0c (SLID-era income lineage)
  expect_equal(ivt_value_trailer(0x84L, 0x00L, 0x0bL), 96L)
  expect_equal(ivt_value_trailer(0x82L, 0x00L, 0x0dL), 160L)
  expect_equal(ivt_value_trailer(0x84L, 0x00L, 0x0eL), 192L)
  # unknown width code, high nibble or b3: abort rather than decode garbage
  expect_error(ivt_value_trailer(0x86L, 0x01L), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x81L, 0x01L), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x48L, 0x01L), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x84L, 0x00L, 0x07L), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x84L, 0x00L, 0x0fL), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x84L, 0x00L, 0x10L), class = "canivt_unknown_marker")
})

test_that("an entry index past 32-bit byte addressing is rejected, not overflowed", {
  # Every page-directory entry is 8 bytes and is reached as `idx0 + 8L * k`, so
  # the addressable ceiling is the integer range less the directory base.
  idx0 <- 1024L
  lim <- (.Machine$integer.max - idx0) %/% 8L
  expect_true(ivt_entry_addressable(0, idx0))
  expect_true(ivt_entry_addressable(lim, idx0))
  expect_false(ivt_entry_addressable(lim + 1, idx0))
  expect_false(ivt_entry_addressable(-1, idx0))
  # the offset the caller then forms must itself stay representable
  expect_false(is.na(idx0 + 8L * as.integer(lim)))

  # A misread descriptor multiplies out past the ceiling. Computed in INTEGER
  # that product is silently NA ("NAs produced by integer overflow"), and the NA
  # reached `ivt_dir_entry()` as "NA/NaN argument" -- an ERROR out of the
  # detection gate rather than an unsupported verdict. The real case is
  # Alternative.cfm_PID_1195_EXT_IVT: 3383 outer members x stride 33554432.
  expect_warning(3383L * 33554432L, "integer overflow")
  expect_false(ivt_entry_addressable(as.numeric(3383) * 33554432, idx0))
  expect_false(ivt_entry_addressable(NA_real_, idx0))
  expect_false(ivt_entry_addressable(as.integer(NA), idx0))
})

test_that("ivt_fallback warns with a classed condition", {
  expect_warning(ivt_fallback("test fallback engaged"), class = "canivt_fallback")
  expect_warning(ivt_fallback("pages missing", class = "canivt_skipped_pages"),
                 class = "canivt_skipped_pages")
})

test_that("a custom class never opts a fallback out of the umbrella class", {
  # ivt_quietly(), strict mode and the corpus ledger all key on canivt_fallback,
  # so ivt_fallback() appends it itself -- a caller passing only a subclass
  # (canivt_skipped_pages, canivt_descriptor_reloc) still carries the umbrella.
  expect_warning(ivt_fallback("pages missing", class = "canivt_skipped_pages"),
                 class = "canivt_fallback")
  expect_no_warning(ivt_quietly(ivt_fallback("probe", class = "canivt_skipped_pages")))
})

test_that("strict mode turns fallbacks into classed errors", {
  withr::local_options(canivt.strict = TRUE)
  expect_error(ivt_fallback("test fallback engaged"), class = "canivt_fallback_error")
  expect_error(ivt_fallback("pages missing", class = "canivt_skipped_pages"),
               class = "canivt_skipped_pages_error")
  # the strict error carries the umbrella _error class too, so detection probes
  # (ivt_quietly) read a refused custom-class fallback as "not found"
  expect_error(ivt_fallback("pages missing", class = "canivt_skipped_pages"),
               class = "canivt_fallback_error")
  expect_null(ivt_quietly({ ivt_fallback("probe", class = "canivt_skipped_pages"); 1L }))
})

test_that("a geography count mismatch is a classed fallback condition", {
  # a raw header whose geography record cannot be read yields want = NA -> silent
  expect_no_warning(ivt_f2_check_geo_count(raw(64L), 10L))
  # subclass first so callers can distinguish it; still a canivt_fallback so
  # detection probes muffle it and strict mode upgrades it
  fake <- structure(list(), class = "fake")
  local_mocked_bindings(ivt_f2_geo_count = function(raw) 5447L)
  expect_warning(ivt_f2_check_geo_count(fake, 5191L), class = "canivt_geo_count")
  expect_warning(ivt_f2_check_geo_count(fake, 5191L), class = "canivt_fallback")
  expect_no_warning(ivt_f2_check_geo_count(fake, 5447L))
  withr::local_options(canivt.strict = TRUE)
  expect_error(ivt_f2_check_geo_count(fake, 5191L), class = "canivt_geo_count_error")
})

test_that("a nameless geography is a classed fallback (silent-truncation tripwire)", {
  # every member named -> clean; NULL (name column undecoded) -> clean
  expect_no_warning(expect_equal(ivt_f2_check_geo_names(c("Canada", "Ontario")), 0L))
  expect_no_warning(expect_equal(ivt_f2_check_geo_names(NULL), 0L))
  # any NA name means a codebook block was mis-parsed: warn loudly, subclass first
  gap <- c("Canada", NA_character_, "Quebec")
  expect_warning(ivt_f2_check_geo_names(gap), class = "canivt_geo_name_gap")
  expect_warning(ivt_f2_check_geo_names(gap), class = "canivt_fallback")
  expect_equal(suppressWarnings(ivt_f2_check_geo_names(gap)), 1L)
  # and strict mode upgrades it to a hard error rather than emit NA metadata
  withr::local_options(canivt.strict = TRUE)
  expect_error(ivt_f2_check_geo_names(gap), class = "canivt_geo_name_gap_error")
})

test_that("the Stage 3 safety net surfaces verbatim labels on an unknown roster", {
  # a doctored `ents` (the Stage 1 accessor object) whose slot directory carries an
  # unknown roster: a member-length NAME run, a matching CODE run, an ordinal run
  # (must be skipped), and a too-short block (must be ignored). No specializer would
  # recognize this, so the dispatcher's last resort recovers it verbatim.
  names_run <- c("Canada", "Ontario", "Quebec", "Nunavut")
  codes_run <- c("01", "35", "24", "62")
  blocks <- list(names_run, codes_run, as.character(1:4), c("x", "y"))
  ents <- list(
    n = length(blocks),
    values = function(r) blocks[[r]],
    strict = function(r) list(values = blocks[[r]], dense = FALSE)
  )
  g <- expect_warning(ivt_f2_geo_combined(raw(0), ents, 4L), class = "canivt_geo_unparsed")
  expect_warning(ivt_f2_geo_combined(raw(0), ents, 4L), class = "canivt_fallback")
  g <- suppressWarnings(ivt_f2_geo_combined(raw(0), ents, 4L))
  expect_identical(g$geo_name, names_run)   # verbatim, most name-like run
  expect_identical(g$geo_label, names_run)
  expect_identical(g$geo_uid, codes_run)    # the all-code run becomes the uid
  # nothing member-length -> NULL (the uid-only read stands), and no false warning
  short <- list(n = 1L, values = function(r) c("a", "b"),
                strict = function(r) NULL)
  expect_no_warning(expect_null(ivt_f2_geo_combined(raw(0), short, 4L)))
  # strict mode upgrades the recovery to a hard error
  withr::local_options(canivt.strict = TRUE)
  expect_error(ivt_f2_geo_combined(raw(0), ents, 4L), class = "canivt_geo_unparsed_error")
})

test_that("Stage 3 deciphers name/uid and picks the display over the code run", {
  # a mixed display run (named + bare-code members, like EO2654's EAs) beside a
  # uniform type-tagged uid: the display must win as the name, the code as the uid.
  disp <- c("Vancouver (933)", "59150004", "59150005", "Surrey (915)")
  cu   <- c("CU0001", "CU0002", "CU0003", "CU0004")
  ents <- list(n = 2L, values = function(r) list(disp, cu)[[r]],
               strict = function(r) list(values = list(disp, cu)[[r]], dense = FALSE))
  g <- suppressWarnings(ivt_f2_geo_combined(raw(0), ents, 4L))
  expect_identical(g$geo_name, disp)        # the mixed display run, not the CU codes
  expect_identical(g$geo_uid, cu)           # the uniform digit-bearing code = uid
})

test_that("Stage 3 recognizes an EN/FR display pair", {
  en <- c("Canada", "New Brunswick", "Quebec", "Ontario")
  fr <- c("Canada", "Nouveau-Brunswick", "Quebec", "Ontario")
  code <- c("01", "13", "24", "35")
  ents <- list(n = 3L, values = function(r) list(en, fr, code)[[r]],
               strict = function(r) list(values = list(en, fr, code)[[r]], dense = FALSE))
  g <- suppressWarnings(ivt_f2_geo_combined(raw(0), ents, 4L))
  expect_identical(g$geo_name, en)          # English copy by frscore
  expect_identical(g$geo_name_fr, fr)
  expect_identical(g$geo_uid, code)
})

test_that("Stage 3 surfaces the run verbatim when no display column exists", {
  # a single opaque code run and nothing else: there is no separate display column
  # to name, so the recovered member string is surfaced as both label and name.
  only <- c("A01", "B02", "C03", "D04")
  ents <- list(n = 1L, values = function(r) only,
               strict = function(r) list(values = only, dense = FALSE))
  g <- suppressWarnings(ivt_f2_geo_combined(raw(0), ents, 4L))
  expect_identical(g$geo_label, only)
  expect_identical(g$geo_name, only)
})

test_that("DQF_NOTE truncation is detected at the container's record ceiling", {
  # a note stored at the 252-char (0xFC) single-byte record ceiling is presumed
  # truncated; shorter notes are complete; NA propagates as NA (no note at all)
  note <- c(strrep("x", 252L), "short", NA_character_, strrep("y", 251L))
  expect_equal(ivt_f2_dqf_note_truncated(note), c(TRUE, FALSE, NA, FALSE))
  expect_null(ivt_f2_dqf_note_truncated(NULL))
})

test_that("truncation flag rides beside dqf_note and warns loudly, faithfully", {
  # no dqf_note -> untouched, no flag, no warning (most tables / the uid-only path)
  g0 <- list(member_id = 1:3, geo_uid = c("a", "b", "c"))
  expect_no_warning(g0b <- ivt_f2_flag_dqf_note_truncation(g0))
  expect_identical(g0b, g0)

  # dqf_note present but none at the ceiling -> flag added (all FALSE), no warning
  clean <- list(member_id = 1:2, dqf_note = c("ok", "also ok"))
  expect_no_warning(gc <- ivt_f2_flag_dqf_note_truncation(clean))
  expect_equal(gc$dqf_note_truncated, c(FALSE, FALSE))

  # a truncated note -> flag marks it AND a classed notice fires
  dirty <- list(member_id = 1:2, dqf_note = c(strrep("z", 252L), "ok"))
  expect_warning(gd <- ivt_f2_flag_dqf_note_truncation(dirty),
                 class = "canivt_dqf_note_truncated")
  expect_warning(ivt_f2_flag_dqf_note_truncation(dirty),
                 class = "canivt_source_truncation")
  expect_equal(suppressWarnings(ivt_f2_flag_dqf_note_truncation(dirty))$dqf_note_truncated,
               c(TRUE, FALSE))
})

test_that("source truncation is a faithful read, NOT upgraded by strict mode", {
  # unlike a heuristic fallback, a container-truncated value is exactly what the
  # file holds, so strict mode leaves it a warning (it refuses risky reads, and
  # there is nothing risky here) -- a strict pipeline reading geo_attributes on
  # 98-10-0129 must not error on its 2,448 truncated notes.
  dirty <- list(dqf_note = strrep("z", 252L))
  withr::local_options(canivt.strict = TRUE)
  expect_no_error(expect_warning(ivt_f2_flag_dqf_note_truncation(dirty),
                                 class = "canivt_dqf_note_truncated"))
})

test_that("ivt_quietly muffles fallback conditions for detection probes", {
  expect_no_warning(v <- ivt_quietly({ ivt_fallback("probe"); 42L }))
  expect_equal(v, 42L)
  # under strict mode the refused fallback reads as "not found", not an error
  withr::local_options(canivt.strict = TRUE)
  expect_no_error(v2 <- ivt_quietly({ ivt_fallback("probe"); 42L }))
  expect_null(v2)
})

test_that("ivt_offline_grace turns a canivt_offline error into a NULL + warning", {
  # network access raises a classed canivt_offline error; the exported entry
  # points wrap their body in ivt_offline_grace() so an offline run degrades to
  # an informative warning + invisible(NULL) instead of aborting an R CMD check.
  expect_warning(
    r <- ivt_offline_grace(ivt_offline_abort("https://example.invalid/x")),
    class = "canivt_offline_warning")
  expect_null(r)
})

test_that("ivt_offline_grace lets non-connection errors propagate", {
  # only the connection failure is caught; a genuine bug/usage error must surface
  expect_error(ivt_offline_grace(stop("boom")), "boom")
  expect_equal(ivt_offline_grace(41L + 1L), 42L)
})
