--- Runtime test of me-network issue #414: the storage cells above 256k and the Singularity cell (AE2-Unofficial's). Two
--- networks, each with a controller and a drive:
---   * a 16384k cell takes iron plates up to its byte limit, (16384 * 1024 - 131072) * 8 items of one type, and a 4096k and a
---     1024k cell their limits; their specs are AE2-Unofficial's (k * 1024 bytes, k * 8 bytes per type, 63 types);
---   * a Singularity cell takes 10^12 iron plates and gives them back, holds one type only (copper plates are refused), and a
---     taken-out cell keeps its count in its tags;
---   * the fluid cells of the new tiers have their specs; the Superluminal Speed Card is made from a 1024k component.
--- Loaded by control.lua: require("bigcells")(H) returns { setup, tick, running }.

local NET = "gregtorio-me-network"
local BX, BY = -150, 90               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 120
local TIERS = { { "1024k", 1024 }, { "4096k", 4096 }, { "16384k", 16384 } }

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "big cells"
		power(s, fails, what, BX, BY)
		power(s, fails, what, BX, BY + 6)
		for i, y in ipairs({ BY, BY + 6 }) do
			local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, y)
			local drive = me_place(s, fails, what, "me-drive", BX + 8.5, y - 0.5)
			H.me_connect(fails, what .. " " .. i, { ctrl, drive })
		end
		return fails
	end

	function T.tick()
		local st = storage.bigcells414
		if (st and st.done) or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.bigcells414 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local function report()
			me_report("BIGCELLS", "Storage cells above 256k and the Singularity cell", problems, "1024k, 4096k and 16384k cells "
				.. "to their limits, a Singularity cell of 10^12 items and one type, kept in its tags; fluid cells; Superluminal recipe")
		end
		local c1, c2 = s.find_entity("me-network-controller", { BX + 7, BY }), s.find_entity("me-network-controller", { BX + 7, BY + 6 })
		local d1, d2 = s.find_entity("me-drive", { BX + 8.5, BY - 0.5 }), s.find_entity("me-drive", { BX + 8.5, BY + 5.5 })
		if not (c1 and c2 and d1 and d2) then expect(false, "entities missing") return report() end
		local inv = game.create_inventory(1)
		local function put(drive, name, slot)
			inv[1].set_stack{ name = name, count = 1 }
			return remote.call(NET, "insert_cell", drive, inv[1], slot)
		end
		local specs = remote.call(NET, "cell_specs") or {}

		--- the item cells above 256k, one at a time in drive 1
		for i, t in ipairs(TIERS) do
			local name, k = "me-" .. t[1] .. "-storage-cell", t[2]
			local sp = specs[name] or {}
			expect(sp.bytes == k * 1024 and sp.per_type == k * 8 and sp.types == 63, name .. " spec: " .. line(sp))
			put(d1, name, i)
			local want = (k * 1024 - k * 8) * 8
			local got = remote.call(NET, "insert", c1, "iron-plate", want + 1000)
			expect(got == want, name .. ": " .. got .. " iron plates went in, its limit is " .. want)
			expect(remote.call(NET, "count", c1, "iron-plate") == want, name .. ": the network counts "
				.. remote.call(NET, "count", c1, "iron-plate"))
			expect(remote.call(NET, "extract", c1, "iron-plate", want) == want, name .. ": not all came out")
			local out = game.create_inventory(1)
			remote.call(NET, "take_cell", d1, i, out[1])
			out.destroy()
		end
		--- the fluid cells of the new tiers
		for _, t in ipairs(TIERS) do
			local sp = specs["me-" .. t[1] .. "-fluid-storage-cell"] or {}
			expect(sp.kind == "fluid" and sp.bytes == t[2] * 1024 and sp.per_type == t[2] * 8, t[1] .. " fluid cell spec: " .. line(sp))
		end

		--- the Singularity cell in drive 2
		local sname = "me-singularity-storage-cell"
		local sp = specs[sname] or {}
		expect(sp.types == 1 and sp.bytes == 2 ^ 50 and sp.per_type == 4096, "Singularity spec: " .. line(sp))
		put(d2, sname, 1)
		local N12 = 1e12
		local got = remote.call(NET, "insert", c2, "iron-plate", N12)
		expect(got == N12, "the Singularity cell took " .. string.format("%.0f", got) .. " of 10^12 iron plates")
		expect(remote.call(NET, "count", c2, "iron-plate") == N12, "the network counts "
			.. string.format("%.0f", remote.call(NET, "count", c2, "iron-plate")))
		expect(remote.call(NET, "insert", c2, "copper-plate", 10) == 0, "a second type went into the Singularity cell")
		expect(remote.call(NET, "extract", c2, "iron-plate", 1000) == 1000, "1000 plates came out")
		--- taken out and put back: the count travels in the cell's tags
		local out = game.create_inventory(1)
		remote.call(NET, "take_cell", d2, 1, out[1])
		expect(out[1].valid_for_read and out[1].name == sname, "the Singularity cell came out of the drive")
		expect(remote.call(NET, "count", c2, "iron-plate") == 0, "the network still counts the taken-out cell's plates")
		remote.call(NET, "insert_cell", d2, out[1], 1)
		expect(remote.call(NET, "count", c2, "iron-plate") == N12 - 1000, "after putting it back the network counts "
			.. string.format("%.0f", remote.call(NET, "count", c2, "iron-plate")))
		out.destroy()
		inv.destroy()

		--- the Superluminal Speed Card's recipe (AE2-Unofficial's, with the 1024k component)
		local r = prototypes.recipe["me-superluminal-speed-card"]
		local ok = false
		for _, ing in pairs(r and r.ingredients or {}) do
			if ing.name == "me-1024k-storage-component" and ing.amount == 1 then ok = true end
		end
		expect(ok or script.active_mods["gregtorio-continued"] ~= nil, "Superluminal Speed Card recipe: " .. line(r and r.ingredients))
		return report()
	end

	function T.running(check) check(storage.bigcells414 and storage.bigcells414.done, "Storage cells above 256k and the Singularity cell") end

	return T
end
