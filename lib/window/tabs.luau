--!strict
-- The last-tab toggle: `cmd+\` jumps to the tab focused before this one
-- and lands on its AGENT pane — the pane the user works in, never the list's copy, even when they left that
-- tab through the list. Pressing the chord again returns, because the jump itself makes the tab it left
-- the new "last". One slot, scoped to the session in view. The jump also names the deck agent of the tab it landed
-- in, so the list's highlight can follow it (window.luau hands that to pusher.follow). The pure state decisions live
-- here, testable without Tern; the shell reads the session, resolves the landing pane and switches focus through
-- compat.

local compat = require("../compat")
local protocol = require("../shared/protocol")
local agents = require("./agents")
local diag = require("./diag")

local M = {}

-- The toggle's state: the session the history belongs to, the tab focused before the current one, the
-- current tab, and each tab's last focused agent pane (never a copy of the list). `prev` nil: focus has
-- not moved yet.
export type State = { session: number?, prev: number?, cur: number?, agent_pane: { [number]: number } }

function M.new_state(): State
	return { session = nil, prev = nil, cur = nil, agent_pane = {} }
end

local function clone_with(panes: { [number]: number }, tab: number, pane: number): { [number]: number }
	local out = table.clone(panes)
	out[tab] = pane
	return out
end

-- A focus event: a tab move pushes the tab it left into `prev` (a pane move inside one tab changes
-- nothing), a session switch starts over, and an agent pane becomes its tab's landing pane. Focus
-- landing in a copy advances the tab history but never becomes a landing pane.
function M.on_focus(state: State, session: number, tab: number, pane: number, is_block: boolean): State
	local out: State
	if state.session ~= session then
		out = { session = session, prev = nil, cur = tab, agent_pane = {} }
	elseif tab == state.cur then
		out = state
	else
		out = { session = session, prev = state.cur, cur = tab, agent_pane = state.agent_pane }
	end
	if is_block or out.agent_pane[tab] == pane then
		return out
	end
	return {
		session = out.session,
		prev = out.prev,
		cur = out.cur,
		agent_pane = clone_with(out.agent_pane, tab, pane),
	}
end

-- The tab `cmd+\` jumps to: the previous one of this session, nil when the history belongs to another
-- session or focus has not moved yet.
function M.target(state: State, session: number): number?
	if state.session ~= session then
		return nil
	end
	return state.prev
end

-- The state after a jump to `tab`, landing on `pane`: exactly what the jump's own focus event will
-- produce, so the module never waits for the event to be consistent.
function M.after_jump(state: State, tab: number, pane: number): State
	return { session = state.session, prev = state.cur, cur = tab, agent_pane = clone_with(state.agent_pane, tab, pane) }
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

-- `focus`: fold the event into the toggle's history. The pane is read authoritatively (`session_pane`),
-- so a copy the scan has not seen yet is still never recorded as a landing pane.
function M.focus_seen(cx: WindowCx, ev: FocusEvent)
	local session = compat.current_session(cx)
	if session == nil then
		return
	end
	local p = compat.session_pane(cx, ev.pane)
	state = M.on_focus(state, session.id, ev.tab, ev.pane, p ~= nil and p.block == protocol.BLOCK_KIND)
end

-- `cmd+\` and "Jumpr: last tab": jump to the tab focused before this one, landing on its agent pane —
-- the tab's last focused agent pane when there was one, else its first pane that is not a copy of the
-- list, else its focused pane. Silent when there is nothing to jump to; a target whose tab closed is
-- dropped, not jumped to. Returns the deck agent pane of the tab it jumped to (`tab_agent`), nil when it did not
-- jump or that tab holds no agent.
function M.last_tab(cx: WindowCx): number?
	local session = compat.current_session(cx)
	if session == nil then
		return nil
	end
	local want = M.target(state, session.id)
	if want == nil then
		return nil
	end
	local tabs = compat.tabs_list(cx)
	if tabs == nil then
		return nil
	end
	local info: TabInfo? = nil
	for _, t in tabs do
		if t.id == want and t.session == session.id then
			info = t
			break
		end
	end
	if info == nil then
		state = M.new_state()
		return nil
	end
	local pane: number? = state.agent_pane[want]
	if pane ~= nil and compat.session_pane(cx, pane) == nil then
		pane = nil
	end
	local panes = compat.tab_panes(cx, want)
	if pane == nil and panes ~= nil then
		for _, p in panes do
			local info_p = compat.session_pane(cx, p)
			if info_p ~= nil and info_p.block ~= protocol.BLOCK_KIND then
				pane = p
				break
			end
		end
	end
	local land: number = if pane ~= nil then pane else (info :: TabInfo).pane
	state = M.after_jump(state, want, land)
	local ok, err = compat.focus(cx, land)
	if not ok then
		diag.error("tabs", "jump to the last tab: " .. tostring(err))
		return nil
	end
	return M.tab_agent(land, panes or {}, agents.is_agent)
end

return M
