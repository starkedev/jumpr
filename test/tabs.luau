--!strict

local Tabs = require("../lib/window/tabs")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local AGENT, LIST = false, true

-- A focus move within one session pushes the tab it left; a pane move inside one tab changes no history.
local s = Tabs.new_state()
s = Tabs.on_focus(s, 1, 10, 100, AGENT)
check(s.session == 1 and s.cur == 10 and s.prev == nil, "the first focus has nothing before it")
s = Tabs.on_focus(s, 1, 10, 101, LIST)
check(s.prev == nil, "focus moving inside the same tab changes no history")
s = Tabs.on_focus(s, 1, 20, 200, AGENT)
check(s.prev == 10 and s.cur == 20, "a tab move records the tab it left")

-- The toggle: jump to the previous tab, and the jump itself swaps the pair so the next press returns.
check(Tabs.target(s, 1) == 10, "the target is the tab focused before this one")
s = Tabs.after_jump(s, 10, 100)
check(s.prev == 20 and s.cur == 10, "the jump swaps the pair")
check(Tabs.target(s, 1) == 20, "so the next press returns to the tab it left")

-- The reported case: agent A in tab 10, into the list there, j/k shows tab 20 with focus in its copy.
-- The toggle must land on tab 10's AGENT pane, never on the copy the user left it through.
s = Tabs.new_state()
s = Tabs.on_focus(s, 1, 10, 100, AGENT)
s = Tabs.on_focus(s, 1, 10, 101, LIST)
check(s.agent_pane[10] == 100, "focus in the list never replaces the tab's agent pane")
s = Tabs.on_focus(s, 1, 20, 201, LIST)
check(Tabs.target(s, 1) == 10 and s.agent_pane[10] == 100, "the jump back lands on tab 10's agent, not its copy")
check(s.agent_pane[20] == nil, "a tab only ever seen through the list has no agent pane yet")
s = Tabs.on_focus(s, 1, 20, 200, AGENT)
check(s.agent_pane[20] == 200, "focusing the agent records it as the tab's landing pane")
s = Tabs.after_jump(s, 10, 100)
check(Tabs.target(s, 1) == 20 and s.agent_pane[20] == 200, "and pressing again returns to tab 20's agent")

-- A session switch starts the history fresh, landing panes included.
s = Tabs.on_focus(s, 2, 30, 300, AGENT)
check(s.session == 2 and s.cur == 30 and s.prev == nil, "a session switch resets the history")
check(s.agent_pane[10] == nil and s.agent_pane[30] == 300, "and forgets the old session's landing panes")
check(Tabs.target(s, 2) == nil, "the first press in a new session does nothing")
check(
	Tabs.target({ session = 1, prev = 10, cur = 20, agent_pane = {} }, 2) == nil,
	"another session's history is not offered"
)
check(Tabs.target(Tabs.new_state(), 1) == nil, "a fresh window has no last tab")

-- A long history still only remembers one tab back.
s = Tabs.new_state()
s = Tabs.on_focus(s, 5, 1, 11, AGENT)
s = Tabs.on_focus(s, 5, 2, 21, AGENT)
s = Tabs.on_focus(s, 5, 3, 31, AGENT)
check(Tabs.target(s, 5) == 2, "only one tab back, not the whole chain")

-- on_focus never mutates its input (the module keeps one state and replaces it).
local before = Tabs.new_state()
local _ = Tabs.on_focus(before, 1, 10, 100, AGENT)
check(before.session == nil and next(before.agent_pane) == nil, "on_focus leaves its input untouched")

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

print("Tabs: " .. checks .. " checks passed")
