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
- **`02 00 20 00` generation — CHUNKED geography (1996 census / Census of
  Agriculture)** (2026-07-23). Two Borealis tables from the third random sweep,
  both preflight-rejected because a `>256`-member geography read **capped at one
  256-member chunk**: `b34csd_1` (1996 census, Geography(**5544**) × Sex(3) ×
  Age(11) × Highest schooling(8) × School attendance(4)) and `EDDTAB16` (1996
  Census of Agriculture, Units(1) × Geography(**2315**) × Variable(30)). The
  gen02 descriptor is rebuilt from the codebook (`ivt_f2_descriptor_02()`), and
  `ivt_f2_slot_member_count()` returns only the largest single block — 256 — so
  the layout under-spanned the page directory and the family gate honestly
  rejected both. Fix: `ivt_f2_slot_chunked_count()` (codebook-f2.R) — the INVERSE
  of `ivt_f2_chunk_layout()`. The chunked codebook lays each 256-member chunk
  down once per attribute×language RUN, so with `R` runs the geo directory holds
  `R` copies of every chunk: `R` = how many times the single trailing PARTIAL
  chunk (< 256) occurs, chunk count = total member arrays / R (must divide
  evenly), true count = `(n_chunks-1)·256 + partial`. Over-determined (three
  consistency checks), so a stray array or a non-chunked dimension yields NA, not
  a wrong count; fires only when `ivt_f2_slot_member_count()` capped at exactly
  256 and a `>256` value is recoverable. b34csd: 63 full + 3×168 partial arrays →
  22 chunks → 5544 (cross-checks the descriptor block's own `a8 15` = 5544);
  EDDTAB16: 72 full + 8×11 → 10 chunks → 2315. LOUD (`canivt_chunked_count`,
  `strict_clean = FALSE`) — an INFERRED count, not a declared field. Validated:
  **b34csd 2,240,847 cells** (Highest-schooling Total 22,628,925 = Σ sub-levels
  22,628,920 ±5 base-5 rounding; Canada pop 15+ ≈ 22.6M matches the 1996 census;
  Sex Total = M+F), geography labelled by name+SGC code via the inline signature.
  **EDDTAB16 60,468 cells** (Canada total farms 277,000 matches the 1996 Census
  of Agriculture ≈ 276,548). b34csd's geography matches the inline `name (code)`
  signature so it gets a proper `geo` column; EDDTAB16's geography carries a rich
  multi-field hierarchy dictionary (`Geocode2/ProvName/CARName/CDName/CCSName/
  GeoLevel/LowLvlName/CompleteName`) with NO UID and six fields mapping to
  `geo_name`, which the shared geo reader cannot disambiguate — so it stays an
  ordinary data dimension (like the sibling `EMPLOY1`'s GEOGRAPHY) labelled by its
  9-digit geocode. **Known minor limitation:** EDDTAB16 geography reads by code,
  not name (the names — CANADA, CompleteName — are present in the codebook but not
  surfaced; a role-disambiguation improvement to the shared reader is deferred).
- **LFHR `Table-210` + Business Patterns `CDCSDNAIC3dec2006` — investigated,
  DEFERRED** (2026-07-23). The other two sweep-3 onboarding targets are genuinely
  hard. **`Table-210`** (LFHR, Geography(11) × Sex(3) × Age(9) × Characteristics(10)
  × Education(10) × Timeseries(240 monthly, 1990-01…2009-12)): its header page-
  directory pointer `@558 = 34997` is stale — the real directory is at **35197**,
  locatable only by the marker SCAN (`ivt_f2_find_directory()`, `lo = 35197`,
  which `ivt_idx0()` deliberately does NOT use for the DECODE path). Even from the
  right base the directory PACKING is irregular (validity alternates 8/12 valid
  entries per 32-entry block, pages come in two sizes) and does not fit the
  power-of-two stride model: characteristics decode only 4 of 10 members (missing
  Unemployment and the rates), the in-page Education dimension is off by one
  (positions 2-8, member 1 phantom-absent). This is the `Table-023`/`Table-024`
  "doubled-window" family's UNSOLVED geometry (the undecoded `16 00` block
  mid-section / per-slot flags likely bites). Left rejected by the pre-flight
  rather than routed through the scan (which would SILENTLY mis-decode).
  **`CDCSDNAIC3dec2006`** (Business Patterns Dec 2006, CD/CSD(5914) × SUB-SECTORS ×
  EMP(12)): the descriptor reads SUB-SECTORS = **26628** (type `0x0b`), a misread —
  for this CD/CSD-separated variant SUB-SECTORS is pure 3-digit NAICS (~104, the
  u8 `0x68` of the u16 `0x6804`); the sibling `CDNAIC3_LOC-1`'s 26628 was a
  genuine NAICS×location combined dim, so the type byte alone cannot separate them.
  Plus a sparse fragmented directory (4306 markers, finder `n_pages = 1`). Needs a
  descriptor-count fix + directory relocation — deferred as the sweep's HARDEST.
- **`04`-gen chunked geography/classification generalised — the metadata-harvest
  sweep** (2026-07-23). A range-based metadata-harvest sweep (`dev/range-harvest.R`,
  100 Borealis + 100 StatCan random files) surfaced a cluster of `04 00 20 00`
  tables preflight-rejected for the **same 256-chunk cap** the gen02 fix above had
  solved — but on the GENERIC descriptor path (byte 0 == `0x04`), where the count
  comes from the slot-directory member block and stops at the first 256-member
  chunk. `ivt_f2_slot_chunked_count()` already recovered the true count; it was
  simply not wired into the generic path. Fix: `ivt_f2_dim_count_reconcile()`
  (dimdir.R) now probes it for **any** dimension read as exactly 256 and adopts the
  chunk-run count when `>256` (LOUD `canivt_chunked_count`; the probe returns NA for
  a single-chunk 256-member dim, so a genuine 256 is untouched — corpus byte-
  identical, FAIL 0 PASS 288 on the pre-existing rows). This one fix onboarded **8
  files**: the 2001 F-series profiles `95f0487xcb01003` (Geography 256→**1585**,
  134,238 cells), `95f0494xcb01001` (Profile 409 × Geography **5108**, 248,780),
  `100801` (Census Div 529 × Geography **5602**, 1,844,241); the 2001 topic tables
  `95f0338xcb01006` (Geography **5108** × Sex × Various-notes(76) × Age, 528,575),
  `95F0377XCB01005` (Geography **1581** × Sex × Marital × Age × Labour-force,
  3,048,793); the 2006 crosstab `97-554-XCB2006027` (Geography **1601** × Housing-
  tenure × Household × Structural, 362,761); PLUS the two 2001 census tables flagged
  (but not fixed) in sweep 4 — `95f0491xcb01003` (Geography **1581**, 105,001) and
  `97F0007XCB2001042` (Geography **5108** × Sex × Characteristics **508** ×
  Mother-tongue, 9,021,645 — BOTH capped dims recovered, the predicted `0x09`-width
  route unneeded). Every one decodes with **all geographies named** (`geo_name_NA =
  0`). All 8 added to the corpus ledger (`strict_clean = FALSE`). The SAME sweep also
  found — and this fix's companion commit closed — a genuine NA-subscript crash in
  `ivt_f2_inline_name_subtract()` (codebook-f2.R): when a member's uid `code` is NA
  the `out == code` comparison put an NA into the `empty` logical index and
  `out[empty] <- code[empty]` threw *"NAs are not allowed in subscripted
  assignments"* (hit on the `02`-gen 1996 census profiles `b28ea47` /
  `95f0205xdb96003`, whose chunk-recovered 2298-member geography carries some NA
  codes). Guarded with `!is.na(code)`; both now decode.
- **`04`-gen chunked count — the reconcile no longer requires a `256` descriptor
  count** (2026-07-24). A second range-based metadata-harvest sweep (200 Borealis +
  200 StatCan) surfaced the 1991 enumeration-area census tables (`04 00 20 00`,
  full-download from www12 `Download.cfm`) — e.g. **PID=128 / catalogue 1006454**,
  "N9101 – Population 15+ by Age Groups (17) and Marital Status (6), showing Labour
  Force Activity (8) and Sex (3), Canada … enumeration areas". Its geography reads
  `type 0x0e count 52` on the descriptor — and **52 is the CHUNK count, not the
  member count**: the codebook stores 52 full 256-member chunks + a 60-member tail,
  true count **13372**. The `2026-07-23` generic-path fix above only invoked
  `ivt_f2_slot_chunked_count()` when the descriptor count was *exactly 256*, so this
  variant (count 52) slipped through and the file preflight-rejected — the extent
  guard (`ivt_page_preflight()`, decode.R) correctly refused to decode 52/13372 of
  the table (a real float64 page sits at the doubled-corner of the modelled
  cartesian). Fix: `ivt_f2_dim_count_reconcile()` (dimdir.R) now runs the chunk-run
  probe on **every** dimension and adopts its count whenever it EXCEEDS the
  descriptor's — the probe is authoritative and self-gating (returns NA unless the
  codebook physically holds ≥2 full 256-arrays + a consistent trailing partial, so a
  ≤256-member dim is never touched and no count is fabricated). Decodes to
  **8,308,875 non-zero cells** across 13,372 EAs, `geo_name_NA = 0`; validated
  internally (Canada Total-Sex 21,304,740 = Male 10,422,145 + Female 10,882,595
  exactly; counts random-rounded to base 5, and the fractional values are the real
  Labour-Force *rate* members — Participation/Unemployment/Employment-population
  ratio — stored as float64). Corpus regression **FAIL 0 PASS 312** on the
  pre-existing rows (no count changed); ledger row `1006454` added
  (`strict_clean = FALSE`, `canivt_chunked_count`).
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
- **`02 00 20 00` generation CLOSED — time-series member table, slot-aware layout,
  quiet gate, no geography dimension** (2026-07-19, second pass). All 23 files now
  decode **strict-clean**; both remaining gaps fell to metadata reads, not new layout
  machinery:
  - **The `81 02 <alloc> 00 08 00` TIME-SERIES MEMBER TABLE** (`ivt_f2_time_members()`)
    is how B2020 stores a reference dimension with no code/label arrays: `alloc`
    one-byte member-slot flags + one **u24 LE date per member** right-aligned at the
    block end. The epoch is **0000-03-01** (proleptic Gregorian — the classic
    computational-calendar epoch): every stored date lands on Jan 1 of its year,
    calibrated on three files at once (LFHR Table-051 1976–2010, h2530002 1975–2010
    with the 1974 lead date clipped by the block length → extrapolated backward by the
    median step, tb611996 1995–97 — its three dates appear verbatim in LFHR's run).
    Labels are generated (the year when the sorted median step is 350–380 days, else
    the ISO period start). Count = non-zero flags; this sized tb611996's ANNUAL
    RATE = 3, which the value-layout probe could never disambiguate from 4
    (`np2(3) == np2(4)`, and its `b2 = 0x20` pages have no exact-fit constraint).
  - **The flag bytes are BYTE-PAIR-SWAPPED and mark member SLOTS, which the presence
    bitmap addresses** — deleted members leave holes. tb611996's periods sit at slots
    {1,2,4}: exactly 1/3 of its stored values sat off the dense member grid until the
    layout became slot-aware (`dims[[k]]$slots` → extent-based nesting/window/stride
    geometry in `ivt_layout()`, per-member bit positions in `ivt_f2_cell_grid(pos=)`,
    slot→member `match()` for straddle/paged coordinates in `ivt_decode()`, loud
    `canivt_slot_hole` if a value ever lands on a hole). The swap direction is
    self-validating: h2530002's raw flags read hole-at-37 + member-at-38, which the
    swap turns into the dense 1..37 its fully-dense 296-cell store requires. 4020
    cells (popcount-exact across 5 data pages + 3 empty `np2`-padded tail windows the
    decoder never visits); year mapping (1996, 1997, 1995 in member order) confirmed
    by the HAART signature — "Infectious and parasitic diseases" 11.4 → 9.9 → 7.7
    across 1995 → 1997, the strongest decline in the table. Its pages also carry a
    24-byte-per-cause appendix after the value run (`b2 = 0x20`, extent-checked ≤,
    presence authoritative, ignored).
  - **`00060117` ("mixed-width") needed NO width machinery**: positional nesting
    already places Quantifier(2) OUTSIDE the straddling REGION(13, ipc 8 → 2 windows)
    in the directory — 4 pages `[84, 84, 88, 88]`, one width per page from each page's
    own marker, which `ivt_decode_page()` always read per-page. The actual blocker:
    `ivt_f2_dim_dir()` accepted a 1-of-4-entry TRUNCATED directory (the strict read
    stops at a mid-table `used < allocated` entry, and `n_entries − 4 ≤ 1` let it
    pass), hiding the ANNUAL(15) fiscal-year code array. It now returns the FULLEST
    ok() candidate; a read reaching the declared `n_entries` still wins at its
    precedence rank. 3120 cells; Canada = Σprovinces ±2 rounding, care split exact,
    count/rate ratio implies Canada's population 23.8M → 29M over 1979–1993.
  - **Cleanup — the gate is now the DESIGNED path, quiet**: `ivt_f2_descriptor_02()`
    no longer raises `canivt_descriptor_02` (byte-0 gate + file's own codebook; only
    the count probe stays loud and is now rarely reachable). **No geography
    dimension**: per design decision, the generation's REGION/GEOGRAPHY dims carry no
    geographic identifiers (no UID/DGUID/GEO_NAME/inline pattern), so
    `ivt_f2_geo_dim_index()` returns **0** and they stay ordinary, fully-labelled
    data dimensions — `metadata$geographies` is empty, cells carry no `geo` column,
    and every `gd == 0` consumer (geo_count/block_dir/marker_labels/tidy/print) holds.
    EN/FR block order is read from the generation's own dictionary vocabularies
    (`ivt_f2_dim_dict_en_first()` second pass: "Label"/"Etiquette",
    "Description_E"/"_F", "Desc"/"Descf", single-letter `01 45`/`01 46` E/F fields)
    replacing the loud content score; code-only reference dims label from
    `ivt_f2_code_array_members()` (extracted from the count read, shared);
    `ivt_f2_dir_is_text_block()` now guards `ivt_f2_dir_member_arrays()` so footnote
    prose can't pose as a short member run (00060123's ANNUAL "1986/1991"); the
    `56 00` marker name is cleaned of its `<name>2<name>` doubling
    (`ivt_f2_02_name_clean()`: "ANNUAL    2ANNUAL…" → "ANNUAL"); the descriptor-offset
    lookup inside the gate is a quiet probe (the block is only an auxiliary name
    source there — 00060129's `@32` relocation no longer warns).

## Completed work log

Milestones that were once on the "likely next tasks" list and are now done.
Kept for the record; the current architecture they produced is described in
`CLAUDE.md`.

- **Paging geometry is DECLARED metadata — the doubled-window mystery closed
  (2026-07-23).** Hunting for the declaration the Table-023 "doubled-window"
  fallback was missing (coverage.md had flagged: "if the layout is real there
  must be a declaration for it in the header/descriptor"), a corpus-wide census
  of the `81 02 <u16> 16 00` member-code blocks (and the `08 00` time tables)
  found that their leading u16 is a per-dimension **member-slot allocation**,
  present for EVERY dimension of EVERY corpus table across all generations. It
  equals `nextpow2(count)` on every supported dimension except exactly one —
  Table-023's Hours, **32 slots for 10 members** — which is precisely the lone
  table that needed the doubled directory: windows-of-4 over 32 allocated slots
  = 8 directory slots. `ivt_layout()` now pads every nesting level (presence
  bits and directory strides) to the declared allocation
  (`ivt_f2_dim_slot_alloc()`), falling back to `nextpow2(extent)` only when the
  declared value cannot hold the members (chunked >1024-member dims declare a
  block-local 1024). Byte-identical corpus-wide (`alloc == nextpow2` everywhere
  else); Table-023 re-validated at its exact 5,771,932 cells with **no probe and
  no `canivt_survey_directory` fallback**; `ivt_survey_double()` (the page-size
  signature probe) deleted. A full directory scan confirmed the allocation
  padding is genuinely empty (every larger-than-minimal page sits inside the
  real member cartesian). Retro-confirmation: the deferred Table-024 "ipc
  mismatch" (in-page occ = 2, 17 windows vs the modelled 4/9) is exactly what
  the allocation rule predicts (Hours 32 × Timeseries 32 = 1024-bit inner
  block). Same pass: (a) the dense-array pre-records marker is accepted as the
  single-bit-byte CLASS (Table-023's English Sex block carried the
  never-catalogued `0x04` and was silently dropped — the dimension labelled
  French; now EN/FR correct); (b) `ivt_f2_dim_dict_en_first()` reads the
  remaining declared `04`-gen language vocabularies (`Description`/
  `Description_FRA`, `English`/`French|Français`, bleed-tolerant leading-boundary
  match inside the tagged `22 00` dict block) — the content-score
  language fallback now fires on ZERO survey dims with a declared pair (only
  accs's "Fiscal year", whose dict names the fields after the dimension itself
  in each language, stays loud). Known remaining gap, documented in coverage.md:
  the `16 00` block's mid-section (likely per-slot flags) is undecoded — it
  would subsume the `ivt_f2_dim_slot_expand()` deleted-slot margin and fix accs
  Offences' 64-labels-for-40-members alignment.
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

### Onboarding backlog — Stage 1 pass (2026-07-21) — DONE

A random re-sample of 20 previously-unseen catalogue tables (10 StatCan + 10
Borealis) surfaced 7 that did not read strict-clean (see
[`onboarding-backlog.md`](onboarding-backlog.md)). One Stage-1 fix, two small
general changes, cleared **4 of them**; corpus ledger FAIL 0 / PASS 257.

- **Geography-LAST prose-bleed name recovery.** The 2001 profile lineage
  `95F0490XCB01006` (Borealis SP3/NIQKF5) read as *unsupported*. Its byte-walk
  already computed the right member counts from the framing — Profile
  `6d 02 0a 01` → `0x6d + 0x02·256 = 621` (the name even says "Profile of Census
  Subdivisions **(621)**"), Geography `11 04 0b 01` → `0x11 + 0x04·256 = 1041`
  (matching the `nv ≈ 1041` on the value pages) — both chunked >256-member
  codebooks (Geography: NL/QC/ON/AB 256-chunks + a 17-member BC tail; Profile:
  256+256+109). But `ivt_f2_descriptor_name()` returned NA for the Geography
  record ("Geograph**yens (pGeography**tut de r": two "Geography" copies
  interleaved with French prose), because its reoccurring-prefix fallback (case e)
  was gated to `first_record` — and the profile lineage stores geography **last**.
  The record was dropped, the descriptor rebuilt from the slot table, and the slot
  rebuild caps each dimension at its **first 256-member chunk** → Profile(256),
  Geography(256) → wrong layout → gate reject. Fix: `descriptor_name()` gained a
  `type` argument and case (e) now fires for any u16-count **geotype** record, not
  only the first. Recovered "Geography"/"Profile of Census Subdivisions (621)",
  the framing counts stand, and the table decodes **538,064 cells strict-clean**.
  Validated by the 2001 labour-force accounting identities (In LF = Employed +
  Unemployed; Total 15+ = In LF + Not in LF) holding across all 1041 geographies
  to ±10 (base-5 random rounding).
- **Exact-fit pre-flight only for `b2 == 0 && b3 == 08`.** The gate demanded an
  exact page/entry-size fit for `b2 == 0 && b3 <= 09`. But `b3 == 09` pages carry
  a 32-byte auxiliary head **and**, on some vintages, an allocation/suppression
  tail after the dense value run: 95F0490's `b3 == 09` pages leave 8–80 byte tails
  (a denormal-≈0 pad or a sparse absent-cell mask — never a value). Decoding is
  presence-authoritative (exactly `popcount` values from the run start), so the
  tail is inert; only the pre-flight over-rejected. Relaxing exact→`<=` for
  `b3 == 09` cannot break a table that was exact (exact satisfies `<=`), so the
  2006 vintage (which exact-fits its `b3 == 09` pages) is unaffected.
- **Cascade.** The two changes cleared three more backlog tables with no further
  work: `97-555-XCB2006058` (2006 census, twin lineage of the supported 97-563;
  the exact-fit relaxation cleared its `b3 == 09` tails → **4,166,909 cells
  strict-clean**; Sex Total=M+F within ±11 on 96.7% of count cells, the residual
  being exactly the non-additive income medians/averages/SEs, members 795–830),
  `95F0378XCB01004` (**859,903 cells**, still on the `canivt_descriptor_from_slots`
  fallback because a footnote bleeds into its descriptor; Sex identity 99.6% within
  ±11), and `95F0489XCB01007` (the geotype name fix removed its
  `canivt_descriptor_lenient` fallback with the cell count unchanged at 86,696 →
  now strict-clean).

### Onboarding backlog — Stage 3: `97-563-XCB2006058` (2026-07-21) — DONE

The Borealis 8-dim single-area extract `SP3_AAV9RM_97-563-XCB2006058`
(Geography(1)×Age(7)×…×Year(2), 75,913 cells) read via **two** loud fallbacks: a
`canivt_fallback` DGUID byte-scan **then** `canivt_geo_datadim`. The backlog
hypothesis ("the geo block directory must resolve the DGUID member blocks") was
wrong — the geography's `81 02` field dictionary declares only **name** columns
(`English Desc / Desc française / short name`) and **no UID**, so there is no
DGUID in the file to resolve (this custom extract's single area is "Canada (01)
20000", uid genuinely NA). The double warning was purely the dispatch order: the
uid-only reader (`ivt_f2_geo_read()` step 5, `ivt_f2_geo_uids()`) ran its byte
scan — and fired its loud "did not resolve the DGUID member blocks" fallback —
before the data-style reader (step 5b, `ivt_f2_geo_datadim()`) picked the table
up. Fix: gate step 5 on `enc != "custom" || ivt_f2_geo_field_has_uid()`, so a
`custom`-encoding geography whose field dictionary declares no `UID/IDU` column
skips the DGUID scan entirely and routes straight to the data-style reader. The
uid-bearing custom exports (EO3278 `UID/IDU`, EO2654) keep step 5 via
`has_uid == TRUE`; the chunked DGUID tables (98-10-0023/0013) are `enc == "dguid"`
and unaffected. Now a single documented `canivt_geo_datadim` fallback (geography
read metadata-driven from the file's own field dictionary + label blocks, no UID);
`strict_clean = FALSE`, cells unchanged at 75,913.

### Onboarding backlog — Stage 4: `table_6_c-ivt-2007` (2026-07-21) — DONE

The Borealis UCR crosstab `SP3_HHP4CZ_table_6_c-ivt-2007` (byte 0 `0x04`,
"Clearance status for all incidents, Selected police services, 2007") read as
*unsupported* — the descriptor walk recovered **0 dimensions**. It is the UCR
survey lineage (sibling of the onboarded `ucr2.2_3-2006`), and its descriptor
block is present but **inverted**: the four doubled-name records
(`Geography`/`Clearance Type`/`Offences`/`Year`) sit BEFORE a signature ending
`81 01 20 00 f0 .. .. 80 01` (not `80 03`/`80 ff`), framed off an `81 02 04 00`
sub-header. The forward walk from `D` finds nothing (records precede it); the
inverted-retry anchors only on `81 02 03 00` (misses `81 02 04 00`); and
`ivt_f2_dims_from_slots()` (the "footnote-bleed" rebuild) declines because its
name-keyed member counter cannot size the 1-member `Year` reference-period
dimension (whose `56 00` name marker is the doubled `Year2YearAnnées2Années`).
The header slot table, though, lists all four dimensions cleanly. Fix:
`ivt_f2_descriptor_impl()` now falls back to `ivt_f2_descriptor_from_slots()` (the
NAME-INDEPENDENT slot member counter, which sizes each dimension from its codebook
member array directly) when the walks recover fewer than the authoritative count;
adopted only at an exact count match, so it cannot fire on a table the walk
already read. Plus `ivt_f2_dim_marker_name()` now applies the `56 00`
survey-name-marker cleaner (`ivt_f2_02_name_clean()`, gated on the `56 00`
sub-marker) so `Year` comes out clean. Reads Geo(1)×ClearanceType(19)×
Offences(187)×Year(1) → **1,952 non-zero cells** (`canivt_descriptor_from_slots`,
`strict_clean = FALSE`, as with the other survey-lineage tables). Validated: the
clearance-status accounting identities (Total = Not cleared + Cleared by charge +
Total Cleared Otherwise; the nested Cleared-Otherwise = Σ(5..9) and
Other-Clearances = Σ(10..19) subtotals) hold EXACTLY across all 177 offences;
national total 2,192,656 incidents.

### Onboarding backlog — Stage 5: `PRSIC1dec1999` (2026-07-21) — DONE, strict-clean

The Borealis `SP_XWJR2W_PRSIC1dec1999` (byte 0 `0x02`, provincial SIC
establishment counts by employment size, December 1999) is an EARLIER `02 00 20 00`
container generation than the onboarded survey gen — `ivt_f2_descriptor_02()`
found nothing. Root cause was NOT a bespoke descriptor framing but three small
general gaps, each of which alone blocked the read:

1. **Directory with interior null holes.** The "Employment size ranges" dimension's
   block directory declares 19 slots but stores only 14 well-formed entries with
   **5 interior `(0,0)` null holes** — beyond the fixed 4-null tolerance
   `ivt_f2_dim_dir()` allowed, so its directory (and hence the whole descriptor)
   would not resolve. Fix: accept a short read when EVERY one of the `want`
   declared slots is either a well-formed entry we captured or an explicit `(0,0)`
   null (`complete_with_holes()`) — the directory is then fully accounted for (a
   wrong pointer shows garbage slots, so this cannot admit a misread).
2. **`0x10` dense-array marker.** That dimension's 11-member array is a bit-headed
   dense `[81 01][u16][bitstream][marker]<records>` array whose pre-records marker
   byte is `0x10` (the modern chunked tables use `0x80`/`0x01`), so
   `ivt_f2_dir_entry_members()` returned NULL and the count read as 2. Added `0x10`
   to the accepted marker set (records parse self-validatingly) → 11 members
   (Total(A), Indeterminate(B), Subtotal(A−B), 1-4 … 500+). Catalogued in
   `markers.md`.
3. **`English Label` schema vocabulary.** This generation names its label columns
   `English Label` / `Etiquette` (not `English Desc` / `Desc Français`), and on two
   of three dimensions binary bleed immediately follows the field name
   (`English Labelco`, `…nd`), breaking the `\bLabel\b` trailing boundary in
   `ivt_f2_dim_dict_en_first()` → the loud content-score language fallback. Anchor
   on the `English Label` phrase (leading boundary only) instead.

Reads PROV/CAN(14)×DIVISIONS(19)×EMP.SIZE(11) → **2,652 non-zero cells,
strict-clean** (no fallbacks). Validated: Canada = Σ provinces, DIVISIONS Total =
Σ divisions, and the employment-size hierarchy (Total(A) = Indeterminate(B) +
Subtotal(A−B); Subtotal = Σ 8 size ranges) all hold EXACTLY; Canada/Total/Total(A)
= 1,996,322 establishments. **The onboarding backlog is fully cleared.**

### Second random sweep (2026-07-21) — two Borealis `04`-gen survey tables — DONE

A fresh random sample of 10 StatCan + 10 Borealis catalogue tables not yet in the
corpus. All 10 StatCan decoded; of the 10 Borealis, 5 decoded, 3 were 403-blocked
(access-restricted OCDMVE dataset — an access grant, not a decode gap), and two
`04 00 20 00` survey tables failed. Both are now onboarded.

**`SP3_THNM6I_00040231`** (Census of Agriculture overview, "Computers used for
farm business", CANSIM 004-0231). The descriptor pointer `@32` points at the
IDENTITY block ("Source: Statistics Canada (tableau CANSIM 004-0231 …)"), NOT the
descriptor — its real `81 02 03 00` named-record descriptor block (listed in the
master directory) sits **after** that identity block. The sibling `00040240`
points `@32` just *past* the same descriptor block, so the existing inverted
retry (which scans **backward** from D for `81 02 03 00`) reaches it — but
00040231's D is *before* its block, out of the backward window. The slot-table
rebuilds (`ivt_f2_dims_from_slots`/`descriptor_from_slots`) also come up empty
because the trailing "Date" reference dimension carries no member array (this is a
2-D table, Geography × Computers, "Date" folded). Fix: a **forward /
master-directory variant of the inverted retry** in `ivt_f2_descriptor_impl()` —
after every slot rebuild has failed, walk each `81 02 ..`-headed master-dir block
forward and adopt the first yielding ≥ 2 doubled-name records. Placed LAST so it
never pre-empts a slot rebuild (table_6_c-ivt-2007's Year(1) still rebuilds from
slots first, not mis-sized from an `81 02 04 00` sub-header). Reads
Geography(2180) × Computers(3) → **6,216 cells** (`canivt_geo_datadim`, as the
sibling — bare-code agriculture geography, no DGUID). Validated: Canada 122,678
farms use computers / 114,416 use internet / 92,154 high-speed (high-speed ⊆
internet ✓).

**`SP3_Q2JJJO_table_5_c-ivt-2008`** (UCR crime, sibling of the onboarded
table_6_c). Two stacked container gaps, both about ALLOCATION PADDING the `04`
families were assumed never to use:
1. **`[used][allocated]` directory entries.** Every page-directory record stores
   `s1 = used < s2 = allocated` (16-byte-aligned slack, 0–32 bytes), which
   `ivt_dir_entry()` accepted only for the `02`-gen (byte 0 `0x02`). So `@558`
   (6207, the real directory) validated no entries and `ivt_idx0()` fell to the
   constant → pre-flight `valid = 0`. Fix: accept `used <= allocated` with a
   bounded (≤ 256 byte) slack for all families, taking the used size.
2. **Padding tail on `b2==0/b3==08` pages.** Even after the directory resolved,
   the pre-flight's EXACT-FIT rule rejected the first page: the value run ends
   3292 bytes in but `s1 = 3308` (a 16-byte alignment tail) on a page with no head
   / no trailer, where exact fit was required. Relaxed to no-overrun + ≤ 32 byte
   undershoot (decoding stays presence-authoritative, so the tail is inert).

Reads Geography(1) × Accused Status(9) × Age Accused(105) × Offences(215) × [Year] →
**35,237 cells**; widths are mixed per page (`84`=int32 / `82`=int16), which the
decoder already handles. Validated: total accused (Total age × Total status ×
offence 1) = 1,110,371. **Known label limitation** (documented, `canivt_geo_datadim`
+ fallbacks, not strict-clean): the Offences dimension's name block carries **216**
records against **215** codes/members, so the reader keeps the stable numeric code
labels rather than risk a mis-aligned name mapping (the geography name is junk HTML
in this single-area viewer export — the same accepted quirk as table_6_c).

### Census of Agriculture 2016 `00040200` / `00040207` (2026-07-22) — the `01 02` facet framing + square-bracket inline geography

A fresh 10 StatCan + 10 Borealis sweep flagged 4 Borealis tables. Two — the
Census of Agriculture 2016 crosstabs `SP3_WLOGGX_00040200` (number of farms by
NAICS × Canada/regions/CDs × 2011/2016) and `00040207` (manure practices) —
failed the family gate, both for the **same** reason.

Their descriptor block reads only **2 of 3** dimensions, so the parse fell back to
the slot-table rebuild (`ivt_f2_descriptor_from_slots`), which sizes the chunked
geography from its largest single member array — one **256-member chunk** — capping
the real 2,568 geographies at 256. With geography under-counted the directory
cartesian cannot span the 161 pages and `ivt_page_preflight()` honestly rejected.

The dropped dimension is the **`Date (2)` facet** (2011/2016). Its descriptor
record uses a double-marker variant of the reference-period framing:
`[type][count] 01 02 <doubled name>` — `13 02 01 02 DateDate` — where the byte
after the `01` is a **`02`** name-copy marker, not the `01` of the
`01 01`-terminated "Year (2)" record (`0e 02 01 01`). The `01`-only descriptor
anchor skipped it. Fix: admit the `01 02` framing in `ivt_f2_descriptor()`'s
`anchorA` (markers.md §D), reading its `[type][count]` exactly as the `01 01`
record. **Gated on a small facet count (`count < 0x20`)**: the `01 02` marker also
appears mid-prose where a doubled name butts against a previous name's tail — the
sibling `00040231` (single-date overview) frames `…business` + `01 02 DateDate`
with the count byte landing on `s` (0x73), a spurious record whose garbage count
had regressed 00040231. Its `Date` is a genuine **1-member** facet (a single
reference date; its `81 02 01 00 08 00` time table allocates one slot) that
collapses harmlessly, so **not** matching it keeps 00040231's correct 2-dim /
6,216-cell decode (Geography × Computers, Date folded) — confirming the earlier
"Date folded" note was right for that table.

With all 3 records found, geography reads its real u16 count **2,568** directly
from the descriptor (`08 0a 0c` = 2568, type 0x0c). Geography stores its code
INLINE in **square brackets** — "`Canada [000000000]`", "`Division No. 1,
Newfoundland and Labrador [CD100101000]`" — a new inline shape (`IVT_F2_INLINE_PAT3`,
same as the paren code-last form but with `[...]`). The data-style geography reader
(`ivt_f2_geo_datadim`, reached because the interleaved index/uid blocks defeat the
inline reader's chunk walk) now splits it into clean bilingual `geo_name` +
`geo_uid` when ≥ 90% of labels carry a bracketed code. Loud `canivt_geo_datadim`
(`strict_clean = FALSE`).

Cell-exact validated: `00040200` **92,584 cells** — Canada total farms 2011 =
**205,730** / 2016 = **193,492** (the published Census-of-Agriculture totals), and
Beef(36,013) + Dairy(10,525) = Cattle(46,538). `00040207` **55,020 cells** —
Canada farms reporting manure applied 2016 = 66,227 = Σ 10 provinces exactly, and
solid-manure area 2,483,220 acres × 0.404686 = 1,004,912 ha ≈ decoded 1,004,923 ha.
Corpus FAIL 0.

### LFHR `Table-023` — the doubled-window survey directory (2026-07-22) — CELLS VALIDATED, GEOMETRY OPEN

`SP3/NAZQV2/Table-023` (Labour Force Historical Review 2009) is the first
*multi-dimensional, long-time-series* survey table: Geography(11) × Sex(3) ×
Class of worker(3) × Occupation(33) × Hours(10) × Timeseries(276 monthly,
1987-01…2009-12). The single-area siblings (`Table-051`, UCR, justice) never
stress multi-dim paging, so this exposed two new things.

**(1) The u16 `alloc`.** The Timeseries member table is `81 02 <alloc-u16> 08 00`;
`alloc = 512 ≥ 256`, so the alloc-high byte is `0x02`, not `0x00`.
`ivt_f2_time_members()` had guarded `raw[off+4] == 0x00` (i.e. `alloc < 256`) and
skipped the block → Timeseries unsized → `descriptor_from_slots` declined →
unsupported. Reading `alloc` as a full u16 (the `08 00` sub-marker at `off+5/off+6`
still tags the block) recovers the 6-dim descriptor. `markers.md` §E.1 updated.

**(2) The doubled window (the RE).** With the descriptor recovered the pow2
`ivt_layout()` decodes plausible-looking but WRONG cells: the *in-page* Timeseries
is right (Canada total employed 11,714→16,826k, matches published LFS) but the
directory-paged dims scramble. Reverse-engineered from the raw directory: within a
super-block the pages run as triples-of-8, super-blocks step by 2048 in a
period-4 pattern (3 present + 1 pad = Sex(3) padded to 4) repeated 11× (Geography).
That gives strides `[win 1, occ 8, class 512, sex 2048, geo 8192]` — **exactly the
census pow2 model `[1,4,256,1024,4096]` but with the innermost paged (straddle
window) dimension padded to DOUBLE its nextpow2** (3 hours-windows in 8 slots, not
4), which cascades ×2 to every stride above it. Validated by 3-way additivity: sex
(Both 453,700.2 = M 278,980 + F 174,720), geography (Canada = Σ 10 provinces to
base-100 rounding), all 11 provinces named in order, 276 months.

The detector `ivt_survey_double()` (decode.R) is purely structural (no name/type
branch) and reads only the page-directory **size signature** — container metadata
(the 8-byte entries' u16 size fields), never the cell presence bitmaps. This is
what makes it robust: it does NOT depend on the very layout hypothesis it is
testing. A window-padding page carries no values, so it is the **minimal page
allocation** (Table-023: 392 bytes, marker `88 01 20 08`, `size − vstart = 128`
fixed slack) — strictly smaller than any page that stores cells (4744..9092).
`minsize` is self-calibrated per table from block 0's floor (no hard-coded size).
An early weak version (accept a valid *marker* at the doubled corner)
false-positived on six large pow2 profile/crosstab corpus tables; the final gate
requires ALL of: the doubled corners hold a **data page** (larger than `minsize`,
not merely a valid marker byte a big file can hit by coincidence); the **pow2
position** of paged-dim-2's member 1 is EMPTY (minimal) while its **doubled
position** is a data page; and the window-padding slots `[win, 2·win_slots)` of
block 0 hold no data page (so a table whose true window count is larger — a
different record packing — is not silently halved). The earlier version probed
`ivt_f2_record_present()` popcounts at the same slots; the size read is equivalent
on the corpus but cheaper and independent of the presence interpretation. Corpus
stays `survey_double = FALSE` throughout (FAIL 0, PASS 270). An extent guard in
`ivt_page_preflight()` honest-rejects any
long-series directory that overshoots the pow2 model but fails the window check, so
an unmodelled shape can never silently mis-decode. Reads **5,771,932 cells** via
`canivt_descriptor_from_slots` + `canivt_survey_directory` (both `canivt_fallback`,
`strict_clean = FALSE`). The sibling `Table-024` (Occupation
straddles, Hours+Timeseries both in-page) packs its record with a different `ipc`
than `ivt_layout()` computes (in-page occ = 2, 17 windows) — a separate puzzle, not
in the corpus, honest-rejected by the extent guard.

**(3) The Hours dimension: 10 members, not 9 (2026-07-22, fixed).** The first
read shipped Hours with **9** members and **4,986,342** cells — dropping the 10th
member ("Average usual hours (main job)", 785,590 cells) and shifting every Hours
label by one. Root cause was NOT the directory doubling (its over-allocation
padding is genuinely EMPTY, verified by a full directory scan: every occupied
entry decomposes cleanly into used ranges). It was the codebook: the descriptor
block (offset 1568, `81 02 06 00`) reads `0c 0a 05 01 "Hours worked"` — count
`0x0a` = 10 — correctly, but the forward master-dir walk recovers only 5 of 6 dims
(Timeseries has no standard `01` name anchor), so `length(dims) < ndim` and
`ivt_f2_descriptor_from_slots()` pre-empts it. That path counts members via
`ivt_f2_slot_member_count()`, and Hours stores its member **descriptions** in a
bit-headed dense array `[81 01][f8 00 bitmap alloc][32-byte bitmap][20 marker][10
Pascal records]` whose post-bitmap marker byte is **`0x20`** — a variant
`ivt_f2_dir_entry_members()` did not admit (it required `{0x80,0x01,0x10}`), so it
returned NULL and the count fell back to the member **CODE** array, which has only
9 entries ("Total employed" carries no code). Widening the dense-array reader to
accept the `0x20` marker (this `04`-gen lineage's member-description framing;
markers.md §F updated) restores Hours = 10 → cells **5,771,932**, labels
un-shifted ("Total employed" first, "Average usual hours (main job)" last).
Validated by additivity on Canada/1987-01: Σ 7 hour-buckets = 11,714.4 = Total
employed ✓, and Total usual hours 430,271.4 / 11,714.4 = 36.73 ≈ file's
"Average usual hours" 36.7 ✓.

**NOT CLOSED — the geometry is provisional (requires further investigation).**
The cells are right, but two things keep the *model* open: (1) the doubled window
WASTES half the directory (3 windows in 8 slots, cascading ×2) — out of character
for these tightly pow2-packed containers, and a hint that an un-modelled nested
level (or value/flag pair, or derived-member sub-axis) occupies the "wasted" slots
that I am collapsing into a phantom ×2 stride. (2) `ivt_survey_double()` now reads
the directory **size signature** (container metadata — the padding pages are the
minimal allocation), not the cell presence bitmaps, which is more robust; but it
still infers the doubling from the directory *structure* rather than a **declared**
marker. If the doubling is real there should be a field in the
header/descriptor/slot table that DECLARES it, and the parser should key off that.
Until such a declaration is found it stays `canivt_survey_directory`
(`strict_clean = FALSE`), not a validated primary path.

**One sibling ruled OUT (2026-07-22): the `accs` table is NOT this phenomenon.**
`accs` had been deferred as `Table-024`-class (same doubled directory), and its
window over-allocation was cited here as corroboration. It turned out to be a
**DELETED MEMBER SLOT** in a paged dimension (Sex: 6 physical slots, 5 members,
interior slot 3 deleted) — an INTERIOR gap with **no directory entry**, structurally
different from Table-023's **present-but-empty** window padding pages (392-byte
minimal allocations). See the `accs` section below; it decodes clean pow2, no
`survey_double`. So Table-023's empty-window over-allocation is now MORE isolated,
not less — the deleted-slot explanation does **not** transfer (every Table-023
dimension has an exact codebook count). `Table-024` is unverified (not in the
corpus); it may be a deleted slot like accs, an `ipc` mismatch, or the genuine
padding of Table-023 — do not assume. Full write-up + marker-hunt candidates in
coverage.md "Open concerns".

### `accs` adult criminal court — the "doubled directory" was a DELETED MEMBER SLOT (2026-07-22) — SOLVED, additivity-validated

`SP3/MRVVPK/accs-number-of-cases-and-charges-by-type-of-decision-1994-1995-to-2009-2010`
(7 dims: FiscalYear(16) × Charge/Case(5) × AgeGroup(7) × **Sex(5)** × Offences(40) ×
Geography(17) × Decision(6)) is a `04`-gen survey table that had been **deferred as
`Table-024`-class** (its page directory spans the DOUBLED cartesian, `k = 0 … 63 916`
vs the pow2 32 768). It is now **fully onboarded — 4,573,026 cells, additivity-exact**
— and the finding **overturns the `Table-024`-class hypothesis for this table**: the
doubling is **not** an un-modelled straddle sub-axis / wasteful ×2 pad, it is a
**DELETED MEMBER SLOT** in the Sex dimension.

**The evidence.** Sex's codebook member-label array carries **SIX** records —
`Total | Males | Females | Company | Unknown | Company` (FR
`Total | Hommes | Femmes | Sociétés | Inconnu | Sociétés`) — while the descriptor
declares **5** members. The physical layout addresses members BY SLOT and pads to
`nextpow2(extent)`: Sex occupies slots `{0,1,2,3,4,5}` with **slot 3 deleted** (it
retains its "Company" label but carries no data). Reading Sex as its logical count
(3 or 5) mis-nests the whole paged geometry — the missing slot 5 (real "Unknown"
data) is pushed past the count, and the block above cascades — which is exactly the
"doubled directory" symptom. Using Sex's physical **extent 6** gives a **CLEAN pow2
nesting** `estride [1,8,64,512,4096]`, cartesian 65 536, `survey_double = FALSE`,
and every additivity identity holds exactly:
- **Sex**: Males(664 830) + Females(106 433) + Company(32 991) + Unknown(5 159) =
  **Total 809 413** (at Canada / Total-offence / Total-decision / 1994-1995), and
  the deleted slot 3 decodes **0 cells**;
- **Age**: Σ age groups = Total; **Charge/Case**: Single + Multiple cases = Total
  Cases (361 788).

**The bug chain that hid it.** (1) The descriptor's FIRST record, the year
dimension "Fiscal year", frames its doubled name with a **bare `02` separator**
(`10 04 02 Fiscal yearCASEYEAR`) instead of `01` — the standard `01`-anchor
skipped it, so the strict walk found 6 of 7 dimensions and fell to the
slot-table rebuild (`ivt_f2_descriptor_from_slots()`), which miscounted Sex as
**3** (its member-label array is a DENSE `81 01` block the reader could not parse —
see below). (2) Sex's dense label array uses the post-bitmap marker byte **`0x08`**,
absent from `ivt_f2_dir_entry_members()`'s accepted set `{0x80,0x01,0x10,0x20}`, so
the label records (and hence the true slot extent 6) were unreadable.

**The fix (three small, general, metadata-driven changes).**
- `ivt_f2_dir_entry_members()` admits the `0x08` dense-array marker (markers.md §F),
  so the 6-record Sex label array parses — the physical extent is now readable.
- `ivt_f2_descriptor()` (`anchorA`/`bare02`) admits the bare-`02` name separator on
  the standard `[count][type] 02 <name><name>` framing (markers.md §D), so the strict
  walk finds all 7 dimensions; accs then reads through the designed
  `canivt_descriptor_lenient` path (its names are display+description pairs —
  "Offences" + "Common Offence Classification" — the doubled-name matcher rejects, so
  the slot-marker names are used) with the descriptor's own authoritative counts.
- `ivt_f2_dim_slot_expand()` (dimdir.R, called from `ivt_f2_dim_count_reconcile()`)
  compares each dimension's descriptor count against its codebook member-label
  record count and, when the codebook holds a SMALL surplus (≤ 2 — a deleted slot or
  two, not a mis-parsed footnote block), expands the count to the physical extent.
  LOUD (`canivt_deleted_slot`), so strict mode surfaces it; `strict_clean = FALSE`.

The layout's existing slot-aware machinery (`$slots`/`slot_pos`/`ext`, built for the
survey time dimensions) needs no change — extent 6 drives the nesting and the deleted
slot falls out empty. Sex is surfaced with its 6 physical slots (the deleted slot
appears as an empty "Company" member, a faithful reflection of the file's allocation).

**This does NOT explain `Table-023`.** The two tables looked identical (both a
doubled page directory) but have **different root causes**, confirmed by direct
comparison:
- **accs** — the deleted Sex slot leaves **NO directory entry** at its position
  (an INTERIOR gap: occupancy `{0,8,16,32,40}` per 64-block, **24 absent**). Every
  dimension's real data is captured once the extent is right; `survey_double` is
  NOT engaged.
- **`Table-023`** — every dimension has an **exact** codebook count (no deleted
  slot). Its doubling is on the straddle **window** (3 real Hours-windows allocated
  **8** directory slots): slots 3–7 are **present** directory entries pointing at
  real **minimal 392-byte EMPTY padding pages** (a genuine ×2 over-allocation the
  writer physically wrote), which is exactly the size signature `ivt_survey_double()`
  keys off. Table-023 is UNCHANGED by the accs fix — still 5,771,932 cells, still
  `canivt_survey_directory`, still genuinely OPEN (see the Table-023 section above).

So the accs onboarding **narrows** the doubled-window mystery rather than solving it
wholesale: accs is off the list (deleted slot); `Table-023`/`Table-024`'s empty
window over-allocation remains the open case.

### `CDNAIC3_LOC-1` Business Patterns — the `canivt_skipped_pages` false alarm & the geometry-validated tripwire (2026-07-22) — DONE, additivity-validated

`SP3/PAWNKX/CDNAIC3_LOC-1` (Canadian Business Patterns, December 2010; the
"Structure des industries canadiennes 1988-2014" Borealis dataset) is a 3-dim
`04`-gen crosstab Geography(314) × SUB-SECTORS(26628) × EMP.SIZE(11) — 3-digit
NAICS × location × employment-size range. It **decodes** (133,217 cells via the
`canivt_descriptor_lenient` + `canivt_geo_datadim` custom-lineage fallbacks) but
was flagged because `ivt_decode()` also raised `canivt_skipped_pages`: **20,523
directory entries pointed at unrecognised markers**, suggesting a large
under-decode.

**It was a false alarm — the decode is complete and correct.** The directory is
very SPARSE: only **282 real data pages** (21 of 314 geographies carry data, over
sparse sub-sector windows). `ivt_decode()` walks the full paged cartesian —
209 sub-sector windows × 314 geographies = 65,626 coordinates — so the ~65k absent
combinations must resolve to "no entry". Most (44,821) hit zero/invalid directory
slots (→ `NULL`, correctly ignored). But 20,523 landed on bytes that
`ivt_dir_entry()` accepts (two agreeing u16 size fields, in-range offset) yet point
at CODEBOOK/member-label text — only **644 distinct offsets**, hit repeatedly. All
644 were checked: 250 have b0 `0x00`, the rest are ASCII digits/letters/spaces or
codebook markers (`01 01`, `81 01`, `82 01`, `84 01`); the 4 superficially
page-like ones are a length field (`a8 00 00 00 …`, invalid `b3`) and `82 01`/`84 01`
codebook blocks. **None is a real data page.** The `SUB-SECTORS = 26628` count is
correct too, not a misread (decoded cells genuinely use sub-sector ids up to 26628,
1,343 populated — NAICS3 × ~266 locations).

Ground truth: **byte-exact internal additivity** on the decoded values, using the
EMP.SIZE structure (member 1 Total = member 2 Indeterminate + member 3 Subtotal;
Subtotal = Σ of the size ranges 1-4 … 500+). Across all 21,681 (geography,
sub-sector) groups: `Subtotal = Σ(ranges)` holds **21,681 / 21,681 with max
deviation 0**, and `Total = Indeterminate + Subtotal` holds **21,675 / 21,681**
(the 6 exceptions are tiny totals at the anomalous geography 306 with
source-suppressed components). Additivity this exact is impossible unless the
sub-sector window math and value placement are correct — so 133,217 cells is a
complete, correct decode.

**The fix is to the tripwire, not the decode** (`ivt_skip_is_lost_page()`,
decode.R). The old skip check counted EVERY directory entry that failed
`ivt_f2_is_marker()` — but the four marker bytes cannot separate a real page with
an unrecognised head from a codebook block coincidentally addressed by a sparse
over-walk (a codebook `84 01 00 02` shares b0/b1 with an int32 page, and both a
codebook block and a page with a doctored/novel head have a `b3 ∉ {08,09,0a,0c}`).
So the refined check validates the target's **page GEOMETRY**: it must be a value
page in b0 (recognised width nibble, page high nibble) and b1, whose fixed
presence record AND its tightest possible value run (`4 + rec_bytes + nv·width`,
trailer/head = 0) fit the entry's allocated size. A real page fits by construction
even when its marker is unrecognised; a codebook block does not (allocation below
`4 + rec_bytes`, or the presence bits overrun). The tally is also deduped by
offset (distinct lost pages, not coordinate visits). Result: **0 false skips on
`CDNAIC3_LOC-1`**, while the deliberate `98-400-X2016203`-doctoring unit test
(a real page with `b3` set to `0x0b`) still fires `canivt_skipped_pages` (its
presence + value run fit its size exactly, 7772 bytes). Corpus regression FAIL 0
(277), unit FAIL 0 (1078).

**Known minor limitation (deferred):** the EMP.SIZE metadata **labels** are shifted
— the codebook stores them as a fixed-width, length-prefixed array
(`[80 10][len]"        Total        (A)"[len]" Indeterminate    (B)"…`) that the
generic scan fallbacks (`ivt_f2_marker_labels()` / count-keyed) misread, dropping
"Total (A)" and bleeding footnote prose. The VALUES and member-id structure are
correct (additivity proves it); only the human-readable labels for this one
dimension are wrong. A proper fix needs a reader for this Business-Patterns
fixed-width member-array framing in the shared codebook path, which carries
corpus-wide regression risk disproportionate to a cosmetic shift, so it is left as
a follow-up.

**Ground truth — how to (re-)validate this table and the whole CDNAIC/Business
Patterns lineage** (needed when the label follow-up lands, and reusable for any
Business-Patterns crosstab):

1. **Internal additivity (primary, no network).** The EMP.SIZE dimension is a
   self-checking total structure — with the CORRECT member order (member id 1 =
   `Total (A)`, 2 = `Indeterminate (B)`, 3 = `Subtotal (A−B)`, 4…11 = the size
   ranges `1-4`, `5-9`, `10-19`, `20-49`, `50-99`, `100-199`, `200-499`, `500 +`):
   `member1 = member2 + member3` and `member3 = Σ(member4…member11)`. Pivot the
   decoded `x$cells` by `emp` within each `(geo, sub)` group and assert both
   identities (expect 21,681/21,681 exact on `Subtotal = Σranges`; the handful of
   `Total ≠ Indet + Subtotal` exceptions are source-suppressed at geo 306). A
   correct label fix must reproduce this member ORDER — validate the new labels
   against these value positions, NOT the other way round. NB the current
   metadata labels are wrong (shifted), so do not use them as the join key.
2. **The Borealis dataset** — DOI `10.5683/SP3/PAWNKX`, "Structure des industries
   canadiennes, 1988-2014 [B2020]". `borealis_ivt_catalogue()` lists every file
   (cache at `ivt_cache_dir("data")/borealis_ivt_catalogue.parquet`, readable
   without a key). `CDNAIC3_LOC-1.ivt` (file_id 713248, 734 718 B) is
   **byte-identical in size to `CDNAIC3_LOCdec2010.ivt`** (file_id 49544) → this is
   the **December 2010** vintage; the plain `CDNAIC3.ivt` (497 KB) is the same
   NAICS-3 data WITHOUT the location cross. Downloading needs
   `BOREALIS_DATAVERSE_KEY` (`borealis_ivt_download()`); the PAWNKX files are not
   access-restricted (unlike the OCDMVE dataset).
3. **External published source** — StatCan Canadian Business Patterns / Business
   Register establishment counts by NAICS × employment-size range × geography
   (December 2010). Use only to spot-check absolute magnitudes; the additivity
   check above already proves the decode is internally correct and complete.

### Title/note-only descriptor — a QUIET slot read (2026-07-23)

`98-313-XCB2011025` (2011 age/sex/living-arrangements, 810 non-zero cells) surfaced
in a random sweep reading via a **loud** `canivt_descriptor_from_slots` fallback whose
message — "a footnote bleeds into the descriptor block" — implied a block-location bug.
It is not one. The descriptor block is located correctly (`@4148`, signature intact);
this table's descriptor simply carries **no per-dimension records at all**. After the
fixed header the block is one contiguous **2103-byte printable run** — the table title
with an embedded `Note: Population universe …` paragraph — running straight into the
codebook region (`81 02 02 00 …`). The dimension names live **solely** in the header
slot directories (`@824`: slots 1–4 → Geography(14)/Sex(3)/Age groups(6)/Living
arrangements(4), slots 5–32 null). The header `n_dim` field is garbage here too
(`38 08` → 2104), so the authoritative count comes from the leading run of populated
slot pointers (4).

Reading the dimensions from the slot directories is therefore the **correct, fully
metadata-driven** path (the `@824` slot table is the file's primary codebook anchor),
not a heuristic recovery — so it should not warn. `ivt_f2_descriptor_impl()` now
detects this variant structurally and adopts the slot rebuild **quietly**: gated on the
standard **and** lenient walks having recovered **zero** records, one large printable
run (≥ 400 bytes — a title/note blob, not a member name) opening within the header and
filling ≥ 85 % of the span up to the first `81 02 02 00` codebook marker, and the slot
table resolving **exactly** the authoritative count. This is strictly narrower than the
loud rebuild that follows it, so it only ever converts a would-be warning into a clean
read — it never changes a decode. It is structurally distinct from the genuinely
**mangled** case the loud path still covers (records present but a footnote spliced
*between* them, which leaves record framing breaking up the run — e.g. the survey
tables that legitimately keep warning: `h2530002`, `Table-051`, `table_5_c`). Corpus
regression unchanged (FAIL 0 / 282 pass, no cell count moved); `98-313-X` now
strict-clean.

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
