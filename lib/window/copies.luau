--!strict
-- Production dependencies for the per-window copies runtime.

local Runtime = require("./copies_runtime")

return Runtime.new({
	compat = require("../compat"),
	agents = require("./agents"),
	copies_core = require("./copies_core"),
	diag = require("./diag"),
	leader = require("./leader"),
	protocol = require("../shared/protocol"),
	pusher = require("./pusher"),
	tern = tern,
})
