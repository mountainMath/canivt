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
  # --- share the signature but are NOT a supported format ------------------
  list(id = "95F0170X",          file = "95F0170X.IVT",          family = NA),
  list(id = "97F0015X",          file = "97F0015X.ivt",          family = NA),
  list(id = "97F0020XCB2001070", file = "97F0020XCB2001070.IVT", family = NA),
  list(id = "97-570-X1981002",   file = "97-570-X1981002.IVT",   family = NA),
  list(id = "98F0172X",          file = "98F0172X.ivt",          family = NA),
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
          expect_equal(length(m$geographies$name), cc$n_geo)
        }
      }
    })
  })
}
