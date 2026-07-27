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
exactly) and **3.3 %** is the pre-value region + page tail. That 3.3 % is **not**
information-free, as this table's own numbers long suggested: on `0x8` pages the
pre-value region is the tail's index bitmap and the tail is the absent mask
(both decoded, see below); on `0xa` pages the tail is the reason-code array
(still open).

## [x] Fully decoded and exposed

- [x] **All cell values.** Validated cell-for-cell vs the StatCan CSV / B20/20
  viewer (family 1: 7,489,464 cells; family 2: 14.5 M; 1991: every scraped
  ground-truth geography). One decoder for every family (`decode.R`).
- [x] **The `0x8` page absent mask — which absent cells are ZEROS and which are
  MISSING** (gap opened *and closed* 2026-07-27; `status.R`, opt-in via
  `read_ivt(missing = TRUE)` → `x$missing`). The bytes between the presence record
  and the value run are an **index bitmap** over the trailing block's
  `width`-byte words, gated on `popcount(index) · width == tail length` —
  **1,810,626 / 1,810,626 mask pages of the corpus, 0 unreadable, 0
  contradictory**. The rebuilt block's first `rec_bytes` are the mask (MSB-first,
  *not* pair-swapped, addressed at `lay$grid$bit`): masked absent ⇒ genuine zero,
  UNMASKED absent ⇒ missing. Reproduces the viewer-validated
  `97F0020XCB2001070` measurement exactly (344 missings over the 86 tail-bearing
  pages of geographies 1–13; **0** for Nunavut). Eight corpus tables report
  missing cells; the remainder report none, which is the confirming half — those
  tables publish no missings. Off by default: the ledger asserts exact cell
  counts and warning sets, and completeness is vintage-dependent (below).
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

- [ ] **The `0xa` cell-status ARRAY is not decoded** (gap OPENED 2026-07-27;
  narrowed 2026-07-27 — the `0x8` mask half is now closed, see below). Pages with
  `b0` high nibble `0xa` carry, after the value run, a self-describing
  `[form][02][W]` array holding **per-cell missing-data reason codes** — `W = 2`
  vocabulary `0` value/genuine zero, `1` filler, `2` = `x` suppressed,
  `3` = `...` not available. canivt reads exactly `popcount` values and discards
  the block, so these codes are lost and the documented "an absent cell
  is a zero" rule is **wrong for these tables**: absence is the union of genuine
  zeros and true missings. `read_ivt(missing = TRUE)` counts these pages
  (1,273,173 over 47 of the 170 ledger tables) and warns
  `canivt_status_block_undecoded`
  rather than guessing at them.
  - Vocabulary validated cell-exact against StatCan's published tables
    (`getFullTableDownloadCSV`): 98-10-0040 `10 x / 49 ...`, 98-10-0655
    `0 / 2,600`, 98-10-0658 `0 / 1,348`, 98-10-0128 `389,888 / 1,466,488` — all
    exact on both codes. 98-10-0655 also position-exact over all 11,154 cells;
    98-10-0040 joins 59/59.
  - Blocked on a general **addressing** rule: 98-10-0655/0658 index at the padded
    presence-grid cell index, 98-10-0040 packs tighter (24-byte geography stride
    vs a padded 128 codes), 98-10-0128 uses per-member sub-blocks
    `[8][48 filler][variable data][48 filler]` with page-varying data length.
    `W = 4` (6 tables), `W = 8` / `W = 1` (survey lineage) are unvalidated.
  - Incidence: 47 of the 170 ledger tables carry `0xa` pages — 2021 NDM
    `9810xxxx`, 2016 `98-400-X`, two 2021 custom extracts (an earlier 171-**file**
    marker scan put 33 of them in the `W = 2` form). **No pre-2016 vintage has
    one.**
- [ ] **The SECOND tail block is not decoded** (gap OPENED 2026-07-27). On 8 corpus
  tables some pages' index bits address words **past** the mask's `rec_bytes`, so
  the same index also addresses a further array: `SP3_1H8SBB_97-555` (11,463
  words), `SP3_AVQOPM_97F0007XCB2001042` (6,877), `97F0015X` (3,113), `97-563`
  (1,567), `pid59227` (805), `SP3_APKNWC_100801` (47),
  `SP3_BJFWAP_95F0377XCB01005` (10), `95f0491xcb01004` (3). Its content is packed
  flag words (`0x3333`, `0x1111`, `0x33FF`, all-ones — nibbles confined to
  `{0,1,3,7,b,f}`, written as numbers in the page's own value type), but it is
  **not a per-cell code array under any of 16 tested encodings** (best 3/400
  pages; `97F0007` 0/107 everywhere) and its size correlates with no per-cell
  quantity. Counted as `extra_words` and reported loudly
  (`canivt_status_extra_block`). Write-up: [`ivt-format.md`](ivt-format.md),
  "The second tail block (OPEN)".
- [ ] **Three known limits on the decoded `0x8` mask**, all reported rather than
  hidden (`read_ivt(missing = TRUE)` raises a classed warning per page class):
  - **Missings past the written mask** (`canivt_status_beyond_mask`): all-zero
    words are dropped by the sparse index, so a mask can stop short of the grid,
    and every cell past that point is unmasked for want of a word rather than by
    the file's statement. Legitimate where the trailing cells really are all
    missing, but indistinguishable from a truncated mask. 2,290,657 of the
    corpus's 3,674,333 reported missings — concentrated in `97F0015X`
    (1,929,312 of 2,080,404) and `97F0007` (360,765 of 1,586,079); `97F0020`'s
    viewer-validated 344 are **0 beyond**.
  - **No tail at all** (`canivt_status_unreadable`): the Business Patterns and
    type-00 sub-A lineages write no page tail, so nothing can be said about their
    absent cells. 64 of the 170 ledger tables have no mask pages, 36 of them no
    tail of any kind.
  - **The x87 signalling-NaN artefact** (`canivt_status_nan_quieted`, kept a
    warning under strict — it is source damage, not a canivt fallback): a
    mostly-ones mask word is NaN-shaped, and the writer's x87 load/store quiets
    it, destroying one status bit **in the file**. 0 signalling NaNs survive in
    63,582 `width = 8` mask words vs 374 / 94,893 (5.9 %) on `width = 4`, where
    no quieting applies.
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
  over-walked (a whole unwritten window resolves onto codebook offsets, NONE of
  them a real page — see "Sparse directories" below). The tally dedups by offset.
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

**The `0xa` marker variant selects the page's cell-status form** (superseding this
file's earlier "storage variant, not suppression" — that was measured on the
*value* decode, which it does not affect). `0xa2`/`0xa4`/`0xa8` pages carry real
inline data that decodes cell-exact, and the high nibble changes the pad/`0xFF`
trailer length, but it **also** picks which status block the page appends: `0x8`
→ the 1-bit absent mask, `0xa` → the reason-code array. **All-zero geographies**
(empty presence record) occur on both, sometimes beside a data-rich geography.

**Whole-geography suppression is real but COARSE — there IS a per-cell signal**
(superseding "not a per-cell sentinel", 2026-07-27: the page tail carries one, in
every vintage). The whole-geography signal is recoverable and remains correct for
a geography with no stored cells at all: on 98-400-X2016120 (income) the 888 geographies with no stored
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
light for all 170 corpus tables, full for 25; opt-in `test-geo-snapshot.R`), and
geography identity feeds only the slug/metadata, never the positional cell decode.

## [x] Lineage coverage

Every `.ivt` in the corpus decodes — the refusal ledger is empty. What unlocked
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
| 2001 census DA-level (95f0437xcb01001, pid59227) | the descriptor record as a count oracle — a rebuilt descriptor's "256" is the codebook chunk size (`ivt_f2_desc_declared_count()`); plus the member-count bound on ordinal runs, so consecutive DA codes stop faking a delimiter |
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
| historical Census of Agriculture (optab12, optab13) | no code change — ordinary `04`-gen containers, descriptor synthesised from the `@824` slot table |
| UCR police-reported crime (table_5_c-2008, table_6_c-2007/2009) | `ivt_f2_descriptor_from_slots()`; slot-addressed member arrays; the widened text-blob recognizer (the per-dimension documentation blob) |
| provincial Business Register NAICS (PRSIC1dec1999, PRNAIC6dec2000) | ordinary `02`-gen containers once the `16 00` slot table declared the industry counts |
| CD/CSD Business Register NAICS (CDNAIC3_LOC-1, PRVNAIC3_LOC-1, CDCSDNAIC3dec2006) | the page directory as the third count witness (`ivt_dir_outer_count()`, `canivt_container_count`); positional geography codebook arrays; the code-first `"<code> - <name>"` combined form |
| LFS historical review (Table-023, Table-024, Table-051) | the declared slot allocation; `ivt_f2_descriptor_from_slots()`; `canivt_geo_datadim` geography |
| transition-home / victim-services surveys (02560006) | under-declared count reconcile + `b3 ∈ {08..0e}` page-head codes |
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
deleted slots widen the *extent*, the allocation widens the *padding*.

## [x] The `16 00` mid-section — DECODED (2026-07-25)

The block's mid-section is **22 bits per allocated slot** (byte-pair-swapped,
MSB-first, padded up to an even byte count): bit 0 LIVE, bits 1..12 the unary
member-code length, bit 18 an extra trailing code byte, bit 19 an undetermined
flag; all-zero = never allocated. Full field table and validation in
[`markers.md`](markers.md) §E.1a. Validated by walking the member-code array to a
**byte-exact** fit — 459/459 of the dimensions that own exactly one such block.

The file therefore DECLARES its member count, its deleted slots and its slot
positions (`ivt_f2_dim_slot_table()` → `ivt_f2_dim_slot_declared()`, quiet: it is
a declaration, not a heuristic). What it closed:

- `ivt_f2_dim_slot_expand()` is demoted to the fallback for dimensions with no
  readable declared table (chunked codebooks, code arrays that do not parse
  byte-exactly). The margin heuristic widened the count to the physical extent,
  which kept the geometry right but emitted the deleted slot as a phantom member;
  accs "Sex" is now 5 members with slot 4 declared deleted.
- **CBP2008DA / CBP2010DA were losing 20 industries each.** "NAT. INDUSTRIES" is
  929 members over 949 used slots (20 deleted, scattered from 458 to 836); the
  count-only read cropped at 929 and dropped the live members at slots 930..949.
  Validated: the industry Total now equals the sum of the 928 six-digit NAICS
  leaves in **all 312,417** geography × emp-size groups. Ledger cell counts
  updated (3,957,641 → 4,059,594 and 3,970,492 → 4,075,156).
- Slot POSITIONS need not start at 1: LFHR `Table-210`'s 10-member "Education
  level" sits at slots **10..19** of 32, and `table_5_c`'s 215 "Offences" skip
  slot **98**.
- SP3_RHUXA9_801's garbage descriptor counts (3338/3386/3378/3338) read as
  1/5/2/7, which isolated its remaining problem to the one dimension owning no
  `16 00` block and **onboarded** it the same day (below).

Chasing the accs "Offences" labels through the declared table also turned up an
unrelated, older bug and disproved a standing suspicion:

- Those labels came out in **French on the English path**, and the cause was not
  slot alignment (the declared table shows 40 used == 40 live slots, contiguous
  from 1 — the count-anchored read was always correct). A member label may carry a
  **trailing CR/LF**: one record of the English array reads
  `"Criminal Code (without traffic)\r\n"`, and the member-run screen rejected any
  array containing a control character, so a single terminated record discarded
  the whole English array and the labels fell through to the French one. The
  terminator is record framing and is now stripped before the screen; interior
  control characters still reject, since those are the footnote/definition prose
  blobs the screen exists to exclude. The same rejection had been pushing that
  file's GEOGRAPHY through the whole specializer chain down to the loud
  last-resort net (`canivt_geo_unparsed`, English names only); it now reads
  through the quiet schema path with both `geo_name` and `geo_name_fr`.

## [x] The `08 00` time table declares its count too (2026-07-25)

The `16 00` mid-section's counterpart. A reference-period dimension carries a
`[81 02][u16 alloc][08 00]` time-series member table *instead of* a `16 00`
member-code block — never both — and it declares the same two things: how many
members, and at which slots. `ivt_f2_time_members()` has read it since the
`02`-generation onboarding; `ivt_f2_dim_time_declared()` now presents it to
`ivt_f2_dim_slot_declared()` whenever the `16 00` table is absent or does not
validate. The gate is the **dates**: accepted only when every populated slot
resolves to a plausible date, which a run of bytes that merely looks like a flag
array cannot do. A declaration, so quiet.

This onboards **`SP3_RHUXA9_801`** (SLID low-income cut-offs, 1980–2002), the last
UNSUPPORTED file of the SLID-era income collection: its four data dimensions
declare 1/5/2/7 in `16 00` blocks, but "Date" reads **3386** in the descriptor
against **23** declared annual members — a 237,020-cell cartesian in a 16.7 KB
file, which is why the pre-flight rejected it. 1 × 5 × 2 × 7 × 23 = **1,610**
dense cells, ledgered `TRUE,FALSE,1610`. Validated on four internal invariants of
the value surface (LICO monotone in family size 230/230 groups, in year 70/70
series, in community size 322/322 groups; after-tax < before-tax 805/805 cells)
plus the published 1992-base cut-offs; detail in
[`decode-history.md`](decode-history.md). The community-size check is the sharpest
— those labels sort alphabetically into a different order than their ordinals, so
it confirms the ordinals drive the nesting.

## [x] Member arrays can be addressed by SLOT (2026-07-25)

The declared slot map turns out to describe the **codebook arrays** too, not only
the presence bitmap. A dimension's label array is normally one record per member,
padded with empty records to the next power of two — which the trailing-NA trim
recovers. But it may instead be written **one record per allocated slot**, empty
at the slots that were never allocated: `Table_6_c-2009`'s 225 offences occupy
slots 1..107 and 109..226 of 256, and its EN and FR arrays are 256 records long
with holes at 108 and 227..256. An INTERIOR hole defeats the trim, the array was
rejected on length, and the labels fell through to the ordinal run — the members
read `"1"`, `"2"`, `"3"`, … `ivt_f2_dir_member_arrays()` now takes the declared
slots and selects `v[slots]`, accepted only when the array's non-NA positions are
**exactly** those slots, so a coincidentally long array cannot pass.

Same commit, the other half of that table's read: the §F **text-blob recognizer**
was too narrow. It required a `[01]` byte after the length and no `0x00`
anywhere, which fits the geo-tail note blobs but not the survey lineage's
**per-dimension documentation blob** — the UCR "Mandatory reading" HTML, repeated
in every dimension's directory, whose text starts immediately after the length
and IS NUL-terminated. The discriminator is now the two things a member array's
framing guarantees: its leading u16 record count must fit the payload, and its
records leave an interior NUL. All three UCR tables' single geography now reads
`Selected Police Services` / `Services de police sélectionnées` instead of a
fragment of that HTML (`action=loc; form.submit();}">Mandatory reading`).

## [x] The nine deferred files, ledgered (2026-07-25)

The corpus carried nine folders with **no ledger row**, so nothing
regression-tested them; `test-corpus.R` now asserts every corpus folder holding
an `.ivt` has one. Four of them decode with no further work beyond the two fixes
above — the `16 00` slot table, the under-declared count reconcile and the time
table opened them — and all four are validated on the file's own internal
identities:

| table | shape | cells | validation |
|---|---|---|---|
| `02560006` | 15 geo × Number/Percent × Women/Children × 3 reasons × 1998/2000 | 184 | Percent sums to 100 (2/2 complete groups); Canada == Σ provinces exact on 6/9 groups (residuals 2/5/4 from suppressed components). Decisive: 1998 carries "Northwest Territories including Nunavut" with NWT/Nunavut absent, 2000 carries NWT and Nunavut separately with the aggregate absent — Nunavut was created 1999-04-01, so the geography × date nesting is provably right |
| `Table_6_c-2009` | 1 geo × 20 clearance × 225 offences × 2009 | 2,072 | Total == NotCleared + ByCharge + ClearedOtherwise **225/225 exact**; ClearedOtherwise == Σ its 16 reasons **225/225 exact**; the offence hierarchy (parent == Σ children by label indentation) **520/520 exact** — which is also what validates the slot-addressed label assignment, since the hierarchy is a function of the labels |
| `Table-024` | 11 geo × 3 sex × 3 class × 33 occupation × 10 hours × 24 years (LFS 1987–2010) | 506,131 | Average usual hours == Total hours / Total employed within 0.05 on **68,312/68,589** cells; Canada 1987 = 12,333.0 and 2010 = 17,041.0 thousand employed, matching the published LFS. The additive identities (sex, class of worker, Canada == Σ provinces, occupation hierarchy, hours bands) hold to the **rounding bound**: residuals are one-sided — negative only to −0.1/−0.2/−0.3/−0.4 for 2/≤6/7/10 summands, i.e. never past ±0.05 per rounded component — with the positive tail (max 6.7) being the suppressed components the store does not carry |
| `PRNAIC6dec2000` | 14 geo × 930 NAICS-6 × 11 employment sizes (Business Register) | 71,794 | **all four identities exact, zero residual**: Canada == Σ 13 provinces/territories 10,230/10,230; Total (A) == Indeterminate (B) + Subtotal 13,020/13,020; Subtotal == Σ the 8 size bands 13,020/13,020; NAICS Total == Σ the 929 industries 154/154 |

The other five were ledgered `FALSE` as gate guards at the time; all five have
since been onboarded (2026-07-26) and the refusal ledger is now empty — see
[`unsupported-formats.md`](unsupported-formats.md).

## [x] The 256-geography cap — the descriptor record is a count oracle (2026-07-25)

The header-harvest sweep flagged two 2001 census tables reporting **exactly 256
geographies** — a suspicious number, and it was: 256 is the codebook's
**chunk size**, not a count.

The chain: 2001 census records bleed French prose *between* the two copies of a
dimension name (`"Geographyment.Geographydu tableau est modifi…"`), so the
doubled-name anchor loses records (2 of 3, 3 of 4). With too few records the
descriptor is rebuilt from the header slot table (§B), which sizes each dimension
from its codebook member array — and that array is chunked at 256 members per
block. Every large dimension therefore reads back as 256.

The fix is metadata, not a heuristic: the descriptor record *is still present and
its count field is still correct* — only its name framing was unusable. Given the
name (which the rebuild recovers from the codebook), `ivt_f2_desc_declared_count()`
locates `[u16 count][type][01]<name>` in the descriptor block, restricted to the
u16-count storage tags and required to resolve uniquely (markers.md §D.1). It is
wired into **both** rebuild paths (`ivt_f2_dims_from_slots()` and
`ivt_f2_descriptor_from_slots()`) and only ever raises a count, never lowers one.
LOUD: `canivt_declared_count`.

The container confirms the recovered counts independently — the page directory's
outer entry cartesian equals the page count exactly (418 == 418, 6686 == 6686),
which no other count produces — and both files now pass `ivt_page_preflight()`.

**A second, distinct defect surfaced underneath it.** With the right count the
geography *labels* were still shifted by 512 (two chunks) past a point: Ontario's
4,219,410 sat at member 17342 while member 17854 was labelled "Ontario".
`ivt_f2_is_ordinal()` classified two blocks of consecutive numeric **codes** as
ordinal delimiters — the 2001 DA codebook stores geographically consecutive DAs,
so a 256-member chunk can be perfectly consecutive (`35210433, 35210434, …`) and
indistinguishable from an ordinal run. Bounding the test by the member count
(`max(iv) <= n`: an ordinal run indexes members, so it cannot exceed the count)
separates them. The positional reader now returns all 53,488 members with **zero
duplicate uids**, replacing the loud dedup/regex scan that had been misordering
chunks.

| table | shape | cells | validation |
|---|---|---|---|
| `95f0437xcb01001` | 53,488 geo × 3 household sizes × Number/Average/Median/SE (2001 household income) | 539,931 | Canada == Σ 13 provinces on the additive member at every household size (residuals 0/−5/−5, one rounding step); 288 CDs — the true 2001 count — summing to +25 over 288 units; the household-size marginal 2,976,875 + 8,586,100 vs 11,562,980 Total, again one step. Every residual a multiple of 5, the random-rounding signature |
| `pid59227` | 53,483 geo × 4 tenure × 9 period of construction × 4 condition | 2,334,008 | Canada == Σ 13 provinces: **all 144** dimension combinations residual ≡ 0 mod 5, range ±20, mean −0.4; over the 288 CDs all 144 likewise ≡ 0 mod 5, range ±85. Each dimension's Total == Σ its members with max deviation 25/40/20 — random rounding across the whole 4-dimensional nesting, which an incorrect layout cannot produce |

## [x] Sparse directories, and the container as the THIRD count witness (2026-07-26)

The Business-Register cluster that had been ledgered "sparse / over-walked
directory" is not sparse in any new sense. The page directory allocates
`nextpow2(window_count)` entry slots per outer member — the same power-of-two
padding every other level gets — and **a window the writer never populated is
simply a zero entry**, exactly like a wholly-suppressed geography. What looked
like a fragmented directory was a correct directory read against a *wrong
count*.

Measured on the two CD-level tables, whose sub-sector dimension spans 11 windows
(1366 members, `ipc = 128`) padded to 16 entry slots per geography:

| table | entries in cartesian | non-zero | at window slot |
|---|---|---|---|
| `CDNAIC3_LOC-1` | 5,024 (11 × 314, stride 16) | 314 | 0 only |
| `CDCSDNAIC3dec2006` | 94,832 (11 × 5,927, stride 16) | 4,305 | 0 only |
| `PRNAIC6dec2000` | 112 (8 × 14, stride 8) | 112 | all 8 |

One page per geography, always the first window. The referenced pages are
**byte-contiguous** — every inter-page gap is exactly 0 across the whole data
region — so no unreferenced page hides between them: these products publish the
3-digit NAICS level only (the file names say `NAIC3`), while the codebook ships
the complete NAICS hierarchy (Total + 103 three-digit + 328 four + 2 five + 931
six + 1 blank = 1366). The 6-digit sibling `PRNAIC6dec2000` populates every
window of the same model, which is what makes the reading structural rather than
a special case. **The stride is the witness for the count**: a 16-slot stride is
the file declaring an 11-window dimension; had SUB-SECTORS really been the ~104
members that carry data, the writer would have allocated one slot.

**The page directory is the third count witness** (`ivt_dir_outer_count()`,
decode.R), after the descriptor record and the codebook. It runs last, inside
`ivt_f2_dim_count_reconcile()`, probing the geometry the earlier witnesses imply:
it walks the outermost paged dimension across its own allocated capacity and
extends the count to the last member whose entry **decodes and carries cells**.
The walk cannot stop at the first gap (an empty geography is a real member) and
cannot be fooled by codebook bytes (a non-page offset ends the scan). It only
ever raises a count, only where slots have no holes, and is LOUD
(`canivt_container_count`).

Three tables onboarded on this model, all validated on the file's own internal
identities and against each other — no external ground truth exists for the
Business Register at this vintage:

| table | shape | cells | validation |
|---|---|---|---|
| `CDNAIC3_LOC-1` | 314 geo (13 prov + provincial residues + CDs) × 1,366 NAICS × 11 employment sizes | 162,127 | **four identities exact, zero residual**: EMP Total == Indeterminate + Subtotal 26,438/26,438; Subtotal == Σ the 8 bands 24,899/24,899; NAICS Total == Σ the 103 three-digit industries 3,306/3,306; province == Σ its CDs + provincial residue 10,903/10,903. Plus a **cross-file** check: its 13 province rows equal `PRVNAIC3_LOC-1` cell-for-cell on 10,903 (geo, sub, emp) triples, max abs 0 — two files with *different dimension orders and different straddle geometry* agreeing exactly |
| `PRVNAIC3_LOC-1` | 11 employment × 14 geo × 1,366 NAICS | 12,022 | Canada == Σ 13 provinces/territories 1,119/1,119 exact; the same three EMP/NAICS identities exact |
| `CDCSDNAIC3dec2006` | 5,927 geo (prov + CD + CSD) × 1,366 NAICS × 11 employment | 740,237 | province == Σ its CDs **11,002/11,002 exact** (this covers the 13 members the container recovered); CD == Σ its CSDs exact on 98.83 % of rows, the 16 differing CDs carrying unlisted CSD detail (max 1,663), not misalignment; the 13 code-less members are exactly the provinces/territories, summing to 2,311,337 |

`CDCSDNAIC3dec2006` needed three further pieces beyond the count witness, each
metadata-driven:

- its geography codebook arrays are **positional** — interior blank records are
  members (blank-name slots), not padding, proven against the file's own `_Sort`
  code array (1,024 values, exact match at the positional offset, 0 % at the
  drop-blanks alignment);
- the descriptor **under-declares geography by 13** (5,914 vs 5,927): the
  container walk recovers exactly the 13 province-level members, two of which
  have empty pages — which is why the walk scans the whole allocated capacity
  rather than stopping at the first gap;
- its geography labels are combined strings in a **code-first** shape,
  `"<code> - <name>"` (`IVT_F2_INLINE_PAT4`), and its field dictionary
  (`"English Label"`, `"Etiquette"`, `"Type"`, `"_Sort"` → `encoding == "custom"`)
  is what licenses the inline reader to run at all: a *DGUID* schema still means
  the positional attribute layout, a *custom* one names the file's own combined
  columns.

## [x] A directory base may open with UNWRITTEN entries (2026-07-26)

The `@558` header pointer was blamed for two LFHR tables that would not decode
(`SP3_C2YSID_Table-080`, `SP3_NAZQV2_Table-210`, ledgered guards since
2026-07-25). It was correct on both. **`ivt_f2_dir_anchor_header()`'s validator
was wrong**: it required entry 0 of the candidate base to be a page marker, but
the directory pads every level to its declared allocation, so the base's leading
slots can be legitimately unwritten — the same absence a suppressed geography
leaves (the sparse-directory model, above, one level up). Measured leading blanks:
**96** entries on Table-080, **1** on Table-210, **3** on `PROVSIC4dec1997`.
(`PROVSIC2june1998` and `PRVNAIC1dec1998` have **0** — the anchor was never their
blocker, which is why they remain guards.)

`ivt_dir_entry_blank()` recognises the all-zero 8-byte record;
`ivt_f2_dir_first_entry()` walks up to `IVT_DIR_LEAD_BLANK_MAX` (1024) of them
before declining, bounded so a run of header padding cannot be walked into an
unrelated page marker. `ivt_f2_dir_anchor_header()` runs the **strict pass across
every wrap first**, so a blank-led candidate can never be preferred to a populated
one and no previously-working file changes. `ivt_f2_find_directory_impl()` starts
its contiguous-run growth from the first populated record.

One further fix was needed downstream: `ivt_f2_descriptor_impl()`'s
`descriptor_from_slots` early return **bypassed `ivt_f2_dim_count_reconcile()`**,
so a dimension whose `16 00` block declares **live slots above 1** never received
its `$slots`. Table-080 declares "Sex" at slots 4..6 of 8 — exactly where the
directory's entries sit — and without the slot positions the walk read slots 1,2,3
and decoded 0 cells. The rebuild sizes each dimension from its codebook; the
reconcile is what reads the file's declaration of *where* those members sit.

Both tables now decode and reconcile on their own aggregate identities:

| table | shape | cells | validation |
|---|---|---|---|
| `SP3_C2YSID_Table-080` | Geography 11 × Sex 3 × Age 9 × Industry 19 × Job permanency 7 × Timeseries 14 (1997–2010) | 260,724 | 10 additive identities, **100 %** exact on complete slices (~189 k comparisons, max abs. residual 0.1–0.3, mean ≈ 0) |
| `SP3_NAZQV2_Table-210` | Geography 11 × Sex 3 × Age 9 × Characteristics 10 × Education 10 × Timeseries 240 (monthly 1990-01…2009-12) | 6,187,914 | 8 additive identities at **100.000 %**, plus three *cross-dimensional* rate identities (`U/LF`, `LF/Pop`, `E/Pop`) at 100 % over ~1.8 M comparisons |

Two methodological notes, both of which made the first runs look like failures:

- **Restrict aggregate identities to complete slices.** Suppressed small detail
  cells are simply absent from the store, so `total ≥ Σ parts` with a positive
  skew — not a decode error. Requiring every part present makes the test exact.
- **Rate members are not additive.** Table-210's Characteristics 8/9/10 are rates;
  summing them across any dimension is meaningless. Filtering to the count
  members (1..7) took the pass rate from 71 % to 100 %.

Both warn `canivt_descriptor_from_slots` + `canivt_geo_datadim` (LFHR files carry
no descriptor block and no geography dimension), so both are ledgered
`strict_clean = FALSE`.

**The reconcile fix also corrected a third, already-"passing" table.**
`SP3_Q2JJJO_table_5_c-ivt-2008` (UCR) rebuilds from the slot table too, and its
`Offences` dimension declares **215 live slots at positions 1..216 — a hole at
slot 98** (`codes_ok = TRUE`: the slot record's predicted code lengths walk the
member-code array byte-exactly). Reading it dense misassigned every member above
the hole by one and dropped slot 216 entirely; the ledger's old **35,237** was a
silent mis-decode and the correct figure is **35,504**. The 215 labels are
non-blank and the hierarchy indentation is coherent across the hole (97 "Unsafe
storage of firearms" → 98 "Total prostitution", a genuine level change), ending at
"Other federal statutes". Its own `Total`-vs-parts identities are unchanged by the
fix (identical residuals before and after) — this UCR product's totals include
not-stated categories and are not plain sums, so the slot table is the evidence,
not an aggregate check.

The third file the anchor fix un-gated, `SP_VB0LLW_PROVSIC4dec1997`, had its
industry count recovered correctly here (1,255, via
`ivt_f2_slot_chunk_multiset()`: a chunk run may carry a *leading* partial as well
as a trailing one) but stayed refused on an unconfirmable outer stride. That is
closed in the next section. Its geo-snapshot row gains a `canivt_chunked_count`
warning class from the recovered count; `n_geo` (0 — the file has no geography
dimension) and both content hashes are unchanged, so that fixture update was
warning-only.

## [x] The sub-A outer stride is a directory TILING (2026-07-26)

The type-00 sub-A cluster's outer directory stride is a non-declared physical
constant — **measured**, not derived. The old rule looked for a *progression* in
the populated entry indices, which silently assumes the run starts at window 0.
`SP_VB0LLW_PROVSIC4dec1997` lays 11 industry windows per province at entry slots
**3..13** of a 16-slot group, so the progression rule found nothing it could
confirm and the file was refused.

The backlog item asked whether a `16 00` slot table declares those live slots above
1. **It does not** — measured: no dimension in any file of this cluster has a `16
00` slot table at all (`ivt_f2_dim_slot_table()` returns NULL throughout). The
declaration does not exist, so the directory itself has to be the witness.

`ivt_f2_suba_dir_stride()` now measures the **tiling**: every geography occupies
`S` consecutive entry slots and writes the *same* window residues inside them. It
accepts the smallest `S` for which the populated entries fall into `geo_count`
groups with an identical residue set **and** nothing is populated beyond
`geo_count · S` — that last clause separating a real stride from a divisor of it.
A couple of wholly-empty groups are tolerated (suppression is whole-geography; a
geography with no cells writes no entries). It returns the window residues as well
as the stride, and those residues also gate the early return: a file may stride
exactly as the positional model does yet reach *further* than the model's window
enumeration, which is `PROVSIC4dec1997` — `ceil(1255/128) = 10` windows from slot 0
against the directory's 3..13. Reading only that prefix drops the top four windows
and the grand-total member.

The rule is strictly tighter than the one it replaces: it also corrects
`PROVSIC4-2` (reported 4, true 16) and `PRNAIC6dec2000` (reported 4, true 8).
Neither had produced a wrong verdict, because the reconciliation gate rejected the
garbage probes — but neither was being measured correctly.

A second shape was added alongside it, the **detached total**: the `Total` member
alone in window 0 with the detail run right-aligned to the top of the group, which
is how `PROVSIC2june1998` and two siblings lay out. All candidate placements remain
gated on exact reconciliation, so nothing is adopted on shape alone.

Four files onboarded, every previously-supported file in the cluster byte-identical
(whole cluster, 13 files, 12.6 s):

| table | shape | cells | validation |
|---|---|---|---|
| `SP_VB0LLW_PROVSIC4dec1997` | PROV/CAN 13 × SIC-4 1,255 × EMPCLASS 11 | 63,305 | 5 identities, **100 %** exact, maxdiff 0 (below) |
| `SP3_PAWNKX_PROVSIC4-2` | PROV/CAN 13 × SIC-4 1,255 × EMPCLASS 11 | 63,872 | 142/142 groups exact, maxdiff 0; **cross-file** vs `PROVSIC2june1998` |
| `SP3_PAWNKX_CACMA3-2` | CA/CMA × SIC-3 × EMPCLASS 11 | 152,628 | 1,539/1,539 groups exact, maxdiff 0 |
| `SP_1ODZAS_PROVSIC2june1998` | PROV/CAN 13 × SIC-2 77 × EMPCLASS 11 | 8,809 | 142/142 groups exact, maxdiff 0; **cross-file** (below) |

`PROVSIC4dec1997`'s five identities, all with zero residual:

| identity | comparisons | exact | maxdiff |
|---|---|---|---|
| industry `Total` == Σ detail (per geo × empclass) | 142 groups | 142 | 0 |
| `Canada` == Σ provinces (per industry × empclass) | 8,369 | 8,369 (100.000 %) | 0, zero one-sided cells |
| `Total` == `0` + `Total (excl. 0)` | 9,209 | 9,209 | 0 |
| `Total (excl. 0)` == Σ size classes | 9,075 | 9,075 | 0 |
| `Total` == `0` + Σ size classes | 9,209 | 9,209 | 0 |

The metadata corroborates the arithmetic independently: EMPCLASS reads `Total`,
`0`, `Total (excl. 0)`, …, `200-499`, `500 +` — exactly the structure the sums
imply — and PROV/CAN ends in `Canada`.

**The strongest check in the cluster is cross-file.** `PROVSIC4-2` and
`PROVSIC2june1998` come from different Borealis deposits, carry different
classifications (1,255 SIC-4 vs 77 SIC-2 members) and decode by different candidate
placements, yet report the identical grand total 7,945,034. Rolling the SIC-4 file
up by 2-digit SIC prefix reproduces the SIC-2 file **cell-for-cell: 8,667/8,667
exact, maxdiff 0, zero one-sided cells**. (`PROVSIC3-1` carries a different grand
total, 7,290,572, so it is a different reference period and is not expected to roll
up to either; it was already supported and its cell count is unchanged.)

**Industry labels stay PROVISIONAL** (`canivt_suba_labels`, loud). Reconciliation
validates sums, not the code → member assignment — a uniform relabel leaves every
sum unchanged. Manual evidence gathered here goes beyond what reconciliation can
do: in SIC only leaf codes carry establishments, and at shift 0 **855/855**
populated members are leaves, where shifts −2/−1/+1/+2 scatter 272–318 members onto
aggregate codes. (Two members first flagged as aggregate-coded turned out to be
genuine leaves whose codes end in 0 — `4010 Residential Building and Development`,
`010 - Other Agricultural Industries, N.E.C.`) This is validation evidence only;
the parser does not run it, so the loud provisional flag stays.

`ivt_f2_suba_dir_stride()` is unit-tested on synthetic directories
(`test-suba.R`) covering the blank-led run, the resumes-past-extent rejection,
empty-geography tolerance, ragged residues, the blank-page stubs and the
single-outer-member decline.

## [x] Blank pages and SPARSE industry slots — the last guard closed (2026-07-26)

`SP_FPBMMO_PRVNAIC1dec1998` (Business Register, provincial NAICS-1, December 1998)
was the corpus's last `supported = FALSE` row. **Onboarded at 2,814 cells**; the
refusal ledger is now empty, with no gate relaxed to get there. Two independent
facts had kept it out.

**1. A written page with no present bits is not a witness.** Three of the thirteen
provinces (5, 6 and 12) write an *extra* directory entry at window slot 8 whose
page is a stub: size 260 = the 4-byte marker + the 256-byte presence record + no
values, presence popcount **0**. Counted, it gives those three groups the residue
set `{0, 8, 10}` against the other ten's `{0, 10}` — ragged, so no stride confirms
and the file is refused. But a page with zero present bits carries no cells, so it
cannot say anything about where the members sit: it is the same absence as an
unwritten entry slot, one level down (the sparse-directory model). `ivt_f2_page_blank()`
counts such entries out of the measurement, and the tiling is then the plain
`{0, 10}` at stride 16 that every province shares. Blast radius across the cluster
is two other blank windows (`PROVSIC2june1998` and `CACMA3-2`, both at slot 13);
dropping them moves neither verdict nor one cell.

**2. The members do not form a contiguous run at all.** Every placement the
chunked case enumerates is an `(offset, length)` pair plus a total. This file's 20
NAICS sectors sit at slots 1..20 and then `Total` and `00 - Not Classified` sit
alone in window 10, at slots **1363 and 1364** — a 1,342-slot gap. Nor can its
members be *counted* by the code scan: three of the twenty sectors are coded as
NAICS **ranges** (`31-33`, `44-45`, `48-49`), which are not numeric tokens, so
`ivt_f2_suba_industry_codes()` reports 19 of 22 (and picks up a stray 6-digit leaf).

The file states the answer twice instead, and the new **sparse-slot** case takes it
only when both witnesses agree:

| witness | reading |
|---|---|
| codebook bilingual member arrays (`ivt_f2_suba_member_arrays()`) | `[20 EN][20 FR]` + `[3 EN][2 FR]` → pairs agree on **22** |
| occupied slots under the measured stride | `{1..20, 1363, 1364}` → **22** |

The English-only third record of the second chunk (an orphan 6-digit NAICS leaf the
writer left behind) is discarded by the pairing rule — a bilingual codebook is
trusted only as far as its two copies agree. With the counts equal the members
simply *are* the occupied slots in ascending order; there is no offset and no
alignment left to guess. Language assignment is structural
(`ivt_f2_dim_dict_en_first()` reads the dictionary's field order), so the file
yields EN **and** FR member labels.

The gate is correspondingly stricter than the chunked one: **exactly one** slot
must equal the sum of all the others over every geography × employment-size group,
and its codebook label must be the one the codebook calls the total. That second
clause is the only LABEL check anywhere in `suba.R` — a shifted assignment would
put a sector's name on the reconciling slot — so it is required, not preferred.
Here slot 1363 is the unique solution and its label is `Total`.

All four of the file's aggregate identities are exact over every cell:

| identity | comparisons | exact | maxdiff |
|---|---|---|---|
| sector `Total` == Σ other 21 (per prov × empclass) | 143 groups | 143 | 0 |
| `Canada` == Σ 12 provinces (per sector × empclass) | 235 groups | 235 | 0 |
| `Total (A)` == `Indeterminate (B)` + `Subtotal (A − B)` | 286 | 286 | 0 |
| `Subtotal (A − B)` == Σ 8 size classes | 286 | 286 | 0 |

**Cross-file corroboration** against `SP_XWJR2W_PRSIC1dec1999`, which shares the
universe but decodes by an entirely different path (it never engages `suba.R`):
one year apart, every province moves by a plausible growth rate and Canada goes
1,795,130 → 1,996,322 establishments. The 1999 file carries a fourteenth
geography, **Nunavut** — created April 1999, so absent from the 1998 file exactly
as it should be — and NWT splits accordingly (3,065 → 2,558 + 652).

| province | Dec 1998 (NAICS) | Dec 1999 (SIC) |
|---|--:|--:|
| Newfoundland | 23,280 | 24,976 |
| Prince Edward Island | 9,389 | 10,104 |
| Québec | 428,773 | 470,373 |
| Ontario | 607,573 | 684,913 |
| British Columbia | 261,488 | 288,478 |
| Yukon | 2,566 | 2,762 |
| **Canada** | **1,795,130** | **1,996,322** |

Labels stay PROVISIONAL for the same reason as the rest of the cluster
(`canivt_suba_labels`, loud): the total member's label is verified by the gate, the
other 21 are the standard storage-order assignment.

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
