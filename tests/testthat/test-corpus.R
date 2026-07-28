# Corpus-wide regression ledger.
#
# Runs the WHOLE local .ivt corpus (the ivt cache, one folder per table) through
# read_ivt() and asserts the measured state recorded in fixtures/corpus-ledger.csv:
#
# - `supported`: ivt_is_supported() accepts/rejects the file (a rejected file
#   must never start decoding unvalidated values; a supported one must decode
#   with no error);
# - `strict_clean`: the file reads end-to-end (cells + metadata) under
#   `options(canivt.strict = TRUE)` -- i.e. every read resolved through a
#   positional, metadata-driven primary path. A `FALSE` row documents a KNOWN
#   fallback (e.g. a label set only recoverable by the marker scan); it must
#   still decode with a classed `canivt_fallback` warning, no error, so a
#   silently-vanishing warning (fallback became primary: flip the ledger) and a
#   new error both fail loudly;
# - `n_cells`: the exact non-zero cell count -- the cheapest whole-pipeline
#   invariant (a mis-nested layout or a collapsed dimension changes it, cf. the
#   98-10-0174 mother-tongue collapse, which decoded 1/331 of the cells).
#
# Opt-in: the full pass decodes ~150M cells in ~4 minutes, so it only runs when
# CANIVT_CORPUS_TESTS is set (and the ivt cache resolves):
#
#   CANIVT_CORPUS_TESTS=1 Rscript -e 'devtools::test(filter = "corpus")'
#
# When a gap is closed (a fallback path retired, a new table onboarded), update
# the ledger row -- and inst/notes/coverage.md -- in the same commit.

corpus_dir <- Sys.getenv("CANIVT_IVT_CACHE")
corpus_on <- nzchar(Sys.getenv("CANIVT_CORPUS_TESTS")) &&
  nzchar(corpus_dir) && dir.exists(corpus_dir)

corpus_file <- function(key) {
  hit <- list.files(file.path(corpus_dir, key), pattern = "\\.ivt$",
                    ignore.case = TRUE, full.names = TRUE)
  if (length(hit)) hit[[1L]] else NA_character_
}

ledger <- utils::read.csv(testthat::test_path("fixtures", "corpus-ledger.csv"),
                          stringsAsFactors = FALSE)

# The ledger is only a net if it COVERS the corpus. Four tables (optab12, optab13,
# Table-210, CDCSDNAIC3dec2006) once sat in the cache with no row, so nothing
# regression-tested them and two that decoded correctly went unnoticed for weeks.
# A new folder must therefore be ledgered -- with a cell count if it decodes, or
# `supported = FALSE` if it is a deliberate gate guard.
test_that("every corpus folder has a ledger row", {
  skip_if(!corpus_on, "corpus tests are opt-in: set CANIVT_CORPUS_TESTS=1 (and CANIVT_IVT_CACHE)")
  dirs <- list.dirs(corpus_dir, recursive = FALSE, full.names = FALSE)
  dirs <- dirs[vapply(dirs, function(k) !is.na(corpus_file(k)), logical(1))]
  expect_identical(sort(setdiff(dirs, ledger$key)), character(0))
})

# One table's whole measurement, as plain data (helper-parallel.R). Runs in a
# forked worker, so it must not assert -- everything the ledger checks is
# returned and asserted serially below.
corpus_probe <- function(row) {
  f <- corpus_file(row$key)
  if (is.na(f)) return(list(key = row$key, absent = TRUE))
  out <- list(key = row$key, absent = FALSE)
  raw <- readBin(f, "raw", file.size(f))
  gate <- ivt_test_capture(ivt_is_supported(raw))
  rm(raw)
  out$gate_error <- gate$error
  out$supported <- gate$value
  # an UNSUPPORTED row asserts the gate verdict only -- it must never decode
  if (!isTRUE(row$supported)) return(out)
  # strict mode is per-process state; `with_options` scopes it to this read even
  # under `mc.preschedule = FALSE` (one child per job, but be explicit).
  # `complete = FALSE`: the ledger's `n_cells` is the STORE -- the file's own
  # stored-value count, which is what a decode regression moves. The published
  # grid is a function of that plus the layout, and completing 4.3 billion
  # corpus rows would be the sweep's cost rather than its subject.
  cap <- if (isTRUE(row$strict_clean)) {
    ivt_test_capture(withr::with_options(list(canivt.strict = TRUE), read_ivt(f, complete = FALSE)))
  } else {
    ivt_test_capture(read_ivt(f, complete = FALSE))
  }
  out$read_error <- cap$error
  out$warnings <- cap$warnings
  out$fallback <- cap$fallback
  out$n_cells <- if (is.null(cap$value)) NA_integer_ else nrow(cap$value$cells)
  gc(verbose = FALSE)
  out
}

corpus_probes <- if (corpus_on) {
  ivt_test_pmap(split(ledger, seq_len(nrow(ledger))), corpus_probe)
} else {
  vector("list", nrow(ledger))
}

for (i in seq_len(nrow(ledger))) {
  local({
    row <- ledger[i, ]
    got <- corpus_probes[[i]]
    test_that(paste0("corpus: ", row$key), {
      skip_if(!corpus_on, "corpus tests are opt-in: set CANIVT_CORPUS_TESTS=1 (and CANIVT_IVT_CACHE)")
      expect_null(got$worker_error)
      skip_if(isTRUE(got$absent), paste0("table ", row$key, " not in the local corpus"))
      expect_null(got$gate_error)
      expect_identical(got$supported, row$supported)
      if (!row$supported) return(invisible())
      expect_null(got$read_error)
      if (isTRUE(row$strict_clean)) {
        # strict + clean: the read resolved through the primary path with no
        # warning at all (under strict a fallback would have ERRORED above)
        expect_identical(got$warnings, character(0))
      } else {
        # a known fallback: must warn with the class, must not error
        expect_gt(got$fallback, 0L)
      }
      expect_identical(got$n_cells, as.integer(row$n_cells))
    })
  })
}
