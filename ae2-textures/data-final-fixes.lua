--- ME Network - AE2 Textures (issue #239): sets this mod's files in place of ME Network's, by prototype name, from the
--- table in overrides.lua. ME Network does not know this mod. One file (an icon, a layer, a sheet) is replaced by one
--- file; no image is put together here, and the layers of another origin around it stay as they are.
--- What cannot be applied (a prototype or a file that is not there) is skipped with a line in the log, so the game
--- still loads with ME Network's own graphics; devcheck fails on such a line.

local OVERRIDES = require("overrides")
local OWN = "__me-network__/"
local MOD = "__me-network-ae2-textures__/"

local function starts(s, prefix) return type(s) == "string" and s:sub(1, #prefix) == prefix end

local function say(key, text) log("me-network-ae2-textures: " .. key .. ": " .. text) end

--- every place in a prototype that names a file of ME Network: { {holder table, key, file} }
local function places_of(proto)
	local out, seen = {}, {}
	local function walk(t, depth)
		if depth > 16 or seen[t] then return end
		seen[t] = true
		for k, v in pairs(t) do
			if starts(v, OWN) then
				out[#out + 1] = { t, k, v }
			elseif type(v) == "table" then
				walk(v, depth + 1)
			end
		end
	end
	walk(proto, 0)
	return out
end

--- puts `new` (a file of this mod, or a table with `filename` and the sprite fields that differ) at every place of `old`
local function replace(key, places, old, new)
	local file = type(new) == "table" and new.filename or new
	if not starts(file, MOD) then
		say(key, "SKIPPED: " .. tostring(file) .. " is not a file of this mod (" .. MOD .. ")")
		return
	end
	local n = 0
	for _, p in pairs(places) do
		local holder, k, v = p[1], p[2], p[3]
		if v == old then
			if type(new) == "table" and type(k) ~= "string" then
				say(key, "SKIPPED: " .. old .. " is one of several file names of a sprite; give a file name only")
				return
			end
			holder[k] = file
			if type(new) == "table" then
				for field, value in pairs(new) do
					if field ~= "filename" then holder[field] = value end
				end
			end
			n = n + 1
		end
	end
	if n == 0 then
		say(key, "SKIPPED: " .. old .. " is not a file of this prototype")
	else
		say(key, old .. " -> " .. file .. " (" .. n .. (n == 1 and " place)" or " places)"))
	end
end

for key, value in pairs(OVERRIDES) do
	local kind, name = key:match("^([^/]+)/(.+)$")
	local proto = kind and data.raw[kind] and data.raw[kind][name]
	if not proto then
		say(key, "SKIPPED: no prototype of that type and name")
	else
		-- a copy of its own, so a table that ME Network shares between prototypes keeps its files elsewhere
		proto = table.deepcopy(proto)
		data.raw[kind][name] = proto
		local places = places_of(proto)
		if type(value) == "string" or (type(value) == "table" and value.filename) then
			local files = {}
			for _, p in pairs(places) do files[p[3]] = true end
			local list = {}
			for f in pairs(files) do list[#list + 1] = f end
			if #list == 1 then
				replace(key, places, list[1], value)
			else
				say(key, "SKIPPED: the prototype uses " .. #list .. " files of ME Network; name the one to replace")
			end
		elseif type(value) == "table" then
			for old, new in pairs(value) do
				if starts(old, OWN) then
					replace(key, places, old, new)
				else
					say(key, "SKIPPED: " .. tostring(old) .. " is not a file of ME Network (" .. OWN .. ")")
				end
			end
		else
			say(key, "SKIPPED: the value is neither a file name nor a table")
		end
	end
end
