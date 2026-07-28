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
  md <- matrix(1:5, 5L, 1L)
  #                 value   nil   n/a   suppressed   a code the legend omits
  v  <- c(7, NA, NA, NA, NA)
  cd <- c(0L, 1L, 2L, 3L, 9L)
  out <- ivt_complete_cells(list(md), list(v), list(cd), 1L, lay, tally,
                            legend = leg)
  expect_identical(as.character(out$symbol), c(NA, "-", "..", "x", NA))
  expect_identical(as.character(out$status),
                   c(NA, "nil", "not available", "suppressed", NA))
  # the unnamed code is not guessed at: NA value, no label
  expect_true(is.na(out$value[5L]))
  # -1 is the 1-bit mask's "missing, reason unstated" -- flagged, never labelled
  out2 <- ivt_complete_cells(list(md[1:2, , drop = FALSE]), list(c(7, NA)),
                             list(c(0L, -1L)), 1L, lay, tally, legend = leg)
  expect_identical(as.character(out2$symbol), c(NA_character_, NA_character_))
  expect_true(is.na(out2$value[2L]))
})
