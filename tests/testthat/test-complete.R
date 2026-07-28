# The published table -- read_ivt()'s default output.
#
# An .ivt writes only non-zero cells; StatCan publishes the whole grid, zeros
# written out and flagged cells carrying a symbol. `complete = TRUE` reproduces
# that, and the rule it applies is read off the file: an absent cell is the
# published zero UNLESS its page's cell-status block says otherwise. These tests
# pin the shape, the rule and the guard; the cell-for-cell agreement with
# StatCan's own CSV downloads is recorded in inst/notes/coverage.md.

bundled <- function() system.file("extdata", "98100044.ivt", package = "canivt")

test_that("the default output spans the whole grid, with symbol and status", {
  x <- read_ivt(bundled())
  lay <- ivt_quietly(ivt_layout(readBin(bundled(), "raw",
                                        file.size(bundled()))))
  # every real coordinate, exactly once
  expect_identical(nrow(x$cells), as.integer(prod(lay$counts)))
  expect_identical(anyDuplicated(x$cells[lay$slugs]), 0L)
  # the store is a strict subset, and the difference is the published zeros
  y <- read_ivt(bundled(), complete = FALSE)
  expect_lt(nrow(y$cells), nrow(x$cells))
  expect_identical(sum(!is.na(x$cells$value) & x$cells$value != 0),
                   sum(y$cells$value != 0))
  # the status columns are factors -- one level per declared code, over a grid
  # that can run to tens of millions of rows
  expect_s3_class(x$cells$symbol, "factor")
  expect_s3_class(x$cells$status, "factor")
  # this table publishes no missings, so nothing is flagged and no value is NA
  expect_false(anyNA(x$cells$value))
  expect_true(all(is.na(x$cells$symbol)))
})

test_that("the completed values agree with the store, cell for cell", {
  x <- read_ivt(bundled())
  y <- read_ivt(bundled(), complete = FALSE)
  key <- function(d) do.call(paste, c(unname(as.data.frame(d)[
    setdiff(names(y$cells), "value")]), sep = "|"))
  i <- match(key(y$cells), key(x$cells))
  expect_false(anyNA(i))
  expect_equal(x$cells$value[i], y$cells$value)
  # and every coordinate the store does not carry completes to a zero, because
  # this table's pages flag nothing
  expect_true(all(x$cells$value[-i] == 0))
})

test_that("the flagged cells are the NA rows, and x$missing is that view", {
  x <- read_ivt(bundled(), missing = TRUE)
  expect_identical(nrow(x$missing), sum(is.na(x$cells$value)))
  expect_identical(names(x$missing),
                   c(setdiff(names(x$cells), c("value", "symbol", "status")),
                     "symbol", "status"))
  # the file's own legend travels with both
  expect_identical(attr(x$missing, "legend"), attr(x$cells, "legend"))
  expect_identical(attr(x$cells, "legend")$symbol,
                   c("..", "X", "...", "F", "0 s"))
})

test_that("ivt_tidy carries the status columns and does not double the rows", {
  x <- read_ivt(bundled())
  td <- ivt_tidy(x)
  expect_identical(nrow(td), nrow(x$cells))
  expect_identical(tail(names(td), 3L), c("value", "symbol", "status"))
  # `missing = TRUE` asks for a shape the published table already has
  expect_identical(nrow(ivt_tidy(x, missing = TRUE)), nrow(x$cells))
  # the compact id form keeps them too
  expect_identical(tail(names(ivt_tidy(x, labels = FALSE)), 3L),
                   c("value", "symbol", "status"))
  # and the dimension columns are still named from the codebook, not from the
  # status columns creeping into the data-column list
  expect_false(any(c("symbol", "status") %in%
                     ivt_data_colnames(setdiff(names(x$cells),
                                               c("geo", "value", "symbol",
                                                 "status")),
                                       x$metadata, "slug", "en")))
})

test_that("completion is refused above the cell budget, with a way out", {
  x <- readBin(bundled(), "raw", file.size(bundled()))
  lay <- ivt_quietly(ivt_layout(x))
  expect_error(ivt_complete_budget(lay, max_cells = 10),
               class = "canivt_complete_too_large")
  expect_error(ivt_complete_budget(lay, max_cells = 10), "complete = FALSE")
  # the option is what read_ivt() consults
  expect_error(withr::with_options(list(canivt.max_cells = 10),
                                   read_ivt(bundled())),
               class = "canivt_complete_too_large")
  # and it never fires on the store path
  expect_silent(read_ivt(bundled(), complete = FALSE))
})

test_that("reason codes are named from the FILE's legend, and only where named", {
  lay <- list(n_dim = 1L, slugs = "d")
  tally <- c(mask = 1L, none = 0L, status = 1L, unreadable = 0L, extra = 0L,
             nan_words = 0L, contradictory = 0L, beyond = 0L,
             status_unread = 0L, status_unknown = 0L)
  # a legend that is NOT the NDM vocabulary: this file numbers `-` first, so a
  # fixed table would mislabel every code
  leg <- tibble::tibble(code = 1:3, symbol = c("-", "..", "x"),
                        text_en = c("nil", "not available", "suppressed"),
                        text_fr = c("nul", "indisponible", "confidentiel"))
  #                 value   nil   n/a   suppressed   a code the legend omits
  v  <- c(7, NA, NA, NA, NA)
  cd <- c(0L, 1L, 2L, 3L, 9L)
  out <- ivt_complete_cells(list(1:5), v, cd, lay, tally, legend = leg)
  expect_identical(as.character(out$symbol), c(NA, "-", "..", "x", NA))
  expect_identical(as.character(out$status),
                   c(NA, "nil", "not available", "suppressed", NA))
  # the unnamed code is not guessed at: NA value, no label
  expect_true(is.na(out$value[5L]))
  # -1 is the 1-bit mask's "missing, reason unstated" -- flagged, never labelled
  out2 <- ivt_complete_cells(list(1:2), c(7, NA), c(0L, -1L), lay, tally,
                             legend = leg)
  expect_identical(as.character(out2$symbol), c(NA_character_, NA_character_))
  expect_true(is.na(out2$value[2L]))
})

# --- corpus sweep (opt-in) -----------------------------------------------------
#
# The corpus and status ledgers are both contracts about the STORE -- both sweeps
# read `complete = FALSE`, because a decode regression moves the file's own
# stored-value count. Nothing there watches the FOLD that turns the store into
# the published table, so an optimisation that quietly mislays a page's zeros
# would pass the whole suite. fixtures/complete-ledger.csv is that net.
#
# `grid` -- the published grid, `prod(lay$counts)` -- is checked for every corpus
# table from the layout alone. The rest is measured on the 126 tables whose grid
# fits the sweep budget (5,000,000 cells); completing the corpus's 4.3 billion
# rows would be the sweep's cost rather than its subject. What it pins:
#
#   * `rows == grid` -- one row per real coordinate, no more and no fewer;
#   * `stored` == the corpus ledger's `n_cells` -- the fold neither invents nor
#     drops a stored value;
#   * `zeros` / `flagged` -- how the ABSENT cells were classified. This is the
#     column that moves if the cell-status tail is mis-scattered: the two are a
#     partition of `grid - stored`, so a bit lost in one lands in the other.
#   * `symbolled` -- flagged cells the file's own legend names (the rest are the
#     1-bit mask's "missing, reason unstated").
#   * `vsum` -- the value sum, so a value scattered to the wrong coordinate
#     shows up even when every count is right.
#
# Re-measure with dev/csweep.R.

corpus_dir <- Sys.getenv("CANIVT_IVT_CACHE")
corpus_on <- nzchar(Sys.getenv("CANIVT_CORPUS_TESTS")) &&
  nzchar(corpus_dir) && dir.exists(corpus_dir)

complete_ledger <- utils::read.csv(
  testthat::test_path("fixtures", "complete-ledger.csv"), stringsAsFactors = FALSE)

complete_probe <- function(row) {
  hit <- list.files(file.path(corpus_dir, row$key), pattern = "\\.ivt$",
                    ignore.case = TRUE, full.names = TRUE)
  if (!length(hit)) return(list(key = row$key, absent = TRUE))
  raw <- readBin(hit[[1L]], "raw", file.size(hit[[1L]]))
  cap <- ivt_test_capture(ivt_quietly(ivt_layout(raw)))
  rm(raw)
  out <- list(key = row$key, absent = FALSE, error = cap$error)
  if (!is.null(cap$value)) out$grid <- prod(as.numeric(cap$value$counts))
  if (is.na(row$rows)) { gc(verbose = FALSE); return(out) }
  cap <- ivt_test_capture(read_ivt(hit[[1L]]))
  if (!is.null(cap$error)) { out$error <- cap$error; return(out) }
  cl <- cap$value$cells
  na <- is.na(cl$value)
  out$rows <- nrow(cl)
  out$flagged <- sum(na)
  out$symbolled <- sum(!is.na(cl$symbol))
  out$zeros <- sum(cl$value[!na] == 0)
  out$stored <- out$rows - out$flagged - out$zeros
  out$vsum <- sum(cl$value, na.rm = TRUE)
  rm(cap, cl); gc(verbose = FALSE)
  out
}

test_that("the corpus completes to the ledgered published grids", {
  skip_if(!corpus_on, "corpus tests are opt-in: set CANIVT_CORPUS_TESTS=1 (and CANIVT_IVT_CACHE)")
  got <- ivt_test_pmap(split(complete_ledger, seq_len(nrow(complete_ledger))),
                       complete_probe)
  store <- utils::read.csv(testthat::test_path("fixtures", "corpus-ledger.csv"),
                           stringsAsFactors = FALSE)
  for (r in got) {
    row <- complete_ledger[complete_ledger$key == r$key, ]
    if (isTRUE(r$absent)) { skip(paste("not in cache:", r$key)); next }
    expect_null(r$error, info = r$key)
    expect_equal(r$grid, row$grid, info = r$key)
    if (is.na(row$rows)) next                       # over the sweep's budget
    # the whole point: one row per coordinate, and the absences partitioned
    expect_equal(r$rows, row$grid, info = r$key)
    expect_equal(r$rows, row$rows, info = r$key)
    expect_equal(r$stored, row$stored, info = r$key)
    expect_equal(r$zeros, row$zeros, info = r$key)
    expect_equal(r$flagged, row$flagged, info = r$key)
    expect_equal(r$symbolled, row$symbolled, info = r$key)
    expect_equal(r$vsum, row$vsum, info = r$key)
    # ... and the store the fold started from is the one the corpus ledger pins
    want <- store$n_cells[store$key == r$key]
    if (length(want) == 1L) expect_equal(r$stored, want, info = r$key)
  }
})
