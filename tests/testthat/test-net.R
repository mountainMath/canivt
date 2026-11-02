# Offline tests for the network transport (net.R): which route a request takes
# and how a refusal is reported. The live routes (safeconduct / download.file
# against StatCan) are exercised manually.

test_that("ivt_url_host / ivt_host_needs_browser pick out the challenged host", {
  expect_equal(ivt_url_host("https://www12.statcan.gc.ca/datasets/Index-eng.cfm?Temporal=2021"),
               "www12.statcan.gc.ca")
  expect_equal(ivt_url_host("https://WWW150.statcan.gc.ca/n1/en/tbl/b2020/x.zip"),
               "www150.statcan.gc.ca")
  expect_true(ivt_host_needs_browser("https://www12.statcan.gc.ca/datasets/Download.cfm?PID=1"))
  expect_false(ivt_host_needs_browser("https://www150.statcan.gc.ca/n1/en/tbl/b2020/x.zip"))
  expect_false(ivt_host_needs_browser("https://borealisdata.ca/api/access/datafile/1"))
})

test_that("the install hint is given only for a challenged host without safeconduct", {
  local_mocked_bindings(ivt_has_safeconduct = function() FALSE)
  h <- ivt_net_hint("https://www12.statcan.gc.ca/datasets/Download.cfm?PID=1")
  expect_match(h, "safeconduct")
  expect_null(ivt_net_hint("https://www150.statcan.gc.ca/n1/en/tbl/b2020/x.zip"))

  local_mocked_bindings(ivt_has_safeconduct = function() TRUE)
  expect_null(ivt_net_hint("https://www12.statcan.gc.ca/datasets/Download.cfm?PID=1"))
})

test_that("ivt_offline_abort carries the hint into the canivt_offline message", {
  cnd <- tryCatch(
    ivt_offline_abort("https://x.test/y", hint = c(i = "install it")),
    canivt_offline = function(e) e)
  expect_s3_class(cnd, "canivt_offline")
  expect_match(paste(cli::ansi_strip(conditionMessage(cnd)), collapse = "\n"), "install it")
})

test_that("ivt_fetch_file without safeconduct raises canivt_offline on an unreachable host", {
  local_mocked_bindings(ivt_has_safeconduct = function() FALSE)
  dest <- withr::local_tempfile(fileext = ".bin")
  expect_error(ivt_fetch_file("https://example.invalid/x.zip", dest, quiet = TRUE),
               class = "canivt_offline")
  expect_false(file.exists(dest))
})

test_that("ivt_fetch_file routes through safeconduct when installed and no headers are set", {
  skip_if_not_installed("safeconduct")
  seen <- list()
  local_mocked_bindings(ivt_has_safeconduct = function() TRUE,
                        ivt_browser_session = function(url) "kept-browser")
  local_mocked_bindings(
    fetch = function(url, destfile, quiet = FALSE, session = NULL, ...) {
      seen$url <<- url; seen$session <<- session
      writeBin(as.raw(1:4), destfile); invisible(destfile)
    },
    .package = "safeconduct")
  dest <- withr::local_tempfile(fileext = ".bin")
  ivt_fetch_file("https://www12.statcan.gc.ca/datasets/Download.cfm?PID=1", dest, quiet = TRUE)
  expect_equal(seen$url, "https://www12.statcan.gc.ca/datasets/Download.cfm?PID=1")
  expect_equal(seen$session, "kept-browser")   # the host's kept browser is passed
  expect_true(file.exists(dest))

  # a safeconduct failure is a canivt_offline error, with the cause attached
  local_mocked_bindings(
    fetch = function(url, destfile, ...) stop("blocked", call. = FALSE),
    .package = "safeconduct")
  dest2 <- withr::local_tempfile(fileext = ".bin")
  expect_error(ivt_fetch_file("https://www12.statcan.gc.ca/x", dest2, quiet = TRUE),
               class = "canivt_offline")

  # custom headers never go through safeconduct
  local_mocked_bindings(
    fetch = function(...) stop("must not be called"), .package = "safeconduct")
  dest3 <- withr::local_tempfile(fileext = ".bin")
  expect_error(
    ivt_fetch_file("https://example.invalid/x", dest3, quiet = TRUE,
                   headers = c("X-Dataverse-key" = "k")),
    class = "canivt_offline")
})

test_that("ivt_fetch_html reads through the kept browser and parses with page_html", {
  skip_if_not_installed("safeconduct")
  skip_if_not_installed("xml2")
  seen <- list()
  local_mocked_bindings(ivt_has_safeconduct = function() TRUE,
                        ivt_browser_session = function(url) "kept-browser")
  local_mocked_bindings(
    read_page = function(url, session = NULL, ...) {
      seen$session <<- session
      list(url = url, status_code = 200L, content = charToRaw("<html><body><p>hi</p></body></html>"))
    },
    page_html = function(resp, ...) xml2::read_html(rawToChar(resp$content)),
    .package = "safeconduct")
  doc <- ivt_fetch_html("https://www12.statcan.gc.ca/datasets/Index-eng.cfm?Temporal=2021")
  expect_s3_class(doc, "xml_document")
  expect_equal(seen$session, "kept-browser")
  # ivt_read_html is the scraper's entry to the same transport
  expect_s3_class(ivt_read_html("https://www12.statcan.gc.ca/x"), "xml_document")
})

test_that("one browser session per challenging host, none for the others", {
  skip_if_not_installed("safeconduct")
  opened <- 0L
  local_mocked_bindings(
    browser_session = function(url, ...) {
      opened <<- opened + 1L
      s <- new.env(); s$open <- TRUE; class(s) <- "safeconduct_session"; s
    },
    .package = "safeconduct")
  withr::defer(rm(list = ls(ivt_browser_sessions), envir = ivt_browser_sessions))

  expect_null(ivt_browser_session("https://www150.statcan.gc.ca/n1/en/tbl/b2020/x.zip"))
  expect_equal(opened, 0L)
  s1 <- ivt_browser_session("https://www12.statcan.gc.ca/datasets/Index-eng.cfm?Temporal=2021")
  s2 <- ivt_browser_session("https://www12.statcan.gc.ca/datasets/Index-eng.cfm?Temporal=2016")
  expect_identical(s1, s2)
  expect_equal(opened, 1L)
  # a closed session is replaced, not reused
  s1$open <- FALSE
  s3 <- ivt_browser_session("https://www12.statcan.gc.ca/x")
  expect_false(identical(s1, s3))
  expect_equal(opened, 2L)
})
