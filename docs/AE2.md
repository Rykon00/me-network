# AE2 in Gregtorio: ME network and autocrafting

## What the ME network is

The ME network is Factorio's logistic network (`prototypes/120-fork-ae2.lua`):

| Entity | Role |
|---|---|
| ME Controller | 2x2 roboport without robots: creates the network area (radius 16). |
| ME Drive (1k ... 256k) | storage chest, capacity from its four storage cells |
| ME Interface | requester chest with "trash unrequested": import/export point |
| ME Terminal | powered screen: search, take, store, and (this page) **crafting** |

Techs: `me-network` (MV), `me-storage-64k` (EV), `me-storage-256k` (IV).

## Autocrafting: how to build it

Tech `me-autocrafting` (EV, needs `me-storage-64k`) unlocks three entities:

| Entity | What it does |
|---|---|
| **ME Molecular Assembler** | assembling machine for item-only crafting recipes (crafting table and assembler recipes up to EV, no fluids), speed 6, 960 kW |
| **ME Pattern Provider** | 1x1 marker, no power. Placed **next to a machine**, the recipe that machine has set becomes a pattern of the network |
| **ME Crafting CPU** | 2x2, needs power (60 kW), part of the network. Runs one job at a time |

Step by step:

1. Build an ME network: ME Controller (powered), at least one ME Drive with items in it,
   an ME Terminal (powered) inside the controller's area.
2. Place an **ME Crafting CPU** in the area and power it. One CPU = one job at a time; a second
   CPU lets two jobs run in parallel.
3. For every recipe the network should be able to craft, place a machine **inside the area**,
   give it power and set the recipe, then put an **ME Pattern Provider on a tile touching the
   machine** (left, right, above or below). Any assembling machine or furnace works: a
   Molecular Assembler for crafting recipes, a GT machine (macerator, EBF, wiremill, ...) for
   processing recipes. One provider can serve up to four machines around it.
4. Open the ME Terminal, tab **Crafting**: every item a pattern can make is listed (also at 0 in
   stock). Click an item, enter an amount, and read the plan line:
   `Ready: 12 crafts in 3 steps. Taken from storage: ...` or `Missing: 12x tin cable`.
   With something missing the Craft button stays disabled. Click **Craft**; the job appears
   in the job list with its progress and a **Cancel** button.
5. When the job is done, the result (and any by-products) is in network storage.

Rules for pattern machines:

* **Dedicate them to the network.** While a job runs the CPU puts ingredients into the machine
  and takes its products out. Do not feed them with inserters or belts as well.
* A machine without a recipe, outside the network, or a provider that touches no machine is ignored.
  Changing the recipe of a pattern machine changes the pattern (within a few seconds). If it is
  changed while a job uses it, that job fails and returns its items.
* The machine has to work on its own: power (or fuel), a mold in the mold slot if the recipe
  needs one, modules as you like. A machine that cannot run makes the job wait; it fails after
  5 minutes without progress and returns its items.
* **Fluids:** recipes with a fluid ingredient or a fluid product **cannot be autocrafted** (the
  ME network has no fluid storage). Such pattern machines are ignored; the crafting tab shows
  how many. Recipes that need more of one ingredient than fits into a machine slot are ignored
  as well.
* Only normal quality items are planned and crafted.

## Design

### Patterns

`storage.fork_ae2.providers` lists every provider. A provider looks at the four tiles around it
(`find_entities_filtered` on the tile centers), collects the assembling machines and furnaces
found there that are in the same logistic network, and reads their recipe (`get_recipe()`, for
furnaces also `previous_recipe`). From all providers of a network the script builds
`patterns[network id]`: item -> recipes that make it, recipe -> machines. The index is rebuilt
lazily when a provider rescan finds a change; a round robin rescan (8 providers per step) keeps
it current. Starting a job rescans all providers first, so the plan always sees the world as it
is now.

### Planning

`need(item, count)` is a recursive resolution: surplus from earlier crafts of this plan, then
storage (normal quality), then a pattern. The item asked for is always crafted (stock is not
counted for the top level, as in AE2). Runs of a recipe are `ceil(count / expected yield)`;
probabilities and ranges use the expected value. Other products of a recipe (by-products) are
not credited to the plan (they may not appear), they simply end in storage. If an item has
several patterns the first one (alphabetical) that needs nothing missing is used. Loops (an
item that needs itself) count as missing and are named in the message. Work is capped at 3000
plan nodes / depth 40 (reported as missing); amounts up to 100 000.

The result is a list of steps (recipe, runs) in dependency order and the items taken from
storage. If something is missing the job does not start and nothing is taken.

### Jobs

Starting a job takes the planned items out of the network into the job's own **item pool**
(`storage.fork_ae2.jobs[id].pool`, plain counts, so it saves, loads and syncs like any storage
table). Reserving at the start means nothing can be stolen by other jobs or by players
taking items while the job runs. A job with no free CPU waits ("Waiting for a free CPU") with
its items reserved.

Each step the CPU of a job:

1. collects machines that are idle again (no progress, no ingredients left): their products go to
   the pool,
2. hands batches (up to 16 crafts, limited by the pool, by one stack per ingredient and by the
   output slot) to idle machines with the right recipe, in plan order (Molecular Assembler
   or any other pattern machine, several machines in parallel),
3. when every step is done, stores the whole pool in the network (result and by-products).

The machines craft at their own speed and use their own power; the script only moves items.
Everything else follows from the pool: the plan makes the total supply equal the total demand,
so the order in which steps consume from the pool does not matter. If a probabilistic product
comes out short, the job tops the ingredient up from network storage when nothing else is
running; if that is impossible it fails after 5 minutes of no progress.

**Cancel** and **failure** never lose items: unused inputs are taken back out of the machines,
machines that are still crafting are waited for (their products are collected), then the pool
goes back into the network. If the network is full the job stays in "Storing items" until there
is room.

Removed entities:

| Removed | Effect |
|---|---|
| Crafting CPU | the job pauses (queued), its items stay in the pool; another free CPU (or a new one) continues it |
| Pattern machine without work in it | the job waits for another machine with that recipe; cancel it or place a machine again |
| Pattern machine with work in it | the job fails (its ingredients go with the machine, like mining any machine); the rest of the pool is returned |
| Pattern provider | the machine is no longer a pattern; a running job finishes what is already in the machine |
| Terminal, controller | jobs without a network pause ("No ME network") |

### Throughput and UPS

* One shared step every 20 ticks (`on_nth_tick(20)`; the terminal refresh uses 60, the molds 30).
* At most 8 jobs per step (round robin), at most 6 machine hand-overs/collections per job per step,
  so one CPU moves up to about 18 machine interactions per second. That matches an assembler
  line and keeps a step cheap; a job with more machines is throttled by the CPU, a second CPU
  doubles it.
* 8 provider rescans per step, planning only on user actions (terminal GUI: while a craft item is
  selected, once per second from the cache).
* No per-tick loops, no loops over the whole network. State lives in `storage.fork_ae2`; GUI
  state (selected item, amount) lives in the GUI elements.

### Existing saves and mod updates

Nothing changes for existing ME networks. `on_configuration_changed` rebuilds the provider and
CPU registries from the world (`find_entities_filtered`), repairs leases and job books and
keeps jobs and their pools.

## Limits and open points

* No fluids (see above). A fluid item storage in the network would be needed.
* Only normal quality, no items with own data (armor, tools) and no spoilage handling in the pool.
* Machines with a fixed recipe picked by their input (furnaces) are only patterns once they
  have smelted the recipe (`previous_recipe`); this path is untested in the real game.
* One CPU runs one job; no co-processors or CPU storage tiers, no crafting request from
  circuit signals, no "keep N in stock" (autocrafting on demand).
* A machine whose only input is shared with a belt or inserter will fight with the network.
* Balance (costs, speeds, tier) and the look of the sprites are untested in the real game.

## Testing

`python tools/devcheck/devcheck.py runtime` builds a small network (CPU, two Molecular
Assemblers, a macerator, providers, a drive) and runs: a two-level job (plate + 2 sticks -> gear,
gear + plate -> belts) whose result and used-up ingredients are checked, a job with too little
raw material that must report the exact shortfall and not start, a queued job that is cancelled,
a CPU that is removed and replaced during a job, a pattern machine that is removed while a job
waits for it and then a cancel (checked with a conservation of raw materials), and a GT
machine as pattern machine. See `tools/devcheck/README.md`.
