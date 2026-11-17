--!strict

local Agents = require("../lib/window/agents")
local Compat = require("../lib/compat")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local PANE = 41
local HOST = "me@devbox"
local ID = "abc12345"

-- What Tern shows the window of the one agent pane: its agent state and the pane's unseen alert.
local tern_state = "working"
local tern_alert = false
local now = 1000

Compat.wall_ms = function(): number
	return now
end

local fake: any = {
	agents = {
		list = function(_self: any): { any }
			return {
				{ pane = PANE, command = "omp --session-dir ~/.omp/deck/" .. ID, cwd = "/", state = tern_state },
			}
		end,
	},
	session = {
		pane = function(_self: any, pane: number): any
			return { pane = pane, title = "omp", alert = tern_alert, busy = tern_state == "working" }
		end,
	},
}
local cx: WindowCx = fake

local hosts: { ManagedHost } = {
	{
		id = 1,
		name = HOST,
		kind = "remote",
		address = nil,
		state = "connected",
		detail = nil,
		identity = nil,
		current = true,
		rtt_ms = nil,
		sessions = { 1 },
		panes = { PANE },
	},
}

local function panes(): { Compat.PaneItem }
	return {
		{
			pane = PANE,
			title = "omp",
			focused = false,
			floating = false,
			parked = false,
			busy = tern_state == "working",
			alert = tern_alert,
		},
	}
end

local function rebuild()
	check(Agents.rebuild(cx, hosts, panes()), "the rebuild reads the fake window")
end

-- The one entry the window would send for the agent.
local function sent(): (string, boolean, number?)
	local list = Agents.entries(HOST)[ID]
	assert(list ~= nil and #list == 1, "the agent has one entry")
	local e = list[1]
	return e.s, e.u == true, e.c
end

-- First sight of a pane is a baseline: the window saw no change, so the entry carries no time.
rebuild()
do
	local s, _, c = sent()
	check(s == "w" and c == nil, "a pane first seen carries no change time")
end
now = 3000
rebuild()
check(select(3, sent()) == nil, "re-reading the same state stamps nothing")

-- The window watches the agent finish unseen: stamped when it happened.
now = 5000
tern_state, tern_alert = "idle", true
check(Agents.on_state(cx, { pane = PANE, old = "working", new = "idle" } :: any), "the state event is the agent's")
do
	local s, u, c = sent()
	check(s == "i" and u and c == 5000, "a watched finish carries its time")
end
now = 9000
rebuild()
check(select(3, sent()) == 5000, "a later re-read of the same state keeps the change time")

-- Looking at the pane clears the unseen finish: a change, stamped.
now = 12000
tern_alert = false
check(Agents.on_focus(PANE), "focus on the agent pane")
do
	local _, u, c = sent()
	check(not u and c == 12000, "looking at it is a change, stamped")
end
now = 13000
Agents.on_focus(PANE)
check(select(3, sent()) == 12000, "focus with nothing to clear stamps nothing")

-- A change the window only notices on a re-read is stamped when it notices it.
now = 20000
tern_alert = true
rebuild()
do
	local _, u, c = sent()
	check(u and c == 20000, "a change found by a re-read is stamped then")
end

-- A finish event that changes nothing visible stamps nothing.
now = 25000
check(Agents.on_finished(cx, { pane = PANE, result = "done" } :: any), "the finish event is the agent's")
check(select(3, sent()) == 20000, "a finish that reads the same keeps the change time")

-- A restart leaves the agent's exited pane open beside its new one: both are bound to the deck id and both are
-- sent, the exited one as "x", but the pane a jump, a tab name or a shown tab goes to is the running one. With
-- every pane exited it is the lowest.
do
	local OLD, NEW = 40, 43
	local exited: { [number]: number? } = { [OLD] = 1 }
	local two: any = {
		agents = {
			list = function(_self: any): { any }
				return {
					{ pane = OLD, command = "omp --session-dir ~/.omp/deck/" .. ID, cwd = "/", state = "exited" },
					{ pane = NEW, command = "omp --session-dir ~/.omp/deck/" .. ID, cwd = "/", state = "idle" },
				}
			end,
		},
	}
	local function item(pane: number): Compat.PaneItem
		return {
			pane = pane,
			title = "omp",
			focused = false,
			floating = false,
			parked = false,
			busy = false,
			alert = false,
			exited = exited[pane],
		}
	end
	local both: { ManagedHost } = { table.clone(hosts[1]) }
	both[1].panes = { OLD, NEW }
	check(Agents.rebuild(two :: WindowCx, both, { item(OLD), item(NEW) }), "the rebuild reads both panes")
	local list = Agents.entries(HOST)[ID]
	check(#list == 2 and list[1].s == "x" and list[2].s == "i", "both panes are sent, the exited one as x")
	local pane, count = Agents.pane_for(HOST, ID)
	check(pane == NEW and count == 2, "the running pane is the agent's, not the lower exited one")
	exited[NEW] = 0
	check(Agents.rebuild(two :: WindowCx, both, { item(OLD), item(NEW) }), "the rebuild reads both exited panes")
	check(Agents.pane_for(HOST, ID) == OLD, "with every pane exited the lowest is the agent's")
end

-- Where an entry's state came from: Tern's agent state ("agents"), or else the pane alone ("pane"): a pane Tern holds
-- no agent state for reads busy as working and not busy as idle, and an exited program reads from its exit status.
-- Only the first says an agent's prompt is ready for typed text: a CLI that exited to the shell prompt reads not busy.
do
	local LISTED, LINE = 50, 51
	local CLI = "def67890"
	local listed_state = "idle"
	local busy = false
	local exited: number? = nil
	local window: any = {
		agents = {
			list = function(_self: any): { any }
				return {
					{
						pane = LISTED,
						command = "omp --session-dir ~/.omp/deck/" .. ID,
						cwd = "/",
						state = listed_state,
					},
				}
			end,
		},
	}
	local function item(pane: number, line: string?): Compat.PaneItem
		return {
			pane = pane,
			title = "codex",
			focused = false,
			floating = false,
			parked = false,
			busy = pane == LINE and busy,
			alert = false,
			line = line,
			exited = if pane == LINE then exited else nil,
		}
	end
	local both: { ManagedHost } = { table.clone(hosts[1]) }
	both[1].panes = { LISTED, LINE }
	-- The entries of the listed agent and of the pane matched only by its running line.
	local function read(): (any, any)
		local panes = { item(LISTED), item(LINE, "env JUMPR_ID=" .. CLI .. " codex") }
		check(Agents.rebuild(window :: WindowCx, both, panes), "the rebuild reads both panes")
		return Agents.entries(HOST)[ID][1], Agents.entries(HOST)[CLI][1]
	end
	local agent, line = read()
	check(agent.s == "i" and agent.src == "agents", "an idle from Tern's agent state comes from the agents")
	check(line.s == "i" and line.src == "pane", "a pane with no agent state, not busy, reads idle from the pane alone")
	listed_state, busy = "working", true
	agent, line = read()
	check(agent.s == "w" and agent.src == "agents", "a working agent state comes from the agents")
	check(line.s == "w" and line.src == "pane", "busy with no agent state reads working from the pane alone")
	exited = 0
	local _, gone = read()
	check(gone.s == "x" and gone.src == "pane", "an exited program reads from the pane alone")
end

print("Agents: " .. checks .. " checks passed")
