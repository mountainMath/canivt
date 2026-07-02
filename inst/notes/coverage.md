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
- [~] Per-chunk **member-ordinal arrays** (`1..n`) — used only as anchors.
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
  single-census tables) is tolerated. Validated exact on member counts: **1991** 41,859
  (byte-identical to the former whole-file scan), **2006 (97-563-XCB2006072)** 57,523
  dissemination areas, **2011 (98-312-XCB2011033)** 5,447 census tracts, **2016
  (98-400-X2016387)** 174 (single-block; its uid was previously empty — no DGUID array,
  and the content detector could not recover the bare-code uid). The geography count is
  read from the descriptor with the per-type width tag (`0x10`/`0x0d` → u16; 2011's `0x0d`
  was misread as u8 = 21 before). `ivt_f2_geo_light()` resolves every family through one
  marker-anchored entry: **combined-block reader** (schema-absent) → **schema/content
  single-block** (2021 small) → **DGUID scan** (2021 chunked). 1991's default tidy now
  labels geography by name + GEOUID (was member-id only).
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
  segmenter. `DQF_NOTE`'s long suppression text still does not map cleanly to member
  boundaries, so it keeps the `ivt_f2_derive_text()` majority-vote from `DQF_CODE` (the
  same post-step the stride path used) — **every other attribute is exact by position.**
  The "variable-span DQF_NOTE / content-located TNR" blocker is gone: the block *count*
  is perfectly regular (`5,952 = 24·248` value blocks on 0023), so the positional
  partition never desyncs.
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
    irregular block count → stride path with the `ivt_f2_geo_root_dir()` root override).
  - **Residual (unchanged, pre-existing):** on 0478 the last group's two code-valued
    attributes (`geo_name`, `alt_geo_code`) lose their trailing 153-member partial — the
    block scanner fragments that code chunk (and a data-page fragment sits in its
    directory slot); the display label and every other attribute are complete. Same
    root as the block-finder-fidelity nicety noted for the big-group long text.
- [ ] The **2048-bit presence cap is assumed constant** (all six tables use it). A
  float64 table or a no-straddle table would confirm / refine it.

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
  crosstabs. `inline_geo` header flag varies; descriptor layout differs;
  `97F0020X` has no locatable page directory. Served by StatCan's legacy `www12`
  dynamic system, not the modern b2020 endpoint.
- [ ] **1981 census** (`97-570-X1981002`): older still; descriptor undecoded.
- [ ] **Custom CT / "cro"/"ord" extracts** (`cro0172986_ct.*-2006-*`,
  `ord-08035-…_ct.1-2021-population`): Beyond 20/20 desktop exports (not StatCan
  table downloads); single-page-ish directories, descriptor undecoded.

Decoding any of these is future work — each likely needs its descriptor/codebook
layout reverse-engineered. Reconnaissance (sub-format taxonomy, descriptor
locations, which share the family-2 value container) is captured in
[`unsupported-formats.md`](unsupported-formats.md). Summary: they fall into ≥3
sub-formats — a near-family-2 crosstab (`ord-08035`, `97F0020X`; `ord-08035`
reuses the 98-10-0023 value container exactly and is the recommended first
target), profile tables with a `"Values"` dimension (`98F0172X`, `95F0170X`; int
container we already decode), and older layouts whose container is not yet located
(`97F0015X`, 1981 `97-570-X`).

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
  directory; `@838` Age; `@852` Sex). Its geography directory exposes, per
  256-member chunk, the combined `"name (code) flag"` block (EN row, FR row) plus
  **separate clean bilingual-name and bare-GEOUID array blocks** — so the inline
  regex parse (`IVT_F2_INLINE_PAT`) and the first-appearance code dedup can be
  replaced by positional reads with deterministic member ids.
- **`@712`** points at the data-quality-flag legend directory (`A…E/R/P` texts, EN
  + FR); a symbol legend directory ("Not available for a specific reference
  period", …) sits nearby (reference slot not yet identified). **`@992`/`@1000`**
  point into a ~10-entry **master directory at offset 992** (also reachable via
  `@544`, and `@12` with one indirection) whose entries cover the whole file:
  the FACET04 title blocks, the dimension descriptor, the inline identity text,
  EN/FR title/notes blobs (the legacy 1003011's out-of-line title + footnote
  blocks are entries here), and an EOF trailer.

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
just not surfaced); (2) the **master directory at 992 / DQF-legend slots**
(decoded but not read from — the per-dimension section-pointer table itself is
now wired, see above); (3) a few small header/marker bytes with inferred/unknown
semantics; plus the footnote↔*member* linkage (dimension linkage is decoded) and
structured member hierarchy that may be absent from the binary.

The family-2 decoder now handles **arbitrary-dimension** tables (validated on the
4-dim 98-10-0129, cell-exact) in addition to the 3-dim and legacy tables. The
remaining open item is the **2001/2006 "F"-series** products (97F0015X, 98F0172X),
not yet decoded — possibly an older B2020 variant; see the section above.
