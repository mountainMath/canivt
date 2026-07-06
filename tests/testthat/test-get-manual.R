# Manual-source imports (named url/path input) and the keep_ivt caching flag.

test_that("ivt_manual_input detects named length-one sources, ignores ids/rows", {
  expect_equal(canivt:::ivt_manual_input(c(my_table = "~/foo.zip")),
               list(key = "my_table", source = "~/foo.zip"))
  expect_equal(canivt:::ivt_manual_input(list(hood = "https://x/y.ivt")),
               list(key = "hood", source = "https://x/y.ivt"))
  # unnamed id string / catalogue-like input -> not a manual source
  expect_null(canivt:::ivt_manual_input("98-10-0241"))
  expect_null(canivt:::ivt_manual_input(setNames("u", "")))  # blank name
  # a data frame (catalogue row) is never a manual source
  expect_null(canivt:::ivt_manual_input(data.frame(catalogue = "x")))
})

test_that("ivt_manual_input rejects multi-entry and empty sources", {
  expect_error(canivt:::ivt_manual_input(c(a = "u", b = "v")), "exactly one entry")
  expect_error(canivt:::ivt_manual_input(c(k = "")), "non-empty string")
  expect_error(canivt:::ivt_manual_input(c(k = NA_character_)), "non-empty string")
})

test_that("ivt_manual_download copies a local raw .ivt into dest_dir and reuses it", {
  # a dummy payload carrying the IVT 04 00 20 00 signature (content is not
  # decoded here -- we only exercise the sniff-and-store path).
  src <- tempfile(fileext = ".ivt")
  writeBin(as.raw(c(0x04, 0x00, 0x20, 0x00, 0x01, 0x02)), src)
  dest <- file.path(tempfile("dest"))

  out <- canivt:::ivt_manual_download(src, "tab", dest_dir = dest, quiet = TRUE)
  expect_true(file.exists(out))
  expect_equal(basename(out), "tab.ivt")
  expect_equal(normalizePath(dirname(out)), normalizePath(dest))
  # original is copied, never moved
  expect_true(file.exists(src))

  # second call reuses the stored file (no overwrite) -- same path back
  out2 <- canivt:::ivt_manual_download(src, "tab", dest_dir = dest, quiet = TRUE)
  expect_equal(normalizePath(out2), normalizePath(out))
})

test_that("ivt_manual_download unzips a local .zip and errors on a missing path", {
  src <- tempfile(fileext = ".ivt")
  writeBin(as.raw(c(0x04, 0x00, 0x20, 0x00, 0xAB)), src)
  zip <- tempfile(fileext = ".zip")
  # zip the .ivt with a stored (no-compression) entry, junk paths dropped
  utils::zip(zip, src, flags = "-j0q")
  skip_if(!file.exists(zip) || file.info(zip)$size == 0, "zip utility unavailable")

  dest <- file.path(tempfile("destzip"))
  out <- canivt:::ivt_manual_download(zip, "ztab", dest_dir = dest, quiet = TRUE)
  expect_true(file.exists(out))
  expect_match(out, "\\.ivt$", ignore.case = TRUE)

  expect_error(
    canivt:::ivt_manual_download("/no/such/file.ivt", "x",
                                 dest_dir = tempfile(), quiet = TRUE),
    "does not exist")
})
