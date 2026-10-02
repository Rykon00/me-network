--------------------------------------------------------------------------------
--- ME NETWORK: the one-time hand-over from Gregtorio Continued (Gregtorio issue #83, its docs/SPLIT.md)
---
--- Up to 0.4.x Gregtorio Continued contained this network, so a save of it keeps the network's script state in
--- gregtorio-continued's storage. Its later versions depend on this mod and offer that state once through the
--- remote interface "gregtorio-me-handover" (take: the tables, cleared on its side, its ME windows closed and its
--- render objects destroyed). This mod takes it in on_init (it is new in such a save; the engine runs a new mod's
--- on_init before the other mods' on_load and on_configuration_changed), so its own on_configuration_changed works
--- on it like Gregtorio's did: graph rebuild, migrations of old networks, the modules.
--- The tables and their keys are the same in both mods, nothing is converted. Each side computes a fingerprint of
--- every table (an order-independent walk; entities as their unit numbers, shared tables as references): this side
--- compares them and logs ME-NETWORK-HANDOVER lines.
--------------------------------------------------------------------------------

local M = {}

M.TABLES = { "fork_me_net", "fork_me_io", "fork_me_sbus", "fork_me_fsbus", "fork_ae2", "fork_me_fluids",
	"fork_me_terminal", "fork_me_gui_bypass", "fork_me_migrate", "fork_me_migrate_fluids" }
local INTERFACE = "gregtorio-me-handover"

--- the same function is in Gregtorio's scripts/fork-me-handover.lua: keep them equal
function M.fingerprint(root)
	local ids, n = {}, 0
	local h1, h2, len = 0, 0, 0
	local function feed(s)
		len = len + #s
		for i = 1, #s do
			local b = s:byte(i)
			h1 = (h1 * 31 + b) % 4294967291
			h2 = (h2 * 131 + b) % 2147483629
		end
	end
	local function scalar(v)
		local t = type(v)
		if t == "number" then return "n" .. string.format("%.17g", v) end
		if t == "string" then return "s" .. #v .. ":" .. v end
		if t == "boolean" then return v and "T" or "F" end
		if t == "userdata" then
			local ok, name = pcall(function() return v.object_name end)
			if ok and name == "LuaEntity" then
				if not v.valid then return "E-invalid" end
				return "E" .. (v.unit_number or (v.name .. "@" .. v.position.x .. "," .. v.position.y))
			end
			return "U" .. tostring(ok and name or "?")
		end
		return "?" .. t
	end
	local walk
	walk = function(v)
		if type(v) ~= "table" then feed(scalar(v)) return end
		if ids[v] then feed("R" .. ids[v]) return end
		n = n + 1
		ids[v] = n
		local keys = {}
		for k in pairs(v) do
			keys[#keys + 1] = { k = k, s = type(k) == "table" and "t" or scalar(k) }
		end
		table.sort(keys, function(a, b) return a.s < b.s end)
		feed("{")
		for _, k in pairs(keys) do
			if type(k.k) == "table" then walk(k.k) else feed(k.s) end
			feed("=")
			walk(v[k.k])
			feed(";")
		end
		feed("}")
	end
	if root == nil then return "nil" end
	walk(root)
	return string.format("%d/%d/%d/%d", len, n, h1, h2)
end

--- takes Gregtorio's state if it has any; returns true when something was taken
function M.pull()
	local iface = remote.interfaces[INTERFACE]
	if not (iface and iface.take and iface.pending) then return false end
	if not remote.call(INTERFACE, "pending") then return false end
	for _, k in pairs(M.TABLES) do
		if storage[k] ~= nil and k ~= "fork_me_gui_bypass" then
			--- cannot happen through the documented paths (a me-network game gets an old Gregtorio's state)
			log("ME-NETWORK-HANDOVER: refused: this save has ME state in both mods (" .. k .. "); Gregtorio's stays where it is")
			game.print({ "", "ME Network: ", { "fork-me-net.handover-conflict" } })
			return false
		end
	end
	local got = remote.call(INTERFACE, "take")
	local bad = {}
	for _, k in pairs(M.TABLES) do
		local t = got.tables[k]
		storage[k] = t
		local fp = M.fingerprint(t)
		log("ME-NETWORK-HANDOVER: got " .. k .. " " .. fp)
		if fp ~= (got.fingerprints[k] or "nil") then
			bad[#bad + 1] = k .. " (" .. tostring(got.fingerprints[k]) .. " -> " .. fp .. ")"
		end
	end
	--- the drive lights are drawn again by this mod (Gregtorio destroyed its own)
	local net = storage.fork_me_net
	if net and net.drives then
		net.dirty = net.dirty or {}
		for unit, d in pairs(net.drives) do
			d.leds = {}
			net.dirty[unit] = true
		end
	end
	storage.me_network_handover = { from = got.from, tick = game.tick, ok = #bad == 0 }
	log("ME-NETWORK-HANDOVER: " .. (#bad == 0 and "ok" or ("MISMATCH " .. table.concat(bad, ", "))) .. " (from " .. tostring(got.from) .. ")")
	return true
end

return M
