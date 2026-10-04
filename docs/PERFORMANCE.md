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

(Written before the rework; what was built and why it differs in places: `docs/ME-REWORK.md`, "Scheduler and
performance at size". The results are in the next section.)

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

## After the rework (0.3.0, pull request 2)

The same scenes and harness, the median of three runs (`bench --reference --profile 1000,5000`), the default
settings. What was built is described in `docs/ME-REWORK.md`, "Scheduler and performance at size".

### Script time per tick (ms), before → after

| N | Average | 99th percentile | Worst tick | Ticks over 5 ms (of 3595) | Lua garbage | Whole update |
|---|---|---|---|---|---|---|
| 100 | 0.709 → **0.227** | 13.8 → 1.93 | 27.1 → 6.8 | 180 → 2 | 0.055 → 0.039 | 0.99 → 0.44 |
| 1000 | 0.834 → **0.779** | 16.6 → 2.51 | 46.4 → 12.1 | 215 → 12 | 0.066 → 0.072 | 1.19 → 1.18 |
| 5000 | 2.675 → **1.262** | 44.8 → 3.28 | 95.0 → 27.4 | 357 → 10 | 0.112 → 0.082 | 3.39 → 2.09 |

The save of the 5000 scene stays 2.4 MB. At 1000 and 5000 the time now buys far more work: every bus of these
scenes has work for the whole window, and all of them get it (below), where 0.2.0 let them wait.

### Throughput (per second), before → after

| | N = 100 | 1000 | 5000 |
|---|---|---|---|
| items, all buses and interfaces | 2082 → 3332 | 5852 → 33 247 | 11 710 → **166 741** |
| items per endpoint | 20.0 → 32.0 | 5.85 → 33.2 | 2.34 → **33.4** |
| capacity probe, import bus (warehouse) | 59.2 → **260** | 6.19 → **267** | 1.24 → **261** |
| capacity probe, export bus (warehouse) | 59.2 → **256** | 6.19 → **256** | 1.24 → **261** |
| fluid capacity probes (big tank), import / export | 925 → 4056 / 4000 | 95 → 4183 / 4009 | 19 → **4075 / 4076** |
| import bus on a steel chest (runs dry: 4800 to 9600 items in 60 s) | 48.4 → 62.2 | 6.15 → 79.1 | 1.23 → 79.6 |
| assembling machine with two buses (out / in) | 0.90 / 1.20 → 0.90 / 1.20 | 1.28 / 1.09 → 0.97 / 1.12 | 0.61 / 0.16 → **0.99 / 1.12** |
| interface with inserters (in / out) | 9.0 / 9.0 → 9.0 / 9.0 | 10.0 / 8.2 → 10.0 / 10.0 | 6.9 / 2.5 → **10.1 / 10.0** |
| provider machines, crafts | 1.2 → 1.2 | 17.1 → 17.3 | 282 → 327 |

* A bus moves its speed, 256 items or 4000 fluid units per second, at every size (the capacity probes): 8.5 bulk
  inserters (30 items/s) or 26 fast inserters (10 items/s) chest to chest, 3.4 pumps (1200 units/s). The steel chests
  of the import and export buses run dry or full within the window at every size, so their numbers and the totals
  are what the chests held, not what the buses could move.
* Machines and the inserters at the interfaces run at their own speed again at 5000 (the assembling machines make
  gears and cable at their rate: 0.99 items/s out, 1.12 in; the fast inserters at the interfaces 10 items/s).
* Native cost for comparison: 5000 inserters move 100 000 items/s for 0.34 ms of entity update per tick (3.4 ns of
  game time per item); the ME scene moves 166 741 items/s (and 1.2 million fluid units/s, 327 crafts/s) for 1.26 ms of
  script time per tick (7.6 ns per item, the fluid and the crafting included). Robots: about 0.3 items/s per robot
  at 26 tiles; one bus does what about 850 such robots do.

### Latencies (s, median / worst), before → after, and the targets

| | N = 100 | 1000 | 5000 | Target (5000) |
|---|---|---|---|---|
| storage bus sees a chest change | 0.27 / 0.27 → 0.02 / 0.02 | 1.27 / 2.27 → 1.07 / 1.15 | 5.52 / 10.8 → **1.33 / 1.72** | 2: met |
| level maintainer starts a job | 1.02 / 1.68 → 0.07 / 0.10 | 4.35 / 7.68 → 0.08 / 0.15 | 25.0 / 41.7 → **0.08 / 0.22** | 5: met |
| the job hands out its first ingredients | 0.33 / 0.33 → 0.02 / 0.02 | 0.33 / 0.67 → 0.13 / 0.15 | 1.00 / 1.33 → 0.07 / 0.87 | |

### Targets of issue #5 (at 5000 buses and interfaces, 500 storage buses, 200 providers, 500 maintainers)

| Target | Before | After | |
|---|---|---|---|
| script time under 2 ms per tick on average | 2.675 | **1.262** | met |
| no tick over 5 ms | 357 ticks, worst 95 ms | 10 ticks, worst 27 ms (99th percentile 3.3 ms) | **not met** (see below) |
| a busy bus moves what a native setup moves, at 100 and at 5000 | 59 → 1.2 items/s | 256 items/s at every size | met (8.5 bulk inserters) |
| storage bus change seen within 2 s | 10.8 s | 1.72 s | met |
| maintainer reacts within 5 s | 41.7 s | 0.22 s | met |

**The worst tick.** What is left over 5 ms, from the worst ticks of single runs at 5000:

* Ticks in which a circuit interface without a filter writes its section: about 900 signals cost about 0.9 ms in the
  engine (linear, about 1 µs per signal: 59 µs for 100, 935 µs for 1000; measured), plus the Lua around it; on a tick
  that is busy anyway this passes 5 ms. A section cannot be changed in part cheaply (setting single slots of a section
  of 900 signals cost milliseconds per changed slot: tried and dropped). The levers are the player's: filters on the
  interfaces, or fewer updates per second (the setting).
* Steps of the Lua garbage collector of 10 to 25 ms in a few ticks per minute (the `luaGarbageIncremental` column of
  the same ticks; 0.2.0 had them too). The rework makes less garbage per moved item (no closures per insert, one
  section per list for unfiltered interfaces, plain items by count) but the engine's own tables (`get_contents`)
  remain.
* The machine: the worst tick of the same code varies between runs by a factor of two to four (other programs, the
  game client). The 99th percentile (3.3 ms) is the steadier number.

So the 5 ms limit is met by 99.7 % of the ticks but not by every tick; in Lua the remaining spikes are the engine
writing a big combinator section and the garbage collector.

### Profile after (5000, inclusive ms per tick, µs per call)

| Function | Before | After |
|---|---|---|
| interfaces and buses (I/O step / `io.M.on_tick`) | 1.508 | 1.065 (16 visits per tick, 62 µs per visit) |
| `room_for` / `can_insert_fluid` | 0.899 (3181) | 0.028 (48; the profile adds about 1 µs per timed call inside) |
| `insert_key` | 0.356 (170) | 0.216 (28, 7.7 calls per tick instead of 2.1) |
| autocrafting with maintainers and circuit interfaces | 0.569 | 0.421 |
| circuit interface update | 0.450 (4501) | 0.128 (850) |

The storage API called directly at 5000 (µs per call, before → after): insert 10 and extract 10 of a raw material
111 → 14; `can_insert` 1000 of it 2077 → 4.7; of an item type the network does not hold 1301 → 3.1; extract into a
chest and back 127 → 19; `can_insert_fluid` 2197 → 18; insert and extract 100 fluid 840 → 43 (the fluid storage
buses' segments, AE2's order: storage buses are emptied first). A circuit interface update without a filter 5.4 to
9.5 ms → 0.9 ms, with 5 filters 1.3 → 0.15 ms. Building one bus into the network 27.6 ms → **0.19 ms**, removing one
90 ms → **0.47 ms**. The graph rebuild of `on_configuration_changed` is unchanged (0.73 to 0.81 s at 5000; once per
mod update).

### Settings

The defaults (`settings.lua`) come from these runs: 16 interface and bus visits per tick already give every bus of
the 5000 scene its full speed through the catch-up (a sweep of 16, 24 and 40 visits per tick moved the same 209 000
items/s in the scene before the random picks were corrected, at 1.4, 2.9 and 2.6 ms per tick on a noisy machine);
more visits only shorten the reaction of busy blocks. The storage bus idle limit of 120 ticks is the latency target.
10 circuit interface updates per second keep the circuit cost at about 0.2 ms per tick with 50 unfiltered
interfaces.

## Upgrade cards and priorities (0.3.0, issue #17)

The scenes have no cards and no interface priority, so this measures what the new code costs a network that does not
use it: the filter checks of the storage engine (blacklist, fuzzy list, overflow destruction), the storage bus visit
and the interface visit with its priority check. The target: no storage call slower.

### Script time per tick (ms, median of three runs, `bench`), before → after

| N | Average | 99th percentile | Worst tick | Ticks over 5 ms | Whole update |
|---|---|---|---|---|---|
| 100 | 0.240 → 0.225 | 2.04 → 1.89 | 7.5 → 6.4 | 4 → 3 | 0.463 → 0.443 |
| 1000 | 0.807 → 0.799 | 2.65 → 2.58 | 11.7 → 10.5 | 14 → 12 | 1.207 → 1.200 |
| 5000 | 1.333 → 1.315 | 3.52 → 3.46 | 25.1 → 24.8 | 10 → 11 | 2.144 → 2.130 |

Throughput (items and fluid per second, per kind of endpoint), the latencies and the conservation check (891 keys, no
difference) are the same to the last digit: 166 741 items and 1 219 697 fluid units per second at 5000, a storage bus
sees a chest change after 1.33 / 1.72 s (median / worst), a level maintainer reacts after 0.08 / 0.22 s.

### Profile: before and after in turns

The first profile after the change showed a storage bus visit about 20 % slower: each item type of a chest went
through two function calls (`shown`, `N.accepts`). A bus or cell without a blacklist or fuzzy list now checks its
whitelist inline, and a bus without filters checks nothing per item (the three-run numbers above are from before that
fix). The machine's noise between two runs of the same code is up to 50 % here, so the profile ran three times for
each version, alternating (`bench --sizes 1000,5000 --runs 1 --profile 1000,5000`, and the same with
`--from-ref c00cad8`); the medians, µs per call:

| | 1000 before | 1000 after | 5000 before | 5000 after |
|---|---|---|---|---|
| storage API: count | 0.52 | 0.40 | 1.41 | 0.40 |
| storage API: insert 10 + extract 10 | 13.2 | 12.3 | 19.2 | 19.8 |
| storage API: can_insert 1000 | 3.19 | 2.96 | 7.20 | 7.26 |
| storage API: can_insert 1000, a new item type | 4.42 | 4.13 | 4.90 | 3.47 |
| storage API: extract_to a chest + insert back | 21.1 | 18.0 | 28.6 | 25.9 |
| storage API: can_insert_fluid 1000 | 3.09 | 3.67 | 26.8 | 26.3 |
| storage API: insert_fluid + extract_fluid 100 | 19.2 | 15.2 | 69.1 | 62.6 |
| `insert_key` (in the scene) | 23.6 | 18.1 | 46.9 | 38.1 |
| `extract_key` | 19.1 | 14.0 | 21.8 | 18.7 |
| `room_for` | 12.2 | 9.9 | 57.5 | 49.0 |
| storage bus visit | 26.6 | 17.7 | 21.4 | 19.2 |
| interface visit (`interface_step`) | 110 | 87 | 119 | 111 |

Every difference is inside the spread of the runs (the single runs are in the pull request); none of the storage
calls got slower. What the code adds per call for a network without cards is a few field reads (`cell.void`,
`cell.deny`, `c.fuzzy`, `ins.void`) and, per interface visit, one look whether any interface of the map has a priority.

### With the Cell Workbench and the cards on cells (pull request 2)

The same scenes (no cell has cards) after both pull requests, `bench` (median of three runs), against the numbers
before issue #17:

| N | Average | 99th percentile | Worst tick | Ticks over 5 ms | Whole update |
|---|---|---|---|---|---|
| 100 | 0.240 → 0.214 | 2.04 → 1.88 | 7.5 → 7.0 | 4 → 3 | 0.463 → 0.411 |
| 1000 | 0.807 → 0.728 | 2.65 → 2.51 | 11.7 → 11.7 | 14 → 13 | 1.207 → 1.044 |
| 5000 | 1.333 → 1.228 | 3.52 → 3.46 | 25.1 → 23.8 | 10 → 18 | 2.144 → 1.964 |

Throughput, latencies and the conservation check are again the same to the last digit. Three more profile pairs in
turns (old version, new version): the storage API calls at 5000 in µs, before → after (medians): count 1.29 → 0.40,
insert + extract 29.7 → 14.9, `can_insert` 7.4 → 6.5, `can_insert` of a new type 4.7 → 3.1, `extract_to` 29.5 → 20.7,
`insert_fluid` + `extract_fluid` 64.3 → 44.3; at 1000 every call within ±1 µs. The spread of single runs of the same
code is larger than any of these differences (the worst tick count of 18 at 5000 is one noisy run of three); the cell
code adds one field read (`cell.eq`) to `cell_room`.

## Crafting CPUs as multiblocks (0.3.0, issue #6)

What issue #6 adds to the runtime: the groups of crafting blocks are kept up to date in the build and removal events
only (`add_block`, `remove_block`, `settle_group`); a job's step asks its group for the network (`group_network`, one
table read and `N.active_of`) instead of its CPU entity; `M.start` and `assign_cpus` pick a CPU (`pick_cpu`,
`groups_in`), which runs only when a job starts or is paused. Nothing runs per tick for a CPU, a block or a monitor.

The scene's CPUs are multiblocks since this issue (`benchmod`: one CPU per job and eight spare, each a row of sixteen
256k crafting storages and three co-processors, as fast as the Quantum CPU; the biggest job of 5000 items needs about
2 MiB); `--from-ref` of an older version builds Quantum CPUs as before. Runs in turns with the version before
(`bench --sizes 1000,5000 --runs 3`, and the same with `--from-ref origin/main`), on a machine with a second Factorio
running (its noise: the same code gave 1.0 and 0.9 ms at 1000, 1.4 and 3.0 ms at 5000 in two series).

### Script time per tick (ms, median of three runs), before → after

| N | Average | 99th percentile | Worst tick | Ticks over 5 ms | Whole update |
|---|---|---|---|---|---|
| 1000 | 0.940 / 0.833 → 0.875 / 0.825 | 3.43 / 2.71 → 3.01 / 2.72 | 14.4 / 12.2 → 12.5 / 15.6 | 14 / 14 → 15 / 10 | 1.369 / 1.253 → 1.297 / 1.244 |
| 5000 | 1.360 / 1.361 → 1.408 / 1.327 | 3.56 / 3.57 → 4.01 / 3.40 | 27.5 / 24.3 → 27.8 / 27.0 | 13 / 15 → 13 / 10 | 2.208 / 2.205 → 2.252 / 2.143 |

(two series each; the first "after" series had two spare CPUs, the second eight.) Throughput, the provider crafts
(17.3 and 327.1 per second) and the conservation check are the same to the last digit; the latencies too (storage
bus 1.07 / 1.33 s, level maintainer 0.08 s, first hand-over of a job 0.13 / 0.07 s). With only two spare CPUs the
maintainer probes waited up to 5 s (their retry) for a free CPU: a job no longer queues behind a busy CPU, so a scene
needs as many free CPUs as jobs it wants to start at once, which the old Quantum CPUs gave with their spare slots.

### Profile (5000, one run, `--profile 5000`)

| Function | Calls in the window (3600 ticks) | Time |
|---|---|---|
| `add_block`, `remove_block`, `settle_group`, `groups_in`, `pick_cpu`, `plan_bytes` | 0 | 0 |
| `group_network` (a job's network, from `job_network`) | 3600 | 9.8 ms (2.7 µs per call) |
| `assign_cpus` | 180 | 2.9 ms |
| `job_step` | 3600 | 582 ms (the jobs' own work, unchanged code path) |

The multiblock costs no script time while nothing is built or removed.

## Round two (issue #38): the extended benchmark and the 0.3.0 baseline

Issue #38 asks for half the script time, no spikes and 50 000 endpoints. Its first pull request changes no runtime
behaviour: it extends the benchmark so that the problem is visible, measures 0.3.0 with it and ranks the levers from
the profile. The only runtime change is the scheduler's counters (below), which cost nothing measurable.

### Method, what is new

* **Sizes.** 20 000 and 50 000 buses and interfaces next to 100, 1000 and 5000 (where the machine stops: below).
* **Service quality.** The scheduler (`scripts/fork-me-schedule.lua`) counts, per queue (interfaces and buses,
  storage buses, fluid storage buses, level maintainers, circuit interfaces; the crafting jobs through their own
  sample): the visits, the units that came due, the backlog left at the end of each tick, and the ticks between two
  visits of the same unit, kept apart by what the visit found: the unit moved all it was allowed to (a **busy**
  block: the budget, not the block, decided when it was served), it moved something, or it found nothing to do
  (**idle**). The record keeps its last visit tick (`rec.vis`); the counters live in the module, never in `storage`
  (they describe one peer's run and decide nothing; the benchmark reads them through the remote
  `gregtorio-me-io.sched_stats`, the in-game diagnostic of part 3 will). The benchmark resets them at the first probe
  and reports them at the second, samples the backlogs every 5 s, and looks at the scene's machines at the second
  probe: working, waiting for ingredients or output full, and the crafts they made against what their speed allowed
  in the window (utilisation). A `pair` machine of the scene (an assembling machine fed and emptied by two buses)
  that is not at 100 % waits for its buses.
* **Idle network** (`bench --idle`): the same scene with every source empty, every sink blocked (a chest full of
  another item, a full tank), no recipe on the machines and no job. What the network costs when nothing moves.
* **Several networks** (`--networks 10,100`): the same blocks on K networks of size / K, one below the other (the
  latency probes and the 855 item types of the variety only in the first; the others hold the raw materials and
  the maintainers' items).
* **Long run** (`--long 30`): one run of 30 minutes at 5000, reported per 5 minutes: script time, the garbage
  collector, the mod's Lua heap (`collectgarbage("count")` through the remote `lua_memory`) and the backlogs.
* **Build burst** (`--burst 1000`, part of every run, after the latency probes): 1000 ME blocks connected to the
  network (364 cables from the spine to a new row, 159 import buses and 159 storage buses on chests, 318 interfaces)
  built in one tick with `raise_built` and removed in one tick with `raise_destroy`, then 1000 plain chests the same
  way (the mod's handlers run for every entity of the map): the time of each loop and the script time of its tick.
* **Open windows**: headless Factorio has no player, so the GUI itself cannot be measured. The profile times what
  each window computes at a refresh instead: the terminal's sorted contents list (`entries`, every 60 ticks while it
  is open, also for the search), the crafting preview, the jobs and cells tabs, and the data of every block window.
* **Planner** (`--planner`, `--with-gregtorio DIR` for GregTech): every enabled recipe of the game with at most 9
  inputs and 6 outputs, whole products without a chance, not recycling and not items with data, as a processing
  pattern (the planner does not care which machine would make it), kept when it is on a shortest path of its main
  product (loops out, alternatives of equal depth in); the raw materials (nothing makes them) in cells. The planner
  is timed on the five deepest items (five plans of 1 and of 100), then one job of 10 is started per target.
* **Load**: the wall time from `Loading map` to the scripts' checksums, and the script time of the first ticks after
  the load, when the queues and the storage engine's lookups come up.
* **Engine's share** (`--engine-share`): the scene with every entity of the mod destroyed after the build and
  nothing registered (the chests, tanks, machines, inserters and power stay). Its whole update, against the normal
  scene's whole update minus its script time, is what the ME entities cost the engine (the interfaces' four hidden
  side tanks each, the controller's power, the lamps of the maintainers and crafting blocks).
* **In turns** (`bench --check <ref>`): the maps of the working copy and of a reference are made once and run
  alternately (ref, working copy, ref, ...), three rounds; every number is compared by its median and fails when the
  working copy is worse by more than the measured noise (the larger spread of the two versions, at least 2 % of the
  reference). Throughput that differs at all is reported: the scheduling changed.
* **Map guard**: every map the harness creates is removed before `--create` and must exist afterwards. Before, a
  Factorio that failed to start would have left the previous run's map for the next step to load: a `migrate` run
  could pass on a stale map. (`setup` also finds the Steam install on Windows now and copies its `bin/` next to a
  config folder of its own, so the harness runs while the game is open.)


### Baseline of 0.3.0 (with the counters), script time per tick (ms)

Three runs per scene, the median per value; the window of 60 s from tick 600. Headless Factorio 2.0.77 (the Steam build's binary) on the i7-8700K of the earlier sections; running at the same time: the Factorio game client, Chrome, Spotify, Steam and the Claude desktop app, so the numbers sit 5 to 10 % above the quieter runs of 0.3.0 (1.26 to 1.33 ms at 5000 then, 1.30 to 1.41 here); the planner scene with Gregtorio and the engine-share rerun at 100 to 5000 ran at the same time in two work folders. The variants are the ME scene with the same blocks: idle (nothing to move), split over 10 and 100 networks, and without the ME entities (the engine's share).

| Scene | N | Average | 99th percentile | Worst tick | Ticks over 5 ms | Lua garbage (avg / worst step) | Whole update | Engine (whole minus script) | Save |
|---|---|---|---|---|---|---|---|---|---|
| ME | 100 | 0.235 | 1.94 | 7.2 | 3 | 0.038 / 2.9 | 0.46 | 0.22 | 1.0 MB |
| idle | 100 | 0.182 | 1.88 | 7.2 | 6 | 0.035 / 1.7 | 0.39 | 0.21 | 1.0 MB |
| 10 networks | 100 | 0.416 | 1.88 | 8.3 | 2 | 0.044 / 4.0 | 0.67 | 0.25 | 1.1 MB |
| 100 networks | 100 | 0.857 | 2.10 | 20.7 | 2 | 0.073 / 29.7 | 1.32 | 0.47 | 2.0 MB |
| without ME entities | 100 | 0.005 | 0.02 | 0.2 | 0 | 0.030 / 0.4 | 0.21 | 0.20 | 1.0 MB |
| ME | 1000 | 0.815 | 2.63 | 12.0 | 11 | 0.081 / 15.4 | 1.25 | 0.44 | 1.3 MB |
| idle | 1000 | 0.371 | 2.30 | 8.1 | 7 | 0.053 / 7.5 | 0.63 | 0.26 | 1.3 MB |
| 10 networks | 1000 | 0.846 | 2.37 | 15.2 | 10 | 0.088 / 18.3 | 1.29 | 0.44 | 1.3 MB |
| 100 networks | 1000 | 0.957 | 2.30 | 22.9 | 2 | 0.083 / 35.7 | 1.46 | 0.50 | 2.1 MB |
| without ME entities | 1000 | 0.005 | 0.02 | 0.2 | 0 | 0.031 / 0.9 | 0.25 | 0.24 | 1.0 MB |
| ME | 5000 | 1.394 | 3.64 | 26.6 | 12 | 0.092 / 39.6 | 2.28 | 0.88 | 2.5 MB |
| idle | 5000 | 0.846 | 2.80 | 23.4 | 8 | 0.094 / 37.8 | 1.38 | 0.54 | 2.4 MB |
| 10 networks | 5000 | 1.019 | 2.74 | 28.9 | 4 | 0.079 / 53.5 | 1.84 | 0.82 | 2.6 MB |
| 100 networks | 5000 | 1.092 | 2.56 | 39.3 | 3 | 0.074 / 33.9 | 1.93 | 0.84 | 3.2 MB |
| without ME entities | 5000 | 0.007 | 0.02 | 0.2 | 0 | 0.041 / 4.9 | 0.53 | 0.52 | 1.3 MB |
| ME | 20000 | 2.948 | 6.45 | 60.8 | 143 | 0.067 / 37.3 | 5.31 | 2.37 | 6.7 MB |
| idle | 20000 | 1.382 | 4.20 | 45.1 | 14 | 0.079 / 84.8 | 2.67 | 1.29 | 6.5 MB |
| without ME entities | 20000 | 0.013 | 0.03 | 0.4 | 0 | 0.057 / 27.3 | 2.13 | 2.11 | 2.1 MB |
| ME | 50000 | 6.782 | 14.97 | 91.5 | 2667 | 0.092 / 69.3 | 11.79 | 5.01 | 15.1 MB |
| 30-minute run | 5000 | 1.074 | 3.06 | 45.1 | 299 | 0.086 / 44.5 | 1.75 | 0.68 | 2.5 MB |

Native reference scenes (the same counting):

| Scene | N | Script avg | Entity update | Logistics | Whole update | Items/s |
|---|---|---|---|---|---|---|
| inserters | 100 | 0.005 | 0.012 | 0.000 | 0.20 | 2000 |
| inserters | 1000 | 0.005 | 0.064 | 0.000 | 0.25 | 20000 |
| inserters | 5000 | 0.007 | 0.352 | 0.000 | 0.59 | 100000 |
| robots | 100 | 0.005 | 0.013 | 0.014 | 0.21 | 66 |
| robots | 1000 | 0.005 | 0.015 | 0.034 | 0.24 | 70 |
| robots | 5000 | 0.005 | 0.045 | 0.015 | 0.26 | 374 |

### Throughput (per second over the window)

| Scene | N | Items/s | per endpoint | Fluid/s | Provider crafts/s | Capacity probe import / export (items/s per bus) | Fluid probe import / export | Interface in / out | Pair machine out / in | Conservation |
|---|---|---|---|---|---|---|---|---|---|---|
| ME | 100 | 3332 | 32.04 | 32778 | 1.2 | 259.55 / 256.00 | 4055.56 / 4000.00 | 9.00 / 9.00 | 0.90 / 1.20 | 891 keys, 0 differ |
| idle | 100 | 0 | 0.00 | 93 | 0.0 | 0.00 / 0.00 | 0.00 / 0.00 | 0.00 / 0.00 | 0.00 / 0.00 | 891 keys, 0 differ |
| 10 networks | 100 | 11731 | 61.74 | 178794 | 12.3 | 257.46 / 166.55 | 4023.06 / 4000.00 | 9.50 / 6.50 | 0.82 / 1.20 | 891 keys, 0 differ |
| 100 networks | 100 | 95511 | 56.18 | 1801684 | 120.5 | 261.87 / 144.17 | 4097.97 / 3994.63 | 9.89 / 5.61 | 0.90 / 1.12 | 891 keys, 0 differ |
| without ME entities | 100 | 18 | 0.17 | 0 | 0.0 | 0.00 / 0.00 | 0.00 / 0.00 | 0.44 / 0.44 | 0.00 / 0.00 | 28 keys, 0 differ |
| ME | 1000 | 33247 | 33.25 | 248585 | 17.3 | 267.35 / 256.23 | 4183.44 / 4008.56 | 10.00 / 10.01 | 0.97 / 1.12 | 891 keys, 0 differ |
| idle | 1000 | 0 | 0.00 | 1310 | 0.0 | 0.00 / 0.00 | 0.00 / 0.00 | 0.00 / 0.00 | 0.00 / 0.00 | 891 keys, 0 differ |
| 10 networks | 1000 | 34431 | 33.11 | 330662 | 12.3 | 267.47 / 176.32 | 4189.56 / 4010.33 | 8.57 / 7.75 | 0.96 / 1.13 | 891 keys, 0 differ |
| 100 networks | 1000 | 108020 | 56.85 | 1793640 | 120.5 | 258.18 / 153.68 | 4038.88 / 4013.94 | 9.94 / 6.56 | 0.96 / 1.07 | 891 keys, 0 differ |
| without ME entities | 1000 | 89 | 0.09 | 0 | 0.0 | 0.00 / 0.00 | 0.00 / 0.00 | 0.22 / 0.22 | 0.00 / 0.00 | 31 keys, 0 differ |
| ME | 5000 | 166741 | 33.35 | 1219697 | 327.1 | 260.69 / 260.58 | 4075.33 / 4076.42 | 10.10 / 10.00 | 0.99 / 1.12 | 891 keys, 0 differ |
| idle | 5000 | 0 | 0.00 | 28969 | 0.0 | 0.00 / 0.00 | 0.00 / 0.00 | 0.00 / 0.00 | 0.00 / 0.00 | 891 keys, 0 differ |
| 10 networks | 5000 | 167644 | 33.53 | 1219974 | 66.5 | 261.29 / 260.43 | 4084.58 / 4077.71 | 10.10 / 10.00 | 0.97 / 1.13 | 891 keys, 0 differ |
| 100 networks | 5000 | 202663 | 36.85 | 2431347 | 120.5 | 260.08 / 147.24 | 4064.28 / 4071.03 | 8.11 / 6.53 | 0.97 / 1.16 | 891 keys, 0 differ |
| without ME entities | 5000 | 337 | 0.07 | 0 | 0.0 | 0.00 / 0.00 | 0.00 / 0.00 | 0.17 / 0.17 | 0.00 / 0.00 | 31 keys, 0 differ |
| ME | 20000 | 528686 | 26.43 | 3379369 | 1501.5 | 102.10 / 102.74 | 1595.33 / 1605.33 | 9.47 / 5.02 | 1.38 / 0.89 | 891 keys, 0 differ |
| idle | 20000 | 3513 | 0.18 | 63739 | 0.0 | 0.00 / 0.00 | 0.00 / 0.00 | 0.00 / 0.88 | 0.00 / 0.00 | 891 keys, 0 differ |
| without ME entities | 20000 | 1029 | 0.05 | 0 | 0.0 | 0.00 / 0.00 | 0.00 / 0.00 | 0.13 / 0.13 | 0.00 / 0.00 | 31 keys, 0 differ |
| ME | 50000 | 343455 | 6.87 | 4449231 | 1733.0 | 15.62 / 15.62 | 242.80 / 242.80 | 7.12 / 2.36 | 0.71 / 0.23 | 891 keys, 0 differ |
| 30-minute run | 5000 | 14735 | 2.95 | 83333 | 89.7 | 44.44 / 43.11 | 555.56 / 555.56 | 2.72 / 2.62 | 0.96 / 1.12 | 891 keys, 0 differ |

### Latencies (s, median / worst of the probes)

| Scene | N | Storage bus sees a chest change | Level maintainer starts a job | The job hands out its first ingredients |
|---|---|---|---|---|
| ME | 100 | 0.02 / 0.02 | 0.07 / 0.10 | 0.02 / 0.02 |
| idle | 100 | 0.02 / 0.02 | 0.07 / 0.10 | 0.02 / 0.02 |
| 10 networks | 100 | 0.00 / 0.00 | 0.05 / 0.08 | 0.17 / 0.17 |
| 100 networks | 100 | 1.02 / 1.02 | 0.05 / 0.08 | 1.67 / 1.67 |
| ME | 1000 | 1.07 / 1.15 | 0.08 / 0.15 | 0.13 / 0.15 |
| idle | 1000 | 1.07 / 1.15 | 0.08 / 0.15 | 0.02 / 0.02 |
| 10 networks | 1000 | 1.02 / 1.02 | 0.07 / 0.12 | 0.15 / 0.17 |
| 100 networks | 1000 | 0.00 / 0.00 | 0.05 / 0.08 | 1.67 / 1.67 |
| ME | 5000 | 1.33 / 1.72 | 0.08 / 0.22 | 0.07 / 0.87 |
| idle | 5000 | 1.33 / 1.72 | 0.08 / 0.22 | 0.02 / 0.02 |
| 10 networks | 5000 | 1.03 / 1.08 | 0.08 / 0.18 | 0.80 / 0.82 |
| 100 networks | 5000 | 1.02 / 1.02 | 0.05 / 0.08 | 1.67 / 1.67 |
| ME | 20000 | 1.33 / 2.82 | 3.38 / 60.00 | 0.60 / 60.00 |
| idle | 20000 | 1.33 / 2.82 | 3.38 / 60.00 | 0.02 / 60.00 |
| ME | 50000 | 3.32 / 7.02 | 10.22 / 15.88 | 3.58 / 7.75 |

### Service quality (the scheduler's counters over the window)

Visits and units due per tick, the backlog at the end of a tick (average / longest), and the ticks between two visits of the same block by what the visit found: a busy block moved all it was allowed to (for jobs: the ticks between two steps of a job), an idle one found nothing.

| Scene | N | Queue | Visits per tick | Due per tick | Backlog avg / max | Busy block: interval median / 99th / worst (s), n | Idle block: interval median / 99th / worst (s), n |
|---|---|---|---|---|---|---|---|
| ME | 100 | io | 2.52 | 2.52 | 0.0 / 0 | 0.25 / 0.25 / 1.08, 4016 | 1.08 / 1.08 / 1.08, 2718 |
| ME | 100 | storage_bus | 0.23 | 0.23 | 0.0 / 0 | - / - / -, 0 | 0.50 / 0.50 / 0.50, 840 |
| ME | 100 | fluid_storage_bus | 0.10 | 0.10 | 0.0 / 0 | - / - / -, 0 | 0.50 / 0.50 / 0.50, 360 |
| ME | 100 | maintainer | 0.05 | 0.05 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 180 |
| ME | 100 | circuit | 0.05 | 0.05 | 0.2 / 1 | 0.10 / 1.10 / 1.10, 110 | - / - / -, 0 |
| ME | 100 | jobs | - | - | 0.0 / 0 | 0.33 / 0.33 / 0.33, 180 | - / - / -, 0 |
| idle | 100 | io | 1.62 | 1.62 | 0.0 / 0 | 1.00 / 1.00 / 1.00, 600 | 1.08 / 1.08 / 1.08, 5244 |
| idle | 100 | storage_bus | 0.23 | 0.23 | 0.0 / 0 | - / - / -, 0 | 0.50 / 0.50 / 0.50, 840 |
| idle | 100 | fluid_storage_bus | 0.10 | 0.10 | 0.0 / 0 | - / - / -, 0 | 0.50 / 0.50 / 0.50, 360 |
| idle | 100 | maintainer | 0.05 | 0.05 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 180 |
| idle | 100 | circuit | 0.05 | 0.05 | 0.2 / 1 | 0.10 / 1.10 / 1.10, 110 | - / - / -, 0 |
| 10 networks | 100 | io | 7.05 | 7.12 | 0.0 / 0 | 0.25 / 0.25 / 1.98, 20348 | 1.98 / 1.98 / 1.98, 1833 |
| 10 networks | 100 | storage_bus | 0.33 | 0.33 | 0.0 / 0 | - / - / -, 0 | 0.50 / 0.50 / 0.50, 1200 |
| 10 networks | 100 | fluid_storage_bus | 0.33 | 0.33 | 0.0 / 0 | - / - / -, 0 | 0.50 / 0.50 / 0.50, 1200 |
| 10 networks | 100 | maintainer | 0.08 | 0.08 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 300 |
| 10 networks | 100 | circuit | 0.17 | 0.17 | 9.8 / 10 | - / - / -, 0 | - / - / -, 0 |
| 10 networks | 100 | jobs | - | - | 0.0 / 0 | 0.33 / 0.33 / 0.33, 1800 | - / - / -, 0 |
| 100 networks | 100 | io | 16.00 | 16.06 | 899.9 / 1191 | 1.17 / 4.72 / 5.23, 38369 | 5.85 / 6.15 / 6.22, 5958 |
| 100 networks | 100 | storage_bus | 0.83 | 0.83 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 3000 |
| 100 networks | 100 | fluid_storage_bus | 0.83 | 0.83 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 3000 |
| 100 networks | 100 | maintainer | 0.68 | 0.68 | 0.0 / 0 | 5.00 / 5.00 / 5.00, 12 | 5.00 / 5.00 / 5.00, 2448 |
| 100 networks | 100 | circuit | 0.17 | 0.17 | 99.8 / 100 | - / - / -, 0 | - / - / -, 0 |
| 100 networks | 100 | jobs | - | - | 0.0 / 0 | 1.67 / 1.67 / 1.67, 3600 | - / - / -, 0 |
| ME | 1000 | io | 13.65 | 13.58 | 102.3 / 527 | 1.00 / 1.53 / 5.53, 22398 | 5.00 / 5.25 / 5.53, 6569 |
| ME | 1000 | storage_bus | 0.58 | 0.58 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 2100 |
| ME | 1000 | fluid_storage_bus | 0.53 | 0.53 | 0.0 / 0 | - / - / -, 0 | 0.95 / 0.95 / 0.95, 1890 |
| ME | 1000 | maintainer | 0.35 | 0.35 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 1260 |
| ME | 1000 | circuit | 0.17 | 0.17 | 11.0 / 11 | 2.10 / 2.10 / 2.10, 540 | - / - / -, 0 |
| ME | 1000 | jobs | - | - | 0.0 / 0 | 0.33 / 0.33 / 0.33, 1800 | - / - / -, 0 |
| idle | 1000 | io | 4.67 | 4.67 | 0.0 / 0 | 1.00 / 1.00 / 1.00, 6000 | 5.00 / 5.00 / 5.00, 10800 |
| idle | 1000 | storage_bus | 0.58 | 0.58 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 2100 |
| idle | 1000 | fluid_storage_bus | 0.53 | 0.53 | 0.0 / 0 | - / - / -, 0 | 0.95 / 0.95 / 0.95, 1890 |
| idle | 1000 | maintainer | 0.35 | 0.35 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 1260 |
| idle | 1000 | circuit | 0.17 | 0.17 | 11.0 / 11 | 2.10 / 2.10 / 2.10, 540 | - / - / -, 0 |
| 10 networks | 1000 | io | 15.04 | 15.24 | 113.3 / 553 | 0.28 / 0.83 / 5.53, 24849 | 5.00 / 5.35 / 5.57, 7787 |
| 10 networks | 1000 | storage_bus | 0.58 | 0.58 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 2100 |
| 10 networks | 1000 | fluid_storage_bus | 0.53 | 0.53 | 0.0 / 0 | - / - / -, 0 | 0.95 / 0.95 / 0.95, 1890 |
| 10 networks | 1000 | maintainer | 0.35 | 0.35 | 0.0 / 0 | 5.00 / 5.00 / 5.00, 108 | 5.00 / 5.00 / 5.00, 1152 |
| 10 networks | 1000 | circuit | 0.17 | 0.17 | 16.6 / 18 | 1.70 / 1.80 / 2.70, 200 | - / - / -, 0 |
| 10 networks | 1000 | jobs | - | - | 0.0 / 0 | 0.33 / 0.33 / 0.33, 1800 | - / - / -, 0 |
| 100 networks | 1000 | io | 16.00 | 16.06 | 1045.4 / 1422 | 1.30 / 5.02 / 5.47, 35664 | 5.97 / 6.35 / 6.40, 6547 |
| 100 networks | 1000 | storage_bus | 0.83 | 0.83 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 3000 |
| 100 networks | 1000 | fluid_storage_bus | 0.83 | 0.83 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 3000 |
| 100 networks | 1000 | maintainer | 0.68 | 0.68 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 2460 |
| 100 networks | 1000 | circuit | 0.17 | 0.17 | 99.8 / 100 | - / - / -, 0 | - / - / -, 0 |
| 100 networks | 1000 | jobs | - | - | 0.0 / 0 | 1.67 / 1.67 / 1.67, 3600 | - / - / -, 0 |
| ME | 5000 | io | 16.00 | 15.47 | 3370.3 / 4669 | 4.47 / 5.58 / 9.27, 29109 | 6.43 / 8.65 / 9.27, 19721 |
| ME | 5000 | storage_bus | 2.92 | 2.92 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 10500 |
| ME | 5000 | fluid_storage_bus | 1.25 | 1.25 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 4500 |
| ME | 5000 | maintainer | 1.68 | 1.68 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 6060 |
| ME | 5000 | circuit | 0.17 | 0.17 | 91.0 / 91 | 10.10 / 10.10 / 10.10, 540 | - / - / -, 0 |
| ME | 5000 | jobs | - | - | 0.0 / 0 | 0.82 / 0.83 / 1.63, 3600 | - / - / -, 0 |
| idle | 5000 | io | 16.00 | 15.16 | 1523.5 / 4136 | 2.18 / 5.05 / 5.22, 12355 | 6.15 / 6.25 / 6.27, 45245 |
| idle | 5000 | storage_bus | 2.92 | 2.92 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 10500 |
| idle | 5000 | fluid_storage_bus | 1.25 | 1.25 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 4500 |
| idle | 5000 | maintainer | 1.68 | 1.68 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 6060 |
| idle | 5000 | circuit | 0.17 | 0.17 | 91.0 / 91 | 10.10 / 10.10 / 10.10, 540 | - / - / -, 0 |
| 10 networks | 5000 | io | 16.00 | 15.47 | 3386.6 / 4670 | 4.48 / 5.57 / 9.15, 29363 | 6.43 / 8.63 / 9.27, 19428 |
| 10 networks | 5000 | storage_bus | 2.92 | 2.92 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 10500 |
| 10 networks | 5000 | fluid_storage_bus | 1.25 | 1.25 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 4500 |
| 10 networks | 5000 | maintainer | 1.68 | 1.68 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 6060 |
| 10 networks | 5000 | circuit | 0.17 | 0.17 | 93.5 / 97 | 10.20 / 10.60 / 10.60, 381 | - / - / -, 0 |
| 10 networks | 5000 | jobs | - | - | 0.0 / 0 | 0.83 / 0.83 / 0.83, 3600 | - / - / -, 0 |
| 100 networks | 5000 | io | 16.00 | 15.52 | 3980.2 / 5165 | 5.15 / 6.08 / 9.52, 23501 | 6.93 / 9.23 / 9.58, 19686 |
| 100 networks | 5000 | storage_bus | 3.33 | 3.33 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 12000 |
| 100 networks | 5000 | fluid_storage_bus | 1.67 | 1.67 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 6000 |
| 100 networks | 5000 | maintainer | 1.68 | 1.68 | 0.0 / 0 | 5.00 / 5.00 / 5.00, 12 | 5.00 / 5.00 / 5.00, 6048 |
| 100 networks | 5000 | circuit | 0.17 | 0.17 | 99.8 / 100 | - / - / -, 0 | - / - / -, 0 |
| 100 networks | 5000 | jobs | - | - | 0.0 / 0 | 1.67 / 1.67 / 1.67, 3600 | - / - / -, 0 |
| ME | 0 | jobs | - | - | 0.0 / 0 | 0.33 / 0.33 / 0.33, 179 | - / - / -, 0 |
| ME | 20000 | io | 16.00 | 15.78 | 19434.8 / 19705 | 20.88 / 21.15 / 21.15, 27503 | 20.78 / 21.23 / 21.60, 12316 |
| ME | 20000 | storage_bus | 8.00 | 8.00 | 440.0 / 440 | - / - / -, 0 | 2.92 / 2.92 / 2.92, 28800 |
| ME | 20000 | fluid_storage_bus | 5.00 | 5.00 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 18000 |
| ME | 20000 | maintainer | 4.00 | 4.00 | 805.0 / 805 | 8.35 / 8.37 / 8.37, 122 | 8.35 / 8.37 / 8.37, 14278 |
| ME | 20000 | circuit | 0.17 | 0.17 | 391.0 / 391 | 40.10 / 40.10 / 40.10, 270 | - / - / -, 0 |
| ME | 20000 | jobs | - | - | 0.0 / 0 | 3.30 / 3.33 / 6.63, 3600 | - / - / -, 0 |
| idle | 20000 | io | 16.00 | 15.19 | 18720.2 / 19559 | 20.48 / 20.75 / 20.83, 4853 | 20.87 / 21.07 / 21.07, 42347 |
| idle | 20000 | storage_bus | 8.00 | 8.00 | 440.0 / 440 | - / - / -, 0 | 2.92 / 2.92 / 2.92, 28800 |
| idle | 20000 | fluid_storage_bus | 5.00 | 5.00 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 18000 |
| idle | 20000 | maintainer | 4.00 | 4.00 | 805.0 / 805 | 8.35 / 8.37 / 8.37, 122 | 8.35 / 8.37 / 8.37, 14278 |
| idle | 20000 | circuit | 0.17 | 0.17 | 391.0 / 391 | 40.10 / 40.10 / 40.10, 270 | - / - / -, 0 |
| ME | 50000 | io | 16.00 | 15.97 | 49669.2 / 49719 | 52.13 / 52.27 / 52.27, 12142 | 52.13 / 52.13 / 52.13, 899 |
| ME | 50000 | storage_bus | 8.00 | 8.00 | 2540.0 / 2540 | - / - / -, 0 | 7.28 / 7.30 / 7.30, 28800 |
| ME | 50000 | fluid_storage_bus | 8.00 | 8.00 | 540.0 / 540 | - / - / -, 0 | 3.12 / 3.13 / 3.13, 28800 |
| ME | 50000 | maintainer | 4.00 | 4.00 | 3805.0 / 3805 | - / - / -, 0 | 20.85 / 20.87 / 20.87, 11795 |
| ME | 50000 | circuit | 0.17 | 0.17 | 991.0 / 991 | - / - / -, 0 | - / - / -, 0 |
| ME | 50000 | jobs | - | - | 0.0 / 0 | 8.30 / 8.33 / 16.63, 3400 | - / - / -, 0 |
| 30-minute run | 5000 | io | 16.00 | 15.97 | 1601.4 / 4669 | 2.52 / 5.32 / 9.27, 590807 | 6.17 / 7.73 / 9.27, 1113142 |
| 30-minute run | 5000 | storage_bus | 2.92 | 2.92 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 315000 |
| 30-minute run | 5000 | fluid_storage_bus | 1.25 | 1.25 | 0.0 / 0 | - / - / -, 0 | 2.00 / 2.00 / 2.00, 135000 |
| 30-minute run | 5000 | maintainer | 1.68 | 1.68 | 0.0 / 0 | - / - / -, 0 | 5.00 / 5.00 / 5.00, 181800 |
| 30-minute run | 5000 | circuit | 0.17 | 0.17 | 91.0 / 91 | 10.10 / 10.10 / 10.10, 16200 | - / - / -, 0 |
| 30-minute run | 5000 | jobs | - | - | 0.0 / 0 | 0.50 / 0.83 / 1.63, 108000 | - / - / -, 0 |

The io backlog sampled every 5 s over the window:

* ME 100, io backlog every 5 s: 0 0 0 0 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 18397 kB
* idle 100, io backlog every 5 s: 0 0 0 0 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 19144 kB
* 10 networks 100, io backlog every 5 s: 0 0 0 0 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 24298 kB
* 100 networks 100, io backlog every 5 s: 1184 1062 1032 867 786 770 843 950 877 801 773; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 99411 kB
* without ME entities 100, io backlog every 5 s: 0 0 0 0 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 1553 kB
* ME 1000, io backlog every 5 s: 508 336 126 57 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 37295 kB
* idle 1000, io backlog every 5 s: 0 0 0 0 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 38682 kB
* 10 networks 1000, io backlog every 5 s: 513 357 173 74 37 37 39 12 3 8 7; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 37692 kB
* 100 networks 1000, io backlog every 5 s: 1330 1296 1068 1006 1026 1006 1055 979 898 866 936; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 102862 kB
* without ME entities 1000, io backlog every 5 s: 0 0 0 0 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 1553 kB
* ME 5000, io backlog every 5 s: 4475 4255 4159 3808 3286 3287 3137 2483 2837 2625 2499; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 110554 kB
* idle 5000, io backlog every 5 s: 3296 1653 1721 1103 1112 1148 1123 1131 1110 1128 1125; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 69412 kB
* 10 networks 5000, io backlog every 5 s: 4474 4277 4167 3837 3308 3325 3136 2506 2876 2597 2507; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 156122 kB
* 100 networks 5000, io backlog every 5 s: 4956 4794 4661 4256 4183 4013 3200 3794 3207 3273 3368; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 156387 kB
* without ME entities 5000, io backlog every 5 s: 0 0 0 0 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 1553 kB
* ME 20000, io backlog every 5 s: 19704 19703 19585 19579 19565 19565 19313 19320 19284 19299 18947; storage bus: 440 440 440 440 440 440 440 440 440 440 440; mod heap 293311 kB
* idle 20000, io backlog every 5 s: 19559 19558 19134 19134 19134 19134 18296 18296 18296 18296 17877; storage bus: 440 440 440 440 440 440 440 440 440 440 440; mod heap 326693 kB
* without ME entities 20000, io backlog every 5 s: 0 0 0 0 0 0 0 0 0 0 0; storage bus: 0 0 0 0 0 0 0 0 0 0 0; mod heap 1553 kB
* ME 50000, io backlog every 5 s: 49704 49704 49704 49703 49711 49710 49713 49712 49586 49583 49564; storage bus: 2540 2540 2540 2540 2540 2540 2540 2540 2540 2540 2540; mod heap 1118843 kB
* 30-minute run 5000, io backlog every 5 s: 4475 4255 4159 3808 3286 3287 3137 2483 2837 2625 2499 2663 2604 2592 2609 2613 2625 2589 2602 2623 2593 2602 2622 2600 2593 2617 2607 2591 2611 2622 2588 2595 2598 2555 2570 2595 2566 2572 2586 2568 2567 2581 2570 2558 2579 2583 2560 2576 2597 2533 2485 2460 2433 2410 2424 2408 2415 2420 2414 2415 2409 2416 2409 2384 2382 2354 2359 2366 2356 2358 2372 2362 2365 2362 2359 2368 2363 2358 2361 2357 2363 2360 2361 2365 2362 2359 2361 2360 2362 2364 2224 2033 2075 2004 1967 1985 1800 1486 1464 1493 1489 1479 1476 1479 1480 1474 1476 1475 1480 1476 1476 1479 1474 1477 1477 1476 1474 1476 1476 1475 1475 1477 1478 1479 1471 1458 1449 1447 1448 1449 1449 1450 1448 1444 1449 1456 1453 1450 1447 1449 1450 1453 1450 1450 1450 1450 1450 1448 1451 1452 1454 1453 1452 1452 1450 1452 1453 1454 1452 1451 1451 1451 1452 1452 1452 1451 1453 1452 1452 1453 1451 1452 1451 1451 1451 1451 1450 1453 1452 1448 1445 1451 1451 1449 1452 1450 1448 1446 1450 1449 1455 1453 1334 1083 1096 1121 1123 1121 1124 1120 1125 1120 1120 1122 1120 1122 1121 1120 1120 1120 1120 1124 1124 1120 1121 1120 1121 1125 1120 1120 1120 1122 1120 1120 1120 1120 1120 1120 1121 1123 1120 1120 1121 1123 1121 1124 1120 1125 1120 1120 1122 1120 1122 1121 1120 1120 1120 1120 1124 1124 1120 1121 1120 1121 1125 1120 1120 1120 1122 1120 1120 1120 1120 1120 1120 1121 1123 1120 1120 1121 1123 1121 1124 1120 1125 1120 1120 1122 1120 1122 1121 1120 1120 1120 1120 1124 1124 1120 1121 1120 1121 1125 1120 1120 1120 1122 1120 1120 1120 1120 1120 1120 1121 1123 1120 1120 1121 1123 1121 1124 1120 1125 1120 1120 1122 1120 1122 1121 1120 1120 1120 1120 1124 1124 1120 1121 1120 1121 1125 1120 1120 1120 1122 1120 1120 1120 1120 1120 1120 1121 1123 1120 1120 1121 1123 1121 1124 1120 1125 1120 1120 1122 1120 1122 1121 1120 1120 1120 1120; storage bus: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0; mod heap 79718 kB

### The scene's machines at the end of the window

| Scene | N | Machines | Working | Waiting for ingredients | Output full | Other | Crafts of possible | Utilisation |
|---|---|---|---|---|---|---|---|---|
| ME | 100 | pair (5) | 5 | 0 | 0 | 0 | 450 / 450 | 100.0 % |
| ME | 100 | provider (9) | 0 | 8 | 1 | 0 | 74 / 895 | 8.3 % |
| idle | 100 | pair (5) | 0 | 0 | 0 | 5 | 0 / 0 | 0.0 % |
| idle | 100 | provider (9) | 0 | 9 | 0 | 0 | 0 / 895 | 0.0 % |
| 10 networks | 100 | pair (10) | 10 | 0 | 0 | 0 | 900 / 900 | 100.0 % |
| 10 networks | 100 | provider (25) | 0 | 15 | 10 | 0 | 740 / 1680 | 44.0 % |
| 100 networks | 100 | pair (100) | 100 | 0 | 0 | 0 | 9000 / 9000 | 100.0 % |
| 100 networks | 100 | provider (205) | 100 | 105 | 0 | 0 | 7232 / 9780 | 73.9 % |
| without ME entities | 100 | pair (5) | 0 | 5 | 0 | 0 | 0 / 450 | 0.0 % |
| ME | 1000 | pair (50) | 50 | 0 | 0 | 0 | 4500 / 4500 | 100.0 % |
| ME | 1000 | provider (45) | 9 | 35 | 1 | 0 | 1039 / 5932 | 17.5 % |
| idle | 1000 | pair (50) | 0 | 0 | 0 | 50 | 0 / 0 | 0.0 % |
| idle | 1000 | provider (45) | 0 | 45 | 0 | 0 | 0 / 5932 | 0.0 % |
| 10 networks | 1000 | pair (50) | 50 | 0 | 0 | 0 | 4500 / 4500 | 100.0 % |
| 10 networks | 1000 | provider (45) | 0 | 35 | 10 | 0 | 740 / 1930 | 38.3 % |
| 100 networks | 1000 | pair (100) | 100 | 0 | 0 | 0 | 9000 / 9000 | 100.0 % |
| 100 networks | 1000 | provider (205) | 100 | 105 | 0 | 0 | 7232 / 9780 | 73.9 % |
| without ME entities | 1000 | pair (50) | 0 | 50 | 0 | 0 | 0 / 4500 | 0.0 % |
| ME | 5000 | pair (250) | 250 | 0 | 0 | 0 | 22500 / 22500 | 100.0 % |
| ME | 5000 | provider (205) | 155 | 44 | 6 | 0 | 19625 / 29935 | 65.6 % |
| idle | 5000 | pair (250) | 0 | 0 | 0 | 250 | 0 / 0 | 0.0 % |
| idle | 5000 | provider (205) | 0 | 205 | 0 | 0 | 0 / 29935 | 0.0 % |
| 10 networks | 5000 | pair (250) | 250 | 0 | 0 | 0 | 22500 / 22500 | 100.0 % |
| 10 networks | 5000 | provider (205) | 49 | 155 | 1 | 0 | 3987 / 22405 | 17.8 % |
| 100 networks | 5000 | pair (200) | 200 | 0 | 0 | 0 | 18000 / 18000 | 100.0 % |
| 100 networks | 5000 | provider (205) | 100 | 105 | 0 | 0 | 7232 / 9780 | 73.9 % |
| without ME entities | 5000 | pair (250) | 0 | 250 | 0 | 0 | 0 / 22500 | 0.0 % |
| ME | 20000 | pair (1000) | 1000 | 0 | 0 | 0 | 85512 / 90000 | 95.0 % |
| ME | 20000 | provider (805) | 682 | 70 | 53 | 0 | 90087 / 119842 | 75.2 % |
| idle | 20000 | pair (1000) | 0 | 0 | 0 | 1000 | 0 / 0 | 0.0 % |
| idle | 20000 | provider (805) | 0 | 805 | 0 | 0 | 0 / 119842 | 0.0 % |
| without ME entities | 20000 | pair (1000) | 0 | 1000 | 0 | 0 | 0 / 90000 | 0.0 % |
| ME | 50000 | pair (2500) | 1667 | 0 | 833 | 0 | 125135 / 225000 | 55.6 % |
| ME | 50000 | provider (2005) | 797 | 170 | 1038 | 0 | 103982 / 298808 | 34.8 % |
| 30-minute run | 5000 | pair (250) | 250 | 0 | 0 | 0 | 675000 / 675000 | 100.0 % |
| 30-minute run | 5000 | provider (205) | 79 | 126 | 0 | 0 | 161508 / 898050 | 18.0 % |

### Load and the build burst

| Scene | N | Load (s) | First tick (ms) | Second tick | First second (sum / max) | Burst build 1000 (ms: loop / tick) | Burst remove 1000 | Plain build 1000 | Plain remove 1000 |
|---|---|---|---|---|---|---|---|---|---|
| ME | 100 | 0.14 | 1.4 | 1.8 | 26.5 / 3.4 | 70.8 / 71.0 | 390.4 / 390.9 | 22.3 / 22.4 | 7.5 / 7.6 |
| idle | 100 | 0.14 | 1.4 | 1.7 | 18.7 / 3.4 | 75.4 / 75.5 | 398.8 / 399.3 | 23.6 / 23.7 | 7.4 / 7.5 |
| 10 networks | 100 | 0.14 | 4.1 | 1.7 | 34.9 / 4.1 | 69.9 / 70.1 | 423.9 / 424.5 | 23.0 / 23.2 | 7.6 / 7.7 |
| 100 networks | 100 | 0.16 | 26.9 | 3.1 | 95.3 / 26.9 | 71.1 / 72.0 | 456.1 / 456.9 | 25.9 / 26.6 | 7.6 / 8.6 |
| without ME entities | 100 | 0.14 | 0.0 | 0.0 | 0.3 / 0.0 | - | - | - | - |
| ME | 1000 | 0.14 | 6.7 | 3.6 | 86.8 / 6.7 | 69.7 / 70.4 | 477.5 / 478.2 | 22.4 / 23.1 | 7.5 / 8.0 |
| idle | 1000 | 0.15 | 6.5 | 3.6 | 66.7 / 6.5 | 87.6 / 87.9 | 459.9 / 460.6 | 21.4 / 21.7 | 7.5 / 7.8 |
| 10 networks | 1000 | 0.15 | 9.5 | 2.5 | 83.9 / 9.5 | 72.7 / 73.2 | 495.4 / 496.5 | 23.3 / 24.3 | 7.7 / 8.6 |
| 100 networks | 1000 | 0.18 | 27.5 | 3.6 | 100.2 / 27.5 | 70.8 / 71.6 | 483.1 / 484.0 | 25.8 / 26.8 | 8.4 / 9.2 |
| without ME entities | 1000 | 0.14 | 0.0 | 0.0 | 0.3 / 0.0 | - | - | - | - |
| ME | 5000 | 0.27 | 36.8 | 18.7 | 197.1 / 36.8 | 75.5 / 76.4 | 847.5 / 848.7 | 22.4 / 23.4 | 7.7 / 8.8 |
| idle | 5000 | 0.26 | 35.2 | 17.2 | 133.4 / 35.2 | 72.4 / 73.1 | 734.0 / 734.5 | 25.2 / 25.8 | 7.7 / 8.2 |
| 10 networks | 5000 | 0.26 | 39.4 | 8.4 | 136.0 / 39.4 | 103.7 / 105.2 | 591.3 / 592.2 | 22.6 / 24.0 | 7.1 / 8.0 |
| 100 networks | 5000 | 0.28 | 50.6 | 8.9 | 142.6 / 50.6 | 73.5 / 74.4 | 625.2 / 625.9 | 24.7 / 25.6 | 7.6 / 8.5 |
| without ME entities | 5000 | 0.18 | 0.1 | 0.0 | 0.5 / 0.1 | - | - | - | - |
| ME | 20000 | 1.50 | 161.9 | 93.0 | 577.8 / 161.9 | 80.3 / 81.4 | 1625.5 / 1629.6 | 23.6 / 26.2 | 7.9 / 9.5 |
| idle | 20000 | 1.55 | 149.1 | 83.3 | 365.0 / 149.1 | 87.9 / 89.0 | 1679.9 / 1680.8 | 24.4 / 25.4 | 7.9 / 8.8 |
| without ME entities | 20000 | 0.30 | 0.0 | 0.0 | 0.8 / 0.0 | - | - | - | - |
| ME | 50000 | 12.57 | 477.7 | 255.3 | 1460.0 / 477.7 | 264.7 / 273.1 | 3775.8 / 3782.3 | 23.0 / 27.3 | 7.3 / 14.2 |

### Planner

#### Vanilla with Space Age

* 321 recipes on shortest paths of 345 usable: 243 processing patterns at chests, 78 crafting patterns at machines ({'assembling-machine-2': 3, 'biochamber': 1, 'chemical-plant': 2, 'cryogenic-plant': 1, 'electromagnetic-plant': 1, 'foundry': 2, 'oil-refinery': 1}), 0 with fluids but no machine; 305 items, 18 raw items and 5 raw fluids in stock, deepest tree 9, items per depth [15, 24, 47, 58, 64, 59, 24, 7, 7]; patterns the network cannot use: {'total': 8, 'fluid-box': 8}. Script time of the window with the jobs: 0.276 ms average, 1.38 99th percentile.

| Target (depth) | Amount | Result | Steps | Runs | Missing | Plan (ms) |
|---|---|---|---|---|---|---|
| fusion-generator (9) | 1 | missing | 26 | 8234 | 3 fluid/molten-iron,stone,fluid/fluoroketone-cold | 20.5 |
| fusion-generator (9) | 100 | missing | 26 | 822527 | 3 fluid/molten-iron,stone,fluid/fluoroketone-cold | 15.7 |
| fusion-reactor (9) | 1 | missing | 26 | 40201 | 3 fluid/molten-iron,stone,fluid/fluoroketone-cold | 20.8 |
| fusion-reactor (9) | 100 | missing | 26 | 4019484 | 6 fluid/molten-iron,stone,copper-ore,fluid/ammoniacal-solution | 22.3 |
| fusion-reactor-equipment (9) | 1 | missing | 35 | 69640 | 3 fluid/molten-iron,stone,fluid/fluoroketone-cold | 17.2 |
| fusion-reactor-equipment (9) | 100 | missing | 35 | 6962187 | 8 fluid/molten-iron,stone,copper-ore,fluid/ammoniacal-solution | 23.0 |
| me-256k-crafting-storage (9) | 1 | ok | 20 | 5038 | 0  | 21.1 |
| me-256k-crafting-storage (9) | 100 | ok | 20 | 503588 | 0  | 16.3 |
| promethium-science-pack (9) | 1 | missing | 26 | 171 | 1 stone | 21.6 |
| promethium-science-pack (9) | 100 | missing | 26 | 1498 | 1 stone | 21.6 |

| Job start of 10 | Result | ms |
|---|---|---|
| fusion-generator | missing | 8.9 |
| fusion-reactor | missing | 13.6 |
| fusion-reactor-equipment | missing | 11.5 |
| me-256k-crafting-storage | ok | 6.7 |
| promethium-science-pack | missing | 32.2 |
#### Gregtorio Continued (GregTech recipes)

* 2650 recipes on shortest paths of 3673 usable: 1658 processing patterns at chests, 992 crafting patterns at machines ({'assembling-machine-2': 1, 'bacterial-vat': 1, 'biochamber': 1, 'chemical-plant': 1, 'coke-oven': 1, 'component-assembly-line': 1, 'cryogenic-plant': 1, 'dimensionally-transcendent-plasma-forge': 2, 'electromagnetic-plant': 1, 'ev-alloy-blast-smelter': 4, 'ev-assembling-machine': 9, 'ev-autoclave': 1, 'ev-canning-machine': 3, 'ev-centrifuge': 1, 'ev-chemical-bath': 1, 'ev-circuit-assembler': 3, 'ev-cracker': 1, 'ev-cutting-machine': 2, 'ev-electric-blast-furnace': 6, 'ev-electrolyzer': 3, 'ev-extractor': 6, 'ev-fluid-solidifier': 14, 'ev-greenhouse': 1, 'ev-large-chemical-reactor': 14, 'ev-laser-engraver': 1, 'ev-microverse-projector': 1, 'ev-mixer': 2, 'ev-ore-washer': 3, 'ev-pyrolyse-oven': 1, 'ev-short-distillation-tower': 1, 'ev-tall-distillation-tower': 1, 'ev-vacuum-freezer': 2, 'fluid-nuclear-reactor': 1, 'foundry': 1, 'fusion-reactor-mk1': 1, 'fusion-reactor-mk2': 2, 'fusion-reactor-mk3': 1, 'fusion-reactor-mk4': 1, 'fusion-reactor-mk5': 1, 'godforge': 1, 'iv-alloy-blast-smelter': 1, 'iv-assembling-machine': 1, 'iv-chemical-bath': 1, 'iv-circuit-assembler': 1, 'iv-cutting-machine': 1, 'iv-electric-blast-furnace': 2, 'iv-extractor': 3, 'iv-fluid-shaper': 1, 'iv-industrial-mixer': 1, 'iv-large-chemical-reactor': 2, 'iv-short-distillation-tower': 1, 'iv-tall-distillation-tower': 1, 'large-heat-exchanger': 1, 'luv-assembling-machine': 1, 'luv-assembly-line': 1, 'luv-autoclave': 1, 'luv-circuit-assembly-line': 1, 'luv-electric-blast-furnace': 2, 'luv-extractor': 1, 'luv-fluid-solidifier': 1, 'luv-large-chemical-reactor': 1, 'luv-laser-engraver': 1, 'luv-mixer': 1, 'max-alloy-blast-smelter': 1, 'max-assembling-machine': 2, 'max-electric-blast-furnace': 6, 'max-extractor': 2, 'max-fluid-solidifier': 8, 'max-laser-engraver': 1, 'max-mixer': 1, 'max-vacuum-freezer': 1, 'neutron-activator': 1, 'oil-refinery': 1, 'water-purification-plant': 1, 'zpm-assembly-line': 2}), 0 with fluids but no machine; 2363 items, 193 raw items and 33 raw fluids in stock, deepest tree 32, items per depth [104, 62, 57, 96, 70, 105, 103, 113, 129, 137, 136, 150, 97, 40, 37, 85, 91, 55, 40, 54, 94, 87, 83, 74, 105, 54, 36, 32, 18, 12, 5, 2]; patterns the network cannot use: {'total': 41, 'stack': 18, 'fluid-box': 23}. Script time of the window with the jobs: 0.259 ms average, 1.13 99th percentile.

| Target (depth) | Amount | Result | Steps | Runs | Missing | Plan (ms) |
|---|---|---|---|---|---|---|
| eternity-wire (32) | 1 | missing | 3 | 3 | 2 eternity-dust,fluid/argon | 480.6 |
| eternity-wire (32) | 100 | missing | 3 | 150 | 2 eternity-dust,fluid/argon | 447.8 |
| eternity-ingot (31) | 1 | missing | 2 | 2 | 2 eternity-dust,fluid/argon | 437.4 |
| eternity-ingot (31) | 100 | missing | 2 | 200 | 2 eternity-dust,fluid/argon | 489.8 |
| uxv-assembling-machine (31) | 1 | missing | 5 | 7 | 8 uxv-conveyor-module,fluid/molten-spacetime,fluid/molten-flerovium,fluid/excited-dimensionally-transcendent-crude-catalyst | 489.7 |
| uxv-assembling-machine (31) | 100 | missing | 5 | 360 | 8 uxv-conveyor-module,fluid/molten-spacetime,fluid/molten-flerovium,fluid/excited-dimensionally-transcendent-crude-catalyst | 482.2 |
| uxv-chemical-bath (31) | 1 | missing | 5 | 32 | 9 bronze-ingot,iron-plate,tin-plate,glass-dust | 404.1 |
| uxv-chemical-bath (31) | 100 | missing | 5 | 255 | 9 bronze-ingot,iron-plate,tin-plate,glass-dust | 349.2 |
| uxv-circuit-assembler (31) | 1 | missing | 5 | 7 | 8 uxv-conveyor-module,fluid/molten-spacetime,fluid/molten-flerovium,fluid/excited-dimensionally-transcendent-crude-catalyst | 401.1 |
| uxv-circuit-assembler (31) | 100 | missing | 5 | 360 | 8 uxv-conveyor-module,fluid/molten-spacetime,fluid/molten-flerovium,fluid/excited-dimensionally-transcendent-crude-catalyst | 395.0 |

| Job start of 10 | Result | ms |
|---|---|---|
| eternity-wire | missing | 281.6 |
| eternity-ingot | missing | 254.8 |
| uxv-assembling-machine | missing | 284.0 |
| uxv-chemical-bath | missing | 191.3 |
| uxv-circuit-assembler | missing | 252.4 |

### Long run (30 minutes at 5000)

| Minute | Script avg | 99th | Worst | Ticks over 5 ms | GC avg | Mod heap (kB) | Backlogs io / storage bus / fluid / maintainer / circuit |
|---|---|---|---|---|---|---|---|
| 5 | 1.331 | 3.38 | 37.1 | 59 | 0.093 | 99189 | 2415 / 0 / 0 / 0 / 91 |
| 10 | 1.151 | 3.11 | 36.4 | 51 | 0.091 | 90515 | 1475 / 0 / 0 / 0 / 91 |
| 15 | 1.051 | 2.94 | 38.1 | 49 | 0.084 | 116457 | 1448 / 0 / 0 / 0 / 91 |
| 20 | 0.981 | 2.84 | 45.1 | 47 | 0.081 | 75619 | 1120 / 0 / 0 / 0 / 91 |
| 25 | 0.959 | 2.84 | 35.1 | 44 | 0.087 | 70669 | 1120 / 0 / 0 / 0 / 91 |

At the end of the run: mod heap 79718 kB.

### Profiles


#### Profile at 1000 (inclusive ms per tick of the window, calls per tick, µs per call; wrapper overhead 0.88 µs per call)

| Function | ms per tick | Calls per tick | µs per call |
|---|---|---|---|
| `schedule.M.run` | 1.1455 | 5.00 | 229.1 |
| `io.M.on_tick` | 0.9624 | 1.00 | 962.4 |
| `io.visit` | 0.9167 | 13.65 | 67.2 |
| `io.M.interface_step` | 0.4352 | 4.90 | 88.8 |
| `io.M.bus_step` | 0.3912 | 8.75 | 44.7 |
| `autocraft.M.on_tick` | 0.2821 | 1.00 | 282.1 |
| `circuit.on_tick` | 0.1558 | 1.00 | 155.8 |
| `circuit.visit_circuit` | 0.1372 | 0.17 | 823.2 |
| `network.M.extract_to` | 0.1330 | 5.92 | 22.5 |
| `io.import_items` | 0.1305 | 3.80 | 34.4 |
| `network.insert_key` | 0.1151 | 7.13 | 16.2 |
| `circuit.circuit_step` | 0.1038 | 0.15 | 691.9 |
| `network.M.insert_stack` | 0.1018 | 2.95 | 34.5 |
| `io.interface_sides` | 0.1002 | 4.90 | 20.5 |
| `network.extract_key` | 0.0995 | 7.81 | 12.7 |
| `network.M.active_of` | 0.0937 | 15.16 | 6.2 |
| `io.export_items` | 0.0834 | 2.96 | 28.2 |
| `network.M.insert` | 0.0730 | 2.97 | 24.6 |
| `autocraft.maintenance` | 0.0723 | 0.50 | 144.6 |
| `autocraft.scan_provider` | 0.0701 | 0.50 | 140.1 |
| `io.M.fluid_bus_step` | 0.0658 | 2.77 | 23.8 |
| `autocraft.step_jobs` | 0.0479 | 1.00 | 47.9 |
| `storagebus.M.on_tick` | 0.0424 | 1.00 | 42.4 |
| `autocraft.job_step` | 0.0413 | 0.50 | 82.7 |
| `io.export_side` | 0.0405 | 1.54 | 26.3 |
| `network.M.network_of` | 0.0388 | 17.27 | 2.2 |
| `network.M.extract_fluid` | 0.0383 | 2.25 | 17.0 |
| `network.M.usable` | 0.0378 | 35.58 | 1.1 |
| `network.lookups` | 0.0332 | 15.69 | 2.1 |
| `circuit.signals_of` | 0.0307 | 0.17 | 184.1 |
| `circuit.network_signals` | 0.0304 | 0.02 | 1825.3 |
| `network.M.storable` | 0.0234 | 3.43 | 6.8 |
| `schedule.M.at` | 0.0226 | 15.27 | 1.5 |
| `network.M.insert_fluid` | 0.0221 | 0.73 | 30.2 |
| `fluid-storagebus.M.on_tick` | 0.0184 | 1.00 | 18.4 |
| `autocraft.on_arrival` | 0.0164 | 7.13 | 2.3 |
| `network.M.insert_partial` | 0.0149 | 0.48 | 31.2 |
| `io.target_of` | 0.0148 | 8.75 | 1.7 |
| `storagebus.M.visit` | 0.0130 | 0.58 | 22.3 |
| `network.moved_key` | 0.0129 | 14.94 | 0.9 |

Engine calls and window data (µs per call):

| Call | µs |
|---|---|
| chest48.get_inventory | 0.5 |
| chest48.get_contents | 0.3 |
| inv.get_item_count{name} | 0.6 |
| inv.get_insertable_count{name} | 0.6 |
| inv.insert+remove 10 | 1.4 |
| inv[i] read + valid_for_read | 0.4 |
| find_entities_filtered{position} | 2.3 |
| entity.valid + direction | 0.3 |
| fluidbox[1] read | 2.1 |
| get_fluid_segment_id | 0.4 |
| get_fluid_segment_contents | 0.6 |
| fluidbox.get_capacity | 0.3 |
| insert_fluid+remove_fluid 100 | 1.4 |
| long segment: get_fluid_segment_contents | 0.6 |
| long segment: insert_fluid+remove_fluid 100 | 1.6 |
| chest800.get_contents | 18.8 |
| chest800.get_item_count{name} | 1.9 |
| chest800.get_insertable_count{name} | 1.0 |
| section.filters = 405 signals | 280.6 |
| section.filters = 100 signals (qualities) | 61.6 |
| section.filters = 400 signals (qualities) | 278.9 |
| section.filters = 700 signals (qualities) | 577.2 |
| section.filters = 1000 signals (qualities) | 990.5 |
| storage API: count | 0.5 |
| storage API: insert 10 + extract 10 (iron-plate) | 9.6 |
| storage API: can_insert 1000 (iron-plate) | 2.3 |
| storage API: can_insert 1000 (a new item type) | 3.3 |
| storage API: extract_to a chest 10 + insert back | 14.6 |
| storage API: can_insert_fluid 1000 (water) | 2.3 |
| storage API: insert_fluid 100 + extract_fluid 100 (water) | 13.9 |
| circuit interface update (no filter, remote) | 907.7 |
| circuit interface update (5 filters, remote) | 131.6 |
| remote.call count (empty work) | 3.2 |
| window: terminal entries (all, by count) | 6522.6 |
| window: terminal entries (items, by name) | 7677.7 |
| window: terminal entries (search 'iron') | 2002.6 |
| window: terminal craft preview (100) | 884.4 |
| window: terminal jobs | 81.4 |
| window: terminal cells | 2847.1 |
| window: interface data (get_interface) | 40.4 |
| window: bus data (bus_info) | 9.1 |
| window: storage bus data (info) | 17.3 |
| window: drive data (drive) | 680.3 |
| window: maintainer data (get_maintainer) | 6.2 |
| window: circuit interface data (get_circuit) | 8.4 |
| window: provider data (provider_info) | 126.5 |
| window: crafting CPU data (group_info) | 30.7 |
| window: controller data (network) | 89.3 |
| build one import bus (raise_built) | 157.2 |
| remove one import bus (raise_destroy) | 121.6 |
| graph rebuild (on_configuration_changed) | 193278.0 |

#### Profile at 5000 (inclusive ms per tick of the window, calls per tick, µs per call; wrapper overhead 0.92 µs per call)

| Function | ms per tick | Calls per tick | µs per call |
|---|---|---|---|
| `schedule.M.run` | 1.6242 | 5.00 | 324.8 |
| `io.M.on_tick` | 1.2948 | 1.00 | 1294.8 |
| `io.visit` | 1.2114 | 16.00 | 75.7 |
| `io.M.interface_step` | 0.6325 | 6.68 | 94.7 |
| `autocraft.M.on_tick` | 0.4638 | 1.00 | 463.8 |
| `io.M.bus_step` | 0.4532 | 9.32 | 48.6 |
| `network.insert_key` | 0.2328 | 7.69 | 30.3 |
| `circuit.on_tick` | 0.2211 | 1.00 | 221.1 |
| `network.M.insert_stack` | 0.1750 | 3.91 | 44.8 |
| `autocraft.step_jobs` | 0.1673 | 1.00 | 167.3 |
| `circuit.visit_circuit` | 0.1644 | 0.17 | 986.4 |
| `io.import_items` | 0.1607 | 3.81 | 42.1 |
| `autocraft.job_step` | 0.1602 | 1.00 | 160.2 |
| `io.interface_sides` | 0.1553 | 6.68 | 23.2 |
| `network.M.extract_to` | 0.1494 | 6.48 | 23.1 |
| `circuit.circuit_step` | 0.1290 | 0.15 | 860.3 |
| `storagebus.M.on_tick` | 0.1257 | 1.00 | 125.7 |
| `network.extract_key` | 0.1183 | 7.73 | 15.3 |
| `network.M.active_of` | 0.1174 | 20.68 | 5.7 |
| `io.M.fluid_bus_step` | 0.0871 | 3.50 | 24.9 |
| `io.export_items` | 0.0846 | 2.94 | 28.8 |
| `network.M.insert` | 0.0696 | 1.89 | 36.8 |
| `autocraft.maintenance` | 0.0680 | 0.50 | 136.0 |
| `autocraft.scan_provider` | 0.0658 | 0.50 | 131.7 |
| `storagebus.M.visit` | 0.0598 | 2.92 | 20.5 |
| `network.M.network_of` | 0.0547 | 26.35 | 2.1 |
| `network.M.insert_partial` | 0.0524 | 1.30 | 40.3 |
| `io.export_side` | 0.0520 | 1.88 | 27.6 |
| `network.M.usable` | 0.0473 | 47.88 | 1.0 |
| `network.M.insert_fluid` | 0.0465 | 0.59 | 79.5 |
| `network.M.extract_fluid` | 0.0460 | 2.33 | 19.7 |
| `circuit.visit_maintainer` | 0.0402 | 1.68 | 23.9 |
| `fluid-storagebus.M.on_tick` | 0.0384 | 1.00 | 38.4 |
| `schedule.M.at` | 0.0378 | 22.02 | 1.7 |
| `network.lookups` | 0.0356 | 16.01 | 2.2 |
| `network.M.storable` | 0.0334 | 5.21 | 6.4 |
| `circuit.signals_of` | 0.0327 | 0.17 | 196.4 |
| `circuit.network_signals` | 0.0325 | 0.02 | 1950.1 |
| `network.M.can_insert_fluid` | 0.0265 | 0.59 | 45.2 |
| `fluid-storagebus.M.visit` | 0.0254 | 1.25 | 20.3 |

Engine calls and window data (µs per call):

| Call | µs |
|---|---|
| chest48.get_inventory | 0.6 |
| chest48.get_contents | 0.4 |
| inv.get_item_count{name} | 0.6 |
| inv.get_insertable_count{name} | 3.8 |
| inv.insert+remove 10 | 5.6 |
| inv[i] read + valid_for_read | 2.7 |
| find_entities_filtered{position} | 1.9 |
| entity.valid + direction | 0.3 |
| fluidbox[1] read | 0.5 |
| get_fluid_segment_id | 0.3 |
| get_fluid_segment_contents | 0.6 |
| fluidbox.get_capacity | 0.3 |
| insert_fluid+remove_fluid 100 | 1.4 |
| long segment: get_fluid_segment_contents | 0.6 |
| long segment: insert_fluid+remove_fluid 100 | 1.4 |
| chest800.get_contents | 15.0 |
| chest800.get_item_count{name} | 1.1 |
| chest800.get_insertable_count{name} | 1.1 |
| section.filters = 405 signals | 279.6 |
| section.filters = 100 signals (qualities) | 67.8 |
| section.filters = 400 signals (qualities) | 278.8 |
| section.filters = 700 signals (qualities) | 605.9 |
| section.filters = 1000 signals (qualities) | 989.7 |
| storage API: count | 0.5 |
| storage API: insert 10 + extract 10 (iron-plate) | 14.8 |
| storage API: can_insert 1000 (iron-plate) | 5.8 |
| storage API: can_insert 1000 (a new item type) | 3.4 |
| storage API: extract_to a chest 10 + insert back | 19.8 |
| storage API: can_insert_fluid 1000 (water) | 17.5 |
| storage API: insert_fluid 100 + extract_fluid 100 (water) | 42.3 |
| circuit interface update (no filter, remote) | 973.6 |
| circuit interface update (5 filters, remote) | 109.5 |
| remote.call count (empty work) | 3.1 |
| window: terminal entries (all, by count) | 6828.9 |
| window: terminal entries (items, by name) | 5838.3 |
| window: terminal entries (search 'iron') | 3577.8 |
| window: terminal craft preview (100) | 2812.9 |
| window: terminal jobs | 693.6 |
| window: terminal cells | 14947.8 |
| window: interface data (get_interface) | 41.7 |
| window: bus data (bus_info) | 10.0 |
| window: storage bus data (info) | 17.3 |
| window: drive data (drive) | 562.7 |
| window: maintainer data (get_maintainer) | 6.3 |
| window: circuit interface data (get_circuit) | 4.5 |
| window: provider data (provider_info) | 131.6 |
| window: crafting CPU data (group_info) | 33.4 |
| window: controller data (network) | 461.9 |
| build one import bus (raise_built) | 164.1 |
| remove one import bus (raise_destroy) | 461.0 |
| graph rebuild (on_configuration_changed) | 915500.1 |

#### Profile at 20000 (inclusive ms per tick of the window, calls per tick, µs per call; wrapper overhead 0.85 µs per call)

| Function | ms per tick | Calls per tick | µs per call |
|---|---|---|---|
| `schedule.M.run` | 3.4832 | 5.00 | 696.6 |
| `io.M.on_tick` | 2.8406 | 1.00 | 2840.6 |
| `io.visit` | 2.7352 | 16.00 | 170.9 |
| `io.M.interface_step` | 1.3783 | 6.36 | 216.7 |
| `io.M.bus_step` | 1.1980 | 9.64 | 124.3 |
| `network.insert_key` | 1.1211 | 18.51 | 60.6 |
| `autocraft.M.on_tick` | 0.7208 | 1.00 | 720.8 |
| `network.M.insert_stack` | 0.6515 | 10.08 | 64.6 |
| `io.import_items` | 0.5173 | 3.85 | 134.3 |
| `storagebus.M.on_tick` | 0.3846 | 1.00 | 384.6 |
| `autocraft.step_jobs` | 0.3548 | 1.00 | 354.8 |
| `io.M.fluid_bus_step` | 0.3518 | 3.68 | 95.7 |
| `autocraft.job_step` | 0.3461 | 1.00 | 346.1 |
| `network.extract_key` | 0.3171 | 7.97 | 39.8 |
| `io.interface_sides` | 0.3164 | 6.36 | 49.7 |
| `network.M.extract_to` | 0.2980 | 5.97 | 50.0 |
| `network.M.insert_fluid` | 0.2934 | 1.39 | 210.7 |
| `circuit.on_tick` | 0.2829 | 1.00 | 282.9 |
| `network.M.insert_partial` | 0.2341 | 4.35 | 53.9 |
| `network.M.insert` | 0.2148 | 2.69 | 79.7 |
| `network.extract_order` | 0.1637 | 7.97 | 20.5 |
| `io.export_items` | 0.1616 | 2.90 | 55.7 |
| `storagebus.M.visit` | 0.1611 | 8.00 | 20.1 |
| `network.M.active_of` | 0.1594 | 25.25 | 6.3 |
| `circuit.visit_circuit` | 0.1569 | 0.17 | 941.5 |
| `io.tank_to_network` | 0.1548 | 0.56 | 278.6 |
| `fluid-storagebus.M.on_tick` | 0.1444 | 1.00 | 144.4 |
| `network.M.can_insert_fluid` | 0.1385 | 1.39 | 99.5 |
| `network.room_for` | 0.1260 | 1.40 | 90.3 |
| `circuit.circuit_step` | 0.1206 | 0.15 | 803.9 |
| `network.M.extract_fluid` | 0.1056 | 2.43 | 43.4 |
| `fluid-storagebus.M.visit` | 0.1026 | 5.00 | 20.5 |
| `circuit.visit_maintainer` | 0.0933 | 4.00 | 23.3 |
| `network.M.storable` | 0.0837 | 14.43 | 5.8 |
| `io.export_side` | 0.0819 | 1.59 | 51.4 |
| `network.M.network_of` | 0.0784 | 39.75 | 2.0 |
| `network.holders` | 0.0778 | 19.91 | 3.9 |
| `autocraft.find_crafter` | 0.0748 | 3.31 | 22.6 |
| `network.M.usable` | 0.0745 | 73.99 | 1.0 |
| `autocraft.maintenance` | 0.0719 | 0.50 | 143.9 |

Engine calls and window data (µs per call):

| Call | µs |
|---|---|
| chest48.get_inventory | 0.8 |
| chest48.get_contents | 0.3 |
| inv.get_item_count{name} | 0.6 |
| inv.get_insertable_count{name} | 0.6 |
| inv.insert+remove 10 | 1.7 |
| inv[i] read + valid_for_read | 0.4 |
| find_entities_filtered{position} | 2.1 |
| entity.valid + direction | 0.3 |
| stack: prototype+spoil+item+health+tags (M.storable) | 0.7 |
| fluidbox[1] read | 0.6 |
| get_fluid_segment_id | 0.3 |
| get_fluid_segment_contents | 0.7 |
| fluidbox.get_capacity | 0.3 |
| insert_fluid+remove_fluid 100 | 1.5 |
| long segment: get_fluid_segment_contents | 0.7 |
| long segment: insert_fluid+remove_fluid 100 | 1.5 |
| chest800.get_contents | 15.7 |
| chest800.get_item_count{name} | 1.1 |
| chest800.get_insertable_count{name} | 1.1 |
| section.filters = 405 signals | 305.4 |
| section.filters = 100 signals (qualities) | 68.2 |
| section.filters = 400 signals (qualities) | 298.2 |
| section.filters = 700 signals (qualities) | 628.2 |
| section.filters = 1000 signals (qualities) | 1206.9 |
| storage API: count | 0.4 |
| storage API: insert 10 + extract 10 (iron-plate) | 43.4 |
| storage API: can_insert 1000 (iron-plate) | 26.3 |
| storage API: can_insert 1000 (a new item type) | 4.1 |
| storage API: extract_to a chest 10 + insert back | 44.2 |
| storage API: can_insert_fluid 1000 (water) | 70.4 |
| storage API: insert_fluid 100 + extract_fluid 100 (water) | 160.9 |
| circuit interface update (no filter, remote) | 928.2 |
| circuit interface update (5 filters, remote) | 111.3 |
| remote.call count (empty work) | 2.9 |
| window: terminal entries (all, by count) | 6550.9 |
| window: terminal entries (items, by name) | 7298.5 |
| window: terminal entries (search 'iron') | 2131.4 |
| window: terminal craft preview (100) | 2668.7 |
| window: terminal jobs | 1550.2 |
| window: terminal cells | 57377.9 |
| window: interface data (get_interface) | 46.9 |
| window: bus data (bus_info) | 10.1 |
| window: storage bus data (info) | 17.3 |
| window: drive data (drive) | 592.0 |
| window: maintainer data (get_maintainer) | 6.5 |
| window: circuit interface data (get_circuit) | 5.6 |
| window: provider data (provider_info) | 151.7 |
| window: crafting CPU data (group_info) | 37.6 |
| window: controller data (network) | 3265.8 |
| build one import bus (raise_built) | 163.3 |
| remove one import bus (raise_destroy) | 1982.5 |
| graph rebuild (on_configuration_changed) | 3748020.1 |


### The premise of the issue, checked

The issue was written from the 0.3.0 numbers of this page, not from a measurement of the scheduler. Checked against
the code (`scripts/fork-me-schedule.lua`, `fork-me-io.lua`) and the counters:

* **The budget is a constant.** True: 16 interface and bus visits per tick at every size (the setting), 8 per
  storage bus side, 4 maintainer checks, 10 circuit updates per second, 1 crafting job step per tick. At 100 the
  interfaces and buses need 2.5 visits per tick, at 1000 13.7, at 5000 the budget is used in every tick and
  3370 blocks wait in the backlog on average (4669 at most); at 20 000 19435
  wait, at 50 000 49669. But the time is not constant: 1.394 ms at 5000, 2.948 at
  20 000, 6.782 at 50 000, because a visit does the work of the ticks since the block's last visit (an
  interface handles 8 slots per 15 ticks of waiting, a bus moves 256 items per second of waiting): the budget caps
  the visits, not the work, and the work follows the throughput.
* **"A busy block is served about every 5 s at 5000."** True, and measured for the first time: a block that moved
  all it was allowed to is due again after 15 ticks, but it is visited again after 4.75 s (median),
  5.75 s (99th percentile), 5.85 s at worst; at 1000 after 0.38 / 0.80 s, at 100 after
  the 15 ticks. At 20 000: 20.77 / 21.02 s, at 50 000: 52.03 /
  52.27 s. The reason is the backlog: every block that is due and does not fit waits in **one**
  first-in-first-out list, busy and idle alike, and a wake does nothing for a block already in it (`Sched.wake`
  returns), so the interval of every block is about (the blocks due per tick) / 16, whatever the block does. The
  `pair` machines of the scene still run at 100 % at 5000: the catch-up (a bus moves its speed times
  the ticks since its last visit) hides the interval as long as the chest or machine on the other side holds what
  piles up. At 20 000 they run at 95 %, at 50 000 at 56 %.
* **Where idle blocks go.** They stay in the same queue. A block that found nothing doubles its interval up to the
  idle limit (300 ticks, the setting; never longer than the round robin of 0.2.0 took, `Sched.idle_limit`) and is
  visited at that interval forever, from the same budget: at 5000, 5.5 of the 16 visits per tick find
  nothing to do (34 % of all visits), and the **idle** scene, where nothing can move at all, still
  costs 0.846 ms per tick against 1.394 for the working scene: all 16 visits per tick find nothing,
  the storage buses are read every 2 s whether they changed or not (2.9 reads per tick), the maintainers checked
  every 5 s (1.7 per tick), one provider rescanned every 2 ticks, and the circuit interfaces written in turns.
* **The other budgets saturate too.** At 20 000 the 2000 storage buses are read every 2.92 s (8 reads per
  tick), so a storage bus sees a chest change after up to 2.82 s (the target of issue #5 was 2 s), the
  2000 level maintainers are checked every 8.35 s (4 per tick) with 805 waiting, and
  a maintainer whose stock was taken reacts after 3.38 s (median; one of the five probes not within
  60 s): its wake finds it in the backlog already, where a wake does nothing, and its job needs a free CPU. The 400
  circuit interfaces are each written every 40.10 s.
* **Memory.** The mod's Lua heap is 108 MB at 5000 and 286 MB at 20 000 (the records of the
  blocks, the cells' item tables, the lookups), the save 6.7 MB; the long run below says whether it grows.
* **What the backlog does.** It serialises everything that is due beyond the budget, each unit once, in the order
  the units came due. There is no priority of busy over idle units and none for a woken unit; its length was not
  reported anywhere (the counters do now). The circuit interfaces show the same effect in small: 100 interfaces at
  10 updates per second are each written every 10.10 s (the "at most once per 60 ticks" of the code
  never applies), with 91 of them waiting at any time.
* **Jobs.** One job step per tick, each job at most every 20 ticks, catch-up at most 3 steps' worth: the 50 jobs at
  5000 are stepped every 0.82 s (full speed through the catch-up); at 20 000 the 200 jobs every
  3.30 s, which is 30 % of their speed, at 50 000 the 500 jobs every 8.30 s.
* **Several networks.** The queue is one for the whole map, so 100 networks of 50 blocks have the same service
  interval as one network of 5000 (4.92 s median), but they cost less per tick
  (1.092 against 1.394 ms): the storage engine's lists are shorter in a small network (the
  variety of 855 item types sits in the first network only, which flatters the number a little).

So the issue's first point stands, including its number; what it did not say is that the idle blocks are the ones
spending the budget, and that the lever is not "more visits" but **who gets a visit**: idle blocks must leave the
budget, and the budget must follow the load by a time-free rule.

### What the new scenes show

* **Long run** (30 minutes at 5000): the script time falls from 1.331 ms in the first five minutes to
  0.959 in the last (the scene's sources run dry and more blocks go idle), the backlog shrinks with them,
  the garbage collector's average stays at 0.087 ms and the mod's Lua heap moves between 69 and
  114 MB with the collector's cycles: nothing grows.
* **Planner.** Vanilla with Space Age: 321 recipes as patterns, trees of depth 9, a plan of the deepest
  items costs 20.8 ms (35 steps), and the crafting tab computes such a plan at every refresh of
  its preview. Gregtorio Continued: 2650 recipes at 75 kinds of machines, trees of depth
  32, and a plan of one of the deepest items costs **437.4 ms** although it stops after
  5 steps at materials the scene cannot make (products with a chance, and 41 patterns
  whose machines' fluid boxes do not fit the recipe as the scene placed them): the planner walks every pattern of
  the network and copies the stock per alternative before it finds that out. Every refresh of the crafting tab's
  preview computes such a plan (lever 11).
* **Engine share.** The ME entities cost the engine 0.36 ms per tick at 5000 and 0.25
  at 20 000 (the scene's whole update minus its script time, against the same scene with every ME entity removed
  before anything was registered): the 2000 hidden side tanks of the interfaces in the fluid system, 20 000 electric
  consumers, the lamps.
* **Load.** Loading the 5000 save takes 0.3 s, the 20 000 save 1.5 s, the 50 000 save
  12.6 s (script.dat alone is most of it: the records of every block, the cells' item tables); the first
  tick after the load costs 37 / 162 / 478 ms.
* **50 000.** The machine builds and runs the scene (a minute to build, 15.1 MB save, 1093 MB of
  Lua heap, 2667 of 3595 ticks over 5 ms); a busy block is visited every 52.03 s, the storage buses
  are read every 7.28 s, the maintainers checked every 20.85 s, the 1000 circuit interfaces
  were not all written once in the window, and 833 of the 2500 `pair` machines stand with a full output. This is
  where the constant budget ends; the issue's size target needs lever 2.

### Targets of issue #38, confirmed or corrected

| Target | 0.3.0 measured here | Verdict |
|---|---|---|
| average script time at 5000: at most 0.6 ms | 1.394 ms (the game client and the browser were running: 1.26 to 1.41 in the quieter runs of 0.3.0) | kept: in the profile 68 % of the mod's tick goes to the interface and bus visits, a third of which find nothing (plan 1), and the visit itself has about 20 µs of lookups and table churn to lose (plan 3) |
| average at 20 000 / 50 000: at most 1.5 / 3 ms | 2.948 / 6.782 ms | kept. The constant budget does not bound the time: a visit moves what its block gathered since the last one (the catch-up, up to 600 ticks' worth), so the work per tick follows the throughput of the scene and the per-visit cost grows with the storage engine's lists; the idle variant at 20 000 costs 1.382 ms because the storage buses (2000 at 8 reads per tick) and the maintainers (2000 at 4 checks per tick) saturate their budgets too. The target is read together with the service target: **at most 1.5 ms at 20 000 and 3 ms at 50 000 while no machine of the scenes waits for its bus** |
| idle network at 5000: at most 0.1 ms | 0.846 ms | kept as a direction, corrected to **at most 0.2 ms**: 0.1 ms leaves no room for what has no event: the storage bus reads (500 buses at 2 s are 4 reads per tick of about 20 µs), the maintainers' checks of circuit conditions and the provider rescans |
| 99th percentile at 5000: at most 2 ms | 3.64 ms | kept |
| ticks over 5 ms at 5000, the mod's own time: none | 12 per minute | corrected to **none from the mod's own work**: the Lua garbage collector's steps (up to 40 ms in one tick, `luaGarbageIncremental`) are the engine's scheduling of the collector; less garbage per visit (plan 4) shortens them, the ticks themselves cannot be promised. The mod's own spikes are the section writes of unfiltered circuit interfaces (0.99 ms for 1000 signals in the engine) on a busy tick |
| worst service interval of a busy block at every size: at most 2 s | 5.75 s at 5000, 21.02 s at 20 000, 52.27 s at 50 000 (99th percentiles) | replaced (pull request 2) by what the interval stood for: **no machine in the scenes waits for its bus, a block is visited before the buffer on its other side runs full or empty, and a woken block is visited within a few ticks**. A uniform period for every busy block was built and measured first and dropped: it cost 70 % more script time at 5000 and moved nothing more. The intervals stay a reported measure of the counters |
| machines waiting for their bus: none in the scenes | `pair` machines at 100 / 95 / 56 % | kept |
| cost per moved item: at most 5 ns | **0.50 µs** of script time per moved item at 5000 (fluid and crafting included), against 0.21 µs of entity update per item for the 5000 inserters of the reference scene: 2.4 times. (The 7.6 and 3.4 ns of the 0.3.0 page divided milliseconds per tick by items per second; the ratio was right, the unit was not.) | corrected to **at most 0.33 µs per moved item** (the issue's 5 ns in the same convention: two thirds of today) |
| Lua garbage per tick at 5000: at most half | 0.092 ms | kept |
| a blueprint of 1000 blocks built or removed: no tick over 16 ms | build 75 ms, removal **848 ms** (1000 plain chests: 22 and 8 ms, the mod's handlers included) | kept for the build as a direction (**at most 30 ms**: 1000 events the engine delivers one by one, each with its registration), **corrected for the removal to at most 50 ms**. The removal's problem is one full search of the network per removed cable (plan 5) |
| graph rebuild on a mod update at 5000: at most 0.3 s | 0.92 s | kept |
| an open terminal on the full network: no tick over 2 ms because of it | the sorted contents list behind it costs **6.8 ms** per refresh (every 60 ticks while the window is open), the cells tab 14.9 ms, the crafting preview 2.8 ms; the GUI work on top is not measurable headless | kept for the data side (**at most 0.5 ms per refresh when nothing changed, 2 ms when everything did**); the GUI side is the maintainer's in-game test |
| load: the first ticks after loading | 37 and 19 ms in the first two ticks at 5000, 162 ms at 20 000 | new target: **no tick over 16 ms after a load at 20 000** |
| several networks | 100 networks of 50 cost 1.092 ms against 1.394 for one of 5000 | new target: **no number of the single network gets worse when the same blocks are split over 100 networks** (the per-network tables must stay cheap) |

### The ranked plan

Each lever with its expected gain from the profile, its risk for saves and its order. One lever or one closely
related group per pull request; a lever whose measured gain is under 5 % of the script time is dropped and recorded
here as tried.

| # | Lever | What changes | Expected gain (from the profile) | Risk for saves | Pull request |
|---|---|---|---|---|---|
| 1 | **Idle blocks leave the budget.** A block that found nothing for its idle limit goes to a sleep list: it is polled from a budget of its own (one visit per tick per 300 sleepers, so every sleeper is still seen within its limit) and comes back the moment a wake hits it (its key arrives, a target is built, its settings change). The busy queue keeps the 16 visits for blocks that have work, and a woken block goes to the front of it (today a wake does nothing for a block that already waits in the backlog, so at 20 000 a maintainer reacts after 3.4 s instead of a tick). | The io queue no longer serialises idle and busy blocks: at 5000 5.5 of the 16 visits per tick find nothing today. Busy interval 99th percentile from 5.75 s to about 0.3 s at 5000 while the number of busy blocks stays under 240 (16 per tick times 15 ticks); idle network from 0.846 to about 0.3 ms at 5000 (what is left: storage bus reads, provider rescans, maintainers). | Low: a flag per record and a second list in the module's storage table; a save without them has every block in the busy queue, as today. Behaviour unchanged: the same blocks are visited, idle ones at most as late as their limit. | 2 |
| 2 | **The budget follows the load, time-free.** The blocks that matter are the ones that hit their cap at their last visit (they moved all the budget allowed: the visit, not the chest or machine, limits them); a block that moved less is limited by the other side and loses nothing by waiting longer. Visits per tick = max(setting, ceil(cap hitters / 120)): every cap hitter is served within 2 s whatever the size, the setting stays the floor, and the count is state, not time. The same rule for crafting jobs (steps per tick = max(setting, ceil(active jobs / 20))), for the storage bus reads (reads per tick = max(setting, ceil(buses / idle limit))) and for the maintainers. | Service: cap hitters at a 99th percentile under 2 s and a median under 0.5 s at every size; `pair` machines at 100 % at 20 000 and 50 000; jobs at full speed above 60 jobs; storage buses at their 2 s. Cost: at 20 000 about 2555 blocks hit their cap (21 visits per tick for the 2 s bound: about 3.64 ms at today's 171 µs per visit, less once a visit moves 2 s of items instead of 20 s and with lever 3); at 50 000 3607 blocks (30 visits per tick). | None for saves (counts, no state). It changes when blocks are visited, so throughput numbers of the scenes change: `bench --check` reports it, the conservation check and the runtime tests guard the behaviour. | 2 (with 1) |
| 3 | **The visit itself.** From the profile: `N.active_of` (network lookup plus `usable` with its controller check) per visit and per storage call, `target_of` revalidation, `get_contents` and the per-type `remove`/`insert` of the import bus, `extract_to` with a fresh stack table per call, the `by_count` string key per item type. Cache the network id and the usable flag per tick on the record, build the ItemStackDefinition tables once per module, look up `by_count` by prototype table instead of a concatenated string, and skip the fluid side of a bus whose target has no fluid boxes without a call. | 76 µs per visit in the profile at 5000 (`io.visit` inclusive; about 10 of them are the profiler's own wrappers), 171 at 20 000; the engine calls inside are about a third. Target 35 µs at 5000: about 0.49 ms per tick (a third of the script time). | None (no state). | 3 |
| 4 | **Garbage.** Scratch tables for the engine call arguments (insert, remove, insert_fluid, set_stack), the `extract_to` definition, `get_contents` replaced by `get_item_count` where one key is asked; the holders and extract-order lists kept instead of rebuilt after every index change; the circuit signal list built in place. | GC average 0.092 ms per tick at 5000, the collector's steps of 10 to 25 ms in a few ticks per minute: fewer allocations per visit halve the garbage; the steps' length follows the allocation rate. Measured by `luaGarbageIncremental` and the worst-tick count. | None. | 3 (with 3) or 4 |
| 5 | **Removal and build burst.** A removed cable runs `components()`, a breadth-first search over the whole network, once per cable: 364 cables in one tick are 364 searches of 20 000 nodes (848 ms). Defer the split check: mark the network dirty and resolve it at the first read of the graph (any lookup of a member's network resolves the dirty networks first), never in the next `on_tick`: there is no end-of-tick event, and a removal and a read in the same tick must see the right networks; search from the smaller side first with an early stop when the neighbours meet. Build: the `find_entities_filtered` per neighbour and the per-module registration are kept, the drive LED redraws batched. | Removal of 1000 blocks from 848 ms to the order of the build (75 ms); the build from 75 toward 30 ms. The graph rebuild of `on_configuration_changed` (0.92 s) gets the same single pass. | Medium: the graph code is the one place where a mistake splits or merges networks wrongly; the runtime tests cover join, split, conflict and sweep, and the burst scene checks the conservation after the removal. | 5 |
| 6 | **Provider rescans.** One provider is rescanned every 2 ticks whatever happens (0.068 ms per tick at 5000, idle or not), because a pattern put into a provider raises no event. Rescan a provider at most every 5 s each (the round robin over the providers with a budget that follows their count, as lever 2), and at once when its network changes or a pattern is inserted through the mod's own functions (which already know). | 0.068 ms per tick at every size, most of the idle cost after lever 1. | None (a scan interval per provider in storage, lazily). | 4 |
| 7 | **Circuit interfaces.** The write of a section of 900 signals (about 1 ms in the engine) only when the list changed is in place; what is left is the list build (`network_signals`: parse and sort about 900 keys, 1.95 ms per build) once per network and 60 ticks while anything moves. Keep the list incrementally: the network's `cver` already counts changes; keep the signal entries keyed by resource and re-sort only when a count crossed another (or sort by name once and keep it, the 1000 largest chosen by a running threshold). | 0.221 ms per tick at 5000 (10 writes per second); halving the build saves a tenth of that; the engine's write stays. Spikes: a write on a busy tick passes 5 ms; a smaller default of the signal count would be a behaviour change and is left to the player. | None. | 6 (dropped if under 5 %) |
| 8 | **Windows.** The terminal's `entries` builds and sorts the whole contents list (6.8 ms at 5000) every 60 ticks while the window is open and compares a signature string. Cache the sorted list per network and version (`net.cver`), rebuild only the buttons whose entry changed, bound the refresh to the visible page. | A refresh of an open terminal from 6.8 ms to under 0.5 ms when nothing changed; the GUI side is measured by the maintainer in the game. | None. | 6 |
| 9 | **Load.** The first two ticks after a load cost 37 and 19 ms at 5000, 162 ms at 20 000: the lookups of every network and the signal lists are built at their first use, all in the first tick. Build them per network when that network is first touched (already) but spread the first visits: the queues' first ticks put every unit due within a second instead of the first tick. | No tick over 16 ms after a load at 20 000. | None. | 5 (with 5) |
| 10 | **Engine share.** The ME entities cost the engine 0.36 ms per tick at 5000 (the whole update of the scene without them against the normal scene's whole update minus script): the interfaces' four hidden side tanks each (2000 tanks in the fluid system), the controllers and crafting blocks as electric consumers, the maintainers' and monitors' lamps. Create an interface's side tank only when its side is set (import sides need a tank only while a pipe touches them), make the crafting blocks' power one consumer per CPU. | Up to 0.36 ms of engine time at 5000 that no script lever reaches. | Medium: the side tanks hold fluid in saves; a migration must keep every drop (the fluid test of `migrate` covers it). | 7 (last; dropped if the share is under 0.1 ms) |
| 11 | **Planner.** `make_plan` builds `stock_of(net)` (every plain item of the network) and the pattern index per call, copies the stock for every alternative pattern (`snapshot`) and walks the tree again for each of the five plans a job start makes: 20.8 ms per plan on 321 vanilla patterns, **437.4 ms** on 2650 GregTech patterns, at every refresh of the crafting tab's preview and at every job start of a level maintainer. Keep the plan cached per network version (`cver`), key and amount while nothing changed; take the stock lazily per key; cut the alternatives' copies to the keys they touch. | A preview from 437.4 to a few ms on GregTech when nothing changed, a job start of a maintainer the same; the planner's node limit (3000) and depth limit (40) stay. | None (the plan is a pure function of the state). | 6 (with 7 and 8) |

Order: 1 and 2 together (they are one scheduler change and decide what the later numbers mean), then 3 with 4 (the visit, measured in turns), then 5 with 9 (graph and load), 6, then 7, 8 and 11 (the circuit list, the windows and the planner: what a player with an open window pays), 10 last. Part 3 (the in-game diagnostic) comes after 2, when the counters have their final shape.

## Pull request 2 (issue #38): the scheduler, levers 1 and 2

Measured on the machine of the other sections (i7-8700K, Factorio 2.0.77), the game closed, nothing else running but the
harness. "Before" is `origin/main` (0.3.0 with the counters of pull request 1). All timings are in turns against it, true
medians. The design is in `docs/ME-REWORK.md` ("Levers 1 and 2 of issue #38").

### What was built, and what was dropped

A first build gave every busy block a uniform period (`ceil(busy / 120)` visits per tick, "every busy block within 2 s"). In
turns against main it cost 70 % more script time at 5000 and moved nothing more: most blocks are limited by the machine or
chest on their other side, not by their visits. The target "worst service interval at most 2 s" was the wrong proxy and is
replaced (table "Targets of issue #38") by what it stood for: no machine in the scenes waits for its bus, a block is visited
before the buffer on its other side runs full or empty, a woken block is visited within a few ticks. The intervals stay a
reported measure.

What is in the pull request instead: the next visit of a block with work comes from the headroom on its other side (half of
the time the buffer lasts, the whole time for a block that moved all its speed allowed, between 15 and 600 ticks, from a
least-loaded tick around it); a block blocked on its target's side is probed (one engine call at a growing interval up to the
idle limit); a block blocked on the network's side is parked and woken by the network, with one slow fallback visit about once
a minute that counts the wakes it had to find (below). The budget per tick is what is due between the floor and the ceiling;
the sleepers' share of it, the probes, is capped at the floor, and the sum of visits and probes of a tick stays within the floor
while the busy list does not need more (a probe that wakes its block counts for two; the probes keep half of the floor when the
busy list needs more, they wait longer, they are never starved). So a network of sleepers never costs more per tick than the
budget of 0.3.0. Defaults: interface and bus visits 16 to 32, storage bus reads 8 to 24 (per side), maintainer checks 4 to 12,
job steps 1 to 2 per tick.

### Script time at 5000: the visits alone, and what the job steps cost and bring

Four rounds in turns, the same map. The job ceiling is the only difference between the three working-copy columns: at
ceiling 1 a tick steps one job as main does, so that column is the visits alone.

| N = 5000 | main | visits alone (job ceiling 1) | default (job ceiling 2) | job ceiling 4 |
|---|---|---|---|---|
| script avg (ms) | 1.187 | 1.172 | 1.255 | 1.294 |
| script p99 (ms) | 3.11 | 3.33 | 3.45 | 3.54 |
| ticks over 5 ms | 11.5 | 11 | 9 | 11.5 |
| provider crafts per second | 327.1 | 327.1 | 344.3 | 341.6 |

* The new visits alone are 1 % under main on the average and 7 % over on the 99th percentile. The average cannot fall much
  further here: the busy interfaces and fluid sides have buffers of about 10 s, half of that is 5 s, and main's saturated queue
  already came back after 4.75 s. A probe costs about what an idle visit did (14 µs against about 35 µs, `io.probe` in the
  profile below). The 99th percentile is higher because main visited exactly 16 blocks every tick and the new schedule visits as
  many as are due, 9.6 on average with peaks.
* The job steps follow the running jobs. At ceiling 2 they cost 0.08 ms (7 %) and bring 5.3 % more crafts at the providers;
  at ceiling 4 they cost 0.12 ms and bring less, so the default is 2.
* The average at 5000 is level with main by design of this pull request (it is 6 % over with the job steps); lever 3 (the visit
  itself, 100 µs per interface visit) is what brings it under.

### `bench --check origin/main`, default settings

`bench --check origin/main`, 3 rounds in turns (reference, working copy, reference, ...), true medians, the spread of the rounds in brackets:

| N = 1000 | Before (origin/main) | After | Verdict |
|---|---|---|---|
| script avg ms | 0.723 (0.715 to 0.726) | 0.395 (0.39 to 0.41) | ok |
| script p99 ms | 2.35 (2.31 to 2.37) | 1.98 (1.93 to 1.98) | ok |
| ticks over 5 ms | 9 (7 to 10) | 8 (7 to 9) | ok |
| gc avg ms | 0.0722 (0.0712 to 0.0773) | 0.042 (0.0416 to 0.0427) | ok |
| items/s | 33247 (33247 to 33247) | 33028 (33028 to 33028) | ok |
| fluid/s | 248 585 (248 585 to 248 585) | 239 425 (239 425 to 239 425) | FAIL |
| provider crafts/s | 17 (17 to 17) | 17 (17 to 17) | ok |
| storage bus latency max s | 1.15 (1.15 to 1.15) | 1.15 (1.15 to 1.15) | ok |
| maintainer latency max s | 0.15 (0.15 to 0.15) | 0.0833 (0.0833 to 0.0833) | ok |
| io busy interval p99 ticks | 48.0 (48.0 to 48.0) | 596.0 (596.0 to 596.0) | reported |
| io backlog max | 527 (527 to 527) | 0 (0 to 0) | ok |
| pair machines utilisation | 100 % (100 % to 100 %) | 100 % (100 % to 100 %) | ok |
| burst build ms | 67 (67 to 68) | 66 (65 to 68) | ok |
| burst remove ms | 414 (405 to 415) | 409 (409 to 426) | ok |
| load first tick ms | 6.26 (6.22 to 6.3) | 6.55 (6.41 to 6.59) | ok |

Throughput per kind of endpoint: differs (the scheduling changed).

| N = 5000 | Before (origin/main) | After | Verdict |
|---|---|---|---|
| script avg ms | 1.19 (1.19 to 1.19) | 1.26 (1.24 to 1.26) | FAIL |
| script p99 ms | 3.03 (3 to 3.06) | 3.48 (3.45 to 3.49) | FAIL |
| ticks over 5 ms | 10 (9 to 10) | 11 (10 to 13) | ok |
| gc avg ms | 0.0745 (0.0733 to 0.076) | 0.0834 (0.0744 to 0.0916) | ok |
| items/s | 166741 (166741 to 166741) | 165819 (165819 to 165819) | ok |
| fluid/s | 1 219 697 (1 219 697 to 1 219 697) | 1 201 474 (1 201 474 to 1 201 474) | ok |
| provider crafts/s | 327 (327 to 327) | 344 (344 to 344) | ok |
| storage bus latency max s | 1.72 (1.72 to 1.72) | 1.72 (1.72 to 1.72) | ok |
| maintainer latency max s | 0.217 (0.217 to 0.217) | 0.0833 (0.0833 to 0.0833) | ok |
| io busy interval p99 ticks | 345.0 (345.0 to 345.0) | 615.0 (615.0 to 615.0) | reported |
| io backlog max | 4669 (4669 to 4669) | 429 (429 to 429) | ok |
| pair machines utilisation | 100 % (100 % to 100 %) | 100 % (100 % to 100 %) | ok |
| burst build ms | 69 (68 to 70) | 71 (70 to 129) | ok |
| burst remove ms | 674 (673 to 677) | 596 (593 to 600) | ok |
| load first tick ms | 33.1 (33.0 to 33.4) | 33.4 (32.6 to 33.5) | ok |

Throughput per kind of endpoint: differs (the scheduling changed).

The three script metrics at 5000 are over main by 6 % (average), 15 % (99th percentile) and inside the noise (ticks over 5 ms)
for the reasons above: 0.08 ms of job steps, the probes, and the uneven number of visits per tick. At 1000 the average falls by
45 %, the 99th percentile by 16 % and the ticks over 5 ms are 9 and 8.

`io busy interval p99` is long on purpose now and is reported, not failed. What fails the check instead is a machine of the
scene waiting for its bus (`pair machines utilisation`, 100 % on both sides) and, once a reference version counts them, visits
that arrived at an empty target or a full source (`io starved arrivals`: 3428 in the window at 5000, 10 % of the visits; main
has no counter, so the check cannot compare it yet). Every scene also fails on a missed wake (below): none in any scene.

**The failure at 1000 is not open.** `fluid/s` is 3.8 % under main in the 3600-tick window. The fluid sources of the scene are
finite (`dry sources` in the bench output) and main empties some of them faster in the first minute: per kind, `iface_fout`
moves 49 998 units per second in main and 43 444 here, `cap_fimp` 41 834 and 39 233. Over a window three times as long (three
rounds in turns) the same kinds are 16 667 and 16 461, 40 608 and 40 004, the total 136 200 against 135 400, 0.6 % under main.
So the difference is when the finite stock leaves, not how much moves. (`burst build ms` at 1000 failed once by 7.5 ms over a
noise floor of 7.3 ms; five rounds later it is 69.7 ms in main and 68.8 ms here, and the merge of two networks no longer
touches the waiting tables when there is nothing waiting.)

### Service quality, before and after

| N = 1000 | 0.3.0 (pull request 1 series) | After levers 1 and 2 |
|---|---|---|
| script time per tick, average (ms) | 0.815 | 0.393 |
| 99th percentile (ms) | 2.63 | 1.96 |
| interface and bus visits per tick (busy + probes) | 13.6 | 4.0 |
| io backlog, average | 102 | 0 |
| busy block (moved all it could): interval median (s) | 0.38 | 0.63 |
| busy block: 99th percentile (s) | 0.80 | 9.93 |
| block that moved something: interval median (s) | 1.00 | 3.65 |
| idle block: interval median / limit (s) | 5.00 | 4.47 |
| storage bus reads per tick | 0.58 | 0.58 |
| storage bus sees a chest change, max (s) | 1.15 | 1.15 |
| level maintainer reacts, max (s) | 0.15 | 0.08 |
| job steps: interval of a job (s) | 0.33 | 0.33 |
| provider crafts per second | 17.3 | 17.3 |
| `pair` machines at their speed (%) | 100 | 100 |
| items per second | 33247 | 33028 |

| N = 5000 | 0.3.0 (pull request 1 series) | After levers 1 and 2 |
|---|---|---|
| script time per tick, average (ms) | 1.394 | 1.262 |
| 99th percentile (ms) | 3.64 | 3.49 |
| interface and bus visits per tick (busy + probes) | 16.0 | 18.0 |
| io backlog, average | 3370 | 15 |
| busy block (moved all it could): interval median (s) | 4.75 | 4.83 |
| busy block: 99th percentile (s) | 5.75 | 10.25 |
| block that moved something: interval median (s) | 4.47 | 3.02 |
| idle block: interval median / limit (s) | 6.43 | 4.83 |
| storage bus reads per tick | 2.92 | 2.92 |
| storage bus sees a chest change, max (s) | 1.72 | 1.72 |
| level maintainer reacts, max (s) | 0.22 | 0.08 |
| job steps: interval of a job (s) | 0.82 | 0.42 |
| provider crafts per second | 327.1 | 344.3 |
| `pair` machines at their speed (%) | 100 | 100 |
| items per second | 166741 | 165819 |

| Idle network, N = 1000 | 0.3.0 | After |
|---|---|---|
| script time per tick, average (ms) | 0.371 | 0.274 |
| interface and bus visits per tick | 4.7 | 3.5 |
| probe interval median (s) | 5.00 | 4.83 |
| probe interval 99th percentile (s) | 5.00 | 5.00 |

| Idle network, N = 5000 | 0.3.0 | After |
|---|---|---|
| script time per tick, average (ms) | 0.846 | 0.573 |
| interface and bus visits per tick | 16.0 | 16.1 |
| probe interval median (s) | 6.15 | 5.25 |
| probe interval 99th percentile (s) | 6.25 | 6.45 |


### The idle network against main, in turns

| nothing to move | main | now |
|---|---|---|
| N = 5000: script avg (ms) | 0.740 | 0.577 |
| N = 5000: script p99 (ms) | 2.43 | 2.37 |
| N = 5000: visits and probes per tick | 16.0 | 1.7 + 14.4 |
| N = 20 000: script avg (ms) | 1.233 | 1.243 |
| N = 20 000: script p99 (ms) | 3.86 | 6.56 |
| N = 20 000: ticks over 5 ms | 12 | 83 |
| N = 20 000: visits and probes per tick | 16.0 | 6.7 + 11.7 |

At 20 000 the average is level with main since the probes of a tick are bounded by the floor (before: 7.7 visits plus 16.0
probes per tick, 1.212 ms against 1.562 ms in the maintainer's run). It is not below: the 20 000 idle scene is not idle for
2000 interfaces that keep moving fluid (107 500 units per second against 63 700 in main, whose queue served them every 21 s)
and the first 7700 blocks start in a backlog that the busy list drains at up to the ceiling, which is why the visits and
probes together are 18.4 per tick and not 16. The 99th percentile is the bursts of those interface visits (a fluid interface
visit moves up to 5000 units), 6.6 against 3.9 ms; that is for lever 3 and its acceptance below.

### 20 000

The maintainer's run (Linux, quiet, `bench --check origin/main --sizes 20000`, three rounds) of `af50d1e`:

| N = 20 000 | main | af50d1e |
|---|---|---|
| script avg (ms) | 2.295 | 2.969 |
| script p99 (ms) | 6.65 | 13.77 |
| ticks over 5 ms | 83 | 267 |
| gc avg (ms) | 0.160 | 0.326 |
| items per second | 528 700 | 580 700 |
| `pair` machines (%) | 95.0 | 99.7 |
| provider crafts per second | 1501 | 1535 |
| maintainer reaction, median (s) | 3.38 | 0.05 |

and the same on this machine for the final code (three rounds in turns): script avg 2.668 to 3.583 ms (+34 %), p99 5.70 to
8.25 ms, ticks over 5 ms 72 to 479, gc avg 0.063 to 0.131 ms, items per second 528 700 to 641 500, fluid 3.38 to 4.12 million
per second, `pair` machines 95.0 to 99.99 %, crafts 1501 to 1535, storage bus latency max 2.82 s on both sides (the storage
bus reads are capped at the floor of 8 per tick as in main), the busy interval at the 99th percentile 21.0 s in main and
20.6 s here (the window starts in a backlog of 19 000 blocks that drains at the ceiling). The price at 20 000 (time up by
a third, the 99th percentile and the ticks over 5 ms up, the garbage doubled, for 10 to 20 % more throughput and the machines
at their speed) is accepted for this pull request only because lever 3 follows and has to pay it back (below). The ceiling
sweep of the previous rule (one run each, not quiet; ceilings 24, 32 and 64 gave 4.06, 4.34 and 5.19 ms with `pair` at 100 %)
is not repeated: the default is 32.

### Parked blocks: the wakes, the fallback, the missed-wakes counter

In 0.3.0 the visit every 5 s hid every missed wake; a parked block with a missed wake would stand still for ever, silently.
Two things guard that now.

* `devcheck.py runtime` has a test per park reason and per way it can end (`runtimemod/parking.lua`, 20 small networks, each
  expecting the block to work within a few hundred ticks, far under the fallback of 3600): the key arrives through a storage
  bus whose chest is filled without an event, through a cell put into a drive and through a crafting job's output; room appears
  because another block exports, because some of a key is taken, because a cell is added to a drive, a drive is built and a
  storage bus gets a chest; the network appears (a cable joins a bus, an island with a drive joins, a controller is placed) and
  splits and joins again; the filter of a block is set and changes; the target is replaced and changes its recipe; a level
  maintainer is woken by its key being taken and by its settings. **None of these was broken**: the same test on `af50d1e`
  passes every wake case (the room after a partial extraction was woken at the next slow step there too; it now marks the
  network on every extraction and wakes the waiting blocks at the next slow step, deterministically). What failed on `af50d1e` are the two cases that lose their
  wakes on purpose (`drop_waits`): the block stood still, and nothing said so.
* A parked block is in the probe list with a slow fallback visit, about once in 3600 ticks, spread over 600 ticks either side,
  from the probe budget. A fallback visit that finds work is a missed wake and is counted (`missed` in `sched_stats`, per
  queue). It is 0 in every test and every bench scene (`bench` reports a scene with one as a problem, so `bench --check` fails
  on it); the two deliberate cases show it counts (1 bus, 1 maintainer). The in-game diagnostic of part 3 will show it.

The fallback costs one full visit per parked block per minute, about 40 µs: 100 parked blocks are 0.028 visits per tick,
1.1 µs. The 100-network scene has 201 parked blocks (key absent) at 5500 blocks: 0.056 visits per tick, 2.2 µs. No scene at 5000 or
20 000 has a parked block, so the measured cost of the fallback there is zero; a base with 10 000 buses waiting for items would
pay 2.8 visits per tick, about 0.11 ms.

### Profile at 5000 after the pull request (inclusive ms per tick, µs per call; one run, the profiler adds 0.9 µs per call)

| Function | ms per tick | Calls per tick | µs per call | main |
|---|---|---|---|---|
| `io.visit` | 0.891 | 9.61 | 92.7 | 1.211 ms, 16 calls, 75.7 µs |
| `io.M.interface_step` | 0.552 | 5.67 | 97.4 | 0.633 ms, 6.68 calls, 94.7 µs |
| `io.M.bus_step` | 0.250 | 3.94 | 63.3 | 0.453 ms, 9.32 calls, 48.6 µs |
| `io.probe` | 0.121 | 8.41 | 14.4 | (idle visits inside `io.visit`) |
| `autocraft.step_jobs` | 0.238 | 1.00 | 237.5 | 0.167 ms |
| `circuit.on_tick` | 0.185 | 1.00 | 185.1 | 0.221 ms |
| `circuit.visit_maintainer` | 0 | 0 | | 0.040 ms |

An interface visit costs 97 µs and is 62 % of the visit time.

### What lever 3 has to deliver

The pull request goes through with the script time at 5000 about level with main. Lever 3 with 4 (the visit itself and the
garbage) has to pay it back, starting where these numbers point: a probe costs as much as an empty visit, so the cost is the Lua
around the engine call (the record and target lookup, the network lookup, the scheduling itself), not the call. Acceptance:
`bench --check v0.3.0` green on script average, 99th percentile and ticks over 5 ms at 5000 and at 20 000, with the average at
5000 clearly below 0.3.0 and the idle network at 20 000 not above it; the garbage per tick at 20 000 back to the level of 0.3.0
or below.

## Pull request 3 (issue #38): the burst and what a change of the graph wakes

The maintainer's run of `bench --check origin/main --sizes 5000,20000` on the merged scheduler found two things: removing
1000 blocks at 20 000 took 1341 / 1295 / 1314 ms on main and 3653 / 2999 / 2584 ms with the scheduler (at 5000 it got better,
852 to 574 ms), and the build burst at 5000 once took 344 ms against 64 to 82. The guess was that a change of the graph wakes
every block of the network, so 1000 removals would wake 20 000 blocks each. The counters say otherwise, and what they found
is below.

### What the removal of 1000 blocks costs at 20 000

`bench --profile 20000` with the burst profiled (`DEVCHECK-BENCH-PROF-BURST remove`, new) and the scheduler's wake counter
(`wakes` in `sched_stats`, new):

* **Wakes in the burst: 0.** A removed block never wakes the other blocks of its network: `remove_node_graph` clears the
  node's own waits and the split of a network (the `components()` search of lever 5) wakes only the waiting blocks that moved
  to a new part. The guess is not the cause.
* **`io.drop` scanned the list of all buses and interfaces** (`s.list`, 20 000 entries) to remove one: about 1.5 ms per
  removal, 476 removals of buses in the burst, 0.7 s. It is O(1) now (`Sched.list_remove`, a position map kept beside the
  array, built again once for a save that does not have it).
* **`components()`** is the rest (lever 5, not part of this pull request): one breadth-first search of the network per removed
  cable.
* **Garbage.** The collector's cost follows the memory allocated far more than the live heap (a run with 20 % more live heap
  cost 9 % more in the collector). A burst allocates what its searches and its removals build.

What the scheduler did add, found while looking for the wakes: a block parked for want of a network (`no-network`) was in a
global list (`s.nonet`) that **every** change of any graph walked and woke completely, whatever network it was on. One cable
placed next to a base woke every unconnected block of the map, and the blocks went to sleep again at their next visit. That
wake was real, though it is not the burst's cost (the burst scene has no such blocks). A block parked for want
of a network or of power now waits on its **own** network (`wait_usable`, the same list as the power wait): a change of that
network, or the slow step's look at its power, wakes it, and a change of any other network does not. Units that left a network
are skipped when it fires, a split wakes only the waiters that moved to a new part, and a merge takes the waiters of the other
network along (`net.wunits`, the index of the waiting units by kind). `runtimemod/parking.lua` has the case (21): a lone import
bus without a network and an export bus without a key keep `parked` and their `due` while a cable merges a small network
elsewhere; it fails on the code of pull request 2 and passes now.

### Numbers (quiet machine, game closed, in turns, medians of the rounds)

`bench` of `v0.3.0` against pull request 2 (`ec49624`) and this pull request (`bdba9db`); 5000 with five rounds, 20 000 with
three. The scheduler is the same code in the last two columns for everything but the wakes of the parked blocks: throughput and
the scheduler's counters are equal to the digit, the script time differs by the noise (20 000: 3.84 and 3.76 ms).

| | v0.3.0 | pull request 2 | this pull request |
|---|---|---|---|
| burst remove 1000 at 5000 (ms) | 749 (738 to 761) | 654 (640 to 675) | **463** (453 to 464) |
| burst build 1000 at 5000 (ms) | 73 (70 to 75) | 117 (75 to 136) | **70** (68 to 73) |
| burst remove 1000 at 20 000 (ms) | 1554 (1453 to 1568) | 1851 (1845 to 1876) | **778** (753 to 817) |
| burst build 1000 at 20 000 (ms) | 77 (73 to 89) | 82 (81 to 93) | 79 (78 to 83) |

* The removal at 20 000 is half of 0.3.0 and 42 % of pull request 2; at 5000 it is 62 % of 0.3.0. (The maintainer's Linux run
  saw a slowdown of 2 to 3 times from pull request 2 here, this machine 19 %; the size of the effect differs between the
  machines, the cure is the same: the list scan is gone.)
* The build at 5000 is back to the 68 to 73 ms of 0.3.0 and the spread of 75 to 136 ms is not seen in five rounds. The cause of
  that spread is not nailed down: a bimodal 74 / 125 ms had been seen before, which fits a collector step landing in the
  burst, but this was not shown. It stays in view: the burst is part of every `bench` run.
* The burst at 20 000 is in the series of this branch (`bench --burst 1000` at every size, default).
* `mod heap alive kB` of the pull request 2 column is not comparable (its tree has no collection before the reading).

### Diagnostics added

`bench --profile ... --alloc` also prints the memory every wrapped function allocates (KB per tick, per call; the collector is
stopped in the window: use `--ticks 600`), the wake counter is in the scheduler's snapshot, and the service report shows the
heap alive after a collection (`mod heap alive kB`, report only, not a pass/fail metric).

## Pull request 4 (issue #38): the visit itself and the garbage, lever 3 with 4, first part

What a visit does that it need not, and the tables it builds for nothing. No change of what is moved, to whom, in which
order: the conservation, priority, filter and card tests and the 21 parking cases are unchanged and pass.

### What was changed

* **An interface with nothing at its sides** (no pipe or pump connected, no row that exports a fluid, nothing in its tanks) does
  not look at the sides again until a wake, a new connection or a changed row (`rec.sidle`); its probe skips the tanks too.
* **The walk over the slots** of the chest runs only when something lies in the inventory that no row keeps (one
  `get_contents` call decides): an interface whose rows hold what they hold, or that is empty, has nothing to import.
* **Scratch tables** for what a visit built per call: the keys of the rows, the info of a bus visit, the arguments of
  `get_item_count` and `remove` (the API copies the arguments); `by_count` cached by quality, then name (no string built per
  call), `prototypes.item` checked once per name, the key of a row cached on the row, the drain budget without a closure per
  run, `is_fluid_key` without a substring for the usual item.
* **The share of the headroom a block waits is learned per block** (separate commit, can be dropped): it starts at half of the
  time the other side's buffer lasts, grows by 0.05 after every visit that found its other side served (up to 0.85) and is back
  at half at once after a visit that arrived at an empty target or a full source; an interface counts the tanks of its sides
  too (a side that had run out, a side's tank that was full). It is the record's state (`rec.sh`), the same on every peer.
  Only blocks with a long headroom (below 600 ticks it is clamped) can use it.
* The profile wrap list covers the storage engine (`insert_key`, `put`, `cell_room`, ...).

### `bench --check v0.3.0` (quiet machine, game closed, in turns, medians; 5000: five rounds, 20 000: three)

| N = 5000 | v0.3.0 | pull request 2 | this pull request | without the learned share |
|---|---|---|---|---|
| script avg (ms) | 1.261 / 1.247 | 1.352 | **1.245 / 1.223** | 1.277 |
| script p99 (ms) | 3.271 / 3.153 | 3.655 | 3.577 / 3.435 | 3.496 |
| ticks over 5 ms | 9 | 14 | 11 / 12 | 12 |
| gc avg (ms) | 0.085 / 0.079 | 0.091 | 0.081 / 0.073 | 0.078 |
| items per second | 166 700 | 165 800 | 165 800 | 165 700 |
| `pair` machines (%) | 100 | 100 | 100 | 100 |
| io visits per tick | | 9.61 | 8.86 | 9.67 |

(two numbers in a cell: the two series of the day, the second with the learned share against the variant without it.)

| N = 20 000 | v0.3.0 | pull request 2 | this pull request |
|---|---|---|---|
| script avg (ms) | 2.839 | 3.838 | 3.678 |
| script p99 (ms) | 5.787 | 8.384 | 8.824 |
| ticks over 5 ms | 103 | 573 | 524 |
| gc avg (ms) | 0.066 | 0.103 | 0.095 |
| items per second | 528 700 | 641 500 | 638 400 |
| `pair` machines (%) | 95.0 | 99.99 | 99.7 |
| idle network, script avg (ms) | 1.207 | 1.252 | **1.166** |
| idle network, p99 (ms) / ticks over 5 ms | 3.73 / 13 | 6.51 / 77 | 6.21 / 76 |

The learned share is worth 4 % at 5000 (1.277 to 1.223 ms) and nothing measurable at 20 000, where every block is already
late. It costs starved arrivals: 4277 against 3428 (the interfaces' sides now report them).

### Where the acceptance of lever 3 is not met, and why

The acceptance (`bench --check v0.3.0` green on average, 99th percentile and ticks over 5 ms at 5000 and 20 000, the average at
5000 clearly below 0.3.0, the idle network at 20 000 not above it, garbage at 20 000 at the level of 0.3.0, burst removal not
above 0.3.0) is **met for the idle network (1.166 against 1.207 ms) and the burst (pull request 3, 778 against 1554 ms)**. It is
**not met** for the rest:

* at 5000 the average is 1 to 2 % below 0.3.0, not clearly below; the 99th percentile is 9 % above (3.4 against 3.15 to 3.27).
* at 20 000 the average is 30 % above (3.68 against 2.84 ms), the 99th percentile 52 % above, the ticks over 5 ms five times, the
  garbage 44 %; the network moves 21 % more items and the machines run at their speed (95 to 99.7 %).

What the visit costs is mostly the work: at 5000 the profile (`io.visit` 175 µs per call in the profiled run) is dominated by the
storage engine (`insert_key` 83 µs per call, 8 calls per tick), which moves items, not by the Lua around it. The visit count
per tick at 20 000 is 24.5 (16 in 0.3.0), because the busy list is a standing backlog (6500 blocks late on average) and every
tick runs at the ceiling of 32 less the probes. The 99th percentile and the ticks over 5 ms follow from that: 32 visits of
about 190 µs are over 5 ms before the rest of the script. The per-tick spikes of the idle network at 20 000 are the start: 48
of its 74 ticks over 5 ms lie in the first 200 ticks after the warm-up (the first visit of 7764 blocks at the ceiling); after
that it is one tick in 200 (0.3.0: 24 ticks in 7000, in no pattern).

The next pull request therefore budgets a tick by the work of its visits and not by their count (below).

### What was tried against the 99th percentile at 20 000, and did not help

Each of these was built, tested with `devcheck.py runtime` and measured at 20 000 (quiet machine, three rounds in turns, medians,
v0.3.0 as the reference: avg 2.70 to 2.78 ms, p99 5.6 to 5.75 ms, 65 to 87 ticks over 5 ms, 528 700 items/s, `pair` 95.0 %). None is in
the pull request.

* **A budget by work instead of the count of visits** (deterministic: each visit reports 80 units plus half a unit per item
  it moved, counted; the busy visits above the floor stop once the work of the tick reaches a cap). Cap at 1500, 2200, 3000 and
  5000 with the floor of 16 visits always done: avg 2.98 / 3.09 / 3.13 / 3.20 ms, p99 7.7 / 8.7 / 8.6 / 8.2 ms, ticks over 5 ms
  283 / 273 / 285 / 390, items per second 515k / 545k / 557k / 600k, `pair` 92.6 / 95.2 / 97.3 / 98.6 %. With only one visit
  guaranteed and the cap at 4500, 6000 and 8000: avg 2.70 / 2.88 / 3.26 ms, p99 8.2 / 8.5 / 8.5 ms, over 5 ms 374 / 408 / 460, items
  per second 425k / 529k / 578k, `pair` 86.9 / 93.8 / 96.9 %. The work of a tick was bounded (maximum 5860 units at the cap of 4500, against
  17 950 without it) and the 99th percentile did not move: the ticks over 5 ms are not the ticks with the most items.
* **Where the ticks over 5 ms come from.** Removing one module at a time (20 000, busy): without the interfaces and buses
  v0.3.0 is at 0.78 ms avg, p99 2.66 ms, 2 ticks over 5 ms, this branch at 0.92 ms, 3.69 ms, 23 (what is not I/O costs more here too: job steps, storage bus probes and the
  rest; not split further); with only the interfaces and buses v0.3.0 is at 1.92 ms, p99 4.19 ms, 14
  ticks, this branch at 2.25 ms, 7.27 ms, 115. A log of every visit between ticks 1000 and 1400 shows the cause: the correlation of
  the tick's time with the items moved is -0.08 and with the number of visits 0.14, and the dearest ticks (8.4 to 10.6 ms against a
  median of 4.4 ms) are runs of 24 interface visits that move no item, in the same stretch of ticks (1299 to 1388): **fluid
  interfaces**, which cost about 0.19 ms more per visit than item interfaces (a regression of the tick time on the kinds of its
  visits; the fluid side's tank and storage calls are the likely part, not profiled per visit), come due together
  (the same buffer and interval) and are served in a streak.
* **Strided picks from the backlog** (every other visit of a tick from a deterministic position of the first 8192 entries, so
  kinds mix): p99 8.54 to 8.0 ms, ticks over 5 ms 425 to 382, avg 3.49 to 3.60 ms. Less than the streaks suggest, and the average
  rises: not worth the mechanism.
* **Interface sides do not report starved arrivals** (the report was added with the learned share): p99 8.0 to 8.2 ms, no
  difference.

What is left is the price of the design: at 20 000 the busy list is a standing backlog, the visits that matter are dear (fluid
interfaces), and the machines are served to their speed. Bringing the 99th percentile to 0.3.0's needs a cheaper fluid
interface visit (to be profiled per visit first), or fewer fluid interface visits for the same fluid
(a larger buffer per visit), not a different order. That is a follow-up (a new issue), not a part of this pull request.

## Pull request 5 (issue #38, part 3): the in-game diagnostic `/me-stats`

The command (`scripts/fork-me-stats.lua`, player guide in `docs/AE2.md`, "What the network costs: /me-stats") reads the scheduler's
counters, so a player sees what #5, #38 and #43 measure: members by kind, interfaces and buses busy, probing and parked (and why),
crafting CPUs and jobs, and for the whole map the visits per tick against the budget, the probes, the backlog, the starved arrivals,
the missed wakes, the wakes and the time between two visits of a block with work (median, 99th percentile, longest) over the last
minute. The window is the difference of two copies of the counters, taken every 3600 ticks (`Sched.mark`, once per tick from
`control.lua`; `Sched.window`), so it covers one to two minutes, or everything since the load; the counters are per peer and never
saved. Cost, measured against pull request 4 (quiet machine, three rounds in turns, medians): script average 1.234 against 1.222 ms at
5000 and 3.706 against 3.733 ms at 20 000, 99th percentile 3.44 against 3.50 and 9.60 against 9.53 ms, ticks over 5 ms 10 against 10
and 553 against 558, garbage 0.087 against 0.072 and 0.132 against 0.095 ms: no difference beyond the noise, as the copy is a few
dozen numbers and the interval histograms once a minute. The runtime test `ME stats command test` builds a small network (an export
bus waiting for an absent key, an import bus on an empty chest, an interface), checks the report (members by kind, blocks by
state: one parked for `no-key`, two probing), that the window since the load is the scheduler's own counters and that a window
between two copies is their difference, and logs every line rendered by the engine: `devcheck.py runtime` fails on a missing
locale key or an unfilled parameter.
