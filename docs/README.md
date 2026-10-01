# Maintain the field manual

The user site is authored under `docs/site/content/`. Repository roadmap,
issue history, vendor notices, and raw demo/audit outputs are not automatically
published. README is the quick introduction, not a second full manual.

## Toolchain and local build

- Zig **0.16.0**, Git, Bash, and `jq`.
- Boris **`08969742f85238443ce5cd1cd53ceab1b1f3f85a`**, recorded once in
  `docs/boris-pin.txt`. Its dependencies retain Boris's content-hash pins.
- No Node, npm, bundler, or browser framework is needed.

```bash
bash docs/build.sh
```

The script fetches the exact compiler commit into an ignored, task-owned
`zig-cache` directory, builds it, validates the profile/content, compiles the
site, enforces `boris proof verify`, and uses Boris's own artifact verifier.
An existing mismatched or dirty checkout fails rather than being reset.
`BORIS_CHECKOUT=/absolute/path/to/boris` selects a clean, matching checkout
without permitting the script to replace it.

Generated HTML goes to `docs/site/dist/`. Each build produces a fresh evidence
directory containing the normalized plan, proof reports, compiler/source pins,
artifact verification, and a **public-only** subtree. These paths are ignored.
Do not upload the entire repository or copy `_boris/proof` into Pages.

## Local preview and authoring

Use the compiler checkout used by the build (the default path includes
the pin):

```bash
PIN=$(cat docs/boris-pin.txt)
BORIS="$PWD/zig-cache/docs-boris-$PIN/zig-out/bin/boris"
"$BORIS" watch --profile docs/site/boris.json --serve
```

The built-in preview serves on loopback at `http://127.0.0.1:8090/`.
It is a local preview, not evidence of a Pages deployment. Ctrl+C stops it.

Pages are Markdown with Boris's closed frontmatter. Use `title`, `parent`,
`status`, and `summary` for ordinary docs. `parent` is a page id relative to
the content root, without `.md`; for example `guides/index`. Use validated
wiki-links such as `[[reference/cli|command reference]]`.

Raw HTML headings need explicit stable `id` values so search fragments resolve.
Keep brand/layout changes in `site/themes/flatlophone/`. The shell and inline
search derive from Boris's default theme, with its MIT notice shipped in assets.
Do not add remote fonts, linked JS, trackers, or a second docs compiler.

## Validate examples

```bash
zig build -Doptimize=ReleaseSafe -Dlive=false --prefix zig-out-docs
KUJAMBA_BIN="$PWD/zig-out-docs/bin/kujamba" bash docs/test_examples.sh
```

The smoke executes render, Ogg decode, voice, pattern, and config examples in
an isolated temporary directory. Silence must be rejected. It never plays
sound, joins a remote room, or needs a microphone. Interactive/device commands
are documented from actual code/help and are not disguised as automated tests.

## GitHub Pages

`.github/workflows/docs.yml` validates/builds on PRs, `main`, and manual dispatch.
PRs do not deploy or need Pages write permissions. Only pushes to `main` and
manual runs on `main` publish. They resolve the authoritative URL through
`actions/configure-pages`, overlay
that identity into a temporary profile, and validate it with Boris.

The default project location is `https://drawmeanelephant.github.io/fart-app`
with origin `https://drawmeanelephant.github.io` and base path `/fart-app`.
The compiler rejects contradictory locations and checks rendered routes,
search fragments, assets, and sitemap metadata.

The workflow uploads only the verified public subtree as the Pages artifact.
It retains proof/toolchain/plan evidence separately, including failed proof
checks. These CI artifacts are not private storage for secrets. Deploy alone gets
`pages: write` and `id-token: write`. Configure **Settings → Pages → GitHub
Actions** before the first deployment. Deployment acceptance is not a live
HTTP audit; inspect the published navigation/search after the first merge.

## Update Boris deliberately

Change `boris-pin.txt` only after checking upstream behavior and dependency
pins. Rebuild, rerun proof/artifact checks and example smokes, and test desktop,
mobile, nested navigation, search, and no-JS navigation. Update the compiler
provenance in the contributor page and theme README if those sources change.
Keep docs authority separate from mutable test counts or historical receipts.
