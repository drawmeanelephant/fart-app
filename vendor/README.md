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
at **`ae9a4d4325addd42d844047c080b9e1c0d6080d4`** byte-for-byte. The null-audio
ABI test also matches upstream (`src/audio_shim_test.c` here,
`zclient/tests/audio_shim_test.c` there). The C dependencies are
compiled exactly as zclient's `build.zig` compiles them (same source list,
same `-fno-sanitize=undefined` flag for libvorbis). zclient's own provenance
work (trimming the Xiph tarballs to the files the build needs) is preserved;
`libvorbis` is 1.3.7 because that is what the reference client's CMake
FetchContent also uses, so both encoders link the same version.

**Merged upstream pin:** [ninjam#38](https://github.com/drawmeanelephant/ninjam/pull/38)
landed in `agent/zclient` on 2026-10-01 at the commit above. Its zclient tree
is unchanged from reviewed feature commit
`c2a0d95848c590f8e259cbe105fb68b9a128e791`. The exact identity checks and
reference demo have been repeated after the merge. Windows (#25) remains
deferred separately and is not a prerequisite for downstream reconciliation.

The shared shim resolves playback and capture IDs separately from one
enumeration snapshot, retains its context until close, supports playback-only
opening, and returns native negative miniaudio errors. Ring-allocation failures
are tested without opening a device. The production miniaudio TU compiles only when `-Dlive` is on
(default for macOS targets): `zig build` on Linux stays ALSA-free unless the
flag asks for audio. `zig build test` also compiles a standalone null-backend
ABI test regardless of that flag; it never opens real audio hardware.

## Local deltas

**`stb_vorbis.c` carries a local security delta since #63** — it no longer
matches the zclient pin above byte-for-byte, and the `cmp stb_vorbis.c` line
of the verify script fails until upstream reconciles. The delta (each hunk is
marked `fart local delta (#63)` in the file) makes stb_vorbis's error paths
safe for wire-hostile input, which is a hard requirement here: server-supplied
interval downloads are decoded with it.

1. `setup_malloc` / `setup_temp_malloc` refuse non-positive sizes. Sizes are
   wire-driven `int` products, so a hostile stream can wrap one negative
   (e.g. a vendor/comment length near 2^31); the malloc-backed mode happened
   to survive that (`malloc((size_t)negative)` fails), the caller-buffer mode
   did not.
2. The Vorbis comment count is bounded by `INT_MAX/8` and by the remaining
   stream bytes before the slot array is allocated, so its `sizeof(char*) *
   count` cannot truncate below the true size.
3. When a comment-string allocation fails mid-list, the count is shrunk to
   the entries that were actually initialized.
4. `vorbis_deinit` no longer dereferences `comment_list` when the slot-array
   allocation failed (the count is already set by then).

Upstream stb v1.22 (and the zclient pin) has all four bugs. The upstream move
is to land the same guards in `drawmeanelephant/ninjam`'s `zclient/vendor` and
re-pin here; the deltas are marked for exactly that reconciliation.

## Verify the pinned subset

Use a clean upstream checkout at the exact pin (not merely the branch tip).
Run from this repository, with `NINJAM_CHECKOUT` set to that checkout:

```sh
set -e
pin=ae9a4d4325addd42d844047c080b9e1c0d6080d4
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

Until #63 the shared source subset had no local exceptions; the stb_vorbis
security delta in "Local deltas" below is the first, and is marked in-file for
reconciliation. Upstream's
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
