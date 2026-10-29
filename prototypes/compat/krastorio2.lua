--------------------------------------------------------------------------------
--- KRASTORIO 2 (issue #598): the ME network on Krastorio 2's materials and science tiers
---
--- Krastorio 2 (and Krastorio 2 Spaced Out) is not our mod, so this mod carries the compatibility itself, the way Gregtorio
--- Continued carries its own in its prototypes/120-fork-me-network-compat.lua: only through ME_NETWORK.replace_recipe and
--- ME_NETWORK.set_technology, no prototype renamed, nothing at runtime. data-updates.lua requires this file when one of the
--- two mods is active, Gregtorio Continued is not (its recipes win) and the startup setting me-network-krastorio2-recipes
--- is on. It runs in our data-updates, after Krastorio 2's (the hidden optional dependencies of info.json); Krastorio 2's
--- data-final-fixes (enforce-science-tier-separation.lua: the red to blue packs taken from technologies that need its
--- higher cards) still runs after it.
---
--- Every Krastorio 2 item goes through kr(): a name that Krastorio 2 or Spaced Out does not have (renamed in a later version)
--- degrades to the vanilla stand-in of the recipe without the compatibility, with one log line, instead of a load error.
--------------------------------------------------------------------------------

local ME = ME_NETWORK

--- the Krastorio 2 item `name` if a prototype of an item type has that name, else the vanilla `fallback` (one log line; a
--- nil fallback: an ingredient Krastorio 2 adds that the recipe without it does not have, then left out)
local function kr(name, fallback)
	for t in pairs(defines.prototypes.item) do
		if data.raw[t] and data.raw[t][name] then return name end
	end
	log("ME-NETWORK: Krastorio 2: no item " .. name .. ", " .. (fallback or "nothing") .. " instead")
	return fallback
end

--- what this file did, for devcheck (tools/devcheck/checkmod/data-final-fixes.lua, section KRASTORIO2)
ME.krastorio2 = { kr = kr }

--------------------------------------------------------------------------------
--- Issue #593: the recipes. Each AE2 material keeps one stand-in (docs/AE2.md "Recipes"), now a Krastorio 2 item where one
--- exists; AE2's counts stay, and so do the processors (electronic circuit, advanced circuit, processing unit), the lamp,
--- the combinators and the machines: Krastorio 2 makes them dearer itself. No ME recipe takes printed silicon itself (in
--- AE2 it goes into the processors), so kr-silicon is not used.
--------------------------------------------------------------------------------

local QUARTZ = kr("kr-quartz", "stone")                         -- certus quartz
local GLASS = kr("kr-glass", "plastic-bar")                     -- glass, quartz glass, quartz fiber
local CORE = kr("kr-automation-core", "electronic-circuit")     -- annihilation core, formation core
local PISTON = kr("kr-inserter-parts", "fast-inserter")         -- piston
local SKY_DUST = kr("kr-imersite-powder", "stone-brick")        -- sky stone dust (the components from 256k)
local GLOWSTONE = kr("kr-rare-metals", "copper-cable")          -- glowstone (64k component, blank pattern)
local DIAMOND = kr("kr-rare-metals", "processing-unit")         -- diamond (advanced card)
local ENERGY_CELL = kr("kr-lithium-sulfur-battery", "battery")  -- dense energy cell (wireless, singularity cells)
local QUANTUM = kr("kr-ai-core", "battery")                     -- quantum ring (ME Quantum Bridge)
local C4096 = kr("kr-imersium-plate", "stone-brick")            -- the 4096k component
local C16384 = kr("kr-energy-control-unit", "stone-brick")      -- the 16384k component
local ACCELERATOR = kr("kr-energy-control-unit", nil)           -- the crafting accelerators of the second technology
local CONDENSER = kr("kr-charged-matter-stabilizer", nil)       -- matter condenser (singularity cells)
--- a fluix crystal or fluix dust (copper cable before): a certus quartz and the copper cable
local FLUIX = { { QUARTZ ~= "stone" and QUARTZ or nil, 1 }, { "copper-cable", 1 } }
local NEW_GLASS = GLASS ~= "plastic-bar" and GLASS or nil     -- (glass that had no stand-in: none without Krastorio 2)

--- ME_NETWORK.recipes -> { [stand-in] = list of { item, per } } and `add`: the stand-in's amount n becomes n * per of each
--- item (per = a number) or exactly `per.n` (per = { n = ... }); `add` lists items added. Recipes missing here keep their
--- ingredients (cells, crafting storages, the not-AE2 blocks).
local function each(item) return { { item, 1 } } end
local function n(count) return { n = count } end
local SWAPS = {
	["fluix-cable"] = { ["plastic-bar"] = each(GLASS), ["copper-cable"] = FLUIX },
	["me-controller"] = { ["copper-cable"] = FLUIX },                               -- (the smooth sky stone stays stone brick)
	["me-interface"] = { ["plastic-bar"] = each(GLASS), ["electronic-circuit"] = each(CORE) },
	["me-terminal"] = { ["electronic-circuit"] = { { CORE, n(2) }, { "electronic-circuit", n(1) } } },   -- (2 cores, a logic processor)
	["me-chest"] = { ["plastic-bar"] = each(GLASS) },
	["basic-storage-housing"] = { ["plastic-bar"] = each(GLASS) },
	["me-1k-storage-component"] = { ["stone"] = each(QUARTZ) },
	["me-4k-storage-component"] = { ["plastic-bar"] = each(GLASS) },
	["me-16k-storage-component"] = { ["plastic-bar"] = each(GLASS) },     -- (AE2's glowstone: kept copper cable, the 16k is red + green)
	["me-64k-storage-component"] = { ["plastic-bar"] = each(GLASS), ["copper-cable"] = each(GLOWSTONE) },
	["me-256k-storage-component"] = { ["plastic-bar"] = each(GLASS), ["stone-brick"] = each(SKY_DUST) },
	["me-1024k-storage-component"] = { ["plastic-bar"] = each(GLASS), ["stone-brick"] = each(SKY_DUST) },
	["me-4096k-storage-component"] = { ["plastic-bar"] = each(GLASS), ["stone-brick"] = each(C4096) },
	["me-16384k-storage-component"] = { ["plastic-bar"] = each(GLASS), ["stone-brick"] = each(C16384) },
	--- AE2-Unofficial: 8 quantum cells (rings, a dense energy cell each) around a matter condenser
	["me-singularity-storage-cell"] = { ["accumulator"] = each(ENERGY_CELL), add = { { CONDENSER, 1 } } },
	["me-singularity-fluid-storage-cell"] = { ["accumulator"] = each(ENERGY_CELL), add = { { CONDENSER, 1 } } },
	["me-import-bus"] = { ["electronic-circuit"] = each(CORE), ["fast-inserter"] = each(PISTON) },
	["me-export-bus"] = { ["electronic-circuit"] = each(CORE), ["fast-inserter"] = each(PISTON) },
	["me-storage-bus"] = { ["fast-inserter"] = each(PISTON) },
	["me-void-storage-cell"] = { ["plastic-bar"] = each(GLASS) },
	["me-void-fluid-storage-cell"] = { ["plastic-bar"] = each(GLASS) },
	["me-io-port"] = { add = { { NEW_GLASS, 3 } } },      -- (AE2's 3 glass, no stand-in before)
	--- eight rings (their energy cell the quantum part) and the chamber's 4 quartz glass (no stand-in before)
	["me-quantum-bridge"] = { ["battery"] = each(QUANTUM), add = { { NEW_GLASS, 4 } } },
	["me-pattern-provider"] = { ["electronic-circuit"] = each(CORE) },
	["me-blank-pattern"] = { ["plastic-bar"] = each(GLASS), ["copper-cable"] = each(GLOWSTONE), ["stone"] = each(QUARTZ) },
	["me-molecular-assembler"] = { ["plastic-bar"] = each(GLASS), ["electronic-circuit"] = each(CORE) },
	["me-advanced-card"] = { ["processing-unit"] = each(DIAMOND) },
	["me-capacity-card"] = { ["stone"] = each(QUARTZ) },
	["me-acceleration-card"] = { ["copper-cable"] = FLUIX },
	["me-view-cell"] = { ["stone"] = each(QUARTZ) },
	["me-wireless-booster"] = { ["copper-cable"] = FLUIX, ["stone"] = each(QUARTZ) },
	["me-wireless-terminal"] = { ["battery"] = { { ENERGY_CELL, n(1) } } },          -- (a dense energy cell: 4 batteries before)
	["me-wireless-module"] = { ["battery"] = { { ENERGY_CELL, n(3) } } },            -- (not AE2: 10 batteries, a cell per 4)
	["me-crafting-accelerator-256x"] = { add = { { ACCELERATOR, 1 } } },
	["me-crafting-accelerator-1024x"] = { add = { { ACCELERATOR, 1 } } },
	["me-crafting-accelerator-4096x"] = { add = { { ACCELERATOR, 1 } } },
}
for _, tier in ipairs({ "1k", "4k", "16k", "64k", "256k", "1024k", "4096k", "16384k" }) do
	SWAPS["me-" .. tier .. "-fluid-storage-cell"] = { ["plastic-bar"] = each(GLASS) }   -- (the fluid cell housing's quartz glass)
end

--- the recipe `name` with its stand-ins swapped (an item that is a stand-in of itself stays; equal items are merged)
local function swapped(name, swaps)
	local r = data.raw.recipe[name]
	if not r then return end
	local out, at = {}, {}
	local function put(item, amount)
		if not item or amount <= 0 then return end
		if at[item] then out[at[item]].amount = out[at[item]].amount + amount
		else out[#out + 1] = { type = "item", name = item, amount = amount } at[item] = #out end
	end
	for _, i in ipairs(r.ingredients or {}) do
		local to = i.type ~= "fluid" and swaps[i.name]
		if to then
			for _, t in ipairs(to) do put(t[1], type(t[2]) == "table" and t[2].n or i.amount * t[2]) end
		elseif i.type == "fluid" then
			out[#out + 1] = table.deepcopy(i)
		else
			put(i.name, i.amount)
		end
	end
	for _, a in ipairs(swaps.add or {}) do put(a[1], a[2]) end
	local def = table.deepcopy(r)
	def.ingredients = out
	return def
end

for _, name in ipairs(table.deepcopy(ME.recipes)) do
	local swaps = SWAPS[name]
	if swaps then
		local def = swapped(name, swaps)
		if def then ME.replace_recipe(def) end
	end
end

--------------------------------------------------------------------------------
--- Issue #593: the ME Molecular Assembler again. prototypes/autocrafting.lua made it in our data.lua from the item
--- categories of the assembling machine 2 as they were then; this takes them as they are after Krastorio 2's data-updates
--- (without the fluid categories: the assembler has no fluid boxes). Its speed and power stay. Krastorio 2's categories of
--- its own machines (crushing, electrolysis, matter, ...) are never categories of the assembling machine 2.
--------------------------------------------------------------------------------

local assembler = data.raw["assembling-machine"]["me-molecular-assembler"]
local base = data.raw["assembling-machine"]["assembling-machine-2"]
if assembler and base then
	local categories = {}
	for _, c in pairs(base.crafting_categories or {}) do
		if not c:find("fluid") then categories[#categories + 1] = c end
	end
	ME.make_molecular_assembler{ base = "assembling-machine-2", crafting_categories = categories,
		crafting_speed = assembler.crafting_speed, energy_usage = assembler.energy_usage }
	ME.krastorio2.assembler_categories = categories
end
