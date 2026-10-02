# Notes for AI agents

- **Language:** everything that ends up on GitHub is English (code, comments, log messages, locale, commits, PRs,
  issues, docs). Chat with the maintainer may be in German.
- Read `CONTRIBUTING.md` and the layout table in `README.md` first. Player guide: `docs/AE2.md`; design record:
  `docs/ME-REWORK.md`; data-stage API for other mods: `docs/API.md`.
- This mod was part of Gregtorio Continued (https://github.com/Rykon00/Gregtorio) until its issue #83 (its
  `docs/SPLIT.md`). Issue numbers in the code and the docs from before 0.1.0 are Gregtorio's. **Never rename** a
  prototype, a storage key (`fork_me_*`, `fork_ae2`) or a remote interface (`gregtorio-me-*`): saves and Gregtorio
  find them by name, and the hand-over of a Gregtorio save copies the tables as they are.
- Prototypes: `data.lua` (guard against Gregtorio before 0.5.0), `prototypes/api.lua` (`ME_NETWORK`: `add_item`,
  `add_recipe`, `add_technology` for this mod; `replace_recipe`, `remove_recipe`, `set_technology`,
  `make_molecular_assembler` for other mods), `network.lua`, `autocrafting.lua`, `fluids.lua`. Recipes and technologies
  here are the standalone ones (vanilla items, vanilla science); Gregtorio replaces them in its
  `prototypes/120-fork-me-network-compat.lua`. A new item or recipe is added with `ME_NETWORK.add_item` /
  `add_recipe` so it is listed in `ME_NETWORK.recipes`; tell Gregtorio's maintainer (its compat file gives it the GT
  recipe). Numbers reach the runtime through the mod-data `fork-me-network`, `fork-me-autocraft`, `fork-me-fluids`.
- Runtime: `control.lua` registers the build, clone, settings paste, blueprint, removal (with an event filter) and
  rotation events of all modules (the graph first on build, last on removal), `on_init` (first the hand-over of a
  Gregtorio save, `scripts/fork-me-handover.lua`, then the terminal's init: state and graph) and
  `on_configuration_changed` (technology effects reset when this mod changed, the graph rebuild, the migrations of
  old Gregtorio networks, the old fluid blocks becoming the unified ones (`scripts/fork-me-unify.lua`, issue #3), the
  modules). The modules use the storage API of `fork-me-network.lua`, never a logistic
  network. Tick intervals in use: `on_nth_tick` 60 (terminal step: the network's slow step, drive lights, sweep, the
  refresh of open windows), 20 (autocrafting; `fork-me-circuit.lua` runs as its step hook), 15 (I/O: interfaces,
  buses, the storage bus visits: 8 per step for the item side and 8 for the fluid side). Processing patterns catch their
  outputs through the network's insert functions (`N.on_arrival`, no tick). A storage bus is an external cell of the
  storage engine (`N.ext_*`), with an item side and a fluid side (`scripts/fork-me-fluid-storagebus.lua`). Since issue
  #3 the ME Interface, the import, export and storage bus handle items and fluids; the ME Fluid Interface and the ME
  Fluid Import / Export / Storage Bus are hidden prototypes that `scripts/fork-me-unify.lua` replaces (keep them while
  saves may hold them). The entity types the buses work with are in `scripts/fork-me-targets.lua`. The terminal module registers every GUI event and hands it to `fork-me-gui.lua`
  (`dispatch`: actions by the `fork_me_act` tag; the block windows are in `fork-me-windows.lua`).
- The hand-over (`scripts/fork-me-handover.lua`): the table list and the fingerprint function must stay equal to
  Gregtorio's `scripts/fork-me-handover.lua`. A new storage table that a Gregtorio save could hold cannot appear any
  more (Gregtorio no longer has ME code), so the list is fixed.
- **Test every change** with the headless harness: `python tools/devcheck/devcheck.py setup` once, then
  `python tools/devcheck/devcheck.py all` (vanilla with Space Age and quality) and, for anything Gregtorio could
  notice, `all --with-gregtorio <Gregtorio checkout>`. Both must end with `RESULT: OK`; `check --base-only` checks
  without Space Age; `migrate --from-ref v0.1.0` loads a save of an older version with the working copy (for changes to
  saved state or to prototypes that saves hold). The runtime tests (`tools/devcheck/runtimemod/control.lua`) name a few Gregtorio machines and
  recipes; without Gregtorio its `data.lua` adds stand-ins with the same names and numbers. See
  `tools/devcheck/README.md`.
- Every referenced `__me-network__/...` file must exist (headless Factorio does not load graphics, the real game
  crashes on missing files); `devcheck check` lists missing ones and names missing in `locale/en`.
- **Changelog:** every change to the game adds its player-facing lines to the topmost section of `changelog.txt` (the
  next version, no `Date:` line yet). Do not change `version` in `info.json` and do not add a `Date:`; that is the
  release pull request into `upstream/release`.
- Graphics: `tools/gen_ae2_sprites.py` (`--gt <GT5-Unofficial checkout>` for everything; `--fluids`, `--r1`, `--r2`,
  `--patterns` and the other switches for parts, see its docstring).
