--------------------------------------------------------------------------------
--- ME NETWORK: the names the player sees, for the search fields (issue #295). The picker's and the ME Terminal's search
--- matched the prototype name only, so an item a mod renames by its locale (Gregtorio Continued: `processing-unit` is
--- "HV Circuit") was not found by the name on its icon. A mod cannot read the locale: each player's client translates
--- the localised names of every item and fluid (LuaPlayer.request_translations, on_string_translated), and the search
--- matches those as well as the prototype name.
---   * State: storage.fork_me_names = { players = { [player_index] = { locale, next, pending = { [id] = key }, names =
---     { ["item/<name>"] = lower case name }, version, done } }, active = { [player_index] = true } }. In `storage`, not
---     derived per load: the names come from events, and in multiplayer a peer that joins later must search like the
---     others (what a search lists builds the GUI, which is part of the game state).
---   * A player's names are requested the first time a picker or a terminal opens for them (and again after their
---     locale or the mods changed), PER_TICK strings a tick for all players together (a queue with a budget, like the
---     scheduler's; the tick handler costs one `next` while nothing is waiting). A player who is not connected waits.
---   * Until the names have arrived the search falls back to the prototype name; when the last one arrives, the open
---     picker and window of that player are filled again (M.on_done).
---   * Matching: the search text in lower case with spaces as dashes against the prototype name (as before), or in
---     lower case as it is against the translated name. (`string.lower` lowers ASCII letters only.)
--------------------------------------------------------------------------------

local M = {}

local PER_TICK = 200              -- translation requests a tick, all players together

--- functions(player) called when a player's names are complete (the picker and the windows fill again)
M.on_done = {}

--- the localised names to translate: { { key, localised_name } } of every item and fluid that is not hidden, in a fixed
--- order (derived from the prototypes only: made again after a load)
local wanted
local function wanted_list()
	if wanted then return wanted end
	wanted = {}
	local function add(kind, protos)
		local names = {}
		for name, p in pairs(protos) do
			if not (p.hidden or p.parameter) then names[#names + 1] = name end
		end
		table.sort(names)
		for _, name in ipairs(names) do wanted[#wanted + 1] = { kind .. "/" .. name, protos[name].localised_name } end
	end
	add("item", prototypes.item)
	add("fluid", prototypes.fluid)
	return wanted
end

local function state()
	local s = storage.fork_me_names
	if not s then
		s = { players = {}, active = {} }
		storage.fork_me_names = s
	end
	return s
end

--- starts (or starts again, after a change of the player's locale) the translation of `player`'s names
function M.ensure(player)
	if not (player and player.valid) then return end
	local s = state()
	local rec = s.players[player.index]
	if rec and rec.locale == player.locale then return end
	s.players[player.index] = { locale = player.locale, next = 1, pending = {}, names = {}, version = 0, done = false }
	s.active[player.index] = true
end

--- every tick: up to PER_TICK requests of the players waiting for names, by player index
function M.step()
	local s = storage.fork_me_names
	if not (s and next(s.active)) then return end
	local list = wanted_list()
	local budget = PER_TICK
	local indexes = {}
	for index in pairs(s.active) do indexes[#indexes + 1] = index end
	table.sort(indexes)
	for _, index in ipairs(indexes) do
		if budget <= 0 then break end
		local rec, player = s.players[index], game.get_player(index)
		if not (rec and player and player.valid) then
			s.active[index] = nil
		elseif player.connected then
			local first, last = rec.next, math.min(#list, rec.next + budget - 1)
			if first <= last then
				local strings = {}
				for i = first, last do strings[#strings + 1] = list[i][2] end
				local ids = player.request_translations(strings)
				for i, id in ipairs(ids or {}) do rec.pending[id] = list[first + i - 1][1] end
				budget = budget - (last - first + 1)
				rec.next = last + 1
			end
			if rec.next > #list then s.active[index] = nil end
		end
	end
end

local function finish(index, rec)
	rec.done = true
	rec.version = rec.version + 1
	local player = game.get_player(index)
	if player and player.valid then
		for _, f in ipairs(M.on_done) do f(player) end
	end
end

--- on_string_translated: a name of one of our requests (other mods' requests are not in `pending`)
function M.on_translated(event)
	local s = storage.fork_me_names
	local rec = s and s.players[event.player_index]
	local key = rec and rec.pending[event.id]
	if not key then return end
	rec.pending[event.id] = nil
	if event.translated and type(event.result) == "string" then rec.names[key] = event.result:lower() end
	if not s.active[event.player_index] and next(rec.pending) == nil then finish(event.player_index, rec) end
end

--- the search text: { dashed (lower case, spaces as dashes: the prototype name), lower (lower case, trimmed: the
--- translated name) }
function M.search(text)
	text = (text or ""):lower()
	return (text:gsub("%s+", "-")), (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- the translated names of a player ({ ["item/<name>"] = lower case name }), or nil
function M.names_of(index)
	local s = storage.fork_me_names
	local rec = s and index and s.players[index]
	return rec and rec.names or nil
end

--- how often a player's names were completed (the terminal's kept lists of a search depend on it)
function M.version(index)
	local s = storage.fork_me_names
	local rec = s and index and s.players[index]
	return rec and rec.version or 0
end

--- does item or fluid `name` (`kind` "item" or "fluid") match the search (M.search's two forms, `names`: M.names_of)?
function M.matches(names, kind, name, dashed, lower)
	if dashed == "" or name:find(dashed, 1, true) then return true end
	local t = names and names[kind .. "/" .. name]
	return t ~= nil and lower ~= "" and t:find(lower, 1, true) ~= nil
end

--- the mods changed: every player's names are requested again when they next search
function M.on_configuration_changed()
	storage.fork_me_names = nil
	wanted = nil
end

function M.forget(index)
	local s = storage.fork_me_names
	if s then s.players[index], s.active[index] = nil, nil end
end

script.on_event(defines.events.on_string_translated, function(event) M.on_translated(event) end)
script.on_event(defines.events.on_player_locale_changed, function(event)
	local s = storage.fork_me_names
	local rec = s and s.players[event.player_index]
	if rec then M.ensure(game.get_player(event.player_index)) end            -- (only a player who searched already)
end)

--- (tests: the harness has no player, so no translation arrives) set a player's names as if they had been translated
function M.set_names(index, names)
	local s = state()
	s.players[index] = { locale = "test", next = math.huge, pending = {}, names = {}, version = 0, done = false }
	s.active[index] = nil
	for k, v in pairs(names or {}) do s.players[index].names[k] = tostring(v):lower() end
	finish(index, s.players[index])
end

--- (tests) a player whose requests `pending` ({ [id] = key }) are on their way, all of them sent
function M.set_pending(index, pending)
	local s = state()
	s.players[index] = { locale = "test", next = math.huge, pending = {}, names = {}, version = 0, done = false }
	s.active[index] = nil
	for id, key in pairs(pending or {}) do s.players[index].pending[id] = key end
end

return M
