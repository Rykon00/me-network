--- Runtime test of the in-game checks of me-network issue #659 (Task-Ingame #661): the ME window of a ghost, opened as the
--- window code opens it (the ghost's stand-in staged for the player's key, then its normal window opened for a stand-in
--- player with a stand-in GUI: the harness has no player; the "(ghost)" note of the title bar is not checked, the stand-in
--- GUI elements have no get_index_in_parent / swap_children) and built by construction robots, on a surface of its own
--- ("me-ghostbuild-test", concrete; a roboport with robots, a storage chest with the blocks' items):
--- * an ME Interface, ME Import Bus, ME Export Bus, ME Storage Bus and ME Pattern Provider, configured, copied as blueprints
---   and pasted as ghosts: each ghost's window opens on a stand-in with the original's settings (its blueprint tags);
--- * the import bus ghost (wired to a constant combinator): its window has the circuit panel; "Enable/disable" switched on
---   through the panel's check box, a condition, other filters and a Capacity Card set in the window; closed, the card comes
---   back; opened again, the change is still there;
--- * the robots build the ghosts: every block has the original's settings, the import bus the change and the condition, and
---   it waits for the card (no network to give it);
--- * a ghost window open while the robots build its ghost: the session cannot write back any more (what the refresh closes);
---   ended, nothing stays on the hidden surface or in storage;
--- * the hidden surface is hidden for every force; ghosts of the ME Terminal, the controller and a crafting unit open no ME
---   window (the game's ghost window stays).
--- Everything ends before the save at tick 500. Loaded by control.lua: require("ghostbuild")(H) returns { setup, tick, running }.

local IO, AC, SB, CONN, GUI, GW = "gregtorio-me-io", "gregtorio-me-autocraft", "gregtorio-me-storagebus", "gregtorio-me-connector",
	"gregtorio-me-gui", "gregtorio-me-ghostwin"
local SURFACE = "me-ghostbuild-test"
local START, LAST = 120, 470
local KEY = 9661                         -- (the stand-in player's index: the ghost window's session key)
local SIG = { type = "virtual", name = "signal-A" }
local Y_SRC, Y_GHOST = -12.5, 8.5
--- the blocks: name, x, how each is configured (by its remote interface, as its window does)
local BLOCKS = {
	{ "me-network-interface", -12.5, function(e)
		remote.call(IO, "set_interface_config", e, { [1] = { name = "iron-plate", quality = "normal", amount = 50 } }, { [2] = 2 })
		remote.call(IO, "set_interface_priority", e, 3)
	end },
	{ "me-import-bus", -8.5, function(e) remote.call(IO, "set_bus_filters", e, { "iron-plate" }) end },
	{ "me-export-bus", -4.5, function(e) remote.call(IO, "set_bus_filters", e, { "copper-plate", "iron-gear-wheel" }) end },
	{ "me-storage-bus", -0.5, function(e) remote.call(SB, "set_settings", e, { filters = { "copper-plate" }, priority = 4 }) end },
	{ "me-pattern-provider", 3.5, function(e)
		remote.call(AC, "set_priority", e, 7)
		remote.call(AC, "set_blocking", e, "blocking")
	end },
}
local GAME_WINDOWS = { "me-terminal", "me-network-controller", "me-crafting-unit" }

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { width = 160, height = 160, default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, 2)
	s.force_generate_chunk_requests()
	local tiles = {}
	for x = -40, 39 do for y = -32, 31 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	s.set_tiles(tiles)
	return s
end

--- a blueprint (in a script inventory) of `e`, tagged by the mod's blueprint handler (copypaste.lua's copy_of)
local function copy_of(e)
	local b = e.bounding_box
	local inv = game.create_inventory(1)
	inv.insert{ name = "blueprint" }
	local bp = inv[1]
	local mapping = bp.create_blueprint{ surface = e.surface, force = "player",
		area = { { b.left_top.x + 0.1, b.left_top.y + 0.1 }, { b.right_bottom.x - 0.1, b.right_bottom.y - 0.1 } } } or {}
	remote.call(AC, "tag_blueprint", bp, mapping)
	return inv, bp
end

--- the mod's tags of `e` in a blueprint of it
local function signature(e)
	if not (e and e.valid) then return "(none)" end
	local inv, bp = copy_of(e)
	local sig = "(not in the blueprint)"
	for _, be in pairs(bp.get_blueprint_entities() or {}) do
		if be.name == e.name then sig = serpent.line(be.tags or {}) end
	end
	inv.destroy()
	return sig
end

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup()
		local fails = {}
		local what = "ghost windows built by robots"
		local s = surface()
		power(s, fails, what, -10, 0)
		local port = me_place(s, fails, what, "roboport", 0, 0)
		if port then port.insert{ name = "construction-robot", count = 20 } end
		local chest = me_place(s, fails, what, "storage-chest", 3.5, -3.5)
		if chest then
			for _, b in ipairs(BLOCKS) do chest.insert{ name = prototypes.entity[b[1]].items_to_place_this[1].name, count = 2 } end
		end
		for _, b in ipairs(BLOCKS) do me_place(s, fails, what, b[1], b[2], Y_SRC) end
		me_place(s, fails, what, "constant-combinator", -8.5, Y_GHOST + 3)
		storage.ghostbuild661 = { problems = {} }
		return fails
	end

	function T.tick()
		local st = storage.ghostbuild661
		if not st or st.done or game.tick < START then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			if st.inv and st.inv.valid then st.inv.destroy() end
			remote.call(GUI, "stand_in_forget", "ghostbuild")
			me_report("GHOSTBUILD", "ME windows of ghosts built by robots (Task-Ingame #661)", problems, note)
		end
		local s = game.surfaces[SURFACE]
		if not s then expect(false, "no test surface") return finish() end
		local function stand_in()
			remote.call(GUI, "stand_in", "ghostbuild", { main = st.inv, index = KEY, gui = true })
		end
		--- (M.open: the stand-in staged for the player's key, its window opened)
		local function open(ghost)
			stand_in()
			local e = remote.call(GW, "stage", ghost, KEY)
			return e and remote.call(GUI, "stand_in_open_entity", "ghostbuild", e)
		end
		local function standin(name)
			local hs = game.surfaces["me-network-ghost-staging"]
			for _, e in pairs(hs and hs.find_entities_filtered{ name = name } or {}) do
				if remote.call(GW, "is_standin", e) then return e end
			end
		end
		local function close(into)
			remote.call(GUI, "stand_in_close_window", "ghostbuild")
			return remote.call(GW, "unstage", KEY, into)        -- (what Ghost.settle does after the window closed)
		end

		if not st.phase then
			st.inv = game.create_inventory(20)
			--- the originals, configured; their ghosts
			local K = s.find_entity("constant-combinator", { -8.5, Y_GHOST + 3 })
			if K then
				local cb = K.get_or_create_control_behavior()
				if cb.sections_count == 0 then cb.add_section() end
				cb.get_section(1).set_slot(1, { value = { type = SIG.type, name = SIG.name, quality = "normal" }, min = 1 })
			end
			st.sig, st.ghosts = {}, {}
			for i, b in ipairs(BLOCKS) do
				local src = s.find_entity(b[1], { b[2], Y_SRC })
				if not src then expect(false, b[1] .. ": the original is missing") return finish() end
				b[3](src)
				st.sig[i] = signature(src)
				local inv, bp = copy_of(src)
				for _, g in pairs(bp.build_blueprint{ surface = s, force = "player", position = { b[2], Y_GHOST } } or {}) do
					if g.valid and g.ghost_name == b[1] then st.ghosts[i] = g end
				end
				inv.destroy()
				src.destroy{ raise_destroy = true }
				if not st.ghosts[i] then expect(false, b[1] .. ": the blueprint made no ghost") return finish() end
			end
			local w = defines.wire_connector_id.circuit_red
			local ig = st.ghosts[2]
			expect(K and ig.get_wire_connector(w, true).connect_to(K.get_wire_connector(w, true), false),
				"the import bus ghost is not wired to the combinator")
			--- checklist 1: every ghost opens its ME window with the original's settings
			for i, b in ipairs(BLOCKS) do
				expect(remote.call(GW, "window_of_ghost", b[1]) ~= nil, b[1] .. ": its ghost has no ME window")
				local out = open(st.ghosts[i])
				expect(out ~= nil, b[1] .. ": its ghost opened no ME window")
				local e = standin(b[1])
				expect(e ~= nil, b[1] .. ": no stand-in on the hidden surface")
				if e then
					local got = signature(e)
					expect(got == st.sig[i], b[1] .. ": the ghost's window shows " .. got .. ", the original has " .. st.sig[i])
				end
				close(st.inv)
			end
			--- checklist 4 and 2: the import bus ghost's window has the circuit panel; Enable/disable through its check box, a
			--- condition, other filters and a Capacity Card (checklist 5: the card comes back when the window closes)
			open(ig)
			local stand = standin("me-import-bus")
			local side = remote.call(GUI, "stand_in_side", "ghostbuild") or {}
			expect(side.visible and side.circuit, "the wired ghost's window has no circuit panel: " .. serpent.line({ side.visible, side.circuit, side.logistic }))
			side = remote.call(GUI, "stand_in_side", "ghostbuild", "cond_on", true) or {}
			expect(side.states and side.states.fork_me_cond_on == true, "Enable/disable on the ghost's panel: " .. serpent.line(side.states or side))
			if stand then
				expect(remote.call(CONN, "condition", stand)[1] == true, "the panel's check box did not switch the stand-in's condition on")
				remote.call(CONN, "set_condition", stand, true, { first_signal = SIG, comparator = ">", constant = 0 })
				remote.call(IO, "set_bus_filters", stand, { "copper-plate", "fluid/water" })
				local hand = game.create_inventory(1)
				hand[1].set_stack{ name = "me-capacity-card", count = 1 }
				local why = remote.call(IO, "bus_card_click", stand, 1, hand[1], hand, false)
				expect(why == nil and not hand[1].valid_for_read, "the stand-in took no card: " .. tostring(why))
				hand.destroy()
				remote.call(GW, "sync", KEY)                         -- (what Ghost.settle does after a GUI event)
			else
				expect(false, "the import bus ghost's window has no stand-in")
			end
			local given = close(st.inv)
			expect(given == 1 and st.inv.get_item_count("me-capacity-card") == 1, "the card did not come back: " .. tostring(given) .. " items")
			--- checklist 3: opened again, the change is still there
			open(ig)
			stand = standin("me-import-bus")
			local b = stand and remote.call(IO, "get_bus", stand)
			expect(b and serpent.line(b.filters) == serpent.line({ "copper-plate", "fluid/water" }),
				"the ghost's window opened again shows the filters " .. serpent.line(b and b.filters))
			local c = stand and remote.call(CONN, "condition", stand) or {}
			expect(c[1] == true and c[2] and c[2].first_signal and c[2].first_signal.name == "signal-A",
				"the ghost's window opened again shows the condition " .. serpent.line(c))
			close(st.inv)
			--- checklist 10: the ghosts of the terminal, the controller and a crafting unit keep the game's window
			for k, name in ipairs(GAME_WINDOWS) do
				local g = s.create_entity{ name = "entity-ghost", inner_name = name, position = { -20.5 + 5 * k, 20.5 }, force = "player" }
				if g then
					stand_in()
					expect(remote.call(GW, "window_of_ghost", name) == nil and remote.call(GW, "stage", g, KEY) == nil
						and remote.call(GUI, "stand_in_open_entity", "ghostbuild", g) == nil, name .. ": its ghost opens an ME window")
					g.destroy()
				else
					expect(false, name .. ": no ghost")
				end
			end
			--- checklist 9: the hidden surface
			local hs = game.surfaces["me-network-ghost-staging"]
			for _, force in pairs(game.forces) do
				expect(hs and force.get_surface_hidden(hs), "the hidden surface is not hidden for the force " .. force.name)
			end
			--- checklist 7: the export bus's window stays open while the robots build
			expect(open(st.ghosts[3]) ~= nil, "the export bus ghost opened no ME window")
			st.phase = "robots"
			return
		end

		if st.phase == "robots" then
			local all = true
			for i = 1, #BLOCKS do if st.ghosts[i].valid then all = false end end
			if not all and game.tick < LAST then return end
			for i, b in ipairs(BLOCKS) do expect(not st.ghosts[i].valid, b[1] .. ": the robots did not build its ghost") end
			--- checklist 7: the open window's session cannot write back once its ghost is built; ended, nothing stays
			expect(remote.call(GW, "sync", KEY) == false, "the export bus window's session still writes into a built ghost")
			close(st.inv)
			local cnt = remote.call(GW, "counts")
			expect(cnt.entities == 0 and cnt.sessions == 0 and cnt.units == 0, "left after the windows: " .. serpent.line(cnt))
			--- checklist 2 and 4: the built blocks
			for i, b in ipairs(BLOCKS) do
				local e = s.find_entity(b[1], { b[2], Y_GHOST })
				if not e then expect(false, b[1] .. ": not built")
				elseif i == 2 then
					local bus = remote.call(IO, "get_bus", e)
					expect(bus and serpent.line(bus.filters) == serpent.line({ "copper-plate", "fluid/water" }),
						"the import bus built by a robot has the filters " .. serpent.line(bus and bus.filters))
					local c = remote.call(CONN, "condition", e)
					expect(c[1] == true and c[2] and c[2].first_signal and c[2].first_signal.name == "signal-A" and c[2].constant == 0,
						"the import bus built by a robot has the condition " .. serpent.line(c))
					local d = remote.call(GUI, "bus_data", e) or {}
					expect(type(d.want) == "table" and next(d.want) ~= nil, "the import bus built by a robot does not wait for its card: "
						.. serpent.line(d.want))
				else
					local got = signature(e)
					expect(got == st.sig[i], b[1] .. " built by a robot: " .. got .. ", the original " .. st.sig[i])
				end
			end
			return finish("5 ghosts opened with their settings, a change with a condition and a card built by robots (tick " .. game.tick .. ")")
		end
	end

	function T.running(check) check(storage.ghostbuild661 and storage.ghostbuild661.done, "ME windows of ghosts built by robots") end

	return T
end
