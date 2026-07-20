# canivt decode history

The blow-by-blow record of how each table / vintage was cracked and how each
decoding gap was closed. This is the **narrative changelog** — moved out of
`CLAUDE.md` to keep that file a lean working guide. For the *current* state see:

- [`CLAUDE.md`](../../CLAUDE.md) — the working guide (code map, key invariants, workflow).
- [`coverage.md`](coverage.md) — the **living** completeness tracker (what we decode
  vs what's left, with measured byte coverage). Update it, not this file, when a
  gap is closed or found.
- [`ivt-format.md`](ivt-format.md) — the authoritative byte-format reference.

Nothing here is required to work on the package day-to-day; it is kept as the
provenance of the invariants and the validation record per table.

## Per-table support — how each was cracked

Every `.ivt` in the corpus decodes; there are no unsupported files. Validated
**cell-exact (byte-identical to the two former decoders)** on the six reference
tables, and viewer/CSV-validated on the wider corpus:

- **98-10-0241** (7-dim, Period straddles): 166 geos, 7,489,464 cells, exact vs CSV.
  The reference table; whole-file pure-R decode runs in ~4–5 s.
- **98-10-0077** (7-dim incl. a reference-period Year, Ages straddles): all 174
  geographies, ~37M cells, exact vs CSV.
- **98-10-0662** (5-dim, Health straddles; small file, mixed int16/int32 pages,
  0x80 per-geo stride): all 91 geographies, exact vs CSV. Was silently misdecoded
  before the unification — it had been misrouted to the family-2 decoder.
- **98-10-0023** (3-dim Age×Gender, **geography straddles** → 4 geos/page): all
  63,404 geographies. **98-10-0129** (4-dim, geography straddles → 2 geos/page):
  all 15,685,859 cells incl. the `0xa4` int32 marker. **1991** `1003011` (3-dim,
  geography straddles → 4 geos/page; int16/int32 pages): 330/330 exact.
- **98-10-0013** (ADA, 5,447 geos): its directory sits past 64 KiB — under the
  plain u16 `@558` read its cell decode was silently EMPTY; with the pointer
  unwrap all 22 pages (18 distinct marker b2 values) decode, **37,587/37,587
  cells exact vs the StatCan CSV** (the b2 trailer formula's source). **98-10-0044**
  (tiny 3-dim collective-dwellings table): the whole table fits one presence
  record (the trivial geography-straddle), **448/448 exact vs the StatCan CSV**.
- **1996 census** (pre-DGUID, B2020-viewer-validated): **94F0009XDB96078** (13
  geos, 5 dims, Years(2) facet) 572/572 across all geographies;
  **95F0250XDB96001** (5,544 CSD-level geos; a digit-led dimension name the old
  descriptor anchor dropped) 72/72; **95F0223XDB96001** (5,007 geos, duplicate
  member labels) 1,134/1,134; **95F0200XDB96003** (43,234 enumeration areas)
  200/200.
- **Large 2016 `98-400-X` crosstabs** in the supported container, needing zero
  code changes: **98-400-X2016328** (18.7 MB, 5-dim, 4,868 geos) 360/360 vs the
  viewer plus **1,680/1,680 on deep-tail geographies** (member positions
  3000+/4860+, pinning member order); **98-400-X2016261** (86.8 MB, 6-dim,
  14.4M cells) 154/154; **98-400-X2016120** (income statistics, all-float64
  pages, geo-straddle 4/page) 510/510 leading + 1,432/1,432 deep-tail numeric
  cells. **Suppression is WHOLE-GEOGRAPHY, exposed via presence + the codebook
  flag**: within a geography that carries any stored cell, an absent cell is a
  true zero; a geography with NO stored cells is wholly suppressed (or wholly
  empty). `read_ivt()` exposes `metadata$geographies$has_data` (presence-
  derived) and, on the inline pre-DGUID tables, `dqf_code` (the per-geography
  flag): on 2016120 the flag's **last digit = 9 exactly for the 888
  geographies with no stored cells** (888/888, zero crossovers), and the
  viewer renders precisely those geographies' cells blank. There is no
  per-cell sentinel.
- **2006 census DA crosstab 97-563-XCB2006072** (37.4 MB, 57,523 geographies,
  Geography × Age(5) × Presence of income(9) × Sex(3), 6.5M cells in ~6 s):
  the `b3 = 0x0a/0x0c` head-block vintage — the marker's fourth byte encodes
  a `32·(b3−8)`-byte auxiliary head before the value run, and its pages append
  per-(geo, age) absent-cell mask records after it (byte-exact reconstructible
  from the presence bitmap on 14,111/14,381 pages). Viewer-validated
  cell-exact: 3,487/3,487 stored cells + 833 absent-as-zero over 32
  geographies (20 random) incl. deep tail (member 57,523) and wholly-empty
  ones; `has_data` flags the 1,999 wholly-suppressed DAs. Fallback-clean under
  `canivt.strict`. Its truncated descriptor name ("Presence of inc") is
  repaired from the descriptor's complete SECOND name copy (the first copy
  caps at ~15 bytes; `ivt_f2_descriptor()` prefers the tail when the first
  copy hits the cap and the tail strictly extends it — this also completes
  the 1996/2011/2016 descriptor names whose Variable List is absent).
- **1981 census profile 97-570-X1981004** (5,989 geos, `Values(1) × Profile(79)
  × Geography(5989)`, 418,400 cells): the profile lineage stores a 1-member
  "Values" placeholder FIRST and **geography LAST**. Two descriptor fixes
  unlocked it (2026-07-04): double-01-framed record counts are **reconciled
  against the dimension's slot-directory member block**
  (`ivt_f2_dim_count_reconcile()` — the "Values" record's count byte reads a
  bogus 32; its codebook stores 1 member), and the geography dimension is
  identified from its codebook (`ivt_f2_geo_dim_index()`, dimdir.R: dim 1
  unless dim 1 has a single member, then the slot directories are probed for
  a GEO_NAME schema / inline combined-block signature). With the true counts
  the **ordinary unified layout fits exactly** — geography straddles (3
  windows of 2048), Profile pages the directory at stride 4 — no new nesting.
  Viewer-validated: 5,989/5,989 geography member order; 1,264/1,264 sampled
  cells exact (incl. window boundaries 2048/2049, 4096/4097 and member 5,989).
  Identity via the master directory (`ivt_f2_master_identity()`; `@40`/`@48`
  are zero), 10 footnotes under the numberless `FOOTNOTE:`/`RENVOI :` framing
  (1981–2016; adding it also surfaced missed notes on 1996/2006/2011/2016
  tables). Strict-clean.
- **98-400-X2016203** (49.6M cells in ~23 s; 51 geos × Admission(47) ×
  Immigrant(11B) × Age(7A) × Selected characteristics(825) × Sex(3)): formerly
  rejected for "non-exact `b2 == 0` pages" — the real bug was reading
  descriptor type `0x0a` as a u8 count (Selected = **825** members; the low
  byte read 57 and mis-nested the layout). Viewer-validated cell-exact
  (39,516/39,516 on multi-fixed slices over 4 geographies incl. the last
  member of every fixed dim, plus ~25k single-fixed cells over 9 more) and
  all 825 chunked EN/FR member labels exact (`ivt_f2_dim_dir_label_chunks()`:
  256-chunks in 1,1,2 groups, EN-then-FR runs, dense trailing block). NOTE:
  this table's viewer d0 dropdown re-sorts geographies (provinces first,
  CMAs after) — join viewer ground truth by NAME, not option position.
  Strict-clean.
- **1991 profiles 98F0172X (CT Part B) + 95F0170X (CD/CSD Part B)** — the
  hybrid dense/sparse page set, decoded 2026-07-04. Same profile lineage as
  1981004 (`Values(1) × Profile(529) × Geography(4063/5602)`, geography LAST
  and straddling: 2/3 windows; the directory is exactly 529 × window_count
  entries — the old "non-rectangular Σcount" puzzle was a truncated directory
  read: the `0x0_` markers were rejected so `ivt_idx0()` fell back to the
  0241 constant). The one new piece is the **dense `0x0_` page variant**
  (`[b0∈{02,04,08}][01][u16 count]` + one value per grid position in grid
  order, zeros stored LITERALLY, count zero-padded past the window; exact
  directory fit `4 + count·width == size` is the preflight rule;
  `ivt_decode_page_dense()`, decode.R). Sparse pages are the standard
  container. Viewer-validated cell-exact: 11,638 + 10,580 cells over 42
  geographies (every window boundary, deep tails, Canada); both viewers
  re-sort their dropdowns (Ottawa-Hull listed Hull-first; 95F0170X appends
  CSD-type suffixes) — join by NAME. Also fixed en route: `@48`/`@40` title
  blobs are NOT fixed language slots (98F0172X stores FR at `@48`;
  `ivt_f2_legacy_identity()` assigns by frscore), the legacy footnote header
  is spelled `Footnote(s)` on this vintage (39 notes each), and their master
  directories store a 4-byte-ALIGNED second length copy
  (`ivt_f2_read_dir_at()` admits it). Both strict-clean, 1.77M/1.84M cells in
  ~0.4 s.
- **2001 F-series crosstab 97F0020XCB2001070** (Geography(14) × Number(2) ×
  Earning(8) × Selected characteristics(282) × Years(2)): formerly rejected
  on the capacity rule ("1124 presence bits vs 448-cell capacity") — the real
  bug was reading descriptor type `0x09` as a u8 count (Selected = **282**;
  the low byte read 1 and collapsed the data dims, over-filling the pages).
  `0x09` is now a u16 width tag. With the true count the ordinary unified
  layout fits exactly (Earning straddles the 2048-bit record, ipc 2, 4
  windows). Viewer-validated cell-exact (34,968/34,968 over all 14
  geographies + every Number×Earning slice; b2020 viewer `Rp-eng.cfm`, PID
  60957). **The same `0x09` fix repaired a *silent mis-decode* on the already-
  supported 98-10-0174** (dissemination areas): its Mother tongue dimension is
  also `0x09` with **331** members — the u8 read collapsed it to 1, so only
  member 1's cells had decoded. Now CSV-validated cell-exact (14,895/14,895
  over 3 geographies: all 331 mother-tongue × 3 gender × 5 knowledge).
- **2006 custom-order crosstabs `cro0172986_ct.7/8`** (BC CDs+CSDs): cells +
  dims were already decoded; **geography now decodes too** — all 581 EN **and**
  FR names + GEOUIDs, read positionally from dimension 1's slot directory. Two
  small fixes: (1) `ivt_f2_read_dir_at(relaxed = TRUE)` admits the `len2 > len`
  **allocated** block size these exports store (content 3024 → allocation 3078),
  used only as `ivt_f2_dim_dir()`'s bounded fallback (capped to the slot's
  declared entry count) so it never over-reads garbage elsewhere; (2)
  `IVT_F2_INLINE_PAT2` + `ivt_f2_parse_inline()` parse the **code-in-trailing-
  parens** combined form `"<name>, <type> (<code>)"` (no dqf flag), tried only
  after the flag-trailing `IVT_F2_INLINE_PAT` — 1991/2006/2011 geo_name/geouid/
  dqf are byte-identical. Internal-consistency validated (owner+renter+band =
  total per geography, ±random rounding). The inline reader now returns
  `geo_name_fr` alongside `geo_name` for all inline vintages.
- **ord-08035** (custom CT export, 2021 population; Geo(791) × chars(79) ×
  Tenure(4), geo-straddle 4/page): the "different page encoding" was a MISREAD
  descriptor — `@32` points at the TITLE block, the real descriptor lives in the
  master dir (sig `81 01 20 00 f0 .. .. 80 03`). `ivt_f2_descriptor_offset()`
  validates `@32` then falls back master-dir → signature-scan; the layout is
  entirely standard. Internal-consistency validated (BC pop 4,915,940; tenure
  Total = Owner + Renter + Band ±random rounding); geo names 789/791; data-dim
  labels from the plaintext "Variables:" enumeration
  (`ivt_f2_varlist_members`, last fallback).
- **Enriched geography metadata on the DEFAULT path** (2026-07-05):
  `metadata$geographies` packs **every decoded per-member column**, all-NA
  columns dropped. Small schema'd tables (≤256 geos: 0241/0077/0662/0044) get
  the full positional attribute table by default (bilingual labels/names,
  DGUID, level, type, prov/geocodes, DQF, TNR); the inline vintages expose the
  formerly-DISCARDED combined-record captures `geo_type_abbr` (the municipal /
  CSD-status token — 2006/2016 `T`/`MÉ`/`IRI`…, 1981 `SUN`, 1996 `COM`, the
  cro/ord `", CSD"` name suffix) and `tnr_short_form` (the 2016+ trailing
  `( 4.0%)`, normalised to the modern decimal form), plus `dqf_code`. The
  stored combined display string stays verbatim as **`geo_label`** (the viewer
  member-order join key = the OLD `geo_name`); `geo_name`/`geo_name_fr` are
  its EN/FR halves (`ivt_f2_split_bilingual()`: `" | "` — 1991's dedicated
  language separator — always splits; `" / "` needs **positive French
  evidence** (frscore > 0 and > EN half) so dual English names ("Kootenay
  Boundary E / West Boundary") and neutral pairs ("Greater Sudbury / Grand
  Sudbury") stay combined; the language order is fixed once per run). The
  inline parse runs under **PCRE** (`perl = TRUE`): TRE reads `[^0-9\s]` as
  not-digit/backslash/'s' and let a leading space into the captured type
  token. cro's second combined run is an alternate ENGLISH display copy (type
  suffixes stripped), so a distinct FR run only feeds `geo_name_fr` when its
  differing names actually score French. `ivt_write_metadata()` writes every
  decoded column (geographies.csv) + `dqf_legend.csv`. Corpus-validated:
  geo_uid order byte-identical on all 26 supported tables; old `geo_name` ==
  new `geo_label` everywhere.
- **Health Statistics 1999 `00060104`** — first of the older **`02 00 20 00`
  split-definition survey generation** (2026-07-19). Container byte 0 is `02`,
  not `04`; everything downstream is the same model — descriptor at the standard
  `81 01 20 00 f0 … 80 03` signature (via the master-dir scan), page directory
  `[u32 off][u16 len][u16 len]` at `@558`, pages `marker(4) + 256-byte presence +
  sparse values` with the same width nibble. Three adaptations: `ivt_family()`
  accepts byte 0 ∈ {2,4}; the descriptor walk has no `FACET04` title, so it is
  bounded at the nested `81 01 <u16 len>` FACET01 block at `D+16` (recovering the
  `REGION` geography, a name+display record the doubled-name splitter drops);
  geography carries no UID/GEO_NAME schema and is identified by the header name
  (the geo-name fallback now also matches `region`/`province`). Result
  `Quantifier(1) × Geography(13 = Canada + provinces + territories) ×
  Period(37 = 1961–1997)` = **451 cells**, bilingual province names, the int16
  block decoding Canada's real total-fertility-rate series `3.84 → 1.55`.
  **The "scaling" question is CLOSED — there is no integer scaling.** The values
  are complete integers in the indicator's own units, which the facet member's
  `_Description` states: the TFR reads *"the number of children born per 1,000 women
  during their reproductive period"*, so `3840` is literally 3840 per 1,000 women
  (= 3.84 per woman), a genuine value — not a fixed-point that needs dividing. That
  is why no decimals byte exists (searched exhaustively: `b2` is only the width/
  trailer; the dec-"3"/dec-"0" facet codebooks are byte-identical). No scale warning
  is emitted; the raw integers are correct. Siblings `EDDTAB39` (Agriculture,
  float64) and `EMPLOY1` (Small Area Business, int32) share the generation but
  arrange descriptors differently — next onboarding step.
- **Health at a Glance line generalised** (2026-07-19): sampling 20 more files from
  the GPVU3L dataset showed the single-file title-block bound was too tight for the
  multi-dimension tables (records spill past the FACET01 title). Two metadata-driven
  rules make the descriptor walk uniform for the whole title-less generation: bound the
  record region at the **first value block** (the page directory's first entry, always
  after the records and before the codebook), and add a **contiguity break** to the
  accept-all pass (records sit back-to-back; a >8-byte gap after the last one ends the
  walk before it mines codebook member labels). **10 of 21 sampled Health files now
  decode** (3–7 dims, int16/int32/float64, geography at descriptor position 2–6,
  multi-facet `Quantifier(2)` tables); ledger rows `SP3_GPVU3L_00060108` (3630,
  abortions+births, Canada = Σprovinces + territories) and `_00060208` (301, Pap-smear
  counts) added. The wider sample also CLOSED the scale question: the page `b2` byte is
  the value width/trailer (NOT decimals — `00060104` and `00060108` are both int16
  `b2 = 0x80`) and the facet codebooks diff to nothing but member-count bytes — because
  there is **no integer scaling at all**. The values are complete integers in the
  indicator's own units (the TFR `_Description`: "children born per 1,000 women"), so
  `3840` is a genuine value, not a fixed-point. No scale warning is emitted. Also fixed
  two identity gaps on this generation: `product_id` (the "Title:/Source:" inline block
  is now read by `ivt_table_info()` in the fallback, so the "Title:" LABEL is no longer
  mistaken for the id, and the FR title is recovered) and the French dimension name
  (`ivt_f2_dim_name_fr_marker()` strips the English prefix off the doubled-name marker's
  "<EN><FR>" run — "Quantifier"→"Quantificateur", "Period"→"Périodes" — guarded `fr!=en`
  so modern doubled-EN markers are untouched). Remaining un-decoded Health variants: a
  `04`-separator time dimension (`00060101`/`00060102`) and large-count time dims failing
  the page pre-flight (`ANNUAL(120)`).
- **`02 00 20 00` generation completed — codebook-driven descriptor** (2026-07-19).
  The bound-the-record-region walk still misread counts on the irregular descriptor
  block (the `04`-separated "ANNUAL" time dimension, the `<display><description>`
  doubled/space-padded name pairs). The fix retires the descriptor block entirely for
  `byte 0 == 0x02` files: `ivt_f2_descriptor_02()` rebuilds the descriptor from the
  **per-dimension codebook** the header slot table (`@824`) locates — the same idea as
  `ivt_f2_descriptor_from_slots()` but keyed on the `02`-generation sub-markers. Each
  dimension's count comes from its member CODE array (`81 02 <alloc> 00 16 00`,
  `alloc = nextpow2(count)` Pascal codes at the block tail, trailing pad slots dropped
  by `drop_pad` — SEX's `04`-alloc array holds "0"/"1"/"2" + one padding space) or its
  label array; its name from the `81 02 02 00 56 00` bilingual name marker
  (`ivt_f2_02_name_marker`; a directory also carries a `.. 02 00 16 00` code array, so
  the `56` sub-byte disambiguates), falling back to a named schema field
  (`81 02 <n> 00 22 00`, e.g. "Timeseries", `ivt_f2_02_schema_name`) then the
  descriptor's doubled reference name (`ivt_f2_02_desc_reference_name`). A lone unsized
  reference/time dimension — one with NO member array in its codebook (Health's ANNUAL
  years) — is recovered from the value layout: the unique count `1:48` for which
  `ivt_layout_impl()` + `ivt_page_preflight()` validates (`canivt_descriptor_02_probe`;
  declines if zero or several counts pass, or >1 dimension is unsized). To probe safely
  `ivt_layout_impl(raw, d)` now takes an explicit descriptor and inlines the geo-dim and
  data-dim-slug lookups from it, avoiding descriptor-memo recursion. Also relaxed
  `ivt_dir_entry()` to admit `used ≤ allocated` page-directory entries (this generation
  writes `used < allocated`; modern files write them equal) — the fix that unblocked
  `tb111996` (`used = 1508` exact-fit, `allocated = 1716`). One more label fix:
  `ivt_f2_dim_member_labels()` no longer bails a named dimension that lacks a
  `81 02 02 00` marker, so a code-only reference dimension (ANNUAL years) gets its
  labels from the whole-directory Pascal run (run-count self-check guards it).
  Result: **21 of 23 sampled `byte 0 == 0x02` files decode**, all Total-consistency
  validated where a Total exists; ledger rows added for all 21 (plus the two known
  gaps as `supported = FALSE`). Two gaps stay open: `00060117` (mixed-width quantifier
  — int32 counts + float64 rates in one table would need per-width page splitting the
  single-presence-record layout doesn't model) and `tb611996` (multi-page sparse whose
  `prod(entry counts)` matches none of its 8 directory entries → ambiguous probe; true
  count 3 stated only in the title "1995 to 1997").

## Completed work log

Milestones that were once on the "likely next tasks" list and are now done.
Kept for the record; the current architecture they produced is described in
`CLAUDE.md`.

- **Geography read consolidated — recover-then-specialize (2026-07-17).** The
  geography read was the most diffuse part of the parser: six layout readers
  (`inline_dir`, `attrs_dir`, `flow_dir`, `custom`, `bare_codes`, `dguids_dir`)
  reached through two separate fallthrough ladders (`ivt_f2_geo_light` for the
  metadata default, the front of `ivt_f2_geographies` for `geo_attributes = TRUE`),
  each re-implementing the same Stage 1 — locate the geography dimension's slot
  directory and recover its member arrays. Consolidated per refactor-plan.md §7,
  gated at every step on a byte-identical geography snapshot (`geo-snapshot.csv`,
  a deterministic `rlang::hash()` of both read paths + the distinct fallback classes
  each emits — the corpus ledger only exercises the light path, so this is the only
  net for the full attribute path) plus corpus FAIL 0. Steps: (1) `ivt_f2_geo_entries()`
  walks the geo block directory ONCE and exposes lazy, memoized per-entry
  `records`/`strict`/`values` accessors that all six readers now consume — laziness
  is load-bearing (eagerly scanning 98-10-0023's 6,244 entries measured ~17 s, so
  `dguids_dir`'s O(1) probe path must never touch the run-scanner). (2) A single
  dispatcher `ivt_f2_geo_read(raw, full)` runs one ordered specializer chain both
  entry points share as thin wrappers, `full` selecting only the schema step
  (comprehensive `ivt_f2_geo_attributes()` vs the cheap `attrs_dir`/uid-only read,
  schema-gated so custom/bare fall through) — this **fixed a latent bug**: the full
  path used to fall to `ivt_f2_geo_attributes()` for a schema-less custom/bare table
  and return an all-NA tibble; it now decodes them. (3) Stage 3
  `ivt_f2_geo_combined()` (`canivt_geo_unparsed`, loud/strict-error) is the
  last-resort verbatim safety net that surfaces the codebook's own member-length run
  on an unrecognized layout (it does NOT assemble a multi-chunk codebook — a
  mis-stitched chunk order would mislabel members). The byte scans (`ivt_f2_geo_dguids`,
  the stride walk) were already explicit loud last-resorts inside their specializers;
  98-10-0013's stride-walk full read is snapshot-guarded byte-identical.
- **Stage 3 assemble-then-decipher (2026-07-17).** Upgraded the safety net from a
  single-block verbatim reader to a schema-free full reader per the owner directive
  (locate like any dimension → recover each item positionally → decipher components →
  last resort, whole member as a string), closing the last two geo-name gaps.
  `ivt_f2_geo_assemble_runs()` reconstructs the codebook's parallel arrays into full
  member-length runs with the same group/chunk geometry `attrs_dir` uses but inferring
  the run count from the block count. Column identity is **metadata-driven where the
  file declares it**: these exports carry a `81 02` field dictionary in the geography
  directory (the data-dim vocabulary "Code / English Desc / Desc Francais / Geo Code /
  DQ / Level/Niveau / UID/IDU", which `ivt_f2_geo_schema()` -- tuned to the modern
  `GEO_NAME_EN` schema -- did not recognise); `ivt_f2_geo_field_schema()` +
  `ivt_f2_geo_field_roles()` read the field names and map each run to `geo_name` /
  `geo_name_fr` / `geo_uid` positionally, no guessing. The content heuristic (display
  name = most human-readable non-uid run; uid = unique digit-bearing code; whole-string
  last resort) is the FALLBACK when no matching dictionary exists. Closed
  **EO3278_T1_CDCSD** (chunked; field dictionary matched 1-to-1: 5,146 names EN+FR +
  the file's declared `UID/IDU` SGC codes `10`/`1001`/`1008001` -- the earlier heuristic
  had mis-picked the `Geo Code` column `PR10`/`CSD…`) and **EO2654_2011_Van** (geography
  is descriptor
  dim 2 named "Geography" → `ivt_f2_geo_dim_index()` header-name fallback
  `canivt_geo_by_name`; its slot dir over-declares 109 vs 92 real entries →
  `ivt_f2_geo_block_dir()` short-directory acceptance `canivt_geo_dir_short`, validated
  by `ivt_f2_check_geo_count()`: 3,433 names + `CU…` uids). Loud throughout; cell counts
  unchanged (geo identity feeds only the slug/metadata, never the cell decode).
- **Unified cell decode — DONE.** One `ivt_layout()` + `ivt_decode()` (`decode.R`)
  decodes every table, reproducing the two former decoders **byte-identical** on all
  six reference tables (0241/0077/0662 data-dim straddle, 0023/0129/1991 geography
  straddle). The decoder is fully name/type-agnostic.
- **Unified metadata — DONE.** `read_ivt()` / `ivt_metadata()` now run **one**
  descriptor-driven metadata path (`ivt_f2_metadata()`) for every family; the
  hard-coded `IVT_DIMS` / `ivt_read_codebook()` / `ivt_pick_english_block()` table is
  gone, as is the family-1 branch in `ivt_tidy()` / `print.ivt()` and the separate
  `ivt_f2_read()`. Dimension member labels come from `ivt_f2_dim_member_labels()`,
  anchored on the codebook's per-dimension **doubled-name marker** (`81 02 02 00` +
  name, the same string the header descriptor stores), which sits immediately after
  each dimension's EN member block: `ivt_f2_marker_labels()` matches the marker name
  to a descriptor dimension and takes that block's trailing `count` records (the
  old ordinal-anchored + adjacent-FR/EN-pair scans remain as a fallback). Full
  dimension names from the header Variable List matched to the descriptor **by
  count** (`ivt_f2_vl_pairs()` — display order ≠ storage order in 98-10-0241, and
  the `(3C)`-style flagged count is parsed). `geographies` is now uniformly keyed
  `geo_name`/`geo_uid`/`member_id` for both families (was `name`/`dguid` for family
  1) **plus every other decoded attribute column the vintage stores**. All six
  reference tables label every data dimension, byte-identical to the old output; the
  marker anchor closed the last gaps: 98-10-0077 `Ages`(18) (EN block carries 2
  leading framing records) and `Year`(2) (a 2-member reference period with no
  ordinal block, `2020`/`2015`), and 98-10-0662's two 6-member language dimensions,
  which share a count and so collapsed under the count-keyed store —
  `ivt_f2_dimensions()` resolves same-count dimensions **by name**.
- **Profile lineage (geography-last) + 2016203 — DONE** (2026-07-04, both
  viewer-validated cell-exact). The delta was entirely in the descriptor/metadata
  layer: u16 width tags `0x0a`/`0x0c`, double-01 count reconciliation against the
  slot-directory member blocks (`ivt_f2_dim_count_reconcile()`), the codebook-driven
  geography-dimension index (`ivt_f2_geo_dim_index()`), chunked >256-member data-dim
  labels (`ivt_f2_dim_dir_label_chunks()`), master-directory identity
  (`ivt_f2_master_identity()`) and the numberless `FOOTNOTE:`/`RENVOI :` footnote
  framing. The unified decoder needed no changes beyond slug/role generality —
  geography-last is the ordinary layout with a 1-member outermost placeholder.
- **1991 profiles 98F0172X/95F0170X — DONE** (2026-07-04). The whole delta was the
  dense `0x0_` page variant (`ivt_decode_page_dense()`) + three legacy-metadata
  fixes (frscore-assigned `@48`/`@40` titles, the `Footnote(s)` header spelling, the
  4-aligned second length field in `ivt_f2_read_dir_at()`). The page→grid assignment
  was the ordinary unified walk all along.
- **2001 F-series 97F0020XCB2001070 — DONE** (2026-07-04). The whole delta was the
  `0x09` u16 count width tag: Selected characteristics is 282 members, not 1 — the
  "1124 presence bits vs 448-cell capacity" was the mis-nested layout the low-byte
  count produced. The same fix repaired a silent mis-decode of 98-10-0174's Mother
  tongue(331).
- **1991 `1003011` — DONE.** Fully wired into `read_ivt()` via the unified decoder
  (geography straddles, 4 geos/page, int16/int32 pages) + the pre-DGUID inline
  geography codebook (`ivt_f2_geo_inline()`, positional via
  `ivt_f2_geo_inline_dir()`; all 41,859 geographies exact vs the B2020 viewer's
  member list, names and codes) and bilingual Age(110)/Sex(3) labels.

### Uniform, content-free geography parsing — DONE

Geography is dimension 1 (except the profile lineage) with the same
`81 02 02 00` doubled-name marker as every data dim; `ivt_f2_geo_light()` resolves
every family through **one marker-anchored entry**. There are **two storage
strategies**: the 2021 census tables store geography as **separate schema-named
arrays** (`ivt_f2_geo_schema()` field list `GEO_NAME·…·DGUID·…`), while every
**schema-absent** table stores it as the inline combined block `"<name> (<code>)
[<type_abbr>] <dqf> [(<pct>%)]"`. **DGUIDs are 2021-specific, not "2016+"** — the
2016 `98-400-X` tables carry no schema and no DGUID. `ivt_f2_geo_light()` order:
combined-block reader (schema-absent) → schema/content single-block (2021 small) →
DGUID scan (2021 chunked); the combined-block reader returns NULL for schema'd
tables (0241's `Corner Brook (CA), N.L.` parens are part of the *name*).

- **Schema'd single-block (0241/0077):** `ivt_f2_geo_simple_schema()` reads arrays by
  schema slot/name, no `"2021"`/`"Canada"` sniffing.
- **Combined-block (1991/2006/2011/2016):** `ivt_f2_geo_inline()` anchors on
  `ivt_f2_geo_marker_region()` and parses only that region (`ivt_f2_parse_inline()`,
  PCRE). The uid is **character** — a bare code (2016 `01`, 2006 `1001105`), a dotted
  census-tract code (2011 `0010001.00`), never a DGUID here. Exact member counts
  (viewer-validated): 1991 41,859 (scan misordered the last 2,435), 2006 57,523 (R=3
  runs, no code array, partial chunk first; scan misordered 18,432), 2011 5,447 (scan
  misordered 1,351), 2016 (98-400-X2016387) 174.
- **2021 chunked DGUID (0023/0129) — Stage 3, DONE.** Folded under the marker+schema
  view, byte-identical on all 63,404 DGUIDs and every attribute. No year literal, no
  hard-coded slot table: `ivt_f2_geo_slot_map()` reads each attribute's slot from the
  file's own schema field list; `ivt_f2_geo_groups_chunked()` segments the 256-member
  groups structurally (the DGUID slot is a contiguous run of `ivt_f2_is_dguid_block()`
  blocks, 2G/group EN then FR, member ids from the running 256-chunk total); the fast
  uid scan `ivt_f2_geo_dguids()` hits on the DGUID **shape** `<YYYY><level letter>`
  (with a dot for census-tract DGUIDs `2021S05079320001.00`), vintage-agnostic.
  Validated beyond 0023/0129 on **98-10-0174** (DAs; a family-1 table with the same
  chunked codebook — proves family-agnostic) and **98-10-0478** (CTs; 6,297 geos,
  type `0x0d`, groups `1,1,2,4,8,9`).
- **Bilingual geography names (display label + GEO_NAME) — DONE.**
  `ivt_f2_geo_attributes()` emits `geo_label`/`geo_label_fr` (the display **Member
  Name**) and `geo_name`/`geo_name_fr` (the schema **GEO_NAME**, a bare code for CTs
  / unnamed DAs), read structurally (`ivt_f2_geo_names()` + `ivt_f2_geo_name_runs()`).
  Language decided per group by `ivt_f2_frscore()` because the physical EN/FR order is
  EN-first in most groups but **FR-first in the root group** (0023 stores
  `Terre-Neuve-et-Labrador` before `Newfoundland and Labrador`). `geo_label` == the
  StatCan "Member Name" 63,404/63,404 on 0023, 6,297/6,297 on 0478.
- **Trailing-partial drop + off-window schema (98-10-0013 ADA) — DONE.** (a) The
  `length ≥ 150` floor dropped the last group's 71-member trailing partial (5,376 of
  5,447); the floor is now structural — a small clean member-array block is kept only
  when it immediately follows a full member block. (b) ADA's attribute dictionary sits
  ~14 KB *before* the codebook pointer, outside the old `[cb−8000, EOF]` window; it is
  now located by **following the file's own metadata directory** (header slot `@824`
  holds `[u32 off][u16 len][u16 len]` entries, confirmed by the `GEO_NAME_EN` field
  name; `ivt_f2_geo_block_dir()` tries two indirection depths).
- **Reverse-stored root chunk (98-10-0013 ADA) — DONE.** The codebook's first
  ("root") chunk is stored in reverse byte order, so the byte-ascending scan reversed
  its logical block order and the stride walk landed wrong (5,191/5,447, NA'd/scrambled
  attributes). Fixed by reading the root chunk **positionally from the header block
  directory** (`ivt_f2_geo_root_dir()`): value blocks in directory order, pair 1 →
  display name, pair k+1 → schema field k, language by `ivt_f2_frscore()`. Matches the
  stride output 256/256 on 0478 and both big tables.
- **Drive *all* groups from the directory's block order — DONE.**
  `ivt_f2_geo_attrs_dir()` is now the **primary** chunked-geography reader (stride path
  only when the directory is absent/irregular): every attribute read positionally, no
  strides, no byte-ascending scan, no content-located TNR. Self-consistency gate is the
  regular block count `2·(nfield+1)·Σsizes`. Fixed latent stride slot bugs on tables
  carrying `TNR_LONG_FORM`: 0478 `pr_code`/`dqf_code`/`tnr_short_form` (stride wrong for
  1,278/327/1,897), 0129 `tnr_short_form` (wrong for 237). Residual: 0478's last-group
  code partials (`geo_name`/`alt_geo_code`, 153 members) stay NA.
- **Geography member-ordering tail artifacts — FIXED.** The byte-ascending scans with
  first-appearance dedup misordered chunks stored out of byte order; the positional
  directory read (`ivt_f2_geo_inline_dir()`) exposed silent misorders of 2,435/41,859
  (1991), 18,432/57,523 (2006), 1,351/5,447 (2011), each validated exact against the
  B2020 viewer's `d0` option order (the definitive member-order ground truth).

### Family-2 geography attributes — DONE, positional-exact

The strict value-entry parse (`ivt_f2_dir_entry_members()`, see ivt-format.md
"Value-entry block framings") supplies the values; the run-scanner only classifies
entries. Every attribute validates exact vs the StatCan metadata CSVs on 0662 (91/91 ×
11 — its aggregate member 26 has NO attributes; the scanner had shifted every uid after
member 25), 0023 (63,404 × 11 incl. **DQF_NOTE 100%**, was ~99.8%), 0129, 0478 (incl.
the formerly-NA 153 code partials) and 0013 (stride fallback). Remaining: (a) DQF_NOTE
texts > 252 chars are stored truncated **in the file** (the 1-byte record length caps at
`0xFC`) — 2,448 members on 0129, 90 on 0478; (b) the dense arrays' bitstream per-member
coding is undecoded (not needed — alignment comes from the plain siblings).

### 2006 DA crosstab & the b3 head block — DONE

`97-563-XCB2006072` was rejected only because this vintage's markers carry
`b3 = 0x0a/0x0c` — the marker's fourth byte encodes an auxiliary head block of
`32·(b3−8)` bytes before the value run (`ivt_value_trailer()` now takes b3; the formerly
hard-coded "+32 on `0xa2` pages" was really `b3 = 09`). Its `b2 == 0` pages append
per-(geo, age) absent-cell mask records after the popcount value run (byte-exact
reconstructible from the presence bitmap on 14,111/14,381 pages), so `b2 == 0` exact-fit
is asserted only for `b3 ≤ 09`. See ivt-format.md "The b3 head block and suppression
tails".

### Footnotes & metadata-directory consolidation — DONE

- **Footnotes are dimension-attributed** (`dimdir.R`): each footnote is an entry of its
  owning dimension's slot directory, so `ivt_f2_footnotes()` emits a `dimension` field
  (texts set-equal to the old tail scan; the scan survives as fallback). Remaining
  nicety: per-*member* attribution (the small records preceding each footnote pair look
  like member references, unverified).
- The DGUID scan / `ivt_f2_geo_marker_region()` are bounded by the geography directory's
  byte span (`ivt_f2_geo_dir_span()`). The 1991-style inline geography is read
  positionally (`ivt_f2_geo_inline_dir()`). Single-chunk schema'd tables (0241/0077) go
  through `ivt_f2_geo_attrs_dir(trim = FALSE)` (byte-identical to `ivt_f2_geo_simple()`).
  The **master directory at offset 992** (`ivt_f2_master_dir()`, slot `@544`) bounds
  `ivt_f2_legacy_footnotes()`, and the **`@712` DQF legend** is decoded
  (`ivt_f2_dqf_legend()`) and exposed as `dqf_legend` on `ivt_metadata()`.

### Geography, flow, footnote & note completeness (2026-07-06 – 07-10) — DONE

The last "small remaining" items that lived in `CLAUDE.md`'s Open-tasks list, now
closed and moved here for the record.

- **Every geography member across the corpus decodes a non-NA `geo_name`**
  (2026-07-06). Two loud, metadata-driven fills close the last gaps (see
  `coverage.md`): `ivt_f2_inline_name_subtract()` recovers inline names the
  fixed-position regex misses — the code embedded mid-name (dual-name CSDs,
  ord-08035) or a bare code-only geography (1996 EAs, 95F0200) — by subtracting the
  code/flag/pct tokens held from the file's own arrays; `ivt_f2_geo_fill_label()`
  backfills `geo_name` from `geo_label` for synthetic aggregate members
  (98-10-0662's "Canada outside Quebec and New Brunswick"). Both fill only NAs
  (validated tables byte-identical) and warn `canivt_fallback`.
- **Commuting-flow decoder generalizes across ALL vintages (2011/2016/2021)**
  (2026-07-09, see `coverage.md`). StatCan uses **three encodings** for the same
  residence→work flow product, all now decoded: (1) **`0x0f` packed flow** (2011 +
  2016 CSD `98-400-X2016325`): decoded by the 2011 reader unchanged (23,565 O-D
  pairs, 100% res/work names+uids). (2) **residence × work crosstab** (all 2021:
  `98-10-0459/0466/0460`, CSD/CD/CMA): a second geography-valued `Place of work`
  dimension, no `0x0f`; strict-clean, residence is a chunked DGUID geography
  (uid-only on the default path, names via `read_ivt(geo_attributes = TRUE)`, like
  `98-10-0023`). (3) **single-dim combined `"origin / dest"` flow-pair labels**
  (2016 CD/CMA `98-400-X2016391`/`-327`): same dedicated `origincode/destcode` uid
  array as `0x0f`, just SHORTER codes (4-digit CD, 3-digit CMA); decoded by relaxing
  `ivt_f2_geo_flow_dir()`/`ivt_f2_flow_sides()` to `[0-9]{3,9}` and trying the flow
  reader BEFORE the plain inline reader (which latched onto the single-side name
  array). `327`'s CMA geography also needed **`0x0b` added to the u16 width-tag set**
  (u8 misread count 5 vs u16 1399). Both now 100% geography coverage (391: 4,199
  flows; 327: 1,399), internal-consistency validated.
- **Flow member order — VIEWER-VALIDATED** (2026-07-10). Decoded `(residence → work)
  → value` triples are content-exact against the Beyond 20/20 viewer on every vintage
  (`98-400-X2016325`/`391`/`327`, `99-012-X2011032`: 100% joined-value + set-equal
  across sampled residences, after fixing each non-geography data dim to its Total
  member as the viewer does). Our member order is residence-major, SGC-code ascending
  (deterministic/geographic); the viewer re-sorts within a residence for display, so a
  positional match isn't expected (same as the 2016203 geography re-sort). Scrape-based,
  internal (`R/ground-truth.R`), not in the automated suite.
- Fixed a latent `metadata$geographies` crash en route: an undecoded `geo_name` NULL
  slot made the list ragged (`as_tibble()` failed) — now undecoded columns are omitted
  so it is always rectangular (`read-f2.R`).
- **`DQF_NOTE` truncation — DETECTED + FLAGGED, accepted by design** (2026-07-10).
  `DQF_NOTE` texts are stored in a single-byte-length Pascal record, so notes longer
  than 252 chars (`0xFC`) are truncated **by StatCan's writer in the source file** —
  2,448 members on 98-10-0129, 90 on 98-10-0478. **Verified at the byte level**: a
  truncated record is `[FC][252 text bytes][00]` cut mid-word, and the byte after the
  `00` terminator opens the *next member's* record — there is **no continuation to
  recover**, the tail is genuinely absent. Our read is byte-exact, so this is a
  container limitation, not a decode gap. Now **surfaced, not silent**: wherever
  `dqf_note` is present a companion `dqf_note_truncated` logical column marks the
  affected members (`ivt_f2_dqf_note_truncated()` / `ivt_f2_flag_dqf_note_truncation()`,
  `codebook-f2.R`), and a classed `canivt_dqf_note_truncated` /
  `canivt_source_truncation` warning fires (`ivt_source_truncation()`, `fallback.R`).
  Because it is a *faithful* read (not a heuristic path), `options(canivt.strict = TRUE)`
  leaves it a warning rather than upgrading it to an error. On the big chunked tables
  `dqf_note` (and the flag) only decode via `read_ivt(geo_attributes = TRUE)`.
- **Synthetic-aggregate `geo_uid`/`geo_level` NA — accepted by design** (2026-07-06).
  A geography member constructed at tabulation time (98-10-0662's member 26, "Canada
  outside Quebec and New Brunswick") carries only a display label; the schema attribute
  arrays (DGUID, level, type, …) store nothing for it. `ivt_f2_geo_fill_label()`
  backfills its `geo_name` from `geo_label` (loud `canivt_fallback`), but `geo_uid` and
  `geo_level` are genuinely absent in the file and correctly stay `NA` — an aggregate
  has no DGUID. Regression-guarded in `test-decode.R` (0662) and `test-fallback.R`.
- **Footnote scope (table / dimension / member) — DONE** (2026-07-09). Every
  footnote carries `scope`, `dimension` and `member_id`, matching StatCan's WDS
  links exactly (validated on 98-10-0241/0077/0023/0129). Member notes come from a
  `84 01` member bitmap opening each dimension's footnote region
  (`ivt_f2_footnote_bitmap()`, pair-swap/MSB-first → member positions; the first
  `popcount` text entries are member notes, the rest dimension notes); table notes
  from the master-directory identity blob (`ivt_f2_table_footnotes()`). **The legacy
  `(N)`-superscript → member linkage on the pre-DGUID profiles is decoded too** — a
  member cites a note by embedding `(N)` in its label; `ivt_f2_note_refs()` /
  `ivt_f2_attach_legacy_refs()` (read-f2.R) parse those (numeric parens 1..n_notes)
  into `scope = "member"` + `member_refs` (one-to-many; quiet, self-validating like
  `parent_id`). Footnote scope is now complete across the corpus.
- **Per-dimension `depth` on `ivt_tidy()` — DONE** (2026-07-09). `ivt_tidy(depth =
  TRUE)` (opt-in, default `FALSE` so Parquet output is unchanged) adds a
  `<col>_depth` integer column after each data-dimension column, read from the
  label indentation (the same measure `ivt_members()` carries). Works on the
  labelled and compact-id (`labels = FALSE`) paths and in both languages.

### Parser consolidation & sharpening (2026-07-11) — refactor-plan §5/§6

The 2026-07 parser review's backlog (`refactor-plan.md`). Each change validated
against the corpus regression ledger (byte-exact cell counts + fallback
cleanliness, FAIL 0 / PASS 120):

- **Page-directory anchor single-sourced** (§5.2). The low-16-bit `@558` pointer
  unwrap (`+ k·65536`, for directories past 64 KiB) now lives once in
  `ivt_f2_dir_anchor_header()`; `ivt_idx0()` is a thin wrapper. Previously only the
  decode side unwrapped, so the metadata-side finder fell to the loud marker scan
  on a >64 KiB directory. Verified 98100013 (k=1) / 95F0250 (k=2) equal across
  `ivt_idx0()` / `ivt_f2_dir_anchor_header()` / `ivt_f2_find_directory()$lo`.
- **`ivt_geo_arrays()` retired** (§6.3), removing the last year/country literals
  (`"^2021[A-Z]"`, `texts[1] == "Canada"`). A full-corpus branch trace of
  `ivt_f2_geo_light()` proved its content fallback (`ivt_f2_geo_simple()`'s
  `2b-SIMPLE`) is **never reached** — every file resolves via inline / attrs_dir /
  uid-only — so it went away by deletion; `ivt_f2_geo_simple()` is now schema-only.
- **`ivt_f2_geo_schema()` window scan made LOUD** (§6.4). All 12 schema'd tables
  resolve the geography dictionary through the header slot table
  (`ivt_f2_geo_dict_block()`), so the ±128 KiB content-window fallback fires on
  zero tables (its "deeper pointer chain we do not decode yet" note was stale since
  the two-depth `ivt_f2_dim_dir()` indirection). Kept as a last resort but now
  warns `canivt_fallback` when it actually supplies a schema (was silent).
- **Doubled-name marker identified STRUCTURALLY** (§6.2). Empirically, within a
  slot directory validated by index + `n_entries` the marker is the unique entry
  OPENING `81 02 02 00` and carrying a name: 152/155 dimension directories have
  exactly one (never >1); the 3 nameless cases are the ord-08035 custom export,
  where the descriptor name also fails. `ivt_f2_dir_marker_entry()` now resolves it
  without the descriptor name (kept only to disambiguate the never-observed
  >1-named case). Byte-identical to the old name-match on all 155 directories; the
  win is robustness — a dimension with a misread/NA name still reads its labels
  (verified on 98-10-0241), demoting the `ivt_f2_descriptor_name()` recovery stack
  from load-bearing to a cross-check.

## Invariant derivations & historical bugs

Why the "Key invariants" in `CLAUDE.md` are what they are — the measurements and the
original bugs behind each rule.

- **Index stride `0x1000` (166 geographies).** Striding by `0x8000` silently reads only
  every 8th geography — the original bug.
- **The b2 trailer formula** `2·(b2>>4) + 2·(low nibble(b2)>0)` was derived from
  98-10-0013's 22 pages (18 distinct b2 values, trailers 6–14, each anchored byte-exact
  vs the StatCan CSV); it reproduces the formerly hard-coded constants (88/20→4,
  a8/41→10, 84/40→8, 82/80→16, a4/82→18). The old `32/width | 64/width+2` width formula
  only coincided because b2 was constant per marker family before 0013.
- **The b3 head formula** `32·(b3−8)` generalises the former "+32 on `0xa2` pages"
  (every corpus 0xa2 page is `a2 01 03 09`) and unlocked the 2006 vintage (97-563:
  b3=0a/0c).
- **`@558` stores only the LOW 16 BITS of the directory offset.** 98-10-0013's directory
  is at `44761 + 65536` — under the plain u16 read its cell decode was silently EMPTY
  (idx0 fell back to the 0241 constant, 0 pages); 95F0250XDB96001 needs `k = 2`. The
  page-directory entry floor is **1024** (past the header region), not 1e5 — the old
  100 KB guess truncated 98-400-X2016387's directory to 6 of 22 pages.
- **The pre-flight rejects misread descriptors, not just alien containers.** The span
  rule flagged 97-570-X1981004 (a bogus Values count of 32 — really 1), the exact-fit
  rule flagged 98-400-X2016203 (Selected 825 read as 57), and the capacity rule flagged
  97F0020X (Selected 282 read as 1) — all three decode cell-exact under the corrected
  descriptors. The legacy 0x1000-stride family-1 probe was removed because it granted
  family 1 to any file with marker bytes at the 0241 offsets, bypassing validation.
- **The geography type byte is a storage-width tag, never an identity.** `0x10`
  (modern 2021/DGUID), `0x0d` (2011 CTs; 1981/1991 profile geographies), `0x0a`/`0x0c`
  (profile characteristics/geography) carry a **u16** count; `0x08` (family-1 reference)
  a **u8**; `0x09` a u16 width tag for a *data* dimension (97F0020X Selected(282),
  98-10-0174 Mother tongue(331)). Original bugs: `type == 0x10` misread 0241's geography
  count as 16383; `0x0d` as u8 misread 2011's 5447 geographies as 21; `0x0a` as u8
  misread 2016203's 825 as 57 (faked "non-exact" pages); `0x09` as u8 collapsed
  97F0020X's Selected to 1 and silently mis-decoded 98-10-0174.
- **Double-01 records are ambiguous.** The reference-period record `[type][count][01][01]`
  ("Year (2)": `0e 02 01 01`) shares its shape with the profile "Values" placeholder
  (`00 20 01 01`, whose count is 1 not 32); counts are reconciled against the
  slot-directory member block (`ivt_f2_dim_count_reconcile()`).
- **Descriptor records are anchored on the doubled name.** The first copy may be
  truncated (~14 chars) and the name may start with a digit ("1995 Household Income (3)"
  in 95F0250XDB96001 — the uppercase-only anchor silently dropped it, and the 2-dim
  layout decoded misindexed cells that passed the pre-flight; only viewer validation
  caught it). The header `n_dim` field is unreliable (95F0200XDB96003 reads 1026 with 4
  clean dims; 97-570-X1981004 reads 770) — gate on `length(d$dims)`. **INVERTED layout**
  (97-570-X1981002, 98-400-X2016019): dimension records sit *before* the signature block;
  `ivt_f2_descriptor()` retries the region between the last `81 02 03 00` before D and D.
  **PROSE-BLEED names** (2001 F-series 97F0015X): French description text bleeds into and
  between the two name copies, so two count-anchored fallbacks in
  `ivt_f2_descriptor_name()` recover them (data-dim names end in `(count)`; the geography
  name is the longest prefix that reoccurs later in the run).
- **The `0xa` high nibble is not a suppression flag** — `0xa*` pages carry real inline
  data; the high nibble only changes the pad/`0xFF` trailer length.
- **A reference-period / facet dimension (`0x0e`) is not geography-folded:** in 98-10-0077
  *Year* is the innermost in-page dimension (the value run carries 2020 then 2015
  consecutively). The legacy `ivt_geography_count()` (0x1000 stride, since removed)
  returned 348 here only as an artefact of striding a directory whose real
  per-geography stride is 0x2000.
