# ME rework (issue #68): design record

> Written in Gregtorio Continued (issue #68 and its follow-ups; issue numbers are Gregtorio's). Since Gregtorio issue
> #83 the network is the mod ME Network. The prototype files are named as in this repository (`prototypes/network.lua`
> was Gregtorio's `120-fork-ae2.lua`, `autocrafting.lua` its 121, `fluids.lua` its 122); the tests that were in
> Gregtorio's `tools/devcheck` are in this repository's `tools/devcheck`, except the migration of old saves, which
> stayed in Gregtorio's `migrate`.

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
| Fluid storage bus | the ME Fluid Storage Bus: the fluid segment of a tank as network storage, one bus per segment | done (this document, "Fluid storage bus (after the storage bus)") |
| Encoded patterns | issue #80: blank and encoded pattern items, the terminal's Patterns tab, the pattern provider with 9 slots, recipe switching, processing patterns with outputs that come back into the network, migration of the old providers | done (this document, "Encoded patterns (issue #80)") |
| Unified I/O | me-network issue #3: one ME Interface, Import Bus, Export Bus and Storage Bus for items and fluids; the four fluid blocks removed and migrated | done (this document, "Items and fluids in one block (me-network issue #3)") |

This file is the design record: what was decided and why, and what is still open ("Open points"). The
player's guide is `docs/AE2.md`.

## Network topology

**Members** ("nodes") are the ME entities: ME Cable, ME Controller, ME Drive, ME Terminal, ME Interface,
ME Import Bus, ME Export Bus, ME Storage Bus, ME Fluid Storage Bus, ME Pattern Provider, the Crafting CPUs, ME Level Maintainer, ME
Circuit Interface, ME Fluid Drive and ME Fluid Interface. Machines next to a pattern provider are not members, nor
is the chest a storage bus faces or the tank a fluid storage bus faces.

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
  step (every 60 ticks, 200 members per step, round robin; since issue #5 from a list taken once per round) and
  removed the same way from its stored data.
* The derived data of a network (controllers, status, drives, storage totals, item index, power) is
  recomputed only for the networks a change touched, and only when the change can alter it (a cable
  joining one network changes nothing but the member count; since issue #5 any member but a controller joining or
  leaving one network without splitting it adds or removes only what it holds).
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
Not storable (the interface leaves them in its slots, the terminal says so, each with a message that names
the refusal): items with an inventory, armor (it can carry a grid), blueprints and books, planners and selection
tools, the spidertron remote, vehicles and other items with entity data, items with a label, items that spoil
(the network would stop their decay), and partly used tools, ammunition and repair packs (the network would
repair them). A damaged item is stored with its health since issue #104. See "What the network stores (issue #76)"
below.

**What the network stores (issue #76):** `N.storable` decides by the prototype type (`N.item_class`), never by
`stack.item`. `stack.item` (a `LuaItem`) is set for every stack with a state of its own, measured on 2.0.77: tools
(science packs), ammo, repair tools, armor, planners, an item that spoils, an item with health below 1. Before the fix of issue #76
the first line of `storable` took it for "carries data of its own", so no science pack, magazine or repair pack
could enter the network by any path that asks `storable`, and the lines meant for them (a whole one may be stored, a
used one not) were never reached.

| Class | Types | The network |
|---|---|---|
| plain | `item`, `gun`, `capsule`, `module`, `rail-planner`, `space-platform-starter-pack` | stored by key `name@quality`; a damaged one (`health` below 1) of an item that places an entity is stored with its health under a key of its own (issue #104), any other damaged item is refused |
| worn | `tool`, `ammo`, `repair-tool` | stored when the top item of the stack is whole: `durability` equals `get_durability(quality)` (a quality scales it: a legendary science pack has 6, a legendary repair pack 1800), `ammo` equals `magazine_size`; a used one is refused as damaged |
| tags | `item-with-tags` | stored with tags and description under its own key; refused with a label (a label cannot be put back with `set_stack`) |
| label | `item-with-label` | stored plain when it has no label |
| refused | `blueprint`, `blueprint-book`; `deconstruction-item`, `upgrade-item`, `selection-tool`, `copy-paste-tool`; `spidertron-remote`; `item-with-entity-data`; `armor`; `item-with-inventory` | `cannot-store-blueprint`, `-planner`, `-remote`, `-entity`, `-armor`, `-inventory` |
| unknown type | anything else | `cannot-store`: a type of a later game version is refused rather than stored without what it carries |

A stack of tools holds one wear: its top item's. Measured: `remove` takes the used item first (a stack of 5 with a
used top gives 4 whole ones after one removal), a whole item inserted merges into a used stack (8 with the used top),
and setting `count` on a used stack makes the top whole. So a count says nothing about wear, and a stack with a used
top item is refused as a whole (the player can take it apart by hand). Taking out never makes a whole item used:
`extract_to` builds new stacks.

Paths and what they do with a used stack: the terminal's store, the pane's shift + click and control + click,
and the stack path of import buses and interfaces call `storable` and refuse it; a control + click goes on with the
next stack (a used stack in front of whole ones no longer stops it). The import bus keeps tools and ammo off its
by-count path (a removal by count would take the used item first and hand it on as a whole one). An interface row's
surplus is taken from whole stacks only (`N.remove_whole`). A storage bus shows, counts, takes and fills only whole
stacks of a worn type (`N.whole_counts`, `count_whole`, `remove_whole`, `has_used`), and puts nothing into a chest
that holds a used stack of that item (it would merge). Before, a storage bus showed a used pack as a whole one and
a removal by count gave it out as a whole one.

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
bounded. (Issue #5 replaced the steps: see "Scheduler and performance at size".)

## Tick budget

The budget of R1 to R3 (issue #5 replaced it by the scheduler and one `on_tick` handler: see "Scheduler and
performance at size"; the 60 tick step stays). No new `on_tick`, no new interval:

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
| ME storable items (issue #76, `storable.lua`) | science packs, magazines, repair packs (also legendary) and a gun in and out by the terminal's store, shift + click at the terminal and another block, control + click; an import bus on a chest (every tool of the game once), an interface (the stacks it imports, the surplus of a row with a used stack first), an export bus, a storage bus (whole stacks counted, the used one stays in the chest), the round trip export bus to import bus; a used pack, magazine and repair pack and a damaged chest refused as damaged and left as they were; a blueprint, book, planners, remote, vehicles, armor with equipment, an item with an inventory and items with a label refused each with its own reason; an item with tags back with its tags. Every result is logged (`DEVCHECK-RUNTIME-STORABLE-CENSUS`) |
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
  fluids with `insert_fluid` (input boxes of a machine, a tank). 1000 units per visit, in the I/O step (issue #5:
  the bus's speed times the ticks since its last visit).

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
24 per step) run in the 15-tick I/O step (issue #5: in the scheduler). A fluid total is a table lookup (the engine's totals); the old
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
quality, whole tools, ammo and repair tools, and no item types with own data (items with inventory, tags or entity
data, armor, blueprints and other planners): the same classes as the cells (`N.item_class`, `M.storable`), decided per
prototype so a visit needs no per-slot reads (a chest with a tool or ammo in it is read stack by stack once per visit).
With filters only the filtered items (exact name and quality). Fluids are not read: they have their own bus, see
"Fluid storage bus".

### Polling and consistency

Inserters, players, robots and trains change an inventory without an event, so the bus polls it:

* The I/O step (`on_nth_tick(15)` of `scripts/fork-me-io.lua`, no new interval) calls `storage_bus.on_step()`
  after the fluid step: **8 bus visits per step**, round robin over the buses (issue #5: each bus is due at a tick
  of its own, 8 visits per tick, an unchanged chest is read again after up to 2 s). A visit checks the target (cached
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

* Fluids: the item storage bus reads no fluid. A tank's fluid is shared with its pipe segment (`get_fluid_count`
  reports only the tank's part), so two tanks of one segment would show the same fluid twice; the fluid storage bus
  therefore stores by segment (see "Fluid storage bus").
* Items are moved by count (`LuaInventory.insert` / `remove`): the health of damaged items in a bus's chest is not
  kept when the network takes them out (cells refuse such items, a chest cannot). Tools, ammo and repair tools are
  the exception since issue #76: whole stacks only (see "What the network stores"). Spoiling items are not shown at all.
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

## Fluid storage bus (after the storage bus)

### Decision: the fluid segment is the unit of storage

The item storage bus left fluids out because a tank does not own its fluid: in 2.0 every connected pipe and tank
forms one **fluid segment** with one fluid, one amount and one temperature, and `get_fluid_count` of a tank reports
only its share. Two buses on two tanks of one segment would each count the whole segment (or each a share that
moves with every tick of the fluid system), and taking from one tank changes the other. The **segment** is the unit
that has a well defined amount, so the bus stores by segment, not by tank:

* **Identity:** `LuaFluidBox.get_fluid_segment_id(box)` of the faced fluid box, key `"s<id>"`. A fluid box that
  belongs to no segment (tested: a machine's box, also with a pipe on it) is its own storage, key `"u<unit>:<box>"`.
* **Contents:** `get_fluid_segment_contents(box)` gives the segment's total (one fluid since 2.0; fractional
  amounts, although the API documents `uint32`).
* **Insert and extract:** the faced entity's `insert_fluid` / `remove_fluid` act on the whole segment (tested on two
  tanks joined by a pipe: 60000 inserted into one tank fill both, 50200 units; a removal of 30000 from one tank takes
  it from the segment). A box without a segment is changed through `LuaFluidBox` (`fluidbox[box] = ...`).
* **Room:** `LuaFluidBox.get_capacity(box)` is the capacity of the segment (tested: 50200 for two tanks and a pipe)
  minus its contents; nothing when it holds another fluid or the faced box has a filter for another fluid.

What the engine sees is the same external cell as the item bus (`N.ext_handlers["fluid-storage-bus"]`, keys
`"fluid/<name>"`); two small engine changes were needed: an external cell gets fractional amounts for fluid keys
(the item path floors), and its snapshot is cleared below `ZERO` like the cells.

### Claims, splits and merges

* **One bus per segment** (`storage.fork_me_fsbus.claims`: key -> bus unit), the same rule as one bus per inventory:
  a second bus on the same segment, through any tank of it, gets "Another ME Fluid Storage Bus already uses this fluid
  segment", shows nothing and takes over at its next visit when the first one goes.
* **Ids change:** building or removing a pipe merges or splits segments and gives them new ids at once (tested:
  removing the pipe between two tanks gives one part a new id in the same tick; rebuilding it merges them under the
  old id). Every visit reads the id again (one API call) and re-claims; a stored claim is never trusted alone: it
  counts only while that bus's own live id is still the key.
* **Conflicts in unit order:** when two buses end up on one segment (a merge), the lower unit number keeps it; the
  other one is cleared at once (empty snapshot, "shared-target"), so the segment is never in two snapshots. When a bus
  finds a stale claim (the owner's segment got a new id), it takes the segment and visits the old owner at once, which
  then claims its new segment: a split is complete after one visit.
* **Ownership in every handler:** `room`, `insert`, `count` and `extract` work only while the bus owns the segment it
  faces now. Between a split and the next visit a bus therefore takes nothing from a segment it no longer owns (its
  `count` is 0 and the engine corrects its snapshot), and two buses never take from the same fluid.
* **Removals:** a removed bus releases its claim and detaches its cell. A removed tank that a bus faces empties that
  bus's snapshot at once. A removed pipe, underground pipe, pump or tank (the removal events now also filter `pipe`,
  `pipe-to-ground` and `pump`) marks the bus that owns its segment for the next I/O step (`urgent`, visited before the
  round robin), so a split is seen within 15 ticks, not after a full cycle.

### Temperature

The network keeps one temperature per fluid (R2: stored by name, what comes out has the fluid's default
temperature). A segment can hold its fluid at any temperature. Decision: **read it, refuse inserts.**

* The bus counts the segment's fluid at whatever temperature it has, like the fluid import bus: what the network
  hands out from it has the default temperature (hot steam loses its heat when it leaves through the network, the
  rule of R2).
* The network puts nothing into a segment whose temperature differs from the fluid's default by more than 1 degree
  (status "temperature", shown in the bus's window with the temperature). `insert_fluid` would mix the temperatures:
  the network's 15 degree steam would cool a 500 degree steam tank (tested: 10 units at 80 degrees into 20200 at 15
  give 15.03 degrees). An empty segment takes fluid at the default temperature.
* The alternative, a segment at another temperature not counted at all, would hide a tank the player put a bus on;
  refusing only inserts keeps the tank's heat intact and its fluid visible. A player who must keep hot steam out of
  the network's hands puts no read and write bus on it (write only, or no bus).

### Polling, settings, cost

* The I/O step (15 ticks, no new interval) calls `fluid_storage_bus.on_step()` after the item storage buses: first
  the buses marked by a removal, then **8 visits** round robin (issue #5: the scheduler, as the item side). A visit: the target check (cached; a
  `find_entities_filtered` at the tile in front only without a target or after a rotation, then
  `get_pipe_connections` per box to pick the box facing the bus), `get_fluid_segment_id`,
  `get_fluid_segment_contents` and `fluidbox[box]` (the temperature): three API calls and a diff of one key.
* Every insert and extract works on the real segment (`count` asks the segment before every extraction, `room` the
  segment's capacity), so a stale snapshot never hands out fluid that is gone. The fluid export bus and the fluid
  interface's export inserted into their target first and then took from the network without checking the result;
  with a bus's segment behind the network that could duplicate fluid, so both now take back from the target what the
  network did not give.
* Settings: mode (read and write, read only, write only), priority (-1000 ... 1000, shared with the drives and the
  item buses) and up to 5 fluid filters, in its window, in blueprints (tag `fork_me_fluid_storage_bus`), by settings
  paste and cloning. The order is the one of the item bus: within one priority cells first for inserts, buses first
  for extracts; a filtered bus first among the buses.

### Cost: 50 fluid storage buses

* Measured headless (2.0.77, 50 buses on 50 storage tanks in one network, `game.create_profiler`): 1600 visits in
  20 to 24 ms, **about 12 to 15 µs per visit**, so about 0.1 to 0.12 ms per I/O step (8 visits) every 15 ticks,
  under 0.01 ms per tick on average.
* Each bus is visited every `ceil(50 / 8) = 7` steps, 105 ticks (1.75 s): the staleness window. A removal that may
  split a segment is seen in the next step (the urgent visit).
* Storage calls: `fluid_count` stays a table lookup. Insertion reaches a bus only in the order (one `get_capacity`,
  one `get_fluid_segment_contents` and one `insert_fluid`); an extraction one `get_fluid_segment_contents` and one
  `remove_fluid` per bus that shows the fluid. A removed fluid entity costs one loop over the bus list and one id
  lookup per fluid box.
* Memory: one key per bus snapshot, one claim per bus.

### Limits

* A machine's fluid box has no segment: a bus on a machine stores in that one box (`fluidbox` read and write); on a
  machine with several boxes the box whose pipe connection points at the bus is used (else the first). Rarely useful;
  tanks are the intended target.
* Fluid wagons are not supported (no fluid box segment; `create_entity` needs a rail, so untested).
* The engine may reuse a segment id after the segment is gone; a claim is checked against the owner's live id, so a
  reused id never lets two buses own one segment.
* The fluid import bus emptying a tank of a bus's segment, or a fluid export bus filling one, moves fluid in a
  circle, like the item buses. Give the fluid storage bus a filter or a lower priority.
* Temperature: inserts into a segment at another temperature are refused; what leaves the network from such a
  segment has the default temperature (see above).
* Not tested in the real game: the window, the sprite, a large fluid system under load.

### Tests

`devcheck runtime`, "ME fluid storage bus test": own network with a drive (four 1k fluid cells), a terminal, six
fluid storage buses on storage tanks, a pump, a fluid export bus and a level maintainer. Two tanks joined by a pipe
are one segment: counted once after a visit (not before), the second bus refused; the terminal's grid shows the
fluid and refuses it by hand; an extract (what autocrafting and the export buses call) takes it from the segment.
Removing the pipe splits the segment: an extract before any visit takes at most what the first bus still owns, then
the second bus takes its part. A filtered insert goes into its tank, a fluid no bus holds into the cells; priority 10
and -10 for storing and taking; read only and write only; a stale snapshot (fluid taken out by hand: the extract gets
only what is there and the totals are corrected); hot steam (status "temperature", counted, the network's steam goes
into the cells, the tank stays at 500 degrees, taking works); a tank removed with an event, a removed bus, a bus
facing a cable; after each part the network's fluid must equal the cells plus the segments of the working buses (each
segment once); the settings in a blueprint tag, on a revived ghost, by paste and clone, the window's data. Then, over
ticks: the fluid export bus takes from the first segment, the level maintainer counts it ("stocked") and a pump that
fills a tank is in the network within one visit cycle. Two mutations were checked to fail it: no claim (every bus
counts its segment: the network shows 2000 of 1000) and `count` trusting the snapshot (the stale extract leaves 100
phantom units). `migrate --from-ref v0.3.2` and every other runtime test pass unchanged.

## Encoded patterns (issue #80)

Until 0.4.1 a pattern provider read the recipe of the machines next to it (a furnace: a recipe chosen in the
provider): one machine was one pattern and the provider held nothing. Issue #80 brings AE2's model: a pattern is an
item, encoded in a terminal, and a provider holds several. Code: `scripts/fork-me-patterns.lua` (the pattern data and
item, encode, clear), `scripts/fork-me-autocraft.lua` (provider slots, scan, planner, jobs, arrivals, migration),
`scripts/fork-me-terminal.lua` (Patterns tab), `scripts/fork-me-windows.lua` (provider window); prototypes in
`prototypes/autocrafting.lua`. The player's guide: `docs/AE2.md`, "Autocrafting".

### The pattern and its item

* **Data:** `{ kind = "crafting" | "processing", recipe, inputs, outputs }`, rows `{ key, amount }` with the resource
  keys of autocrafting (item name, `fluid/<name>`). `normalize` validates (prototypes exist, amounts > 0, items whole,
  each key once, at most 9 inputs and 6 outputs, no items with tags as rows: the planner never moves those) and
  refreshes a crafting pattern's rows from its recipe. The planner and the jobs read a crafting pattern's recipe
  itself (probabilities and ranges), a processing pattern's rows (exact).
* **Identity:** `c/<recipe>` or `p/<sorted inputs>><sorted outputs>`. Equal patterns in several providers are one
  pattern of the network; their machines are pooled.
* **Items:** `me-blank-pattern` (plain item, LV assembler recipe in `me-autocrafting`) and `me-encoded-pattern`
  (item with tags, stack size 1, no recipe). The tag `fork_me_pattern` is the data; the custom description is the
  tooltip (kind, recipe, inputs, outputs with rich text icons). Encoded patterns can be stored in the network (they
  are items with tags: kept exactly, equal ones stack in a cell) and are never planning stock.
* **Encoding** (`P.encode(cursor, inventory, network, pattern)`): the blank comes from the hand, else the inventory,
  else the network; the encoded pattern replaces a single blank in the hand, or goes into an empty hand, else into
  the inventory (the blank is taken first so its slot can be the free one; with no room it goes back). Nothing is
  created or lost: one blank in, one encoded pattern out.
* **Clearing** (`P.clear(stack)`): an encoded pattern becomes one blank. AE2 does it with shift right click on the item;
  a mod cannot catch a click on an inventory slot (custom inputs know the selected entity, not the slot), so it is the
  terminal's "Clear pattern in hand" button.

### Where patterns are encoded: a tab of the ME Terminal

R3 made the terminal the hub of the network (storage, crafting, jobs, cells). AE2 has a separate Pattern Encoding
Terminal; here a **Patterns** tab fits R3's window design better: no new block, prototype, recipe or graphics, the
blanks of the network are at hand, and the tab sits next to the Crafting tab where the patterns are used. The tab's
logic is in functions of the terminal module that the runtime test calls (`new_editor`, `set_editor_recipe`,
`set_editor_row`, `pattern_of`, `encode`, `clear_pattern`, `load_pattern`, `blanks`); the recipe chooser is the
game's (with its search), and only recipes the force has unlocked are accepted.

### The provider: 9 slots in script storage

The provider stays a `simple-entity-with-force` (no new prototype type: changing a prototype's type would delete the
entities of every save). Its patterns are data in `storage.fork_ae2.providers[unit].slots[1..9]` (exactly as they
came out of the item, validated by the scan), like the cells of a drive. Window and open key: click a slot with a
pattern in hand to put it in (swap with one in the slot), click to take it out (shift: inventory), click the provider
with a pattern in hand: first free slot.

| Event | The patterns |
|---|---|
| mined by a player or robot | into the event's buffer (the player's inventory, the robot's cargo) |
| destroyed | dropped on the ground (`spill_item_stack`) |
| removed by a script with `raise_destroy` | dropped on the ground (the event has no inventory) |
| gone without an event | dropped where it stood at the next scan (the record keeps surface and position); the force is told |
| blueprint, copy and paste | see "Blueprints" below |
| settings paste, clone | the priority only |

### Crafting patterns: switching the recipe

A crafting pattern's targets are the assembling machines next to the provider that can make the recipe: crafting
category, recipe researched, no other fixed recipe, every item ingredient within a stack, and fluid boxes: with the
recipe set the exact map (filters, capacity, pipes, temperature); before a switch by count and size of unconnected
input and output boxes (the exact map is made after `set_recipe`; a machine that fails then is not used again by that
job). Decisions:

* **Items left in the machine when the recipe changes:** the machine is switched only when idle (no craft in
  progress); everything in its input and output inventories and fluid boxes goes into the network first (stored with
  `N.no_arrival`, so no job claims it); if the network cannot take all of it the machine is not switched and the job
  waits. What `set_recipe` itself would return is stored too (or spilled at the machine). Nothing is lost.
* **A machine busy with another pattern:** one lease per machine (`busy[unit] = job`). A step needs an idle machine
  that has the recipe, else an idle one to switch; a busy machine is skipped and the step waits ("machine"). Jobs take
  turns by the round robin of the step (8 jobs per step; issue #5: one job per tick, each at most every 20 ticks);
  within a job the steps go in plan order. No queue is kept: a
  machine is taken by the first job that finds it idle.
* **The machine cannot make the recipe** (category, not researched, fixed recipe, stack, fluid boxes, a furnace): the
  pattern has no target in that provider; with none at all it is no pattern of the network (`ignored[reason]`, shown
  per slot in the provider window and counted in the crafting tab's info line).
* The machine keeps the last recipe; a player's own recipe on such a machine is overwritten ("dedicate machines").

### Processing patterns: output detection

A processing pattern's inputs are pushed into a machine next to the provider (a furnace, an assembling machine with a
recipe of its own, which is never changed) as a lease, or into a chest next to it (no lease: the start of a line).
The question of the issue: how does a job know its outputs arrived?

* **Count deltas against expected outputs** (compare the network's count with the count at hand-over) were rejected:
  any other change of the same item (a player taking it, an import bus importing the same item from elsewhere, another
  job storing its result, a level maintainer's job) would be counted as an arrival or hide one, and two jobs waiting
  for the same item could not be told apart.
* **Chosen: interception of arrivals, as in AE2** (AE2's crafting service offers items entering the network to the
  CPUs that wait for them). The network module's public insert functions (`insert`, `insert_stack`,
  `insert_partial`, `insert_fluid`: import bus, ME Interface, fluid import bus, fluid interface, terminal) offer what
  comes in to `N.on_arrival(net, key, count)` before storing it. A running job with processing steps that still owe
  `key` (issued runs times the amount, minus what was received) takes it into its pool, at most what it owes, in job
  order; the rest is stored. Normal quality plain keys only. `can_insert` and `can_insert_fluid` add what jobs wait
  for (an import bus may import outputs even when the cells are full). Outputs collected from the machine's output
  when a lease ends count the same way. A storage bus does not insert (it sees a chest change), so outputs that only
  appear in a chest behind a storage bus do not count (AE2 behaves the same).
* **Timeout with failure:** a job whose processing steps wait only for outputs shows "Waiting for the outputs of a
  processing pattern to come back"; every arrival is progress; after `STALL_STEPS` (5 minutes) without progress it
  fails and gives back its pool. Inputs already pushed into a chest stay in the line; outputs that come later are
  stored like any import.
* **A machine that takes none of the inputs** (no matching recipe, full): the inputs come back into the pool when the
  lease ends, the issued runs are taken back, and the job does not use that machine for the pattern again.
* Cost: with no job waiting for a key an arrival is two table lookups; the index (network -> key -> job ids) is
  rebuilt only when processing work is handed out, a job closes or ends, or the graph changes. No tick of its own.

### Several patterns for one output: the pattern order

Rule: providers by **priority** descending (a number in the provider window, -1000 to 1000, default 0, kept in
blueprints and settings paste), at equal priority by unit number (the provider built first), then by slot. The
planner tries the patterns in that order and takes the first whose plan needs nothing missing, else the first (the
rule of 0.4.1, which went alphabetically by recipe name). A priority instead of only the order of building lets the
player prefer one route (an AE2 player does it by removing a pattern; here both can stay).

### Blueprints: patterns travel as data, never as items

An encoded pattern is an item, so a blueprint must not create patterns out of nothing. A blueprint keeps the
provider's priority and its patterns as data (tag `fork_me_provider = { priority, patterns = { ["slot"] = pattern }
}`). A provider built from it holds them as **pending** (`providers[unit].pending`): the scan (on build, the round
robin of 8 providers per step (issue #5: one every 2 ticks), before a job) encodes each pending pattern from a blank pattern of the provider's
network (`N.extract` of one blank), so the provider ends up exactly as if the player had encoded and inserted them.
A slot filled by hand drops its pending pattern; a click on a pending slot forgets it; mining a provider drops pending
patterns (they were never items). Old blueprints of 0.4.1 and older (tag `fork_ae2_recipe`, the furnace recipe choice)
give a pending processing pattern of that recipe. Settings paste and clones copy the priority only.

### Migration (0.4.1 -> 0.5.0)

`storage.fork_ae2.pattern_version` marks saves with encoded patterns. In a save without it,
`on_configuration_changed` (after the ME graph is rebuilt) gives every provider encoded patterns for what it provided
under the 0.4.1 rules: a crafting pattern for the recipe of each assembling machine next to it, and a processing
pattern for each furnace next to it (the provider's recipe choice when the furnace can make it, else the recipe it
runs, else the one it smelted last; research is not asked, the update has just reset the technology effects), each
pattern once, in the slots from 1. A furnace without any recipe gets nothing. The migration is the only place where
patterns appear without a blank; each provider is logged (`FORK-ME-MIGRATE: patterns: provider <unit> at <x,y> on
<surface>: crafting <recipe>, processing <recipe>`) and the total (`FORK-ME-MIGRATE: patterns: <n> encoded patterns in
<m> of <k> pattern providers`). Saved jobs: steps and leases that name a recipe get the pattern that makes it now (the
crafting pattern of the recipe, else the processing pattern migrated from that furnace recipe); a processing step
counts its finished runs as received outputs, a furnace lease becomes a processing lease. Level maintainers need
nothing: they ask for items, and the migrated patterns make them.

The old "read the machine's recipe" path and the furnace recipe choice are **removed**, not kept as a mode: a second
way to make patterns would keep the "one machine is one pattern" model alive next to the new one (two sources for the
same pattern, two rule sets for furnaces), and the migration covers every running setup.

### Tests (issue #80)

`devcheck runtime`: the furnace test (encode, tags and tooltip data, research check, crafting pattern next to a
furnace, processing pattern smelting a job, clear, load, paste, blueprint with pending patterns and an old tag, mined,
destroyed and vanished providers), the pattern switching test (three crafting patterns on one assembler with the
recipe switched and the leftovers counted, two jobs for one machine, two patterns for one output by priority, a
processing pattern on a machine with its own recipe, a level maintainer keeping blank patterns), the processing line
test (a processing pattern into a chest, the outputs back through an import bus, claimed exactly); the autocrafting,
fluid (crafting patterns of fluid recipes), CPU tier and level maintainer tests run on encoded patterns. `devcheck
migrate --from-ref v0.4.1`: providers on an assembler and on a furnace with a recipe choice, a running job and a level
maintainer of 0.4.1 work after the update. Not testable headless: the provider window, the Patterns tab, the tooltip
as the game shows it (the pull request has a click-through list).

## Items and fluids in one block (me-network issue #3)

Issue numbers in this section are me-network's. AE2 has one interface, one import bus, one export bus and one storage
bus that handle items and fluids; ME Network had a fluid version of each (`me-fluid-interface`, `me-fluid-import-bus`,
`me-fluid-export-bus`, `me-fluid-storage-bus`). They are merged into `me-network-interface` (item `me-interface`),
`me-import-bus`, `me-export-bus` and `me-storage-bus`; the fluid blocks are no longer craftable, and every placed one
becomes the unified block when a save is loaded.

### Engine behaviour this relies on (tested headless, 2.0.77)

* **No entity is a container with fluid boxes**, and a crafting machine is no substitute: an `assembling-machine`
  accepts only `input` and `output` fluid boxes ("Crafting machine fluidboxes must be input or output types"), and
  without a recipe its boxes join the pipe's segment id but exchange no fluid with it (a pipe of water next to an input
  box stayed at its amount, 1000 steam written into a box never reached the pipe on that side, 400 ticks).
* **Storage tanks on one tile:** four hidden 1x1 `storage-tank`s with an empty collision mask and one pipe connection
  each, created with the directions north, east, south and west on the container's tile, connect only to the pipe on
  their own side: four separate fluid segments (water, crude oil, steam in three of them did not mix). `insert_fluid`
  and `remove_fluid` of such a tank act on its segment; writing `fluidbox[1]` of an unconnected one and building a pipe
  next to it afterwards merges the fluid into the new segment; `find_entities_filtered` at the tile finds the container
  and the four tanks.
* **Destroying a tank loses its share** of the segment (a segment of 3000 water in a 5000 tank and a pipe kept 100
  after the tank was destroyed). A migration that replaces a tank must count before and after.

### ME Interface: container plus four side tanks

* **Compound:** the container `me-network-interface` stays the block (selection, window, item config, blueprints).
  When it is built, the script creates four hidden storage tanks `me-network-interface-side` on its tile, one per side
  (not selectable, not minable, not blueprintable, not destructible, empty collision mask, no graphics). Pipes, pumps
  and tanks connect to a side like to any tank. The tanks are found again by position (clones, saves) and destroyed
  with the container.
* **Config rows:** the 9 rows take an item (with quality) or a fluid, mixed, as in AE2 (`{ name, quality, amount }` or
  `{ type = "fluid", name, amount }`). Items work as before.
* **How a side is tied to a fluid:** every side has a setting: *import* (the default), *off*, or a fluid row. A side
  tied to a row keeps that fluid in its tank at the row's amount (at most 5000, the old fluid interface's volume);
  several sides may share one row. When a fluid is put into a row, the first import side with a pipe connected gets
  it (else the first import side); the window has a drop-down per side. A fluid row that no side uses keeps nothing.
* **How many fluids at once:** four, one per side (a fluid box holds one fluid; a 1x1 block has four sides). Up to nine
  rows can be fluids, but only those tied to a side are kept. Closest to AE2's 9 mixed slots that a 1x1 block allows
  without the fluids of two rows sharing one segment.
* **Import:** a fluid pushed into an import side is moved into the network, the whole segment (pipes up to the next
  pump), as the fluid interface did. An import side whose segment is the segment of one of the interface's export sides
  (a pipe loop around the block) is skipped, so the interface does not pump in a circle.
* **Export:** the side's tank is filled from the network up to the amount (the tank's share of its segment, like the
  fluid interface's level). Another fluid in an export side goes into the network first. A surplus is not taken back
  (pipes level out between the tank and the pipes; the fluid interface did the same).
* **Removal:** mined, the sides' fluid goes into the network first (as the fluid interface's content did); destroyed,
  it is lost like a tank's; an interface removed without an event loses its tanks at the next I/O step.
* **Saves:** item interfaces of saves made before this change get their tanks on the first load. A side that an
  existing pipe, pump or tank already points at is set to *off*, so a pipeline that ran past an interface is not drained
  into the network (logged per interface); the player switches it to import.
* **Cost:** a visit that looks at the sides reads one `fluidbox` per side (four). An interface without fluid rows
  whose sides held nothing at the last look reads them only every fourth visit (fluid waits at most four visits in the
  pipe); without any pipe on its sides only every 32nd visit, and a fluid entity built next to it (the build event)
  makes it look at the next visit. So an item-only interface costs what it cost before.
* **Visit budget:** the 8 fluid interface visits per I/O step of the old fluid interface are gone; ME Interfaces are
  visited in the 24 visits of interfaces and buses, as before for items.

### Import and export bus: one target, items and fluids

* **Target:** the bus finds the entity in front once (cached until it is gone or the bus is rotated) and keeps what it
  has: an inventory of the kind the bus uses (`fork-me-targets.lua`: crafter or furnace output for import, input for
  export, the chest of a container, logistic chest or infinity chest) and fluid boxes (the prototype has fluid boxes,
  so a chemical plant without a recipe still counts and is used once it has one). A machine with a fluid recipe gets
  both from one bus; a chest only items, a tank only fluids.
* **Filters:** up to 9, items and fluids mixed (keys: the item name, `fluid/<name>`), split into an item list and a
  fluid list when they are set. Import: no filter imports every item and every fluid of the output boxes; filters are a
  whitelist of both (only item filters: no fluid). Export: no filter exports nothing; each list goes to its own part of
  the target.
* **Cost:** a visit on a chest does the item calls of the item bus, a visit on a tank the fluid calls of the fluid bus;
  only a target with both does both. Throughput per visit stays 64 items and 1000 fluid units (issue #5: the speed
  times the ticks since the last visit).

### Storage bus: an item side and a fluid side

* **What it is decided by:** the target. A chest, logistic chest, infinity chest or cargo wagon makes it item storage
  (as the storage bus was); any other entity with a fluid box makes it the storage of that box's fluid segment (as the
  fluid storage bus was: one bus per segment, claims, splits and merges, the temperature rule, the snapshot logic). No
  target type has both. The record is one external cell (`ext = "storage-bus"`) with `side = "fluid"` and
  `handler = "fluid-storage-bus"` while it faces fluid: the engine looks the handler up by that name
  (`ext_handlers[cell.handler or cell.ext]`), so a call costs what it cost before (a dispatch function on `side` was
  measurable: every `room` of every external cell went through it). A bus whose tank is removed has no side until it
  faces something again.
* **Visits:** the bus is in the item visit list or the fluid visit list, by its side (8 visits each per I/O step, as
  before), so a base of only item or only fluid storage buses is visited exactly as often as before.
* **Settings:** mode and priority shared; up to 18 filters, items and fluids mixed: a whitelist of keys (an item
  storage bus with only fluid filters takes no item, as in AE2). Blueprint tag `fork_me_storage_bus` with `filters` as
  keys; the old tag `fork_me_fluid_storage_bus` (fluid names) is read on old ghosts.

### Saves: the old blocks become the unified ones

`scripts/fork-me-unify.lua`, from `on_configuration_changed` after the graph rebuild (and so after the hand-over of a
Gregtorio save and the R1/R2 migrations, which may still create old blocks from older saves), before the modules
rebuild their records. Idempotent: what it converts disappears.

* **Fluid interface:** the segment total of its tank is read, the tank replaced by an ME Interface (same tile, force,
  last user) with its sides; import mode becomes no config (every side imports); export mode becomes row 1 = its fluid
  and level, tied to all four sides (the old tank gave the fluid on every side). What the old tank's share was (before
  minus what the new sides' segments hold) goes into the new sides (the configured ones first), then into the network,
  so the fluid totals are equal.
* **Fluid import and export bus:** replaced in place with direction and filters (`fluid/<name>`). **Fluid storage
  bus:** replaced in place with mode, priority and filters; the old external cell is detached, the new bus visits once,
  claims its segment again.
* **Ghosts:** the old entities stay as hidden prototypes with `placeable_by` the unified item, so their ghosts survive
  loading and robots can build them; the migration turns them into ghosts of the unified block (tags converted), and the
  build event does the same for a ghost of an old blueprint and for an old entity a robot built from one.
* **Items:** the four old items stay hidden (no recipe) and place the unified block. Stacks in inventories (players:
  main, trash, cursor; containers, logistic and infinity chests, cars, cargo wagons, spidertrons) become the unified
  item, in place, with count and quality. Cells in drives: the key is renamed in the cell (bytes and types recomputed,
  partitions too) and the networks recounted; a cell in an inventory converts when it is put into a drive. Encoded
  patterns (provider slots and pattern items), level maintainers and circuit interface filters get the unified key; a
  crafting pattern of an old recipe becomes the pattern of the unified recipe. Blueprints in inventories (also in books)
  get the unified entities and tags.
* **Check:** fluid in the old blocks (and what they held of segments) before, in the new sides and the network after;
  `FORK-ME-MIGRATE: unified: <n> blocks, <m> ghosts, <k> items, <a> fluid units before, <b> after` in the log, a chat
  message on a difference.

### Technologies and the API

* **Fluids from the start (AE2):** the unified blocks move fluids as soon as they are built. A technology check would
  cost a lookup per visit and make the fluid half of a block appear later; the network can only store fluid in fluid
  cells (`me-fluid-storage` and `me-fluid-storage-256k`, unchanged otherwise) or in a tank behind a storage bus, so
  fluid storage stays where it was in the tree. `me-fluid-storage` loses the four blocks from its unlocks.
* **Removed for players:** no item in a recipe or a technology effect; their entity, item, sprites and icons stay as
  hidden prototypes (a hidden prototype must still have its files).
* **API:** `ME_NETWORK.removed` lists the removed recipes. `replace_recipe` of such a name is ignored with one log line;
  `set_technology` skips it like any missing recipe. `data-final-fixes.lua` deletes every recipe that makes a removed
  item and its unlocks in every technology: Gregtorio Continued 0.5.0 makes these recipes itself
  (`120-fork-me-network-compat.lua`) and keeps loading; the unified blocks keep the GT recipes it gives them.

### Tests (issue #3)

* `devcheck runtime`, "ME unified I/O test" (own network): the interface's four side tanks, an item row and a fluid row
  (the row takes the side with a pipe: north is the cable), the fluid out of the network equals the side's segment,
  steam piped into an import side, a side off and on again, a pipe loop from an export side to an import side
  (`loop`), the blueprint tag with rows and sides (no side tank in the blueprint), a mined interface's fluid back in the
  network with its tanks gone; an export bus on a chemical reactor with a fluid recipe (boards into the input, phenol into
  an input box), an import bus on another (the output inventory and an output box, the input box left alone; no fluid
  with only item filters); a storage bus on a chest, then on a tank (fluid side, extraction), mixed filters, then facing
  a cable; an old fluid import bus built by a script replaced, ghosts of the old blocks with old tags revived as the
  unified blocks with their settings, the old items hidden, placing the unified block, without recipe or unlock.
  The fluid, fluid cell, R3, fluid storage bus and settings copy tests run on the unified blocks.
* `devcheck migrate --from-ref v0.1.0` (new command, `tools/devcheck/migratemod`): a save of 0.1.0 with three fluid
  interfaces (import with a tank, export with pipes and fluid, export alone), the fluid import and export bus with
  filters on tanks, the fluid storage bus (read only, priority 5, a filter) on a tank, an item interface next to a pipe
  with 100 water, a level maintainer and two patterns naming old items, ghosts of the four old blocks with old tags,
  old items in a chest, a blueprint with old blocks, old items in the cells and in a cell taken out into the chest.
  After loading with the working copy: the unified blocks in place with the settings, no old entity, ghost or item,
  the converted ghosts and blueprint, the maintainer and patterns on the unified item, the item interface's side next
  to the pipe off (and the pipe not drained after 150 ticks), the cells' old items under the new key, and the fluid of
  the area (every segment once) plus the cells equal before, after the update and after the I/O steps: 10540 units.
  Two mutations were checked to fail it: no restoring of the old tank's share (1600 units short) and no "off" for a
  side that touches an existing pipe (the pipe drained).
* `devcheck all --with-gregtorio` against Gregtorio Continued 0.5.0 as released (it still makes the old recipes: they
  are removed in data-final-fixes, four log lines) and against its updated compat file; Gregtorio's own
  `migrate --from-ref v0.4.1` and `v0.3.2` (the hand-over then the unified blocks).

### Cost: measured (issue #3)

Headless 2.0.77, one network with 4 drives of 256k cells (items and fluids), `--benchmark-verbose all` over 3600
ticks (from tick 300), the median of 3 runs, `scriptUpdate` per tick; per block one visit of each through the remote
step, timed with `game.create_profiler` (ms per 100 visits, the range of 3 to 6 runs). Before: main with the fluid
blocks; after: this change.

| Scenario | Blocks | Script ms/tick before | after |
|---|---|---|---|
| items | 100 import and 100 export buses on infinity chests, 100 interfaces with a row, 50 storage buses on chests | 0.083 | 0.079 |
| fluids | 100 import and 100 export buses on tanks, 50 interfaces importing and 50 exporting through a pipe, 50 storage buses on tanks | 1.66 | 1.01 |
| mixed | both | 1.06 | 0.55 |

| Visit (ms per 100) | before | after |
|---|---|---|
| import bus on a chest | 6.3 to 6.8 | 6.0 to 6.5 |
| export bus on a chest | 3.9 to 4.1 | 3.7 to 3.9 |
| storage bus on a chest | 0.54 to 0.55 | 0.54 to 0.63 |
| interface, items only (the remote step looks at the sides every time; the I/O step every 32nd visit) | 1.6 to 1.7 | 2.2 to 2.3 |
| import bus on a tank | 120 to 131 | 126 to 134 |
| export bus on a tank | 3.1 to 3.6 | 2.9 to 3.1 |
| storage bus on a tank | 0.56 to 0.66 | 0.60 to 0.96 |
| fluid interface / interface with fluid | 85 to 95 | 70 to 75 |

* The fluid scenarios are cheaper per tick mostly because the old fluid interfaces had 8 visits per step of their own
  on top of the 24 of interfaces and buses; the per-visit cost of an interface with fluid is lower too (no `stats`
  of the network before each import).
* An import visit on a tank is 95 % one call: `can_insert_fluid`, unchanged engine code that costs about 1.1 ms with
  20 cells because every `cell_spec` copies the mod-data table (`prototypes.mod_data[...].data`, 22 µs per copy).
  Measured alone, 100 calls took 109 to 114 ms before and 112 to 118 ms after; the import visit's own code is shorter
  than before (the box prototype is read only for a box with fluid). Caching the mod-data is a separate change.

### Windows

One window per unified block, with key buttons that open the picker of issue #70 (items and fluids; they were `signal`
choosers before it): the interface (rows with item or fluid and
amount, a drop-down per side, the container's content, the sides' fluid), the bus (9 mixed filters, target, status) and
the storage bus (mode, priority, 18 mixed filters, what it shows: items or the segment's fluid and temperature). The
fluid windows are removed; the old entities are replaced on load, so none of them can be opened.

## Scheduler and performance at size (me-network issue #5)

Measured first (`devcheck.py bench`, `docs/PERFORMANCE.md`): at 5000 buses and interfaces the fixed steps of R1 cost
2.7 ms per tick on average and 40 to 100 ms in every I/O tick, a bus moved 1.2 items per second, a storage bus saw a
change after up to 11 s and a level maintainer reacted after up to 42 s. The profile put three quarters of the time
into the storage engine (Lua walking every cell per call) and every spike into steps that did all their work in one
tick. The rework follows the profile.

### The scheduler (`scripts/fork-me-schedule.lua`)

* One `on_tick` handler (control.lua) instead of the 15 and 20 tick steps: interfaces and buses, storage buses (each
  side), crafting jobs, provider rescans, level maintainers and circuit interfaces. The 60 tick terminal step stays
  (windows, drive lights, the sweep).
* **A queue per kind**: `q.due[tick] = { unit, ... }` and `rec.due` in the record. A unit is visited when the tick
  comes and its record still says that tick; a wake or a reschedule leaves the old entry behind (stale entries are
  skipped, nothing is searched). Units that do not fit into the tick's budget wait in a backlog (`q.back`, first in
  first out, each unit moved once) and come before the units of the next ticks. So no tick does more than its
  budget, and an idle unit costs nothing until it is due.
* **Intervals.** After a visit: `MIN_INTERVAL` (15 ticks for interfaces and buses, 30 for storage buses) while the
  unit moved all it was allowed to (or its storage changed), 1.5 times longer while it moves little (interfaces and
  buses: up to 60 ticks), twice as long while it found nothing, up to the idle limit: the settings (300 and 120
  ticks), but never longer than the round robin of 0.2.0 took for that many units (`Sched.idle_limit`), so a small
  network reacts at least as fast as before.
* **Wakes.** An export bus or an interface row whose key the network does not hold, and a fluid row of an interface
  side, wait in `net.wait_in[key]` and are due at the next tick when the network gets the key (insert, a storage bus
  read, a cell put in); a stocked level maintainer waits in `net.wait_below[key]` with its target and is due when the
  stock falls below it; the end of a maintainer's job wakes it. Settings (filters, config, sides, maintainer
  settings), a rotation and an entity built in front of a bus or storage bus or next to an interface wake the
  block. These tables are in `storage` (they decide when a block is visited, so every peer must have them).
* **Catch-up.** A bus moves its speed (settings: 256 items and 4000 fluid units per second, what one visit moved per
  15 ticks in 0.2.0) times the ticks since its last visit, at most 600 ticks' worth; an interface handles 8 slots per
  15 ticks since its last visit. A bus that waits in the backlog moves more when its turn comes: its throughput does
  not fall with the number of buses.
* **Budgets** (map settings, `settings.lua`, read once per load and on `on_runtime_mod_setting_changed`; counts of
  visits, never time):

| Setting | Default | What |
|---|---|---|
| `me-network-io-visits-per-tick` | 16 | interfaces, import and export buses |
| `me-network-storage-bus-visits-per-tick` | 8 | storage bus reads, per side (items, fluid) |
| `me-network-maintainer-checks-per-tick` | 4 | level maintainers (and one job start per tick) |
| `me-network-circuit-updates-per-second` | 10 | circuit interfaces (each at most once per 60 ticks) |
| `me-network-crafting-jobs-per-tick` | 1 | crafting jobs stepped (each at most once per 20 ticks) |
| `me-network-bus-items-per-second` | 256 | speed of an import or export bus, items |
| `me-network-bus-fluid-per-second` | 4000 | speed of an import or export bus, fluid |
| `me-network-idle-limit` | 300 ticks | longest wait of an idle interface or bus |
| `me-network-storage-bus-idle-limit` | 120 ticks | longest wait of an unchanged storage bus: the latency target of 2 s |

  The defaults come from the benchmark: 16 visits per tick already give every bus of the 5000 scene its full speed
  (the catch-up), more only shorten the reaction of busy blocks and cost more.

### Levers 1 and 2 of issue #38: the headroom rule, probes and parked blocks

Measured first (`docs/PERFORMANCE.md`, "Round two"): with one list per queue and a constant budget, the idle blocks
spent the budget (a third of the visits at 5000 found nothing), every block waited its turn in one line (a busy bus
was visited every 4.75 s at 5000, every 21 s at 20 000), and a wake did nothing for a block already waiting. A first
rework (a sleep list and a budget of ceil(busy / 120) visits: "every busy block within 2 s") was measured and
dropped: a uniform period for every busy block cost 70 % more script time at 5000 and moved nothing more, because
most blocks are limited by their other side, not by their visits. The rework keeps the queues in `storage` and adds:

* **The headroom rule.** When a block with work is due comes from the buffer on its other side, not from a period.
  An export bus into a machine or chest keeps what the target held of each filtered item after the visit
  (`rec.tgt`) and sees at the next visit what the target used since; an import bus what the source gathered since
  it was emptied and how much room is left (`rec.left`; the slots times the stack size); the fluid sides the same
  with the boxes' capacities (`rec.fleft`, `rec.fcap`); an interface per row (its amount and what was taken), for
  its imports (the free slots) and per side (the side tank's volume). From rate and headroom the step knows when
  the buffer would run empty or full, and the block comes back at about half of that time (`Sched.headroom`), the
  whole time while it moved all its speed allowed (then the catch-up covers the wait), between MIN_INTERVAL (15
  ticks) and MAX_CATCH_UP (600). A block whose other side had run out on arrival (a machine with an empty input or
  a full output, a row that ran empty) is served sooner (half the interval) and before the backlog next time
  (`rec.starve`, the front). A visit that cannot know the rate yet (the first fill of a row or a target, the first
  fluid into a box, the first look at a source after a wake) comes back after MIN_INTERVAL to learn it, and a rest
  that an import visit left in the source (it moved all its speed allowed) brings it back when the bus's speed
  covers that rest. A block woken out of the probe list keeps the catch-up of a sleeper of 0.3.0 (the ticks since its
  last visit, at most the idle limit); one woken out of a park, whose wait has no bound, starts with one minimum
  visit's worth and the headroom rule takes over. Blocks that got the same interval from the same tick would come due
  in lockstep for ever and the ceiling would serve them in bursts (at 5000 the backlog reached 481 and the 99th
  percentile 5 ms): a block comes back at the least loaded of four ticks around its interval (`Sched.slot`: a hash of
  its unit number picks the four, the load is the number of units already due there, so it is state and the same on
  every peer), up to 20 % sooner, and up to 20 % later when its interval is half of the headroom time (never later for
  a block that moved all its speed allowed, sits at the catch-up limit or is probed). Everything comes from what the
  visit reads anyway; the one extra read is `get_item_count` per filter of an export bus into a chest (a machine had
  it before). **The margin of a short busy list** (issue #51): the headroom rule saves visits, which pays where the
  budget is the limit and only costs machine time where it is not. So no busy block waits longer than
  `n / (floor × Sched.MARGIN)` ticks (at least MIN_INTERVAL; `n` the units of the busy list, `Sched.margin_cap`), with
  `MARGIN` 1/16: at the default floor of 16 that is `n` ticks, the busy blocks spend at most one visit per tick on
  margin against a buffer that empties faster than the visit before measured (inserter swings, a machine's crafts). In
  the scene at the maintainer's size (83 busy blocks) the cap is 83 ticks; at 5000 interfaces and buses (about 2100
  busy) it lies beyond MAX_CATCH_UP and changes nothing. A starved export fluid bus is one whose insert the target's
  room ended and that took about the most it ever took that way (`rec.froom`); before, an insert the bus's speed ended
  counted as a dry target at every visit.
* **Probes.** A block blocked on its target's side (source empty, target full, no target, an interface with nothing
  to do) is not visited but probed: one cheap engine call (`probe_work`: the item count of the source or interface,
  `can_insert` or the input count of a full target, the search for a missing target) at an interval that doubles up
  to the idle limit (the probe list `q.sl`); a change wakes the block into the front, visited in the same tick. The
  probes of a tick are at most the floor (16 interface and bus visits by default), whatever the ceiling is, and the
  sum of visits and probes of a tick stays within the floor while the busy list does not need more (a probe that wakes
  its block counts for two; when the busy list needs more, the probes keep half of the floor, they wait longer but are
  never starved), so a network of sleepers never costs more per tick than the budget of 0.3.0; the probes of a bigger
  network wait longer than the idle limit. The storage buses' "probe" is the full read of an unchanged bus and follows
  the same rule.
* **Parked blocks.** A block blocked on the network's side (its key absent, the network full, no network or
  controller, no power, no filters) is parked: not visited, woken by the network (and found by the slow fallback below if a wake is missed):
  `N.wait_for` (the key comes in, or some is taken), `N.wait_room` (a cell joins, a key type leaves),
  `N.wait_usable` (the power is back: the controller of a network with such waiters is read once a second,
  `slow_step`), the change hooks (the graph changed), its settings or a target built in front of it. The waits live
  in the network tables; a network merged into another hands them over, a split or a rebuild fires them all once,
  so no parked block loses its wake. A level maintainer that is stocked with a fixed target is parked the same way
  (`N.wait_below`, its job's end, its settings), one without a key too.
* **The fallback.** In 0.3.0 the visit every 5 s hid every missed wake; a parked block with a missed wake would stand
  still for ever, silently. So a parked block is also in the probe list, with one slow fallback visit about once in
  `Sched.PARK_FALLBACK` (3600) ticks, spread by `Sched.slot` over a sixth of that either side, from the probe budget:
  the probe function sees `rec.park` and visits the block fully. A fallback visit that finds work (a bus that moved
  something, a maintainer that left "stocked") is a missed wake: `Sched.missed` counts it per queue (`missed` in
  `sched_stats`, module-local like the other counters). It is 0 in the runtime tests and in every bench scene
  (`bench` reports a scene with a missed wake as a problem). `devcheck.py runtime` has a test for every park reason and
  every way it can end (`runtimemod/parking.lua`), and two cases that lose their wakes on purpose
  (`gregtorio-me-network.drop_waits`, `gregtorio-me-io.set_park_fallback`) to show that the fallback finds them.
* **The front.** A wake puts the unit into the busy list's front list (`q.front`), visited before the backlog; a
  unit that is already waiting there or in the busy backlog is as early as it can be.
* **The budget is what is due.** Per tick a queue visits what is due (the front, the backlog, the units due now),
  at least the floor and at most the ceiling (the settings "at least" and "at most"; defaults 16 and 32 for
  interfaces and buses, job steps 1 and 2); the probes take at most the floor of it and the busy list the rest, at
  least the floor again; when the ceiling binds, the earliest due come first and the starved blocks before them. No time, no count of a kind: the ceiling bounds the
  script time of a big base, the floor only matters while more is due than it says. The counts (`q.n`, `q.sl.n`)
  are kept by the visits, wakes and removals themselves (`Sched.at`, `Sched.wake`, `Sched.park`, `Sched.forget`),
  so every peer schedules alike; the module-local counters of the benchmark decide nothing. The crafting jobs' steps
  per tick follow the running jobs (`Sched.load_budget`); the maintainers and both storage bus sides use the same
  lists (a storage bus that did not change is read at its growing interval from the probe list).
* **Saves.** New fields in the queues (`front`, `fhead`, `sl`, `n`, `tag`), the records (`sq`, `inq`, `vis`,
  `park`, `block`, `seen`, `starve`, `tgt`, `left`, `fleft`, `fcap`) and the networks (`wait_use`, `wait_room`);
  a queue of 0.3.0 gets them at its first use (`Sched.upgrade`: every scheduled record counts as busy until its
  next visit), so a 0.3.0 save loaded without `on_configuration_changed` works on (tested by `migrate --from-ref
  v0.3.0`). The schedule after a save and a load is the one of an unbroken run: `devcheck.py runtime` saves the test
  map at tick 500 through a headless server and RCON, loads the save and compares a digest of every block's schedule
  and the queues' counts at ticks 1000 and 1400 with the unbroken run; the scheduler test parks an export bus for
  its key and for its power and checks both wakes.
  and the queues' counts at ticks 1000 and 1400 with the unbroken run.

### The storage engine

* **Lookups per network** (`lookups`, kept outside `storage`: a pure function of the network's state, built again
  after a load, the same on every peer): the priority groups of the insertion order; per group the cells
  partitioned for a key, the unpartitioned item and fluid cells in order with a pointer to the first one that may
  still take a new key (cells fill in order; an extraction that frees bytes or a type moves it back), and the
  storage buses that take inserts, by the kind they face (read only buses are left out). The holders of a key
  sorted by cell id (the uniform order of R1) or by insertion rank, and the extraction order of a key, are made
  when asked and dropped when the key's index changes (`idx_add`, `idx_del`). `insert_key`, `extract_key` and
  `room_for` use them instead of walking every cell; the order of R3 is unchanged.
* `room_for` (`can_insert`, `can_insert_fluid`) stops once it has found the room asked for and asks the holders in
  insertion order (cells before storage buses, whose room is an engine read).
* **A full storage bus** (`cell.full[key]`): a bus that took less of a key than it was offered is passed by for that
  key until its next read or until something is taken from it. Before, every insert asked every full chest that
  held the key (about 34 engine calls per insert in the 5000 scene).
* **Members without a recompute.** A member that joins one network adds only what it holds (a drive its cells, a
  storage bus already registered its external cell); one removed with at most one neighbour (an endpoint) cannot
  split the network and takes out only what it held; only a controller, a merge or a split recompute. Building a
  bus into the 5000 scene costs 0.8 ms instead of 28, removing one 1.3 ms instead of 90, and no provider is
  rescanned.
* `insert_key` keeps its state in a module table instead of closures, `extract_to` looks for item data only for
  keys of items with tags.

### The other modules

* **Import bus**: plain items (type `item`, no place result, no spoilage) are moved by count from one
  `get_contents` (one `remove` per item type); other items stack by stack as before (their damage, wear, spoilage or
  data decides; tools, ammo and repair tools are never by count, issue #76). A big chest that is empty at the front is no longer scanned slot by slot.
* **Autocrafting**: a job is stepped at most every 20 ticks as before, now one job per tick in turns (the setting),
  with its CPU's operations for each 20 ticks since its last step (up to 3 steps' worth): the cap of 96 operations
  and 8 jobs per step is gone, so more than 8 jobs no longer slow each other down. One provider rescan every 2 ticks
  (8 per 20 before). A job start rescans the providers of its plan's patterns only (`rescan_plan`), not every
  provider; the GUI's fresh plan still rescans all.
* **Circuit interfaces**: the signals of a network are one list in `storage` (`net.sigs`), made at most once per 60
  ticks while the contents change and shared by every interface of the network; it is made in one tick and written
  in the next. An interface writes only when the list changed since its last write; an unfiltered interface reuses
  one built section per list. The list is sorted by type and name (the 1000 largest amounts are chosen when there are
  more), so the combinator shows its signals by name. Writing single changed slots was tried and dropped: a
  section of 900 signals took milliseconds per slot change.
* **Drive lights** are recolored when a cell's state changes and created or destroyed only when a cell goes in or
  out. **The sweep** checks 200 members per 60 ticks from a list taken once per round instead of walking every
  member of the map to find them.

### Saves

No prototype, storage key or remote interface is renamed. New: `settings.lua`, `scripts/fork-me-schedule.lua`, the
remote function `gregtorio-me-io.schedule` (tests), fields in existing records (`due`, `iv`, `siv`, `last`, `full`,
`led_state`) and tables (`q` in `fork_me_io`, `fork_me_sbus`, `fork_me_fsbus`; `mq`, `cq` in `fork_ae2`;
`wait_in`, `wait_out`, `wait_below`, `sigs`, `cver` per network). A save without them gets them on its first tick
(every unit due within a second): a save of 0.2.0 loaded with the same version number has no
`on_configuration_changed`, and the hand-over of a Gregtorio save copies the old tables as they are. Tested with
`devcheck.py migrate --from-ref v0.2.0` (a new scenario of the migrate helper: every kind of block of 0.2.0 works
after the load, the fluid is the same) and Gregtorio's `migrate --from-ref v0.4.1`.

### What changes for the player

* Throughput: a busy bus moves 256 items per second in any network (0.2.0: 256 per second with fewer than 25
  interfaces and buses, 1.2 at 5000). Machines fed by buses run at their own speed again in big bases.
* Reaction: an idle bus or interface waits at most 5 s (setting) and at most as long as in 0.2.0 for that many
  blocks; it reacts at once to its item coming into the network, its settings, a rotation and a target built in front
  of it. A storage bus sees a change made by an inserter or a player within 2 s (setting; 0.2.0: up to 11 s at
  5000 buses, 0.27 s at 100: the old interval is the cap, so small networks are not slower). A level maintainer
  reacts within a tick of its item being taken below its amount (0.2.0: up to 42 s at 5000), and checks a circuit
  target at least every 5 s.
* A full storage bus chest that an inserter empties is used again at the bus's next read (at most the idle limit),
  not at the next insert.
* The circuit interface lists its signals by name (still the 1000 largest amounts) and updates about once a second
  at most, all interfaces of the map together at most 10 per second by default (0.2.0: 2 per 20 ticks in turns).
* Crafting jobs: more than 8 jobs at once no longer slow each other down; one job alone is stepped every 20 ticks as
  before.

### Limits

* The worst tick: at 5000 the target of no tick over 5 ms is not met on the test machine. What remains are ticks
  in which a circuit interface without a filter writes about 900 signals (about 1 ms in the engine, 1.5 ms with the
  Lua around it) on top of the ordinary work, and long steps of the Lua garbage collector (10 to 25 ms in a few
  ticks per minute, also in 0.2.0). A combinator section cannot be changed in part cheaply; fewer updates per second
  (the setting) or filters on the interfaces are the levers. See `docs/PERFORMANCE.md` for the numbers.
* `on_configuration_changed` still rebuilds the graph from the map: 0.8 s at 5000 endpoints (once per mod update).
* Removing a cable whose network splits still searches the network (a breadth first search) and recomputes both
  parts; removing an endpoint does not.
* The planner copied the stock for each alternative pattern of a key (`snapshot`). Since issue #50 (lever 11) it reads
  the stock of a key when it first asks for it, tries the alternatives on the same tables and undoes them from a journal,
  and keeps its last plans: a kept plan is given back while the network's patterns are the same table and every key the
  plan read holds the same amount, or held and holds at least all that was asked of it. See "The planner" in
  `docs/PERFORMANCE.md` (pull request 11).

### Tests

`devcheck.py bench` (`docs/PERFORMANCE.md`, the conservation check under budget pressure: every item and fluid of
the world counted before and after the window, 891 keys, no difference), the runtime test "ME scheduler test" (an
export bus waiting for its item is due at the next tick when the item comes in, an import bus is due at the next
tick when a chest is built in front of it, a full storage bus is passed by until its read and then takes items again,
300 random inserts and extracts keep every count equal to what went in minus what came out and the totals equal to
the cells plus the chest; the wake was checked to fail with the key wake removed), the storage bus tests with the
new latency bound, every other runtime test unchanged, `migrate --from-ref v0.2.0` and `v0.1.0`, Gregtorio's
`migrate --from-ref v0.4.1`.

## Upgrade cards, storage bus settings, the Cell Workbench and priorities (me-network issue #17)

Issue #17 gives the ME Storage Bus the settings of AE2's storage bus, cells their cards in an ME Cell Workbench, and a
priority to every block that has one in AE2. Decided by the maintainer: the settings come from **upgrade cards** (items
with a recipe, put into card slots), "fuzzy" means **any quality**, cells get their cards in a **Cell Workbench**.
Two pull requests: 1. the cards, the storage bus and the priorities; 2. the workbench and the cards on cells.

### AE2's numbers (from its source)

The guide gives no numbers; they are from AE2's source, branch `forge/1.20.1` (commit 1c2f96e, 2026-09-27), paths under
`src/main/java/appeng/`:

| What | AE2 | Where |
|---|---|---|
| Card slots of the storage bus | 5 | `parts/storagebus/StorageBusPart.java`, `getUpgradeSlots()` returns 5 |
| Cards the storage bus takes | Capacity 5, Fuzzy 1, Inverter 1, Overflow Destruction ("void") 1; no Equal Distribution | `init/internal/InitUpgrades.java`, `Upgrades.add(..., AEParts.STORAGE_BUS, n)` |
| Filter slots of the storage bus | 18 + 9 per Capacity Card (63 with five; the config holds 63) | `StorageBusPart.createFilter()`: `18 + getInstalledUpgrades(CAPACITY_CARD) * 9`; `ConfigInventory.configTypes(63)` |
| Card slots of a cell | item cells 4, fluid cells 3 | `items/storage/BasicStorageCell.java`, `getUpgrades()`: `forItem(is, keyType == items ? 4 : 3)` |
| Cards a cell takes | item cells: Fuzzy, Inverter, Equal Distribution, Overflow Destruction, 1 each; fluid cells: the same without Fuzzy | `InitUpgrades.java`, the `itemCells` and `fluidCells` loops |
| Equal Distribution | each type may hold `ceil((total bytes - bytes per type × n) × amount per byte / n)`, n = the number of whitelist entries (a whitelist without fuzzy), else the cell's type limit | `me/cells/BasicCellInventory.java`, constructor (`maxItemsPerType`) |
| Overflow Destruction on a cell | whatever passes the cell's filter is taken in full; a cell without a partition voids only what it already holds once it cannot take a new type | `BasicCellInventory.insert()` |
| Overflow Destruction on a bus | whatever passes the filter and the access mode is taken in full | `me/storage/MEInventoryHandler.java`, `insert()` (`voidOverflow ? amount : inserted`) |
| Filter on extract, what the network sees | settings `FILTER_ON_EXTRACT` (default yes), `STORAGE_FILTER` (default extractable only) | `StorageBusPart`, constructor and `updateTarget()`; `MEInventoryHandler.getAvailableStacks()` |
| Cell Workbench: network or power | **neither**: the block entity has no grid node | `blockentity/misc/CellWorkbenchBlockEntity.java` extends `AEBaseBlockEntity` (not `AENetworkBlockEntity`) |
| Workbench copy mode | `CLEAR_ON_REMOVE` (default) or `KEEP_ON_REMOVE`: the partition stays in the workbench and goes onto the next cell whose partition is empty | `CellWorkbenchBlockEntity.onChangeInventory()`, `menu/implementations/CellWorkbenchMenu.java` |
| Storage priority | inserting: priority groups descending, in each the storages "preferred" for the item first (a whitelist that lists it, or one that holds it), then the rest; extracting: priority ascending | `me/storage/NetworkStorage.java` `insert()` / `extract()`, `MEInventoryHandler.isPreferredStorageFor()` |
| Interface priority | only stops a lower priority interface from pulling its stock out of a higher priority interface through a storage bus | `helpers/InterfaceLogic.java`, `InterfaceInventory.extract()` |
| Pattern priority | patterns of higher priority providers first; the crafting calculation falls back to the next pattern when one cannot be crafted | `helpers/patternprovider/PatternProviderLogic.java` `getPatternPriority()` |

### The cards: items, recipes, technology

New items of this mod (`ME_NETWORK.add_item`, stack 64, subgroup `fork-me-cards`), named with `me-` so they never meet
Gregtorio's `advanced-card` and `acceleration-card`:

| Item | Recipe (standalone, vanilla items) | AE2 | Use |
|---|---|---|---|
| `me-basic-card` | 2 iron plates, 2 copper cables, 1 electronic circuit, 1 advanced circuit → 2 | gold, iron, redstone, calculation processor → 2 | component |
| `me-advanced-card` | 2 iron plates, 1 processing unit, 1 electronic circuit, 1 advanced circuit → 2 | diamond, iron, redstone, calculation processor → 2 | component |
| `me-capacity-card` | basic card + iron chest | basic card + certus quartz | 9 more filters (storage bus) |
| `me-overflow-destruction-card` | basic card + advanced circuit | basic card + calculation processor | void what does not fit (storage bus, cells) |
| `me-fuzzy-card` | advanced card + copper cable | advanced card + white wool | filters in any quality (storage bus, item cells) |
| `me-inverter-card` | advanced card + decider combinator | advanced card + redstone torch | blacklist (storage bus, cells) |
| `me-equal-distribution-card` | advanced card + advanced circuit | advanced card + calculation processor | equal room per type (cells) |

The basic card is cheap (red and green circuits), the advanced card dearer (a blue circuit), each card is one component
and one item (only items that Gregtorio Continued has as well: its game has no plastic bar, so the Fuzzy Card takes a
copper cable). Technology `me-upgrade-cards` (after ME 64k Storage, which already needs blue circuits) unlocks all seven;
the second pull request adds the ME Cell Workbench to it. Its cost is that of ME 64k Storage (`data-final-fixes.lua`
copies it, standalone 400 units of red, green and blue science) unless a mod sets the technology itself
(`ME_NETWORK.set_technology`, recorded in `ME_NETWORK.customized`): so a mod that puts the network on its own tiers
gets a researchable cards technology on its 64k tier before it knows the cards. Gregtorio gives them its own recipes in
its compat file (`ME_NETWORK.replace_recipe` per name in `ME_NETWORK.recipes`).

### Where a block keeps its cards

* **Storage bus:** 5 card slots in its record (the external cell, `rec.cards`, a list of 5 item names), in its window.
  A click with a card in hand puts one into a free slot (the hand's stack shrinks by one); a click on a card takes it
  into the hand (shift: into the inventory). A card the bus cannot take (wrong kind, the limit of its kind) is refused
  with a flying text.
* **Cells:** the cards are part of the cell's tags (`fork_me_cell.cards`, a list), like its partition and contents; they
  travel with the cell. Only the ME Cell Workbench puts them in or takes them out.

**A card is never created or lost by script.** The only ways in are a card item from a hand; the only ways out are
into a hand, an inventory, a mined buffer, the network or the ground:

| Event | The cards |
|---|---|
| bus mined (player, robot, platform) | into the mined buffer (the player's or robot's inventory), the rest spilled |
| bus destroyed, removed by a script event | spilled at the bus |
| bus vanished without an event (the sweep) | spilled at the position kept in the record |
| blueprint, copy/paste | the tag `fork_me_storage_bus.cards` names the cards the bus **wants**; a bus built from it has none and takes them from the network (one extract per missing card at its visits, like a provider's pending patterns) |
| settings paste between buses | the destination wants the source's cards: missing ones are taken from the player's inventory, then the network; cards it has beyond them go into the player's inventory (or the network, else spilled at the player) |
| clone | wants the source's cards (taken from the network); the source keeps its own |
| recipe paste (#12) | only the filters change; cards, mode, priority and the new settings stay |

A bus without the cards it wants works as if it had none (18 filters, whitelist, exact quality, no void); its window
lists what it still waits for. Cards in a cell are part of an item and follow it everywhere.

### The storage bus

Settings in its window and its blueprint tag (`fork_me_storage_bus = { mode, priority, filters, extract, cards }`):

* **Filters**: up to 63 kept (`rec.filters`), the first `18 + 9 × capacity cards` apply. A bus without a Capacity Card
  uses 18 as before; taking a card out keeps the filters beyond 18 for the next card.
* **Inverter Card**: the filters are a blacklist. **Fuzzy Card**: a filter matches its item in every quality (fluids
  have no quality). **Overflow Destruction Card**: what the network stores into this bus and does not fit into the chest
  (or the tank's segment) is destroyed, for every key the bus accepts by its filters and mode, and only while the bus
  works on a target (a bus facing nothing destroys nothing: AE2 would). Items with tags never reach a storage bus, so
  they are never destroyed. The window shows it in red with the amount destroyed so far; the card's tooltip says so.
* **Filter on extract** (AE2's "filter on extract", default on): the filters decide what the network sees and takes; off,
  they decide only what goes in, and the network sees and takes everything in the chest that it can hold.
* **Access**: the three modes stay; their names get AE2's words (read and write = bi-directional, read only = extract
  only, write only = insert only: the same meanings).
* **Partition**: "From contents" sets the filters to what the chest or tank holds now (at most the filters that
  apply), "Clear" removes them; both are plain settings, as in AE2.
* **What the network sees**: left as it is and documented. Items the network cannot hold (spoiling, with an inventory or
  data, blueprints) are not shown. AE2's switch would show them as present but not extractable; counts that cannot be
  taken would mislead every plan, level maintainer and circuit signal, which all trust `count`.

### Into the storage engine without a scan per insert (issue #5)

The engine's lookups (outside `storage`) stay the only way an insert finds its cells. The cell record (a drive cell or
a storage bus's external cell) gets derived fields, written whenever its settings or cards change (deterministic, so
every peer has them):

* `partition` stays the **whitelist** of exact keys (as before); `deny` is the **blacklist** (inverter); `fnames` the
  item names of the list (fuzzy); `void`, `eq` (Equal Distribution) and `inonly` (filter only what goes in) are flags.
  A block without cards has none of the new fields: every code path of a network without cards is the one of 0.3.0.
* **Whitelist, exact**: `parts[key]` as before. **Whitelist, fuzzy**: a new index `fparts[name]` per priority group;
  pass 1 of an insert walks `parts[key]` and then `fparts[name]` (a fuzzy cell is indexed by name only, so it is never
  visited twice). So a fuzzy filter costs one more table lookup per group, no scan.
* **Blacklist**: the cell is not "partitioned": it sits in the open lists (`cells`, `ext`) like an unpartitioned cell,
  and `cell_room` / the bus's `room` refuse a listed key (one lookup). As AE2: a blacklist is not "whitelisted" for an
  item and gets no preference for it (pass 1 skips it); a blacklist cell that already holds the key is preferred like
  any holder (pass 2).
* **Filter only what goes in**: only the snapshot changes (the bus reads everything it can hold, `count` and `extract`
  ignore the filter); the insert lookups are those of its filter.
* **Equal Distribution**: `cell_room` caps the room of a key at AE2's per-type limit (arithmetic on the cell's numbers).
* **Overflow Destruction**: `put()` stores what fits, then takes the rest of the insert when the cell voids that key
  (AE2's rules above); `room_for` returns "everything" at such a cell, so an import bus or interface asking
  `can_insert` empties its source into it. A voiding bus is never marked full.
* `ordered()` marks a network with any card as not uniform (the R1 fast path is for networks without partitions).
* **Voided items are accounted for**: an insert returns what it stored plus what it destroyed (AE2 does the same: the
  caller's items are gone). The amount is added to the block's counter (`rec.voided`, shown in its window; a cell's
  counter is not part of its tags) and to the map's total per key (`storage.fork_me_net.voided[key]`), which the
  runtime tests' conservation checks add to the network's contents. Waiting blocks are woken only by what was stored.

### Priorities

* **Drive and storage bus**: the order of R3 (`insert_key`, `extract_key`) checked against AE2's four rules. Highest
  priority first: yes. Same priority, one that already holds the item first: yes (pass 2, after the partitioned ones).
  Whitelisted cells count as holding it: yes, they even come before the holders (pass 1); AE2 treats both as one
  "preferred" pass in mount order, the mod's finer order fills partitioned storage first and is kept. Lowest priority
  first on extraction: yes. Kept: cells before buses on insertion and buses before cells on extraction at one priority.
  New: a blacklist bus or cell is not preferred (above); a fuzzy whitelist counts as whitelisted for every quality.
* **ME Interface**: a priority (-1000 to 1000, default 0) in its window, blueprint tag (`fork_me_interface.priority`),
  settings paste and clones. AE2's code uses it only against storage buses on interfaces, which the mod refuses ("Faces
  an ME block"); the issue's rule is used instead: when the network has less of a key than the interfaces want, the
  higher priority interface is filled first. Without sorting interfaces: an interface whose row stays short registers
  its shortfall per key and priority (`net.short[key][unit] = { p, missing }`, totals `net.short_p[key][p]`, in
  `storage`: they decide what moves); an interface of priority p may take only what is left after the shortfalls of
  higher priorities (a sum over the few distinct priorities of that key). A satisfied row, a changed config, priority or
  network, and a removed interface drop the entry. While no interface of the map has a priority other than 0
  (`storage.fork_me_io.prio` is empty, every old save) nothing is registered or summed: the visit is the one of 0.3.0.
* **Pattern provider**: the planner tries a key's patterns in pattern order (provider priority descending, then the
  provider built first, then the slot) and takes the first whose plan needs nothing missing, else reports the first
  one's shortfall: AE2's fall-back. A new test checks it.
* Import and export bus, level maintainer, crafting CPU: no priority, as in AE2.

### The ME Cell Workbench (pull request 2)

A 1x1 block (`me-cell-workbench`, a simple entity with its own window), not an ME member: AE2's workbench needs neither
the network nor power, so it needs no cable. Its cell is kept in a script inventory of one slot (the cell stays an item
with its tags); mined, the cell goes into the buffer, destroyed or removed by a script it is spilled. Its window: the
cell slot (click with a cell in hand, click the cell to take it), the cell's partition (items with quality, or fluids;
as the cell window has it), the cell's card slots (4 for item cells, 3 for fluid cells, AE2's limits), "From contents",
"Clear" and AE2's copy mode ("Keep the partition when the cell is taken out": it stays in the workbench and goes onto
the next cell whose partition is empty). Every change is written into the cell's tags at once. Recipe: AE2's crafting
table, 2 white wool, calculation processor, 4 iron ingots and chest become an assembling machine 1, 2 plastic bars, an
advanced circuit, 4 iron plates and an iron chest.

**The partition without a cell (issue #37).** The copy mode's kept partition (`rec.config`) was a line of text
("Kept partition: N kinds") and the slots were gone without a cell. Now the slots are always there: without a cell
they show and set `rec.config` itself. It is one list for both kinds of cell (the item keys, then the fluid keys:
`kept_list`), because the workbench cannot know which cell comes next; a cell that arrives without a partition takes
the keys of its kind (`N.clean_partition` drops the others), a cell in the workbench shows and changes its kind's keys
and leaves the other kind's alone (`remember`). A partition set by hand goes onto the next cell also without the copy
mode: setting it is the request. Without the copy mode the workbench forgets all of it when a cell leaves, as before.
The slots without a cell: at most what a cell of the kind takes (63 items, 18 fluids).

**No virtual signals in the partition (issue #69), the quality and the check (issues #82, #94).** Issue #65 gave the
slots without a cell one button, the signal chooser the buses use, and a virtual signal (or an entity, a recipe, a
quality) chosen in it was dropped, the slot empty again. Factorio cannot offer less: `elem_filters` of a
`choose-elem-button` exist for items, fluids, entities, recipes and so on, but "`signal` and `item-group` do not support
filters" (the `PrototypeFilter` page of the runtime API, 2.0.77 in the install and the 2.1.20 page; 2.1.20 adds a
`VirtualSignalPrototypeFilter` to that union, but the sentence is unchanged and `LuaGuiElement::elem_filters` still takes
no filter for `"signal"`). The picker of an `item-with-quality` button, the way out of #69, has no quality row and takes a
choice at once (#82), and a switch plus a quality drop-down plus a green check beside it (the pull request of #82) was
not what was wanted: the check belongs in the picker (#94). So the picker is the mod's own: `scripts/fork-me-picker.lua`.

`Picker.open(player, spec)` builds a frame in `player.gui.screen` (`fork_me_picker`): a search field, the groups as tabs
(`filter_group_button_tab_slightly_larger`, `item-group/<name>` sprites; only groups that list an allowed element), a
scroll pane with the group's subgroups as tables of 10 `slot_button`s (the game's order: group, subgroup, `order`, name),
and a bottom row of quality buttons (`quality/<name>`, items only, only with the quality mod) and the green check
(`item_and_count_select_confirm`). The catalog (`catalog_of`) is made from the item and fluid prototypes (not hidden, not
parameters) on first use and kept outside `storage` (derived from prototypes only, made again after a load). A search
text is matched against the prototype name like the terminal's search (lower case, spaces as dashes); the display is
capped (1500 buttons) with a line that says so. `spec` = `{ callback, data, kinds = { item, fluid }, preset = { kind,
name, quality }, title }`: the choice (`{ kind, name, quality }`) comes back through `Picker.on_confirm(callback, fn)`;
what the picker knows lives in the frame's tags, so nothing is in `storage` and a multiplayer game has nothing to agree
on (the picker is one player's GUI, like any window).

The workbench's slots are `sprite-button`s (`wb_slot`): a click opens the picker for that slot with `kinds` from
`M.workbench_kinds(data, index)` (the kind a slot has can always be chosen again; a new kind needs room: 63 items, 18
fluids without a cell, the cell's types with one; with a cell only its kind) and the slot's element and quality as the
preset; right click empties (`workbench_clear_slot`). The green check calls `M.workbench_set(entity, index, kind, name,
quality)`, which refuses anything but an item with a known quality (a quality other than normal needs the quality mod)
or a fluid, a kind the slot may not take and a slot beyond the free one, and sets the key (`name@quality` or
`fluid/name`; the list sorts itself: items, then fluids). The window is drawn anew afterwards, so a key that is in the
list already or that no cell takes leaves no stale button. The remote interface `gregtorio-me-gui` has `workbench_slots`,
`workbench_kinds`, `workbench_set`, `workbench_clear_slot`, `workbench_qualities`, `picker_groups` and `picker_entries`
for the test (the window itself cannot run headless). No change to saved state: `rec.config` is still a list of keys.

*Closing and the confirm key.* The picker is not the player's opened GUI (the window below it is), so Escape and "E"
close that window. `G.on_window_closed` (a hook in `scripts/fork-me-gui.lua`'s `on_closed`) turns that into the game's
rule that the popup goes first: the window stays (`player.opened = window`), the picker is hidden and marked with the
tick (`cancel_tick` in its tags). Escape ends there (a hidden picker of an earlier tick goes with the next close, the next
open or the 60 tick refresh). The custom input `fork-me-picker-confirm` (`prototypes/network.lua`, linked to the game's
`confirm-gui`, "E" by default, `consuming = "none"`) fires in the same tick as the close, before or after it: it confirms
the shown picker, or the one hidden in this tick (`cancel_tick == game.tick`), and marks the window (`keep_tick`) so that
the close that comes after it is ignored. Neither order needs anything in `storage`; the marks are in the GUI elements'
tags. Whether the game fires both in the same tick and in which order is only known in the game: that is the first thing
the `[Task-Ingame]` issue checks.

**The picker everywhere a window chooses an item or a fluid (issue #70).** The signal chooser (`elem_type = "signal"`) was
the filter button of the buses and the storage bus, the row button of the ME Interface, the target of the level
maintainer, the filter button of the circuit interface and the row button of the pattern editor. None of them can use a
virtual signal, and the chooser cannot be filtered (above), so each is a key button now (`G.key_button`: the item with
its quality badge, the game's tooltip and a hint, or a fluid's name) that opens the picker. A left click opens it with the
slot's key chosen (`Picker.preset_of`), a right click empties the slot; this replaces "a virtual signal clears the row" of
the interface. The choice comes back as `{ kind, name, quality }` through `Picker.on_confirm(act, fn)` (the acts
`if_item`, `bus_filter`, `sbus_filter`, `maint_target`, `circ_filter`, `pat_row`; the data is the block's unit number
and the slot's index, or the editor row's `which` and `index`) and `Picker.key_of(choice, with_quality)` makes the key: an
item with quality (`name@quality`) where the place takes one (the interface rows and the storage bus filters), else the
plain name (the bus filters, the maintainer's target, the circuit interface's filters and the pattern rows: their setters
take plain names only, as the chooser gave them before), a fluid as `fluid/<name>`. A choice that is nothing of that
(an unknown name or quality) is refused with a message and nothing changes (`M.set_interface_choice` for the interface).
The picker has the option `quality = false` for those places: no quality row, the choice has none. The helpers of the
signal chooser (`signal_of_key`, `key_of_signal_q`, `signal_chooser`, the terminal's copy) and the remote
`set_interface_signal` and `key_of_signal` are gone; the remote interface has `set_interface_choice` and `key_of_choice`.
Still a signal chooser: the circuit condition's signal of the level maintainer, which is a real circuit signal. Still a
plain `choose-elem-button` without a quality row: the partition buttons of a cell's own window (drive window, the
terminal's Cells tab), which are item-with-quality or fluid pickers and take no virtual signal.

The cards are a list in the tags (no gaps: tags keep none; a card taken out closes up the list). The cell window
(drive window, terminal's Cells tab) keeps its partition buttons, so nothing a player uses goes away; it
shows the cell's cards but cannot change them. AE2's stricter way (partitions only in the workbench) would make every
partition a trip to the workbench for no gain: the cards are the only thing that needs the workbench, because they are
items that have to go somewhere.

A cell with an Inverter Card takes everything except its partition; with a Fuzzy Card its partition matches every
quality; with an Equal Distribution Card no key takes more than AE2's share; with an Overflow Destruction Card it voids
by AE2's rule. All of it through the fields above.

### The tooltip of a cell (issue #64)

`cell_stack` (`scripts/fork-me-network.lua`) is the one place that writes a cell into a stack definition: the workbench
(`write`, `pack_cards`), `take_cell` (the drive window, the terminal's Cells tab), `unload_drive` (a mined or destroyed
drive), `spill` (a drive that vanished), `fluid_cells` (fluid in new cells) and the alias rewrite of `apply_aliases` (its
tags only) go through it (a blueprint holds no cell: a drive's blueprint tags are priority and partitions), and nothing else writes a cell's `custom_description`
(`storable` and `stack_def` carry the description of a cell kept in the network as part of its key, unchanged). It
used to describe a cell by what it holds, and an empty one by its partition's size or its card count, so a cell that
held anything hid its partition and its cards, and a blacklist read like a whitelist. Now `cell_description` builds one
concatenation, in the same order for every cell that is not fresh: the contents line (the old `cell-holds` and
`fluid-cell-holds` keys with the same six parameters, or for an empty cell the new `cell-tip-empty` /
`cell-tip-empty-fluid` with its bytes and types), the partition (`cell-tip-partition`, `cell-tip-partition-more`), the
mode (`cell-mode-whitelist`, or `cell-mode-blacklist`), the cards (`cell-tip-cards`) and the sentences of Fuzzy, Equal
Distribution and Overflow Destruction. The mode sentences are the windows': `N.cell_mode_text(kind, flags)` is the one
source, `cell_mode_caption` of the windows joins them with a space (the keys lost their leading space for it), and the
tooltip puts them on lines of their own.

What the Factorio API allows (checked in the runtime test's probes on 2.0.77): a localised string takes at most 20
parameters, 21 raises "Too many parameters for localised string: 21 > 20 (limit)"; the longest tooltip is 13 parts. A
plain string parameter longer than 200 characters is accepted at runtime (the 200 characters of the API page are for the
settings and prototype stages; a 12 icon line with quality is about 400). The icons are rich text in plain string
parameters, as the contents list was already. Number parameters come back as strings when the description is read.
How the lines break, how big the icons are and how the red line looks cannot be seen headless: the `[Task-Ingame]`
issue of the pull request has the maintainer look.

The old keys `cell-partitioned` and `cell-with-cards` stay in the locale: cells written before still carry them, and a
description is translated when it is shown. The tags are untouched, so nothing is migrated; a cell in a chest keeps its
old tooltip until a drive or the workbench writes it again.

**Marking a partitioned cell without hovering (evaluated, nothing added).** `LuaItemStack.label` and `label_color` exist
for an item with tags (the runtime probe set both), but `label` is a plain string (no locale: an item would show by its
internal name; rich text icons would replace the cell's name in the tooltip), `label_color` only colours a label, and
both can only be set on a stack object: the `ItemStackDefinition` that `cell_stack` returns and every drive path
inserts has no such field, and the key a cell gets in the network (`storable`) does not see it. So only the workbench
could mark a cell, and a cell would lose its mark on its first trip through a drive. The windows already frame a
partitioned cell in yellow; the tooltip is the place for the rest.

### Saves

No prototype, storage key or remote interface is renamed. New: the card items, `me-cell-workbench`, the technology, the
tag fields `cards` (cell tags, storage bus tag) and `extract` (storage bus), `priority` (interface tag), the record fields
above, `storage.fork_me_net.voided`, `storage.fork_me_io.prio`, `net.short`, `net.short_p`, `storage.fork_me_workbench`
(workbenches). Buses, cells and interfaces of older saves have none of them: whitelist, exact quality, filter both ways,
no void, 18 filters, priority 0, as before. `migrate --from-ref v0.2.0` checks it.

### Tests

New runtime tests (`runtimemod/cards.lua`): every card and setting on a chest and a tank (capacity, inverter, fuzzy,
filter only what goes in, overflow destruction with the conservation check, from contents, clear), cards given back on
mining and spilled on destruction, never duplicated by paste, blueprint or clone (counted), the insert and extract order
with mixed priorities, partitions, whitelists and blacklists, two interfaces of different priority competing for a short
item and a short fluid, the pattern fall-back; with pull request 2 the workbench (cards on item and fluid cells, its
buttons, the copy mode, mined and destroyed with a cell) and every card on a cell.

## Crafting CPUs as multiblocks (me-network issue #6)

Issue #6 makes the crafting CPU an AE2 multiblock. **Decided by the maintainer** (AE2 guide, "Crafting CPU
multiblock"): a CPU is a **solid rectangle** of crafting blocks with no gaps and **at least one crafting storage**, no
core block; a group that is not a rectangle forms no CPU and shows a status. Blocks: crafting storage 1k to 256k
(required), crafting unit (filler), crafting co-processing unit (speed), crafting monitor (shows the job). **One job per
CPU**, any number of CPUs per network; touching crafting blocks are one group. A CPU is in the network when one of its
blocks touches a cable or another ME block. The plan preview shows the bytes of a job and the CPUs that can take it; a
job that fits no free CPU is not started (a level maintainer waits). The CPU window shows the size, used and total
crafting storage, the co-processors and the job. What follows is the part "to design".

### AE2's numbers (from its source)

Branch `forge/1.20.1` (commit 1c2f96e, 2026-09-27), paths under `src/main/java/appeng/`:

| What | AE2 | Where |
|---|---|---|
| Storage of a block | 1k, 4k, 16k, 64k, 256k = 1024 × k bytes; unit, co-processor and monitor 0 | `block/crafting/CraftingUnitType.java` |
| Co-processors | each one is one more pattern push per crafting tick: `coprocessors + 1` operations | `crafting/execution/CraftingCpuLogic.java`, `tickCraftingLogic()` |
| Bytes of a request | every node of the crafting tree adds its requested amount × 8 / amount per byte (8 items or 8 buckets per byte in a cell): **1 byte per item, 1 byte per bucket**, "crafting storage is 8 times bigger than normal storage, this is intentional" | `crafting/inv/ICraftingSimulationState.java` `addStackBytes()`, `crafting/CraftingTreeNode.java` `request()` |
| Bytes of a craft | 1 byte per craft (process) | `crafting/CraftingTreeProcess.java` `request()`: `inv.addBytes(times)` |
| Bytes of the tree | 8 bytes per node of the tree | `crafting/CraftingCalculation.java`: `addBytes(tree.getNodeCount() * 8)` |

### The bytes a job needs

AE2's rule, counted per step of our plan instead of per node of AE2's tree (the planner merges every request of a
pattern into one step):

    bytes = the amount ordered
          + for every step: runs × (1 + the item ingredients of one run) + the fluid ingredients of all runs / 10
          + 8 × (steps + resources taken from storage)

Items cost 1 byte each, fluids 1 byte per 10 units (rounded up per step and fluid; the ordered amount too). Every
ingredient counts, whether it comes from storage, from a step or from the surplus of a step, as in AE2. For a tree
without shared intermediates the total is exactly AE2's (each AE2 node is a step or a resource from storage); a shared
intermediate costs its 8 bytes once instead of once per use.

Why 10 units per byte and not AE2's ratio: AE2 counts 1 byte per bucket (1000 mB), the same 8 : 1 to its cells as for
items. This mod's fluid cells hold 8 units per byte like items, so AE2's ratio would be 1 byte per unit; but Factorio
recipes use about ten times more fluid units than items (vanilla: 20 petroleum gas per 2 plastic bars, 5 sulfuric acid
per processing unit; Gregtorio: 144 units of molten metal per ingot), so a byte per unit would make a fluid job ten times
the size of the item job next to it. One number, `fluid_units_per_byte` in the mod-data `fork-me-autocraft`.

Two worked examples (vanilla recipes, plates in storage):

* **100 electronic circuits** (1 iron plate + 3 copper cables; 1 copper plate → 2 cables). Steps: copper cable 150
  runs, electronic circuit 100 runs; from storage: iron plates, copper plates.
  100 (ordered) + 150 × (1 + 1) + 100 × (1 + 1 + 3) + 8 × (2 + 2) = 100 + 300 + 500 + 32 = **932 bytes**: fits the
  smallest CPU (one 1k crafting storage, 1024 bytes).
* **50 processing units** (20 electronic circuits, 2 advanced circuits, 5 sulfuric acid; an advanced circuit is 2
  plastic bars, 2 electronic circuits, 4 copper cables); plastic, acid and plates from storage. Steps: copper cable
  2000 runs (3600 + 400 cables), electronic circuit 1200 runs (1000 + 200), advanced circuit 100 runs, processing unit
  50 runs. 50 + 2000 × 2 + 1200 × 5 + 100 × (1 + 2 + 2 + 4) + 50 × (1 + 20 + 2) + 250 / 10 + 8 × (4 + 4)
  = 50 + 4000 + 6000 + 900 + 1150 + 25 + 64 = **12 189 bytes**: a 16k crafting storage (or four 4k).

The planner returns `plan.bytes`; a job keeps `job.bytes`. Jobs of older saves have none: it is computed from their
steps the first time it is needed (the resources taken from storage are then unknown and not counted).

### The blocks

All are 1x1 blocks (`simple-entity-with-force`, no power connection of their own, like the ME Pattern Provider),
members of the ME network (graph kind `crafting`): they draw their power through the ME Controller, like a drive.
Without power, or without a working network, a CPU is not usable (its job waits: "No ME network").

| Block | Storage | Effect | Power | Recipe (standalone) | Technology |
|---|---|---|---|---|---|
| ME Crafting Unit (`me-crafting-unit`) | 0 | filler | 4 kW | 4 iron plates, 2 advanced circuits, 2 fluix cables, 1 electronic circuit | `me-autocrafting` |
| ME 1k Crafting Storage (`me-1k-crafting-storage`) | 1 024 bytes | | 4 kW | crafting unit + 1k storage component | `me-autocrafting` |
| ME 4k Crafting Storage (`me-4k-crafting-storage`) | 4 096 | | 8 kW | crafting unit + 4k component | `me-autocrafting` |
| ME 16k Crafting Storage (`me-16k-crafting-storage`) | 16 384 | | 16 kW | crafting unit + 16k component | `me-co-processing` |
| ME 64k Crafting Storage (`me-64k-crafting-storage`) | 65 536 | | 32 kW | crafting unit + 64k component | `me-co-processing` |
| ME 256k Crafting Storage (`me-256k-crafting-storage`) | 262 144 | | 64 kW | crafting unit + 256k component | `me-quantum-crafting` |
| ME Crafting Co-Processing Unit (`me-crafting-co-processing-unit`) | 0 | +1x speed | 32 kW | crafting unit + 1 processing unit | `me-co-processing` |
| ME Crafting Monitor (`me-crafting-monitor`) | 0 | shows the job | 4 kW | crafting unit + 1 small lamp + 1 electronic circuit | `me-autocrafting` |

The recipes follow AE2 (crafting unit: iron, calculation and logic processors, fluix cable; a crafting storage is a
crafting unit and the storage component of the same size; the co-processing unit a crafting unit and an engineering
processor; the monitor a crafting unit and a storage monitor), with vanilla items that Gregtorio Continued has too. The
first CPU (a 1k crafting storage: a crafting unit and a 1k component) is cheap when `me-autocrafting` is researched and
takes the jobs of the example above. The numbers reach the runtime through the mod-data `fork-me-autocraft`
(`blocks[name] = { bytes, coprocessors, monitor, power }`), the network reads the power per block from it.

**What a co-processor does:** a job hands work to its pattern machines in steps (one job per tick, each job at most
every 20 ticks, the setting "crafting jobs per tick" unchanged). A step makes 6 machine hand-overs or collections times
the speed of its CPU; the speed is **1 + the co-processors** (AE2: `coprocessors + 1` pushes per tick). A CPU with 3
co-processors is as fast as the old ME Quantum Crafting CPU (4x, 24 hand-overs per step, about 72 per second). At most
**16 co-processors count** (17x, 102 hand-overs per step): more may be built but add nothing. AE2 has no limit; here
one step of one job runs in one tick, and the cap keeps that step at about the cost of four Quantum CPU jobs.

The legacy CPU tiers' technologies keep their names and get the new blocks: `me-co-processing` unlocks the
co-processing unit and the 16k and 64k crafting storage, `me-quantum-crafting` the 256k crafting storage. A mod that set
these technologies itself (Gregtorio Continued replaces their recipe lists with `ME_NETWORK.set_technology`) would leave
the new recipes unlocked by nothing, so `data-final-fixes.lua` adds every crafting block recipe that no technology
unlocks to its technology above: Gregtorio games get the blocks on Gregtorio's tiers until its compat file gives them GT
recipes.

### Finding the rectangle: kept up to date on build and removal

The pattern is the graph's (`add_node` / `remove_node_graph`): nothing is scanned while nothing changes, a build merges,
a removal looks at one group only. State in `storage.fork_ae2` (created lazily: older saves have none):

* `cblocks[unit] = { entity, x, y, surface, group }`: every crafting block, by its tile;
* `cgrid["surface:x:y"] = unit`: the tile index, so neighbours are four table lookups, no `find_entities`;
* `groups[id] = { blocks = { unit = true }, n, x1, y1, x2, y2, bytes, coprocessors, monitors = { unit = true },
  status, job, anchor }`: one group of touching blocks.

**Built** (also by robots, from a blueprint, cloned): the block looks up its four neighbour tiles. No neighbour: a new
group. One or more groups: they are merged into the largest (the blocks of the smaller ones are moved, O(smaller)); the
bounding box, the bytes, the co-processors and the monitors are added. **Removed** (mined, destroyed, or found vanished
by the network's sweep, which calls a hook of this module): the block leaves its group and its tile; with one neighbour
in the group the group cannot split (the box is computed again if the block was on its edge, O(group)); with more, one
breadth first search over the group's blocks through `cgrid` finds the parts, each becomes a group (O(group)). Since all
blocks are 1x1 and cannot overlap, a group is a **solid rectangle exactly when `n = (x2 - x1 + 1) × (y2 - y1 + 1)`**.
Status: `ok` (a rectangle with storage), `not-rectangle`, `no-storage` (a rectangle of units, co-processors and
monitors only). `on_configuration_changed` builds the groups once from the map (next to the graph's own rebuild).

What the player sees: a block of a CPU shows its lit picture, a block of a group that is no CPU its dark one
(`graphics_variation`, set only when a group's status changes); the window of any block names the status ("Not a
crafting CPU: 7 blocks do not fill their 3 x 3 area" / "Not a crafting CPU: it has no crafting storage"); the plan
preview lists only groups that are CPUs. A monitor draws the job's item and amount on its face (two render objects per
monitor, changed when its CPU starts or ends a job, never per tick).

### A running job when its CPU changes

A job's items and fluids are not in the CPU: they are in the job's pool (`storage.fork_ae2.jobs[id].pool`), and the
machines it leased keep crafting. So nothing has to be cancelled to avoid a loss, and the rule is the one that the old
CPUs have since issue #38 ("a job on a removed CPU pauses and goes on on the next free one"):

* **A block of its CPU is removed** (or the group stops being a CPU): the job **pauses** with everything it holds
  (status "Waiting for a free CPU"); the next CPU assignment (at most 20 ticks later) gives it a free CPU of its network
  with enough bytes, **the rest of its own CPU included** if that is still a CPU and big enough. If no CPU has room it
  waits ("Waiting for a CPU with at least N bytes"); **Cancel** gives everything back as always. AE2 cancels the job
  and returns its items; here the items never left the network's books, and pausing keeps the work done in machines.
* **A block is added**: the job stays if the group is still a CPU with enough bytes (a co-processor added to a running
  CPU makes the job faster at once); otherwise it pauses as above.
* **Two CPUs merged** by a block between them: the group keeps the job with the lower id if it fits; the other job
  pauses and takes another CPU.

### Plan preview, CPU window, monitor (pull request 2)

`M.cpu_list(net, bytes)` gives the CPUs in the order a job takes them, each with `fits` and `free`; the terminal's
`craft_preview` adds `bytes`, `cpu_list` and the reasons `cpu-too-small` / `no-free-cpu` (the Craft button is off),
and a line lists the CPUs that can take the job now, the busy ones that are big enough and the ones too small. The
window of a crafting block (`crafting-cpu`, kind `crafting`) reads `M.group_info`. A monitor's two render objects
(`storage.fork_ae2.monitors[unit]`) are made by a group hook when its CPU gets a job and destroyed when the job ends
or the group changes; they show the ordered amount, which does not change while the job runs, so nothing is redrawn
per tick.

### The old CPUs (migration)

The three single-entity CPUs of Gregtorio issue #38 (`me-crafting-cpu`: 1 job; `me-co-processing-cpu`: 2 jobs, 2x;
`me-quantum-crafting-cpu`: 4 jobs, 4x) stay as **legacy blocks**: same prototypes, same storage records
(`storage.fork_ae2.cpus`, `job.cpu`), same job slots and speed, **no byte limit**, so no save loses or stops a running
job. They can no longer be crafted: their names are in `ME_NETWORK.removed` (so `replace_recipe` ignores them and
`data-final-fixes.lua` deletes every recipe that makes them, Gregtorio's too); their items stay usable (a player who
holds one can still place it), their descriptions say "legacy". No prototype and no storage key is renamed.

Why not replace each by a multiblock: a 2x2 entity cannot become a rectangle of 1x1 blocks in its place without
moving or destroying what stands around it, and a Co-Processing CPU (two jobs) would need two separate CPUs that do not
touch, so the conversion would have to place new blocks where the player built other things. Keeping them is free:
the job code already knows two kinds of CPUs. When the mod is updated (`on_configuration_changed`) a job stays on its
legacy CPU; before, every job was queued again and took the fastest free slot (`migrate --from-ref v0.2.0` checks that
the three jobs of the old save end on the CPUs they started on).

Assignment order of a waiting job: the multiblock CPUs of its network that are free and have enough bytes, **the
smallest storage first** (big CPUs stay free for big jobs), then the most co-processors, then the group made first;
then the legacy CPUs with a free slot, fastest first (as before). Starting a job (the Craft button, a level maintainer)
needs such a CPU **now**: otherwise the start is refused with "needs N bytes; the biggest CPU of this network has M"
or "every CPU that can take it is busy", and a level maintainer waits and tries again. (Before, a job could be queued
behind busy legacy CPUs; jobs that are queued in a save keep waiting and start when a slot is free.)

### Graphics

`tools/gen_ae2_sprites.py --crafting-cpu <GT5-Unofficial>` draws the eight blocks in AE2's layout (a casing frame
around a face: the storage blocks with a coloured chip per size, the co-processor with a blue core, the monitor with a
screen) from GT5-Unofficial's casings and Pillow shapes, each in a dark (no CPU) and a lit (CPU) variant, and their
icons and the three technology icons stay. **Not from AE2's own crafting block textures:** they are licensed CC BY-NC-SA
3.0 (AE2's README: "Textures and Models"), which is not compatible with this mod's GPLv3 and with the mod portal
(non-commercial, share-alike under another license); `README.md` says so for every graphic of this mod.

### Saves

New: the eight block prototypes and items, the record fields `job.bytes`, `job.group`, the tables `cblocks`, `cgrid`,
`groups`, `next_group` in `storage.fork_ae2` (created lazily; `migrate --from-ref v0.2.0` loads without
`on_configuration_changed`). The hand-over list of Gregtorio saves is unchanged (`fork_ae2` is handed over whole; a
Gregtorio save has no groups).

### Tests

Runtime (`runtimemod/cpus.lua`): the smallest CPU (one 1k crafting storage) runs a job and refuses a too big one; a
rectangle with every block kind (storage, unit, co-processors, monitor: bytes, speed, monitor objects); a group that is
not a rectangle and one without storage (status, not offered); two CPUs running two jobs at once; a job too big for
every CPU (refused, the maintainer waits); a block removed during a job (pauses, goes on on the rest or another CPU,
nothing lost); a blueprint and a clone of a CPU (form a CPU); the legacy CPUs (slots, speed, no byte limit). Migration:
`migrate --from-ref v0.2.0` with running jobs on all three legacy CPUs, which must finish after the load. Bench: the
scene's CPUs are multiblocks (the legacy Quantum CPU with `--from-ref` of an older version); script time unchanged.

## Windows with the player's inventory (me-network issue #28)

The ME windows were free frames in `player.gui.screen` without the player's inventory: cards, cells and patterns went
in only by a click with the item in hand. **Decision (the maintainer's comment "Maintainer decision after the in-game
test of pull request #30" on #28, approved in the game from a mock): every ME window is one screen frame with two
panes, the player's inventory drawn by the mod on the left, the ME content with the block's slots on the right.** The
game cannot show its inventory without its own second panel, and a mod cannot put the real inventory element into its
own window.

The first attempt (pull request #30) made the window a frame in `player.gui.relative` anchored to `script_inventory_gui`
with the block's script inventory as the opened GUI: it worked, but showed three parts side by side (the game's
inventory, the game's column of slots, the ME frame), and a script inventory of zero slots still leaves a stub of that
column. From it stay: the cards of a storage bus and the cell and cards of the workbench are real items in an inventory
of the block, the migration of the old records into it, `give_back` and their tests. The anchored frame and the opened
script inventory are gone.

### The window (`scripts/fork-me-gui.lua`)

* `G.open_window(player, name, caption, tags, pane)`: a frame `fork_me_window` in `player.gui.screen`, the player's
  `opened` GUI (E and Escape close it, as before #30), one title bar (caption, drag handle, close button), then a
  horizontal flow `fork_me_body` with the inventory pane and then the content frame (`inside_shallow_frame_with_padding`).
  Every window has the pane (pull request B; `pane = false` would leave it out, no window does). `def.hint` is a line
  under the pane's caption (the storing windows: "shift + click stores in the network").
* The pane: a frame `inside_shallow_frame_with_padding` with the label "Character", a scroll pane (maximal height 600)
  and a table of 10 columns (`filter_slot_table`), one `slot_button` per slot of the main inventory, named `s<slot>`,
  with the item's sprite, count (`number`), quality (`quality`, the bottom left mark) and the game's item tooltip
  (`elem_tooltip` item-with-quality). The empty slot the cursor's stack came from (`player.hand_location`) shows the
  game's hand (`utility/hand`). The inventory's filters (set by the player in the game's window) are not shown.
  **The tooltip of a slot (issue #75).** `elem_tooltip` is the tooltip of the item's *prototype*, so it knew nothing of
  the stack: a cell or an encoded pattern showed the prototype text in the pane and in the block slots (the workbench's
  cell and card slots, a storage bus's card slots), where the game's inventory shows the stack's `custom_description`.
  The API says an `elem_tooltip` "will be displayed above `tooltip`" (the `add` parameter of `LuaGuiElement`), and the
  terminal's entries already use both. So `G.render_slot` also sets `tooltip = G.stack_tooltip(stack, hint)`: the stack's
  description, a line break and the slot's own hint (nil: none); the item's name, stack size and prototype lines stay
  where they were, above. The description is read only for an item of type `item-with-tags` (the only type with a
  `custom_description`; looked up once per name in `tagged_names`, prototype data, never saved), and only when the slot is
  written. The slot's signature gets the stack's `item_number` for those items (`G.stack_ident`; in the pane inline): every
  write of a cell or pattern is a `set_stack`, which gives the stack a new number (the workbench relies on it for the cell it
  keeps track of), so a cell whose partition changed in the workbench's slot is noticed without reading its description,
  and an unchanged slot is not written again. A stack without a description gets what it got before. What is **not**
  covered: the label of a blueprint or other item with a label, durability and ammo, health, a spoil timer, "Item has
  tags": the prototype tooltip has none of them and nothing here reads them. Cost, per refresh of 80 slots (60 plain
  stacks, 10 cells, 10 patterns; the signature work alone, headless, 160 000 slot visits per run): 2.0 µs a slot before,
  2.4 µs after (0.16 ms against 0.19 ms a refresh); an inventory without such items pays one table lookup a slot. Reading a
  description costs about 1 µs, once per changed slot. 2.1's GUI element `inventory` would show the game's own tooltips.
  **The grids of stored items (issue #79).** An item with tags kept in the network has the key `name@quality#<json>`, the
  json being `{ tags, description }` as `N.storable` made it; `G.slot` builds its buttons from a key, so it had only the
  prototype's tooltip and stored cells and patterns looked alike in the terminal's storage tab (and the cell window's
  contents). `G.key_description(key)` reads the description from the key's json (`helpers.json_to_table`, cached per key
  for this load, never saved, emptied at 2000 entries) and `G.slot` puts it below the item's own tooltip, above the extra
  tooltip a caller gives. The description is a function of the key (a stack written anew is another key), so a button never
  shows an old one: the terminal's grid already makes a button again when its key changes, and its refresh of unchanged
  entries calls nothing new. Cost: a plain key one `find` at the button's creation (0.4 µs), a key with tags one parse
  (26 µs for a cell's 283 characters) once per key per load.
* `G.window(name, { open, refresh, entities, shift, click })`: `shift(entity, stack, inventory)` says where a
  shift-clicked stack of the player's inventory goes (it moves what the block takes and returns the reason when it takes
  nothing); `click(entity, slot, cursor, inventory, shift)` is a click on a slot of the block: with an item in the cursor
  it puts it in, **refused before anything moves** when it does not belong there (the reason is shown as flying text and
  the item stays in the cursor); with an empty cursor it takes the item into the cursor, with shift into the inventory.
* The pane's clicks (`G.inventory_click`, the same for every window): left click picks the stack up (the slot gets the
  hand), or puts the cursor's stack down, merges it with the same item and quality or swaps it; right click takes half
  the stack, or puts one item of the cursor's stack down; shift + click sends the stack to the block (`def.shift`);
  control + click calls `def.control` (every stack of that item; the windows without one treat it as shift + click).
  A refusal's message comes from `def.message(reason)` (the network module's reasons: `G.net_message`, status-* or
  error-* of [fork-me-net]) or `fork-me-gui.refused-<reason>`.
* The block's slots are slot buttons too (`G.stack_button`, `G.render_slot`), with the action `block_slot`
  (`G.block_click` calls `def.click`).
* Following the real inventory: `on_player_main_inventory_changed` and `on_player_cursor_stack_changed` call
  `G.on_inventory_changed`; a player without a pane costs one table lookup. `G.update_pane` compares each slot's
  signature (name and count, or the hand) with the one shown (`storage.fork_me_gui_pane[player] = { size, sigs, quals }`:
  in storage, so every client sets the same buttons) and sets only the buttons that changed; it reads the slots through
  cached `LuaItemStack`s (a read-only cache outside storage: indexing a slot makes a new object each time). The quality
  is read only for a slot that changed, since reading it doubles the cost; the 60 tick refresh compares the qualities of
  every filled slot as well (only with the quality mod), for a change of quality alone. A new window or a changed
  inventory size builds the table and sets every button. Nothing runs per tick.
* Cost, measured headless (2.0.77, a script inventory of 400 slots with 380 filled, per pass over every slot): indexing
  the slots 0.19 ms, name and count 0.61 ms, name and count through the cached stacks 0.38 ms, with the quality as well
  1.39 ms. One inventory change of a player with a window open therefore costs about 0.4 ms at 400 slots (0.1 ms at
  the character's 80) plus a few button writes for the slots that changed; a click in the pane causes two events (cursor
  and inventory) and one update of its own. The refresh's quality pass costs 1.4 ms per second and window at 400 slots.
* Closing: E, Escape, the close button, another GUI (`on_gui_closed` with the frame); the tool click rule of #13;
  `close_all` on a mod update (it also destroys an anchored frame of #30 and drops `storage.fork_me_gui_open`, #30's
  record, which a save made with #30 may hold).

### Per window: the slots and the shift + click

| Window | The block's slots (where the items live) | Shift + click of a stack of the player's inventory |
|---|---|---|
| ME Storage Bus (PR A) | the 5 card slots: the bus's inventory `rec.inv` (#30) | its cards into the empty card slots, one each, within the kind's limit |
| ME Cell Workbench (PR A) | the cell slot and the card slots: the workbench's inventory (slot 1 the cell, 2 to 5 its cards, #30) | a cell into the empty cell slot; a card into a card slot the cell takes |
| ME Drive (PR B) | the 10 cell slots: the drive's records (`N.drive_click`, unchanged: a cell is refused unless it is one, and becomes an item with its contents when it leaves) | a cell into the first free slot (`N.insert_cell`; not a cell, or a full drive: refused) |
| Storage cell (PR B) | none (partition buttons) | a cell into a free slot of the drive the window belongs to |
| ME Pattern Provider (PR B) | the 9 pattern slots (`autocraft.provider_click`, unchanged) | an encoded pattern into the first free slot (`autocraft.insert_pattern`) |
| ME Terminal (PR B) | none: its own "Your inventory" grid and its "store all of it" are gone, the storage grid is taller | the stack is stored in the network (`store_stack`); control + click: every stack of that item (`store_inventory_item`) |
| Interface, import and export bus, controller, level maintainer, circuit interface, crafting block and the legacy CPUs (PR B) | none | the stack is stored in the block's network (`M.store_shift`: `N.insert_stack`, which needs a working network); control + click every stack of that item (`M.store_all`) |

Since every move into and out of a block is a click the mod handles, nothing goes in that has to come back: the slot
rules are checked before the move (`card_fits`, the cell rules), and the sync of #30 is only the backstop for the
migration and the removal. A cell that leaves the workbench by a click gets its cards into its tags before it moves.

**ME Storage Bus.** `sbus.card_click` (a click on a card slot) and `sbus.shift_in`; the slots are the cards, `rec.cards`
follows them (#30). The window shows the 5 slots in its content.

**ME Cell Workbench.** `bench.cell_click` (slot 1: a cell goes in, a cell there is swapped into the cursor with its
cards, anything else is refused), `bench.card_click` (slots 2 to 5, addressed by slot: a card the cell takes, refused
without a cell, beyond a limit or without a free slot) and `bench.shift_in`. While a cell lies in the workbench its
cards are the items of slots 2 to 5 (#30); the window shows the cell slot and the card slots (4, a fluid cell 3).

### Saves and multiplayer

No prototype, storage key or remote interface is renamed. New storage key: `storage.fork_me_gui_pane` (the pane's slot
signatures per player). The migration of #30 stays (a storage bus of an older save gets its card names as items in its
inventory, a workbench's one-slot inventory is replaced and its cell's tag cards become items; lazy, in `inv_of`).
Two players at one block see the same slots: the block's slots are refreshed after every click, the other player's
window at the refresh (60 ticks); each player's pane is their own inventory.

### Tests

Pull request B: the window test ("ME partitions and windows") checks that every registered window (remote `windows`) has
the pane and a shift + click target, then clicks through `inventory_click`: the terminal stores a stack (shift), every
stack of an item (control) and refuses a blueprint; an interface, import bus, export bus, level maintainer, circuit
interface, legacy CPU and the controller store a stack (fresh blocks on the terminal's network), an interface without
a working network refuses; control + click at an interface stores every stack; the drive takes a cell into a free slot,
refuses iron plates and, full, refuses a cell; the cell window of that drive takes a cell; the provider takes an encoded
pattern and refuses iron plates. The crafting CPU test stores a stack through a crafting block's window.

The harness has no player, so every rule runs through the GUI module's functions (remote `inventory_click` and
`block_click` of `gregtorio-me-gui`) with a script inventory standing in for the player's main inventory and a slot of
another one for the cursor: shift + click of a card (a stack spread over the empty slots, the inverter limit), of a
wrong item (refused, it stays), of a cell into the workbench (its tag card becomes a slot's item), of a second cell
(refused), of a card without a cell (refused); a click on a block slot with a wrong item (refused, the cursor keeps it),
with a card (one goes in), on a full bus (refused), with an empty cursor (into the cursor), with shift (into the
inventory), the workbench's cell into the cursor with its cards and back, a swap of two cells; the pane's own clicks
(half a stack, one item put down, merge, pick up, put down, swap); no card made or lost. The slot tests, the migration
test and the generic window test of #30 stay. The drawing of the pane (`open_window`, `update_pane`, the hand, the
events) was run against a mock of the GUI elements outside the game; how it looks only the game shows (`[Task-Ingame]`).

## Open points

* Patterns (issue #80, left open on purpose; the data model keeps room for them): upgrade cards on providers
  (e.g. a blocking mode: push into a chest only when it is empty), substitutions and fuzzy patterns (rows would get a flag; the identity and the planner's ingredient lookup are the
  places to change), a 36 slot provider tier (`SLOTS` is one constant; it needs a second prototype and window layout),
  clearing a pattern by a click in the inventory (not possible for a mod), outputs that only appear behind a storage
  bus.
* A level maintainer with several resources; cards on the import and export bus and the ME Interface (capacity,
  speed, fuzzy, inverter, redstone, crafting card: the follow-up of issue #17; the card items and `N.card_rules()` are
  there, the buses need slots, limits from AE2's `InitUpgrades` and the speed setting replaced per bus).
* Issue #3: an ME Interface keeps four fluids at most (one per side) and takes no surplus back from an export side; a
  fluid that reaches an unconnected side only by script waits up to 32 visits; old blueprints in the blueprint
  library keep the old entities (they build the unified blocks); running crafting jobs that make an old fluid block
  keep their old step (their patterns are converted).
* Fluid wagons on the fluid storage bus. Issue #17 left: the card icons and the workbench sprite are placeholders;
  a storage bus with an Overflow Destruction Card facing nothing destroys nothing (AE2 would).
* Terminal search by localised name (a script cannot read localised names).
* The windows are checked by hand only (see "Tests (R3)"), also the provider window and the Patterns tab.
* Old fluid drive items stored inside ME cells are converted only when placed (see "Migration of fluids").

## A refilled chest behind a storage bus (issue #67)

An extraction through a storage bus works on the real inventory and corrects the snapshot (`extract_key`), and told the
bus nothing, so a refill of the chest showed at the bus's next regular read: at the idle limit (120 ticks with 64 buses or
more, 30 ticks of a busy bus, with the probes' share on top) plus the window's 60 tick step, about 1.5 s on average for an
infinity chest, 3 s at worst.

**The bus.** `extract_key` calls the handler's `emptied(cell, key)` (new, optional) when an extraction took the last of a
key out of an external cell; the item side of the storage bus answers with `M.reread(rec)`: its visit moves to REREAD = 5
ticks later (`Sched.at` on the busy list, the same visit as any other). Not when the bus is due within those ticks anyway
or waits on the busy list (`due < 0`), not on the fluid side, not while one is pending. The state is the record's (saved):
`rereading`, `rr`, and what the re-read replaced (`rr_back` its due tick, `rr_probe` whether it was in the probe list,
`rr_vis` its last visit), so a re-read that finds nothing puts the regular visit back and the counters keep the regular
rhythm; a re-read is counted in the service quality only when it found something.

**The bound.** A first attempt re-read after every key that ran out and failed `bench --check origin/main --sizes
base,5000`: the storage bus latency went from 1.27 to 1.70 s at the maintainer's size and from 1.72 to 1.95 s at 5000,
because the benchmark's chests are drained for a minute and never refilled, so every item type that ran out cost reads that
the other buses' probes then waited for. So `rec.rr`: a re-read that found nothing sets it to false, and no re-read is
scheduled while it is false; a regular read that finds something new (or a re-read that does) clears it. A chest that stays
empty costs one extra read, a chest that refills is read again 5 ticks after every time it runs out.

**The window.** The terminal's step is 60 ticks, so a take schedules one more refresh of the taker's window 10 ticks
later (`follow_up` in `fork-me-terminal.lua`, `storage.fork_me_follow[player_index] = tick`, handled in the on_tick of
`control.lua` with one `next()` while nothing is pending): at most one per player in that time, the same tick on every peer.

**Not done, and why.** A partial take leaves the correct rest in the snapshot (`real - got`), so the terminal never shows
items that are gone; only an increase from outside waits for the regular read, as for every change an inserter makes. The
fluid side: a segment is read as a whole and a fluid does not run out in the way a stack does; the pump that refills a tank
is seen at its regular read (the fluid bus's idle limit), and the same bound would apply if it is wanted later.

**Test** (`runtimemod/refill.lua`, `ME storage bus refill test`): 70 more storage buses on chests make the item side's idle limit
the real 120 ticks; bus A faces an infinity chest holding one stack of iron plates; after 450 ticks (the bus idle at its limit)
the network takes the stack three times, and the next stack must be in the network at the next check (the test runs every 10
ticks) each time: on main 120, 30 and 30 ticks, with the change 10, 10, 10 (a re-read after 5). Bus B faces a chest with
three item types and nothing refills it: after the first type is taken and the re-read found nothing, taking the second
schedules no re-read (a mutation without the bound fails it); a plate put into the chest and seen by a regular read arms
it again (the next take schedules one 5 ticks later; main schedules none).

## An ME Export Bus into a lab (issue #86)

`T.INPUT["lab"] = defines.inventory.lab_input` (`scripts/fork-me-targets.lua`): the export bus's target resolution
(`target_of`) takes any entity whose type has an input inventory in that table, so a lab is a target; `T.OUTPUT` has no lab
(a lab has no output inventory), so an import bus facing one has no target. `T.SLOTTED` (assembling machine, furnace, lab)
names the types whose input has a slot of its own for what it uses: `export_items` tops each filtered item up to one
stack of it (`stack_of`), and the probe of a bus that found its target full (`probe_work`) wakes the bus when a slot has
room again. A lab's slot per pack is the stack of that pack (200), which is what a machine's slot is too.

What the lab's input does (runtime test): `insert` of a pack the lab uses fills its slot up to the stack, `insert` or
`can_insert` of anything else (an iron plate) is refused, which `N.extract_to` handles without churn (it inserts into the
target first and takes from the network only what went in). So a filter the lab cannot take moves nothing and costs the
network nothing; for the probe a lab uses `can_insert` as well, since a refused filter would otherwise look like work for ever
(its slot count is always below a stack). The vanilla lab (Space Age) uses all twelve science packs (`lab_inputs`), so there
is no pack it refuses; the test's case for one is skipped unless a mod adds a tool the lab does not use.

The packs come out of the network as whole items (since #76 a stack of full packs is stored and taken by stack, not by
count); a pack the lab has partly used lives in its slot and is never taken back (there is no import side). Nothing about
the bus's cap (256 items per second) changes: a lab uses a pack every research unit, the bus is visited again when its slot
runs low (the headroom rule of #38).

**Test** (`runtimemod/lab.lua`, `ME export bus into a lab test`): lab A with two pack filters holds a stack of the one and what
the network had of the other, the network keeps the rest; lab C (a bus with a plate and a pack as filters) takes the pack
and nothing of the plate; 150 packs taken out of lab A are topped up again; no pack made or lost; an import bus facing a lab has
the status "no-target". On main it fails (every lab stays empty). No bench: the change is one table lookup in place of two
type comparisons per visit.

## Damaged items on the by-count paths (issue #84)

An item that places an entity (a mined wall, belt or chest) carries that entity's health in its stack, below 1 when it was
damaged. `N.storable` refuses such a stack (`is_used`: `health < 1`), but two paths move items by count and never look at the
stack: the storage bus (`get_contents` / `get_item_count` count a damaged stack like a whole one, `inv.remove` hands it out as a
new one) and the surplus of an interface row (`inv.remove` by count, then `N.insert` by key). On 2.0.77 a damaged stack does
not merge with whole ones, but a count and a removal by count do not tell them apart (the runtime test confirms it on main:
8 wooden chests came out of a chest with 5 damaged and 3 whole ones, all whole, and the damaged stack was gone; an interface
took 3 iron chests as surplus out of a damaged stack of 5). #76 fixed this for tools, ammo and repair packs (`worn`).

**Design.** The cost decides: a stack walk per storage bus visit would read every slot of every chest that holds a belt or a
wall (a warehouse of 800 slots), so the walk is paid by the rare operations only.

* `N.can_be_damaged(proto)`: the item has a `place_result` (or is a rail planner). Decided per prototype, cached
  (`placeable` in the storage bus), never saved.
* **Taking out** (`extract` of the storage bus handler): such an item goes through `N.remove_whole`, the whole stacks only
  (the walk stops when the count is served, so a take costs the slots before the stacks it uses). When that serves less
  than asked while the key is still in the chest, a damaged stack is there: the bus remembers it (`rec.dmg[key]`, the
  record's state, saved). `N.extract_to` already takes back from the target what the storage did not give, so nothing is
  duplicated.
* **Showing**: a bus with `rec.dmg` counts a flagged key by `N.count_whole`, and its visit reads the whole counts
  (`N.whole_counts`, now also for placeable items) for the flagged keys only; the flag is dropped when the whole count
  equals the total (the damaged stack is gone). So the terminal may show a damaged stack until the first take finds it,
  then shows only what can be handed out; a bus without a flagged key pays nothing at its visits.
* **Interface row surplus**: `N.remove_whole` for such an item (as for `worn`): the damaged stack stays in the interface.
  A damaged stack still counts toward its row's amount (`get_item_count`), so a row whose only stack is damaged does not ask
  the network for whole ones: the maintainer swaps the stack.
* Not touched: the import bus (`by_count` excludes every item with a `place_result`, so a damaged stack is refused stack by
  stack, #85); the other ways in (`insert_stack`, the terminal's store) ask `storable`.

**Test** (`runtimemod/damaged.lua`, `damaged items on the by-count paths test`): a chest behind a storage bus with a damaged stack
of 5 wooden chests and a whole stack of 3: taking the 8 the terminal shows hands out the 3 whole ones, the damaged stack stays,
the bus then shows 0; the damaged stack replaced by 4 whole ones, the bus shows 4 and hands them out; an interface row of 2 with
a damaged stack of 5 and a whole stack of 3 iron chests: the 3 whole ones are the surplus, the damaged stack stays. On main every
one of these fails.

## An import bus with only refused stacks (issue #85)

`import_items` took the answer "nothing stored" of `N.insert_partial` for a full network: a bus that found only stacks
the network refuses itself (a used science pack, a damaged item, a blueprint) set `info.netfull` and registered
`N.wait_for` for the item's key, so it was **parked** ("net-full") for room that does not change a refusal, and woke only at
the slow fallback visit of a parked block (`Sched.PARK_FALLBACK`, 3600 ticks): whole items that came into its chest meanwhile
waited up to a minute. `N.insert_partial` now returns its reason to `import_items`, and `N.refuses_stack(why)` (the
`cannot-store*` reasons: this one stack) leaves it out: no `netfull`, no wait, and the stack's count is taken out of `held`
(it stays in the source and is no rest to come back for, which would have made the bus come back at the speed of its cap
for a stack it can never take). A bus that finds only refused stacks moves nothing and gets the status "empty": it is
probed at its growing interval up to the idle limit and woken by the probe when the source's contents change, like any
empty import bus, so whole items that arrive are taken within the idle limit (300 ticks by default). A real full network
(`no-storage`) and a network without power or controller (`no-power`, `no-network`) are still `netfull`.

**Test** (`runtimemod/refused.lua`, `ME import bus with refused stacks test`): the chest of bus A holds a used science pack and
a blueprint only; after the bus has looked (status "empty", not parked, no wait for the key) iron plates are put into the
chest and are in the network within the idle limit; the chest of bus B holds plates and the same refused stacks: the plates
go in at once, the refused stacks stay, and the bus is not visited again for them. On main both buses are parked ("net-full", the test fails
on that); the plates reach the network only when something wakes the parked bus (here the slow step did after 120 ticks, at the
latest the fallback visit after 3600).

## Damaged items are stored (issue #104)

#76 refused every stack with a `health` below 1: the network keeps counts per key, and a count says nothing about health,
so a damaged item would have come out whole. The maintainer's in-game test of #84 found it in the way ("Damaged or partly
used items cannot be stored"). A damaged stack is now stored like an item with tags: under a key of its own,
`name@quality#<json>`, the json holding `{ health, description }` (`N.storable` builds it). All items of a stack share one
health (measured: a stack has one `health`, merging two damaged stacks in an inventory averages it, weighted by the
counts, which is the game's own rule and not the network's), so a count of such a key is exact and nothing has to be
decomposed.

* **In:** `N.storable` returns the key and the data for a stack of an item that can be damaged (`N.can_be_damaged`:
  `place_result`, rail planners) with `health < 1`; every path that calls it (the terminal's store, the pane's shift + click
  and control + click, `insert_stack`, the import bus's and the interface's stack path through `insert_partial`) stores it.
  The health is read once per plain stack, as before. Any other damaged item (the stack of an item that is no building) and
  every partly used tool, ammunition or repair pack stays refused (`cannot-store-damaged`, now worded "Partly used items
  (tools, ammunition, repair packs) cannot be stored").
* **Out:** `stack_def` sets `health` from the key's data (and a description only for an item with tags, the one type that
  has one); `extract_to` builds the stack, so a damaged key comes out at the health it went in with, in the cursor, an
  inventory or a chest the export path fills. One inventory merges two damaged stacks it receives (averaging the health):
  that is the game's rule.
* **The terminal:** the key is an entry of its own with a description, "Damaged: 50% health" (`G.key_description` reads it
  from the key's json, #79).
* **Cells:** the key and its data go into the cell like a tags key (`cell.data`, the cell's tags); it is one type of the cell.
* **Not reached:** the storage bus ignores keys with data (`item_of`), so a damaged item is never put into a chest, where it
  would come out whole; export buses and interfaces work by plain name, so they never hand one out; autocrafting counts plain
  keys only. A damaged stack in a chest behind a storage bus is not shown (#84); the import bus takes it into the network.
* **Partly used tools, ammo and repair packs stay refused:** their wear is that of the top item of the stack only, so two
  stacks of the same wear stored under one key would come out as one used item and the rest whole (a magazine with 3 rounds
  twice would give 13 rounds back for 6). Storing each used item under a key of its own would be exact, at a type of a
  cell per item; not done without a reason.

**Test** (`runtimemod/damaged.lua`): `insert_stack` of a damaged stack of 5 wooden chests (health 0.5), a whole stack of 4 and a
damaged stack of 2 (health 0.25) stores 5, 4 and 2: two keys with data (5 and 2), the plain count rises by 4 only, the chest
behind the storage bus is unchanged, each damaged key comes out at its health, the terminal's description reads "50"; the
import bus takes a damaged stack of 7 stone walls (health 0.4) as a key of 7 and the whole 3 as 3. The #76 test lost its cases
of damaged chests (a refusal no more).
