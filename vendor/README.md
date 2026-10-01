# Vendored dependencies

Third-party source, vendored directly: no package manager, no submodules, no
ecosystem. Each dependency is a single file or a source-only tree.

| Path | Upstream | Version | License | Used for |
| --- | --- | --- | --- | --- |
| `stb_vorbis.c` | https://github.com/nothings/stb | public domain (Unlicense) / MIT | see file header | Vorbis decoding (tests + peer decode) |
| `libogg/` | https://xiph.org/ogg/ | 1.3.6 | BSD-3-Clause (`libogg/COPYING`) | Ogg container (encode path) |
| `libvorbis/` | https://xiph.org/vorbis/ | 1.3.7 (2020-07-04) | BSD-3-Clause (`libvorbis/COPYING`) | Vorbis encoding of the kujamba channel |
| `miniaudio.h` + `miniaudio_impl.c` | https://github.com/mackron/miniaudio | 0.11.25 (2026-03-04) | public domain / MIT-0 (statement at the end of `miniaudio.h`) | live audio device behind the `zc_*` shim (#20: `kujamba play`/`trigger` local playback) |

Provenance: the 15 Zig files in `src/ninjam/`, both Xiph source trees, and
the miniaudio/stb headers and shims match zclient in `drawmeanelephant/ninjam`
at **`c2a0d95848c590f8e259cbe105fb68b9a128e791`** byte-for-byte. The null-audio
ABI test also matches upstream (`src/audio_shim_test.c` here,
`zclient/tests/audio_shim_test.c` there). The C dependencies are
compiled exactly as zclient's `build.zig` compiles them (same source list,
same `-fno-sanitize=undefined` flag for libvorbis). zclient's own provenance
work (trimming the Xiph tarballs to the files the build needs) is preserved;
`libvorbis` is 1.3.7 because that is what the reference client's CMake
FetchContent also uses, so both encoders link the same version.

**Pending upstream merge:** this pin is the tip of the reviewed feature branch
`droid/instrument-interfaces-29`, based on `agent/zclient` tip
`17905c5bdf85ff6d385a9741ebadb2e214071d0c`. It is not yet merged. Land the
upstream PR first, then repin this document and README to its actual merged
commit, repeat the checks below and the demo, and only then merge downstream.
Windows (#25) is deferred separately and is not a prerequisite.

The shared shim resolves playback and capture IDs separately from one
enumeration snapshot, retains its context until close, supports playback-only
opening, and returns native negative miniaudio errors. Ring-allocation failures
are tested without opening a device. The production miniaudio TU compiles only when `-Dlive` is on
(default for macOS targets): `zig build` on Linux stays ALSA-free unless the
flag asks for audio. `zig build test` also compiles a standalone null-backend
ABI test regardless of that flag; it never opens real audio hardware.

## Verify the pinned subset

Use a clean upstream checkout at the exact pin (not merely the branch tip).
Run from this repository, with `NINJAM_CHECKOUT` set to that checkout:

```sh
set -e
pin=c2a0d95848c590f8e259cbe105fb68b9a128e791
test "$(git -C "$NINJAM_CHECKOUT" rev-parse HEAD)" = "$pin"
git -C "$NINJAM_CHECKOUT" diff --exit-code HEAD -- zclient/src zclient/vendor zclient/tests
diff -r "$NINJAM_CHECKOUT/zclient/src" src/ninjam
diff -r "$NINJAM_CHECKOUT/zclient/vendor/libogg" vendor/libogg
diff -r "$NINJAM_CHECKOUT/zclient/vendor/libvorbis" vendor/libvorbis
for file in miniaudio.h miniaudio_impl.c stb_vorbis.c stb_vorbis_impl.c; do
  cmp "$NINJAM_CHECKOUT/zclient/vendor/$file" "vendor/$file" || exit 1
done
cmp "$NINJAM_CHECKOUT/zclient/tests/audio_shim_test.c" src/audio_shim_test.c
```

No local exceptions remain in the shared source subset. Upstream's
`zclient/vendor/refresh-vendor.sh --check` independently regenerates and verifies
the pinned third-party downloads and trim rule. Local README/build/test-root
layout is intentionally separate from the vendored source contract.

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
