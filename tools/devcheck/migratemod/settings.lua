--- Issue #503 (`devcheck.py migrate --removed-items`): which test items data.lua makes. "none" (every other run): none.
--- "old" (the save): devcheck-renamed-item, devcheck-removed-item and devcheck-new-item. "new" (the load): devcheck-new-item
--- only, and devcheck-renamed-item -> devcheck-new-item through ME_NETWORK.replace_item.
data:extend({ {
	type = "string-setting",
	name = "zz-me-network-devcheck-migrate-items",
	setting_type = "startup",
	default_value = "none",
	allowed_values = { "none", "old", "new" },
} })
