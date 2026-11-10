--!strict
-- The status messages the window sends the copies of the list, run against the fake window. A scripted run (start,
-- an agent finishing, quiet heartbeats, an agent's pane closing, a new tab, the 30 s resync) is checked twice: by
-- the rules every message keeps, and against a recorded transcript of every message, so a change to how messages
-- are built that changes what is sent shows here.

local Fake = require("./support/fake_window")
local Agents = require("../lib/window/agents")
local Copies = require("../lib/window/copies")
local Leader = require("../lib/window/leader")
local Pusher = require("../lib/window/pusher")
local Startup = require("../lib/window/startup")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local cx = Fake.cx

-- One line of text for a value: keys sorted, the window uid written as `W`, an empty table as `[]`.
local function canon(v: any): string
	if type(v) == "table" then
		if v == Fake.NULL then
			return "null"
		end
		local keys: { string } = {}
		for k in v do
			table.insert(keys, tostring(k))
		end
		if #keys == 0 then
			return "[]"
		end
		table.sort(keys)
		local parts: { string } = {}
		for _, k in keys do
			local item = v[k]
			if item == nil then
				item = v[tonumber(k)]
			end
			table.insert(parts, k .. "=" .. canon(item))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return if v == Leader.uid() then "W" else string.format("%q", v)
	end
	return tostring(v)
end

-- Every status message so far, in order, as `<copy label> <message>` at its fake time.
local transcript: { string } = {}
local labels: { [number]: string } = {}
local seen = 0

local function label(pane: number): string
	local l = labels[pane]
	if l == nil then
		local n = 0
		for _ in labels do
			n += 1
		end
		l = "copy" .. tostring(n + 1)
		labels[pane] = l
	end
	return l
end

local function record()
	local events = Fake.world().events
	for i = seen + 1, #events do
		local e = events[i]
		if e.act == "st" then
			table.insert(transcript, string.format("%d %s %s", Fake.now(), label(e.pane), canon(e.value)))
		end
	end
	seen = #events
end

-- Steps the clock 50 ms at a time, recording what is sent.
local function run(ms: number)
	for _ = 1, ms // 50 do
		Fake.advance(50)
		record()
	end
end

-- The recorded transcript: every status message of the scripted run, as `<ms> <copy> <message>`.
local TRANSCRIPT = {
	[[250 copy1 {a={agent-a={1={s="i",src="agents"}},agent-b={1={s="w",src="agents"}}},dupb=false,em="A",full=true,h="connected",hn="devbox",p=2,seq=1,sn="deck",t=1700000000250,w=W}]],
	[[250 copy2 {a={agent-a={1={s="i",src="agents"}},agent-b={1={s="w",src="agents"}}},dupb=false,em="A",full=true,h="connected",hn="devbox",p=2,seq=1,sn="deck",t=1700000000250,w=W}]],
	[[1000 copy1 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=2,sn="deck",t=1700000001000,w=W}]],
	[[1000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=2,sn="deck",t=1700000001000,w=W}]],
	[[1250 copy1 {a={agent-b={1={c=1700000001000,s="i",src="agents"}}},dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=3,sn="deck",t=1700000001250,w=W}]],
	[[1250 copy2 {a={agent-b={1={c=1700000001000,s="i",src="agents"}}},dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=3,sn="deck",t=1700000001250,w=W}]],
	[[2000 copy1 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=4,sn="deck",t=1700000002000,w=W}]],
	[[2000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=4,sn="deck",t=1700000002000,w=W}]],
	[[2750 copy2 {a={agent-a=[]},dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=5,sn="deck",t=1700000002750,w=W}]],
	[[3750 copy3 {a={agent-b={1={c=1700000001000,s="i",src="agents"}},agent-c={1={s="i",src="agents"}}},dupb=false,em="A",full=true,h="connected",hn="devbox",p=2,seq=1,sn="deck",t=1700000003750,w=W}]],
	[[3750 copy2 {a={agent-c={1={s="i",src="agents"}}},dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=6,sn="deck",t=1700000003750,w=W}]],
	[[5000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=2,sn="deck",t=1700000005000,w=W}]],
	[[5000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=7,sn="deck",t=1700000005000,w=W}]],
	[[5400 copy3 {a={agent-c={1={c=1700000005150,s="w",src="agents"}}},dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=3,sn="deck",t=1700000005400,w=W}]],
	[[5400 copy2 {a={agent-c={1={c=1700000005150,s="w",src="agents"}}},dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=8,sn="deck",t=1700000005400,w=W}]],
	[[7000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=4,sn="deck",t=1700000007000,w=W}]],
	[[7000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=9,sn="deck",t=1700000007000,w=W}]],
	[[8000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=5,sn="deck",t=1700000008000,w=W}]],
	[[8000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=10,sn="deck",t=1700000008000,w=W}]],
	[[9000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=6,sn="deck",t=1700000009000,w=W}]],
	[[9000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=11,sn="deck",t=1700000009000,w=W}]],
	[[10000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=7,sn="deck",t=1700000010000,w=W}]],
	[[10000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=12,sn="deck",t=1700000010000,w=W}]],
	[[11000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=8,sn="deck",t=1700000011000,w=W}]],
	[[11000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=13,sn="deck",t=1700000011000,w=W}]],
	[[12000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=9,sn="deck",t=1700000012000,w=W}]],
	[[12000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=14,sn="deck",t=1700000012000,w=W}]],
	[[13000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=10,sn="deck",t=1700000013000,w=W}]],
	[[13000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=15,sn="deck",t=1700000013000,w=W}]],
	[[14000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=11,sn="deck",t=1700000014000,w=W}]],
	[[14000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=16,sn="deck",t=1700000014000,w=W}]],
	[[15000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=12,sn="deck",t=1700000015000,w=W}]],
	[[15000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=17,sn="deck",t=1700000015000,w=W}]],
	[[16000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=13,sn="deck",t=1700000016000,w=W}]],
	[[16000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=18,sn="deck",t=1700000016000,w=W}]],
	[[17000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=14,sn="deck",t=1700000017000,w=W}]],
	[[17000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=19,sn="deck",t=1700000017000,w=W}]],
	[[18000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=15,sn="deck",t=1700000018000,w=W}]],
	[[18000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=20,sn="deck",t=1700000018000,w=W}]],
	[[19000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=16,sn="deck",t=1700000019000,w=W}]],
	[[19000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=21,sn="deck",t=1700000019000,w=W}]],
	[[20000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=17,sn="deck",t=1700000020000,w=W}]],
	[[20000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=22,sn="deck",t=1700000020000,w=W}]],
	[[21000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=18,sn="deck",t=1700000021000,w=W}]],
	[[21000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=23,sn="deck",t=1700000021000,w=W}]],
	[[22000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=19,sn="deck",t=1700000022000,w=W}]],
	[[22000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=24,sn="deck",t=1700000022000,w=W}]],
	[[23000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=20,sn="deck",t=1700000023000,w=W}]],
	[[23000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=25,sn="deck",t=1700000023000,w=W}]],
	[[24000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=21,sn="deck",t=1700000024000,w=W}]],
	[[24000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=26,sn="deck",t=1700000024000,w=W}]],
	[[25000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=22,sn="deck",t=1700000025000,w=W}]],
	[[25000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=27,sn="deck",t=1700000025000,w=W}]],
	[[26000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=23,sn="deck",t=1700000026000,w=W}]],
	[[26000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=28,sn="deck",t=1700000026000,w=W}]],
	[[27000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=24,sn="deck",t=1700000027000,w=W}]],
	[[27000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=29,sn="deck",t=1700000027000,w=W}]],
	[[28000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=25,sn="deck",t=1700000028000,w=W}]],
	[[28000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=30,sn="deck",t=1700000028000,w=W}]],
	[[29000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=26,sn="deck",t=1700000029000,w=W}]],
	[[29000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=31,sn="deck",t=1700000029000,w=W}]],
	[[30000 copy3 {a={agent-b={1={c=1700000001000,s="i",src="agents"}},agent-c={1={c=1700000005150,s="w",src="agents"}}},dupb=false,em="A",full=true,h="connected",hn="devbox",p=2,seq=27,sn="deck",t=1700000030000,w=W}]],
	[[30000 copy2 {a={agent-b={1={c=1700000001000,s="i",src="agents"}},agent-c={1={c=1700000005150,s="w",src="agents"}}},dupb=false,em="A",full=true,h="connected",hn="devbox",p=2,seq=32,sn="deck",t=1700000030000,w=W}]],
	[[31000 copy3 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=28,sn="deck",t=1700000031000,w=W}]],
	[[31000 copy2 {a=[],dupb=false,em="A",full=false,h="connected",hn="devbox",p=2,seq=33,sn="deck",t=1700000031000,w=W}]],
}

-- One machine with a deck session of two tabs: agent-a idle, agent-b working.
Fake.host("laptop", "local")
local h = Fake.host("devbox")
local deck = Fake.session(h, "deck")
local t1, t2 = Fake.tab(deck), Fake.tab(deck)
local agent_a = Fake.agent(t1, "agent-a")
local agent_b = Fake.agent(t2, "agent-b")
Fake.world().panes[agent_b].state = "working"
Fake.view(deck)
Fake.focus(agent_a)

Startup.ensure(cx)
record()
run(1000)

-- agent-b finishes its turn.
Fake.world().panes[agent_b].state = "idle"
if Agents.on_state(cx, { pane = agent_b, old = "working", new = "idle" }) then
	Pusher.mark_dirty()
end
record()
run(1500)

-- agent-a's pane closes: the window rebuilds, tidies the copy left alone in its tab, and marks the change.
Fake.close(agent_a)
if Pusher.rebuild(cx) then
	Copies.tidy(cx)
end
Pusher.mark_dirty()
record()
run(1000)

-- A new tab with agent-c: the window sees the agent's pane (a rebuild, then the change marked) and the tab, which
-- gets its own copy.
local t3 = Fake.tab(deck)
Fake.agent(t3, "agent-c")
Pusher.rebuild(cx)
Pusher.mark_dirty()
Copies.ensure(cx)
record()
run(1650)

-- agent-c starts a turn 600 ms before a heartbeat is due: the copies just got its change, so that heartbeat skips
-- them (a heartbeat only goes to a copy quiet for 750 ms).
local agent_c = Fake.world().order[t3][2]
Fake.world().panes[agent_c].state = "working"
if Agents.on_state(cx, { pane = agent_c, old = "idle", new = "working" }) then
	Pusher.mark_dirty()
end
record()
run(26350)

-- The rules every message keeps.
do
	local by_copy: { [number]: { any } } = {}
	for _, e in Fake.world().events do
		if e.act == "st" then
			local list = by_copy[e.pane] or {}
			by_copy[e.pane] = list
			table.insert(list, e.value)
		end
	end
	for pane, list in by_copy do
		check(list[1].full == true, label(pane) .. ": the first message to a copy is a full snapshot")
		for i, msg in list do
			check(msg.seq == i, label(pane) .. ": seq counts up by one per message")
			check(msg.p == 2 and msg.w == Leader.uid(), label(pane) .. ": every message carries p and the window uid")
		end
	end
	local copy2 = Fake.copies_in(t2)[1]
	local gone_seen = false
	for _, msg in by_copy[copy2] do
		if not msg.full and msg.a["agent-a"] ~= nil then
			gone_seen = #msg.a["agent-a"] == 0
		end
	end
	check(gone_seen, "a gone agent is sent as an empty list")
	local fulls = 0
	for _, msg in by_copy[copy2] do
		if msg.full then
			fulls += 1
		end
	end
	check(fulls >= 2, "the 30 s resync sends a full snapshot again")
end

check(#transcript == #TRANSCRIPT, "the run sends as many messages as the transcript holds")
for i, line in TRANSCRIPT do
	check(transcript[i] == line, "message " .. tostring(i) .. " matches the transcript: " .. tostring(transcript[i]))
end

print("Pusher: " .. checks .. " checks passed")
