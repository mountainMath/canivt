# Chunked conversion (R/stream.R): the published grid written a slice at a time.
#
# The store an .ivt holds is an order of magnitude smaller than the table
# StatCan publishes from it (4.3 billion corpus grid rows against 366 million
# stored cells), so what puts a big table out of reach on a small machine is
# materialising the fold, not reading the file. The entry cartesian's outermost
# paged dimension varies slowest, so a slice of it is a contiguous run of output
# rows -- decode it, write it, drop it. These pin the two things that makes it
# worth having: the plan covers the table exactly once, and the streamed file is
# the one the in-memory path writes.

bundled <- function() system.file("extdata", "98100044.ivt", package = "canivt")

test_that("the chunk plan covers the outer dimension exactly once", {
  # a layout is only ever sliced on the last entry-cartesian column
  lay <- list(counts = c(10L, 10L, 10L), ent_counts = c(2L, 5L))
  # the whole grid fits -> one piece, and `outer = NULL` means "no slice"
  expect_identical(ivt_chunk_plan(lay, max_cells = 1e6), list(NULL))
  # 1000 rows over 5 outer members = 200 each: a 500-cell budget takes two
  p <- ivt_chunk_plan(lay, max_cells = 500)
  expect_identical(sort(unlist(p)), 0:4)
  expect_true(all(lengths(p) <= 2L))
  # a budget below a single outer member still yields the finest slice there is,
  # rather than refusing
  p1 <- ivt_chunk_plan(lay, max_cells = 1)
  expect_identical(p1, split(0:4, 0:4), ignore_attr = TRUE)
  # a layout with nothing outside the straddle window cannot be sliced
  expect_identical(ivt_chunk_plan(list(counts = 10L, ent_counts = 3L),
                                  max_cells = 1), list(NULL))
})

test_that("a decoded slice is the whole table's rows, and only those", {
  raw <- readBin(bundled(), "raw", file.size(bundled()))
  lay <- ivt_quietly(ivt_layout(raw))
  # the bundled table pages on nothing but its straddle window, so it says so
  # rather than silently decoding everything
  expect_identical(length(lay$ent_counts), 1L)
  expect_error(ivt_decode(raw, lay = lay, complete = TRUE, outer = 0L),
               "nothing to slice")
})

test_that("streaming writes the same Parquet as the in-memory path", {
  skip_if_not_installed("arrow")
  dir <- withr::local_tempdir()
  x <- read_ivt(bundled(), missing = TRUE)
  a <- ivt_write_parquet(x, file.path(dir, "whole_en.parquet"))
  b <- ivt_write_parquet(bundled(), file.path(dir, "stream_en.parquet"))
  rd <- function(p) tibble::as_tibble(arrow::read_parquet(p))
  expect_equal(rd(b), rd(a))
  # the sidecars travel too, labelled the same way
  expect_equal(rd(ivt_members_path(b)), rd(ivt_members_path(a)))
  expect_equal(rd(ivt_missing_path(b)), rd(ivt_missing_path(a)))
  # `missing = FALSE` writes no cell-status sidecar
  d <- ivt_write_parquet(bundled(), file.path(dir, "nomiss_en.parquet"),
                         missing = FALSE)
  expect_false(file.exists(ivt_missing_path(d)))
})

test_that("streaming writes the same CSV as the in-memory path", {
  dir <- withr::local_tempdir()
  x <- read_ivt(bundled(), missing = TRUE)
  a <- ivt_write_csv(x, file.path(dir, "whole_en.csv"))
  b <- ivt_write_csv(bundled(), file.path(dir, "stream_en.csv"))
  expect_identical(readLines(b), readLines(a))
  expect_identical(readLines(ivt_csv_missing_path(b)),
                   readLines(ivt_csv_missing_path(a)))
})

test_that("CSV is gzipped by default, and says so in the extension", {
  dir <- withr::local_tempdir()
  x <- read_ivt(bundled(), missing = TRUE)
  gz <- ivt_write_csv(x, file.path(dir, "d_en.csv"))
  # the returned path is the one written -- `.gz` appended, sidecar too
  expect_identical(basename(gz), "d_en.csv.gz")
  expect_true(file.exists(gz))
  expect_identical(basename(ivt_csv_missing_path(gz)), "d_en_missing.csv.gz")
  expect_true(file.exists(ivt_csv_missing_path(gz)))
  # ... and it really is gzip: the magic number, not just the name
  expect_identical(readBin(gz, "raw", 2L), as.raw(c(0x1f, 0x8b)))

  plain <- ivt_write_csv(x, file.path(dir, "p_en.csv"), compress = FALSE)
  expect_identical(basename(plain), "p_en.csv")
  # same table either way, and the compression earns its default
  expect_identical(readLines(gz), readLines(plain))
  expect_lt(file.size(gz), file.size(plain))

  # a path that already ends in `.gz` is a request to compress, whatever the
  # argument says
  forced <- ivt_write_csv(x, file.path(dir, "f_en.csv.gz"), compress = FALSE)
  expect_identical(basename(forced), "f_en.csv.gz")
  expect_identical(readBin(forced, "raw", 2L), as.raw(c(0x1f, 0x8b)))

  # the sidecar name keeps the data table's own extension, whatever it is
  expect_identical(ivt_csv_missing_path("t/a_en.csv"), "t/a_en_missing.csv")
  expect_identical(ivt_csv_missing_path("t/a_en.csv.gz"), "t/a_en_missing.csv.gz")
  expect_identical(ivt_csv_missing_path("t/a_en.gz"), "t/a_en_missing.csv.gz")
  expect_identical(ivt_csv_missing_path("t/a_en"), "t/a_en_missing.csv")
})

test_that("a missing input is refused before anything is written", {
  expect_error(ivt_write_csv(file.path(tempdir(), "nope.ivt")), "No such file")
})

# --- corpus sweep (opt-in) -----------------------------------------------------
#
# The bundled table has a single directory-entry level, so it exercises the
# streaming machinery but never actually slices. These do: on every corpus table
# with a paged dimension outside the straddle window, the concatenation of the
# finest possible slices must be the whole-table decode, row for row and in
# order -- which is also what makes the streamed file byte-identical.

corpus_dir <- Sys.getenv("CANIVT_IVT_CACHE")
corpus_on <- nzchar(Sys.getenv("CANIVT_CORPUS_TESTS")) &&
  nzchar(corpus_dir) && dir.exists(corpus_dir)

stream_ledger <- utils::read.csv(
  testthat::test_path("fixtures", "complete-ledger.csv"), stringsAsFactors = FALSE)

stream_probe <- function(row) {
  hit <- list.files(file.path(corpus_dir, row$key), pattern = "\\.ivt$",
                    ignore.case = TRUE, full.names = TRUE)
  if (!length(hit)) return(list(key = row$key, absent = TRUE))
  cap <- ivt_test_capture({
    raw <- readBin(hit[[1L]], "raw", file.size(hit[[1L]]))
    lay <- ivt_layout(raw)
    ne <- length(lay$ent_counts)
    if (ne < 2L) list(sliceable = FALSE) else {
      whole <- ivt_decode(raw, lay = lay, complete = TRUE)
      # every outer member on its own -- the finest slice the layout allows
      parts <- do.call(rbind, lapply(seq_len(lay$ent_counts[[ne]]) - 1L,
                                     function(w)
        ivt_decode(raw, lay = lay, complete = TRUE, outer = w)))
      # ... and a plan that puts several members in a chunk
      plan <- ivt_chunk_plan(lay, max_cells = nrow(whole) / 3)
      coarse <- do.call(rbind, lapply(plan, function(w)
        ivt_decode(raw, lay = lay, complete = TRUE, outer = w)))
      list(sliceable = TRUE, n = nrow(whole), n_out = lay$ent_counts[[ne]],
           chunks = length(plan),
           fine_same = isTRUE(all.equal(as.data.frame(parts),
                                        as.data.frame(whole),
                                        check.attributes = FALSE)),
           coarse_same = isTRUE(all.equal(as.data.frame(coarse),
                                          as.data.frame(whole),
                                          check.attributes = FALSE)))
    }
  })
  gc(verbose = FALSE)
  list(key = row$key, absent = FALSE, error = cap$error, value = cap$value)
}

test_that("the corpus decodes slice by slice into the whole table", {
  skip_if(!corpus_on, "corpus tests are opt-in: set CANIVT_CORPUS_TESTS=1 (and CANIVT_IVT_CACHE)")
  led <- stream_ledger[!is.na(stream_ledger$rows), ]   # under the sweep budget
  got <- ivt_test_pmap(split(led, seq_len(nrow(led))), stream_probe)
  n_sliced <- 0L
  for (r in got) {
    if (isTRUE(r$absent)) { skip(paste("not in cache:", r$key)); next }
    expect_null(r$error, info = r$key)
    v <- r$value
    if (is.null(v) || !isTRUE(v$sliceable)) next
    n_sliced <- n_sliced + 1L
    expect_true(v$fine_same, info = r$key)
    expect_true(v$coarse_same, info = r$key)
    # a paged dimension with a single member has one slice and that is correct;
    # anything wider must actually have been split
    if (v$n_out > 1L) expect_gt(v$chunks, 1L) else expect_identical(v$chunks, 1L)
  }
  expect_gt(n_sliced, 0L)
})
