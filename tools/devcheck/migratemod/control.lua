--- Test helper for `devcheck.py migrate`. On the new map made with the older version (on_init) it builds a
--- small ME network with two loaded 1k fluid drives and a loaded drive outside any network. After the save
--- is loaded with the working copy it checks that every drive kept its contents, then destroys a drive: its
--- fluid must go into the other drive and the recovered fluid (issue #26) with nothing lost.
--- Results are logged as DEVCHECK-MIGRATE-FLUIDS lines. Versions without fluid drives are skipped.
local F = "gregtorio-me-fluids"
local DRIVE = "me-fluid-drive-1k"
local Y = 40
local TOTAL = { water = 40000, chlorine = 10000 }      -- drive 1: 32000 water, drive 2: 8000 water + 10000 chlorine
local LONE = { water = 500 }

local function near(a, b) return math.abs((a or 0) - (b or 0)) <= 1e-3 end
local function same(a, b)
	for k, v in pairs(a) do if not near(v, b[k]) then return false end end
	for k, v in pairs(b) do if not near(v, a[k]) then return false end end
	return true
end

script.on_init(function()
	storage.state = "skipped"
	if not (remote.interfaces[F] and prototypes.entity[DRIVE] and prototypes.entity["me-controller"]) then
		log("DEVCHECK-MIGRATE-SETUP skipped (no ME fluid drives in this version)")
		return
	end
	local s = game.surfaces[1]
	s.request_to_generate_chunks({ 0, Y }, 2)
	s.request_to_generate_chunks({ 120, Y }, 1)
	s.force_generate_chunk_requests()
	local function place(name, x, y)
		return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
	end
	local eei = place("electric-energy-interface", 0, Y)
	eei.power_production = 1e6
	eei.electric_buffer_size = 1e7
	place("substation", 3, Y)
	place("me-controller", 6, Y)
	local d1, d2 = place(DRIVE, 8.5, Y + 3.5), place(DRIVE, 10.5, Y + 3.5)
	local lone = place(DRIVE, 120.5, Y + 0.5)
	local ok = near(remote.call(F, "insert", d1, "water", TOTAL.water), TOTAL.water)
		and near(remote.call(F, "insert", d1, "chlorine", TOTAL.chlorine), TOTAL.chlorine)
	remote.call(F, "unpack_drive", lone, { fork_me_fluids = LONE })
	storage.drives = {}
	for _, d in pairs({ d1, d2, lone }) do
		storage.drives[#storage.drives + 1] = { entity = d, contents = remote.call(F, "drive", d).contents }
	end
	storage.state = ok and "ready" or "setup-failed"
	log("DEVCHECK-MIGRATE-SETUP " .. (ok and "ok" or "failed"))
end)

--- runs after every mod or prototype change: tells the check which path ran
script.on_configuration_changed(function() storage.config_changed = true end)

script.on_nth_tick(30, function()
	if storage.checked then return end
	storage.checked = true
	if storage.state ~= "ready" then
		log("DEVCHECK-MIGRATE-FLUIDS " .. (storage.state == "skipped" and "skipped" or "failed (" .. tostring(storage.state) .. ")"))
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	for i, d in pairs(storage.drives) do
		expect(d.entity.valid, "drive " .. i .. " is gone")
		if d.entity.valid then
			local now = remote.call(F, "drive", d.entity)
			expect(now and same(now.contents, d.contents), "drive " .. i .. " holds " .. serpent.line(now and now.contents) .. ", before " .. serpent.line(d.contents))
		end
	end
	local d1, d2 = storage.drives[1].entity, storage.drives[2].entity
	if d1.valid and d2.valid then
		expect(same(remote.call(F, "totals", d2), TOTAL), "network holds " .. serpent.line(remote.call(F, "totals", d2)))
		if remote.interfaces[F].recovered then
			--- drive 2 has room for 14000 of drive 1's water, the other 18000 are recovered
			d1.die()
			local totals, pool = remote.call(F, "totals", d2), remote.call(F, "recovered", d2.surface, "player")
			expect(same(totals, { water = 22000, chlorine = 10000 }), "network after the destroyed drive " .. serpent.line(totals))
			expect(same(pool, { water = 18000 }), "recovered fluid " .. serpent.line(pool))
		end
	end
	for _, p in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL " .. p) end
	log("DEVCHECK-MIGRATE-FLUIDS " .. (#problems == 0 and "ok" or "failed")
		.. " (on_configuration_changed " .. (storage.config_changed and "ran" or "did not run") .. ")")
end)
