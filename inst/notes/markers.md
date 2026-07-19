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
| `04 00 20 00` | THE IVT file signature — every supported file (modern, legacy, profile, custom, Business Patterns) | `read.R` / `ivt_store_download()` |
| `02 00 20 00` | a **different** container family (e.g. Health Statistics 1999) — **not decodable**, rejected before decode | `ivt_is_supported()` returns FALSE |

The signature alone does not imply decodability: same-signature containers that
fail the page pre-flight (`ivt_page_preflight()`) are still rejected.

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
| `@824 + 14·(k−1)` | 14 B | per-dimension **block-directory slot** record `[u32 dir_ptr][u32 ?][u32 n_entries][2B]`, dimension `k` (1 = geography) | `IVT_HDR_DIM_SLOT0` / `IVT_HDR_DIM_STRIDE` |

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
  `b3 ∈ {0x08, 0x09, 0x0a, 0x0c}`. (`b3 ≥ 0x0a` pages append per-(geo,outer-dim)
  suppression-mask records after the value run.)
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

Within the descriptor each dimension is a record `[count][type 01][name][name]`
(doubled name; the first copy may be truncated ~14 chars). The type byte is a
storage/width tag, **not** a fixed dimension identity.

## E. Codebook name markers (`81 02 [sub] 00`)

The `81 02` prefix is a **generic block header** shared by several codebook record
types (member-id tables, ordinal delimiters, …); the third byte selects the record
kind and is **not a closed set**. The three sub-codes below are the ones that mark
a **name** block — the only ones the decoder keys on here.

| bytes | meaning | recognizer |
|-------|---------|-----------|
| `81 02 02 00` | **doubled-name** marker — a dimension's name stored twice; the geography anchor and every data-dim label anchor | `ivt_f2_codebook_dim_markers()`, `ivt_f2_dim_dir_label1()` |
| `81 02 01 00` | **single-name** marker — custom/inline geography laid out like a data dim (CRO extracts, EO2654) | `ivt_f2_dir_name_marker01()` |
| `81 02 03 00` | before-descriptor **retry anchor** for the INVERTED descriptor layout | `ivt_f2_descriptor()` |

## F. Directory value-entry framings (block-directory entries)

A codebook block directory entry `[u32 off][u16 len][u16 len]` (§I) points at a
value block in one of three framings, all opening with `01 01` or `81 01`:

| bytes | meaning | recognizer |
|-------|---------|-----------|
| `[01 01][u16 len-4][u16 n_slots] <records [len][text][00]>` | **plain** member array; NUL-terminated records, an absent member = empty record `00 00` → NA | `ivt_f2_dir_entry_members()` |
| `[81 01][u16 nbits][bitstream u16-padded][80\|01] <records [len][text]>` | **bit-headed DENSE** array; absent members skipped, re-aligned against sibling NA pattern | `ivt_f2_dir_entry_members()` |
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

- **2026-07-18** — Catalog created. Added §F footnote **text-blob** framing
  (`[01 01][u16 len-4][01]<text, no NUL>`, `ivt_f2_dir_is_text_block()`), the fix
  that made 98100019 (FSA) / 98100010 (FED) / 98100013 (ADA) read completely.
