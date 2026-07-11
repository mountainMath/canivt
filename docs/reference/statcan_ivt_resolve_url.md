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
