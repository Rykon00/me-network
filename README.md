# ME Network

An ME storage network for Factorio 2.0, inspired by Applied Energistics 2: ME blocks joined by cables, storage cells
in drives that keep their contents, a terminal as the hub, interfaces and buses for items and fluids, storage buses on
chests and tanks,
autocrafting with encoded patterns and crafting CPUs, level maintainers, and fluids. On the mod portal:
[ME Network](https://mods.factorio.com/mod/me-network) (`me-network`).

**Discord:** questions, help and release news in the [Gregtorio & ME Network server](https://discord.gg/bfkwAanSD8), shared with
[Gregtorio Continued](https://github.com/Rykon00/Gregtorio).

It was made in [Gregtorio Continued](https://github.com/Rykon00/Gregtorio) (issues #68, #38, #80) and became a mod of
its own in Gregtorio issue #83. On its own it uses vanilla recipes and technologies; Gregtorio Continued depends on it
and puts it on its GregTech tiers (its `prototypes/120-fork-me-network-compat.lua`, through the API below). Issue
numbers in the code and in `docs/` before 0.1.0 are Gregtorio's.

The player guide is `docs/AE2.md`, the design record `docs/ME-REWORK.md`, the data-stage API for other mods
`docs/API.md`, the measured cost at megabase size `docs/PERFORMANCE.md`. The licenses of every part: `docs/LICENSES.md`. The design note of the wireless terminal (issue #153, not built yet) is `docs/ME-WIRELESS.md`.

**Old saves:** since 0.5.1 a save is converted only from ME Network 0.5.0 on (issue #146). A save of an older version
(ME Network 0.1.0 to 0.3.x, or Gregtorio Continued 0.4.x and older) is refused with a message when it loads; load it
once with ME Network 0.5.0, save it, then update (`docs/AE2.md`, "Old saves").

## Layout

The repository root is the mod itself. The folder `ae2-textures/` is a second, optional mod, ME Network - AE2 Textures
(`me-network-ae2-textures`, CC BY-NC-SA 3.0, issue #239), built into a zip of its own; see "License".

| Path | Contents |
|---|---|
| `data.lua` | refuses to load next to Gregtorio Continued before 0.5.0 (which contains this network itself), then loads the prototypes |
| `prototypes/api.lua` | the data-stage API `ME_NETWORK` (`docs/API.md`): items, recipes and technologies of this mod, replacing and removing recipes, setting technologies, the molecular assembler |
| `prototypes/network.lua` | cable and underground cable, controller, drive, storage components and cells (items with tags), housing, ME chest (issue #229: one cell, its own terminal and power), interface, import, export and storage bus, terminal, the hidden old drive items, mod-data `fork-me-network`, technologies `me-network`, `me-storage-64k`, `me-storage-256k` |
| `prototypes/autocrafting.lua` | pattern provider, pattern terminal, blank and encoded pattern, molecular assembler, the crafting blocks of the multiblock crafting CPUs (issue #6), level maintainer, circuit interface, mod-data `fork-me-autocraft`, technologies `me-autocrafting`, `me-automation`, `me-co-processing`, `me-quantum-crafting` |
| `prototypes/fluids.lua` | fluid cells, the ME Interface's fluid sides, the hidden old fluid drive items, mod-data `fork-me-fluids`, technologies `me-fluid-storage`, `me-fluid-storage-256k` |
| `data-final-fixes.lua` | removes the recipes (also another mod's) that make an item this mod no longer makes (`ME_NETWORK.removed`); unlocks a crafting block recipe that no technology unlocks any more (issue #6); lets every crafting machine paste its settings onto the ME Interface, the import, export and storage bus (`additional_pastable_entities`) |
| `settings.lua` | the map settings: the scheduler's budgets, the bus speed and the idle limits (issue #5, `docs/PERFORMANCE.md`) |
| `control.lua` | the event registrations of every module, the one `on_tick` handler (the scheduler), `on_init` (with the hand-over from Gregtorio) and `on_configuration_changed` (saves before 0.5.0 refused, graph rebuild, modules) |
| `scripts/fork-me-network.lua` | the core: cable graph, networks and their controller, storage cells and the storage API, the drive, partitions and priorities, external cells (storage buses), the cable router; remote interface `gregtorio-me-network` |
| `scripts/fork-me-schedule.lua` | the scheduler: queues of due units, budgets per tick, intervals, idle limits, the settings (issue #5) |
| `scripts/fork-me-stats.lua` | the command `/me-stats`: members, block states, the scheduler's counters of the last minute (issue #38, part 3) |
| `scripts/fork-me-io.lua` | ME Interface (items, and fluids through its four sides) and import/export buses (items and fluids), their scheduled visits; `gregtorio-me-io` |
| `scripts/fork-me-targets.lua` | what a bus works with: the entity types and inventories of the import, export and storage bus, the tile in front, fluid boxes |
| `scripts/fork-me-cardslots.lua` | the card slots of a block (a script inventory the window shows, the clicks, blueprints, mining): the storage bus's and, since issue #110, the import and export bus's |
| `scripts/fork-me-storagebus.lua`, `scripts/fork-me-fluid-storagebus.lua` | the storage bus: its item side (a chest, logistic chest or cargo wagon) and its fluid side (a tank's fluid segment) as network storage; `gregtorio-me-storagebus`, `gregtorio-me-fluid-storagebus` (the old remote, on the storage bus) |
| `scripts/fork-me-recipe-paste.lua` | a crafting machine's recipe pasted onto an ME Interface, import, export or storage bus (issue #12); `gregtorio-me-recipe-paste` |
| `scripts/fork-me-terminal.lua`, `fork-me-gui.lua`, `fork-me-windows.lua` | the terminal (hub window), the shared GUI and the windows of every block; `gregtorio-me-terminal`, `gregtorio-me-gui` |
| `scripts/fork-me-patternterm.lua` | the ME Pattern Terminal (issue #130): the pattern editor window and the block's blank and output slots; `gregtorio-me-pattern-terminal` |
| `prototypes/wireless.lua`, `scripts/fork-me-wireless.lua` | the wireless terminal (issues #153, #205 to #211): ME Wireless Access Point and Wireless Boosters, the Wireless ME Terminal item and its hotkey, the ME Charger, the equipment module; the wireless window is the terminal's (or the pattern terminal's) with the access point as its entity; mod-data `fork-me-network` `wireless`, technology `me-wireless`; `gregtorio-me-wireless` |
| `scripts/fork-me-picker.lua` | the mod's own item and fluid picker (groups, search, qualities, green check; issue #94), used by the ME Cell Workbench |
| `scripts/fork-me-names.lua` | the names of items and fluids in each player's language (requested from the client a few per tick), so the search of the picker and the terminal finds an item by the name it shows (issue #295) |
| `scripts/fork-me-autocraft.lua`, `fork-me-patterns.lua` | providers with encoded patterns, planner (with the bytes of a job), jobs, the multiblock CPUs (groups of crafting blocks kept up to date on build and removal), the pattern items; `gregtorio-me-autocraft` |
| `scripts/fork-me-circuit.lua` | level maintainer and circuit interface; `gregtorio-me-circuit` |
| `scripts/fork-me-fluids.lua` | the fluid calls of the other modules; `gregtorio-me-fluids` |
| `scripts/fork-me-handover.lua` | takes the ME state of a Gregtorio Continued save once (Gregtorio issue #83) |
| `graphics/` | sprites, icons and technology icons (`tools/gen_ae2_sprites.py`), GPLv3/LGPL-3.0 |
| `ae2-textures/` | the second mod, `me-network-ae2-textures` (issue #239), CC BY-NC-SA 3.0, nothing of it is GPL: its `info.json` (depends on `me-network`), `overrides.lua` (which sprites of this mod it replaces, by prototype name) and `data-final-fixes.lua` (sets them, one file or layer at a time), locale, changelog, license file, `README.md`, `MANIFEST.tsv` and in `graphics/` the AE2-derived images; never in the me-network zip (`ae2-textures/README.md`, `docs/LICENSES.md`) |
| `locale/en/me-network.cfg` | English names and texts |
| `tools/devcheck/` | headless test harness: static checks and the runtime tests, on vanilla and with Gregtorio, and the benchmark (`bench`, `docs/PERFORMANCE.md`) (`tools/devcheck/README.md`) |
| `tools/build.py` | builds `dist/me-network_<version>.zip` (without `ae2-textures/`) and `dist/me-network-ae2-textures_<version>.zip` (`ae2-textures/` alone) and fails when a zip breaks the license split (`--portal` for the mod portal, `--install` into the mods folder) |
| `tools/release_textures.py`, `tools/portal_upload.sh` | the release workflow's texture mod version check (is `ae2-textures/` new since the last release tag, and its version unused; a texture-only release under the tag `me-network-ae2-textures-vX.Y.Z`, issue #245) and its mod portal upload of each zip to its own page (issue #243) |
| `.discord/server.yml` | this mod's category on the Discord server (channels, forum tags), applied by `.github/workflows/discord.yml` with the tool of https://github.com/Rykon00/gregtorio-me-network_discord-bot; a pull request that only changes `.discord/` is merged and applied automatically |
| `tools/dev_link.py` | links the repository into the Factorio mods folder, and `ae2-textures/` as `me-network-ae2-textures_<version>` (`--no-textures` leaves it out) |
| `tools/check_syntax.py` | Lua syntax check (`--loaded`: only the files the mod loads) |
| `tools/gen_ae2_sprites.py` | the sprites and icons (GT5-Unofficial casings, screens, circuit boards, memory chips and GUI signs + Pillow) |
| `tools/upstream_icons.py`, `tools/upstream-icon-hashes.tsv` | the hashes of the 17 icons taken over from Gregtorio 0.1.9 until 0.5.2 and the guard that `devcheck check` runs: no file under `graphics/` and not `thumbnail.png` may have one (issue #238) |
| `tools/import_ae2_textures.py`, `tools/ae2_manifest.py` | the only way AE2 graphics get into `ae2-textures/graphics/` (copied from an AE2 checkout, recorded in the manifest), and the guard of the texture mod that `devcheck check` runs |
| `tools/ae2_blocks.py` | makes the texture mod's block pictures, working strips and cube icons from AE2 block faces in `ae2-textures/graphics/` (issue #260, look B of #236), recorded with `--mark-changed`; reads and writes only that folder |
| `tools/scale_ae2_icons.py` | scales the AE2 item icons in `ae2-textures/graphics/` from 16 px to the size of the icon they replace (nearest neighbour, recorded with `--mark-changed`; issue #247), after swapping some colours of the icons that stand in for items AE2-Unofficial lacks (fluid cells #250, interface capacity card #251); reads and writes only that folder |

The names (`fork-me-*.lua`, the storage keys `fork_me_*`, the remote interfaces `gregtorio-me-*`, every prototype
name) are kept from Gregtorio Continued: saves find their entities and items by name, the state of a Gregtorio save is
taken over without conversion, and other mods and the tests call the interfaces by these names.

## With Gregtorio Continued

Gregtorio Continued 0.5.0 and later depends on this mod. A save of an older Gregtorio with an ME network is taken over
when it is loaded with both mods: cells with their items and fluids, patterns, running jobs, maintainers and every
setting (`scripts/fork-me-handover.lua`). Loading this mod next to Gregtorio Continued before 0.5.0 is refused with a
message (both would run the same network).

## Workflow

```bash
python tools/dev_link.py                        # once: the working copy (and the texture mod) is loaded by Factorio
python tools/devcheck/devcheck.py setup         # once (see tools/devcheck/README.md)
python tools/devcheck/devcheck.py all           # before every pull request: RESULT: OK
python tools/devcheck/devcheck.py all --with-gregtorio ../Gregtorio
python tools/devcheck/devcheck.py migrate --from-ref v0.5.0   # a save of an older version (changes to saved state)
python tools/devcheck/devcheck.py bench         # script time, throughput and latencies at 100, 1000 and 5000 endpoints
```

Releases: `CONTRIBUTING.md`.

## License

This repository holds two mods with two licenses (issue #239; every origin is listed in `docs/LICENSES.md`):

| Mod | Folder | License | Contents |
|---|---|---|---|
| **ME Network** (`me-network`) | the repository root, without `ae2-textures/` | **GPLv3** (`LICENSE`), like Gregtorio Continued, where this network was made; its GT5-Unofficial graphics **LGPL-3.0** | the code, the locale, the graphics, the docs and the tools |
| **ME Network - AE2 Textures** (`me-network-ae2-textures`) | `ae2-textures/` | **CC BY-NC-SA 3.0** (`ae2-textures/LICENSE-CC-BY-NC-SA-3.0.txt`), nothing of it GPL | graphics taken from Applied Energistics 2 (© AlgorithmX2 et al., in today's AE2 also © 2020 Ridanisaurus Rid), with their attribution and manifest, and the code that puts them in place: [`ae2-textures/README.md`](ae2-textures/README.md) |

The two are built into two zips (`tools/build.py`), and no zip contains both licenses; each has its own page on the mod
portal ([me-network](https://mods.factorio.com/mod/me-network),
[me-network-ae2-textures](https://mods.factorio.com/mod/me-network-ae2-textures)), and the release workflow uploads
each zip to its own page only, the texture mod's when its version is new (issue #243). **The texture mod is optional:
me-network never needs it** and does not know it; it depends on me-network and replaces sprites when a player installs
both. Gregtorio Continued depends on me-network only.

What CC BY-NC-SA 3.0 means for the texture mod, in short:

- **BY:** every image in it names its author, its source, the license and whether it was changed (`MANIFEST.tsv`).
- **NC:** it may not be used commercially, by us or by anyone who takes it; me-network itself has no NC part.
- **SA:** a changed version of a file in it stays CC BY-NC-SA 3.0.
- Origins are never mixed in one image: the texture mod replaces one file or layer of a sprite at a time.

The graphics of me-network are generated by `tools/gen_ae2_sprites.py` from
[GT5-Unofficial](https://github.com/GTNewHorizons/GT5-Unofficial) by GTNewHorizons (LGPL-3.0: machine casings and
screens; for the upgrade cards its circuit boards, circuits, an SMD chip and the signs of its machine GUI buttons; for
the storage components its circuit boards and memory chips) and shapes drawn with Pillow; the ME cable, the drive's cell
bays, the bus plates and arrows and the ME Cell Workbench are drawn by the script or derived from those sprites, and
`thumbnail.png` is put together from them (a drive and a terminal). The script never reads AE2 graphics. The texture
mod holds no graphics yet: which sprites it replaces by AE2's is decided per asset group (issue #236).

As far as the maintainer knows, me-network uses no graphics of the original Gregtorio and none of Applied Energistics 2. Older
releases (0.1.0 to 0.5.2) contain 17 icons in `graphics/icons/` that were taken over from the original Gregtorio 0.1.9
by Damien Reave and look like Applied Energistics 2's art; issue #238 replaced them by icons the script draws, and
`devcheck.py check` fails on a file with the bytes of one of them (`tools/upstream-icon-hashes.tsv`).

The network follows the design of [Applied Energistics 2](https://github.com/AppliedEnergistics/Applied-Energistics-2)
(code LGPL-3.0, © 2013 - 2020 AlgorithmX2 et al.). Its rules and ideas are written anew here for Factorio; where a
function is a port of AE2's code, a comment at the function names the source. Files with ported code: none so far.
