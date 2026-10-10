# ME Network: the data-stage API

`prototypes/api.lua` defines the global table `ME_NETWORK`. A mod that depends on `me-network` (so it loads after
it) can use it in its `data.lua`, `data-updates.lua` or `data-final-fixes.lua` to give the ME blocks other recipes and
technologies. Gregtorio Continued does this in its `prototypes/120-fork-me-network-compat.lua` (GT recipes, its
tiers and science packs).

Prototype names never change, so a mod can also edit `data.raw` directly; the API covers what is easy to get wrong:
technologies that still unlock a removed recipe, and the molecular assembler, which is a copy of another machine.

## What this mod owns

- `ME_NETWORK.recipes`: the names of its recipes, `ME_NETWORK.technologies`: the names of its technologies (in the
  order they were made). `replace_recipe` adds to the list, `remove_recipe` takes from it.
- Items: `fluix-cable` (places the ME cable), `me-controller`, `me-interface`, `me-terminal`, `me-chest`, `me-drive`,
  `basic-storage-housing`, `me-1k`...`me-256k-storage-component`, `me-1k`...`me-256k-storage-cell`,
  `me-1k`...`me-256k-fluid-storage-cell`, `me-underground-cable`, `me-import-bus`, `me-export-bus`,
  `me-storage-bus`, `me-pattern-provider`, `me-blank-pattern`, `me-encoded-pattern` (no recipe),
  `me-molecular-assembler`, `me-crafting-cpu`, `me-co-processing-cpu`, `me-quantum-crafting-cpu`,
  `me-level-maintainer`, `me-circuit-interface`; since 0.3.0 (issue #17) the upgrade cards `me-basic-card`,
  `me-advanced-card`, `me-capacity-card`, `me-overflow-destruction-card`, `me-fuzzy-card`, `me-pattern-capacity-card` (issue #156), `me-sticky-card` (issue #193), `me-inverter-card`,
  `me-equal-distribution-card` (each with a recipe of the same name), since issue #110 the module
  `me-acceleration-card` (category `me-acceleration`; `ME_NETWORK.ACCELERATION`) and `me-cell-workbench`; since issues #205 to #209 the wireless items `me-wireless-access-point`, `me-wireless-booster`, `me-wireless-terminal` (item-with-tags), `me-charger`, `me-wireless-module` (equipment of type battery-equipment, grid category `armor`), technology `me-wireless`; since 0.3.0 (issue #6)
  the crafting blocks of the multiblock crafting CPUs `me-crafting-unit`, `me-1k`...`me-256k-crafting-storage`,
  `me-crafting-co-processing-unit`, `me-crafting-monitor` (each with a recipe of the same name; subgroup
  `fork-me-crafting-cpu`); the legacy CPUs `me-crafting-cpu`, `me-co-processing-cpu` and `me-quantum-crafting-cpu`
  are gone since 0.5.1 (issue #145; still in `ME_NETWORK.removed`, their items migrate to `me-1k-crafting-storage`); hidden: the old drive items of Gregtorio saves (`me-drive-1k` ... and `me-fluid-drive-1k` ...: they place an ME Drive
  with their cells). The old fluid blocks of issue #3 (`me-fluid-interface`, `me-fluid-import-bus`, `me-fluid-export-bus`,
  `me-fluid-storage-bus`) have no prototype since 0.5.1 (issue #146); a stray item becomes the unified one.
- `ME_NETWORK.removed`: { old item -> the item that replaced it } for those four and the three legacy CPUs (0.3.0;
  since 0.5.1 they map to `me-1k-crafting-storage` and have no prototype any more).
  Their recipes are gone: see
  `replace_recipe` and "Recipes of removed items" below.
- Technologies: `me-network`, `me-storage-64k`, `me-storage-256k`, `me-autocrafting`, `me-automation`,
  `me-co-processing`, `me-quantum-crafting`, `me-fluid-storage`, `me-fluid-storage-256k`, `me-upgrade-cards` (0.3.0:
  after `me-storage-64k`, whose cost it takes in `data-final-fixes.lua` unless a mod sets it with `set_technology`).
  Since 0.3.0 (issue #6) `me-autocrafting` unlocks the crafting unit, the 1k and 4k crafting storage and the monitor,
  `me-co-processing` the co-processing unit and the 16k and 64k crafting storage, `me-quantum-crafting` the 256k
  crafting storage (`ME_NETWORK.crafting_block_tech`: recipe -> technology). A crafting block recipe that no
  technology unlocks after every mod's changes (a mod replaced the recipe list with `set_technology`) gets its unlock
  on that technology again in `data-final-fixes.lua`; give the recipe to a technology of your own to move it.
- `ME_NETWORK.customized`: { technology name -> true } for every technology changed with `set_technology` (0.3.0).
- Item subgroups: `fork-me-network`, `fork-me-drives`, `fork-me-cells`, `fork-me-fluid-cells`, `fork-me-fluid-drives`,
  `fork-me-cards` (0.3.0), `fork-me-crafting-cpu` (0.3.0).

## Functions

### `ME_NETWORK.replace_recipe(def)`

Replaces the recipe `def.name` by `def`, a full recipe prototype (`type = "recipe"` is set). The technologies that
unlock that name keep unlocking it. A name in `ME_NETWORK.removed` (an item this mod no longer makes) is ignored with
one log line.

```lua
ME_NETWORK.replace_recipe{
	name = "me-controller", category = "advanced-crafting", energy_required = 10, enabled = false,
	ingredients = { { type = "item", name = "processing-unit", amount = 4 }, { type = "item", name = "fluix-cable", amount = 8 } },
	results = { { type = "item", name = "me-controller", amount = 1 } },
}
```

### `ME_NETWORK.remove_recipe(name)`

Deletes a recipe and every `unlock-recipe` effect of it, in every technology. Use it when your mod makes an item with
recipes of other names (Gregtorio removes `me-1k-storage-component` and has `me-1k-storage-component-lv` and `-nand`).

### `ME_NETWORK.set_technology(name, def)`

Replaces fields of a technology of any mod: `def.prerequisites` (a list), `def.unit` (a unit table), `def.recipes`
(the recipes it unlocks, in order; other effects stay). Recipes that do not exist are skipped and logged. A recipe it
unlocks is set to `enabled = false`.

```lua
ME_NETWORK.set_technology("me-network", {
	prerequisites = { "my-mod-logistics" },
	unit = { count = 200, time = 30, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 } } },
	recipes = { "fluix-cable", "me-controller", "me-drive", "me-terminal" },
})
```

### `ME_NETWORK.make_molecular_assembler(def)`

Rebuilds the ME Molecular Assembler as a copy of another assembling machine: `def.base` (the machine's name),
`def.crafting_categories`, `def.crafting_speed`, `def.energy_usage`. The copy gets the assembler's name, icon,
graphics and mining result and no fluid boxes. **Its size is not the base's** (issue #131): the block is one tile
(collision box -0.35 .. 0.35, selection box -0.5 .. 0.5, pictures of 32 px) whatever size `def.base` has, and what the
copy would inherit that is laid out for a bigger machine is set for one tile (the recipe icon of the alt mode, the icons of
the five module slots, the alert icon, the circuit connector if the base has one, the corpse and the dying explosion); a
frozen patch of the base's graphics is not kept (the assembler runs item recipes; autocrafting checks the machine's
fluid boxes before it sets a recipe). Standalone it is a copy of `assembling-machine-2` with its item categories,
speed 2.5, 375 kW.

### Helpers of this mod

`add_item`, `add_recipe`, `add_technology` and `unit` are what this mod's own prototype files use (items with the
same fields as Gregtorio's upstream `create_item`, so saves and other mods see the same items). Other mods do not
need them.

### Recipes of removed items

`data-final-fixes.lua` deletes every recipe that makes an item of `ME_NETWORK.removed` (whichever mod made it) and its
unlock in every technology, with one log line each (since 0.3.0 also the recipes Gregtorio Continued gives the three
legacy CPUs). Gregtorio Continued 0.5.0 makes the recipes of the four old fluid
blocks itself (not through the API) and keeps loading: they are removed there, and the unified blocks keep the
recipes Gregtorio gives them. A mod should drop those recipes and unlocks from its own files.

## The drive view (graphics mods)

The ME Drive (ten bays) and the ME Chest (one) show a light for each cell, and can show the cell itself. Where, is the
mod-data `fork-me-network`'s `drive_view` (since issue #264), which a graphics mod that replaces the drive's or the
chest's picture can set in its `data.lua` or `data-updates.lua` (since issue #267 not later: me-network's
`data-final-fixes.lua` makes the pictures of the hidden entities `me-drive-light`, `me-drive-cell`, `me-chest-light`
and `me-chest-cell` from it, one variation per bay and state, drawn on the block's position above its picture and sorted
with it against the character):

```lua
local view = data.raw["mod-data"]["fork-me-network"].data.drive_view
view.drive = {
	bays = { { x = 9, y = 6 }, { x = 30, y = 6 }, ... },   -- one per slot (1 and 2 the top row, left and right), top left
	light = { x = 9, y = 3, w = 3, h = 3 },               -- the light, from a bay's top left
	cells = { item = "my-cell-sprite", fluid = "my-fluid-cell-sprite", w = 15, h = 6 },   -- optional
}
view.chest = { bays = { { x = 18, y = 30 } }, light = { ... }, cells = { ... } }
```

All numbers are px of the 64 px picture of the drive and the chest (drawn at scale 0.5: 64 px a tile), from its top
left. `cells` names two sprite prototypes (defined by then), one for item cells and one for fluid cells, drawn `w` x
`h` px at the bay (under the light) for every slot that holds a cell; without `cells` only the light is drawn. me-network's own view is
the geometry of its own pictures and has no `cells`. The light's colour is me-network's (green, orange above 75 %,
red when full; the chest's dark without power).

## The controller view (graphics mods)

The ME Controller's picture is the same whatever its state. A graphics mod can show the state, as AE2 does, with the
mod-data `fork-me-network`'s `controller_view` (since issue #278), set in its `data.lua` or `data-updates.lua`:

```lua
local view = data.raw["mod-data"]["fork-me-network"].data.controller_view
view.off = { ... }        -- no power (also a conflict without power)
view.on = { filename = "__my-mod__/controller-lit.png", width = 128, height = 128, scale = 0.5, frame_count = 12,
	line_length = 1, animation_speed = 1 / 9 }   -- its network works
view.conflict = { ... }   -- a second controller in its network, with power
```

Each state is an `Animation` (a single frame is one too), drawn over the controller's picture at its position (the
controller is 2 x 2 tiles: the shift is from its centre), above it and sorted with it against a character. Each is
optional: a state without one shows the controller's picture alone. me-network's `data-final-fixes.lua` makes the
hidden entity `me-controller-light` from them (one animation variation per state); the script sets every controller's
part to its state once a second. With an empty view (me-network's own) there is no such entity.

## The bus view (graphics mods)

The ME Import, Export and Storage Bus show where they work by a marker: the plate on the side they face and their
arrows. Since issue #282 it is a layer of its own over each direction's picture (`me-<bus>-<direction>-marker.png`,
the picture's own pixels), so a graphics mod can replace the picture (the first layer) and keep the marker. Where the
marker is drawn is the mod-data `fork-me-network`'s `bus_view`, the square of the 64 px picture that is the bus's face,
in px from its top left; me-network's own is `{ x = 0, y = 0, size = 58 }`. A mod whose bus has another face sets it in
its `data.lua` or `data-updates.lua`:

```lua
local view = data.raw["mod-data"]["fork-me-network"].data.bus_view
view.x, view.y, view.size = 3, 3, 48
```

me-network's `data-final-fixes.lua` scales and moves the marker layer of every bus and direction to that square.

## Runtime

The remote interfaces are `gregtorio-me-network` (storage: `insert`, `extract`, `count`, `contents`,
`fluid_contents`, the drive, `connect`, ...), `gregtorio-me-io`, `gregtorio-me-storagebus`,
`gregtorio-me-fluid-storagebus`, `gregtorio-me-autocraft`, `gregtorio-me-circuit`, `gregtorio-me-fluids`,
`gregtorio-me-terminal`, `gregtorio-me-gui`, `gregtorio-me-migrate` (names kept from Gregtorio Continued). The tests
in `tools/devcheck/runtimemod/control.lua` use most of their functions.

Since 0.2.0 (issue #3): `gregtorio-me-io` takes config rows with fluids (`{ type = "fluid", name, amount }`) and the
sides of an interface (`set_interface_config(entity, config, sides)`, `set_interface_key`, `set_interface_side`,
`get_interface_sides`, `interface_tanks`), bus filters as keys (item name or `fluid/<name>`); `gregtorio-me-fluid-storagebus`
works on the storage bus (its fluid side); `gregtorio-me-fluids` keeps the fluid calls (`count`, `totals`, `capacity`,
`insert`, `remove`), its interface functions are gone with the ME Fluid Interface.

Since 0.3.0 (issue #17): `gregtorio-me-storagebus` has `card_click(bus, slot, cursor, inventory, shift)`,
`want_cards(bus, names, player_index)`, `from_contents`, `clear`; its settings take `extract = false` (filter only what
goes in) and report `cards`; `info` reports `cards`, `slots`, `want`, `extract`, `inverted`, `fuzzy`, `void`, `voided`.
`gregtorio-me-io` has `get_interface_priority` / `set_interface_priority`; `get_interface` reports `priority` and
`short` (what the interface lacks while priorities are in use). `gregtorio-me-network.voided()` returns what Overflow
Destruction Cards destroyed on the map, per key. `gregtorio-me-workbench` is the ME Cell Workbench's (`info`,
`cell_click`, `card_click`, `set_partition_slot`, `from_contents`, `clear`, `set_keep`); the drive's cell data reports
`cards`, `inverted`, `fuzzy`, `equal`, `void`, `voided`.

Since 0.3.0 (issue #6): `gregtorio-me-autocraft` `plan` reports `bytes`; `start` returns `id, why, missing, bytes,
biggest` with the new reasons `cpu-too-small` and `no-free-cpu` (a job needs a free CPU when it starts); `job` and
`jobs` report `bytes` and `group`; `group_info(block)` is the multiblock CPU of a crafting block (`status`, `blocks`,
`width`, `height`, `bytes`, `used`, `coprocessors`, `speed`, `monitors`, `job`). `cpu_list(entity, bytes)` lists the CPUs of the network in the
order a job takes them (`fits`, `free`); `monitor(block)` is what a crafting monitor shows. `gregtorio-me-terminal`
`craft_preview` reports `bytes`, `biggest` and `cpu_list`; `gregtorio-me-gui` has `crafting_cpu_data(block)`.

Since 0.5.1 (issue #159, fluids keep their temperature): a fluid's storage key is `fluid/<name>` at its default
temperature (as before) and `fluid/<name>@<degrees>` at any other (whole degrees, clamped to the fluid's default and
max temperature). The fluid calls take an optional temperature after their arguments (nil: the default temperature,
so every call of before does what it did): `gregtorio-me-network` `insert_fluid(entity, name, amount, temperature)`,
`extract_fluid`, `fluid_count`, `can_insert_fluid`, and the new `fluid_key_contents(entity)` (`{ key -> amount }`, one
entry per temperature) and `fluid_key(name, temperature)` (the storage key); `fluid_contents` adds the temperatures
of a fluid up. `gregtorio-me-fluids` `count(entity, fluid, temperature)` (`temperature = "any"`: every temperature),
`insert` and `remove` with a temperature, and `key_totals(entity)`; `totals` adds the temperatures up. Filter keys
(bus, storage bus, circuit interface filters, cell partitions, processing pattern inputs) may name a temperature,
`fluid/<name>@<degrees>`; without one they take every temperature. Interface config rows take `temperature`
(`{ type = "fluid", name, amount, temperature }`), `get_interface` reports each side's `temperature`, `bus_info`
reports `tstat` (`{ fluid, the temperatures the network has, what the target takes }`) with the status `temperature`.
