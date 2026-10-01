# ME rework (issue #68): design record

Issue #68 replaces the ME network that was built on Factorio's logistic network (controller = roboport
without robots, drive = logistic storage chest, interface = requester chest) by a network that plays like
Applied Energistics 2: cables, a controller, drives with storage cells that keep their contents, a
terminal as the central GUI, interfaces and buses for import and export.

The rework comes in three steps:

| Step | Content | State |
|---|---|---|
| **R1** | the new core: cable graph, controller, drives with cell slots, cells with their contents in tags, the storage API, the terminal, the ME Interface and buses, migration of old networks; autocrafting, level maintainer, circuit interface and fluids moved onto the new API | done (PR #69) |
| **R2** | fluids on cells: fluid storage cells in the ME Drive, the fluid API of the storage engine, fluids in the terminal grid, the fluid interface on the new API, fluid import and export buses, migration of fluid drives, their recovered fluid and loaded drive items; the old recovery removed | done (PR #70, "Fluids (R2)") |
| **R3** | one GUI style and a window for every ME block (replacing the panels next to the game's windows), the terminal as hub (storage, crafting, jobs, cells), the ME Interface's config rows, cell partitions and drive priorities | done (this document, "GUIs, partitions and priorities (R3)") |
| Storage bus | the ME Storage Bus that R1 left out: a chest or cargo wagon as network storage, with filters, priority and read/write mode | done (this document, "Storage bus (after R3)") |

This file is the design record: what was decided and why, and what is still open ("Open points"). The
player's guide is `docs/AE2.md`.

## Network topology

**Members** ("nodes") are the ME entities: ME Cable, ME Controller, ME Drive, ME Terminal, ME Interface,
ME Import Bus, ME Export Bus, ME Storage Bus, ME Pattern Provider, the Crafting CPUs, ME Level Maintainer, ME
Circuit Interface, ME Fluid Drive and ME Fluid Interface. Machines next to a pattern provider are not members, nor
is the chest a storage bus faces.

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

**Entity:** a `simple-entity-with-force` without engine inventory, and a script window with the 10 slots
(open it with the normal open key; since R3 in `scripts/fork-me-windows.lua`, with the drive's priority and a
cell window per slot): click a slot with a cell in the cursor to put it in, click a filled
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
  Cancel), moved onto the new API. Since R3 the terminal is the hub with Storage, Crafting, Jobs and Cells
  tabs (see "GUIs, partitions and priorities (R3)").

Every button calls a function that the runtime test calls directly (`take`, `store_cursor`,
`store_inventory_item`, ...), so the logic behind the GUI is tested headless.

## Import and export

**ME Interface** (`me-network-interface`, placed by the existing `me-interface` item, 1x1 container
with 18 slots that can be filtered like a cargo wagon's): a **filtered slot** is an export slot, the network
keeps it filled with its item up to a full stack; every **unfiltered slot** is imported, its items go into
the network. Inserters and belts work with it as with a chest: inserters put items in (import) and take the
filtered items out (export). The filters are kept in blueprints, copied by settings paste and by cloning
(tag `fork_me_interface`). This is AE2's interface (config slots plus storage) with the slot filter as its
configuration, so it needs no extra GUI in R1. **R3** replaced the slot filters by script-held config rows (item,
quality, amount; see "GUIs, partitions and priorities (R3)").

**ME Import Bus / ME Export Bus** (`me-import-bus`, `me-export-bus`, 1x1, rotatable): a bus faces one
entity. The import bus pulls items out of that entity's output (assembler or furnace result, chest) into the
network, the export bus puts its filtered items into the entity's input (assembler or furnace input, chest),
up to one stack of each in the target. Up to 5 item filters (import: none means everything), set in its
window (open key), kept in blueprints, settings paste and clones (tag `fork_me_bus`).

For Gregtorio both are worth having: belts and inserters feed machines through the interface, and a bus
saves the two inserters (and their power) when one machine is fed from or emptied into the network. R1 left
storage buses (a chest as network storage) out: they would bring back the "network reads chests" model
the rework removes. They came after R3 as one more kind of storage next to the cells, bounded per step (see
"Storage bus (after R3)").

**Throughput** (per I/O step, every 15 ticks): an interface handles up to 8 slots per visit (import all of
a slot, or top a filtered slot up), a bus moves up to 64 items per visit. At most 24 interfaces and buses
are visited per step (round robin); with more of them each is visited less often, the work per step stays
bounded.

## Tick budget

No new `on_tick`, no new interval:

| Interval | Work |
|---|---|
| 15 (was fluids only) | the I/O step: the fluid interfaces and recovered fluid (unchanged, 8 interfaces, 4 entries), 8 storage bus visits (after R3) and then up to 24 item interfaces and buses |
| 20 | autocrafting, level maintainers, circuit interfaces (unchanged) |
| 60 | open ME windows (R3: at most 30, one per player), drive fill lights of changed drives (up to 50 drives), the sweep for vanished members (200 per step) |

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
  `can_insert_fluid` allows, export takes what the network holds. Its panel showed the fluid bytes and types (since R3: its window shows the tank and the status).
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

## GUIs, partitions and priorities (R3)

### One window style

`scripts/fork-me-gui.lua` (new) is the shared GUI: a window is a screen frame `fork_me_window` with a title bar
(caption, drag handle, close button) and a light content frame, and it is the player's `opened` GUI (E and Escape
close it). One window per player: opening another replaces it. Building blocks: slot buttons for items (with
quality) and fluids, number fields, slot grids, headings, wrapping labels; amounts are formatted with `fmt` (999,
1.2k, 12k, 1.5M, 2.5G) on every button and label.

Routing: an acting element carries `fork_me_act = <action>` and its data in its tags; modules register actions
with `G.on(action, fn)` and windows with `G.window(name, { open, refresh, entities })` (entities by name or by ME
kind). `scripts/fork-me-terminal.lua` registers every GUI event of the mod once (click, text, elem, confirmed,
checked, switch, selection, tab, value) and calls `G.dispatch`; one action per element, so no module has to look
at another module's elements. Every handler calls a function of the block's module (or a small `set_*` helper
of `fork-me-windows.lua`) that the runtime test calls through the remote interfaces.

### Own windows instead of panels

`scripts/fork-me-windows.lua` (new) has a window for the drive, a storage cell, the controller, the pattern
provider, the crafting CPUs, the level maintainer, the circuit interface, the fluid interface, the ME Interface and
the four buses (`docs/AE2.md`, "The ME windows"). A click on the block opens it: the custom input linked to the
game's `open-gui` (simple entities without a window of their own: drive, controller, buses, provider) and
`on_gui_opened` (lamps, combinator, tank, container: the game opens its window, the handler sets `opened` to the
ME window, which closes the game's one at once). Both fire for the same click; `open_entity` sees its window open
for that unit and only re-sets `opened`. Fallbacks: the ME Interface's container window stays reachable through
"Open inventory" (`G.open_vanilla`, a one-time bypass in `storage.fork_me_gui_bypass`); the level maintainer's
lamp window is replaced, its circuit condition is edited in the ME window through the lamp's own control behavior
(so the game keeps copying and blueprinting it). Removed: the drive GUI of the network module, the provider window
of the autocrafting module, the relative panels on the lamp (maintainer), constant combinator (circuit interface)
and storage tank (fluid interface), the bus window of the I/O module, and every `on_open_input` / `on_gui_*`
handler of those modules; the terminal's event routing to them; their frames are destroyed on a mod update.

Refresh: the terminal step (60 ticks) calls `G.refresh_all`: only players with an ME window open, at most 30;
a window whose entity is gone or out of reach (a window opened from the terminal: the terminal's reach) is closed.
A window part is rebuilt only when its data signature changed (kept in the part's tags), so open tooltips and
focused number fields survive the refresh; number fields are never rebuilt by their own change.

### Terminal as hub

Tabs Storage (sort, kind filter all/items/fluids, grid, inventory row), Crafting (the craftable grid in the
storage style, picked resource, amount, plan preview with missing and taken resources as slot buttons, Craft),
Jobs (amount, progress, status, Cancel), Cells (the network's drives by priority with their cells; a click opens
the drive or cell window with a Back button and the terminal's reach). The search field above the tabs filters
Storage and Crafting. Per player state: `storage.fork_me_terminal[player] = { entity, filter, sort, kind, pick,
amount, tab, signatures }`. Data functions for the test: `entries(net, filter, sort, kind)`, `craft_preview`,
`start_craft`, `cancel_job`, `jobs`, `cells`.

### ME Interface config

AE2's interface has config slots with amounts; R1 used the container's slot filters (one stack per filtered
slot). R3: `storage.fork_me_io.recs[unit].config = { [1..9] = { name, quality, amount } }`. The step keeps the
inventory count of each configured item at its amount (fill with `extract_to`, take a surplus back with
`can_insert`/`remove`/`insert`), then imports the other stacks (up to 8 operations per visit as before). Lazy
migration: the first `config_of` of an interface without config turns its slot filters into config rows (one stack
per filtered slot, the same item adds up, at most 9 items) and clears the filters; a blueprint tag of R1
(`{ filters }`) is converted the same way, R3 writes `{ config = { { slot, name, quality, amount } } }`. The
container prototype keeps `with_filters_and_bar` so the filters of old saves are still there to be read.

### Partitions and priorities

Kept simple and documented in `docs/AE2.md` ("Partitions and priorities"):

* A cell partition is a set of exact keys (`name`, `name@quality`, `fluid/<name>`), at most the cell's types, no
  items with tags. A partitioned cell takes nothing else (`cell_room`). It is part of the cell's tags, so it
  travels with the cell; an empty partitioned cell is an item with tags.
* A drive priority (-1000 ... 1000) applies to every cell in it.
* Insertion: priority descending; inside one priority partitioned-for-the-key, then holding-the-key, then any.
  Extraction: priority ascending; inside one priority unpartitioned first. AE2 does the same with priorities and
  prefers partitioned cells on insertion; taking from unpartitioned (overflow) cells first keeps the partitioned
  ones full.
* Cost: the order is cached per network (`net.order`, rebuilt when a cell or setting changes, 500 cells sort in
  well under a millisecond); a network with one priority and no partition keeps the R1 path (`net.uniform`).
  Extraction sorts only the cells that hold the key (the index).
* Blueprints, paste, clone: drive tag `fork_me_drive = { priority, partitions = { ["slot"] = keys } }` (string
  slot keys: blueprint tags need them); a slot without a cell keeps the template for the next cell
  (`slot_partition`). Settings paste sets every slot (a source slot without partition clears the target's).

### Tests (R3)

`devcheck runtime`, "ME partitions and windows test": insertion and extraction order with priorities and
partitions, the all-partitioned network that refuses other items, partition from contents, the partition in the
tags of empty and loaded cells, a fluid cell's partition, drive settings through the blueprint handler, a revived
ghost, settings paste and a clone, `fmt`, a window for every ME block, the data and set functions of every window,
the terminal's kind filter, cells tab, craft preview and jobs tab. The ME import/export test now checks the
interface config (fill, top-up, surplus back, import of the rest, paste, old filters and old blueprint tags as
config). The settings copy test lost its check of the panels' anchors. Not testable headless (no player): building
the windows, the clicks, the replacement of the game's windows; the pull request has a click-through list.

## Storage bus (after R3)

### Decision

R1 left the storage bus out: "they would bring back the 'network reads chests' model the rework removes". That
model was the problem of the old network as a whole (the logistic network *was* the storage, so nothing could be
counted, ordered or kept consistent). As one more kind of storage next to the cells it is AE2's storage bus and
plays the way AE2 players use it: an **input chest** (a high priority bus with filters that the network fills
first, for a machine that takes from the chest), an **overflow chest** (a low priority bus without filters), or a
chest or cargo wagon that a factory fills and the network reads (read only). What made the old model costly stays
bounded: one bus reads one inventory, at most 8 buses per I/O step, never the whole map.

### Model: an external cell

`me-storage-bus` is a rotatable 1x1 member (kind `storage-bus`, 4 kW on the controller, like the other buses). It
faces a chest, a logistic chest or a cargo wagon (`container`, `logistic-container`, `cargo-wagon`). Its record is
an **external cell** of the storage engine (`scripts/fork-me-network.lua`, `storage.fork_me_net.ext[unit]`, cell id
`"<unit>:ext"`): `items` is a snapshot of what the bus shows of the inventory, `partition` its filters, `priority`
its priority, `hidden` set in write only mode. The network's totals and index include the snapshot like a cell's
contents, so `count`, `contents`, the terminal, autocrafting plans, the level maintainer and the circuit interface
see the chest without knowing about buses. The real inventory is reached only through four functions of the bus
module (`scripts/fork-me-storagebus.lua`, `N.ext_handlers["storage-bus"]`): `room`, `insert`, `count` and
`extract`. `insert_key` calls `insert` for an external cell and adds what went in to the snapshot; `extract_key`
calls `count` first, corrects the snapshot and the totals to it, and then `extract`s at most that. A recompute of
the network (merge, split, rebuild) takes the external cells of its members back in with their snapshot.

**Order:** the bus takes part in R3's order with its priority (-1000 ... 1000, the same range as the drives); its
filters act as a partition (a filtered bus gets its items before unfiltered storage of the same priority and never
takes other items). Within one priority and one pass, cells come before storage buses on insertion and storage buses
before cells on extraction: the network's own storage is filled first, a chest is the overflow and is emptied
first. (Without this rule the order depended on when the cells were put into the drives, a test found it.)

**Modes:** read and write (default); read only (`room` and `insert` give 0: the network takes from the inventory
and shows it, never puts anything in); write only (`hidden`: the snapshot stays empty, so the network neither
shows nor takes from it, but stores into it: AE2's "insert only").

**What the bus shows and moves:** plain items that do not spoil (`get_spoil_ticks` 0 for their quality), of any
quality, and no item types with own data (items with inventory, tags or entity data, armor, blueprints and other
planners): the same rule as the cells (`M.storable`), decided per prototype so a visit needs no per-slot reads.
With filters only the filtered items (exact name and quality). Fluids are not read (no fluid storage bus, see
"Limits").

### Polling and consistency

Inserters, players, robots and trains change an inventory without an event, so the bus polls it:

* The I/O step (`on_nth_tick(15)` of `scripts/fork-me-io.lua`, no new interval) calls `storage_bus.on_step()`
  after the fluid step: **8 bus visits per step**, round robin over the buses. A visit checks the target (cached
  until it is invalid, the bus is rotated or a wagon left; else one `find_entities_filtered` at the tile in front),
  reads the inventory once (`get_contents`) and passes it to `N.ext_sync`, which applies only the differences to the
  snapshot, the totals and the index.
* Everything the network itself does through the bus (insert, extract) updates the snapshot at once, so a visit
  never counts it twice.
* **Staleness window:** between two visits of a bus, at most `ceil(buses / 8) × 15` ticks (50 buses: 7 steps, 105
  ticks, 1.75 s), the snapshot can be off in two ways. Items that came in are not shown yet: the network promises
  less than there is (safe). Items that went out are still shown: the terminal, a plan or a level maintainer can
  count on them, but every extraction asks the inventory first (`count`), corrects the snapshot and the totals and
  takes only what is there; the rest comes from other storage, or the caller gets less. Every caller already
  handles a shortfall: `extract_to` gives back what the target got too much (the R1 code for this called
  `remove_item` on a `LuaInventory`, which has no such method: it was never reached before; fixed), a crafting job
  that cannot take its reservation undoes it ("stock-changed"), jobs and level maintainers retry, an interface or
  an export bus moves less. So the network never hands out an item that is gone and never duplicates one; a stale
  number on the screen or in a plan is corrected at the next visit or extraction.
* Insertion asks the inventory too (`get_insertable_count`, then `insert`): a chest that filled up in the meantime
  takes what fits, the rest goes to the next storage in the order.

### Rules

* **One bus per inventory:** a second bus facing an inventory that another bus already uses is refused with the
  status "Another ME Storage Bus already uses this inventory" and shows nothing (`storage.fork_me_sbus.claims`:
  inventory owner unit -> bus unit). When the first bus is removed or turned away, the second takes over at its
  next visit. Counting a shared inventory once was the alternative, but two buses can differ in filters, mode and
  priority: whose settings would apply to the one snapshot? A refusal with a status is clear and costs nothing.
  This covers two buses of the same network and of different networks.
* **No loops:** a bus facing an ME block (any member, or any `me-` entity such as an old ME chest) is refused with
  "Faces an ME block" and does nothing. A storage bus on an ME Interface would show the network its own items.
* **Removal:** a removed bus (mined, destroyed, script raised destroy) detaches its external cell
  (`N.on_removed` -> `ext_detach`), the inventory leaves the totals at once. A removed inventory (the removal events
  now also filter `logistic-container` and `cargo-wagon`) is dropped by its bus at once (`on_removed`: empty
  snapshot, status "no target"); one removed without an event, or a wagon that drove away, at the bus's next visit or
  at the first extraction (its `count` is 0). The sweep of vanished members detaches a vanished bus.
* **Settings:** mode, priority and up to 18 item filters, in the bus's window (`scripts/fork-me-windows.lua`), in
  blueprints (tag `fork_me_storage_bus = { mode, priority, filters }`, through the blueprint handler of the
  autocrafting module), by settings paste and by cloning. A change of settings visits the bus at once.
* **Saves:** a new entity, no migration. `on_configuration_changed`: the graph rebuild keeps the external cells of
  buses that still exist, then `fork_sbus.on_configuration_changed` registers every bus, forgets the targets and
  claims and visits each bus once.

### Cost: 50 storage buses on chests of 48 slots

* Per visit: the target check (a validity test; a `find_entities_filtered` only without a target, or for a wagon),
  one `get_contents` of 48 slots, a Lua loop over at most 48 entries (cached prototype check, filter lookup) and
  the diff against the snapshot (at most 48 old and 48 new keys, table writes only). About 30 to 50 µs.
* Per I/O step: 8 visits, about 0.25 to 0.4 ms every 15 ticks, 0.02 to 0.03 ms per tick on average. The step's
  other work (24 interfaces and buses, 8 fluid interfaces) is unchanged.
* Each bus is visited every 7 steps (105 ticks): that is the staleness window above.
* Storage calls: `count` stays a table lookup. Insertion reaches a bus only in the order (usually after the cells
  of its priority); each bus it reaches costs one `insert`. `can_insert` (the ME Interface's surplus, rare) asks
  `get_insertable_count` of every bus whose filter and mode allow the item: 50 calls of about a microsecond. An
  extraction costs one `get_item_count` and one `remove` per bus that shows the item.
* Memory: a snapshot of at most 48 keys per bus.

### Limits

* No fluid storage bus: a tank's fluid is shared with its pipe segment (`get_fluid_count` reports only the tank's
  part), two tanks of one segment would show the same fluid twice, and a removal from one tank changes the others.
  Fluids stay in fluid cells.
* Items are moved by count (`LuaInventory.insert` / `remove`): the health of damaged items and the durability or
  ammunition left in partly used tools and magazines in a bus's chest are not kept when the network takes them out
  (cells refuse such items, a chest cannot). Spoiling items are not shown at all.
* An import bus or ME Interface that empties a chest a storage bus shows moves the items in a circle (into the
  network, which may store them back into that chest); AE2 has the same. Give the storage bus a filter or a lower
  priority.
* Cargo wagons: only the wagon whose body covers the tile in front of the bus; a train that leaves drops out of the
  network at the next visit or extraction.
* Not tested in the real game: the window, cargo wagons (no train in the headless test), the sprite.

### Tests

`devcheck runtime`, "ME storage bus test": own network with a drive (two 1k cells), a terminal and seven storage
buses on iron chests. The chest's items are counted only after a visit (no event); a terminal take comes out of the
chest; a filtered bus gets its item, an unfiltered item goes into the cells; priority 10 against the cells gets the
item first, priority -10 gets it after the cells; extraction from the bus first at -10, from the cells first at 10;
read only (nothing in, taking works), write only (not shown, not taken from, filled), read and write again; a stale
snapshot (items taken out by hand: an extract and a terminal take get only the real ones, the totals are corrected);
two buses on one chest (counted once, one refused, the other takes over when the first is removed); a bus facing a
cable; a chest removed with an event (at once) and without (at the next visit); a removed bus; after each part the
network's totals must equal the cells plus what the working buses' chests hold; the settings in a blueprint tag, on
a revived ghost, by paste and clone, the window's data and a filter button; then an inserter puts wood into a
chest and the network must show it within one visit cycle (plus the test's own 10 tick granularity). Two mutations
were checked to fail it: extraction trusting the snapshot instead of the inventory, and no claim (two buses count
the chest twice). `migrate --from-ref v0.3.2` and every other runtime test pass unchanged.

## Open points

* Pattern provider with AE2 style encoded patterns (pattern slots) instead of reading the machine next to it;
  a level maintainer with several resources; upgrade and speed cards on buses; more than 5 bus filters.
* Fuzzy or inverted partitions (AE2 cards), also for storage bus filters; a fluid storage bus (see "Storage bus
  (after R3)", "Limits").
* Terminal search by localised name (a script cannot read localised names).
* The windows are checked by hand only (see "Tests (R3)").
* Old fluid drive items stored inside ME cells are converted only when placed (see "Migration of fluids").
