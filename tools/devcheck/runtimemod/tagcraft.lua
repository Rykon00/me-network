--- Runtime test of me-network issue #480: autocrafting of an item of the type item-with-tags (Quality Turrets Reworked makes
--- every turret one, to keep its kills). The item is `zz-devcheck-tagged-wall` of data.lua; data-final-fixes.lua adds a recipe
--- that makes it from an iron plate and one that makes a `zz-devcheck-tagged-post` of two, in a category of the ME Molecular
--- Assembler. One network: a drive with iron plates, three Crafting CPUs, a pattern provider with an ME Molecular Assembler and
--- both crafting patterns, an ME Interface with a Crafting Card, a level maintainer.
--- * The Pattern Terminal encodes both recipes and a processing pattern with the item as its output (on main every key of an
---   item with tags was refused, `P.valid_key`).
--- * The assembler is set to the post recipe and holds a wall with tags (kills 13): the first job (5 walls) switches it, and the
---   wall with tags goes into the network with its tags, not as a plain wall.
--- * A job of 4 posts takes the 5 walls of the network (the planner counts the plain key, `plain_item`) and crafts 3; a wall
---   with tags (kills 7) stored in the network is never taken.
--- * The interface's row of 2 walls with the Crafting Card: a job crafts them and the interface holds 2 untagged walls.
--- * A level maintainer row of 3 walls: a job of the maintainer, the network holds 3.
--- At the end both walls with tags come out of the network with their kills. Loaded by control.lua: require("tagcraft")(H)
--- returns { setup, tick, running }.

local NET, IO, AC, PT = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal"
local CIRC = "gregtorio-me-circuit"
local BX, BY = 380, 252                   -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of tagdamaged.lua)
local START, TIMEOUT = 120, 300           -- (each phase; the runtime run reports at tick 1450)
local ITEM, POST = "zz-devcheck-tagged-wall", "zz-devcheck-tagged-post"
local CARD = "me-crafting-card"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "tagcraft"
		local sc = {}
		power(s, fails, what, BX, BY)
		power(s, fails, what, BX + 22, BY - 8)                 -- (the assembler and the blocks beyond the first substation)
		sc.ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		sc.drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 100, [CARD] = 1 }, "16k")
		sc.cpu1 = me_place(s, fails, what, "me-16k-crafting-storage", BX + 10.5, BY + 1.5)
		sc.cpu2 = me_place(s, fails, what, "me-16k-crafting-storage", BX + 12.5, BY + 1.5)
		sc.cpu3 = me_place(s, fails, what, "me-16k-crafting-storage", BX + 14.5, BY + 1.5)
		sc.prov = me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY - 0.5)
		sc.mol = me_place(s, fails, what, "me-molecular-assembler", BX + 16.5, BY - 1.5)
		sc.iface = me_place(s, fails, what, "me-network-interface", BX + 18.5, BY + 1.5)
		sc.maint = me_place(s, fails, what, "me-level-maintainer", BX + 20.5, BY + 1.5)
		sc.pterm = me_place(s, fails, what, "me-pattern-terminal", BX + 22.5, BY + 1.5)
		me_connect(fails, what, { sc.ctrl, sc.drive, sc.cpu1, sc.cpu2, sc.cpu3, sc.prov, sc.iface, sc.maint, sc.pterm })
		if sc.mol then
			for _, r in pairs({ ITEM, POST }) do sc.mol.force.recipes[r].enabled = true end
			sc.mol.get_module_inventory().insert{ name = "me-acceleration-card", count = 5 }
		end
		if sc.prov then
			give_patterns(sc.prov, { { kind = "crafting", recipe = ITEM }, { kind = "crafting", recipe = POST } }, fails)
		end
		storage.tagcraft480_scene = sc
		return fails
	end

	--- the items of the item with tags in the network: { kills -> count }
	local function tagged(e)
		local out = {}
		for key, n in pairs(remote.call(NET, "contents", e)) do
			if key:find(ITEM .. "@normal#", 1, true) == 1 then
				local data = helpers.json_to_table(key:sub(key:find("#", 1, true) + 1)) or {}
				local k = data.tags and data.tags.kills or "none"
				out[k] = (out[k] or 0) + n
			end
		end
		return out
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.tagcraft480_scene
		local st = storage.tagcraft480
		if st and st.done then return end
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, phase = "start", since = tick }
			storage.tagcraft480 = st
		end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("TAGCRAFT", "ME autocrafting of items with tags", problems, note)
		end
		for _, e in pairs(sc) do
			if not (e and e.valid) then
				expect(false, "the test network was not built")
				return finish("no network")
			end
		end
		local function count(name) return remote.call(NET, "count", sc.ctrl, name) end
		local function job(id) return id and remote.call(AC, "job", id) or nil end
		local function over(j) return j and (j.status == "done" or j.status == "failed" or j.status == "cancelled") end
		local function next_phase(p) st.phase, st.since = p, tick end
		local function timeout(what)
			if tick > st.since + TIMEOUT then
				expect(false, what .. " timed out: " .. serpent.line(job(st.j2 or st.j1)))
				finish("timed out in " .. st.phase)
			end
		end

		if st.phase == "start" then
			--- the Pattern Terminal: both recipes as crafting patterns, the item as the output of a processing pattern
			local force = sc.pterm.force
			for _, r in ipairs({ ITEM, POST }) do
				local ok, why, ed = remote.call(PT, "set_editor_recipe", force, remote.call(PT, "new_editor"), r)
				local pat = ok and remote.call(PT, "pattern_of", force, ed)
				expect(ok and pat ~= nil, "the Pattern Terminal does not encode the recipe " .. r .. ": " .. tostring(why))
			end
			local ed = remote.call(PT, "new_editor")
			ed.mode = "processing"
			local ok1, ed1 = remote.call(PT, "set_editor_row", ed, "inputs", 1, "iron-plate", 1)
			local ok2, ed2 = remote.call(PT, "set_editor_row", ed1, "outputs", 1, ITEM, 1)
			expect(ok1 and ok2 and remote.call(PT, "pattern_of", force, ed2) ~= nil,
				"the Pattern Terminal does not take the item with tags as a processing output: " .. tostring(ok2))
			local info = remote.call(AC, "provider_info", sc.prov) or {}
			local n = 0
			for _ in pairs(info.slots or {}) do n = n + 1 end
			expect(n == 2, "the provider holds " .. n .. " patterns, not the 2 of the recipes with the item")
			--- the assembler set to the post recipe, a wall with tags in its input
			local ok, err = pcall(function() sc.mol.set_recipe(POST) end)
			expect(ok, "the assembler does not take the post recipe: " .. tostring(err))
			local inp = sc.mol.get_inventory(defines.inventory.crafter_input)
			inp[1].set_stack{ name = ITEM, count = 1 }
			inp[1].tags = { kills = 13 }
			local id, why = remote.call(AC, "start", sc.ctrl, ITEM, 5)
			expect(id ~= nil, "no job of 5 walls: " .. tostring(why))
			if not id then return finish("no job") end
			st.j1 = id
			return next_phase("walls")
		end

		if st.phase == "walls" then
			local j = job(st.j1)
			if not over(j) then return timeout("the job of 5 walls") end
			expect(j.status == "done", "the job of 5 walls ended as " .. tostring(j.status) .. " " .. serpent.line(j.reason))
			local t = tagged(sc.ctrl)
			expect(count(ITEM) == 5, "the network holds " .. count(ITEM) .. " plain walls after the job of 5 (the assembler's wall with tags went in as a plain one?)")
			expect(t[13] == 1, "the assembler's wall with tags is not in the network with its tags: " .. serpent.line(t))
			--- a wall with tags in the network; 4 posts take the 5 plain walls and 3 crafted ones, never the one with tags
			local inv = game.create_inventory(1)
			inv[1].set_stack{ name = ITEM, count = 1 }
			inv[1].tags = { kills = 7 }
			expect(remote.call(NET, "insert_stack", sc.ctrl, inv[1]) == 1, "the wall with tags (kills 7) was not stored")
			inv.destroy()
			local p = remote.call(AC, "plan", sc.ctrl, POST, 4) or {}
			expect(p.ok, "no plan of 4 posts: " .. serpent.line(p))
			st.plates = count("iron-plate")
			local id, why = remote.call(AC, "start", sc.ctrl, POST, 4)
			expect(id ~= nil, "no job of 4 posts: " .. tostring(why))
			if not id then return finish("no job") end
			st.j2 = id
			return next_phase("posts")
		end

		if st.phase == "posts" then
			local j = job(st.j2)
			if not over(j) then return timeout("the job of 4 posts") end
			expect(j.status == "done", "the job of 4 posts ended as " .. tostring(j.status) .. " " .. serpent.line(j.reason))
			expect(count(POST) == 4, "the network holds " .. count(POST) .. " posts, not 4")
			expect(count(ITEM) == 0, "the network still holds " .. count(ITEM) .. " plain walls (the job did not take its 5)")
			expect(st.plates - count("iron-plate") == 3, "the job of 4 posts used " .. (st.plates - count("iron-plate"))
				.. " iron plates, not 3 (5 walls came from storage)")
			local t = tagged(sc.ctrl)
			expect(t[7] == 1 and t[13] == 1, "a wall with tags was taken by the job: " .. serpent.line(t))
			--- the interface's row of 2 walls with the Crafting Card
			local inv = game.create_inventory(1)
			expect(remote.call(NET, "extract_to", sc.ctrl, inv, CARD, 1) == 1, "no Crafting Card in the network")
			local why = remote.call(IO, "interface_card_click", sc.iface, 4, inv[1], inv, false)
			expect(why == nil and not inv[1].valid_for_read, "the Crafting Card did not go into the interface: " .. tostring(why))
			inv.destroy()
			remote.call(IO, "set_interface_slot", sc.iface, 1, ITEM, "normal", 2)
			return next_phase("interface")
		end

		if st.phase == "interface" then
			local held = sc.iface.get_inventory(defines.inventory.chest).get_item_count(ITEM)
			if held < 2 then return timeout("the interface's Crafting Card (it holds " .. held .. " walls)") end
			local fi = sc.iface.get_inventory(defines.inventory.chest)
			local plain = 0
			for i = 1, #fi do
				if fi[i].valid_for_read and fi[i].name == ITEM and not next(fi[i].tags) then plain = plain + fi[i].count end
			end
			expect(plain == 2, "the interface holds " .. plain .. " untagged walls, not its row of 2")
			local t = tagged(sc.ctrl)
			expect(t[7] == 1 and t[13] == 1, "a wall with tags left the network for the interface: " .. serpent.line(t))
			expect(remote.call(CIRC, "set_maintainer", sc.maint, ITEM, 3, false), "set_maintainer")
			return next_phase("maintainer")
		end

		if st.phase == "maintainer" then
			if count(ITEM) < 3 then return timeout("the level maintainer's row of 3 walls (the network holds " .. count(ITEM) .. ")") end
			local mine = false
			for _, j in pairs(remote.call(AC, "jobs", sc.ctrl) or {}) do
				if j.item == ITEM and j.owner == sc.maint.unit_number then mine = true end
			end
			expect(mine, "the walls were not crafted by a job of the level maintainer")
			--- the walls with tags come out with their kills
			for kills, n in pairs(tagged(sc.ctrl)) do
				local key
				for k in pairs(remote.call(NET, "contents", sc.ctrl)) do
					if k:find(ITEM .. "@normal#", 1, true) == 1 and k:find('"kills":' .. kills, 1, true) then key = k end
				end
				local out = game.create_inventory(1)
				local got = key and remote.call(NET, "extract_to", sc.ctrl, out, key, n) or 0
				expect(got == 1 and out[1].valid_for_read and out[1].tags.kills == kills, "the wall with " .. tostring(kills) .. " kills came out as "
					.. serpent.line(out[1].valid_for_read and out[1].tags))
				out.destroy()
			end
			return finish("the Pattern Terminal encodes recipes and a processing output of an item with tags; a recipe switch stores the "
				.. "assembler's wall with tags with them; jobs craft the item and use it from storage and as an input, never one with tags; "
				.. "the interface's Crafting Card and a level maintainer row craft it")
		end
	end

	function T.running(check) check(storage.tagcraft480 and storage.tagcraft480.done, "ME autocrafting of items with tags") end
	return T
end
