# Vendored dependencies

Third-party source, vendored directly: no package manager, no submodules, no
ecosystem. Each dependency is a single file or a source-only tree.

| Path | Upstream | Version | License | Used for |
| --- | --- | --- | --- | --- |
| `stb_vorbis.c` | https://github.com/nothings/stb | public domain (Unlicense) / MIT | see file header | Vorbis decoding (tests + peer decode) |
| `libogg/` | https://xiph.org/ogg/ | 1.3.6 | BSD-3-Clause (`libogg/COPYING`) | Ogg container (encode path) |
| `libvorbis/` | https://xiph.org/vorbis/ | 1.3.7 (2020-07-04) | BSD-3-Clause (`libvorbis/COPYING`) | Vorbis encoding of the kujamba channel |
| `miniaudio.h` + `miniaudio_impl.c` | https://github.com/mackron/miniaudio | 0.11.25 (2026-03-04) | public domain / MIT-0 (statement at the end of `miniaudio.h`) | live audio device behind the `zc_*` shim (#20: `kujamba play`/`trigger` local playback) |

Provenance: the vendored C trees — `libogg/`, `libvorbis/`, `miniaudio.h`,
`stb_vorbis.c`, `stb_vorbis_impl.c` — match zclient in
`drawmeanelephant/ninjam` at **`a423bd189f8c55fe5d4de8ceb7027349d914eafb`**
byte-for-byte. The C dependencies are compiled exactly as zclient's
`build.zig` compiles them (same source list, same `-fno-sanitize=undefined`
flag for libvorbis). zclient's own provenance work (trimming the Xiph
tarballs to the files the build needs) is preserved; `libvorbis` is 1.3.7
because that is what the reference client's CMake FetchContent also uses, so
both encoders link the same version.

**Merged upstream pin:** [ninjam#42](https://github.com/drawmeanelephant/ninjam/pull/42)
merged on main on 2026-10-06 at the commit above. It carries the wire-safety
work from this repo's #63/#64/#66: the five `stb_vorbis.c` guards and the
bounded interval downloads in `session.zig`. Its follow-up
[ninjam#43](https://github.com/drawmeanelephant/ninjam/pull/43) lands the
caller-buffer `decodeMemory` from #63 — until that merges, `src/ninjam/vorbis.zig`
is the one file whose wire-safety change is downstream-only.

The Zig subset no longer mirrors whole-file. zclient reorganized after the
previous pin (its `zclient/tests/` and the kujamba adapter files left that
tree), and this repository's kujamba integration keeps evolving shared files
(#13/#14/#20/#24). The split, per file, as of this pin:

* byte-identical — `buf.zig`, `clock.zig`, `log.zig`, `wav.zig`, `auth.zig`,
  `main.zig`
* kujamba-integrated divergence (upstream does not carry the kujamba
  features) — `audio.zig` (#20), `net.zig` (#13/#14), `proto.zig`,
  `session.zig` (#24, plus the upstreamed #64 bounds),
  `instrument.zig`, `backpressure_test.zig`, `session_timing_test.zig`
  (fart-app-side files), and `vorbis.zig` (#63, pending ninjam#43)

The shared shim resolves playback and capture IDs separately from one
enumeration snapshot, retains its context until close, supports playback-only
opening, and returns native negative miniaudio errors. Ring-allocation failures
are tested without opening a device. The production miniaudio TU compiles only when `-Dlive` is on
(default for macOS targets): `zig build` on Linux stays ALSA-free unless the
flag asks for audio. `zig build test` also compiles a standalone null-backend
ABI test regardless of that flag; it never opens real audio hardware.

The shared shim resolves playback and capture IDs separately from one
enumeration snapshot, retains its context until close, supports playback-only
opening, and returns native negative miniaudio errors. Ring-allocation failures
are tested without opening a device. The production miniaudio TU compiles only when `-Dlive` is on
(default for macOS targets): `zig build` on Linux stays ALSA-free unless the
flag asks for audio. `zig build test` also compiles a standalone null-backend
ABI test regardless of that flag; it never opens real audio hardware.

## Wire-safety deltas: upstreamed

The wire-hostile audit (#63, #64, #66) left marked deltas in this subset —
five `stb_vorbis.c` hunks (non-positive size refusal in the allocators, the
comment-count bound, the partial-list shrink, the `NULL comment_list` guard
in `vorbis_deinit`, and the codebook `entries * dimensions` product bound)
and the bounded interval downloads in `session.zig`. **All of it now lives
upstream**: ninjam#42 landed the stb guards and the session bounds, ninjam#43
(pending) lands the caller-buffer `decodeMemory` from #63. The in-file marks
(`fart local delta (#63)`, `(#66)`, `wire-hostile-audit delta`) stay as the
paper trail — upstream carries the same comments — and the stb file is
byte-identical to the pin again.

## Verify the pinned subset

Use a clean upstream checkout at the exact pin (not merely the branch tip).
Run from this repository, with `NINJAM_CHECKOUT` set to that checkout:

```sh
set -e
pin=a423bd189f8c55fe5d4de8ceb7027349d914eafb
test "$(git -C "$NINJAM_CHECKOUT" rev-parse HEAD)" = "$pin"

# vendored C trees: byte-identical
diff -r "$NINJAM_CHECKOUT/zclient/vendor/libogg" vendor/libogg
diff -r "$NINJAM_CHECKOUT/zclient/vendor/libvorbis" vendor/libvorbis
for file in miniaudio.h stb_vorbis.c stb_vorbis_impl.c; do
  cmp "$NINJAM_CHECKOUT/zclient/vendor/$file" "vendor/$file" || exit 1
done

# mirrored Zig core: byte-identical (no kujamba integration, no pending deltas)
for file in buf.zig clock.zig log.zig wav.zig auth.zig main.zig; do
  cmp "$NINJAM_CHECKOUT/zclient/src/$file" "src/ninjam/$file" || exit 1
done
```

`miniaudio_impl.c` and the kujamba-integrated Zig files listed above are
checked by review, not by `cmp` — their divergence is the kujamba feature
work, described in the provenance section. Upstream's
`zclient/vendor/refresh-vendor.sh --check` independently regenerates the
pinned third-party downloads, applies its documented local patches, and
verifies the result. Local README/build/test-root layout is intentionally
separate from the vendored source contract.

## What was trimmed (per zclient)

The Xiph trees ship as autotools/CMake/MSVC tarballs: ~329k lines of which
about 65k are C sources and headers. The build compiles 25 files from those
trees via `build.zig`, so the trees were reduced to exactly what the build
needs and nothing else:

* kept — `AUTHORS`, `CHANGES`, `COPYING`, `README.md`, `include/**`, `lib/**`,
  `src/**` (`.c` and `.h`)
* dropped — `configure*`, `aclocal.m4`, `m4/`, `libtool`, `Makefile.am/.in`,
  `CMakeLists.txt`, `*.pc.in`, `*.spec*`, `win32/`, `macosx/`, `symbian/`,
  `debian/`, `doc/`, `test/`, `examples/`, `vq/`, `cmake/`, IDE project files

Nothing in the kept set is generated at build time: `libvorbis/lib/books/` and
`libvorbis/lib/modes/` are the codebook/residue tables that `vq/` would
otherwise generate, and they are committed upstream, so they stay. That is
where most of the remaining size is (1.3 MB of tables out of 2.4 MB).
