## Submission

This is a new release (0.2.0). The package has not previously been published
on CRAN.

## Test environment

* local: macOS (aarch64-apple-darwin), R 4.6.0, `R CMD check --as-cran`

## R CMD check results

0 errors | 0 warnings | 0 notes

(One informational NOTE about this being a new submission is expected and not
listed above.)

## Downstream dependencies

There are no downstream dependencies for this package, as it has not yet been
published.

## Notes for reviewers

* All examples and vignettes that need network access are wrapped in
  `\donttest{}` / guarded so `R CMD check` does not require network access to
  pass; the bundled sample table (`inst/extdata/98100044.ivt`) lets the core
  examples run offline.
* The package downloads and parses publicly available Statistics Canada
  *Beyond 20/20* `.ivt` tables; the data itself is published under the
  Statistics Canada Open Licence, noted in the DESCRIPTION.
