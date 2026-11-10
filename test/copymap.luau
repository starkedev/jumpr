--!strict
-- The copy map the window builds from one read of hosts, panes and sessions (`pusher.scan`), run against the fake
-- window, for the joins no other suite reaches: a parked copy, two copies in one tab, and a copy no host lists.

local Fake = require("./support/fake_window")
local Pusher = require("../lib/window/pusher")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local cx = Fake.cx
local COPY = { kind = "plugin", block = "jumpr.list", title = "jumpr" }

-- The last status message sent to `pane`, or nil.
local function last_status(pane: number): any
	local sent = Fake.status_sent(pane)
	return sent[#sent]
end

-- A parked copy (in no tab) takes its machine's session when the machine has only one; on a machine with two
-- sessions it is left without one rather than guessed.
do
	Fake.reset_world()
	local h = Fake.host("devbox")
	local deck = Fake.session(h, "deck")
	Fake.pane(Fake.tab(deck))
	local parked = Fake.parked(deck, COPY)
	check(Pusher.rebuild(cx), "the scan reads the window")
	local host, session = Pusher.block_info(parked)
	check(host == "devbox" and session == "deck", "a parked copy takes its machine's only session")
	check(Pusher.session_of("devbox") == "deck", "and that is the machine's deck session")
	check(Pusher.copy_in_tab(nil) == nil, "a parked copy is in no tab")

	Fake.reset_world()
	local h2 = Fake.host("devbox2")
	local one = Fake.session(h2, "one")
	Fake.session(h2, "two")
	Fake.pane(Fake.tab(one))
	local parked2 = Fake.parked(one, COPY)
	Pusher.rebuild(cx)
	local host2, session2 = Pusher.block_info(parked2)
	check(host2 == "devbox2" and session2 == nil, "with two sessions a parked copy has none")
end

-- Two copies in one tab: the lower pane is the tab's copy, and the status both get says they are a duplicate; a copy
-- alone in its tab is not.
do
	Fake.reset_world()
	local h = Fake.host("devbox3")
	local deck = Fake.session(h, "deck")
	local t1, t2 = Fake.tab(deck), Fake.tab(deck)
	Fake.agent(t1, "agent-a")
	Fake.agent(t2, "agent-b")
	local first = Fake.pane(t1, COPY)
	local second = Fake.pane(t1, COPY)
	local alone = Fake.pane(t2, COPY)
	Pusher.full(cx)
	check(Pusher.copy_in_tab(t1) == math.min(first, second), "the lower pane is the tab's copy")
	check(#Pusher.blocks_for("devbox3") == 3, "all three are copies of the machine's list")
	local a, b, c = last_status(first), last_status(second), last_status(alone)
	check(a ~= nil and a.dupb == true and b ~= nil and b.dupb == true, "both copies in one tab are told duplicate")
	check(c ~= nil and c.dupb == false, "a copy alone in its tab is not")
end

-- A copy no machine lists is no copy: it is left out of the map, gets no status, and is logged once however often
-- the window scans.
do
	Fake.reset_world()
	local h = Fake.host("devbox4")
	local deck = Fake.session(h, "deck")
	local t = Fake.tab(deck)
	local listed = Fake.pane(t, COPY)
	local stray = Fake.pane(t, { kind = "plugin", block = "jumpr.list", title = "jumpr", unhosted = true })
	local logged_before = #Fake.logs()
	Pusher.full(cx)
	Pusher.rebuild(cx)
	Pusher.rebuild(cx)
	check(not Pusher.is_block(stray) and Pusher.is_block(listed), "a copy no machine lists is not in the map")
	check(#Fake.status_sent(stray) == 0 and #Fake.status_sent(listed) > 0, "and gets no status")
	local mentions = 0
	for i = logged_before + 1, #Fake.logs() do
		if string.find(Fake.logs()[i], "has no host", 1, true) ~= nil then
			mentions += 1
		end
	end
	check(mentions == 1, "it is logged once over three scans")
	check(Pusher.copy_in_tab(t) == listed, "the tab's copy is the listed one")
end

print("Copymap: " .. checks .. " checks passed")
