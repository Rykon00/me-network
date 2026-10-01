# AE2 in Gregtorio: ME network, autocrafting, fluids and automation

## What the ME network is

Since issue #68 (step R1) the ME network plays like Applied Energistics 2: ME blocks connected by ME
cables, storage cells in drives, a terminal as the central window (`prototypes/120-fork-ae2.lua`,
`scripts/fork-me-network.lua`; the design and its reasons: `docs/ME-REWORK.md`). It has nothing to do with
Factorio's logistic network any more.

| Entity | Role |
|---|---|
| ME Cable | placed with the **fluix cable** item; connects ME blocks on all four sides; can be walked over |
| ME Underground Cable | rotatable pair (MV, `me-network`, 8 fluix cables + 2 aluminium plates -> 2): carries the network under up to 10 tiles to the first underground cable facing it, like an underground pipe; above ground an end connects only on the side opposite its arrow; a dashed line on the ground shows a connected pair; can be walked over |
| ME Controller | 2x2, needs power; exactly one per network runs it (two are a conflict) |
| ME Drive | 1x1, holds up to 10 storage cells |
| Storage cell (1k ... 256k) | holds the items (AE2 bytes and types); keeps them when taken out of the drive |
| ME Terminal | powered screen: the network's contents, take and store items, **crafting** |
| ME Interface | 1x1 with 18 slots: filtered slots are kept filled from the network, everything else is imported |
| ME Import Bus, ME Export Bus | 1x1, rotatable: pull items out of / put items into the machine or chest they face |
| Fluid storage cell (1k ... 256k) | holds fluids in an ME Drive, like an item cell (this page, **Fluids**) |
| ME Fluid Interface | small tank: import/export point for fluids |
| ME Fluid Import Bus, ME Fluid Export Bus | 1x1, rotatable: take fluid out of / put fluid into the machine or tank they face |
| ME Crafting CPU, Co-Processing and Quantum Crafting CPU | run autocrafting jobs: 1, 2 or 4 at once (this page, **CPU tiers**) |
| ME Pattern Provider | makes the recipe of the machine next to it a pattern (this page, **Autocrafting**) |
| ME Level Maintainer | keeps an item or fluid in stock by autocrafting (this page, **Keeping items in stock**) |
| ME Circuit Interface | puts the network contents onto a circuit wire (this page, **Circuit network**) |

Techs: `applied-energistics-components` (MV, upstream: fluix cable, ME Controller, ME Interface),
`logistic-system` (the ME Drive), `me-network` (MV: terminal, 1k/4k/16k cells, buses), `me-storage-64k` (EV),
`me-storage-256k` (IV), `me-autocrafting` (EV), `me-fluid-storage` (EV), `me-fluid-storage-256k` (IV),
`me-automation` (EV), `me-co-processing` (IV), `me-quantum-crafting` (LuV).

## Building a network

1. Place an **ME Controller** and give it power (120 kW, plus 4 kW for every drive, interface, bus, pattern
   provider, circuit interface and fluid block of the network; cables, terminals, CPUs and level maintainers
   have their own power connection).
2. Connect everything else with **ME cables**: a cable connects on all four sides, and ME blocks that touch
   each other connect without a cable (a row of drives next to the controller is one network). Corners do not
   connect. Everything connected is one network. The cable picture shows its connections.
3. Place **ME Drives** and put **storage cells** into them (see below), and an **ME Terminal** (powered).
4. Import and export with **ME Interfaces** (inserters, belts) or **buses** (directly on a machine or chest).

The terminal's status line (and the ME Controller's status) tells what is wrong:

| Status | Meaning |
|---|---|
| Working | one controller with power |
| No controller | no ME Controller in this network (a cable gap?) |
| Controller conflict | more than one ME Controller in this network: remove one |
| No power | the controller has no power |

A network that does not work stores nothing and gives nothing: interfaces and buses wait, crafting jobs wait
("No ME network"), the circuit interface sends nothing. Nothing is lost: the items stay in their cells.

There are no channels (AE2's 8 or 32 devices per cable): any number of blocks on any cable. The controller's
power draw grows with the network instead (see `docs/ME-REWORK.md`, "Channels: none").

## Storage cells and the ME Drive

A storage cell holds items virtually; its capacity is AE2's:

| Cell | Bytes | Bytes per type | Types | Items of one type |
|---|---|---|---|---|
| 1k | 1 024 | 8 | 63 | 8 128 |
| 4k | 4 096 | 32 | 63 | 32 512 |
| 16k | 16 384 | 128 | 63 | 130 048 |
| 64k | 65 536 | 512 | 63 | 520 192 |
| 256k | 262 144 | 2 048 | 63 | 2 080 768 |

Every item type in a cell costs its bytes per type, and every 8 items of it one byte. Another quality of an
item is another type. A network fills cells that already hold an item first, then cells with a free type.

* **Putting a cell in:** open the ME Drive (normal open key) and click a slot with the cell in hand, or click the
  drive itself with a cell in hand (first free slot). Only storage cells go into a drive (10 slots).
* **Taking it out:** click a filled slot (the cell goes into your hand; shift click: into your inventory). The
  cell keeps its items: its tooltip lists them ("1234 items of 5 types: ..."). Put it into any drive of any
  network and the items are there again.
* **Fill lights:** each cell in a drive shows a light on the drive: green while it has room, orange above 75 %
  of its bytes, red when it is full (bytes or types). The drive window shows bytes and types per slot.
* **Mining a drive** gives the drive and its cells with their items. **A destroyed drive** drops its cells
  (with their items) on the ground. Blueprints and copies of a drive come without cells.
* Cells can be stored in the network like any item; one that holds items is stored with them.
* **Not storable:** items with an inventory or equipment grid, blueprints and planners, items that spoil
  (the network would stop their decay), damaged items and partly used tools or ammunition.
* **Old drive items** (ME Drive 1k ... 256k from before the rework) cannot be crafted any more; placing one
  builds an ME Drive with its four (empty) cells, the 256k one also gives its acceleration card back.

## ME Terminal

Needs power and a working network. Its window:

* **Status line:** bytes and types used of the network's cells, drives and cells, the controller's power.
* **Storage tab:** search (by the item's internal name) and sort (by amount or by name) the item grid.
  **Left click** an item: a stack into your hand; with something in hand, the click stores that instead.
  **Right click**: one item into your hand (one more of the same item). **Shift click**: a stack into your
  inventory. Items with tags (loaded cells) have a yellow frame. After the items, the fluids of the fluid cells
  with their amounts (they cannot be taken by hand). Below: **your inventory**: click an item there to store all of it, right click to
  store one stack. "Store item in hand" stores the cursor.
* **Crafting tab:** see **Autocrafting** below.

## Import and export

**ME Interface** (18 slots, like a chest for inserters and belts). Middle click a slot to give it a filter (the
normal slot filter of the game). A **filtered slot** is an export slot: the network keeps it filled with its
item up to a stack, and inserters take the items out. Every **unfiltered slot** is imported: whatever inserters
put in goes into the network (items the network cannot store stay in the slot). The filters are kept in
blueprints and copied with the entity settings (shift right click, shift left click).

**ME Import Bus / ME Export Bus** face one machine or chest (rotate them; the plate and the arrow show the
side). Open one to set up to 5 item filters.

| Bus | Takes from / puts into | Filters |
|---|---|---|
| Import | the output of an assembler or furnace, or any slot of a chest, into the network | only those items; none: everything |
| Export | from the network into the input of an assembler or furnace (up to a stack of each filtered item) or a chest | the items to export (none: nothing) |

A bus moves up to 64 items per visit, an interface handles up to 8 slots per visit; every interface and bus is
visited about every quarter second while there are fewer than 24 of them (more: each less often).

## Old saves (from before the rework)

Old ME networks are converted when the save is loaded (`docs/ME-REWORK.md`, "Migration"): the old controller
becomes an ME Controller, every old drive an ME Drive with four cells of its tier holding its items, every old
interface an ME Interface (its items go into the network), and ME cables are laid from the controller to every
block of the old network. Further old controllers of the same network become items in the network. Items the
new cells cannot hold go into iron chests next to the controller (the chat names them). A block that no cable
can reach (walled in, on water) is named in the chat: connect it yourself. Items in vanilla chests of the old
logistic network stay there. The game removes ghosts of the old blocks when the save is loaded.

## Autocrafting: how to build it

Tech `me-autocrafting` (EV, needs `me-storage-64k`) unlocks three entities:

| Entity | What it does |
|---|---|
| **ME Molecular Assembler** | assembling machine for item-only crafting recipes (crafting table and assembler recipes up to EV, no fluid boxes), speed 6, 960 kW |
| **ME Pattern Provider** | 1x1 marker, no power. Placed **next to a machine**, the recipe that machine has set becomes a pattern of the network; for furnaces you choose the recipe in the provider |
| **ME Crafting CPU** | 2x2, needs power (60 kW), part of the network. Runs one job at a time (bigger CPUs: see [CPU tiers](#cpu-tiers)) |

Step by step:

1. Build an ME network: ME Controller (powered), at least one ME Drive with cells and items, an ME
   Terminal (powered), all connected.
2. Connect an **ME Crafting CPU** to the network and power it. One CPU = one job at a time; a second
   CPU, or a bigger one, lets two jobs run in parallel.
3. For every recipe the network should be able to craft, place a machine, give it power and set the
   recipe, then put an **ME Pattern Provider on a tile touching the machine** (left, right, above or
   below) and connect the provider to the network (the machine itself needs no cable). Any assembling machine or furnace works: a
   Molecular Assembler for crafting recipes, a GT machine (macerator, EBF, wiremill, chemical
   reactor, ...) for processing recipes. One provider can serve up to four machines around it.
   Furnaces have no recipe setting: see [Furnaces as pattern machines](#furnaces-as-pattern-machines).
4. Open the ME Terminal, tab **Crafting**: every item and fluid a pattern can make is listed
   (also at 0 in stock). Click one, enter an amount (items, or fluid units), and read the plan line:
   `Ready: 12 crafts in 3 steps. Taken from storage: ...` or `Missing: 12x tin cable, 400 chlorine`.
   With something missing the Craft button stays disabled. Click **Craft**; the job appears
   in the job list with its progress and a **Cancel** button.
5. When the job is done, the result (and any by-products) is in network storage: items in the
   cells of the ME Drives (items in item cells, fluids in fluid cells).

Rules for pattern machines:

* **Dedicate them to the network.** While a job runs the CPU puts ingredients into the machine
  and takes its products out. Do not feed them with inserters, belts or pipes as well.
* A machine without a recipe, a provider that is not connected to the network, or a provider that
  touches no machine is ignored.
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

1. Place the furnace (with fuel or power) and an ME Pattern Provider touching it, connected to the network.
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
a 1x1 block that needs power (30 kW) and is a member of the network.

1. Connect it to the network and power it. Autocrafting must work for the resource: a pattern
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

Tech `me-automation`. The **ME Circuit Interface** is a constant combinator (no power) connected to the
network. Connect red or green wires to it: they carry

* every item of the network (with its quality) and every fluid, fluids rounded down to whole units,
  or
* only the resources chosen as **filters**: open it, the panel **ME Circuit Interface** next to the
  combinator window has 20 signal buttons. Items and fluids only; without filters everything is sent.

The signals are refreshed about once a second (with more than six interfaces a little less often: two
of them are refreshed every 20 ticks, in turns). The network writes the combinator's signal list: entries
added by hand are replaced, extra sections are removed; the combinator's on/off switch still turns the
output off. Filters are copied by settings paste and kept in blueprints, copy and paste, and clones. Since
issue #68 the ME Controller has no circuit connection (it was a roboport): the Circuit Interface is the way to
read the network. Items with tags (loaded cells) count under their item. Up to 1000 signals per interface (the
largest amounts first).

## Settings in blueprints and copy/paste

| Entity | Settings | Settings paste | Blueprint, copy/paste, clone |
|---|---|---|---|
| ME Pattern Provider | furnace recipe choice | yes | yes |
| ME Interface | slot filters (the export slots) | yes | yes |
| ME Import Bus, ME Export Bus | item filters | yes | yes |
| ME Drive | none: the cells are items, not settings | - | a drive from a blueprint is empty |
| ME Fluid Interface | import/export, fluid, fill level | yes (shift right click, shift left click) | yes (since issue #38) |
| ME Fluid Import Bus, ME Fluid Export Bus | fluid filters | yes | yes |
| ME Level Maintainer | resource, amount, amount from the circuit; the lamp's circuit condition | yes | yes |
| ME Circuit Interface | filters | yes | yes (the signals of the moment in a blueprint are rewritten when it is built) |

## Fluids

Tech `me-fluid-storage` (EV, needs `me-autocrafting`) unlocks 1k to 64k **fluid storage cells**, the **ME Fluid
Interface** and the **ME Fluid Import and Export Bus**; `me-fluid-storage-256k` (IV, also needs `me-storage-256k`)
the 256k fluid cell (`prototypes/122-fork-ae2-fluids.lua`). Since issue #68 step R2 fluids are stored like items:
in cells in the ME Drive.

| Thing | What it is |
|---|---|
| **Fluid storage cell** (1k ... 256k) | storage housing + storage component of the tier + a pump. Goes into an ME Drive slot like an item cell; a drive may hold item and fluid cells in any mix |
| **ME Fluid Interface** | 1x1 tank of 5000 units with a pipe connection on every side: the import/export point for pipes |
| **ME Fluid Import Bus / Export Bus** | 1x1, rotatable: takes fluid out of / puts fluid into the machine or tank it faces |

**Fluid cell capacity** (the item cells' byte model; AE2 gives fluid cells fewer types than item cells, 18 is
Gregtorio's choice):

| Cell | Bytes | Bytes per fluid | Fluids | Units of one fluid |
|---|---|---|---|---|
| 1k | 1 024 | 8 | 18 | 8 128 |
| 4k | 4 096 | 32 | 18 | 32 512 |
| 16k | 16 384 | 128 | 18 | 130 048 |
| 64k | 65 536 | 512 | 18 | 520 192 |
| 256k | 262 144 | 2 048 | 18 | 2 080 768 |

Every 8 units of a fluid cost one byte. One fluid cell holds a little more than the old fluid drive held per
cell (8 000 units per "1k"). An item cell takes no fluid and a fluid cell no items.

* **Putting a cell in, taking it out:** exactly as item cells (the ME Drive's window, or click the drive with a cell
  in hand). A fluid cell taken out keeps its fluid; its tooltip lists it ("12345 units of 2 fluids: ...").
* **Terminal:** the fluids are in the same grid as the items, after them, with their amounts; the search and sort
  apply to them. The status line shows the bytes and types of the fluid cells next to those of the item cells.
  Fluids cannot be taken by hand: use a fluid interface in export mode or a fluid export bus.
* **Import (interface):** connect pipes to an ME Fluid Interface. Import is the default mode: everything in the
  pipes and tanks connected to it goes into the network. Pipes and tanks connected **without a pump** in between
  form one fluid segment with the interface, and the whole segment is emptied (a full storage tank within a
  second). With a pump in front of the interface the fluid arrives at the pump's rate. Import stops when the
  fluid cells are full.
* **Export (interface):** open the interface. The panel next to the tank GUI has an Import/Export switch, a fluid
  selector and a fill level (0 to 5000). In export mode the network fills the interface with the chosen fluid up
  to that level and refills it as pipes and machines take it. Pipes and tanks connected without a pump share that
  level with the interface; a pump behind the interface takes the fluid away at its rate. Another fluid still in
  the tank is imported first (if the cells have room). The panel shows the status (working, no fluid cell, cells
  full, the network does not hold this fluid, ...) and the bytes and types of the network's fluid cells.
* **Fluid buses:** the import bus empties the output boxes of the machine it faces (a tank: all of it), the
  export bus fills its filtered fluids into the machine's input boxes or the tank. Up to 1000 units per visit (a
  visit about every quarter second while there are fewer than 24 interfaces and buses), up to 5 fluid filters
  (import: none means every fluid), kept in blueprints, settings paste and clones.
* **Blueprints:** a drive from a blueprint is empty (cells are items). The settings of a fluid interface (import
  or export, fluid, fill level) are kept in blueprints and copied by settings paste and cloning (issue #38).

**Temperature:** the network stores fluids by name only, without a temperature. Importing drops the temperature;
an export, a fluid export bus and the hand-over to a pattern machine deliver the fluid at its default
temperature. Steam therefore loses its heat in the network (it comes out at 15 °C, which no steam engine or
turbine accepts); the Gregtorio fluids have a single temperature and are not affected. A recipe whose fluid box
needs a temperature the default does not satisfy is not a pattern (`fluid-temperature` in the info line).

**Old fluid drives** (before step R2: four fluid cells crafted into an ME Fluid Drive) are converted when the save
is loaded (`docs/ME-REWORK.md`, "Migration of fluids (R2)"): each becomes an ME Drive with four fluid cells of its
tier holding its fluid; recovered fluid of destroyed drives goes into the cells of its network (else of the
nearest drive with room); a loaded fluid drive item in an inventory or a chest keeps its item, and its fluid comes
as fluid cells next to it. Placing an old fluid drive item builds an ME Drive with its four fluid cells (and its
fluid, if it carried any). The old recovery (recovered fluid, "Take over", pull-in) is gone: a fluid cell keeps its
fluid wherever it is, and a destroyed drive drops its cells.

## Design

### Network, cells and storage (issue #68)

The graph, the storage engine, the drive, the terminal, the interface and buses, the tick budget and the
migration are described in `docs/ME-REWORK.md` (the design record of the rework). In short:
`scripts/fork-me-network.lua` keeps the members (`storage.fork_me_net.nodes`, adjacency by shared tile edges),
the networks (one connected component each, its controllers, status, drives, storage totals, bytes, types and
an index item -> cells) and the drives with their cells (`storage.fork_me_net.drives[unit].slots`); every
build and removal updates them, a breadth first search over the stored adjacency splits a network when a
member is removed, and a sweep in the terminal step finds members removed without an event. The storage API
(`insert`, `extract`, `count`, `can_insert`, `contents`, `insert_stack`, `extract_to`, `stats`) works on a
network and does nothing when the network does not work. `scripts/fork-me-io.lua` runs the I/O step (every 15
ticks: the fluid step below, then up to 24 interfaces and buses), `scripts/fork-me-migrate.lua` converts old
networks, `scripts/fork-me-terminal.lua` is the terminal and routes the GUI events of every ME window.

### Fluid storage (issue #68, R2)

Fluids are stored by the same engine as items (`scripts/fork-me-network.lua`): a fluid cell's spec (mod-data
`fork-me-network`, `cells[name]`) has `kind = "fluid"` and `per_byte = 8`; its contents are keyed
`fluid/<name>` (the resource keys of autocrafting), amounts may be fractional. `cell_room` gives an item cell
no room for fluid keys and a fluid cell none for item keys; everything else (`insert_key`, `extract_key`, the
per-network totals and the index key -> cells, the bytes and types, tags of a cell taken out) is shared.
The network keeps item and fluid bytes and types apart (`bytes`/`types` and `fbytes`/`ftypes`). The fluid API is
`insert_fluid`, `extract_fluid`, `fluid_count`, `can_insert_fluid` and `fluid_contents`; `scripts/fork-me-fluids.lua`
keeps the calls the other modules used (`totals`, `count`, `insert`, `remove`, `capacity` in units = fluid bytes
times 8) on top of them.

The **ME Fluid Interface** is a real storage tank (5000 units). Every 15 ticks (the I/O step of
`scripts/fork-me-io.lua`, which registers `on_nth_tick(15)` and runs the fluid step first) up to 8 interfaces are
stepped, round robin. Import: the tank's fluid is removed with `remove_fluid`, limited to what the network can
take (`can_insert_fluid`); this takes the whole fluid segment (pipes and tanks connected without a pump share it
with the interface, whose own box would only ever hold its share). Export: `want = level - held`, `insert_fluid`
of `min(want, stored)` at the default temperature. In both directions only what the engine reports as removed or
inserted is booked, never the requested amount, so fluid is conserved. The status of the last step is shown in
the panel.

The **fluid buses** run in the same I/O step as the item buses (`fork-me-io.lua`, `fluid_bus_step`): the import
bus reads the target's fluid boxes by index and skips input boxes (`production_type == "input"`), takes at most
what the network can store and writes the rest back into the box; the export bus uses `insert_fluid` (the engine
picks the box) and books what it reports. 1000 units per visit.

Fluids are stored by name only. One temperature per fluid keeps totals, export and hand-over unambiguous; the
price is the temperature rule above.

### Patterns

`storage.fork_ae2.providers` lists every provider. A provider looks at the four tiles around it
(`find_entities_filtered` on the tile centers), collects the assembling machines and furnaces
found there (when the provider is a member of a network; the machines need no connection), and reads
their recipe (`get_recipe()`). For
furnaces the provider's recipe choice (`providers[unit].recipe`) counts when the furnace can make it
(category, researched, no fluid) and holds nothing: a furnace that holds or smelts something counts
with the recipe it runs, so a job notices when the furnace picked another recipe. Without a choice
`previous_recipe` is used; a furnace with no recipe at all is counted under `no-recipe`. The
choice is set by `set_recipe` (GUI, settings paste, the blueprint tag `fork_ae2_recipe` on build,
cloning; the remote interface has the same function), survives `on_configuration_changed`, and
leases keep the choice they were started with. From all providers of a network the script builds
`patterns[network id]`: resource key -> recipes that make it, recipe -> machines. A change of the ME
graph (networks joined or split, a change hook of the network module) rescans every provider before the
patterns are used next. Resource keys
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
storage (normal quality plain items of the network, fluids from `fluids.totals(net)`), then a
pattern. The resource asked for is always crafted (stock is not counted for the top level, as in
AE2). Runs of a recipe are `ceil(count / expected yield)`; probabilities and ranges use the
expected value; fluid amounts stay fractional (14.4 molten tin per craft is planned as such).
Other products of a recipe (by-products) are not credited to the plan (they may not appear),
they simply end in storage. If a resource has several patterns the first one (alphabetical)
that needs nothing missing is used. Loops (a resource that needs itself) count as missing and
are named in the message. Work is capped at 3000 plan nodes / depth 40 (reported as missing);
amounts up to 100 000 items or 10 000 000 fluid units. Items with tags (cells, fluid drive items) are
never counted as stock, so a job cannot strip their contents.

The result is a list of steps (recipe, runs) in dependency order and the resources taken from
storage. If something is missing the job does not start and nothing is taken.

### Jobs

Starting a job takes the planned resources out of the network into the job's own **pool**
(`storage.fork_ae2.jobs[id].pool`, plain counts per key, so it saves, loads and syncs like any
storage table); items with the network's `extract`, fluids with `fluids.remove`. Reserving at the start
means nothing can be stolen by other jobs or by players taking items while the job runs. A job
with no free CPU waits ("Waiting for a free CPU") with its resources reserved.

Each step the CPU of a job:

1. collects machines that are idle again (no progress, no ingredients left): their products go to
   the pool,
2. hands batches (up to 16 crafts, limited by the pool, by one stack per item ingredient, by the
   output slot and by the fluid boxes) to idle machines with the right recipe, in plan order
   (Molecular Assembler or any other pattern machine, several machines in parallel),
3. when every step is done, stores the whole pool in the network (result and by-products), items
   with the network's `insert`, fluids with `fluids.insert`. What does not fit stays in the pool
   ("Storing items and fluids (network cells full?)").

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
| A drive or a fluid cell during a job | nothing happens to the job: its items and fluids are in its pool, not in a cell. At the end the pool is stored in the remaining cells, or waits for room |
| Fluid interface | nothing for jobs; what it holds goes back into the network (as far as the cells have room), its mode, fluid and level are forgotten |
| Terminal, controller, a cable | jobs without a working network pause ("No ME network"). A job finds its network through its CPU, else through the entity it was started at (terminal, level maintainer), else through the ME block at its position (jobs of older saves) |

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
  the network's `count` (normal quality) or `fluid_count`. Its own job still queued or running:
  nothing. Stock below target: if an active, not closing job of the network crafts the same key
  (`active_job_for`), nothing; else, if a powered CPU has a free slot (`free_slot`), `M.start` with the
  difference and the maintainer's unit number as the job's `owner`. At most one start per step (a start
  rescans the providers and plans); a failed start (missing, no pattern) waits `RETRY_TICKS` (300).
* **Circuit interface update** (2 per step, round robin): the network's `contents` (with quality; items with
  tags under their item)
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

* One shared autocrafting step every 20 ticks (`on_nth_tick(20)`; the I/O step uses 15,
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
* The I/O step every 15 ticks: up to 24 ME Interfaces and buses (`docs/ME-REWORK.md`, "Tick budget"), and
  the fluid step, which handles at most 8 fluid interfaces (one `remove_fluid` or
  `insert_fluid` each) and the open interface panels; a network's fluid total is a table lookup (the storage
  engine's totals), never a loop over tanks, pipes or drives. Fluid buses move up to 1000 units per visit.
* The terminal step every 60 ticks: the open terminals, the lights of up to 50 changed drives and a sweep
  over 200 network members (members removed without an event).
* No per-tick loops, no loops over the whole network. State lives in `storage.fork_me_net`, `storage.fork_me_io`,
  `storage.fork_ae2` and `storage.fork_me_fluids`; GUI state (selected resource, amount) lives in the GUI
  elements.

### Existing saves and mod updates

`on_configuration_changed` first rebuilds the ME graph from the world (`scripts/fork-me-network.lua`, the only
map scan; drives keep their cells by unit number), then converts the ME networks of saves from before issue
#68 (`scripts/fork-me-migrate.lua`, rule in `docs/ME-REWORK.md`; `migrate --from-ref v0.3.2` checks it with an
old network holding items, fluids, a pattern and a running job), then the other modules rebuild their
records. It also rebuilds the provider and
CPU registries from the world (`find_entities_filtered`), repairs leases and job books and
keeps jobs and their pools; leases from before fluid support get empty fluid maps, providers are
rescanned.
CPU records of older saves hold one `job`; they are rebuilt (`jobs = {}`) and the jobs reassigned, and a
record read before the rebuild is converted on the spot (`migrate --from-ref v0.3.1` starts a job with
the old version and checks that it finishes after the update). Level maintainers and circuit interfaces
are new, their state is created lazily and rebuilt from the world (settings kept by unit number).
Before the item migration, the fluid migration of step R2 (`run_fluids`) converts the old fluid drives, their
recovered fluid, the contents held for an upgrade and loaded fluid drive items into fluid cells and drops that
part of `storage.fork_me_fluids` (rule in `docs/ME-REWORK.md`, "Migration of fluids (R2)"); the fluid module then
rebuilds its interface records from the world (settings kept by unit number) and closes open panels.

## Limits and open points

* One temperature per fluid: stored by name, exported at the default temperature. Hot steam loses
  its heat; recipes that need another temperature are not patterns.
* Cells are not part of blueprints: a drive built from a blueprint starts empty. A destroyed drive drops its
  cells with their items and fluids.
* No cell partitioning (a cell that takes only some fluids) and no drive priorities: a fluid goes into the cells
  that already hold it first, then into any fluid cell with a free type.
* Loaded old fluid drive items stored inside ME cells (R1 allowed storing them) are not converted by the
  migration; placing such an item later gives a drive with its fluid in cells.
* The export level applies to the interface's own box; pipes and tanks connected without a pump
  share that level, so the segment holds more than `level` in total. Put a pump behind the
  interface to fill a tank.
* The fluid interface has no circuit connection; the fluid totals reach the circuit network through
  the ME Circuit Interface (issue #38).
* Autocrafting plans and crafts only normal quality, no items with own data (armor, tools, cells with
  contents) and no spoilage handling in the pool. Network storage takes every quality, and items with tags.
* Network storage (issue #68): no channels, no cell partitioning, no drive priorities, no storage bus; the
  terminal search matches internal item names only; spoiling items, items with an inventory and damaged items
  cannot be stored. Old ghosts of ME blocks disappear when an old save is loaded (the game removes them before
  any script runs). The GUIs of drive, terminal and buses, the drive lights, the cable pictures and the
  controller's status are untested in the real game (the headless test calls the functions behind them).
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
* Balance (costs, speeds, tier), the look of the sprites and the GUIs (the terminal's fluid entries, the fluid
  bus window, the interface panel) are untested in the real game.

## Testing

`python tools/devcheck/devcheck.py runtime` first tests the network core (issue #68, right of the machine
grid): the cable graph (join, split with the larger part keeping its id, a second controller is a conflict and
the network stores nothing, a cable removed without an event is found by the sweep, the cable router, a
network without power, with power, and after the power is cut), the cells (insert into slots, only cells,
AE2 bytes and capacity, quality as its own type, a cell taken out carries its items in its tags and brings
them into another drive, a loaded cell stored in the network and taken out with its tags, the drive window's
clicks, a destroyed drive spills its cells with their items, an old drive item gives its four cells, robots
mining a drive bring the drive and its loaded cells to a storage chest), the terminal's functions (a stack into
the cursor, one more, the cursor stored by a click, one item, a stack into the inventory, the inventory row,
search, sort, a spoiling item and a blueprint refused) and import/export (interface export slot filled and
topped up, import slot emptied, a spoiling item left in the interface, settings paste, the import bus 64 per
visit and with a filter, the export bus into a chest and into a machine, a rotated bus, blueprint tags).
Every other test runs on cable networks laid by the same router. Then it builds a small network (CPU, two Molecular
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

A second network tests the fluids (issue #68 R2: a drive with four 1k fluid cells): an import interface with a
storage tank of chlorine connected to it, an export interface set to 1000 units, a roboport with construction
robots, and HV chemical reactors and an EV extractor with fluid recipes behind pattern providers. It checks that
the tank drains into the network and the export interface holds its level (fluid conserved, the fluid bytes
right), that the export never overfills and re-imports when switched, that a fluid cell taken out carries the
chlorine in its tags, survives a trip through the terminal and brings it back from another slot, that robots
mining the drive deliver the drive and its four cells (the chlorine in the tags) to a storage chest and the
rebuilt drive is empty until the cells are back, that full cells stop the import and keep the fluid in the tank
while the panel reports it, that a reactor with a pipe on its input is counted under `fluid-pipes` and not a
pattern, that a too large request reports the missing chlorine and raw silicon exactly, that three jobs (fluid in
and out, fluid out only, fluid in only) finish with the expected amounts and empty machines, and that a reactor
mined by robots while it holds a job's chlorine gives it back.

The fluid cell test (another network right of the machine grid) puts an item cell and a fluid cell into one drive
(each takes only its kind), takes the fluid cell out (water in the tags, the network keeps none, the item cell
takes no fluid) and puts it back, checks a fluid cell's capacity to the unit, the terminal's entries (items, then
fluids; search; taking a fluid by hand is refused), the fluid import bus emptying a tank (1000 per visit) and the
fluid export bus filling one (nothing without a filter), and old fluid drive items placed as ME Drives (four cells
with the fluid of the tags; 40 000 units on a 1k item: more cells in the free slots, nothing lost).

`devcheck.py migrate` (the old fluid recovery is tested as the migration): the old save has two loaded 1k fluid
drives in a network, a loaded drive outside any network, recovered chlorine with no network at its place and a
chest with two loaded drive items. After the update the drives must be ME Drives with four 1k fluid cells holding
their fluid, the recovered chlorine must be in the nearest drive with room, the items must have lost their tags
and their water must be in fluid cells in the chest, and the migration report must count the same units before
and after (`--from-ref v0.3.2` and from a commit with R1, whose old save uses the cable network).
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

`devcheck.py migrate --from-ref v0.3.2` (issue #68) builds an old logistic ME network with the old version: a
1k drive with items (also of another quality, and a blueprint the new network cannot store), a requester
interface with items in its inventory and its trash, a terminal, a second controller in the same logistic
network, the fluid drives, CPU, providers and running job above, a chest with 16 storage cells on one stack, old
drive items and the ghost of an old drive. After the update no old entity may be left, every block must be
connected to the new controller, the drives must hold four cells of their tier, the migration report must
have counted exactly the items of the old chests (and the second controller) and found no difference, those
items (job items aside) must be in the network and the blueprint in an overflow chest, the 16 cells and the old
drive items must be kept, and the fluid, pattern and job checks above must pass on the new network.
See `tools/devcheck/README.md`.
