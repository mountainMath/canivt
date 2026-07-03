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
- [x] Dimension member labels (Age/Gender/Sex), counts, type markers.
- [x] Footnote text (modern framed `Footnote N`/`Renvoi N`; legacy `(N) text`).
- [x] Header layout pointers (`ivt_f2_header_layout()`); format/version indicator.

## [~] Read but not surfaced (recoverable, just not exposed)

The codebook scan finds 5,942 member-array blocks; we extract the English/first
copy of each attribute and parse past the rest.

- [~] **French copies of every label** — names, levels, types, footnotes, and the
  Age/Gender member labels (~half the codebook volume). Discarded (EN-only).
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
- [?] Page-marker bytes `b2` (`0x20`/`0x41`/`0x03`) and `b3` (`08`/`09`); only the
  value-width low nibble of `b0` is understood.
- [x] The marker-specific pad/`0xFF` **trailer length** is now tabulated per
  marker (`IVT_F2_PAGE_TRAILER`: 4/10/34/18/8/16) and the value-run start derived
  as `4 + presence_len + trailer`. Still *positional* (we do not know why each
  marker has its particular trailer), but no longer a decode gap.

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
  The legacy `ivt_geography_count()` (stride at `0x1000`) returns **348** here only
  as an artefact — 98-10-0077's real per-geography directory stride is `0x2000`,
  and striding it at `0x1000` lands on every other geography's mid-block, doubling
  the count. It is no longer used for decoding (only the family-1 detection gate).

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
  Brook`). Falls back to `ivt_geo_arrays()` for tables whose attribute arrays aren't
  clean `n_geo`-blocks (0662).
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
  (`ivt_f2_read_block_dir()`) and confirms the block by its `GEO_NAME_EN` field name,
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
  - **Fallback still runs on 98-10-0013 ADA** (its directory drops a trailing partial →
    irregular block count → stride path with the `ivt_f2_geo_root_dir()` root override);
    all its attributes validate exact vs the StatCan metadata CSV.
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
  - **DQF_NOTE is now positional-exact**: 63,404/63,404 on 98-10-0023 (was ~99.8%
    via the majority vote), 91/91 on 0662. The `ivt_f2_derive_text()` vote now only
    fills slots whose block the strict parse could not decode. The only residual is
    the **container's own 252-byte record cap** (`0xFC` max length byte): notes
    longer than 252 chars are stored truncated in the file (2,448 members on
    98-10-0129, 90 on 0478) — byte-faithful, not a decode gap.
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
  `2*(b2 >> 4) + 2*(low nibble(b2) > 0)`, plus a fixed 32-byte auxiliary block
  on `0xa2` int16 pages. Derived from 98-10-0013 (22 pages, 18 distinct b2
  values, trailers 6–14, each anchored byte-exact vs the StatCan CSV); it
  reproduces the formerly hard-coded six-marker constants, which had made the
  trailer look like a per-width constant (`32/width` / `64/width + 2`) only
  because b2 never varied within a marker family before 0013. Unknown width
  codes / high nibbles abort (`canivt_unknown_marker`);
- the **extent check**: the directory entry's u16 size is the page's allocated
  length and `4 + presence + trailer + nv*width <= size` always (with equality
  on the `b2 == 0` pages); an overrun aborts (`canivt_page_overrun`);
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

- **97F0020XCB2001070** (2001 F-series): layout resolves and its pages fit
  their directory sizes exactly, but they carry 1124 presence bits against a
  448-real-cell capacity — the data is nested differently. Capacity rule.
- **97-570-X1981004** (1981 profile): parses into a geography-first layout
  whose directory covers only outer member 1 of 32 — the data is nested
  geography-LAST (the profile-table variant). Span rule.
- **98-400-X2016203**: non-exact `b2 == 0` pages (exactness holds on every
  validated table) plus **369 undecoded `a2 01 03 0a` pages** (`b3 = 0x0a`;
  int16 values all `-1`, presumably suppression sentinels). A direct
  `ivt_decode()` still runs with a loud `canivt_skipped_pages` warning, but the
  file is unsupported: its cells were never ground-truthed and its metadata
  needs two heuristic fallbacks. To revisit: validate a `0x0a` page against a
  B2020 viewer slice. Note 2016203 is the odd one out, not the 2016 norm: the
  large crosstabs 98-400-X2016328 (5-dim, 4,868 geos), 98-400-X2016261
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

## [ ] Other Beyond 20/20 products that share the signature but are undecoded

Several other `.ivt` products share the `04 00 20 00` signature and even expose a
page-directory-like structure, but their **header descriptor is a different,
undecoded layout**: `ivt_f2_descriptor()` reads a garbage dimension count
(hundreds/thousands) and recovers zero data dimensions. They are now **detected as
unsupported** (`ivt_family()` returns `NA`, `ivt_is_supported()` is `FALSE`) and
`read_ivt()`/`ivt_metadata()` abort with a clear message — previously they passed
the loose family-2 gate and crashed the decoder with `argument of length 0`. The
fix is the `ivt_f2_decodable()` check (plausible `n_dim`, ≥1 sized data dimension).
Regression-guarded in `tests/testthat/test-formats.R`.

Files in the test corpus that are currently unsupported:

- [~] **Profile tables** (`98F0172X`, `95F0170X`): **structure largely cracked, not
  yet wired.** 2-D Geography × Values; value order **characteristic-major,
  geography-minor**. For 98F0172X: 4,063 geographies decode exactly today
  (`ivt_f2_geo_inline()`); values confirmed exact vs the HTML profile-viewer ground
  truth (St. John's char 101 = 171,859); the **full page directory** is located
  (header `u16@558`=1936, 1,046 contiguous records tiling 100 % of the value
  region). Pages are a **hybrid**: dense `0x0_` (`[b0][01][count]`+values) and
  sparse `0x8_` (presence-bitmap + values + trailer, the container we already
  decode). Open: the grid is **non-rectangular** (Σcount=2,222,304 not a multiple of
  4063/529) — likely geography-level-dependent characteristic sets — plus the
  Values count/order from the type-`0x01` descriptor. See `unsupported-formats.md` §2.
- [ ] **Other "F"-series** (`97F0015XCB2001041`, `97F0020XCB2001070`): 2001-era
  crosstabs. `inline_geo` header flag varies; descriptor layout differs.
  `97F0020X`'s page directory **is** locatable after the entry-floor fix (header
  `@558` = 18589; entries in *reverse* offset order, `84 01 00 08` pages of size
  4756 that fit **exactly** under the b2-trailer arithmetic) — but its pages
  carry 1124 presence bits against the layout's 448-real-cell capacity, so the
  data is nested differently and the pre-flight **capacity rule** rejects it.
  Served by StatCan's legacy `www12` dynamic system, not the modern b2020
  endpoint.
- [ ] **2006 census DA crosstab** (`97-563-XCB2006072`): geography fully
  validated (57,523 members, positional inline reader) but its **page directory
  has not been located** — no `@558` unwrap candidate validates, so the file
  stays unsupported. Open: find where this vintage stores its directory pointer
  (or whether its directory starts with entry shapes the validator rejects).
- [ ] **1981 census** (`97-570-X1981002` profile, descriptor undecoded;
  `97-570-X1981004` parses — Values(32) × Profile(79) × Geography(5989),
  geography stored LAST — but its directory covers only the first outer member
  under the geography-first layout, so the pre-flight **span rule** rejects it;
  decoding this lineage means supporting geography-last nesting, i.e. the
  profile-table variant).
- [ ] **Custom CT / "cro"/"ord" extracts** (`cro0172986_ct.*-2006-*`,
  `ord-08035-…_ct.1-2021-population`): Beyond 20/20 desktop exports (not StatCan
  table downloads); single-page-ish directories, descriptor undecoded.

Decoding any of these is future work — each likely needs its descriptor/codebook
layout reverse-engineered. Reconnaissance (sub-format taxonomy, descriptor
locations, per-file blockers) is captured in
[`unsupported-formats.md`](unsupported-formats.md). Summary: near-family-2
crosstabs (`ord-08035` — its page body turned out NOT to be the 98-10-0023
container and needs re-RE'ing; `97F0020X` — container located, presence nesting
differs), profile tables with a `"Values"` dimension (`98F0172X`, `95F0170X`,
plus the geography-last `97-570-X1981004`; hybrid page set decoded, the
non-rectangular page→grid mapping is the open item), the 2006 crosstab
`97-563-XCB2006072` (directory hunt), and older layouts whose container is not
yet located (`97F0015X`, 1981 `97-570-X1981002`). The most tractable targets:
the 2006 directory hunt and the profile grid mapping.

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

- [~] **Footnote → member/dimension linkage.** The metadata CSV carries per-member
  Note IDs. Footnote → *dimension* linkage IS stored and is now decoded: each
  footnote is an entry of its owning dimension's slot directory (see the header
  section-pointer table above), and `ivt_f2_footnotes()` emits it as a
  `dimension` field on every footnote. Per-*member* linkage remains open: the
  small records preceding each footnote pair in the directory look like member
  references (plausible, unverified). (The inline `01 01 … 00 01` markers we
  investigated earlier are block framing, not note references.)
- [ ] **Member hierarchy as a structured tree** for family 2. Encoded via leading-
  space indentation in the labels (preserved verbatim) but not parsed into
  parent/child. Family 1 exposes `ivt_label_depth()`; family 2 does not yet.

## Summary

For the **reference tables** (family 1: 98-10-0241; 3-dim family 2: 98-10-0023;
legacy: 1003011), ~100 % of information-bearing bytes are identified and the data
plus all geography/dimension/footnote metadata decode exactly. The bit-level gaps
there, by size: (1) the **French label copies** (~half the codebook, recoverable,
just not surfaced); (2) a few small header/marker bytes with inferred/unknown
semantics and the dense value arrays' **bitstream per-member coding** (their
values decode fully via the plain siblings' NA pattern); plus the
footnote↔*member* linkage (dimension linkage is decoded) and structured member
hierarchy that may be absent from the binary. The master directory at 992 and
the `@712` DQF legend are now read (see the header section-pointer table above).

The unified decoder handles **arbitrary-dimension** tables (validated on the
4-dim 98-10-0129, cell-exact) and, as of 2026-07-02, spans **1991–2021 census
vintages**: the 1996 tables 94F0009XDB96078 / 95F0250XDB96001 / 95F0223XDB96001 /
95F0200XDB96003 (13 → 43,234 geographies, all B2020-viewer-validated), the tiny
one-page 98-10-0044 (the trivial geography-straddle, StatCan-CSV-exact) and
98-10-0013 (whose cell decode had been silently empty; now CSV-exact — the
source of the b2 trailer formula and the `@558` pointer unwrap). Remaining open
items: the **2006 crosstab 97-563-XCB2006072** (geography validated, page
directory not located), the **profile-table lineage** (98F0172X, 95F0170X, 1981
`97-570-X`: geography-last / `Values`-dimension layout) and the other 2001
"F"-series products; see the section above.
