# testing.md — the dev workflow and the regression ledgers

`.ivt` and large `.csv` files are git-ignored; **never commit them.** Every
integration test therefore auto-skips when the files it needs are absent.

## Sample files (unit-level integration tests)

| env var | file (fallback path) |
|---------|----------------------|
| `CANIVT_SAMPLE_IVT` | `98100241.ivt` (`~/projects/censusmapper-import/data/raw/98100241/`) |
| `CANIVT_SAMPLE_IVT_F2` | `98100023.ivt` (`/tmp/t23/`) |
| `CANIVT_SAMPLE_IVT_F2_4D` | `98100129.ivt` (`/tmp/t129/`) |
| `CANIVT_SAMPLE_IVT_1991` | `1003011.IVT` |

## The corpus is the regression suite

The local corpus is one folder per table under `CANIVT_IVT_CACHE`
(`~/data/ivt_raw`) — 170 tables, ~366 M stored cells — so all three sweeps over
it are **opt-in**:

```sh
CANIVT_CORPUS_TESTS=1 Rscript -e 'devtools::test(filter = "corpus")'
```

Three ledgers, three different contracts:

| ledger | test | asserts | re-measure with |
|---|---|---|---|
| `fixtures/corpus-ledger.csv` | `test-corpus.R` | per table: the `ivt_is_supported()` verdict, strict-mode cleanliness, the exact non-zero cell count | — |
| `fixtures/status-ledger.csv` | `test-status.R` | the cell-status tail per table; `unreadable` / `contradictory` are the two columns that must never move | `dev/msweep.R` |
| `fixtures/complete-ledger.csv` | `test-complete.R`, `test-stream.R` | the **fold**: grid size `prod(counts)` for all 170 tables (read off the layout, so it is checked even where the table is too big to complete under the sweep budget) and, for the 126 under it, `rows`/`stored`/`zeros`/`flagged`/`symbolled`/`vsum` | `dev/csweep.R` |

Notes on what each contract is protecting:

- `strict_clean = FALSE` rows are the **known** fallbacks — they must *warn*, not
  error, so both a vanished warning and a new failure trip the test.
- The corpus and status sweeps read with **`complete = FALSE`**: they are
  contracts about the *store* (the file's own stored-value count is what a decode
  regression moves), and completing 4.3 billion corpus rows would be the sweep's
  cost rather than its subject.
- `rows == grid` in the complete ledger is the assertion that catches an
  optimization quietly mislaying a page's zeros; `stored` is cross-checked
  against `corpus-ledger.csv`'s `n_cells`.
- `test-stream.R` runs on the complete ledger, decoding every sliceable table one
  outer member at a time and requiring the concatenation to be the whole-table
  decode.
- `dev/msweep.R` also produces the corpus status figures quoted in the notes; see
  `dev/README.md`.

**When a gap is closed or a table onboarded, update the ledger row *and*
[`coverage.md`](coverage.md) in the same commit.** `markers.md` is likewise
self-checked by `test-markers.R` (catalog↔code equality plus an opt-in corpus
sweep that fails on an un-catalogued marker) and must move in the same commit as
the recognizer.

## The suite is parallel

`Config/testthat/parallel: true` splits the *test files* across processes. The
three corpus sweeps each loop over the whole ledger **inside one file**, so
file-level splitting cannot touch them: they do their reads through
`ivt_test_pmap()` (`tests/testthat/helper-parallel.R`) in a pre-pass and then
assert **serially** over the collected results.

- **`expect_*()` must never be called from a forked child** — testthat's reporter
  is process-local, so a child's expectations are silently lost. A sweep's worker
  therefore captures its own errors and warnings (`ivt_test_capture()`) and
  returns them as data.
- Workers default to **half the physical cores** (each holds a whole decoded
  table — memory is the binding constraint, not CPU). Override with
  `CANIVT_TEST_CORES`; `=1` restores the old serial behaviour exactly.
- Measured: corpus 8 m 28 s CPU → 1 m 50 s wall; markers 40 s.
- Trap: testthat sources test files at **run** time, so editing one mid-run
  corrupts that run.
