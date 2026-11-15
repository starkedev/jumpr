--!strict

local Tabs = require("../lib/window/tabs")
local Fake = require("./support/fake_window")
local Protocol = require("../lib/shared/protocol")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local AGENT, LIST = false, true
local function all_open(_: number): boolean
	return true
end
local function open_except(closed: number): (number) -> boolean
	return function(t: number): boolean
		return t ~= closed
	end
end

-- Entering: focus on a pane that is not a copy of the list enters its tab; a pane move inside one tab re-enters
-- only that tab.
local s = Tabs.new_state()
s = Tabs.on_focus(s, 1, 10, 100, AGENT)
check(s.session == 1 and s.here == 10 and #s.entered == 1, "the first focus enters its tab")
check(Tabs.target(s, 1, all_open) == nil, "with one entered tab there is nothing to jump to")
s = Tabs.on_focus(s, 1, 10, 101, LIST)
check(#s.entered == 1 and s.agent_pane[10] == 100, "focus moving to the copy in the same tab changes nothing")
s = Tabs.on_focus(s, 1, 10, 100, AGENT)
check(#s.entered == 1, "and back to the agent re-enters only that tab")
s = Tabs.on_focus(s, 1, 20, 200, AGENT)
check(s.entered[1] == 20 and s.entered[2] == 10, "entering a second tab puts it first")

-- The toggle: entering two tabs, `cmd+\` goes between them, the jump itself making the next press return.
check(Tabs.target(s, 1, all_open) == 10, "the target is the tab entered before this one")
s = Tabs.after_jump(s, 10, 100, AGENT)
check(s.here == 10 and s.entered[1] == 10 and s.entered[2] == 20, "the jump enters its tab")
check(Tabs.target(s, 1, all_open) == 20, "so the next press returns")
s = Tabs.after_jump(s, 20, 200, AGENT)
check(Tabs.target(s, 1, all_open) == 10, "and the one after toggles again")

-- The reported bug: working in tab 20, then j/k in the list previews tabs 30, 40, 50 (focus lands in each copy).
-- Previews enter nothing, so `cmd+\` from the list goes back to the tab last worked in, not the last previewed.
s = Tabs.on_focus(s, 1, 20, 201, LIST)
s = Tabs.on_focus(s, 1, 30, 301, LIST)
s = Tabs.on_focus(s, 1, 40, 401, LIST)
s = Tabs.on_focus(s, 1, 50, 501, LIST)
check(s.here == 50 and s.entered[1] == 20 and s.entered[2] == 10, "previews on the list's copies enter no tab")
check(s.agent_pane[30] == nil and s.agent_pane[50] == nil, "a tab only ever seen through the list has no landing pane")
check(Tabs.target(s, 1, all_open) == 20, "from a previewed tab the chord returns to the tab last worked in")
s = Tabs.after_jump(s, 20, 200, AGENT)
check(Tabs.target(s, 1, all_open) == 10, "and pressing again toggles to the tab entered before it")

-- `cmd+j` into the list of the tab being worked in: the chord still goes to the OTHER entered tab.
s = Tabs.on_focus(s, 1, 20, 201, LIST)
check(s.here == 20 and Tabs.target(s, 1, all_open) == 10, "from the list in an entered tab the chord goes to the other")

-- Enter from the list (a jump onto an agent pane) enters that tab.
s = Tabs.on_focus(s, 1, 30, 301, LIST)
s = Tabs.on_focus(s, 1, 30, 300, AGENT)
check(s.entered[1] == 30 and s.entered[2] == 20 and s.agent_pane[30] == 300, "landing on the agent enters its tab")
check(Tabs.target(s, 1, all_open) == 20, "so the chord then toggles with the tab worked in before")

-- Closed tabs: a closed target is skipped for the tab entered before it, and prune forgets it.
check(Tabs.target(s, 1, open_except(20)) == 10, "a closed tab is skipped for the one entered before it")
local pruned = Tabs.prune(s, open_except(20))
check(#pruned.entered == 2 and pruned.entered[2] == 10, "prune drops the closed tab from the history")
check(pruned.agent_pane[20] == nil and pruned.agent_pane[30] == 300, "and its landing pane")
check(Tabs.prune(s, all_open) == s, "prune with nothing closed returns the state itself")

-- A jump that can only land on the copy (the tab's other panes closed) still enters the tab, without recording
-- the copy as its landing pane.
local j = Tabs.after_jump(Tabs.on_focus(Tabs.new_state(), 1, 60, 600, AGENT), 70, 701, LIST)
check(j.entered[1] == 70 and j.agent_pane[70] == nil, "a jump onto a copy enters the tab but records no copy")

-- A session switch starts the history fresh, landing panes included, even when focus lands on a copy.
s = Tabs.on_focus(s, 2, 80, 801, LIST)
check(s.session == 2 and s.here == 80 and #s.entered == 0, "a session switch resets the history")
check(next(s.agent_pane) == nil, "and forgets the old session's landing panes")
check(Tabs.target(s, 2, all_open) == nil, "the first press in a new session does nothing")
check(Tabs.target(s, 1, all_open) == nil, "another session's history is not offered")
check(Tabs.target(Tabs.new_state(), 1, all_open) == nil, "a fresh window has no last tab")

-- The history stays bounded however many tabs are entered.
s = Tabs.new_state()
for t = 1, 20 do
	s = Tabs.on_focus(s, 5, t, t * 10, AGENT)
end
check(#s.entered == 8 and s.entered[1] == 20 and Tabs.target(s, 5, all_open) == 19, "the history keeps the newest few")

-- on_focus never mutates its input (the module keeps one state and replaces it).
local before = Tabs.new_state()
local _ = Tabs.on_focus(before, 1, 10, 100, AGENT)
check(
	before.session == nil and #before.entered == 0 and next(before.agent_pane) == nil,
	"on_focus leaves its input untouched"
)

-- The agent the jump names for the list to follow: the landing pane when it is an agent, else the tab's lowest
-- agent pane, nil for a tab with no agent.
local agent_panes: { [number]: boolean } = { [100] = true, [300] = true, [302] = true }
local function is_agent(p: number): boolean
	return agent_panes[p] == true
end
check(Tabs.tab_agent(100, { 101, 100 }, is_agent) == 100, "landing on the agent names it")
check(Tabs.tab_agent(301, { 303, 302, 301, 300 }, is_agent) == 300, "landing on a shell names the tab's lowest agent")
check(Tabs.tab_agent(201, { 200, 201 }, is_agent) == nil, "a tab with no agent names none")
check(Tabs.tab_agent(201, {}, is_agent) == nil, "an unread tab layout names none")

-- A settings page's return: focus reaching the page from another tab makes the pane it came from the return, a move
-- inside the page's own tab keeps it, coming back from another tab replaces it, and focus arriving from another session
-- makes none. Taking a return hands it over once and leaves the state it was taken from alone.
do
	local SETTINGS = true
	local st = Tabs.on_focus(Tabs.on_focus(Tabs.new_state(), 1, 10, 101, LIST), 1, 90, 900, AGENT, SETTINGS)
	local _, back = Tabs.take_return(st, 900)
	check(back == 101, "focus reaching settings from another tab makes the pane it came from its return")
	check(st.here == 90 and st.entered[1] == 90, "the settings page's tab is entered like any other")
	st = Tabs.on_focus(Tabs.on_focus(st, 1, 90, 901, LIST), 1, 90, 900, AGENT, SETTINGS)
	_, back = Tabs.take_return(st, 900)
	check(back == 101, "a move inside the settings page's own tab keeps its return")
	st = Tabs.on_focus(Tabs.on_focus(st, 1, 30, 300, AGENT), 1, 90, 900, AGENT, SETTINGS)
	local taken, again = Tabs.take_return(st, 900)
	check(again == 300, "coming back from another tab makes that pane the return")
	_, back = Tabs.take_return(taken, 900)
	check(back == nil, "a return is handed over once")
	_, back = Tabs.take_return(st, 900)
	check(back == 300, "taking it leaves the state it was taken from alone")
	local switched = Tabs.on_focus(st, 2, 70, 700, AGENT, SETTINGS)
	_, back = Tabs.take_return(switched, 700)
	check(back == nil, "focus arriving from another session makes no return")
	_, back = Tabs.take_return(switched, 900)
	check(back == 300, "and a session switch keeps the returns already made")
end

-- Against the fake window: a settings page that closes while it has focus sends focus back to the pane it was opened
-- from through Tern's own move of focus, whether that move is seen before the page's pane_closed or after it; Tern's
-- choice of tab never counts as a tab worked in. With that pane gone, or the page closed from another tab, focus stays
-- where Tern put it.
do
	local cx = Fake.cx
	Fake.host("laptop", "local")
	local deck = Fake.session(Fake.host("devbox"), "deck")
	local tb, ta, tn = Fake.tab(deck), Fake.tab(deck), Fake.tab(deck)
	local agent_b, agent_a, agent_n = Fake.agent(tb, "agent-b"), Fake.agent(ta, "agent-a"), Fake.agent(tn, "agent-n")
	Fake.view(deck)

	-- Focus moves to `pane`, and the history sees the event as window.luau hands it on; true when it sent focus back.
	local function moved(pane: number): boolean
		Fake.focus(pane)
		return Tabs.focus_seen(cx, { pane = pane, tab = Fake.world().panes[pane].tab :: number })
	end
	-- Tern's own move of focus, already made, seen as an event.
	local function seen(pane: number): boolean
		return Tabs.focus_seen(cx, { pane = pane, tab = Fake.world().panes[pane].tab :: number })
	end
	-- The settings page in a new last tab of the deck session, focused as the router opens it.
	local function open_settings(): number
		local page = Fake.pane(Fake.tab(deck), { kind = "plugin", block = Protocol.SETTINGS_KIND })
		moved(page)
		return page
	end

	-- Esc, and the page's pane_closed comes before Tern's focus event. Tern shows tab tn, the tab before the page's.
	moved(agent_b)
	moved(agent_a)
	local page = open_settings()
	Fake.close(page)
	check(Fake.world().focused == agent_n, "Tern shows the neighbouring tab when the settings page closes")
	Tabs.pane_closed(cx, page)
	check(Fake.world().focused == agent_n, "the page's pane_closed moves no focus by itself")
	check(seen(agent_n), "Tern's move of focus off the closed page is dropped")
	check(Fake.world().focused == agent_a, "and focus goes back to the pane settings was opened from")
	seen(agent_a)

	-- Esc, and Tern's focus event comes first: it is not folded, so the toggle still goes to the tab worked in before.
	page = open_settings()
	Fake.close(page)
	check(seen(agent_n), "Tern's move of focus off the closed page is dropped")
	check(Fake.world().focused == agent_a, "and focus goes back to the pane settings was opened from")
	Tabs.pane_closed(cx, page)
	check(Fake.world().focused == agent_a, "the page's pane_closed after it changes nothing")
	seen(agent_a)
	Tabs.last_tab(cx)
	check(Fake.world().focused == agent_b, "the toggle goes to the tab worked in before settings, not Tern's choice")

	-- The pane settings was opened from closes while the page is open: Tern's choice stands.
	moved(agent_a)
	page = open_settings()
	Fake.close(agent_a)
	Fake.close(page)
	local choice = Fake.world().focused
	Tabs.pane_closed(cx, page)
	check(choice ~= nil and Fake.world().focused == choice, "with the pane it came from gone, focus stays put")
	check(not seen(choice :: number), "and Tern's move of focus is taken as it is")

	-- The page closed from another tab: focus stays where the user is.
	moved(agent_b)
	page = open_settings()
	moved(agent_n)
	Fake.close(page)
	Tabs.pane_closed(cx, page)
	check(Fake.world().focused == agent_n, "a settings page closed from another tab moves no focus")

	-- Tern's own move after the close lands on the pane settings was opened from: it is kept as it is.
	moved(agent_n)
	page = open_settings()
	Fake.close(page)
	check(Fake.world().focused == agent_n, "Tern can land on the pane settings was opened from by itself")
	check(not seen(agent_n), "then its move is kept and folded as it is")
	Tabs.pane_closed(cx, page)
	check(Fake.world().focused == agent_n, "and the page's pane_closed changes nothing")
end

print("Tabs: " .. checks .. " checks passed")
