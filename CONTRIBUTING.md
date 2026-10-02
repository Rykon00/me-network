# Contributing

## Language

**Everything that lands on GitHub is written in English:** code, comments, log messages, locale entries, commit
messages, pull requests, issues, README and other docs.

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
   `main` without a `changelog.txt` change unless it has the label `no changelog`.
6. Releases: `main` is development, `upstream/release` is the published state. Set `version` in `info.json` to the
   topmost changelog section, add its `Date: YYYY-MM-DD` line, then open a pull request from `main` into
   `upstream/release`. Its checks fail if the version is released already or has no changelog section. Merging it
   makes `.github/workflows/release.yml` create the GitHub release `vX.Y.Z` with the zip and upload the same zip to
   https://mods.factorio.com/mod/me-network (repository secret `FACTORIO_MOD_API_KEY`: an API key from
   https://factorio.com/profile with the permission "ModPortal: Upload Mods"). Without the secret only the GitHub
   release is created; the zip can then be uploaded by hand (`python tools/build.py --portal`).
   The very first version (0.1.0) is uploaded by hand: the portal API only uploads new versions of an existing mod.
7. Gregtorio Continued depends on this mod: a version that Gregtorio needs is released here first, then Gregtorio
   raises its dependency `me-network >= X.Y.Z`.

## Commits

- Imperative subject line, max ~70 characters, blank line, then the why and the what.
- One logical change per commit.
