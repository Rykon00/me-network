--- Runtime test of me-network issue #538: what construction needs, offered by the ME Logistic Interface in Automatic mode
--- (scripts/fork-me-logistic-construction.lua), on a surface of its own ("me-lifbuild-test", concrete):
--- * Q (construction robots): an ME network with stone walls, fast transport belts and speed modules, which the base has none
---   of. A blueprint of 8 walls pasted as ghosts (build_blueprint, raise_built), 5 transport belts marked for upgrade
---   (order_upgrade: the upgrade planner's event) and an item request proxy for 2 speed modules in an assembling machine
---   (raise_built): the construction robots build all of it from the interface.
--- * R (no robots, so the ghosts stay): 6 wall ghosts (raise_built) are counted; a seventh made without an event is counted
---   once the safety net's rescan has passed (it is not right after); 3 ghosts destroyed drop out (on_object_destroyed) and
---   the stock follows the count; 2 belts marked for upgrade, one cancelled: 1 fast belt counted.
--- The save at tick 500 lies between the checks; the records are in `storage`. Loaded by control.lua like lifauto.lua.

local NET, LIF = "gregtorio-me-network", "gregtorio-me-logistic-interface"
local SURFACE = "me-lifbuild-test"
local NAME = "me-logistic-interface"
local X = { Q = 0, R = 200 }
local SILENT, T1, T2 = 30, 400, 1150   -- (the ghost without an event, the checks; the save at 500 lies between them; the
                                        -- harness calls the tests every 10 ticks)

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { width = 600, height = 160, default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	local tiles = {}
	for _, x0 in pairs(X) do
		s.request_to_generate_chunks({ x0, 0 }, 3)
		for x = x0 - 40, x0 + 39 do for y = -32, 31 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	end
	s.force_generate_chunk_requests()
	s.set_tiles(tiles)
	return s
end

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	local function me_net(s, fails, what, x0, items, members)
		local ctrl = me_place(s, fails, what, "me-network-controller", x0 + 5, -6)
		local drive = H.me_drive(s, fails, what, x0 + 6.5, -6.5, items)
		local list = { ctrl, drive }
		for _, m in ipairs(members) do list[#list + 1] = m end
		H.me_connect(fails, what, list)
		return drive
	end

	local function wall_ghost(s, x, y, raise)
		return s.create_entity{ name = "entity-ghost", inner_name = "stone-wall", position = { x, y }, force = "player",
			raise_built = raise }
	end

	function T.setup()
		local fails = {}
		local what = "logistic interface construction"
		local s = surface()
		local items = { ["stone-wall"] = 50, ["fast-transport-belt"] = 20, ["speed-module"] = 4 }
		--- Q
		local q = X.Q
		power(s, fails, what, q - 7, 0)
		local port = me_place(s, fails, what, "roboport", q, 0)
		if port then port.insert{ name = "construction-robot", count = 30 } end
		local lq = me_place(s, fails, what, NAME, q + 4.5, 3.5)
		me_net(s, fails, what, q, items, { lq })
		local bpi = game.create_inventory(1)
		bpi.insert{ name = "blueprint" }
		local bp = bpi[1]
		local walls = {}
		for k = 1, 8 do walls[k] = { entity_number = k, name = "stone-wall", position = { k - 4.5, 0.5 } } end
		bp.set_blueprint_entities(walls)
		local ghosts = bp.build_blueprint{ surface = s, force = "player", position = { q, 12 }, raise_built = true } or {}
		if #ghosts ~= 8 then fails[#fails + 1] = what .. ": the blueprint made " .. #ghosts .. " ghosts" end
		bpi.destroy()
		for k = 0, 4 do
			local b = me_place(s, fails, what, "transport-belt", q - 10.5 + k, 8.5, { direction = defines.direction.east })
			if b then b.order_upgrade{ target = "fast-transport-belt", force = "player" } end
		end
		local asm = me_place(s, fails, what, "assembling-machine-2", q - 8.5, -8.5)
		if asm then
			local MOD = defines.inventory.crafter_modules
			s.create_entity{ name = "item-request-proxy", position = asm.position, force = "player", target = asm, raise_built = true,
				modules = { { id = { name = "speed-module", quality = "normal" },
					items = { in_inventory = { { inventory = MOD, stack = 0 }, { inventory = MOD, stack = 1 } } } } } }
		end
		--- R
		local r = X.R
		power(s, fails, what, r - 7, 0)
		me_place(s, fails, what, "roboport", r, 0)
		local lr = me_place(s, fails, what, NAME, r + 4.5, 3.5)
		me_net(s, fails, what, r, items, { lr })
		for k = 1, 6 do wall_ghost(s, r - 10.5 + k, 12.5, true) end
		for k = 0, 1 do
			local b = me_place(s, fails, what, "transport-belt", r - 10.5 + k, 8.5, { direction = defines.direction.east })
			if b then b.order_upgrade{ target = "fast-transport-belt", force = "player" } end
		end
		local b2 = s.find_entity("transport-belt", { r - 9.5, 8.5 })
		if b2 then b2.cancel_upgrade("player") end
		remote.call(LIF, "set_accept", lr, false)                      -- (Q takes the replaced belts back)
		storage.lifbuild538 = { problems = {} }
		return fails
	end

	local function finish(st, problems)
		st.done = true
		me_report("LIFBUILD", "ME logistic interface construction supply (issue #538)", problems, "a blueprint's ghosts, an "
			.. "upgrade of belts and a module request built from the interface; counted by events, a ghost without one by the "
			.. "rescan, destroyed ghosts and a cancelled upgrade dropped, the stock follows the count")
	end

	function T.tick()
		local st = storage.lifbuild538
		if not st or st.done then return end
		local tick = game.tick
		if tick ~= T1 and tick ~= T2 and tick ~= SILENT then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[SURFACE]
		local lr = s.find_entity(NAME, { X.R + 4.5, 3.5 })
		local lid = lr and remote.call(LIF, "info", lr).lid
		local function tally() return lid and remote.call(LIF, "construction", lid) or {} end
		if tick == SILENT then
			wall_ghost(s, X.R - 2.5, 12.5, false)                         -- (made without an event: not counted now)
			local t = tally()
			expect(t["stone-wall"] == 6 and t["fast-transport-belt"] == 1, "R: counted by events " .. serpent.line(t)
				.. " (want 6 walls, 1 fast belt)")
			return
		end
		local provider = lr and remote.call(LIF, "chests", lr).provider
		local function stock(name) return provider and provider.valid and provider.get_item_count(name) or -1 end
		if tick == T1 then
			local t = tally()
			expect(t["stone-wall"] == 7, "R: the ghost without an event not counted by the rescan: " .. serpent.line(t))
			expect(stock("stone-wall") == 7 and stock("fast-transport-belt") == 1, "R: the stock " .. stock("stone-wall")
				.. " walls, " .. stock("fast-transport-belt") .. " fast belts (want 7, 1)")
			local gone = 0
			for _, g in pairs(s.find_entities_filtered{ name = "entity-ghost", area = { { X.R - 10, 12 }, { X.R - 7, 13 } } }) do
				g.destroy()
				gone = gone + 1
			end
			expect(gone == 3, "R: " .. gone .. " ghosts destroyed, not 3")
			return
		end
		--- T2
		local t = tally()
		expect(t["stone-wall"] == 4 and stock("stone-wall") == 4, "R: after 3 ghosts went: counted " .. tostring(t["stone-wall"])
			.. ", stock " .. stock("stone-wall") .. " (want 4, 4)")
		local q = X.Q
		local walls = #s.find_entities_filtered{ name = "stone-wall", area = { { q - 5, 11 }, { q + 5, 14 } } }
		local fast = #s.find_entities_filtered{ name = "fast-transport-belt", area = { { q - 11, 8 }, { q - 5, 9 } } }
		local asm = s.find_entity("assembling-machine-2", { q - 8.5, -8.5 })
		local mods = asm and asm.get_inventory(defines.inventory.crafter_modules).get_item_count("speed-module") or -1
		local lq = s.find_entity(NAME, { q + 4.5, 3.5 })
		expect(walls == 8 and fast == 5 and mods == 2, "Q: built " .. walls .. " walls, " .. fast .. " fast belts, " .. mods
			.. " modules (want 8, 5, 2)")
		expect(lq and remote.call(NET, "count", lq, "stone-wall") == 42 and remote.call(NET, "count", lq, "speed-module") == 2,
			"Q: the network has " .. (lq and remote.call(NET, "count", lq, "stone-wall") or -1) .. " walls, "
			.. (lq and remote.call(NET, "count", lq, "speed-module") or -1) .. " modules (want 42, 2)")
		local qt = lq and remote.call(LIF, "construction", remote.call(LIF, "info", lq).lid) or {}
		expect(next(qt) == nil, "Q: still counted after the build: " .. serpent.line(qt))
		finish(st, problems)
	end

	function T.running(check) check(storage.lifbuild538 and storage.lifbuild538.done, "ME logistic interface construction supply (issue #538)") end

	return T
end
