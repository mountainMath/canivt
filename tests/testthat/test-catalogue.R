# Offline tests for the catalogue scraper / URL resolution. The live-site
# functions (statcan_ivt_years, statcan_ivt_catalogue, get_statcan_ivt over the
# network) are exercised manually; here we test the parsing + URL logic against
# a fixture so no network is needed.

test_that("ivt_abs_url resolves relative and site-absolute hrefs", {
  expect_equal(ivt_abs_url("Alternative.cfm?PID=1&EXT=IVT"),
               "https://www12.statcan.gc.ca/datasets/Alternative.cfm?PID=1&EXT=IVT")
  expect_equal(ivt_abs_url("/global/URLRedirect.cfm?ips=X"),
               "https://www12.statcan.gc.ca/global/URLRedirect.cfm?ips=X")
  expect_equal(ivt_abs_url("https://x.test/a.zip"), "https://x.test/a.zip")
  expect_true(is.na(ivt_abs_url(NA_character_)))
})

test_that("statcan_ivt_resolve_url forwards Alternative.cfm to Download.cfm", {
  expect_equal(
    statcan_ivt_resolve_url("Alternative.cfm?PID=55701&EXT=IVT"),
    "https://www12.statcan.gc.ca/datasets/Download.cfm?PID=55701")
  # a direct b2020 zip is returned unchanged
  z <- "https://www150.statcan.gc.ca/n1/en/tbl/b2020/98100241.zip"
  expect_equal(statcan_ivt_resolve_url(z), z)
})

test_that("ivt_extract_pid pulls the numeric PID or NA", {
  expect_equal(ivt_extract_pid("Download.cfm?PID=55701"), "55701")
  expect_true(is.na(ivt_extract_pid("b2020/98100241.zip")))
})

test_that("catalogue key/normalisation helpers", {
  expect_equal(ivt_catalogue_norm("98-10-0241-01"), "9810024101")
  expect_equal(ivt_catalogue_key("98-10-0241-01"), "98-10-0241-01")
  expect_equal(ivt_catalogue_key("a/b c"), "a_b_c")
})

test_that("ivt_parse_index_row + year selector parse the fixture", {
  skip_if_not_installed("rvest")
  skip_if_not_installed("xml2")
  doc <- xml2::read_html(test_path("fixtures", "index-sample.html"))

  opts <- rvest::html_elements(doc, "select#Temporal option")
  expect_equal(rvest::html_attr(opts, "value"), c("2021", "2017", "2001"))

  rows <- rvest::html_elements(doc, "table.wb-tables tbody tr")
  expect_length(rows, 3L)

  r1 <- ivt_parse_index_row(rows[[1]])
  expect_equal(r1$catalogue, "95F0436XCB2001003")
  expect_true(r1$archived)
  expect_equal(r1$title, "2000 Family Income (4) and Family Structure (2)")
  expect_equal(r1$pid, "55701")
  expect_equal(r1$download_url,
               "https://www12.statcan.gc.ca/datasets/Download.cfm?PID=55701")
  expect_match(r1$http_url, "URLRedirect.cfm")

  r2 <- ivt_parse_index_row(rows[[2]])
  expect_equal(r2$catalogue, "98-10-0241-01")
  expect_false(r2$archived)
  expect_true(is.na(r2$pid))
  expect_match(r2$download_url, "b2020/98100241\\.zip$")

  # third product has no IVT link -> dropped
  expect_null(ivt_parse_index_row(rows[[3]]))
})

test_that("a stale cached catalogue warns once per session", {
  skip_if_not_installed("arrow")
  cache <- withr::local_tempdir()
  withr::local_options(canivt.data_cache = cache)
  .ivt_session$catalogue_stale_warned <- NULL
  withr::defer(.ivt_session$catalogue_stale_warned <- NULL)

  cache_file <- file.path(cache, "statcan_ivt_catalogue.parquet")
  arrow::write_parquet(tibble::tibble(temporal = "2021", catalogue = "x"),
                       cache_file)

  # fresh cache: no warning
  expect_no_warning(statcan_ivt_catalogue())

  # backdate the cache beyond the staleness threshold
  Sys.setFileTime(cache_file, Sys.time() - as.difftime(45, units = "days"))
  expect_warning(statcan_ivt_catalogue(), "catalogue is .* days old")
  # second call in the same session is silent
  expect_no_warning(statcan_ivt_catalogue())
})

test_that("ivt_find_cached_ivt locates a deposited custom file", {
  cache <- withr::local_tempdir()
  withr::local_options(canivt.ivt_cache = cache)
  expect_true(is.na(ivt_find_cached_ivt("mytable")))

  f <- file.path(cache, "mytable.ivt")
  writeBin(as.raw(c(4, 0, 32, 0)), f)
  expect_equal(normalizePath(ivt_find_cached_ivt("mytable")), normalizePath(f))

  # also found in a per-id subfolder, case-insensitively
  sub <- file.path(cache, "Other")
  dir.create(sub)
  g <- file.path(sub, "x.IVT"); writeBin(as.raw(c(4, 0, 32, 0)), g)
  expect_equal(normalizePath(ivt_find_cached_ivt("Other")), normalizePath(g))
})
