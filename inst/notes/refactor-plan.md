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

## 2. Dead code to retire

Confirmed by grep: definition + tests only, no production callers.

- [ ] `ivt_f2_read_block_dir()` (codebook-f2.R) — zero callers anywhere.
- [ ] `IVT_F2_REC_BYTES` / `IVT_F2_PRESENCE_LEN` (container-f2.R) — only
  reference each other; the comment mentions `ivt_f2_rec_bytes()`, which no
  longer exists.
- [ ] `ivt_geography_count()` + `ivt_entry_valid()` + `IVT_IDX_STRIDE`
  (container.R) — one regression test only (`test-decode.R:54`); `ivt_family()`
  no longer touches it (CLAUDE.md's "kept for the family detector" is stale).
  Move into the test file or drop with the test rewritten against
  `ivt_layout()`.
- [ ] `ivt_f2_header_layout()` (codebook-f2.R) — test-only; either export
  intent or fold the two test assertions onto its components.
- [ ] Update CLAUDE.md / coverage.md "legacy counter" caveats when these go.

## 3. Per-read parse context (the enabling refactor)

There is no memoization anywhere: `ivt_f2_descriptor(raw)` is re-parsed from
13 call sites, `ivt_f2_geo_dim_index()` from 12, `ivt_f2_geo_count()` from 9 —
and each descriptor parse re-runs `ivt_f2_dim_count_reconcile()` (which
strict-parses slot directories), while `ivt_f2_geo_dim_index()` probes
directories with `ivt_f2_dir_entry_members()` when dim 1 has count 1. One
`read_ivt()` re-derives the descriptor dozens of times, and each dimension's
block directory is decoded at least three times (labels / ordinals /
footnotes).

- [ ] Build a `ctx` object once per file (descriptor, slot table,
  per-dimension directories, geo dim index, layout, geo count) and thread it
  through the readers.
- [ ] Delete the re-entrancy special case `ivt_f2_dim_slots(raw, m =)` (exists
  only so the count reconcile does not re-enter the descriptor parse).
- [ ] Collapse `ivt_f2_dim_dir_labels()` / `ivt_f2_dim_dir_ordinals()`
  (structurally identical wrappers, dimdir.R) into one pass over cached
  directories.
- [ ] `ivt_f2_check_geo_count()` stops re-parsing the descriptor per call.

Nearly every duplication in §4 exists partly because functions cannot assume
shared state — do this before the big dedups.

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
- [ ] **EN/FR pair pick ×7**: the `diff <- which(a != b);
  frscore(a[diff]) <= frscore(b[diff])` idiom is inlined in
  `ivt_f2_dim_dir_label1()` twice (including a verbatim-duplicated fallback
  warning), `ivt_f2_geo_root_dir()`, `ivt_f2_geo_names()`,
  `ivt_f2_geo_attrs_dir()`, `ivt_f2_geo_inline_dir()`, `ivt_f2_dqf_legend()`
  and the identity readers. One `ivt_f2_pick_en(a, b)` →
  `list(en, fr, en_first)`.
- [ ] **Name prefix-match ×4** ("shorter is a prefix of the longer, ≥4
  chars"): `ivt_f2_match_dim()`, `ivt_f2_dir_marker_entry()`,
  `ivt_f2_geo_simple_schema()`, `ivt_f2_geo_marker_region()` `is_geo_mk`.
- [ ] **Schema-stem → column mapping ×3**: identical `stem_col()` closures in
  `ivt_f2_geo_root_dir()` and `ivt_f2_geo_attrs_dir()`, plus the inverted
  match in `ivt_f2_geo_slot_map()`.
- [ ] **Pair-swap + MSB-first bit reads ×2 (+1 partial)**:
  `ivt_f2_record_present()` (decode-f2.R) and `ivt_f2_footnote_bitmap()`
  (dimdir.R) reimplement the same swap/shift; the DGUID `probe()`
  (codebook-f2.R) reimplements the dense `[81 01]` header skip that
  `ivt_f2_dir_entry_members()` already knows.
- [ ] **Directory-entry validation ×5**: the `[u32 off][u16 s1][u16 s2]`,
  `s1 == s2 && s1 > 0 && off in-range && is_marker` check is inlined in
  `ivt_idx0()`, `ivt_page_preflight()` (twice), `ivt_decode()` and
  `ivt_f2_entry_valid()`. One reader returning `list(off, size)`/NULL.
- [ ] **The page-marker byte model is expressed twice**: `ivt_f2_marker_b0`
  (container-f2.R) and `ivt_value_trailer()`'s nibble decomposition
  (`w ∈ {2,4,8} && hi ∈ {0x80,0xa0}`, decode.R) describe the same set
  independently — they agree today but can drift. Define the marker test once
  via the nibble model.
- [ ] **`ivt_f2_dim_dir_label1()` / `ivt_f2_dim_dir_ordinal1()`** share the
  entire candidate-entry walk (len window, `ivt_find_member_blocks`,
  `cnt..cnt+8` size gate, trailing-`cnt` slice); factor a shared member-array
  iterator (label1 skips ordinal blocks, ordinal1 keeps permutations). Both
  should also try the strict entry parse first (see strict-first above).
- [ ] **Geography column ordering ×3**: the `ivt_f2_geo_attrs_dir()` tibble,
  `geo_cols` in `ivt_f2_metadata()`, `front` in `ivt_f2_geographies()`. One
  `IVT_GEO_COLS` constant.
- [ ] **uid naming**: inline readers emit `geouid`, attrs emit `dguid`,
  renamed to `geo_uid` at two different downstream sites. Emit `geo_uid` at
  the source; drop both renames.

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
