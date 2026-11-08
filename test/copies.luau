--!strict

local Runtime = require("../lib/window/copies_runtime")
local Core = require("../lib/window/copies_core")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function managed_host(id: number, name: string, sessions: { number }): ManagedHost
	return {
		id = id,
		name = name,
		kind = "remote",
		address = nil,
		state = "connected",
		detail = nil,
		identity = nil,
		current = true,
		rtt_ms = nil,
		sessions = sessions,
		panes = {},
	}
end

local function managed_session(id: number, name: string, host: number): ManagedSession
	return { id = id, name = name, host = host, current = true, locked = false, note = nil, tabs = 2 }
end

local function session_info(id: number, name: string, tabs: { number }): SessionInfo
	return { id = id, name = name, current = true, locked = false, tabs = tabs }
end

type State = {
	host: ManagedHost,
	session: ManagedSession,
	rows: { SessionInfo },
	listed: { ManagedSession },
	deck: string?,
	hidden: boolean,
	copies: { [number]: number },
	agents: { [string]: number },
	pane_tabs: { [number]: number },
	timers: { any },
	opens: { number },
	toasts: { { level: string, text: string, sub: string? } },
	focused: number?,
	switches: { number },
	new_block_error: string?,
	agent_title: string?,
}

local function fixture(): (any, State, any)
	local state: State = {
		host = managed_host(1, "devbox", { 20 }),
		session = managed_session(10, "devbox", 1),
		rows = { session_info(20, "devbox", { 201, 202 }) },
		listed = { managed_session(20, "devbox", 1) },
		deck = "devbox",
		hidden = false,
		copies = {},
		agents = { a = 501, b = 502 },
		pane_tabs = { [501] = 201, [502] = 202 },
		timers = {},
		opens = {},
		toasts = {},
		focused = nil,
		switches = {},
		new_block_error = nil,
		agent_title = nil,
	}
	local compat = {}
	function compat.current_host(_cx: any): ManagedHost
		return state.host
	end
	function compat.current_session(_cx: any): ManagedSession
		return state.session
	end
	function compat.session_tabs(_cx: any): { SessionInfo }
		return state.rows
	end
	function compat.sessions_list(_cx: any): { ManagedSession }
		return state.listed
	end
	function compat.session_focused(_cx: any): number?
		return state.focused
	end
	function compat.session_tab_of(_cx: any, pane: number): number?
		return state.pane_tabs[pane]
	end
	function compat.leftmost_pane(_cx: any, tab: number): number
		return tab * 10
	end
	function compat.new_block(_cx: any, _kind: string, _args: { string }, _how: string, opts: any): (number?, string?)
		local tab = opts.target / 10
		table.insert(state.opens, tab)
		if state.new_block_error ~= nil then
			return nil, state.new_block_error
		end
		local pane = 1000 + tab
		state.copies[tab] = pane
		state.pane_tabs[pane] = tab
		return pane, nil
	end
	function compat.toast(_cx: any, level: string, text: string, sub: string?)
		table.insert(state.toasts, { level = level, text = text, sub = sub })
	end
	function compat.focus(_cx: any, pane: number): (boolean, string?)
		state.focused = pane
		return true, nil
	end
	function compat.close(_cx: any, pane: number): (boolean, string?)
		for tab, copy in state.copies do
			if copy == pane then
				state.copies[tab] = nil
			end
		end
		return true, nil
	end
	function compat.session_switch(_cx: any, id: number): (boolean, string?)
		table.insert(state.switches, id)
		return true, nil
	end

	local agents = {}
	function agents.pane_for(_host: string, id: string): number?
		return state.agents[id]
	end
	function agents.rebuild(_cx: any): boolean
		return true
	end

	local pusher = {}
	function pusher.scan(_cx: any): boolean
		return true
	end
	function pusher.session_of(_host: string): string?
		return nil
	end
	function pusher.blocks_for(_host: string): { number }
		local out: { number } = {}
		for _, pane in state.copies do
			table.insert(out, pane)
		end
		table.sort(out)
		return out
	end
	function pusher.copy_in_tab(tab: number?): number?
		if tab == nil then
			return nil
		end
		return state.copies[tab]
	end
	function pusher.mark_dirty() end
	function pusher.copies_by_tab(): { [number]: { number } }
		return {}
	end
	function pusher.accompanied(_tab: number): boolean
		return false
	end
	function pusher.block_info(_pane: number): string?
		return nil
	end
	function pusher.agent_title(_tab: number, _pane: number): string?
		return state.agent_title
	end

	local leader = {}
	function leader.is_leader(): boolean
		return true
	end
	function leader.leading(): boolean
		return true
	end
	function leader.deck_session(_host: string): string?
		return state.deck
	end
	function leader.set_deck_session(_host: string, session: string?)
		state.deck = session
	end
	function leader.hidden(): boolean
		return state.hidden
	end
	function leader.set_hidden(hidden: boolean)
		state.hidden = hidden
	end
	function leader.take() end

	local diag = {}
	function diag.error(_source: string, _text: string) end
	function diag.provide(_source: string, _provider: () -> any) end

	local fake_tern = {}
	function fake_tern.now(): number
		return 10000
	end
	function fake_tern.timer(_ms: number, callback: any)
		table.insert(state.timers, callback)
	end

	local protocol = { BLOCK_KIND = "jumpr.list" }
	function protocol.launch_args(session: string, host: string): { string }
		return { "session=" .. session, "host=" .. host }
	end

	local copies = Runtime.new({
		compat = compat,
		agents = agents,
		copies_core = Core,
		diag = diag,
		leader = leader,
		protocol = protocol,
		pusher = pusher,
		tern = fake_tern,
	})
	return copies, state, {}
end

local function run_timer(state: State, cx: any)
	local callback = table.remove(state.timers, 1)
	assert(callback ~= nil, "expected an armed timer")
	callback(cx)
end

-- The production show path accepts a stale generation, performs no effects, and coalesces retries.
local copies, state, cx = fixture()
local ok, why = copies.show(cx, "devbox", "a")
check(ok and why == nil, "router-facing show accepts a transitional generation")
check(#state.opens == 0 and #state.toasts == 0 and #state.timers == 1, "transition opens and toasts nothing")
local second_ok = copies.show(cx, "devbox", "b")
check(second_ok and #state.timers == 1, "repeated incoherence keeps one timer and accepts the latest show")
run_timer(state, cx)
check(#state.opens == 0 and #state.timers == 1, "continued incoherence rearms one serial retry")
state.session = managed_session(20, "devbox", 1)
run_timer(state, cx)
check(
	#state.opens == 2 and state.opens[1] == 201 and state.opens[2] == 202,
	"coherent retry opens each missing tab once"
)
check(state.focused == 1202, "coherent retry re-resolves and focuses the latest selected agent's exact tab")

-- A user-visible view change cancels a deferred show and invalidates its armed callback.
copies, state, cx = fixture()
copies.show(cx, "devbox", "a")
state.session = managed_session(30, "other", 1)
copies.on_focus(cx, { pane = 700, tab = 301 })
run_timer(state, cx)
check(#state.opens == 0 and state.focused == nil and #state.timers == 0, "view change cancels deferred effects")

-- Hiding before delivery cancels deferred focus and prevents the stale timer from reopening copies.
copies, state, cx = fixture()
copies.show(cx, "devbox", "a")
copies.hide(cx)
run_timer(state, cx)
check(state.hidden and #state.opens == 0 and state.focused == nil, "hide cancels deferred show before retry")

-- show_all waits through asynchronous session-switch propagation, then opens and focuses the target session.
copies, state, cx = fixture()
state.hidden = true
state.deck = "deck"
state.host.sessions = { 10, 30 }
state.listed = { managed_session(10, "devbox", 1), managed_session(30, "deck", 1) }
state.rows = { session_info(10, "devbox", { 101 }), session_info(30, "deck", { 301, 302 }) }
copies.show_all(cx)
check(
	#state.switches == 1 and state.switches[1] == 30 and #state.timers == 1,
	"show_all requests the recorded deck session and arms one wait"
)
copies.on_focus(cx, { pane = 700, tab = 101 })
check(#state.timers == 1, "an old-source focus event does not cancel session-switch propagation")
run_timer(state, cx)
check(#state.opens == 0 and #state.timers == 1, "old-session APIs are treated as switch propagation, not failure")
state.session = managed_session(30, "deck", 1)
state.host.sessions = { 30 }
state.focused = 701
state.pane_tabs[701] = 301
run_timer(state, cx)
check(
	#state.opens == 2 and state.focused == 1301,
	"show_all opens and focuses after the target session becomes coherent"
)

-- Native new_block errors remain on the existing visible failure path.
copies, state, cx = fixture()
state.session = managed_session(20, "devbox", 1)
state.new_block_error = "native open failed"
local outcome = copies.ensure(cx)
check(outcome == "ready", "coherent identity completes even when native opens fail")
check(
	#state.toasts == 1
		and state.toasts[1].text == "Jumpr could not open its list on devbox"
		and state.toasts[1].sub == "native open failed",
	"genuine new_block errors remain visible"
)

-- Same-name rows and sessions from another host never satisfy exact current identity.
local duplicate = Core.coherent_tabs(
	managed_host(1, "devbox", { 10 }),
	managed_session(10, "devbox", 1),
	{ session_info(30, "devbox", { 301 }) }
)
check(duplicate == nil, "a duplicate session name from another host is never selected")
local wrong_host = Core.coherent_tabs(
	managed_host(1, "devbox", { 10 }),
	managed_session(10, "devbox", 2),
	{ session_info(10, "devbox", { 101 }) }
)
check(wrong_host == nil, "the current session must belong to the current host")

-- The tab-title formatter yields to a name `r` gave the tab, and otherwise shows the agent's title.
local function tab_info(name: string?): TabInfo
	return {
		id = 201,
		session = 1,
		color = nil,
		position = 1,
		pane = 1001,
		name = name,
		cwd = "",
		program = "omp",
		title = "fix the header",
		panes = 1,
		busy = false,
	}
end
copies, state, cx = fixture()
state.agent_title = "fix the header"
check(copies.tab_title(tab_info(nil)) == "fix the header", "an unnamed tab shows its agent's title")
check(copies.tab_title(tab_info("auth-refactor")) == nil, "a named tab keeps the name `r` gave it")
check(copies.tab_title(tab_info("")) == "fix the header", "a blank name is no name: Tern restores the pane's label")

print("Copies: " .. checks .. " checks passed")
