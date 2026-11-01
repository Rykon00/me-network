--- Runtime test of me-network issue #623: ME cables never overextend. The underground cable is a pipe-to-ground whose
--- fluid box is only there for the engine's pairing, so a chain of them is one fluid segment; its max_pipeline_extent
--- (prototypes/network.lua, NO_PIPELINE_EXTENT) lifts the engine's cap (320 tiles by default).
--- * On a surface of its own: a drive, LENGTH tiles of underground cable pairs end to end (8 tiles apart, the next pair
---   right after), a drive at the far end; no controller (the graph test's underground case needs none either).
--- * Checked: every pair paired, no underground cable reports "pipeline overextended", the chain is one fluid segment
---   whose extent spans the chain (its box covers the collision boxes: 1124.7 tiles for 1125), and both drives are
---   one ME network with every cable of the chain in it.
--- Loaded by control.lua like lab.lua.

local NET = "gregtorio-me-network"
local UG = "me-underground-cable"
local SURFACE = "me-extent-test"
local PAIRS = 125                         -- 9 tiles per pair: 1125 tiles, far past the default extent of 320
local STEP, GAP = 9, 8                    -- tiles from one pair to the next, between the two ends of a pair
local LENGTH = PAIRS * STEP
local CHECK = 180

--- the test's surface, with concrete along the chain
local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	for x = -32, LENGTH + 32, 32 do s.request_to_generate_chunks({ x, 0 }, 0) end
	s.force_generate_chunk_requests()
	local tiles = {}
	for x = -4, LENGTH + 6 do for y = -3, 2 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	s.set_tiles(tiles)
	return s
end

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup()
		local fails = {}
		local what = "extent"
		local s = surface()
		local st = { pairs = {} }
		storage.extent623 = st
		st.d1 = me_place(s, fails, what, "me-drive", 0.5, 0.5)
		for k = 0, PAIRS - 1 do
			local x = 1 + STEP * k
			local a = me_place(s, fails, what, UG, x + 0.5, 0.5, { direction = defines.direction.west })
			local b = me_place(s, fails, what, UG, x + GAP + 0.5, 0.5, { direction = defines.direction.east })
			st.pairs[#st.pairs + 1] = { a, b }
		end
		st.d2 = me_place(s, fails, what, "me-drive", STEP * PAIRS + 1.5, 0.5)
		return fails
	end

	function T.tick()
		local st = storage.extent623
		if not st or st.done or game.tick < CHECK then return end
		st.done = true
		local problems = {}
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local status_name = {}
		for k, v in pairs(defines.entity_status) do status_name[v] = k end
		local ends, unpaired, over, segments, seg = 0, 0, 0, {}, nil
		for k, pr in ipairs(st.pairs) do
			local a, b = pr[1], pr[2]
			if not (a and a.valid and b and b.valid) then
				expect(false, "pair " .. k .. " is missing")
			else
				if remote.call(NET, "underground_partner", a) ~= b.unit_number then unpaired = unpaired + 1 end
				for _, e in pairs({ a, b }) do
					ends = ends + 1
					if e.status == defines.entity_status.pipeline_overextended then
						over = over + 1
						if over <= 3 then expect(false, "the underground cable at x " .. e.position.x .. " is " .. status_name[e.status]) end
					end
					seg = e.get_fluid_segment_id(1)
					segments[seg] = true
				end
			end
		end
		expect(unpaired == 0, unpaired .. " of " .. PAIRS .. " pairs did not pair")
		expect(over == 0, over .. " of " .. ends .. " underground cables are overextended")
		local nseg = table_size(segments)
		expect(nseg == 1, "the chain is " .. nseg .. " fluid segments, not one")
		local first = st.pairs[1][1]
		local box = first and first.valid and first.get_fluid_segment_extent_bounding_box(1)
		local width = box and (box.right_bottom.x - box.left_top.x) or 0
		expect(width >= LENGTH - 1, "the fluid segment's extent is " .. width .. " tiles wide, the chain " .. LENGTH)
		local d1, d2 = st.d1, st.d2
		local n = d1 and d1.valid and remote.call(NET, "network", d1)
		expect(d1 and d2 and remote.call(NET, "same_network", d1, d2), "the two drives at the ends are not one network")
		expect(n and n.members == 2 + ends, "network " .. serpent.line(n) .. ", expected " .. (2 + ends) .. " members")
		me_report("EXTENT", "ME underground cable extent", problems, PAIRS .. " underground pairs over " .. width
			.. " tiles: none overextended, one fluid segment, one network of " .. tostring(n and n.members) .. " members")
	end

	function T.running(check) check(storage.extent623 and storage.extent623.done, "ME underground cable extent") end
	return T
end
