--!strict
-- A copy of the list the window lists but whose block never runs (Tern refuses its events: "no program runs in that
-- pane"), run against the fake window: the window says so once and backs off rather than retrying every beat, and a
-- copy that comes back gets a full snapshot and the normal heartbeat again. Its healthy neighbour is untouched.

local Fake = require("./support/fake_window")
local Startup = require("../lib/window/startup")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local cx = Fake.cx
local COPY = { kind = "plugin", block = "jumpr.list", title = "jumpr" }

-- The log lines that name the dead copy's reason.
local function mentions(): number
	local n = 0
	for _, line in Fake.logs() do
		if string.find(line, "no program runs in that pane", 1, true) ~= nil then
			n += 1
		end
	end
	return n
end

Fake.host("laptop", "local")
local h = Fake.host("devbox")
local deck = Fake.session(h, "deck")
local t1, t2 = Fake.tab(deck), Fake.tab(deck)
Fake.agent(t1, "agent-a")
Fake.agent(t2, "agent-b")
local healthy = Fake.pane(t1, COPY)
local dead = Fake.pane(t2, COPY)
Fake.world().dead[dead] = true
Fake.view(deck)
Fake.focus(healthy)

Startup.ensure(cx)
for _ = 1, 60 do
	Fake.advance(1000)
end

-- Over a minute of heartbeats the dead copy is tried a handful of times, not every beat, and said once.
do
	local tries = Fake.world().event_attempts[dead] or 0
	check(tries >= 3 and tries <= 8, "a dead copy is tried a handful of times in a minute, not every beat: " .. tries)
	check(mentions() == 2, "its reason is logged once by the window and once in full: " .. mentions())
	local beats = #Fake.status_sent(healthy)
	check(beats >= 55, "the healthy copy keeps its heartbeat: " .. beats)
end

-- The copy comes back: within the longest wait it gets a full snapshot as a first contact, then the normal heartbeat.
do
	Fake.world().dead[dead] = nil
	for _ = 1, 31 do
		Fake.advance(1000)
	end
	local sent = Fake.status_sent(dead)
	check(#sent >= 1 and sent[1].full == true and sent[1].seq == 1, "a copy that comes back gets a full first contact")
	local before = #sent
	for _ = 1, 5 do
		Fake.advance(1000)
	end
	check(#Fake.status_sent(dead) >= before + 4, "and the normal heartbeat after it")
	check(mentions() == 2, "coming back logs nothing more")
end

-- The same copy failing again later is said again once, and backs off again.
do
	Fake.world().dead[dead] = true
	local tries_before = Fake.world().event_attempts[dead] or 0
	for _ = 1, 60 do
		Fake.advance(1000)
	end
	local tries = (Fake.world().event_attempts[dead] or 0) - tries_before
	check(tries >= 3 and tries <= 8, "a second failure backs off again: " .. tries)
	check(mentions() == 3, "and the window says it once more (the full text was already logged): " .. mentions())
end

print("Deadcopy: " .. checks .. " checks passed")
