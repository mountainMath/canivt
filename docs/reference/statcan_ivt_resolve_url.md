# Resolve a published IVT link to its direct-download URL

StatCan publishes the IVT link in two forms. The 2021-era products link
straight to a Beyond 20/20 `.zip`; older products link to an
`Alternative.cfm?PID=` landing page that itself forwards to a
`Download.cfm?PID=` endpoint serving the raw `.ivt`. This returns the
direct URL in either case (a `.zip` is returned unchanged).

## Usage

``` r
statcan_ivt_resolve_url(ivt_url)
```

## Arguments

- ivt_url:

  The published IVT link (absolute or relative to the datasets base).

## Value

The direct-download URL.

## Examples

``` r
# An Alternative.cfm landing page resolves to its Download.cfm endpoint:
statcan_ivt_resolve_url("Alternative.cfm?PID=55701&EXT=IVT")
#> [1] "https://www12.statcan.gc.ca/datasets/Download.cfm?PID=55701"
# a direct .zip is returned unchanged:
statcan_ivt_resolve_url("https://www150.statcan.gc.ca/n1/en/tbl/b2020/98100241.zip")
#> [1] "https://www150.statcan.gc.ca/n1/en/tbl/b2020/98100241.zip"
```
