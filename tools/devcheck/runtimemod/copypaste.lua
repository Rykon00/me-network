--- Runtime test of me-network issue #383: the copy-paste tool (Ctrl+C, Ctrl+X, Ctrl+V) keeps the settings of every
--- configurable block. The game's copy is a blueprint that the handler of on_player_setup_blueprint tags (the stack of the
--- event since Factorio 2.0.34), pasted as ghosts with those tags, built by a player or a robot (the tags come with the
--- build event) or pasted over a block that stands there already. Every block below is configured, and its "signature"
--- (its entity in a blueprint of it, tags and the game's own settings, without position and number; the level
--- maintainer's empty rows left out) must be the same after each path:
--- * blueprint: a copy built on free ground as ghosts and revived (what #378 tested for five blocks);
--- * ghost copy: the ghosts of a paste copied again before anything built them (the copy holds ghosts), pasted and revived;
--- * paste over: the copy pasted over a blank block of the same kind that stands there already. The game makes no ghost
---   and raises no event (Factorio 2.0), so the block kept its blank settings (the step that lost them, issue #383; the
---   row "over, game only" records it); the mod's on_pre_build handler (scripts/fork-me-pasteover.lua, called here as the
---   event calls it, the harness has no player) gives the block the tags' settings;
--- * cut: the copy revived after the original was mined (Ctrl+X);
--- * ghost window (issue #659): the copy pasted as a ghost whose ME window is opened: the window's stand-in on the hidden
---   surface has the original's settings, the ghost keeps them when the window writes them back, and the block revived
---   from it has them; nothing stays on the hidden surface or in the mod's storage when the window is closed. And a change
---   made in a ghost's window arrives in the block built from the ghost (GHOSTWIN).
--- And the landing of the paste handler: a blueprint of the whole row (blocks of 1x1, 2x2 and 3x3) built at positions
--- on and off the tile grid in the four directions: every ghost stands where pasteover.landing puts its entity.
--- No network: the settings belong to the blocks, not to a network. Everything is built, checked and taken away in one tick.
--- Loaded by control.lua like lab.lua.

local IO, NET, AC = "gregtorio-me-io", "gregtorio-me-network", "gregtorio-me-autocraft"
local SB, C, MON, EM = "gregtorio-me-storagebus", "gregtorio-me-circuit", "gregtorio-me-monitor", "gregtorio-me-emitter"
local PO = "gregtorio-me-pasteover"
local CONN = "gregtorio-me-connector"
local BX, BY = -300, 180                 -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local STEP = 4                           -- tiles between two blocks of a row
local ROWS = { source = 0, blueprint = 6, ghost = 12, ghostcopy = 18, over = 24, raw = 30, cut = 36, mixed = 42, ghostwin = 48 }
local GW = "gregtorio-me-ghostwin"      -- (issue #659: the ME window of a ghost)
--- the landing check's second blueprint: entities of other sizes, two of them turned (a 1x2 pump facing east, a bus facing
--- west), so the area it covers has an even side; the ones the game lacks (another mod removed them) are left out
local MIXED = { { "assembling-machine-1", 1.5, 1.5 }, { "accumulator", 5, 1 }, { "pump", 8, 1, defines.direction.east },
	{ "me-import-bus", 10.5, 0.5, defines.direction.west }, { "iron-chest", 12.5, 2.5 } }
local LAND = { x = BX + 30, y = BY + 90 }   -- (the landing check: the row, turned, reaches 30 tiles around it)
local START = 60

local function cond(cb) cb.circuit_condition = { first_signal = { type = "item", name = "iron-plate" }, comparator = ">", constant = 5 } end
--- issue #628: the circuit condition of the buses, the interface and the provider (kept by the script, in their tags)
local function wired(e, on, second)
	remote.call(CONN, "set_condition", e, on, { first_signal = { type = "virtual", name = "signal-B" }, comparator = "<=",
		constant = 17, second_signal = second and { type = "item", name = "copper-plate" } or nil })
	--- issue #639: the logistic condition too (in the same tag)
	remote.call(CONN, "set_logistic", e, true, { first_signal = { type = "item", name = "iron-plate" }, comparator = ">",
		constant = 9, second_signal = second and { type = "item", name = "copper-plate" } or nil })
end
--- the blocks and how each is configured (by its remote interface, as its window does)
local BLOCKS = {
	{ "me-network-interface", function(e)
		remote.call(IO, "set_interface_config", e, { [1] = { name = "iron-plate", quality = "normal", amount = 50 },
			[2] = { type = "fluid", name = "water", amount = 2345 } }, { [2] = 2, [4] = "off" })
		remote.call(IO, "set_interface_priority", e, 3)
		wired(e, true)
	end },
	{ "me-import-bus", function(e) remote.call(IO, "set_bus_filters", e, { "iron-plate", "fluid/water" }) wired(e, true, true) end },
	{ "me-export-bus", function(e) remote.call(IO, "set_bus_filters", e, { "copper-plate", "iron-gear-wheel" }) end },
	{ "me-storage-bus", function(e)
		remote.call(SB, "set_settings", e, { filters = { "copper-plate" }, priority = 4 })
		wired(e, false)                                                                                -- (set, but off)
	end },
	{ "me-level-maintainer", function(e)
		remote.call(C, "set_maintainer", e, "iron-gear-wheel", 1234, false)
		remote.call(C, "set_logistic", e, true, { first_signal = { type = "item", name = "copper-plate" }, comparator = "<", constant = 3 })   -- (#639)
	end },
	{ "me-circuit-interface", function(e) remote.call(C, "set_circuit_filters", e, { "iron-plate", "fluid/water" }) end },
	{ "me-toggle-bus", function(e) cond(e.get_or_create_control_behavior()) end },
	{ "me-inverted-toggle-bus", function(e) cond(e.get_or_create_control_behavior()) end },
	{ "me-storage-monitor", function(e) remote.call(MON, "set", e, "iron-plate", true) end },
	{ "me-conversion-monitor", function(e) remote.call(MON, "set", e, "copper-plate", true) end },
	{ "me-throughput-monitor", function(e) remote.call(MON, "set", e, "iron-plate", true, "hour") end },
	{ "me-level-emitter", function(e) remote.call(EM, "set", e, { key = "iron-plate", amount = 1000, mode = "low" }) end },
	{ "me-advanced-level-emitter", function(e)                                                                  -- (issue #443)
		remote.call(EM, "set", e, { rows = { { key = "iron-plate", amount = 10 }, false, { key = "fluid/water", amount = 99, inverted = true } },
			logic = "and" })
	end },
	{ "me-pattern-provider", function(e)
		remote.call(AC, "set_priority", e, 7)
		remote.call(AC, "set_blocking", e, "blocking")
		wired(e, true)
	end },
	{ "me-drive", function(e) remote.call(NET, "set_priority", e, 5) end },
	{ "me-chest", function(e) remote.call(NET, "set_priority", e, -2) end },
	{ "me-io-port", function(e) remote.call("gregtorio-me-ioport", "set_mode", e, "fill") end },       -- (issue #386)
	{ "me-quantum-bridge", function(e) remote.call("gregtorio-me-qbridge", "set_frequency", e, 1234) end },   -- (issue #385, 3x3)
	{ "me-wireless-link", function(e) remote.call("gregtorio-me-qbridge", "set_frequency", e, 4321) end },   -- (issue #384)
	--- issue #663: the ME Logistic Interface (issue #531), every setting away from a blank block's (built since #537: Automatic)
	{ "me-logistic-interface", function(e)
		local LIF = "gregtorio-me-logistic-interface"
		remote.call(LIF, "set_row", e, "offer", 2, "iron-plate", 70)
		remote.call(LIF, "set_row", e, "request", 1, "copper-plate", 30)
		remote.call(LIF, "set_accept", e, false)
		remote.call(LIF, "set_filter", e, "iron-gear-wheel")
		remote.call(LIF, "set_auto", e, false)
		remote.call(LIF, "set_mode", e, "manual")
	end },
}

--- the centre of block `i` in a row (by the size of its prototype)
local function spot(name, i, row)
	local p = prototypes.entity[name]
	local w, h = p.tile_width or 1, p.tile_height or 1
	return { BX + (i - 1) * STEP + w / 2, BY + ROWS[row] + h / 2 }
end

--- a blueprint (in a script inventory) of the entities in `area`, tagged by the mod's blueprint handler (the same code the
--- event's handler runs). Returns the inventory (destroy it) and its stack.
local function copy_of(s, area)
	local inv = game.create_inventory(1)
	inv.insert{ name = "blueprint" }
	local bp = inv[1]
	local mapping = bp.create_blueprint{ surface = s, force = "player", area = area } or {}
	remote.call(AC, "tag_blueprint", bp, mapping)
	return inv, bp
end

local function area_of(e)
	local b = e.bounding_box
	return { { b.left_top.x + 0.1, b.left_top.y + 0.1 }, { b.right_bottom.x - 0.1, b.right_bottom.y - 0.1 } }
end

--- the level maintainer writes its five rows once it has been rebuilt from tags (empty ones and batch 0 included):
--- the same settings, another spelling; an electric energy interface's buffer and power use (the wireless link's, issue
--- #384) are set by the runtime from the distance to its partner, no setting
local RUNTIME_STATE = { buffer_size = true, power_usage = true, power_production = true }
local function normal(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do
		if RUNTIME_STATE[k] then goto skip end
		if k == "rows" and type(v) == "table" then
			local rows = {}
			for _, r in ipairs(v) do
				if type(r) == "table" and r.key then      -- (issue #443: an empty row of the advanced emitter is false)
					local c = normal(r)
					if c.batch == 0 then c.batch = nil end
					rows[#rows + 1] = c
				end
			end
			out[k] = rows
		else
			out[k] = normal(v)
		end
		::skip::
	end
	return out
end

--- the block's entity in a blueprint of it, without its number and position (tags and the game's own settings)
local function signature(e)
	if not (e and e.valid) then return "(none)" end
	local inv, bp = copy_of(e.surface, area_of(e))
	local sig = "(not in the blueprint)"
	for _, be in pairs(bp.get_blueprint_entities() or {}) do
		if be.name == e.name then
			be.entity_number, be.position = nil, nil
			sig = serpent.line(normal(be))
		end
	end
	inv.destroy()
	return sig
end

--- build the blueprint `bp` with its centre at `at`; revive the ghosts unless `keep`. Returns the entity named `name`
--- built (or the ghost) and the number of ghosts.
local function paste(s, bp, at, name, keep)
	local ghosts = bp.build_blueprint{ surface = s, force = "player", position = at } or {}
	local found
	for _, g in pairs(ghosts) do
		if g.valid and g.name == "entity-ghost" and g.ghost_name == name then
			if keep then found = g
			else
				local _, e = g.revive{ raise_revive = true }
				found = e
			end
		end
	end
	return found, #ghosts
end

--- the landing check: the blueprint of the source row built at `at` in direction `d`; every ghost must stand where the
--- paste handler puts its blueprint entity. Returns the problems.
local function landing(s, bp, at, d)
	local problems = {}
	local want = remote.call(PO, "landings", bp, at, d)
	local ghosts = bp.build_blueprint{ surface = s, force = "player", position = at, direction = d } or {}
	if #ghosts < table_size(want) then
		problems[#problems + 1] = "landing at " .. serpent.line(at) .. " direction " .. d .. ": " .. #ghosts .. " ghosts of " .. table_size(want)
	end
	local at_ghost = {}                               -- (issue #412: where the blocks' ghosts stand)
	for _, g in pairs(ghosts) do
		if g.valid and g.ghost_name ~= "me-circuit-connector" then at_ghost[g.position.x .. ":" .. g.position.y] = true end
	end
	for _, g in pairs(ghosts) do
		if g.valid and g.ghost_name == "me-circuit-connector" then
			--- issue #628: the blocks take their wires themselves; a blueprint has no connector any more
			problems[#problems + 1] = "a blueprint holds an old circuit connector at " .. serpent.line(g.position)
			g.destroy()
		elseif g.valid then
			local p = want[g.ghost_name]
			if not (p and math.abs(p.x - g.position.x) < 0.01 and math.abs(p.y - g.position.y) < 0.01) then
				problems[#problems + 1] = "landing of " .. g.ghost_name .. " at " .. serpent.line(at) .. " direction " .. d
					.. ": the ghost at " .. serpent.line(g.position) .. ", the handler says " .. serpent.line(p)
			end
			g.destroy()
		end
	end
	return problems
end

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	--- the blocks are built in the tick of the test and taken away in it (circuit interfaces and emitters share their
	--- budgets with the other tests)
	local function build(s)
		local fails = {}
		for _, m in ipairs(MIXED) do
			if prototypes.entity[m[1]] then
				me_place(s, fails, "copy-paste", m[1], BX + m[2], BY + ROWS.mixed + m[3], m[4] and { direction = m[4] } or nil)
			end
		end
		for i, b in ipairs(BLOCKS) do
			for _, row in ipairs({ "source", "over", "raw" }) do              -- (the blocks a paste goes over: blank)
				local p = spot(b[1], i, row)
				me_place(s, fails, "copy-paste", b[1], p[1], p[2])
			end
		end
		return fails
	end

	--- me-network issue #519: settings paste through the game, the script's path (LuaEntity.copy_settings). The game pastes
	--- between two blocks only when their prototypes allow it (prototypes/paste.lua; an electric energy interface copies
	--- nothing while its allow_copy_paste is false), and raises on_entity_settings_pasted only for a player: copy_settings
	--- without one copies the game's own settings and raises nothing. Issue #527: the ME Quantum Bridge and the ME Wireless
	--- Link are electric energy interfaces that the game cannot paste for a player ("Not operable"), so they keep the flag
	--- off and the mod's own keys paste them (PASTEKEYS below, the player's path). Here copy_settings must paste nothing
	--- onto them (a marked power production of the source must not arrive: with it, the game would copy the source's power
	--- use and buffer too, which the handler does not repair), and the handler, called as the event calls it, copies the
	--- frequency between two blocks of the same kind only. The other blocks have no settings of the game's to copy:
	--- devcheck check covers their lists.
	local QB, PY, MARK = "gregtorio-me-qbridge", BY + 130, 123   -- (MARK: a power production no bridge or link has)
	local function game_paste(s)
		local problems = {}
		local B, L = "me-quantum-bridge", "me-wireless-link"
		local function put(name, x) return me_place(s, problems, "settings paste", name, BX + x, PY) end
		local a, b, c, d = put(B, 1.5), put(B, 6.5), put(L, 11.5), put(L, 14.5)
		local function gone() for _, e in pairs({ a, b, c, d }) do if e and e.valid then e.destroy{ raise_destroy = true } end end end
		if not (a and b and c and d) then gone() return problems end
		local function freq(e) local i = remote.call(QB, "info", e) return i and i.freq end
		local function near(x, y) return math.abs(x - y) <= 1e-6 * math.max(1, math.abs(y)) end
		local function paste(src, dst, what)
			src.power_production = MARK
			dst.copy_settings(src)
			if dst.power_production ~= 0 then
				problems[#problems + 1] = what .. ": the game pasted the power settings (allow_copy_paste, prototypes/paste.lua KEYS)"
				dst.power_production = 0
			end
			src.power_production = 0
			remote.call(QB, "paste", src, dst)
		end
		local function power(e, watts, what)
			if not (near(e.power_usage * 60, watts) and near(e.electric_buffer_size, math.max(watts * 2, 1))) then
				problems[#problems + 1] = ("%s: power use %.0f W, buffer %.0f J (its own: %.0f W, %.0f J)"):format(what,
					e.power_usage * 60, e.electric_buffer_size, watts, math.max(watts * 2, 1))
			end
		end
		local function want(e, f, what)
			if freq(e) ~= f then problems[#problems + 1] = what .. ": frequency " .. tostring(freq(e)) .. ", not " .. f end
		end
		local dx, dy = c.position.x - d.position.x, c.position.y - d.position.y
		local bridge_w, link_w = remote.call(QB, "drain", B), remote.call(QB, "drain", L, math.sqrt(dx * dx + dy * dy))
		remote.call(QB, "set_frequency", a, 1234)
		paste(a, b, "bridge onto bridge")
		want(b, 1234, "bridge onto bridge")
		power(b, bridge_w, "bridge onto bridge")
		remote.call(QB, "set_frequency", c, 4321)
		paste(c, d, "link onto link")
		want(d, 4321, "link onto link")
		power(d, link_w, "link onto link (a pair)")
		paste(a, d, "bridge onto link")
		want(d, 4321, "bridge onto link")
		power(d, link_w, "bridge onto link")
		paste(c, b, "link onto bridge")
		want(b, 1234, "link onto bridge")
		power(b, bridge_w, "link onto bridge")
		gone()
		return problems
	end

	--- me-network issue #527: settings paste of the ME Quantum Bridge and the ME Wireless Link by the mod's copy and paste
	--- keys (scripts/fork-me-paste-keys.lua), the player's path. The harness has no player: the keys' handlers are called
	--- through the remote with a stand-in player (an empty hand) and the block as player.selected. The frequency goes from a
	--- bridge onto a bridge and from a link onto a link with the game's sounds and a flying text, never from a bridge onto a
	--- link or back; a copy over another block forgets the source, a copy over nothing keeps it, a block of another force
	--- is neither copied nor pasted onto, and a source that is gone pastes nothing.
	local PK, KY = "gregtorio-me-paste-keys", PY + 6
	local function keys_paste(s)
		local problems = {}
		local B, L = "me-quantum-bridge", "me-wireless-link"
		local function put(name, x) return me_place(s, problems, "paste keys", name, BX + x, KY) end
		local a, b, c, d, chest = put(B, 1.5), put(B, 6.5), put(L, 11.5), put(L, 14.5), put("iron-chest", 17.5)
		local function gone()
			for _, e in pairs({ a, b, c, d, chest }) do if e and e.valid then e.destroy{ raise_destroy = true } end end
		end
		if not (a and b and c and d and chest) then gone() return problems end
		local function freq(e) local i = remote.call(QB, "info", e) return i and i.freq end
		local function set(e, f) remote.call(QB, "set_frequency", e, f) end
		--- `key` ("copy" or "paste") over `e`: it must be done (or not), with the game's sound (and a flying text)
		local function press(key, e, done, what, force)
			local r = remote.call(PK, key, 1, e, force)
			if r.done ~= done then
				problems[#problems + 1] = what .. ": " .. key .. (done and " did nothing" or " was done")
			elseif done then
				local seen = key == "copy" and "utility/entity_settings_copied"
					or "utility/entity_settings_pasted,fork-me-paste.settings-pasted"
				if table.concat(r.seen, ",") ~= seen then
					problems[#problems + 1] = what .. ": the player got " .. table.concat(r.seen, ",") .. ", not " .. seen
				end
			end
		end
		local function want(e, f, what)
			if freq(e) ~= f then problems[#problems + 1] = what .. ": frequency " .. tostring(freq(e)) .. ", not " .. f end
		end
		set(a, 1234) set(b, 1) set(c, 4321) set(d, 2)
		press("copy", a, true, "bridge onto bridge")
		press("paste", b, true, "bridge onto bridge")
		want(b, 1234, "bridge onto bridge")
		press("copy", c, true, "link onto link")
		press("paste", d, true, "link onto link")
		want(d, 4321, "link onto link")
		set(b, 1) set(d, 2)
		press("paste", b, false, "link onto bridge")
		want(b, 1, "link onto bridge")
		press("copy", a, true, "bridge onto link")
		press("paste", d, false, "bridge onto link")
		want(d, 2, "bridge onto link")
		press("copy", nil, false, "copy over nothing")
		press("paste", b, true, "copy over nothing (keeps the source)")
		want(b, 1234, "copy over nothing (keeps the source)")
		set(b, 1)
		press("copy", chest, false, "copy over another block")
		press("paste", b, false, "copy over another block (forgets the source)")
		want(b, 1, "copy over another block (forgets the source)")
		press("copy", a, false, "copy from a block of another force", "enemy")
		press("copy", a, true, "paste onto a block of another force")
		press("paste", b, false, "paste onto a block of another force", "enemy")
		want(b, 1, "paste onto a block of another force")
		a.destroy{ raise_destroy = true }
		press("paste", b, false, "a source that is gone")
		want(b, 1, "a source that is gone")
		gone()
		return problems
	end

	--- me-network issue #649: an ME P2P tunnel's copy pasted over a tunnel that stands there (Ctrl+C / Ctrl+V) gives it the
	--- copy's frequency and role, as a tunnel built from the ghost: a bound output pasted over an unbound tunnel becomes an
	--- output of that frequency; an input pasted over a tunnel of another frequency becomes a second input of the copy's
	--- frequency, which waits ("taken") while the first one holds it, and the frequency it left has no input any more.
	local P2P, TY = "gregtorio-me-p2p", KY + 6
	local function p2p_paste(s)
		local problems = {}
		local I = "me-item-p2p-tunnel"
		local function put(x, name) return me_place(s, problems, "p2p paste", name or I, BX + x + 0.5, TY + 0.5) end
		local a, b, c, d, e = put(0), put(3), put(6), put(9), put(12)
		--- (Task-Ingame #654: an unbound one, and the fluid kind)
		local F = "me-fluid-p2p-tunnel"
		local u, fa, fb, fc, fd, fe = put(15), put(18, F), put(21, F), put(24, F), put(27, F), put(30, F)
		local function gone()
			for _, x in pairs({ a, b, c, d, e, u, fa, fb, fc, fd, fe }) do if x and x.valid then x.destroy{ raise_destroy = true } end end
		end
		if not (a and b and c and d and e and u and fa and fb and fc and fd and fe) then gone() return problems end
		local function info(x) return remote.call(P2P, "info", x) or {} end
		local function over(src, dst)
			local inv, bp = copy_of(s, area_of(src))
			remote.call(PO, "paste", bp, s, "player", dst.position, defines.direction.north)
			inv.destroy()
		end
		local function want(x, freq, output, status, what)
			local i = info(x)
			if i.freq ~= freq or i.output ~= output or (status and i.status ~= status) then
				problems[#problems + 1] = ("%s: frequency %s, %s, status %s (expected %s, %s%s)"):format(what, tostring(i.freq),
					i.output and "output" or "input", tostring(i.status), freq, output and "output" or "input",
					status and (", " .. status) or "")
			end
		end
		local f1 = remote.call(P2P, "make_input", a)
		remote.call(P2P, "bind_output", b, f1)
		local f2 = remote.call(P2P, "make_input", d)
		remote.call(P2P, "bind_output", e, f2)
		if not (f1 and f2 and f1 ~= f2) then
			problems[#problems + 1] = "p2p paste: no two frequencies (" .. tostring(f1) .. ", " .. tostring(f2) .. ")"
			gone()
			return problems
		end
		--- a bound output over an unbound tunnel
		over(b, c)
		want(c, f1, true, nil, "a bound output pasted over an unbound tunnel")
		want(b, f1, true, nil, "the copied output")
		--- an input over the input of another frequency: a second input of the copy's frequency waits
		over(a, d)
		want(d, f1, false, "taken", "an input pasted over the input of another frequency")
		want(a, f1, false, "input", "the copied input (it keeps the frequency)")
		want(e, f2, true, "no-input", "the output of the frequency the pasted-over input left")
		--- Task-Ingame #654: a blank (unbound) copy pasted over a bound tunnel changes nothing
		over(u, b)
		want(b, f1, true, nil, "a blank copy pasted over a bound output")
		over(u, a)
		want(a, f1, false, "input", "a blank copy pasted over a bound input")
		--- Task-Ingame #654: the same with fluid tunnels
		local g1 = remote.call(P2P, "make_input", fa)
		remote.call(P2P, "bind_output", fb, g1)
		local g2 = remote.call(P2P, "make_input", fd)
		remote.call(P2P, "bind_output", fe, g2)
		if not (g1 and g2 and g1 ~= g2) then
			problems[#problems + 1] = "p2p paste: no two fluid frequencies (" .. tostring(g1) .. ", " .. tostring(g2) .. ")"
		else
			over(fb, fc)
			want(fc, g1, true, nil, "a bound fluid output pasted over an unbound fluid tunnel")
			over(fa, fd)
			want(fd, g1, false, "taken", "a fluid input pasted over the input of another frequency")
			want(fa, g1, false, "input", "the copied fluid input (it keeps the frequency)")
			want(fe, g2, true, "no-input", "the fluid output of the frequency the pasted-over input left")
		end
		gone()
		return problems
	end

	--- me-network issue #659: a change in the ME window of a ghost arrives in the block built from it. An ME Import Bus copied
	--- with one filter, pasted as a ghost that another mod tagged as well: its window's stand-in (the harness has no player,
	--- so the test stages it as the window does) gets other filters and a Capacity Card; written back, the ghost carries them
	--- and the other mod's tag, the card comes back when the window closes (the ghost then wants it), and the bus built from
	--- the ghost has the new filters. The stand-in of an ME Quantum Bridge of a frequency that two bridges have takes it from
	--- neither (the third block of a frequency would). Nothing stays on the hidden surface or in storage.
	local GX, GY = -380, 180              -- (west of the rows, clear of the logistic storage bus test's roboports)
	local function ghost_window(s)
		local problems = {}
		local function bad(text) problems[#problems + 1] = text end
		local B = "me-quantum-bridge"
		local bus = me_place(s, problems, "ghost window", "me-import-bus", GX + 0.5, GY + 0.5)
		local q1, q2 = me_place(s, problems, "ghost window", B, GX + 5.5, GY + 1.5), me_place(s, problems, "ghost window", B, GX + 10.5, GY + 1.5)
		local inv = game.create_inventory(4)
		local function gone()
			for _, e in pairs(s.find_entities_filtered{ area = { { GX - 1, GY - 1 }, { GX + 20, GY + 8 } } }) do
				if e.valid and e.type ~= "character" then e.destroy{ raise_destroy = true } end
			end
			inv.destroy()
		end
		if not (bus and q1 and q2) then gone() return problems end
		remote.call(IO, "set_bus_filters", bus, { "iron-plate" })
		local cinv, bp = copy_of(s, area_of(bus))
		bus.destroy{ raise_destroy = true }
		local g = paste(s, bp, { GX + 0.5, GY + 0.5 }, "me-import-bus", true)
		cinv.destroy()
		if not g then bad("the import bus made no ghost") gone() return problems end
		local t = g.tags or {}
		t.another_mod = { kept = 42 }
		g.tags = t
		local stand = remote.call(GW, "stage", g, "edit")
		if not stand then bad("the import bus's ghost opened no stand-in") gone() return problems end
		if remote.call(GW, "ghost_of", stand) ~= g then bad("the stand-in does not know its ghost") end
		if stand.surface == s then bad("the stand-in stands on the ghost's surface") end
		remote.call(IO, "set_bus_filters", stand, { "copper-plate", "fluid/water" })
		inv[1].set_stack{ name = "me-capacity-card", count = 1 }
		local why = remote.call(IO, "bus_card_click", stand, 1, inv[1], inv, false)
		if why ~= nil or inv[1].valid_for_read then bad("the stand-in took no card: " .. tostring(why)) end
		remote.call(GW, "sync", "edit")
		local tags = g.tags or {}
		local bt = tags.fork_me_bus or {}
		if serpent.line(bt.filters) ~= serpent.line({ "copper-plate", "fluid/water" }) then
			bad("the ghost's filters after the window: " .. serpent.line(bt.filters))
		end
		if serpent.line(bt.cards) ~= serpent.line({ "me-capacity-card" }) then bad("the ghost's cards after the window: " .. serpent.line(bt.cards)) end
		if not (type(tags.another_mod) == "table" and tags.another_mod.kept == 42) then bad("another mod's tag on the ghost was lost") end
		local back = game.create_inventory(4)
		local given = remote.call(GW, "unstage", "edit", back)
		if given ~= 1 or back.get_item_count("me-capacity-card") ~= 1 then
			bad("the card put into the ghost's window did not come back (" .. tostring(given) .. " items)")
		end
		back.destroy()
		if not g.valid then bad("the ghost is gone after its window") gone() return problems end
		local _, e = g.revive{ raise_revive = true }
		local got = e and remote.call(IO, "get_bus", e)
		if not (got and serpent.line(got.filters) == serpent.line({ "copper-plate", "fluid/water" })) then
			bad("the bus built from the ghost has the filters " .. serpent.line(got and got.filters))
		end
		--- what the game's own window put into a stand-in (the ME Interface's "Open inventory") comes back too
		local iface = me_place(s, problems, "ghost window", "me-network-interface", GX + 2.5, GY + 5.5)
		if iface then
			local iinv, ibp = copy_of(s, area_of(iface))
			iface.destroy{ raise_destroy = true }
			local ig = paste(s, ibp, { GX + 2.5, GY + 5.5 }, "me-network-interface", true)
			iinv.destroy()
			local is = ig and remote.call(GW, "stage", ig, "iface")
			if not is then bad("the interface's ghost opened no stand-in")
			else
				is.get_inventory(defines.inventory.chest).insert{ name = "iron-plate", count = 7 }
				local into = game.create_inventory(4)
				local n = remote.call(GW, "unstage", "iface", into)
				if n ~= 7 or into.get_item_count("iron-plate") ~= 7 then
					bad("the plates put into the interface's stand-in came back as " .. tostring(n) .. " items")
				end
				into.destroy()
			end
		end
		--- a bridge's ghost of the pair's frequency: its stand-in takes the frequency from neither
		remote.call(QB, "set_frequency", q1, 777)
		remote.call(QB, "set_frequency", q2, 777)
		local before = (remote.call(QB, "info", q1) or {}).status
		local qinv, qbp = copy_of(s, area_of(q1))
		local qg = paste(s, qbp, { GX + 15.5, GY + 1.5 }, B, true)
		qinv.destroy()
		local qs = qg and remote.call(GW, "stage", qg, "bridge")
		if not qg then bad("the bridge made no ghost")
		elseif not qs then bad("the bridge's ghost opened no stand-in")
		else
			if (remote.call(QB, "info", qs) or {}).freq ~= 777 then bad("the bridge's stand-in has not the ghost's frequency") end
			local during = (remote.call(QB, "info", q1) or {}).status
			if during ~= before then bad("the bridge's stand-in took the pair's frequency: " .. tostring(before) .. " -> " .. tostring(during)) end
			remote.call(GW, "unstage", "bridge")
		end
		local c = remote.call(GW, "counts")
		if c.entities ~= 0 or c.sessions ~= 0 or c.units ~= 0 then bad("left after the windows: " .. serpent.line(c)) end
		gone()
		return problems
	end

	function T.setup() return {} end

	function T.tick()
		if game.tick ~= START then return end
		local s = game.surfaces[1]
		local before = remote.call(C, "queues")      -- (issue #660: what the circuit module holds before the blocks)
		before.rate, before.interval = nil, nil
		local problems, lost, raw = build(s), {}, {}
		local function lose(path, name, why)
			lost[path] = lost[path] or {}
			table.insert(lost[path], name)
			problems[#problems + 1] = path .. ": " .. name .. " " .. why
		end
		local sources = {}
		for i, b in ipairs(BLOCKS) do
			local src = s.find_entity(b[1], spot(b[1], i, "source"))
			if src then
				b[2](src)
				sources[i] = src
			else
				problems[#problems + 1] = b[1] .. ": the original was not built"
			end
		end
		--- the landing of the paste handler, against the game's own ghosts
		do
			local first, last = sources[1], sources[#BLOCKS]
			if first and last then
				local a, z = area_of(first), area_of(last)
				local inv, bp = copy_of(s, { { a[1][1], BY - 0.9 }, { z[2][1], BY + 3.9 } })
				local inv2, bp2 = copy_of(s, { { BX, BY + ROWS.mixed }, { BX + 14, BY + ROWS.mixed + 4 } })
				for _, b in ipairs({ bp, bp2 }) do
					for _, d in ipairs({ defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west }) do
						for _, off in ipairs({ { 0, 0 }, { 0.5, 0.5 }, { 0.25, 0.75 }, { 0.5, 0 }, { 0.75, 0.25 } }) do
							for _, p in ipairs(landing(s, b, { x = LAND.x + off[1], y = LAND.y + off[2] }, d)) do problems[#problems + 1] = p end
						end
					end
				end
				inv.destroy()
				inv2.destroy()
			end
		end
		for i, b in ipairs(BLOCKS) do
			local name, src = b[1], sources[i]
			if src then
				local want = signature(src)
				if not want:find("tags") and not want:find("control_behavior") then
					problems[#problems + 1] = name .. ": the original's blueprint carries no settings: " .. want
				end
				local function same(path, e)
					local got = signature(e)
					if got ~= want then lose(path, name, "lost its settings: " .. got .. " (the original: " .. want .. ")") end
				end
				local inv, bp = copy_of(s, area_of(src))
				--- blueprint: on free ground, revived
				same("blueprint", (paste(s, bp, spot(name, i, "blueprint"), name)))
				--- ghost copy: pasted as ghosts, the ghosts copied again, that copy pasted and revived
				local ghost = paste(s, bp, spot(name, i, "ghost"), name, true)
				if not ghost then lose("ghost copy", name, "made no ghost")
				else
					local inv2, bp2 = copy_of(s, area_of(ghost))
					same("ghost copy", (paste(s, bp2, spot(name, i, "ghostcopy"), name)))
					inv2.destroy()
				end
				--- paste over a blank block: the game alone (the step that loses the settings), then with the mod's handler
				local r = s.find_entity(name, spot(name, i, "raw"))
				local _, nr = paste(s, bp, spot(name, i, "raw"), name)
				if r and signature(r) ~= want then raw[#raw + 1] = name end
				local o = s.find_entity(name, spot(name, i, "over"))
				local at = spot(name, i, "over")
				remote.call(PO, "paste", bp, s, "player", { x = at[1], y = at[2] }, defines.direction.north)
				local _, n = paste(s, bp, at, name)
				if not (o and r) then problems[#problems + 1] = name .. ": the blank blocks to paste over were not built"
				else same("paste over", o) end
				if n + nr > 0 then problems[#problems + 1] = name .. ": the paste over a blank block made " .. (n + nr) .. " ghost(s)" end
				--- cut: the original mined, then the copy revived
				local ghost2 = paste(s, bp, spot(name, i, "cut"), name, true)
				local buffer = game.create_inventory(16)
				src.mine{ inventory = buffer, raise_destroyed = true, ignore_minable = true }
				buffer.destroy()
				if ghost2 and ghost2.valid then
					local _, e = ghost2.revive{ raise_revive = true }
					same("cut", e)
				else lose("cut", name, "made no ghost") end
				--- ghost window (issue #659): the stand-in has the settings, writes them back, and the built block has them (issue
				--- #660: the circuit interface too, since a removed one leaves its queue at once)
				if remote.call(GW, "window_of_ghost", name) then
					local g = paste(s, bp, spot(name, i, "ghostwin"), name, true)
					local stand = g and remote.call(GW, "stage", g, "copypaste")
					if not stand then lose("ghost window", name, "opened no stand-in")
					else
						local got = signature(stand)
						if got ~= want then lose("ghost window", name, "stand-in without its settings: " .. got .. " (the original: " .. want .. ")") end
						remote.call(GW, "unstage", "copypaste")
						if g.valid then
							local _, e = g.revive{ raise_revive = true }
							same("ghost window", e)
						else lose("ghost window", name, "the ghost is gone") end
					end
				end
				inv.destroy()
			end
		end
		local paths = {}
		for path, names in pairs(lost) do paths[#paths + 1] = path .. ": " .. table.concat(names, ", ") end
		table.sort(paths)
		--- (the blocks go again)
		for _, e in pairs(s.find_entities_filtered{ area = { { BX - 2, BY - 2 }, { BX + #BLOCKS * STEP + 2, BY + ROWS.ghostwin + 6 } } }) do
			if e.valid and e.type ~= "character" then e.destroy{ raise_destroy = true } end
		end
		--- issue #660: every maintainer and circuit interface of this test was mined or destroyed (with the event, also the
		--- stand-ins of the ghost windows): none stays in the module's records or in its queues' counts
		local after = remote.call(C, "queues")
		after.rate, after.interval = nil, nil
		if serpent.line(after) ~= serpent.line(before) then
			problems[#problems + 1] = "the removed maintainers and circuit interfaces stay in the circuit module: before "
				.. serpent.line(before) .. ", after " .. serpent.line(after)
		end
		storage.copypaste383 = { done = true, lost = paths, raw = raw }
		me_report("COPYPASTE", "ME settings through the copy-paste tool", problems, #paths == 0
			and (#BLOCKS .. " blocks keep their settings through a blueprint, a copy of ghosts, a paste over a blank block and a cut;"
				.. " the game alone pasted over " .. #raw .. " of them without their settings: " .. table.concat(raw, ", "))
			or ("lost: " .. table.concat(paths, "; ")))
		me_report("SETTINGSPASTE", "ME settings paste through the game", game_paste(s),
			"the script's path (copy_settings; the player's path is PASTEKEYS): the game pastes nothing between two bridges,"
				.. " two links and a bridge and a link; the handler copies the frequency between two of a kind only and each"
				.. " block keeps its own power")
		me_report("PASTEKEYS", "ME settings paste through the copy and paste keys", keys_paste(s),
			"the player's path (the mod's keys, issue #527): the frequency from a bridge onto a bridge and a link onto a link,"
				.. " not across, with sound and flying text; a copy over another block, another force and a source that is"
				.. " gone paste nothing")
		me_report("GHOSTWIN", "The ME window of a ghost", ghost_window(s),
			"issue #659: the filters and a card set in a ghost's window reach its tags (another mod's tag kept) and the built"
				.. " block, the card comes back, a bridge's stand-in takes no frequency, nothing stays")
		me_report("P2PPASTE", "ME P2P tunnels pasted over tunnels", p2p_paste(s),
			"issue #649: a bound output pasted over an unbound tunnel takes its frequency and role; an input pasted over the"
				.. " input of another frequency waits as a second input of the copy's frequency; a blank copy changes nothing;"
				.. " the same with fluid tunnels (Task-Ingame #654)")
	end

	function T.running(check) check(storage.copypaste383 and storage.copypaste383.done, "ME settings through the copy-paste tool") end
	return T
end
