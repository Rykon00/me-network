--- Runtime check of me-network issue #511, used by qbridge.lua and wlink.lua at their last tick: the frequency field of the
--- window of a quantum bridge or a wireless link (built into a stand-in frame, remote gregtorio-me-gui qbridge_view: the
--- harness has no player) keeps what is typed over the refreshes, and shows a frequency set elsewhere at the next one.
--- `freq`: the block's frequency, `other`: one to set and take back (the block ends on `freq` again).

local QB, GUI = "gregtorio-me-qbridge", "gregtorio-me-gui"

return function(problems, entity, freq, other, name)
	local function expect(ok, msg, v)
		if not ok then problems[#problems + 1] = "frequency field (issue #511): " .. msg .. ": " .. serpent.line(v) end
	end
	local v = remote.call(GUI, "qbridge_view", name, entity)
	expect(v.ok and v.text == tostring(freq) and v.shown == freq, "opened on frequency " .. freq, v)
	v = remote.call(GUI, "qbridge_view", name, entity, "12")
	expect(v.ok and v.text == "12", "12 typed, then a refresh", v)
	v = remote.call(GUI, "qbridge_view", name, entity)
	expect(v.text == "12", "12 typed, then a second refresh", v)
	remote.call(QB, "set_frequency", entity, other)
	v = remote.call(GUI, "qbridge_view", name, entity)
	expect(v.text == tostring(other) and v.shown == other, "frequency " .. other .. " set elsewhere, then a refresh", v)
	remote.call(QB, "set_frequency", entity, freq)
	v = remote.call(GUI, "qbridge_view", name, entity)
	expect(v.text == tostring(freq), "frequency " .. freq .. " set back, then a refresh", v)
	remote.call(GUI, "stand_in_forget", name)
end
