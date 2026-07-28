# csweep.R -- corpus-wide COMPLETED-GRID sweep.
#
# The corpus ledger and the status ledger are both contracts about the STORE:
# both sweeps read `complete = FALSE`. Nothing, therefore, regression-tested the
# fold that turns the store into the published table -- and an optimisation that
# quietly mislays a page's zeros would pass the whole suite. This sweep is that
# net's measurement.
#
# Per table it records:
#
#   grid        prod(lay$counts) -- the published grid, from the LAYOUT alone
#               (no decode), so every table is covered whatever its size
#   rows        nrow(x$cells) with `complete = TRUE`; must equal `grid`
#   flagged     cells with `value = NA` (the file states a reason, or its mask
#               says only "not a zero")
#   symbolled   flagged cells whose code the file's own legend names
#   zeros       published zeros -- absent, and the file says nothing about it
#   stored      cells that carry a value; must equal the corpus ledger's n_cells
#   vsum        the value sum, so a mis-scattered value moves a column
#
# The grid identity `stored + zeros + flagged == rows == grid` is the whole
# point: it fails the moment a page's absences land in the wrong bucket.
#
# Tables whose grid exceeds `--budget` (default 5,000,000 cells) are measured
# for `grid` only -- completing the corpus's 4.3 billion rows would be the
# sweep's cost rather than its subject.
#
#   Rscript dev/csweep.R [out.csv] [budget]
#
# Env: CANIVT_IVT_CACHE (corpus root, one folder per table; falls back to
# ~/data/ivt_raw), CANIVT_TEST_CORES (workers; default half the cores -- each
# holds a whole completed grid, so memory is the binding constraint), CANIVT_PKG
# (package root; defaults to the working directory).

pkg <- Sys.getenv("CANIVT_PKG")
if (!nzchar(pkg)) pkg <- "."
suppressMessages(devtools::load_all(pkg))

cache <- Sys.getenv("CANIVT_IVT_CACHE")
if (!nzchar(cache)) cache <- path.expand("~/data/ivt_raw")
args <- commandArgs(trailingOnly = TRUE)
out_csv <- args[1L]
if (is.na(out_csv)) out_csv <- file.path(tempdir(), "csweep.csv")
budget <- suppressWarnings(as.numeric(args[2L]))
if (is.na(budget)) budget <- 5e6

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
  o <- list(key = k, want_stored = led$n_cells[i], grid = NA_real_,
            rows = NA_real_, stored = NA_real_, zeros = NA_real_,
            flagged = NA_real_, symbolled = NA_real_, vsum = NA_real_,
            err = NA_character_)
  raw <- readBin(f, "raw", file.size(f))
  lay <- tryCatch(ivt_quietly(ivt_layout(raw)),
                  error = function(e) { o$err <<- conditionMessage(e); NULL })
  rm(raw)
  if (is.null(lay)) return(o)
  o$grid <- prod(as.numeric(lay$counts))
  if (o$grid > budget) return(o)                  # geometry only, no decode
  x <- tryCatch(ivt_quietly(read_ivt(f)),
                error = function(e) { o$err <<- conditionMessage(e); NULL })
  if (is.null(x)) return(o)
  cl <- x$cells
  o$rows <- nrow(cl)
  na <- is.na(cl$value)
  o$flagged <- sum(na)
  o$symbolled <- sum(!is.na(cl$symbol))
  o$zeros <- sum(cl$value[!na] == 0)
  o$stored <- o$rows - o$flagged - o$zeros
  o$vsum <- sum(cl$value, na.rm = TRUE)
  rm(x, cl); gc(verbose = FALSE)
  o
}, mc.cores = cores)

res <- Filter(Negate(is.null), res)
df <- do.call(rbind, lapply(res, function(r)
  as.data.frame(r, stringsAsFactors = FALSE)))
utils::write.csv(df, out_csv, row.names = FALSE)
cat("tables", nrow(df), " completed", sum(!is.na(df$rows)), "->", out_csv, "\n")

cat("ERRORS:", sum(!is.na(df$err)), "\n")
if (any(!is.na(df$err))) print(df[!is.na(df$err), c("key", "err")])

d <- df[!is.na(df$rows), ]
cat("GRID MISMATCH (rows != grid):", sum(d$rows != d$grid), "\n")
print(d[d$rows != d$grid, c("key", "grid", "rows")])
cat("STORE MISMATCH (stored != ledger n_cells):",
    sum(d$stored != d$want_stored), "\n")
print(d[d$stored != d$want_stored, c("key", "want_stored", "stored")])

cat("\n-- totals over the completed subset --\n")
for (c_ in c("grid", "rows", "stored", "zeros", "flagged", "symbolled"))
  cat(sprintf("%-10s %s\n", c_,
              format(sum(d[[c_]]), big.mark = ",", scientific = FALSE)))
cat(sprintf("%-10s %s\n", "grid(all)",
            format(sum(df$grid, na.rm = TRUE), big.mark = ",",
                   scientific = FALSE)))
