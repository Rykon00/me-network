# AE2 in Gregtorio: ME network, autocrafting and fluids

## What the ME network is

The ME network is Factorio's logistic network (`prototypes/120-fork-ae2.lua`):

| Entity | Role |
|---|---|
| ME Controller | 2x2 roboport without robots: creates the network area (radius 16). |
| ME Drive (1k ... 256k) | storage chest, capacity from its four storage cells |
| ME Interface | requester chest with "trash unrequested": import/export point |
| ME Terminal | powered screen: search, take, store, and (this page) **crafting** |
| ME Fluid Drive (1k ... 256k) | fluid storage of the network, capacity from its four fluid storage cells (this page, **Fluids**) |
| ME Fluid Interface | small tank: import/export point for fluids |

Techs: `me-network` (MV), `me-storage-64k` (EV), `me-storage-256k` (IV), `me-autocrafting` (EV),
`me-fluid-storage` (EV), `me-fluid-storage-256k` (IV).

## Autocrafting: how to build it

Tech `me-autocrafting` (EV, needs `me-storage-64k`) unlocks three entities:

| Entity | What it does |
|---|---|
| **ME Molecular Assembler** | assembling machine for item-only crafting recipes (crafting table and assembler recipes up to EV, no fluid boxes), speed 6, 960 kW |
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
   Molecular Assembler for crafting recipes, a GT machine (macerator, EBF, wiremill, chemical
   reactor, ...) for processing recipes. One provider can serve up to four machines around it.
4. Open the ME Terminal, tab **Crafting**: every item and fluid a pattern can make is listed
   (also at 0 in stock). Click one, enter an amount (items, or fluid units), and read the plan line:
   `Ready: 12 crafts in 3 steps. Taken from storage: ...` or `Missing: 12x tin cable, 400 chlorine`.
   With something missing the Craft button stays disabled. Click **Craft**; the job appears
   in the job list with its progress and a **Cancel** button.
5. When the job is done, the result (and any by-products) is in network storage: items in the
   ME Drives, fluids in the ME Fluid Drives.

Rules for pattern machines:

* **Dedicate them to the network.** While a job runs the CPU puts ingredients into the machine
  and takes its products out. Do not feed them with inserters, belts or pipes as well.
* A machine without a recipe, outside the network, or a provider that touches no machine is ignored.
  Changing the recipe of a pattern machine changes the pattern (within a few seconds). If it is
  changed while a job uses it, that job fails and returns its items.
* The machine has to work on its own: power (or fuel), a mold in the mold slot if the recipe
  needs one, modules as you like. A machine that cannot run makes the job wait; it fails after
  5 minutes without progress and returns its items.
* **Fluids:** once `me-fluid-storage` is researched (see below), recipes with fluid ingredients
  or fluid products work as patterns, provided the fluid boxes the recipe uses have **no pipes
  connected**: the network fills the input boxes and drains the output boxes itself. The
  Molecular Assembler has no fluid boxes, so fluid recipes need a GT machine (chemical reactor,
  extractor, ...). Not usable, and counted per reason in the crafting tab's info line: machines
  that need more of one ingredient than fits into a machine slot (`stack`), machines without a
  usable box for the recipe (`fluid-box`: box too small for one craft, no matching box, a furnace),
  machines with a pipe on a used box (`fluid-pipes`), and recipes that need a fluid temperature
  the network cannot deliver (`fluid-temperature`, see the temperature rule below).
* Only normal quality items are planned and crafted.

## Fluids

Tech `me-fluid-storage` (EV, needs `me-autocrafting`) unlocks fluid storage cells and ME Fluid
Drives from 1k to 64k and the ME Fluid Interface; `me-fluid-storage-256k` (IV, also needs
`me-storage-256k`) the 256k cell and drive (`prototypes/122-fork-ae2-fluids.lua`).

| Thing | What it is |
|---|---|
| **Fluid storage cell** (1k ... 256k) | storage housing + storage component of the tier + a pump. Holds 8000 fluid units per "1k" |
| **ME Fluid Drive** (1k ... 256k) | 1x1, no power, four cells on a drive chassis: 32 000 / 128 000 / 512 000 / 2 048 000 / 8 192 000 units. Takes any fluids of the network in any mix; the disassembly recipe gives the cells back (a loaded drive item loses its fluid there, so place it and export first; recyclers do not take drives) |
| **ME Fluid Interface** | 1x1 tank of 5000 units with a pipe connection on every side: the import/export point |

Step by step:

1. Place ME Fluid Drives inside the network area (ME Controller or roboport coverage), like ME
   Drives. The storage tab of the ME Terminal shows `Fluids: used of capacity` as soon as a drive
   is there. The upgrade planner swaps in bigger drives (read "Picking a drive up" below first).
2. **Import:** place an ME Fluid Interface inside the area and connect pipes to it. Import is
   the default mode: everything in the pipes and tanks connected to the interface goes into the
   network. Pipes and tanks connected **without a pump** in between form one fluid segment with
   the interface, and the whole segment is emptied (a full storage tank within a second). With
   a pump in front of the interface the fluid arrives at the pump's rate. Import stops when the
   fluid drives are full.
3. **Export:** open the interface. The panel next to the tank GUI has an Import/Export switch,
   a fluid selector and a fill level (0 to 5000). In export mode the network fills the interface
   with the chosen fluid up to that level and refills it as pipes and machines take it. Pipes
   and tanks connected without a pump share that level with the interface; a pump behind the
   interface takes the fluid away at its rate. Another fluid still in the tank is imported first
   (if the drives have room). The panel shows the status (working, no drive, drives full, the
   network does not hold this fluid, ...) and the fluid totals of the network.
4. The **storage tab** of the ME Terminal lists the stored fluids below the items (the search
   applies to them too). Fluids cannot be taken by hand: use an interface in export mode. The
   "open GUI" key on a fluid drive shows what that drive holds (the window closes when you walk
   out of reach). A loaded drive item can be stored in the network and taken out again through
   the terminal; it keeps its fluid. Autocrafting never takes drive items out of storage.

**Picking a drive up:** the contents travel on the drive item and are listed in the item's
tooltip; placing that item brings them back (by hand, by robots, from a ghost of a
deconstructed drive, on a space platform). The upgrade planner and fast replace leave the fluid
on the **old** drive item, the new drive starts empty: place the old drive item again inside the
network to get its fluid back. A drive that is destroyed loses its fluids, like a storage tank
that burns down, and so does a loaded drive item whose cells are taken out. Picking up a fluid
interface moves what it holds back into the network (as far as the drives have room).

**Temperature:** the network stores fluids by name only, without a temperature. Importing drops
the temperature; an export, and the hand-over to a pattern machine, delivers the fluid at its
default temperature. Steam therefore loses its heat in the network (it comes out at 15 °C, which
no steam engine or turbine accepts); the Gregtorio fluids have a single temperature and are not
affected. A recipe whose fluid box needs a temperature the default does not satisfy is not a
pattern (`fluid-temperature` in the info line).

## Design

### Fluid storage

The logistic network knows no fluids, so the fluid side lives in `storage.fork_me_fluids`
(`scripts/fork-me-fluids.lua`). An ME Fluid Drive is a passive 1x1 entity without a fluid box;
its contents are a plain table `{ fluid -> amount }` per drive (`drives[unit_number]`), capped by
the capacity the prototype file passes through the mod-data `fork-me-fluids` (no duplicated
numbers). The network total of a fluid is the sum over the drives whose entity stands in that
logistic network; the network is looked up when a total is asked for
(`find_logistic_network_by_position`), so merging or splitting networks needs no bookkeeping
and nothing is ever rebuilt. Keeping the contents per drive rather than per network is what
makes picking a drive up work: the mined-entity events move the table onto the item as tags
(`fork_me_fluids`) with a description, the built events read the tags of the consumed item
(`event.tags` for ghosts and `script_raised_revive`, `event.stack` for robots and platforms,
`event.consumed_items` for players) and restore the contents, clamped to the capacity. A cloned
drive starts empty (no duplication). `insert` fills drives that already hold the fluid first,
then the rest; `remove` takes from the drives in unit-number order.

The **ME Fluid Interface** is a real storage tank (5000 units). Every 15 ticks
(`on_nth_tick(15)`; 20, 30 and 60 are taken by autocrafting, molds and terminal) up to 8
interfaces are stepped, round robin, with one drive list per network and step. Import: the
tank's fluid is removed with `remove_fluid`, limited to the free capacity of the drives; this
takes the whole fluid segment (pipes and tanks connected without a pump share it with the
interface, whose own box would only ever hold its share). Export: `want = level - held`,
`insert_fluid` of `min(want, stored)` at the default temperature. In both directions only what
the engine reports as removed or inserted is booked in the drives, never the requested amount,
so fluid is conserved. The status of the last step (ok, no network, no drive, full, empty, the
network does not hold the fluid, another fluid blocks the tank) is shown in the panel.

Fluids are stored by name only. One temperature per fluid keeps totals, export and hand-over
unambiguous; the price is the temperature rule above.

### Patterns

`storage.fork_ae2.providers` lists every provider. A provider looks at the four tiles around it
(`find_entities_filtered` on the tile centers), collects the assembling machines and furnaces
found there that are in the same logistic network, and reads their recipe (`get_recipe()`, for
furnaces also `previous_recipe`). From all providers of a network the script builds
`patterns[network id]`: resource key -> recipes that make it, recipe -> machines. Resource keys
are item names and `fluid/<name>` for fluids; stock, plan, pool, GUI and the remote interface
use the same keys. A machine with a fluid recipe carries its **fluid map**, built from
`entity.fluidbox`: which input box (by index) takes which fluid ingredient (the box filter the
recipe set, or recipe order for unfiltered boxes) and which output boxes hold the fluid products,
with their capacities. Machines the network cannot use are counted per reason in
`patterns[net].ignored = { total, [reason] }`: `stack`, `fluid-box` (no matching box, box smaller
than one craft, an input-output box, a furnace), `fluid-pipes` (a used box has a connection) and
`fluid-temperature` (the box filter's temperature range excludes the fluid's default). The index
is rebuilt lazily when a provider rescan finds a change; a round robin rescan (8 providers per
step) keeps it current. Starting a job rescans all providers first, so the plan always sees the
world as it is now.

### Planning

`need(key, count)` is a recursive resolution: surplus from earlier crafts of this plan, then
storage (normal quality items from `get_contents()`, fluids from `fluids.totals(net)`), then a
pattern. The resource asked for is always crafted (stock is not counted for the top level, as in
AE2). Runs of a recipe are `ceil(count / expected yield)`; probabilities and ranges use the
expected value; fluid amounts stay fractional (14.4 molten tin per craft is planned as such).
Other products of a recipe (by-products) are not credited to the plan (they may not appear),
they simply end in storage. If a resource has several patterns the first one (alphabetical)
that needs nothing missing is used. Loops (a resource that needs itself) count as missing and
are named in the message. Work is capped at 3000 plan nodes / depth 40 (reported as missing);
amounts up to 100 000 items or 10 000 000 fluid units. Items with own data (the fluid drive
items, which may carry fluid) are never counted as stock, so a job cannot strip them.

The result is a list of steps (recipe, runs) in dependency order and the resources taken from
storage. If something is missing the job does not start and nothing is taken.

### Jobs

Starting a job takes the planned resources out of the network into the job's own **pool**
(`storage.fork_ae2.jobs[id].pool`, plain counts per key, so it saves, loads and syncs like any
storage table); items with `remove_item`, fluids with `fluids.remove`. Reserving at the start
means nothing can be stolen by other jobs or by players taking items while the job runs. A job
with no free CPU waits ("Waiting for a free CPU") with its resources reserved.

Each step the CPU of a job:

1. collects machines that are idle again (no progress, no ingredients left): their products go to
   the pool,
2. hands batches (up to 16 crafts, limited by the pool, by one stack per item ingredient, by the
   output slot and by the fluid boxes) to idle machines with the right recipe, in plan order
   (Molecular Assembler or any other pattern machine, several machines in parallel),
3. when every step is done, stores the whole pool in the network (result and by-products), items
   with `net.insert`, fluids with `fluids.insert`. What does not fit stays in the pool
   ("Storing items and fluids (network or fluid drives full?)").

The machines craft at their own speed and use their own power; the script only moves items and
fluids. Everything else follows from the pool: the plan makes the total supply equal the total
demand, so the order in which steps consume from the pool does not matter. If a probabilistic
product comes out short, the job tops the ingredient up from network storage when nothing else
is running; if that is impossible it fails after 5 minutes of no progress.

**Cancel** and **failure** never lose anything: unused inputs are taken back out of the machines,
machines that are still crafting are waited for (their products are collected), then the pool
goes back into the network. If the network is full the job stays in "Storing items and fluids"
until there is room.

### Fluid hand-over

Fluid amounts in the engine are fixed point (24 fractional bits), so the script never assumes a
box holds "exactly" an amount:

* A craft's fluid ingredient is rounded up to the next fixed point value; the batch is limited
  by `floor(input box capacity / amount)` and `floor(output box capacity / product amount)` on
  top of the item limits.
* Input boxes are set by index: `fluidbox[i] = { name, amount = batch * amount + margin }`. The
  margin (at most 0.01, and only what the pool holds beyond the batch) covers the rounding of the
  machine's consumption. A leftover below one craft that is still in the box is credited back
  to the pool first, and the pool is charged with what the box reports afterwards.
* A job reserves its fluids at the start with `fluids.remove(count + 0.01)`; the top-up of a
  stalled job asks for the same margin.
* Idle means `crafting_progress == 0`, no item ingredient in the input, and every fluid input box
  below one craft's amount. Products are collected by draining the output boxes by index into
  the pool (`fluidbox[i] = nil`); remainders in the input boxes are taken back the same way.
* Crafts are counted with `products_finished`: if the machine made fewer crafts than were handed
  over (rounding ate the last one), the difference is issued again instead of counted as done,
  so the plan's totals stay right.
* Before a hand-over the used boxes are checked for pipe connections again (a pipe placed after
  the scan); such a machine is skipped.

Removed entities:

| Removed | Effect |
|---|---|
| Crafting CPU | the job pauses (queued), its resources stay in the pool; another free CPU (or a new one) continues it |
| Pattern machine without work in it | the job waits for another machine with that recipe; cancel it or place a machine again |
| Pattern machine with work in it | the job fails; the fluid in its boxes goes back into the job's pool before the machine vanishes (mined-entity hook), items still in it go to whoever mined it, a craft in progress is lost; the pool is returned |
| Pattern provider | the machine is no longer a pattern; a running job finishes what is already in the machine |
| Fluid drive during a job | nothing happens to the job: its fluids are in its pool, not in a drive. The drive item carries what the drive held. At the end the pool is stored in the remaining drives, or waits for room |
| Fluid interface | nothing for jobs; what it holds goes back into the network (as far as the drives have room), its mode, fluid and level are forgotten |
| Terminal, controller | jobs without a network pause ("No ME network") |

### Throughput and UPS

* One shared autocrafting step every 20 ticks (`on_nth_tick(20)`; the fluid interfaces use 15,
  the molds 30, the terminal refresh 60).
* At most 8 jobs per step (round robin), at most 6 machine hand-overs/collections per job per step,
  so one CPU moves up to about 18 machine interactions per second. That matches an assembler
  line and keeps a step cheap; a job with more machines is throttled by the CPU, a second CPU
  doubles it.
* 8 provider rescans per step, planning only on user actions (terminal GUI: while a craft item is
  selected, once per second from the cache).
* The fluid step every 15 ticks handles at most 8 interfaces (one `remove_fluid` or
  `insert_fluid` each) and the open drive and interface panels. A network total loops over the
  fluid drives (a few hundred at most, once per network and step), never over tanks or pipes.
* No per-tick loops, no loops over the whole network. State lives in `storage.fork_ae2` and
  `storage.fork_me_fluids`; GUI state (selected resource, amount) lives in the GUI elements.

### Existing saves and mod updates

Nothing changes for existing ME networks. `on_configuration_changed` rebuilds the provider and
CPU registries from the world (`find_entities_filtered`), repairs leases and job books and
keeps jobs and their pools; leases from before fluid support get empty fluid maps, providers are
rescanned.
The fluid state is created lazily; its rebuild (run first, autocrafting reads it) finds the fluid
drives and interfaces in the world, keeps drive contents by unit number (clamped to the capacity)
and interface settings, and closes open fluid panels.

## Limits and open points

* One temperature per fluid: stored by name, exported at the default temperature. Hot steam loses
  its heat; recipes that need another temperature are not patterns.
* Drive contents are not part of blueprints: a drive built from a blueprint starts empty, only
  the item's tags carry fluid. Fluid in a destroyed drive is lost.
* No per-drive limits on fluid types (no partitioning, no filters, unlike AE2 cells): every drive
  takes every fluid; `insert` prefers drives that already hold it.
* The export level applies to the interface's own box; pipes and tanks connected without a pump
  share that level, so the segment holds more than `level` in total. Put a pump behind the
  interface to fill a tank.
* The fluid interface has no circuit connection, and the ME Controller's circuit output lists
  items only; the fluid totals are only shown in the terminal and the panels.
* Taking the cells out of a loaded drive item (disassembly recipe) loses its fluid; the recipe
  says so, and recyclers do not accept drives.
* Only normal quality, no items with own data (armor, tools) and no spoilage handling in the pool.
* Machines with a fixed recipe picked by their input (furnaces) are only patterns once they
  have smelted the recipe (`previous_recipe`); this path is untested in the real game.
* One CPU runs one job; no co-processors or CPU storage tiers, no crafting request from
  circuit signals, no "keep N in stock" (autocrafting on demand).
* A machine whose only input is shared with a belt, inserter or pipe will fight with the network.
* Balance (costs, speeds, tier), the look of the sprites and the GUIs (terminal fluid grid,
  drive contents, interface panel) are untested in the real game.

## Testing

`python tools/devcheck/devcheck.py runtime` builds a small network (CPU, two Molecular
Assemblers, a macerator, providers, a drive) and runs: a two-level job (plate + 2 sticks -> gear,
gear + plate -> belts) whose result and used-up ingredients are checked, a job with too little
raw material that must report the exact shortfall and not start, a queued job that is cancelled,
a CPU that is removed and replaced during a job, a pattern machine that is removed while a job
waits for it and then a cancel (checked with a conservation of raw materials), and a GT
machine as pattern machine.

A second network tests the fluids: an import interface with a storage tank of chlorine connected
to it, an export interface set to 1000 units, a 1k fluid drive, a roboport with construction
robots, and HV chemical reactors and an EV extractor with fluid recipes behind pattern providers.
It checks that the tank drains into the network and the export interface holds its level (fluid
conserved, totals and capacity right), that the export never overfills and re-imports when
switched, that a drive picked up by script and by robots (deconstruction, then a ghost) carries
its contents on the item and brings them back (and that the loaded item survives a trip through
the terminal), that full drives stop the import and keep the fluid in the tank while the panel
reports it, that a reactor with a pipe on its input is counted under `fluid-pipes` and not a
pattern, that a too large request reports the missing chlorine and raw silicon exactly, that
three jobs (fluid in and out, fluid out only, fluid in only) finish with the expected amounts and
empty machines, and that a reactor mined by robots while it holds a job's chlorine gives it back.
See `tools/devcheck/README.md`.
