# canivt decode history

The narrative changelog: how each table / vintage was cracked, the per-table
validation record, and the derivations behind the invariants. Not needed
day-to-day — consult it for the *why*.

- [`CLAUDE.md`](../../CLAUDE.md) — the working guide (code map, key invariants, workflow).
- [`coverage.md`](coverage.md) — the **living** completeness tracker. Update *that*
  when a gap closes or opens, not this file.
- [`ivt-format.md`](ivt-format.md) — the authoritative byte-format reference;
  [`markers.md`](markers.md) — the byte-marker catalog.
- [`unsupported-formats.md`](unsupported-formats.md) — the current refusal ledger.

## Per-table validation record

Grouped by lineage. Cell counts are non-zero stored cells; "viewer" = the Beyond
20/20 HTML viewer via the internal `R/ground-truth.R`.

### The six reference tables (byte-identical to the two former decoders)

| table | shape | validation |
|---|---|---|
| **98-10-0241** | 7-dim, Period straddles, 166 geos | 7,489,464 cells exact vs CSV; whole-file decode ~4–5 s |
| **98-10-0077** | 7-dim incl. a `0x0e` Year facet, Ages straddles | 174 geos, ~37M cells exact vs CSV |
| **98-10-0662** | 5-dim, Health straddles, mixed int16/int32, `0x80` per-geo stride | 91 geos exact vs CSV (silently mis-decoded pre-unification — it had been misrouted to the family-2 decoder) |
| **98-10-0023** | 3-dim Age×Gender, geography straddles → 4 geos/page | all 63,404 geographies |
| **98-10-0129** | 4-dim, geography straddles → 2 geos/page | 15,685,859 cells incl. the `0xa4` int32 marker |
| **1991 `1003011`** | 3-dim, geography straddles → 4 geos/page, int16/int32 | 330/330 exact; all 41,859 geographies exact vs the viewer member list |

### 2021 modern (DGUID) census

- **98-10-0013** (ADA, 5,447 geos) — its directory sits past 64 KiB, so under the
  plain u16 `@558` read the cell decode was silently EMPTY. With the pointer unwrap
  all 22 pages (18 distinct marker `b2` values) decode: **37,587/37,587 exact vs
  CSV** — the source of the b2 trailer formula.
- **98-10-0044** — tiny 3-dim collective dwellings, the whole table in one presence
  record (trivial geography straddle): **448/448 exact vs CSV**.
- **98-10-0174** (DAs) — Mother tongue is type `0x09` with **331** members; the u8
  read collapsed it to 1 and only member 1's cells decoded (a *silent* mis-decode,
  found via 97F0020X). Now 14,895/14,895 exact over 3 geographies.
- **98-10-0478** (CTs, 6,297 geos, type `0x0d`, groups `1,1,2,4,8,9`) — chunked
  DGUID codebook; `geo_label` == StatCan "Member Name" 6,297/6,297.

### 1996 census (pre-DGUID, viewer-validated)

**94F0009XDB96078** (13 geos, 5 dims, Years(2) facet) 572/572 · **95F0250XDB96001**
(5,544 CSDs; a **digit-led** dimension name the old uppercase-only descriptor anchor
dropped — the resulting 2-dim layout decoded misindexed cells that *passed* the
pre-flight, caught only by viewer validation) 72/72 · **95F0223XDB96001** (5,007
geos, duplicate member labels) 1,134/1,134 · **95F0200XDB96003** (43,234 EAs) 200/200.

### 2016 `98-400-X` crosstabs (supported container, zero code changes)

- **2016328** (18.7 MB, 5-dim, 4,868 geos): 360/360 vs viewer + **1,680/1,680 on
  deep-tail geographies** (member positions 3000+/4860+), pinning member order.
- **2016261** (86.8 MB, 6-dim, 14.4M cells): 154/154.
- **2016120** (income, all-float64, geo-straddle 4/page): 510/510 leading +
  1,432/1,432 deep-tail. **Suppression is WHOLE-GEOGRAPHY**: the `dqf_code`'s last
  digit is 9 for exactly the **888** geographies with no stored cells (888/888, zero
  crossovers) and the viewer renders precisely those blank. No per-cell sentinel.
- **2016203** (49.6M cells in ~23 s; 51 geos × Admission(47) × Immigrant(11B) ×
  Age(7A) × Selected(825) × Sex(3)) — formerly rejected for "non-exact `b2 == 0`
  pages"; the real bug was reading type `0x0a` as a u8 (Selected 825 read as **57**).
  Viewer-exact (39,516/39,516 multi-fixed over 4 geos incl. the last member of every
  fixed dim, + ~25k single-fixed over 9 more) and all 825 chunked EN/FR labels exact.
  Its viewer `d0` re-sorts geographies — **join viewer ground truth by NAME**.

### 2006 census

- **97-563-XCB2006072** (37.4 MB, 57,523 geos, Geo × Age(5) × Presence of income(9)
  × Sex(3), 6.5M cells in ~6 s) — the `b3 = 0x0a/0x0c` **head-block** vintage: the
  marker's fourth byte encodes a `32·(b3−8)`-byte auxiliary head before the value
  run, and its `b2 == 0` pages append per-(geo, age) absent-cell mask records after
  it (byte-exact reconstructible from the presence bitmap on 14,111/14,381 pages) —
  hence exact-fit is asserted only for `b2 == 0 && b3 == 08`. Viewer-exact:
  3,487/3,487 stored + 833 absent-as-zero over 32 geographies incl. deep tail
  (member 57,523) and wholly-empty ones; `has_data` flags the 1,999 suppressed DAs.
  Its truncated descriptor name ("Presence of inc") is repaired from the complete
  SECOND name copy.
- **97-555-XCB2006058** (twin lineage) — **4,166,909 cells** strict-clean once
  exact-fit was relaxed for its `b3 == 09` tails; Sex Total = M+F within ±11 on 96.7 %
  of count cells, the residual being exactly the non-additive income
  medians/averages/SEs (members 795–830).
- **cro0172986_ct.7/8** (BC custom-order CDs+CSDs) — geography now decodes: all 581
  EN **and** FR names + GEOUIDs, read positionally from dim 1's slot directory. Needed
  `ivt_f2_read_dir_at(relaxed = TRUE)` (these exports store `len2` = the *allocated*
  block size, 3024 → 3078) and `IVT_F2_INLINE_PAT2` for the code-in-trailing-parens
  form `"<name>, <type> (<code>)"`. Validated owner+renter+band = total per geography.

### Profile lineage (a 1-member "Values" placeholder FIRST, geography LAST)

- **97-570-X1981004** (5,989 geos, `Values(1) × Profile(79) × Geography(5989)`,
  418,400 cells). Two descriptor fixes unlocked it: double-01 counts reconciled
  against the slot-directory member block (the "Values" record's count byte reads a
  bogus 32; its codebook stores 1), and `ivt_f2_geo_dim_index()`. With true counts
  the **ordinary unified layout fits exactly** — geography straddles (3 windows of
  2048), Profile pages the directory at stride 4. Viewer-validated 5,989/5,989 member
  order + 1,264/1,264 cells (incl. window boundaries 2048/2049, 4096/4097). Identity
  via the master directory (`@40`/`@48` are zero); 10 footnotes under the numberless
  `FOOTNOTE:`/`RENVOI :` framing (adding it also surfaced missed notes on
  1996/2006/2011/2016). Strict-clean.
- **1991 profiles 98F0172X (CT Part B) + 95F0170X (CD/CSD Part B)** — the one new
  piece is the **dense `0x0_` page variant** (`[b0∈{02,04,08}][01][u16 count]` + one
  value per grid position, zeros stored LITERALLY, exact fit `4 + count·width == size`).
  The old "non-rectangular Σcount" puzzle was a truncated directory read (the `0x0_`
  markers were rejected, so `ivt_idx0()` fell back to the 0241 constant). Viewer-exact:
  11,638 + 10,580 cells over 42 geographies. Also fixed: `@48`/`@40` title blobs are
  NOT fixed language slots (98F0172X stores FR at `@48`; assigned by frscore), the
  legacy footnote header is spelled `Footnote(s)` here (39 notes each), and their
  master directories store a 4-byte-ALIGNED second length copy. Both strict-clean,
  1.77M/1.84M cells in ~0.4 s.
- **95F0490XCB01006** (2001 profile, Borealis SP3/NIQKF5) — read as *unsupported*
  because `ivt_f2_descriptor_name()` returned NA for a **prose-bled geography-LAST**
  record ("Geograph**yens (pGeography**tut de r"): its reoccurring-prefix fallback was
  gated to `first_record`. Gating it on any u16-count geotype record instead recovers
  Geography(1041)/Profile(621) → **538,064 cells strict-clean**, validated by the
  2001 labour-force identities (In LF = Employed + Unemployed; Total 15+ = In LF + Not
  in LF) across all 1,041 geographies to ±10 (base-5 random rounding).

### 2001 F-series

- **97F0020XCB2001070** (Geo(14) × Number(2) × Earning(8) × Selected(282) × Years(2))
  — formerly rejected on the capacity rule ("1124 presence bits vs 448-cell
  capacity"); the real bug was type `0x09` read as u8 (Selected **282** read as 1).
  Viewer-exact 34,968/34,968 over all 14 geographies. The same fix repaired
  98-10-0174 (above).
- **95F0378XCB01004** — 859,903 cells (still `canivt_descriptor_from_slots`: a
  footnote bleeds into its descriptor); Sex identity 99.6 % within ±11.
- **95F0489XCB01007** — the geotype name fix removed its `canivt_descriptor_lenient`
  fallback, cell count unchanged at 86,696 → strict-clean.

### Custom / one-off exports

- **ord-08035** (2021 CT export; Geo(791) × chars(79) × Tenure(4)) — the "different
  page encoding" was a MISREAD descriptor: `@32` points at the TITLE block, the real
  descriptor lives in the master dir. `ivt_f2_descriptor_offset()` validates `@32`
  then falls back master-dir → signature scan. BC pop 4,915,940; tenure Total = Owner
  + Renter + Band; geo names 789/791; labels from the plaintext "Variables:" list.
- **EO3278_T1_CDCSD** — chunked; the geography **field dictionary** matched the runs
  1-to-1: 5,146 EN+FR names + the file's declared `UID/IDU` SGC codes (`10`/`1001`/
  `1008001`). The earlier content heuristic had mis-picked the `Geo Code` column.
- **EO2654_2011_Van** — geography is descriptor dim 2 named "Geography"
  (`canivt_geo_by_name`); its slot dir over-declares 109 vs 92 real entries
  (`canivt_geo_dir_short`, validated by `ivt_f2_check_geo_count()`): 3,433 names +
  `CU…` uids.
- **97-563-XCB2006058** (Borealis 8-dim single-area, 75,913 cells) — read via *two*
  loud fallbacks. The hypothesis "the geo block directory must resolve the DGUID
  blocks" was wrong: its field dictionary declares only **name** columns and **no
  UID**, so there is no DGUID in the file. The double warning was dispatch order —
  the uid-only reader ran its byte scan before the data-style reader picked the table
  up. Step 5 is now gated on `enc != "custom" || ivt_f2_geo_field_has_uid()`.

### Commuting flows

Three encodings of the same residence→work product, all decoded (a flow decodes as
TWO geographies, POR/POW → `geo_res_*`/`geo_work_*`):

1. **`0x0f` packed flow** — 2011 `99-012-X2011032` (17,163 O-D flows; the u8 read
   took the high byte 67 and collapsed 27 data pages to 201 cells) and 2016 CSD
   `98-400-X2016325` (23,565 pairs, 100 % res/work names+uids).
2. **residence × work crosstab** — all 2021 (`98-10-0459/0466/0460`): a second
   geography-valued `Place of work` dimension, no `0x0f`; strict-clean.
3. **single-dim combined `"origin / dest"` labels** — 2016 CD/CMA
   `98-400-X2016391`/`-327`: same dedicated `origincode/destcode` uid array, just
   SHORTER codes (4-digit CD, 3-digit CMA). Needed `[0-9]{3,9}` and trying the flow
   reader BEFORE the plain inline reader; `327` also needed **`0x0b` added to the u16
   width-tag set** (u8 misread count 5 vs u16 1399). 391: 4,199 flows; 327: 1,399,
   both 100 % geography coverage.

**Member order VIEWER-VALIDATED** (2026-07-10) on every vintage: 100 % joined-value +
set-equal across sampled residences, after fixing each non-geography dim to its Total
member as the viewer does. Our order is residence-major, SGC ascending; the viewer
re-sorts within a residence for display, so a positional match isn't expected.

### `02 00 20 00` survey generation (container byte 0 == `0x02`)

All **23** corpus files strict-clean via `ivt_f2_descriptor_02()`, which retires the
descriptor block entirely for this generation and rebuilds it from the per-dimension
codebook the header slot table locates. **These tables have NO geography dimension** —
their REGION/GEOGRAPHY dims carry no geographic identifiers, so
`ivt_f2_geo_dim_index()` returns 0 and they stay ordinary data dimensions.

- **Health Statistics 1999 `00060104`** (first of the generation): `Quantifier(1) ×
  Geography(13) × Period(37 = 1961–1997)` = **451 cells**; the int16 block decodes
  Canada's real total-fertility-rate series 3.84 → 1.55. **The "scaling" question is
  CLOSED — there is no integer scaling.** Values are complete integers in the
  indicator's own units, which the facet member's `_Description` states (TFR = "children
  born per 1,000 women"), so `3840` is literally a genuine value. Searched
  exhaustively: `b2` is only width/trailer, and the dec-"3"/dec-"0" facet codebooks are
  byte-identical. No scale warning is emitted.
- **Health at a Glance line generalised**: bound the descriptor record region at the
  **first value block** (the page directory's first entry) and add a **contiguity
  break** to the accept-all pass, so the walk stops before mining codebook labels.
  Ledger rows `00060108` (3,630 cells, Canada = Σ provinces + territories) and
  `00060208` (301). Also fixed `product_id` (the "Title:" LABEL was mistaken for the
  id) and the French dimension name (`ivt_f2_dim_name_fr_marker()` strips the English
  prefix off the doubled-name marker, guarded `fr != en`).
- **The `81 02 <alloc> 00 08 00` TIME-SERIES MEMBER TABLE** (`ivt_f2_time_members()`)
  is how B2020 stores a reference dimension with no code/label arrays: `alloc`
  one-byte member-slot flags + one **u24 LE date per member**, right-aligned. Epoch
  **0000-03-01** (proleptic Gregorian, the classic computational-calendar epoch) —
  every stored date lands on Jan 1 of its year; calibrated on three files at once
  (LFHR Table-051 1976–2010, h2530002 1975–2010 with the 1974 lead date clipped by the
  block length → extrapolated backward by the median step, tb611996 1995–97, whose
  three dates appear verbatim in LFHR's run). Labels are generated.
- **The flag bytes are BYTE-PAIR-SWAPPED and mark member SLOTS, which the presence
  bitmap addresses** — deleted members leave holes. tb611996's periods sit at slots
  {1,2,4}: exactly 1/3 of its stored values sat off the dense member grid until the
  layout became slot-aware. The swap direction is self-validating: h2530002's raw flags
  read hole-at-37 + member-at-38, which the swap turns into the dense 1..37 its
  fully-dense 296-cell store requires. tb611996: 4,020 cells, year mapping confirmed by
  the HAART signature (infectious/parasitic diseases 11.4 → 9.9 → 7.7 across 1995–97).
- **`00060117` ("mixed-width") needed NO width machinery**: positional nesting already
  places Quantifier(2) OUTSIDE the straddling REGION — 4 pages `[84,84,88,88]`, one
  width per page from each page's own marker, which `ivt_decode_page()` always read
  per-page. The real blocker was `ivt_f2_dim_dir()` accepting a 1-of-4-entry TRUNCATED
  directory; it now returns the FULLEST ok() candidate. 3,120 cells; Canada = Σ
  provinces ±2.
- **Chunked geography** (`ivt_f2_slot_chunked_count()`, the INVERSE of
  `ivt_f2_chunk_layout()`): with `R` attribute×language runs the geo directory holds
  `R` copies of every 256-chunk, so `R` = how many times the trailing PARTIAL chunk
  occurs, chunk count = arrays / R, true count = `(n_chunks−1)·256 + partial`.
  Over-determined (three consistency checks) → NA rather than a wrong count.
  **b34csd_1** (1996 census): 63 full + 3×168 partial → 22 chunks → **5,544**
  (cross-checks the descriptor's own `a8 15`), **2,240,847 cells** (Highest-schooling
  Total 22,628,925 = Σ sub-levels ±5). **EDDTAB16** (1996 Agriculture): 72 full + 8×11
  → 10 chunks → **2,315**, **60,468 cells** (Canada 277,000 farms ≈ the published
  276,548). *Known limitation*: EDDTAB16's geography carries a rich multi-field
  hierarchy dictionary with NO UID and six fields mapping to `geo_name`, which the
  shared reader cannot disambiguate — it stays a data dimension labelled by 9-digit
  geocode.
- **`PRSIC1dec1999`** (provincial SIC establishment counts, an EARLIER `02` generation)
  needed three small general gaps closed: a directory with **5 interior `(0,0)` null
  holes** beyond the fixed 4-null tolerance (now accepted when every declared slot is
  either captured or an explicit null); the **`0x10` dense-array marker**; and the
  `English Label` / `Etiquette` schema vocabulary (with binary bleed after the field
  name, so anchor on the leading boundary only). PROV/CAN(14) × DIVISIONS(19) ×
  EMP.SIZE(11) → **2,652 cells, strict-clean**; Canada = Σ provinces, Total = Σ
  divisions, Total(A) = Indeterminate(B) + Subtotal, Subtotal = Σ 8 ranges — all exact;
  Canada/Total = 1,996,322 establishments.

### `04`-gen survey lineage (Borealis)

- **`ucr2.2_3-2006`**, **LFHR `Table-051`**, **justice `h2530002`** — the pre-DGUID
  single-area lineage; the last two have **no descriptor block at all** and are
  synthesized from the `@824` slot table (`ivt_f2_descriptor_from_slots()`).
- **`table_6_c-ivt-2007`** (UCR clearance) — descriptor **inverted** behind an
  `81 02 04 00` sub-header ending `80 01`, which neither the forward walk nor the
  `81 02 03 00`-only inverted retry reached. `ivt_f2_descriptor_impl()` now falls back
  to the NAME-INDEPENDENT slot rebuild when the walks recover fewer than the
  authoritative count, adopted only at an exact count match. Geo(1) × ClearanceType(19)
  × Offences(187) × Year(1) → **1,952 cells**; the clearance accounting identities
  (Total = Not cleared + Cleared by charge + Total Cleared Otherwise, plus the nested
  Σ(5..9) and Σ(10..19) subtotals) hold EXACTLY across all 177 offences; national total
  2,192,656 incidents.
- **`table_5_c-ivt-2008`** — two stacked gaps about ALLOCATION PADDING the `04`
  families were assumed never to use: (1) `[used][allocated]` directory entries
  (`s1 < s2`, 16-byte-aligned slack) were accepted only for the `02`-gen, so `@558`
  validated no entries; now `used <= allocated` with ≤ 256 byte slack for all families.
  (2) A 16-byte alignment tail on a `b2==0/b3==08` page failed exact fit; relaxed to
  no-overrun + ≤ 32 byte undershoot. **35,237 cells**; total accused 1,110,371.
  *Known label limitation*: the Offences name block carries **216** records against
  **215** codes, so the reader keeps the numeric code labels rather than risk a
  mis-aligned mapping.
- **`00040231`** (Census of Agriculture overview) — `@32` points at the IDENTITY
  block and its real `81 02 03 00` descriptor sits *after* it, out of the backward
  retry's window. Added a **forward/master-directory variant** of the inverted retry,
  placed LAST so it never pre-empts a slot rebuild. Geography(2180) × Computers(3) →
  **6,216 cells**; Canada 122,678 farms use computers / 114,416 internet / 92,154
  high-speed (high-speed ⊆ internet ✓).
- **Census of Agriculture 2016 `00040200` / `00040207`** — both dropped the **`Date (2)`
  facet**, whose record uses the double-marker reference-period framing
  `[type][count] 01 02 <doubled name>` (`13 02 01 02 DateDate`) that the `01`-only
  anchor skipped; with the facet missing, geography fell to the slot rebuild and capped
  at one 256-chunk. Admitting `01 02` is **gated on `count < 0x20`** because the marker
  also appears mid-prose (in the sibling `00040231` the count byte lands on `s` = 0x73;
  its `Date` is a genuine 1-member facet that collapses harmlessly). Geography reads its
  real u16 **2,568** and stores its code inline in **square brackets** ("Canada
  [000000000]", `IVT_F2_INLINE_PAT3`). `00040200`: **92,584 cells**, Canada total farms
  2011 = 205,730 / 2016 = 193,492 (the published totals), Beef + Dairy = Cattle.
  `00040207`: **55,020 cells**, farms reporting manure 2016 = 66,227 = Σ 10 provinces
  exactly; solid-manure 2,483,220 acres × 0.404686 = 1,004,912 ha ≈ decoded 1,004,923.
- **LFHR `Table-023`** (Geo(11) × Sex(3) × Class(3) × Occupation(33) × Hours(10) ×
  Timeseries(276 monthly, 1987-01…2009-12)) — the first multi-dimensional long-series
  survey table, and the origin of the "doubled-window directory" puzzle. Three findings:
  1. **The u16 `alloc`.** Its Timeseries table has `alloc = 512 ≥ 256`, and
     `ivt_f2_time_members()` had guarded `raw[off+4] == 0x00`. Reading `alloc` as a full
     u16 recovers the 6-dim descriptor.
  2. **Hours is 10 members, not 9** (2026-07-22). The first read shipped 4,986,342
     cells — dropping "Average usual hours (main job)" (785,590 cells) and shifting every
     Hours label. The descriptor block reads count `0x0a` correctly, but the forward walk
     recovers only 5 of 6 dims so the slot rebuild pre-empts it, and Hours stores its
     member *descriptions* in a bit-headed dense array whose post-bitmap marker is
     **`0x20`** — a variant `ivt_f2_dir_entry_members()` did not admit, so the count fell
     to the member CODE array (9 entries; "Total employed" carries no code). Widening the
     reader restores **5,771,932 cells**; validated by additivity (Σ 7 buckets = 11,714.4
     = Total employed; 430,271.4 / 11,714.4 = 36.73 ≈ the file's "Average usual hours"
     36.7).
  3. **The doubled window — RESOLVED (2026-07-23) as DECLARED metadata.** It was
     reverse-engineered as strides `[1,8,512,2048,8192]` = the census pow2 model with the
     straddle-window dimension padded to double its `nextpow2`, and shipped behind a
     structural page-size probe (`ivt_survey_double()`) while the geometry stayed open —
     explicitly because "if the doubling is real there should be a field that DECLARES
     it." There is: the `81 02 <alloc-u16> 16 00` member-code block's leading u16 is a
     per-dimension **slot allocation**, and Hours declares **32 slots for 10 members**.
     `ivt_layout()` pads to it; the probe was deleted; Table-023 re-validated at the
     identical 5,771,932 cells with no fallback. See "Declared slot allocation" below.
- **`accs` adult criminal court** (7 dims, 4,573,026 cells) — had been deferred as
  `Table-024`-class (its directory spans the DOUBLED cartesian) but is a **DELETED
  MEMBER SLOT**: Sex's codebook carries SIX label records (`Total | Males | Females |
  Company | Unknown | Company`) against a declared 5, with **slot 3 deleted** (it keeps
  its label, carries no data). Using the physical extent 6 gives a CLEAN pow2 nesting
  `estride [1,8,64,512,4096]` and every identity holds: Males 664,830 + Females 106,433
  + Company 32,991 + Unknown 5,159 = Total 809,413, the deleted slot decodes 0 cells,
  Σ age groups = Total, Single + Multiple = Total Cases 361,788. The bug chain that hid
  it: the first descriptor record frames its doubled name with a **bare `02` separator**
  (`10 04 02 Fiscal yearCASEYEAR`) so the strict walk found 6 of 7 dims and fell to the
  slot rebuild, which miscounted Sex as 3 because its dense label array uses the
  post-bitmap marker **`0x08`**. Three general fixes: admit `0x08`; admit the bare-`02`
  separator; `ivt_f2_dim_slot_expand()` expands a count to the physical extent on a
  SMALL codebook surplus (≤ 2), LOUD as `canivt_deleted_slot`. Structurally distinct
  from Table-023's *present-but-empty* 392-byte padding pages — an interior gap with
  **no directory entry** (occupancy `{0,8,16,32,40}` per 64-block).
- **`98-313-XCB2011025`** (810 cells) — warned `canivt_descriptor_from_slots` ("a
  footnote bleeds into the descriptor"), implying a location bug. It is not one: this
  table's descriptor carries **no per-dimension records at all** — after the fixed
  header the block is one contiguous 2,103-byte printable run (title + an embedded
  `Note:` paragraph) running straight into the codebook. The dimension names live solely
  in the `@824` slot directories, so reading them there is the *correct* metadata-driven
  path, not a recovery. `ivt_f2_descriptor_impl()` now adopts the slot rebuild
  **quietly** when: both walks recovered zero records, one large printable run (≥ 400 B)
  fills ≥ 85 % of the span up to the first `81 02 02 00`, and the slot table resolves
  exactly the authoritative count. Strictly narrower than the loud rebuild that follows,
  so it can only convert a warning into a clean read.

### Canadian Business Patterns (Business Register)

Establishment counts by geography × NAICS/SIC × employment size. Descriptor signature
ends `80 ff`; the geography record has NO `01` separator and varies position by year;
bare-numeric-code geography codebook. 8 of 9 corpus files onboarded (`Dec09DA` is a
corrupted source download).

- **`CDNAIC3_LOC-1`** (Dec 2010; Geo(314) × SUB-SECTORS(26628) × EMP.SIZE(11)) —
  flagged for **20,523 `canivt_skipped_pages`**, which was a **false alarm**. The
  directory is very sparse (282 real data pages; 21 of 314 geographies carry data), so
  the full cartesian walk (65,626 coordinates) must resolve ~65k absences; 20,523 landed
  on bytes `ivt_dir_entry()` accepts but that point at CODEBOOK text — only **644
  distinct offsets**, all checked, **none a real page**. Ground truth is byte-exact
  internal additivity on EMP.SIZE: `Subtotal = Σ(ranges)` holds **21,681 / 21,681 with
  max deviation 0**, `Total = Indeterminate + Subtotal` **21,675 / 21,681** (the 6
  exceptions are source-suppressed at the anomalous geography 306). The fix was to the
  **tripwire**, not the decode: `ivt_skip_is_lost_page()` now validates the target's page
  GEOMETRY (recognised width/page nibbles, and the presence record + tightest possible
  value run fitting the entry's allocated size) instead of counting every unrecognised
  marker — a real page fits by construction, a codebook block does not. 0 false skips
  here; the doctored-`b3` unit test still fires. *Known limitations*: EMP.SIZE labels are
  shifted (a fixed-width `[80 10][len]…` member array the generic scans misread — values
  and member ids are correct, additivity proves it), and see
  [`unsupported-formats.md`](unsupported-formats.md) for the 133,217 vs 162,127 cell
  question.

  **To (re-)validate this lineage**: pivot `x$cells` by `emp` within each `(geo, sub)`
  group and assert `member1 = member2 + member3` and `member3 = Σ(member4…member11)`
  with the member ORDER `Total (A) | Indeterminate (B) | Subtotal (A−B) | 1-4 … 500+`.
  A label fix must reproduce that order — validate new labels against these value
  positions, not the other way round. Source: Borealis DOI `10.5683/SP3/PAWNKX`;
  `CDNAIC3_LOC-1.ivt` is byte-size-identical to `CDNAIC3_LOCdec2010.ivt` → the December
  2010 vintage.

### Type-00 sub-A provincial Business-Patterns (`R/suba.R`, 2026-07-24)

The older provincial SIC tabulations (`byte 0 == 0x02`, no geography,
`PROV/CAN|CA/CMA × INDUSTRY × EMPCLASS`) resisted the unified layout for two reasons
absent from any declared allocation:

1. **The outer directory stride is a physical CONSTANT** — 16 windows for the industry
   straddle, the same whether a geography uses one window (PROVIND: 13 provinces, one
   each) or five (PROVSIC3: windows {0,1,2,3,13}), and independent of geo count; the
   declared industry allocation (1024) predicts 8. Three candidate rules (constant 16,
   `nextpow2(empclass)`, `nextpow2(⌈entries/geo⌉)`) are indistinguishable on the corpus,
   so the stride is **measured** from the page directory by an arithmetic-progression
   scan of the geography window-0 entries (robust to spurious far entries that a max()
   estimate trips on).
2. **The industry codebook UNDER-declares its count** (161 of 321), lays the detail
   members in a contiguous run at a file-specific offset (right-aligned for multi-chunk,
   left-aligned for single-chunk — no unified rule), and stores a grand-"Total" member
   whose slot varies by vintage: FAR at a high window (`PROVSIC3june1997`, slot 1671),
   CONTIGUOUS-FIRST (`PROVSIC3-1`, member 1), or dense-first (`PROVIND`).

There is **no ground truth** (Borealis and Odesi carry only the `.ivt`; the open
Canadian Business Counts CSVs are modern NAICS — a different vintage *and*
classification, confirmed by web search + Dataverse API on DOIs SP3/PAWNKX, SP/OWUF3P,
SP/VB0LLW). So values are validated GROUND-TRUTH-FREE by a **reconciliation identity**
— industry-`Total` == Σ detail per geography × employment size (or geography `Canada`
== Σ provinces) — which `ivt_f2_suba_annotate()` ENFORCES as the decode gate: it
measures the stride, recovers the count/slot map from the codebook chunks, tries each
candidate total placement, and COMMITS only the one that reconciles exactly.

Onboarded: `PROVINDjune1997` (dense DIVISIONS, **2,031** cells), `PROVSIC3june1997`
(chunked total-far, **22,581**), `PROVSIC3-1` (chunked total-first, **29,463**). Left
honestly UNSUPPORTED and ledgered `FALSE` as gate guards: `CACMA3-2` (hierarchical, 330
codes over 415 slots), `PROVSIC4-2` (SIC-4, 1,254 classes), `PROVSIC4dec1997` (an `idx0`
mis-detection).

**What reconciliation cannot verify is the LABEL assignment** — a uniform relabel leaves
the sums unchanged — so the industry axis labels are surfaced PROVISIONAL via the loud
`canivt_suba` / `canivt_suba_labels` fallbacks.

### Chunked-count generalisation (the metadata-harvest sweeps)

- **2026-07-23**: `ivt_f2_slot_chunked_count()` (written for the `02`-gen above) was
  simply not wired into the generic `04`-gen path, where the count comes from the slot
  directory and stops at the first 256-member chunk. `ivt_f2_dim_count_reconcile()` now
  probes it for any dimension read as exactly 256 and adopts a `>256` chunk-run count
  (LOUD `canivt_chunked_count`; the probe returns NA for a single-chunk 256-member dim,
  so a genuine 256 is untouched). **8 files onboarded** in one fix: `95f0487xcb01003`
  (Geo 256→1585, 134,238 cells), `95f0494xcb01001` (Profile 409 × Geo 5108, 248,780),
  `100801` (529 × 5602, 1,844,241), `95f0338xcb01006` (528,575), `95F0377XCB01005`
  (3,048,793), `97-554-XCB2006027` (362,761), `95f0491xcb01003` (105,001),
  `97F0007XCB2001042` (Geo 5108 × Characteristics 508 × Mother-tongue, **9,021,645** —
  both capped dims recovered). All with `geo_name_NA = 0`. The same sweep found a
  genuine NA-subscript crash in `ivt_f2_inline_name_subtract()` (an NA uid `code` put an
  NA into the `empty` logical index), guarded with `!is.na(code)`.
- **2026-07-24**: the reconcile no longer requires a `256` descriptor count. The 1991
  enumeration-area census tables (e.g. **PID=128 / catalogue 1006454**, "N9101 —
  Population 15+ by Age Groups (17) and Marital Status (6)…") read `type 0x0e count 52`
  for geography — and **52 is the CHUNK count**: 52 full 256-member chunks + a 60-member
  tail, true count **13,372**. The probe now runs on every dimension and is adopted
  whenever it EXCEEDS the descriptor's (self-gating: NA unless the codebook physically
  holds ≥ 2 full 256-arrays + a consistent partial). **8,308,875 cells** across 13,372
  EAs, `geo_name_NA = 0`; Canada Total-Sex 21,304,740 = Male 10,422,145 + Female
  10,882,595 exactly (counts random-rounded to base 5; the fractional values are the real
  Labour-Force *rate* members stored as float64).

### Under-declared member counts — allocation as the second count witness (2026-07-25)

The SP3/RHUXA9 income lineage (Borealis, "Income in Canada" / SLID-era tables
`103`, `404`, `405`, `501`, `701`, `703`) read a geography count of **5** or **4**
from a `[type][count][01][01]` descriptor record — the *double-01* shape that
`ivt_f2_dim_count_reconcile()` already treats as ambiguous, because it is shared by
the reference-period record and the profile "Values" placeholder. Here the "5" of
`1e 05 01 01` is not a member count at all.

The signal that resolves it is **metadata already in the file**: the dimension's
`81 02 <alloc-u16> 16 00` member-code block declares its slot allocation. On every
validated table the allocation is the `nextpow2` of the member count — measured
corpus-wide, `alloc <= 2 * nextpow2(count)` without exception. A dimension that
declares **4× that** is declaring more members than the descriptor was read to
hold. `ivt_f2_dim_count_reconcile()` now, for any dimension whose allocation
exceeds `4 * nextpow2(count)`, reads the codebook member array's own length
(`ivt_f2_dir_member_count()`) and adopts it when it lies strictly between the
descriptor count and the allocation (LOUD `canivt_underdeclared_count`). The
replacement is the *array length*, never the allocation, so a dimension that merely
over-allocates is untouched — the accs "Offences" case (40 members, 64 stored
labels, alloc 64) stays below the 4× gate and never fires. The loop runs *before*
the double-01 pass, which then sees a count consistent with its slots and leaves it
alone. Geography recovers 5→**30** (`103`, `404`) and 4→**13** (`405`, `501`,
`701`, `703`).

**The page-head model widened at the same time.** With the corrected geography
count, `404` still decoded only 473,932 cells and skipped 395 pages loudly
(`canivt_skipped_pages`) on markers `a4 01 08 0b` and `a2 01 dc 0d`: `b3` values of
`0x0b`/`0x0d`/`0x0e`, outside the then-catalogued `{08,09,0a,0c}`. The head is a
contiguous run of 32-byte blocks (`32·(b3−8)`), so that set was the observed span,
not a closed enumeration; on this lineage the head grows with the geography
dimension's slot allocation. `ivt_f2_marker_b3` is now `{08 … 0e}`.

That widening cannot be validated by the page-size equation on these files — *every*
page here, including the already-accepted `b3 ∈ {0a, 0c}` ones, carries 1,528–2,344
bytes of allocation slack, so only `≤` applies. It is validated at the data level
instead, and decisively: `404`'s age axis reconciles **14,520/14,520** groups
("All age groups" == Σ of the six detail groups) with max |d| = 3, exactly the
bound for six values rounded to thousands, 7,370 of them exact. The single sharpest
datum is one previously-*skipped* page: its "25 to 34 years" cell decodes as
**1956**, precisely the `7975 − 6019` residual the published "All age groups" total
requires. Cells 473,932 → **807,273**, no skipped pages.

Per-table validation, all metadata-internal (no external ground truth exists for
this lineage):

| table | cells | check | result |
|-------|-------|-------|--------|
| `404` | 807,273 | All age groups == Σ 6 age groups | 14,520/14,520 (max \|d\| = 3) |
| `405` | 12,000 | Σ 5 quintiles == Total of quintiles | 1,199/1,199 |
| `501` | 21,412 | Σ 5 quintiles == Total of quintiles | 1,162/1,162 |
| `701` | 42,884 | Σ 5 quintiles == Total of quintiles | 3,444/3,444 |
| `703` | 43,224 | Σ 5 quintiles == Total of quintiles | 3,597/3,597 |
| `103` | 9,326 | Both sexes == M + F; All earners == Σ 3 work-activity; Canada == selected CMAs + other areas | 3,096/3,096; 959/959; 312/312 (all max \|d\| = 1, values in thousands) |

`801` in the same collection stays honestly **UNSUPPORTED** — it is rejected
cleanly by the new integer-overflow guard in `ivt_layout()` rather than throwing,
and is ledgered `supported = FALSE` as a gate guard.

### The detection gate must always return a verdict (2026-07-25)

`ivt_layout()`'s guard covers the stride *accumulator*; it does not cover the
places that later multiply a stride back out by a member count. A header-cache
parse sweep over 1 005 harvested files surfaced the second site — the outer
entry cartesian in `ivt_page_preflight()`'s directory-span check:

```r
for (k in (ocount * ostride - 1L):max(0L, ocount * ostride - 65536L))
```

On `Alternative.cfm_PID_1195_EXT_IVT` (a 53 KB body whose descriptor reads out to
four dimensions of 3 386 / 3 373 / 3 383 members, striding 33 554 432 entries) the
product is **113 514 643 456** — about 440× the addressable extent. In integer
arithmetic it is silently `NA` ("NAs produced by integer overflow"), and the `NA`
reached `ivt_dir_entry()` as `"NA/NaN argument"`, so **`ivt_is_supported()` threw
instead of returning `FALSE`**. A detection gate that errors is worse than one
that rejects: callers sweeping a catalogue cannot tell "not an IVT we model" from
"canivt is broken".

The rule, now shared by all three sites that turn an entry index into a byte
offset (`ivt_entry_addressable()`): entries are 8 bytes and are reached as
`idx0 + 8L * k`, so any index above `(.Machine$integer.max - idx0) %/% 8L` is not
merely absent from the file — it is unrepresentable, hence a misread descriptor.
Indices are computed in **double** and checked before coercion.

- **span check** — unaddressable top ⇒ `FALSE` (clean unsupported verdict).
- **doubled-corner overshoot probe** — unaddressable corner ⇒ *skip the probe*.
  That corner is deliberately outside the modelled cartesian, so on a legitimately
  large layout it can exceed the range on its own; no entry there is exactly what
  a `NULL` read means, and treating it as evidence against the nesting would
  reject good files.
- **`ivt_decode()`** — checked once before the cartesian is materialised, since
  decode is reachable without the gate (directly, or with a caller-supplied
  `lay`).

The search window is unchanged (`ktop:max(0L, ktop - 65535L)` is the same 65 536
entries as the old expression, verified for every top value). Gates after the
fix: corpus ledger FAIL 0 / PASS 346 with cell counts unchanged, geo snapshot
FAIL 0 / PASS 238, unit suite FAIL 0 / PASS 1110.

## Milestones — how the architecture arrived

### Unified cell decode & metadata

One `ivt_layout()` + `ivt_decode()` (`decode.R`) decodes every table, reproducing the
two former decoders **byte-identical** on all six reference tables, fully
name/type-agnostic. `read_ivt()` / `ivt_metadata()` run **one** descriptor-driven
metadata path for every family; the hard-coded `IVT_DIMS` / `ivt_read_codebook()` /
`ivt_pick_english_block()` table is gone, as are the family-1 branches in `ivt_tidy()` /
`print.ivt()` and the separate `ivt_f2_read()`.

Member labels are anchored on the codebook's per-dimension **doubled-name marker**
(`81 02 02 00` + name, the same string the header descriptor stores), which sits
immediately after each dimension's EN member block. That anchor closed the last label
gaps: 98-10-0077's `Ages`(18) (its EN block carries 2 leading framing records) and
`Year`(2) (a reference period with no ordinal block), and 98-10-0662's two 6-member
language dimensions, which share a count and collapsed under the old count-keyed store —
`ivt_f2_dimensions()` resolves same-count dimensions **by name**. Full dimension names
come from the header Variable List matched to the descriptor **by count** (display order
≠ storage order in 98-10-0241, and the `(3C)`-style flagged count is parsed).

### Declared slot allocation — the paging geometry is metadata (2026-07-23)

A corpus-wide census of the `81 02 <u16> 16 00` member-code blocks (and the `08 00` time
tables) found their leading u16 is a per-dimension **member-slot allocation**, present
for EVERY dimension of EVERY corpus table across all generations. It equals
`nextpow2(count)` on every supported dimension except exactly one — Table-023's Hours,
32 slots for 10 members — which is precisely the lone table that had needed the doubled
directory (windows-of-4 over 32 allocated slots = 8 directory slots).

`ivt_layout()` now pads every nesting level (presence bits **and** directory strides) to
the declared allocation, falling back to `nextpow2(extent)` only when the declaration
cannot hold the members (chunked >1024-member dims declare a block-local 1024).
Byte-identical corpus-wide; a full directory scan confirmed the padding is genuinely
empty. `ivt_survey_double()` deleted. Retro-confirmation: the deferred Table-024 "ipc
mismatch" (in-page occ 2, 17 windows) is exactly what the rule predicts (Hours 32 ×
Timeseries 32 = 1024-bit inner block).

Same pass: the dense-array pre-records marker is accepted as the single-bit-byte CLASS
(Table-023's English Sex block carried the never-catalogued `0x04` and was silently
dropped, labelling the dimension French); and `ivt_f2_dim_dict_en_first()` reads the
remaining declared `04`-gen language vocabularies (`Description`/`Description_FRA`,
`English`/`French|Français`, bleed-tolerant leading-boundary match inside the tagged
`22 00` dict block), so the content-score language fallback now fires on **zero** survey
dims with a declared pair. Remaining gap: the `16 00` block's mid-section (likely
per-slot flags) is undecoded — it would subsume the `ivt_f2_dim_slot_expand()` margin and
fix accs Offences' 64-labels-for-40-members alignment.

### Uniform, content-free geography parsing

Geography is dimension 1 (except the profile lineage) with the same `81 02 02 00`
doubled-name marker as every data dim. There are **two storage strategies**: the 2021
census tables store it as **separate schema-named arrays**, while every **schema-absent**
table stores it as the inline combined block `"<name> (<code>) [<type_abbr>] <dqf>
[(<pct>%)]"`. **DGUIDs are 2021-specific, not "2016+"** — the 2016 `98-400-X` tables
carry no schema and no DGUID.

- **Combined-block (1991/2006/2011/2016)** — the uid is **character**: a bare code (2016
  `01`, 2006 `1001105`), a dotted census-tract code (2011 `0010001.00`), never a DGUID.
  Exact member counts, viewer-validated: 1991 41,859, 2006 57,523, 2011 5,447, 2016
  (98-400-X2016387) 174.
- **2021 chunked DGUID** — no year literal, no hard-coded slot table:
  `ivt_f2_geo_slot_map()` reads each attribute's slot from the file's own schema field
  list; `ivt_f2_geo_groups_chunked()` segments the 256-member groups structurally; the
  fast uid scan hits on the DGUID **shape** `<YYYY><level letter>`, vintage-agnostic.
- **Bilingual names** — `geo_label`/`geo_label_fr` (the display **Member Name**) and
  `geo_name`/`geo_name_fr` (the schema **GEO_NAME**, a bare code for CTs / unnamed DAs).
  Language is decided per group by `ivt_f2_frscore()` because the physical EN/FR order is
  EN-first in most groups but **FR-first in the root group** (0023 stores
  `Terre-Neuve-et-Labrador` first).
- **Member-ordering tail artifacts — FIXED.** The byte-ascending scans with
  first-appearance dedup misordered chunks stored out of byte order; the positional
  directory read exposed silent misorders of 2,435/41,859 (1991), 18,432/57,523 (2006),
  1,351/5,447 (2011), each then validated exact against the viewer's `d0` option order
  (the definitive member-order ground truth).
- **98-10-0013 ADA, three separate bugs**: (a) a `length ≥ 150` floor dropped the last
  group's 71-member trailing partial — the floor is now structural (a small clean member
  array is kept only when it immediately follows a full one); (b) its attribute
  dictionary sits ~14 KB *before* the codebook pointer, outside the old window — now
  located by following the file's own `@824` metadata directory; (c) its first ("root")
  chunk is stored in **reverse byte order**, so the byte-ascending scan reversed its
  logical block order (5,191/5,447, NA'd/scrambled attributes) — fixed by reading the
  root chunk positionally.
- **Drive *all* groups from the directory's block order.** `ivt_f2_geo_attrs_dir()` is
  the **primary** chunked reader (stride path only when the directory is
  absent/irregular): every attribute read positionally, no strides, no byte-ascending
  scan, no content-located TNR. Fixed latent stride slot bugs on tables carrying
  `TNR_LONG_FORM` (0478 `pr_code`/`dqf_code`/`tnr_short_form` wrong for 1,278/327/1,897;
  0129 `tnr_short_form` wrong for 237).
- **Attributes are positional-exact.** Every attribute validates exact vs the StatCan
  metadata CSVs on 0662 (91/91 × 11 — its aggregate member 26 has NO attributes; the
  scanner had shifted every uid after member 25), 0023 (63,404 × 11 incl. **DQF_NOTE
  100 %**, was ~99.8 %), 0129, 0478 (incl. the formerly-NA 153 code partials) and 0013.
- **Consolidation, recover-then-specialize (2026-07-17, refactor-plan §7).** Six layout
  readers reached through two separate fallthrough ladders, each re-implementing Stage 1.
  Now: `ivt_f2_geo_entries()` walks the geo block directory ONCE with lazy, memoized
  per-entry accessors (laziness is load-bearing — eagerly scanning 0023's 6,244 entries
  measured ~17 s, so the uid-only O(1) probe must never touch the run-scanner), and a
  single dispatcher `ivt_f2_geo_read(raw, full)` runs one ordered specializer chain both
  entry points share. This **fixed a latent bug**: the full path used to return an all-NA
  tibble for a schema-less custom/bare table. Gated at every step on a byte-identical
  geography snapshot plus corpus FAIL 0.
- **Stage 3 assemble-then-decipher.** The last-resort net (`canivt_geo_unparsed`,
  loud/strict-error) became a schema-free *full* reader: `ivt_f2_geo_assemble_runs()`
  reconstructs the codebook's parallel arrays with the same group/chunk geometry
  `attrs_dir` uses, inferring the run count from the block count. Column identity is
  **metadata-driven where the file declares it** (`ivt_f2_geo_field_schema()` +
  `ivt_f2_geo_field_roles()` map runs by the file's own field names); the content
  heuristic is the fallback. This closed EO3278 and EO2654 (above).
- **Every geography member decodes a non-NA `geo_name`** (2026-07-06). Two loud
  metadata-driven fills close the last gaps: `ivt_f2_inline_name_subtract()` recovers
  names the fixed-position regex misses (code embedded mid-name; bare code-only
  geographies) by subtracting the code/flag/pct tokens held from the file's own arrays;
  `ivt_f2_geo_fill_label()` backfills from `geo_label` for synthetic aggregates. Both
  fill only NAs.
- **Enriched geography metadata on the DEFAULT path** (2026-07-05). `metadata$geographies`
  packs every decoded per-member column, all-NA dropped; the inline vintages expose the
  formerly-DISCARDED `geo_type_abbr` and `tnr_short_form` captures plus `dqf_code`. The
  stored combined display string stays verbatim as **`geo_label`** (the viewer member-order
  join key = the OLD `geo_name`); `geo_name`/`geo_name_fr` are its EN/FR halves —
  `" | "` (1991's dedicated language separator) always splits, but `" / "` needs
  **positive French evidence** so dual English names ("Kootenay Boundary E / West
  Boundary") and neutral pairs ("Greater Sudbury / Grand Sudbury") stay combined. The
  inline parse runs under **PCRE**: TRE reads `[^0-9\s]` as not-digit/backslash/'s' and
  let a leading space into the type token. Corpus-validated: `geo_uid` order
  byte-identical on all supported tables; old `geo_name` == new `geo_label` everywhere.

### Footnotes, notes & the metadata directory

- **Footnotes are dimension-attributed**: each is an entry of its owning dimension's
  slot directory (texts set-equal to the old tail scan, which survives as fallback).
- **Scope (table / dimension / member) is complete** and matches StatCan's WDS links
  exactly (validated on 98-10-0241/0077/0023/0129). Member notes come from a `84 01`
  member bitmap opening each dimension's footnote region (pair-swap/MSB-first → member
  positions; the first `popcount` text entries are member notes, the rest dimension
  notes); table notes from the master-directory identity blob.
- **The legacy `(N)`-superscript linkage is decoded too**: a member cites a note by
  embedding `(N)` in its label → `scope = "member"` + `member_refs` (one-to-many).
- The **master directory at offset 992** (slot `@544`) bounds the legacy footnote read,
  and the **`@712` DQF legend** is decoded and exposed as `dqf_legend`.
- **Per-dimension `depth` on `ivt_tidy(depth = TRUE)`** (opt-in) from label indentation.

### Parser consolidation & sharpening (2026-07-11, refactor-plan §5/§6)

- **Page-directory anchor single-sourced** (§5.2): the low-16-bit `@558` unwrap lives
  once in `ivt_f2_dir_anchor_header()`. Previously only the decode side unwrapped, so the
  metadata-side finder fell to the loud marker scan on a >64 KiB directory.
- **`ivt_geo_arrays()` retired** (§6.3), removing the last year/country literals
  (`"^2021[A-Z]"`, `texts[1] == "Canada"`). A full-corpus branch trace proved its content
  fallback was **never reached**, so it went away by deletion.
- **`ivt_f2_geo_schema()` window scan made LOUD** (§6.4): all 12 schema'd tables resolve
  through the header slot table, so the ±128 KiB content-window fallback fires on zero
  tables. Kept as a last resort but now warns when it actually supplies a schema.
- **Doubled-name marker identified STRUCTURALLY** (§6.2): within a validated slot
  directory the marker is the unique entry OPENING `81 02 02 00` and carrying a name —
  152/155 dimension directories have exactly one (never >1); the 3 nameless cases are the
  ord-08035 custom export, where the descriptor name also fails. Byte-identical to the old
  name-match on all 155 directories; the win is robustness — a dimension with a
  misread/NA name still reads its labels, demoting the `ivt_f2_descriptor_name()` recovery
  stack from load-bearing to a cross-check.

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
