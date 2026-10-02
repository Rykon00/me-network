# Performance at megabase size (issue #5)

What the ME network costs and moves at size, measured with `python tools/devcheck/devcheck.py bench` (the scenes,
the counting and the profile: `tools/devcheck/README.md`). Every change that touches the runtime adds its numbers
here, before and after.

## Method

* **Scenes.** A synthetic base of N buses and interfaces on one ME network (N = 100, 1000, 5000), built by the
  benchmark mod `tools/devcheck/benchmod/`: import buses on chests (18 % of N), export buses into chests (12 %),
  assembling machines with an export bus on their input and an import bus on their output (10 %), import and export
  buses on tanks (8 % each), ME Interfaces with an item row, fed and emptied by inserters (20 %), ME Interfaces
  importing a tank and exporting into one (10 % each), capacity probes (1 % each: an import and an export bus on a
  warehouse of 800 slots and on a tank of 1 000 000 units, so their target never runs out); storage buses (N / 10, 70 %
  on chests, a fifth of them at priority -10, a tenth at 10 with filters, 30 % on tanks), pattern providers with a
  molecular assembler each (N / 25, 61 recipes, jobs for a quarter of them on quantum CPUs), level maintainers (N / 10,
  stocked), circuit interfaces (N / 50, half of them filtered with 5 keys), drives of 256k cells (N / 50, at least 8) about 70 %
  full (24 raw materials in millions, 855 other item types: every plain item in every quality) and fluid drives.
  At 5000: 19 586 network members, 1000 item cells, 200 fluid cells, 350 storage buses on chests and 150 on tanks,
  37 775 entities. (The first version of this page had a bias in the benchmark's random picks: every circuit
  interface was filtered. The numbers below are from the corrected scenes.)
* **Window.** Ticks 600 to 4200 (60 s). At tick 600 the sources are filled and the sinks emptied, then everything is
  counted; at 4200 it is counted again. The benchmark mod does nothing in between, so `scriptUpdate` of
  `--benchmark-verbose all` is the ME network's time (the two probe ticks and their neighbours are left out).
* **Conservation.** Every item and fluid in the world is counted at both probes (cells, chests, interfaces, machines
  with a craft in progress, inserter hands, job pools, tanks and fluid segments, items on the ground, robots); the
  difference must equal what the machines crafted. Every scene below passed (891 keys in the ME scenes).
* **Latencies** (after the window, ME scene): 20 storage bus chests spread over all of them get an item by script
  (no event, like an inserter): how long until the network counts it; 5 level maintainers lose 10 of their stock:
  how long until each starts a job, and from there until the job hands its first ingredients to a machine.
* **Runs.** Three runs per scene, the median is reported (per value). Headless Factorio 2.0.77 (Steam build) with
  Space Age and quality, on an Intel i7-8700K (6 cores, 12 threads, 3.7 GHz), 32 GB, Windows 10. Running at the same
  time: the Factorio game client (about 0.4 of a core), Spotify, Chrome, Discord, Steam and the Claude desktop app,
  for a while the Raspberry Pi Imager. The worst tick is noisy on this machine (the same scene and code: 74 to 515 ms
  in three runs); the count of ticks over 5 ms and the 99th percentile are steadier.
* **Profile.** One run of the 1000 and 5000 scenes with an instrumented copy of the mod (`bench --profile`): about
  60 functions timed with `LuaProfiler`, inclusive (callees included), single engine calls timed on the scene's
  entities, and the storage API called directly inside the mod. A timed function costs 0.9 to 1.5 µs more per call;
  the totals below include that.
* **Comparisons.** `bench --from-ref <tag>` runs the same scenes against an older version (`git archive`), `--set
  name=value` with other runtime settings (written into `mod-settings.dat` for the run).

## Baseline (0.2.0)

### Script time per tick (ms)

| Scene | N | Average | 99th percentile | Worst tick | Ticks over 5 ms (of 3595) | Lua garbage | Whole update | Save |
|---|---|---|---|---|---|---|---|---|
| ME | 100 | 0.709 | 13.8 | 27.1 | 180 | 0.055 | 0.99 | 1.0 MB |
| ME | 1000 | 0.834 | 16.6 | 46.4 | 215 | 0.066 | 1.19 | 1.3 MB |
| ME | 5000 | **2.675** | 44.8 | **95.0** | 357 | 0.112 | 3.39 | 2.4 MB |
| inserters | 5000 | 0.003 (entities: 0.348) | | | 0 | 0.042 | 0.56 | 1.2 MB |
| robots | 5000 (500 requesters) | 0.002 (entities 0.039, logistics 0.014) | | | 0 | 0.029 | 0.24 | 1.0 MB |

Every tick over 5 ms in the ME scenes is an I/O step (every 15th tick; at 5000 each takes 23 ms on average) or an
autocrafting step (every 20th tick: circuit interfaces, maintainers, jobs, provider rescans; 11 ms at 5000).

### Throughput (per second, over the window)

| | N = 100 | 1000 | 5000 |
|---|---|---|---|
| items, all buses and interfaces | 2082 | 5852 | 11 710 |
| items per endpoint | 20.0 | 5.85 | 2.34 |
| import bus on a chest, per bus | 48.4 | 6.15 | **1.23** |
| export bus into a chest, per bus | 49.5 | 6.14 | 1.23 |
| capacity probe (warehouse), per bus | 59.2 | 6.19 | 1.24 |
| fluid capacity probe (big tank), per bus | 925 | 95 | 19 |
| interface with inserters, per interface (in / out) | 9.0 / 9.0 | 10.0 / 8.2 | 6.9 / 2.5 |
| assembling machine with two buses (out / in) | 0.90 / 1.20 | 1.28 / 1.09 | 0.61 / 0.16 |
| provider machines, crafts | 1.2 | 17.1 | 282 |

* A bus moves 64 items or 1000 fluid units per visit, and all interfaces and buses share 24 visits per 15 ticks: one
  bus gets 59 items/s at N = 100, 6 at 1000 and 1.2 at 5000, exactly as the issue predicted. At 5000 the
  machines of the `pair` slots stand still most of the time, and the inserters of the interfaces wait.
* At N = 100 the sources of the import buses run dry and the sinks fill up within the window (their per-bus numbers
  are below the capacity probes). The fluid interfaces import a whole segment per visit (all 25 000 units of a
  tank at once): their throughput is the volume of the tank, not a rate.
* Native reference (the same counting, full research): **bulk inserter chest to chest 30.0 items/s, fast inserter
  10.0 items/s**, at every N (5000 inserters: 100 000 items/s for 0.35 ms of entity update per tick). Logistic robots
  (requester chests emptied by bulk inserters, providers 26 tiles away, 50 robots per roboport): 6.7 items/s per
  requester with 10 requesters and 50 robots, 0.75 with 500 requesters and 1250 robots (about 0.3 items/s per robot).

### Latencies (s, median / worst of the probes)

| | N = 100 | 1000 | 5000 | Target (5000) |
|---|---|---|---|---|
| storage bus sees a chest change | 0.27 / 0.27 | 1.27 / 2.27 | 5.52 / **10.8** | 2 |
| level maintainer starts a job | 1.02 / 1.68 | 4.35 / 7.68 | 25.0 / **41.7** | 5 |
| the job hands out its first ingredients | 0.33 / 0.33 | 0.33 / 0.67 | 1.00 / 1.33 | |

### Profile

Inclusive milliseconds per tick of the window (µs per call), the largest ones:

| Function | N = 1000 | N = 5000 |
|---|---|---|
| I/O step (`on_nth_tick(15)`) | 0.284 (4267 per step) | **1.508** (22 623 per step) |
| `can_insert_fluid` → `room_for` | 0.115 (671) | **0.899** (3181) |
| interface visit | 0.084 (132) | 0.765 (1195) |
| bus visit | 0.172 (179) | 0.712 (742) |
| `tank_to_network` (interface fluid import) | 0.025 (892) | 0.553 (3979) |
| fluid storage bus `room` (42 calls per tick at 5000) | 0.057 (11) | 0.431 (10) |
| `insert_key` | 0.053 (38) | 0.356 (170) |
| autocrafting step (`on_nth_tick(20)`) | 0.414 (8275 per step) | 0.569 (11 385 per step) |
| circuit interface update (`circuit_step`) | 0.347 (3469) | 0.450 (4501) |
| `network_signals` (the contents list of a circuit interface) | 0.275 (2750) | 0.342 (3422) |
| slow step (`on_nth_tick(60)`: lights, sweep) | 0.025 (1518) | 0.050 (3005) |
| provider rescans (`maintenance`, 8 per step) | 0.039 (776) | 0.036 (722) |

The storage API called directly (µs per call, 1000 / 5000): `count` 0.4 / 0.4; insert 10 and extract 10 of a raw
material 28 / 111; `can_insert` 1000 of it 484 / **2077**; of an item type the network does not hold 245 / 1301;
`can_insert_fluid` 452 / 2197; insert and extract 100 fluid 166 / 840.

Engine calls, µs per call (5000 scene): `get_contents` of a chest of 48 slots 0.3 to 0.9, of 800 slots 20 to 27;
`get_item_count` 0.5 to 0.6; `get_insertable_count` 0.6; `insert` + `remove` 1.3 to 1.5; `find_entities_filtered`
at a position 2 to 3; reading a stack and the checks of `M.storable` 1.9; a fluid box 0.5, its segment id 0.4, the
segment's contents 0.65 (0.64 to 0.74 for a segment of 200 pipes), `insert_fluid` + `remove_fluid` 1.5; writing a
combinator section: 59 µs for 100 signals, 268 for 400, 575 for 700, 935 for 1000 (about 1 µs per signal); a
`remote.call` 2.8. One update of a circuit interface without a filter: 5.4 to 9.5 ms, with 5 filters 1.3 to 1.4 ms.
Building one import bus into the network costs 5.6 ms at 1000 and **28 ms at 5000**, removing it 15 and **90 ms**,
the graph rebuild of `on_configuration_changed` 148 and **807 ms**.

What follows from it:

* **The storage engine is most of the time at 5000, and it is Lua, not engine calls.** `room_for`
  (`can_insert`, `can_insert_fluid`) walks every cell and every storage bus of the network for every call and adds up
  their room: 1350 cells and buses at 5000, 2 to 3 ms per call, linear in the network's size. Of that, 0.43 ms per
  tick are the `room` calls of the 150 fluid storage buses (engine reads of their segments), the rest is Lua
  (`cell_room` per cell). `insert_key` takes the general path as soon as the network has a storage bus or a
  partition (every real network): three passes over every cell of each priority. `extract_key` builds and sorts the
  list of the cells holding the key on every call (a raw material sits in 27 cells at 5000).
* **The engine calls of a visit are cheap** (a bus visit needs 5 to 15 of them, 0.3 to 3 µs each); a visit is
  expensive only through the storage engine. The import bus reads its target slot by slot (`inv[i]` and
  `M.storable` per stack: 2.5 µs per stack; an 800 slot warehouse that is empty at the front costs a scan of every
  empty slot).
* **Spikes come from doing a step's work in one tick**: 24 + 8 + 8 visits in one I/O tick (23 ms at 5000), 8 jobs,
  4 maintainers, 2 circuit interfaces and 8 provider rescans in one autocrafting tick.
* **Circuit interfaces** cost 1.3 to 9.5 ms per update whatever the size: the whole contents list (about 900 types)
  is built with a string parse per key and sorted, also for an interface with 5 filters, and up to 1000 signals are
  written (about 1 µs each in the engine).
* **Building and removing members** recompute the network's totals from every cell (`changed` → `recompute`), and a
  change of the graph has autocrafting rescan every provider; at 5000 a robot placing a blueprint of 20 buses costs
  0.5 s of script time.
* **The slow step** walks every member of the map to find 200 to check (3 ms at 5000) and redraws all lights of
  every drive whose cells changed (every drive that took or gave an item: 10 render objects destroyed and created).
* **Throughput falls with N** because the visits are a fixed number shared by all; the latencies grow the same way.

## Design of the rework (pull request 2), from the profile

In the order of the profile:

1. **Storage engine.** Per network and priority, ordered lists that `insert_key`, `extract_key` and `room_for`
   use instead of walking every cell: the cells partitioned for a key, the cells holding a key (kept sorted, renewed
   only when a cell gains or loses the key), and a pointer to the first cell that can still take a new type (cells
   fill in order; a cell that frees bytes or a type moves the pointer back). Item cells, fluid cells and storage buses
   in separate lists, so an item never looks at a fluid cell. `room_for` stops when it has found the room asked for.
   Adding or removing a member that holds no storage (a bus, an interface, a cable) touches no totals; a drive adds or
   removes its own cells; only a merge or a split recomputes.
2. **Scheduler.** One `on_tick` handler (the mod has none yet), with per-tick lists of due endpoints instead of
   round robin steps: interfaces, import and export buses, storage buses (item and fluid side), level maintainers,
   circuit interfaces, provider rescans and crafting jobs. Each kind has a budget of visits per tick (runtime mod
   settings, defaults from the benchmark), work that does not fit waits for the next tick: no step does all its work
   in one tick any more.
   * **Idle endpoints sleep.** A visit that moved nothing doubles the endpoint's interval up to a limit; a visit that
     moved something keeps it short. An export bus or interface row whose key the network does not hold waits in an
     index by network and key (like `N.on_arrival`) and wakes when the key comes in; a level maintainer wakes when its
     key is taken from the network (and is checked at least every 5 s, for circuit targets and conditions); settings,
     a rotation, a built or removed target wake an endpoint at once. Where the engine has no event (an inserter
     filling a chest, a machine finishing a craft), the back-off has an upper limit: 2 s for storage buses (the
     target), a few seconds for buses.
   * **Throughput that does not fall with the count.** What a visit may move is a rate times the ticks since the
     endpoint's last visit (the rate as a setting, by default the 64 items and 1000 units per 15 ticks a bus had when
     the network was small), limited by what the target holds or takes. A bus visited less often moves more per visit.
   * The import bus reads its target with `get_contents` and moves whole counts of plain items (one storable check per
     item type, cached per prototype like the storage bus does); items with data, damage or durability keep the
     per-stack path.
3. **Autocrafting.** A job start rescans only the providers of the patterns its plan uses, not every provider; a
   graph change rescans only the providers of the networks involved; jobs are stepped one by one over the ticks with
   the same budget of machine operations.
4. **Level maintainers and circuit interfaces.** Maintainers as above (wake by key, budget per tick). A circuit
   interface is written only when its network's contents changed since its last write; one sorted signal list per
   network is shared by its unfiltered interfaces; a filtered interface reads only its keys.
5. **Storage buses on big chests and long segments.** The back-off keeps a chest that does not change from being read
   (`get_contents` of 800 slots: 20 µs); a long fluid segment costs the same as a short one (its contents are one
   engine call).
6. **Render objects and the sweep.** A drive light is recoloured only when its cell's fill state changes and created
   or destroyed only when a cell goes in or out; the sweep walks a list of members in slices instead of the whole map.
7. **Garbage, load time and save size.** No new tables per visit where a reused one does; the scheduler's state is a
   due tick and an interval per endpoint, rebuilt from the records when it is missing (saves of 0.2.0 get it on
   their first tick, without `on_configuration_changed`).

Determinism: every budget is a count of visits or operations, never a measured time; the settings are runtime-global
(the same for every player); profilers exist only in the benchmark's instrumented copy.
