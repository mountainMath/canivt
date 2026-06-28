# Integration tests against a real sample IVT. The .ivt files are large and not
# shipped with the package; point CANIVT_SAMPLE_IVT at a copy of 98100241.ivt
# (StatCan table 98-10-0241) to run these. They skip otherwise.
sample_ivt <- function() {
  p <- Sys.getenv("CANIVT_SAMPLE_IVT", "")
  if (nzchar(p) && file.exists(p)) return(p)
  # fall back to the sibling reverse-engineering repo, if present
  guess <- "~/projects/censusmapper-import/data/raw/98100241/98100241.ivt"
  guess <- path.expand(guess)
  if (file.exists(guess)) return(guess)
  ""
}

test_that("codebook parses identity, members and geo DGUIDs", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  m <- ivt_metadata(p)
  expect_equal(m$product_id, "98100241")
  expect_equal(length(m$geographies$name), 166L)
  expect_equal(m$geographies$name[1], "Canada")
  expect_equal(m$geographies$dguid[1], "2021A000011124")
  expect_equal(m$geographies$dguid[166], "2021A000262")
  expect_true(all(nzchar(m$geographies$dguid)))
  counts <- vapply(m$dimensions, function(d) length(d$members), 1L)
  expect_equal(counts, c(166L, 9L, 16L, 13L, 3L, 6L, 7L))
})

test_that("footnotes are extracted in both languages", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  m <- ivt_metadata(p)
  langs <- vapply(m$footnotes, function(f) f$language, "")
  expect_equal(sum(langs == "en"), 10L)
  expect_equal(sum(langs == "fr"), 10L)
  en <- vapply(m$footnotes[langs == "en"], function(f) f$text, "")
  # whole footnote bodies are captured (one maximal text run each), incl. a long
  # multi-paragraph one and a short one-liner
  expect_true(any(grepl("^Includes data up to May 11, 2021\\.$", en)))
  expect_true(any(grepl("Dwelling condition.*Housing suitability", en)))
  expect_true(all(nchar(en) > 0L))
})

test_that("Canada decodes to the published tenure totals", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  tab <- read_ivt(p)
  expect_equal(nrow(tab$cells), 7489464L)
  td <- ivt_tidy(tab)
  row <- td[td$dguid == "2021A000011124" &
    td$age == "Total - Age of primary household maintainer" &
    td$household_type ==
      "Total - Household type including census family structure" &
    td$period_of_construction == "Total - Period of construction" &
    td$statistic == "Number of private households" &
    td$housing_indicator == "Total - Housing indicators", ]
  expect_equal(row$value,
               c(14687350L, 9787420L, 5870875L, 3916550L, 4899925L,
                 576625L, 4323300L))
})
