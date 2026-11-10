--!strict
-- The last-tab toggle: `cmd+\` jumps to the tab the user last worked in and lands on its AGENT pane — the pane
-- the user works in, never the list's copy, even when they left that tab through the list. Pressing the chord
-- again returns, because the jump itself enters the tab it lands in. Scoped to the session in view. The jump also
-- names the deck agent of the tab it landed in, so the list's highlight can follow it (window.luau hands that to
-- pusher.follow). The pure state decisions live here, testable without Tern; the shell reads the session,
-- resolves the landing pane and switches focus through compat.
--
-- Only ENTERED tabs count. A tab is entered when focus lands on a pane in it that is not a copy of the list (an
-- agent's pane or any ordinary pane): Enter from the list, a click into the agent pane, Tern's own tab switching.
-- Focus landing on a copy never enters its tab: moving through the list with j/k shows each agent's tab and puts
-- focus in that tab's copy, and those previews must not push the tab the user was working in out of the history.

local compat = require("../compat")
local protocol = require("../shared/protocol")
local agents = require("./agents")
local diag = require("./diag")

local M = {}

-- How many entered tabs the history keeps: two make the toggle, the rest stand in when one of them closes.
local DEPTH = 8

-- The toggle's state: the session the history belongs to, the tab focus is in now (entered or not), the entered
-- tabs newest first without repeats, and each tab's last focused pane that is not a copy of the list. `here` nil:
-- no focus event yet.
export type State = {
	session: number?,
	here: number?,
	entered: { number },
	agent_pane: { [number]: number },
}

function M.new_state(): State
	return { session = nil, here = nil, entered = {}, agent_pane = {} }
end

-- `state` with `tab` entered (moved to the front of the history) and focus in it; `pane` becomes the tab's landing
-- pane unless it is nil. Never mutates `state`.
local function enter(state: State, tab: number, pane: number?): State
	local entered = { tab }
	for _, t in state.entered do
		if t ~= tab and #entered < DEPTH then
			table.insert(entered, t)
		end
	end
	local panes = state.agent_pane
	if pane ~= nil and panes[tab] ~= pane then
		panes = table.clone(panes)
		panes[tab] = pane
	end
	return { session = state.session, here = tab, entered = entered, agent_pane = panes }
end

-- A focus event: a session switch starts over; focus always moves `here`; focus on a pane that is not a copy of the
-- list enters its tab and makes that pane the tab's landing pane, while focus on a copy (a preview, `cmd+j`) enters
-- nothing. Moving between the copy and the agent inside one tab only ever re-enters that same tab.
function M.on_focus(state: State, session: number, tab: number, pane: number, is_list: boolean): State
	local base = state
	if state.session ~= session then
		base = { session = session, here = nil, entered = {}, agent_pane = {} }
	end
	if is_list then
		return { session = base.session, here = tab, entered = base.entered, agent_pane = base.agent_pane }
	end
	return enter(base, tab, pane)
end

-- The tab `cmd+\` jumps to: the newest entered tab of this session that is not the one focus is in and is still
-- open (`is_open`). From the tab the user works in, that is the tab entered before it; from a tab only previewed
-- through the list, it is the tab the user last worked in. A closed tab is skipped for the one entered before it.
-- nil when the history belongs to another session or holds no other open tab.
function M.target(state: State, session: number, is_open: (number) -> boolean): number?
	if state.session ~= session then
		return nil
	end
	for _, t in state.entered do
		if t ~= state.here and is_open(t) then
			return t
		end
	end
	return nil
end

-- `state` without the tabs that are no longer open, so closed tabs neither linger in the history nor keep a landing
-- pane. Returns `state` itself when nothing closed.
function M.prune(state: State, is_open: (number) -> boolean): State
	local entered: { number } = {}
	for _, t in state.entered do
		if is_open(t) then
			table.insert(entered, t)
		end
	end
	local panes: { [number]: number } = {}
	local dropped = #entered ~= #state.entered
	for t, p in state.agent_pane do
		if is_open(t) then
			panes[t] = p
		else
			dropped = true
		end
	end
	if not dropped then
		return state
	end
	return { session = state.session, here = state.here, entered = entered, agent_pane = panes }
end

-- The state after a jump to `tab`, landing on `pane`: the jump enters the tab even when it can only land on the
-- list's copy there (its other panes have closed), because the user chose that tab; a copy never becomes the tab's
-- landing pane. This is what the jump's own focus event would produce for a non-copy pane, so the module never
-- waits for the event to be consistent.
function M.after_jump(state: State, tab: number, pane: number, landed_on_list: boolean): State
	return enter(state, tab, if landed_on_list then nil else pane)
end

-- The deck agent pane of the tab a jump landed in on `land`: `land` itself when it is an agent, else the tab's
-- lowest agent pane among `panes` (a shell the jump landed on still names the agent beside it), nil when the tab
-- holds no agent.
function M.tab_agent(land: number, panes: { number }, is_agent: (number) -> boolean): number?
	if is_agent(land) then
		return land
	end
	local best: number? = nil
	for _, p in panes do
		if is_agent(p) and (best == nil or p < best) then
			best = p
		end
	end
	return best
end

local state = M.new_state()

-- Whether `pane` is a copy of the list, read authoritatively (`session_pane`), so a copy the scan has not seen yet
-- still counts as one.
local function is_copy(cx: WindowCx, pane: number): boolean
	local p = compat.session_pane(cx, pane)
	return p ~= nil and p.block == protocol.BLOCK_KIND
end

-- `focus`: fold the event into the toggle's history; focus on a copy of the list enters no tab.
function M.focus_seen(cx: WindowCx, ev: FocusEvent)
	local session = compat.current_session(cx)
	if session == nil then
		return
	end
	state = M.on_focus(state, session.id, ev.tab, ev.pane, is_copy(cx, ev.pane))
end

-- `cmd+\` and "Jumpr: last tab": jump to the tab the user last worked in (`target`; from that tab itself, the one
-- entered before it), landing on its agent pane — the tab's last focused pane that is not a copy of the list when
-- it is still there, else its first pane that is not a copy, else its focused pane. Closed tabs are dropped from the
-- history first. Silent when there is nothing to jump to. Returns the deck agent pane of the tab it jumped to
-- (`tab_agent`), nil when it did not jump or that tab holds no agent.
function M.last_tab(cx: WindowCx): number?
	local session = compat.current_session(cx)
	if session == nil then
		return nil
	end
	local tabs = compat.tabs_list(cx)
	if tabs == nil then
		return nil
	end
	local open: { [number]: TabInfo } = {}
	for _, t in tabs do
		if t.session == session.id then
			open[t.id] = t
		end
	end
	local function is_open(tab: number): boolean
		return open[tab] ~= nil
	end
	state = M.prune(state, is_open)
	local want = M.target(state, session.id, is_open)
	if want == nil then
		return nil
	end
	local info = open[want] :: TabInfo
	local pane: number? = state.agent_pane[want]
	if pane ~= nil and compat.session_pane(cx, pane) == nil then
		pane = nil
	end
	local panes = compat.tab_panes(cx, want)
	if pane == nil and panes ~= nil then
		for _, p in panes do
			if compat.session_pane(cx, p) ~= nil and not is_copy(cx, p) then
				pane = p
				break
			end
		end
	end
	local land: number = if pane ~= nil then pane else info.pane
	state = M.after_jump(state, want, land, pane == nil and is_copy(cx, land))
	local ok, err = compat.focus(cx, land)
	if not ok then
		diag.error("tabs", "jump to the last tab: " .. tostring(err))
		return nil
	end
	return M.tab_agent(land, panes or {}, agents.is_agent)
end

return M
