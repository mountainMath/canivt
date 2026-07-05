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

for (i in seq_len(nrow(ledger))) {
  row <- ledger[i, ]
  test_that(paste0("corpus: ", row$key), {
    skip_if(!corpus_on, "corpus tests are opt-in: set CANIVT_CORPUS_TESTS=1 (and CANIVT_IVT_CACHE)")
    f <- corpus_file(row$key)
    skip_if(is.na(f), paste0("table ", row$key, " not in the local corpus"))
    raw <- readBin(f, "raw", file.size(f))
    expect_identical(ivt_is_supported(raw), row$supported)
    if (!row$supported) return(invisible())
    rm(raw)
    if (isTRUE(row$strict_clean)) {
      withr::local_options(canivt.strict = TRUE)
      expect_no_warning(x <- read_ivt(f))
    } else {
      # a known fallback: must warn with the class, must not error
      expect_warning(x <- read_ivt(f), class = "canivt_fallback")
    }
    expect_identical(nrow(x$cells), as.integer(row$n_cells))
    rm(x)
    gc(verbose = FALSE)
  })
}
