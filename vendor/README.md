# Vendored dependencies

Third-party source, vendored directly: no package manager, no submodules, no
ecosystem. Each dependency is a single file or a source-only tree.

| Path | Upstream | Version | License | Used for |
| --- | --- | --- | --- | --- |
| `stb_vorbis.c` | https://github.com/nothings/stb | public domain (Unlicense) / MIT | see file header | Vorbis decoding (tests + peer decode) |
| `libogg/` | https://xiph.org/ogg/ | 1.3.6 | BSD-3-Clause (`libogg/COPYING`) | Ogg container (encode path) |
| `libvorbis/` | https://xiph.org/vorbis/ | 1.3.7 (2020-07-04) | BSD-3-Clause (`libvorbis/COPYING`) | Vorbis encoding of the kujamba channel |
| `miniaudio.h` + `miniaudio_impl.c` | https://github.com/mackron/miniaudio | 0.11.25 (2026-03-04) | public domain / MIT-0 (statement at the end of `miniaudio.h`) | live audio device behind the `zc_*` shim (#20: `kujamba play`/`trigger` local playback) |

Provenance: these trees were taken from zclient
(`drawmeanelephant/ninjam`, branch `agent/zclient`, commit `f428caf`) and are
compiled exactly as zclient's `build.zig` compiles them (same source list,
same `-fno-sanitize=undefined` flag for libvorbis). zclient's own provenance
work (trimming the Xiph tarballs to the files the build needs) is preserved;
`libvorbis` is 1.3.7 because that is what the reference client's CMake
FetchContent also uses, so both encoders link the same version.

Provenance: miniaudio was taken unchanged from zclient
(`drawmeanelephant/ninjam`, branch `agent/zclient`, commit `4d40aa1c`) except
for the shim fixes this PR needed: the custom-device-id path now resolves ids
through backend enumeration (the old code passed a `ma_device_id*` as
`ma_device_init`'s context argument), `zc_playback_device_open` was added for
the playback-only audition path, and `zc_error_string` no longer negates the
result code twice. The miniaudio TU compiles only when `-Dlive` is on
(default for macOS targets): `zig build` on Linux stays ALSA-free unless the
flag asks for audio.

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
