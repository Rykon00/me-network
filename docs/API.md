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
  `me-level-maintainer`, `me-circuit-interface`; hidden: the old drive items of Gregtorio saves, and since 0.2.0
  (issue #3: the ME Interface and the buses handle fluids) `me-fluid-interface`, `me-fluid-import-bus`,
  `me-fluid-export-bus`, `me-fluid-storage-bus` (no recipe; they place the unified block).
- `ME_NETWORK.removed`: { old item -> the item that replaced it } for those four. Their recipes are gone: see
  `replace_recipe` and "Recipes of removed items" below.
- Technologies: `me-network`, `me-storage-64k`, `me-storage-256k`, `me-autocrafting`, `me-automation`,
  `me-co-processing`, `me-quantum-crafting`, `me-fluid-storage`, `me-fluid-storage-256k`.
- Item subgroups: `fork-me-network`, `fork-me-drives`, `fork-me-cells`, `fork-me-fluid-cells`, `fork-me-fluid-drives`.

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
graphics and mining result and no fluid boxes (the assembler runs item recipes; autocrafting checks the machine's
fluid boxes before it sets a recipe). Standalone it is a copy of `assembling-machine-2` with its item categories,
speed 2.5, 375 kW.

### Helpers of this mod

`add_item`, `add_recipe`, `add_technology` and `unit` are what this mod's own prototype files use (items with the
same fields as Gregtorio's upstream `create_item`, so saves and other mods see the same items). Other mods do not
need them.

### Recipes of removed items

`data-final-fixes.lua` deletes every recipe that makes an item of `ME_NETWORK.removed` (whichever mod made it) and its
unlock in every technology, with one log line each. Gregtorio Continued 0.5.0 makes the recipes of the four old fluid
blocks itself (not through the API) and keeps loading: they are removed there, and the unified blocks keep the
recipes Gregtorio gives them. A mod should drop those recipes and unlocks from its own files.

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
