--!strict
-- Jumpr, window half: runs in each Tern window. Wiring only; the logic lives in lib/window/.
-- Events feed the binding (agents), the status pusher and the copies of the list (one per tab of
-- the deck session); jumpr:// links go to the router; the palette commands, the chords (the jumpr key toggles), and
-- the tab-title formatter that names a tab after its agent while focus is in the list. `startup.ensure` opens every
-- handler: `window_start` does not fire on a plugin reload into an open window, so the heartbeats start on load or
-- on the first event instead.

local agents = require("./lib/window/agents")
local block = require("./lib/window/block")
local compat = require("./lib/compat")
local copies = require("./lib/window/copies")
local diag = require("./lib/window/diag")
local leader = require("./lib/window/leader")
local pusher = require("./lib/window/pusher")
local router = require("./lib/window/router")
local startup = require("./lib/window/startup")
local tabs = require("./lib/window/tabs")

local ok_title, title_err = compat.tab_title(copies.tab_title)
if not ok_title then
	diag.error("window", "tab-title formatter: " .. tostring(title_err))
end

-- Three chords on every OS, the same on each: `cmd` is ⌘ on macOS and the Super/Win key on PCs in tern.bind chords.
local CHORD = "cmd+j"
local HIDE_CHORD = "cmd+shift+j"
local LAST_TAB_CHORD = "cmd+\\"
local JUMPR_SCHEME = "jumpr://"

tern.on("window_start", function(cx: WindowCx)
	startup.ensure(cx)
end)
startup.arm()

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	startup.ensure(cx)
	leader.take()
	agents.on_focus(ev.pane)
	block.on_focus(cx, ev)
	copies.on_focus(cx, ev)
	tabs.focus_seen(cx, ev)
	pusher.mark_dirty()
end)

-- One read of hosts and panes serves the binding and the copy map (pusher.rebuild); the tidy reads that scan, so an event costs one pane-list read.
tern.on("pane_created", function(_ev: PaneEvent, cx: WindowCx)
	startup.ensure(cx)
	pusher.rebuild(cx)
	pusher.mark_dirty()
end)

tern.on("pane_closed", function(_ev: PaneEvent, cx: WindowCx)
	startup.ensure(cx)
	if pusher.rebuild(cx) then
		copies.tidy(cx)
	end
	pusher.mark_dirty()
end)

tern.on("tab_created", function(_ev: TabEvent, cx: WindowCx)
	startup.ensure(cx)
	copies.ensure(cx)
end)

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	startup.ensure(cx)
	if agents.on_state(cx, ev) then
		pusher.mark_dirty()
	end
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	startup.ensure(cx)
	if agents.on_finished(cx, ev) then
		pusher.mark_dirty()
	end
end)

tern.on("budget", function(ev: BudgetEvent, cx: WindowCx)
	startup.ensure(cx)
	if ev.state == "resumed" then
		pusher.full(cx)
	end
end)

-- The focus chord's action: the toggle. A command, so the key is rebindable in settings.json keybinds.
tern.command({
	id = "toggle_focus",
	title = "Jumpr: toggle list",
	run = function(cx: WindowCx)
		startup.ensure(cx)
		block.toggle(cx)
	end,
})

tern.command({
	id = "focus",
	title = "Jumpr: focus list",
	run = function(cx: WindowCx)
		startup.ensure(cx)
		block.focus_list(cx)
	end,
})

tern.command({
	id = "diag",
	title = "Jumpr: diagnostics",
	run = function(cx: WindowCx)
		startup.ensure(cx)
		if diag.write(cx) ~= nil then
			diag.ask_host(cx, block.in_view(cx))
		end
	end,
})

tern.command({
	id = "toggle",
	title = "Jumpr: hide or show list",
	run = function(cx: WindowCx)
		startup.ensure(cx)
		copies.toggle(cx)
	end,
})

-- The hide chord's action: hide from anywhere, without the toggle's focus-list half.
tern.command({
	id = "hide_list",
	title = "Jumpr: hide list",
	run = function(cx: WindowCx)
		startup.ensure(cx)
		block.hide_list(cx)
	end,
})
-- The last-tab chord's action: jump to the tab focused before this one; pressing it again returns. The list's
-- highlight follows onto the agent of the tab it landed in.
tern.command({
	id = "last_tab",
	title = "Jumpr: last tab",
	run = function(cx: WindowCx)
		startup.ensure(cx)
		local agent = tabs.last_tab(cx)
		if agent ~= nil then
			pusher.follow(cx, agent)
		end
	end,
})
-- The jumpr key is `cmd+j`; `cmd+shift+j` hides the list from anywhere; `cmd+\` toggles the last tab.
tern.bind(CHORD, "plugin.jumpr.toggle_focus")
tern.bind(HIDE_CHORD, "plugin.jumpr.hide_list")
tern.bind(LAST_TAB_CHORD, "plugin.jumpr.last_tab")

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	startup.ensure(cx)
	if string.sub(link.url, 1, #JUMPR_SCHEME) ~= JUMPR_SCHEME then
		return nil
	end
	router.handle(cx, link.url, link.pane)
	return { handled = true }
end)
