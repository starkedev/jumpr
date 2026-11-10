--!strict
-- Parked agent panes (a program running in no tab), run against the fake window: the binding keeps them and its
-- entries say so, Enter deals one into a tab of its own in the deck session, a session daemon that cannot deal it
-- back is answered in one line, and a parked pane beside a tabbed one for the same agent is still a duplicate.

local Agents = require("../lib/window/agents")
local Fake = require("./support/fake_window")
local Leader = require("../lib/window/leader")
local Protocol = require("../lib/shared/protocol")
local Pusher = require("../lib/window/pusher")
local Router = require("../lib/window/router")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local cx = Fake.cx

-- Machine devbox, deck session `deck`, three tabs each holding a copy of the list and an agent.
Fake.host("laptop", "local")
local h = Fake.host("devbox")
local deck = Fake.session(h, "deck")
local t1 = Fake.tab(deck)
local a = Fake.agent(t1, "agent-a")
Fake.pane(t1, { kind = "plugin", block = Protocol.BLOCK_KIND, left = true })
local t2 = Fake.tab(deck)
Fake.agent(t2, "agent-b")
local copy2 = Fake.pane(t2, { kind = "plugin", block = Protocol.BLOCK_KIND, left = true })
local t3 = Fake.tab(deck)
local b = Fake.agent(t3, "agent-c")
Fake.pane(t3, { kind = "plugin", block = Protocol.BLOCK_KIND, left = true })
Fake.view(deck)
Fake.focus(copy2)
Leader.take()
Pusher.start(cx)

-- The entries the window holds for `id` on devbox.
local function entries(id: string): { any }
	return Agents.entries("devbox")[id] or {}
end

-- The replies (`act = "res"`) to request `n`, one per copy of the list on devbox.
local function replies(n: number): { any }
	local out = {}
	for _, e in Fake.world().events do
		if e.act == "res" and e.value.r == n then
			table.insert(out, e.value)
		end
	end
	return out
end

local r = 0
local function jump(id: string)
	r += 1
	Router.handle(cx, Protocol.request_url("jump", "blk", r, "devbox", { id = id }, "deck"), copy2)
end

-- An agent parked with no event to say so: the next beat binds it parked, and the status the copies get marks it, while
-- an agent in a tab carries no mark at all.
do
	check(#entries("agent-a") == 1 and entries("agent-a")[1].k == nil, "an agent in a tab carries no parked mark")
	Fake.park(a)
	Fake.advance(1000)
	local e = entries("agent-a")
	check(#e == 1 and e[1].k == true and e[1].s == "i", "a parked agent is still bound, its entry marked parked")
	check(entries("agent-b")[1].k == nil, "the agent in a tab is not marked")
	local sent = Fake.status_sent(copy2)
	local last = sent[#sent]
	check(
		last ~= nil and last.a["agent-a"] ~= nil and last.a["agent-a"][1].k == true,
		"the copies are told it is parked"
	)
end

-- Should a host listing leave a parked pane out, it keeps the host this window last bound it to.
do
	Fake.world().panes[a].unhosted = true
	Pusher.rebuild(cx)
	local e = entries("agent-a")
	check(#e == 1 and e[1].k == true, "a parked pane no host lists keeps its last host")
	Fake.world().panes[a].unhosted = nil
	Pusher.rebuild(cx)
end

-- Enter on the parked agent (from agent-b's tab) deals it into a new tab of its own in the deck session: that tab gets
-- its copy of the list, focus goes to the agent, and agent-b's tab is left as it was.
do
	local tabs_before = #Fake.world().sessions[deck].tabs
	jump("agent-a")
	local p = Fake.world().panes[a]
	check(p.tab ~= nil and p.tab ~= t2, "the agent is dealt into a tab, not the tab in view")
	local tab = p.tab :: number
	check(#Fake.world().sessions[deck].tabs == tabs_before + 1, "a new tab of the deck session")
	local others = 0
	for _, pane in Fake.world().order[tab] do
		if Fake.world().panes[pane].kind == "agent" and pane ~= a then
			others += 1
		end
	end
	check(others == 0, "no other agent shares its tab")
	check(#Fake.copies_in(tab) == 1, "the new tab gets its copy of the list")
	check(Fake.world().focused == a, "focus goes to the agent")
	check(#Fake.world().order[t2] == 2, "the tab in view keeps only its own copy and agent")
	Pusher.rebuild(cx)
	check(entries("agent-a")[1].k == nil, "dealt back, the agent is no longer marked parked")
end

-- A session daemon that cannot deal a parked pane back: the jump is answered with one line the list shows, nothing
-- throws, and the agent stays parked rather than landing in the tab in view.
do
	Fake.focus(copy2)
	Fake.park(b)
	Pusher.rebuild(cx)
	Fake.world().arrange_raises = "unknown request: regroup\nstack traceback:\n\t[C]: in ?"
	jump("agent-c")
	local res = replies(r)
	check(#res > 0 and res[1].ok == false, "the jump is answered with a failure")
	check(
		res[1].err == "could not bring agent agent-c on devbox back into a tab: unknown request: regroup",
		"in one line naming the agent and Tern's reason: " .. tostring(res[1].err)
	)
	check(Fake.world().panes[b].tab == nil, "the agent stays parked")
	check(#Fake.world().order[t2] == 2, "nothing lands in the tab in view")
	Fake.world().arrange_raises = nil
end

-- A session daemon that answers the regroup as done but moves nothing: the pane is read again, still parked, so the
-- jump is answered with the one-line reason, focus stays where it was, and Tern is asked once.
do
	Fake.focus(copy2)
	Fake.world().arrange_noop = true
	local asked = #Fake.world().arranged
	jump("agent-c")
	local res = replies(r)
	check(#res > 0 and res[1].ok == false, "a regroup that moved nothing is answered with a failure")
	check(
		res[1].err == "could not bring agent agent-c on devbox back into a tab: Tern left it in no tab",
		"saying Tern left it in no tab: " .. tostring(res[1].err)
	)
	check(Fake.world().panes[b].tab == nil, "the agent is still parked")
	check(Fake.world().focused == copy2, "focus stays in the list")
	check(#Fake.world().arranged == asked + 1, "Tern is asked once, never again")
	Fake.world().arrange_noop = false
end

-- A parked pane and a pane in a tab for one agent: both are bound, so the host still sees a duplicate, and the tabbed
-- pane is the one a jump would go to.
do
	local t4 = Fake.tab(deck)
	local tabbed = Fake.agent(t4, "agent-c")
	Pusher.rebuild(cx)
	local e = entries("agent-c")
	check(#e == 2, "both panes are reported: a duplicate")
	local marked = 0
	for _, x in e do
		if x.k == true then
			marked += 1
		end
	end
	check(marked == 1, "only the parked one is marked")
	check(Agents.pane_for("devbox", "agent-c") == tabbed, "the pane in a tab is the one to go to")
end

print("Parked: " .. checks .. " checks passed")
