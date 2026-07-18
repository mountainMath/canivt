# Parser consolidation & sharpening plan

Findings of a comprehensive parser review (2026-07-10): opportunities to
consolidate duplicated code, harmonize divergent handling, and sharpen the
parser further toward a purely metadata-driven read with fewer fallback paths.
Work through this top-down; check items off (and update `coverage.md` /
`decode-history.md` where a real format gap closes) as they land.

The corpus regression ledger (`tests/testthat/test-corpus.R`, opt-in via
`CANIVT_CORPUS_TESTS=1`) asserts exact cell counts *and* that known fallbacks
still warn, so it catches both silent breakage and silently-vanishing
fallbacks — run it for every step below.

## 1. Correctness-adjacent fixes (small, do first) — DONE 2026-07-10

- [x] **Reserve the `geo`/`value` slugs.** `ivt_f2_data_dims()` made slugs
  unique only among themselves; `ivt_layout()` adds `geo` and `ivt_decode()`
  appends `value`. A dimension whose leading word slugs to `value` — and
  *"Value of dwelling"* is a real census dimension — had its member-id column
  silently overwritten by `out$value <- ...` (decode.R) and then dropped by
  `ivt_f2_tidy()`'s `setdiff(names, c("geo","value"))`. Fixed: slugs are
  uniquified against the reserved names (`ivt_dim_slugs()`, codebook-f2.R).
- [x] **`canivt_fallback` umbrella class.** `ivt_fallback()` used the caller's
  `class` verbatim, so `canivt_skipped_pages` (decode.R) and
  `canivt_descriptor_reloc` (codebook-f2.R) warnings did **not** carry
  `canivt_fallback` — unlike `canivt_geo_count`/`canivt_geo_flow`/... which
  appended it manually. `ivt_quietly()` would not muffle them and
  `canivt_fallback`-keyed handlers would not see them. Fixed: `ivt_fallback()`
  now appends the umbrella itself (warning **and** strict-mode `_error`
  classes); the manual appends at the call sites are gone.

## 2. Dead code to retire — DONE 2026-07-10

Confirmed by grep: definition + tests only, no production callers.

- [x] `ivt_f2_read_block_dir()` (codebook-f2.R) — removed (zero callers;
  coverage.md now names `ivt_f2_read_dir_at()`).
- [x] `IVT_F2_REC_BYTES` / `IVT_F2_PRESENCE_LEN` (container-f2.R) — removed
  (only referenced each other; the comment mentioned `ivt_f2_rec_bytes()`,
  which no longer existed).
- [x] `ivt_geography_count()` + `ivt_entry_valid()` + `IVT_IDX_STRIDE`
  (container.R) — removed with the single regression assertion
  (test-decode.R keeps the 174-geography fact and a comment recording the
  348 artefact); `ivt_family()` had not used it since detection moved to
  `ivt_f2_decodable()`.
- [x] `ivt_f2_header_layout()` — KEPT deliberately: it is the reference
  implementation of the header map documented in ivt-format.md ("Header
  layout map") and the vignette, exercised by the header regression tests.
  Its docstring now states it is a diagnostic/documentation entry point,
  not part of the decode path.
- [x] CLAUDE.md / coverage.md / ivt-format.md / decode-history.md "legacy
  counter" caveats updated.

## 3. Per-read parse context (the enabling refactor) — DONE 2026-07-10

There was no memoization anywhere: `ivt_f2_descriptor(raw)` was re-parsed from
13 call sites, `ivt_f2_geo_dim_index()` from 12, `ivt_f2_geo_count()` from 9 —
each descriptor parse re-running `ivt_f2_dim_count_reconcile()` (which
strict-parses slot directories) — and each dimension's block directory was
decoded at least three times (labels / ordinals / footnotes).

Landed as a TRANSPARENT per-raw memo (`R/memo.R`) rather than an explicit
`ctx` argument threaded through ~40 signatures: same wins, no signature
churn, internals stay directly callable with a plain raw vector (as the
tests and detection gate do). Design points:

- [x] `ivt_memo(raw, key, compute)`: single slot keyed by
  `identical(raw, slot$raw)` (byte-exact — a doctored copy never reuses the
  original's parse). Memoized: `ivt_f2_descriptor`, `ivt_layout`,
  `ivt_f2_dim_dir` (per k), `ivt_f2_geo_dim_index`, `ivt_f2_geo_count`,
  `ivt_f2_geo_schema`, `ivt_f2_find_directory`.
- [x] Warnings raised inside a memoized compute are recorded and REPLAYED on
  every hit, so a warm cache is exactly as loud as a cold one (the loud-
  fallback contract survives memoization); errors are never cached (strict
  mode stays strict). `read_ivt()`/`ivt_metadata()` clear the slot on exit.
- [x] The memo made the metadata-driven gates free to consult, which exposed
  and fixed the REAL metadata hot spot: `ivt_f2_geo_inline()`'s marker-region
  fallback scan had no schema gate (unlike `flow_dir`/`inline_dir`), so every
  large schema'd table walked its whole multi-MB geography codebook through
  the pure-R Pascal scanner. Gated on `ivt_f2_geo_schema()`:
  `ivt_metadata(98-10-0023)` 20 s → 1.7 s.
- The `ivt_f2_dim_slots(raw, m =)` parameter STAYS: it is what breaks the
  descriptor → reconcile → slots cycle *while the descriptor compute is in
  flight* (memoization cannot help mid-compute).
- The `ivt_f2_dim_dir_labels()` / `ivt_f2_dim_dir_ordinals()` wrappers stay
  as-is — with `ivt_f2_dim_dir` memoized their duplicate directory decode is
  gone; merging them is now a ~15-line cosmetic item (fold into §4's helper
  work if convenient).
- [x] `ivt_f2_check_geo_count()` no longer re-parses the descriptor per call.

## 4. Duplicated logic → shared helpers (by payoff)

- [x] **Four chunk-group walkers — shared GEOMETRY extracted** (2026-07-11).
  The "groups of G chunks (`ivt_f2_geo_group_sizes()`), each attribute = G
  language-A blocks then G language-B blocks, chunk size `min(256, remaining)`,
  trim pow-2 slot padding" walk is implemented four times with different
  tolerances: `ivt_f2_geo_dguids_dir()` (identical-copy check),
  `ivt_f2_dim_dir_label_chunks()` (skip-nonmatching `take_run`),
  `ivt_f2_geo_attrs_dir()` (NA-hole pattern + dense re-alignment),
  `ivt_f2_geo_inline_dir()` (partial-first rotation + `skip` prefix). The
  duplicated part is the group/chunk **geometry** (group sizes → group start
  member → per-chunk sizes → member positions), copied verbatim as
  `starts`/`M`/`chunk_sz` in `dguids_dir` + `attrs_dir` and as the
  `chunk_of()` / `chunk_len()` closures in `inline_dir` / `label_chunks`
  (algebraically verified identical across all four). Extracted to one
  `ivt_f2_chunk_layout(n)` (codebook-f2.R, beside `ivt_f2_geo_group_sizes()`)
  returning per group `list(G, start, size, chunk)` plus `$sizes`/`$n_chunks`;
  all four walkers now consume it, their load-bearing block-alignment tolerances
  left **untouched** (each set is load-bearing for specific vintages).
  Verified byte-identical: the four walkers' outputs (+`ivt_f2_dim_dir_labels()`,
  which routes through `label_chunks`) are `identical()` on all 40 corpus tables
  before/after; unit suite FAIL 0 / PASS 994; corpus ledger FAIL 0 / PASS 120.
  The deeper "one parameterized consumer carrying all four *behaviors*" was
  evaluated and **not pursued**: the number of runs (2 / 2·nattr / discovered)
  and the block→member alignment differ so much that a single consumer degenerates
  to the geometry above plus a per-walker `place_chunk` / `combine_runs` callback,
  scattering the load-bearing logic into closures with no maintainability gain
  over the current per-walker form (same reasoning the strict-first item at §4
  used to keep classification per-walker). The geometry extraction captures the
  real, drift-prone duplication.
- [x] **Strict-first entry parsing** (2026-07-10, scoped):
  `ivt_f2_dim_dir_label1()` / `ivt_f2_dim_dir_ordinal1()` — the only readers
  that were *purely* run-scanner — now read values strict-first through the
  shared `ivt_f2_dir_member_arrays()` walk (see next item). The flow reader
  was already strict-first. `ivt_f2_geo_attrs_dir()` /
  `ivt_f2_geo_inline_dir()` keep run-scanner CLASSIFICATION by documented
  design (the `k == 2·nattr·Σsizes` gate must see a stable block set; their
  VALUES are already strict-first) — revisit only as part of the walker
  unification above, where the gate itself gets restated on strict counts.
- [x] **EN/FR pair pick** (2026-07-10): `ivt_f2_pick_en(a, b)` →
  `list(en, fr, en_first)` replaces the inlined idiom in
  `ivt_f2_dim_dir_label1()` (both sites, via the shared loud
  `ivt_f2_label_lang_fallback()` — the verbatim-duplicated warning is gone),
  `ivt_f2_geo_root_dir()`, `ivt_f2_geo_names()`, `ivt_f2_geo_attrs_dir()`,
  `ivt_f2_geo_inline_dir()`, `ivt_f2_dqf_legend()` and
  `ivt_f2_legacy_identity()`. (`ivt_f2_inline_table()`'s strict-inequality
  variant and `ivt_f2_master_identity()`'s which.min-over-candidates shape
  stay explicit.)
- [x] **Name prefix-match** (2026-07-10): `ivt_f2_name_match(a, b)` replaces
  the four copies in `ivt_f2_match_dim()`, `ivt_f2_dir_marker_entry()`,
  `ivt_f2_geo_simple_schema()`, `ivt_f2_geo_marker_region()`.
- [x] **Schema-stem → column mapping** (2026-07-10): `ivt_f2_stem_col()`
  beside `IVT_F2_ATTR_FIELD` replaces the two identical closures;
  `ivt_f2_geo_slot_map()` keeps its field→slot direction (same rule, noted).
- [x] **Pair-swap + MSB-first bit reads** (2026-07-10):
  `ivt_bits_pairswap_msb(bytes, bit)` (decode-f2.R) now backs both
  `ivt_f2_record_present()` and `ivt_f2_footnote_bitmap()`. The DGUID
  `probe()`'s dense-header skip stays (it is a cheap O(1) prefix probe, not a
  bitstream read).
- [x] **Directory-entry validation** (2026-07-10): `ivt_dir_entry(raw, o, n)`
  → `list(off, size, marker)`/NULL (container-f2.R) replaces the five inlined
  copies in `ivt_idx0()`, `ivt_page_preflight()` (×2), `ivt_decode()` and
  `ivt_f2_entry_valid()` (which adds its 1024 header floor on top).
- [x] **Marker byte model single-sourced** (2026-07-10): `ivt_f2_marker_b0` is
  now DERIVED from `IVT_MARKER_WIDTHS {2,4,8} × high nibble {0x8,0xa}`; the
  width checks in `ivt_value_trailer()` / `ivt_decode_page()` /
  `ivt_page_preflight()` use the same constant, so the two expressions of the
  model can no longer drift.
- [x] **`ivt_f2_dim_dir_label1()` / `ivt_f2_dim_dir_ordinal1()`**
  (2026-07-10): the shared `ivt_f2_dir_member_arrays(raw, dir, cnt, rows,
  accept, max_keep)` iterator now carries the candidate walk for both
  (label1: first two non-ordinal clean arrays after the marker; ordinal1: the
  last 1..cnt permutation anywhere), with strict-first values and the
  run-scanner's established trailing-`cnt` slice as the fallback.
- [x] **Geography column ordering** (2026-07-10): `IVT_GEO_COLS` +
  `ivt_geo_col_order()` (read-f2.R) now order both `metadata$geographies` and
  `ivt_f2_geographies()` identically (the documented leading schema
  member_id/label/name/uid first, then the French copies, then attributes;
  undecoded columns skipped, extras like the flow sides / has_data appended).
  The two entry points previously imposed *different* orders. (`ivt_f2_geo_attrs_dir()`'s internal tibble keeps its own order —
  it feeds through the shared ordering at the boundary.)
- [x] **uid naming — resolved as WON'T DO** (2026-07-10): the internal reader
  columns (`dguid` in the attribute table, `geouid` in the inline table)
  deliberately mirror the file's own field vocabulary (schema DGUID vs the
  bare pre-DGUID GEOUID) and are asserted throughout the test suite as the
  reader contract; the public surface is already uniformly `geo_uid`, renamed
  at exactly the two path boundaries (`ivt_f2_geo_light()`,
  `ivt_f2_geographies()`). Renaming at source would be wide churn for no
  behavioral gain.

## 5. Harmonization

- [x] **`ivt_f2_geo_light()` vs `ivt_f2_geographies()` — resolved as WON'T MERGE**
  (2026-07-11). The premise ("parallel ladders over the same readers") does not
  hold on inspection: the two are **different reader sets** producing **two
  deliberately-different, separately-tested output contracts**, verified by
  snapshotting `metadata$geographies` (light) vs `ivt_f2_geographies()` (full)
  across the whole corpus:
  - **Different readers, not just shapes.** For the big chunked tables the light
    path is **uid-only** (98-10-0023 / 98-10-0013 → `member_id, geo_uid`, a fast
    positional DGUID scan), whereas the full path runs the ~30 s complete
    attribute scan (all 16 columns). They are not the same read gated differently.
  - **Different contracts.** The full tibble **keeps all-NA columns by design**
    (1003011 keeps all-NA `geo_type_abbr`/`tnr_short_form`; 98-10-0013 keeps all-NA
    `tnr_short_form`) and the tests assert its column set (`dqf_note_truncated %in%
    names(g)`, the truncation-flag count). The lean default packs a **list with
    all-NA columns dropped**. Collapsing to one entry would force one contract on
    the other — breaking either the lean default or the tested full tibble.
  - **The "recompute" is cheap.** On `geo_attributes = TRUE` the discarded
    light work is a uid scan (~1 s) in front of the 30 s full scan it precedes;
    not worth a contract-breaking merge.
  The only genuinely shared step is the inline-first read + `geouid`→`geo_uid`
  rename (~3 lines), too small to abstract. Both functions carry a cross-reference
  comment noting they are intentionally distinct.
- [x] **`ivt_idx0()` vs `ivt_f2_find_directory()`** (2026-07-11): the low-16-bit
  `+ k·65536` unwrap now lives once in `ivt_f2_dir_anchor_header()`
  (container-f2.R), and `ivt_idx0()` (container.R) is a thin wrapper over it
  (unwrap → validated anchor, else the historical constant). Both the decode and
  metadata sides now resolve a >64 KiB directory positionally instead of the
  metadata finder falling to the loud marker scan (verified: 98100013 k=1 /
  95F0250 k=2 give equal `ivt_idx0()` == `ivt_f2_dir_anchor_header()` ==
  `ivt_f2_find_directory()$lo`, decodes unchanged). Validation now uses the
  documented `>= 1024` header floor (`ivt_f2_entry_valid()`) on both sides. The
  fallback marker scan's `mk >= 1e5` floor is now truly last-resort (only if
  `@558` is absent/corrupt) and left as-is.
- [x] **Loudness of content-based language assignment — philosophy documented**
  (2026-07-11). Chose the "document why per-group content scoring is primary"
  option (not "pin from schema `_EN`/`_FR` naming"): the geography block language
  order genuinely varies per group (most EN-first, the geography ROOT group
  FR-first), so there is no schema-declared order to pin against — `frscore` is
  the correct primary read there, not a fallback, hence silent. That is the
  opposite of `ivt_f2_dim_dir_label1()`, whose dictionary schema block DOES fix
  the order, making `frscore` a genuine (loud) fallback when the block is absent.
  The philosophy is now stated once at the shared `ivt_f2_pick_en()` (codebook-f2.R)
  with a cross-reference from the loud `ivt_f2_label_lang_fallback()` (dimdir.R).
  Same function, different status by context — no code change, the asymmetry is
  correct.

## 6. Sharpening toward metadata-driven (retiring fallback paths)

- [~] **Decode the `[81 01]` dense bitstream — INVESTIGATED, hypothesis
  FALSIFIED** (2026-07-11). The premise was that the `[81 01]` bitstream might be
  the same pair-swap/MSB-first *member*-presence convention as the `[84 01]`
  footnote bitmap, which would make dense chunks positional in their own right and
  retire the sibling-alignment heuristic. Measured on 98-10-0662's six bit-headed
  dense geography arrays: it is **not** member-granular. For each entry
  `nbits` (449, 446, 641, …) ≫ the ~91 members, and crucially the bitstream's
  **popcount == the records-region byte length + 1** exactly (282 = 281+1,
  279 = 278+1, 474 = 473+1, …), where the records region is `Σ(1 length byte +
  text bytes)` over the packed records. So the bitstream is a **per-byte** map of
  the packed records region, not a per-member presence map — it cannot place
  members positionally, and understanding it fully would still need the record
  lengths. The sibling-alignment heuristic (spread dense values into the NA
  pattern of the entry's plain-array siblings) is the correct approach and already
  decodes these **cell-exact** (98-10-0662: 91/91). Leaving it in place;
  `ivt_f2_dir_entry_members()`'s comment is accurate. No format gap to close here.
- [x] **Doubled-name marker entry identified STRUCTURALLY** (2026-07-11).
  Confirmed the hypothesis empirically across the corpus: within a slot directory
  already validated by index + `n_entries`, the marker is the entry that OPENS
  with `81 02 02 00` **and carries a printable name** — and there is **never more
  than one** such entry per directory (152 of 155 dimension directories have
  exactly one; the other 3, the ord-08035 custom export, have none, exactly where
  the descriptor name also fails). The `len ~16` nameless `81 02 02 00` stubs that
  7 directories additionally carry are excluded (no printable run).
  `ivt_f2_dir_marker_entry()` (dimdir.R) now resolves the marker structurally and
  keeps the descriptor name only to disambiguate the never-observed >1-named case
  (prefix match or the >=8-char SHORT/LONG cro-pair hit). Byte-identical to the old
  name-match on all 155 directories; the win is robustness — a dimension whose name
  is misread (NA or wrong) still resolves its labels (verified on 98-10-0241), so
  the five-heuristic `ivt_f2_descriptor_name()` recovery is demoted from
  load-bearing to a cross-check. Corpus ledger clean.
- [x] **`ivt_geo_arrays()` retired** (2026-07-11) — took the plan's "Better"
  path. A full-corpus branch trace of `ivt_f2_geo_light()` showed **no** table
  ever reaches the content fallback (`2b-SIMPLE`): every file resolves via inline
  (step 1), `attrs_dir` (step 2) or uid-only (step 3). So the last year/country
  literals (`"^2021[A-Z]"`, `texts[1] == "Canada"`) went away by deletion rather
  than by patching: `ivt_geo_arrays()` is gone from codebook.R and
  `ivt_f2_geo_simple()` is now schema-only (`ivt_f2_geo_simple_schema()`).
  Verified 98-10-0241 still returns 166 names/DGUIDs byte-identical, and the five
  tables that used to *reach* the content path directly (94F0009 / 98-10-0044 /
  2016387 / 0662 / 2016019) still decode full geography via their real branches.
  (The minimum patch — a cardinality-based name block — was tried and rejected:
  it picked the inline-combined block over the clean-names block, since the
  `"Canada"` literal was silently disambiguating the two.)
- [x] **`ivt_f2_geo_schema()`'s ±128 KiB content window — made LOUD, comment
  de-staled** (2026-07-11). Verified across the whole corpus: all 12 schema'd
  tables (incl. the big 98-10-0023 / 98-10-0174) resolve the geography dictionary
  through the header slot-table `ivt_f2_geo_dict_block()` — the window scan fires
  on **zero** tables, so the "routed through a deeper pointer chain we do not
  decode yet" note was stale (the two-depth `ivt_f2_dim_dir()` indirection covers
  it). Rather than retire (losing robustness on unseen layouts), kept it as a
  genuine last-resort but fixed the real latent bug: it was a **silent**
  content-heuristic scan, against the loud-fallback invariant. It now warns
  `canivt_fallback` *only when it actually supplies a schema the slot table
  could not* (so inline tables, which return NULL, stay quiet), and the comment
  states it never fires on the current corpus. Schema output byte-identical on all
  12 tables.

## 7. Geography: unify on recover-then-specialize (DONE — 2026-07-17)

All six migration steps landed (each gated on: geography snapshot identical +
corpus FAIL 0). The shared Stage 1 (`ivt_f2_geo_entries()`), the single dispatcher
(`ivt_f2_geo_read()`), and the combined-string safety net (`ivt_f2_geo_combined()`)
are in; the two ladders and six Stage-1 copies are gone. A latent full-path bug
(custom/bare tables returned an all-NA tibble) was fixed as a side effect. Two
custom-export tables (EO3278_T1_CDCSD, EO2654_2011_Van) remain geo-NAME gaps needing
dedicated readers — see step 4 and coverage.md. Detail per step below.

Goal (owner request): the geography read is still the most diffuse part of the
parser — **6 layout readers** (`ivt_f2_geo_inline_dir`, `ivt_f2_geo_attrs_dir`,
`ivt_f2_geo_flow_dir`, `ivt_f2_geo_custom`, `ivt_f2_geo_bare_codes`,
`ivt_f2_geo_dguids_dir`) plus a legacy byte-scan stride-walk
(`ivt_f2_geo_attributes` → `ivt_f2_codebook_blocks`/`ivt_f2_geo_groups_chunked`/
`ivt_f2_extract_attr`/`ivt_f2_geo_names`/`ivt_f2_geo_root_dir`), reached through
**two separate fallthrough ladders** (`ivt_f2_geo_light` for `metadata$geographies`
and the front of `ivt_f2_geographies` for `geo_attributes = TRUE`). Each reader
**re-does the same Stage 1** — locate the geography dimension's slot directory
(`ivt_f2_dim_dir(raw, geo_dim)`, *exactly* how the data dimensions are located)
and recover its member arrays — before diverging. And there is **no graceful
fallback**: an unrecognized layout returns NULL and either falls through to
uid-only or trips `ivt_f2_check_geo_count()`/`_names()`.

Target: locate + recover **once** (metadata-driven, shared with the data
dimensions), then run a chain of **specializers** that each interpret the
recovered arrays for uid / label / bilingual label / auxiliary fields (non-return
rate, quality flag, …); if none fits, emit a warning and surface the raw combined
string **verbatim** rather than mis-parsing it. This directly realizes the
owner's model and folds the two ladders + six Stage-1 copies into one path.

### Reader distribution (measured, 51-table corpus, 2026-07-17)

`inline_dir` 25 · `uid_only` (DGUID scan) 9 · `custom` 6 · `attrs_dir` 5 ·
`flow` 4 · `bare_codes` 3. Full-attribute path (`geo_attributes = TRUE`): every
schema'd table resolves via `attrs_dir` **except `98100013`** (ADA), whose
irregular directory drops a trailing partial → it is the **only** table that
still needs the stride-walk + reverse-root override. The corpus ledger reads the
*default* path, so **the stride-walk is not corpus-covered** — the snapshot below
must pin it.

### Target architecture

```
ivt_f2_geo_read(raw, full = FALSE) →                # replaces geo_light + front of geographies
  gi   <- ivt_f2_geo_dim_index(raw)                 # same locator as data dims
  ents <- ivt_f2_geo_entries(raw, gi)               # Stage 1 (SHARED): recover all
  for spec in SPECIALIZERS:                          # Stage 2: ordered, first non-NULL wins
     g <- spec(raw, ents, full)                      #   each interprets `ents`
     if (!is.null(g)) return(finalize(g))
  finalize(ivt_f2_geo_combined(ents))               # Stage 3: verbatim, LOUD (canivt_geo_unparsed)
```

- **Stage 1 — `ivt_f2_geo_entries(raw, gi)` (the real dedup).** Walk the geo slot
  directory; recover every value entry strict-first
  (`ivt_f2_dir_entry_members()`, run-scanner fallback), returning the entry list
  in directory order: `list(off, len, values, dense, strict, n)` with ordinal /
  framing entries flagged (`ivt_f2_is_ordinal`). This is the byte-for-byte Stage 1
  copied today into `attrs_dir`, `inline_dir`, `flow_dir`, `custom`, `bare_codes`,
  `dguids_dir`. It uses the *same primitives* `ivt_f2_dir_member_arrays()` (the
  data-dim label reader) uses.
- **Stage 2 — specializers over the shared entries.** Same interface
  `function(raw, ents, full) → geo-tibble | NULL`; ordered as the ladders are
  today (flow → inline → schema-attrs/uid → custom → bare). Each keeps its
  **own** assembly + parse internals (the load-bearing tolerances below), but no
  longer re-walks the directory. `dguids_dir` (uid) and `attrs_dir` (full) become
  the two faces of the schema specializer, chosen by `full`.
- **Stage 3 — `ivt_f2_geo_combined(ents)` (new, the owner's safety net).** When no
  specializer claims: pick the most member-complete member-length run and expose
  it verbatim as `geo_label` = `geo_name`, `geo_uid` = NA (or a run that is
  unambiguously all-code as the uid), warn `canivt_geo_unparsed` (strict-mode
  error). Guarantees every member gets *a* label on a never-seen layout — the
  behavior absent today.
- **`finalize()`** = the existing tail shared by both entry points:
  `ivt_f2_geo_fill_label` → `ivt_f2_flag_dqf_note_truncation` →
  `ivt_geo_col_order` → `ivt_f2_check_geo_count` / `_names`.

### Risk register — load-bearing tolerances that MUST survive byte-identical

These are why §4 declined a single parameterized consumer; they stay **inside**
their specializers, fed from shared `ents`:

1. `attrs_dir` per-chunk **dense re-alignment** via the plain-array NA-hole
   pattern + the `k == 2·nattr·Σsizes` gate (98-10-0662 aggregate member 26).
2. `inline_dir` **partial-first rotation** + `skip`-prefix search (2006 vintage;
   98-400-X2016120/0328 auxiliary blocks).
3. `flow_dir` is a **code-join, not positional** — anchors on the code/code uid
   array and joins combined records by code; keep as its own specializer.
4. The **stride-walk full read** (`ivt_f2_geo_attributes` fallback +
   `ivt_f2_geo_root_dir`) is the ONLY full reader for `98100013` — demote to
   last-resort inside the schema specializer's `full` branch, do **not** delete.
5. Per-group **language order** varies (root group FR-first) — `ivt_f2_pick_en`
   stays the per-group primary.
6. `dguids_dir` **identical-copy** check + the byte-scan `ivt_f2_geo_dguids`
   last-resort (98-10-0013 reverse-root chunk below the marker region).

### Validation harness (build FIRST, before any code moves)

`scratchpad/geo-snapshot.rds` already captures the **light** path for all 51
tables. Extend to a committed test helper capturing, per table:
- `ivt_f2_geo_light(raw, n_geo)` (default path), AND
- `ivt_f2_geographies(raw)` **including `98100013`, 98100023, 98100478,
  98100662, 1003011** (the full-attribute path the corpus ledger never exercises),
- the exact set + order of `canivt_*` fallback warnings emitted.
Every migration step below must reproduce this snapshot `identical()`, plus the
corpus ledger (`CANIVT_CORPUS_TESTS=1`) FAIL 0.

### Migration steps (each gated on: snapshot identical + corpus FAIL 0)

1. [x] **Snapshot harness** — light + full + warning-set for the tables above.
   DONE 2026-07-17. `tests/testthat/helper-geo-snapshot.R` (capture: a
   deterministic `rlang::hash()` of each read's returned object + the ordered
   `canivt_*` warning set), `tests/testthat/fixtures/geo-snapshot.csv` (the
   frozen 51-table baseline: `light_hash`/`light_warnings` for every ledger
   table + `full_hash`/`full_warnings` for the 16 `GEO_SNAP_FULL` tables — the
   plan's five plus the cheap small schema'd/flow tables), and the opt-in
   `tests/testthat/test-geo-snapshot.R` (regenerate via `geo_snapshot_regen()`).
   Verified GREEN end-to-end against the corpus; every subsequent step must keep
   it so.
2. [x] **Extract Stage 1** `ivt_f2_geo_entries()`; refactor the 6 readers to
   consume it (behavior-preserving; no output change). Biggest, safest win.
   DONE 2026-07-17. `ivt_f2_geo_entries(raw)` (codebook-f2.R) locates the geo
   block directory ONCE (`ivt_f2_geo_block_dir()`, proven byte-identical to the
   `ivt_f2_dim_dir(geo_dim)` the four inline/flow/custom/bare readers used — the
   legacy-slot fallback fires on **no** corpus table) and exposes LAZY, memoized
   per-entry accessors `$records(r)` / `$strict(r)` / `$values(r)` / `$dense(r)`
   over the `$dir` matrix. Laziness is load-bearing: eagerly scanning all 6,244
   entries of 98-10-0023 measured ~17 s, so dguids_dir's O(1) probe path must
   never touch `$records`. All six readers (`dguids_dir`, `attrs_dir`,
   `inline_dir`, `flow_dir`, `custom`, `bare_codes`) now consume it instead of
   re-walking the directory. Cache subtlety: entries are stored via
   `x[r] <<- list(v)`, never `x[[r]] <<- v` (a NULL strict parse via `[[<-`
   deletes the slot and misaligns the cache). Verified against the §7.1
   snapshot: every `light_hash`/`full_hash`/`full_warnings` byte-identical; the
   only delta is 5 tables (3 CBP bare_codes + 2 EO) emitting **one fewer
   duplicate** `canivt_descriptor_*` warning replay (bare_codes no longer
   re-parses the descriptor) — a benign reduction in duplicate noise, output
   unchanged, no fallback vanished; fixture updated to match. Unit suite FAIL 0,
   corpus ledger FAIL 0 / 51 tables.
3. [x] **Single dispatcher** `ivt_f2_geo_read(raw, full)`; point
   `ivt_f2_geo_light` and `ivt_f2_geographies` at it (thin wrappers, contracts
   unchanged — light drops all-NA cols to a list, full keeps the tibble; see
   §5.1, NOT merged). DONE 2026-07-17. One ordered specializer chain both entry
   points share; `full` selects ONLY the schema step (cheap light readers vs the
   comprehensive `ivt_f2_geo_attributes()` scan), gated on `ivt_f2_geo_schema()`
   so a schema-less table falls through. Flow/inline/custom/bare are SHARED,
   which **fixed a latent bug**: the full path (`read_ivt(geo_attributes =
   TRUE)`) previously fell to `ivt_f2_geo_attributes()` for custom/bare tables
   and returned an all-NA tibble (e.g. CRO0163850_CT6 `geo_name = NA`, CBP2007DA
   50,988 rows all-NA); it now decodes them correctly (CRO → "Canada"/20000,
   CBP → the DA codes). `ivt_f2_geo_read()` returns the specializer's NATIVE
   object; the wrappers finalize (light `as.list`+drop-all-NA;
   `ivt_f2_geo_list_to_tibble()` lifts a list return to the full tibble). Light
   output byte-identical corpus-wide; 4 custom/bare full captures added to the
   snapshot's `GEO_SNAP_FULL` guarding the fix. Also **hardened the harness**:
   the warning-set assertion now compares DISTINCT classes, not the raw multiset
   — the memo (§3) replays warnings on every hit, so the count is an artifact
   that shifts with benign refactors (this had produced ±1 duplicate
   `canivt_descriptor_*` churn in §7.2/§7.3); distinct-class still catches any
   new/vanished fallback. Unit FAIL 0, corpus FAIL 0 / 51, geo-snapshot FAIL 0.
   NOTE (for step 4): the two custom exports **EO2654_2011_Van** /
   **EO3278_T1_CDCSD** decode ZERO geography (light returns `geo_name = NULL`,
   `geo_uid = character(0)`) — no specializer claims them and
   `ivt_f2_check_geo_names()` skips a wholly-NULL `geo_name`. (Stage 3 does NOT
   rescue these -- see step 4: EO3278 is chunked, EO2654's directory does not
   resolve; both need dedicated readers, not the verbatim net.)
4. [x] **Stage 3** `ivt_f2_geo_combined()` + `canivt_geo_unparsed`; a synthetic
   unit test (a doctored directory with an unknown run roster) proves it warns
   and returns verbatim labels. DONE 2026-07-17. Wired as the dispatcher's
   last resort, reached only when no specializer claimed the layout AND the uid
   scan came up short (a complete uid array still wins at step 5, so the big
   uid-only tables are untouched). It recovers the codebook's own member strings
   VERBATIM: from the geo slot directory's value entries it picks the single
   member-length run (un-chunked, or a pow-2-padded block that trims to `n_geo`)
   that is most name-like as `geo_label`/`geo_name`, plus an all-code run as
   `geo_uid`. LOUD (`canivt_geo_unparsed`, strict-mode error). Synthetic unit
   test in test-fallback.R (verbatim name run, code→uid, NULL on no member-length
   block, strict error). Engages on ZERO corpus tables (returns NULL for all):
   light byte-identical, corpus FAIL 0 / 51, geo-snapshot FAIL 0 / 51, unit
   FAIL 0. SCOPE: it deliberately does NOT assemble a multi-chunk attribute
   codebook (a mis-stitched chunk order would mislabel members -- that is a
   specializer's job). So it does **not** rescue the two nameless custom exports
   noted at step 3: **EO3278_T1_CDCSD** is an attribute-major chunked codebook
   (groups 1,1,2,4,8… like `attrs_dir`) with no GEO_NAME schema -- it needs a
   schema-less `attrs_dir` variant, a new specializer; **EO2654_2011_Van** does
   not even resolve a geo block directory (its geography dimension is misread as
   "2011 Census", `ivt_f2_geo_entries()` NULL) -- a descriptor / geo-identify
   gap. Both remain genuine gaps for a future pass (own decode-history entry).
5. [x] **Demote the byte-scans** (`ivt_f2_geo_dguids`, stride-walk) to explicit
   last-resort inside their specializers, each already `ivt_fallback()`-loud;
   confirm 98100013 full-attr snapshot still byte-identical. DONE 2026-07-17 --
   satisfied by existing structure, no code change. Verified both byte-scans are
   already explicit, loud, last-resort: `ivt_f2_geo_dguids()` (byte scan) is
   called ONLY inside `ivt_f2_geo_uids()` immediately after its `ivt_fallback()`,
   after `ivt_f2_geo_dguids_dir()` (positional) returns NULL; the stride walk
   (`ivt_f2_codebook_blocks`/`ivt_f2_geo_names`/`ivt_f2_geo_root_dir`) is inside
   `ivt_f2_geo_attributes()` after its `ivt_fallback()`, reached only when
   `ivt_f2_geo_attrs_dir()` (positional) returns NULL. 98100013's full read
   exercises the stride walk (its snapshot `full_warnings` = `canivt_fallback`)
   and is in `GEO_SNAP_FULL` -- byte-identical (geo-snapshot FAIL 0).
6. [x] Update CLAUDE.md code map, coverage.md, decode-history.md; retire the
   superseded ladder comments.

### Explicitly NOT done (kept as documented specializations)

Flow code-join (#3), the 98100013 stride-walk (#4), and the dense re-alignment
(#1) are **not** collapsed into the shared assembler — that is the §4 finding,
still correct. The win here is the *shared Stage-1 recovery*, the *single
dispatcher*, and the *combined-string safety net*, not a single mega-parser.

## Suggested order

1. §1 correctness fixes (done).
2. §2 dead-code removal — shrink the surface before refactoring.
3. §3 `ctx` object — mechanical but touchy; corpus ledger as the byte-exact net.
4. §4 strict-first harmonization + shared helpers; §5 alongside.
5. §6 dense-bitstream decode and structural marker identification — new format
   work; each gets its own validation entry in decode-history.md.
6. §7 geography recover-then-specialize — build the snapshot harness first, then
   migrate in the 6 gated steps above.
