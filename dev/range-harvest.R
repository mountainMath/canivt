# dev/range-harvest.R — PROTOTYPE: lazy range/deflate-backed IVT metadata harvester.
#
# Reads only the front metadata region (and the first data pages) of a remote
# `.ivt` — over HTTP Range for raw endpoints, over a streaming-deflate compressed
# prefix for zipped ones — and runs the UNCHANGED canivt metadata parser on top,
# so the data-page bulk is never fetched. Pairs each harvested fragment with a
# provenance row (id + link + byte ranges) in an inventory file.
#
# Usage:
#   devtools::load_all("~/R/canivt"); source("dev/range-harvest.R")
#   rh_harvest_catalogue("borealis", out_dir, limit = 50)
#   rh_harvest_catalogue("statcan",  out_dir, limit = 50)

suppressMessages({ library(curl); library(arrow) })

RH_UA  <- "Mozilla/5.0 (canivt-metadata-harvester)"
RH_DEV <- tryCatch(dirname(sys.frame(1)$ofile), error = function(e) NA)
if (is.na(RH_DEV) || !dir.exists(RH_DEV)) RH_DEV <- path.expand("~/R/canivt/dev")
RH_PY  <- file.path(RH_DEV, "rh_inflate.py")
# read-through fragment cache (gitignored + rbuildignored: dev/harvest-cache/)
RH_CACHE_ROOT <- file.path(RH_DEV, "harvest-cache")
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# per-file wall-clock deadline, checked INSIDE rh_get so the timeout is a normal
# catchable error raised in the tryCatch-protected network region -- unlike
# setTimeLimit(elapsed=), whose error can fire at any interpreter checkpoint
# (between files, inside an error handler) and ESCAPE the per-file handler, halting
# the whole sweep. NULL when not harvesting (probe / ad-hoc rh_get).
RH_STATE <- new.env(parent = emptyenv()); RH_STATE$deadline <- NULL

rh_cache_dir <- function(id) {
  d <- file.path(RH_CACHE_ROOT, gsub("[^A-Za-z0-9._-]", "_", id))
  dir.create(d, recursive = TRUE, showWarnings = FALSE); d
}

# ---- low-level HTTP range GET (follows redirects, forwards Range) ----------
rh_get <- function(url, from0, to0) {
  if (!is.null(RH_STATE$deadline) && Sys.time() > RH_STATE$deadline)
    stop("rh: per-file deadline exceeded", call. = FALSE)   # catchable, in the protected region
  h <- new_handle(followlocation = TRUE, useragent = RH_UA,
                  range = sprintf("%.0f-%.0f", from0, to0),
                  connecttimeout = 20L, timeout = 90L)  # fast, catchable network cap
  r <- curl_fetch_memory(url, handle = h)
  hd <- curl::parse_headers_list(r$headers)
  list(status = r$status_code, content = r$content, headers = hd, final = r$url)
}

rh_u16 <- function(d, o) as.integer(d[o + 1]) + as.integer(d[o + 2]) * 256L
rh_u32 <- function(d, o) as.numeric(d[o + 1]) + as.numeric(d[o + 2]) * 256 +
                         as.numeric(d[o + 3]) * 65536 + as.numeric(d[o + 4]) * 16777216

# probe: total size, range support, zip signature, first bytes
rh_probe <- function(url) {
  r <- rh_get(url, 0, 63)
  cr <- r$headers[["content-range"]]
  size <- if (!is.null(cr)) as.numeric(sub(".*/", "", cr)) else {
    cl <- r$headers[["content-length"]]; if (!is.null(cl)) as.numeric(cl) else NA
  }
  first <- r$content[seq_len(min(64, length(r$content)))]
  is_zip <- length(first) >= 4 && identical(first[1:4], as.raw(c(0x50,0x4b,0x03,0x04)))
  ranged <- isTRUE(r$status == 206L)
  list(size = if (is.na(size) && !ranged) length(r$content) else size,
       supports_range = ranged, is_zip = is_zip, first = first, final = r$final,
       # a non-range server already streamed the WHOLE body into the probe -- keep it
       full_body = if (!ranged) r$content else NULL)
}

# parse a zip's first local file header -> inner member geometry
rh_zip_member <- function(url) {
  d <- rh_get(url, 0, 63)$content
  flag <- rh_u16(d, 6); method <- rh_u16(d, 8)
  csize <- rh_u32(d, 18); usize <- rh_u32(d, 22)
  nlen <- rh_u16(d, 26); elen <- rh_u16(d, 28)
  name <- rawToChar(d[(30 + 1):(30 + nlen)])
  list(method = method, csize = csize, usize = usize,
       data0 = 30 + nlen + elen, name = name, flag = flag)
}

# ---- backends: each exposes $read(off0, len)->raw, $size, and fetch counters --
# raw sparse backend (64 KiB chunk cache); window0 offsets into a stored zip member
rh_src_raw <- function(url, size, window0 = 0, cache_dir = NULL) {
  e <- new.env(parent = emptyenv())
  e$kind <- "raw"; e$url <- url; e$size <- size; e$window0 <- window0
  e$chunk <- 65536L; e$cache <- new.env(parent = emptyenv()); e$cache_dir <- cache_dir
  e$bytes <- 0; e$reqs <- 0; e$cache_bytes <- 0
  e$read <- function(off0, len) {
    if (len <= 0) return(raw(0))
    off0 <- max(0, off0); len <- min(len, e$size - off0)
    c0 <- off0 %/% e$chunk; c1 <- (off0 + len - 1) %/% e$chunk
    for (ci in c0:c1) {
      k <- as.character(ci)
      if (!exists(k, e$cache, inherits = FALSE)) {
        cf <- if (!is.null(e$cache_dir)) file.path(e$cache_dir, sprintf("c%08d.bin", ci)) else NULL
        if (!is.null(cf) && file.exists(cf)) {            # read-through: disk hit
          ct <- readBin(cf, "raw", n = file.info(cf)$size); e$cache_bytes <- e$cache_bytes + length(ct)
        } else {                                          # miss: network, then persist
          a <- ci * e$chunk; b <- min(e$size, a + e$chunk) - 1
          ct <- rh_get(e$url, e$window0 + a, e$window0 + b)$content
          e$bytes <- e$bytes + length(ct); e$reqs <- e$reqs + 1
          if (!is.null(cf)) writeBin(ct, cf)
        }
        assign(k, ct, e$cache)
      }
    }
    out <- raw(len)
    for (ci in c0:c1) {
      ch <- get(as.character(ci), e$cache, inherits = FALSE); a <- ci * e$chunk
      lo <- max(off0, a); hi <- min(off0 + len, a + length(ch))
      if (hi > lo) out[(lo - off0 + 1):(hi - off0)] <- ch[(lo - a + 1):(hi - a)]
    }
    out
  }
  class(e) <- "ivt_lazy"; e
}

# deflate backend: growing inflated prefix from a streamed compressed prefix
rh_inflate <- function(cb) {                               # raw deflate prefix -> raw
  tf <- tempfile(); to <- tempfile(); on.exit(unlink(c(tf, to)))
  writeBin(cb, tf)
  system2("python3", c(shQuote(RH_PY), shQuote(tf), shQuote(to)), stdout = FALSE, stderr = FALSE)
  readBin(to, "raw", n = file.info(to)$size)
}
rh_src_deflate <- function(url, data0, usize, csize, cache_dir = NULL) {
  e <- new.env(parent = emptyenv())
  e$kind <- "zip-deflate"; e$url <- url; e$data0 <- data0; e$size <- usize; e$csize <- csize
  e$buf <- raw(0); e$have <- 0; e$cfetched <- 0; e$bytes <- 0; e$reqs <- 0; e$cache_bytes <- 0
  # cache the COMPRESSED prefix (small); re-inflate on warm open
  e$cfile <- if (!is.null(cache_dir)) file.path(cache_dir, "compressed.bin") else NULL
  if (!is.null(e$cfile) && file.exists(e$cfile)) {
    cb <- readBin(e$cfile, "raw", n = file.info(e$cfile)$size)
    e$buf <- rh_inflate(cb); e$have <- length(e$buf); e$cfetched <- length(cb); e$cache_bytes <- length(cb)
  }
  e$grow <- function(need) {
    while (e$have < min(need, e$size) && e$cfetched < e$csize) {
      target <- min(e$csize, max(e$cfetched * 2, e$cfetched + 262144))
      cb <- rh_get(e$url, e$data0, e$data0 + target - 1)$content
      e$bytes <- e$bytes + (target - e$cfetched); e$reqs <- e$reqs + 1; e$cfetched <- target
      e$buf <- rh_inflate(cb); e$have <- length(e$buf)
      if (!is.null(e$cfile)) writeBin(cb, e$cfile)          # persist the compressed prefix
    }
  }
  e$read <- function(off0, len) {
    if (len <= 0) return(raw(0))
    len <- min(len, e$size - off0); e$grow(off0 + len)
    n <- min(e$have, off0 + len); if (n <= off0) return(raw(len))
    out <- raw(len); out[1:(n - off0)] <- e$buf[(off0 + 1):n]; out
  }
  class(e) <- "ivt_lazy"; e
}

# in-memory backend (non-range servers -> one full GET; small files only)
rh_src_mem <- function(bytes, from_cache = FALSE) {
  e <- new.env(parent = emptyenv())
  e$kind <- "full"; e$buf <- bytes; e$size <- length(bytes)
  e$bytes <- if (from_cache) 0 else length(bytes)
  e$cache_bytes <- if (from_cache) length(bytes) else 0
  e$reqs <- if (from_cache) 0 else 1
  e$read <- function(off0, len) { if (len <= 0) return(raw(0))
    len <- min(len, e$size - off0); e$buf[(off0 + 1):(off0 + len)] }
  class(e) <- "ivt_lazy"; e
}

# ---- make the lazy source look like a raw vector to the parser --------------
# A handful of OLDER/survey-vintage metadata fallbacks (French-name marker scan,
# geo DGUID byte-scan: codebook-f2.R `as.integer(raw)`) scan the WHOLE vector,
# bypassing `[`. Those tables are small, so materialize on demand; above a cap we
# refuse (a big modern table should never hit a whole-file scan -- it uses the
# directory paths -- so a cap breach flags a genuine "needs full fetch").
RH_MATERIALIZE_CAP <- 96e6
length.ivt_lazy <- function(x) as.integer(x$size)
`[.ivt_lazy` <- function(x, i) {
  i <- as.integer(i); if (!length(i)) return(raw(0))
  lo <- min(i); hi <- max(i)
  span <- x$read(lo - 1L, hi - lo + 1L)
  span[i - lo + 1L]
}
as.integer.ivt_lazy <- function(x, ...) {
  if (x$size > RH_MATERIALIZE_CAP)
    stop(sprintf("ivt_lazy: metadata needs a whole-file scan (%.0f MB > cap); needs-full-fetch",
                 x$size / 1e6), call. = FALSE)
  as.integer(x$read(0, x$size))
}
as.double.ivt_lazy  <- function(x, ...) as.double(as.integer.ivt_lazy(x))
as.numeric.ivt_lazy <- as.double.ivt_lazy

# ---- open a source for a URL (chooses the backend; read-through cache) -------
# When `id` is given and `cache` is TRUE, fetched bytes persist under
# dev/harvest-cache/<id>/ and a `manifest.rds` lets a re-open reconstruct the
# backend from disk WITHOUT re-probing or re-fetching the network.
rh_open <- function(url, size_hint = NA, id = NULL, cache = TRUE) {
  cdir <- if (cache && !is.null(id)) rh_cache_dir(id) else NULL
  man  <- if (!is.null(cdir)) file.path(cdir, "manifest.rds") else NULL

  if (!is.null(man) && file.exists(man)) {                 # reconstruct from cache
    m <- readRDS(man)
    src <- switch(m$container,
      "full-download" = rh_src_mem(readBin(file.path(cdir, "full.bin"), "raw",
                                           n = file.info(file.path(cdir, "full.bin"))$size),
                                   from_cache = TRUE),
      "zip-deflate"   = rh_src_deflate(url, m$data0, m$size, m$csize, cache_dir = cdir),
      "zip-store"     = rh_src_raw(url, m$size, window0 = m$window0, cache_dir = cdir),
      "raw-range"     = rh_src_raw(url, m$size, cache_dir = cdir))
    attr(src, "container") <- m$container; attr(src, "final_url") <- m$final
    attr(src, "member") <- m$member; attr(src, "from_cache") <- TRUE
    return(src)
  }

  p <- rh_probe(url); win0 <- NA; d0 <- NA; cs <- NA; member <- NA
  if (p$is_zip) {
    zm <- rh_zip_member(url)
    if (zm$usize == 0) stop("zip member size in central dir only (data-descriptor); TODO")
    member <- zm$name
    if (zm$method == 0) { win0 <- zm$data0
      src <- rh_src_raw(url, zm$usize, window0 = zm$data0, cache_dir = cdir)
      attr(src, "container") <- "zip-store"
    } else { d0 <- zm$data0; cs <- zm$csize
      src <- rh_src_deflate(url, zm$data0, zm$usize, zm$csize, cache_dir = cdir)
      attr(src, "container") <- "zip-deflate"
    }
    attr(src, "member") <- zm$name
  } else if (p$supports_range && !is.na(p$size)) {
    src <- rh_src_raw(url, p$size, cache_dir = cdir); attr(src, "container") <- "raw-range"
  } else {
    src <- rh_src_mem(p$full_body %||% raw(0)); attr(src, "container") <- "full-download"
    if (!is.null(cdir)) writeBin(src$buf, file.path(cdir, "full.bin"))
  }
  attr(src, "final_url") <- p$final; attr(src, "from_cache") <- FALSE
  if (!is.null(man))
    saveRDS(list(url = url, final = p$final, container = attr(src, "container"),
                 size = src$size, window0 = win0, data0 = d0, csize = cs, member = member), man)
  src
}

# ---- harvest one file -> inventory row (+ optional saved meta/fragment) ------
rh_harvest_one <- function(id, source, url, size_hint = NA, out_dir = NULL,
                           save_meta = TRUE, save_frag = TRUE, timeout = 120, cache = TRUE) {
  t0 <- Sys.time()
  row <- list(id = id, source = source, url = url, fetched_at = format(t0, "%Y-%m-%dT%H:%M:%S"))
  res <- tryCatch({
    RH_STATE$deadline <- t0 + timeout           # a pathological file can't stall the sweep
    on.exit({ RH_STATE$deadline <- NULL; canivt:::ivt_memo_clear() }, add = TRUE)
    src <- rh_open(url, size_hint, id = id, cache = cache)
    warns <- character(0)
    out <- withCallingHandlers(
      canivt:::ivt_quietly({
        fam  <- canivt:::ivt_family(src)
        meta <- canivt:::ivt_f2_metadata(src)
        list(fam = fam, meta = meta)
      }),
      warning = function(w) { warns <<- c(warns, conditionMessage(w)); invokeRestart("muffleWarning") })
    list(src = src, fam = out$fam, meta = out$meta, warns = warns)
  }, error = function(e) list(err = conditionMessage(e), src = if (exists("src")) src else NULL))

  if (!is.null(res$err)) {
    row$status <- if (grepl("needs-full-fetch", res$err)) "NEEDS-FULL-FETCH"
                  else if (grepl("per-file deadline|reached elapsed time limit|reached CPU|Timeout was reached|resolve host", res$err)) "TIMEOUT"
                  else "ERROR"
    row$error <- substr(res$err, 1, 200)
    if (!is.null(res$src)) {
      row$container <- attr(res$src, "container"); row$logical_size <- res$src$size
      row$bytes_fetched <- res$src$bytes; row$n_requests <- res$src$reqs
    }
    return(as.data.frame(row, stringsAsFactors = FALSE))
  }
  src <- res$src; meta <- res$meta
  row$container   <- attr(src, "container")
  row$final_url   <- attr(src, "final_url")
  row$logical_size<- src$size
  row$bytes_fetched <- src$bytes
  row$cache_bytes <- src$cache_bytes %||% 0
  row$from_cache  <- isTRUE(attr(src, "from_cache")) || (src$bytes == 0 && (src$cache_bytes %||% 0) > 0)
  row$n_requests  <- src$reqs
  row$pct_fetched <- round(100 * src$bytes / src$size, 3)
  row$family      <- if (is.na(res$fam)) NA_integer_ else res$fam
  row$supported   <- !is.na(res$fam)
  row$n_dim       <- length(meta$dimensions)
  row$dims        <- paste(vapply(meta$dimensions,
                      function(d) paste0(gsub("[|:]", " ", substr(d$name, 1, 20)), ":", d$count), ""),
                      collapse = "|")
  nrow0 <- function(x) if (is.data.frame(x)) nrow(x)
                       else if (is.list(x) && length(x)) length(x[[1]]) else 0L
  row$n_geo       <- meta$n_geographies %||% nrow0(meta$geographies)
  row$n_footnotes <- nrow0(meta$footnotes)
  row$n_warn      <- length(res$warns)
  row$warn        <- paste(unique(res$warns), collapse = " ~ ")
  row$status      <- if (row$supported) "OK" else "UNSUPPORTED"

  if (!is.null(out_dir)) {
    safe <- gsub("[^A-Za-z0-9._-]", "_", id)
    if (save_meta) {
      dir.create(file.path(out_dir, "meta"), showWarnings = FALSE, recursive = TRUE)
      saveRDS(list(id = id, source = source, url = url, final_url = row$final_url,
                   family = res$fam, metadata = meta),
              file.path(out_dir, "meta", paste0(safe, ".rds")))
    }
    if (save_frag) {                     # contiguous inflated/fetched prefix
      dir.create(file.path(out_dir, "frag"), showWarnings = FALSE, recursive = TRUE)
      frag <- if (src$kind %in% c("zip-deflate", "full")) src$buf else {
        # raw backend: concat fetched chunks in offset order (contiguous prefix
        # when front-loaded; sparse otherwise -- ranges implied by chunk indices)
        ks <- sort(as.integer(ls(src$cache)))
        if (length(ks)) do.call(c, lapply(ks, function(k) get(as.character(k), src$cache))) else raw(0)
      }
      writeBin(frag, file.path(out_dir, "frag", paste0(safe, ".ivtfrag")))
      row$frag_bytes <- length(frag)
    }
  }
  as.data.frame(row, stringsAsFactors = FALSE)
}

# ---- harvest a whole catalogue ---------------------------------------------
rh_harvest_catalogue <- function(source = c("borealis", "statcan"), out_dir,
                                 limit = NULL, keys = NULL, resume = TRUE, ...) {
  source <- match.arg(source)
  cat_path <- file.path(path.expand("~/data/ivt_data"),
                        if (source == "borealis") "borealis_ivt_catalogue.parquet"
                        else "statcan_ivt_catalogue.parquet")
  cat <- as.data.frame(read_parquet(cat_path))
  if (source == "borealis") {
    cat <- cat[cat$file_type == "Beyond 20/20" | grepl("\\.ivt$", cat$file, TRUE), ]
    cat <- cat[!duplicated(cat$file_stem), ]
    rows <- data.frame(id = cat$key, url = cat$download_url,
                       size_hint = cat$size_in_bytes, stringsAsFactors = FALSE)
  } else {
    cat$ivt_base <- sub("\\.zip$", "", basename(cat$ivt_url))
    cat <- cat[!duplicated(cat$ivt_base), ]
    # id = ivt_base (unique per file); cat$catalogue repeats across a cube's members
    rows <- data.frame(id = cat$ivt_base, url = cat$download_url,
                       size_hint = NA, stringsAsFactors = FALSE)
  }
  if (!is.null(keys)) rows <- rows[rows$id %in% keys, , drop = FALSE]
  if (!is.null(limit)) rows <- head(rows, limit)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  # RESUME: a per-file meta rds is written only on a SUCCESSFUL harvest, so skipping
  # keys that already have one re-runs a batch cheaply and retries ONLY the failures
  # (ERROR/TIMEOUT/NEEDS-FULL-FETCH wrote no meta). Set resume = FALSE to force all.
  if (isTRUE(resume)) {
    done <- file.exists(file.path(out_dir, "meta",
                                  paste0(gsub("[^A-Za-z0-9._-]", "_", rows$id), ".rds")))
    if (any(done))
      message(sprintf("resume: skipping %d/%d already-harvested %s files",
                      sum(done), nrow(rows), source))
    rows <- rows[!done, , drop = FALSE]
  }
  inv <- vector("list", nrow(rows))
  for (i in seq_len(nrow(rows))) {
    message(sprintf("[%d/%d] %s %s", i, nrow(rows), source, rows$id[i]))
    inv[[i]] <- tryCatch(
      rh_harvest_one(rows$id[i], source, rows$url[i], rows$size_hint[i], out_dir = out_dir, ...),
      error = function(e) data.frame(id = rows$id[i], source = source, url = rows$url[i],
                                     status = "FATAL", error = conditionMessage(e),
                                     stringsAsFactors = FALSE))
    inv_df <- do.call(rbind, lapply(inv[seq_len(i)], function(d) {
      d[setdiff(RH_INV_COLS, names(d))] <- NA; d[RH_INV_COLS] }))
    write.csv(inv_df, file.path(out_dir, sprintf("inventory_%s.csv", source)), row.names = FALSE)
  }
  invisible(do.call(rbind, lapply(inv, function(d) { d[setdiff(RH_INV_COLS, names(d))] <- NA; d[RH_INV_COLS] })))
}

RH_INV_COLS <- c("id","source","url","final_url","container","logical_size","bytes_fetched",
                 "cache_bytes","from_cache","n_requests","pct_fetched","frag_bytes","supported",
                 "family","n_dim","dims","n_geo","n_footnotes","status","n_warn","warn","error",
                 "fetched_at")
