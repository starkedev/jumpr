--!strict
-- The copies of the list in every tab of a machine's deck session, and showing the selected agent's tab.
-- Each tab holds one `jumpr.list` block on its left, opened once at a fixed
-- width beside the tab's leftmost pane and never moved or resized after, so nothing reflows. Moving the selection
-- onto an agent asks the window (`jumpr://show`) to focus the copy in that agent's tab, which brings the tab to the
-- front with focus in the list. Only the leader window opens, closes or focuses a copy. The copy map itself is the
-- pusher's scan (`pusher.copy_in_tab`).

local compat = require("../compat")
local protocol = require("../shared/protocol")
local agents = require("./agents")
local diag = require("./diag")
local leader = require("./leader")
local pusher = require("./pusher")

local M = {}

local BLOCK_KIND = protocol.BLOCK_KIND
-- A copy opens at this share of its tab's leftmost pane's split, so it starts as a column.
local RATIO = 0.2
-- A failed tab gets no second attempt within this long; an incoherent session identity retries sooner.
local RETRY_MS = 5000
local TRANSITION_RETRY_MS = 100

type EnsureOutcome = "ready" | "deferred" | "ignored"
type DeferredKind = "focus" | "show" | "show_all"
type Deferred = { kind: DeferredKind, host: string, session: string, source_session: string, agent: string? }

-- Per tab: when a copy was last attempted. Per host: whether the install and failure toasts were shown.
local tried_at: { [number]: number } = {}
local told_missing: { [string]: boolean } = {}
local told_failed: { [string]: boolean } = {}
local retry_pending = false
local retry_epoch = 0
local deferred: Deferred? = nil
local resume_deferred: (WindowCx, Deferred) -> ()
-- "<host>\n<session>" of the view the last focus event saw.
local last_view: string? = nil
-- Set while `tidy` closes a copy, so the pane_closed that follows does not tidy again.
local tidying = false

-- The deck session's name for `host`: the session holding its copies, else the recorded one, else nil (first use).
local function deck_session_of(host: string): string?
	return pusher.session_of(host) or leader.deck_session(host)
end

-- The session `name` on `host`, as `cx.sessions:list()` reports it (a session is told apart by its host and name, and
-- switched to by its id). Nil with `true` when the list was read and holds none; nil with `false` when it could
-- not be read.
local function find_session(cx: WindowCx, host: ManagedHost, name: string): (ManagedSession?, boolean)
	local sessions = compat.sessions_list(cx)
	if sessions == nil then
		return nil, false
	end
	for _, s in sessions do
		if s.host == host.id and s.name == name then
			return s, true
		end
	end
	return nil, true
end

-- Focuses the copy in the current tab, or the host's first copy.
local function focus_copy(cx: WindowCx, host: string)
	pusher.scan(cx)
	local focused = compat.session_focused(cx)
	local tab = if focused ~= nil then compat.session_tab_of(cx, focused) else nil
	local copy = pusher.copy_in_tab(tab) or pusher.blocks_for(host)[1]
	if copy == nil then
		return
	end
	local ok, err = compat.focus(cx, copy)
	if not ok then
		diag.error("copies", "focus the list on " .. host .. ": " .. tostring(err))
		compat.toast(cx, "error", "Jumpr could not focus its list on " .. host, err)
	end
end

local function clear_deferred()
	deferred = nil
end

-- Invalidates an armed callback as well as its intent; Tern timers cannot be cancelled.
local function cancel_retry()
	retry_epoch += 1
	retry_pending = false
	clear_deferred()
end

-- At most one live timer exists for an epoch. An explicit action replaces passive retry intent.
local function retry_transition(intent: Deferred?)
	if intent ~= nil then
		deferred = intent
	end
	if retry_pending then
		return
	end
	retry_pending = true
	retry_epoch += 1
	local epoch = retry_epoch
	compat.timer(TRANSITION_RETRY_MS, function(tcx: WindowCx?)
		if epoch ~= retry_epoch then
			return
		end
		retry_pending = false
		if tcx == nil then
			clear_deferred()
			return
		end
		local waiting = deferred
		if waiting == nil then
			M.ensure(tcx)
			return
		end
		local host = compat.current_host(tcx)
		local session = compat.current_session(tcx)
		if host == nil or session == nil or host.name ~= waiting.host then
			clear_deferred()
			return
		end
		if session.name ~= waiting.session then
			if session.name == waiting.source_session then
				retry_transition(waiting)
			else
				clear_deferred()
			end
			return
		end
		resume_deferred(tcx, waiting)
	end)
end

-- Opens a copy in `tab`. Returns whether `new_block` was called and gave a pane. A nil answer with no error means
-- the host has no Jumpr plugin ready: one toast per host; any other failure toasts once per host too.
local function open_copy(cx: WindowCx, host: ManagedHost, session: string, tab: number): boolean
	local target = compat.leftmost_pane(cx, tab)
	if target == nil then
		return false
	end
	tried_at[tab] = compat.now()
	local opts: BlockOpts = { focus = false, dir = "left", target = target, ratio = RATIO }
	local pane, err = compat.new_block(cx, BLOCK_KIND, protocol.launch_args(session, host.name), "beside", opts)
	if pane ~= nil then
		told_missing[host.name] = nil
		told_failed[host.name] = nil
		return true
	end
	if err ~= nil then
		diag.error("copies", "new copy in tab " .. string.format("%.0f", tab) .. " on " .. host.name .. ": " .. err)
		if not told_failed[host.name] then
			told_failed[host.name] = true
			compat.toast(cx, "error", "Jumpr could not open its list on " .. host.name, err)
		end
	elseif not told_missing[host.name] then
		told_missing[host.name] = true
		diag.error("copies", "not installed on " .. host.name)
		compat.toast(
			cx,
			"error",
			"Jumpr is not installed on " .. host.name .. ": run tern plugin link <checkout> there"
		)
	end
	return false
end

-- Closes every copy on `host` (the deck session in view): hiding the list, or a hidden flag found set.
local function close_copies(cx: WindowCx, host: string)
	tidying = true
	for _, pane in pusher.blocks_for(host) do
		local ok, err = compat.close(cx, pane)
		if not ok then
			diag.error("copies", "close copy on " .. host .. ": " .. tostring(err))
		end
	end
	tidying = false
	pusher.scan(cx)
end

-- The tabs of the session in view, only when the current host, its session list and the session rows all
-- identify the same session (a reconnect or reload can briefly report an older generation); nil otherwise.
local function coherent_tabs(host: ManagedHost, session: ManagedSession, sessions: { SessionInfo }): { number }?
	if session.host ~= host.id then
		return nil
	end
	local hosted = false
	for _, id in host.sessions do
		if id == session.id then
			hosted = true
			break
		end
	end
	if not hosted then
		return nil
	end
	for _, item in sessions do
		if item.id == session.id then
			return item.tabs
		end
	end
	return nil
end

-- Makes sure every tab of the coherent deck session in view holds a copy.
local function ensure_with(cx: WindowCx, intent: Deferred?): EnsureOutcome
	if not leader.is_leader() then
		return "ignored"
	end
	local host = compat.current_host(cx)
	local session = compat.current_session(cx)
	if host == nil or session == nil then
		return "ignored"
	end
	if not pusher.scan(cx) then
		return "ignored"
	end
	local deck = deck_session_of(host.name)
	if deck ~= nil and pusher.session_of(host.name) == nil then
		local found, readable = find_session(cx, host, deck)
		if found == nil and readable then
			leader.set_deck_session(host.name, nil)
			deck = nil
		end
	end
	if deck ~= nil and deck ~= session.name then
		return "ignored"
	end
	if leader.hidden() then
		if #pusher.blocks_for(host.name) > 0 then
			close_copies(cx, host.name)
		end
		return "ignored"
	end
	local sessions = compat.session_tabs(cx)
	local tabs = if sessions ~= nil then coherent_tabs(host, session, sessions) else nil
	if tabs == nil then
		retry_transition(intent)
		return "deferred"
	end
	local opened = false
	local now = compat.now()
	for _, tab in tabs do
		if pusher.copy_in_tab(tab) == nil then
			local at = tried_at[tab]
			if (at == nil or now - at >= RETRY_MS) and open_copy(cx, host, session.name, tab) then
				opened = true
			end
		end
	end
	if opened then
		if deck == nil then
			leader.set_deck_session(host.name, session.name)
		end
		pusher.scan(cx)
		pusher.mark_dirty()
	end
	return "ready"
end

-- Public callers may request that focus be resumed after a transitional disagreement.
function M.ensure(cx: WindowCx, defer_focus: boolean?): EnsureOutcome
	local intent: Deferred? = nil
	if defer_focus then
		local host = compat.current_host(cx)
		local session = compat.current_session(cx)
		if host ~= nil and session ~= nil then
			intent = {
				kind = "focus",
				host = host.name,
				session = session.name,
				source_session = session.name,
				agent = nil,
			}
		end
	end
	local outcome: EnsureOutcome = ensure_with(cx, intent)
	if defer_focus and outcome ~= "deferred" then
		cancel_retry()
	end
	return outcome
end

-- `focus`: opens the missing copies when the view moved to another session or host, or a tab without a copy got
-- focus.
function M.on_focus(cx: WindowCx, ev: FocusEvent)
	local host = compat.current_host(cx)
	local session = compat.current_session(cx)
	if host == nil or session == nil then
		return
	end
	if
		deferred ~= nil
		and (
			deferred.host ~= host.name
			or (deferred.session ~= session.name and deferred.source_session ~= session.name)
		)
	then
		-- The requested target and its switch source are both different: the user chose another view.
		cancel_retry()
	end
	local key = host.name .. "\n" .. session.name
	if key ~= last_view then
		last_view = key
		M.ensure(cx)
	elseif pusher.copy_in_tab(ev.tab) == nil then
		M.ensure(cx)
	end
end

-- `pane_closed`, after the handler's scan (pusher.rebuild): a copy left alone in its tab (its agent stopped or was
-- closed) is closed, so the tab goes too, unless it is the last copy of its deck session, which stays as the
-- session's list. When the closed copy had focus, focus moves to the copy in the tab Tern shows next, so it stays in
-- the list and never lands in omp.
function M.tidy(cx: WindowCx)
	if tidying or not leader.is_leader() then
		return
	end
	for tab, in_tab in pusher.copies_by_tab() do
		local copy = in_tab[1]
		if not pusher.accompanied(tab) and #in_tab == 1 then
			local host = pusher.block_info(copy)
			if host ~= nil and #pusher.blocks_for(host) > 1 then
				local had_focus = compat.session_focused(cx) == copy
				tidying = true
				local ok, err = compat.close(cx, copy)
				tidying = false
				if not ok then
					diag.error("copies", "close the lone copy on " .. host .. ": " .. tostring(err))
				else
					pusher.scan(cx)
					if had_focus then
						local f = compat.session_focused(cx)
						local at = if f ~= nil then compat.session_tab_of(cx, f) else nil
						local next_copy = pusher.copy_in_tab(at)
						if next_copy == nil then
							M.ensure(cx)
							next_copy = pusher.copy_in_tab(at)
						end
						if next_copy ~= nil and next_copy ~= f then
							compat.focus(cx, next_copy)
						end
					end
				end
			end
		end
	end
end

-- Resolves the agent again at focus time, so deferred shows never retain a stale pane or tab id.
local function focus_agent_copy(cx: WindowCx, host: string, id: string): (boolean, string?)
	pusher.scan(cx)
	local pane = agents.pane_for(host, id)
	if pane == nil then
		agents.rebuild(cx)
		pane = agents.pane_for(host, id)
	end
	if pane == nil then
		return false, "agent " .. id .. " is not running on " .. host
	end
	local tab = compat.session_tab_of(cx, pane)
	if tab == nil then
		return false, "agent " .. id .. " has no tab on " .. host
	end
	local copy = pusher.copy_in_tab(tab)
	if copy == nil then
		return false, "no list in the tab of agent " .. id .. " on " .. host
	end
	if compat.session_focused(cx) == copy then
		return true, nil
	end
	return compat.focus(cx, copy)
end

-- Deals parked agent pane `pane` (deck id `id` on `host`) into a new tab of its own in the host's deck session, so it
-- never lands in another agent's tab (focusing a parked pane would deal it into whichever tab is in view). The tab
-- gets its copy of the list now when that session is in view, else when the view comes to it. The new tab, or nil and
-- the reason in one line.
function M.deal(cx: WindowCx, host: string, id: string, pane: number): (number?, string?)
	local fail = "could not bring agent " .. id .. " on " .. host .. " back into a tab: "
	local hosts, hosts_err = compat.hosts_list(cx)
	if hosts == nil then
		return nil, fail .. tostring(hosts_err)
	end
	local h: ManagedHost? = nil
	for _, each in hosts do
		if each.name == host then
			h = each
		end
	end
	local deck = deck_session_of(host)
	if h == nil or deck == nil then
		return nil, fail .. "its deck session is unknown"
	end
	local session, readable = find_session(cx, h, deck)
	if session == nil then
		return nil,
			fail .. (if readable
				then "its deck session " .. deck .. " is not open"
				else "the sessions could not be listed")
	end
	local made, err = compat.arrange(cx, { session = session.id, tabs = { { blocks = { pane } } }, rest = "keep" })
	if made == nil then
		return nil, fail .. tostring(err)
	end
	-- What Tern reports is not taken on trust: a session daemon that cannot serve the regroup may answer it and move
	-- nothing, so the pane itself is read again and must now sit in a tab.
	local now, read_err = compat.session_pane(cx, pane)
	if now == nil or now.parked or now.tab == nil then
		local why = if now == nil and read_err ~= nil then read_err else "Tern left it in no tab"
		return nil, fail .. why
	end
	local tab: number = now.tab
	pusher.rebuild(cx)
	M.ensure(cx)
	pusher.mark_dirty()
	return tab, nil
end

-- `jumpr://show`: accepts a coherent focus now or preserves the agent id through a session transition. A parked agent
-- is dealt into a tab of its own first.
function M.show(cx: WindowCx, host: string, id: string): (boolean, string?)
	local view_host = compat.current_host(cx)
	local session = compat.current_session(cx)
	if view_host == nil or session == nil or view_host.name ~= host then
		return false, "stale"
	end
	if not pusher.scan(cx) then
		return false, "could not read the window's panes"
	end
	local deck = deck_session_of(host)
	if deck == nil or deck ~= session.name then
		return false, "stale"
	end
	local pane = agents.pane_for(host, id)
	if pane == nil then
		agents.rebuild(cx)
		pane = agents.pane_for(host, id)
	end
	if pane == nil then
		return false, "agent " .. id .. " is not running on " .. host
	end
	local tab = compat.session_tab_of(cx, pane)
	if tab == nil and agents.parked(pane) then
		local dealt, why = M.deal(cx, host, id, pane)
		if dealt == nil then
			return false, why
		end
		tab = dealt
	end
	if tab == nil then
		return false, "agent " .. id .. " has no tab on " .. host
	end
	if pusher.copy_in_tab(tab) == nil then
		local intent: Deferred = {
			kind = "show",
			host = host,
			session = session.name,
			source_session = session.name,
			agent = id,
		}
		local outcome = ensure_with(cx, intent)
		if outcome == "deferred" then
			return true, nil
		end
		cancel_retry()
	else
		cancel_retry()
	end
	return focus_agent_copy(cx, host, id)
end

resume_deferred = function(cx: WindowCx, waiting: Deferred)
	local outcome = ensure_with(cx, waiting)
	if outcome == "deferred" then
		return
	end
	cancel_retry()
	if outcome ~= "ready" then
		return
	end
	if waiting.kind == "show" and waiting.agent ~= nil then
		focus_agent_copy(cx, waiting.host, waiting.agent)
	else
		focus_copy(cx, waiting.host)
	end
end

-- "Jumpr: hide or show list" step one: cancels deferred actions, sets hidden and closes this host's copies.
function M.hide(cx: WindowCx)
	cancel_retry()
	leader.take()
	table.clear(tried_at)
	leader.set_hidden(true)
	local host = compat.current_host(cx)
	if host == nil then
		return
	end
	pusher.scan(cx)
	close_copies(cx, host.name)
end

-- Shows the recorded deck session. A successful session switch is asynchronous: keep its target until observed.
function M.show_all(cx: WindowCx)
	leader.take()
	table.clear(tried_at)
	leader.set_hidden(false)
	local host = compat.current_host(cx)
	local session = compat.current_session(cx)
	if host == nil or session == nil then
		return
	end
	local deck = leader.deck_session(host.name)
	local intent: Deferred = {
		kind = "show_all",
		host = host.name,
		session = deck or session.name,
		source_session = session.name,
		agent = nil,
	}
	if deck ~= nil and deck ~= session.name then
		local target, readable = find_session(cx, host, deck)
		if target ~= nil then
			local ok, err = compat.session_switch(cx, target.id)
			if not ok then
				diag.error("copies", "switch to " .. deck .. " on " .. host.name .. ": " .. tostring(err))
				compat.toast(cx, "error", "Jumpr could not switch to its session " .. deck .. " on " .. host.name, err)
				return
			end
			retry_transition(intent)
			return
		elseif readable then
			leader.set_deck_session(host.name, nil)
			intent.session = session.name
		else
			diag.error("copies", "switch to " .. deck .. " on " .. host.name .. ": the sessions could not be listed")
			compat.toast(
				cx,
				"error",
				"Jumpr could not switch to its session " .. deck .. " on " .. host.name,
				"the sessions could not be listed"
			)
			return
		end
	end
	deferred = intent
	resume_deferred(cx, intent)
end

-- The palette command: hides the copies, or shows them again.
function M.toggle(cx: WindowCx)
	leader.take()
	if leader.hidden() then
		M.show_all(cx)
	else
		M.hide(cx)
	end
end

-- The tab-title formatter (`tern.chrome.tab_title`): a tab named by `r` keeps that name (nil here, so Tern's
-- own default shows it); otherwise, while focus is in a copy, the tab shows its agent's title (spinner frame
-- removed) rather than the deck's. Only reads the map the pusher's scan rebuilt (4 ms budget).
function M.tab_title(tab: TabInfo): string?
	if tab.name ~= nil and tab.name ~= "" then
		return nil
	end
	return pusher.agent_title(tab.id, tab.pane)
end

diag.provide("copies", function(): any
	local tried: { [string]: number } = {}
	for tab, at in tried_at do
		tried[string.format("%.0f", tab)] = at
	end
	return { hidden = leader.hidden(), tried_at_ms = tried }
end)

return M
