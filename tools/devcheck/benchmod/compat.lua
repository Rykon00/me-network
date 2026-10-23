--- me-network issue #487: the benchmark runs in Factorio 2.1 and, for the numbers of a 2.0 version (`bench` with a Factorio
--- 2.0 work folder), in 2.0: the engine calls that changed between them. (devcheck.py gives the helper mods the
--- factorio_version of the Factorio they run in.)
local M = {}
local major, minor = (script.active_mods.base or "2.0"):match("^(%d+)%.(%d+)")
M.V21 = tonumber(major) > 2 or tonumber(minor) >= 1

--- the fluid boxes of `e`: { n, get(i), id(i) (nil: no segment), segment(i) ({ name -> amount }), capacity(i) (2.0's
--- LuaFluidBox.get_capacity: the segment's, else the box's) }; nil without boxes
function M.boxes(e)
	if M.V21 then
		local n = e.fluids_count
		if n == 0 then return nil end
		return {
			n = n,
			get = function(i) return e.get_fluid(i) end,
			id = function(i) return e.has_fluid_segment(i) and e.get_fluid_segment_id(i) or nil end,
			segment = function(i)
				if not e.has_fluid_segment(i) then return nil end
				local f = e.get_fluid_segment_fluid(i)
				return f and { [f.name] = f.amount } or {}
			end,
			capacity = function(i)
				if e.has_fluid_segment(i) then return e.get_fluid_segment_capacity(i) end
				return e.get_fluid_capacity(i)
			end,
		}
	end
	local fb = e.fluidbox
	if #fb == 0 then return nil end
	return { n = #fb, get = function(i) return fb[i] end, id = function(i) return fb.get_fluid_segment_id(i) end,
		segment = function(i) return fb.get_fluid_segment_contents(i) end, capacity = function(i) return fb.get_capacity(i) end }
end

--- take fluid out of `e` (and its segment): extract_fluid since 2.1, remove_fluid before
function M.extract(e, spec)
	if M.V21 then return e.extract_fluid(spec) end
	return e.remove_fluid(spec)
end

--- a recipe's categories (a list since 2.1; an engine object raises an error for a key it does not have)
function M.categories(r)
	if M.V21 then return r.categories end
	return { r.category }
end

--- does a machine of the crafting categories `cats` (a set) make recipe `r`?
function M.makes(cats, r)
	for _, c in pairs(M.categories(r)) do if cats[c] then return true end end
	return false
end

--- the chance that a craft makes product `p`
function M.chance(p)
	local sp = p.shared_probability
	return (p.independent_probability or p.probability or 1) * (sp and (sp.max - sp.min) or 1)
end

--- the name of a machine prototype's fixed recipe (a LuaRecipePrototype since 2.1), nil without one
function M.fixed_recipe(proto)
	local f = proto.fixed_recipe
	if type(f) == "string" then return f ~= "" and f or nil end
	return f and f.name or nil
end

return M
