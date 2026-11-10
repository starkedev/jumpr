--!strict
-- The copies of the list, run against the fake window: opening a copy in every tab of the deck session, deferring
-- through a session transition, hiding and showing, and the tab-title formatter. Each case builds its own machines
-- and names, so what one case leaves in the window modules never decides the next.

local Fake = require("./support/fake_window")
local Copies = require("../lib/window/copies")
local Leader = require("../lib/window/leader")
local Pusher = require("../lib/window/pusher")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local cx = Fake.cx
local TRANSITION_MS = 100

-- A machine `name` with deck session `name` of two tabs, each holding one agent; the deck session is recorded
-- and this window holds the lead. Returns the session, the tabs and the agents' deck ids.
local function machine(name: string): (number, number, { number }, { string })
	Fake.reset_world()
	local h = Fake.host(name)
	local s = Fake.session(h, name)
	local t1, t2 = Fake.tab(s), Fake.tab(s)
	local ids = { name .. "-a", name .. "-b" }
	Fake.agent(t1, ids[1])
	Fake.agent(t2, ids[2])
	Leader.take()
	Leader.set_deck_session(name, name)
	return h, s, { t1, t2 }, ids
end

-- Drains the status pushes that opening copies arms, so a case ends with nothing pending.
local function settle()
	Fake.advance(1000)
end

-- A show during a session transition (the window reports a generation it no longer lists) opens and toasts
-- nothing, keeps one serial retry, and once the session is coherent opens each missing tab once and focuses the
-- latest selected agent's copy.
do
	local h, s, tabs, ids = machine("devbox")
	Fake.view_stale(h, "devbox")
	local ok, why = Copies.show(cx, "devbox", ids[1])
	check(ok and why == nil, "a show during a transition is accepted")
	check(#Fake.world().opened == 0 and #Fake.world().toasts == 0, "a transition opens and toasts nothing")
	check(Fake.pending_timers() == 1, "a transition arms one retry")
	local second = Copies.show(cx, "devbox", ids[2])
	check(second and Fake.pending_timers() == 1, "a second show keeps one retry and takes the latest agent")
	Fake.advance(TRANSITION_MS)
	check(#Fake.world().opened == 0 and Fake.pending_timers() == 1, "a continued transition rearms one retry")
	Fake.view(s)
	Fake.advance(TRANSITION_MS)
	local opened = Fake.world().opened
	check(#opened == 2 and opened[1] == tabs[1] and opened[2] == tabs[2], "a coherent retry opens each tab once")
	check(Fake.world().focused == Fake.copies_in(tabs[2])[1], "a coherent retry focuses the latest agent's copy")
	settle()
end

-- A view change to another session cancels a deferred show: even when the deck session is in view again by the
-- time its retry runs, the retry neither opens copies nor moves focus.
do
	local h, s, _tabs, ids = machine("devbox2")
	local other = Fake.session(h, "other")
	local other_tab = Fake.tab(other)
	local other_pane = Fake.pane(other_tab)
	Fake.view_stale(h, "devbox2")
	Copies.show(cx, "devbox2", ids[1])
	Fake.view(other)
	Copies.on_focus(cx, { pane = other_pane, tab = other_tab })
	Fake.view(s)
	Fake.advance(TRANSITION_MS)
	check(#Fake.world().opened == 0, "a view change cancels a deferred show")
	check(Fake.world().focused == nil, "a cancelled show moves no focus")
	check(Fake.pending_timers() == 0, "a cancelled show leaves no retry armed")
end

-- Hiding before the retry cancels a deferred show, and the retry reopens nothing.
do
	local h, _s, _tabs, ids = machine("devbox3")
	Fake.view_stale(h, "devbox3")
	Copies.show(cx, "devbox3", ids[1])
	Copies.hide(cx)
	Fake.advance(TRANSITION_MS)
	check(Leader.hidden(), "hide sets the hidden flag")
	check(#Fake.world().opened == 0 and Fake.world().focused == nil, "hide cancels a deferred show")
end

-- Showing the list again switches to the recorded deck session, waits while the window still reports the session
-- it came from, then opens a copy in every tab of the deck session and focuses the one in the focused tab.
do
	Fake.reset_world()
	local h = Fake.host("devbox4")
	local home = Fake.session(h, "devbox4")
	local home_tab = Fake.tab(home)
	local home_pane = Fake.pane(home_tab)
	local deck = Fake.session(h, "deck")
	local t1, t2 = Fake.tab(deck), Fake.tab(deck)
	local agent = Fake.agent(t1, "deck-a")
	Fake.agent(t2, "deck-b")
	Leader.set_deck_session("devbox4", "deck")
	Fake.view(home)
	Fake.world().switch_lags = true
	Copies.show_all(cx)
	check(not Leader.hidden(), "showing clears the hidden flag")
	local switches = Fake.world().switches
	check(#switches == 1 and switches[1] == deck, "showing switches to the recorded deck session")
	check(Fake.pending_timers() == 1, "showing waits for the switch with one retry")
	Copies.on_focus(cx, { pane = home_pane, tab = home_tab })
	check(Fake.pending_timers() == 1, "a focus in the session switched from keeps the wait")
	Fake.advance(TRANSITION_MS)
	check(#Fake.world().opened == 0 and Fake.pending_timers() == 1, "the old session still in view keeps waiting")
	Fake.focus(agent)
	Fake.advance(TRANSITION_MS)
	check(#Fake.world().opened == 2, "the deck session in view gets a copy in every tab")
	check(Fake.world().focused == Fake.copies_in(t1)[1], "focus lands in the copy of the focused tab")
	settle()
end

-- A copy Tern refuses to open is said once per machine, with Tern's reason.
do
	local _h, s = machine("devbox5")
	Fake.view(s)
	Fake.world().block_result = "native open failed"
	check(Copies.ensure(cx) == "ready", "a coherent view completes even when opening fails")
	local toasts = Fake.world().toasts
	check(#toasts == 1, "two refused copies toast once")
	check(
		toasts[1].text == "Jumpr could not open its list on devbox5" and toasts[1].sub == "native open failed",
		"the toast names the machine and Tern's reason"
	)
end

-- The tab-title formatter shows the agent's title while focus is in its tab's copy, and yields to a tab name.
do
	Fake.reset_world()
	local h = Fake.host("devbox6")
	local s = Fake.session(h, "devbox6")
	local t = Fake.tab(s)
	Fake.agent(t, "titled", nil, "⠋ fix the header")
	local copy = Fake.pane(t, { kind = "plugin", block = "jumpr.list", left = true })
	Fake.view(s)
	Fake.focus(copy)
	Pusher.rebuild(cx)
	local function tab_info(name: string?): TabInfo
		return {
			id = t,
			session = s,
			color = nil,
			position = 1,
			pane = copy,
			name = name,
			cwd = "",
			program = "omp",
			title = "",
			panes = 2,
			busy = false,
		}
	end
	check(Copies.tab_title(tab_info(nil)) == "fix the header", "an unnamed tab shows its agent's title")
	check(Copies.tab_title(tab_info("auth-refactor")) == nil, "a named tab keeps the name it was given")
	check(Copies.tab_title(tab_info("")) == "fix the header", "a blank name is no name")
end

-- A session of the same name on another machine never counts as the session in view, and neither does a session
-- that belongs to another machine than the one in view: no copy opens.
do
	Fake.reset_world()
	local h = Fake.host("devbox7")
	local elsewhere = Fake.host("elsewhere")
	local other = Fake.session(elsewhere, "devbox7")
	Fake.tab(other)
	Leader.set_deck_session("devbox7", "devbox7")
	Fake.view_stale(h, "devbox7")
	check(Copies.ensure(cx) == "deferred", "a same-name session on another machine is not the one in view")
	Fake.view_stale(h, "devbox7", elsewhere)
	Fake.advance(TRANSITION_MS)
	check(#Fake.world().opened == 0, "a session of another machine never gets copies")
	Copies.hide(cx)
end

print("Copies: " .. checks .. " checks passed")
