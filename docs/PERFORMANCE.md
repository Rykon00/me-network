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
  stocked), circuit interfaces (N / 50, half of them filtered), drives of 256k cells (N / 50, at least 8) about 70 %
  full (24 raw materials in millions, 855 other item types: every plain item in every quality) and fluid drives.
  At 5000: 19 586 network members, 1000 item cells, 200 fluid cells, 350 storage buses on chests and 150 on tanks,
  37 775 entities.
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
  time: the Factorio game client (about 0.4 of a core), Spotify, Chrome, Discord, Steam and the Claude desktop app.
  The worst tick is noisy on this machine (one run of the 5000 scene: 74 ms, the two others: 507 and 515 ms, the
  same ticks); the count of ticks over 5 ms and the 99th percentile are steadier.
* **Profile.** One run of the 1000 and 5000 scenes with an instrumented copy of the mod (`bench --profile`): 60
  functions timed with `LuaProfiler`, inclusive (callees included), and single engine calls timed on the scene's
  entities. A timed function costs 0.9 to 1.5 µs more per call; the totals below include that.

## Baseline (0.2.0)

### Script time per tick (ms)

| Scene | N | Average | 99th percentile | Worst tick | Ticks over 5 ms (of 3595) | Lua garbage | Whole update | Save |
|---|---|---|---|---|---|---|---|---|
| ME | 100 | 0.400 | 7.1 | 19.9 | 106 | 0.046 | 0.68 | 1.0 MB |
| ME | 1000 | 0.594 | 10.6 | 23.8 | 172 | 0.058 | 0.93 | 1.3 MB |
| ME | 5000 | **2.691** | 47.8 | **507** | 340 | 0.098 | 3.45 | 2.3 MB |
| inserters | 5000 | 0.002 (entities: 0.326) | | | 0 | 0.041 | 0.54 | 1.2 MB |
| robots | 5000 (500 requesters) | 0.002 (entities 0.039, logistics 0.009) | | | 0 | 0.029 | 0.24 | 1.0 MB |

Every tick over 5 ms in the ME scenes is an I/O step (every 15th tick; at 5000 each takes 25 ms on average, 40 to
75 ms usually), a few are autocrafting steps (every 20th tick).

### Throughput (per second, over the window)

| | N = 100 | 1000 | 5000 |
|---|---|---|---|
| items, all buses and interfaces | 2392 | 6183 | 16 032 |
| items per endpoint | 23.0 | 6.18 | 3.21 |
| import bus on a chest, per bus | 59.1 | 6.15 | **1.23** |
| export bus into a chest, per bus | 59.1 | 6.14 | 1.23 |
| capacity probe (warehouse), per bus | 59.2 | 6.19 | 1.24 |
| fluid capacity probe (big tank), per bus | 925 | 95 | 19 |
| interface with inserters, per interface (in / out) | 9.0 / 9.0 | 9.97 / 9.84 | 8.08 / 5.63 |
| assembling machine with two buses (gears, cable, sticks, pipes; out / in) | 1.50 / 0.75 | 1.80 / 0.75 | 0.61 / 0.09 |
| provider machines, crafts | 1.2 | 17.1 | 282 |

* A bus moves 64 items or 1000 fluid units per visit, and all interfaces and buses share 24 visits per 15 ticks: one
  bus gets 59 items/s at N = 100, 6 at 1000 and 1.2 at 5000, exactly as the issue predicted. At 5000 the
  machines of the `pair` slots stand still most of the time (an import bus empties a gear machine every 52 s).
* The fluid interfaces import a whole segment per visit (all 25 000 units of a tank at once): their throughput is
  the volume of the tank, not a rate (every import tank was empty by the end of the window).
* Native reference (the same counting, full research): **bulk inserter chest to chest 30.0 items/s, fast inserter
  10.0 items/s**, at every N (5000 inserters: 100 000 items/s for 0.33 ms of entity update per tick). Logistic robots
  (requester chests emptied by bulk inserters, providers 26 tiles away, 50 robots per roboport): 6.5 items/s per
  requester with 10 requesters and 50 robots, 0.7 with 500 requesters and 1250 robots (about 0.3 items/s per robot).

### Latencies (s, median / worst of the probes)

| | N = 100 | 1000 | 5000 | Target (5000) |
|---|---|---|---|---|
| storage bus sees a chest change | 0.27 / 0.27 | 1.27 / 2.27 | 5.52 / **10.8** | 2 |
| level maintainer starts a job | 1.02 / 1.68 | 4.35 / 7.68 | 25.0 / **41.7** | 5 |
| the job hands out its first ingredients | 0.33 / 0.33 | 0.33 / 0.67 | 1.00 / 1.33 | |

### Profile

Inclusive milliseconds per tick of the window (calls per tick, µs per call), the largest ones:

| Function | N = 1000 | N = 5000 |
|---|---|---|
| I/O step (`on_nth_tick(15)`) | 0.297 (4458 per step) | **1.706** (25 582 per step) |
| `can_insert_fluid` → `room_for` | 0.108 (628 µs) | **0.923** (3263 µs) |
| interface visit | 0.081 (126 µs) | 0.880 (1375 µs) |
| bus visit | 0.189 (197 µs) | 0.794 (827 µs) |
| `tank_to_network` (interface fluid import) | 0.021 (742 µs) | 0.584 (4207 µs) |
| `insert_key` | 0.076 (75 µs) | 0.491 (343 µs) |
| fluid storage bus `room` (42 calls per tick at 5000) | 0.055 | 0.450 (10.6 µs) |
| autocrafting step (`on_nth_tick(20)`) | 0.211 | 0.289 |
| circuit interface update (`circuit_step`) | 0.147 (1471 µs) | 0.177 (1765 µs) |
| `extract_key` | 0.033 (42 µs) | 0.155 (176 µs) |
| slow step (`on_nth_tick(60)`: lights, sweep) | 0.014 (832 µs) | 0.050 (3005 µs) |
| provider rescans (`maintenance`, 8 per step) | 0.036 (709 µs) | 0.036 (722 µs) |

Engine calls, µs per call (5000 scene): `get_contents` of a chest of 48 slots 0.4, of 800 slots 17 to 23;
`get_item_count` 0.5 to 0.7; `get_insertable_count` 0.6 (3.7 in one run); `insert` + `remove` 1.6;
`find_entities_filtered` at a position 2 to 3.3; reading a stack and the checks of `M.storable` 2.0 to 2.4; a fluid
box 0.4, its segment id 0.3, the segment's contents 0.55 (1.35 for a segment of 200 pipes), `insert_fluid` +
`remove_fluid` 1.4; writing 389 signals into a combinator section 260 to 280; a `remote.call` 2.7 to 2.9.
Building one import bus into the network costs 5.4 ms at 1000 and **28 ms at 5000**, removing it 14 and **93 ms**,
the graph rebuild of `on_configuration_changed` 139 and **813 ms**.

What follows from it:

* **The storage engine is three quarters of the time at 5000, and it is Lua, not engine calls.** `room_for`
  (`can_insert`, `can_insert_fluid`) walks every cell and every storage bus of the network for every call and adds up
  their room: 1150 cells and buses at 5000, 3.3 ms per call, linear in the network's size (628 µs at 1000). Of that,
  0.45 ms per tick are the `room` calls of the 150 fluid storage buses (engine reads of their segments), the rest is
  Lua (`cell_room` per cell). `insert_key` takes the general path as soon as the network has a storage bus or a
  partition (every real network): three passes over every cell of each priority, 343 µs per call. `extract_key`
  builds and sorts the list of the cells holding the key on every call (a raw material sits in 27 cells at 5000).
* **The engine calls of a visit are cheap** (a bus visit needs 5 to 15 of them, 0.3 to 3 µs each); a visit is
  expensive only through the storage engine. The import bus reads its target slot by slot (`inv[i]` and
  `M.storable` per stack: 2.5 µs per stack, an 800 slot warehouse that is empty at the front costs a scan of every
  empty slot).
* **Spikes come from doing a step's work in one tick**: 24 + 8 + 8 visits in one I/O tick (25 ms at 5000), 8 jobs,
  4 maintainers, 2 circuit interfaces and 8 provider rescans in one autocrafting tick.
* **Circuit interfaces** cost 1.5 to 1.8 ms per update whatever the size: the whole contents list (855 + 24 types)
  is built with a string parse per key, sorted, and up to 1000 signals are written (0.27 ms in the engine).
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
