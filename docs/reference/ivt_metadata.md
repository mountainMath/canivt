# Read only the metadata of an IVT file (no value decoding)

Much faster than
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
when you only need the codebook: table identity, dimension members,
geographic identifiers (names + DGUIDs) and footnotes.

## Usage

``` r
ivt_metadata(path)
```

## Arguments

- path:

  Path to an `.ivt` file.

## Value

A list of metadata (see
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)).
