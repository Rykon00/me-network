--- Runtime test of me-network issue #790: the fluid sides of an ME Interface turn with a turned or flipped blueprint. The
--- interface is a container, so the game moves it with the blueprint but has nothing to turn, and the sides live in a tag
--- (fork_me_interface.sides) that the game never looks into. scripts/fork-me-bpturn.lua remembers how a player placed a
--- blueprint (on_pre_build) and turns the tags of the interfaces and interface ghosts built in that tick;
--- scripts/fork-me-pasteover.lua turns them for an interface that stands where the blueprint is pasted.
--- The harness has no player and LuaItemStack.build_blueprint raises no on_pre_build, so the placement is fed through the
--- remote `gregtorio-me-bpturn` (note: what on_pre_build remembers; built: the build handlers of control.lua as
--- on_built_entity of that player calls them). On a surface of its own ("me-bpturn-test"):
--- * the source: an interface with an item row and two fluid rows, north importing, east tied to row 2, south off, west tied
---   to row 3 (four different sides), in a blueprint with an ME Drive three tiles east of it;
--- * every placement (four directions, each plain, with H, with V and with both: 16): where each side has to land is worked
---   out here from the side's vector, flipped first and then turned, as scripts/fork-me-pasteover.lua moves the positions
---   (and written out for R, H, V and H + R). For each placement:
---   - ghost: the blueprint built as ghosts, the interface's ghost goes through the build handlers: its tags have the turned
---     sides (the rows, the priority and another mod's tag kept), and the interface revived from it (raise_revive, what a
---     robot's build brings: no second turn) has them;
---   - instant: an interface built at once with the blueprint entity's tags (editor, cheat mode) has the turned sides;
---   - paste over: the blueprint pasted over a blank interface that stands where its interface lands gives it the turned sides;
--- * an unturned placement remembers nothing; anything but a blueprint in the cursor forgets the placement (an interface
---   item placed by hand onto the turned ghost must not turn it again); a placement of an earlier tick turns nothing (checked
---   one tick later); a blueprint a script builds (no on_pre_build) keeps the sides of its own frame (the limit of the issue);
---   a turn of an interface tag without sides and of a tag in the older spelling ([side] = value).
--- * issue #795: a ghost of an interface that lies under the paste gets the blueprint entity's tags from the game, which
---   raises on_blueprint_settings_pasted for it: its tags turn there (fed through the remote `pasted`), not for an
---   unturned paste, another player's, a later tick's, or a ghost left without tags.
--- Loaded by control.lua: require("bpturn")(H) returns { setup, tick, running }.

local IO, AC, PO, BT = "gregtorio-me-io", "gregtorio-me-autocraft", "gregtorio-me-pasteover", "gregtorio-me-bpturn"
local SURFACE = "me-bpturn-test"
local START = 170
local IFACE, DRIVE = "me-network-interface", "me-drive"
local D = defines.direction
local PLAYER = 1                          -- (no such player in the harness: the index only keys the remembered placement)
local NAMES = { [0] = "north", [4] = "east", [8] = "south", [12] = "west" }
--- the vectors of the sides 1 north, 2 east, 3 south, 4 west
local VEC = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

--- the source's sides: north imports (no entry), east row 2, south off, west row 3
local SOURCE = { [2] = 2, [3] = "off", [4] = 3 }

--- where the sides `sides` land: each side's vector flipped (in the blueprint's own frame), then turned clockwise
local function expected(sides, d, fh, fv)
	local out = {}
	for side, v in pairs(sides) do
		local x, y = VEC[side][1], VEC[side][2]
		if fh then x = -x end
		if fv then y = -y end
		for _ = 1, d / 4 do x, y = -y, x end
		for to, vec in ipairs(VEC) do
			if vec[1] == x and vec[2] == y then out[to] = v end
		end
	end
	return out
end

local function show(sides)
	if type(sides) ~= "table" then return tostring(sides) end
	local t = {}
	for d = 1, 4 do t[d] = tostring(sides[d] or "import") end
	return "N " .. t[1] .. ", E " .. t[2] .. ", S " .. t[3] .. ", W " .. t[4]
end

--- the sides of an interface tag ({ { side, row | off } }) as [side] = value
local function tag_sides(tags)
	local t = type(tags) == "table" and tags.fork_me_interface
	if type(t) ~= "table" or type(t.sides) ~= "table" then return nil end
	local out = {}
	for _, v in pairs(t.sides) do
		if type(v) == "table" and v.side then out[v.side] = v.off and "off" or v.row end
	end
	return out
end

local function name_of(d, fh, fv)
	return NAMES[d] .. (fh and " + H" or "") .. (fv and " + V" or "")
end

return function(H)
	local me_report = H.me_report
	local T = {}

	local function surface()
		local s = game.surfaces[SURFACE]
		if s then return s end
		s = game.create_surface(SURFACE, { width = 256, height = 256, default_enable_all_autoplace_controls = false,
			autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
				decorative = { treat_missing_as_default = false, settings = {} } } })
		s.always_day = true
		s.request_to_generate_chunks({ 0, 0 }, 4)
		s.force_generate_chunk_requests()
		local tiles = {}
		for x = -96, 95 do for y = -96, 95 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
		s.set_tiles(tiles)
		return s
	end

	function T.setup()
		surface()
		storage.bpturn790 = {}
		return {}
	end

	--- a second fluid beside water (the game's or Gregtorio's)
	local function second_fluid()
		for _, name in ipairs({ "steam", "crude-oil", "lubricant", "sulfuric-acid" }) do
			if prototypes.fluid[name] then return name end
		end
		for name in pairs(prototypes.fluid) do
			if name ~= "water" then return name end
		end
	end

	local function clear(s)
		for _, e in pairs(s.find_entities_filtered{ area = { { -90, -90 }, { 90, 90 } } }) do
			if e.valid and e.type ~= "character" then e.destroy{ raise_destroy = true } end
		end
	end

	local function run(s)
		local problems = {}
		local function bad(text) problems[#problems + 1] = text end
		local function same(what, got, want)
			if show(got) ~= show(want) then bad(what .. ": " .. show(got) .. " (expected " .. show(want) .. ")") end
		end
		local fluid = second_fluid()
		local src = s.create_entity{ name = IFACE, position = { 0.5, 0.5 }, force = "player", raise_built = true }
		local drive = s.create_entity{ name = DRIVE, position = { 3.5, 0.5 }, force = "player", raise_built = true }
		if not (src and drive and fluid) then
			bad("the source was not built (interface " .. tostring(src) .. ", drive " .. tostring(drive) .. ", fluid " .. tostring(fluid) .. ")")
			return problems
		end
		remote.call(IO, "set_interface_config", src, { [1] = { name = "iron-plate", quality = "normal", amount = 50 },
			[2] = { type = "fluid", name = "water", amount = 2000 }, [3] = { type = "fluid", name = fluid, amount = 1000 } }, SOURCE)
		remote.call(IO, "set_interface_priority", src, 3)
		same("the source's sides", remote.call(IO, "get_interface_sides", src), SOURCE)
		local inv = game.create_inventory(1)
		inv.insert{ name = "blueprint" }
		local bp = inv[1]
		local mapping = bp.create_blueprint{ surface = s, force = "player", area = { { -0.4, -0.4 }, { 4.4, 1.4 } } } or {}
		remote.call(AC, "tag_blueprint", bp, mapping)
		local be_tags
		for _, be in pairs(bp.get_blueprint_entities() or {}) do
			if be.name == IFACE then be_tags = be.tags end
		end
		same("the sides in the blueprint", tag_sides(be_tags), SOURCE)
		if not be_tags then
			inv.destroy()
			return problems
		end

		--- the interface's ghost of the blueprint built at `at` in direction `d` (the other ghosts go)
		local function ghost_at(at, d)
			local found
			for _, g in pairs(bp.build_blueprint{ surface = s, force = "player", position = at, direction = d } or {}) do
				if g.valid and g.name == "entity-ghost" and g.ghost_name == IFACE and not found then found = g
				elseif g.valid then g.destroy() end
			end
			return found
		end

		--- the rule written out for the placements a player uses most (the worked-out rule must agree with them)
		local WRITTEN = {
			{ D.east, false, false, { [1] = 3, [3] = 2, [4] = "off" } },          -- R: north -> east, east -> south, ...
			{ D.north, true, false, { [2] = 3, [3] = "off", [4] = 2 } },          -- H: east and west change places
			{ D.north, false, true, { [1] = "off", [2] = 2, [4] = 3 } },          -- V: north and south change places
			{ D.east, true, false, { [1] = 2, [3] = 3, [4] = "off" } },           -- H, then R
			{ D.south, false, false, { [1] = "off", [2] = 3, [4] = 2 } },         -- R twice
			{ D.west, false, false, { [1] = 2, [2] = "off", [3] = 3 } },          -- Shift + R
		}
		for _, w in ipairs(WRITTEN) do
			same("the rule of this test for " .. name_of(w[1], w[2], w[3]), expected(SOURCE, w[1], w[2], w[3]), w[4])
		end

		local n, y = 0, 10
		for _, d in ipairs({ D.north, D.east, D.south, D.west }) do
			for _, flips in ipairs({ { false, false }, { true, false }, { false, true }, { true, true } }) do
				local fh, fv = flips[1], flips[2]
				local what, want = name_of(d, fh, fv), expected(SOURCE, d, fh, fv)
				local turned = d ~= D.north or fh or fv
				n = n + 1
				--- ghost: through the build handlers as the player's build event brings it, then revived
				local g = ghost_at({ x = -60.5, y = y + 0.5 }, d)
				if not g then bad(what .. ": the blueprint made no interface ghost")
				else
					local t = g.tags or {}
					t.another_mod = { kept = 42 }
					g.tags = t
					remote.call(BT, "note", PLAYER, d, fh, fv)
					if (remote.call(BT, "noted", PLAYER) ~= nil) ~= turned then
						bad(what .. ": " .. (turned and "nothing remembered" or "an unturned placement was remembered"))
					end
					remote.call(BT, "built", g, nil, PLAYER)
					local tags = g.valid and g.tags or {}
					same(what .. ", the ghost's tags", tag_sides(tags), want)
					local it = tags.fork_me_interface or {}
					if not (type(it.config) == "table" and #it.config == 3 and it.priority == 3) then
						bad(what .. ": the ghost's tag lost its rows or its priority: " .. serpent.line(it))
					end
					if not (type(tags.another_mod) == "table" and tags.another_mod.kept == 42) then
						bad(what .. ": another mod's tag on the ghost was lost")
					end
					--- (a second ghost of the same placement: every ghost of the tick is turned, each once)
					local g2 = ghost_at({ x = -40.5, y = y + 0.5 }, d)
					if g2 then
						remote.call(BT, "built", g2, nil, PLAYER)
						same(what .. ", a second ghost of the placement", tag_sides(g2.tags), want)
						g2.destroy()
					end
					local _, e = g.revive{ raise_revive = true }
					if not e then bad(what .. ": the ghost was not revived")
					else
						same(what .. ", the interface built from the ghost", remote.call(IO, "get_interface_sides", e), want)
						local config = remote.call(IO, "get_interface_config", e) or {}
						if not (config[2] and config[2].name == "water" and config[3] and config[3].name == fluid) then
							bad(what .. ": the interface built from the ghost lost its rows: " .. serpent.line(config))
						end
					end
				end
				--- instant: the interface itself is what the player's build event brings, with the blueprint entity's tags
				local e = s.create_entity{ name = IFACE, position = { -20.5, y + 0.5 }, force = "player" }
				remote.call(BT, "note", PLAYER, d, fh, fv)
				remote.call(BT, "built", e, be_tags, PLAYER)
				same(what .. ", built at once", remote.call(IO, "get_interface_sides", e), want)
				--- paste over a blank interface where the blueprint's interface lands
				local at = { x = 20.5, y = y + 0.5 }
				local land = remote.call(PO, "landings", bp, at, d, fh, fv)[IFACE]
				local blank = s.create_entity{ name = IFACE, position = land, force = "player", raise_built = true }
				local count = remote.call(PO, "paste", bp, s, "player", at, d, fh, fv)
				if count ~= 1 then bad(what .. ": the paste over a blank interface set " .. tostring(count) .. " blocks") end
				same(what .. ", pasted over a blank interface", blank and remote.call(IO, "get_interface_sides", blank), want)
				y = y + 4
			end
		end

		--- anything but a blueprint in the cursor forgets the placement: the ghost a hand build goes onto is not turned again
		remote.call(BT, "note", PLAYER, D.east, false, false)
		remote.call(BT, "pre_build", { player_index = PLAYER, position = { 0, 0 }, direction = D.east,
			flip_horizontal = false, flip_vertical = false })
		if remote.call(BT, "noted", PLAYER) ~= nil then bad("a pre-build without a blueprint in the cursor kept the placement") end
		local g = ghost_at({ x = -60.5, y = -20.5 }, D.north)
		if g then
			remote.call(BT, "built", g, nil, PLAYER)
			same("a ghost built after a pre-build without a blueprint", tag_sides(g.tags), SOURCE)
			g.destroy()
		end
		--- a blueprint a script builds raises no on_pre_build: the sides of its own frame stay (the issue's limit)
		local g3 = ghost_at({ x = -60.5, y = -30.5 }, D.east)
		if g3 then
			local _, e = g3.revive{ raise_revive = true }
			same("a blueprint built by a script, turned east (no on_pre_build: not turned)",
				e and remote.call(IO, "get_interface_sides", e), SOURCE)
		end
		--- the turn itself: a tag without sides is the same table, the older spelling of the sides turns too, both flips are
		--- half a turn, eighth turns do not count
		local plain = { fork_me_interface = { config = {} }, other = 1 }
		local out = remote.call(IO, "turn_interface_tags", plain, D.east, true, false)
		if serpent.line(out) ~= serpent.line(plain) then bad("a tag without sides was changed: " .. serpent.line(out)) end
		same("the older spelling of the sides, turned east",
			tag_sides(remote.call(IO, "turn_interface_tags", { fork_me_interface = { sides = { [2] = 2, [3] = "off", [4] = 3 } } }, D.east)),
			expected(SOURCE, D.east))
		same("both flips against half a turn", tag_sides(remote.call(IO, "turn_interface_tags", be_tags, D.north, true, true)),
			tag_sides(remote.call(IO, "turn_interface_tags", be_tags, D.south, false, false)))
		same("an eighth turn", tag_sides(remote.call(IO, "turn_interface_tags", be_tags, D.northeast, false, false)), SOURCE)
		--- issue #795: a ghost that lies under the paste. The game gives it the blueprint entity's tags and raises
		--- on_blueprint_settings_pasted (no build event): the tags turn there, as for a ghost the placement builds
		local function ghost_under()
			return s.create_entity{ name = "entity-ghost", inner_name = IFACE, position = { -60.5, -50.5 }, force = "player",
				tags = be_tags }
		end
		for _, w in ipairs({ { D.east, false, false }, { D.north, true, false }, { D.north, false, true }, { D.east, true, false } }) do
			local what = name_of(w[1], w[2], w[3]) .. ", pasted over a ghost"
			local og = ghost_under()
			remote.call(BT, "note", PLAYER, w[1], w[2], w[3])
			remote.call(BT, "pasted", og, PLAYER)
			same(what, tag_sides(og.tags), expected(SOURCE, w[1], w[2], w[3]))
			local it = (og.tags or {}).fork_me_interface or {}
			if not (type(it.config) == "table" and #it.config == 3 and it.priority == 3) then
				bad(what .. ": the ghost's tag lost its rows or its priority: " .. serpent.line(it))
			end
			og.destroy()
		end
		--- (an unturned paste, the paste of another player, a ghost the paste left without tags and a built block: nothing turns)
		local og = ghost_under()
		remote.call(BT, "note", PLAYER, D.north, false, false)
		remote.call(BT, "pasted", og, PLAYER)
		same("an unturned blueprint pasted over a ghost", tag_sides(og.tags), SOURCE)
		remote.call(BT, "note", PLAYER, D.east, false, false)
		remote.call(BT, "pasted", og, PLAYER + 1)
		same("a ghost pasted over by another player than the one who turned", tag_sides(og.tags), SOURCE)
		og.tags = nil
		remote.call(BT, "pasted", og, PLAYER)
		if og.tags ~= nil then bad("a ghost without tags got tags from a paste: " .. serpent.line(og.tags)) end
		og.destroy()
		local standing = s.create_entity{ name = IFACE, position = { -60.5, -54.5 }, force = "player", raise_built = true }
		remote.call(IO, "set_interface_config", standing, { [2] = { type = "fluid", name = "water", amount = 2000 },
			[3] = { type = "fluid", name = fluid, amount = 1000 } }, SOURCE)
		remote.call(BT, "pasted", standing, PLAYER)
		same("a built interface in the settings-pasted event (the paste over it is pasteover's)",
			remote.call(IO, "get_interface_sides", standing), SOURCE)
		--- a placement of this tick, looked at in the next one (T.tick): it turns nothing then
		remote.call(BT, "note", PLAYER, D.east, false, false)
		local late = ghost_at({ x = -60.5, y = -40.5 }, D.north)
		inv.destroy()
		return problems, n, late
	end

	function T.tick()
		local st = storage.bpturn790
		if not st or st.done or game.tick < START then return end
		local s = game.surfaces[SURFACE]
		if not st.problems then
			st.problems, st.n, st.late = run(s)
			return
		end
		local problems = st.problems
		local g = st.late
		if g and g.valid then
			remote.call(BT, "pasted", g, PLAYER)                 -- (issue #795: a paste event of a later tick)
			if show(tag_sides(g.tags)) ~= show(SOURCE) then
				problems[#problems + 1] = "a ghost pasted over a tick after the placement was turned: " .. show(tag_sides(g.tags))
			end
			remote.call(BT, "built", g, nil, PLAYER)
			if show(tag_sides(g.tags)) ~= show(SOURCE) then
				problems[#problems + 1] = "a ghost built a tick after the placement was turned: " .. show(tag_sides(g.tags))
			end
			if remote.call(BT, "noted", PLAYER) ~= nil then problems[#problems + 1] = "the placement of an earlier tick was kept" end
		else
			problems[#problems + 1] = "the ghost for the next tick is gone"
		end
		clear(s)
		st.late = nil
		st.done = true
		me_report("BPTURN", "ME Interface sides turned with a blueprint (issue #790)", problems,
			tostring(st.n) .. " placements (4 directions, each plain, with H, with V and with both): the sides in the ghost's tags,"
				.. " of the interface built from the ghost, of one built at once and of one pasted over are the blueprint's, flipped"
				.. " and then turned; a hand build, a later tick and a script's blueprint turn nothing; a ghost under the paste"
				.. " turns with it (issue #795)")
	end

	function T.running(check) check(storage.bpturn790 and storage.bpturn790.done, "ME Interface sides turned with a blueprint (issue #790)") end
	return T
end
