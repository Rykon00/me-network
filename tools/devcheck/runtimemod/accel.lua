--- Runtime test of me-network issue #110 (docs/AE2.md "Acceleration Card"): the Acceleration Card is a module. The ME Molecular
--- Assembler has five module slots that take it and nothing else; no other machine and no beacon takes the card, and the
--- cards speed the assembler up (+80 % crafting speed and +80 % power each: five cards are AE2's five, 5 times as fast at 5
--- times the power).
--- Loaded by control.lua: require("accel")(H) returns { setup, tick, running } like margin.lua.

local AX, AY = 560, -200
local START, CHECK = 100, 140
local CARD = "me-acceleration-card"

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "acceleration"
		me_place(s, fails, what, "me-molecular-assembler", AX + 1.5, AY + 1.5)
		me_place(s, fails, what, "assembling-machine-2", AX + 5.5, AY + 1.5)
		me_place(s, fails, what, "beacon", AX + 9.5, AY + 1.5)
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.accel110
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false }
			storage.accel110 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local me = s.find_entity("me-molecular-assembler", { AX + 1.5, AY + 1.5 })
		local plain = s.find_entity("assembling-machine-2", { AX + 5.5, AY + 1.5 })
		local beacon = s.find_entity("beacon", { AX + 9.5, AY + 1.5 })
		if not (me and plain and beacon) then
			problems[#problems + 1] = "the entities were not built"
			st.done = true
			return me_report("ACCEL", "Acceleration Card", problems, "no entities")
		end
		local inv = me.get_module_inventory()
		if not st.inserted then
			st.inserted = true
			expect(inv ~= nil and #inv == 5, "the ME Molecular Assembler has " .. tostring(inv and #inv) .. " module slots, not 5")
			if not inv then
				st.done = true
				return me_report("ACCEL", "Acceleration Card", problems, "no module inventory")
			end
			st.base, st.base_bonus = me.crafting_speed, me.consumption_bonus
			--- the card goes in; nothing else of the game's modules does
			expect(not inv.can_insert{ name = "speed-module", count = 1 } and not inv.can_insert{ name = "productivity-module", count = 1 },
				"the ME Molecular Assembler takes a module of the game")
			expect(inv.can_insert{ name = CARD, count = 5 }, "the ME Molecular Assembler does not take the Acceleration Card")
			expect(inv.insert{ name = CARD, count = 5 } == 5, "five cards did not go into its five slots")
			expect(inv.insert{ name = CARD, count = 1 } == 0, "a sixth card went in")
			--- no other machine and no beacon takes the card
			local pinv, binv = plain.get_module_inventory(), beacon.get_module_inventory()
			expect(pinv ~= nil and #pinv > 0 and not pinv.can_insert{ name = CARD, count = 1 }, "an assembling machine 2 takes the Acceleration Card")
			expect(binv ~= nil and #binv > 0 and not binv.can_insert{ name = CARD, count = 1 }, "a beacon takes the Acceleration Card")
			--- the machines of the game still take their own modules (the lists the mod gave them name every other category)
			expect(pinv ~= nil and pinv.can_insert{ name = "speed-module", count = 1 }, "an assembling machine 2 no longer takes a speed module")
			return
		end
		if tick < CHECK then return end
		local want = st.base * 5
		expect(math.abs(me.crafting_speed - want) < 1e-6, "five cards: crafting speed " .. me.crafting_speed .. ", not 5 times " .. st.base)
		expect(math.abs(me.consumption_bonus - (st.base_bonus + 4.0)) < 1e-6, "five cards: consumption bonus " .. me.consumption_bonus .. ", not " .. (st.base_bonus + 4.0))
		local ratio = me.crafting_speed / st.base
		inv.remove{ name = CARD, count = 3 }
		st.done = true
		me_report("ACCEL", "Acceleration Card", problems, "five module slots that take only the card, no assembling machine 2 or beacon takes it, five cards: "
			.. string.format("%.2f", ratio) .. " times the speed")
	end

	function T.running(check) check(storage.accel110 and storage.accel110.done, "Acceleration Card") end
	return T
end
