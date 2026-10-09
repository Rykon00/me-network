# Contributing

## Language

**Everything that lands on GitHub is written in English:** code, comments, log messages, locale entries, commit
messages, pull requests, issues, README and other docs.

## Licenses

The repository holds two mods (issue #239): **ME Network** (`me-network`, the repository root) is GPLv3 (the
GT5-Unofficial parts of the graphics LGPL-3.0); **ME Network - AE2 Textures** (`me-network-ae2-textures`, the folder
`ae2-textures/`) holds graphics of Applied Energistics 2 under CC BY-NC-SA 3.0, and everything in that folder is
CC BY-NC-SA 3.0. They are built into two zips and no zip contains both. Every origin and its rules:
[`docs/LICENSES.md`](docs/LICENSES.md).

- AE2 graphics get into the repository only through `tools/import_ae2_textures.py`, into `ae2-textures/graphics/`,
  which records each file in `ae2-textures/MANIFEST.tsv`. They are never in the me-network zip (`tools/build.py` fails
  then), never traced, never merged into one image with graphics of another origin (the texture mod replaces one file
  or layer of a sprite at a time, `ae2-textures/overrides.lua`), never given to `tools/gen_ae2_sprites.py` and never
  taken from anywhere else than a checkout of AE2 or of GTNewHorizons' AE2-Unofficial (the same authors' work under
  the same license; the manifest records which checkout and commit).
- A contribution that touches `ae2-textures/` is made under CC BY-NC-SA 3.0. A changed image stays in the folder and
  is recorded with `tools/import_ae2_textures.py --mark-changed`.
- me-network never depends on the texture mod and never names it; the texture mod finds me-network's prototypes by
  name, which is one more reason never to rename one.
- AE2 code (LGPL-3.0) can be ported into the GPLv3 part: a comment at the function names its source.

## Workflow

1. Work on a branch, open a pull request into `main`.
2. For local testing link the repo into Factorio once: `python tools/dev_link.py`. After that Factorio loads the
   working copy directly; restart Factorio after changes.
3. Before committing: `python tools/check_syntax.py --loaded` and the headless harness
   `python tools/devcheck/devcheck.py all` (see `tools/devcheck/README.md`); it must end with `RESULT: OK`. A change
   that Gregtorio Continued could notice (a prototype, a recipe or technology name, the API, a remote interface) also
   runs `python tools/devcheck/devcheck.py all --with-gregtorio <Gregtorio checkout>`.
4. **Prototype names never change** (entities, items, recipes, technologies, fluids, subgroups, mod-data, custom
   inputs), nor do the storage keys and remote interface names: saves and Gregtorio Continued find them by name.
5. Changelog: the topmost section of `changelog.txt` is always the **next** version (`Version: X.Y.Z` without a
   `Date:` line). Every pull request into `main` that changes the game (prototypes, scripts, locale, graphics) adds its
   player-facing lines there, in the Factorio changelog format (`Features:`, `Changes:`, `Bugfixes:`, `Balancing:`,
   `Graphics:`, `Info:`). Pure tooling or docs changes need no entry. CI fails a game-changing pull request into
   `main` without a `changelog.txt` change unless it has the label `no changelog`. The texture mod has its own
   `ae2-textures/changelog.txt` and its own `version` in `ae2-textures/info.json`; a pull request that changes its
   code, locale or images adds its lines there (CI checks it the same way), in a new topmost section when the topmost
   one is a released version.
6. Releases: `main` is development, `upstream/release` is the published state. Make a release branch from `main`,
   set `version` in `info.json` to the topmost changelog section, add its `Date: YYYY-MM-DD` line, then open a pull
   request from that branch into `upstream/release`. Its checks fail if the version is released already or has no
   changelog section. **The texture mod** has a version of its own, independent of me-network's (issue #243): if
   anything under `ae2-textures/` changed since the last release tag, the release branch also sets `version` in
   `ae2-textures/info.json` to the topmost section of `ae2-textures/changelog.txt` and adds its `Date:` line. That
   version must be one no earlier release used (no release tag holds it, the mod portal does not have it); the checks
   (`tools/release_textures.py`) fail on a used version and on a missing section. When `ae2-textures/` did not
   change, leave it alone: the release attaches and uploads no texture zip. Merge it with a merge commit (not squash
   or rebase). The merge makes `.github/workflows/release.yml` create the GitHub release `vX.Y.Z` with the me-network
   zip (and the texture zip when its version is new), upload the me-network zip to
   https://mods.factorio.com/mod/me-network and a new texture zip to https://mods.factorio.com/mod/me-network-ae2-textures,
   each in a step of its own through `tools/portal_upload.sh`, which takes the mod name from the zip's own `info.json`
   (one repository secret `FACTORIO_MOD_API_KEY` for both: an API key from
   https://factorio.com/profile with the permission "ModPortal: Upload Mods") and, as its last step, fast-forward
   `main` to the merged `upstream/release`, so `main` has the version bump and the `Date:` line too. A local clone
   of `main` then only pulls. If that run shows the warning "main has commits that upstream/release lacks" (something
   was merged into `main` while the release was open, or the release was squashed), or fails before its last step,
   `main` is not moved: merge `upstream/release` into `main` by hand (`git fetch origin`, `git switch main`,
   `git merge origin/upstream/release`, `git push origin main`).
   Without the secret only the GitHub release is created; the zips can then be uploaded by hand
   (`python tools/build.py --portal`). A texture version uploaded by hand goes into `HAND_RELEASES` of
   `tools/release_textures.py` (the version and the commit whose `ae2-textures/` was uploaded), as its 0.1.0 is, so
   that the next release knows it. After a release the job `announce`
   posts a digest of the version's changelog section to the Discord channel `#me-network-releases` and, when the
   texture version is new, a second one from `ae2-textures/changelog.txt` (repository secret
   `DISCORD_BOT_TOKEN`; without it the job only warns); if it fails, re-run that job alone.
   The very first version of each mod (me-network 0.1.0, the texture mod 0.1.0) was uploaded by hand: the portal API
   only uploads new versions of an existing mod. A release is made by a new me-network version, so with the workflow
   as it is a new texture version alone goes out with a me-network patch release (or is uploaded by hand and recorded
   as above); a texture-only release is issue #245.
7. Gregtorio Continued depends on this mod: a version that Gregtorio needs is released here first, then Gregtorio
   raises its dependency `me-network >= X.Y.Z`.

## Commits

- Imperative subject line, max ~70 characters, blank line, then the why and the what.
- One logical change per commit.
