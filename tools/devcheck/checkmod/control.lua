--- Issue #514: the runtime part of `devcheck.py check` (its map is made with --create, so on_init runs): the ME Terminal's
--- row above its tabs as the window builds it, in a stand-in (remote gregtorio-me-gui terminal_top_view: the harness has no
--- player), one tab-separated row per element: its type and name. devcheck.py checks that the quality filter is there with
--- the quality mod and not without it (--base-only).
script.on_init(function()
	local gui = remote.interfaces["gregtorio-me-gui"]
	if not (gui and gui.terminal_top_view) then return end      -- (an older me-network)
	local rows = {}
	for _, c in ipairs(remote.call("gregtorio-me-gui", "terminal_top_view")) do
		rows[#rows + 1] = c.type .. "\t" .. (c.name or "")
	end
	log("DEVCHECK-TERMTOP-BEGIN\n" .. table.concat(rows, "\n") .. "\nDEVCHECK-TERMTOP-END")
end)
