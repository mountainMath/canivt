# Parallel harness for the opt-in corpus sweeps.
#
# testthat's own parallelism (`Config/testthat/parallel` in DESCRIPTION) splits
# work by FILE. That covers the unit suite, but the three corpus sweeps
# (test-corpus.R, test-markers.R, test-geo-snapshot.R) each loop over the whole
# ~130-table ledger INSIDE ONE FILE, so file-level splitting cannot touch them
# and the suite's wall clock is whatever the slowest single file takes.
#
# They are, however, embarrassingly parallel: one independent read per table,
# no shared state, results are pure values. So each sweep does its expensive
# work through `ivt_test_pmap()` in a pre-pass, then asserts SERIALLY over the
# collected results. Assertions stay on the main process -- `expect_*()` is
# never called from a forked child (testthat's reporter is process-local, so a
# child's expectations would be silently lost), and a failure still reports with
# its normal message and location.
#
# Degrades to `lapply()` on Windows or one core, in which case the sweeps behave
# exactly as they did before.

# Worker count. `CANIVT_TEST_CORES` overrides; otherwise half the physical cores
# -- each worker holds a whole decoded table (the largest is ~8.7M cells, and
# `geo_attributes = TRUE` reads are heavier still), so MEMORY, not CPU, is the
# binding constraint. Never more workers than jobs.
ivt_test_cores <- function(n_jobs = Inf) {
  env <- suppressWarnings(as.integer(Sys.getenv("CANIVT_TEST_CORES", "")))
  cores <- if (!is.na(env) && env >= 1L) {
    env
  } else {
    n <- parallel::detectCores(logical = FALSE)
    if (is.na(n)) 1L else max(1L, n %/% 2L)
  }
  # mclapply forks; there is no fork on Windows.
  if (.Platform$OS.type != "unix") cores <- 1L
  # Nesting guard: `CANIVT_CORPUS_TESTS=1 devtools::test()` (no filter) runs the
  # three heavy files CONCURRENTLY as testthat file-workers, and each would then
  # fork a full complement of its own. Halve inside a testthat parallel worker so
  # the product stays bounded. An explicit CANIVT_TEST_CORES is honoured as-is.
  if (is.na(env) &&
      isTRUE(tryCatch(testthat::is_parallel(), error = function(e) FALSE)))
    cores <- max(2L, cores %/% 2L)
  as.integer(max(1L, min(cores, n_jobs)))
}

# Map `f` over `x`, in parallel where possible. `f` must CAPTURE its own errors
# and warnings and return them as data -- a child that throws yields a
# `try-error`, which is converted to a marker list so the serial assertion pass
# fails naming the table rather than aborting the sweep.
#
# `mc.preschedule = FALSE` gives one child per job: table cost varies by two
# orders of magnitude (a 184-cell guard file vs 8.7M cells), so round-robin
# prescheduling would leave workers idle behind one long straggler.
ivt_test_pmap <- function(x, f, ...) {
  cores <- ivt_test_cores(length(x))
  if (cores <= 1L) return(lapply(x, f, ...))
  res <- parallel::mclapply(x, f, ..., mc.cores = cores, mc.preschedule = FALSE)
  lapply(res, function(r) {
    if (inherits(r, "try-error")) {
      list(worker_error = conditionMessage(attr(r, "condition")))
    } else if (is.null(r)) {
      # a child killed outright (OOM) returns NULL rather than a value
      list(worker_error = "parallel worker produced no result (killed?)")
    } else {
      r
    }
  })
}

# Read one corpus table's bytes, recording every condition it raises, and return
# the result as plain data. Shared by the corpus and geo-snapshot sweeps.
#
#   value    -- `expr`'s value, or NULL if it errored
#   error    -- the error message, or NULL
#   warnings -- the most-specific class of each warning, in emission order
#   fallback -- how many of those inherited `canivt_fallback`
ivt_test_capture <- function(expr) {
  warns <- character(0)
  fb <- 0L
  err <- NULL
  val <- withCallingHandlers(
    tryCatch(expr, error = function(e) { err <<- conditionMessage(e); NULL }),
    warning = function(w) {
      warns[[length(warns) + 1L]] <<- class(w)[[1L]]
      if (inherits(w, "canivt_fallback")) fb <<- fb + 1L
      invokeRestart("muffleWarning")
    }
  )
  list(value = val, error = err, warnings = warns, fallback = fb)
}
