# Format coverage: every .ivt in the test corpus (the IVT cache) is classified
# correctly. Decodable tables are detected as their family and read their
# metadata; other Beyond 20/20 products that merely share the `04 00 20 00`
# signature (the "F"-series, the 1981 census, custom CT extracts) are rejected
# cleanly rather than crashing the decoder. Each case skips if its file is not in
# the cache, so this runs locally (with the corpus) and skips in CI.

# id = cache subfolder, file = filename within it.
ivt_corpus <- list(
  # --- decodable -----------------------------------------------------------
  list(id = "98100241", file = "98100241.ivt", family = 1L,
       n_geo = 166L),
  list(id = "98100023", file = "98100023.ivt", family = 2L,
       dims = c(63404L, 128L, 3L)),
  list(id = "98100129", file = "98100129.ivt", family = 2L,
       dims = c(63404L, 3L, 13L, 16L)),
  list(id = "1003011",  file = "1003011.IVT",  family = 2L,
       dims = c(41859L, 110L, 3L)),
  # 2006 DA crosstab: the b3 = 0x0a/0x0c head-block vintage (b3 encodes a
  # 32*(b3-8)-byte auxiliary head before the value run; suppression-mask tail
  # records after it). Viewer-validated cell-exact.
  list(id = "97-563-XCB2006072", file = "97-563-XCB2006072.IVT", family = 2L,
       dims = c(57523L, 5L, 9L, 3L)),
  # 2016203: unlocked by the u16 width tag on descriptor type 0x0a -- its
  # "Selected characteristics" dimension is 825 members (the low byte alone
  # read 57, which mis-nested the layout and made the b2 == 0 pages look
  # non-exact-fit). Viewer-validated cell-exact incl. the chunked 825-member
  # label read (256+256+256+57, dense trailing block).
  list(id = "98-400-X2016203", file = "98-400-X2016203.IVT", family = 1L,
       dims = c(51L, 47L, 11L, 7L, 825L, 3L)),
  # 1981 profile: descriptor order Values(1) x Profile(79) x Geography(5989) --
  # geography is the LAST descriptor dimension (ivt_f2_geo_dim_index resolves
  # it from the codebook) and straddles the presence record (3 windows);
  # "Values" is a 1-member placeholder whose count byte reads 32 unless
  # reconciled against its member block. Viewer-validated cell-exact.
  list(id = "97-570-X1981004", file = "97-570-X1981004.ivt", family = 2L,
       dims = c(1L, 79L, 5989L)),
  # 1991 profiles: Values(1) x Profile(529) x Geography, geography-LAST and
  # straddling (2/3 windows of 2048); their page set is a dense/sparse HYBRID --
  # the `0x0_` dense pages are `[b0][01][u16 count]` + one value per grid
  # position (zeros stored literally, count zero-padded past the window).
  # Viewer-validated cell-exact (22 and 20 geographies x all 529 characteristics,
  # incl. every window boundary and the re-sorted Ottawa-Hull block).
  list(id = "98F0172X", file = "98F0172X.ivt", family = 2L,
       dims = c(1L, 529L, 4063L)),
  list(id = "95F0170X", file = "95F0170X.IVT", family = 2L,
       dims = c(1L, 529L, 5602L)),
  # 2001 F-series crosstab: unlocked by the u16 width tag on descriptor type
  # 0x09 -- its "Selected characteristics" dimension is 282 members (the low
  # byte alone read 1, which mis-nested the layout and made the pages carry
  # more presence bits than the layout's cell capacity, so the pre-flight
  # rejected it). Viewer-validated cell-exact (34,968/34,968 over all 14
  # geographies and every Number x Earning fixed-dim slice). The same 0x09
  # fix corrected 98-10-0174's silently mis-decoded Mother tongue(331).
  list(id = "97F0020XCB2001070", file = "97F0020XCB2001070.IVT", family = 1L,
       dims = c(14L, 2L, 8L, 282L, 2L)),
  # Custom-order Beyond 20/20 exports (2021 "ord", 2006 "cro"): the ONLY
  # structural difference from the standard tables is that the header `@32`
  # descriptor pointer targets the identity/title block, not the descriptor --
  # which `ivt_f2_descriptor_offset()` now relocates via the master directory
  # (confirmed by the invariant `81 01 20 00 f0 .. .. 80 03` signature). The
  # geography-straddle layout, page markers and cell decode are all standard.
  # ord-08035 is Geography(791) x Selected characteristics(79) x Tenure(4) for
  # BC CDs/CSDs; internal-consistency validated (Canada/BC total pop 4,915,940
  # in private households; tenure Total == Owner + Renter + Band across counts,
  # differing only by random rounding +/-10). Data-dim member labels come from
  # its plaintext "Variables:" enumeration (no binary member codebook), and
  # geography names from the inline combined block (789/791; two alternate-name
  # entries stay uid-only). The 2006 cro crosstabs decode cells + dimensions the
  # same way (owner+renter=total holds); their pre-DGUID geography combined
  # block is not yet located (geo_name empty), so n_geo is not asserted.
  list(id = "ord-08035_ct1_2021",  file = "ord-08035-q7v4p7_ct.1-2021-population_updated.ivt",
       family = 2L, dims = c(791L, 79L, 4L), n_geo = 791L),
  list(id = "cro0172986_ct7_2006", file = "cro0172986_ct.7-2006-population.ivt",
       family = 2L, dims = c(581L, 4L, 79L)),
  list(id = "cro0172986_ct8_2006", file = "cro0172986_ct.8-2006_private-households.ivt",
       family = 2L, dims = c(581L, 5L, 87L)),
  # INVERTED descriptor layout (records BEFORE the `81 01 20 00 f0` signature
  # block, anchored after the `81 02 03 00` sub-header; the signature block is
  # followed by the identity/title text instead): the 1981 CMA/CA profile
  # Part A and the tiny 2016 collective-dwellings crosstab. Both viewer-
  # validated cell-exact (1981002: 1,920/1,920 over 24 geographies incl.
  # members 60/100/119/120; 2016019: all 448/448 cells).
  list(id = "97-570-X1981002",   file = "97-570-X1981002.IVT",   family = 1L,
       dims = c(1L, 80L, 120L), n_geo = 120L),
  list(id = "98400X2016019",     file = "98400X2016019.ivt",     family = 2L,
       dims = c(14L, 16L, 2L), n_geo = 14L),
  # 2001 F-series 97F0015X: its descriptor bleeds French description prose INTO
  # and BETWEEN the two name copies of each dimension record ("Total Income
  # GrTotal Income Groups (12). ; Dans tous les ..."; "Sex (3)atif totSex (3)
  # et les ..."). The names are recovered by anchoring on the framing count --
  # each data-dim name ends in "(count)" -- and the geography name by the
  # longest reoccurring prefix ("Geographyle nomGeography..." -> "Geography").
  # Viewer-validated cell-exact: 864/864 over Canada across all four data dims
  # (5 fixed sex/age slices) + 1,080/1,080 over 29 further geographies; all
  # 4,432 geographies named. Strict-clean.
  list(id = "97F0015X",          file = "97F0015X.ivt",          family = 1L,
       dims = c(4432L, 3L, 7L, 12L, 9L), n_geo = 4432L)
)

for (case in ivt_corpus) {
  local({
    cc <- case
    label <- if (is.na(cc$family)) "is rejected cleanly (unsupported)"
             else sprintf("is detected as family %d and reads metadata", cc$family)
    test_that(sprintf("%s %s", cc$id, label), {
      p <- locate_sample_ivt("", cc$id, cc$file)
      skip_if(p == "", sprintf("no corpus file %s (not in IVT cache)", cc$id))
      raw <- readBin(p, "raw", n = file.info(p)$size)

      if (is.na(cc$family)) {
        expect_false(ivt_is_supported(raw))
        expect_true(is.na(ivt_family(raw)))
        # both entry points fail gracefully with an informative message,
        # never the raw "argument of length 0" crash.
        expect_error(read_ivt(p), "[Uu]nsupported|unrecognised")
        expect_error(ivt_metadata(p), "[Uu]nsupported|unrecognised")
      } else {
        expect_true(ivt_is_supported(raw))
        expect_equal(ivt_family(raw), cc$family)
        m <- ivt_metadata(p)
        if (!is.null(cc$dims)) {
          expect_equal(unname(m$dimension_counts), cc$dims)
        }
        if (!is.null(cc$n_geo)) {
          expect_equal(length(m$geographies$geo_name), cc$n_geo)
        }
      }
    })
  })
}

# Every real corpus file is now supported, so exercise the rejection path with a
# synthetic input: the `04 00 20 00` signature but a garbage descriptor region
# (no recoverable dimension records). `ivt_f2_decodable()` must reject it and the
# public entry points must fail with an informative message, never the raw
# "argument of length 0" crash.
test_that("a signature-only file with no decodable descriptor is rejected cleanly", {
  raw <- as.raw(rep(0L, 4096L))
  raw[1:4] <- as.raw(c(0x04, 0x00, 0x20, 0x00))
  expect_false(ivt_is_supported(raw))
  expect_true(is.na(ivt_family(raw)))
})

# ---- the descriptor record as a count oracle (markers.md D.1) ----------------
#
# A rebuilt descriptor sizes each dimension from its CODEBOOK member array, which
# chunks at 256 -- so a >256-member dimension reads back as exactly 256. The
# record itself is still present and correct; `ivt_f2_desc_declared_count()`
# re-finds it by NAME. Synthetic bytes: no corpus needed.

# lay a descriptor signature at `at`, then one record `[u16 count][type][01]<name>`
fmt_desc_raw <- function(count, type, name, at = 1024L, size = 8192L,
                         sep = 0x01L, prefix = character(0)) {
  raw <- as.raw(rep(0L, size))
  raw[1:4] <- as.raw(c(0x04, 0x00, 0x20, 0x00))
  # the @32 descriptor pointer, so the offset resolves on the primary path
  # (without it `ivt_f2_descriptor_offset()` falls back to the signature scan
  # and warns -- correct behaviour, just noise for these cases)
  raw[33:36] <- as.raw(c(at %% 256L, (at %/% 256L) %% 256L,
                         (at %/% 65536L) %% 256L, at %/% 16777216L))
  raw[at + (1:9)] <- as.raw(c(0x81, 0x01, 0x20, 0x00, 0xf0, 0x00, 0x00, 0x80, 0x03))
  p <- at + 10L
  for (s in prefix) {                      # extra records laid down first
    body <- c(s$count %% 256L, s$count %/% 256L, s$type, 0x01L,
              utf8ToInt(s$name))
    raw[p + seq_along(body)] <- as.raw(body); p <- p + length(body) + 4L
  }
  body <- c(count %% 256L, count %/% 256L, type, sep, utf8ToInt(name))
  raw[p + seq_along(body)] <- as.raw(body)
  raw
}

test_that("a named descriptor record yields its declared u16 count", {
  raw <- fmt_desc_raw(53488L, 0x10L, "Geography")
  expect_identical(ivt_f2_desc_declared_count(raw, "Geography"), 53488L)
})

test_that("the count oracle declines what it cannot resolve", {
  raw <- fmt_desc_raw(53488L, 0x10L, "Geography")
  # a name that is not framed as a record
  expect_true(is.na(ivt_f2_desc_declared_count(raw, "Tenure")))
  # NULL / NA / empty names (ivt_f2_first_marker_name may hand back any of them)
  expect_true(is.na(ivt_f2_desc_declared_count(raw, NULL)))
  expect_true(is.na(ivt_f2_desc_declared_count(raw, NA_character_)))
  expect_true(is.na(ivt_f2_desc_declared_count(raw, "")))
  # a u8-COUNT storage tag cannot undercount a 256-chunk read, so it is ignored
  expect_true(is.na(ivt_f2_desc_declared_count(fmt_desc_raw(300L, 0x08L, "Geography"),
                                               "Geography")))
  # the 0x01 record separator is required
  expect_true(is.na(ivt_f2_desc_declared_count(
    fmt_desc_raw(53488L, 0x10L, "Geography", sep = 0x02L), "Geography")))
})

test_that("the count oracle refuses a name that resolves to two different counts", {
  raw <- fmt_desc_raw(53488L, 0x10L, "Geography",
                      prefix = list(list(count = 999L, type = 0x10L, name = "Geography")))
  expect_true(is.na(ivt_f2_desc_declared_count(raw, "Geography")))
  # ... but agreeing duplicates are fine
  raw2 <- fmt_desc_raw(53488L, 0x10L, "Geography",
                       prefix = list(list(count = 53488L, type = 0x10L, name = "Geography")))
  expect_identical(ivt_f2_desc_declared_count(raw2, "Geography"), 53488L)
})

# ---- ordinal runs are bounded by the member count ---------------------------
test_that("consecutive member CODES are not mistaken for an ordinal delimiter", {
  # a genuine ordinal delimiter: positions within the member list
  expect_true(ivt_f2_is_ordinal(c(1, 2, 3, 4), n = 100L))
  expect_true(ivt_f2_is_ordinal(c(2049, 2050, 2051), n = 4096L))
  # 2001 census DA codes: consecutive, but far beyond the member count
  expect_false(ivt_f2_is_ordinal(c(35210433, 35210434, 35210435), n = 53488L))
  # unbounded callers keep the old behaviour
  expect_true(ivt_f2_is_ordinal(c(35210433, 35210434, 35210435)))
  expect_true(ivt_f2_is_ordinal(c(35210433, 35210434, 35210435), n = NA_integer_))
  # non-consecutive is never ordinal, bound or no bound
  expect_false(ivt_f2_is_ordinal(c(1, 2, 4), n = 100L))
  expect_false(ivt_f2_is_ordinal(c(1, 2), n = 100L))
})
