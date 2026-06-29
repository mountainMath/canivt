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
- [?] The marker-specific `0xFF` **trailer length** (264/270/294) — positional.

## [ ] Not parsed at all

- [ ] The **variable section-pointer table** (~header bytes 690–1080). Known to
  exist and to tag entries with a type byte (`16` = member/data block, `15` =
  notes), but its record grammar is undecoded. Not needed (everything is located
  from the fixed header + scanning), but it is the single unparsed structure.

## [ ] Unknown / possibly not in the binary

- [ ] **Footnote → member/dimension linkage.** The metadata CSV carries per-member
  Note IDs; we extract footnote *text* but not *which* footnote annotates which
  member. (The inline `01 01 … 00 01` markers we investigated are block framing,
  not note references, so it is unproven this linkage is stored inline at all.)
- [ ] **Member hierarchy as a structured tree** for family 2. Encoded via leading-
  space indentation in the labels (preserved verbatim) but not parsed into
  parent/child. Family 1 exposes `ivt_label_depth()`; family 2 does not yet.

## Summary

~100 % of information-bearing bytes are identified, and the data plus all
geography/dimension/footnote metadata decode exactly across all three layouts.
Remaining gaps, by size: (1) the **French label copies** (~half the codebook,
fully recoverable, just not surfaced); (2) the **section-pointer table grammar**
(routed around); (3) a handful of small header/marker bytes with inferred/unknown
semantics. The only information *missing vs the StatCan metadata* is the
footnote↔member linkage and the structured member hierarchy — both possibly absent
from the binary and present only in the companion metadata CSV.
