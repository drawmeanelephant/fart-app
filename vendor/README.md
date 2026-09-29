# Vendored dependencies

Third-party source, vendored directly: no package manager, no submodules, no
ecosystem. Each dependency is a single file or a source-only tree.

| Path | Upstream | Version | License | Used for |
| --- | --- | --- | --- | --- |
| `stb_vorbis.c` | https://github.com/nothings/stb | public domain (Unlicense) / MIT | see file header | Vorbis decoding (tests + peer decode) |
| `libogg/` | https://xiph.org/ogg/ | 1.3.6 | BSD-3-Clause (`libogg/COPYING`) | Ogg container (encode path) |
| `libvorbis/` | https://xiph.org/vorbis/ | 1.3.7 (2020-07-04) | BSD-3-Clause (`libvorbis/COPYING`) | Vorbis encoding of the kujamba channel |

Provenance: these trees were taken from zclient
(`drawmeanelephant/ninjam`, branch `agent/zclient`, commit `f428caf`) and are
compiled exactly as zclient's `build.zig` compiles them (same source list,
same `-fno-sanitize=undefined` flag for libvorbis). zclient's own provenance
work (trimming the Xiph tarballs to the files the build needs) is preserved;
`libvorbis` is 1.3.7 because that is what the reference client's CMake
FetchContent also uses, so both encoders link the same version.

## Not vendored

`miniaudio.h` / `miniaudio_impl.c` (live audio device) are deliberately absent:
`kujamba` is a headless instrument — no mic, no speaker — and the session
engine is compiled with `live = false`, so the Phase-B live path is never
analyzed or linked.

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
