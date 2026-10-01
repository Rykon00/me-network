# ME rework (issue #68): design record

Issue #68 replaces the ME network that was built on Factorio's logistic network (controller = roboport
without robots, drive = logistic storage chest, interface = requester chest) by a network that plays like
Applied Energistics 2: cables, a controller, drives with storage cells that keep their contents, a
terminal as the central GUI, interfaces and buses for import and export.

The rework comes in three steps:

| Step | Content | State |
|---|---|---|
| **R1** | the new core: cable graph, controller, drives with cell slots, cells with their contents in tags, the storage API, the terminal, the ME Interface and buses, migration of old networks; autocrafting, level maintainer, circuit interface and fluids moved onto the new API | done (PR #69) |
| **R2** | fluids on cells: fluid storage cells in the ME Drive, the fluid API of the storage engine, fluids in the terminal grid, the fluid interface on the new API, fluid import and export buses, migration of fluid drives, their recovered fluid and loaded drive items; the old recovery removed | done (this document, "Fluids (R2)") |
| R3 | proper GUIs for pattern provider, level maintainer, circuit interface, crafting CPUs, interface and buses | open |

This file is the design record: what was decided and why, and what is left for R3. The player's
guide is `docs/AE2.md`.

## Network topology

**Members** ("nodes") are the ME entities: ME Cable, ME Controller, ME Drive, ME Terminal, ME Interface,
ME Import Bus, ME Export Bus, ME Pattern Provider, the Crafting CPUs, ME Level Maintainer, ME Circuit
Interface, ME Fluid Drive and ME Fluid Interface. Machines next to a pattern provider are not members.

**Connections:** two members are connected when their tile boxes share an edge (left, right, above,
below; corners do not count). This is AE2's rule: a cable connects on all four sides, and full blocks
(drives, the controller, terminals) pass the network on like a cable, so a row of drives needs no cable
between them. A network is a connected component of this graph.

**ME Cable** (`me-cable`): placed with the existing `fluix-cable` item (AE2's fluix cable is the cable
item; three for 10 s in an MV assembler, unlocked by Applied Energistics Components). 1x1,
`simple-entity-with-force` with 16 graphics variations (a bit for each side with a neighbour); the script
sets `graphics_variation` when the cable or a neighbour is built or removed. It collides with objects like
any 1x1 entity (it cannot cross belts or pipes).

**Controller:** a network works when its component holds exactly one ME Controller and that controller has
power. Two or more controllers in one component are a conflict: the network is off and the controllers show
the status "Controller conflict" (AE2 shows the same for two separate controllers). Without a controller
the status is "No controller"; with an unpowered controller "No power". An off network stores nothing and
gives nothing: every storage call returns 0, interfaces and buses idle, crafting jobs wait ("No ME
network").

The controller (`me-network-controller`, placed by the `me-controller` item, 2x2) is an
`electric-energy-interface` without GUI. Its power use is 120 kW plus 4 kW for every member that has no
power of its own (drives, interfaces, buses, providers, circuit interfaces, fluid drives and interfaces;
cables are free), set by the script when the network changes. It counts as powered while its status is not
"no power" and its buffer is not empty (an energy interface without any pole reports no "no power" status;
an underpowered controller keeps the network running at low power, like other machines).
Terminals, CPUs and level maintainers keep their own power connection (lamps), as before.

**Incremental graph:** nothing scans the map at runtime.

* Build (`on_built_entity`, robots, platforms, script raised, revive, clone): one
  `find_entities_filtered` around the new member's box finds its neighbours; the adjacency is stored on
  both sides. No neighbour: a new network. One network: the member joins it. Several: they are merged
  into the largest one, which keeps its id.
* Removal (mined, died, script raised destroy): the member is unlinked; the networks of its former
  neighbours are found again by a breadth first search over the stored adjacency (no map access). If the
  graph is split, the part with the most members keeps the id, the others get new ids.
* An entity removed without any event (`destroy()` by another mod) is noticed by a sweep in the terminal
  step (every 60 ticks, 200 members per step, round robin) and removed the same way from its stored data.
* The derived data of a network (controllers, status, drives, storage totals, item index, power) is
  recomputed only for the networks a change touched, and only when the change can alter it (a cable
  joining one network changes nothing but the member count).
* `on_configuration_changed` (and `on_init`) rebuild the graph once from the world, the only scan.

Network ids stay the same across most changes (merge keeps the larger id, split keeps the id on the
larger part), but other code must not store them for long: autocrafting keys its pattern cache by network
id and rebuilds it when the graph version changes; jobs remember the CPU (an entity), not the network.

### Channels: none

AE2 limits a cable to 8 or 32 devices ("channels"). R1 has no channels and no device limit:

* Channels are a planning puzzle that AE2 needs because Minecraft blocks are cheap and a network can
  touch thousands of machines; in Gregtorio the number of members is limited by the cost of the
  members themselves (drives, buses, interfaces are MV to IV machines).
* They add nothing to UPS: the cost of a network is its endpoints (interfaces, buses), which are
  budgeted per step anyway (see **Tick budget**).
* The migration lays cables along one path per network (see **Migration**); with channels a migrated
  network could end up over its limit and partly off, which would be a loss of function that the player
  did not cause.

The power draw per member is the soft limit instead. If channels are wanted later, they fit on top: the
graph knows every member and its distance to the controller.

## Storage engine

Items are stored **virtually** in script state, per cell, never in chests.

**Storage cells** (`me-1k-storage-cell` ... `me-256k-storage-cell`, the existing items) become
`item-with-tags` with stack size 1 (they were plain items, stack 16). Their recipes do not change. The
capacity follows AE2:

| Cell | Bytes | Bytes per type | Max types | Items of one type |
|---|---|---|---|---|
| 1k | 1 024 | 8 | 63 | 8 128 |
| 4k | 4 096 | 32 | 63 | 32 512 |
| 16k | 16 384 | 128 | 63 | 130 048 |
| 64k | 65 536 | 512 | 63 | 520 192 |
| 256k | 262 144 | 2 048 | 63 | 2 080 768 |

A type costs its bytes per type, and every 8 items of it one byte (rounded up per type). Items of another
quality are another type. This is more per cell than the old cells (16 to 256 slots), but a drive now
holds 10 cells instead of 4, and a cell is a single item that can be carried around; the balance is in the
cell recipes (MV to IV) and the AE2 numbers were the maintainer's target.

**Contents travel with the cell:** taking a cell out of a drive writes its contents into its tags
(`fork_me_cell = { items = { [key] = count }, data = { [key] = { tags, description } } }`) and a
description ("1 234 items of 5 types: ..."). Putting it into a drive reads them back. So swapping cells
between drives, networks or players is lossless; a cell with contents can be stored in another cell (AE2
allows that too) because tagged items are stored with their tags.

**What can be stored:** plain items of any quality, and items with tags (cells, loaded fluid drive items):
an item with tags is stored with its tags and description under its own key, one type per distinct tag set.
Not storable (the interface leaves them in its slots, the terminal says so): items with an inventory or
grid, blueprints and planners, items that spoil (the network would stop their decay), damaged items and
partly used tools or ammunition (the network would repair them).

**Network API** (`scripts/fork-me-network.lua`, all O(1) or O(cells holding the item)):

| Call | Returns |
|---|---|
| `insert(net, name, quality, count)` | inserted count: cells that hold the type first, then cells with a free type |
| `extract(net, name, quality, count)` | extracted count |
| `count(net, name, quality)` | stored count |
| `can_insert(net, name, quality, count)` | how many would fit, nothing changed |
| `contents(net)` | list of `{ key, name, quality, count, data }` |
| `insert_stack(net, stack)` / `extract_to(net, target, key, count)` | the same for a LuaItemStack, keeping tags |
| `stats(net)` | bytes used/total, types used/total, cells, drives, power |

Per network the script keeps the totals (`net.items[key]`), the bytes and types, and an index
`net.index[key] = { cell id = true }` of the cells that hold a type, so `count` is a table lookup and
`extract` touches only cells that hold the item. A cell id is `"<drive unit>:<slot>"`. Inserting a new type
walks the network's cells once for one with a free type (a few hundred cells at most).

## ME Drive

An empty ME Drive (`me-drive`, the existing drive chassis item, 1x1) is placed, and up to **10 cells** go
into its slots (AE2: 10). Only storage cells are accepted.

**Entity:** a `simple-entity-with-force` without engine inventory, and a script GUI with the 10 slots
(open it with the normal open key): click a slot with a cell in the cursor to put it in, click a filled
slot to take the cell into the cursor (shift: into the inventory). Clicking the drive itself with a cell in
the cursor puts it into the first free slot. A container with an engine inventory was rejected: Factorio
raises no event when a player moves a stack in or out of a container, so the script could not write the
contents into the tags of a cell taken out by hand at the moment it leaves; any polling would leave a
window in which a cell exists twice or not at all. With the script GUI every move goes through one
function that writes the tags first.

**Fill state per slot:** ten small rectangles on the drive (`rendering.draw_rectangle`, no sprites):
none for an empty slot, green while the cell has room, orange above 75 % of its bytes, red when it is full
(bytes or types). The GUI shows the same per slot as a bar with "bytes used / total, types used / 63".
Updated in the terminal step (every 60 ticks) for drives whose cells changed.

**Removing a drive:** mining it puts its cells (with their tags) into the mined buffer, so the player or
robot gets the drive and the cells. A destroyed drive (biters, script raised destroy) spills its cells on
the ground at its position (AE2 drops them as well); nothing is lost, and the ghost is rebuilt empty. A
drive that vanished without an event is spilled at its stored position by the sweep. Blueprints and clones
copy no cells.

**Old drive items** (`me-drive-1k` ... `me-drive-256k`, crafted from the chassis and four cells) can no
longer be crafted and are hidden. Placing one builds an ME Drive with its four empty cells in the first four
slots (the 256k one also gives its acceleration card back into the player's inventory, or spills it). The
old disassembly recipes are removed (their result is what placing the item gives).

## ME Terminal

The ME Terminal stays the same entity (a lamp that needs power, now also a network member). Its GUI is the
central window of the network:

* **Status line:** network state (working, no controller, controller conflict, no power), bytes used of
  total, types used of total, drives and cells, the controller's power draw.
* **Storage tab:** a search field (matches the internal item name: a script cannot read localised names), a
  sort switch (by amount or by name) and the item grid. Left click on an item: a stack into the cursor
  (with something in the cursor: that is stored instead, like AE2). Right click: one item into the cursor
  (more of the same item: one more). Shift click: a stack into the inventory. Below the grid the fluids of the
  fluid drives (read only, as before) and a row with the player's inventory: click an item there to store
  all of it (right click: one stack).
* **Crafting tab:** kept as it was (craftable list, amount, plan line, Craft, job list with progress and
  Cancel), moved onto the new API. Its look is redone in R3.

Every button calls a function that the runtime test calls directly (`take`, `store_cursor`,
`store_inventory_item`, ...), so the logic behind the GUI is tested headless.

## Import and export

**ME Interface** (`me-network-interface`, placed by the existing `me-interface` item, 1x1 container
with 18 slots that can be filtered like a cargo wagon's): a **filtered slot** is an export slot, the network
keeps it filled with its item up to a full stack; every **unfiltered slot** is imported, its items go into
the network. Inserters and belts work with it as with a chest: inserters put items in (import) and take the
filtered items out (export). The filters are kept in blueprints, copied by settings paste and by cloning
(tag `fork_me_interface`). This is AE2's interface (config slots plus storage) with the slot filter as its
configuration, so it needs no extra GUI in R1.

**ME Import Bus / ME Export Bus** (`me-import-bus`, `me-export-bus`, 1x1, rotatable): a bus faces one
entity. The import bus pulls items out of that entity's output (assembler or furnace result, chest) into the
network, the export bus puts its filtered items into the entity's input (assembler or furnace input, chest),
up to one stack of each in the target. Up to 5 item filters (import: none means everything), set in a small
window (open key), kept in blueprints, settings paste and clones (tag `fork_me_bus`).

For Gregtorio both are worth having: belts and inserters feed machines through the interface, and a bus
saves the two inserters (and their power) when one machine is fed from or emptied into the network. Storage
buses (a chest as network storage) are left out: they would bring back the "network reads chests" model
the rework removes.

**Throughput** (per I/O step, every 15 ticks): an interface handles up to 8 slots per visit (import all of
a slot, or top a filtered slot up), a bus moves up to 64 items per visit. At most 24 interfaces and buses
are visited per step (round robin); with more of them each is visited less often, the work per step stays
bounded.

## Tick budget

No new `on_tick`, no new interval:

| Interval | Work |
|---|---|
| 15 (was fluids only) | the I/O step: the fluid interfaces and recovered fluid (unchanged, 8 interfaces, 4 entries) and then up to 24 item interfaces and buses |
| 20 | autocrafting, level maintainers, circuit interfaces (unchanged) |
| 60 | open terminals, drive fill lights of changed drives (up to 50 drives), the sweep for vanished members (200 per step) |

`fork-me-network.lua` registers the interval 15 and calls the fluid step from it (one handler per interval).

**Expected cost, 50 drives (500 cells) and 200 interfaces and buses:**

* I/O step: 24 endpoint visits; a visit is one `get_inventory` and `get_contents` of at most 18 slots,
  a few API calls and table lookups; about 20 to 40 µs each, so 0.5 to 1 ms per step, 0.03 to 0.07 ms per tick
  on average. Each endpoint is visited every 9 steps (2.25 s); an interface moves up to 8 stacks per visit.
* Storage calls: `count` is a lookup; `insert` and `extract` of a known type touch the cells in its index
  (usually one); a new type walks up to 500 cells once.
* Graph changes: building a member is one `find_entities_filtered`; removing one runs a breadth first
  search over at most the network's members (about 1 300 with 1 000 cables: well under a millisecond); a
  merge or split recomputes the totals of the networks involved (500 cells × their types).
* Terminal step: per open terminal one `contents` and a sort (a few hundred types); the drive lights and the
  sweep are bounded per step.

## Migration (from 0.3.2 and older)

Runs in `on_configuration_changed` when the world still has entities of the old prototypes (it is
idempotent: what it converts disappears). The old prototypes stay in the game, hidden, so saves load
them: the roboport `me-controller`, the logistic storage chests `me-drive-1k` ... `me-drive-256k` and the
requester chest `me-interface`.

1. **Count** every item in the old ME chests (drives and interfaces, both inventories of an interface) per
   surface and force: the total that must come out at the end.
2. **Group** the old entities by the logistic network they belonged to (the old ME network). Old
   terminals, CPUs, providers, level maintainers, circuit interfaces, fluid drives and fluid interfaces
   are already the new entities; they are taken into the group of the logistic network at their position.
3. **Controller:** the first old controller of a group (by unit number) is replaced in place by an ME
   Controller (same 2x2 box). Further old controllers in the same group are removed and their
   `me-controller` items go into the new network's storage (two controllers would be a conflict). A group
   without an old controller (an ME network that lived only in vanilla roboport coverage) gets a new
   controller next to its first member: the only item the migration adds.
4. **Drives:** every old drive is replaced in place by an ME Drive with four cells of its tier in slots
   1 to 4; its contents go into these cells. The 256k drive's acceleration card goes into the network.
5. **Interfaces:** every old interface is replaced in place by an ME Interface (no filters: old requests
   pulled through robots, there is nothing equivalent to carry over); its contents and trash go into the
   network.
6. **Overflow:** what the four cells of a drive cannot take (only possible with items whose stack size is
   above about 500) goes into any other cell of the group with room; the migration creates no cells. What is
   still left, and every stack the network cannot store (items with an inventory, spoiling items, ...), goes
   into an iron chest the migration places next to the controller (more chests if needed), with a chat message
   and a map link. If no chest can be placed, the stacks are spilled at the controller.
7. **Cables:** the members of a group are connected to its controller by cables, one path at a time: a
   breadth first search from everything already connected over free tiles (where an ME Cable can be
   placed) to the nearest unconnected member, within the group's bounding box plus 16 tiles. The cables are
   placed by the script (they are not taken from anywhere). A member that no path reaches (walled in) is
   left unconnected and named in the chat with a map link; its contents stay in it (cells in the drive,
   fluid in the fluid drive), nothing is lost, the player connects it.
8. **Ghosts** of the old entities: the game removes them when the save is loaded, before any script runs
   (nothing can build the old prototypes any more; seen in `migrate --from-ref v0.3.2`). Should one be left,
   the migration makes it a ghost of the new entity, and the built event does the same for a ghost of an old
   entity built from an old blueprint. Ghosts are no items: nothing is lost.
9. **Check:** the item totals of step 1 are compared with what the new networks, the overflow chests and
   the spilled items hold, per item; a difference is written to the log (`FORK-ME-MIGRATE`) and the chat.

Limits of the rule: the vanilla logistic network loses the old controllers' roboports; robots that relied
on them for coverage lose it (the controllers had no robots and no charging pads). Items in vanilla
storage chests of the old ME network stay in those chests: the new network holds only cells. A cable path
can block a walkway (it collides like a 1x1 entity); the player can move it.

**Fluids** (R1; replaced in R2, see "Migration of fluids (R2)"): the ME Fluid Drive kept its contents and its
recovery and was a network member like any other, its totals summed over the fluid drives of the new network. A recovered
fluid entry keeps its position and the ME member it was recovered at (the member nearest to the destroyed
drive within 1.5 tiles, or to the player within 10 tiles for the hand disassembly of a loaded fluid drive
item): its network is that member's network while the member exists, else the network of a member within
1.5 tiles of the position. (Without the member, an entry made at a player's position looked like "no network"
and the first fluid drive placed anywhere took it; the runtime test caught that.)

**Autocrafting:** CPUs, providers and jobs keep their records; a job looks its network up through its CPU
(or the entity it was started at) instead of a position. Running jobs and their pools survive.

## Removed logistic-network dependencies

| Old | New |
|---|---|
| `me-controller` roboport (network area radius 16) | `me-network-controller` (electric energy interface), the old prototype stays hidden |
| `me-drive-<tier>` logistic storage chests | `me-drive` (script GUI, 10 cell slots), old prototypes hidden |
| `me-interface` requester chest with "trash unrequested" | `me-network-interface` (container with filtered slots), old prototype hidden |
| `find_logistic_network_by_position` in terminal, autocrafting, fluids, circuit | `fork-me-network.lua` |
| `LuaLogisticNetwork.get_contents / insert / remove_item / get_item_count` | the storage API |
| ME Controller reads the network on its circuit connection (roboport) | the ME Circuit Interface does that (it did already for fluids and filters) |

## Tests (headless, `tools/devcheck`)

`runtime` (all through the same functions the GUIs call):

| Test | What it checks |
|---|---|
| ME graph | join (members, power draw, cable pictures), split (the larger part keeps the id), join again, a second controller (conflict, nothing stored, status on the controller), a cable removed without an event (sweep), the cable router, a network without power, with power, after the power is cut |
| ME cells | cells into slots, only cells, AE2 bytes, the contents in the tags of a cell taken out and back in another drive, capacity of the network exactly, full cells, quality as its own type, a loaded cell stored in the network and taken out with its tags, the drive window's clicks (take, put, swap, shift), a destroyed drive spills its cells with their items, an old drive item gives its four cells and the card, robots mine a drive with loaded cells into a storage chest |
| ME terminal | take a stack, one more, a click with something in the cursor stores it, take one, store the cursor, a stack into the inventory, the inventory row, search, sort by amount and name, a spoiling item and a blueprint refused |
| ME import/export | interface export slot filled and topped up, import slot emptied, a spoiling item stays, filters pasted; import bus 64 per visit, with a filter; export bus without filter idle, into a chest, into a machine; a rotated bus; bus filters pasted; blueprint tags of interface and bus |
| autocrafting, furnace patterns, fluids, fluid recovery, level maintainer, CPU tiers, circuit interface, settings copy | the tests that existed, on cable networks laid by the router |

`migrate --from-ref v0.3.2`: an old ME network with items in a drive and an interface (other quality, a
blueprint that cannot be stored, items in the requester's trash), a second controller in the same logistic
network, a terminal, fluid drives with fluid and recovered fluid, pattern providers and a running job, a
chest with 16 cells on one stack, old drive items, the ghost of an old drive. After the update: no old entity
left, every block connected, drives with four cells of their tier, the report's counts equal the old chests'
items, those items are in the network (the blueprint in an overflow chest), no difference, the 16 cells kept,
fluids, recovery, patterns and the job as before.

## Fluids (R2)

### Fluid cell model

A fluid storage cell (`me-1k-fluid-storage-cell` ... `me-256k-fluid-storage-cell`, the existing items, recipes
unchanged) becomes an item with tags, stack size 1, and goes into an ME Drive slot like an item cell. A drive may
hold item and fluid cells in any mix.

| Cell | Bytes | Bytes per fluid | Fluids | Units of one fluid |
|---|---|---|---|---|
| 1k | 1 024 | 8 | 18 | 8 128 |
| 4k | 4 096 | 32 | 18 | 32 512 |
| 16k | 16 384 | 128 | 18 | 130 048 |
| 64k | 65 536 | 512 | 18 | 520 192 |
| 256k | 262 144 | 2 048 | 18 | 2 080 768 |

The byte model is the item cells' one, with 8 fluid units per byte (AE2 stores 8 buckets per byte; a Gregtorio
fluid unit is far smaller than a bucket, and 8 units per byte keeps a cell where the old fluid cell was: 8 000
units per "1k"). AE2 gives fluid cells fewer types than item cells; 18 is Gregtorio's choice (a cell full of
different fluids still holds a useful amount of each). Amounts may be fractional (fixed point fluid amounts):
a fluid's bytes are `ceil(amount / 8)`, an amount below 1e-6 counts as nothing.

**Engine:** one storage engine for items and fluids (`scripts/fork-me-network.lua`). A cell spec has
`kind = "fluid"` and `per_byte`; fluids are keyed `fluid/<name>` (the resource keys autocrafting has always used).
`cell_room` gives a cell no room for the other kind, so `insert_key` and `extract_key`, the per-network totals and
the index key -> cells, cells' tags, drives, spilling and robots work unchanged. Per network the bytes and types
of fluid cells are kept apart (`fbytes`, `ftypes`, `fbytes_total`, `ftypes_total`). API: `insert_fluid`,
`extract_fluid`, `fluid_count`, `can_insert_fluid`, `fluid_contents` (and on the remote interface); `contents`
and `plain_counts` list items only. `scripts/fork-me-fluids.lua` keeps `totals`, `count`, `insert`, `remove` and
`capacity` for its callers (autocrafting, level maintainer, circuit interface, terminal).

**One temperature per fluid** stays: fluids are stored by name; importing drops the temperature, everything that
comes out has the fluid's default temperature. Per-temperature storage would make every steam temperature its own
type, and an export would have to pick one; the cost (hot steam cannot be stored) is documented in `docs/AE2.md`.

### Terminal, interface and buses

* **Terminal:** the fluids are in the main grid after the items (`entries` returns them with `fluid = true` and
  the key `fluid/<name>`), with their amounts in the tooltip; search and sort apply. The status line shows item and
  fluid cell bytes and types and both cell counts. Taking a fluid by hand returns `fluid-by-hand` (AE2 needs
  buckets for that; Factorio has none).
* **ME Fluid Interface:** unchanged entity and settings (import by default, export with a fluid and a level,
  blueprint tag `fork_me_fluid_interface`, settings paste, clones), now on the fluid API: import takes what
  `can_insert_fluid` allows, export takes what the network holds. Its panel shows the fluid bytes and types.
* **ME Fluid Import / Export Bus** (`me-fluid-import-bus`, `me-fluid-export-bus`, tech `me-fluid-storage`, HV
  assembler: an item bus, an HV pump, two pipes): R1's bus design with fluid filters. The import bus empties the
  output boxes of a machine (every box of a tank; input boxes are left alone), the export bus fills its filtered
  fluids with `insert_fluid` (input boxes of a machine, a tank). 1000 units per visit, in the I/O step.

### Migration of fluids (R2)

`run_fluids` in `scripts/fork-me-migrate.lua`, from `on_configuration_changed`, after the graph rebuild and before
the item migration (so the new drives are members when old logistic networks are grouped). It reads the old
state (`storage.fork_me_fluids.drives`, `.recovered`, `.replacing`) and the world:

1. **Old fluid drives** (`me-fluid-drive-1k` ... `-256k`, kept hidden): each is replaced in place by an ME Drive
   with four fluid cells of its tier holding its fluid. Four cells hold what the old drive held as long as it has
   few fluid types (the type overhead); otherwise the rest goes into new cells of the same tier in the drive's free
   slots (`fill_fluids`). The 256k drive's acceleration card goes into a chest next to it.
2. **Recovered fluid, fluid held for an upgrade, records of vanished drives:** into the fluid cells of the
   network the entry belonged to (its anchor member, else a member within 1.5 tiles of its position), also when
   that network has no power; what is left into the nearest drive on the surface with room
   (`fluid_drives_near`).
3. **Loaded old fluid drive items** in player inventories (main, trash, cursor) and in containers, logistic
   containers, cars, cargo wagons and spidertrons: the item stays without tags (placing it gives four empty
   cells), its fluid comes as fluid cells into the same inventory (next to it on the ground when the inventory is
   full). Old fluid drive items stored inside ME cells (R1 allowed that) are not converted; placing such an item
   later fills its new cells from its tags.
4. Anything without room goes into new fluid cells (the smallest tier that holds it) in an iron chest next to
   where it was.
5. The old fluid state is dropped (only the interfaces remain in `storage.fork_me_fluids`); the recovery (pull-in,
   "Take over", salvage on destruction, the hand disassembly, upgrade spots, the drive window) is removed: cells
   carry their fluid, a destroyed drive drops its cells.
6. Every unit is counted before (drives, entries, items) and after (cells filled, cells created), per fluid;
   `FORK-ME-MIGRATE: fluids: ... units before, ... after, ... all fluid kept` in the log, a chat message on a
   difference.

Placing an old fluid drive item (hand, robot, platform) builds an ME Drive with its four fluid cells and the
item's fluid in them (more cells in the free slots if needed, the rest as cells on the ground).

**Totals in the tests:** `migrate --from-ref v0.3.2` and from R1 (`52ec0f3`): 3 old fluid drives (32 000 water;
8 000 water and 10 000 chlorine; 500 water), 700 recovered chlorine without a network at its place and a chest
with two loaded items of 777 water each: 52 754 units before, 52 754 after, no cell added, no chest.

### Ticks

Unchanged intervals: the fluid interfaces (8 per step) and the fluid buses (with the item interfaces and buses,
24 per step) run in the 15-tick I/O step. A fluid total is a table lookup (the engine's totals); the old
per-step loop over all fluid drives and the recovered-fluid pull-in are gone.

### Tests

`runtime`: the fluid test (a drive with four 1k fluid cells: import, export, a fluid cell's round trip through
its tags and the terminal, robots mining the drive with its loaded cells and rebuilding it, full cells, a reported
shortfall, three fluid jobs, a machine mined while it holds a job's fluid) and the fluid cell test (a mixed drive,
tags, the item cell takes no fluid, a fluid cell's capacity, the terminal's entries and a refused take, the fluid
import bus emptying a tank, the fluid export bus filling one, old fluid drive items with fluid placed as drives,
also with more fluid than four cells hold); the level maintainer, circuit interface (water in fluid cells on the
wire) and settings copy tests on the new fluid storage. `migrate`: the totals above, the network's fluid totals,
the drives' cells, the untagged items with their cells.

## Open for R3

* GUIs: pattern provider (pattern slots, AE2 style encoded patterns instead of reading the machine),
  level maintainer (several resources), circuit interface, crafting CPU status, interface (amounts per
  filter instead of a stack), buses (more filters, speed cards), the fluid interface's panel as a window of its
  own (today a panel next to the tank GUI).
* The terminal's crafting tab in the style of the storage tab; a crafting status window per CPU; fluid amounts
  shown on the buttons in AE2 style (k, M) instead of a floored number.
* Cell partitioning (a cell that takes only some items or fluids) and priorities between drives.
* A "view cells" mode in the terminal (per drive and cell).
* Old fluid drive items stored inside ME cells are converted only when placed (see "Migration of fluids").
