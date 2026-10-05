--- Runtime test of the removal from the cable graph (me-network issues #38 lever 5 and #43, scripts/fork-me-network.lua
--- split_parts): a grid of cables with holes and a few drives is built, then members are removed one at a time, and after
--- each removal the networks the engine reports must be the connected components an independent search of the grid finds:
--- the same members in each network (one id per component, none shared), the drives and cells and bytes of each (so a part
--- that took a drive away is recomputed and one that took none is not wrong), and the largest part keeping the id of the
--- network that was split (a tie: the part with the smaller position). Loaded by control.lua: require("graph")(H)
--- returns { setup, tick, running }.

local NET = "gregtorio-me-network"
local GX, GY, W, H = 330, -190, 15, 15
local CHECK = 500
local REMOVALS = 70

return function(Hh)
	local me_place, me_report = Hh.me_place, Hh.me_report
	local T = {}

	local seed = 12345
	local function rnd(n)                                      -- a small deterministic generator
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed % n
	end

	--- the tiles of the grid: present (a cable, or a drive), by "i,j"
	local function build_plan()
		local plan = { present = {}, drive = {} }
		local keys = {}
		for i = 0, W - 1 do
			for j = 0, H - 1 do
				if rnd(100) < 74 then
					local k = i .. "," .. j
					plan.present[k] = true
					keys[#keys + 1] = k
				end
			end
		end
		for _ = 1, 4 do                                         -- four of the tiles are drives
			local k = keys[rnd(#keys) + 1]
			plan.drive[k] = true
		end
		return plan
	end

	function T.setup(s)
		local fails = {}
		local plan = build_plan()
		local ents = {}
		for k in pairs(plan.present) do
			local i, j = k:match("^(%-?%d+),(%-?%d+)$")
			i, j = tonumber(i), tonumber(j)
			local x, y = GX + i + 0.5, GY + j + 0.5
			if plan.drive[k] then
				ents[k] = me_drive(s, fails, "graph", x, y, { ["iron-plate"] = 100 }, "1k")
			else
				ents[k] = me_place(s, fails, "graph", "me-cable", x, y)
			end
		end
		storage.graph43_scene = { plan = plan, ents = ents }
		return fails
	end

	local function neighbours(i, j)
		return { { i + 1, j }, { i - 1, j }, { i, j + 1 }, { i, j - 1 } }
	end

	--- the connected components of the tiles that are still there: { { keys... }, ... }, each sorted by key order
	local function components(present)
		local seen, out = {}, {}
		local keys = {}
		for k in pairs(present) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do
			if not seen[k] then
				local comp, queue, q = {}, { k }, 1
				seen[k] = true
				while queue[q] do
					local c = queue[q]
					q = q + 1
					comp[#comp + 1] = c
					local i, j = c:match("^(%-?%d+),(%-?%d+)$")
					for _, n in ipairs(neighbours(tonumber(i), tonumber(j))) do
						local nk = n[1] .. "," .. n[2]
						if present[nk] and not seen[nk] then
							seen[nk] = true
							queue[#queue + 1] = nk
						end
					end
				end
				out[#out + 1] = comp
			end
		end
		return out
	end

	function T.tick()
		local st = storage.graph43
		if not st then
			if game.tick < CHECK then return end
			st = { problems = {}, done = false }
			storage.graph43 = st
		end
		if st.done then return end
		local problems = st.problems
		local sc = storage.graph43_scene
		local function fail(what) problems[#problems + 1] = what end
		if not sc then
			fail("the grid was not built")
		else
			local plan, ents = sc.plan, sc.ents
			local present = {}
			for k in pairs(plan.present) do present[k] = true end
			local ids = {}                                          -- tile -> network id before the removal
			local function stats_of(k)
				local e = ents[k]
				return e and e.valid and remote.call(NET, "network", e) or nil
			end
			--- the check after a removal: the engine's networks against the components of the tiles that are left
			local function check(step, removed_id, removed_key)
				local comps = components(present)
				local seen_ids = {}
				local drive_bytes
				--- the parts of the network that was split: the largest of them (not a tie) must keep its id
				local largest, largest_n, tie = nil, -1, false
				for ci, comp in ipairs(comps) do
					if removed_id and ids[comp[1]] == removed_id then
						if #comp > largest_n then largest, largest_n, tie = ci, #comp, false
						elseif #comp == largest_n then tie = true end
					end
				end
				for ci, comp in ipairs(comps) do
					local first = stats_of(comp[1])
					if not first then
						fail("step " .. step .. ": no network for " .. comp[1])
						return false
					end
					local drives = 0
					for _, k in ipairs(comp) do
						if plan.drive[k] then drives = drives + 1 end
						local r = stats_of(k)
						if not r or r.id ~= first.id then
							fail("step " .. step .. " (removed " .. removed_key .. "): " .. k .. " is not in the network of " .. comp[1])
							return false
						end
					end
					if seen_ids[first.id] then
						fail("step " .. step .. ": two components share the network " .. first.id)
						return false
					end
					seen_ids[first.id] = true
					if first.members ~= #comp then
						fail("step " .. step .. ": network " .. first.id .. " has " .. first.members .. " members, the component " .. #comp)
						return false
					end
					if first.drives ~= drives or first.cells ~= 4 * drives then
						fail("step " .. step .. ": network " .. first.id .. " has " .. first.drives .. " drives and " .. first.cells
							.. " cells, expected " .. drives .. " and " .. 4 * drives)
						return false
					end
					if drives == 0 then
						if first.bytes ~= 0 then fail("step " .. step .. ": a network without drives has " .. first.bytes .. " bytes") return false end
					else
						local per = first.bytes / drives
						drive_bytes = drive_bytes or per
						if per ~= drive_bytes then
							fail("step " .. step .. ": network " .. first.id .. " has " .. first.bytes .. " bytes for " .. drives
								.. " drives (" .. drive_bytes .. " per drive elsewhere)")
							return false
						end
					end
					--- the largest part keeps the id of the network that was split
					if ci == largest and not tie and first.id ~= removed_id then
						fail("step " .. step .. ": the largest part (" .. #comp .. ") lost the id " .. removed_id .. ", it has " .. first.id)
						return false
					end
				end
				for ci, comp in ipairs(comps) do
					local r = stats_of(comp[1])
					for _, k in ipairs(comp) do ids[k] = r.id end
				end
				return true
			end
			local all = {}
			for k in pairs(present) do all[#all + 1] = k end
			table.sort(all)
			if check(0, nil, "-") then
				for k in pairs(present) do
					local r = stats_of(k)
					ids[k] = r and r.id
				end
				local splits = 0
				for step = 1, REMOVALS do
					local keys = {}
					for k in pairs(present) do keys[#keys + 1] = k end
					table.sort(keys)
					if #keys <= 3 then break end
					local k = keys[rnd(#keys) + 1]
					local removed_id = ids[k]
					local before = #components(present)
					local e = ents[k]
					present[k] = nil
					if e and e.valid then e.destroy{ raise_destroy = true } end
					if #components(present) > before then splits = splits + 1 end
					if not check(step, removed_id, k) then break end
				end
				st.splits = splits
				--- the graph built again from the entities (on_configuration_changed, issue #43) gives the same networks
				remote.call(NET, "rebuild")
				for k in pairs(present) do ids[k] = nil end
				if check(REMOVALS + 1, nil, "rebuild") then
					local list_ok, why = remote.call(NET, "sweep_list_ok")
					if not list_ok then fail("after the rebuild: the sweep list: " .. tostring(why)) end
				end
				if splits < 8 then fail("only " .. splits .. " of the removals split a network: the test does not exercise the split") end
			end
		end
		st.done = true
		me_report("GRAPH", "ME graph removal test", problems, REMOVALS .. " removals from a grid of cables and drives; " .. tostring(st.splits)
			.. " split a network; the networks are the components, with their drives, cells and bytes, the largest keeping the id")
	end

	function T.running(check) check(storage.graph43 and storage.graph43.done, "ME graph removal") end
	return T
end
