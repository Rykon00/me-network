--------------------------------------------------------------------------------
--- ME NETWORK: settings paste by the mod's own keys (issue #527). The game cannot paste the ME Quantum Bridge and the ME
--- Wireless Link for a player: they are electric energy interfaces with `gui_mode = "none"`, which the game finds not
--- operable ("Not operable"). So they keep `allow_copy_paste` off (the game pastes nothing onto them) and two custom inputs
--- linked to the game's copy and paste controls (prototypes/paste.lua, INPUTS; consuming "none") do it:
---   * Copy over a block of prototypes/paste.lua's KEYS: its unit number is kept for the player (storage). Copy over any
---     other block forgets it, so a later paste never brings back an older block's settings; copy over nothing keeps it.
---   * Paste over one of the source's targets: the source's paste handler is called as the game's event calls it
---     ({ source, destination, player_index }), with the game's sounds and a flying text at the block. A source that is
---     gone is forgotten and pastes nothing; a block that is no target of it (a bridge onto a link) gets nothing.
---   * Only with an empty hand (no item, ghost or blueprint record in the cursor): with one, the same keys build.
---   * Only on blocks of the player's force or a friend's.
--- State: storage.fork_me_paste_keys = { [player_index] = { unit, name } }
--------------------------------------------------------------------------------

local PASTE = require("prototypes.paste")
local G = require("scripts.fork-me-gui")

local M = {}

local HANDLERS = {}                                  -- module name -> module (required here: require only at load)
for _, spec in pairs(PASTE.KEYS) do
	HANDLERS[spec.handler] = HANDLERS[spec.handler] or require("scripts." .. spec.handler)
end
local TARGETS = {}                                   -- source name -> { [target name] = true }
for name, spec in pairs(PASTE.KEYS) do
	TARGETS[name] = {}
	for _, t in ipairs(spec.targets) do TARGETS[name][t] = true end
end

local function empty_hand(player)
	local stack = player.cursor_stack
	return not (stack and stack.valid_for_read) and not player.cursor_ghost and not player.cursor_record
end

local function own(player, e)
	return e.force == player.force or player.force.is_friend(e.force)
end

--- the copy key over `e` (nil: nothing selected); true when a block was copied
function M.copy(player, e)
	if not (e and e.valid and empty_hand(player)) then return false end
	if not (TARGETS[e.name] and e.unit_number and own(player, e)) then
		local s = storage.fork_me_paste_keys
		if s then s[player.index] = nil end
		return false
	end
	storage.fork_me_paste_keys = storage.fork_me_paste_keys or {}
	storage.fork_me_paste_keys[player.index] = { unit = e.unit_number, name = e.name }
	player.play_sound{ path = "utility/entity_settings_copied" }
	return true
end

--- the paste key over `e`; true when the source's settings were pasted
function M.paste(player, e)
	local s = storage.fork_me_paste_keys
	local from = s and s[player.index]
	if not (from and e and e.valid and empty_hand(player)) then return false end
	local targets = TARGETS[from.name]
	if not (targets and targets[e.name] and own(player, e)) then return false end
	local src = G.entity_by_unit(from.unit)
	if not (src and src.valid and src.name == from.name) then
		s[player.index] = nil                                            -- (the source is gone)
		return false
	end
	if src == e then return false end
	HANDLERS[PASTE.KEYS[from.name].handler].on_entity_settings_pasted{ source = src, destination = e,
		player_index = player.index }
	player.play_sound{ path = "utility/entity_settings_pasted" }
	player.create_local_flying_text{ text = { "fork-me-paste.settings-pasted" }, position = e.position, surface = e.surface }
	return true
end

script.on_event(PASTE.INPUTS.copy.name, function(event)
	local player = game.get_player(event.player_index)
	if player then M.copy(player, player.selected) end
end)

script.on_event(PASTE.INPUTS.paste.name, function(event)
	local player = game.get_player(event.player_index)
	if player then M.paste(player, player.selected) end
end)

--- after a mod change: the copies of players that are gone
function M.on_configuration_changed()
	local s = storage.fork_me_paste_keys
	if not s then return end
	for index in pairs(s) do
		if not game.get_player(index) then s[index] = nil end
	end
end

--- a stand-in for the player (the harness has none): an empty hand, the force `force`, the sounds and texts it would get
--- recorded in `seen`
local function stand_in(index, force, seen)
	return {
		index = index, force = game.forces[force or "player"],
		play_sound = function(spec) seen[#seen + 1] = spec.path end,
		create_local_flying_text = function(spec) seen[#seen + 1] = spec.text[1] end,
	}
end

remote.add_interface("gregtorio-me-paste-keys", {
	--- the copy and paste keys of player `index` (a stand-in with an empty hand, of the force `force`, default "player")
	--- over `entity`, as the custom input's handler calls them: { done = true when copied or pasted, seen = { sounds and
	--- texts } }
	copy = function(index, entity, force)
		local seen = {}
		return { done = M.copy(stand_in(index, force, seen), entity), seen = seen }
	end,
	paste = function(index, entity, force)
		local seen = {}
		return { done = M.paste(stand_in(index, force, seen), entity), seen = seen }
	end,
})

return M
