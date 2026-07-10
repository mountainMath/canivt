# The per-file parse memo (memo.R). Pure unit tests -- no sample file needed.

test_that("ivt_memo computes once per raw vector and key", {
  withr::defer(ivt_memo_clear())
  raw <- as.raw(1:64)
  n <- 0L
  f <- function() ivt_memo(raw, "x", function() { n <<- n + 1L; "v" })
  expect_equal(f(), "v")
  expect_equal(f(), "v")
  expect_equal(n, 1L)
  # a different key on the same raw computes separately
  expect_equal(ivt_memo(raw, "y", function() { n <<- n + 1L; "w" }), "w")
  expect_equal(n, 2L)
})

test_that("a byte-different raw (doctored copy) never reuses the cache", {
  withr::defer(ivt_memo_clear())
  raw <- as.raw(1:64)
  n <- 0L
  compute <- function() { n <<- n + 1L; n }
  expect_equal(ivt_memo(raw, "x", compute), 1L)
  doctored <- raw
  doctored[10] <- as.raw(0xff)
  expect_equal(ivt_memo(doctored, "x", compute), 2L)   # same length, one byte off
  # ... and the slot moved on: the original recomputes too (single slot)
  expect_equal(ivt_memo(raw, "x", compute), 3L)
})

test_that("a NULL result is cached like any other value", {
  withr::defer(ivt_memo_clear())
  raw <- as.raw(1:8)
  n <- 0L
  f <- function() ivt_memo(raw, "x", function() { n <<- n + 1L; NULL })
  expect_null(f())
  expect_null(f())
  expect_equal(n, 1L)
})

test_that("warnings from a memoized compute are replayed on every hit", {
  withr::defer(ivt_memo_clear())
  raw <- as.raw(1:8)
  f <- function() ivt_memo(raw, "x", function() {
    ivt_fallback("located by scan", class = "canivt_descriptor_reloc")
    "v"
  })
  # first compute warns (and records) ...
  expect_warning(expect_equal(f(), "v"), class = "canivt_descriptor_reloc")
  # ... and every hit replays it, umbrella class included, so a warm cache is
  # exactly as loud as a cold one
  expect_warning(expect_equal(f(), "v"), class = "canivt_descriptor_reloc")
  expect_warning(f(), class = "canivt_fallback")
})

test_that("errors are never cached: strict mode stays strict on every call", {
  withr::defer(ivt_memo_clear())
  raw <- as.raw(1:8)
  n <- 0L
  f <- function() ivt_memo(raw, "x", function() { n <<- n + 1L; stop("boom") })
  expect_error(f(), "boom")
  expect_error(f(), "boom")
  expect_equal(n, 2L)
})

test_that("ivt_memo_clear drops the slot (and its raw reference)", {
  raw <- as.raw(1:8)
  n <- 0L
  f <- function() ivt_memo(raw, "x", function() { n <<- n + 1L; "v" })
  f()
  ivt_memo_clear()
  expect_length(ls(canivt:::.canivt_memo, all.names = TRUE), 0L)
  f()
  expect_equal(n, 2L)
  ivt_memo_clear()
})
