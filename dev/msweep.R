# msweep.R -- corpus-wide cell-status (missing-data) sweep.
#
# Reads every SUPPORTED table in the corpus ledger with `missing = TRUE` and
# collects, per table, the page-class tally from `attr(x$missing, "pages")`
# (see R/status.R) plus the missing-cell count. It also re-asserts the cheapest
# whole-pipeline invariant -- `nrow(x$cells)` against the ledger -- so a change
# to the status path that perturbs the value decode shows up immediately.
#
# This is the script behind the figures quoted in inst/notes/coverage.md and
# decode-history.md ("The mask is index-addressed"). Re-run it after any change
# to status.R or decode.R and update tests/testthat/fixtures/status-ledger.csv
# from the CSV it writes.
#
# The two columns that must never move:
#   unreadable    == 0   the index accounts for every mask page's tail byte-exactly
#   contradictory == 0   no mask bit lands on a cell that carries a value
#
#   Rscript dev/msweep.R [out.csv]
#
# Env: CANIVT_IVT_CACHE (corpus root, one folder per table; falls back to
# ~/data/ivt_raw), CANIVT_TEST_CORES (workers; default half the cores -- each
# holds a whole decoded table, so memory is the binding constraint), CANIVT_PKG
# (package root; defaults to the working directory).

# run from the package root (or point CANIVT_PKG at it)
pkg <- Sys.getenv("CANIVT_PKG")
if (!nzchar(pkg)) pkg <- "."
suppressMessages(devtools::load_all(pkg))

cache <- Sys.getenv("CANIVT_IVT_CACHE")
if (!nzchar(cache)) cache <- path.expand("~/data/ivt_raw")
out_csv <- commandArgs(trailingOnly = TRUE)[1L]
if (is.na(out_csv)) out_csv <- file.path(tempdir(), "msweep.csv")

led <- utils::read.csv(
  file.path(pkg, "tests", "testthat", "fixtures", "corpus-ledger.csv"),
  stringsAsFactors = FALSE)
led <- led[led$supported %in% c(TRUE, "TRUE", "true"), ]

cf <- function(k) {
  h <- list.files(file.path(cache, k), pattern = "\\.ivt$", ignore.case = TRUE,
                  full.names = TRUE)
  if (length(h)) h[[1L]] else NA_character_
}

cores <- suppressWarnings(as.integer(Sys.getenv("CANIVT_TEST_CORES")))
if (is.na(cores)) cores <- max(1L, parallel::detectCores() %/% 2L)

res <- parallel::mclapply(seq_len(nrow(led)), function(i) {
  k <- led$key[i]; f <- cf(k)
  if (is.na(f)) return(NULL)
  o <- list(key = k, want = led$n_cells[i])
  ws <- character()
  v <- tryCatch(withCallingHandlers(read_ivt(f, missing = TRUE),
        warning = function(w) { ws <<- c(ws, class(w)[1L]); invokeRestart("muffleWarning") }),
        error = function(e) { o$err <<- conditionMessage(e); NULL })
  if (is.null(v)) return(o)
  o$cells <- nrow(v$cells); o$miss <- nrow(v$missing)
  t <- attr(v$missing, "pages", exact = TRUE)
  for (nm in names(t)) o[[nm]] <- t[[nm]]
  # how many reason codes the file's OWN status legend declares (0 = none)
  lg <- attr(v$missing, "legend", exact = TRUE)
  o$legend <- if (is.null(lg)) 0L else nrow(lg)
  o$warn <- paste(unique(ws), collapse = ",")
  rm(v); gc(verbose = FALSE)
  o
}, mc.cores = cores)

res <- Filter(Negate(is.null), res)
nm <- unique(unlist(lapply(res, names)))
df <- do.call(rbind, lapply(res, function(r) {
  r <- r[nm]; names(r) <- nm
  as.data.frame(lapply(r, function(x) if (is.null(x)) NA else x),
                stringsAsFactors = FALSE)
}))
utils::write.csv(df, out_csv, row.names = FALSE)
cat("tables", nrow(df), "->", out_csv, "\n")

cat("CELL MISMATCH:", sum(!is.na(df$cells) & df$cells != df$want), "\n")
print(df[!is.na(df$cells) & df$cells != df$want, c("key", "want", "cells")])
# `err` only exists as a column if some table actually failed
if ("err" %in% names(df)) {
  cat("ERRORS:", sum(!is.na(df$err)), "\n")
  print(df[!is.na(df$err), c("key", "err")])
} else {
  cat("ERRORS: 0\n")
}

cat("\n-- totals --\n")
for (c_ in c("mask", "none", "status", "status_unread", "status_unknown",
             "unreadable", "extra", "nan_words", "contradictory", "beyond",
             "miss"))
  if (c_ %in% names(df)) cat(sprintf("%-14s %d\n", c_, sum(df[[c_]], na.rm = TRUE)))

cat("\n-- tables with missing cells --\n")
print(df[!is.na(df$miss) & df$miss > 0,
         c("key", "cells", "miss", "beyond", "mask", "none", "status",
           "status_unread", "status_unknown", "extra", "nan_words", "legend")])

cat("\n-- 0xa pages with NO declared legend (must be empty) --\n")
print(df[!is.na(df$status) & df$status > 0 & df$legend == 0L,
         c("key", "status", "legend")])

cat("\n-- tables with unreadable/contradictory pages (must be empty) --\n")
print(df[!is.na(df$unreadable) & (df$unreadable > 0 | df$contradictory > 0),
         c("key", "mask", "unreadable", "contradictory", "nan_words")])
