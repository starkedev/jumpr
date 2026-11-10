--!strict
-- Starting the window half: the diagnostics, the leader's 2 s heartbeat, the
-- pusher's 1 s heartbeat and 30 s resync (with its first full snapshot), and the copies of the list. Tern fires
-- `window_start` once per plugin per window, not again on a plugin reload into an open window (a `git pull` of the
-- linked checkout, `tern plugin reload`), whose modules re-run with fresh state; so the start also runs from a timer
-- armed when this module loads (a window-context timer gets a fresh cx) and from every event and command that
-- carries a cx. Once per VM: every call after the first is one boolean check.

local compat = require("../compat")
local copies = require("./copies")
local diag = require("./diag")
local leader = require("./leader")
local pusher = require("./pusher")

local M = {}

local started = false

-- Starts the window half the first time it runs in this VM; a no-op after that.
function M.ensure(cx: WindowCx)
	if started then
		return
	end
	started = true
	diag.start()
	leader.start()
	pusher.start(cx)
	copies.ensure(cx)
end

-- Arms the load-time start: the next timer tick after the module loads, so a reloaded window starts its
-- heartbeats without waiting for an event (a fresh window's `window_start` usually gets there first).
function M.arm()
	compat.timer(0, function(tcx: WindowCx?)
		if tcx ~= nil then
			M.ensure(tcx)
		end
	end)
end

return M
