# AE2 in Gregtorio: ME network, autocrafting, fluids and automation

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
| ME Crafting CPU, Co-Processing and Quantum Crafting CPU | run autocrafting jobs: 1, 2 or 4 at once (this page, **CPU tiers**) |
| ME Level Maintainer | keeps an item or fluid in stock by autocrafting (this page, **Keeping items in stock**) |
| ME Circuit Interface | puts the network contents onto a circuit wire (this page, **Circuit network**) |

Techs: `me-network` (MV), `me-storage-64k` (EV), `me-storage-256k` (IV), `me-autocrafting` (EV),
`me-fluid-storage` (EV), `me-fluid-storage-256k` (IV), `me-automation` (EV), `me-co-processing` (IV),
`me-quantum-crafting` (LuV).

## Autocrafting: how to build it

Tech `me-autocrafting` (EV, needs `me-storage-64k`) unlocks three entities:

| Entity | What it does |
|---|---|
| **ME Molecular Assembler** | assembling machine for item-only crafting recipes (crafting table and assembler recipes up to EV, no fluid boxes), speed 6, 960 kW |
| **ME Pattern Provider** | 1x1 marker, no power. Placed **next to a machine**, the recipe that machine has set becomes a pattern of the network; for furnaces you choose the recipe in the provider |
| **ME Crafting CPU** | 2x2, needs power (60 kW), part of the network. Runs one job at a time (bigger CPUs: see [CPU tiers](#cpu-tiers)) |

Step by step:

1. Build an ME network: ME Controller (powered), at least one ME Drive with items in it,
   an ME Terminal (powered) inside the controller's area.
2. Place an **ME Crafting CPU** in the area and power it. One CPU = one job at a time; a second
   CPU, or a bigger one, lets two jobs run in parallel.
3. For every recipe the network should be able to craft, place a machine **inside the area**,
   give it power and set the recipe, then put an **ME Pattern Provider on a tile touching the
   machine** (left, right, above or below). Any assembling machine or furnace works: a
   Molecular Assembler for crafting recipes, a GT machine (macerator, EBF, wiremill, chemical
   reactor, ...) for processing recipes. One provider can serve up to four machines around it.
   Furnaces have no recipe setting: see [Furnaces as pattern machines](#furnaces-as-pattern-machines).
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
  A furnace without a recipe (no choice in its provider, never smelted anything) is counted as
  `no-recipe` in the crafting tab's info line.
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

### Furnaces as pattern machines

A furnace (stone, iron or steel furnace, any `furnace` type machine) has no recipe setting: it
picks the recipe from the item in its input slot. So the **pattern provider holds the recipe**:

1. Place the furnace (with fuel or power) and an ME Pattern Provider touching it, inside the network.
2. Point at the provider and press the normal **open** key (left click by default). The window
   lists every recipe the furnaces next to it can make: their crafting categories, researched
   recipes only, no hidden and no fluid recipes.
3. Click a recipe. It is the pattern at once, the furnace does not have to smelt it first.
   Clicking the chosen recipe again, or **Clear**, removes the choice.

The choice belongs to the provider and applies to every furnace next to it that can make the
recipe; a furnace that cannot make it keeps the recipe it smelted last. It is kept in the save,
copied with the provider's settings (shift right click on it, shift left click on another
provider), stored in blueprints and copied when a provider is cloned. Without a choice the
furnace's last smelted recipe is used (`previous_recipe`), as before; a furnace with neither is
counted as `no-recipe`.

While a job runs the network puts only the chosen recipe's ingredient into the furnace and
collects the products, exactly as for an assembling machine. The furnace itself still picks the
recipe from that ingredient: if another recipe of that furnace has the same input, it may smelt
that one instead. The window marks such recipes, and a job whose furnace smelts another recipe
fails ("a furnace smelted another recipe with the same input") and returns its items. None of the
current smelting recipes share an input.

## CPU tiers

Two bigger Crafting CPUs (issue #38) run several jobs at once and hand work to the pattern machines
faster. They are 2x2 like the ME Crafting CPU, need power, and belong to the network they stand in.

| Entity | Tech (tier) | Jobs at once | Speed | Power | Recipe (main parts) |
|---|---|---|---|---|---|
| ME Crafting CPU | `me-autocrafting` (EV) | 1 | 1x (6 machine hand-overs per job every 20 ticks) | 60 kW | EV hull, ME controller, 2 64k cells |
| **ME Co-Processing Crafting CPU** | `me-co-processing` (IV, after `me-storage-256k` and IV components) | 2 | 2x | 240 kW | ME Crafting CPU, IV hull, 2 256k cells, 4 acceleration cards, 4 IV circuits (IV assembler) |
| **ME Quantum Crafting CPU** | `me-quantum-crafting` (LuV, after `me-co-processing` and LuV machines) | 4 | 4x | 960 kW | Co-Processing CPU, LuV hull, 2 LuV emitters, 8 acceleration cards, 4 LuV circuits (LuV assembler) |

* The job slots of all CPUs in the network are the number of jobs that run at once. The crafting
  tab shows them: `Crafting CPUs: 1, job slots: 2 (free: 1)`. A new job takes the fastest CPU with a
  free slot; with none free it waits (`Waiting for a free CPU`).
* **Speed** is how many machines a job can load and empty per step. It matters when a job has many
  pattern machines for the same recipe: a job on the base CPU keeps about 18 machine hand-overs per
  second going, on a Quantum CPU four times that. The machines still craft at their own speed.
* **Upgrading:** the upgrade planner (or fast replace by hand) swaps a CPU for the next tier. A job on
  the replaced CPU pauses for a moment and goes on on the new one (or on any other free slot), with
  everything it holds.

## Keeping items in stock: ME Level Maintainer

Tech `me-automation` (EV, needs `me-autocrafting` and Circuit network). The **ME Level Maintainer** is
a 1x1 block that needs power (30 kW) and stands in the network.

1. Place it inside the network area and power it. Autocrafting must work for the resource: a pattern
   (provider next to a machine with the recipe) and a Crafting CPU.
2. Open it (the lamp window opens with a panel **ME Level Maintainer** next to it). Choose the item or
   fluid in the signal button and type the amount to keep (items, or fluid units).
3. When the network holds less than that amount, the maintainer starts a crafting job for the
   difference, the way the Craft button does. It checks about once a second (several maintainers take
   turns, see **Design**).
4. While that job runs, it starts no other one; nor does it while any other job of the network crafts
   the same resource (for example one you started in the terminal). When the job is done and the stock
   is reached again, it waits until the stock drops.

What the panel says:

| Status | Meaning |
|---|---|
| Enough in stock | nothing to do |
| Crafting job N is running | its job; the progress is also in the terminal's job list |
| Another job of this network is crafting it | waits for that job |
| Waiting for a Crafting CPU with a free job slot | all slots are busy: the maintainer does not queue jobs, it waits and tries again |
| Cannot craft the difference, missing: ... | the plan lacks raw materials; it tries again every 5 seconds |
| No pattern for this item or fluid | no machine with that recipe behind a provider |
| Switched off by the circuit condition | see below |

**Circuit network** (connect a red or green wire to the maintainer):

* **On/off:** the lamp window's circuit condition ("Enable/disable") switches the maintainer. While
  the condition is false it starts nothing; a running job goes on.
* **Amount from the circuit:** tick the box in the panel. The signal of the chosen item or fluid on
  the wires (red plus green) is then the amount to keep, instead of the number field. No signal means
  0 (keep nothing).

**Copying:** shift right click and shift left click copy the resource, amount and circuit option to
another maintainer (the game copies the circuit condition). Blueprints, copy and paste (ctrl+C, ctrl+V)
and cloning keep them.

## Circuit network: ME Circuit Interface

Tech `me-automation`. The **ME Circuit Interface** is a constant combinator (no power) inside the
network area. Connect red or green wires to it: they carry

* every item of the network (with its quality) and every fluid, fluids rounded down to whole units,
  or
* only the resources chosen as **filters**: open it, the panel **ME Circuit Interface** next to the
  combinator window has 20 signal buttons. Items and fluids only; without filters everything is sent.

The signals are refreshed about once a second (with more than six interfaces a little less often: two
of them are refreshed every 20 ticks, in turns). The network writes the combinator's signal list: entries
added by hand are replaced, extra sections are removed; the combinator's on/off switch still turns the
output off. Filters are copied by settings paste and kept in blueprints, copy and paste, and clones. The ME
Controller's own circuit connection still reads the items of the network (roboport behavior); the
Circuit Interface adds the fluids and the filter. Up to 1000 signals per interface (the largest amounts
first).

## Settings in blueprints and copy/paste

| Entity | Settings | Settings paste | Blueprint, copy/paste, clone |
|---|---|---|---|
| ME Pattern Provider | furnace recipe choice | yes | yes |
| ME Fluid Interface | import/export, fluid, fill level | yes (shift right click, shift left click) | yes (since issue #38) |
| ME Fluid Drive | none: no filters or partitions; its contents are fluid, not settings | - | the contents stay on the drive item (see **Fluids**) |
| ME Level Maintainer | resource, amount, amount from the circuit; the lamp's circuit condition | yes | yes |
| ME Circuit Interface | filters | yes | yes (the signals of the moment in a blueprint are rewritten when it is built) |

## Fluids

Tech `me-fluid-storage` (EV, needs `me-autocrafting`) unlocks fluid storage cells and ME Fluid
Drives from 1k to 64k and the ME Fluid Interface; `me-fluid-storage-256k` (IV, also needs
`me-storage-256k`) the 256k cell and drive (`prototypes/122-fork-ae2-fluids.lua`).

| Thing | What it is |
|---|---|
| **Fluid storage cell** (1k ... 256k) | storage housing + storage component of the tier + a pump. Holds 8000 fluid units per "1k" |
| **ME Fluid Drive** (1k ... 256k) | 1x1, no power, four cells on a drive chassis: 32 000 / 128 000 / 512 000 / 2 048 000 / 8 192 000 units. Takes any fluids of the network in any mix; the disassembly recipe (hand crafting only) gives the cells back, the fluid of a loaded drive item is recovered (see below); recyclers do not take drives |
| **ME Fluid Interface** | 1x1 tank of 5000 units with a pipe connection on every side: the import/export point |

Step by step:

1. Place ME Fluid Drives inside the network area (ME Controller or roboport coverage), like ME
   Drives. The storage tab of the ME Terminal shows `Fluids: used of capacity` as soon as a drive
   is there. The upgrade planner (or fast replace by hand) swaps in bigger drives and keeps their
   fluid (see "Upgrading a drive" below).
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
deconstructed drive, on a space platform; checked for robots). Picking up a fluid interface moves
what it holds back into the network (as far as the drives have room).

**Upgrading a drive** (the upgrade planner with robots, also on a space platform, or fast replace by
hand: placing another drive onto a drive) moves its fluid into the **new** drive. If the new drive is
smaller and cannot hold all of it, the rest goes into the other fluid drives of the network, and what
still does not fit becomes recovered fluid (see below); the chat says which. The old drive item comes
back without fluid.

**A destroyed drive** (biters, an explosion, a script) loses nothing:

1. The other fluid drives of its network take its fluid, as far as they have room.
2. What does not fit (or everything, if the drive stood outside any network) is kept as
   **recovered fluid** of that surface, together with the place it came from.
3. The fluid drives of the same network take the recovered fluid over by themselves as soon as
   they have room (an export took fluid out, a drive was upgraded or added), a few entries every
   quarter second; the chat reports it once when all of an entry is back. A fluid drive placed in
   that network takes it over at once, as far as it has room. Robots rebuilding the ghost of the
   destroyed drive do exactly that, so a network with construction robots and a spare drive item
   repairs itself. If no network covers that place any more (the roboports burnt down too), the
   recovered fluid waits for the next fluid drive placed anywhere on the surface.
4. The "open GUI" key on any fluid drive shows the recovered fluid of the surface with a
   **Take over** button, which moves all of it (from any network) into that drive.

Every step is reported in the chat with a map link: what went into other drives, what was kept as
recovered fluid, what a drive took over. Recovered fluid is only lost when its surface is deleted,
and that is reported too. The same happens to a drive removed by another mod without an event: its
fluid is kept as recovered fluid as soon as the network is next looked at.

**Taking the cells out of a loaded drive item** (the disassembly recipe) works by hand only. The
drive's fluid goes into the fluid drives of the network you stand in, as far as they have room; the
rest becomes recovered fluid (as above), and the chat says which. The item comes back without its
fluid. Assemblers cannot run the disassembly, because the mod cannot see the fluid of an item an
assembler consumes.

**Blueprints** do not carry fluid: fluid contents are not blueprint data. A drive built from a
blueprint (or a copy-paste) starts empty, apart from the recovered fluid it takes over; only the
drive item carries fluid, on its tags. The **settings** of a fluid interface (import or export, fluid,
fill level) are kept in blueprints and copied by settings paste and cloning (issue #38); a drive has no
settings.

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

**Recovery** (`storage.fork_me_fluids.recovered`: surface index -> force name -> list of
`{ position, contents }`). `on_entity_died` and `script_raised_destroy` drop the drive's record
first, then `salvage` inserts its contents into the drives of the logistic network at its position
(the same `insert` as the interfaces) and adds the rest as an entry. An entry takes the fluid of
every later salvage in the same network (or at the same spot); at most 32 entries per surface and
force, more are merged into the last one. Networks have no stable identity (the network id changes
when networks merge or split, and an attack often takes the roboports with it), so an entry stores
its position and the network is looked up when a drive is placed: the drive takes the entries whose
position lies in its own network, or in no network at all. Placing a drive restores the item's
tags first, then the contents of a drive it replaced (see **Upgrades**), then takes recovered fluid.
The drive GUI's button takes every entry of the surface. The fluid step also pulls entries into the
drives that already stand in their network: `RECOVERED_PER_STEP` (4) entries per step, round robin
over every surface and force (cursor `rcursor`), each into the drives of the network its position
lies in now (the per-step drive list cache of the interfaces, so a network's drives are listed once
per step), with the same `insert`. Entries without a network or without room there are skipped. An
entry sums what it gave away in `moved`; when it is empty it is reported once with that sum and
dropped.
A drive record whose entity became invalid without any event is salvaged into an entry at its
stored position the next time a network total is computed (records carry surface, force and
position; records from older saves get them on the fly). `on_pre_surface_deleted` drops the
surface's drives and entries and reports the amounts as lost. The hand disassembly uses
`on_pre_player_crafted_item`: the consumed drive items are replaced by the same items without tags
and their fluid is salvaged at the player's position; `on_player_cancelled_crafting` strips the
tags from returned drive items, so a cancelled craft cannot hand the fluid out twice. Everything is
exposed on the remote interface for the tests (`recovered`, `salvage_items`, `take_recovered`).

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

### Upgrades

Factorio 2.0 does not tell a script which entity replaced which: the built events have no
"replaced entity" field and there is no upgrade event that carries both entities
(`on_marked_for_upgrade` only marks). The old drive is mined and the new one built at the same
position of the same surface and force in the same tick, so the script links them by **spot**. The
runtime test logs the robot event order (`DEVCHECK-RUNTIME-UPGRADE-EVENTS` in the log):

| Path | Events | The mined drive counts as replaced when |
|---|---|---|
| Upgrade planner, robots (bigger or smaller drive) | `on_robot_mined_entity` (old), then `on_robot_built_entity` (new), same tick; no `on_robot_pre_mined` | `entity.to_be_upgraded()` is still true in the mined event (a deconstruction gives false) |
| Upgrade planner on a space platform | `on_space_platform_mined_entity`, then `on_space_platform_built_entity` | the same (`to_be_upgraded()`) |
| Fast replace by hand (also onto a drive marked for upgrade) | `on_pre_build` (player, position of the new entity), `on_player_mined_entity` (old), `on_built_entity` (new), same tick | the same player had an `on_pre_build` in this tick whose position lies on the mined drive |

A drive that counts as replaced puts nothing onto its item. Its contents are held in
`storage.fork_me_fluids.replacing["surface:x:y"]` (with force, tick and name), and the drive built at
that spot takes them in `on_built` (any build path), as far as it has room; the rest goes through
`salvage` (the network at that spot, then the recovered fluid) and is reported. Held contents that no
drive took (the build did not happen) are salvaged the same way by the next fluid step, so nothing is
lost. Should the hand path ever raise the mined event before `on_pre_build`, the drive would not count
as replaced and its fluid would go onto the old item as before: no loss and no duplication either.

### Patterns

`storage.fork_ae2.providers` lists every provider. A provider looks at the four tiles around it
(`find_entities_filtered` on the tile centers), collects the assembling machines and furnaces
found there that are in the same logistic network, and reads their recipe (`get_recipe()`). For
furnaces the provider's recipe choice (`providers[unit].recipe`) counts when the furnace can make it
(category, researched, no fluid) and holds nothing: a furnace that holds or smelts something counts
with the recipe it runs, so a job notices when the furnace picked another recipe. Without a choice
`previous_recipe` is used; a furnace with no recipe at all is counted under `no-recipe`. The
choice is set by `set_recipe` (GUI, settings paste, the blueprint tag `fork_ae2_recipe` on build,
cloning; the remote interface has the same function), survives `on_configuration_changed`, and
leases keep the choice they were started with. From all providers of a network the script builds
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

### CPU tiers (issue #38)

The tier numbers come from the mod-data `fork-me-autocraft` (`cpus[name] = { jobs, speed }`, written by
`prototypes/121-fork-ae2-autocrafting.lua`), so the runtime has no copy of them. A CPU record holds the
jobs it runs (`cpus[unit].jobs = { [job id] = true }`; a record of an older save with a single `job` is
converted when it is first read). `assign_cpus` gives a queued job the fastest CPU of its network with
fewer jobs than slots. A job's machine interactions per step are `STEP_OPS` (6) times the speed of its
CPU, and all jobs of one step share `MAX_OPS_PER_STEP` (96, four Quantum jobs at full speed): what a job
does not use goes back to the step's budget. A CPU that is replaced or removed releases its jobs, which
queue and take the next free slot (the path the existing CPU test covers).

### Level maintainer and circuit interface (issue #38)

`scripts/fork-me-circuit.lua` keeps `storage.fork_ae2.maintainers` / `mlist` / `mcursor` and `circuits` /
`clist` / `ccursor` (created lazily) and runs as a step hook of the autocrafting step (every 20 ticks).

* **Maintainer check** (4 per step, round robin): no resource, no power, `cb.disabled` of the lamp's
  control behavior while its circuit (or logistic) condition is switched on (a freshly wired lamp reads
  `disabled` until its next circuit update, so the flag alone is not trusted), no network: status only. Otherwise the target is the amount,
  or the resource's signal on red plus green (`get_circuit_network(wire).get_signal`). The stock is
  `get_item_count` (normal quality) or the fluid drives' count. Its own job still queued or running:
  nothing. Stock below target: if an active, not closing job of the network crafts the same key
  (`active_job_for`), nothing; else, if a powered CPU has a free slot (`free_slot`), `M.start` with the
  difference and the maintainer's unit number as the job's `owner`. At most one start per step (a start
  rescans the providers and plans); a failed start (missing, no pattern) waits `RETRY_TICKS` (300).
* **Circuit interface update** (2 per step, round robin): the network's `get_contents()` (with quality)
  and fluid totals (floored, at least 1 unit), filtered by key, sorted by amount, at most 1000, are
  written as the filters of section 1 of the combinator's control behavior; other sections are removed.
* **Settings copy:** blueprint tags `fork_me_maintainer` (`{ key, amount, circuit }`), `fork_me_circuit`
  (`{ filters }`) and `fork_me_fluid_interface` (`{ mode, fluid, level }`), written by the one
  `on_player_setup_blueprint` handler (autocrafting module: providers, then `fluids.tag_blueprint`, then
  the blueprint hooks) and read in the built events from `event.tags`; `on_entity_settings_pasted` and
  `on_entity_cloned` copy the records. The fluid interface prototype lists itself in
  `additional_pastable_entities`, since a storage tank has no settings of its own.
* **GUI:** relative panels on the lamp GUI (maintainer) and the constant combinator GUI (interface),
  refreshed every step while open. All GUI events are registered once in the terminal module, which
  routes them to the fluids and circuit modules.

### Throughput and UPS

* One shared autocrafting step every 20 ticks (`on_nth_tick(20)`; the fluid interfaces use 15,
  the molds 30, the terminal refresh 60).
* At most 8 jobs per step (round robin), at most 6 machine hand-overs/collections per job per step
  on the base CPU (12 on a Co-Processing, 24 on a Quantum CPU), at most 96 for all jobs together, so a
  base CPU job moves up to about 18 machine interactions per second. That matches an assembler line
  and keeps a step cheap; a job with more machines is throttled by the CPU, a faster CPU lifts it.
* Level maintainers and circuit interfaces run in the same step: 4 maintainer checks (cheap: a count
  and a few table lookups) with at most one job start per step (the only expensive part: a provider
  rescan and a plan, like the Craft button; a failed start waits 5 seconds), and 2 circuit interface
  updates (one `get_contents()`, the fluid totals and one write of the section each).
* 8 provider rescans per step, planning only on user actions (terminal GUI: while a craft item is
  selected, once per second from the cache).
* The fluid step every 15 ticks handles at most 8 interfaces (one `remove_fluid` or
  `insert_fluid` each), at most 4 recovered entries (nothing when there is no recovered fluid) and
  the open drive and interface panels. A network total loops over the
  fluid drives (a few hundred at most, once per network and step), never over tanks or pipes.
* No per-tick loops, no loops over the whole network. State lives in `storage.fork_ae2` and
  `storage.fork_me_fluids`; GUI state (selected resource, amount) lives in the GUI elements.

### Existing saves and mod updates

Nothing changes for existing ME networks. `on_configuration_changed` rebuilds the provider and
CPU registries from the world (`find_entities_filtered`), repairs leases and job books and
keeps jobs and their pools; leases from before fluid support get empty fluid maps, providers are
rescanned.
CPU records of older saves hold one `job`; they are rebuilt (`jobs = {}`) and the jobs reassigned, and a
record read before the rebuild is converted on the spot (`migrate --from-ref v0.3.1` starts a job with
the old version and checks that it finishes after the update). Level maintainers and circuit interfaces
are new, their state is created lazily and rebuilt from the world (settings kept by unit number).
The fluid state is created lazily; its rebuild (run first, autocrafting reads it) finds the fluid
drives and interfaces in the world, keeps drive contents by unit number (clamped to the capacity)
and interface settings, and closes open fluid panels. Recovered fluid is created lazily as well;
the rebuild drops entries of fluids, surfaces or forces that no longer exist. Loaded fluid drives
of an older save keep their contents (`devcheck.py migrate` builds such a save with the old
version and checks it). The layout of `storage.fork_me_fluids` is unchanged; the pull-in cursor, the
held contents of replaced drives and the players' last build spots are added lazily (held contents
never outlive a tick; a configuration change salvages any that are left). Recovered fluid of an older
save is kept and pulled into its network's drives like new entries (`migrate --from-ref v0.3.1`).

## Limits and open points

* One temperature per fluid: stored by name, exported at the default temperature. Hot steam loses
  its heat; recipes that need another temperature are not patterns.
* Drive contents are not part of blueprints: a drive built from a blueprint starts empty, only
  the item's tags carry fluid. A destroyed drive's fluid is recovered (see **Fluids**): the drives
  of its network pull it in when they have room (4 entries per quarter second), a newly placed drive
  takes it at once, the Take over button from any network.
* Upgrades are linked by spot and tick (see **Upgrades**). The robot upgrade and downgrade run in
  the engine in the headless test; the hand fast replace is tested through the same functions in the
  engine's order (no player in a benchmark run) and is untested in the real game, like the chat reports.
* No per-drive limits on fluid types (no partitioning, no filters, unlike AE2 cells): every drive
  takes every fluid; `insert` prefers drives that already hold it.
* The export level applies to the interface's own box; pipes and tanks connected without a pump
  share that level, so the segment holds more than `level` in total. Put a pump behind the
  interface to fill a tank.
* The fluid interface has no circuit connection; the fluid totals reach the circuit network through
  the ME Circuit Interface (issue #38).
* The disassembly recipe is hand crafting only (the fluid of a loaded item is recovered); a
  cancelled hand disassembly returns the drive item without its fluid, which stays recovered.
  Untested in the real game: the headless test calls the same function the craft event calls.
* Only normal quality, no items with own data (armor, tools) and no spoilage handling in the pool.
* A furnace picks its recipe from its input: if two recipes it can make share an input, the
  network cannot force the chosen one (the job fails and returns its items). The provider window,
  settings paste and blueprint event are untested in the real game (the headless test calls the
  same functions).
* CPU tiers (issue #38) add parallel jobs and speed, not storage: a job's size is not limited by its
  CPU (AE2's crafting storage has no counterpart). The level maintainer keeps one resource per block;
  a circuit signal sets its amount or switches it, but there is no "craft what the circuit asks for"
  request of several resources at once. The maintainer and circuit interface panels, the lamp's circuit
  condition in the real lamp GUI, settings paste by hand and the upgrade planner on CPUs are untested in
  the real game (the headless test calls the same functions).
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

A furnace network (issue #27) has two fresh iron furnaces with providers: both must be counted as
`no-recipe`, the recipe options must list only researched smelting recipes, and after the choice
(`set_recipe`, the function the GUI calls) one furnace must be a pattern at once, smelt a job and
leave the ingots in storage with empty furnace slots. Then the choice is pasted onto the other
provider, cleared (the last smelted recipe keeps the furnace a pattern), stored in a blueprint as
entity tag, and restored on a provider revived from a tagged ghost.

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

A third network tests the recovery: two loaded 1k drives, one of them destroyed (the other takes
what fits, the rest becomes recovered fluid, totals conserved), its ghost rebuilt by robots (the new
drive takes the recovered fluid over), the upgrade planner on a loaded drive (robots: the new 4k
drive holds all of the fluid, the old item comes back into storage without tags), the cells taken out
of a loaded item inside the network (all fluid in the drives, the item without tags) and outside of
any network (all recovered, then taken over), a loaded drive removed without an event, and a
destroyed drive on a second surface that is then deleted. Then the pull-in (issue #43): the network is
filled up, a disassembly's chlorine is recovered (no room), an export interface takes 5000 water out,
and the drives must pull the chlorine in by themselves (drives + interface + recovered fluid conserved
at every check). The upgrade planner then downgrades the full 4k drive to a 1k (robots): the new drive
holds 32000, the network's last room is filled, the rest is recovered, the old 4k item has no tags.
Last, a hand fast replace of the other drive by a 4k (`on_pre_build`, the mined event with the old
item in its buffer, then the build, in the engine's order through the remote interface): the old item
has no tags, the new drive holds the old drive's fluid and then the recovered fluid of its network,
and the whole amount is conserved. `devcheck.py migrate --from-ref v0.3.0` builds loaded fluid drives
with 0.3.0 and checks them (and the recovery) after the update; from v0.3.1 on the old save also holds
recovered fluid, which must be kept, and after 5000 water leave the network the recovered water of a
destroyed drive must be pulled in.
Issue #38 (four more networks right of the machine grid): a level maintainer that keeps 10 gears, in a
network with two free job slots, must start exactly one job for 10, never have two active gear jobs, start
nothing while the stock holds (120 ticks), start one job for exactly the difference after 3 gears are taken
out, take 14 from a constant combinator's signal with "amount from the circuit", start nothing while the
lamp's circuit condition is false and start the job for 20 once it is true. A Co-Processing CPU runs two gear
jobs at once (both running at the start, both with a machine crafting at the same time, 12 hand-overs per
step, no free slot), a third job waits and is cancelled, and a Quantum CPU put in its place has four slots.
A circuit interface wired to a pole must carry exactly the network's items and floored fluids (500.5 water
is 500), then only its two filters, then follow 25 more plates. The settings of a maintainer (a fluid, 1234,
circuit), a circuit interface (two filters) and a fluid interface (export water 2345) must be blueprint
tags, come back on the entities built from that blueprint and revived, and be copied by settings paste and
by cloning. `devcheck.py migrate` checks a job started by the old version.
See `tools/devcheck/README.md`.
