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
  network. Ticks: `on_nth_tick` 60 (terminal step: the network's slow step, drive lights, sweep, the refresh of open
  windows) and one `on_tick` handler in control.lua (issue #5, `scripts/fork-me-schedule.lua`): every interface and
  bus, storage bus (item and fluid side), level maintainer and circuit interface is due at a tick of its own (a queue
  per kind, `rec.due`, a backlog for what does not fit), crafting jobs are stepped one per tick (each at most every 20
  ticks), one provider rescan every 2 ticks. The budgets and the bus speed are runtime-global map settings
  (`settings.lua`, read through `Sched.setting`): visits per tick (interfaces and buses 16, storage buses 8 per side,
  maintainers 4), circuit interface updates per second (10), crafting jobs per tick (1), bus speed (256 items, 4000
  fluid per second, times the ticks since the last visit), idle limits (300 and 120 ticks). Never base anything on
  measured time; a new periodic task gets a queue and a budget, not a step of its own. The command `/me-stats` (`scripts/fork-me-stats.lua`,
  issue #38 part 3) prints the scheduler's counters of the last minute and a network's blocks by state: a new queue is added to its `QUEUES` table and
  to the locale (`[me-stats]`). Blocks waiting for a key wake
  through `N.wait_for` / `N.wait_below` (in `storage`, per network); what is derived from the state only (the lookups
  of the storage engine) is kept outside `storage`. Processing patterns catch their
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
  notice, `all --with-gregtorio <Gregtorio checkout>`. `runtime` also saves the test map at tick 500 through a headless
  server (RCON on 127.0.0.1:27815) and checks that the schedule after the load is the unbroken run's: anything that
  decides when a block is visited must live in `storage`. Both must end with `RESULT: OK`; `check --base-only` checks
  without Space Age; `migrate --from-ref v0.1.0` (the old fluid blocks) or `--from-ref v0.2.0` (every kind of
  unified block, loaded without `on_configuration_changed` while the version number is the same) loads a save of an
  older version with the working copy (for changes to saved state or to prototypes that saves hold). The runtime tests (`tools/devcheck/runtimemod/control.lua`) name a few Gregtorio machines and
  recipes; without Gregtorio its `data.lua` adds stand-ins with the same names and numbers. See
  `tools/devcheck/README.md`. A change to the runtime's cost (the storage engine, the I/O, autocrafting, the step
  budgets) runs `devcheck.py bench` (script time per tick, throughput, latencies and the service quality of every kind of block
  from the scheduler's counters at 100 to 50 000 endpoints and at the maintainer's size (`--sizes base`, issue #51), `--idle`, `--networks`, `--long`, the build burst, the planner
  scene, `--reference` for inserters and robots, `--profile 1000,5000` for where the time goes) and puts its numbers
  before and after into `docs/PERFORMANCE.md`, measured in turns (`bench --check <ref>` fails a number that is worse
  than the measured noise; the busy interval is only reported, since issue #38 a block is visited when the buffer on
  its other side needs it). A chain of long runs goes into a second work folder (`ME_DEVCHECK_WORK`), never into the
  one a quick test uses.
- Every referenced `__me-network__/...` file must exist (headless Factorio does not load graphics, the real game
  crashes on missing files); `devcheck check` lists missing ones and names missing in `locale/en`.
- **Changelog:** every change to the game adds its player-facing lines to the topmost section of `changelog.txt` (the
  next version, no `Date:` line yet). Do not change `version` in `info.json` and do not add a `Date:`; that is the
  release pull request into `upstream/release`.
- **Applied Energistics 2 as a reference:** a checkout of AE2 (https://github.com/AppliedEnergistics/Applied-Energistics-2)
  may lie next to this one (`..\Applied-Energistics-2` on the maintainer's machine). It is read-only: never a worktree,
  never the target of a junction, nothing of it is committed here; if it is missing, say so in your report and go on.
  Its code is LGPL-3.0 (its API MIT), which GPLv3 can take in. Read it when a design question is open (the storage
  lists, the crafting calculation, the tick management); when a function here is a port of AE2's, say so in a comment
  at the function (`ported from Applied Energistics 2, <its path>, LGPL-3.0, (c) AlgorithmX2 et al.`) and name the file
  in the "License" section of `README.md`. Its textures, models and sounds are CC BY-NC-SA 3.0: never copied, traced or
  given to `tools/gen_ae2_sprites.py`. AE2 is Java on Minecraft, so a port is written anew for Lua and the Factorio
  API, tested and measured like any other change; "AE2 does it this way" is no reason by itself, the number is.
- Graphics: `tools/gen_ae2_sprites.py` (`--gt <GT5-Unofficial checkout>` for everything; `--fluids`, `--r1`, `--r2`,
  `--patterns` and the other switches for parts, see its docstring).
- **Issues and the board:** every open issue of this repository and of its sister repository is on the project board
  "Gregtorio Continued Backlog" (https://github.com/users/Rykon00/projects/1). The board only follows the issue state: a
  closed issue moves to Done and is archived a day later; nothing else moves a card. So the pull request that finishes an
  issue has `Closes #N` in its **description** (a number in the title or "Refs" does not close it); with several pull
  requests for one issue the last one closes it and the others say `Refs #N`. Work that is left over goes into a new
  issue, named in the pull request, so the old one can close. When you start on an issue, set its status on the board to
  "In Progress" if `gh project` works for you (`gh project item-list 1 --owner Rykon00`, then `gh project item-edit`; the
  token needs the scope `project`); if it does not, say so in your report and go on. An issue the maintainer has to do or
  test in the game himself is titled `[Task-Ingame]`, not `[Task]`.
- **Close what is handled:** an issue is closed as soon as it is handled, never left for later, because an open issue
  is a card in Todo that says work is waiting. Whoever handles it closes it, with a comment that names the pull request
  or the reason:
  - work done by a pull request into `main`: `Closes #N` in its description (the rule above);
  - a **release**: the release pull request goes into `upstream/release`, where a closing keyword in the description
    closes nothing. Put `Closes #N` for the release issue into the **message of the release commit** (it reaches `main`
    through the workflow's fast-forward), and after the release check that the issue is closed; close it by hand if
    not;
  - a `[Task-Ingame]` issue: when the maintainer says he tested it (in the chat or in the issue), close it; what he
    found goes into new issues first;
  - an issue that was superseded, became pointless or turned out wrong: close it as "not planned" with the reason and
    the issue that replaces it.
  Before you report, list the open issues (`gh issue list`) and close or name every one your work touched.
- **Local sessions on the maintainer's Windows machine:** `C:\00_Repositories\me-network` is linked into the Factorio mods
  folder, so never switch branches or edit files there. Work in **one** worktree next to it
  (`git worktree add ..\me-network-<topic> -b <branch> origin/main`). Do not add more worktrees to compare versions: use
  `git show <ref>:<path>`, `git diff <ref>` or `devcheck.py ... --from-ref <ref>`; a second checkout that cannot be
  avoided is yours to remove as well. A `.devcheck` may hold junctions (to the Steam install's `data` folder, to the
  mod checkouts): `git worktree remove`, `rm -r` and PowerShell's `Remove-Item -Recurse` follow junctions on Windows
  and empty what they point to. So when your pull request is open, clean up in this order and say so in your report:
  remove every junction under `.devcheck` with `cmd /c rmdir <junction>`, then run `git worktree remove <path>` from
  the linked clone. The branch stays on GitHub; follow-up work makes a new worktree from it.
