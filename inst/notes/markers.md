# markers.md — the IVT byte-marker catalog

The single reference for every **byte marker / fixed signature** the decoder keys
on. It is the human-readable half of a self-checking pair: the machine half is
`tests/testthat/test-markers.R` + `helper-markers.R`, which (a) unit-test each
recognizer against the byte patterns documented here, (b) assert the documented
byte **sets** equal the code constants (so this file cannot silently drift from
`R/`), and (c) sweep the corpus recording which markers each `.ivt` exercises and
**fail loudly if a file uses a marker not catalogued here** — the tripwire for a
newly-imported vintage.

When you decode a new marker (or widen a known set), update THREE places in the
same commit: the recognizer in `R/`, the relevant `IVT_MARKER_SET` entry /
recognizer example in `helper-markers.R`, and this file. The byte-format prose and
derivations live in [`ivt-format.md`](ivt-format.md); this file is the terse index.

All offsets are **0-based** (binary layout). Byte strings are big-endian written
(`04 00 20 00` = the bytes at offsets 0,1,2,3). `..` = a byte that varies.

---

## A. File container signature (`u32 @0`)

| bytes | meaning | recognizer |
|-------|---------|-----------|
| `04 00 20 00` | THE modern IVT file signature — census/custom lineages (modern, legacy, profile, custom, Business Patterns) | `read.R` / `ivt_store_download()` |
| `02 00 20 00` | the older **survey** generation (Health Statistics 1999, Census of Agriculture 1996, Small Area Business 1996) — same header/page/value model, no `FACET04` title; integer facet values are complete (in the indicator's own units, stated in the member `_Description`), NOT fixed-point | `ivt_family()` accepts byte 0 ∈ {2,4} |

Byte 0 is a container-generation tag (`04` modern, `02` older survey); the three
trailing bytes `00 20 00` are shared. The signature alone does not imply
decodability: same-signature containers that fail the page pre-flight
(`ivt_page_preflight()`) are still rejected.

## B. Header pointer slots (fixed offsets, not byte markers)

The header is a fixed table of pointers into the file. These are **positions**, not
signatures — the decoder reads a structure at each rather than scanning for it.

| offset | width | → | constant |
|--------|-------|---|----------|
| `@32`  | u32 | dimension **descriptor** block | `IVT_HDR_DESCRIPTOR_PTR` |
| `@40`  | u32 | French title (0 in the modern inline format) | `IVT_HDR_TITLE_FR_PTR` |
| `@48`  | u32 | English title (0 in the modern inline format) | `IVT_HDR_TITLE_EN_PTR` |
| `@544` | u32 | **master directory** (whole-file sections) | `IVT_HDR_MASTER_SLOT` |
| `@552` | u32 | geography field/attribute count (11 / 12) | `IVT_HDR_GEO_FIELDS` |
| `@558` | u16 | **page directory** start — **LOW 16 BITS only** (`ivt_idx0()` unwraps `+ k·65536`) | `IVT_HDR_DIR_PTR` |
| `@572` | u32 | codebook region start | `IVT_HDR_CODEBOOK_PTR` |
| `@712` | u32 | **DQF legend** directory | `IVT_HDR_DQF_SLOT` |
| `@824 + 14·(k−1)` | 14 B | per-dimension **block-directory slot** record `[u32 dir_ptr][u32 alloc][u32 n_entries][u16 flag]`, dimension `k` (1 = geography). `alloc` = `nextpow2(n_entries)` (allocated capacity, 243/243). `n_entries` = number of codebook **BLOCKS**, NOT members (members are packed inside the label-array blocks); a dimension's blocks are individually addressed and may interleave across dimensions. `flag` = 1 only on the 3 double-indirection chunked-DGUID geo dirs (else 0); `ivt_f2_dim_dir()` uses it to direct the indirection-depth order (metadata-driven, other depth kept as fallback); semantic inferred/unproven — see ivt-format.md "The 14-byte slot record, field by field" | `IVT_HDR_DIM_SLOT0` / `IVT_HDR_DIM_STRIDE` |

`@32` is not authoritative for all vintages: custom-order exports (ord-08035, cro
crosstabs) point it at the title/identity block, Business Patterns at a zero slot;
the descriptor is then relocated via the master directory or a signature scan (§D).

## C. Page markers (cell decode) — `[b0] 01 [b2] [b3]`

The 4-byte header opening every data page. **Byte 1 is always `0x01`.**

- **`b0` — value width + page variant** (`ivt_f2_marker_b0`, `IVT_MARKER_WIDTHS`):
  low nibble = value width (`2`→int16, `4`→int32, `8`→float64); high nibble =
  variant (`0x8` plain, `0xa` 0xFF-run / suppression-mask-tail, `0x0` **dense**).
  - plain/mask set: **`{0x82, 0x84, 0x88, 0xa2, 0xa4, 0xa8}`**
  - dense set (high nibble 0): **`{0x02, 0x04, 0x08}`**
- **`b3` — auxiliary head block** (`ivt_f2_marker_b3`): head length = `32·(b3−8)`,
  `b3 ∈ {0x08 … 0x0e}`. (`b3 ≥ 0x0a` pages append per-(geo,outer-dim)
  suppression-mask records after the value run.) The head is a *contiguous run of
  32-byte blocks*, so the set is the observed span, not a sparse enumeration:
  `0x0b`/`0x0d`/`0x0e` were added for the SP3/RHUXA9 income lineage, where the
  head grows with the geography dimension's slot allocation. Those pages carry
  allocation slack, so the size equation only bounds them (`≤`); the head length
  was confirmed by data reconciliation instead — see `decode-history.md`.
- **`b2` — trailer** (`ivt_value_trailer`): `0` when `b2 == 0x00`, else
  `2·(b2 >> 4) + 2·(low nibble(b2) > 0)`. Realised as a 0xFF pad run.
- **Dense variant** (`b0` high nibble `0x0`): bytes 3–4 are a **u16 value count**,
  not `b2`/`b3` — `[b0][01][u16 count]` then `count` positional values (1991
  profiles). `ivt_decode_page_dense()`.

Value-run start = `4 + presence_len + trailer + head`. An unrecognised width, high
nibble or `b3` **aborts** (`canivt_unknown_marker`).

Literal container markers observed as the recurring page/sub-record heads:
`82 01 80 08`, `84 01 40 08` (sub-record), `88 01 20 08`.

Recognizers: `ivt_f2_is_marker()`, `ivt_value_trailer()`; sets `ivt_f2_marker_b0`,
`ivt_f2_marker_b0_dense`, `ivt_f2_marker_b3`, `IVT_MARKER_WIDTHS` (container-f2.R).

## D. Dimension-descriptor signature (9 bytes)

`81 01 20 00 f0 .. .. 80 [b9]` — opens the descriptor block on **every** layout.
`b5/b6` vary (`20`/`28`); `b9 ∈ {0x03, 0xff}` (**`0x03`** standard, **`0xff`** the
Canadian Business Patterns lineage). Recognizer `ivt_f2_is_descriptor()`.

Within the descriptor each dimension is a record `[count][type][sep][name][name]`
(doubled name; the first copy may be truncated ~14 chars). The type byte is a
storage/width tag, **not** a fixed dimension identity. The name **separator** is
normally `01`, but the `04`-gen criminal-court survey lineage frames its
reference-period / year record with a **bare `02`** separator instead —
`[count][type] 02 <name><name>` (accs's "Fiscal year": `10 04 02`, count 0x10 =
16, type 0x04). The `01`-only anchor dropped that record, collapsing the strict
walk to 6 of 7 dimensions and forcing the slot-table rebuild (which then
miscounts the deleted-slot "Sex" — see §F). The bare-`02` anchor reads count/type
the standard way and is guarded by the doubled-name self-check. Distinct from the
double-marker **reference-period / facet** variant `[type][count] 01 [01|02]
<doubled name>` — there the byte after the `01` is a name-copy marker, `01` (the
"Year (2)" record `0e 02 01 01`) **or `02`** (the "Date (2)" facet of the
Census-of-Agriculture 2016 crosstabs 00040200/00040207, `13 02 01 02 DateDate`);
the `01 02` form also occurs mid-prose where a doubled name butts against a
previous name's tail, so the `v[k]==0x02` double-marker anchor is gated on a
plausible small facet count (`count < 0x20`).
Recognizer `ivt_f2_descriptor()` (`anchorA` / `bare02`).

## E. Codebook name markers (`81 02 [sub] 00`)

The `81 02` prefix is a **generic block header** shared by several codebook record
types (member-id tables, ordinal delimiters, …); the third byte selects the record
kind and is **not a closed set**. The three sub-codes below are the ones that mark
a **name** block — the only ones the decoder keys on here.

| bytes | meaning | recognizer |
|-------|---------|-----------|
| `81 02 02 00` | **doubled-name** marker — a dimension's name stored twice; the geography anchor and every data-dim label anchor | `ivt_f2_codebook_dim_markers()`, `ivt_f2_dim_dir_label1()` |
| `81 02 01 00` | **single-name** marker (custom/inline geography laid out like a data dim: CRO extracts, EO2654); also wraps a **single-member VALUE** block on the older survey tables — a `81 02 01 00 …[u8 strlen][latin1 string]` whose string reaches the block END exactly (vs the field-NAME block, which has trailing schema bytes), e.g. ucr2.2_3-2006's "Year" member "2006" | `ivt_f2_dir_name_marker01()`, `ivt_f2_dim_value_block_labels()` |
| `81 02 03 00` | before-descriptor **retry anchor** for the INVERTED descriptor layout | `ivt_f2_descriptor()` |
| `81 02 <alloc> 00` | **per-member FLAG block** (`alloc` = a power of two ≥ 8 = `nextpow2(member count)`): one flag byte per member (near-uniform, e.g. `e0`), the rest of `alloc` zero-padded. The reference-period / "Timeseries" dimension of the no-descriptor survey lineage stores its members this way (no label array); member count = the non-zero flag bytes. Distinct from the field dictionary `81 02 <nfields> 00` (small `nfields`, `[02][len][name]` payload) | `ivt_f2_slot_member_count()` |

### E.1 The `02 00 20 00` survey generation's sub-kind byte

On the **older `02 00 20 00` survey lineage** (file **byte 0 == `0x02`** — Health
Statistics at a Glance 1999, Census of Agriculture / Small Area Business 1996,
provincial employment/training extracts) each `81 02 <alloc> 00` codebook block
carries a **sub-kind byte at offset +5** (`b5`) that selects the record type. A
single dimension's block directory carries several of these, told apart by `b5`:

| bytes | `b5` | meaning | recognizer |
|-------|------|---------|-----------|
| `81 02 <n> 00 22 00 <field names>` | `0x22` | **field-schema dictionary** — the dimension's column vocabulary (`Code`, `Label`/`Etiquette`, …); the reference/time dimension names its sole field after itself ("Timeseries"), the naming fallback | `ivt_f2_02_schema_name()` |
| `81 02 02 00 56 00 <EN><sep><desc><FR><sep><desc>` | `0x56` | **bilingual dimension-name marker** — the primary dimension-name source (a directory also holds a `.. 02 00 16 00` code array, so the generic doubled-name reader grabs a code; the `56` sub-byte uniquely tags the name) | `ivt_f2_02_name_marker()` |
| `81 02 <alloc-u16> 16 00 …<tail Pascal codes>` | `0x16` | **member CODE array / member-slot table** — present in EVERY generation (each dimension of every corpus table carries this block or the `08 00` time table). The leading **u16 `alloc` is the dimension's DECLARED member-slot allocation**, the basis of the paging geometry (`ivt_f2_dim_slot_alloc()` → `ivt_layout()`): presence-bit nesting and page-directory strides pad each level to it. Almost always `nextpow2(count)`, but it can exceed it — LFHR Table-023's Hours allocates **32 slots for 10 members**, producing the "doubled-window" directory the retired `ivt_survey_double()` probe used to infer from page sizes. On chunked >alloc-member dimensions the u16 is a block-local allocation (observed 1024) below the member count — then it is NOT the slot capacity (fall back to nextpow2(extent)). The mid-section between the marker and the codes is a **22-bit record per slot**, `alloc` of them, byte-pair-swapped and MSB-first, the run padded up to an EVEN byte count (`nb = ceil(alloc·22/8)`, rounded up to even) — see §E.1a. Pascal member codes follow at the block tail; a member/label source for a reference dimension with no label array (years "1979-80", SEX "0"/"1"/"2"). Trailing pad slots (empty/whitespace) dropped | `ivt_f2_dim_slot_table()`, `ivt_f2_code_array_members()`, `ivt_f2_dim_slot_alloc()` |
| `81 02 <alloc-u16> 08 00 <alloc slot-flag bytes> … <u24 dates>` | `0x08` | **time-series member table** — `alloc` is a full **u16** slot-capacity (long monthly series need >255 slots: LFHR `NAZQV2/Table-023`'s 276-month Timeseries allocates 512; the older `08 00`-sub-marker guard, which assumed `alloc < 256` by requiring a `00` high byte, dropped it). `alloc` one-byte member-SLOT flags (**byte-pair-swapped** like every container bitmap; non-zero = populated slot, deleted members leave HOLES — tb611996's periods sit at slots {1,2,4}) + one 3-byte little-endian date per populated slot, right-aligned at the block end: **days since 0000-03-01** (proleptic Gregorian; the value lands on Jan 1 of the period's year for annual series, the ISO month-start for a monthly one). Count = non-zero flags; labels are GENERATED from the dates; a clipped leading date (h2530002 stores 36 of 37) is extrapolated backward by the median step. The presence bitmap and page directory address these members **by slot**, so the layout carries `dims[[k]]$slots` | `ivt_f2_time_members()` |

### E.1a. The `16 00` mid-section — the per-slot record

Between `[81 02][u16 alloc][16 00]` and the member-code array sits one
**22-bit record per allocated slot**, `alloc` of them, packed with no padding
between records, then **byte-pair-swapped** and read **MSB-first** like every
other bitmap in the container. The run is padded up to an **even byte count**
(the swap unit): `nb = ceil(alloc · 22 / 8)`, rounded up to even. Corpus-wide the
936,317 slot records take only **34 distinct values**, and only four bit
positions are ever used:

| bit | meaning |
|-----|---------|
| 0 | **LIVE** — the slot holds a real member. A record that is non-zero but has bit 0 clear is a **DELETED** member: it keeps its codebook entry (label, code, ordinal) but addresses no cells |
| 1..12 | **unary code length** — the count of consecutive 1s starting at bit 1 is the byte length of this slot's member code (observed 1..12) |
| 18 | one **extra byte** follows this slot's code in the code array (empirically the aggregate / "total" members) |
| 19 | a further per-slot flag, no byte cost, semantics undetermined (1028 slots corpus-wide) |
| 13–17, 20, 21 | never set |

An all-zero record is a slot that was never allocated.

The member-code array is then walked per **USED** slot in slot order, and its
byte-exact consumption is what **validates** the whole reading:

```
live slot     [u8 len][code]        len == the declared unary length
deleted slot  <len code bytes>      NO length prefix
              + 1 byte              whenever bit 18 is set
```

1335 of the corpus's 1347 `16 00` blocks consume their code array exactly, zero
leftover; the 12 that do not are `alloc = 1024` chunked blocks whose codes live
elsewhere. Restricted to the 459 dimensions that own exactly one such block,
**459/459 parse byte-exactly**.

What this DECLARES, consumed by `ivt_f2_dim_slot_declared()`:

- the **member count** = the live count (a third, and the strongest, count
  witness — it exposes SP3_RHUXA9_801's garbage descriptor counts 3338/3386/
  3378/3338 as 1/5/2/7);
- the **deleted slots** exactly, replacing the `ivt_f2_dim_slot_expand()` margin
  heuristic: accs "Sex" is 5 members over 6 slots with slot **4** deleted
  (confirmed empty in the decode), so the geometry keeps extent 6 via `$slots`
  while the dimension no longer emits a phantom second "Company". CBP's
  "NAT. INDUSTRIES" is 929 members over 949 used slots, 20 deleted — the old
  count-only read cropped at 929 and **lost the 20 live members at slots
  930..949**;
- the **slot POSITIONS**, which need not start at 1 or be contiguous: LFHR
  `Table-210`'s 10-member "Education level" occupies slots **10..19** of its 32,
  and `table_5_c`'s 215 "Offences" skip slot **98**. The presence bitmap
  addresses members by slot, so `1..n` mis-assigns every member above a hole.

Not a fallback and therefore **not loud** — nothing is inferred; the values are
read from a declaration in the file.

`ivt_f2_dim_slot_expand()` (`canivt_deleted_slot`) survives as the fallback for
dimensions with no readable declared table (chunked codebooks, code arrays that
do not parse byte-exactly).

The whole descriptor for this generation is rebuilt from the slot table
(`ivt_f2_descriptor_02()`) — the designed, quiet read for `byte 0 == 0x02`
(the descriptor BLOCK is framed irregularly and is not consulted); a lone
unsized reference dimension is recovered from the value-page layout (LOUD
`canivt_descriptor_02_probe`). These tables have **no geography dimension**:
their regional dimensions (REGION/GEOGRAPHY/Provinces) carry no geographic
identifiers and stay ordinary data dimensions (`ivt_f2_geo_dim_index()`
returns 0). See decode-history.md.

## F. Directory value-entry framings (block-directory entries)

A codebook block directory entry `[u32 off][u16 len][u16 len]` (§I) points at a
value block in one of three framings, all opening with `01 01` or `81 01`:

| bytes | meaning | recognizer |
|-------|---------|-----------|
| `[01 01][u16 len-4][u16 n_slots] <records [len][text][00]>` | **plain** member array; NUL-terminated records, an absent member = empty record `00 00` → NA | `ivt_f2_dir_entry_members()` |
| `[81 01][u16 nbits][bitstream u16-padded][single-bit byte] <records [len][text]>` | **bit-headed DENSE** array; absent members skipped, re-aligned against sibling NA pattern. The pre-records marker is always a **single-bit byte** (exactly one bit set; semantics unknown — the recognizer accepts the class, not an enumeration, after every new lineage surfaced another power of two): `0x80`/`0x01` on the modern chunked tables, `0x10` on the earlier `02 00 20 00` survey generation (PRSIC1dec1999's 11-member "Employment size ranges"), `0x20` on the `04`-gen long-time-series survey lineage (LFHR Table-023's 10-member "Hours worked"), `0x08` on the `04`-gen criminal-court survey lineage's member-label arrays (accs's **6-slot** "Sex" — `Total/Males/Females/Company/Unknown` plus a **DELETED slot** that retains its label; the record count 6 is the physical slot EXTENT, one more than the descriptor's logical count 5), `0x04` on Table-023's Sex (whose English "Both sexes"/Men/Women block the enumerated set silently dropped, labelling the dimension French) | `ivt_f2_dir_entry_members()` |
| `[01 01][u16 len-4][01] <latin1 text, NO NUL>` | **footnote / note TEXT blob** — a lone un-terminated text (e.g. `Renvoi 1 / Ne comprend pas ...`), one per member that cites a note, in the geo directory TAIL; **not** a member array | `ivt_f2_dir_is_text_block()` |

The text-blob framing reuses the plain `01 01` header, so it is told apart
**structurally**: its payload after the `01` marker carries **no `0x00` byte**,
whereas a member array's records are each NUL-terminated. This is the fix that
closed the FSA/FED/ADA (98100019/98100010/98100013) full-attribute read — those
tail blocks used to be miscounted as attribute value blocks and defeat the
regular-layout gate.

## G. Footnote markers

| bytes / text | meaning | recognizer |
|--------------|---------|-----------|
| `84 01 [u16 nbits][bitstream u16-padded]` | **member bitmap** opening a dimension's member-footnote region (EN + identical FR); set bit p → member p+1 carries a note. Pair-swapped, MSB-first | `ivt_f2_footnote_bitmap()` |
| `Footnote N` (EN) / `Renvoi N` (FR) prefix; `FOOTNOTE:` / `RENVOI:` framing | footnote text lead-in (the `N` is always `1` and is not a member ref) | `ivt_footnote_texts()` |

## H. DQF legend record (`@712` directory)

`[82 01][u16][flag bytes][02][code char][00][u16 text_len][text]` — one per
data-quality-flag code A–E / R / P, EN then FR. Recognizer `ivt_f2_dqf_legend()`.

## I. Directory entry shape (8 bytes)

`[u32 off][u16 size][u16 size]` — the shared entry of the **page directory**, the
per-dimension **block directories** and the **master directory**; the two u16 size
fields agree (equality is the end-of-table sentinel), the offset is in range.
Recognizer `ivt_dir_entry()` (page dir) / `ivt_f2_read_dir_at()` (block dirs).

## J. In-page presence bitmap (structural, not a fixed byte)

The "present" marker over the innermost dimension of bit-width `n` is `2^n − 2`
(e.g. Tenure(7)→`0xFE`, Sex(3)→`0xE`): a positional power-of-two-nested bitmap,
read **byte-pair-swapped** then **MSB-first**. Recognizer
`ivt_f2_record_present()`. Not catalogued as a byte set — it is derived from the
layout.

---

## Change log

- **2026-07-25** — **The `16 00` mid-section is decoded** (new §E.1a): 22 bits
  per slot, byte-pair-swapped, MSB-first, even-byte-padded — bit 0 LIVE, bits
  1..12 the unary member-code length, bit 18 a trailing extra code byte, bit 19
  an undetermined flag. Validated by walking the member-code array to a
  byte-exact fit (459/459 single-block dimensions). `ivt_f2_dim_slot_table()` +
  `ivt_f2_dim_slot_declared()`; the file now DECLARES its member count, its
  deleted slots and its slot positions, so `ivt_f2_dim_slot_expand()` is demoted
  to a fallback. Fixes: CBP2008DA/CBP2010DA recovered 20 lost industries each
  (validated — the industry Total now equals the sum of the 928 six-digit NAICS
  leaves in all 312,417 geography × emp-size groups), accs "Sex" no longer emits
  a phantom deleted member.
- **2026-07-23** — **The doubled-window directory is DECLARED metadata** (§E.1
  `16 00` row): the member-code block's leading u16 is the dimension's slot
  ALLOCATION and drives all paging geometry (`ivt_f2_dim_slot_alloc()`;
  `ivt_survey_double()` retired — Table-023's Hours declares 32 slots for 10
  members, byte-identical decode, no probe). §F dense pre-records marker widened
  to the single-bit-byte class (`0x04`, Table-023's English Sex block — fixes the
  Sex dimension labelling French). §E.1 vocabulary note: `ivt_f2_dim_dict_en_first()`
  now also reads the declared `Description`/`Description_FRA` and
  `English`/`French|Français` field pairs (bleed-tolerant leading-boundary
  match), retiring the content-score language fallback on the `04`-gen tables.
- **2026-07-22** — Onboarded the `accs` adult-criminal-court survey. §D: the
  descriptor's bare-`02` name separator (`[count][type] 02 <name><name>`, accs's
  "Fiscal year"). §F: the dense member-label array's `0x08` pre-records marker,
  and the **deleted-slot** insight — a codebook member-label array can carry MORE
  records than the descriptor's logical count (accs "Sex": 6 slots, 5 members);
  the physical slot EXTENT drives the page geometry, and the deleted slot decodes
  empty. This is what made accs LOOK like the LFHR "doubled-window" survey
  directory; it is a distinct root cause (`ivt_f2_dim_slot_expand()`,
  `canivt_deleted_slot`). See decode-history.md.
- **2026-07-18** — Catalog created. Added §F footnote **text-blob** framing
  (`[01 01][u16 len-4][01]<text, no NUL>`, `ivt_f2_dir_is_text_block()`), the fix
  that made 98100019 (FSA) / 98100010 (FED) / 98100013 (ADA) read completely.
