---
title: Audit utility
parent: contributors/index
status: published
summary: Source manifests and token warnings, not a security certification.
---

# The oddly serious third binary

`audit` scans a source directory and writes a chunked XML-style manifest for
LLM ingestion. It is independent of the musical instrument and uses Zig
stdlib, not an external parser service.

```bash
zig build audit -- --src src --out manifest.txt
```

The input directory and output path are explicit. Run from the repository
root for that example. The manifest is a generated output, not documentation
to publish to GitHub Pages.

## What it measures

- Approximately 1024-byte windows with 150-byte overlap, snapped to line boundaries.
- UTF-8-safe chunk boundaries.
- SHA-256 per chunk for identifying identical content.
- Approximate surrounding function names.
- Token-based triggers, including `@ptrCast`, `@ptrFromInt`, `system`,
  `syscall`, `anyopaque`, and extern/export FFI.
- A progress display and warning list while files are processed concurrently.

The scan accepts `.zig`, `.zon`, `.md`, and `.json`. It filters paths
containing `.git`, `.zig-cache`, and `zig-out`, and skips `audit.zig` and
`root.zig`. Those filters are not a general secret-discovery or access-control
boundary.

## A HIGH warning is not a vulnerability

The manifest classifies a triggered chunk as HIGH and records its trigger.
That means a pattern worth examining occurred. It does not prove exploitability,
and LOW does not prove safety. The real instrument has legitimate casts, FFI,
and host-player integration.

The function label is approximate; token detection does not turn this into
a semantic whole-program security analysis.

## Treat the manifest as source disclosure

It contains source chunks. Review it before sharing it with a model, a support
ticket, or another service. Do not scan a credential-bearing private tree
and publish its output alongside the docs.
