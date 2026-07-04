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
  # --- share the signature but are NOT a supported format ------------------
  list(id = "97F0015X",          file = "97F0015X.ivt",          family = NA),
  list(id = "97-570-X1981002",   file = "97-570-X1981002.IVT",   family = NA),
  list(id = "cro0172986_ct7_2006", file = "cro0172986_ct.7-2006-population.ivt",       family = NA),
  list(id = "cro0172986_ct8_2006", file = "cro0172986_ct.8-2006_private-households.ivt", family = NA),
  list(id = "ord-08035_ct1_2021",  file = "ord-08035-q7v4p7_ct.1-2021-population_updated.ivt", family = NA)
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
