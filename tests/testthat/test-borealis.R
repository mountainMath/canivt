# Offline tests for the Borealis catalogue tidy/keying + resolution logic. The
# live search (borealis_ivt_catalogue over the network, requiring the API key)
# and downloads are exercised manually; here we test the pure logic against a
# small synthetic set of raw search rows so no network / key is needed.

# A minimal stand-in for dataverse_search()'s raw `items` data frame, covering
# the tricky cases: a stray non-.ivt hit, a blank name, the same filename in two
# datasets with DIFFERENT content, a byte-identical duplicate, and a non-Borealis
# (10.7939) DOI shoulder.
borealis_raw_fixture <- function() {
  data.frame(
    name = c("94-575-XCB2006001.IVT", "CD1T29M3.IVT", "CD1T29M3.IVT",
             "dup.ivt", "dup.ivt", "notes.csv", ""),
    file_id = c("11", "12", "13", "14", "15", "16", "17"),
    url = paste0("https://borealisdata.ca/api/access/datafile/", 11:17),
    size_in_bytes = c(1000, 2000, 2100, 500, 500, 9, 42),
    md5 = c("aaa", "bbb", "ccc", "ddd", "ddd", "eee", "fff"),
    published_at = "2024-01-01T00:00:00Z",
    file_type = "Beyond 20/20",
    dataset_name = c("Census 2006", "LFHR 2000", "LFHR 2001",
                     "Set A (EN)", "Set A (FR)", "Docs", "Orphan"),
    dataset_persistent_id = c("doi:10.5683/SP3/RFXZIF", "doi:10.5683/SP3/6DGOTF",
                              "doi:10.5683/SP3/ILZGFJ", "doi:10.5683/SP3/DUPSET",
                              "doi:10.5683/SP3/DUPSET", "doi:10.5683/SP3/DOCS00",
                              "doi:10.7939/DVN/10512"),
    stringsAsFactors = FALSE
  )
}

test_that("borealis_token strips the doi: scheme and Borealis shoulder", {
  expect_equal(borealis_token("10.5683/SP3/6DGOTF"), "SP3/6DGOTF")
  # non-Borealis DOIs keep their full shoulder (stay unambiguous)
  expect_equal(borealis_token("10.7939/DVN/10512"), "10.7939/DVN/10512")
})

test_that("borealis_tidy_catalogue filters to .ivt and builds DOI-qualified keys", {
  catl <- borealis_tidy_catalogue(borealis_raw_fixture())
  # the .csv is dropped; the blank name becomes <file_id>.ivt and is kept
  expect_false(any(grepl("\\.csv$", catl$file)))
  expect_true("17.ivt" %in% catl$file)
  expect_equal(nrow(catl), 6L)
  expect_equal(catl$key[catl$file_id == "11"], "SP3/RFXZIF/94-575-XCB2006001")
  expect_equal(catl$key[catl$file_id == "12"], "SP3/6DGOTF/CD1T29M3")
  # download_url comes straight off the search `url`
  expect_equal(catl$download_url[catl$file_id == "12"],
               "https://borealisdata.ca/api/access/datafile/12")
})

test_that("ivt_lookup_borealis resolves by key, file_id and unambiguous stem", {
  catl <- borealis_tidy_catalogue(borealis_raw_fixture())
  local_mocked_bindings(borealis_ivt_catalogue = function(...) catl)

  # DOI-qualified key
  expect_equal(ivt_lookup_borealis("SP3/6DGOTF/CD1T29M3")$file_id, "12")
  # bare file_id
  expect_equal(ivt_lookup_borealis("13")$file_id, "13")
  # unambiguous filename stem
  expect_equal(ivt_lookup_borealis("94-575-XCB2006001")$file_id, "11")
  # nothing matches -> NULL
  expect_null(ivt_lookup_borealis("does-not-exist"))
})

test_that("ivt_lookup_borealis errors on genuinely-ambiguous names, collapses identical dupes", {
  catl <- borealis_tidy_catalogue(borealis_raw_fixture())
  local_mocked_bindings(borealis_ivt_catalogue = function(...) catl)

  # CD1T29M3 is two DIFFERENT files (distinct md5) -> ambiguous, abort
  expect_error(ivt_lookup_borealis("CD1T29M3"), "different datasets")
  # dup.ivt is two byte-identical copies (same md5) -> pick one silently
  expect_equal(ivt_lookup_borealis("dup")$file_stem, "dup")
})

test_that("catalogue rows are accepted as input (id/key derivation + source routing)", {
  catl <- borealis_tidy_catalogue(borealis_raw_fixture())
  brow <- catl[catl$file_id == "12", , drop = FALSE]
  srow <- tibble::tibble(catalogue = "98-10-0241-01",
                         download_url = "https://x.test/98100241.zip")

  # a Borealis row is detected and yields its DOI key; a StatCan row its number
  expect_true(ivt_row_is_borealis(brow))
  expect_false(ivt_row_is_borealis(srow))
  expect_equal(ivt_input_id(brow), "SP3/6DGOTF/CD1T29M3")
  expect_equal(ivt_input_id(srow), "98-10-0241-01")
  expect_equal(ivt_input_id("CD1T29M3"), "CD1T29M3")   # plain string passes through

  # ivt_row_source routes to the right source + a working download closure
  expect_equal(ivt_row_source(brow)$source, "borealis")
  expect_equal(ivt_row_source(srow)$source, "statcan")
  # a foreign data frame is rejected
  expect_error(ivt_row_source(tibble::tibble(x = 1)), "Unrecognised catalogue row")
})
