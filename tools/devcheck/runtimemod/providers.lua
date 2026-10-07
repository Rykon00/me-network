--- Runtime test of me-network issue #158: the pattern provider runs machines next to it. Each case is a provider with
--- one pattern (a crafting pattern, or a processing pattern that names the recipe it was encoded from) next to one
--- machine that has no recipe set: the Molecular Assembler, a machine of an item recipe, of a fluid recipe (free and with
--- a pipe on a used box), a machine with a fixed recipe, a furnace and a rocket silo. The census logs each case's status
--- (DEVCHECK-RUNTIME-PROVIDERS-CENSUS) and the crafting machine prototypes of the game; the checks follow the census:
---   * a processing pattern that names its recipe is usable at an assembling machine without that recipe (the Molecular
---     Assembler, an item and a fluid recipe), refused at a fixed machine of another recipe ("fixed-recipe"); a furnace
---     keeps taking processing patterns by its input; crafting patterns as before;
---   * a job of the processing pattern at the macerator (no recipe set): the machine is switched, runs, the product
---     arrives in the network, the machine is idle again with the pattern's recipe;
---   * the macerator busy on another recipe (plates in it): a second job waits, the machine is switched when it is done
---     with them (what was left of them went into the network), the job ends done.
--- Loaded by control.lua: require("providers")(H) returns { setup, tick, running }.

local AC, NET = "gregtorio-me-autocraft", "gregtorio-me-network"
local BX, BY = -100, -260
local START, TIMEOUT = 150, 1000

--- the cases: machine, recipe, the pattern kinds, and a pipe on the first used fluid input box
local CASES = {
	{ id = "assembler-item", machine = "me-molecular-assembler", recipe = "iron-gear-crafting-table" },
	{ id = "machine-item", machine = "ev-macerator", recipe = "crushed-iron" },
	{ id = "machine-fluid", machine = "hv-chemical-reactor", recipe = "hydrochloric-acid" },
	{ id = "machine-fluid-piped", machine = "hv-chemical-reactor", recipe = "hydrochloric-acid", pipe = true },
	--- issue #164: the same machine turned east, and a pipe beside the machine on a tile without a connection
	{ id = "machine-fluid-piped-east", machine = "hv-chemical-reactor", recipe = "hydrochloric-acid", pipe = true, dir = "east" },
	{ id = "machine-fluid-pipe-beside", machine = "hv-chemical-reactor", recipe = "hydrochloric-acid", pipe = "beside" },
	{ id = "fixed-other", machine = "zz-devcheck-fixed-machine", recipe = "zz-devcheck-unfixed" },
	{ id = "fixed-own", machine = "zz-devcheck-fixed-machine", recipe = "zz-devcheck-fixed" },
	{ id = "furnace", machine = "iron-furnace", recipe = "iron-dust-smelter" },
	{ id = "rocket-silo", machine = "rocket-silo", recipe = "rocket-part" },
}
local KINDS = { "crafting", "processing" }

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	--- the pattern of `kind` for `recipe`: a crafting pattern, or a processing pattern from the recipe's ingredients and
	--- products that names the recipe (as the Pattern Terminal's "From recipe" encodes it)
	local function pattern(kind, recipe)
		if kind == "crafting" then return { kind = "crafting", recipe = recipe } end
		local proto = prototypes.recipe[recipe]
		local inputs, outputs = {}, {}
		for _, i in pairs(proto.ingredients) do
			inputs[#inputs + 1] = { key = (i.type == "fluid" and "fluid/" or "") .. i.name, amount = i.amount }
		end
		for _, p in pairs(proto.products) do
			local amount = p.amount or p.amount_max or 1
			if p.type == "fluid" then outputs[#outputs + 1] = { key = "fluid/" .. p.name, amount = amount }
			else outputs[#outputs + 1] = { key = p.name, amount = amount } end
		end
		return { kind = "processing", inputs = inputs, outputs = outputs, recipe = recipe }
	end

	function T.setup(s)
		local fails = {}
		local what = "provider machines"
		local tiles = {}
		for x = BX - 6, BX + 6 + 14 * #CASES do
			for y = BY - 6, BY + 34 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["raw-iron"] = 100, ["iron-plate"] = 100 }, "16k")
		local cpu = me_place(s, fails, what, "me-crafting-cpu", BX + 11, BY)
		local members = { ctrl, drive, cpu }
		local scene = { ctrl = ctrl, cases = {} }
		for i, c in ipairs(CASES) do
			for k, kind in ipairs(KINDS) do
				local x, y = BX + 14 * (i - 1), BY + 6 + 14 * (k - 1)
				local proto = prototypes.entity[c.machine]
				local m, p
				if proto and prototypes.recipe[c.recipe] then
					local w = proto.tile_width
					p = me_place(s, fails, what, "me-pattern-provider", x + 0.5, y + 0.5)
					m = me_place(s, fails, what, c.machine, x + 1 + w / 2, y + 0.5, c.dir and { direction = defines.direction[c.dir] } or nil)
					if m and c.pipe == "beside" then
						--- (the tile below the machine's middle column: no box of the chemical plant has a connection there)
						me_place(s, fails, what, "pipe", m.position.x, m.position.y + 2)
					elseif m and c.pipe then
						--- a pipe on the pipe connection of the recipe's first fluid input box (after the recipe is set, the boxes exist)
						pcall(m.set_recipe, c.recipe)
						local fb = m.fluidbox
						for b = 1, #fb do
							local pr = fb.get_prototype(b)
							if pr and pr.production_type == nil and pr[1] then pr = pr[1] end
							if pr and pr.production_type == "input" then
								for _, pc in pairs(fb.get_pipe_connections(b)) do
									if pc.target_position then
										me_place(s, fails, what, "pipe", pc.target_position.x, pc.target_position.y)
										break
									end
								end
								break
							end
						end
						pcall(m.set_recipe, nil)
					end
					if p then members[#members + 1] = p end
				end
				scene.cases[#scene.cases + 1] = { id = c.id, kind = kind, recipe = c.recipe, provider = p, machine = m,
					missing = not (proto and prototypes.recipe[c.recipe]) }
				if c.id == "machine-item" and kind == "processing" then           -- the job tests: power for the macerator
					local eei = me_place(s, fails, what, "electric-energy-interface", x + 8.5, y + 4.5)
					if eei then
						eei.power_production = 1e9
						eei.electric_buffer_size = 1e10
					end
					me_place(s, fails, what, "substation", x + 5, y + 4)
				end
			end
		end
		H.me_connect(fails, what, members)
		storage.providers158_scene = scene
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.providers158
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = 0 }
			storage.providers158 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("PROVIDERS", "ME pattern provider machines", problems, note)
		end
		local sc = storage.providers158_scene
		if not (sc and sc.ctrl and sc.ctrl.valid) then
			expect(false, "the network was not built")
			return finish()
		end
		if st.phase == 0 then
			st.phase = 1
			for _, c in ipairs(sc.cases) do
				if c.provider and c.provider.valid then
					c.provider.force.recipes[c.recipe].enabled = true
					give_patterns(c.provider, { pattern(c.kind, c.recipe) }, problems)
				end
			end
			--- the census of the crafting machine prototypes
			local by_type, fixed, fluid = {}, 0, 0
			for _, proto in pairs(prototypes.get_entity_filtered{ { filter = "crafting-machine" } }) do
				by_type[proto.type] = (by_type[proto.type] or 0) + 1
				if proto.fixed_recipe and proto.fixed_recipe ~= "" then fixed = fixed + 1 end
				if #(proto.fluidbox_prototypes or {}) > 0 then fluid = fluid + 1 end
			end
			log("DEVCHECK-RUNTIME-PROVIDERS-CENSUS prototypes | " .. serpent.line(by_type) .. " | fixed recipe " .. fixed .. " | with fluid boxes " .. fluid)
			st.phase_tick = tick
			return
		end
		if st.phase == 1 then
			if tick < st.phase_tick + 5 then return end
			for _, c in ipairs(sc.cases) do
				local slot
				if c.provider and c.provider.valid then
					local info = remote.call(AC, "provider_info", c.provider)
					slot = info and info.slots and info.slots[1]
				end
				local m = c.machine
				log("DEVCHECK-RUNTIME-PROVIDERS-CENSUS " .. c.id .. " | " .. c.kind .. " | "
					.. (c.missing and "no such machine or recipe" or slot and ((slot.ok and "usable" or "not usable") .. " | reason "
						.. tostring(slot.reason) .. " | machines " .. tostring(slot.machines)) or "no pattern")
					.. " | " .. (m and m.valid and (m.type .. " " .. m.name) or "-"))
			end
			--- the checks of the census
			local want = {
				["assembler-item"] = { crafting = true, processing = true },
				["machine-item"] = { crafting = true, processing = true },
				["machine-fluid"] = { crafting = true, processing = true },
				--- issue #164: a pipe on a used box is seen also while the machine's boxes are off (Gregtorio's machines)
				["machine-fluid-piped"] = { crafting = "fluid-pipes", processing = "fluid-pipes" },
				["machine-fluid-piped-east"] = { crafting = "fluid-pipes", processing = "fluid-pipes" },
				["machine-fluid-pipe-beside"] = { crafting = true, processing = true },
				["fixed-other"] = { crafting = "fixed-recipe", processing = "fixed-recipe" },
				["fixed-own"] = { crafting = true, processing = true },
				["furnace"] = { crafting = "furnace", processing = true },
			}
			for _, c in ipairs(sc.cases) do
				local w = want[c.id] and want[c.id][c.kind]
				if w ~= nil and c.provider and c.provider.valid then
					local slot = ((remote.call(AC, "provider_info", c.provider) or {}).slots or {})[1] or {}
					if w == true then expect(slot.ok and slot.machines == 1, c.id .. " " .. c.kind .. ": " .. serpent.line(slot))
					else expect(not slot.ok and slot.reason == w, c.id .. " " .. c.kind .. ": " .. serpent.line(slot) .. ", want " .. w) end
				end
			end
			--- the job tests on the macerator's processing pattern (its provider first, before the crafting pattern's)
			for _, c in ipairs(sc.cases) do
				if c.id == "machine-item" and c.kind == "processing" then st.job_case = c end
			end
			local c = st.job_case
			if not (c and c.provider and c.provider.valid and c.machine and c.machine.valid) then
				expect(false, "the macerator case is missing")
				return finish()
			end
			remote.call(AC, "set_priority", c.provider, 100)
			st.before = remote.call(NET, "count", sc.ctrl, "crushed-iron")
			local id, why = remote.call(AC, "start", sc.ctrl, "crushed-iron", 2)
			expect(id ~= nil, "the first job: " .. tostring(why))
			if not id then return finish() end
			st.job, st.phase, st.phase_tick = id, 2, tick
			return
		end
		local c = st.job_case
		local m = c.machine
		local function recipe() local r = m.valid and m.get_recipe() return r and r.name end
		local function job() return remote.call(AC, "job", st.job) end
		if st.phase == 2 then
			--- the first job: the macerator had no recipe; it is switched, runs, the crushed iron arrives
			local j = job()
			if j and j.status ~= "done" and j.status ~= "failed" and j.status ~= "cancelled" then
				if tick > st.phase_tick + TIMEOUT / 2 then
					expect(false, "the first job did not end: " .. serpent.line(j))
					return finish()
				end
				return
			end
			local got = remote.call(NET, "count", sc.ctrl, "crushed-iron") - st.before
			expect((not j or j.status == "done") and got >= 2, "the first job: " .. serpent.line(j and j.status) .. ", crushed iron " .. got)
			expect(recipe() == c.recipe and m.crafting_progress == 0 and m.get_inventory(defines.inventory.crafter_input).is_empty(),
				"the macerator after the first job: " .. tostring(recipe()) .. ", progress " .. m.crafting_progress)
			--- busy on another recipe: plates in it
			m.set_recipe("zz-devcheck-macerate-plate")
			local put = m.get_inventory(defines.inventory.crafter_input).insert{ name = "iron-plate", count = 6 }
			expect(put == 6, "plates into the macerator: " .. put)
			st.before = remote.call(NET, "count", sc.ctrl, "crushed-iron")
			st.plates = remote.call(NET, "count", sc.ctrl, "iron-plate")
			local id, why = remote.call(AC, "start", sc.ctrl, "crushed-iron", 2)
			expect(id ~= nil, "the second job: " .. tostring(why))
			if not id then return finish() end
			st.job, st.phase, st.phase_tick, st.waited = id, 3, tick, false
			return
		end
		if st.phase == 3 then
			local j = job()
			if recipe() == "zz-devcheck-macerate-plate" and j and j.status ~= "done" then st.waited = true end
			if j and j.status ~= "done" and j.status ~= "failed" and j.status ~= "cancelled" then
				if tick > st.phase_tick + TIMEOUT then
					expect(false, "the second job did not end: " .. serpent.line(j) .. ", recipe " .. tostring(recipe()))
					return finish()
				end
				return
			end
			local got = remote.call(NET, "count", sc.ctrl, "crushed-iron") - st.before
			expect(st.waited and (not j or j.status == "done") and got >= 2 and recipe() == c.recipe,
				"the second job: waited " .. tostring(st.waited) .. ", " .. serpent.line(j and j.status) .. ", crushed iron " .. got
				.. ", recipe " .. tostring(recipe()))
			return finish("census, a processing pattern switches a machine, a busy machine switched after it")
		end
	end

	function T.running(check) check(storage.providers158 and storage.providers158.done, "ME pattern provider machines") end

	return T
end
