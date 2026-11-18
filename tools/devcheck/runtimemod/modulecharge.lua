--- Runtime test of me-network issue #748: what charges the ME Wireless Module in an armour's grid. Three characters with
--- a power armour on a surface of their own ("me-modulecharge-test"), the grids left alone for WAIT ticks:
--- * A, a full personal battery and an empty module, no generator: the module charges from the battery (the report: it
---   never did, a battery piece being a buffer like the battery, and the grid moves nothing from buffer to buffer);
--- * B, a generator (the first generator equipment the game has for an armour) and an empty module: the module charges,
---   as before;
--- * C, a full module and an empty personal battery, no generator: the battery stays empty and the module full (nothing
---   draws from the module: its energy is the window's).
--- Loaded by control.lua: require("modulecharge")(H) returns { setup, tick, running }.

local SURFACE = "me-modulecharge-test"
local START, WAIT = 140, 120
local MODULE = "me-wireless-module"

return function(H)
	local me_report = H.me_report
	local T = {}

	local function surface()
		local s = game.surfaces[SURFACE]
		if s then return s end
		s = game.create_surface(SURFACE, { width = 64, height = 64, default_enable_all_autoplace_controls = false,
			autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
				decorative = { treat_missing_as_default = false, settings = {} } } })
		s.request_to_generate_chunks({ 0, 0 }, 1)
		s.force_generate_chunk_requests()
		local tiles = {}
		for x = -10, 10 do for y = -10, 10 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
		s.set_tiles(tiles)
		return s
	end

	--- the name of an equipment of `type` that fits an armour's grid and (a battery) holds the most
	local function equipment_of(type)
		local best, size
		for name, p in pairs(prototypes.equipment) do
			if p.type == type and name ~= MODULE then
				local armor = false
				for _, c in pairs(p.equipment_categories or {}) do if c == "armor" then armor = true end end
				local n = type == "battery-equipment" and (p.energy_source and p.energy_source.buffer_capacity or 0) or 1
				if armor and (not size or n > size) then best, size = name, n end
			end
		end
		return best
	end

	function T.setup()
		surface()
		return {}
	end

	function T.tick()
		local st = storage.modulecharge748
		if st and st.done or game.tick < START then return end
		local s = game.surfaces[SURFACE]
		local function finish(problems, note)
			st.done = true
			me_report("MODULECHARGE", "ME Wireless Module charged in the grid (issue #748)", problems, note)
		end
		if not st then
			st = { problems = {}, chars = {} }
			storage.modulecharge748 = st
			local problems = st.problems
			local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
			if not s then expect(false, "no test surface") return finish(problems) end
			if not prototypes.equipment[MODULE] then return finish(problems, "nothing to check: no ME Wireless Module") end
			local battery, generator = equipment_of("battery-equipment"), equipment_of("generator-equipment")
			st.battery, st.generator = battery, generator
			local function char(i, parts)
				local c = s.create_entity{ name = "character", position = { -6 + 4 * i, 0 }, force = "player" }
				if not c then expect(false, "no character " .. i) return end
				c.get_inventory(defines.inventory.character_armor).insert{ name = "power-armor", count = 1 }
				local grid = c.grid
				if not grid then expect(false, "character " .. i .. " has no grid") return end
				local got = {}
				for _, part in ipairs(parts) do
					local eq = part[1] and grid.put{ name = part[1] }
					if not eq then
						expect(false, "character " .. i .. ": " .. tostring(part[1]) .. " did not go into the grid")
					else
						eq.energy = part[2] and eq.max_energy or 0
						got[#got + 1] = eq.energy
					end
				end
				st.chars[i] = { c = c, at = got }
			end
			char(1, { { battery, true }, { MODULE, false } })
			if generator then char(2, { { generator, false }, { MODULE, false } }) end
			char(3, { { MODULE, true }, { battery, false } })
			st.check = game.tick + WAIT
			return
		end
		if game.tick < st.check then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function energies(i)
			local rec = st.chars[i]
			local grid = rec and rec.c.valid and rec.c.grid
			if not grid then expect(false, "character " .. i .. " or its grid is gone") return nil end
			local out = {}
			for _, eq in pairs(grid.equipment) do out[eq.name] = eq.energy end
			return out
		end
		local notes = {}
		local a = energies(1)
		if a then
			local m, b = a[MODULE] or 0, a[st.battery] or 0
			expect(m > 0, "A: the module took nothing from the full battery (" .. m .. " J)")
			expect(b < st.chars[1].at[1], "A: the battery lost nothing (" .. b .. " J)")
			notes[#notes + 1] = string.format("A: battery -> module %.1f MJ in %d ticks", m / 1e6, WAIT)
		end
		if st.generator then
			local b = energies(2)
			if b then
				expect((b[MODULE] or 0) > 0, "B: the generator did not charge the module (" .. (b[MODULE] or 0) .. " J)")
				notes[#notes + 1] = string.format("B: %s -> module %.1f MJ", st.generator, (b[MODULE] or 0) / 1e6)
			end
		else
			notes[#notes + 1] = "B: no generator equipment for an armour in this game"
		end
		local c = energies(3)
		if c then
			expect((c[st.battery] or 0) == 0, "C: the battery drew " .. (c[st.battery] or 0) .. " J from the module")
			expect((c[MODULE] or 0) == st.chars[3].at[1], "C: the module lost energy (" .. (c[MODULE] or 0) .. " J)")
			notes[#notes + 1] = "C: nothing draws from the module"
		end
		for _, rec in pairs(st.chars) do if rec.c.valid then rec.c.destroy() end end
		st.chars = nil
		finish(problems, table.concat(notes, "; "))
	end

	function T.running(check) check(storage.modulecharge748 and storage.modulecharge748.done, "ME Wireless Module charge") end

	return T
end
