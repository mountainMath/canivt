#!/usr/bin/env python3
# Streaming raw-DEFLATE inflater for IVT zip members (method 8).
# Usage: rh_inflate.py <compressed-prefix-in> <uncompressed-out>
# A TRUNCATED deflate prefix does not error: zlib.decompressobj streams, so it
# emits every uncompressed byte the given compressed prefix determines. That is
# exactly the uncompressed metadata prefix, recovered from a small compressed read.
import sys, zlib

cin, out = sys.argv[1], sys.argv[2]
d = zlib.decompressobj(-15)                     # raw deflate, no header
buf = d.decompress(open(cin, "rb").read())
open(out, "wb").write(buf)
sys.stderr.write("%d\n" % len(buf))
