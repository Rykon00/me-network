--- Runtime test of me-network issue #753: x2, x3, x4 and /2, /3, /4 for the amounts of a processing pattern in the ME
--- Pattern Terminal and the ME Pattern Terminal Ex (remote gregtorio-me-pattern-terminal scale_editor: the editor's rows).
--- * a processing editor of 2 iron plates + 100 water -> 1 gear + 14.4 steam: x2 doubles every row (4, 200, 2, 28.8), x3
---   then /3 gives the start again, /2 divides (2, 100, 1, 14.4), a second /2 is refused (1 gear does not divide) and
---   changes nothing, the outputs alone divide no further either; x4 on the outputs alone leaves the inputs;
--- * a row without an item and a row with the amount 0 stay as they are;
--- * a row of 400 000 takes x2 and refuses x3 and x4 (a pattern row holds 1 000 000): nothing changes, also not the rows
---   that would have fitted;
--- * a fluid row of 100 refuses /3 (33.333...), 14.4 takes /2 and /4 (7.2, 3.6);
--- * a crafting editor is refused ("scale-crafting"), an editor without rows too ("scale-empty");
--- * the Ex editor (32 inputs) scales its 20 rows; the scaled editor still encodes (pattern_of).
--- * the window: the ME Pattern Terminal opened for a stand-in player with a processing editor has the six buttons, on or
---   off by what the rows take (x2 on; /2 off for 1 gear; with every row even, /2 on and /3 off); in crafting mode there
---   are none.
--- Loaded by control.lua: require("patternscale")(H) returns { setup, tick, running }.

local PT, GUI = "gregtorio-me-pattern-terminal", "gregtorio-me-gui"
local START = 165

return function(H)
	local me_report = H.me_report
	local T = {}

	function T.tick()
		local st = storage.patternscale753
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.patternscale753 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note) me_report("PATTERNSCALE", "scaling a processing pattern's amounts (issue #753)", problems, note) end
		if not remote.interfaces[PT].scale_editor then return finish("nothing to check: a version before #753") end
		local pt = function(fn, ...) return remote.call(PT, fn, ...) end

		local function editor(inputs, outputs, ex)
			local ed = ex and pt("new_editor_ex") or pt("new_editor")
			ed.mode = "processing"
			for i, r in pairs(inputs) do ed.inputs[i] = r and { key = r[1], amount = r[2] } or nil end
			for i, r in pairs(outputs) do ed.outputs[i] = r and { key = r[1], amount = r[2] } or nil end
			return ed
		end
		local function amounts(ed)
			local out = {}
			for _, which in ipairs({ "inputs", "outputs" }) do
				local keys = {}
				for i in pairs(ed[which]) do keys[#keys + 1] = i end
				table.sort(keys)
				for _, i in ipairs(keys) do out[#out + 1] = tostring(ed[which][i].amount) end
				out[#out + 1] = "|"
			end
			return table.concat(out, " ")
		end
		--- scale and compare: `want` the amounts afterwards (as amounts() writes them), `why` the reason of a refusal
		local function scale(label, ed, factor, divide, outputs_only, want, why)
			local before = amounts(ed)
			local ok, got_why, new = pt("scale_editor", ed, factor, divide, outputs_only)
			if why then
				expect(not ok and got_why == why and amounts(new) == before, label .. ": " .. tostring(ok) .. " " .. tostring(got_why)
					.. ", amounts " .. amounts(new) .. " (before " .. before .. ")")
			else
				expect(ok == true and amounts(new) == want, label .. ": " .. tostring(ok) .. " " .. tostring(got_why) .. ", amounts "
					.. amounts(new) .. ", expected " .. want)
			end
			return new
		end

		local ed = editor({ { "iron-plate", 2 }, { "fluid/water", 100 } }, { { "iron-gear-wheel", 1 }, { "fluid/steam", 14.4 } })
		ed = scale("x2", ed, 2, false, false, "4 200 | 2 28.8 |")
		ed = scale("x3", ed, 3, false, false, "12 600 | 6 86.4 |")
		ed = scale("/3", ed, 3, true, false, "4 200 | 2 28.8 |")
		ed = scale("/2", ed, 2, true, false, "2 100 | 1 14.4 |")
		ed = scale("/2 of 1 gear", ed, 2, true, false, nil, "scale-not-divisible")
		ed = scale("/2 of the outputs with 1 gear", ed, 2, true, true, nil, "scale-not-divisible")
		ed = scale("x4 of the outputs alone", ed, 4, false, true, "2 100 | 4 57.6 |")
		ed = scale("/4 of the outputs alone", ed, 4, true, true, "2 100 | 1 14.4 |")

		--- an empty row and a row with the amount 0
		ed = editor({ [1] = { "iron-plate", 6 }, [3] = { "copper-plate", 0 } }, { [2] = { "iron-gear-wheel", 3 } })
		ed = scale("x2 with a gap and a zero", ed, 2, false, false, "12 0 | 6 |")
		ed = scale("/3 with a gap and a zero", ed, 3, true, false, "4 0 | 2 |")

		--- the largest row
		ed = editor({ { "iron-plate", 400000 }, { "copper-plate", 5 } }, { { "iron-gear-wheel", 1 } })
		ed = scale("x3 of 400 000", ed, 3, false, false, nil, "scale-too-large")
		ed = scale("x4 of 400 000", ed, 4, false, false, nil, "scale-too-large")
		ed = scale("x2 of 400 000", ed, 2, false, false, "800000 10 | 2 |")
		ed = scale("x2 of 800 000", ed, 2, false, false, nil, "scale-too-large")
		ed = scale("x4 of its outputs alone", ed, 4, false, true, "800000 10 | 8 |")

		--- fluids
		ed = editor({ { "fluid/water", 100 } }, { { "fluid/steam", 14.4 } })
		ed = scale("/3 of 100 water", ed, 3, true, false, nil, "scale-not-divisible")
		ed = scale("/4 of 100 water and 14.4 steam", ed, 4, true, false, "25 | 3.6 |")
		ed = scale("/2 of 25 water and 3.6 steam", ed, 2, true, false, "12.5 | 1.8 |")

		--- not a processing editor, and nothing to scale
		local crafting = pt("new_editor")
		scale("a crafting editor", crafting, 2, false, false, nil, "scale-crafting")
		scale("an editor without rows", editor({}, {}), 2, false, false, nil, "scale-empty")

		--- the Ex: 20 input rows, and the scaled editor encodes
		local ins = {}
		local n = 0
		for name, p in pairs(prototypes.item) do
			if p.type == "item" and not p.hidden and not p.parameter and name:sub(1, 3) ~= "me-" and p.get_spoil_ticks() <= 0 then
				n = n + 1
				ins[n] = { name, n }
				if n == 20 then break end
			end
		end
		local ex = editor(ins, { { "iron-gear-wheel", 2 } }, true)
		local ok, why, ex2 = pt("scale_editor", ex, 4, false, false)
		expect(ok and ex2.inputs[20] and ex2.inputs[20].amount == 80 and ex2.inputs[1].amount == 4 and ex2.outputs[1].amount == 8,
			"the Ex editor x4: " .. tostring(ok) .. " " .. tostring(why))
		local def = pt("pattern_of", game.forces.player, ex2)
		expect(def and def.kind == "processing" and #def.inputs == 20 and def.inputs[20].amount == 80 and def.outputs[1].amount == 8,
			"the scaled Ex editor encodes: " .. serpent.line(def and { kind = def.kind, inputs = #def.inputs }))

		--- the window's buttons
		local term
		for _, s in pairs(game.surfaces) do
			term = s.find_entities_filtered{ name = "me-pattern-terminal", limit = 1 }[1]
			if term then break end
		end
		if term then
			local g = function(fn, ...) return remote.call(GUI, fn, ...) end
			local inv = game.create_inventory(10)
			local INDEX = 9431
			local function buttons(ed_for)
				pt("set_player_editor", INDEX, ed_for)
				g("stand_in", "patternscale", { main = inv, index = INDEX, gui = true })
				g("stand_in_open_entity", "patternscale", term)
				local b = g("stand_in_named", "patternscale", "fork_me_pat_scale_")
				g("stand_in_close_window", "patternscale", false)
				g("stand_in_forget", "patternscale")
				return b
			end
			local function state(b)
				local out = {}
				for _, id in ipairs({ "m2", "m3", "m4", "d2", "d3", "d4" }) do
					local el = b["fork_me_pat_scale_" .. id]
					out[#out + 1] = id .. (el and (el.enabled and "+" or "-") or "?")
				end
				return table.concat(out, " ")
			end
			local b = buttons(editor({ { "iron-plate", 2 } }, { { "iron-gear-wheel", 1 } }))
			expect(state(b) == "m2+ m3+ m4+ d2- d3- d4-", "the buttons for 2 plates -> 1 gear: " .. state(b))
			local m2 = b.fork_me_pat_scale_m2
			expect(m2 and m2.caption == "×2" and m2.tags.fork_me_act == "pat_scale" and m2.tags.factor == 2 and not m2.tags.divide,
				"the x2 button: " .. serpent.line(m2))
			local d4 = b.fork_me_pat_scale_d4
			expect(d4 and d4.tags.factor == 4 and d4.tags.divide == true, "the /4 button: " .. serpent.line(d4 and d4.tags))
			b = buttons(editor({ { "iron-plate", 8 } }, { { "iron-gear-wheel", 4 } }))
			expect(state(b) == "m2+ m3+ m4+ d2+ d3- d4+", "the buttons for 8 plates -> 4 gears: " .. state(b))
			--- (the inputs do not divide by 3, the outputs alone do: the button stays on for the shift + click)
			b = buttons(editor({ { "iron-plate", 8 } }, { { "iron-gear-wheel", 3 } }))
			expect(state(b) == "m2+ m3+ m4+ d2- d3+ d4-", "the buttons for 8 plates -> 3 gears: " .. state(b))
			--- (x2 and x3 pass a row's limit for the inputs, the outputs alone take them; x4 passes it for both)
			b = buttons(editor({ { "iron-plate", 600000 } }, { { "iron-gear-wheel", 300000 } }))
			expect(state(b) == "m2+ m3+ m4- d2+ d3+ d4+", "the buttons for 600 000 plates -> 300 000 gears: " .. state(b))
			b = buttons(pt("new_editor"))
			expect(next(b) == nil, "no buttons in crafting mode: " .. state(b))
			pt("set_player_editor", INDEX, nil)
			inv.destroy()
		else
			expect(false, "no ME Pattern Terminal on the test map")
		end
		finish("x2 x3 x4 and /2 /3 /4 on items and fluids, the outputs alone, the refusals, the Ex, the buttons")
	end

	function T.running(check) check(storage.patternscale753 and storage.patternscale753.done, "scaling a pattern's amounts") end

	return T
end
