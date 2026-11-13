--------------------------------------------------------------------------------
--- SPACE EXPLORATION: the ME network on Space Exploration's materials and science tiers
---
--- Space Exploration is not our mod, so this mod carries the compatibility itself, like the one for Krastorio 2
--- (prototypes/compat/krastorio2.lua): only through ME_NETWORK.replace_recipe and ME_NETWORK.set_technology, no prototype
--- renamed, nothing at runtime. data-updates.lua requires this file when Space Exploration is active, Gregtorio Continued is
--- not (its recipes win) and the startup setting me-network-space-exploration-recipes is on. It runs in our data-updates,
--- after Space Exploration's (the hidden optional dependency of info.json). Space Exploration's data-final-fixes still runs
--- after it: its procedural technology pass skips our technologies (prototypes/compat/space-exploration-early.lua), and the
--- last loop of that file (utility science with the astronomic and energy packs, production science with the material and
--- biological ones, the space science pack with those two, the rocket science pack with the space science pack) finds every
--- one of those packs already named here, so the result does not depend on it. Its postprocess mod then drops prerequisites
--- that another prerequisite implies.
---
--- Every Space Exploration item, pack and technology goes through se(): a name it does not have (renamed in a later
--- version) degrades to the stand-in of the recipe without the compatibility, with one log line, instead of a load error.
---
--- With Krastorio 2 as well (a combination Space Exploration supports with a compatibility of its own): the Krastorio 2
--- file has run before this one. Its early materials stay (quartz, glass, automation core, inserter parts, rare metals, the
--- lithium-sulfur battery); where both files name a stand-in of the same recipe, this one wins (the components from 256k,
--- the ME Quantum Bridge, the Singularity cells, the second accelerators), and so do its technologies from ME 64k Storage
--- on: Space Exploration reorders Krastorio 2's upper tiers itself, and its own tiers are the ones a player of both follows.
--------------------------------------------------------------------------------

local ME = ME_NETWORK
local COMMON = require("prototypes.compat.common")
local K2 = ME.krastorio2                      -- (the Krastorio 2 compatibility ran: its table, else nil)

local missing = {}
--- the first of `names` (a name or a list of names) that is a prototype of an item type, else the vanilla `fallback` (one
--- log line; a nil fallback: an ingredient Space Exploration adds that the recipe without it does not have, then left out)
local function se(names, fallback)
	if type(names) == "string" then names = { names } end
	for _, name in ipairs(names) do
		for t in pairs(defines.prototypes.item) do
			if data.raw[t] and data.raw[t][name] then return name end
		end
	end
	log("ME-NETWORK: Space Exploration: no item " .. table.concat(names, " / ") .. ", " .. (fallback or "nothing") .. " instead")
	missing[#missing + 1] = { names[1], fallback or "nothing" }
	return fallback
end
--- the technology `name` if it exists, else nil (one log line)
local function se_tech(name)
	if data.raw.technology[name] then return name end
	log("ME-NETWORK: Space Exploration: no technology " .. name)
	missing[#missing + 1] = { name, "no prerequisite" }
end

--- what this file did, for devcheck (tools/devcheck/checkmod/data-final-fixes.lua, section SPACEEXPLORATION)
ME.space_exploration = { se = se, missing = missing, packs = {}, with_krastorio2 = K2 ~= nil }

--------------------------------------------------------------------------------
--- The recipes. Each AE2 material keeps one stand-in (docs/AE2.md "Recipes"), now a Space Exploration item where a fitting
--- one exists; AE2's counts stay, and so do the processors (electronic circuit, advanced circuit, processing unit: Space
--- Exploration puts the processing unit behind its rocket science pack itself), the lamp, the combinators and the machines.
--- The storage ladder follows the data line (issue #712: an ME storage component is data storage): the data storage
--- substrate for 256k, blank data cards from 1024k on, in place of the cryonite rod and the heavy parts of the material line
--- they took before; the crafting side follows the energy science line (holmium cable, quantum processor), the Singularity
--- cells take the naquium tessaract of the second deep space tier (issue #709; a plain recipe, no arcosphere recipe). Space Exploration has no quartz and no core item: certus quartz stays stone,
--- the annihilation and formation core the electronic circuit.
--------------------------------------------------------------------------------

--- glass: AAI Industry's (a dependency of Space Exploration), or Krastorio 2's where Space Exploration uses that
local GLASS = K2 and K2.glass or se({ "glass", "kr-glass" }, "plastic-bar")
local PISTON = se("electric-motor", "fast-inserter")              -- piston (AAI Industry's electric motor)
--- issue #712 (replaced, no second recipe): the sky stone dust of the components from 256k is Space Exploration's data line
local C256 = se("se-data-storage-substrate", "stone-brick")       -- ... of the 256k component: data storage substrate
local C1024 = se("se-empty-data", "stone-brick")                  -- ... of the 1024k, 4096k and 16384k component: blank data cards
local C4096, C16384 = C1024, C1024
local QUANTUM = se("se-quantum-processor", "battery")             -- quantum ring (ME Quantum Bridge), energy science 3
--- issue #714: the singularity of the ME Quantum Bridge's chamber is a naquium cube (deep space 1), the one the Singularity
--- cells took before issue #709: the bridge is a deep space 1 block (the technologies below say why)
local BRIDGE_CORE = se("se-naquium-cube", nil)
local ENERGY_CELL = se("se-space-accumulator", "accumulator")     -- dense energy cell of the Singularity cells
--- issue #709: the matter condenser of the Singularity cells is the naquium tessaract (deep space 2; the naquium cube of deep
--- space 1 before). The tessaract itself is folded with arcospheres in Space Exploration's own recipe; the cell's recipe
--- stays a plain one that takes it, so nobody has to solve an arcosphere puzzle for a storage cell.
local CONDENSER = se({ "se-naquium-tessaract", "se-naquium-cube" }, nil)
local ACCELERATOR = se("se-holmium-cable", nil)                   -- the crafting accelerators of the first technology
local ACCELERATOR_2 = se("se-quantum-processor", nil)             -- the crafting accelerators of the second technology
local NEW_GLASS = GLASS ~= "plastic-bar" and GLASS or nil         -- (glass that had no stand-in: none without a glass item)

local function each(item) return { { item, 1 } } end
local SWAPS = {
	["me-256k-storage-component"] = { ["stone-brick"] = each(C256) },
	["me-1024k-storage-component"] = { ["stone-brick"] = each(C1024) },
	["me-4096k-storage-component"] = { ["stone-brick"] = each(C4096) },
	["me-16384k-storage-component"] = { ["stone-brick"] = each(C16384) },
	--- AE2-Unofficial: 8 quantum cells (rings, a dense energy cell each) around a matter condenser
	["me-singularity-storage-cell"] = { ["accumulator"] = each(ENERGY_CELL), add = { { CONDENSER, 1 } } },
	["me-singularity-fluid-storage-cell"] = { ["accumulator"] = each(ENERGY_CELL), add = { { CONDENSER, 1 } } },
	--- eight rings (their energy cell the quantum part) and the chamber's 4 quartz glass (no stand-in without a glass item)
	["me-quantum-bridge"] = { ["battery"] = each(QUANTUM), add = { { NEW_GLASS, 4 }, { BRIDGE_CORE, 1 } } },
	["me-crafting-accelerator-4x"] = { add = { { ACCELERATOR, 4 } } },          -- (the wiring of its 4 co-processing units)
	["me-crafting-accelerator-256x"] = { add = { { ACCELERATOR_2, 1 } } },
	["me-crafting-accelerator-1024x"] = { add = { { ACCELERATOR_2, 1 } } },
	["me-crafting-accelerator-4096x"] = { add = { { ACCELERATOR_2, 1 } } },
}
--- the early stand-ins, glass and the piston: with the Krastorio 2 compatibility its table has them already (its glass, its
--- inserter parts), and the entries here would only repeat or replace them
if not K2 then
	local glass = { ["plastic-bar"] = each(GLASS) }
	for _, name in ipairs({ "fluix-cable", "me-interface", "me-chest", "basic-storage-housing", "me-4k-storage-component",
			"me-16k-storage-component", "me-64k-storage-component", "me-256k-storage-component", "me-1024k-storage-component",
			"me-4096k-storage-component", "me-16384k-storage-component", "me-void-storage-cell", "me-void-fluid-storage-cell",
			"me-blank-pattern", "me-molecular-assembler" }) do
		SWAPS[name] = SWAPS[name] or {}
		SWAPS[name]["plastic-bar"] = glass["plastic-bar"]
	end
	for _, tier in ipairs({ "1k", "4k", "16k", "64k", "256k", "1024k", "4096k", "16384k" }) do
		SWAPS["me-" .. tier .. "-fluid-storage-cell"] = { ["plastic-bar"] = each(GLASS) }   -- (the fluid cell housing's quartz glass)
	end
	SWAPS["me-io-port"] = { add = { { NEW_GLASS, 3 } } }      -- (AE2's 3 glass, no stand-in before)
	SWAPS["me-import-bus"] = { ["fast-inserter"] = each(PISTON) }
	SWAPS["me-export-bus"] = { ["fast-inserter"] = each(PISTON) }
	SWAPS["me-storage-bus"] = { ["fast-inserter"] = each(PISTON) }
end

--- Krastorio 2's table with this one laid over it, applied to the recipes as they were before either (data-updates.lua):
--- per recipe and stand-in this file's entry where it has one, else Krastorio 2's
ME.space_exploration.swaps = SWAPS
COMMON.apply(COMMON.merged(K2 and K2.swaps, SWAPS), ME.standalone.recipes)

--------------------------------------------------------------------------------
--- The ME Molecular Assembler again, as with Krastorio 2: from the item categories of the assembling machine 2 as they are
--- after Space Exploration's (and AAI Industry's) data-updates. Never a "space-..." category: Space Exploration makes a
--- "-grounded" twin of a machine that has one and can stand on land, and swaps the two at runtime; the assembler is one
--- entity everywhere (issue: the space assembling machine's recipes are an idea of their own).
--------------------------------------------------------------------------------

ME.space_exploration.assembler_categories = COMMON.remake_assembler(function(category)
	return not category:find("fluid") and category:sub(1, 6) ~= "space-"
end)

--------------------------------------------------------------------------------
--- The technologies on Space Exploration's science tiers (docs/AE2.md, "With Space Exploration"). Its order is: red, green,
--- blue; the rocket science pack (made on Nauvis, before the first launch); the space science pack (the first one made in
--- orbit); utility and production science (in orbit); the four specialist lines, 1 to 4 (astronomic and energy on utility,
--- material and biological on production); deep space 1 to 4. A technology names the packs below its tier and only the
--- highest pack of a line, as Space Exploration's own do.
---   - ME Network, the cells up to 16k and the level emitter: untouched (red and green).
---   - 64k and fluid storage: blue. Without Space Exploration ME 64k Storage follows the processing unit, which Space
---     Exploration moved behind rocket science; no recipe of the two takes one, so the prerequisite is dropped and they
---     stay before the rocket.
---   - Autocrafting, the cards, automation, wireless: rocket science. Their recipes take processing units (pattern terminal,
---     P2P tunnels, Advanced Card, advanced level emitter, wireless module), which stay (the rule of the recipes above), so
---     they follow the processing unit. That is still Nauvis: the rocket science pack needs no launch.
---   - The storage ladder from 256k on the data line (issue #712). The line has two materials, the data storage substrate
---     and the blank data card (both from Space Exploration's technology Data cards, space science), and four tiers of the
---     machine that works on data cards, the space supercomputer. So: 256k after Data cards (space science, the substrate);
---     1024k after Supercomputer 1 (space science, blank data cards); 4096k after Supercomputer 2 (energy science 3); 16384k
---     after Supercomputer 3 (energy, material and biological science 3). Supercomputer 4 (deep space 3) is past the
---     Singularity cells' tier and gates nothing. Co-processing stays at space science.
---   - Quantum crafting and the accelerators: energy science 1; the second accelerators: energy science 3 (quantum processor);
---     the crafting storages take the component of their storage tier: its packs with the energy pack of quantum crafting.
---   - ME Quantum Bridge: deep space 1 (issue #714; astronomic and energy science 3 before). It joins networks on any two
---     surfaces at once and without a limit, items and fluids, which in Space Exploration is the work of cargo rockets and
---     the delivery cannon (rocket science), the space elevator (2000 x 60 s with energy 1, astronomic 1 and material 2)
---     and spaceships (astronomic 3); Space Exploration's own instant link, arcolink storage, is deep space 4 behind
---     Teleportation (10 000 x 60 s). At astronomic and energy 3 the bridge came in the same tier as the spaceship and made
---     it pointless as a freighter the moment it was researched. Deep space 1 is the tier after every specialist line is
---     done: rockets, the elevator and ships have carried the base through four science tiers by then; it is still three
---     tiers below the arcolink, and one below the Singularity cells (deep space 2), which take four bridges. Its recipe
---     takes a naquium cube (deep space 1), so the technology follows Naquium cube; 500 x 60 s as the naquium technologies.
---   - Singularity cells: deep space 2 (issue #709: the naquium tessaract, after Space Exploration's technology of that
---     name, at its cost of 500 x 60 s); the Singularity crafting storage, which takes the cell's component: deep space 2
---     as well, after the cells. The end of the storage ladder is then two steps past 16384k (Supercomputer 3, issue #712):
---     the quantum bridge, and the tessaract. Supercomputer 4 and the naquium processor (deep space 3) stay above it.
--- me-upgrade-cards is set here (without Space Exploration data-final-fixes.lua copies ME 64k Storage's cost onto it, issue
--- #17): its Advanced Card takes a processing unit, so it is ME 64k Storage's count and time with the rocket science pack.
--------------------------------------------------------------------------------

local function pack(name, fallback)
	return se(name, fallback)
end
local RED, GREEN, BLUE = "automation-science-pack", "logistic-science-pack", "chemical-science-pack"
local PRODUCTION, UTILITY = "production-science-pack", "utility-science-pack"
local ROCKET = pack("se-rocket-science-pack", BLUE)
local SPACE = pack("space-science-pack", BLUE)
local function line(name)
	local out = {}
	for i = 1, 4 do out[i] = pack("se-" .. name .. "-science-pack-" .. i, name == "material" and PRODUCTION or UTILITY) end
	return out
end
local MATERIAL, ENERGY, ASTRONOMIC, BIOLOGICAL = line("material"), line("energy"), line("astronomic"), line("biological")

local DEEP_1 = pack("se-deep-space-science-pack-1", UTILITY)
local DEEP_2 = pack("se-deep-space-science-pack-2", UTILITY)

local T_BLUE = { RED, GREEN, BLUE }
local T_ROCKET = { RED, GREEN, BLUE, ROCKET }
local T_SPACE = { RED, GREEN, BLUE, ROCKET, SPACE }
local function t_energy(i) return { RED, GREEN, BLUE, ROCKET, SPACE, UTILITY, ENERGY[i] } end
--- issue #712: the packs of Space Exploration's Supercomputer 3 (the 16384k tier of the data line)
local T_DATA_3 = { RED, GREEN, BLUE, ROCKET, SPACE, UTILITY, PRODUCTION, ENERGY[3], MATERIAL[3], BIOLOGICAL[3] }
local function t_deep(deep)
	return { RED, GREEN, BLUE, ROCKET, SPACE, UTILITY, PRODUCTION, ASTRONOMIC[4], ENERGY[4], MATERIAL[4], deep }
end

--- a unit of `count` with `time`, the packs listed (a fallback pack named twice is counted once)
local function unit(count, time, packs)
	local ingredients, seen = {}, {}
	for _, p in ipairs(packs) do
		if not seen[p] then ingredients[#ingredients + 1] = { p, 1 } seen[p] = true end
	end
	return { count = count, time = time, ingredients = ingredients }
end

--- the prerequisites of `name` as they are without a compatibility file, with `add` (technologies that exist) added and
--- `drop` taken out; with the Krastorio 2 compatibility also `k2`, the Krastorio 2 technologies whose items its recipes
--- still take
local function prerequisites(name, add, drop, k2)
	local out, seen = {}, {}
	local function put(p)
		if p and data.raw.technology[p] and not seen[p] and not (drop and drop[p]) then out[#out + 1] = p seen[p] = true end
	end
	for _, p in ipairs(ME.standalone.prerequisites[name] or {}) do put(p) end
	for _, p in ipairs(add or {}) do put(se_tech(p)) end
	if K2 then
		for _, p in ipairs(k2 or {}) do put(se_tech(p)) end
	end
	return out
end

local NO_UTILITY, NO_PRODUCTION = { ["utility-science-pack"] = true }, { ["production-science-pack"] = true }
local NO_BOTH = { ["utility-science-pack"] = true, ["production-science-pack"] = true }
--- name -> { count, time, packs, prerequisites to add, prerequisites to drop, Krastorio 2 prerequisites to keep }
local TECHS = {
	["me-storage-64k"] = { 400, 30, T_BLUE, { "chemical-science-pack" }, { ["processing-unit"] = true }, { "kr-rare-metal-processing" } },
	["me-fluid-storage"] = { 400, 30, T_BLUE },
	["me-upgrade-cards"] = { 400, 30, T_ROCKET, { "processing-unit" } },
	["me-autocrafting"] = { 200, 60, T_ROCKET, { "processing-unit" } },
	--- (issue #711: the ME Space Molecular Assembler, with Space Assembling, whose cost it has)
	["me-space-autocrafting"] = { 100, 60, T_ROCKET, { "se-space-assembling" } },
	["me-automation"] = { 200, 60, T_ROCKET },
	["me-wireless"] = { 200, 60, T_ROCKET, nil, nil, { "kr-lithium-sulfur-battery" } },
	["me-wireless-link"] = { 100, 60, T_ROCKET },
	--- (issue #712: the data line: Data cards, then the space supercomputers 1 to 3)
	["me-storage-256k"] = { 100, 60, T_SPACE, { "space-science-pack", "se-space-data-card" }, NO_PRODUCTION },
	["me-co-processing"] = { 100, 60, T_SPACE },
	["me-fluid-storage-256k"] = { 100, 60, T_SPACE },
	["me-storage-1024k"] = { 100, 60, T_SPACE, { "se-space-supercomputer-1" }, NO_BOTH },
	["me-fluid-storage-1024k"] = { 100, 60, T_SPACE, nil, NO_BOTH },
	["me-storage-4096k"] = { 200, 60, t_energy(3), { "se-space-supercomputer-2" } },
	["me-fluid-storage-4096k"] = { 200, 60, t_energy(3) },
	["me-storage-16384k"] = { 300, 60, T_DATA_3, { "se-space-supercomputer-3" } },
	["me-fluid-storage-16384k"] = { 300, 60, T_DATA_3 },
	["me-quantum-crafting"] = { 100, 60, t_energy(1), { "se-energy-science-pack-1" }, NO_UTILITY },
	["me-crafting-accelerators"] = { 100, 60, t_energy(1), { "se-holmium-cable" }, NO_UTILITY },
	["me-crafting-accelerators-2"] = { 300, 60, t_energy(3), { "se-quantum-processor" } },
	["me-crafting-storage-1024k"] = { 100, 60, t_energy(1) },
	["me-crafting-storage-4096k"] = { 200, 60, t_energy(3) },
	["me-crafting-storage-16384k"] = { 300, 60, T_DATA_3 },
	["me-quantum-bridge"] = { 500, 60, t_deep(DEEP_1), { "se-quantum-processor", "se-naquium-cube" }, NO_UTILITY },
	["me-storage-singularity"] = { 500, 60, t_deep(DEEP_2), { "se-naquium-tessaract", "se-space-accumulator" },
		{ ["electric-energy-accumulators"] = true } },
	["me-crafting-storage-singularity"] = { 500, 60, t_deep(DEEP_2) },
}

for _, name in ipairs(ME.technologies) do
	local t = TECHS[name]
	if t and data.raw.technology[name] then
		local u = unit(t[1], t[2], t[3])
		ME.set_technology(name, { unit = u, prerequisites = prerequisites(name, t[4], t[5], t[6]) })
		local packs = {}
		for i, ingredient in ipairs(u.ingredients) do packs[i] = ingredient[1] end
		ME.space_exploration.packs[name] = packs
	end
end
