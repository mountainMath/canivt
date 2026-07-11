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

- [ ] **Four chunk-group walkers — DEFERRED to a dedicated session.** The
  "groups of G chunks (`ivt_f2_geo_group_sizes()`), each attribute = G
  language-A blocks then G language-B blocks, chunk size `min(256,
  remaining)`, trim pow-2 slot padding" walk is implemented four times with
  different tolerances: `ivt_f2_geo_dguids_dir()` (identical-copy check),
  `ivt_f2_dim_dir_label_chunks()` (skip-nonmatching `take_run`),
  `ivt_f2_geo_attrs_dir()` (NA-hole pattern + dense re-alignment),
  `ivt_f2_geo_inline_dir()` (partial-first rotation + `skip` prefix). One
  parameterized group-run consumer carrying all four behaviors (~200 lines).
  Deferred deliberately (2026-07-10): it is the deepest redesign of the
  section with the highest drift risk and a maintainability-only payoff —
  each walker's tolerance set is load-bearing for specific vintages, so the
  unification needs a fresh session with the corpus run before/after each
  walker is folded in (start with `dguids_dir` + `label_chunks`, the two
  simplest; `inline_dir`'s rotation/skip handling last).
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

## Suggested order

1. §1 correctness fixes (done).
2. §2 dead-code removal — shrink the surface before refactoring.
3. §3 `ctx` object — mechanical but touchy; corpus ledger as the byte-exact net.
4. §4 strict-first harmonization + shared helpers; §5 alongside.
5. §6 dense-bitstream decode and structural marker identification — new format
   work; each gets its own validation entry in decode-history.md.
