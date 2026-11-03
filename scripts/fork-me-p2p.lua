--------------------------------------------------------------------------------
--- ME P2P TUNNELS (me-network issue #629; AE2-Unofficial's P2P tunnels: src/main/java/appeng/parts/p2p/PartP2PTunnel.java,
--- PartP2PItems.java, PartP2PLiquids.java and the frequencies of me/cache/P2PCache.java, read and written anew for Factorio;
--- prototypes/network.lua; guide: docs/AE2.md "ME P2P Tunnels")
---   * Two kinds, items and fluids, 1x1 and turned: a tunnel faces the tile its plate points to. A frequency (a whole number,
---     0: none) has one input and any number of outputs (AE2's P2PCache: one input per frequency); an output of the other
---     kind carries nothing. A second input of a frequency waits ("taken") until the first one goes or leaves it, as the
---     third ME Quantum Bridge of a frequency does.
---   * AE2 keeps the frequencies per grid: an output carries only while it is in the input's network (on any surface the
---     network reaches through an ME Quantum Bridge).
---   * A pattern provider faced by an input (on one of its four sides) serves the machines and chests that the outputs of the
---     input's frequency face, as if they were next to it (scripts/fork-me-autocraft.lua, EXT.tunnel_views): item ingredients
---     through an item tunnel, fluid ingredients through a fluid tunnel. What a job hands to such a machine and takes back of
---     it goes as with a neighbour; nothing travels back through a tunnel (AE2's item tunnel is one way).
---   * Binding: AE2's memory card (scripts/fork-me-memorycard.lua: `make_input`, AE2's convertToInput: an output or an unbound
---     tunnel gets a new frequency; then `bind_output` on others); settings paste (the destination becomes an output of the
---     source's frequency; an unbound source becomes the input of a new one); the window (frequency, input or output, a new
---     frequency, unbind).
---   * Kept in blueprints (tag fork_me_p2p = { freq, output }), copy and paste, clones (the source's) and settings paste.
---   * Cost: the frequencies are kept by number (`freqs`); which outputs of a frequency carry (valid, of the input's kind, in
---     its network) is derived when something changed (a tunnel built, removed, turned or bound; the ME graph changed), never
---     per visit; the machine an output faces is kept in its record and looked for again only when it is gone or the tunnel
---     turned (as a bus keeps its target).
--- State: storage.fork_me_p2p = { recs = { [unit] = { entity, freq, output, face (the key of the tile it faces), target, tdir } },
--- freqs = { [freq] = { inputs = { unit ... }, outputs = { unit ... } } } (in the order they were bound), facing = { [tile key] =
--- { unit ... } } (the inputs by the tile they face), next_freq }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local T = require("scripts.fork-me-targets")

local M = {}

M.ITEM, M.FLUID = "me-item-p2p-tunnel", "me-fluid-p2p-tunnel"
M.NAMES = { M.ITEM, M.FLUID }
local KIND = { [M.ITEM] = "item", [M.FLUID] = "fluid" }
M.TAG = "fork_me_p2p"
local MAX_FREQ = 2 ^ 31 - 1

--- functions() run when the tunnels changed so that a provider's targets may have (scripts/fork-me-autocraft.lua rescans)
M.change_hooks = {}

local function state()
	local s = storage.fork_me_p2p
	if not s then
		s = { recs = {}, freqs = {}, facing = {}, next_freq = 1 }
		storage.fork_me_p2p = s
	end
	return s
end

function M.is_tunnel(entity) return entity ~= nil and entity.valid and KIND[entity.name] ~= nil end
function M.kind_of(name) return KIND[name] end

local function tile_key(surface, x, y) return surface .. ":" .. math.floor(x) .. ":" .. math.floor(y) end
M.tile_key = tile_key

local function face_key(entity)
	local p = T.front(entity)
	return tile_key(entity.surface.index, p[1], p[2])
end

--- which outputs of a frequency carry: freq -> { unit ... } (derived; dropped by every change, rebuilt when asked)
local resolved = {}

local function changed()
	resolved = {}
	for _, hook in ipairs(M.change_hooks) do hook() end
end
N.change_hooks[#N.change_hooks + 1] = function() resolved = {} end   -- (networks joined or split: other outputs carry)

local function remove_value(list, value)
	for i = #list, 1, -1 do
		if list[i] == value then table.remove(list, i) end
	end
end

--- take record `rec` of `unit` out of its frequency and the inputs' tile index
local function unlink(s, unit, rec)
	local fr = rec.freq ~= 0 and s.freqs[rec.freq]
	if fr then
		remove_value(fr.inputs, unit)
		remove_value(fr.outputs, unit)
		if #fr.inputs == 0 and #fr.outputs == 0 then s.freqs[rec.freq] = nil end
	end
	local list = rec.face and s.facing[rec.face]
	if list then
		remove_value(list, unit)
		if #list == 0 then s.facing[rec.face] = nil end
	end
	rec.face = nil
end

--- put it into its frequency (an input also into the tile index, by the tile it faces)
local function link(s, unit, rec)
	if rec.freq == 0 then return end
	local fr = s.freqs[rec.freq]
	if not fr then
		fr = { inputs = {}, outputs = {} }
		s.freqs[rec.freq] = fr
	end
	if rec.output then
		fr.outputs[#fr.outputs + 1] = unit
	else
		fr.inputs[#fr.inputs + 1] = unit
		rec.face = face_key(rec.entity)
		local list = s.facing[rec.face] or {}
		s.facing[rec.face] = list
		list[#list + 1] = unit
	end
end

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, freq = 0, output = false }
		s.recs[unit] = rec
	end
	return rec, s
end

local function rec_of(entity)
	local s = storage.fork_me_p2p
	return s and M.is_tunnel(entity) and s.recs[entity.unit_number] or nil
end

--- set the frequency (0 .. 2^31 - 1; 0: unbound) and the role of a tunnel. Returns true when they are valid.
function M.set(entity, freq, output)
	if not M.is_tunnel(entity) then return false end
	freq = math.floor(tonumber(freq) or -1)
	if freq < 0 or freq > MAX_FREQ then return false end
	local rec, s = register(entity)
	output = freq ~= 0 and output == true or false
	if rec.freq == freq and rec.output == output then return true end
	unlink(s, entity.unit_number, rec)
	rec.freq, rec.output = freq, output
	link(s, entity.unit_number, rec)
	changed()
	return true
end

--- a frequency no tunnel has
local function new_frequency(s)
	local f = s.next_freq or 1
	while s.freqs[f] do f = f % MAX_FREQ + 1 end
	s.next_freq = f % MAX_FREQ + 1
	return f
end

--- AE2's convertToInput: an output or an unbound tunnel becomes the input of a new frequency, an input keeps its own (`fresh`:
--- a new one in any case, the window's button). Returns the frequency.
function M.make_input(entity, fresh)
	if not M.is_tunnel(entity) then return nil end
	local rec, s = register(entity)
	if fresh or rec.output or rec.freq == 0 then M.set(entity, new_frequency(s), false) end
	return rec.freq
end

function M.bind_output(entity, freq)
	if not (freq and freq ~= 0) then return false end
	return M.set(entity, freq, true)
end

function M.unbind(entity) return M.set(entity, 0, false) end

--- the input of frequency `f` that carries: the first one bound to it that is still there
local function active_input(s, f)
	local fr = s.freqs[f]
	if not fr then return nil end
	for _, unit in ipairs(fr.inputs) do
		local rec = s.recs[unit]
		if rec and rec.entity.valid then return unit, rec end
	end
	return nil
end

--- the outputs of frequency `f` that carry: of the input's kind, in its network (derived, see `resolved`)
local function carriers(s, f)
	local list = resolved[f]
	if list then return list end
	list = {}
	local _, inrec = active_input(s, f)
	local net = inrec and N.network_of(inrec.entity)
	if net then
		local name = inrec.entity.name
		for _, unit in ipairs(s.freqs[f].outputs) do
			local rec = s.recs[unit]
			local e = rec and rec.entity
			if e and e.valid and e.name == name then
				local on = N.network_of(e)
				if on and on.id == net.id then list[#list + 1] = unit end
			end
		end
	end
	resolved[f] = list
	return list
end

--- the entity output `rec` faces (one of `types`, of its force), kept in the record until it is gone or the tunnel turned
local function target_of(rec, types)
	local t, e = rec.target, rec.entity
	if t and t.valid and rec.tdir == e.direction then return t end
	rec.target, rec.tdir = nil, e.direction
	local found = e.surface.find_entities_filtered{ position = T.front(e), type = types, force = e.force, limit = 1 }
	t = found[1]
	if t then rec.target = t end
	return t
end

--- The machines and chests a pattern provider (`entity`, in network `net`) reaches through tunnels: the inputs that face it,
--- in `net`, that carry their frequency; the entities of `types` that the outputs carrying it face. A list of { entity, kind
--- ("item" or "fluid") } in the order of the inputs and outputs (a machine reached twice is listed twice), nil when none.
function M.targets(entity, net, types)
	local s = storage.fork_me_p2p
	local ins = s and s.facing[tile_key(entity.surface.index, entity.position.x, entity.position.y)]
	if not ins then return nil end
	local out
	for _, unit in ipairs(ins) do
		local rec = s.recs[unit]
		local e = rec and rec.entity
		if e and e.valid and not rec.output and active_input(s, rec.freq) == unit then
			local en = N.network_of(e)
			if en and en.id == net.id then
				local kind = KIND[e.name]
				for _, o in ipairs(carriers(s, rec.freq)) do
					local t = target_of(s.recs[o], types)
					if t then
						out = out or {}
						out[#out + 1] = { entity = t, kind = kind }
					end
				end
			end
		end
	end
	return out
end

local function where(e) return { surface = e.surface.name, x = e.position.x, y = e.position.y } end

--- What the window shows: { kind ("item" or "fluid"), freq, output, status, input = { surface, x, y } (an output's input, or
--- the input that holds the frequency), outputs (how many carry), bound (how many outputs the frequency has) }. Status:
--- "unbound"; an input: "input", "taken" (another input holds the frequency); an output: "output", "no-input", "other-kind"
--- (the input is of the other kind), "other-network".
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local s = storage.fork_me_p2p
	local out = { kind = KIND[entity.name], freq = rec.freq, output = rec.output }
	if rec.freq == 0 then out.status = "unbound" return out end
	local fr = s.freqs[rec.freq]
	local iu, inrec = active_input(s, rec.freq)
	out.bound = fr and #fr.outputs or 0
	if not rec.output then
		if iu ~= entity.unit_number then
			out.status = "taken"
			if inrec then out.input = where(inrec.entity) end
			return out
		end
		out.status = "input"
		out.outputs = #carriers(s, rec.freq)
		return out
	end
	if not inrec then out.status = "no-input" return out end
	out.input = where(inrec.entity)
	if inrec.entity.name ~= entity.name then out.status = "other-kind" return out end
	local unit = entity.unit_number
	for _, o in ipairs(carriers(s, rec.freq)) do
		if o == unit then out.status = "output" return out end
	end
	out.status = "other-network"
	return out
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- `tags`: blueprint tags of a built ghost (or of a paste over a block, issue #383); `source`: the original of a clone
function M.on_built(entity, tags, source)
	if not M.is_tunnel(entity) then return end
	register(entity)
	local t = type(tags) == "table" and tags[M.TAG] or nil
	if type(t) == "table" then
		M.set(entity, t.freq or 0, t.output == true)
	elseif M.is_tunnel(source) then
		local from = rec_of(source)
		if from then M.set(entity, from.freq, from.output) end
	end
end

function M.on_removed(entity)
	local s = storage.fork_me_p2p
	if not (s and M.is_tunnel(entity) and entity.unit_number) then return end
	local rec = s.recs[entity.unit_number]
	if not rec then return end
	unlink(s, entity.unit_number, rec)
	s.recs[entity.unit_number] = nil
	changed()
end

--- a turned tunnel faces another tile: an input another provider, an output another machine
function M.on_rotated(entity)
	local rec = rec_of(entity)
	if not rec then return end
	local s = storage.fork_me_p2p
	unlink(s, entity.unit_number, rec)
	link(s, entity.unit_number, rec)
	rec.target = nil
	changed()
end

--- settings paste (and the mod's paste of a memory card's copy): the destination becomes an output of the source's frequency;
--- an unbound source becomes the input of a new frequency first. Between tunnels of the same kind.
function M.paste(src, dst)
	if not (M.is_tunnel(src) and M.is_tunnel(dst) and src.name == dst.name and src ~= dst) then return false end
	local rec = register(src)
	if rec.freq == 0 then M.make_input(src) end
	return M.bind_output(dst, rec.freq)
end

function M.on_entity_settings_pasted(event) M.paste(event.source, event.destination) end

function M.tag_blueprint(bp, mapping)
	local s = storage.fork_me_p2p
	if not s then return end
	for index, entity in pairs(mapping) do
		local rec = entity.valid and KIND[entity.name] and s.recs[entity.unit_number]
		if rec and rec.freq ~= 0 then bp.set_blueprint_entity_tag(index, M.TAG, { freq = rec.freq, output = rec.output }) end
	end
end

--- after a mod change: the tunnels of the world (records kept by unit number), the frequencies and the tile index made again
--- from the records: each frequency's tunnels in the order they were bound (which input holds it stays), then the others by
--- unit number
function M.on_configuration_changed()
	local s = state()
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = M.NAMES }) do register(e) end
	end
	local units = {}
	for unit, rec in pairs(s.recs) do
		if rec.entity and rec.entity.valid then units[#units + 1] = unit else s.recs[unit] = nil end
	end
	table.sort(units)
	local old, freqs = s.freqs, {}
	for f in pairs(old) do freqs[#freqs + 1] = f end
	table.sort(freqs)
	s.freqs, s.facing = {}, {}
	local done = {}
	local function again(unit, f)
		local rec = s.recs[unit]
		if rec and not done[unit] and (f == nil or rec.freq == f) then
			done[unit] = true
			rec.face = nil
			link(s, unit, rec)
		end
	end
	for _, f in ipairs(freqs) do
		for _, unit in ipairs(old[f].inputs or {}) do again(unit, f) end
		for _, unit in ipairs(old[f].outputs or {}) do again(unit, f) end
	end
	for _, unit in ipairs(units) do again(unit, nil) end
	changed()
end

remote.add_interface("gregtorio-me-p2p", {
	info = function(entity) return M.info(entity) end,
	set = function(entity, freq, output) return M.set(entity, freq, output) end,
	make_input = function(entity, fresh) return M.make_input(entity, fresh) end,
	bind_output = function(entity, freq) return M.bind_output(entity, freq) end,
	unbind = function(entity) return M.unbind(entity) end,
	paste = function(source, destination) return M.paste(source, destination) end,
	--- tests: the unit numbers of the machines and chests a provider reaches through tunnels (in its network)
	targets = function(provider)
		local net = N.network_of(provider)
		local out = {}
		for _, t in ipairs(net and M.targets(provider, net, { "assembling-machine", "furnace", "container", "logistic-container" }) or {}) do
			out[#out + 1] = t.entity.unit_number
		end
		return out
	end,
})

return M
