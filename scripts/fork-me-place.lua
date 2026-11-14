--------------------------------------------------------------------------------
--- ME NETWORK: WHAT A SURFACE IS CALLED (issue #713, Space Exploration's zone names)
---
--- A network joined by ME Quantum Bridges spans surfaces, and the windows and messages say where a block stands. The game's
--- name of a surface is its internal one ("nauvis", "spaceship-3"); with Space Exploration a player knows the place by its
--- zone ("Nauvis Orbit", "Calidus Asteroid Belt") or by a spaceship's name. M.name(surface) is what to show:
---   * without Space Exploration: the surface's name, as before;
---   * with it: the name of the surface's zone, asked from its remote interface (get_zone_from_surface_index), guarded
---     (the mod active, the interface and the function there, the call in pcall, the answer a table with a string name);
---   * a surface without a zone (a spaceship in flight has its own surface and is no zone of the remote interface): the
---     display name Space Exploration gave the surface (LuaSurface.localised_name, which carries the ship's name), else the
---     surface's name;
---   * a call that fails: the surface's name, as before.
--- The answer is kept per surface for TTL ticks in `storage.fork_me_place` (the remote call copies the whole zone table, and
--- a window refreshes every second): never asked per tick. It is in `storage`, not in a table of the Lua state, because
--- the names end up in GUI captions, which are part of the game state: two players' games must give the same text.
--- A spaceship can be renamed and a zone too: the entry runs out; a surface that goes takes its entry along.
--- M.gps(position, surface): the map marker of a message, "[gps=x,y,surface]" (the tag needs the surface's own name), and
--- with Space Exploration the place's name after it in brackets.
--------------------------------------------------------------------------------

local M = {}

local SE = "space-exploration"
local TTL = 600                          -- ticks an answer is kept

--- the zone name and type of the surface `index` from Space Exploration, nil without one or when the call fails
local function ask(index)
	local iface = remote.interfaces[SE]
	if not (iface and iface.get_zone_from_surface_index) then return nil end
	local ok, zone = pcall(remote.call, SE, "get_zone_from_surface_index", { surface_index = index })
	if ok and type(zone) == "table" and type(zone.name) == "string" and zone.name ~= "" then return zone.name, zone.type end
	return nil
end

--- the kept answer for `surface`: { n = zone name or false, g = a planet or a moon, t = tick }
local function entry(surface)
	local s = storage.fork_me_place
	if not s then
		s = { names = {}, calls = 0 }
		storage.fork_me_place = s
	end
	local index, now = surface.index, game.tick
	local c = s.names[index]
	if not c or now - c.t >= TTL then
		s.calls = s.calls + 1
		local name, kind = ask(index)
		c = { n = name or false, g = kind == "planet" or kind == "moon", t = now }
		s.names[index] = c
	end
	return c
end

--- what to show for `surface` (a LuaSurface): a string, or a LocalisedString (a spaceship's display name)
function M.name(surface)
	if not script.active_mods[SE] then return surface.name end
	local c = entry(surface)
	if c.n then return c.n end
	return surface.localised_name or surface.name
end

--- issue #729: is `surface` the ground of a planet or a moon of Space Exploration (not an orbit, a belt, deep space or a
--- spaceship in flight)? Without Space Exploration: false. From the same kept answer as the name.
function M.ground(surface)
	if not script.active_mods[SE] then return false end
	return entry(surface).g == true
end

--- the map marker of `position` on `surface` for a message
function M.gps(position, surface)
	local tag = string.format("[gps=%d,%d,%s]", math.floor(position.x), math.floor(position.y), surface.name)
	if not script.active_mods[SE] then return tag end
	return { "", tag, " (", M.name(surface), ")" }
end

--- on_pre_surface_deleted: its entry goes
function M.on_surface_gone(event)
	local s = storage.fork_me_place
	if s and event.surface_index then s.names[event.surface_index] = nil end
end

--- (tests) what a surface is called, and how often Space Exploration was asked
remote.add_interface("me-network-place", {
	name = function(surface_index)
		local surface = game.get_surface(surface_index)
		return surface and M.name(surface) or nil
	end,
	gps = function(surface_index, x, y)
		local surface = game.get_surface(surface_index)
		return surface and M.gps({ x = x, y = y }, surface) or nil
	end,
	calls = function() return storage.fork_me_place and storage.fork_me_place.calls or 0 end,
	ground = function(surface_index)
		local surface = game.get_surface(surface_index)
		return surface ~= nil and M.ground(surface)
	end,
})

return M
