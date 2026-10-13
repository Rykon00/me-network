--------------------------------------------------------------------------------
--- FORK AE2: THE GROUP FILTER (issue #354; the Group Filter Card, prototypes/cards.lua)
--- AE2-Unofficial's Ore Dictionary Filter Card (appeng/util/prioitylist/OreFilteredList.java) replaces a filter's slots with
--- a text matched against the ore dictionary names of an item. Factorio has no ore dictionary; its names of a resource are
--- its own name, its subgroup and its group (Factoriopedia's rows), so a term matches when one of the three does.
--- The syntax is AE2-Unofficial's boolean one (makeBooleanMatcher): terms separated by `&` (and) and `|` (or), read from left
--- to right without precedence (AE2-U's fold: "a|b&c" is "(a or b) and c"), a term starting with `!` is negated, `*` in a
--- term stands for any text (a term without `*` must match a whole name). AE2-U's regular expressions (a text with \ ^ $ +
--- ( ) [ ]) are not supported: such a text is read literally. Case does not matter. An empty text is no filter (AE2-U:
--- OreFilteredList.isEmpty, an empty partition list): the card's holder then takes everything.
--- What is derived from the text and the prototypes only (the parsed terms, the result per key) is kept outside storage,
--- per load: the filters' text is the state (in the cells' tags and the storage buses' records).
--------------------------------------------------------------------------------

local M = {}

local parsed = {}                -- text -> list of { neg, op, pattern } (op of the first term: nil)
local results = {}               -- text -> { key -> true/false }
local texts = 0                  -- texts in `results`: dropped all at once past MAX_TEXTS (a text typed letter by letter)
local MAX_TEXTS = 64

local function glob(term)
	local p = term:lower():gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*")
	return "^" .. p .. "$"
end

local function parse(text)
	local terms = {}
	local op = nil
	local pos = 1
	while pos <= #text do
		local s, e = text:find("[&|]", pos)
		local part = text:sub(pos, (s or #text + 1) - 1)
		part = part:match("^%s*(.-)%s*$")
		if part ~= "" then
			local neg = part:sub(1, 1) == "!"
			if neg then part = part:sub(2) end
			if part ~= "" then terms[#terms + 1] = { neg, #terms > 0 and (op or "&") or nil, glob(part) } end
		end
		if not s then break end
		op = text:sub(s, e)
		pos = e + 1
	end
	return terms
end

--- the names a key is matched by: its name, subgroup and group (a fluid key "fluid/<name>@<degrees>": the fluid's)
local function names_of(key)
	local name, proto
	if key:sub(1, 6) == "fluid/" then
		name = key:sub(7):match("^([^@]+)")
		proto = name and prototypes.fluid[name]
	else
		name = key:match("^([^@#]+)")
		proto = name and prototypes.item[name]
	end
	if not proto then return { name and name:lower() or key:lower() } end
	local sub = proto.subgroup
	return { name:lower(), sub and sub.name:lower() or "", sub and sub.group and sub.group.name:lower() or "" }
end

local function term_hits(pattern, names)
	for _, n in ipairs(names) do
		if n:find(pattern) then return true end
	end
	return false
end

--- Does the filter text `text` let the storage key `key` in?
function M.match(text, key)
	local r = results[text]
	if not r then
		texts = texts + 1
		if texts > MAX_TEXTS then
			results, parsed, texts = {}, {}, 1
		end
		r = {}
		results[text] = r
	end
	local v = r[key]
	if v ~= nil then return v end
	local terms = parsed[text]
	if not terms then
		terms = parse(text)
		parsed[text] = terms
	end
	local names = names_of(key)
	local acc = nil
	for _, t in ipairs(terms) do
		local hit = term_hits(t[3], names)
		if t[1] then hit = not hit end
		if acc == nil then acc = hit elseif t[2] == "|" then acc = acc or hit else acc = acc and hit end
	end
	v = acc == true
	r[key] = v
	return v
end

--- a filter text for storage: as typed (a window's text field shows it back unchanged), at most 200 characters; nil when
--- it is empty or only spaces
function M.clean(text)
	if type(text) ~= "string" or not text:find("%S") then return nil end
	return text:sub(1, 200)
end

return M
