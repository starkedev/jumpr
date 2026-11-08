--!strict
-- Focus of the list: the focus chord's toggle,
-- `focus_list`, `back`, and the last non-deck pane focused in each host's deck session. The copies'
-- existence belongs to copies.luau; this module only moves focus.

local compat = require("../compat")
local copies = require("./copies")
local diag = require("./diag")
local leader = require("./leader")
local pusher = require("./pusher")
local protocol = require("../shared/protocol")

local M = {}

local BLOCK_KIND = protocol.BLOCK_KIND

type Recorded = { pane: number, session: string }

local last_pane: { [string]: Recorded } = {}

local function pane_key(pane: number): string
	return string.format("%.0f", pane)
end

-- The host and session in view.
local function view(cx: WindowCx): (ManagedHost?, ManagedSession?)
	local host, host_err = compat.current_host(cx)
	local session, session_err = compat.current_session(cx)
	if host == nil or session == nil then
		diag.error("block", "view: " .. tostring(host_err or session_err))
		return nil, nil
	end
	return host, session
end

-- `focus`: record a non-deck pane of the deck session, which `back` returns to. Focus landing in a copy never
-- changes it.
function M.on_focus(cx: WindowCx, ev: FocusEvent)
	local host, session = view(cx)
	if host == nil or session == nil then
		return
	end
	local p = compat.session_pane(cx, ev.pane)
	if p == nil or p.block == BLOCK_KIND then
		return
	end
	local deck_session = pusher.session_of(host.name)
	if deck_session == nil or deck_session == session.name then
		last_pane[host.name] = { pane = ev.pane, session = session.name }
	end
end

-- The copy of the list in the tab in view (else any copy on the host in view), and that host's name.
function M.in_view(cx: WindowCx): (number?, string?)
	local host = view(cx)
	if host == nil then
		return nil, nil
	end
	pusher.scan(cx)
	local focused = compat.session_focused(cx)
	local tab = if focused ~= nil then compat.session_tab_of(cx, focused) else nil
	return pusher.copy_in_tab(tab) or pusher.blocks_for(host.name)[1], host.name
end

-- `jumpr://back`: focus the last non-deck pane seen focused in `host`'s deck session.
function M.back(cx: WindowCx, host: string): (boolean, string?)
	local rec = last_pane[host]
	if rec == nil then
		return false, "no pane to go back to on " .. host
	end
	local p = compat.session_pane(cx, rec.pane)
	if p == nil then
		last_pane[host] = nil
		return false, "the last pane on " .. host .. " is gone"
	end
	return compat.focus(cx, rec.pane)
end

-- "Jumpr: focus list", and the toggle's outside-the-list path: show the copies first if hidden, then focus
-- the copy in the tab in view (opened first if the tab has none), or a copy in another tab of the deck session,
-- which switches the view to it (compat.focus switches to a session another is shown). Under Esc mode B, pressed
-- in the list, it goes back to the agent instead.
function M.focus_list(cx: WindowCx)
	local host = view(cx)
	if host == nil then
		diag.error("block", "focus the list: no host or session in view")
		return
	end
	leader.take()
	if leader.hidden() then
		copies.show_all(cx)
		return
	end
	pusher.scan(cx)
	local focused = compat.session_focused(cx)
	if leader.esc_mode() == "B" and focused ~= nil and pusher.is_block(focused) then
		local ok, err = M.back(cx, host.name)
		if not ok then
			compat.toast(cx, "info", "Jumpr: " .. tostring(err))
		end
		return
	end
	local tab = if focused ~= nil then compat.session_tab_of(cx, focused) else nil
	local copy = pusher.copy_in_tab(tab)
	if copy == nil then
		if copies.ensure(cx, true) == "deferred" then
			return
		end
		copy = pusher.copy_in_tab(tab)
	end
	if copy == nil then
		copy = pusher.blocks_for(host.name)[1]
	end
	if copy == nil then
		-- The chord reaches Tern, so say why nothing moved: no copy anywhere on this host, none to open.
		diag.error("block", "focus the list: no copy of the list on " .. host.name .. " and none could be opened")
		compat.toast(cx, "info", "Jumpr has no list on " .. host.name)
		return
	end
	local ok, err = compat.focus(cx, copy)
	if not ok then
		diag.error("block", "focus the list on " .. host.name .. ": " .. tostring(err))
		compat.toast(cx, "error", "Jumpr could not focus its list on " .. host.name, err)
	end
end

diag.provide("block", function(): any
	local back: { [string]: any } = {}
	for host, rec in last_pane do
		back[host] = { pane = pane_key(rec.pane), session = rec.session }
	end
	return { last_non_deck = back }
end)

-- The focus chord and "Jumpr: toggle list": pressed while focus is not in a copy it shows and focuses the
-- list (focus_list); pressed while focus is in a copy it goes back to the pane the user came from (the Esc `back`
-- path) and hides the list (closes every copy, as "Jumpr: hide or show list" does). Esc keeps its own behaviour.
-- Back runs before the copies close, so focus lands in the agent pane and stays there when they go.
function M.toggle(cx: WindowCx)
	local host = view(cx)
	if host == nil then
		diag.error("block", "toggle the list: no host or session in view")
		return
	end
	leader.take()
	pusher.scan(cx)
	local focused = compat.session_focused(cx)
	if focused ~= nil and pusher.is_block(focused) then
		local ok, err = M.back(cx, host.name)
		if not ok then
			compat.toast(cx, "info", "Jumpr: " .. tostring(err))
		end
		copies.hide(cx)
		return
	end
	M.focus_list(cx)
end

-- "Jumpr: hide list" and the hide chord: pressed while focus is in a copy of the list it goes back first (the Esc
-- `back` path, so focus lands in the agent pane and stays there when the copies close), then closes every copy.
-- From anywhere else it just hides. It never shows or focuses the list, and when the list is already hidden it
-- changes nothing (there is no copy in focus and `copies.hide` finds none).
function M.hide_list(cx: WindowCx)
	local host = view(cx)
	if host == nil then
		diag.error("block", "hide the list: no host or session in view")
		return
	end
	leader.take()
	pusher.scan(cx)
	local focused = compat.session_focused(cx)
	if focused ~= nil and pusher.is_block(focused) then
		local ok, err = M.back(cx, host.name)
		if not ok then
			compat.toast(cx, "info", "Jumpr: " .. tostring(err))
		end
	end
	copies.hide(cx)
end

return M
