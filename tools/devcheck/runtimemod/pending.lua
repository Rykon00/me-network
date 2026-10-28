--- Runtime test of me-network issue #558: the patterns a pasted or built pattern provider waits for. A source provider (on no
--- network) holds four processing patterns A, B, C, D; its blueprint settings are the tags of the providers built here:
---   * P1, revived from a ghost on a network with neither blanks nor encoded patterns: all four wait, its custom status
---     (yellow) says so and the provider data counts them;
---   * an encoded B stored in the network: filled from it (taken out of the network), three wait;
---   * an inventory with an encoded C and one blank, the network with an encoded D: C from the inventory's encoded one, D from
---     the network's, A from the inventory's blank (encoded patterns first, so nothing is encoded twice); none waits, the
---     status is gone;
---   * P2, revived with two blanks in the network: two filled, two wait; two more blanks: none waits;
---   * P3, built on no network for a player whose inventory holds an encoded A and three blanks (the build handler with an
---     inventory): A from the encoded one, B, C, D from the blanks, nothing left in the inventory.
--- Loaded by control.lua: require("pending")(H) returns { setup, tick, running }.

local NET, AC, PT = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal"
local BX, BY = 250, 20                -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 160
local BLANK, ENCODED = "me-blank-pattern", "me-encoded-pattern"
local DEFS = {
	A = { kind = "processing", inputs = { { key = "iron-plate", amount = 1 } }, outputs = { { key = "iron-stick", amount = 2 } } },
	B = { kind = "processing", inputs = { { key = "copper-plate", amount = 1 } }, outputs = { { key = "copper-cable", amount = 2 } } },
	C = { kind = "processing", inputs = { { key = "stone", amount = 2 } }, outputs = { { key = "stone-brick", amount = 1 } } },
	D = { kind = "processing", inputs = { { key = "iron-plate", amount = 2 } }, outputs = { { key = "iron-gear-wheel", amount = 1 } } },
}
local ORDER = { "A", "B", "C", "D" }

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end

	--- one encoded pattern of `def` into `target` (an inventory)
	local function encode_into(target, def)
		local tmp = game.create_inventory(2)
		tmp[1].set_stack{ name = BLANK, count = 1 }
		remote.call(PT, "encode_def", tmp, nil, def)
		local ok = tmp[2].valid_for_read and target.insert(tmp[2]) == 1
		tmp.destroy()
		return ok
	end

	function T.setup(s)
		local fails = {}
		local what = "pending patterns"
		H.power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local drive = H.me_drive(s, fails, what, BX + 7.5, BY - 0.5, { ["iron-plate"] = 10 })
		H.cable_row(s, fails, BX + 8, BX + 20, BY - 1)
		if not (ctrl and drive) then fails[#fails + 1] = what .. ": the network was not built" end
		--- the source provider, on no network (far from the cables)
		local src = me_place(s, fails, what, "me-pattern-provider", BX + 0.5, BY + 10.5)
		if src then
			local defs = {}
			for i, k in ipairs(ORDER) do defs[i] = DEFS[k] end
			if give_patterns(src, defs, fails) ~= 4 then fails[#fails + 1] = what .. ": the source provider has not four patterns" end
		end
		return fails
	end

	function T.tick()
		local st = storage.pending558
		if game.tick < START or (st and st.done) then return end
		if not st then
			st = { problems = {} }
			storage.pending558 = st
		end
		local s = game.surfaces[1]
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("PENDING", "Pattern provider waiting for patterns (issue #558)", problems, "four waiting patterns with a "
				.. "yellow status; filled from an encoded pattern of the network, then an inventory's encoded one, the network's "
				.. "encoded one and the inventory's blank in that order; blanks of the network; a build with an inventory's "
				.. "encoded pattern and blanks")
		end
		local ctrl = s.find_entity("me-network-controller", { BX + 6, BY })
		local src = s.find_entity("me-pattern-provider", at(0, 10))
		if not (ctrl and src) then expect(false, "entities missing") return finish() end
		local tags = { fork_me_provider = remote.call(AC, "provider_settings", src) }
		local function count(name)                                       -- (every key of the item: encoded patterns have tags)
			local n = 0
			for key, c in pairs(remote.call(NET, "contents", ctrl)) do
				if key == name or key:sub(1, #name + 1) == name .. "@" then n = n + c end
			end
			return n
		end
		local function ids()                                             -- (the pattern ids of the four, from the source)
			local out = {}
			local info = remote.call(AC, "provider_info", src)
			for i, k in ipairs(ORDER) do out[k] = info.slots[i] and info.slots[i].id end
			return out
		end
		local id = ids()
		local function filled(p)                                          -- letters of the filled slots, sorted
			local info = remote.call(AC, "provider_info", p) or { slots = {} }
			local out = {}
			for _, k in ipairs(ORDER) do
				for slot = 1, 4 do
					local d = info.slots[slot]
					if d and not d.pending and d.id == id[k] then out[#out + 1] = k end
				end
			end
			return table.concat(out), info.pending
		end
		local function status(p)
			local cs = remote.call(AC, "custom_status", p)
			return cs and cs.label and cs.label[1] == "fork-me-pattern.status-waiting" and cs.diode == defines.entity_status_diode.yellow
				and tonumber(cs.label[2]) or (cs and -1) or 0                   -- (read back, a parameter is a string)
		end
		local function revive(x)
			local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-pattern-provider", position = at(x, -2),
				force = "player", tags = tags }
			local _, p = ghost.revive{ raise_revive = true }
			return p
		end
		local function store_encoded(def)
			local tmp = game.create_inventory(1)
			local ok = encode_into(tmp, def) and remote.call(NET, "insert_stack", ctrl, tmp[1]) == 1
			tmp.destroy()
			return ok
		end

		--- P1: nothing to fill from
		expect(count(BLANK) == 0, "the network has blanks at the start: " .. count(BLANK))
		local p1 = revive(10)
		expect(p1 and remote.call(NET, "same_network", p1, ctrl), "P1 is not on the network")
		if not p1 then return finish() end
		local f, n = filled(p1)
		expect(f == "" and n == 4 and status(p1) == 4, "P1 without sources: filled " .. f .. ", waiting " .. tostring(n)
			.. ", status " .. tostring(status(p1)))
		--- an encoded B in the network
		expect(store_encoded(DEFS.B), "storing an encoded B")
		remote.call(AC, "fill_pending", p1, nil)
		f, n = filled(p1)
		expect(f == "B" and n == 3 and status(p1) == 3 and count(ENCODED) == 0, "P1 with an encoded B in the network: filled " .. f
			.. ", waiting " .. tostring(n) .. ", status " .. tostring(status(p1)) .. ", encoded left " .. count(ENCODED))
		--- an inventory with an encoded C and a blank, the network with an encoded D
		local inv = game.create_inventory(10)
		encode_into(inv, DEFS.C)
		inv.insert{ name = BLANK, count = 1 }
		expect(store_encoded(DEFS.D), "storing an encoded D")
		remote.call(AC, "fill_pending", p1, inv)
		f, n = filled(p1)
		expect(f == "ABCD" and n == 0 and status(p1) == 0 and inv.is_empty() and count(ENCODED) == 0 and count(BLANK) == 0,
			"P1 with an inventory (encoded C, a blank) and an encoded D in the network: filled " .. f .. ", waiting " .. tostring(n)
			.. ", status " .. tostring(status(p1)) .. ", inventory " .. serpent.line(inv.get_contents()) .. ", network encoded "
			.. count(ENCODED) .. ", blanks " .. count(BLANK))
		--- P2: two blanks in the network, then two more
		remote.call(NET, "insert", ctrl, BLANK, 2)
		local p2 = revive(13)
		if not p2 then expect(false, "P2 was not built") return finish() end
		f, n = filled(p2)
		expect(#f == 2 and n == 2 and status(p2) == 2 and count(BLANK) == 0, "P2 with two blanks: filled " .. f .. ", waiting "
			.. tostring(n) .. ", status " .. tostring(status(p2)))
		remote.call(NET, "insert", ctrl, BLANK, 2)
		remote.call(AC, "fill_pending", p2, nil)
		f, n = filled(p2)
		expect(f == "ABCD" and n == 0 and status(p2) == 0 and count(BLANK) == 0, "P2 with two more blanks: filled " .. f
			.. ", waiting " .. tostring(n) .. ", status " .. tostring(status(p2)))
		--- P3: built for a player whose inventory holds an encoded A and three blanks, on no network
		inv.clear()
		encode_into(inv, DEFS.A)
		inv.insert{ name = BLANK, count = 3 }
		local p3 = s.create_entity{ name = "me-pattern-provider", position = at(0, 14), force = "player" }
		if not p3 then expect(false, "P3 was not built") inv.destroy() return finish() end
		remote.call(AC, "built", p3, tags, nil, inv)
		f, n = filled(p3)
		expect(f == "ABCD" and n == 0 and inv.is_empty() and status(p3) == 0, "P3 built with an encoded A and three blanks: filled "
			.. f .. ", waiting " .. tostring(n) .. ", inventory " .. serpent.line(inv.get_contents()))
		inv.destroy()
		return finish()
	end

	function T.running(check) check(storage.pending558 and storage.pending558.done, "Pattern provider waiting for patterns") end
	return T
end
