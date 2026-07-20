# IVT format coverage — what we decode and what's left

A living assessment of how completely `canivt` understands the Beyond 20/20 `.ivt`
format. **Update this when a gap is closed or a new one is found.** Status keys:
`[x]` decoded & exposed · `[~]` read but not surfaced (recoverable) · `[?]` read
but semantics unproven · `[ ]` not parsed / unknown.

Byte-coverage figures below are measured on the family-2 reference table
**98-10-0023** (142,016,485 bytes); cross-checked against family-1 (98-10-0241)
and the legacy 1991 table (1003011).

## Byte coverage (every region is identified)

| region | bytes | share | status |
|---|--:|--:|---|
| header (identity + descriptor) | ~3.2 KB | 0.002 % | partial — see below |
| header zero-padding | ~33 KB | 0.023 % | reserved, no information |
| page directory | 127 KB | 0.089 % | fully used |
| dir → pages gap | ~4 KB | 0.003 % | padding |
| value pages (data) | 124 MB | 87.6 % | decoded cell-exact |
| codebook + footnotes + dimension blocks | 17.4 MB | 12.3 % | see below |

No unexplained "mystery blocks": 100 % of the file is accounted for by region.
Within the value pages, **96.7 %** is marker + presence + values (all decoded
exactly) and **3.3 %** is `0xFF` trailers + zero-padding (no information).

## [x] Fully decoded and exposed

- [x] All cell values (validated cell-for-cell vs the StatCan CSV — family 1:
  7,489,464 cells; family 2: 14.5 M; 1991: all scraped ground-truth geographies).
- [x] Geography: all 11 attributes — name, DGUID/GEOUID, level, type +
  abbreviation, province abbreviation, two geocodes, data-quality flag + note,
  non-response rate. (Covers every StatCan geo attribute key 3,4,5,9,10,12-17.)
- [x] **Geography attributes on the DEFAULT metadata path** (2026-07-05):
  `ivt_metadata()$geographies` now packs every decoded per-member column, not
  just name+uid. Small schema'd tables (≤256 geos, e.g. 98-10-0241/0077/0662)
  return the full positional attribute table (bilingual labels/names, DGUID,
  `geo_level`, `geo_type(_abbr)`, `prov_abbr`, `alt_geo_code`, `pr_code`,
  `dqf_code`/`dqf_note`, `tnr_short_form`); the pre-DGUID inline vintages
  return what their combined record stores — the previously **discarded**
  captures `geo_type_abbr` (the municipal / CSD-status token: 2006/2016 `T`,
  `MÉ`, `IRI`, …; the 1981/1996 `SUN`/`COM` styles; the cro/ord `", CSD"` name
  suffix) and `tnr_short_form` (the 2016+ trailing `( 4.0%)` percentage,
  normalised to the modern decimal-point form), alongside `dqf_code`. The
  stored combined display string is kept verbatim as `geo_label` (the viewer
  join key) and its EN/FR halves are split into `geo_name`/`geo_name_fr`
  (`ivt_f2_split_bilingual()`: `" | "` — 1991's dedicated language separator —
  always splits; `" / "` splits only with **positive French evidence** in the
  French half, so dual English names like `Kootenay Boundary E / West
  Boundary` and language-neutral pairs like `Greater Sudbury / Grand Sudbury`
  stay combined). All-NA columns are dropped (only what the vintage stores is
  exposed); large chunked tables stay uid-only by default (the full table via
  `read_ivt(geo_attributes = TRUE)` as before). `ivt_write_metadata()` writes
  every decoded column to geographies.csv plus the DQF legend
  (`dqf_legend.csv`). Corpus-validated: geo_uid order byte-identical on all 26
  supported tables, old `geo_name` recoverable as the new `geo_label`.
- [x] Dimension member labels (Age/Gender/Sex), counts, type markers.
- [x] Footnote text (modern framed `Footnote N`/`Renvoi N`; legacy `(N) text`;
  the numberless all-caps `FOOTNOTE:`/`RENVOI :` framing, 1981–2016 — its
  addition surfaced real notes the numbered scan had missed on the
  1996/2006/2011/2016 tables). Identity falls back to the master-directory
  blobs (`ivt_f2_master_identity()`) when the inline text and the `@40`/`@48`
  title blocks are both absent — this filled the previously-NA product
  id/titles on the 1996 and 2016 `98-400-X` tables too.
- [x] Header layout pointers (`ivt_f2_header_layout()`); format/version indicator.

## [~] Read but not surfaced (recoverable, just not exposed)

The codebook scan finds 5,942 member-array blocks; we extract the English/first
copy of each attribute and parse past the rest.

- [x] **French member labels + French dimension names — now DECODED and SURFACED**
  (2026-07-03). Each dimension's slot directory carries a dictionary/schema block
  naming its fields `Code · English Desc · Desc Français` (`Desc fran` in 1991), and
  the two member-label blocks are laid down in that **schema order** — so English
  vs French is decided by a **structural marker** (`ivt_f2_dim_dict_en_first()`),
  not by content-scoring (`ivt_f2_frscore()` is only the fallback when the schema
  block is absent, and it fires a loud warning). `ivt_f2_dim_dir_label1()` returns
  `list(en, fr, name_fr)`; each dimension of `ivt_metadata()` gains `members_fr`
  and `name_fr`, and `dimension_names_fr` is exposed on the metadata list. The
  **French dimension name** comes from the French `Total - <name>` first member
  (the header Variable List is English-only) — full and accented (e.g. `Mode
  d'occupation incluant la présence de paiements hypothécaires…`); NA for the
  Statistics-type dimension whose first member is not a `Total - …` label.
  `ivt_write_metadata()` writes `dimension_fr`/`label_fr` (dimension_members.csv)
  and `name_fr`/`label_fr` (geographies.csv); `ivt_members()` / the
  `_members.parquet` sidecar carries `level_fr`. Validated on 98-10-0241 (6 dims),
  -0023/-0129 (incl. the Gender/Sex dimensions frscore cannot separate), and the
  1991 legacy 1003011. Geography names/labels were already bilingual
  (`geo_*_fr`); footnotes (`Footnote`/`Renvoi`), the DQF legend and the title were
  already EN+FR.
- [x] **Member-ordinal arrays** (`1..n`) — now PARSED and SURFACED (2026-07-02),
  no longer just anchors: `ivt_f2_dim_dir_ordinals()` (dimdir.R) reads each data
  dimension's ordinal block positionally from its slot directory (a candidate
  must be a permutation of `1..count`, which rejects numeric label blocks like
  the reference-period years; dimensions without an ordinal block — e.g. the
  2-member Year — are ordered by member id). Exposed as `ordinal` on each
  dimension of `ivt_metadata()`, in `ivt_members()` (the per-column level table,
  written as a `_members.parquet` sidecar by `ivt_write_parquet()`), and consumed
  by `collect_ivt()`, which converts dimension columns of collected tidy/Parquet
  data into factors whose levels are the FULL member list in ordinal order — so
  filtered-out members stay visible as levels. On every validated table the
  stored ordinals are the identity (member order), verified on 98-10-0241 and
  the 1991 legacy 1003011 (Age 1..110, Sex 1..3). The geography chunks' running
  ordinal delimiters (1..256, 2049.., …) remain anchors only.
- [~] Block-framing **`<u16>` length prefixes** — we scan instead of using them.
- [~] The **doubled directory size field** (second copy ignored).

## [?] Read structurally but semantics unproven

- [?] Fixed header fields `@4,@8,@12,@16,@20` (constants `32`, `64/8`, `544`,
  `32/14`, `4096`) — `@20` is the family-1 `0x1000` stride; the rest unexplained.
- [?] Descriptor sub-header bytes (`f0 20 00 80`, `8f c8 0f f8`, per-dimension
  display masks `f3 ff f0 ff` / `c0 ff c0 ff`).
- [?] Dimension **type markers** `0x10`/`0x07`/`0x02` (geography / age-type /
  gender-type — inferred, not proven).
- [x] Page-marker bytes `b2` and `b3` are now both DECODED as size fields:
  `b2` encodes the pad/`0xFF` trailer (`2·(b2>>4) + 2·(lo>0)`, 0 when `b2==0`)
  and `b3` the auxiliary head block (`32·(b3−8)`, `b3 ∈ {08,09,0a,0c}`); the
  value run starts at `4 + presence_len + trailer + head`
  (`ivt_value_trailer()`). What the trailer/head bytes *contain* remains
  unproven (the 2006 heads carry per-geo sentinel/value words), but the
  arithmetic is corpus-verified — no longer a decode gap.

## [x] Decoder generality — arbitrary-dimension family-2 (DONE)

The family-2 cell decoder is now **n-dimensional**, driven entirely by the header
descriptor, and validated cell-exact on the 4-dimension table **98-10-0129**
(Geography × Gender × Marital status × Age): the full 15,685,859 non-zero cells
decode in ~3 s, with **120/120** sampled geographies and **all 28 `0xa4`-marker
geographies** an exact match vs the StatCan CSV; the 3-dim tables (98-10-0023,
1003011) still decode exact (regression-green).

- [x] **Geographies per page is computed** = geography member count / page count
  (4 for the 3-dim tables, **2** for 98-10-0129). `ivt_f2_geos_per_page()`.
- [x] **Presence is a power-of-two-nested positional bitmap** over the data
  dimensions (descriptor order, outermost first; each level padded to the next
  power of two of count × inner-block; innermost in the low bits). Byte-pair-
  swapped, read **MSB-first**. The old "128 Age nibbles × 3 Gender bits" is the
  special case (Gender→4 bits, Age→512 → 64-byte record). 98-10-0129 →
  strides 256/16/1, 128-byte record. `ivt_f2_bit_layout()` / `ivt_f2_cell_grid()`.
- [x] **Marker `0xa4`** (int32) added: trailer **18** → values inline at off+278.
  (It is *not* a "separator" layout — the value run is contiguous; the trailing
  `0xAAAAAAAA` slots are pad after the run.)
- [x] **Value-run start generalised** to `4 + presence_len + trailer[marker]`
  (`presence_len = rec_bytes × geos_per_page`), reproducing the validated absolute
  starts and adapting to any record size. `IVT_F2_PAGE_TRAILER`.
- [x] **Geography count** comes from the descriptor's geography record
  (`ivt_f2_geo_count()`); the fixed-offset `ivt_f2_header_geo_count()` u16 reads a
  wrong 16320 for 4-dim descriptors and is no longer used for sizing.
- [x] **Geography is identified positionally** (the first descriptor dimension),
  not by a magic type byte: the geography type differs by format — `0x10` in the
  modern family-2 files (count u16) but `0x08` in the family-1 reference tables
  (count u8). The old `type == 0x10` filter silently misread 98-10-0241's geography
  count as 16383.
- [x] **… except on the profile lineage, where geography is the LAST descriptor
  dimension** (97-570-X1981004: `Values(1) × Profile(79) × Geography(5989)`).
  `ivt_f2_geo_dim_index()` (dimdir.R) keeps dimension 1 as the fast-path
  default and probes the dimension slot directories for a geography codebook
  signature (GEO_NAME schema field / inline combined-format member blocks)
  only when dimension 1 has a single member — a real geography can never be a
  1-member dimension alongside others. Three companion descriptor fixes
  (2026-07-04): the **u16 count width tags now include types `0x0a`/`0x0c`**
  (98F0172X's Profile(529)/Geography(4063); the u8 read of `0x0a` is what
  broke 98-400-X2016203 — 825 read as 57) **and `0x09`** (the >256-member
  detailed-classification data dimensions: 97F0020X's Selected(282) and
  98-10-0174's Mother tongue(331), both chunked >256-member codebooks; the u8
  read got 1, which mis-nested the layout — this rejected 97F0020X on the
  capacity rule and *silently mis-decoded* 98-10-0174's cells; u16 is safe for
  a small member of any of these types because count_hi is then 00), and
  **double-01-framed record counts are reconciled against the dimension's
  slot-directory member block** (`ivt_f2_dim_count_reconcile()`: the profile
  "Values" placeholder shares the facet record's byte shape but stores no
  count there — 1 member, not 32). All previously supported tables
  byte-identical through these changes.

## [x] Descriptor markers generalised across family-1 tables (DONE)

A **second family-1 table, 98-10-0077** ("Economic family income by family
structure"), confirmed the descriptor model and forced two generalisations. It has
7 dimensions (174 geographies + 6 data dims) and, because it spans the **2021 and
2016 censuses**, carries a **reference-period dimension "Year (2)"** (type `0x0e`,
count 2).

- [x] **Dimension records are anchored on the doubled name**, not on a rigid
  `<known type> 01 <upper>` scan. Each record stores its display name twice
  back-to-back preceded by `0x01`; the count/type framing bytes before that
  separator vary by dimension. `ivt_f2_descriptor()` now walks the bounded region,
  detects each `0x01` whose following printable run is a doubled string, and reads
  count/type relative to it. This dropped the hard-coded `IVT_F2_DESC_TYPES` type
  list entirely.
- [x] **Reference-period / facet records** use a different framing —
  `[type][count][01][01]<name><name>` (type-first, **doubled** `0x01`) vs the
  normal `[count][type][01]<name><name>`. The old scan landed on the second `0x01`
  and so **dropped the 7th dimension** of 98-10-0077. New type bytes seen:
  `0x0e` (reference period), `0x05` (generic ordinal, e.g. age-range / income).
- [x] **The reference-period dimension is the innermost *in-page* dimension, NOT a
  geography facet** (this revises an earlier guess). In 98-10-0077 *Year (2)* sits
  at the bottom of the presence-bitmap nesting: the dense value run carries the
  2020 then 2015 value for each cell consecutively. The descriptor count
  `ivt_f2_geo_count()` = **174** is the true geography count the decoder keys on.
  The legacy `ivt_geography_count()` (stride at `0x1000`) returned **348** here only
  as an artefact — 98-10-0077's real per-geography directory stride is `0x2000`,
  and striding it at `0x1000` lands on every other geography's mid-block, doubling
  the count. It has been removed (2026-07-10): nothing decodes or detects through
  it — `ivt_layout()` computes directory strides per table.

## [x] One unified cell decoder — "family 1 / family 2" are one pattern (DONE)

`decode.R` (`ivt_layout()` + `ivt_decode()`) is the single, name/type-agnostic
decoder for every table; `decode-f1.R` and the family-2 `ivt_f2_decode()` are gone.
The realisation: **both former families are the same power-of-two-nested positional
layout** (`ivt_f2_bit_layout()`); they differ only in *which dimension straddles*
the page boundary. Nest every dimension — data dimensions innermost (descriptor
order), **geography outermost** — fill a fixed **2048-bit (256-byte)** page
presence record innermost-first; the same nesting describes the in-page bits (bit
units) and the directory entries (8-byte entry units).

- [x] Exactly one dimension **straddles** the 2048-bit boundary: its in-page part
  (`ipc = floor(2048 / inner_block)`) stays in the bitmap, the rest becomes
  `window_count = ceil(count / ipc)` directory windows; dimensions outside it are
  positional in the directory (power-of-two-nested entry strides, window innermost).
- [x] **A data dimension straddles → geography is fully paged** (per-geography
  directory blocks): **98-10-0241** (Period; geo stride 512 entries = `0x1000`),
  **98-10-0077** (Ages; geo stride 1024 = `0x2000`), **98-10-0662** (Health; geo
  stride 16 = `0x80`, small file with mixed int16/int32 pages). All cell-exact vs
  the StatCan CSV; 0241 byte-identical to the original hand-cracked decoder.
- [x] **Geography itself straddles → `gpp = 2048 / data_bits` geographies per page**,
  flat contiguous directory: **98-10-0023** (4 geos/page, 63,404 geos), **98-10-0129**
  (2/page, 15.6M cells), **1991 `1003011`** (4/page). The unified decoder reproduces
  the former family-2 decoder byte-identical. `ivt_layout()$geo_in_page` discriminates.
- [x] **Fully name/type-agnostic.** Column slugs are a generic function of the
  metadata name (`ivt_dim_slug()`); no code branches on a dimension's name or
  descriptor type byte. Removing the old `0x02→gender` / `0x07→age` slug special-
  casing changed only 1991's data-column names (now `single`/`sex`, the real
  metadata names) — every other table was unaffected, confirming the wart.
- [x] **Value-start (trailer)** is marker-driven: trailer 0 when the marker's third
  byte is `0x00`, else the per-marker family-2 constant (`0x82`→16, `0x84`→8,
  `0xa2`→34, `0xa4`→18, …). Some tables realise the high-A trailers as a `0xFF` run,
  others as fixed padding — all land identically.
- [x] **Family-1 metadata is now descriptor-driven (no name-tied code).** The
  hard-coded `IVT_DIMS` / `ivt_read_codebook()` are gone; `read_ivt()` /
  `ivt_metadata()` run the single `ivt_f2_metadata()` for every family. Dimension
  member labels come from `ivt_f2_dim_member_labels(raw, want)` (codebook
  doubled-name markers; ordinal-anchored + adjacent-FR/EN-pair heuristics as
  fallback), full dimension names from the header Variable List matched **by count**
  (`ivt_f2_vl_pairs()`), and geography names+DGUIDs from the cheap single-block
  codebook (`ivt_f2_geo_simple()`). `geographies` is uniformly `geo_name`/`geo_uid`/
  `member_id` and `ivt_tidy()` emits `geo_name`/`geo_uid` for all families.
  98-10-0241 is exact (names, DGUIDs, all 6 data-dim labels, footnotes).
- [x] **Member labels are anchored by the codebook doubled-name marker.** Each
  dimension's codebook entry carries a `81 02 02 00` header marker bearing the
  dimension's display name (same as the header descriptor) right after its English
  member block; `ivt_f2_codebook_dim_markers()` + `ivt_f2_marker_labels()` match the
  marker name to a descriptor dimension and take that block's trailing `count`
  records. This is metadata-derived (name, not block-adjacency guessing) and closes
  three gaps: **98-10-0077 `Ages`(18)** (English block has 2 leading framing records
  → take the tail), **98-10-0077 `Year`(2)** (a 2-member reference period with no
  trailing ordinal block, values `2020`/`2015`), and **98-10-0662's two 6-member
  language dimensions** (`French used at work` / `English used at work` — same count,
  so the count-keyed store collapsed them; `ivt_f2_dimensions()` now resolves them
  per dimension by NAME). All six tables label every data dimension; byte-identical
  to the old output on every dimension that previously labelled. **Now the
  fallback**: the primary label read is positional from each dimension's slot
  directory (`ivt_f2_dim_dir_labels()`, see the header section-pointer table
  below); the marker scan runs only for dimensions the directories miss.
- [x] **Geography parsed from the file's own attribute schema (content-free).**
  Geography is dimension 1 with the same `81 02 02 00` doubled-name marker as every
  data dim; the file also stores a **geography attribute schema** — the named field
  list `GEO_NAME · GEO_TYPE_DESC · GEO_TYPE_ABBR · GEO_LEVEL_DES · PROV_ABBR · DGUID
  · ALT_GEO_CODE · PR_CODE · DQF_CODE · DQF_NOTE · TNR_…` (each `_EN`/`_FR`), the
  geography analogue of the data dims' Variable List (`ivt_f2_geo_schema()`).
  **Stage 1 (single-block DGUID tables, 0241/0077): done.**
  `ivt_f2_geo_simple_schema()` locates geography by its marker and reads attribute
  arrays **by schema slot/name** — DGUID and GEO_NAME are no longer found by sniffing
  a `"2021…"` prefix or a `"Canada"` first entry. DGUIDs are byte-identical to the
  legacy `"2021"` scan; `GEO_NAME` is now the canonical short name (e.g. `Corner
  Brook`). (The former content-based array detector `ivt_geo_arrays()`, with its
  `"^2021"`/`"Canada"` literals, was retired 2026-07-11 — a full-corpus branch trace
  showed no table ever reached it in `ivt_f2_geo_light()`; inline / `attrs_dir` /
  uid-only cover every file, so `ivt_f2_geo_simple()` is now schema-only.)
  **Stage 2 (schema-absent tables, 1991 / 2006 / 2011 / 2016): done.** There are two
  storage strategies, not one: the 2021 census tables store geography as **separate
  schema-named arrays** (above), while every **schema-absent** table (older *and*, it
  turns out, the 2016 `98-400-X` tables — DGUIDs are 2021-specific, not "2016+") stores
  it as the inline combined block `"<name> (<code>) [<type_abbr>] <dqf> [(<pct>%)]"`.
  `ivt_f2_geo_inline()` anchors on the geography dimension's own `81 02 02 00` marker
  (`ivt_f2_geo_marker_region()`) and parses **only** the blocks in that marker region —
  geography is *located from the metadata*, and each entry's name/uid/flag come from the
  combined block's **structural format**, not from sniffing `"Canada"`/`"2021"`. The uid
  is read as **character**: a bare geographic code (2016 `01`/2006 `1001105`), a dotted
  census-tract code (2011 `0010001.00`), never a DGUID here. The type abbreviation admits
  accents (Quebec `MÉ`), and a trailing `(pct%)` non-response rate (the 2016
  single-census tables) is tolerated. **All four vintages now read positionally from
  the block directory** (`ivt_f2_geo_inline_dir()` — see the section-pointer table
  below): the byte-order scan + first-appearance dedup had silently **misordered**
  members wherever chunks are stored out of byte order — **2,435 of 41,859 on 1991,
  18,432 of 57,523 on 2006, 1,351 of 5,447 on 2011** — each validated exact against
  the Beyond 20/20 viewer's geography member list (option order of the `d0` select).
  The per-group run roster varies by vintage and is detected by content: 1991/2011
  carry 4 runs `[combined ×2, name array, code array]`, 2006 carries 3 (no code
  array; the uid is the combined block's parsed code), the 2016 98-400-X an extra
  leading run; 2006 also stores the last group's **partial chunk first** within each
  run (accepted as a rotation and placed back at its member position). **2016
  (98-400-X2016387)** 174 members (single-block; its uid was previously empty — no
  DGUID array, and the content detector could not recover the bare-code uid).
  The geography count is read from the descriptor with the per-type width tag
  (`0x10`/`0x0d` → u16; 2011's `0x0d` was misread as u8 = 21 before).
  `ivt_f2_geo_light()` resolves every family through one metadata-anchored entry:
  **combined-block reader** (schema-absent; directory-positional first) →
  **directory-driven positional attribute read** (single-chunk schema'd tables,
  `ivt_f2_geo_attrs_dir(trim = FALSE)`, byte-identical to the single-block readers,
  which remain the fallback) → **DGUID scan** (2021 chunked). The marker region that
  bounds the scans is itself now **bounded by the geography directory's byte span**
  (`ivt_f2_geo_dir_span()`) when the slot table resolves, with the codebook-pointer
  marker walk as fallback. 1991's default tidy now labels geography by name + GEOUID
  (was member-id only).
  **Stage 3 (the last split): done.** The **2021 chunked DGUID** tables (98-10-0023
  / 0129) are now folded under the marker+schema view too, **byte-identical on all
  63,404 DGUIDs and every attribute** for both files. Nothing on the chunked read is
  year-locked or hard-coded: (a) attribute slots are read from the file's schema
  field list (`ivt_f2_geo_slot_map()` → `ivt_f2_geo_schema()`, now anchored on the
  header codebook pointer so it survives the ~18 MB codebook tail), reproducing the
  fixed `IVT_F2_ATTR_SLOTS` order exactly — that table is kept only as the no-schema
  fallback; (b) the 256-member groups are segmented **structurally** by contiguous
  runs of `ivt_f2_is_dguid_block()` blocks (2G per group, EN then FR) with
  **deterministic** member ids from the running 256-chunk total
  (`ivt_f2_geo_groups_chunked()`) — no pre-scanned DGUID array, no `"2021…"` content
  anchor; (c) the DGUID column falls out of its own schema slot, and
  `ivt_f2_extract_attr()` anchors each group start on `d0 − dguid_slot·2G` (also
  schema-derived); and (d) the fast uid-only scan `ivt_f2_geo_dguids()` hits on the
  DGUID **shape** `<YYYY><level letter>` inside the geography marker region rather
  than the literal `"2021"`, so it is vintage-agnostic. The shared shape
  `IVT_F2_DGUID_RE` admits a **dot** so census-tract DGUIDs (`2021S05079320001.00`)
  are recognised (bare numeric codes still are not). Validated beyond 0023/0129 on
  **98-10-0174** (dissemination areas, a **family-1** table with the same chunked
  63,404-geo codebook — the reader is family-agnostic) and **98-10-0478** (census
  tracts, 6,297 geos, geography type `0x0d`, chunk groups `1,1,2,4,8,9`; all
  DGUIDs/levels/types/codes exact).
- [x] **Bilingual geography member names (display label + GEO_NAME) — DONE.**
  `ivt_f2_geo_attributes()` now emits `geo_label`/`geo_label_fr` (the human-readable
  display **Member Name**, e.g. `0001.00 - Abbotsford - Mission`) and
  `geo_name`/`geo_name_fr` (the schema **GEO_NAME** — a bare code like `9320001.00`
  for census tracts / unnamed dissemination areas). Both are read structurally from
  the codebook, **not inferred from content**: the two NAME attributes sit at the
  front of each group and are anchored on `GEO_TYPE_DESC`'s block (`d0 −
  (dguid_slot−1)·2G`, reliable because every attribute from type through DGUID keeps
  its trailing partial), walking backward through the two GEO_NAME runs (drop-aware:
  a code run's lost trailing partial is detected by its last block being a full 256
  instead of the partial size) then the two display runs (`ivt_f2_geo_name_runs()`).
  Language is decided **per group** by `ivt_f2_frscore()` (accents + French
  connective tokens − English tokens over the members where the two runs differ),
  because the physical EN/FR order is EN-first in most groups but **FR-first in the
  root group** (0023's group 1 stores `Terre-Neuve-et-Labrador` before
  `Newfoundland and Labrador`). Validated: `geo_label` matches the StatCan "Member
  Name" column **63,404/63,404** on 98-10-0023 and **6,297/6,297** on 98-10-0478,
  and cross-checks 63,404/63,404 between 0023 and 0174 (same DA universe).
  `ivt_tidy()` / the `geographies` table now front `geo_label` before `geo_name`.
  Known nicety on 0478: the last group's GEO_NAME (code) loses its trailing 153-member
  partial to the block scanner (special bytes after the short block) → those 153
  `geo_name` codes are NA; `geo_label` (text, keeps its partial) and every other
  attribute are complete. Same root as 0023's 2 special-char NA names.
- [x] **Trailing-partial chunk drop + off-window schema (98-10-0013 ADA) — FIXED.**
  Two hard-coded heuristics failed this aggregate-dissemination-area table:
  (a) `ivt_f2_codebook_blocks`'s blunt `length >= 150` floor dropped the last chunk
  group's **71-member trailing partial**, undercounting geography 5,376 / 5,447. The
  floor is now structural: a small clean member-array block is kept **only when it
  immediately follows a full member block** (a trailing partial trails its own full
  chunks), so genuine partials survive while the garbage byte-runs the floor targets
  — which cluster on their own — are still dropped. All 5,447 DGUIDs now decode, and
  0023/0478 DGUIDs stay byte-identical. (b) `ivt_f2_geo_schema` reported the schema
  "absent" — it wasn't: the attribute dictionary sits ~14 KB *before* the codebook
  pointer, outside the old `[cb-8000, EOF]` half-window. Geography's dictionary block
  is now located by **following the file's own metadata directory** — a header slot
  (`@824` on the small chunked tables, indexing the geography codebook blocks; also
  `@572`/`@712`) holds a table of `[u32 off][u16 len][u16 len]` entries, the same
  entry shape as the page directory. `ivt_f2_geo_dict_block()` decodes it
  (`ivt_f2_read_dir_at()`) and confirms the block by its `GEO_NAME_EN` field name,
  so the dictionary start comes **from the file, not a scan**, on **every** table:
  `ivt_f2_geo_block_dir()` tries two indirection depths per slot — the slot value is
  the directory itself on the small chunked tables (0013/0478/0241), but a small
  geography-dimension struct whose first u32 is the directory pointer on the big
  tail-codebook tables (`@824 → struct → ptr1 → directory`; 6,244 entries on 0023,
  6,758 on 0174). Validated byte-identical to the window result. The `cb ± 128 KB`
  centred window survives only as a last-ditch fallback for a directory-less layout.
- [x] **Reverse-stored root chunk, read positionally from the block directory
  (98-10-0013 ADA root group) — FIXED.** The codebook's first ("root") chunk is stored
  in **reverse byte order** (region A of the tail: the block directory's offsets
  *decrease* through the root chunk, then jump up for the bulk). The byte-ascending
  block scan reverses that chunk's logical order, and because ADA's root chunk also
  carries extra framing blocks the stride walk lands on the wrong blocks — leaving
  `geo_label`/`geo_name`/`geo_type`/`geo_level`/`geo_type_abbr` **NA** for members
  1–256 *and* **scrambling** `prov_abbr`/`alt_geo_code`/`pr_code` (they read codes /
  French type text). ADA read 5,191/5,447. Fix: read the root chunk **positionally from
  the header block directory** — the `@824` slot is a table of `[u32 off][u16 len][u16
  len]` entries (block **offsets and lengths**, the same entry shape as the page
  directory), and within a group the value blocks are laid down in a fixed sequence: the
  display Member Name pair, then every schema field in **schema order**, each EN then FR.
  `ivt_f2_geo_root_dir()` reads the value blocks (record count == chunk size `rootN`) in
  directory order, pairs them, and maps pair 1 → display name, pair k+1 →
  `ivt_f2_geo_schema()[k]` (language per pair by `ivt_f2_frscore()`); no marker, no
  content sniffing, no `d0 ± k·2G` stride. `ivt_f2_geo_attributes()` overrides members
  1..rootN with it. Validated: ADA every root attribute exact (`geo_label` == "Member
  Name" **5,447/5,447**, `geo_type` Country/Province/ADA, `prov_abbr`/`pr_code`/
  `alt_geo_code` correct); the positional read matches the stride output **256/256 on
  every attribute** on CT (98-10-0478) **and on both big tables 0023/0174** (whose
  directory now resolves via the extra indirection), so the override is byte-identical
  there (unchanged **63,404/63,404**).
- [x] **Drive *all* groups from the directory's block order — DONE.** The whole
  chunked geography codebook is now read **positionally** from the file's own metadata
  block directory (`ivt_f2_geo_attrs_dir()`), with **no `d0 ± k·2G` strides**, no
  byte-ascending block scan (so the reverse-stored root chunk needs no special
  override), and **no content-location of TNR**. Value blocks appear in directory
  (logical) order as, per group of `G` chunks, `[display Member Name, then every schema
  field]` each stored as an EN run (chunks 0..G-1) then an FR run — exactly `2G` blocks
  per attribute, `2·(nfield+1)·G` per group. The reader collects the ordinal-filtered
  value blocks, gates on that regular block count (`ivt_f2_geo_attrs_dir()` returns NULL
  → fall back to the stride path when the directory drops a trailing partial), then
  consumes exactly `G` blocks per language-run and places each chunk at its member
  offset; language per attribute by `ivt_f2_frscore()`. Group chunk-sizes come from
  `ivt_f2_geo_group_sizes(n_geo)` (1,1,2,4,8,… last trimmed), not the DGUID-run
  segmenter.
  - **Validated byte-identical to the stride path on 98-10-0023** (all 63,404 members,
    every one of the 15 columns), and slightly faster (~20 s vs ~26 s).
  - **Fixes latent stride bugs on the tables that carry the extra `TNR_LONG_FORM`
    schema field** (which shifted the fixed slot offsets): on **98-10-0478** (census
    tracts, 12 schema fields) the directory read is **exact vs the StatCan metadata**
    for `pr_code`, `dqf_code` and `tnr_short_form` (0 mismatches each), where the stride
    path was silently wrong (1,278 / 327 / 1,897 mismatches); on **98-10-0129** the
    directory `tnr_short_form` is exact vs metadata where the stride root-override was
    wrong for 237 members. `geo_label`/`dguid`/`geo_level`/`geo_type`/`geo_type_abbr`/
    `prov_abbr`/`alt_geo_code` stay correct.
  - **98-10-0013 ADA now reads through the directory path too** (2026-07-18). Its
    directory did not "drop a trailing partial" — its tail carries 70 per-member
    footnote TEXT blocks ("Renvoi 1 / Ne comprend pas ...") that the block classifier
    counted as attribute value blocks, so the regular-layout gate tripped and forced
    the stride path (whose `ivt_f2_geo_root_dir()` root override then MISALIGNED
    `dqf_code`/`dqf_note` — the schema declares no DQF field, yet the stride walk
    populated them with bare ALT_GEO_CODE strings). `ivt_f2_dir_is_text_block()` now
    skips those footnote blocks, so `ivt_f2_geo_attrs_dir()` reads all 5,447 members
    schema-exact (the spurious DQF columns correctly drop out as all-NA). The
    stride/root-override fallback is retained (loud) but unreached by the corpus.
- [x] **The uid-only DEFAULT read is positional too (`ivt_f2_geo_dguids_dir()`) —
  DONE** (2026-07-05). The default metadata path for the chunked tables used the
  byte scan (`ivt_f2_geo_dguids()`), which reads blocks in BYTE order: on
  98-10-0013 the reverse-stored root chunk sits below the geography marker
  region, so the scan **silently dropped members 1–256** (5,191/5,447 with only
  a plain count-mismatch warning). The positional read walks the geography
  block directory with an O(1) per-entry probe — a plain `[01 01]` or dense
  `[81 01]` value-block header whose first non-empty record is DGUID-shaped
  (no other attribute stores DGUID-shaped strings) — then strict-parses only
  the 2·Σsizes DGUID blocks, consumed per group as two language runs of `G`
  chunks that must agree record-for-record (DGUIDs are language-invariant),
  each chunk exactly its expected size (a dense partial chunk — 0013 stores
  its 71-member last chunk bit-headed — is accepted only when no member is
  absent). Validated: 0013 all **5,447/5,447** (== the validated full
  attribute table's DGUID column); byte-identical to the scan on
  0023/0129/0174/0478 and **5–13× faster** (0.8 s vs 6.5–10.4 s on the 63k-geo
  tables). The scan survives as the loud fallback (`ivt_f2_geo_uids()`).
- [x] **Strict value-entry parse (the two block framings) — DECODED and wired**
  (`ivt_f2_dir_entry_members()`; see ivt-format.md "Value-entry block framings").
  Plain arrays are `[01 01][u16 payload][u16 n_slots]` + exactly `n_slots`
  NUL-terminated records, where `n_slots` is the chunk size **padded to a power of
  two with explicit empty records** (`00 00`) and an **absent member** is likewise
  an explicit empty record; dense arrays are `[81 01][u16 nbits][u16-padded
  bitstream][80|01]` + unterminated records that **skip** absent members (re-aligned
  from a plain sibling's NA pattern; the bitstream's per-member coding is still
  undecoded). The run-scanner now only *classifies* directory entries; the strict
  parse supplies the values. This closed four gaps at once:
  - **98-10-0662 geography attributes: all 11 attributes exact 91/91** vs the
    StatCan metadata CSV (was: unreadable — its aggregate member 26, "Canada
    outside Quebec and New Brunswick", carries **no attributes at all**, and the
    scanner's split at its empty record silently **shifted every uid after member
    25 by one** and dropped the count to 90 in the light metadata path).

- [x] **Synthetic aggregate geography members: `geo_name` now derived from
  `geo_label`** (2026-07-06). 98-10-0662's member 26 ("Canada outside Quebec and New
  Brunswick") is an *aggregate* geography constructed at tabulation time with **only
  a display `geo_label`** — the schema attribute arrays (GEO_NAME, DGUID, level,
  type, …) store nothing for it, so those columns decoded `NA`. `ivt_f2_geo_fill_label()`
  (codebook-f2.R, run once on the `ivt_f2_geo_light()` result so metadata **and**
  tidy both benefit) now backfills `geo_name`/`geo_name_fr` from `geo_label`/
  `geo_label_fr` for any member that carries a label but no GEO_NAME — the member's
  real name is exactly the label. It is a **loud** derivation
  (`canivt_fallback`; strict-mode error) because the value is derived, not read
  from its own slot. `geo_uid`/`geo_level` stay `NA` — an aggregate genuinely has
  no DGUID/level in the file. Generic (any table with synthetic aggregates, not a
  hard-coded member). The earlier `ivt_label_depth()`/`ivt_label_parent()` crash on
  an `NA` label was fixed separately (NA → depth 0, no parent).
- [x] **Inline geography names the positional regex missed are recovered by
  SUBTRACTION** (2026-07-06). `ivt_f2_parse_inline()` keys on the geographic code
  sitting at a **fixed** position (just before the quality flag), so it returned no
  name for two shapes: (a) the code **embedded mid-name** on some dual-official-name
  CSDs (ord-08035: `Kootenay Boundary D (5905052) / Rural Grand Forks, CSD 00000
  (5.9%)` → 2 members), and (b) **code-only** geographies whose whole combined string
  is the bare code (95F0200's 1996 enumeration areas — the display name *is* the
  code, exactly as the 43,008 named members already read; the last partial chunk of
  each attribute-run stores 226 such bare codes). `ivt_f2_inline_name_subtract()`
  recovers both by removing the tokens we already hold from the file's own dedicated
  arrays — the parenthesised code, the trailing flag, the `(pct%)` — leaving the
  display text (or the code itself when nothing else remains). Metadata-driven (the
  code comes from the code array), fills **only** NA names so every validated table
  is byte-identical, and **loud** (`canivt_fallback`). Corpus-wide result: **0 NA
  `geo_name` on every one of the 32 tables** (was 226 on 95F0200, 2 on ord-08035, 1
  on 0662). `strict_clean` flips to `FALSE` for 95F0200 and 0662 (they now emit the
  loud derivation).
  - **DQF_NOTE is now positional-exact**: 63,404/63,404 on 98-10-0023 (was ~99.8%
    via the majority vote), 91/91 on 0662. The `ivt_f2_derive_text()` vote now only
    fills slots whose block the strict parse could not decode. The only residual is
    the **container's own 252-byte record cap** (`0xFC` max length byte): notes
    longer than 252 chars are stored truncated in the file (2,448 members on
    98-10-0129, 90 on 0478) — byte-faithful, not a decode gap. **Verified at the
    byte level (2026-07-10)**: a truncated record is `[FC][252 text bytes][00]` cut
    mid-word, and the byte after the `00` opens the next member's record — no
    continuation exists, so nothing is missed. Now **flagged, not silent**: a
    companion `dqf_note_truncated` column rides beside `dqf_note` and a classed
    `canivt_dqf_note_truncated` (`canivt_source_truncation`) warning fires
    (`ivt_f2_flag_dqf_note_truncation()`). It is a faithful read, so strict mode
    keeps it a warning rather than an error. On the chunked tables the note + flag
    decode only via `read_ivt(geo_attributes = TRUE)`. **The truncation is the .ivt
    export's alone** — StatCan's authoritative WDS metadata carries the full text:
    98-10-0478 CT 0010.00 is 252 chars in the .ivt vs the WDS `getCubeMetadata`
    `geoAttribute.valueEn`'s complete 375 (the .ivt dropped a whole "Long-form
    income data suppressed…" clause). A consumer needing the full note can recover
    it from WDS / the CSV-download metadata; we don't fetch it (no-external-ground-
    truth rule).
  - **0478's 153-member code-partial residual is FIXED**: `geo_name` and
    `alt_geo_code` are now exact 6,297/6,297 (the strict parse does not fragment
    the code chunk the scanner broke).
  - A latent **root-group language-pick bug on 98-10-0129** (member 2's `geo_name`
    read the French copy) is fixed; `GEO_NAME` is exact 63,404/63,404 vs metadata.
- [x] The **2048-bit presence record is universal — geography always takes the
  straddle role.** When nothing overflows the record, `ipc = 2048/inner` simply
  exceeds the geography count and there is a single directory window: the
  "no-straddle" case is the trivial geography-straddle, validated cell-exact on
  98-10-0044 (448/448 vs the StatCan CSV). Sizing the record to the used bits
  (512 for 0044) instead misaligns the value run.

### Note: page geometry is now validated structurally, and gaps are LOUD

Per-page invariants, verified across every page of every supported table in the
corpus, are enforced by the decoder (2026-07-02):

- the **b2 trailer formula**: `b2 == 0x00` → no trailer, else
  `2*(b2 >> 4) + 2*(low nibble(b2) > 0)`. Derived from 98-10-0013 (22 pages,
  18 distinct b2 values, trailers 6–14, each anchored byte-exact vs the
  StatCan CSV); it reproduces the formerly hard-coded six-marker constants,
  which had made the trailer look like a per-width constant (`32/width` /
  `64/width + 2`) only because b2 never varied within a marker family before
  0013. Unknown width codes / high nibbles abort (`canivt_unknown_marker`);
- the **b3 head formula** (2026-07-03): the marker's fourth byte encodes an
  auxiliary head block of `32*(b3 - 8)` bytes before the value run
  (`b3 ∈ {08,09,0a,0c}`). This generalises the former "+32 on 0xa2 pages"
  constant (every corpus 0xa2 page is `a2 01 03 09`; everything else on the
  supported tables is b3=08, so the two rules were observationally identical
  there) and is what unlocked the 2006 vintage (b3=0a/0c, 64/128-byte heads).
  Unknown b3 aborts (`canivt_unknown_marker`);
- the **extent check**: the directory entry's u16 size is the page's allocated
  length and `4 + presence + trailer + head + nv*width <= size` always (with
  equality on the `b2 == 0` pages when `b3 <= 0x09`; the `b3 >= 0x0a`
  suppression-tail pages append absent-cell mask records after the run); an
  overrun aborts (`canivt_page_overrun`);
- **no silent page skips**: a valid directory entry pointing at an unknown
  marker warns (`canivt_skipped_pages`);
- the **pre-flight** (`ivt_page_preflight()`) applies these to the first pages
  plus a **capacity rule** (presence bits ≤ the page's real cell count) and a
  **span rule** (the highest valid directory entry must sit in the outer
  dimension's upper half), and is part of `ivt_f2_decodable()` — so
  same-signature containers whose pages are inconsistent with the layout are
  rejected as unsupported instead of decoding unvalidated values. The legacy
  0x1000-stride probe is gone from `ivt_family()`.

Every content-heuristic fallback (the stride walk, regex/dedup scans,
count-keyed labels, marker-scan directory location, fixed slot orders, tail
windows) announces itself with a classed `canivt_fallback` warning
(`ivt_fallback()`, R/fallback.R), and `options(canivt.strict = TRUE)` turns any
of them into errors; detection probes (`ivt_family()`) stay quiet
(`ivt_quietly()`).

Hard-coded content guesses closed by the same sweep, each exposed by a new
corpus table:

- the header dir pointer **`@558` stores only the low 16 bits** of the
  directory offset (`ivt_idx0()` unwraps by `+ k·65536`): 98-10-0013's
  directory is at `44761 + 65536` — its **cell decode had been silently EMPTY**
  (0 pages; only its metadata was ever validated); now 37,587/37,587 cells
  exact vs the StatCan CSV. 95F0250XDB96001 needs `k = 2`;
- the page-directory entry floor `off >= 1e5` silently truncated
  98-400-X2016387's directory to 6 of 22 pages (its pages start at ~7 KB; the
  floor is now 1024, past the header region);
- the descriptor's doubled-name anchor required an uppercase first letter:
  95F0250XDB96001's "1995 Household Income (3)" dimension was silently dropped
  and the 2-dim layout decoded misindexed cells **that passed the pre-flight**
  — only viewer validation caught it (now 72/72). Digits are admitted; the
  header `n_dim` count field is unreliable (95F0200XDB96003 reads 1026 with 4
  clean dimensions) — every gate now uses `length(d$dims)`.

### Rejected same-signature variants (all structural, no allow/deny lists)

- ~~**97F0020XCB2001070** (2001 F-series)~~ — **SUPPORTED as of 2026-07-04.**
  The capacity-rule rejection ("1124 presence bits vs a 448-real-cell
  capacity") was a symptom of a misread descriptor, not a different nesting:
  its "Selected Demographic, Educational, Cultural, Language Characteristics"
  dimension is **type `0x09` with a u16 count = 282** (`1a 01` LE), and the u8
  read took the low byte and got **1**, collapsing the data dimensions to
  Number(2)×Earning(8)×Selected(1)×Years(2) so the pages carried more presence
  bits than the layout's cell capacity. With the true count the ordinary
  unified layout fits exactly (Earning straddles the 2048-bit record — ipc 2,
  4 windows — capacity 1128 bits) and every geometry invariant is clean.
  Viewer-validated cell-exact: **34,968/34,968** cells over all 14
  geographies (default fixed) plus Canada/Ontario/Nunavut across every
  Number×Earning fixed-dim slice (b2020 viewer `Rp-eng.cfm`, PID 60957).
  The **same `0x09` u16 width fix** repaired a *silent mis-decode* on the
  supported table **98-10-0174** (dissemination areas): its Mother tongue
  dimension is also `0x09` with **331** members (the u8 read collapsed it to
  1, so only member 1's cells decoded) — now CSV-validated **14,895/14,895**
  cells over 3 geographies (all 331 mother-tongue × 3 gender × 5 knowledge).
  Strict-mode clean.
- ~~**97-570-X1981004** (1981 profile)~~ — **SUPPORTED as of 2026-07-04.** The
  span-rule rejection was a symptom of a misread descriptor, not a new
  nesting: the "Values" placeholder's count read 32 instead of 1 (the
  double-01 framing ambiguity), which made the layout expect 32 outer entry
  members. With the reconciled counts (`Values(1) × Profile(79) ×
  Geography(5989)`, geography the LAST descriptor dimension via
  `ivt_f2_geo_dim_index()`) the ordinary unified layout fits exactly:
  geography straddles (3 windows of 2048 presence bits), Profile pages the
  directory at stride 4, and the observed period-4 valid-entry pattern is the
  pow-2-padded window count. Viewer-validated: 5,989/5,989 geography members
  in order; 1,264/1,264 sampled cells exact over 16 geographies (incl. the
  2048/2049 and 4096/4097 window boundaries and member 5,989); 217
  absent-as-zero. Identity via the master directory
  (`ivt_f2_master_identity()`; the `@40`/`@48` pointers are zero), 10
  footnotes under the `FOOTNOTE:`/`RENVOI :` framing, inline geography
  names + GEOUIDs positional. Strict-mode clean.
- ~~**98-400-X2016203**~~ — **SUPPORTED as of 2026-07-04.** Both anomalies were
  one bug: descriptor type `0x0a` carries a **u16** count, and the u8 read had
  taken the low byte of "Selected characteristics (825)" (= 57), mis-nesting
  the whole layout — the "non-exact `b2 == 0` pages" were an artifact of the
  wrong presence geometry (the `a2 01 03 0a` pages had already been explained
  by the b3 head rule). With the true count every page fits, the pre-flight
  passes, and the decode (49.6M cells, ~23 s) is **viewer-validated
  cell-exact**: 39,516/39,516 on multi-fixed slices over Canada/Montréal/
  Toronto/Victoria (incl. the last member of every fixed dimension) plus
  ~25k more single-fixed cells over 9 further geographies, absent-as-zero
  confirmed throughout; all 825 chunked EN/FR member labels exact vs the
  viewer row list (`ivt_f2_dim_dir_label_chunks()`); 51 geographies named.
  NOTE the viewer's d0 dropdown re-sorts geographies (provinces first, CMAs
  after) on this table — join ground truth by NAME, not option position.
  Strict-mode clean. The 2016 vintage is now fully supported in the corpus:
  the large crosstabs 98-400-X2016328 (5-dim, 4,868 geos), 98-400-X2016261
  (6-dim, 86.8 MB, 14.4M cells) and the income table 98-400-X2016120
  (all-float64 pages) are ordinary supported-container tables — every geometry
  invariant clean, cells viewer-exact (360/360, 154/154 and 510/510 on leading
  geographies; 1,680/1,680 and 1,432/1,432 on deep-tail members 3000+/4860+).
  **Suppression in this container is WHOLE-GEOGRAPHY cell absence, not a
  per-cell sentinel** — and it IS recoverable from the file: on 2016120
  (income — heavily suppressed for small areas) the 888 geographies with no
  stored cells at all are exactly the 888 whose inline per-geography dqf flag
  ends in `9` (888/888, zero crossovers over all 4,868 geographies), and the
  viewer renders exactly those geographies' cells blank; published
  geographies' absent cells all render as 0. `read_ivt()` exposes both
  signals: `metadata$geographies$has_data` (presence-derived, all tables) and
  `metadata$geographies$dqf_code` (inline pre-DGUID tables). Cross-vintage
  survey of the two signals: `has_data` is universal by construction (any
  vintage, any table — it is the per-TABLE truth). The dqf flag is a
  per-geography descriptor with per-SUBJECT digits, where digit value `9`
  marks suppression for that subject: exact 888/888 on both 2016 income
  tables (digit 5 = income), a consistent subset on the 2016 commuting table
  (its 5 empty geos all carry the flag, but most flagged geos publish
  commuting data), and multi-9 patterns (`09999`, `19999`, …) on the 2021 CT
  table's 90 empty geographies (2021's schema DQF_CODE uses the same 5-digit
  convention). The 1996/2011 flags carry 0/1/2 quality rounds without 9s, and
  their empty geographies (806 on 95F0250, 137 on 95F0200, 2 on 2011) are NOT
  flag-marked — consistent with genuinely empty/tiny areas rather than
  quality suppression; 1991 has no 9-convention and no empty geographies in
  the corpus table. 2016120's
  geography also reads positionally now: its dim-1 directory carries two
  odd-sized auxiliary blocks BEFORE the group runs (2016328/2016261 carry the
  same two after them), so the run walk accepts a small leading-block skip —
  a wrong skip cannot fit, the partial chunks anchor the alignment. Member
  order = the viewer d0 list, 4,868/4,868, on all three tables.

### Note: the `0xa` marker variant and empty geographies

`0xa` vs `0x8` in the marker's high nibble is purely a **storage variant** (a
longer pad/`0xFF` trailer before the still-inline value run), **not** a data-
suppression flag: `0xa2`/`0xa4`/`0xa8` pages carry real data that decodes
cell-exact. **All-zero geographies** (an empty presence record) do occur — listed
for completeness with no data in this table — but that is a per-geography property
(the CSV publishes them as all-zero) and appears on both `0x8` and `0xa` pages,
sometimes right beside a data-rich geography on the same page.

## [x] Other Beyond 20/20 products that share the signature — ALL DECODED

**Every `.ivt` file in the test corpus now decodes** (2026-07-06). The products
below share the `04 00 20 00` signature but historically read a garbage
dimension count and recovered zero data dimensions; each turned out to be a
**descriptor-layer difference** (a relocated pointer, an inverted record region,
a misread count width, or prose-bled name copies), not an alien container. The
`ivt_f2_decodable()` gate (plausible `n_dim`, ≥1 sized data dimension) still
rejects genuinely non-decodable inputs — previously they passed the loose
family-2 gate and crashed the decoder with `argument of length 0` — and that
rejection path is regression-guarded by a synthetic signature-only input in
`tests/testthat/test-formats.R`.

Files formerly unsupported, now all DECODED and SUPPORTED:

- [x] **Profile tables** (`98F0172X`, `95F0170X`) — **DECODED and SUPPORTED**
  (2026-07-04). They are the ordinary unified layout (`Values(1) × Profile(529)
  × Geography`, geography LAST and straddling — the 97-570-X1981004 lineage)
  plus one new page variant: the **dense `0x0_` marker**
  (`[b0][01][u16 count]` + one value per grid position in grid order, zeros
  stored literally, `count` zero-padded past the window; exact directory fit
  `4 + count·width == size` on every dense page). The historical
  "non-rectangular Σcount = 2,222,304" puzzle dissolved: at the true directory
  base the entries number **exactly 529 × window_count** (1,058 = 529 × 2 on
  98F0172X, 529 × 3 on 95F0170X) — the old count was a truncated read (the
  `0x0_` markers were rejected, `ivt_idx0()` fell back to the 0241 constant),
  and the "member 3808 = St. John's" anchor predated the positional
  inline-geography fix (St. John's is member 1). The sparse pages are the
  standard container, untouched. Viewer-validated cell-exact: **11,638 cells
  (22 geographies × 529)** on 98F0172X incl. window boundary 2048/2049, deep
  tail 4,062/4,063 and the Ottawa-Hull block (whose dropdown the viewer
  re-sorts Hull-first — join by NAME; the codebook order is confirmed by the
  value↔name pairing), and **10,580 cells (20 geographies × 529)** on 95F0170X
  incl. boundaries 2048/2049 + 4096/4097, Canada and last member 5,602 (its
  viewer labels append CSD-type suffixes and re-sort — name-join with type
  stripped). Both strict-clean, with 39 legacy footnotes each (the
  `Footnote(s)` section-header spelling; master-directory-bounded after
  admitting the 4-byte-aligned second length field in `ivt_f2_read_dir_at()`)
  and EN/FR titles assigned by content (`@48`/`@40` are NOT fixed language
  slots — 98F0172X stores FR at `@48`; `ivt_f2_legacy_identity()` now decides
  by `ivt_f2_frscore()`, the `ivt_f2_master_identity()` pick).
- [x] **2001 F-series crosstab** (`97F0020XCB2001070`): **DECODED — SUPPORTED**
  (2026-07-04). The "1124 presence bits vs 448-real-cell capacity" rejection
  was a **descriptor misread**, not a different nesting: its "Selected
  characteristics" dimension is **type `0x09` with a u16 count = 282**, and the
  u8 read got 1 (the low byte), collapsing the data dims and over-filling the
  pages. With the true count the ordinary unified layout fits exactly and the
  decode is viewer-validated cell-exact (34,968/34,968; PID 60957). The same
  `0x09` u16 fix corrected 98-10-0174's Mother tongue(331). Served by
  StatCan's legacy `www12` dynamic system, but its b2020 HTML viewer renders.
- [x] **Other "F"-series** (`97F0015XCB2001041`) — **DECODED, SUPPORTED**
  (2026-07-06). This was the "least understood 2001 file": French **description
  prose bleeds INTO and BETWEEN the two name copies** of every dimension record
  (`Total Income GrTotal Income Groups (12). ; Dans tous les …`;
  `Sex (3)atif totSex (3) et les …`; `Geographyle nomGeography connexes …`), so
  the exact-double, truncated-tail and split paths in `ivt_f2_descriptor_name()`
  all missed. Two count-anchored fallbacks recover the names structurally: each
  **data-dim name ends in `(count)`** and the framing count is known, so take the
  shortest prefix completing `(count)` (de-truncating a capped first copy A+B →
  B); the **geography** name (no parenthetical) is the longest prefix that
  reoccurs later in the run (`Geography`). The framing counts were always clean
  (`Geography(4432, type 0x0d) × Sex(3) × Age Groups(7) × Total Income
  Groups(12) × Mode of Transportation(9)`), so with the names recovered the
  ordinary family-1 layout decodes 864,205 cells. **Viewer-validated
  cell-exact**: 864/864 over Canada across all four data dimensions (5 fixed
  sex/age slices) + 1,080/1,080 over 29 further geographies (member order
  confirmed by reconstructing the viewer's `<name>, <type_abbr>` display key);
  median-income (member 12) values are all sensible ($18,991–$33,553 for
  Canada). All 4,432 geographies named + coded, all data-dim EN/FR labels
  resolve, strict-clean. One byte-faithful negative stored value (-3298, a tiny
  area's median-income sentinel). Served by StatCan's legacy `www12` dynamic
  system, but its b2020 HTML viewer renders.
- [x] **2016 collective-dwellings crosstab** (`98-400-X2016019`) — **DECODED,
  SUPPORTED** (2026-07-06). Same **inverted descriptor layout** as
  97-570-X1981002 (records before the signature block, anchored on the
  preceding `81 02 03 00` sub-header — see the header section-pointer notes).
  With the real descriptor the layout is ordinary: `Geography(14) × Type of
  collective dwelling(16) × Collective dwellings occupied…(2)`, geography
  straddles (14 fits one window). Viewer-validated cell-exact: **448/448**
  cells across all 14 geographies (join by the EN half of the bilingual
  geography name), strict-clean; all 16+2 EN/FR data-dim labels and the 14
  inline geography names + bare codes decode.
- [x] **2006 census DA crosstab** (`97-563-XCB2006072`): **DECODED — SUPPORTED**
  (2026-07-03). The page directory was at the plain `u16@558 = 45641` all along
  (14,381 entries = ⌈57,523/4⌉ exactly, the geography-straddle layout the
  descriptor predicts); the validator had rejected it only because this
  vintage's markers carry **`b3 = 0x0a/0x0c`**, which encode a
  **`32·(b3−8)`-byte auxiliary head block** before the value run — the general
  rule behind the formerly hard-coded "+32 on `a2 01 03 09` pages"
  (`ivt_value_trailer()` now takes b3; observationally identical on every
  supported table, where all 0xa2 pages are b3=09 and everything else b3=08).
  Its `b2 == 0` pages are NOT exact-fit: after the popcount value run they
  append **per-(geo, age) suppression-mask records** (one nibble per
  presence-member, sex T/M/F at bits 3..1, split into value-width units with
  all-zero units dropped) — byte-exact reconstructible from the presence
  bitmap on 14,111 of 14,381 pages, the rest benign writer slack/truncation
  (see ivt-format.md "The b3 head block and suppression tails"). Exact-fit is
  now asserted only for `b3 ≤ 0x09`; the capacity/span preflight rules carry
  the gate. Cell semantics are the SAME as every other vintage — only non-zero
  cells stored, absent renders `0` in the published table (the 2006
  tabulations zero-fill area-suppressed small areas; the tail masks flag every
  absent cell but the published value is 0 either way, and `has_data` remains
  the per-geography suppression signal). **Viewer-validated cell-exact**:
  3,487/3,487 stored cells match the B2020 viewer across 32 geographies ×
  all 135 cells (Canada, NL, deep-tail members 40,000/57,000/57,523, 20
  random ones, and wholly-empty geographies) and all 833 absent sampled cells
  render 0. 6,526,221 cells decode in ~6 s; all four dimensions labelled
  (the descriptor's truncated first name copy "Presence of inc" is repaired
  from its complete second copy — `ivt_f2_descriptor()` prefers the tail copy
  when the first hits the ~15-byte cap, which also completes the
  1996/2011/2016 descriptor names); geography (already viewer-validated)
  names + uids flow through the standard inline reader.
- [x] **1981 profile `97-570-X1981004` — SUPPORTED** (2026-07-04; see the
  Rejected-variants section above for the full story: descriptor count
  reconciliation + `ivt_f2_geo_dim_index()`, no new nesting needed).
- [x] **1981 census `97-570-X1981002`** (CMA/CA profile, Part A) — **DECODED,
  SUPPORTED** (2026-07-06). Its descriptor uses the **INVERTED layout**: the
  dimension records sit *before* the `81 01 20 00 f0 .. .. 80 03` signature
  block (which is followed by the identity/title text instead of preceding the
  records), anchored after the same `81 02 03 00` sub-header that trails the
  signature at D+14/15 on the standard profile tables. `ivt_f2_descriptor()`
  now retries the region between the last `81 02 03 00` before D and D itself
  when the forward walk recovers < 2 records; both anchors are block
  signatures and the retry only wins on ≥ 2 doubled-name records, so it stays
  structural (quiet). Layout is then the ordinary profile lineage
  (`Values(1) × Profile(80) × Geography(120)`, geography LAST and straddling).
  Viewer-validated cell-exact: **1,600/1,600** over the 20 leading geographies
  plus **320/320** deep-tail (members 60/100/119/120, member order confirmed
  by name), strict-clean. Inline geography names + GEOUIDs (120/120).
- [x] **2021 custom-order export `ord-08035…_ct.1-2021-population` — DECODED,
  SUPPORTED** (2026-07-04). The only structural difference from the standard
  tables is that the header `@32` descriptor pointer targets the identity/title
  block, not the descriptor — a red herring that made the "page body looks like
  a different encoding" reading (the misread descriptor mis-nested the layout).
  `ivt_f2_descriptor_offset()` now relocates the descriptor via the master
  directory (every candidate confirmed by the invariant `81 01 20 00 f0 .. ..
  80 03` block signature; a signature scan is the loud last resort). With the
  real descriptor the layout is entirely standard: `Geography(791) × Selected
  characteristics(79) × Tenure(4)`, geography straddles at 4 geos/page over 198
  windows, ordinary `88 01 20 08` float64 / `a2 01 03 09` markers. 101,525
  cells in ~2 s, internal-consistency validated (BC total population in private
  households **4,915,940**; tenure Total == Owner+Renter+Band across all count
  characteristics, differing only by StatCan random rounding ±10). Two
  descriptor-parse generalisations went with it: the geography record may store
  its name **once** (followed by inline member text) and the two name copies may
  be **space-separated or a short/long pair** — handled by
  `ivt_f2_descriptor_name()` (a lowercase→uppercase split), with the single-name
  form accepted only for the opening record. Geography names decode 789/791 from
  the inline combined block (`IVT_F2_INLINE_PAT` relaxed to admit the inverted
  `"<name> (<code>), <type>"` order a few unorganised CSDs use; 2 alternate-name
  entries stay uid-only). Data-dimension member labels come from the plaintext
  **"Variables:" enumeration** (`ivt_f2_varlist_members()`) — the last label
  fallback, since this export carries no binary `81 02 02 00` member codebook —
  Tenure 4/4, characteristics 76/79 (the text under-lists the 3 tail members
  the cube stores).
- [x] **2006 custom-order crosstabs `cro0172986_ct.7/8-2006` — cells + dimensions
  + geography DECODED** (cells 2026-07-04 via the `@32` relocation; geography
  2026-07-04). `Geography(581, BC CDs+CSDs) × Tenure/Housing(4) ×
  Characteristics`; owner+renter+band = total holds per geography (±random
  rounding). Geography now reads **positionally from dimension 1's slot
  directory** (`ivt_f2_geo_inline_dir()`), all 581 EN **and** FR names + GEOUIDs,
  via two format/reader fixes: (a) `ivt_f2_read_dir_at(relaxed = TRUE)` admits the
  `len2 > len` **allocated** size these exports store (content 3024 → allocation
  3078), used only as `ivt_f2_dim_dir()`'s bounded fallback so it never over-reads
  garbage on other tables; (b) `IVT_F2_INLINE_PAT2` + `ivt_f2_parse_inline()` parse
  the **code-in-trailing-parens** combined form `"<name>, <type> (<code>)"` (no dqf
  flag), tried only after the flag-trailing `IVT_F2_INLINE_PAT` so 1991/2006/2011
  are byte-identical (geo_name/geouid/dqf verified unchanged on all three). The
  two combined runs are near-identical EN/FR (BC names untranslated bar the
  province), surfaced as `geo_name`/`geo_name_fr`. **ct8's "Selected
  Characteristics" labels read positionally too** (2026-07-05, strict-clean):
  its codebook marker block stores the name as a SHORT/LONG pair
  (`"Characteristics" 01 03 32 "Selected Characteristics"`), and the first
  printable run — the short copy — failed `ivt_f2_dir_marker_entry()`'s prefix
  match, dropping the dimension to the count-keyed scan (English only). The
  matcher now also accepts a verbatim full-name hit inside a marker-bearing
  entry (≥ 8 chars; entries without the `81 02 02 00` marker cannot qualify,
  so label blocks containing `Total - <name>` never match). Corpus-diffed:
  the ONLY output change on all 28 supported tables is ct8 dim 3 gaining
  `members_fr`/`name_fr` (its EN labels are identical to the old fallback's).
- [x] **2016 custom-extract lineage `CRO0163850` / `CRO0166131` — DECODED,
  SUPPORTED, census-validated** (2026-07-17). A new descriptor/codebook VARIANT:
  large (up to 9-dimension) crosstabs, one detailed table per geographic area, so
  the geography count is usually 1 (`CRO0166131_CT.1.1` = just "Vancouver CMA";
  `CRO0163850_CT.6` = "Canada") or a small set (CT.7 = the 13 provinces/
  territories; CT.2 = 293 CDs). Four format facts, each handled metadata-driven:
  (a) dimension names are UNRELATED `<display><description>` pairs (e.g.
  `CondoStat/Type` + `Condominium status and structural type`) plus a
  lowercase-led `chars`, which the standard doubled-name splitter drops — the
  descriptor now falls back to a **structural accept-all walk**
  (`ivt_f2_descriptor`, gated on the header slot table's authoritative dimension
  count, adopted only when it recovers EXACTLY that count; loud
  `canivt_descriptor_lenient`); (b) the geography descriptor record is a
  `00 00 01 01` count-ZERO placeholder — the real count comes from the codebook
  attribute arrays (`ivt_f2_dim_count_reconcile` now replaces a zero, not just an
  over-count); (c) the per-dimension name marker uses sub-code `81 02 01 00` (not
  `02`), `<name1>[01 .. 32]<name2>` — `ivt_f2_dir_name_marker01` locates it as a
  fallback in `ivt_f2_dir_marker_entry` when no `02` marker exists, keyed on the
  `0x32` copy-tag signature so it cannot match a schema block; (d) geography is
  laid out like a data dimension (name marker + one English combined
  `"<name> <code> (  <gnr>%)"` array, no `GEO_NAME_EN` schema, **English only**) —
  `ivt_f2_geo_custom` reads it positionally and splits name/code (loud
  `canivt_geo_custom`). Also `ivt_page_preflight`'s span check now uses the
  outermost entry dimension with count > 1 (a single-geography outer dimension
  spans nothing). VALIDATED against public census: `CT.6` grand total 13,798,300
  private households and avg/median household income $93,162/$70,615 (census
  $92,990/$70,336, the gap = the universe's farm/reserve/band/income≤0
  exclusions); `CT.7`'s 13 provinces sum to 13,798,305 (= CT.6 ± rounding);
  `CRO0166131_CT.1.1` grand total 960,895 vs the published Vancouver CMA figure
  960,890. Ledger: `CRO0163850_CT6` (545,481 cells) + `CRO0163850_CT7`
  (3,586,460), both `strict_clean = FALSE` (the two loud fallbacks). Corpus
  regression unchanged at FAIL 0 (120 prior tables + these 2).
- [x] **CMHC movers family `CMHC 2016 Table 1/2/3` — DECODED, SUPPORTED,
  reference-CSV-validated** (2026-07-18). Same 2016 custom-extract lineage, but
  the two LARGER tables (Table 2 "Commuters", Table 3 "NOCs"; 10 dimensions each)
  bleed a long **footnote paragraph INTO the descriptor block**, so even the
  accept-all walk finds ~1 dimension and the header `n_dim` field reads garbage
  (543). The header slot table still lists every dimension cleanly (slot k =
  descriptor dimension k), so `ivt_f2_dims_from_slots()` rebuilds the whole
  descriptor from it — name marker + slot-directory member count per dimension,
  geography stays dimension 1 — adopted only when it resolves EXACTLY the
  authoritative dimension count (loud `canivt_descriptor_from_slots`). The
  garbage trailing slots (huge random `n_entries`) are excluded from the
  authoritative count by an `n_entries < 1e6` bound. Validated cell-exact against
  the parsed reference CSVs (`movers_xtab/table{1,2,3}.csv`, harmonized labels):
  Table 1 (StructuralType, geo_custom path, 8 geographies incl. the "minus"
  aggregates) — grand totals + all 7 marginals + a 2-way (Core×STIR) + a 3-way
  (315 cells) exact; Table 2 (9 geographies) and Table 3 (6 geographies) — grand
  totals AND all 9 per-dimension marginals for Canada exact (compared as sorted
  value sets, since labels/orders are harmonized/re-pivoted). Ledger:
  `CMHC2016_movers_T1` (1,067,791 cells) + `CMHC2016_movers_T2` (11,078,692),
  both `strict_clean = FALSE`.
- [x] **Canadian Business Patterns `Dec07DA`…`December 2015` — DECODED, SUPPORTED,
  internal-consistency validated** (2026-07-18). A new StatCan PRODUCT LINE (the
  Business Register, not census): establishment counts by `Dissemination Area ×
  National industries (6-digit NAICS) × Employment size ranges`, 9 files 2007–2015.
  Same Beyond 20/20 container (byte-identical 32-byte header prefix), but three new
  variant facts, all handled metadata-driven: (a) the descriptor **signature ends
  `80 ff`** (`f0 00 00 80 ff` / `f0 00 80 80 ff`) not `80 03`, and `@32` points at a
  zero-filled slot, so the descriptor is found only by the signature scan
  (`ivt_f2_is_descriptor` now accepts `b9 ∈ {03, ff}`); (b) the geography record is
  framed `[count_lo][count_hi][geotype] <name>` with **NO `01` separator** (embedded
  in a binary blob) and sits at a **VARYING descriptor position** — geography-first
  (2007, `geo_dim = 1`), -last (2008/2012–2015, `geo_dim = 3`) or -middle (2010/2011,
  `geo_dim = 2`) as the tabulation order changes year to year — recovered by descriptor
  anchor B (a geotype-led no-`01` record, any position, u16 count with `count_hi > 0`;
  loud `canivt_descriptor_lenient`) and geography identified by codebook signature not
  position (`ivt_f2_geo_dim_index` probes every dimension, and `ivt_f2_dir_has_bare_codes`
  recognises the bare-numeric-code geography); (c) the geography codebook stores bare
  8-digit DA GEOUIDs (e.g. `59150001`) as dense `[len][ascii-digits]` records in the
  tail of each `81 02 00 04` chunk, single language, no DGUID shape / no `GEO_NAME`
  schema — read positionally by `ivt_f2_geo_bare_codes` (loud `canivt_geo_bare_codes`;
  a DA has no name, so `geo_name` is the code). Also fixed a general chunk-assembler bug
  (`ivt_f2_dim_dir_label_chunks`): a `>256`-member dimension's partial FINAL label chunk
  may be padded to a full 256-slot block, which the exact-length matcher skipped —
  recovering NAICS(929)'s 4th chunk (161 members) and any similarly-padded codebook.
  Cell counts validated by three independent signals agreeing (descriptor count =
  bare-code count = distinct cell geographies): 2007 4,074,605 cells / 50,988 DAs,
  2008 3,957,641 / 51,144, 2010 3,970,492 / 45,383; internal consistency holds
  (`Total (A) = Indeterminate (B) + Subtotal (A−B)` per cell). Ledger: `CBP2007DA`
  (geo-first), `CBP2008DA` (geo-last), `CBP2010DA` (geo-middle), all
  `strict_clean = FALSE`. **`Dec09DA` is a CORRUPTED SOURCE file** — the geography
  name overwrote the `EMP. SIZE RANGE` descriptor record at the byte level (garbled
  `DA2Dissemination AreaDA2DA`+`IZE RANGE`, `ndim` reads 2), unrecoverable; a documented
  source defect like the DQF-note truncation, not a decoder gap.
- [x] **Untested-but-supported `~/data/xtabs` groups now ledger-covered** (2026-07-18).
  A sweep of the `~/data/xtabs` tree found these already decode via existing lineages
  (no code change) and added a regression row for each: `EO2654_2011_Van` — the
  EO2654 Standard-Community-Profile timelines (1971–2011, Toronto/Vancouver; **1971 is
  the oldest vintage yet decoded**), ordinary profile lineage, 1,227,181 cells;
  `EO3278_T1_CDCSD` — the CMHC "unoccupied dwellings" EO3278 tables, ordinary family-2
  (`Geography × Structural type × Document type`), 80,016 cells; `CMHC2016_movers_T3`
  ("NOCs", the 3rd movers table, same footnote-bleed 10-dim lineage as T1/T2 via the
  slot-table rebuild), 22,704,083 cells; `CRO0166131_CT1_1` (Vancouver CMA, the 2016
  custom-extract per-area sibling of `CRO0163850`), 9,269,180 cells. All
  `strict_clean = FALSE`.
- [x] **Older Borealis survey tables — `ucr2.2_3-2006` (Uniform Crime Reporting)
  DECODED, SUPPORTED** (2026-07-18). A Borealis `SP3/6OXWOP` file, and the first of
  the pre-DGUID single-area survey lineage (single geography, single reference year,
  one real data dimension) to onboard. It carries the standard `04 00 20 00`
  signature and the **inverted descriptor layout** (records before the
  `81 01 20 00 f0 … 80 03` signature block; identity prose *after* it), which the
  existing retry already handles — but three descriptor-layer quirks broke it, each
  fixed generally: (a) a **zero-count reference dimension** ("Year" → member "2006"):
  its count byte lands on the previous block's tail (`00 20 01`), read as 0. A count
  of 0 is always invalid, so `ivt_f2_dim_count_reconcile()` now reconciles `count == 0`
  the same way it reconciles the double-01 records — from the codebook, defaulting a
  member-array-less singleton to 1 (loud `canivt_zero_count`). (b) That singleton's
  member label ("2006") is stored as a **`81 02 01 00` VALUE block** (told from the
  same-tagged field-NAME/schema block by its trailing `[strlen][string]` reaching the
  block end), which the `[01 01]`/`[81 01]` array reader could not see — recovered by
  `ivt_f2_dim_value_block_labels()`, including the case where the name marker is the
  LAST directory entry (arrays precede it). (c) The single-area **geography is stored
  exactly like a data dimension** (a `81 02` field dictionary "Code / Description /
  Description_FRA / _Sort" + per-member `[01 01]` label blocks, no UID) — the
  schema-free chunk assembler skipped its <3-member blocks and returned garbage, so a
  new specializer `ivt_f2_geo_datadim()` reads it with the generic dimension-label
  machinery (gated on a UID-less field dictionary + a clean `n_geo` label read; loud
  `canivt_geo_datadim`). Result: `Year(1) × Geography(1="Selected Police Services") ×
  Offence(30)` = **30 cells**, bilingual geography + all 30 motivation-category labels,
  `strict_clean = FALSE`.
- [x] **`02 00 20 00` split-definition survey generation — Health Statistics 1999
  (`00060104`) DECODED, SUPPORTED** (2026-07-19; `SP3_GPVU3L_00060104,TRUE,FALSE,451`).
  The first onboarded file of the older Beyond 20/20 generation whose container byte 0
  is `02`, not `04`. Everything downstream of the header is the **same model**: the
  descriptor sits at the standard `81 01 20 00 f0 … 80 03` signature (resolved via the
  master-directory scan), the page directory is the usual `[u32 off][u16 len][u16 len]`
  at `@558`, and the pages are the modern `marker(4) + 256-byte presence + sparse
  values` model with the same width nibble (`2/4/8` = int16/int32/float64). Three small
  adaptations: (a) `ivt_family()` accepts byte 0 ∈ {2,4}; (b) the descriptor walk has
  no `FACET04` title to bound the records, so `ivt_f2_descriptor()` bounds them at the
  nested `81 01 <u16 len>` FACET01 title block at `D+16` (else the accept-all pass
  wanders into the codebook member blocks) — this recovers the geography record
  `REGION` (a name+display record the doubled-name splitter drops); (c) the geography
  dimension carries no UID / GEO_NAME schema, so it is identified by the header
  dimension name (the geo-name fallback now also matches `region`/`province`, loud
  `canivt_geo_by_name`). Result: `Quantifier(1="Total fertility rate") ×
  Geography(13 = Canada + provinces + territories) × Period(37 = 1961–1997)` = **451
  non-zero cells**, bilingual province names EN+FR, year labels; the int16 value block
  decodes Canada's real total-fertility-rate series (`3.84 → 1.55`).
  **Generalised across the Health at a Glance line** (2026-07-19): sampling 20 more
  files from the same dataset showed the single-`00060104` bound (the nested FACET01
  title block) was too tight for the multi-dimension tables — their records spill past
  the title block. Replaced it with two metadata-driven rules that make the walk
  uniform: bound the record region at the **first value block** (the page directory's
  first entry — records always precede the value data and codebook), and add a
  **contiguity break** to the accept-all pass (genuine records sit back-to-back; once
  one is in hand, a >8-byte gap with no further record ends the walk before it can mine
  codebook member labels). With these, **10 of 21 sampled Health files decode** (3–7
  dimensions, int16/int32/float64, geography at descriptor position 2–6, and
  multi-facet `Quantifier(2)` tables) — up from 1. `00060108` (therapeutic abortions +
  births, geography at dim 3) is internal-consistency-validated (Canada = Σprovinces +
  territories). The `02` container is **not** limited to these 3 datasets by vintage
  alone: Income Trends 1976-2006 and Census of Agriculture 2001 are byte-0 `04`, so the
  `02` generation is specifically the **late-1990s survey products** (Health at a
  Glance 1999, Census of Agriculture 1996, Small Area Business 1996).
  **RESOLVED — there is NO integer scaling; the values are complete.** The apparent
  "scaling" was a misreading. The `.ivt` stores each facet's values as complete integers
  in the **indicator's own units**, and those units are stated in the facet member's
  `_Description`. For the TFR, the description reads: *"This indicator shows the number of
  children born **per 1,000 women** during their reproductive period."* — so the stored
  `3840` is literally *3840 children per 1,000 women* (= 3.84 per woman): a genuine,
  complete value, not a fixed-point that needs dividing. This is why no decimals byte was
  ever found (there is none), why the `b2` byte only tracks the value width/trailer, and
  why the dec-"3" vs dec-"0" facet codebooks are byte-identical — the difference was
  never encoded because there is no decimal scaling. `read_ivt()` returns the raw
  integers as the correct values; **no scale warning** is emitted. The unit statement
  lives in the facet member's `_Description`, which `ivt_members()` now SURFACES as
  `description`/`description_fr` (`ivt_f2_dim_prose_texts()` reads the full-length
  `[01 01][u16 len][01]<prose>` block, NUL-padding trimmed, footnote-prefixed notes
  excluded, mapped positionally only when unambiguous — a singleton facet or a dense
  one-per-member set; `NA` for the many dimensions/tables carrying none, so modern files
  and existing Parquet are unchanged).
  **COMPLETED — the whole `02 00 20 00` generation now decodes from the codebook, not
  the descriptor block** (2026-07-19). The earlier bound-the-record-region approach
  still misread counts on the irregular descriptor block (the `04`-separated "ANNUAL"
  time dimension, the doubled/space-padded `<display><description>` name pairs). Replaced
  it, for `byte 0 == 0x02` files only, with `ivt_f2_descriptor_02()`: a dedicated
  descriptor rebuilt **entirely from the per-dimension codebook** the header slot table
  (`@824`) locates. Each dimension's count comes from its member CODE array
  (`81 02 <alloc> 00 16 00`, `alloc = nextpow2(count)` Pascal codes at the block tail,
  trailing pad dropped) or label array; its name from the `81 02 02 00 56 00` bilingual
  name marker, falling back to a named schema field (`81 02 <n> 00 22 00`, e.g.
  "Timeseries") then the descriptor's doubled reference name. A lone unsized
  reference/time dimension (no member array in its codebook) is recovered from the
  value-page layout — the unique small count for which `ivt_page_preflight()` validates
  (`canivt_descriptor_02_probe`). Also relaxed `ivt_dir_entry()` to admit the
  generation's `used ≤ allocated` directory entries (modern files write `used == allocated`).
  Result: **21 of 23 sampled `byte 0 == 0x02` files decode** (Health Statistics at a
  Glance 1999 `00060101/102/103/104/108/112/118/123/129/141/153/210/216/221/229/234/239`,
  Census of Agriculture 1996 `EDDTAB39` float64, Small Area Business / employment
  `EMPLOY1` int32, `tb111996`), all internal-consistency-validated where a Total row
  exists (Canada = Σprovinces + territories on `00060101`; `EMPLOY1`, `00060129`,
  `00060141`). All decode through the loud `canivt_descriptor_02` fallback
  (`strict_clean = FALSE` in the ledger).
  **Two known gaps remain** (ledger `supported = FALSE`): `00060117` — a **mixed-width
  quantifier** (int32 counts + float64 rates in one table) that would force per-width
  page splitting the unified single-presence-record layout does not model; and
  `tb611996` — a **multi-page sparse** table whose `prod(entry counts)` matches none of
  its 8 directory entries for any candidate count, leaving the reference-dimension probe
  ambiguous (its true count, 3, is only stated in the title "1995 to 1997").
- [x] **No-descriptor-block survey lineage — LFHR `Table-051` + criminal-justice
  `h2530002` DECODED, SUPPORTED** (2026-07-19). The UCR siblings: same `04 00 20 00`
  header but **no dimension-descriptor block at all** — no `81 01 20 00 f0` signature,
  `@32 = 0`, and neither the master directory nor a signature scan resolves one.
  The **header slot table `@824` is present and valid**, though, and is a complete
  metadata-driven substitute, so `ivt_f2_descriptor_from_slots()` synthesizes the
  descriptor from it (loud `canivt_descriptor_from_slots`): the dimension count is
  the number of populated slots (`alloc == nextpow2(n_entries)` validated), each
  dimension's member count from its codebook (`ivt_f2_slot_member_count()`: the
  largest non-numeric `[01 01]`/`[81 01]` member array, else a `81 02 <alloc> 00`
  per-member FLAG block — the reference-period/"Timeseries" dimension stores one flag
  byte per member, `alloc = nextpow2(count)` a power of two ≥ 8, count = the non-zero
  flags), and its name from the codebook doubled-name marker
  (`ivt_f2_dim_marker_name()`, with `ivt_f2_first_marker_name()` for the time
  dimension's two markers "Timeseries"/"Date"). Also relaxed `ivt_f2_geo_datadim()`
  to admit a **schema-less** single-area geography (LFHR's "Canada" is mis-encoded as
  `bare`; its `[01 01]` label arrays read cleanly via the generic reader). Results,
  both `strict_clean = FALSE`, internal-consistency plausible: **justice
  `Geography(1=Canada) × Methods(8) × Timeseries(37, 1974–2010)` = 296 cells**
  (homicide counts by method by year); **LFHR `Geography(1=Canada) × Sex(3) × Class
  of worker(4) × Retirement age(2) × Timeseries(35, 1976–2010)` = 800 cells**
  (retirement ages/rates). KNOWN GAPS (accepted, not decode errors): the Timeseries
  members surface as ordinal positions, not year strings (the years live in the flag
  block, not a label array); LFHR's Retirement-age member labels fall to a note-block
  and read imperfectly. The synthesis fires ONLY when no descriptor block resolves,
  so the whole existing corpus (which all carry descriptor blocks) is untouched.
- [x] **1986 census profile `97-570-X1986002` — DECODED, SUPPORTED** (2026-07-07).
  A previously-untested VINTAGE (no 1986 table was in the corpus). It is the
  ordinary profile lineage, identical in shape to the 1981 profiles: `Values(1) ×
  Profile of Census Divisions/…(139) × Geography(6288, type 0x0d)`, geography LAST
  and straddling. Decoded out of the box with **no code change** — 618,723 cells,
  strict-clean, every geography named (`CANADA`, `Newfoundland - Terre-Neuve`,
  Division/CSD names + bare GEOUIDs, 0 NA), Canada population 24.3 M. Confirms the
  profile-lineage machinery generalises across the 1981/1986/1991 vintages.
- [x] **2011 NHS commuting-flow `99-012-X2011032` — CELLS DECODED, flow geography
  onboarded** (2026-07-07). A new PRODUCT LINE (the 2011 National Household Survey
  `99-0xx-X` origin-destination flow tables) with a **new geography descriptor type
  `0x0f`**, a u16 count the u8 read misread as its high byte 67 — collapsing the 27
  data pages (9 geography windows × 3 sex groups) to 201 cells. Adding `0x0f` to the
  u16 width-tag set recovers the true count **17,163** (origin-destination CSD
  flows, "flows ≥ 20"); the ordinary profile-lineage layout (`Values(1) × Sex(3) ×
  Geography(17163)`, geography straddling, 8 dense + 19 sparse int32 pages) then
  decodes **42,655** cells, strict-clean, internal-consistency validated (Total =
  Male + Female per flow; self-flows average 3,570 commuters vs 328 for
  cross-flows — confirming the geography member order aligns with the cell decoder).
  Geography is a genuinely new codebook shape: each member is a flow stored as the
  combined string `"origin (code) type flag (pct%) / dest (code) type flag (pct%)"`
  alongside a dedicated `origincode/destcode` uid array. The generic inline reader
  cannot fit it (each member chunk carries ~11 parallel arrays — two full-flow
  combined copies EN/FR, a code-less display copy, per-side component arrays and the
  uid — and the ` / ` flow separator collides with the bilingual split), so
  `ivt_f2_geo_flow_dir()` anchors on the uid array in member order and **joins each
  combined label back to its member by the two codes it carries** (order-independent,
  self-validating). **A flow is decoded as TWO geographies** — the file's own
  `POR`/`POW` (Place Of Residence / Place Of Work; `LDR`/`LDT` in French) schema:
  the origin (before the ` / `) is the place of residence, the destination the place
  of work. `ivt_tidy()` / the geography metadata surface `geo_res_name`/`geo_res_uid`
  (residence) and `geo_work_name`/`geo_work_uid` (work) as separate columns, keeping
  the pair as `geo_uid` and the combined string as `geo_label`. **Geography metadata is
  100% complete** — all 17,163 residence + work uids **and names** (EN + FR). Most names
  come from the combined-record split; the handful of members whose combined record is
  missing or truncated in a tail partial chunk (6 remote Nunavut self-flows — Whale Cove,
  Repulse Bay, Kugaaruk, Kugluktuk, Gjoa Haven, Taloyoak) are backfilled from the file's
  per-side name arrays (`POR/LDR` · `POW/LDT`) via a `code → name` dictionary, keyed by
  the residence/work code already held; `geo_label` for those is reconstructed from the
  recovered halves. It is a loud `canivt_geo_flow` fallback (→ `strict_clean = FALSE`),
  gated on a complete uid array so no other table engages it. **Flow member order —
  VIEWER-VALIDATED** (2026-07-10): the decoded `(residence → work) → value` triples are
  **content-exact** against the Beyond 20/20 viewer on all vintages (`98-400-X2016325`
  CSD, `98-400-X2016391` CD, `98-400-X2016327` CMA, `99-012-X2011032` 2011 NHS —
  100% joined-value match and set-equal work destinations across sampled residences,
  after fixing every non-geography data dim to its Total member as the viewer does).
  Our member order is **residence-major, SGC-code ascending** — deterministic and
  geographic; the viewer *re-sorts* within each residence for display (so a positional
  order match to the viewer is not expected, the same behaviour as the 2016203 geography
  re-sort). Validation is scrape-based and internal (see `R/ground-truth.R`), not part of
  the automated suite.
- [x] **Commuting-flow generalization across 2016 + 2021 vintages** (2026-07-09). The
  2011 `0x0f` packed origin-destination flow reader was validated against the sibling
  flow products of the 2016 and 2021 censuses. StatCan uses **three different
  encodings** for the same "commuting flow from residence to work" product:
  - **`0x0f` packed flow (2011 + 2016 census-subdivision level).** `98-400-X2016325`
    (2016 CSD) decodes with the *identical* `0x0f` flow path: **23,565** O-D flow
    members, `Values(1) x Sex(3) x Geography(23565)`, **67,555** cells, `geo_res_*` /
    `geo_work_*` names + uids **100% populated** (EN + FR, 0 NA). Confirms the flow
    decoder is portable across the 2011 NHS and 2016 `98-400-X` container generations.
    Loud `canivt_geo_flow` fallback (`strict_clean = FALSE`).
  - **Residence x work crosstab (all 2021 levels).** 2021 abandoned the packed format:
    the flow is a plain crosstab with geography (residence, dim 1, flagged geo) and a
    second geography-valued **`Place of work`** dimension (both type `0x0d`/`0x09`/`0x08`
    by level), no `0x0f`. `98-10-0459-01` (CSD, 5161-squared, **93,314** cells),
    `98-10-0466-01` (CD, 293-squared, **15,520**) and `98-10-0460-01` (CMA, 152-squared
    x mode x duration, **91,666**) all decode **strict-clean** through the ordinary
    positional path. The residence geography is a chunked schema'd DGUID table exactly
    like `98-10-0023`: **uid-only on the default path** (DGUIDs present, `geo_name`
    recovered via `read_ivt(geo_attributes = TRUE)`, verified all 5161 names +
    level/type in ~6 s); the small CMA table (152 <= 256) gets its full attribute table
    by default. The `Place of work` dimension carries the same CSD names as ordinary
    data-dim labels. **Fixed en route:** `metadata$geographies` packed an undecoded
    `geo_name` as an explicit `NULL` slot beside the length-`n`
    `member_id`/`geo_uid`/`has_data` columns, making the list **ragged** (it crashed
    `as_tibble()`/`as.data.frame()`); it now **omits** undecoded columns so the
    structure is always rectangular and coercible (`read-f2.R`). This latently affected
    every uid-only chunked table (`98-10-0023`, ...); cell counts and `ivt_tidy()`
    output are unchanged (`[["geo_name"]]` still returns `NULL` when absent).
- [x] **2016 CD/CMA flow (`98-400-X2016391`/`-X2016327`) — the THIRD encoding, now
  decoded** (2026-07-09). These store the flow as a **single geography dimension of
  combined `"origin / dest"` flow-pair labels** (neither the `0x0f` packed format nor
  the 2021 crosstab) — but, crucially, the codebook DOES carry the same dedicated
  `origincode/destcode` uid array as the `0x0f` tables, just with **shorter codes**
  (4-digit CDs, 3-digit CMAs/CAs) that the flow reader's `[0-9]{5,9}` regexes rejected.
  Two changes decode them:
  - **`0x0b` added to the u16 width-tag set** (`{10,0d,0a,0c,09,0f,0b}`): `327`'s CMA
    geography descriptor is type `0x0b` and the u8 read took the low byte, reporting
    **5** members instead of the u16 value `0x0577 = 1399` (framing `77 05 0b 01`),
    collapsing the decode to 312 cells; the fix gives **1,399** members / **89,122**
    cells. (`391`'s CD geography is type `0x0d`, already a u16 tag, so its count 4,199
    was right; only its labels were missing.)
  - **flow reader generalised to 3-9-digit codes** (`ivt_f2_geo_flow_dir()` /
    `ivt_f2_flow_sides()` `[0-9]{5,9}` → `[0-9]{3,9}`) and **tried before the plain
    inline reader** (`ivt_f2_geo_inline()`): the inline reader otherwise latched onto
    the single-side name array — 239 unique CDs on `391` — and returned the wrong
    member count. Now both decode with **100% geography coverage** — every residence +
    work name and code, EN + FR (`391`: 4,199 flows, 0 NA; `327`: 1,399, 0 NA). Loud
    `canivt_geo_flow` fallback (`strict_clean = FALSE`), added to the corpus ledger.
    Internal-consistency validated: `391` has exactly **293 self-flows** (residence CD
    = work CD = Canada's CD count), self-flow mean 37,572 ≫ cross-flow mean 725, and
    every `Total − (Male + Female)` gap is a multiple of 5 (StatCan base-5 random
    rounding). Flow member order **viewer-validated content-exact** for `391`/`327`
    alongside the other flow tables (2026-07-10, see the flow-metadata note above).

**Robustness: byte-exact records + a silent-truncation tripwire (2026-07-09).** The
handful of flow names lost in the first cut were a symptom, not a one-off: the reader
had been splitting a codebook block with the loose run-scanner
(`ivt_f2_dir_entry_records()`, `ivt_find_member_blocks`), which fragments/truncates
records in dense tail chunks. The flow reader now reads every block with the byte-exact
value-block parser (`ivt_f2_dir_entry_members()`) FIRST and only falls back to the
run-scanner when that returns NULL, fixing the truncation at the source (100% flow-name
coverage with no backfill needed; the `code -> name` backfill and the
`canivt_geo_flow_gap` check remain as belt-and-suspenders). And a general tripwire,
`ivt_f2_check_geo_names()`, runs on EVERY read: after the name-fills, a residual NA
`geo_name` means a codebook block was mis-parsed and a member dropped, so it raises
`canivt_geo_name_gap` (a `canivt_fallback`; a hard error under
`options(canivt.strict = TRUE)`). Every corpus table decodes a complete `geo_name`, so
it never fires on a clean read -- it is a regression/new-vintage tripwire for exactly
the silent metadata truncation the flow tail chunk exhibited (unit-tested in
`test-fallback.R`).

**The entire test corpus is now decoded — there are no remaining unsupported
files.** Reconnaissance (sub-format taxonomy, descriptor locations, per-file
blockers) is captured in [`unsupported-formats.md`](unsupported-formats.md).
The last three onboarded (2026-07-06): `97-570-X1981002` and `98-400-X2016019`
via the **inverted descriptor layout** (records before the signature block), and
`97F0015X` via the **count-anchored prose-bleed name recovery** (French
description text bleeds into and between the two name copies; the name is
recovered from the framing `(count)` suffix, geography from the longest
reoccurring prefix). Earlier: the `cro0172986_ct.7/8` custom crosstabs incl.
bilingual geography names; `ord-08035` via the relocated `@32` pointer; and
`97F0020X`, `97-563-XCB2006072`, `97-570-X1981004`, `98-400-X2016203` and the
1991 profiles `98F0172X`/`95F0170X` via the `@32` relocation, the b3 head-block
rule, the descriptor count reconciliation + geography-dimension index, the
`0x0a`/`0x09` u16 width tags, and the dense `0x0_` page variant respectively.

**Borealis-sourced corpus table (2026-07-06):** `97f0017xcb01004` (2001 census
topic-based tabulation, Geography(164) × Census Years(3) × Age(13) × Sex(3) ×
Highest level of schooling(12) × School Attendance(4), 662,564 cells, strict-
clean) is the first ledger table downloaded through the **Borealis Dataverse**
ingestion path (`borealis_ivt_catalogue()` / `borealis_ivt_download()`). It needs
no new decode work — it is the already-supported 2001 F-series family (cf.
`97F0020X`) — but is a Borealis-**only** product (not on the StatCan index), so it
exercises the fallback source end to end.

## [x] Header section-pointer table — DECODED and WIRED (`dimdir.R`)

The "variable section-pointer table" (~header bytes 690–1080) is decoded
(2026-07-01, confirmed on 98-10-0241, 98-10-0077, 98-10-0129, 98-10-0023 and
1003011) and is now the **primary anchor** for member labels, footnotes and the
geography block directory (`ivt_f2_dim_slots()` / `ivt_f2_dim_dir()` /
`ivt_f2_dim_dir_labels()` / `ivt_f2_dir_footnotes()` in `dimdir.R`; the marker /
tail-scan paths survive as fallbacks). Wiring validated byte-identical to the
previous output on all five local reference tables (labels, geographies,
footnote text sets), with the footnotes now **dimension-attributed** and the
small family-1 metadata ~5× faster (no tail scans). It is a **per-dimension
directory slot table**:

- **`@824 + 14·(k−1)`** holds a 14-byte record for descriptor dimension `k` (in
  descriptor order, geography = dim 1): `[u32 dir_ptr][u32 ?][u32 n_entries][2B]`.
  `dir_ptr` points at that dimension's **block directory** (the familiar
  `[u32 off][u16 len][u16 len]` entry shape), either directly or — for the big
  chunked geography directories (98-10-0023: 6,244 entries) — via a small struct
  whose first u32 is the directory (the two indirection depths
  `ivt_f2_geo_block_dir()` already implements). `n_entries` matches the decoded
  entry count (up to 2 null slots). The current `IVT_F2_DIR_SLOTS = c(824, 572,
  712)` guesses were accidental hits on this table (`@852` = dimension 3's slot).
- Each **dimension directory lists that dimension's complete codebook in logical
  order** with exact offsets/lengths: dictionary/schema block, member-id table,
  ordinal block, the `81 02 02 00` doubled-name marker block, then **row 6 = the
  EN member block, row 8 = the FR member block** (consistent across all 17 data
  dimensions of the three files; labels byte-identical to the marker-anchored
  reader), then **that dimension's footnotes** (EN/FR pairs, preceded by small
  member-reference records) — i.e. the footnote → dimension attribution the tail
  text-scan cannot provide. 98-10-0241's 20 footnote entries = the known 10 EN +
  10 FR, now attributed to Age/Household type/Period/Housing/Tenure.
- **The 1991 legacy file has the same table** (`@824` → 1,097-entry geography
  directory; `@838` Age; `@852` Sex). Its geography directory exposes, per group
  of `G` 256-member chunks (the same `1,1,2,4,…` group sizes as the modern chunked
  codebook), four attribute runs of `G` chunk blocks: the combined
  `"name (code) flag"` block (one run per language), a **separate clean name
  array** (accent-stripped search names — `Malpeque`, not the display `Malpèque`)
  and a **bare-GEOUID code array**, interleaved with framing, per-4-chunk index
  blocks (1024 records) and ordinal delimiters. **`ivt_f2_geo_inline_dir()` now
  reads these runs positionally** (record-count-validated per chunk; uid = the
  code array when one exists, cross-checked against the combined block's parsed
  code; name/flag from the combined block, which keeps the accents): the
  byte-ascending scan + first-appearance dedup path had silently **misordered the
  last 2,435 members' names and uids** (the tail chunks are stored out of byte
  order) — the positional read matches the StatCan Beyond 20/20 viewer's member
  list **41,859/41,859** (names and codes). The same reader covers the 2006 / 2011
  / 2016 vintages (run rosters differ — see the schema-absent stage above), each
  viewer-validated. The regex scan survives only as the fallback for layouts whose
  directory does not resolve.
- **`@712` — the data-quality-flag legend directory: DECODED and WIRED**
  (`ivt_f2_dqf_legend()`, dimdir.R). 15 entries on every 2021 table: a u32 index
  entry, then 14 legend records framed `[82 01][u16][flags][02][code char][00]
  [u16 text_len][text]` (FR records carry an extra flag dword; `text_len` counts
  a trailing NUL the entry length may drop), in EN/FR pairs per code — A…E
  quality classes, R Revised, P Preliminary, language per pair by
  `ivt_f2_frscore()`. Exposed as `dqf_legend` on `ivt_metadata()`
  (tibble `code/text_en/text_fr`); the pre-DGUID tables carry a 1-entry 6-byte
  stub → NULL. A symbol legend directory ("Not available for a specific
  reference period", …) sits nearby (reference slot not yet identified).
- **`@544` → the master directory at offset 992: DECODED and WIRED**
  (`ivt_f2_master_dir()`; also reachable via `@992`/`@1000` and `@12` with one
  indirection). Its ~10 entries cover the whole file in a stable order: the
  FACET04 + EN title block, the dimension descriptor (the same block `@32`
  points at, 14 framing bytes earlier), a 15-byte EOF trailer, the **EN
  identity/notes blob** (modern: the inline `Product ID: … Title: …` text;
  legacy/2016: the out-of-line title + notes blob the header EN title pointer
  `@48` also addresses), the product-id string, small framing blocks, then the
  FACET04 + FR title and the FR blob. `ivt_f2_legacy_footnotes()` now bounds the
  legacy "(N) …" notes parse to exactly the EN blob entry (matched to the `@48`
  pointer; the 200 KB tail window survives as fallback).

## [ ] Unknown / possibly not in the binary

- [x] **Footnote → table / dimension / member linkage — DECODED and SURFACED**
  (2026-07-09). Every footnote now carries a `scope` (`"table"` / `"dimension"` /
  `"member"`), the owning `dimension`, and a `member_id` for member notes, exactly
  matching the three-tier scope in StatCan's own WDS footnote links
  (`dimensionPositionId` 0 = table, `memberId` 0 = dimension). Geography is a
  dimension here too. The three scopes are stored differently and each is read
  structurally:
  - **Member notes**: each dimension's footnote region in its slot directory opens
    with a `84 01`-framed **member bitmap** (an EN copy and an identical FR copy) —
    a dense record listing which members carry a note, read with the presence
    convention (byte-pair-swapped, MSB-first). `ivt_f2_footnote_bitmap()` decodes it
    to 1-based member positions; the footnote text entries then follow in that same
    order, so the first `popcount(bitmap)` per language are member notes (assigned to
    the bitmapped members in order) and the rest are dimension notes. (The "small
    records preceding each footnote pair" from the earlier note ARE this bitmap; the
    trailing int32s are block-index framing.)
  - **Dimension notes**: the remaining footnote entries in the dimension directory
    (`memberId 0`). One directory entry = one scope-target; where StatCan splits a
    target's note into several Note IDs the IVT stores them concatenated in that one
    entry (sometimes with an internal `Footnote 2` marker, sometimes merged), so the
    IVT's granularity is one text per target — the scope/member attribution is exact,
    the per-Note-ID split is not always recoverable.
  - **Table notes**: stored in the master-directory identity blob (with the product
    id / title), framed `Footnote N` / `Renvoi N` mid-blob; `ivt_f2_table_footnotes()`
    finds them by the numbered marker (ignoring the bare `Footnotes :` section header
    that empty-note tables still carry).

  Validated **exact against StatCan WDS** on 98-10-0241 (10 targets: 6 member incl.
  the non-Total member 13 / member 5, 4 dimension), 98-10-0077 (9 targets incl. a
  table-level note and dim-2 member notes on members 1/7/8), 98-10-0023 and
  98-10-0129 (member notes on Men+/Women+, two dimension notes each) — every
  (dimension, member) target matches. `ivt_f2_dir_footnotes()` (dimdir.R) does the
  member/dimension split, `ivt_f2_table_footnotes()` (dimdir.R) the table notes,
  `ivt_f2_footnotes()` (read-f2.R) combines + renumbers them, and
  `ivt_write_metadata()` writes `scope`/`dimension`/`member_id`/`member_refs` to
  footnotes.csv.
- [x] **Legacy `(N)` footnote → member linkage — DECODED and SURFACED**
  (2026-07-09). The pre-DGUID profiles (1991 `98F0172X`/`95F0170X`; the same
  mechanism would apply to any inline-codebook table) store footnotes as a
  table-wide numbered `(N) text` list, and a member **cites** a note by embedding
  its number as a `(N)` marker in its own label — the pre-DGUID analogue of the
  modern member bitmap (Beyond 20/20 renders it as the superscript link). E.g.
  `"1307 Other non-university - With certificate (19) (20)"` cites notes 19 & 20;
  `"2604 Average value of dwelling (26) $"` cites 26 before a unit suffix.
  `ivt_f2_note_refs()` (read-f2.R) parses these — **only** numeric parens whose
  value is a valid footnote number (1..n_notes), so the leading profile line number
  (unparenthesised) and text parentheticals like `(non-institutional)` are ignored,
  and a modern table (no numeric-paren labels) yields nothing. `ivt_f2_attach_legacy_refs()`
  turns each cited note into `scope = "member"` with `dimension` (the citing
  dimension) and `member_refs` (**all** citing member ids — a legacy note is
  one-to-many: `98F0172X`'s note 2 "knowledge of non-official languages" is cited by
  30 members; `member_id` is set only when a single member cites it); notes no member
  cites stay `scope = "table"`. It is **quiet** (not a fallback): the `(N)` marker is
  the file's own reference notation and the read self-validates (every ref resolves to
  an existing note), like the quiet indentation-derived `parent_id`/`depth`. Validated
  on `98F0172X`/`95F0170X` (39 notes each, 131 refs, `member_refs` byte-identical to an
  independent label scan; semantically coherent — note 2 → the 30 non-official-language
  rows, note 21 "Postsecondary" → the two postsecondary-qualification members) and
  `1003011` (a crosstab whose 40 notes are cited by no member → all `scope = "table"`).
- [x] **Member hierarchy as a structured tree** — DONE (2026-07-06). The
  leading-space indentation of the member labels (preserved verbatim) is parsed
  into both `depth` (already exposed) and now `parent_id` — the `member_id` of
  each member's parent, i.e. the nearest preceding member at a strictly smaller
  depth (robust to depth skips like 0→2; `NA` for top-level members).
  `ivt_label_parent()` (write.R) turns the flat depth sequence into the tree;
  `parent_id` rides on `ivt_members()`, the `_members.parquet` sidecar and the
  `dimension_members.csv` metadata export, for both families (the geography
  columns and every data dimension). Validated on 97F0015X's income groups
  (the `$X–$Y` brackets roll up to "With income" → "Total - Income groups";
  "Median income $" is a separate top-level statistic).

## [x] Geography read consolidated — recover-then-specialize (2026-07-17)

The geography read (the most diffuse part of the parser — six layout readers reached
through two fallthrough ladders, each re-walking the geo slot directory) is now one
path (refactor-plan.md §7). A shared Stage 1 `ivt_f2_geo_entries()` locates the geo
block directory ONCE and exposes lazy, memoized per-entry accessors that all six
readers consume; a single dispatcher `ivt_f2_geo_read(raw, full)` runs the ordered
specializer chain that both `ivt_f2_geo_light()` (metadata default) and
`ivt_f2_geographies()` (`geo_attributes = TRUE`) share as thin wrappers, `full`
selecting only the schema step. Sharing the custom/bare specializers across both
paths fixed a latent bug — the full path used to return an all-NA tibble for
custom/bare tables. A new Stage 3 `ivt_f2_geo_combined()` (`canivt_geo_unparsed`,
loud) is the last-resort verbatim safety net for an unrecognized layout. The whole
read is snapshot-guarded (`tests/testthat/fixtures/geo-snapshot.csv` — light for
every corpus table, full for 23, incl. 98-10-0013 / 98100019 (FSA) / 98100010
(FED), all of which read cleanly through the directory path once the tail footnote
text blocks are skipped (`ivt_f2_dir_is_text_block()`); opt-in
`test-geo-snapshot.R`). Geography output byte-identical across the corpus.

The two custom exports that were briefly nameless (EO3278_T1_CDCSD, EO2654_2011_Van)
now decode geography in full (2026-07-17) — see the Stage 3 upgrade below.

## [x] Stage 3 assemble-then-decipher — the schema-less geography net (2026-07-17)

Following the owner directive — locate the geography metadata like any other
dimension, recover each item positionally, THEN decipher the components, and only
as a last resort surface the whole member as a string — Stage 3
(`ivt_f2_geo_combined()`) was upgraded from a single-block verbatim reader to a full
schema-free reader, closing the last two geo-name gaps:
- **`ivt_f2_geo_assemble_runs()`** reconstructs the codebook's parallel member arrays
  into full member-length runs using the SAME power-of-two group/chunk geometry the
  schema'd `ivt_f2_geo_attrs_dir()` uses, but inferring the run count from the block
  count (`k / total_chunks`) instead of a schema.
- **Column identity is METADATA-DRIVEN where the file declares it.** These exports
  carry a `81 02` field dictionary in the geography directory — the SAME
  "Code / English Desc / Desc Français / Geo Code / DQ / Level/Niveau / UID/IDU"
  vocabulary a data-dimension dictionary uses (`ivt_f2_geo_field_schema()`), not the
  modern DGUID attribute schema `ivt_f2_geo_schema()` looks for. When its named
  columns match the assembled runs one-to-one, the run → column mapping is read from
  the file's OWN field names (`ivt_f2_geo_field_roles()`): `geo_name` = the English
  description field, `geo_name_fr` = the French one, `geo_uid` = the field the file
  literally NAMES `UID/IDU`. No content guessing.
- The **content heuristic is the FALLBACK** (only when there is no matching field
  dictionary): display name = the most human-readable non-uid run (spaces / lower-case,
  or the first non-uid run when every member is a bare code; EN/FR pair when two runs
  are wordy); uid = a fully-unique, space-free, digit-bearing code run. If no run reads
  as a name, every run is joined per member into one verbatim string (the true last
  resort).
- **[x] EO3278_T1_CDCSD** — attribute-major chunked codebook (groups 1,1,2,4,8…) with
  a `Code/English Desc/…/UID/IDU` field dictionary: read SCHEMA-DRIVEN, 5,146/5,146
  names (EN + FR) + the file's declared `UID/IDU` uids (SGC codes `10` / `1001` /
  `1008001`). (The earlier heuristic had mis-picked the `Geo Code` column, `PR10` /
  `CSD1001105`, as the uid — the field dictionary corrects it.)
- **[~] EO2654_2011_Van** — geography is descriptor dimension 2, named "Geography"
  in the header but with no decodable signature, so `ivt_f2_geo_dim_index()` gained a
  header-NAME fallback (`canivt_geo_by_name`); its slot directory over-declares its
  entry count (109 vs 92 real), so `ivt_f2_geo_block_dir()` gained a geography-scoped
  short-directory acceptance (`canivt_geo_dir_short`, validated downstream by
  `ivt_f2_check_geo_count()`): 3,433/3,433 names + `CU…` uids. Its field dictionary
  declares 5 columns but only 4 are stored (one field is empty/absent), so the
  run → column map is NOT 1-to-1 and it falls to the content HEURISTIC — the one
  remaining table whose geography column identity is a guess, not read from the
  schema. (Resolving which field is unstored would make it schema-driven too.)

All loud (`canivt_geo_unparsed` etc., strict-mode errors) — the split is heuristic,
not a validated positional parse. Both tables' cell counts are unchanged (geography
identity feeds only the slug / metadata, never the positional cell decode).

## Summary

For the **reference tables** (family 1: 98-10-0241; 3-dim family 2: 98-10-0023;
legacy: 1003011), ~100 % of information-bearing bytes are identified and the data
plus all geography/dimension/footnote metadata decode exactly, in **both
languages** (English + French member labels, dimension names, geography
names/labels, footnotes, DQF legend and title). The bit-level gaps
there, by size: (1) a few small header/marker bytes with inferred/unknown
semantics and the dense value arrays' **bitstream per-member coding** (their
values decode fully via the plain siblings' NA pattern). Footnote↔scope linkage
(table / dimension / member) is now decoded and WDS-validated on the modern tables,
and the legacy `(N)`-superscript → member linkage on the pre-DGUID profiles is
decoded too; the master directory at 992 and the `@712` DQF legend are read (see the
header section-pointer table above). Footnote scope is now complete across the corpus.

The unified decoder handles **arbitrary-dimension** tables (validated on the
4-dim 98-10-0129, cell-exact) and spans **1991–2021 census vintages**: the 1996
tables 94F0009XDB96078 / 95F0250XDB96001 / 95F0223XDB96001 /
95F0200XDB96003 (13 → 43,234 geographies, all B2020-viewer-validated), the tiny
one-page 98-10-0044 (the trivial geography-straddle, StatCan-CSV-exact),
98-10-0013 (whose cell decode had been silently empty; now CSV-exact — the
source of the b2 trailer formula and the `@558` pointer unwrap), the **2006 DA
crosstab 97-563-XCB2006072** (2026-07-03: the b3 head-block rule + suppression
tails; viewer-validated cell-exact) and, as of 2026-07-04, the **1981 profile
97-570-X1981004** (geography stored LAST, resolved by descriptor count
reconciliation + `ivt_f2_geo_dim_index()` — the "geography-last" nesting turned
out to be the ordinary layout with a 1-member outermost placeholder) and
**98-400-X2016203** (the `0x0a` u16 count width tag: 825 Selected
characteristics, chunked EN/FR labels; viewer-validated cell-exact), and the
**1991 profiles 98F0172X / 95F0170X** (the dense `0x0_` page variant — one
value per grid position, zeros literal; both viewer-validated cell-exact),
and the **2001 F-series crosstab 97F0020XCB2001070** (the `0x09` u16 count
width tag: Selected characteristics is 282 members, not 1 — the same fix also
repaired a silent mis-decode of 98-10-0174's Mother tongue(331);
viewer- and CSV-validated cell-exact respectively).
The **inverted descriptor layout** (records before the `81 01 20 00 f0`
signature block, anchored on the preceding `81 02 03 00` sub-header) onboarded
the 1981 CMA/CA profile **97-570-X1981002** and the tiny 2016
collective-dwellings crosstab **98-400-X2016019** (both viewer-validated
cell-exact, 2026-07-06), and the **count-anchored prose-bleed name recovery**
onboarded the last file, the 2001 F-series **97F0015X** — so **every `.ivt`
file in the test corpus now decodes**. See the section above.

Coverage-broadening additions (2026-07-18, decoded with no code change):
the 2021 "Population and dwelling counts" tables **98100019** (Canada + forward
sortation areas -- postal geography, alphanumeric `A0A` GEOUIDs, a code shape no
other corpus table carries) and **98100010** (Canada + federal electoral
districts) extend the corpus to two geographic levels it lacked, both family-2
strict-clean on the DEFAULT (uid-only light) path. Their FULL attribute read
(`geo_attributes = TRUE`) was initially a gap and is now **complete** (2026-07-18):
the read was not irregular after all -- the geography block directory carries
per-member FOOTNOTE TEXT blocks in its tail (one "Renvoi 1 / Ne comprend pas les
données du recensement pour ..." per member that cites the note -- FSA one, FED
37) that the run-scanner fragmented and the block classifier miscounted as
attribute value blocks, so the regular-layout gate `k == 2*(nfield+1)*n_chunks`
tripped (FSA 183 vs 182, FED 73 vs 36) and forced the lossy stride-walk. A text
block reuses the plain-array header `[01 01][u16 len-4]` but its payload is a lone
un-terminated latin1 text `[01]<text>` with NO NUL record terminators, so
`ivt_f2_dir_is_text_block()` now recognizes and skips it structurally; the
directory-driven `ivt_f2_geo_attrs_dir()` then reads all members (FSA 1647/1647,
FED 352/352 -- every attribute, DGUID, province, dqf), and the geo-snapshot guards
the full path. And the
Borealis **95f0491xcb01004** (2001 Census Profile of CMAs,
`Values x Profile(69) x Geography(150)`) extends the profile lineage from 1991
up to 2001 (a known `canivt_descriptor_lenient` fallback -> `strict_clean =
FALSE`; its `product_id`/`title` decode NA, a minor identity gap).

Not yet decodable -- the frontier the Borealis catalogue surfaces (2026-07-18):
whole non-census lineages remain unsupported, notably the rest of the
**`02 00 20 00` split-definition survey generation** (Census of Agriculture 1996
`EDDTAB39` + Small Area Business 1996 `EMPLOY1` -- the Health Statistics 1999
sibling `00060104` is now SUPPORTED, see above; these two share the container but
arrange their descriptors differently and still need onboarding), the **2006
Profile Series**
(94-575-/94-576-XCB2006*, valid `04`-family + 3-dim descriptor but
pre-flight-rejected), the **Labour Force Historical Review** (descriptor does
not parse), **Uniform Crime Reporting** and the **2016 Census of Agriculture**
(both `04`-family, descriptor parses, pre-flight-rejected). These are the
highest-value targets for the next parser-coverage pass.
