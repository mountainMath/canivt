# Open test failures (recorded 2026-11-10)

A pick-up note. Delete each section when it is closed, and the file when it is
empty.

The full suite with the corpus enabled

```sh
CANIVT_CORPUS_TESTS=1 CANIVT_IVT_CACHE=~/data/ivt_raw Rscript -e 'devtools::test()'
```

reports **237 failing expectations**. They were measured twice on 2026-11-10 —
at `334f5a7` (clean `main`) and with the issue #5 geography change applied — and
the two failure sets are identical, message for message and hash for hash. So
none of this was introduced by the #5 work, and none of it has been diagnosed
yet. Without `CANIVT_CORPUS_TESTS` the suite does not run these tests at all,
which is how they went unnoticed.

## 1. `test-geo-snapshot.R` — 236 failures, all 170 fixture tables

| column | failing tables |
|--------|---------------:|
| `light_hash` | 170 (every row of the fixture) |
| `full_hash` | 25 |
| `light_warnings` | 37 |
| `full_warnings` | 4 |

`fixtures/geo-snapshot.csv` was last regenerated on 2026-07-27 (`61687b4`); 27
commits have landed since, and neither `test-geo-snapshot.R` nor
`helper-geo-snapshot.R` changed in that time.

What is known:

- **Every `light_hash` differs.** That is not 170 independent regressions; it
  points at one change that touches every table's default-path geography frame
  (a column added, dropped, renamed or retyped in `metadata$geographies`, or in
  what `geo_snap_one()` feeds the digest). **Find that one change first** —
  until it is identified the hashes cannot tell a real per-table regression from
  the systematic shift.
- **The warning columns moved towards FEWER warnings**, e.g. `95f0491xcb01004`
  expected `canivt_descriptor_from_slots` and now raises nothing;
  `95f0437xcb01001` expected `canivt_declared_count|canivt_descriptor_from_slots`
  and now raises nothing. That is what the zero-suppressed records read
  (`8d6df26`, `4f4afb1`) should do: the 82-byte dimension records became the
  quiet primary descriptor path. Classes appearing in the 41 changed warning
  expectations: `descriptor_from_slots` 22, `descriptor_lenient` 17,
  `geo_datadim` 16, `declared_count` 11, `fallback` 7, `geo_custom` 5,
  `chunked_count` 4, `geo_bare_codes` 4, `geo_by_name` 2, `container_count` 1,
  `descriptor_reloc` 1. Not checked: whether any table GAINED a warning.

Not known: whether any geography content actually changed. Suggested order:

1. Check out `61687b4`, dump the geography frame for two or three small tables,
   and diff against `HEAD` to name the systematic change.
2. Bisect the 27 commits on one table's `light_hash` if step 1 is not obvious.
3. Review the 41 warning changes as a list (lost vs gained).
4. Only then regenerate — the fixture is a frozen baseline, so regenerating
   before step 1 would bless whatever is there:

   ```sh
   CANIVT_IVT_CACHE=~/data/ivt_raw Rscript -e \
     'devtools::load_all("."); source("tests/testthat/test-geo-snapshot.R"); geo_snapshot_regen()'
   ```

The fixture also has 170 rows against 178 ledger rows, so 8 ledgered tables have
no snapshot; the regeneration picks them up.

## 2. `test-corpus.R:50` — "every corpus folder has a ledger row" — 1 failure

13 folders in `~/data/ivt_raw` have no row in `fixtures/corpus-ledger.csv`:

| folder | note |
|--------|------|
| `ea_profile_1986_2A`, `ea_profile_1986_2B` | issue #5; decode, geography validated against the 1986 GAF. Ready to ledger. |
| `ea_profile_1981_2B` | issue #6; decodes, but rows 418–422 are wrong in the source file past EA 4,096 — ledger with that caveat (see `decode-history.md`). |
| `98100044` | `61687b4` dropped this as a **duplicate** corpus folder; it is back on disk (`.ivt` + `.zip`). Probably delete the folder again rather than ledger it. |
| `98-10-0023-01` | holds `98100023.ivt` — looks like a second copy of an already-ledgered table under a different folder name. Check, then delete or ledger. |
| `1004521`, `93-337-X`, `93-338-X`, `94-581-XCB2006007`, `95F0168X`, `95F0171X`, `98F0173X`, `98F0174X` | not looked at. Run the onboarding recipe (`onboarding-backlog.md`). |

Each ledgered table also needs its `status-ledger.csv` / `complete-ledger.csv`
rows (`dev/msweep.R`, `dev/csweep.R`) and a `coverage.md` line.

## 3. Not a test failure, but open: 17× `canivt_descriptor_reloc` on the 1986 EA profiles

Both `ea_profile_1986_2A` and `_2B` raise `canivt_descriptor_reloc` 17 times per
read. It predates the #5 change and the decode is correct, but the same
fallback firing 17 times suggests a probe that should be quiet
(`ivt_quietly()`) or memoised, or a descriptor that should be found by the
records path without relocating at all.
