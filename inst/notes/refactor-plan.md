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

- [ ] **Four chunk-group walkers.** The "groups of G chunks
  (`ivt_f2_geo_group_sizes()`), each attribute = G language-A blocks then G
  language-B blocks, chunk size `min(256, remaining)`, trim pow-2 slot
  padding" walk is implemented four times with different tolerances:
  `ivt_f2_geo_dguids_dir()` (identical-copy check),
  `ivt_f2_dim_dir_label_chunks()` (skip-nonmatching `take_run`),
  `ivt_f2_geo_attrs_dir()` (NA-hole pattern + dense re-alignment),
  `ivt_f2_geo_inline_dir()` (partial-first rotation + `skip` prefix). One
  parameterized group-run consumer carrying all four behaviors (~200 lines).
- [ ] **Strict-first entry parsing everywhere** (also a §6 sharpening item):
  the flow reader does byte-exact `ivt_f2_dir_entry_members()` first with the
  run-scanner as fallback (that ordering fixed the silently-truncated flow
  names), but `ivt_f2_geo_attrs_dir()`, `ivt_f2_geo_inline_dir()` and
  `ivt_f2_dir_entry_records()` still *classify* entries via the run-scanner
  first — the same fragmentation risk sits in the classification gates (a
  fragmented dense tail can flunk the `k == 2·nattr·Σsizes` count and
  needlessly trip the stride fallback). One shared "read directory entry:
  strict, else scanner (tracked)" helper replaces three inlined loops.
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
- [ ] **`ivt_f2_dim_dir_label1()` / `ivt_f2_dim_dir_ordinal1()`** share the
  entire candidate-entry walk (len window, `ivt_find_member_blocks`,
  `cnt..cnt+8` size gate, trailing-`cnt` slice); factor a shared member-array
  iterator (label1 skips ordinal blocks, ordinal1 keeps permutations). Both
  should also try the strict entry parse first (see strict-first above).
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

- [ ] **`ivt_f2_geo_light()` vs `ivt_f2_geographies()`**: two parallel
  priority ladders over the same readers; with
  `read_ivt(geo_attributes = TRUE)` the light path's work (uid scan, fill,
  truncation flag) is computed then discarded when `ivt_f2_geographies()`
  re-runs everything. One entry `ivt_f2_geographies(raw, full = FALSE)`; state
  the `n_geo <= 256` cost gate in metadata terms ("one group of one chunk",
  `length(sizes) == 1`).
- [ ] **`ivt_idx0()` vs `ivt_f2_find_directory()`**: both anchor the page
  directory from `@558`, but only `ivt_idx0()` knows the field stores the low
  16 bits (the `+ k·65536` unwrap). `ivt_f2_dir_anchor_header()` does the
  plain u16 read, so on a >64 KiB-directory file the metadata-side finder
  falls to the loud marker scan (which still carries the elsewhere-removed
  `mk >= 1e5` floor) for something the decode side resolves positionally.
  Anchor `ivt_f2_find_directory()` on `ivt_idx0()`.
- [ ] **Loudness of content-based language assignment**:
  `ivt_f2_dim_dir_label1()` warns when it falls back to `frscore` (no schema
  block), but the geography paths (`attrs_dir`, `geo_names`, `root_dir`,
  `dqf_legend`) use `frscore` as the *primary* language decider, silently.
  Defensible (per-group order genuinely varies — the root group is FR-first),
  but state the philosophy once: either pin language from the schema's
  `_EN`/`_FR` field naming where block order follows schema order (frscore as
  validating tiebreak), or document why per-group content scoring is primary
  there.

## 6. Sharpening toward metadata-driven (retiring fallback paths)

- [ ] **Decode the `[81 01]` dense bitstream** (highest-value sharpening).
  `ivt_f2_dir_entry_members()` notes "the bitstream's per-member coding is not
  yet decoded" and callers re-align dense values against the NA pattern of
  *sibling plain arrays* — a heuristic with a bail-out (→ stride fallback).
  The same writer's `[84 01]` footnote bitmap decodes as pair-swapped
  MSB-first presence (`ivt_f2_footnote_bitmap()`); if the `81 01` bitstream is
  the same convention, dense chunks become positional in their own right, the
  sibling-alignment heuristic goes away, and a real format gap closes (then
  update ivt-format.md / coverage.md / decode-history.md).
- [ ] **Identify the doubled-name marker entry structurally, not by name.**
  `ivt_f2_dir_marker_entry()` prefix-matches the descriptor name — which is
  why the five-heuristic `ivt_f2_descriptor_name()` recovery stack is
  load-bearing for label reads. Within a slot directory already validated by
  index + `n_entries`, the marker block is the entry opening `81 02 02 00`
  (the dictionary block has a different field count). If a structural scan
  finds exactly one such entry per directory across the corpus, demote the
  name match to a cross-check.
- [ ] **`ivt_geo_arrays()` still hard-codes `"^2021[A-Z]"` and
  `texts[1] == "Canada"`** (codebook.R) — the only remaining year/country
  literals, against the project rule; reachable via `ivt_f2_geo_simple()`'s
  content fallback. Minimum: use `IVT_F2_DGUID_RE` and drop the "Canada"
  anchor (name block = the equal-length block that is neither DGUID-shaped nor
  all-numeric). Better: verify `ivt_f2_geo_attrs_dir()` now covers every table
  that needed it and retire the function.
- [ ] **`ivt_f2_geo_schema()`'s ±128 KiB content window** carries the comment
  "routed through a deeper pointer chain we do not decode yet" — likely stale
  since `ivt_f2_dim_dir()`'s two-depth indirection landed. Verify on
  98-10-0023 / 98-10-0174 whether `ivt_f2_geo_dict_block()` resolves through
  the slot table; if so retire the window scan (it is not even loud today) or
  make it loud.

## Suggested order

1. §1 correctness fixes (done).
2. §2 dead-code removal — shrink the surface before refactoring.
3. §3 `ctx` object — mechanical but touchy; corpus ledger as the byte-exact net.
4. §4 strict-first harmonization + shared helpers; §5 alongside.
5. §6 dense-bitstream decode and structural marker identification — new format
   work; each gets its own validation entry in decode-history.md.
