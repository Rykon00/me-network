# ME Network: the network, autocrafting, fluids and automation

> This guide was written in Gregtorio Continued, where the ME network was made (issue numbers are Gregtorio's). The
> recipes and technology tiers it names (GT materials, voltage tiers, science packs) are the ones in a Gregtorio game.
> On its own, ME Network uses vanilla recipes and science: the network with red and green science, 64k cells,
> autocrafting and fluids with blue, 256k storage, the co-processing unit and the 16k and 64k crafting storage with
> production, the 256k crafting storage with utility science (`prototypes/network.lua`, `autocrafting.lua`, `fluids.lua`). Everything else here is the same in both.


## What the ME network is

Since issue #68 the ME network plays like Applied Energistics 2: ME blocks connected by ME cables, storage
cells in drives (with partitions and drive priorities), a terminal as the hub, and one window per block
(`prototypes/network.lua`, `scripts/fork-me-network.lua`, `scripts/fork-me-windows.lua`; the design and its
reasons: `docs/ME-REWORK.md`). It has nothing to do with Factorio's logistic network any more.

| Entity | Role |
|---|---|
| ME Cable | placed with the **fluix cable** item; connects ME blocks on all four sides; can be walked over |
| ME Underground Cable | rotatable pair (MV, `me-network`, 8 fluix cables + 2 aluminium plates -> 2): carries the network under up to 10 tiles to the first underground cable facing it, like an underground pipe; above ground an end connects only on the side opposite its arrow; it is a pipe-to-ground with its own connection category, so the game pairs the ends and shows the pairing on hover and while placing exactly like underground pipes (it never connects to pipes or carries fluid); can be walked over |
| ME Controller | 2x2, needs power; exactly one per network runs it (two are a conflict) |
| ME Drive | 1x1, holds up to 10 storage cells; has a priority |
| Storage cell (1k ... 256k) | holds the items (AE2 bytes and types); keeps them when taken out of the drive; can be partitioned |
| ME Terminal | powered screen (can be walked over), the hub: storage, **crafting**, jobs, the drives and cells of the network |
| ME Interface | 1x1 with 18 slots, a tank on each of its four sides for pipes, and 9 config rows (an item or a fluid + amount): keeps those in stock in it, imports everything else (this page, **Import and export**) |
| ME Import Bus, ME Export Bus | 1x1, rotatable: pull items and fluids out of / put them into the machine, chest or tank they face; can be walked over |
| ME Storage Bus | 1x1, rotatable, can be walked over: the chest or cargo wagon it faces, or the fluid of the tank it faces with every pipe and tank connected to it, becomes network storage, with filters, priority, read/write mode and 5 upgrade card slots (this page, **ME Storage Bus**, **Upgrade cards**) |
| Fluid storage cell (1k ... 256k) | holds fluids in an ME Drive, like an item cell (this page, **Fluids**) |
| Crafting blocks: crafting unit, 1k ... 256k crafting storage, co-processing unit, crafting monitor | 1x1; a solid rectangle of them with at least one crafting storage is a Crafting CPU, which runs one autocrafting job of up to its crafting storage in bytes (this page, **Crafting CPUs**). The single-block ME Crafting CPU, Co-Processing and Quantum Crafting CPU are legacy blocks |
| ME Pattern Provider | holds 9 encoded patterns; the machines (or a chest) next to it do their work (this page, **Autocrafting**) |
| Blank / Encoded Pattern | a blank pattern is encoded in the terminal's Patterns tab into an encoded pattern: a recipe (crafting pattern) or free inputs and outputs (processing pattern) |
| ME Level Maintainer | keeps an item or fluid in stock by autocrafting (this page, **Keeping items in stock**) |
| ME Circuit Interface | puts the network contents onto a circuit wire (this page, **Circuit network**) |

Techs: `applied-energistics-components` (MV, upstream: fluix cable, ME Controller, ME Interface),
`logistic-system` (the ME Drive), `me-network` (MV: terminal, 1k/4k/16k cells, import, export and storage bus,
underground cable), `me-storage-64k` (EV),
`me-storage-256k` (IV), `me-autocrafting` (EV), `me-fluid-storage` (EV), `me-fluid-storage-256k` (IV),
`me-automation` (EV), `me-co-processing` (IV), `me-quantum-crafting` (LuV).

## Building a network

1. Place an **ME Controller** and give it power (120 kW, plus 4 kW for every drive, interface, bus, pattern
   provider and circuit interface of the network; cables, terminals, CPUs and level maintainers
   have their own power connection).
2. Connect everything else with **ME cables**: a cable connects on all four sides, and ME blocks that touch
   each other connect without a cable (a row of drives next to the controller is one network). Corners do not
   connect. Everything connected is one network. The cable picture shows its connections.
3. Place **ME Drives** and put **storage cells** into them (see below), and an **ME Terminal** (powered).
4. Import and export with **ME Interfaces** (inserters, belts, pipes) or **buses** (directly on a machine, chest or
   tank); an **ME Storage Bus** makes a chest or a tank part of the network's storage.

**Walking and driving:** the cable, the underground cable, the three buses and the terminal can be walked over (and driven
over by cars and tanks: they collide through the same layer as the player); nothing can be built on them. The interface,
drive, controller, provider, level maintainer, circuit interface, crafting blocks and the Cell Workbench stay solid.

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

* **Putting a cell in:** open the ME Drive (click it) and click a slot with the cell in hand, or click the
  drive itself with a cell in hand (first free slot). Only storage cells go into a drive (10 slots).
* **Taking it out:** click a filled slot (the cell goes into your hand; shift click: into your inventory). The
  cell keeps its items: its tooltip lists them ("1234 items of 5 types: ..."). Put it into any drive of any
  network and the items are there again. **Right click** a cell in the drive window: its cell window
  (contents, bytes, types, partition).
* **Fill lights:** each cell in a drive shows a light on the drive: green while it has room, orange above 75 %
  of its bytes, red when it is full (bytes or types). The drive window shows a fill bar, bytes and types per slot.
* **Mining a drive** gives the drive and its cells with their items. **A destroyed drive** drops its cells
  (with their items) on the ground. Blueprints and copies of a drive come without cells, but with the drive's
  priority and the partition of each slot (the next cell put into that slot gets it).
* Cells can be stored in the network like any item; one that holds items is stored with them.
* **Storable:** plain items, items with tags (cells, patterns), whole tools, ammunition and repair packs
  (science packs, magazines and unused repair packs go in and come out with the count they went in with), and **damaged
  items** (a mined wall, belt or chest): a damaged stack is kept apart from the whole ones with its health, shown in the
  terminal as "Damaged: 50% health", and comes out damaged. Two damaged stacks of different health that you put into one
  inventory merge into one of averaged health, as in the game.
* **Not storable:** items with an inventory or equipment grid (armor), blueprints and blueprint books, planners and
  selection tools, the spidertron remote, vehicles and other items with entity data, items with a label, items that
  spoil (the network would stop their decay), and partly used tools, ammunition and repair packs (a used science pack,
  repair pack or magazine; a stack whose top item is used is refused as a whole). Each refusal says what was refused.
* **Old drive items** (ME Drive 1k ... 256k from before the rework) cannot be crafted any more; placing one
  builds an ME Drive with its four (empty) cells, the 256k one also gives its acceleration card back.

### Partitions and priorities

Two AE2 storage features decide **which cell** an item or fluid goes into (and comes out of):

* **Cell partition** (AE2's "partitioned cell"): open a cell's window (right click it in the drive window, or click
  it in the terminal's Cells tab) and choose items (with quality) or fluids in the partition buttons, at most as
  many as the cell has types. A partitioned cell **only** takes those; what it held before stays in it until it is
  taken out. **From contents** restricts the cell to what it holds now, **Clear** removes the partition.
  Partitioned cells have a yellow frame in the drive window and the Cells tab. The partition travels with the cell
  (also an empty one). The cell's tooltip names it (see "The tooltip of a cell"). The **ME Cell Workbench** sets the partition too, and puts
  **upgrade cards** into a cell (see "ME Cell Workbench"): with an Inverter Card the partition is a blacklist, with
  a Fuzzy Card it matches every quality; the cell window shows the cards and what they do.
* **Drive priority** (-1000 to 1000, default 0, in the drive window): the priority of every cell in that drive.
* **Storage buses** (see "ME Storage Bus") take part with their own priority; their filters work like a partition
  (with an **Inverter Card** like a blacklist, with a **Fuzzy Card** in every quality: see "Upgrade cards").

The rules (`scripts/fork-me-network.lua`, `insert_key` and `extract_key`):

1. **Storing**: the drives of the **highest priority** first. Within one priority: first the cells
   **partitioned** for the item, then the cells that **already hold** it, then any cell with room. A partitioned
   cell never takes anything else, whatever its priority.
2. **Taking out** is the reverse: the **lowest priority** first; within one priority the unpartitioned cells
   before the partitioned ones.
3. Same priority and same rule: the order the cells joined the network (drive by drive, slot by slot); cells
   before storage buses when storing, storage buses before cells when taking out.
4. A **blacklist** (a storage bus with an Inverter Card) is not partitioned for anything: it takes what it lets in
   with the cells "with room" (rule 1, last), never before them for an item, unless it already holds the item. A
   filter with a Fuzzy Card counts as partitioned for its item in every quality.

These are AE2's four rules ("Import, Export, and Storage"): the highest priority first; at the same priority storage
that already holds the item first; whitelisted storage counts as holding it (here it even comes first); taking out
from the lowest priority. AE2 puts whitelisted and holding storage into one pass in the order they joined; the mod's
finer order fills partitioned storage first.

So a high priority drive with cells partitioned for ores takes every ore first, and a low priority drive of
unpartitioned cells is the overflow that is emptied first. A network with one priority and no partition behaves
as before (cells that hold the item, then any cell). Priority and partitions are kept in blueprints (the cells
are not: a slot keeps its partition for the next cell put in), copied by settings paste between drives (every
slot: the source slot's partition, or none) and by cloning.

## ME Terminal

Needs power and a working network. It is the hub of the network: a status line (bytes and types of the item and
fluid cells, drives, cells, the controller's power), a search field for the Storage and Crafting tabs, and five
tabs:

* **Storage:** sort (by amount or by name) and **Show: all / items / fluids**. **Left click** an item: a stack into
  your hand; with something in hand, the click stores that instead. **Right click**: one item into your hand (one
  more of the same item). **Shift click**: a stack into your inventory. Items with tags (loaded cells) have a
  yellow frame. After the items, the fluids of the fluid cells with their amounts (they cannot be taken by hand).
  **Storing:** your inventory is on the left of the window (issue #28): **shift + click** a stack there to store it
  in the network, **control + click** to store every stack of that item (a stack the network refuses stays, the others
  go in); what the network cannot take (a blueprint, an item that spoils, a partly used one, no room) stays
  with a short message that says why. What you take out appears there at once.
  "Store item in hand" stores the cursor. Amounts are shown as 999, 1.2k, 12k, 1.5M, 2.5G everywhere.
* **Crafting:** every item and fluid a pattern can make, in the same grid (the picked one in yellow). Pick one,
  enter the amount: the plan preview lists the crafts and steps, and as slot buttons what is **missing** (red) and
  what is taken from storage. **Craft** starts the job (see **Autocrafting** below).
* **Jobs:** the crafting jobs of the network with amount, progress bar, status and **Cancel**.
* **Cells:** the drives of the network, highest priority first, with their cells (number: fill in percent;
  yellow: partitioned). Click a drive for its window, a cell for its cell window; both have a **Back** button
  to the terminal and need only the terminal in reach.
* **Patterns** (issue #80, AE2's pattern terminal): encodes blank patterns (see [Patterns](#patterns-encoding-and-clearing)).

## The ME windows

Every ME block has its own window in one style (title bar with close button, drag it by the title bar), opened by
**clicking the block** (the normal open key). Issue #28: **every ME window shows your inventory on its left**
("Character"), the block's slots (cards, cell, cells of a drive, patterns) in the window: click a stack in your
inventory to pick it up, put it down, merge or swap it, right click for half a stack, **shift + click to put it into
the block** (a card into a card slot, a cell into the workbench or a free drive slot, a pattern into a free provider
slot; in the terminal and every block without slots of its own (interface, import and export bus, controller, level
maintainer, circuit interface, crafting CPUs) it is **stored in the network**, control + click stores every stack of
that item). What the block cannot take stays where it is, with a short message. Click a slot of the block with an item
in hand to put it in (what does not belong there is refused and stays in your hand), click it with an empty hand to
take the item, shift + click to take it into your inventory. Blocks that have a window of the game (terminal, crafting CPUs and
level maintainer: lamps; circuit interface: constant combinator; ME Interface: container) show the ME window
instead; the others (drive, controller, buses, pattern provider) have no window of
their own and open the ME window directly. E or Escape closes it. Open windows refresh once per second. With a tool
in hand (blueprint, deconstruction or upgrade planner, copy-paste or cut tool, a wire, a ghost, an item to build) a
click uses the tool and opens no window, as on a chest.

| Block | Window |
|---|---|
| ME Terminal | the hub above; shift + click in your inventory stores |
| ME Drive | 10 slots with cell, fill bar, bytes and types; priority; click: cell in/out, right click: cell window; shift + click a cell in your inventory: into a free slot |
| Storage cell | contents, fill, partition buttons, **Clear**, **From contents**; shift + click a cell: into a free slot of its drive |
| ME Controller | status, members, drives, cells, bytes and types of item and fluid cells, power |
| ME Pattern Provider | 9 pattern slots (shift + click an encoded pattern in your inventory: into a free slot; click with one in hand: put it in or swap; click a pattern: take it, shift: into the inventory), the status of each pattern (usable by how many machines, or why not), the machines and chests next to it with their recipe, the priority |
| Crafting block (any block of a Crafting CPU) | the CPU's status (or why the group is no CPU), size, crafting storage used and total, co-processors and speed, monitors, its job (progress, **Cancel**) |
| ME Crafting CPU (legacy, all tiers) | job slots, speed, power, the jobs it runs (progress, **Cancel**) and the jobs waiting for a CPU |
| ME Level Maintainer | item or fluid, amount, amount from the circuit, the circuit condition (on/off by a signal), stock and status |
| ME Circuit Interface | output on/off, up to 20 filters (empty: everything), how many signals it sends |
| ME Interface | the priority, 9 config rows (an item or a fluid + amount), the four sides (import, off, or a fluid row; what each side's tank holds), what it holds, status, **Open inventory** (the container's own window, once) |
| ME Import/Export Bus | 9 filters (items and fluids), the entity it faces and whether the bus uses its items, fluids or both, status |
| ME Storage Bus | your inventory on the left, its 5 card slots; mode (read and write, read only, write only), priority, 18 filters (9 more per Capacity Card; a blacklist with an Inverter Card), "filter on extract", From contents, Clear, the cards it waits for, a red warning with an Overflow Destruction Card, how many items it shows (on a tank: the fluid with amount and temperature), the entity it faces, status |

The ME Interface's container window is still reachable through **Open inventory** (to take items out by hand);
the lamp window of the level maintainer is replaced, its circuit condition is set in the ME window (it is the
same lamp condition, so blueprints and settings paste of the game keep it).

## Import and export

**ME Interface** (18 slots, like a chest for inserters and belts, and a tank on each of its four sides for pipes).
Its window has **9 config rows** (AE2's config slots): each an item (with quality) or a fluid, and an amount. A row's
button opens the **picker** (issue #70, see "ME Cell Workbench": item groups, search, qualities, the green check or the
confirm key), right click empties the row; no virtual signal can be chosen.

* **Items:** the network keeps exactly that amount of each configured item in the interface: it fills up what
  inserters took and takes back a surplus. Everything else put in is imported into the network (items the network
  cannot store stay in the interface). A new item starts with one stack; choosing an item that is in another row
  moves it with its amount.
* **Fluids** (issue #3 of ME Network; before, the ME Fluid Interface did this): pipes, pumps and tanks connect to
  any of the four sides. Each side is set in the window to **Import** (the default: everything piped in, the whole
  pipe network up to the next pump, goes into the network), **Off** (neither), or a **fluid row**: the network keeps
  that side's tank filled with the row's fluid up to the row's amount (at most 5000 units; pipes connected without a
  pump share the level with the tank). A new fluid row takes the first import side that has a pipe (else the first
  import side); several sides can keep the same row. A side holds one fluid, so **up to four fluids at once** (AE2's
  interface holds 9 fluids; a 1x1 block has four sides). A fluid row that no side keeps does nothing. An import side
  whose pipes run round to an export side of the same interface imports nothing (no pumping in a circle).
* Mined, the fluid in its sides goes into the network; destroyed, it is lost like a tank's. Interfaces of saves from
  before 0.2.0 get their sides when the game is loaded; a side that an existing pipe, pump or tank points at is set
  to **Off**, so a pipeline that ran past the interface is not drained (switch it to Import in the window).
* **Priority** (in its window, -1000 to 1000, default 0; me-network issue #17): when the network has less of an item
  or fluid than its interfaces want, the interfaces of the higher priority are filled first; one of a lower priority
  gets only what is left after them (its fluid side says "ME Interfaces of a higher priority lack it"). What an
  interface already holds stays in it. Interfaces of the same priority share what there is in the order they are
  visited.
* The rows, sides and the priority are kept in blueprints and copied with the entity settings (shift right click, shift left
  click) and by cloning. Interfaces of older saves: every filtered slot becomes a config row of one stack (several
  slots with the same item add up), the first time the interface works after the update; the slot filters are
  cleared. Old blueprints with filters are converted the same way.

**ME Import Bus / ME Export Bus** face one machine, chest or tank (rotate them; the plate and the arrow show the
side). Open one to set up to 9 filters, items and fluids mixed (the window also shows the entity it faces and
whether the bus uses its items, its fluids or both). On a machine with an inventory and fluid boxes (an assembling
machine with a fluid recipe, a chemical plant) one bus does both; on a chest only items, on a tank only fluids.

The filter buttons of the buses open the same picker (items and fluids, no quality row: a bus filter is a plain item or a
fluid), right click empties a filter. The ME Storage Bus's filters (items with quality, or fluids), the ME Level
Maintainer's target, the ME Circuit Interface's filters and the pattern editor's rows of the ME Terminal work the same
way (the maintainer's, the circuit interface's and the pattern editor's without a quality).

An **ME Export Bus facing a lab** feeds it science packs (issue #86): the filters are the packs, and the bus tops each up
to a stack (200 packs) in the lab's slot for it, again as the lab uses them. The lab takes only the packs it uses: a filter
it refuses (an iron plate) moves nothing and stays in the network. A lab has no output, so an ME Import Bus facing one
shows "Faces nothing it can work with". Science packs can be stored in the network (issue #76), so a pack line can run
from the drives through export buses into labs; labs that sit next to each other are fed by inserters between them as usual.

| Bus | Takes from / puts into | Filters |
|---|---|---|
| Import | the output of an assembler or furnace, or any slot of a chest, and the fluid in the output boxes of a machine (a tank: all of it), into the network | only those items and fluids; none: everything |
| Export | from the network into the input of an assembler, furnace or **lab** (up to a stack of each filtered item) or a chest, and its filtered fluids into the machine's input boxes or the tank, at the fluid's default temperature | the items and fluids to export (none: nothing) |

A bus moves up to 256 items and 4000 units of fluid per second (map settings "Bus speed"), however many buses the
map has: a bus that is visited less often moves more per visit. An interface handles 8 slots per quarter second since
its last visit, and its four sides. When a block with work is visited again follows the buffer on its other side:
the visit sees what the machine or chest used or gathered since the last one and how much it still holds or has
room for, and comes back before that runs out (about halfway, at the earliest after a quarter second, at the
latest after 10 seconds), so a machine never waits for its bus while its buffer lasts; a block whose machine had
run out is served first the next time. A block with nothing to do on its machine's side (an empty source, a full
target, no target) is only probed, with one cheap look at a growing interval (up to 5 seconds, setting "Longest
wait of an idle interface or bus"), and visited at once when the look sees a change; one with nothing to do on the
network's side (its item is not in the network, the network is full, no power, no network) costs nothing until the
network wakes it: when its item comes in or room appears, the power is back or the network changes, and also when
its settings change, it is rotated or something is built in front of it. The visits per tick are what is due,
between the map settings "Interface and bus visits per tick, at least" and "at most" (above the ceiling the
earliest due come first: a big base pays at most the ceiling). Storage bus reads, level maintainer checks and
crafting job steps follow the same rule with their own floor and ceiling settings; a stocked level maintainer waits
without any cost until its item is taken. The unified blocks move fluids as soon as they are built; the network stores fluid in fluid
storage cells (tech ME Fluid Storage) or in a tank behind a storage bus.
storage cells (tech ME Fluid Storage) or in a tank behind a storage bus.

## ME Storage Bus

The **ME Storage Bus** (tech ME Network, MV assembler: an ME Interface, two MV pistons, aluminium plates and fluix
cable) is AE2's storage bus: rotate it so its green plate faces a **chest, logistic chest or cargo wagon**, connect it
to the network like any bus, and that inventory becomes storage of the network. Facing a **storage tank** it makes
the tank's fluid storage of the network instead (see **ME Storage Bus on a tank**); what it faces decides.

* The **terminal** shows what is in the chest (with the cells' items, as one total); autocrafting, export buses, ME
  Interfaces, level maintainers and the circuit interface count it and take from it.
* The network **stores into** the chest by the bus's **filters** and **priority**, together with the drives (see
  "Partitions and priorities"): a high priority bus with filters is an **input chest** (the network puts those items
  there first, an inserter or a machine takes them out), a low priority bus without filters an **overflow chest**.
  At the same priority the cells are filled first and the chest is emptied first.
* **Mode** (in its window): **Read and write** (AE2: bi-directional); **Read only** (AE2: extract only): the network
  takes from the chest and shows it, but never puts anything in (a factory's output chest); **Write only** (AE2: insert
  only): the network puts items in but does not show or take them (a chest that a train or another factory empties).
* **Filters**: 18 items (with quality) and fluids, 9 more with each **Capacity Card** (up to 63). With filters the bus
  shows and stores only those; without filters everything the network can store (a bus with only fluid filters takes
  no item). With an **Inverter Card** the filters are a **blacklist**: everything except them; with a **Fuzzy Card** a
  filter matches its item in **every quality**.
* **Filter on extract** (a check box, on by default, AE2's setting of the same name): on, the filters decide what goes
  in and what the network sees and takes; off, they decide only what goes in, and the network sees and takes everything
  in the chest it can hold (an input chest that also takes back what a machine left in it).
* **From contents** sets the filters to what the chest holds now (AE2's "partition storage"), **Clear** removes them.
* **Upgrade cards**: 5 card slots in its window (see **Upgrade cards**): Capacity, Inverter, Fuzzy and Overflow
  Destruction Card. With an **Overflow Destruction Card** whatever the network stores into the bus and does not fit
  into the chest is **destroyed** (only what its filters let in, and only while it faces a chest or tank): the window
  says so in red and counts what it destroyed. Give such a bus a low priority, or it takes everything before the
  drives.
* Inserters, players and trains change the chest without the network noticing at once: every bus looks at its
  chest about every quarter second (with more than 8 storage buses each less often: 50 buses, every 1.75 s). Until
  then the terminal may show a few items that are gone, or not yet show new ones; taking out always checks the chest
  first, so nothing is ever duplicated or promised from an empty chest.
* **A chest that refills** (an infinity chest, an inserter feeding it): when the network takes the last of an item type
  out of the chest, the bus looks at it again 5 ticks later, so the next stack is in the network (and the terminal) a
  fraction of a second after you took the first. Only for a bus that is not due within those 5 ticks, and bounded: a
  bus whose second look found nothing new does not look again after the next type runs out, until one of its regular
  looks finds something new, so a chest that stays empty costs one extra look, not one per item type. The terminal
  refreshes your window once more 10 ticks after you took something (it refreshes every second otherwise). A partial
  take (32 of 64) leaves the rest in the snapshot, which is right, and a refill of that is seen at the next regular look;
  the fluid side (a tank a pump refills) is not covered: its read is a whole fluid segment, and a tank does not run out
  of a fluid the way a chest runs out of a stack.
* **One bus per chest**: a second storage bus on the same chest shows "Another ME Storage Bus already uses this
  inventory" and does nothing until the first one is removed. A storage bus facing an ME block (an interface, a
  drive, a cable, ...) does nothing either ("Faces an ME block"): no loops.
* Removing the bus or the chest takes the chest's items out of the network at once (a chest destroyed by another
  mod without an event: at the bus's next look); nothing is lost, the items stay in the chest.
* Not shown or moved: spoiling items, items with an inventory or own data (armor, blueprints, ...). AE2 can show
  items a bus cannot take as present; here they are not shown at all, because every plan, level maintainer and
  circuit signal counts on what the network shows. Items are taken out by count: a damaged item or a partly used tool
  or magazine in the chest comes out as a new one would. Tools (science packs), ammunition and repair packs are the
  exception: of those the bus shows and moves only the whole stacks, a stack whose top item is used is not shown and
  stays in the chest, and a whole item put in is never put into a chest that holds a used stack of that item. A damaged
  item (a mined wall, belt or chest with less than full health) is not handed out as a whole one either (issue #84): the
  bus takes the whole stacks of such an item out of the chest and leaves a damaged stack in it. Until the first take
  finds it, the terminal may show the damaged ones in the count; after that the bus shows only the whole ones, and all of
  them again when the damaged stack is gone from the chest. A damaged stack in an ME Interface is no surplus the
  network takes (its whole stacks are).
* Settings (mode, priority, filters, filter on extract) are kept in blueprints, copied by settings paste and by
  cloning; so is which cards it has, but the cards themselves are items (see **Upgrade cards**).

## ME Storage Bus on a tank

An **ME Storage Bus** facing a **storage tank** (or any other entity with a fluid box that is no ME block) makes the
fluid in that tank storage of the network (issue #3 of ME Network: this was the ME Fluid Storage Bus).

* **What counts is the fluid segment, not the tank.** In Factorio 2.0 every tank and pipe connected to each other
  (without a pump in between) shares one fluid, one amount and one temperature. The bus shows the whole segment: two
  tanks joined by a pipe are one storage of 50200 units. Pumps separate segments.
* **One bus per segment**: a second storage bus on any tank of the same segment shows "Another ME Storage Bus already
  uses this fluid segment" and does nothing until the first one is removed. If you remove the
  pipe between two tanks, they become two segments and the second bus takes its tank's part; if you connect two
  segments, the bus that was built first keeps the joined segment and the other one stops counting at once.
* The **terminal** shows the fluid (one total with the fluid cells); autocrafting, export buses, interfaces, level
  maintainers and the circuit interface count it and take from it. Fluids cannot be taken by hand.
* The network **stores into** the segment by the bus's **filters** (its fluid filters) and **priority**, together with
  the drives and the item storage buses (see "Partitions and priorities"): at the same priority the fluid cells are
  filled first and the tank is emptied first. A tank takes one fluid: a tank holding crude oil gets no water.
* **Mode**: read and write, read only, write only, as for the item storage bus; filters (fluids), "filter on
  extract", "From contents", "Clear" and the cards too (a Fuzzy Card does nothing for fluids). With an **Overflow
  Destruction Card** what does not fit into the segment is destroyed; a tank that holds another fluid or is at another
  temperature takes nothing and destroys nothing.
* **Temperature**: the network stores one temperature per fluid (see "Fluids"). A tank at another temperature (hot
  steam) is shown and can be taken from (what leaves the network has the fluid's default temperature, as with the
  import bus), but the network puts nothing into it, so the tank keeps its heat. The window shows the
  temperature and "the fluid is not at its default temperature".
* Pumps and pipes change the segment without the network noticing at once: every bus looks at its segment about
  every quarter second (50 buses: every 1.75 s); taking out always checks the segment first, so no fluid is ever
  duplicated. Removing a pipe or tank of a segment is seen within a quarter second.
* Removing the bus or its tank takes the fluid out of the network at once; nothing is lost, the fluid stays in the
  tank.
* A bus facing an ME block (an ME Interface's sides too) does nothing. A machine's fluid box works as a small storage
  of its own (machines are not part of segments); fluid wagons are not supported.
* Settings (mode, priority, filters) are kept in blueprints, copied by settings paste and by cloning.

## Upgrade cards

AE2's upgrade cards (me-network issue #17, technology **ME Upgrade Cards** after ME 64k Storage, with its cost). Each
card is made from a component card and one item:

| Card | Recipe (standalone) | Goes into | Does |
|---|---|---|---|
| Basic Card (2 per craft) | 2 iron plates, 2 copper cables, an electronic circuit, an advanced circuit | | component |
| Advanced Card (2 per craft) | 2 iron plates, a processing unit, an electronic circuit, an advanced circuit | | component |
| Capacity Card | basic card + iron chest | storage bus, up to 5 | 9 more filters each (18 + 9 per card, up to 63) |
| Overflow Destruction Card | basic card + advanced circuit | storage bus, 1 | **destroys** what the network stores into the bus and does not fit |
| Fuzzy Card | advanced card + copper cable | storage bus, 1 | the filters match every quality of their item |
| Inverter Card | advanced card + decider combinator | storage bus, 1 | the filters are a blacklist |
| Equal Distribution Card | advanced card + advanced circuit | storage cells, 1 | every kind gets the same share of the cell |
| Acceleration Card | advanced card + processing unit | ME Import Bus and Export Bus, up to 4; ME Molecular Assembler (module slots), up to 5 | a bus moves 8, 32, 64, 96 times the items per second; an assembler +80 % crafting speed and +80 % power use each |

On storage cells (in the ME Cell Workbench) the Inverter, Fuzzy (item cells only) and Overflow Destruction Card work
like on the bus. The numbers are AE2's (its source: a storage bus has 5 card slots and takes up to 5 Capacity Cards
and one of each other card, `StorageBusPart` and `InitUpgrades`; an item cell has 4 card slots, a fluid cell 3,
`BasicStorageCell`).

* **The Acceleration Card** (issue #110) is a **module**: it goes into the module slots of an **ME Molecular Assembler**
  (five of them, which the game draws in the assembler's window), nothing else of the game's modules does, and no other
  machine or beacon takes the card. Each card adds 80 % crafting speed and 80 % power use: five cards make the
  assembler 5 times as fast at 5 times the power, which is what AE2's assembler does with its five cards (its progress
  rises 10, 13, 17, 20, 25, 50 with power 1.0, 1.3, 1.7, 2.0, 2.5, 5.0 times; a module's effect is the same for every
  card, so the first cards are stronger here than in AE2 and the fifth weaker). The ME Molecular Assembler ignores
  beacons.
* **The Acceleration Card in an ME Import Bus or Export Bus** (issue #110, AE2's speed cards): the bus window has 4 card
  slots (your inventory is on the left, as in the storage bus's window); only this card goes in. The items per second a
  bus moves, the map setting "Bus speed" (256 by default), are multiplied by 1, 8, 32, 64 and 96 with 0 to 4 cards (AE2's
  1, 8, 32, 64, 96 items per operation); the window says the factor and the rate. Only items are sped up, not fluids (as in
  AE2). A bus still moves what its machine, chest or the network can take: an export bus fills a machine to a stack of each
  item, a chest as far as it has room, so a faster bus mostly matters for a chest or a drive with a lot to move. Putting
  cards in, taking them out, mining (the cards go into your inventory), destruction (they drop) and blueprints, copy/paste,
  settings paste and clones work as for the storage bus (see below).
* **Putting a card in:** open the storage bus (your inventory is on the left of its window) and shift + click the card
  in your inventory: a stack goes into the empty card slots, one card each. Or click a card slot with the card in hand
  (one card of the stack goes in). A card the bus cannot take (an Equal Distribution Card), one more of a kind than it
  takes, a card for which no slot is left and anything that is no card are refused with a message and stay where they
  are. Click a card to take it into the hand, shift + click into your inventory.
* **Cards are items and are never made or lost by the network:** a mined bus gives its cards back (with the bus), a
  destroyed one drops them, as a drive drops its cells.
* **Blueprints, copy/paste, settings paste and clones** copy which cards a bus has, not the cards: a bus built from a
  blueprint takes its cards from the network as soon as the network has them (its window lists the ones it still
  waits for); a settings paste takes them from your inventory first, then from the network, and puts the cards the
  bus had beyond them into your inventory. Taking a card out by hand ends the waiting. A bus without its cards works
  as if it had none.
* A **Recipe paste** (a crafting machine onto the bus) changes only the filters; cards and settings stay.

### The tooltip of a cell

The item tooltip of a storage cell that is not a fresh one (a fresh cell, with no contents, partition or cards, keeps
the text of the item) says, always in this order and leaving out the lines that do not apply, so two cells can be
compared at a glance:

1. what it holds ("130 items of 2 types: 100 [iron plate], 30 [copper plate] (33 of 1024 bytes)"); an empty cell says
   its size instead ("Empty: 1024 bytes, up to 63 item types.", for a fluid cell "... up to 18 fluid types.");
2. the partition as icons, with the quality where it is not normal, a fluid cell's as fluid icons: "Partition: [iron
   plate] [copper plate]". Up to 12 show, then "+N more" ("Partition: ... +3 more");
3. whether it is a whitelist ("Whitelist: the cell takes only its partition.") or, with an Inverter Card, a blacklist
   ("Blacklist (Inverter Card): the cell takes everything except its partition."). A cell with no partition and no
   Inverter Card has neither line;
4. the cards as icons ("Cards: [Inverter Card] [Fuzzy Card]"), and one line for each card that changes what the
   partition means, in the words of the cell window and the workbench: Fuzzy ("the partition matches every quality"),
   Equal Distribution ("at most N of each kind") and Overflow Destruction in red ("what does not fit into the cell is
   DESTROYED").

The text is written with the stack whenever the cell is written: in the workbench, when a drive gives the cell back,
when a drive is mined or destroyed. A cell that lies in a chest or in an inventory of a save from before this change
keeps its old tooltip (what it holds, or "Empty, partitioned for N kinds") until it passes through a drive or the
workbench; the mod does not walk the inventories of the map for it. The cell's tags and the saved state are not
changed: only the description.

The partition is not marked on the item itself (no label, no colour): the label of a stack is a plain text, not a
localised one (an item would show by its internal name), and only a stack object can carry it, not the item definition
every drive, mining and spilling path writes. The drive window and the Cells tab frame a partitioned cell in yellow.

## ME Cell Workbench

AE2's Cell Workbench (technology ME Upgrade Cards; an iron chest, 4 iron plates, an advanced circuit and 2 electronic
circuits). It needs **neither the network nor power** (AE2's does not either): place it anywhere.

* **The cell:** shift + click a storage cell in your inventory (on the left of the window), or click the cell slot with
  a cell in hand (another cell there is swapped into the hand, with its cards); click the cell to take it, shift +
  click into your inventory. Anything else is refused with a message. The cell keeps its items all the time; every
  change of the partition is written into it at once.
* **Partition:** the cell's filled slots (items with quality, or fluids for a fluid cell) and one free slot at the end,
  **From contents** and **Clear**. A click on a slot (the free one adds, a filled one changes) opens the **picker**
  (issue #94), made like the game's own: the item groups as tabs (fluids in theirs), a search by name (as the
  terminal's), the items and fluids of the group, a row with the **qualities** at the bottom (items only) and the **green
  check** at its right end. Click an element, click a quality, click the check; the confirm key (the game's "Confirm
  GUI", "E" by default) is the check, Enter in the search field too, Escape or the X closes the picker only. A filled
  slot opens it with its element and quality chosen, so both can be changed; right click empties a slot. Only items
  (with quality) and fluids are listed, no virtual signal and no other signal.
* **Card slots:** an item cell takes 4 cards, a fluid cell 3 (AE2): one each of **Inverter Card** (the partition is a
  blacklist: the cell takes everything except it), **Fuzzy Card** (item cells: the partition matches every quality),
  **Equal Distribution Card** (no kind takes more than an equal share of the cell: with a partition of n kinds the
  bytes left after the kinds' costs divided by n, without one by the cell's 63 types; a 1k cell holds 67 of each kind,
  partitioned for two kinds 4032 each) and **Overflow Destruction Card** (what the network stores into the cell and does
  not fit, or exceeds a kind's share, is **destroyed**; a cell without a partition destroys only what it already holds
  once it cannot take a new kind). Shift + click a card in your inventory, or click a card slot with it in hand; a card
  the cell cannot take, a second one of a kind and a card without a cell are refused. While the cell lies in the
  workbench its cards are the items in its card slots; taking the cell out puts them into it.
* **Keep the partition when the cell is taken out** (AE2's copy mode): the partition stays in the workbench and goes
  onto the next cell put in whose partition is empty; a cell put in with a partition shows its own.
* **Without a cell** the partition slots are there too: they show and set the workbench's own partition, the one the
  next cell without a partition gets. It can hold items and fluids (the items first, then the fluids, then one free
  slot; the picker lists both): an item cell takes the items, a fluid cell the fluids. When the partition holds the most
  items (or fluids) a cell takes, the picker offers no more of that kind; the free slot is greyed out when neither is
  left. **Clear** empties it; **From contents** needs a cell. A partition set this way goes onto the next cell also when the copy mode is off; with the
  copy mode off the workbench forgets its partition when a cell is taken out (and when the copy mode is switched off
  without a cell).
* The cards are part of the cell (its tags): they travel with it into drives, chests and the network, like its items
  and partition. Only the workbench puts cards in or takes them out; the cell window (drive window, the terminal's
  Cells tab) shows them and keeps its partition buttons, so nothing a player used goes away.
* Mined, the workbench gives its cell back (with the cards of its slots in it); destroyed, it drops it.
* Two players at one workbench or storage bus see the same slots; what one of them puts in or takes out the other sees
  at once.

## Old saves (from before the rework)
## Old saves (from before the rework)

Old ME networks are converted when the save is loaded (`docs/ME-REWORK.md`, "Migration"): the old controller
becomes an ME Controller, every old drive an ME Drive with four cells of its tier holding its items, every old
interface an ME Interface (its items go into the network), and ME cables are laid from the controller to every
block of the old network. Further old controllers of the same network become items in the network. Items the
new cells cannot hold go into iron chests next to the controller (the chat names them). A block that no cable
can reach (walled in, on water) is named in the chat: connect it yourself. Items in vanilla chests of the old
logistic network stay there. The game removes ghosts of the old blocks when the save is loaded.

**The old fluid blocks** (ME Network 0.1.0 and Gregtorio Continued before 0.5.0: ME Fluid Interface, ME Fluid
Import Bus, ME Fluid Export Bus, ME Fluid Storage Bus) become the unified blocks when the save is loaded
(`docs/ME-REWORK.md`, "Items and fluids in one block"), in place and with their settings: a fluid interface in
import mode an ME Interface whose sides import, one in export mode an ME Interface with a fluid row of its fluid and
level kept on all four sides; the fluid buses import and export buses with their fluid filters; a fluid storage bus a
storage bus with its mode, priority and filters. No fluid is lost (the log line `FORK-ME-MIGRATE: unified` counts
it). Their ghosts become ghosts of the unified blocks; their items, in inventories, chests, the network's cells, cells
in chests (when they are put into a drive), blueprints in inventories, patterns and level maintainers, become the
unified items. An old blueprint from the blueprint library still builds the unified blocks with their settings.

## Autocrafting: how to build it

Tech `me-autocrafting` (EV, needs `me-storage-64k`) unlocks:

| Thing | What it does |
|---|---|
| **ME Blank Pattern** | cheap item (LV assembler: 2 glass, certus quartz, aluminium plate, fluix cable). Encoded in the ME Terminal's **Patterns** tab |
| **ME Encoded Pattern** | item with tags, stack size 1: one pattern. Its tooltip lists the kind, the inputs and the outputs |
| **ME Pattern Provider** | 1x1, no power, a member of the network. Holds **9 encoded patterns**; each one is a pattern of the network. The machines on the four tiles around it (or a chest there) do the work |
| **ME Molecular Assembler** | assembling machine for item-only crafting recipes (crafting table and assembler recipes up to EV, no fluid boxes), speed 6, 960 kW |
| **Crafting blocks** | 1x1 members of the network; a solid rectangle of them with at least one **crafting storage** is a Crafting CPU running one job (see [Crafting CPUs](#crafting-cpus)). The first: a single **ME 1k Crafting Storage** |

Step by step:

1. Build an ME network: ME Controller (powered), at least one ME Drive with cells and items, an ME
   Terminal (powered), all connected.
2. Build a **Crafting CPU** touching the network: the smallest is one **ME 1k Crafting Storage** next to a cable.
   One CPU = one job at a time, of at most its crafting storage in bytes; a second CPU (not touching the first)
   lets two jobs run in parallel.
3. Put **blank patterns** into your inventory (or into the network) and encode them in the terminal's
   **Patterns** tab (below): a **crafting pattern** for each recipe the network should craft.
4. Place a machine (Molecular Assembler for crafting recipes, a GT machine for processing recipes: macerator, EBF,
   wiremill, chemical reactor, ...) with power, put an **ME Pattern Provider on a tile touching it** (left, right,
   above or below) and connect the provider to the network (the machine needs no cable). Open the provider and
   click a slot with an encoded pattern in hand (or click the provider with a pattern in hand: first free slot).
   The machine needs **no recipe**: the provider sets the pattern's recipe on it for each job. One machine serves
   all patterns of its provider (one job at a time), one provider up to four machines around it.
5. Open the ME Terminal, tab **Crafting**: every item and fluid a pattern can make is listed
   (also at 0 in stock). Click one, enter an amount (items, or fluid units), and read the plan preview:
   `Ready: 12 crafts in 3 steps` with what is taken from storage, or the **missing** items and fluids as
   red slot buttons. With something missing the Craft button stays disabled. Click **Craft**; the job
   appears in the **Jobs** tab (and in the window of the CPU that runs it) with its progress and a
   **Cancel** button.
6. When the job is done, the result (and any by-products) is in network storage.

### Patterns: encoding and clearing

The terminal's **Patterns** tab:

* **Crafting / Processing** switch.
* **Crafting pattern:** choose a recipe with the recipe button (the game's recipe chooser, with its search). Only
  researched recipes are accepted. The inputs and outputs (fluids too) come from the recipe and are shown.
* **Processing pattern:** up to **9 inputs** and **6 outputs**, each an item or fluid (signal button) with an amount
  per run. The recipe button fills the rows from a recipe ("Fill from a recipe"), which is the quick way to a
  furnace pattern. Items with tags (cells, patterns) cannot be inputs or outputs.
* **Encode** takes one blank pattern from your **hand**, else your **inventory**, else the **network**, and gives
  the encoded pattern into your hand (where the blank was, or an empty hand), else into your inventory. The line
  below shows how many blanks are in each place.
* **Load pattern in hand** copies the pattern you hold into the editor (to change and encode it again).
* **Clear pattern in hand** turns the encoded pattern you hold back into one blank pattern (AE2: shift right click;
  a click on an item in the inventory cannot be caught by a mod, so it is this button).

Encoded patterns can be stored in the network like any item (they keep their pattern; equal patterns stack in the
network), but the planner never uses them as ingredients.

### Crafting patterns: the provider sets the recipe

A crafting pattern names a recipe. For each hand-over the provider looks for an **assembling machine** next to it
that can make the recipe: its crafting categories, the recipe researched, no fixed recipe of its own, every item
ingredient fits into a slot, and fluid boxes for the recipe's fluids without pipes (see **Fluids** below).

* A machine that already has the recipe and is idle is used first; else an idle machine is **switched**: the
  provider calls the game's `set_recipe`. The machine must be idle (no craft in progress). **What is left in it**
  (items in its input and output, fluid in its boxes) goes **into the network** first; if the network cannot take
  all of it, the machine is not switched and the job waits. Nothing is lost on a switch.
* **One machine, many patterns:** a machine works for one job at a time. A job that needs a machine that is busy with
  another job (or another pattern) **waits** ("Waiting for a free machine") and takes it at the next step after it is
  free. Jobs take turns: one job per tick (setting "Crafting jobs stepped per tick"), each one every 20 ticks at most.
* The machine keeps the recipe of the last job; it is never switched back.
* **Cannot make it:** a pattern whose machines cannot make the recipe is no pattern of the network: the provider
  window shows why (`category`: no machine of the right kind, `not-researched`, `fixed-recipe`, `stack`, the fluid
  reasons, `furnace`: a furnace has no recipe setting), and the crafting tab's info line counts it.

### Processing patterns: furnaces, machines with their own recipe, lines

A processing pattern has free inputs and outputs. The provider **pushes the inputs** into what is next to it:

* a **furnace** (stone, iron or steel furnace, any `furnace` machine): it picks its recipe from the input. Encode the
  furnace recipe as a processing pattern ("Fill from a recipe" in processing mode). A crafting pattern next to a
  furnace is no pattern (status `furnace`).
* an **assembling machine with a recipe of its own** (set by you; the provider never changes it): the inputs go into
  it like an inserter would put them. A machine without a recipe cannot take a processing pattern (`no-recipe`).
* a **chest** (iron, steel, logistic chest): the start of a production line. Items only.

**Outputs** come back in two ways, and both count:

1. from the machine's output (items and fluid output boxes), collected when the machine is idle again;
2. **into the network**, through an ME Import Bus, an ME Interface, a fluid interface or bus, or the terminal: while
   a job waits for the outputs of a processing pattern, **every item or fluid of those kinds that enters the
   network is taken by the job first** (up to what its runs still owe), as in AE2. Outputs that a storage bus merely
   sees appearing in a chest do not count (they are not inserted).

A run is done when all its outputs are back. Until then the job shows "Waiting for the outputs of a processing
pattern to come back"; with no progress at all for 5 minutes it fails (and gives back what it still holds). What a
job pushed into a chest is in the line: a cancelled or failed job cannot take it back, and outputs that come back
later simply go into storage. If a machine takes none of the inputs (wrong recipe, full), they come back into the job
and that machine is not used again by that job.

### Several patterns for one item: the pattern order

If several patterns make the same item or fluid, they are tried in **pattern order**: providers with a higher
**priority** first (set in the provider window, -1000 to 1000, default 0), at the same priority the provider built
first, within a provider by slot. The planner takes the first pattern whose plan needs nothing missing, else the
first one. Equal patterns in two providers are one pattern: its machines are pooled.

### Rules for pattern machines

* **Dedicate them to the network.** While a job runs the CPU puts ingredients into the machine
  and takes its products out, and crafting patterns change its recipe. Do not feed them with inserters, belts or
  pipes as well.
* A provider that is not connected to the network, or that touches no machine, makes no pattern; its patterns stay
  in it.
* The machine has to work on its own: power (or fuel), a mold in the mold slot if the recipe
  needs one, modules as you like. A machine that cannot run makes the job wait; it fails after
  5 minutes without progress and returns its items.
* **Fluids:** once `me-fluid-storage` is researched (see below), recipes with fluid ingredients
  or fluid products work as patterns, provided the fluid boxes the recipe uses have **no pipes
  connected**: the network fills the input boxes and drains the output boxes itself. The
  Molecular Assembler has no fluid boxes, so fluid recipes need a GT machine (chemical reactor,
  extractor, ...). Not usable, and counted per reason in the crafting tab's info line: patterns
  that need more of one ingredient than fits into a machine slot (`stack`), no usable box for the recipe
  (`fluid-box`: box too small for one craft, no matching box, a furnace or a chest with fluids), a pipe on a used
  box (`fluid-pipes`), and recipes that need a fluid temperature the network cannot deliver (`fluid-temperature`,
  see the temperature rule below).
* Only normal quality items are planned and crafted.

### Patterns in providers: mining, destroying, blueprints

* **Mined** (by hand or by robots): the patterns come with the provider (into the inventory or the robot's cargo).
  **Destroyed**: they drop on the ground. A provider that disappears without an event (removed by another mod's
  script) drops them where it stood, at the next scan.
* **Blueprints, copy and paste:** a blueprint keeps the provider's priority and its **patterns as data**. An encoded
  pattern is an item, so a blueprint never creates one out of nothing: a provider built from a blueprint shows the
  patterns as "waiting for a blank pattern" (yellow) and **encodes each one from a blank pattern of its network**
  as soon as the network has one (within a few seconds). Click such a slot to forget it. Old blueprints (0.4.1 and
  older) with a furnace recipe choice give a processing pattern of that recipe, the same way.
* **Settings paste** (shift right click, shift left click) and cloning copy the **priority** only; patterns are items
  and stay where they are.

## Crafting CPUs

A Crafting CPU is built, as in AE2, from **crafting blocks** (issue #6). Every block is 1x1, a member of the ME network
like any ME block (it draws its power through the ME Controller; without power the CPU waits). **Any group of touching
crafting blocks that is a solid rectangle (no gaps) and holds at least one crafting storage is one Crafting CPU.**
There is no core block, and any number of CPUs may be in a network; two CPUs must not touch (touching blocks are one
group).

| Block | Crafting storage | What it does | Power | Recipe (standalone) | Technology |
|---|---|---|---|---|---|
| ME Crafting Unit | | fills the rectangle | 4 kW | 4 iron plates, 2 advanced circuits, 2 fluix cables, 1 electronic circuit | `me-autocrafting` |
| ME 1k Crafting Storage | 1 024 bytes | holds the job | 4 kW | crafting unit + 1k storage component | `me-autocrafting` |
| ME 4k Crafting Storage | 4 096 bytes | | 8 kW | crafting unit + 4k storage component | `me-autocrafting` |
| ME 16k Crafting Storage | 16 384 bytes | | 16 kW | crafting unit + 16k storage component | `me-co-processing` |
| ME 64k Crafting Storage | 65 536 bytes | | 32 kW | crafting unit + 64k storage component | `me-co-processing` |
| ME 256k Crafting Storage | 262 144 bytes | | 64 kW | crafting unit + 256k storage component | `me-quantum-crafting` |
| ME Crafting Co-Processing Unit | | the CPU hands work to the machines once more per step | 32 kW | crafting unit + processing unit | `me-co-processing` |
| ME Crafting Monitor | | shows the job | 4 kW | crafting unit + small lamp + electronic circuit | `me-autocrafting` |

* **The smallest CPU** is a single 1k crafting storage touching a cable: it runs a job of 100 electronic circuits from
  plates (932 bytes). Bigger CPUs: more or bigger storage blocks in one rectangle (their bytes add up), filled up with
  crafting units, co-processing units and monitors as you like.
* **Bytes of a job** (AE2's rule): the amount ordered, plus for every step of the plan its crafts and all the
  ingredients of those crafts (1 byte per item, 1 byte per 10 fluid units), plus 8 bytes per step and per item or
  fluid taken from storage. 100 electronic circuits need 932 bytes, 50 processing units from plates, plastic and acid
  12 189 bytes (a 16k crafting storage).
* **One job per CPU.** A job starts only when a CPU of the network is free and big enough; it takes the smallest one
  that fits. Otherwise the Craft button tells why ("needs N bytes, the biggest CPU has M", or "every CPU that can take
  it is busy") and starts nothing; a level maintainer waits and tries again.
* **Speed:** every co-processing unit lets the CPU hand one more batch to the pattern machines per step: a CPU with n
  co-processors is 1 + n times as fast (at most 16 count). It matters when a job has many machines for the same
  pattern; the machines still craft at their own speed. Three co-processors make a CPU as fast as the old Quantum CPU.
* **Not a CPU:** a group with a gap or a corner missing, or one without crafting storage, is no CPU: its blocks stay
  dark (the blocks of a CPU are lit) and its window says why ("its 7 blocks do not fill their 3 x 3 area", "it has
  no crafting storage").
* **The plan preview** in the terminal's Crafting tab shows the bytes the job needs and the CPUs of the network: those
  that can take it now, those big enough but busy, those too small (each with its number, size, bytes and
  co-processors). The Craft button is off when no CPU can take it now.
* **The CPU window** (click any block of the CPU): status, size, crafting storage used by its job and total,
  co-processors and speed, monitors, and the job with its progress and **Cancel**.
* **ME Crafting Monitor:** shows the item or fluid the CPU is crafting and the amount on its face (several monitors
  all show it).
* **Changing a running CPU:** remove a block and the job **pauses** with everything it holds (nothing is lost: its
  items and fluids are kept by the job, not by the blocks). It goes on as soon as a free CPU of the network is big
  enough, which may be what is left of its own CPU; until then it shows "Paused: waiting for a free CPU with at least
  N bytes", and **Cancel** gives everything back. A block added to a running CPU (a co-processor) helps at once.
* Blueprints, copy and paste and cloning build the blocks; they form a CPU when the rectangle is complete.

### The old Crafting CPUs (legacy)

The single 2x2 CPUs of earlier versions (issue #38) are **legacy blocks**: they can no longer be crafted, but those in
a save, or in your inventory, keep working as before, and their running jobs go on through the update on the same CPU:

| Entity | Jobs at once | Speed | Power |
|---|---|---|---|
| ME Crafting CPU | 1 | 1x (6 machine hand-overs per job every 20 ticks) | 60 kW |
| ME Co-Processing Crafting CPU | 2 | 2x | 240 kW |
| ME Quantum Crafting CPU | 4 | 4x | 960 kW |

They have no byte limit. A job takes a free multiblock CPU first, a legacy CPU with a free slot after that. A job is
no longer queued behind busy CPUs: with every slot busy, the start is refused. The upgrade planner still swaps the
legacy tiers (a job on the replaced CPU pauses and goes on on the new one).

## Keeping items in stock: ME Level Maintainer

Tech `me-automation` (EV, needs `me-autocrafting` and Circuit network). The **ME Level Maintainer** is
a 1x1 block that needs power (30 kW) and is a member of the network.

1. Connect it to the network and power it. Autocrafting must work for the resource: a pattern
   (an encoded pattern in a provider next to a machine) and a Crafting CPU big enough for the difference.
2. Click it: its ME window opens. Choose the item or fluid in the signal button and type the amount to
   keep (items, or fluid units).
3. When the network holds less than that amount, the maintainer starts a crafting job for the
   difference, the way the Craft button does. It checks about once a second (several maintainers take
   turns, see **Design**).
4. While that job runs, it starts no other one; nor does it while any other job of the network crafts
   the same resource (for example one you started in the terminal). When the job is done and the stock
   is reached again, it waits until the stock drops.

What the window says:

| Status | Meaning |
|---|---|
| Enough in stock | nothing to do |
| Crafting job N is running | its job; the progress is also in the terminal's job list |
| Another job of this network is crafting it | waits for that job |
| Waiting for a Crafting CPU with a free job slot | all CPUs are busy: the maintainer does not queue jobs, it waits and tries again |
| Waiting for a free Crafting CPU that is big enough for the job | the CPUs that could take the job are busy |
| Waiting: the job is bigger than every Crafting CPU of this network | add crafting storage (or keep a smaller amount) |
| Cannot craft the difference, missing: ... | the plan lacks raw materials; it tries again every 5 seconds |
| No pattern for this item or fluid | no usable encoded pattern for it in a provider of the network |
| Switched off by the circuit condition | see below |

**Circuit network** (connect a red or green wire to the maintainer):

* **On/off:** tick "Switch on and off by the circuit condition" in the window and set the condition
  (signal, comparator, number; it is the lamp's circuit condition). While the condition is false it
  starts nothing; a running job goes on.
* **Amount from the circuit:** tick the box in the window. The signal of the chosen item or fluid on
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
* only the resources chosen as **filters**: click it, its ME window has up to 20 signal buttons and the
  output on/off switch. Items and fluids only; without filters everything is sent.

The signals are refreshed about once a second, and only when the network's contents changed (all circuit interfaces
of the map together at most 10 times per second, setting "Circuit interface updates per second": with many
interfaces each one less often). The signals are listed by type and name (the 1000 largest amounts when there are
more). The network writes the combinator's signal list: entries added by hand are replaced, extra sections are removed; the combinator's on/off switch still turns the
output off (also in the ME window). Filters are copied by settings paste and kept in blueprints, copy and
paste, and clones. Since
issue #68 the ME Controller has no circuit connection (it was a roboport): the Circuit Interface is the way to
read the network. Items with tags (loaded cells) count under their item. Up to 1000 signals per interface (the
largest amounts first).

## Settings in blueprints and copy/paste

| Entity | Settings | Settings paste | Blueprint, copy/paste, clone |
|---|---|---|---|
| ME Pattern Provider | priority; its patterns (blueprint only, encoded from blank patterns of the network) | yes (priority) | yes (patterns pending a blank pattern); clone: priority |
| ME Interface | config rows (item with quality, or fluid; amount), the four sides, the priority | yes | yes (old blueprints with slot filters, and of the old fluid interface, are converted) |
| ME Import Bus, ME Export Bus | filters (items and fluids); which Acceleration Cards it has | yes (the cards from your inventory, then the network; extra cards into your inventory) | yes (the cards are taken from the network as soon as it has them) |
| ME Storage Bus | mode, priority, filters (items and fluids), filter on extract; which upgrade cards it has | yes (the cards from your inventory, then the network; extra cards into your inventory) | yes (the cards from the network, when it has them) |
| ME Drive | priority, the partition of each slot | yes (every slot) | yes; the cells are items, not settings: a drive from a blueprint is empty, a slot keeps its partition for the next cell |
| ME Level Maintainer | resource, amount, amount from the circuit; the lamp's circuit condition | yes | yes |
| ME Circuit Interface | filters | yes | yes (the signals of the moment in a blueprint are rewritten when it is built) |

### A machine's recipe onto an ME block

Like a requester chest: **shift + right click** a crafting machine (an assembling machine, a furnace, a rocket silo,
the GregTech machines of Gregtorio Continued, the machines of every other mod) and **shift + left click** an ME block.
The block is set up for the machine's recipe; what it had is replaced:

| Paste onto | Result | Kept | Holds |
|---|---|---|---|
| ME Interface | config rows = the ingredients in the recipe's order: one full stack of each item (whatever one craft needs), a fluid row of a side's volume for each fluid | sides that are off; a side tied to a fluid that is in the recipe again | 9 rows, 4 fluids |
| ME Storage Bus | filters = the ingredients: on a chest or cargo wagon the items, on a tank the fluids, facing nothing yet both | mode, priority, filter on extract, the cards | 18 filters (9 more per Capacity Card) |
| ME Export Bus | filters = the ingredients, items and fluids | | 9 filters |
| ME Import Bus | filters = the **products**, items and fluids | | 9 filters |

* The recipe's quality is the quality of the interface's item rows and of the storage bus's item filters. The
  import and export bus filter by name: the export bus moves normal quality only (a flying text says so).
* A furnace that is not smelting gives its last recipe.
* A new fluid row gets the side a new fluid row gets in the window: the first import side with a pipe, else the first
  import side (the flying text says that it has no pipe yet). A side tied to a row that goes away imports again.
* A flying text names what did not fit, a fluid row with no side left (every side off or tied: set one in the
  window), and a machine without a recipe. Nothing is changed when the recipe has nothing for the block (no
  ingredients; a storage bus on a chest and a recipe of fluids only, or on a tank and no fluid).
* A paste between two ME blocks of the same kind copies the settings as before.

## Fluids

Tech `me-fluid-storage` (EV, needs `me-autocrafting`) unlocks 1k to 64k **fluid storage cells**;
`me-fluid-storage-256k` (IV, also needs `me-storage-256k`) the 256k fluid cell (`prototypes/fluids.lua`). Since
issue #68 step R2 fluids are stored like items: in cells in the ME Drive. The ME Interface and the ME Import, Export
and Storage Bus move fluids from the start (issue #3 of ME Network, like AE2's); before, the ME Fluid Interface and
the ME Fluid Import, Export and Storage Bus did that and came with this technology.

| Thing | What it is |
|---|---|
| **Fluid storage cell** (1k ... 256k) | storage housing + storage component of the tier + a pump. Goes into an ME Drive slot like an item cell; a drive may hold item and fluid cells in any mix |
| **ME Interface** | its four sides (a tank of 5000 units each) are the import/export point for pipes |
| **ME Import Bus / Export Bus** | 1x1, rotatable: takes fluid out of / puts fluid into the machine or tank it faces |

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
  Fluids cannot be taken by hand: use a fluid row of an ME Interface or an export bus.
* **Import (interface):** connect pipes to a side of an ME Interface. A side imports by default: everything in the
  pipes and tanks connected to it goes into the network. Pipes and tanks connected **without a pump** in between
  form one fluid segment with the side, and the whole segment is emptied (a full storage tank within a second).
  With a pump in front of the interface the fluid arrives at the pump's rate. Import stops when the fluid cells are
  full.
* **Export (interface):** click the interface, choose a fluid in a config row and its amount (0 to 5000), and tie a
  side to that row (the first free side with a pipe is tied by itself). The network fills that side with the fluid
  up to the amount and refills it as pipes and machines take it. Pipes and tanks connected without a pump share that
  level with the side; a pump behind the interface takes the fluid away at its rate. Another fluid still in the side
  is imported first (if the cells have room). The window shows what each side holds and, on hover, its status
  (working, the network has no room, the network does not hold this fluid, ...).
* **Fluid cell partition:** a fluid cell can be partitioned for fluids like an item cell for items (see
  **Partitions and priorities**).
* **Buses:** the import bus empties the output boxes of the machine it faces (a tank: all of it), the export bus
  fills its filtered fluids into the machine's input boxes or the tank. Up to 4000 units per second (setting "Bus
  speed: fluid per second"), fluid filters next to the item filters
  (import: none means everything), kept in blueprints, settings paste and clones.
* **Blueprints:** a drive from a blueprint is empty (cells are items; priority and partitions are kept). The rows and
  sides of an ME Interface are kept in blueprints and copied by settings paste and cloning.

**Temperature:** the network stores fluids by name only, without a temperature. Importing drops the temperature;
an export, an export bus and the hand-over to a pattern machine deliver the fluid at its default
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

## What the network costs: /me-stats

`/me-stats` prints, in the chat, what the ME network near you does. It works for every player (no admin rights) and costs
nothing while you do not use it.

* `/me-stats`: the network of the ME block you have open, otherwise of the nearest ME block within 10 tiles.
  * **Members** by kind (controller, cables, drives, interfaces, buses, level maintainers, crafting blocks, ...).
  * **Interfaces and buses** by state: *busy* (they have work and are visited when their machine's buffer needs it),
    *probing* (they wait for something on the machine's side: `empty` source, `full` target, `no-target`, `idle`; one cheap
    look now and then) and *parked* (they wait for the network: `no-key`, the item is not in the network, `net-full`,
    `no-network`, `no-power`; they cost nothing until the network wakes them, with one slow look a minute as a safety net).
    A network with many parked blocks and few busy ones is quiet; a network with all blocks busy and a high backlog is
    where a base starts to cost script time.
  * **Level maintainers** and **crafting**: the CPUs (and how many have a job) and the jobs running or queued.
  * **The scheduler of the whole map** over the last minute (a window of one to two minutes, or since the load): per kind of
    block the visits per tick against the budget of the map settings (the first number is "at least", the second "at most"),
    the probes per tick, the average backlog (blocks that were due and waited), the *starved* arrivals (a visit that found
    its machine's chest empty or its tank full: the machine ran dry) with how long the other side had been out (an estimate:
    from the tick the visit before expected it to run out at the rate it saw; "ran out sooner" counts the arrivals where it
    emptied faster than that rate said, so no estimate is given), the *missed wakes* (a parked block whose slow look found
    work: a bug; "0" is right) and the wakes, and the time between two visits of a block that had work (median, 99th
    percentile, longest; under a second in ticks). The counters are your own: they start at zero when you load the game and
    are not saved.
* `/me-stats all`: one line per network of the map (up to 25), then the scheduler.

The command reads counters the scheduler keeps anyway; once every 3600 ticks it copies them for the window. Its
numbers and its cost are in `docs/PERFORMANCE.md`. Tests: `ME stats command test` in `devcheck.py runtime`, which also
renders the lines through the engine and fails on a missing locale key.

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
network and does nothing when the network does not work. `scripts/fork-me-io.lua` visits the interfaces and buses
(since issue #5 of ME Network each one at a tick of its own, `scripts/fork-me-schedule.lua`, from the one `on_tick`
handler of `control.lua`), `scripts/fork-me-migrate.lua` converts old
networks, `scripts/fork-me-terminal.lua` is the terminal and routes the GUI events of every ME window.

### Upgrade cards and priorities (me-network issue #17)

Design record: `docs/ME-REWORK.md`, "Upgrade cards, storage bus settings, the Cell Workbench and priorities" (AE2's
numbers with their source, the cards' storage, how a blacklist, a fuzzy filter, "filter only what goes in" and the void
fit into the storage engine's lookups, the interface shortfalls). The cards are items (`prototypes/cards.lua`); a
storage bus keeps them in its record (`rec.cards`, `rec.want`); `apply()` in `scripts/fork-me-storagebus.lua` turns
filters and cards into `partition`, `deny`, `fnames`, `void` and `inonly`, which `accepts()` and the lookups of
`scripts/fork-me-network.lua` read. A network without cards takes exactly the code paths of 0.3.0.

### Windows (issue #68, R3)

`scripts/fork-me-gui.lua` is the shared GUI: one window per player (`player.gui.screen.fork_me_window`, the
player's `opened`), title bar, content frame, slot buttons, number fields and the k/M/G formatting. Every acting
element carries its action in its tags (`fork_me_act`); the modules register actions (`G.on`) and windows
(`G.window(name, { open, refresh, entities })`, entities by name or ME kind). The terminal module registers every
GUI event once and hands it to `G.dispatch`; the open key and `on_gui_opened` call `G.open_entity`, which replaces
the game's window (setting `opened` to the ME window). `G.open_vanilla` lets the game's window through once (the
ME Interface's "Open inventory", a flag in `storage.fork_me_gui_bypass`, cleared by the next open key). The
terminal step (every 60 ticks) refreshes the open windows (`G.refresh_all`, at most 30, one per player) and closes
a window whose entity is gone or out of reach; a window rebuilds a part only when its data changed (a signature in
the part's tags), so focused text fields keep their text. `scripts/fork-me-windows.lua` builds the block windows;
each shows data from a `*_data` function and changes things through a function of the block's module or a small
`set_*` helper; the remote interface `gregtorio-me-gui` exposes the same functions to the runtime test. Nothing of a
window is in storage except the terminal's tab, search, sort, kind and picked craft
(`storage.fork_me_terminal[player]`).

Issue #28 (`docs/ME-REWORK.md`, "Windows with the player's inventory"): a window can have the **inventory pane**, the
player's main inventory drawn by the mod on the left of the content (`G.open_window(..., pane)`): one slot button per
slot, updated through `on_player_main_inventory_changed` and `on_player_cursor_stack_changed` for the slots that changed
only (`G.update_pane`, signatures in `storage.fork_me_gui_pane[player]`). Its clicks (`G.inventory_click`) pick up, put
down, merge, swap and halve stacks like the game's, and shift + click hands the stack to the window's `shift`; the
block's slots are buttons whose click goes to the window's `click`, which refuses a wrong item before anything moves.
A slot's tooltip is the item's own (`elem_tooltip`) and, below it, the stack's description when it has one (issue #75: a
cell's contents, partition and cards, a pattern's recipe; `G.stack_tooltip`), then the slot's own hint. The terminal's
storage tab and every other grid of items kept in the network show the same for a stored cell or pattern (issue #79):
the description is part of its key (`G.key_description`).
The storage bus keeps its cards in its inventory (`rec.inv`, `rec.cards` follows it); the Cell Workbench keeps the cell
in slot 1 and, while it is there, the cell's cards as items in slots 2 to 5 (they go into its tags when it is taken
out).

### Partitions and priorities (issue #68, R3)

A cell's partition is `cell.partition = { [key] = true }` (nil: none), checked in `cell_room` (no room for other
keys), kept in the cell's tags (`fork_me_cell.partition`, also for an empty cell) and cleaned on load
(`clean_partition`: valid prototypes, the cell's kind, no items with tags, at most the cell's types). A drive's
priority is `drives[unit].priority` (nil = 0). Each network caches its cell order (`net.order`: priority
descending, then the order of `cell_list`), marked dirty when a cell joins or leaves or a priority or partition
changes. `insert_key` keeps the old two-pass order when the network has one priority and no partition
(`net.uniform`), else it walks the priority groups with three passes (partitioned for the key, unpartitioned
holding it, unpartitioned with room). `extract_key` sorts the holders of the key (from the index) by priority
ascending, unpartitioned first. Drive settings in blueprints: tag `fork_me_drive = { priority, partitions =
{ ["slot"] = { keys } } }`, applied in `on_built` from the event's tags; a slot without a cell keeps its template in
`drives[unit].slot_partition` for the next cell placed in it. Settings paste: `me-drive` lists itself in
`additional_pastable_entities`.

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

The **ME Interface's sides** (issue #3 of ME Network) are four hidden 1x1 storage tanks of 5000 units on its tile,
one pipe connection each. The interface is visited by the scheduler (`scripts/fork-me-io.lua`, issue #5); after its
items it looks at its sides. Import side: the tank's fluid is removed
with `remove_fluid`, limited to what the network can take (`can_insert_fluid`); this takes the whole fluid segment.
Export side: `want = amount - held`, `insert_fluid` of `min(want, stored)` at the default temperature. In both
directions only what the engine reports as removed or inserted is booked, never the requested amount, so fluid is
conserved. An interface without fluid rows whose sides held nothing looks at them only every fourth visit.

The **buses** move fluids in the same visit as items (`fork-me-io.lua`, `fluid_bus_step`), when their target has
fluid boxes (decided once, by its prototype, when the target is found): the import
bus reads the target's fluid boxes by index and skips input boxes (`production_type == "input"`), takes at most
what the network can store and writes the rest back into the box; the export bus uses `insert_fluid` (the engine
picks the box) and books what it reports. The bus's speed times the ticks since its last visit (1000 units per 15
ticks by default).

Fluids are stored by name only. One temperature per fluid keeps totals, export and hand-over unambiguous; the
price is the temperature rule above.

### Patterns

Since issue #80 (design record: `docs/ME-REWORK.md`, "Encoded patterns (issue #80)") a pattern is plain data,
`{ kind = "crafting" | "processing", recipe, inputs, outputs }` (rows `{ key, amount }`, resource keys as below),
kept in the tag `fork_me_pattern` of an encoded pattern item (`scripts/fork-me-patterns.lua`: validation
`normalize`, identity `id_of`, tooltip `description`, `encode`, `clear`). A crafting pattern's rows are copied from
its recipe for the tooltip; the planner and the jobs read the recipe itself. The identity of a pattern is
`c/<recipe>` or `p/<sorted inputs>><sorted outputs>`: equal patterns in several providers are one pattern.

`storage.fork_ae2.providers[unit]` holds a provider's `slots` (the patterns exactly as they came out of the items),
`pending` (blueprint patterns waiting for a blank), `priority`, its position (to drop the patterns of a provider that
vanished), and what the scan found: `patterns[slot] = { id, def, targets }` and `status[slot] = { ok, reason,
machines }`. A scan looks at the four tiles around the provider (`find_entities_filtered` on the tile centers: assembling
machines, furnaces, containers, logistic containers) and asks `target_for(entity, pattern)` for each slot: a crafting
pattern needs an assembling machine that can make the recipe (category, research, fixed recipe, stack, fluid boxes:
exactly with the recipe set, by size and count before a switch), a processing pattern a machine ("push") or a chest
("chest"). From all providers, in pattern order (priority descending, unit number, slot), `patterns[network id]`
holds `items[key] = { pattern ids }`, `defs[id]` and `targets[id]` (each machine once); patterns without a target are
counted in `ignored[reason]`. A merge or split of ME networks rescans every provider before the patterns are used
next; a round robin rescan (one provider every 2 ticks) keeps them current and encodes pending blueprint patterns;
starting a job rescans the providers of its plan's patterns first (and plans again if one changed), so the plan sees
its machines as they are now. Resource keys
are item names and `fluid/<name>` for fluids; stock, plan, pool, GUI and the remote interface
use the same keys. A machine with a fluid recipe carries its **fluid map**, built from
`entity.fluidbox` after the recipe is set: which input box (by index) takes which fluid ingredient (the box filter
the recipe set, or recipe order for unfiltered boxes) and which output boxes hold the fluid products, with their
capacities.

### Planning

`need(key, count)` is a recursive resolution: surplus from earlier crafts of this plan, then
storage (normal quality plain items of the network, fluids from `fluids.totals(net)`), then a
pattern. The resource asked for is always crafted (stock is not counted for the top level, as in
AE2). Runs of a recipe are `ceil(count / expected yield)`; probabilities and ranges use the
expected value; fluid amounts stay fractional (14.4 molten tin per craft is planned as such).
Other products of a recipe (by-products) are not credited to the plan (they may not appear),
they simply end in storage. If a resource has several patterns the first one in pattern order
(provider priority, provider built first, slot) that needs nothing missing is used, else the first. Loops (a resource that needs itself) count as missing and
are named in the message. Work is capped at 3000 plan nodes / depth 40 (reported as missing);
amounts up to 100 000 items or 10 000 000 fluid units. Items with tags (cells, fluid drive items) are
never counted as stock, so a job cannot strip their contents.

The result is a list of steps (recipe, runs) in dependency order and the resources taken from
storage. If something is missing the job does not start and nothing is taken.

### Jobs

Starting a job takes the planned resources out of the network into the job's own **pool**
(`storage.fork_ae2.jobs[id].pool`, plain counts per key, so it saves, loads and syncs like any
storage table); items with the network's `extract`, fluids with `fluids.remove`. Reserving at the start
means nothing can be stolen by other jobs or by players taking items while the job runs. A job starts only on a
free CPU that is big enough (issue #6); a job whose CPU changed or went waits ("Waiting for a free CPU") with its
resources reserved.

Each step the CPU of a job:

1. collects machines that are idle again (no progress, no ingredients left): their products go to
   the pool,
2. hands batches (up to 16 crafts, limited by the pool, by one stack per item ingredient, by the
   output slot and by the fluid boxes) to idle machines of the step's pattern, in plan order
   (Molecular Assembler or any other pattern machine, several machines in parallel). Crafting patterns:
   a machine that has the recipe first, else an idle one is switched (`switch_recipe`: its items and fluids into
   the network with `N.no_arrival`, then `set_recipe`; not when the network cannot take them). Processing
   patterns: an idle machine gets the inputs as a lease, a chest gets them directly (no lease),
3. when every step is done, stores the whole pool in the network (result and by-products), items
   with the network's `insert`, fluids with `fluids.insert`. What does not fit stays in the pool
   ("Storing items and fluids (network cells full?)").

A crafting lease counts the crafts the machine made (`products_finished`); a processing lease counts the runs
whose inputs the machine used (`given` minus what is taken back), and the step counts the runs whose **outputs**
are back (`step.received`): from the machine's output when the lease ends, or as **arrivals**: the network module
offers every insert of its public functions (`insert`, `insert_stack`, `insert_partial`, `insert_fluid`) to
`N.on_arrival` first, and a running job with processing steps that still owe that key takes it into its pool (index
`storage.fork_ae2.await`: network -> key -> job ids, rebuilt when processing work is handed out, a job ends or the
graph changes; `can_insert` counts what jobs wait for as room). The jobs' own stores (pools, a machine emptied for a
switch) set `N.no_arrival`. A job whose processing steps wait only for outputs shows `wait = "outputs"`.

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
| Pattern provider | its patterns are no patterns any more (mined: into the buffer; destroyed: on the ground); a running job finishes what is already in the machine and waits for another machine of the pattern |
| A drive or a fluid cell during a job | nothing happens to the job: its items and fluids are in its pool, not in a cell. At the end the pool is stored in the remaining cells, or waits for room |
| Fluid interface | nothing for jobs; what it holds goes back into the network (as far as the cells have room), its mode, fluid and level are forgotten |
| A block of a multiblock Crafting CPU (issue #6) | the job pauses (queued) with its pool and its leases, and takes the next free CPU with enough bytes, the rest of its own CPU included |
| Terminal, controller, a cable | jobs without a working network pause ("No ME network"). A job finds its network through its CPU, else through the entity it was started at (terminal, level maintainer), else through the ME block at its position (jobs of older saves) |

### CPU tiers (issue #38)

The tier numbers come from the mod-data `fork-me-autocraft` (`cpus[name] = { jobs, speed }`, written by
`prototypes/autocrafting.lua`), so the runtime has no copy of them. A CPU record holds the
jobs it runs (`cpus[unit].jobs = { [job id] = true }`; a record of an older save with a single `job` is
converted when it is first read). `assign_cpus` gives a queued job the fastest CPU of its network with
fewer jobs than slots. A job's machine interactions per step are `STEP_OPS` (6) times the speed of its
CPU for every 20 ticks since its last step (at most three steps' worth: a job that waited for its turn catches up). A CPU that is replaced or removed releases its jobs, which
queue and take the next free slot (the path the existing CPU test covers).

### Crafting CPUs as multiblocks (issue #6)

Design record: `docs/ME-REWORK.md`, "Crafting CPUs as multiblocks". In short: the groups of touching crafting blocks
are kept in `storage.fork_ae2` (`cblocks`, `cgrid`, `groups`) from the build and removal events (a vanished block from
the network's sweep), merged on a build and split by one search over the group on a removal; a group is a CPU when its
block count fills its bounding box and it has storage. `make_plan` returns `bytes`; `M.start` picks the CPU at once
(`pick_cpu`: free multiblock CPUs that fit, smallest first, then legacy CPUs with a slot) or refuses the job
(`cpu-too-small`, `no-free-cpu`). `assign_cpus` only places jobs that were paused. Nothing of this runs while no
block is built or removed.

### Level maintainer and circuit interface (issue #38)

`scripts/fork-me-circuit.lua` keeps `storage.fork_ae2.maintainers` / `mlist` / `mq` and `circuits` /
`clist` / `cq` (created lazily) and runs as a tick hook of the autocrafting module: each maintainer and interface is
due at a tick of its own (issue #5, `scripts/fork-me-schedule.lua`).

* **Maintainer check** (4 per tick at most, setting): a stocked maintainer waits until its item is taken below its
  amount (`N.wait_below`) and is checked at least every 5 seconds (circuit targets and conditions have no event);
  its job's end wakes it. no resource, no power, `cb.disabled` of the lamp's
  control behavior while its circuit (or logistic) condition is switched on (a freshly wired lamp reads
  `disabled` until its next circuit update, so the flag alone is not trusted), no network: status only. Otherwise the target is the amount,
  or the resource's signal on red plus green (`get_circuit_network(wire).get_signal`). The stock is
  the network's `count` (normal quality) or `fluid_count`. Its own job still queued or running:
  nothing. Stock below target: if an active, not closing job of the network crafts the same key
  (`active_job_for`), nothing; else, if a powered CPU has a free slot (`free_slot`), `M.start` with the
  difference and the maintainer's unit number as the job's `owner`. At most one start per tick (a start
  rescans the providers of its plan and plans); a failed start (missing, no pattern) waits `RETRY_TICKS` (300).
* **Circuit interface update** (10 per second for the whole map, setting; each interface at most every 60 ticks): the
  network's totals (with quality; items with tags under their item) and fluid totals (floored, at least 1 unit)
  as one list per network (`net.sigs`, made at most every 60 ticks while the contents change, shared by every
  interface), filtered by key, the 1000 largest amounts, sorted by type and name, are written as the filters of
  section 1 of the combinator's control behavior; other sections are removed. An interface writes only when the
  list changed since its last write.
* **Settings copy:** blueprint tags `fork_me_maintainer` (`{ key, amount, circuit }`), `fork_me_circuit`
  (`{ filters }`) and `fork_me_fluid_interface` (`{ mode, fluid, level }`), written by the one
  `on_player_setup_blueprint` handler (autocrafting module: providers, then `fluids.tag_blueprint`, then
  the blueprint hooks) and read in the built events from `event.tags`; `on_entity_settings_pasted` and
  `on_entity_cloned` copy the records. The fluid interface prototype lists itself in
  `additional_pastable_entities`, since a storage tank has no settings of its own.
* **GUI:** the ME windows of `scripts/fork-me-windows.lua` (see **Windows** above); the maintainer's on/off
  condition is the lamp's own circuit condition, set through `set_condition`.

### Throughput and UPS

* Since issue #5 of ME Network everything runs from one `on_tick` handler, spread over the ticks (the terminal
  refresh stays at 60 ticks; numbers in `docs/PERFORMANCE.md`).
* One job per tick (round robin), each at most every 20 ticks, at most 6 machine hand-overs/collections per job per
  20 ticks on the base CPU (12 on a Co-Processing, 24 on a Quantum CPU), so a base CPU job moves up to about 18
  machine interactions per second, however many jobs run. That matches an assembler line
  and keeps a step cheap; a job with more machines is throttled by the CPU, a faster CPU lifts it.
* Level maintainers and circuit interfaces: up to 4 maintainer checks per tick (cheap: a count and a few table
  lookups) with at most one job start per tick (the only expensive part: a rescan of the plan's providers and a
  plan, like the Craft button; a failed start waits 5 seconds), and circuit interface updates (one list per
  network and one write of the section each).
* One provider rescan every 2 ticks, planning only on user actions (terminal GUI: while a craft item is
  selected, once per second from the cache). An arrival is one table lookup per insert (network, key) when no job
  waits for that key; the index of waiting jobs is rebuilt only when it changes (no tick of its own).
* Interfaces and buses: up to 16 visits per tick (`docs/ME-REWORK.md`, "Scheduler and performance at size"), up to 8
  storage bus visits per tick and side (one `get_contents` each, the difference to the last look applied to the network's totals; cost for 50
  buses in `docs/ME-REWORK.md`, "Storage bus (after R3)"), 8 fluid storage bus visits (three calls on one fluid box
  each, about 15 µs; cost for 50 in `docs/ME-REWORK.md`, "Fluid storage bus"); the ME Interfaces' sides are part of
  their visit (one `remove_fluid` or `insert_fluid` per busy side); a network's fluid total is a table lookup (the
  storage engine's totals), never a loop over tanks, pipes or drives. Buses move up to 4000 units of fluid per second.
* The terminal step every 60 ticks: the open ME windows (at most 30, only players with one open), the lights of
  up to 50 changed drives and a sweep over 200 network members (members removed without an event).
* No loops over the whole network (the one per-tick handler only takes what is due). State lives in `storage.fork_me_net`, `storage.fork_me_io`,
  `storage.fork_ae2` and `storage.fork_me_fluids`; GUI state lives in the GUI elements' tags and
  `storage.fork_me_terminal`.

### Recipe paste (me-network issue #12)

`scripts/fork-me-recipe-paste.lua`. The game raises `on_entity_settings_pasted` for a pair of different entity types
only when the source prototype lists the target in `additional_pastable_entities`; `data-final-fixes.lua` adds the ME
Interface, the import, export and storage bus to that list of every `assembling-machine`, `furnace` and `rocket-silo`
(what other mods put there stays). A machine a mod makes after this mod's data-final-fixes misses the list (the
runtime test counts every crafting machine that lacks it). The recipe is `get_recipe()` (with its quality), for an
idle furnace `previous_recipe`. The handler writes through `set_interface_config` / `set_interface_side`,
`set_bus_filters` and the storage bus's `set_settings`, so blueprint tags and windows read the same state; windows that
show the block are refreshed at once. The messages are one flying text at the cursor (one line each); the remote
`gregtorio-me-recipe-paste.paste(source, destination)` returns them (the harness has no player).

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
Issue #80 (0.5.0): providers of 0.4.1 and older (`storage.fork_ae2.pattern_version` not set) get encoded patterns for
what they provided, once: a crafting pattern for the recipe of each assembling machine next to them, a processing
pattern for each furnace next to them (the recipe chosen in the provider when the furnace can make it, else the one it
runs, else the one it smelted last), each pattern once, in the slots from 1 (`FORK-ME-MIGRATE: patterns` in the log).
These patterns are created by the migration (the only place where patterns come from nothing). Saved job steps and
leases that name a recipe get the pattern that makes it now (the crafting pattern, or the processing pattern migrated
from that furnace recipe; processing steps count their finished runs as received outputs). The old "read the
machine's recipe" path and the furnace recipe choice are gone.
Before the item migration, the fluid migration of step R2 (`run_fluids`) converts the old fluid drives, their
recovered fluid, the contents held for an upgrade and loaded fluid drive items into fluid cells and drops that
part of `storage.fork_me_fluids` (rule in `docs/ME-REWORK.md`, "Migration of fluids (R2)"); the fluid module then
rebuilds its interface records from the world (settings kept by unit number). Since R3 every open ME window and
the panels and windows of older versions are closed on a mod update; the ME Interfaces' slot filters become config
rows when each interface is first used (lazily, `config_of` in `scripts/fork-me-io.lua`), drive priorities and
partitions start empty.

## Limits and open points

* One temperature per fluid: stored by name, exported at the default temperature. Hot steam loses
  its heat; recipes that need another temperature are not patterns.
* Cells are not part of blueprints: a drive built from a blueprint starts empty. A destroyed drive drops its
  cells with their items and fluids.

* Loaded old fluid drive items stored inside ME cells (R1 allowed storing them) are not converted by the
  migration; placing such an item later gives a drive with its fluid in cells.
* The amount of a fluid row applies to the side's own tank; pipes and tanks connected without a pump share that
  level, so the segment holds more than the amount in total. Put a pump behind the interface to fill a tank. A
  surplus in an export side is not taken back. Four fluids at most per interface (one per side).
* The ME Interface's sides have no circuit connection; the fluid totals reach the circuit network through the ME
  Circuit Interface (issue #38).
* Autocrafting plans and crafts only normal quality, no items with own data (armor, tools, cells with
  contents) and no spoilage handling in the pool. Network storage takes every quality, and items with tags.
* Network storage (issue #68): no channels, no fluid wagons on the storage bus, no cards on the import and export bus
  and the ME Interface (capacity, speed, fuzzy, inverter, redstone and crafting card: a follow-up of me-network issue
  #17); the terminal search matches internal item names only; spoiling items, items with an inventory and damaged items cannot be stored. Old
  ghosts of ME blocks disappear when an old save is loaded (the game removes them before any script runs).
* The ME windows cannot be opened in the headless test (no player): their data and set functions are tested,
  building the windows, the clicks and the replacement of the game's windows are checked by hand (click-through
  list in the R3 pull request). The drive lights, the cable pictures and the sprites are untested in the real game.
* The ME Interface keeps the container's slot filters of the game (with_filters_and_bar): a filter set by hand in
  its container window only restricts that slot, it is no config. The level maintainer's lamp window is no longer
  shown (its circuit condition is in the ME window).
* A furnace picks its recipe from its input: a processing pattern whose input fits several of its recipes may be
  smelted into the wrong product; the job then waits for its outputs and fails after 5 minutes.
* Encoded patterns (issue #80): no upgrade cards on providers, no
  substitutions or fuzzy patterns, no "blocking mode" (a provider pushes into a chest as long as it has room), no
  pattern tier with 36 slots. Clearing a pattern needs the terminal's button (an inventory click cannot be caught).
  A provider mined by another mod's script (not a player or robot) drops its patterns instead of giving them to
  that script's inventory.
* Crafting CPUs (issue #6): no choice of the CPU in the terminal (the smallest free one that fits is taken), no
  "requests from players only / automation only" mode; the legacy CPUs have no byte limit. The level maintainer
  keeps one resource per block;
  a circuit signal sets its amount or switches it, but there is no "craft what the circuit asks for"
  request of several resources at once. Settings paste by hand and the upgrade planner on CPUs are untested in
  the real game (the headless test calls the same functions).
* A machine whose only input is shared with a belt, inserter or pipe will fight with the network.
* Recipe paste (issue #12) is tested headless through its handler: the shift clicks themselves, the game raising the
  event for each machine and how the flying text of several lines looks need the real game.
* Balance (costs, speeds, tier) and the look of the sprites are untested in the real game.
* Upgrade cards and priorities (me-network issue #17), where the mod differs from AE2: partitions can also be set in
  the cell window (AE2: only in the Cell Workbench); "fuzzy" means any quality
  (Factorio has no damage values or NBT, so AE2's fuzzy modes do not apply); a storage bus with an Overflow
  Destruction Card destroys nothing while it faces nothing, and a tank holding another fluid or at another temperature
  destroys nothing (AE2 voids into a bus without an inventory); items with tags are never destroyed; a storage bus never
  shows what it cannot take (AE2 has a switch); cards a blueprint wants come from the network (AE2's memory card takes
  them from the player's inventory); interface priority fills the higher priority interface first when the network is
  short (AE2's code uses it only to stop a lower priority interface from pulling stock out of a higher one through a
  storage bus, which this mod refuses anyway); partitioned storage is filled before storage that only holds the item
  (AE2: one pass for both). The card window, the red warning and the flying texts are untested in the real game.

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
search, sort, a spoiling item and a blueprint refused) and import/export (an interface config row filled, topped
up and its surplus taken back, other items imported, a spoiling item left in the interface, settings paste of the
config, old slot filters and old blueprint tags turned into config, the import bus 64 per visit and with a
filter, the export bus into a chest and into a machine, a rotated bus, blueprint tags).
Every other test runs on cable networks laid by the same router. Then it builds a small network (CPU, two Molecular
Assemblers, a macerator, providers, a drive) and runs: a two-level job (plate + 2 sticks -> gear,
gear + plate -> belts) whose result and used-up ingredients are checked, a job with too little
raw material that must report the exact shortfall and not start, a queued job that is cancelled,
a CPU that is removed and replaced during a job, a pattern machine that is removed while a job
waits for it and then a cancel (checked with a conservation of raw materials), and a GT
machine as pattern machine.

The furnace test (issues #27 and #80, two iron furnaces with providers) encodes through the terminal's functions: a
recipe that is not researched is refused; a crafting pattern encoded from a blank of the network (its tags, the
tooltip, stack size 1) is no pattern next to a furnace (`furnace`); a processing pattern filled from the recipe and
encoded from the blank in the hand (the hand gets it) is loaded into a new editor and clicked into the provider; the
plan uses it and a job smelts the ingots into storage with empty furnace slots and an empty pool. Then: the crafting
pattern is taken into the hand and cleared (a blank again; clearing a blank is refused), settings paste copies the
priority only, a blueprint carries the priority and the processing pattern, a provider revived from it waits for a
blank (no item exists) and encodes the pattern once a blank is stored, an old 0.4.1 tag gives a pending processing
pattern, a mined provider gives its pattern into the buffer (not the pending one), a destroyed one drops it on the
ground, and one removed without an event drops it at the next scan.

The pattern switching test (issue #80, own network) gives one Molecular Assembler without a recipe three crafting
patterns (gears, belts, blank patterns) and runs a job of each: the machine is switched each time, and 3 plates and 2
gears left in it before the belt job end in the network (counted exactly). Two jobs that need the same machine at once
run one after the other (one waits for the machine, never two leases on it). Two patterns make gears: the crafting
pattern and a processing pattern on a second assembler with its own gear recipe; at equal priority the provider built
first wins, provider priority 10 makes the processing pattern first (a job runs it: pushed in, the gears taken out, the
machine never switched), -10 the crafting one. A level maintainer keeps blank patterns in stock with the blank
pattern's crafting pattern. The processing line test encodes a processing pattern with free rows (2 copper plates ->
3 copper cables; an item with tags is refused as a row) from a blank of the network, pushes the inputs of a job into a
chest; the test script plays the line (plates out, cables into a second chest) and an ME Import Bus brings the cables
back: the job takes them (it waited for exactly 9), ends done with an empty pool, and waits for nothing afterwards.
Two mutations were checked to fail these tests: no arrivals (the line job times out waiting for its outputs) and a
switch that drops what was left in the machine (the counts after the belt job are short).

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
mined by robots while it holds a job's chlorine gives it back. Before that last job the reactor's recipe is cleared: its
crafting pattern (a fluid recipe) must be usable on a machine without a recipe and set it again (issue #80).

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
step, no free slot), a third job is refused (issue #6), and a Quantum CPU put in its place has four slots.
A circuit interface wired to a pole must carry exactly the network's items and floored fluids (500.5 water
is 500), then only its two filters, then follow 25 more plates. The settings of a maintainer (a fluid, 1234,
circuit), a circuit interface (two filters) and a fluid interface (export water 2345) must be blueprint
tags, come back on the entities built from that blueprint and revived, and be copied by settings paste and
by cloning. `devcheck.py migrate` checks a job started by the old version.
Issue #6 (`runtimemod/cpus.lua`, its own network): the smallest CPU (one 1k crafting storage: 1024 bytes, speed 1), a
3x2 rectangle of every block kind (5120 bytes, two co-processors: speed 3, a monitor), an L of three blocks and a row
of two units (no CPU, dark pictures), the bytes of a gear plan (5 per gear + 24), a job too big for every CPU
(refused with the bytes, nothing taken; a level maintainer waits), two jobs on the two CPUs at once and a third one
refused, a block removed during a job (the job pauses, goes on on the 2x2 rest of its CPU, is cancelled: every plate
and stick back), the CPU rebuilt, a clone and a blueprint of it (each forms a CPU of its own), a legacy CPU that takes
the job too big for every multiblock. `devcheck.py migrate --from-ref v0.2.0` loads a save with a running job on each
of the three legacy CPUs: each must end done on the CPU it started on.
`devcheck.py migrate --from-ref v0.4.1` (issue #80) builds providers next to a Molecular Assembler with the gear recipe
and next to a fresh iron furnace with the smelting recipe chosen in the provider, a gear job and a level maintainer
keeping 8 gears with the old version; after the update the providers must hold a crafting pattern of the gear recipe
and a processing pattern of the smelting recipe (both usable, both items craftable, `FORK-ME-MIGRATE: patterns`),
the old job must finish and the maintainer must then finish a job of its own.

`devcheck.py migrate --from-ref v0.3.2` (issue #68) builds an old logistic ME network with the old version: a
1k drive with items (also of another quality, and a blueprint the new network cannot store), a requester
interface with items in its inventory and its trash, a terminal, a second controller in the same logistic
network, the fluid drives, CPU, providers and running job above, a chest with 16 storage cells on one stack, old
drive items and the ghost of an old drive. After the update no old entity may be left, every block must be
connected to the new controller, the drives must hold four cells of their tier, the migration report must
have counted exactly the items of the old chests (and the second controller) and found no difference, those
items (job items aside) must be in the network and the blueprint in an overflow chest, the 16 cells and the old
drive items must be kept, and the fluid, pattern and job checks above must pass on the new network.

The R3 test (own network right of the fluid cell test: a controller, three drives, a terminal, and every other ME
block standing apart) checks partitions and priorities: a drive of priority 5 is filled first, also before a cell
partitioned for the item in a lower priority drive; with that drive at -5 the partitioned cell gets its item and
other items never go into it; a network whose cells are all partitioned for something else takes nothing;
extraction takes from the lowest priority first and, at the same priority, from unpartitioned cells first;
"From contents"; the partition in the tags of an empty and a loaded cell taken out and put back; a fluid cell's
partition keeps only fluids. Drive settings: the blueprint tag written through the autocrafting module's handler,
a drive revived from it (priority, and the slot's partition on the cell put in later), settings paste (a slot
without partition in the source is cleared) and a clone. The windows: `fmt`, every ME block has a window, and the
data and set functions of the drive, cell (partition buttons), controller, provider, CPU, level maintainer
(target, circuit condition), circuit interface (filter buttons, output switch), fluid
interface, ME Interface (config rows, an item moved to another row keeps its amount) and buses (filter buttons,
fluid bus); the terminal's kind filter, Cells tab (priority order), craft preview (no pattern, amount 0) and Jobs
tab. It reports `ME partitions and windows test (issue #68 R3): ok`.

The storage bus test (own network right of the R3 test: a drive with two 1k cells, a terminal and seven storage
buses on iron chests) checks that a chest's items reach the totals at the bus's visit, a terminal take out of the
chest, a filtered bus getting its item while an unfiltered one goes into the cells, priority 10 and -10 against the
cells for storing and taking, read only, write only, a stale look (items taken out by hand: an extract and a
terminal take get only what is really there and the totals are corrected), two buses on one chest (counted once,
the second takes over), a bus facing a cable, a chest removed with and without an event, a removed bus, the network's
totals against cells plus chests after every part, the settings in a blueprint, on a revived ghost, by paste and
clone, and an inserter's item seen within the storage bus idle limit (2 s). It reports `ME storage bus test (issue #68): ok`.

The fluid storage bus test (own network right of the storage bus test: a drive with four 1k fluid cells, a terminal,
six fluid storage buses on storage tanks, a pump, a fluid export bus and a level maintainer) checks that two tanks of
one segment are counted once and the second bus is refused, the terminal's entry, an extract out of the segment, a
split segment (pipe removed: no extraction beyond what the first bus still owns, then the second bus takes its part),
a filtered insert into its tank and the rest into the cells, priority 10 and -10, read only, write only, a stale look
(fluid taken out by hand), hot steam (counted, nothing put in, the tank keeps its temperature), a removed tank and bus,
a bus facing a cable, the network's fluid against cells plus segments after every part, the settings in a blueprint,
on a revived ghost, by paste and clone; then the fluid export bus taking from a segment, a level maintainer counting it
and a pump's fluid seen within the storage bus idle limit. It reports `ME fluid storage bus test (issue #68): ok`. Since
issue #3 of ME Network the buses there are storage buses on tanks (the remote of the old fluid storage bus works on
them).

The unified I/O test (issue #3 of ME Network, own network) gives an ME Interface an item row and a fluid row (the row
takes the side with a pipe: north is the cable), checks the item stock, the fluid in the east side and the water out
of the network, steam piped into the south side imported, the side switched off and on again, a second interface whose
pipes run from an export side round to an import side (`loop`: nothing imported), the blueprint tag with rows and
sides (no side tank in the blueprint), and the fluid of a mined interface back in the network with its side tanks gone.
An export bus on a chemical reactor with a fluid recipe puts boards into its input and phenol into an input box; an
import bus on another one takes the boards of its output and the fluid of an output box and leaves the input box alone,
and takes no fluid with only item filters. A storage bus faces a chest (item side), then a tank (fluid side, taken
from), gets mixed filters and faces a cable. An old fluid import bus built by a script becomes an import bus; ghosts
of the old export bus, fluid interface and fluid storage bus with old tags are revived as the unified blocks with their
settings; the old items are hidden, place the unified blocks and have no recipe or unlock. It reports
`ME unified I/O test: ok`.

The recipe paste test (issue #12 of ME Network, own network) checks that every crafting machine prototype lists the
four ME blocks as pastable (with Gregtorio all GregTech machines too) and calls the paste handler with the event's
shape: an item recipe and a quality recipe onto an interface (one stack each, the quality), a storage bus (quality
keys, mode and priority kept) and an export bus (names, the quality message); a chemical reactor's fluid recipe onto an
interface (the fluid row on the side with a pipe, an off side kept), onto an interface whose side is tied to that fluid
(kept), then a recipe of two other fluids (the side imports again, two new rows on sides without a pipe, two messages),
onto the import bus (products) and export bus, onto storage buses on a chest (a recipe of fluids only: unchanged,
message), on a pipe (fluids) and facing nothing (both); fixture recipes with 20 items and 5 fluids and with 2 items and
5 fluids (rows, fluids and filters full, no side left); a furnace while smelting and its previous recipe once idle; an
assembler and a furnace without a recipe; a paste between two ME blocks is left to their own handlers. It reports
`recipe paste test: ok`.

The upgrade card test (me-network issue #17, own network: two drives, storage buses on chests, a tank and nothing)
checks the defaults of a bus without cards (18 filters, no extra settings), Capacity Cards (30 filters kept, 18, 27 and
63 apply; a card of another kind and one more than the limit are refused; a card taken out), the Inverter Card (iron
refused, copper taken; the blacklisted item in the chest not shown, then shown and taken with "filter on extract" off),
"filter only what goes in" on a whitelist, the Fuzzy Card (another quality only with the card, stored and shown), the
Overflow Destruction Card on a chest (what fits, the rest destroyed and counted, an unfiltered key kept, `can_insert`,
the window data) and on a tank, a voiding bus facing nothing (destroys nothing), From contents and Clear, and that no
card is ever made or lost: every card of the area counted before and after a bus mined (cards in the buffer), destroyed
and vanished (spilled), a blueprint and a revived ghost (wants the cards, takes one when the network gets it), a
settings paste (the extra card into the network, the wanted one from it), a clone and a card taken by hand; then a
recipe paste that changes only the filters. It reports `ME upgrade card test: ok`. Mutations checked to fail it: no
void, no fuzzy lookup.

The priority test (issue #17, own network) checks the storage order with a blacklist bus built first and a whitelist
bus at priority 5 (the whitelist gets its item, the blacklist the rest of its priority, a blacklisted item goes to the
cells before a bus at -5), a partitioned cell behind a higher priority bus, a bus that holds an item before an empty
cell of its priority, taking out from the lowest priority first; two ME Interfaces of priority 0 and 10 that want 50
gears and 1000 water (nothing registered while no interface has a priority; with 30 gears and 600 water the high one
gets all, with 40 and 1400 more both end full); the interface priority in a blueprint, a paste, a clone and the window
data; and the pattern fall-back (a provider of priority 10 whose pattern lacks its input: the provider of priority 0 is
used, the high one once its input is there, the first one's shortfall when neither can run). It reports `ME priority
test: ok`. A mutation without the reservation was checked to fail it.

The Cell Workbench test (issue #17, part 3, own network: a drive at priority 10 for the cell under test, a backstop
drive with an item and a fluid cell, four workbenches without a cable) checks an empty workbench, an item cell put in
(4 card slots), the partition buttons, the cards and their limits (a second inverter, a capacity card and a fifth card
refused, a card taken out), the partition and cards in the tags of the cell taken out, From contents and Clear on a
cell with items (they stay), the copy mode (the kept partition onto an empty cell), a fluid cell (3 slots, no fuzzy
card); then cells made in the workbench in the drive: an inverted fluid cell (water refused, steam taken), the
inverted item cell (iron refused, wood taken, every quality refused with its fuzzy card; the cell window shows the
cards), a fuzzy whitelist (copper in two qualities, no stone), equal distribution (67 of a kind in a 1k cell, 4032
with a partition of two), overflow destruction on a partitioned cell (full, 500 destroyed and counted, another key
kept, `can_insert`), and workbenches with a cell mined (the cell in the buffer), destroyed and vanished (spilled). It
reports `ME Cell Workbench test: ok`.

The cell tooltip test (issue #64, `runtimemod/workbench.lua`) makes cells through the workbench's remote interface and
reads the `custom_description` of the cell that comes out (structure and keys, not a rendered text; the game gives a
number parameter back as a string): a fresh cell and a cell cleared again have none, a whitelist of two items, the same
with an Inverter Card, an item with quality, a fluid cell, 14 keys (12 icons and "+2 more") and exactly 12, every card on
an item cell (7 lines, at most 20 parts) and on a fluid cell (no Fuzzy line), a partitioned cell that holds items
(also blacklisted, and with nothing else), an empty unpartitioned cell with a card, a cell that comes out of a drive,
and the window's mode line made of the same sentences. It reports `ME cell tooltip test: ok`.

The slot tests of issue #28 change the script inventories the way a player does, with an inventory standing for the
player's: the storage bus card slots (a card taken, a wrong item back, the inverter limit, a stack of capacity cards
spread over the empty slots, a full bus, an Equal Distribution Card refused, a card taken out, the cards that were there
first, the settings after a move inside the inventory, mined with an item no sync has seen: `ME storage bus card slots
test: ok`) and the Cell Workbench slots (a cell's tag cards become items and go back into its tags when it is found in
the hand, limits and a wrong item, a card without a cell, a cell put into a card slot, a cell that is not found, a fluid
cell with an item cell's cards, mined with a card no sync has seen; no card made or lost: `ME Cell Workbench slots test:
ok`). `migrate --from-ref <main before #28>` loads a save with cards on a storage bus and a cell with cards in a
workbench: the cards are items in the inventories after the load.

The pane tests of issue #28 click through `inventory_click` and `block_click` of `gregtorio-me-gui`, with a script
inventory standing for the player's: shift + click of cards (spread over the empty slots, the inverter limit), of a
wrong item, of a cell, a second cell and a card without a cell into the workbench (refused, nothing moves); clicks on the
block's slots with a wrong item, a card, on a full bus, with an empty hand and with shift; the workbench's cell into the
hand with its cards and back, a swap of two cells; half a stack, one item put down, merge, pick up, put down and swap
in the pane; no card made or lost (`ME window pane test (storage bus): ok`, `ME window pane test (workbench): ok`).
The stored item description test of issue #79 (`ME stored item descriptions test: ok`) stores a cell made in the workbench
and an encoded pattern in a network and reads the description back from the key the network gave them (it equals the stack's),
checks that a plain key, a quality key, a fluid, a broken json and one without a description give none, and that a cell with
another partition is another key.
The slot tooltip test of issue #75 (`ME window slot tooltips test: ok`, `runtimemod/workbench.lua`) calls the functions behind
a slot (the window itself needs a player): a plain item, an empty slot and a fresh cell get the slot's hint alone, a cell made
in the workbench and an encoded pattern their description (with a hint: the description, a line break, the hint), and the
signature piece of a cell that stays in the workbench's slot changes when its partition does.

`python tools/devcheck/devcheck.py migrate --from-ref v0.1.0` makes a save with ME Network 0.1.0 (three fluid
interfaces, the fluid buses and the fluid storage bus with settings and fluid, an item interface next to a pipe with
water, a level maintainer and patterns naming old items, ghosts with old tags, old items in a chest, a blueprint, the
cells and a cell in the chest) and loads it with the working copy: the unified blocks with the same settings, no old
entity, ghost or item, the item interface's side next to the pipe off, the same fluid in the area and the cells after
the update and after 150 ticks of I/O steps.
See `tools/devcheck/README.md`.
