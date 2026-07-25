# Parser consolidation & sharpening plan

Findings of the 2026-07-10 parser review, worked through to completion. **Every
item below is landed** (2026-07-10 … 07-23); nothing here is open work. What
survives is the *record of the decisions* — in particular the items resolved as
**WON'T DO**, whose reasoning is load-bearing for anyone tempted to merge these
paths again. Section numbers are referenced from comments in `R/` (§5.1, §5.3,
§6.1, §7, §7.3, §7.4, §8) — **keep them stable**.

Every step was gated on the same net: the corpus ledger
(`CANIVT_CORPUS_TESTS=1`, exact cell counts *and* that known fallbacks still
warn) FAIL 0, plus the geography snapshot (§7.1) `identical()`.

## 1. Correctness-adjacent fixes — DONE

- [x] **Reserved the `geo`/`value` slugs** (`ivt_dim_slugs()`, codebook-f2.R).
  A dimension whose leading word slugs to `value` — *"Value of dwelling"* is a
  real census dimension — had its member-id column silently overwritten by
  `out$value <- …` and then dropped by `ivt_f2_tidy()`.
- [x] **`canivt_fallback` umbrella class** is appended by `ivt_fallback()` itself
  (warning **and** strict-mode `_error` classes). `canivt_skipped_pages` /
  `canivt_descriptor_reloc` previously lacked it, so `ivt_quietly()` did not
  muffle them and umbrella-keyed handlers did not see them.

## 2. Dead code retired — DONE

`ivt_f2_read_block_dir()`, `IVT_F2_REC_BYTES` / `IVT_F2_PRESENCE_LEN`,
`ivt_geography_count()` + `ivt_entry_valid()` + `IVT_IDX_STRIDE` (the legacy
0x1000-stride counter; test-decode.R keeps the 174-geography fact and a comment
recording the 348 artefact). **`ivt_f2_header_layout()` was KEPT deliberately**:
it is the reference implementation of the header map documented in
ivt-format.md / the vignette, a diagnostic entry point, not part of decode.

## 3. Per-read parse context — DONE (as a transparent memo)

There was no memoization anywhere: `ivt_f2_descriptor(raw)` was re-parsed from 13
call sites, `ivt_f2_geo_dim_index()` from 12, `ivt_f2_geo_count()` from 9, and
each dimension's block directory decoded at least three times.

Landed as `R/memo.R` — `ivt_memo(raw, key, compute)`, a single slot keyed by
`identical(raw, slot$raw)` (byte-exact, so a doctored copy never reuses the
original's parse) — rather than a `ctx` argument threaded through ~40 signatures:
same wins, no signature churn, internals stay directly callable with a plain raw
vector. Memoized: `ivt_f2_descriptor`, `ivt_layout`, `ivt_f2_dim_dir` (per k),
`ivt_f2_geo_dim_index`, `ivt_f2_geo_count`, `ivt_f2_geo_schema`,
`ivt_f2_find_directory`.

- **Warnings raised inside a memoized compute are recorded and REPLAYED on every
  hit**, so a warm cache is exactly as loud as a cold one; errors are never
  cached (strict stays strict). `read_ivt()`/`ivt_metadata()` clear the slot on
  exit.
- `ivt_f2_dim_slots(raw, m =)` STAYS: it is what breaks the descriptor →
  reconcile → slots cycle *while the descriptor compute is in flight*.
- The memo made the gates free to consult, which exposed the real hot spot:
  `ivt_f2_geo_inline()`'s marker-region fallback scan had no schema gate, so
  every large schema'd table walked its multi-MB geography codebook through the
  pure-R Pascal scanner. Gated: `ivt_metadata(98-10-0023)` 20 s → 1.7 s.

## 4. Duplicated logic → shared helpers — DONE

- [x] **Chunk-group geometry** extracted to `ivt_f2_chunk_layout(n)` — the
  group-sizes → group-start → per-chunk-size → member-position walk that four
  walkers (`ivt_f2_geo_dguids_dir`, `ivt_f2_dim_dir_label_chunks`,
  `ivt_f2_geo_attrs_dir`, `ivt_f2_geo_inline_dir`) had copied verbatim. Their
  **block-alignment tolerances were left untouched** — each set is load-bearing
  for specific vintages. Verified `identical()` output on all corpus tables.
  - **NOT pursued: one parameterized consumer carrying all four behaviors.** The
    number of runs (2 / 2·nattr / discovered) and the block→member alignment
    differ so much that a single consumer degenerates to the shared geometry plus
    per-walker `place_chunk`/`combine_runs` callbacks — scattering the
    load-bearing logic into closures with no maintainability gain. (Same finding
    as §7's risk register.)
- [x] **Strict-first entry parsing** — `ivt_f2_dim_dir_label1()` /
  `ivt_f2_dim_dir_ordinal1()` read values strict-first through the shared
  `ivt_f2_dir_member_arrays()` iterator (run-scanner as fallback). The flow reader
  already was. `attrs_dir`/`inline_dir` keep run-scanner **classification** by
  design (their `k == 2·nattr·Σsizes` gate needs a stable block set; their VALUES
  are already strict-first).
- [x] Shared helpers: `ivt_f2_pick_en(a, b)` (EN/FR pair pick),
  `ivt_f2_name_match(a, b)` (name prefix-match, 4 copies),
  `ivt_f2_stem_col()` (schema-stem → column),
  `ivt_bits_pairswap_msb(bytes, bit)` (backs both `ivt_f2_record_present()` and
  `ivt_f2_footnote_bitmap()`), `ivt_dir_entry(raw, o, n)` (5 inlined copies),
  `IVT_GEO_COLS` + `ivt_geo_col_order()` (the two entry points previously imposed
  *different* geography column orders).
- [x] **Marker byte model single-sourced**: `ivt_f2_marker_b0` is DERIVED from
  `IVT_MARKER_WIDTHS {2,4,8} × high nibble {0x8,0xa}`, and `ivt_value_trailer()` /
  `ivt_decode_page()` / `ivt_page_preflight()` use the same constant, so the two
  expressions of the model cannot drift.
- [x] **uid naming — WON'T DO.** The internal reader columns (`dguid` in the
  attribute table, `geouid` in the inline table) deliberately mirror the file's
  own field vocabulary and are asserted throughout the suite as the reader
  contract; the public surface is already uniformly `geo_uid`, renamed at exactly
  the two path boundaries.

## 5. Harmonization — DONE

- [x] **§5.1 `ivt_f2_geo_light()` vs `ivt_f2_geographies()` — WON'T MERGE.** The
  premise ("parallel ladders over the same readers") does not hold: they are
  **different reader sets** with **two deliberately-different, separately-tested
  contracts**. For big chunked tables the light path is uid-only (a fast
  positional DGUID scan) while the full path runs the ~30 s attribute scan; the
  full tibble **keeps all-NA columns by design** (asserted by tests) while the
  lean default drops them. Collapsing would force one contract on the other. The
  only genuinely shared step is ~3 lines. Both carry a cross-reference comment.
- [x] **`ivt_idx0()` vs `ivt_f2_find_directory()`** — the low-16-bit `+ k·65536`
  unwrap lives once in `ivt_f2_dir_anchor_header()`; `ivt_idx0()` is a thin
  wrapper. Both the decode and metadata sides resolve a >64 KiB directory
  positionally (98100013 k=1 / 95F0250 k=2 verified equal) instead of the metadata
  finder falling to the loud marker scan. The scan's `mk >= 1e5` floor is now
  truly last-resort (only if `@558` is absent/corrupt).
- [x] **§5.3 Loudness of content-based language assignment — philosophy.** The
  geography block language order genuinely varies per group (most EN-first, the
  geography ROOT group FR-first), so there is no schema-declared order to pin
  against: `ivt_f2_frscore()` is the correct **primary** read there, hence silent.
  That is the opposite of `ivt_f2_dim_dir_label1()`, whose dictionary schema block
  DOES fix the order, making frscore a genuine (loud) fallback when the block is
  absent. Same function, different status by context — stated once at
  `ivt_f2_pick_en()`, cross-referenced from `ivt_f2_label_lang_fallback()`.

## 6. Sharpening toward metadata-driven — DONE

- [x] **`ivt_survey_double()` retired (2026-07-23)** — the paging geometry is
  DECLARED: the `81 02 <alloc-u16> 16 00` block's u16 is the dimension's slot
  allocation and `ivt_layout()` pads every nesting level to it
  (`ivt_f2_dim_slot_alloc()`), reproducing the pow2 model corpus-wide and
  Table-023's "doubled" strides exactly. `canivt_survey_directory` is gone. Same
  pass: the dense pre-records marker is accepted as the single-bit-byte class
  (fixed Table-023's Sex EN/FR), and `ivt_f2_dim_dict_en_first()` reads the
  declared `Description`/`Description_FRA` and `English`/`French|Français` pairs,
  retiring the content-score language fallback on every `04`-gen dim with a
  declared pair.
- [~] **§6.1 Decode the `[81 01]` dense bitstream — hypothesis FALSIFIED.** It is
  **not** the `[84 01]` member-presence convention. Measured on 98-10-0662's six
  bit-headed dense arrays: `nbits` (449, 446, 641, …) ≫ the ~91 members, and the
  bitstream's **popcount == the records-region byte length + 1** exactly
  (282 = 281+1, 279 = 278+1, 474 = 473+1). It is a **per-byte** map of the packed
  records region, not per-member — it cannot place members positionally. The
  sibling-alignment heuristic (spread dense values into the NA pattern of the
  entry's plain-array siblings) is correct and already decodes these cell-exact
  (98-10-0662: 91/91). **No format gap to close here.**
- [x] **Doubled-name marker entry identified STRUCTURALLY.** Within a slot
  directory already validated by index + `n_entries`, the marker is the entry that
  OPENS with `81 02 02 00` **and carries a printable name** — and there is never
  more than one (152 of 155 dimension directories have exactly one; the other 3,
  the ord-08035 custom export, have none, exactly where the descriptor name also
  fails). Nameless `81 02 02 00` stubs (`len ~16`) are excluded.
  `ivt_f2_dir_marker_entry()` keeps the descriptor name only to disambiguate the
  never-observed >1-named case — so a dimension whose name is misread still
  resolves its labels, demoting `ivt_f2_descriptor_name()`'s five-heuristic
  recovery from load-bearing to a cross-check.
- [x] **`ivt_geo_arrays()` retired.** A full-corpus branch trace showed **no**
  table ever reaches the content fallback, so the last year/country literals
  (`"^2021[A-Z]"`, `texts[1] == "Canada"`) went away by deletion;
  `ivt_f2_geo_simple()` is schema-only. (The minimum patch — a cardinality-based
  name block — was tried and rejected: it picked the inline-combined block over
  the clean-names block, since the `"Canada"` literal was silently disambiguating
  the two.)
- [x] **`ivt_f2_geo_schema()`'s ±128 KiB content window made LOUD.** All 12
  schema'd tables resolve the dictionary through the header slot table, so the
  window scan fires on zero tables; kept for robustness on unseen layouts but it
  now warns `canivt_fallback` *only when it actually supplies a schema the slot
  table could not*.

## 7. Geography: unify on recover-then-specialize — DONE (2026-07-17)

All six migration steps landed. Architecture:

```
ivt_f2_geo_read(raw, full = FALSE) →                # replaces geo_light + front of geographies
  gi   <- ivt_f2_geo_dim_index(raw)                 # same locator as data dims
  ents <- ivt_f2_geo_entries(raw, gi)               # Stage 1 (SHARED): locate once, lazy accessors
  for spec in SPECIALIZERS:                         # Stage 2: flow → inline → schema → custom → bare
     g <- spec(raw, ents, full)                     #   first non-NULL wins
     if (!is.null(g)) return(finalize(g))
  finalize(ivt_f2_geo_combined(ents))               # Stage 3: verbatim, LOUD (canivt_geo_unparsed)
```

- **§7.1 Snapshot harness (built FIRST).** `helper-geo-snapshot.R` +
  `fixtures/geo-snapshot.csv` + opt-in `test-geo-snapshot.R`: a deterministic
  hash of each read plus the ordered `canivt_*` warning set, light for every
  ledger table and full for the `GEO_SNAP_FULL` set (incl. **98100013**, the only
  table whose full read exercises the stride walk — the corpus ledger reads only
  the default path, so the snapshot is what pins it). The warning assertion
  compares **distinct classes**, not the raw multiset: the §3 memo replays
  warnings on every hit, so counts shift with benign refactors while
  distinct-class still catches any new or vanished fallback.
- **§7.2 Stage 1** `ivt_f2_geo_entries()` locates the geo block directory ONCE and
  exposes LAZY memoized per-entry accessors (`$records`/`$strict`/`$values`/
  `$dense`). **Laziness is load-bearing**: eagerly scanning all 6,244 entries of
  98-10-0023 measured ~17 s, so `dguids_dir`'s O(1) probe must never touch
  `$records`. Cache subtlety: entries are stored via `x[r] <<- list(v)`, never
  `x[[r]] <<- v` (a NULL strict parse via `[[<-` deletes the slot and misaligns
  the cache).
- **§7.3 Single dispatcher** — `full` selects ONLY the schema step; flow / inline
  / custom / bare are SHARED, which **fixed a latent bug**: the full path used to
  return an all-NA tibble for custom/bare tables.
- **§7.4 Stage 3** `ivt_f2_geo_combined()` — verbatim last resort, loud
  (`canivt_geo_unparsed`, strict error), engages on ZERO corpus tables.
  **Scope: it deliberately does NOT assemble a multi-chunk attribute codebook** —
  a mis-stitched chunk order would mislabel members; that is a specializer's job.
  (Later upgraded to a full schema-free reader — see coverage.md.)
- **§7.5** The byte-scans (`ivt_f2_geo_dguids`, the stride walk) were confirmed
  already explicit, loud and last-resort inside their specializers; no change.

### Risk register — load-bearing tolerances that MUST survive byte-identical

These are why §4 declined a single parameterized consumer; they stay **inside**
their specializers, fed from shared `ents`:

1. `attrs_dir` per-chunk **dense re-alignment** via the plain-array NA-hole
   pattern + the `k == 2·nattr·Σsizes` gate (98-10-0662 aggregate member 26).
2. `inline_dir` **partial-first rotation** + `skip`-prefix search (2006 vintage;
   98-400-X2016120/0328 auxiliary blocks).
3. `flow_dir` is a **code-join, not positional** — keep as its own specializer.
4. The **stride-walk full read** is the ONLY full reader for `98100013` — demoted
   to last resort, **not** deleted.
5. Per-group **language order** varies (root group FR-first) — `ivt_f2_pick_en()`
   stays the per-group primary.
6. `dguids_dir` **identical-copy** check + the byte-scan last resort
   (98-10-0013's reverse-root chunk below the marker region).

**Explicitly NOT collapsed** into a shared assembler: the flow code-join (#3), the
98100013 stride walk (#4), the dense re-alignment (#1). The win is the shared
Stage-1 recovery, the single dispatcher and the safety net — not a mega-parser.

## §8 Unify geography with data-dimension parsing — ARC COMPLETE (2026-07-18)

**Premise (validated on 12 tables across every lineage):** every dimension —
geography AND data — stores its codebook the same way: a `81 02 <nfields> 00`
field dictionary naming its columns in ONE shared vocabulary
(`Code / English Desc / Desc Français / … / UID/IDU / Level`), followed by the
member-value runs. Geography's dictionary is a data dimension's plus geo-specific
columns.

**The load-bearing subtlety (measured, not assumed):** the dictionary is a
faithful MANIFEST of logical columns, but columns have TWO storage disciplines, so
`n_dense_runs < n_fields`:

- **Dense** (Code / English Desc / Desc Français): one slot per member, pow-2
  padded, NA for absent. "Code" is the ordinal — a framing, not a label run.
- **Sparse, bitmap-gated** (`_Description` / `_ItemNotes`): a `84 01` member
  bitmap picks which members carry a value; only those texts are stored
  (popcount = record count). When no member carries one, bitmap AND text vanish
  though the dictionary still names the column. **Measured 1:1 across the corpus:
  `_Description`/`_ItemNotes` in the dictionary ⟺ exactly the EN+FR `84 01`
  bitmaps.** These are what `ivt_f2_dir_footnotes()` already decodes.
  (Dimension-level footnotes appear WITHOUT a bitmap and are not dictionary
  columns.)

So the unification is **not** "map runs 1:1 to fields" — it is "classify each
DENSE run's ROLE (ordinal / EN label / FR label / uid), the dictionary supplying
the vocabulary + EN-before-FR order, never a positional guess."

- [x] **§8.1** `ivt_f2_geo_field_schema()` generalized to
  `ivt_f2_dim_field_schema(raw, dir)` (dim-members.R); one field-dictionary read
  for all dimensions.
- [x] **§8.2** `ivt_f2_dim_members(raw, k)` → per-dimension member tibble
  (`member_id`, `ordinal`, `label_en`, `label_fr`, `uid`), role-inferred.
  `ivt_f2_dim_dir_label1()` delegates to it — data-dim label parity **173/173
  byte-identical**. Also materializes the sparse `notes_en`/`notes_fr` column from
  the `84 01` bitmap (opt-in `include_notes`), verified 173/173 identical to
  `ivt_f2_dir_footnotes()`'s member-scoped output.
- [x] **§8.3 — migration BLOCKED (assessed, no code change).** A unified
  dim-members-style geography read reproduces the current output for **exactly
  one table** (EO3278, 6 fields = 6 runs), which the schema branch already
  handles. Every other schema-carrying geography breaks the 1:1 field↔run
  assumption: EO2654 5f/4r (`Geo Code` unstored), CRO0163850_CT7 5f/6r (extra
  `GNR`), CMHC2016_T1 6f/5r (sparse `_Sort`/`DQ`), 98-400-X2016203 6f/9r, the
  modern DGUID tables 25–27 fields vs 24–26 runs. Forcing a 1:1 map would regress
  or fall back to the very content heuristic the schema work replaced.
  **Conclusion: the geography specializers are irreducible.**
- [x] **§8.4** `ivt_f2_dir_is_geo()` identifies a geography dimension from its own
  field dictionary first: a `81 02` block is geography when it names `GEO_NAME`,
  the `POR/POW` / `LDR/LDT` flow schema, or a `UID/IDU` column together with
  `Level/Niveau` or `Geo Code`. The inline-pattern CONTENT probe is now the
  fallback for schema-thin vintages. Byte-identical; no data dim carries the geo
  vocabulary.
- [x] **§8.5** The schema-driven geography path emits EVERY column the file's
  dictionary declares, under its canonical role by the file's OWN field name
  (`ivt_f2_geo_field_role()`: `English Desc`→`geo_name`, `Desc Français`→
  `geo_name_fr`, `UID/IDU`→`geo_uid`, `Geo Code`→`geo_code`, `Level/Niveau`→
  `geo_level`, `DQ`→`dqf_code`, `GNR`→`tnr_short_form`). The positional run→field
  map is SELF-VALIDATED (name run reads as text, uid run as a bare code), so a
  codebook whose run order ≠ dictionary order falls through to the heuristic
  instead of emitting mis-aligned columns. The modern DGUID schema reader is
  deliberately NOT folded in — two genuinely distinct schema blocks and
  vocabularies, both now following the same "file's own field name → role"
  principle.
- [x] **§8.6** `ivt_f2_geo_encoding(raw)` classifies the encoding family purely
  from the dictionary (`dguid`/`flow`/`bare`/`custom`/`none`), non-overlapping
  corpus-wide; the dispatcher routes `dguid`/`bare` on it, so "why this reader" is
  an auditable metadata decision. The combined-string families share the
  self-detecting inline entry, so a mis-classification cannot mis-read. **KEY
  LIMIT:** the dictionary declares logical columns but NOT the physical STORAGE.
- [x] **§8.7 — NEGATIVE RESULT: there is no metadata marker for
  combined-vs-parallel storage.** The variation is **per-file** (it tracks the
  export tool: EO3278/EO2654 parallel; the census inline vintages + cro/CMHC/CRO/
  ord combined), and the same-tool `cro0172986_ct7`/`_ct8` pair stores identically
  yet differs in the dictionary field-struct bytes — so that struct is per-file
  layout noise, not a flag. Every candidate location checked: the `81 02` dict
  header is IDENTICAL across both storages (`88 0a ff af`), the descriptor type
  byte is a width tag (`0x0d` spans parallel AND combined), the geo slot's 2nd u32
  is an allocation size, and a full 1 KB header scan yielded only that same
  allocation byte read coincidentally. The format does not encode it because
  Beyond 20/20 never needed to — it reads the DISPLAY LABEL and shows it;
  decomposing it into name/uid/code is *our* goal, not the file's. So the robust
  design is the one in place: read the display label from metadata, then
  STRUCTURALLY probe for parallel attribute arrays. **Do not invent a marker
  heuristic from the 2 parallel exemplars.**
