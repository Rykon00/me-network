--- Runtime test of me-network issue #796: undo (Ctrl+Z) of a removed ME block keeps its settings. The game makes the
--- ghost of an undone removal from the undo record, and puts the record's tags on it; scripts/fork-me-undo.lua takes the
--- tags a blueprint of the block would carry when a player removes it and sets them on the record a tick later.
--- The harness has no player and so no undo stack (the record itself was measured in a client, see the issue), so the
--- test covers what leads up to it, through the remote `gregtorio-me-undo`. On a surface of its own ("me-undo-test"):
--- * an interface with rows, sides and a priority: the tags undo would give (tags_of) are the tags of a real blueprint of
---   it; a blank interface and a cable have none;
--- * removed by player 1: one removal waits, with the block's name, place and those tags; removed by nobody (robots,
---   scripts), a cable and a blank interface: nothing waits;
--- * the waiting tags are a copy: the block is destroyed in the same tick (as a mined block's records are emptied) and
---   the tags still hold its rows and sides;
--- * an interface marked for deconstruction by a script (no player): nothing waits;
--- * on the next tick the queue is empty (player 1 does not exist here: dropped, no error).
--- Loaded by control.lua: require("undo")(H) returns { setup, tick, running }.

local IO, AC, UN = "gregtorio-me-io", "gregtorio-me-autocraft", "gregtorio-me-undo"
local SURFACE = "me-undo-test"
local START = 175
local IFACE, CABLE = "me-network-interface", "me-cable"
local SIDES = { [2] = 2, [3] = "off", [4] = 3 }

return function(H)
	local me_report = H.me_report
	local T = {}

	function T.setup()
		local s = game.create_surface(SURFACE, { width = 64, height = 64, default_enable_all_autoplace_controls = false,
			autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
				decorative = { treat_missing_as_default = false, settings = {} } } })
		s.always_day = true
		s.request_to_generate_chunks({ 0, 0 }, 1)
		s.force_generate_chunk_requests()
		local tiles = {}
		for x = -20, 19 do for y = -20, 19 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
		s.set_tiles(tiles)
		storage.undo796 = {}
		return {}
	end

	local function second_fluid()
		for _, name in ipairs({ "steam", "crude-oil", "lubricant", "sulfuric-acid" }) do
			if prototypes.fluid[name] then return name end
		end
		for name in pairs(prototypes.fluid) do
			if name ~= "water" then return name end
		end
	end

	local function run(s)
		local problems = {}
		local function bad(text) problems[#problems + 1] = text end
		local fluid = second_fluid()
		local function build(name, x, y)
			return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
		end
		local e = build(IFACE, 0.5, 0.5)
		local blank = build(IFACE, 4.5, 0.5)
		local cable = build(CABLE, 8.5, 0.5)
		if not (e and blank and cable and fluid) then
			bad("the blocks were not built")
			return problems
		end
		remote.call(IO, "set_interface_config", e, { [1] = { name = "iron-plate", quality = "normal", amount = 50 },
			[2] = { type = "fluid", name = "water", amount = 2000 }, [3] = { type = "fluid", name = fluid, amount = 1000 } }, SIDES)
		remote.call(IO, "set_interface_priority", e, 3)
		--- the tags of a real blueprint of the interface
		local inv = game.create_inventory(1)
		inv.insert{ name = "blueprint" }
		local bp = inv[1]
		local mapping = bp.create_blueprint{ surface = s, force = "player", area = { { 0.1, 0.1 }, { 0.9, 0.9 } } } or {}
		remote.call(AC, "tag_blueprint", bp, mapping)
		local be = (bp.get_blueprint_entities() or {})[1]
		local want = be and be.tags
		inv.destroy()
		if type(want) ~= "table" or not want.fork_me_interface then
			bad("the blueprint of the interface has no tags: " .. serpent.line(want))
			return problems
		end
		local got = remote.call(UN, "tags_of", e)
		if serpent.line(got) ~= serpent.line(want) then
			bad("the tags for undo are not a blueprint's: " .. serpent.line(got) .. " (expected " .. serpent.line(want) .. ")")
		end
		if remote.call(UN, "tags_of", blank) ~= nil then bad("a blank interface has tags for undo: " .. serpent.line(remote.call(UN, "tags_of", blank))) end
		if remote.call(UN, "tags_of", cable) ~= nil then bad("a cable has tags for undo") end

		local function waiting() return #remote.call(UN, "queued") end
		if waiting() ~= 0 then bad("removals wait before the test: " .. waiting()) end
		remote.call(UN, "removed", e, nil)
		remote.call(UN, "removed", cable, 1)
		remote.call(UN, "removed", blank, 1)
		if waiting() ~= 0 then bad("a removal by nobody, of a cable or of a blank interface waits: " .. serpent.line(remote.call(UN, "queued"))) end
		--- (marked by a script: the mod's own handler runs, without a player)
		blank.order_deconstruction("player")
		e.order_deconstruction("player")
		if waiting() ~= 0 then bad("a block marked by a script waits: " .. waiting()) end
		e.cancel_deconstruction("player")
		remote.call(UN, "removed", e, 1)
		local q = remote.call(UN, "queued")
		local r = q[1]
		if #q ~= 1 or not r then
			bad("the interface removed by player 1 does not wait: " .. serpent.line(q))
			return problems
		end
		if not (r.p == 1 and r.name == IFACE and r.x == 0.5 and r.y == 0.5 and r.s == s.index and r.tick == game.tick) then
			bad("the waiting removal names another block: " .. serpent.line({ r.p, r.name, r.x, r.y, r.s, r.tick }))
		end
		if serpent.line(r.tags) ~= serpent.line(want) then bad("the waiting tags are not the blueprint's: " .. serpent.line(r.tags)) end
		--- the block goes in the same tick (its records are emptied): the waiting tags are a copy
		e.destroy{ raise_destroy = true }
		local after = remote.call(UN, "queued")[1]
		if not after or serpent.line(after.tags) ~= serpent.line(want) then
			bad("the waiting tags changed when the block went: " .. serpent.line(after and after.tags))
		end
		return problems
	end

	function T.tick()
		local st = storage.undo796
		if not st or st.done or game.tick < START then return end
		local s = game.surfaces[SURFACE]
		if not st.problems then
			st.problems = run(s)
			return
		end
		local problems = st.problems
		local left = #remote.call(UN, "queued")
		if left ~= 0 then problems[#problems + 1] = "a removal still waits a tick later (no such player: it is dropped): " .. left end
		for _, x in pairs(s.find_entities()) do
			if x.valid and x.type ~= "character" then x.destroy{ raise_destroy = true } end
		end
		st.done = true
		me_report("UNDO", "Undo keeps an ME block's settings (issue #796)", problems,
			"the tags for undo are a blueprint's tags of the block; a block removed by a player waits with a copy of them for"
				.. " its undo record; nothing waits for a cable, a blank block, or a removal without a player")
	end

	function T.running(check) check(storage.undo796 and storage.undo796.done, "Undo keeps an ME block's settings (issue #796)") end
	return T
end
