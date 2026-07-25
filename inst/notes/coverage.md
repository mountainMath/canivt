# IVT format coverage — what we decode and what's left

A living assessment of how completely `canivt` understands the Beyond 20/20 `.ivt`
format. **Update this when a gap is closed or a new one is found.** Status keys:
`[x]` decoded & exposed · `[~]` read but not surfaced (recoverable) · `[?]` read
but semantics unproven · `[ ]` not parsed / unknown.

This file is the **status tracker**. The story of how each table/vintage was
cracked lives in [`decode-history.md`](decode-history.md); the byte-marker catalog
in [`markers.md`](markers.md); the format spec in [`ivt-format.md`](ivt-format.md);
the current refusals in [`unsupported-formats.md`](unsupported-formats.md).

## Byte coverage (every region is identified)

Measured on the family-2 reference table **98-10-0023** (142,016,485 bytes);
cross-checked against family-1 (98-10-0241) and the legacy 1991 table (1003011).

| region | bytes | share | status |
|---|--:|--:|---|
| header (identity + descriptor) | ~3.2 KB | 0.002 % | partial — see `[?]` below |
| header zero-padding | ~33 KB | 0.023 % | reserved, no information |
| page directory | 127 KB | 0.089 % | fully used |
| dir → pages gap | ~4 KB | 0.003 % | padding |
| value pages (data) | 124 MB | 87.6 % | decoded cell-exact |
| codebook + footnotes + dimension blocks | 17.4 MB | 12.3 % | see below |

No unexplained "mystery blocks": 100 % of the file is accounted for by region.
Within the value pages, **96.7 %** is marker + presence + values (all decoded
exactly) and **3.3 %** is `0xFF` trailers + zero-padding (no information).

## [x] Fully decoded and exposed

- [x] **All cell values.** Validated cell-for-cell vs the StatCan CSV / B20/20
  viewer (family 1: 7,489,464 cells; family 2: 14.5 M; 1991: every scraped
  ground-truth geography). One decoder for every family (`decode.R`).
- [x] **Geography — all 11 attributes**: name, DGUID/GEOUID, level, type +
  abbreviation, province abbreviation, two geocodes, data-quality flag + note,
  non-response rate (StatCan geo attribute keys 3,4,5,9,10,12–17), **on the
  DEFAULT metadata path** — `metadata$geographies` packs every decoded per-member
  column and drops all-NA ones, so each vintage exposes exactly what it stores.
  The stored combined display string is kept verbatim as `geo_label` (the viewer
  join key) and split into `geo_name`/`geo_name_fr` (`ivt_f2_split_bilingual()`:
  `" | "` always splits; `" / "` only with positive French evidence, so
  `Kootenay Boundary E / West Boundary` and `Greater Sudbury / Grand Sudbury`
  stay combined). Pre-DGUID vintages additionally yield `geo_type_abbr` (the
  CSD-status token `T` / `MÉ` / `IRI`, the 1981/1996 `SUN`/`COM` styles, the
  cro/ord `", CSD"` suffix) and `tnr_short_form` (the 2016+ trailing `( 4.0%)`,
  normalised). Large chunked tables stay uid-only by default; the full table via
  `read_ivt(geo_attributes = TRUE)`.
- [x] **Dimension member labels, counts, ordinals, hierarchy** — bilingual
  (see below), with `ordinal`, `depth` and `parent_id` per member.
- [x] **Footnotes with scope** (table / dimension / member) — modern framed
  `Footnote N`/`Renvoi N`, legacy `(N) text`, and the numberless all-caps
  `FOOTNOTE:`/`RENVOI :` framing (1981–2016). Identity falls back to the
  master-directory blobs (`ivt_f2_master_identity()`) when both the inline text
  and the `@40`/`@48` title blocks are absent.
- [x] **Header layout pointers** (`ivt_f2_header_layout()`), format/version
  indicator, DQF legend, master directory — see the section-pointer table below.
- [x] **French member labels + French dimension names.** Each dimension's slot
  directory carries a dictionary/schema block naming its fields
  `Code · English Desc · Desc Français` (`Desc fran` in 1991), and the member
  blocks are laid down in that **schema order** — EN vs FR is a **structural**
  decision (`ivt_f2_dim_dict_en_first()`), with `ivt_f2_frscore()` only as a loud
  fallback. Each dimension gains `members_fr`/`name_fr`; `dimension_names_fr` is
  on the metadata list. The French dimension name comes from the French
  `Total - <name>` first member (the header Variable List is English-only); NA
  where the first member is not a `Total - …` label. Validated on 98-10-0241
  (6 dims), -0023/-0129 (incl. the Gender/Sex dims frscore cannot separate) and
  1003011.
- [x] **Member-ordinal arrays** (`ivt_f2_dim_dir_ordinals()`) — read positionally
  per dimension; a candidate must be a permutation of `1..count` (which rejects
  numeric label blocks like reference-period years). Exposed on
  `ivt_metadata()`, `ivt_members()`, the `_members.parquet` sidecar, and consumed
  by `collect_ivt()` for full-level factors. On every validated table the stored
  ordinals are the identity.
- [x] **Page-marker bytes `b2`/`b3` as size fields**: `b2` → the pad/`0xFF`
  trailer (`2·(b2>>4) + 2·(lo>0)`, 0 when `b2==0`), `b3` → an auxiliary head block
  of `32·(b3−8)` bytes (`b3 ∈ {08..0e}`); value run starts at
  `4 + presence_len + trailer + head` (`ivt_value_trailer()`).

## [~] Read but not surfaced (recoverable, just not exposed)

- [~] Block-framing `<u16>` length prefixes — we scan instead of using them.
- [~] The doubled directory size field (second copy ignored).
- [~] The geography chunks' running ordinal delimiters (1..256, 2049.., …) —
  anchors only.

## [?] Read structurally but semantics unproven

- [?] Fixed header fields `@4,@8,@12,@16,@20` (constants `32`, `64/8`, `544`,
  `32/14`, `4096`) — `@20` is the family-1 `0x1000` stride; the rest unexplained.
- [?] Descriptor sub-header bytes (`f0 20 00 80`, `8f c8 0f f8`, per-dimension
  display masks `f3 ff f0 ff` / `c0 ff c0 ff`).
- [?] What the `b2` trailer / `b3` head bytes *contain* (the 2006 heads carry
  per-geo sentinel/value words). The arithmetic is corpus-verified, so this is not
  a decode gap.
- [?] Dimension type markers are **storage/classification tags, not identities** —
  never branch on them (see the width-tag invariant in CLAUDE.md).

## [ ] Open gaps

- [ ] **The `16 00` member-code block's mid-section** (between the u16 slot
  allocation and the tail Pascal codes) is undecoded and very likely carries
  **per-slot flags** — the analogue of the time table's flag bytes. Decoding it
  would give a fully declared slot table for every dimension, subsuming the
  `ivt_f2_dim_slot_expand()` deleted-slot margin heuristic (accs Sex: 6 slots /
  5 members) and fixing the accs **Offences** label alignment (64 stored label
  records for 40 members — 24 deleted slots at unknown positions, so its labels
  come from a count-anchored scan and may be misaligned; the EN/FR pair likewise).
- [ ] **EO2654_2011_Van geography column identity** stays a content heuristic: its
  field dictionary declares 5 columns but only 4 are stored, so the run → column
  map is not 1-to-1. Resolving which field is unstored would make it
  schema-driven like every other table.
- [ ] **EDDTAB16 geography reads by code, not name** — its rich no-UID hierarchy
  dictionary (`Geocode2/ProvName/CARName/CDName/CCSName/GeoLevel/LowLvlName/
  CompleteName`) has six fields mapping to `geo_name`, which the shared reader
  cannot disambiguate, so it stays an ordinary data dimension (like sibling
  `EMPLOY1`'s GEOGRAPHY). The names are present in the codebook, just not surfaced.
- [ ] **Type-00 sub-A industry labels are PROVISIONAL** — the reconciliation gate
  validates SUMS, not the SIC-code → member assignment (a uniform relabel leaves
  the sums unchanged) and there is no ground truth. Loud `canivt_suba_labels`.
- [ ] The remaining **UNSUPPORTED** files — see
  [`unsupported-formats.md`](unsupported-formats.md).

## Structural guarantees (page geometry is validated, gaps are LOUD)

Per-page invariants, enforced by the decoder and verified across every page of
every supported table:

- **b2 trailer formula** — `b2 == 0x00` → no trailer, else
  `2·(b2 >> 4) + 2·(low nibble > 0)`. Derived from 98-10-0013 (22 pages, 18
  distinct b2 values, trailers 6–14, each byte-exact vs the StatCan CSV); it
  reproduces the formerly hard-coded six-marker constants, which had only *looked*
  like per-width constants because b2 never varied within a marker family before
  0013. Unknown width codes / high nibbles abort (`canivt_unknown_marker`).
- **b3 head formula** — `32·(b3 − 8)` bytes before the value run,
  `b3 ∈ {08..0e}`. Generalises the former "+32 on `0xa2` pages" constant and
  is what unlocked the 2006 vintage (b3 = 0a/0c, 64/128-byte heads). The head is a
  contiguous run of 32-byte blocks, so the set is the observed *span*: `0b/0d/0e`
  were added for the SLID-era income lineage (2026-07-25), where the head grows
  with the geography dimension's slot allocation. Those pages carry allocation
  slack, so only the `≤` extent bound applies to them — the head length was
  confirmed by data reconciliation instead (14,520/14,520 age-additivity groups on
  `SP3_RHUXA9_404`). Unknown b3 aborts.
- **Extent check** — `4 + presence + trailer + head + nv·width ≤ size` always,
  with **equality only when `b2 == 0 && b3 == 08`** (pages with a head block may
  append an absent-cell mask / allocation slack after the dense run). Overrun
  aborts (`canivt_page_overrun`). Decoding stays presence-authoritative, so a tail
  never affects it.
- **No silent page skips** — a directory entry pointing at a REAL value page we
  cannot decode warns (`canivt_skipped_pages`). "Real page" is validated by
  GEOMETRY (`ivt_skip_is_lost_page()`), not the four marker bytes alone: the
  target must be a value page whose presence record and tightest value run fit the
  entry's allocated size. That separates a genuinely undecodable page from a
  codebook block coincidentally addressed when a **sparse** directory is
  over-walked (`CDNAIC3_LOC-1` walks a 209×314 cartesian over 282 real pages,
  resolving ~20 k absent coordinates onto 644 codebook offsets, NONE a real page —
  additivity-validated complete without them). The tally dedups by offset.
- **Pre-flight** (`ivt_page_preflight()`) applies the above to the first pages plus
  a **capacity rule** (presence bits ≤ the page's real cell count) and a **span
  rule** (the highest valid directory entry must sit in the outer dimension's
  upper half), and is part of `ivt_f2_decodable()` — so same-signature containers
  inconsistent with the layout are rejected as unsupported instead of decoding
  unvalidated values.
- **Every content-heuristic fallback is loud** (`ivt_fallback()`, classed
  `canivt_fallback`; `options(canivt.strict = TRUE)` → error). Detection probes
  stay quiet (`ivt_quietly()`).

Hard-coded content guesses closed by the same sweep, each exposed by a new corpus
table (kept as regression warnings):

- `@558` stores only the **low 16 bits** of the directory offset (`ivt_idx0()`
  unwraps by `+ k·65536`): 98-10-0013's directory is at `44761 + 65536` — its cell
  decode had been silently EMPTY; now 37,587/37,587 exact. 95F0250XDB96001 needs
  `k = 2`.
- The page-directory entry floor `off ≥ 1e5` silently truncated
  98-400-X2016387's directory to 6 of 22 pages; the floor is now **1024**.
- The doubled-name anchor required an uppercase first letter: 95F0250XDB96001's
  "1995 Household Income (3)" dimension was silently dropped and the 2-dim layout
  decoded misindexed cells **that passed the pre-flight** — only viewer validation
  caught it (now 72/72). Digits are admitted; the header `n_dim` field is
  unreliable (95F0200XDB96003 reads 1026 with 4 clean dimensions) — every gate uses
  `length(d$dims)`.

**The `0xa` marker variant is a storage variant, not suppression**: `0xa2`/`0xa4`/
`0xa8` pages carry real inline data that decodes cell-exact; the high nibble only
lengthens the pad/`0xFF` trailer. **All-zero geographies** (empty presence record)
occur on both `0x8` and `0xa` pages, sometimes beside a data-rich geography.

**Suppression is WHOLE-GEOGRAPHY cell absence, not a per-cell sentinel** — and it
is recoverable: on 98-400-X2016120 (income) the 888 geographies with no stored
cells are exactly the 888 whose inline dqf flag ends in `9` (888/888, zero
crossovers over 4,868 geographies), and the viewer renders exactly those blank.
`read_ivt()` exposes both signals: `metadata$geographies$has_data`
(presence-derived, universal by construction) and `dqf_code` (inline pre-DGUID
tables). Cross-vintage: digit `9` marks suppression per subject (exact on both
2016 income tables, a consistent subset on the 2016 commuting table, multi-9
patterns on the 2021 CT table's 90 empty geographies); the 1996/2011 flags carry
0/1/2 quality rounds without 9s and their empty geographies are genuinely
empty/tiny rather than quality-suppressed; 1991 has no 9-convention.

## [x] Header section-pointer table — DECODED and WIRED (`dimdir.R`)

The "variable section-pointer table" (~header bytes 690–1080) is the **primary
anchor** for member labels, footnotes and the geography block directory
(`ivt_f2_dim_slots()` / `ivt_f2_dim_dir()` / `ivt_f2_dim_dir_labels()` /
`ivt_f2_dir_footnotes()`; marker / tail-scan paths survive as fallbacks). Wiring
validated byte-identical on all five reference tables, with footnotes now
dimension-attributed and small family-1 metadata ~5× faster.

- **`@824 + 14·(k−1)`** — a 14-byte record per descriptor dimension `k`:
  `[u32 dir_ptr][u32 ?][u32 n_entries][2B]`. `dir_ptr` points at that dimension's
  block directory (`[u32 off][u16 len][u16 len]` entries), directly or — for the
  big chunked geography directories (98-10-0023: 6,244 entries) — via a small
  struct whose first u32 is the directory (the two indirection depths
  `ivt_f2_geo_block_dir()` implements). `n_entries` matches the decoded count (up
  to 2 null slots).
- Each **dimension directory lists that dimension's complete codebook in logical
  order**: dictionary/schema block, member-id table, ordinals, the `81 02 02 00`
  doubled-name marker, **row 6 = EN member block, row 8 = FR member block**
  (consistent across all 17 data dimensions of the three reference files), then
  that dimension's footnotes (EN/FR pairs preceded by the member bitmap) — i.e.
  the footnote → dimension attribution the tail scan cannot provide.
- **The 1991 legacy file has the same table** (`@824` → 1,097-entry geography
  directory; `@838` Age; `@852` Sex). Its geography directory exposes, per group
  of `G` 256-member chunks (the same `1,1,2,4,…` group sizes as the modern chunked
  codebook), four attribute runs: the combined `"name (code) flag"` block (one run
  per language), a separate **clean name array** (accent-stripped search names —
  `Malpeque`, not the display `Malpèque`) and a **bare-GEOUID code array**,
  interleaved with framing, per-4-chunk index blocks and ordinal delimiters.
  `ivt_f2_geo_inline_dir()` reads these positionally (record-count-validated per
  chunk): the old byte-ascending scan + dedup had silently **misordered the last
  2,435 members** (tail chunks are stored out of byte order); the positional read
  matches the viewer's member list **41,859/41,859**. The same reader covers
  2006/2011/2016, each viewer-validated.
- **`@712` — the DQF legend directory** (`ivt_f2_dqf_legend()`): 15 entries on
  every 2021 table — a u32 index entry then 14 legend records framed
  `[82 01][u16][flags][02][code char][00][u16 text_len][text]` (FR records carry an
  extra flag dword) in EN/FR pairs per code A…E, R Revised, P Preliminary. Exposed
  as `dqf_legend` (`code/text_en/text_fr`); pre-DGUID tables carry a 1-entry
  6-byte stub → NULL. A nearby symbol legend directory is not yet slot-identified.
- **`@544` → the master directory at offset 992** (`ivt_f2_master_dir()`; also
  reachable via `@992`/`@1000` and `@12` with one indirection). ~10 entries in a
  stable order covering the whole file: FACET04 + EN title block, the dimension
  descriptor (the block `@32` points at, 14 framing bytes earlier), a 15-byte EOF
  trailer, the EN identity/notes blob, the product-id string, small framing blocks,
  then FACET04 + FR title and the FR blob. `ivt_f2_legacy_footnotes()` bounds the
  legacy `(N)` parse to exactly the EN blob entry (the 200 KB tail window survives
  as fallback).

## [x] Footnote linkage — decoded and WDS-validated

Every footnote carries a `scope` (`table`/`dimension`/`member`), the owning
`dimension`, and `member_id`/`member_refs` — matching the three-tier scope in
StatCan's WDS footnote links (`dimensionPositionId` 0 = table, `memberId` 0 =
dimension). Geography is a dimension here too.

- **Member notes** — each dimension's footnote region opens with a `84 01`-framed
  **member bitmap** (identical EN and FR copies) read with the presence convention
  (byte-pair-swapped, MSB-first); `ivt_f2_footnote_bitmap()` → 1-based positions,
  and the first `popcount` text entries per language are those members' notes.
- **Dimension notes** — the remaining entries (`memberId 0`). Where StatCan splits
  a target's note into several Note IDs the IVT concatenates them into one entry,
  so scope/member attribution is exact but the per-Note-ID split is not always
  recoverable.
- **Table notes** — in the master-directory identity blob, framed `Footnote N` /
  `Renvoi N` (the bare `Footnotes :` section header is ignored).
- Validated exact vs WDS on 98-10-0241 (10 targets), 98-10-0077 (9 incl. a
  table-level note), 98-10-0023 and 98-10-0129.
- **Legacy `(N)` linkage** — pre-DGUID profiles store a table-wide numbered list
  and members *cite* notes by embedding `(N)` in their labels.
  `ivt_f2_note_refs()` parses only numeric parens resolving to a valid note number
  (so profile line numbers and text parentheticals are ignored) and
  `ivt_f2_attach_legacy_refs()` makes each cited note member-scope with
  `member_refs` (one-to-many; `member_id` only when a single member cites it).
  **Quiet, not a fallback** — the `(N)` marker is the file's own notation and the
  read self-validates. Validated on 98F0172X/95F0170X (39 notes, 131 refs) and
  1003011 (40 notes cited by nobody → all table scope).

## [x] Geography read — one path, recover-then-specialize

The geography read is a single path (refactor-plan.md §7): Stage 1
`ivt_f2_geo_entries()` locates the geo block directory ONCE and exposes lazy
memoized per-entry accessors that all six readers consume; the dispatcher
`ivt_f2_geo_read(raw, full)` runs the ordered specializer chain (flow → inline →
schema → custom → bare) that `ivt_f2_geo_light()` and `ivt_f2_geographies()` share
as thin wrappers. Stage 3 `ivt_f2_geo_combined()` (`canivt_geo_unparsed`, loud) is
the last-resort net: `ivt_f2_geo_assemble_runs()` rebuilds the parallel member
arrays with the same group/chunk geometry as the schema'd reader, inferring the
run count from the block count.

**Column identity is metadata-driven where the file declares it.** The schema-less
custom exports carry a `81 02` field dictionary (`ivt_f2_geo_field_schema()`, the
data-dim `Code / English Desc / Desc Français / … / UID/IDU` vocabulary the
modern-DGUID grep misses); when its named columns match the runs 1-to-1,
`ivt_f2_geo_field_roles()` maps each run by the file's own field names. Only
without a matching dictionary does it fall to the content heuristic (display name =
most human-readable non-uid run; uid = unique digit-bearing code; whole-string last
resort). Recovered: **EO3278_T1_CDCSD** schema-driven 5,146/5,146 names + the
declared `UID/IDU` uids (the heuristic had mis-picked the `Geo Code` column);
**EO2654_2011_Van** 3,433/3,433 via a header-name geo-dim fallback
(`canivt_geo_by_name`) + short-directory acceptance (`canivt_geo_dir_short`,
validated by `ivt_f2_check_geo_count()`) — still heuristic, see Open gaps.

The whole read is snapshot-guarded (`tests/testthat/fixtures/geo-snapshot.csv` —
light for every corpus table, full for 23; opt-in `test-geo-snapshot.R`), and
geography identity feeds only the slug/metadata, never the positional cell decode.

## [x] Lineage coverage

Every `.ivt` in the corpus decodes except the ledgered guard files. What unlocked
each lineage (narrative + validation records in
[`decode-history.md`](decode-history.md)):

| lineage / example tables | what unlocked it |
|---|---|
| 2021 modern (98-10-0241/0077/0662/0023/0129/0013/0044/0174) | the base model; b2/b3 size fields, `@558` unwrap, `0x09` u16 width tag |
| 1991 legacy (1003011) + 1991 profiles (98F0172X, 95F0170X) | dense `0x0_` page variant (one value per grid position, zeros literal); positional inline geo directory |
| 1991 enumeration-area census (1006454 / PID 128) | chunk-run count probe on every dimension (geo `count 52` = chunk count → 13,372 EAs, 8,308,875 cells) |
| 1996 (94F0009XDB96078, 95F0250XDB96001, 95F0223XDB96001, 95F0200XDB96003, b28ea47, 95f0205xdb96003) | digit-initial descriptor names, `@558` `k = 2`, chunked counts |
| 1981/1986 profiles (97-570-X1981004/1002, 97-570-X1986002) | geography-LAST lineage (`ivt_f2_geo_dim_index()`), double-01 count reconcile, INVERTED descriptor |
| 2001 F-series (97F0020XCB2001070, 97F0015XCB2001041, 95f0487/95f0491/95f0494/95f0338/95F0377/97F0007) | `0x09` u16 width tag; prose-bleed name recovery; chunked-count reconcile |
| 2006 (97-563-XCB2006072/58, 97-554-XCB2006027, 97-555-XCB2006058, cro0172986) | b3 head-block rule + suppression tails; `canivt_geo_datadim` for uid-less custom geography |
| 2016 `98-400-X` crosstabs (2016203/2016019/2016328/2016261/2016120/2016387) | `0x0a` u16 width tag; leading-block skip in the geo run walk; entry floor 1024 |
| 2016 custom extracts (CRO0163850, CRO0166131, EO3278, EO2654) | accept-all descriptor walk, `81 02 01 00` name marker, geography laid out like a data dim, field-dictionary roles |
| 2021 custom orders (ord-08035…) | count-0 reconcile + `81 02 01 00` value block |
| commuting flows (99-012-X2011032, 98-400-X2016325/391/327, 2021) | three encodings — `0x0f` packed, residence×work crosstab, single-dim `"origin / dest"` labels; flow = TWO geographies (POR/POW) |
| CMHC movers (2016 Table 1/2/3) | ordinary containers once the descriptor walk generalised |
| Canadian Business Patterns (Dec07DA … December 2015) | descriptor signature ending `80 ff`; geo record with no `01` separator, position varies by year; bare 8-digit DA GEOUIDs |
| `02 00 20 00` survey generation (Health Statistics 1999, Agriculture/Small Area Business 1996, tb-series — 23 files, strict-clean) | `ivt_f2_descriptor_02()` rebuilds the descriptor from the codebook; the `08 00` time-series member table (slot flags + u24 dates, epoch 0000-03-01); slot-aware layout; NO geography dimension |
| no-descriptor-block surveys (LFHR Table-051, justice h2530002, UCR table_5_c/6_c) | `ivt_f2_descriptor_from_slots()` synthesises the descriptor from the `@824` slot table |
| LFHR long series (Table-023) | u16 `alloc` read + the declared slot allocation rule (see below); `0x20` post-bitmap dense-array marker → Hours = 10 |
| 1996 chunked gen02 (b34csd_1, EDDTAB16) | `ivt_f2_slot_chunked_count()` — the inverse of the codebook chunk layout |
| 2016 Census of Agriculture (00040200, 00040207) | the `[type][count] 01 02 <doubled name>` facet framing (gated on facet count `< 0x20`); inline `[code]` geography |
| type-00 sub-A provincial Business Patterns (PROVINDjune1997, PROVSIC3june1997, PROVSIC3-1) | `R/suba.R` — stride MEASURED from the directory, count from codebook chunks, **commits only if the decode reconciles**; labels provisional |
| 2021 postal/electoral (98100019 FSA, 98100010 FED, 98100013 ADA) | no code change for cells; full attribute read needed `ivt_f2_dir_is_text_block()` (per-member footnote text blocks in the directory tail) |
| SLID-era income (SP3_RHUXA9 103/404/405/501/701/703) | under-declared count reconcile — the declared slot allocation is the second count witness (`> 4·nextpow2(count)` ⇒ take the codebook member array's length, `canivt_underdeclared_count`); page-head codes widened to `b3 ∈ {08..0e}` |

## [x] The `04`-gen "doubled-window" survey directory — RESOLVED (2026-07-23)

**The "doubling" was never a variant — the paging geometry is DECLARED
per-dimension metadata** that the layout had been re-deriving as `nextpow2(count)`.
Every dimension of every corpus table carries a member-slot block in its slot
directory — the member-code block `81 02 <alloc-u16> 16 00` or the time-series
table `81 02 <alloc-u16> 08 00` — whose leading u16 is the dimension's allocated
SLOT CAPACITY. `ivt_layout()` pads every nesting level (presence bits and
directory strides alike) to this declared allocation (`ivt_f2_dim_slot_alloc()`),
falling back to `nextpow2(extent)` only when the declaration cannot hold the
members (chunked >1024-member dims declare a block-local 1024).

Corpus census: `alloc == nextpow2(count)` on ~350 dimensions across ~100 tables
with exactly one exception — **Table-023's Hours, 32 slots for 10 members** — which
is precisely the table that had needed a "doubled window": windows-of-4 over 32
allocated slots = 8 directory slots where `nextpow2(ceil(10/4)) = 4`. So the
census/profile corpus is byte-identical under the rule, Table-023 decodes its
identical **5,771,932** cells with no probe and no fallback, and
`ivt_survey_double()` (the page-size signature probe) is **retired**. The former
red flags dissolve: a full 87,300-entry directory scan confirms the padding slots
hold only minimal 392-byte empty pages, and detection is now a declared metadata
field rather than an inferred signature. The `ivt_page_preflight()` extent guard is
retained and still honest-rejects a directory the layout does not model.

**Table-024 retro-confirmation**: its "ipc mismatch" (in-page Occupation `ipc = 2`,
17 windows, where the pow2 model computed 4/9) is exactly what the rule produces —
Hours alloc 32 × Timeseries alloc 32 = a 1024-bit inner block →
`ipc = 2048/1024 = 2`, `ceil(33/2) = 17`.

**Historical note**: the accs table showed the same doubled-directory *symptom*
from a different cause — an interior DELETED member slot in Sex, solved via
`ivt_f2_dim_slot_expand()` (`canivt_deleted_slot`). Both are now principled:
deleted slots widen the *extent*, the allocation widens the *padding*. The
still-open `16 00` mid-section (per-slot flags) would subsume the deleted-slot
heuristic — see Open gaps.

## Summary

For the reference tables (98-10-0241, 98-10-0023, 1003011) ~100 % of
information-bearing bytes are identified, and the data plus all
geography/dimension/footnote metadata decode exactly in **both languages**. The
remaining bit-level gaps are a few small header/marker bytes with inferred
semantics and the dense value arrays' per-member bitstream coding (whose values
decode fully via the plain siblings' NA pattern).

The unified decoder handles arbitrary-dimension tables and spans **1981–2021
census vintages** plus the non-census survey/Business-Register generations listed
above. Footnote scope is complete across the corpus; geography names are complete
(every member of every supported table gets a non-NA `geo_name`, including the
17,163 flow members of 99-012-X2011032).
