--- Runtime test of me-network issue #603: the wireless refill. A network with iron plates (500), copper plates (100), an ME
--- Wireless Access Point (range 32 without boosters) and a character without a player beside it, in modular armour with the
--- ME Wireless Module linked to the network (a record of the refill queue, remote refill_add). Its logistic section asks for
--- 150 iron plates, 20 copper plates and 10 steel plates (the network has none); its trash slots hold 7 gears.
--- * through the queue: after a few visits the character holds 150 iron plates (one stack per request and visit: 100, then
---   50) and 20 copper plates, the gears are in the network, the network lost what the character got, the steel request
---   stays open, and the controllers paid for every item (the energy of the network's controllers, remote refill_paid);
--- * a visit (remote refill_visit) with energy for 5 items moves 5 (the controller's buffer set to one tick's draw plus
---   5 items' worth);
--- * out of the access point's range (teleported 100 tiles away) nothing moves; back inside, it does;
--- * without personal logistics (the force's character_logistic_requests off) nothing moves.
--- Loaded by control.lua like qualityterm.lua.

local NET, WL = "gregtorio-me-network", "gregtorio-me-wireless"
local BX, BY = 20, 80                    -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 140, 400

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "wireless refill"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 500, ["copper-plate"] = 100 }, "16k")
		local ap = me_place(s, fails, what, "me-wireless-access-point", BX + 12.5, BY + 2.5)
		H.me_connect(fails, what, { ctrl, drive, ap })
		local c = s.create_entity{ name = "character", position = { BX + 16, BY + 6 }, force = "player" }
		if not c then fails[#fails + 1] = what .. ": no character" return fails end
		c.get_inventory(defines.inventory.character_armor).insert{ name = "modular-armor" }
		if not (c.grid and c.grid.put{ name = "me-wireless-module" }) then fails[#fails + 1] = what .. ": the module is not in the grid" end
		storage.wrefill603_scene = { ctrl = ctrl, ap = ap, c = c }
		return fails
	end

	function T.tick()
		local st = storage.wrefill603
		if (st and st.done) or game.tick < START then return end
		local sc = storage.wrefill603_scene
		local ctrl, c = sc and sc.ctrl, sc and sc.c
		if not st then
			st = { problems = {}, phase = "start" }
			storage.wrefill603 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish(note)
			st.done = true
			me_report("WREFILL", "ME wireless refill (issue #603)", problems, note or "")
		end
		if not (ctrl and ctrl.valid and c and c.valid) then expect(false, "the test blocks were not built") return finish() end
		local force = c.force
		local main = c.get_inventory(defines.inventory.character_main)
		local function have(name) return main.get_item_count(name) end
		local function count(name) return remote.call(NET, "count", ctrl, name) end
		local unit = -c.unit_number

		if st.phase == "start" then
			st.logistics = force.character_logistic_requests
			force.character_logistic_requests = true
			if force.character_trash_slot_count < 10 then force.character_trash_slot_count = 10 end
			local sec = c.get_requester_point().add_section()
			sec.set_slot(1, { value = { name = "iron-plate", quality = "normal", comparator = "=" }, min = 150 })
			sec.set_slot(2, { value = { name = "copper-plate", quality = "normal", comparator = "=" }, min = 20 })
			sec.set_slot(3, { value = { name = "steel-plate", quality = "normal", comparator = "=" }, min = 10 })
			local trash = c.get_inventory(defines.inventory.character_trash)
			expect(trash and trash.insert{ name = "iron-gear-wheel", count = 7 } == 7, "7 gears into the trash slots")
			st.paid0 = remote.call(WL, "refill_paid")
			remote.call(WL, "refill_add", c, ctrl)
			st.phase, st.tick = "fill", game.tick
			return
		end

		if st.phase == "fill" then
			if have("iron-plate") < 150 then
				if game.tick > st.tick + TIMEOUT then
					expect(false, "the requests were not filled: iron " .. have("iron-plate") .. ", copper " .. have("copper-plate"))
					return finish()
				end
				return
			end
			expect(have("iron-plate") == 150 and have("copper-plate") == 20, "the character holds 150 iron and 20 copper plates: "
				.. have("iron-plate") .. ", " .. have("copper-plate"))
			expect(count("iron-plate") == 350 and count("copper-plate") == 80, "the network lost what the character got: "
				.. count("iron-plate") .. ", " .. count("copper-plate"))
			expect(count("iron-gear-wheel") == 7, "the trash went into the network: " .. count("iron-gear-wheel") .. " gears")
			expect(have("steel-plate") == 0, "no steel plates (the network has none)")
			local paid = remote.call(WL, "refill_paid") - st.paid0
			local per = remote.call(WL, "refill_energy")
			expect(math.abs(paid - (150 + 20 + 7) * per) < 1e-6, "the controllers paid " .. paid .. " J for 177 items at " .. per .. " J")
			--- energy for five items only
			main.remove{ name = "iron-plate", count = 50 }
			local e = ctrl
			e.energy = e.power_usage + 5 * per
			local moved = remote.call(WL, "refill_visit", unit)
			expect(moved == 5 and have("iron-plate") == 105, "with energy for 5 items a visit moves 5: " .. tostring(moved) .. ", "
				.. have("iron-plate"))
			--- out of range
			st.home = c.position
			c.teleport{ c.position.x + 100, c.position.y }
			main.remove{ name = "copper-plate", count = 20 }
			st.phase, st.tick, st.copper = "away", game.tick, count("copper-plate")
			return
		end

		if st.phase == "away" then
			if game.tick < st.tick + 200 then return end
			expect(have("copper-plate") == 0 and count("copper-plate") == st.copper, "out of range nothing moves: " .. have("copper-plate"))
			c.teleport(st.home)
			st.phase, st.tick = "back", game.tick
			return
		end

		if st.phase == "back" then
			if have("copper-plate") < 20 then
				if game.tick > st.tick + TIMEOUT then
					expect(false, "back in range the copper plates did not come: " .. have("copper-plate"))
					return finish()
				end
				return
			end
			force.character_logistic_requests = false
			main.remove{ name = "copper-plate", count = 20 }
			local moved = remote.call(WL, "refill_visit", unit)
			expect(moved == 0 and have("copper-plate") == 0, "without personal logistics nothing moves: " .. tostring(moved))
			force.character_logistic_requests = st.logistics
			return finish("150 iron and 20 copper plates refilled, 7 gears of the trash stored, energy paid per item; 5 items "
				.. "with energy for 5; nothing out of range or without personal logistics")
		end
	end

	function T.running(check) check(storage.wrefill603 and storage.wrefill603.done, "ME wireless refill") end
	return T
end
