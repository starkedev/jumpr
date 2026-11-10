--!strict
-- The window half started in a window that is already open (a plugin reload: no `window_start`), run against the
-- fake window: its heartbeats, the leader lock shared with other windows through the window file, closing a copy
-- left alone in its tab, hiding and showing the list, and the diagnostics dump.

local Fake = require("./support/fake_window")
local Copies = require("../lib/window/copies")
local Diag = require("../lib/window/diag")
local Leader = require("../lib/window/leader")
local Pusher = require("../lib/window/pusher")
local Startup = require("../lib/window/startup")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local cx = Fake.cx
local WINDOW_FILE = "/data/window.json"

-- One machine with a deck session of two tabs, each holding one agent, in view.
Fake.host("laptop", "local")
local h = Fake.host("devbox")
local deck = Fake.session(h, "deck")
local t1, t2 = Fake.tab(deck), Fake.tab(deck)
local agent_a = Fake.agent(t1, "agent-a")
local agent_b = Fake.agent(t2, "agent-b")
Fake.view(deck)
Fake.focus(agent_a)

-- A reload into an open window: the load-time timer starts everything on the next tick.
Startup.arm()
check(#Fake.world().opened == 0, "nothing starts before the load-time timer runs")
Fake.advance(0)
check(#Fake.copies_in(t1) == 1 and #Fake.copies_in(t2) == 1, "the start opens a copy in every tab")
local file = Fake.files()[WINDOW_FILE]
check(file ~= nil and file.leader.uid == Leader.uid(), "the start takes the free leader lock")
check(file.deck_sessions.devbox == "deck", "the start records the deck session holding the copies")
local copy1, copy2 = Fake.copies_in(t1)[1], Fake.copies_in(t2)[1]
check(#Fake.status_sent(copy1) == 0, "a copy opened at the start has no status yet")
Fake.advance(250)
local first1, first2 = Fake.status_sent(copy1)[1], Fake.status_sent(copy2)[1]
check(first1 ~= nil and first2 ~= nil, "every new copy gets status within 250 ms")
check(first1.full == true and first2.full == true, "a copy's first status is a full snapshot")

-- The heartbeats run with no event: a copy quiet for a second gets a status message, and the leader's lock is
-- rewritten every 2 s.
do
	local before = #Fake.status_sent(copy1)
	local hb = Fake.files()[WINDOW_FILE].leader.hb_ms
	Fake.advance(2000)
	check(#Fake.status_sent(copy1) >= before + 2, "a quiet copy gets a heartbeat every second")
	check(Fake.files()[WINDOW_FILE].leader.hb_ms >= hb + 2000, "the leader rewrites its lock every 2 s")
end

-- Another window that takes the lock (focus moved to it) keeps this one from opening copies while it beats; once its
-- lock is more than 5 s old, this window takes over and opens them.
local t3 = Fake.tab(deck)
do
	Fake.agent(t3, "agent-c")
	local function other_takes()
		local f = Fake.files()[WINDOW_FILE]
		f.leader = { uid = "otherwindow", hb_ms = Fake.wall() }
	end
	other_takes()
	check(Copies.ensure(cx) == "ignored" and #Fake.copies_in(t3) == 0, "a window that is not the leader opens no copy")
	Fake.advance(4000)
	other_takes()
	Fake.advance(4000)
	check(Fake.files()[WINDOW_FILE].leader.uid == "otherwindow", "a lock the other window keeps beating stays its own")
	check(Copies.ensure(cx) == "ignored" and #Fake.copies_in(t3) == 0, "and this window still opens no copy")
	Fake.advance(6000)
	check(Fake.files()[WINDOW_FILE].leader.uid == Leader.uid(), "a lock left for over 5 s is taken over")
	check(Copies.ensure(cx) == "ready" and #Fake.copies_in(t3) == 1, "the new leader opens the missing copy")
end

-- An agent's pane closing leaves its copy alone in the tab: the copy closes too, and focus that was on it (which
-- Tern moves on to the agent in the next tab) moves to that tab's copy. The deck session's last copy stays.
do
	Fake.focus(copy2)
	Fake.close(agent_b)
	Pusher.rebuild(cx)
	Copies.tidy(cx)
	check(#Fake.copies_in(t2) == 0, "a copy left alone in its tab is closed")
	check(Fake.world().focused == Fake.copies_in(t3)[1], "focus moves to the copy in the tab Tern shows next")
	-- Every other pane of the deck session closes, then agent-a's: t1's copy is the session's last.
	local others: { number } = {}
	for pane, p in Fake.world().panes do
		if p.session == deck and p.tab ~= t1 then
			table.insert(others, pane)
		end
	end
	for _, pane in others do
		Fake.close(pane)
	end
	Fake.close(agent_a)
	Pusher.rebuild(cx)
	Copies.tidy(cx)
	check(#Fake.copies_in(t1) == 1, "the deck session's last copy stays")
end

-- Hiding closes every copy on the machine (a tab that held only a copy closes with it); showing opens one in every
-- tab of the deck session again and focuses the list.
local t4, t5 = Fake.tab(deck), Fake.tab(deck)
do
	Fake.agent(t4, "agent-d")
	Fake.agent(t5, "agent-e")
	Fake.focus(Fake.copies_in(t1)[1])
	Copies.ensure(cx)
	check(#Fake.copies_in(t4) == 1 and #Fake.copies_in(t5) == 1, "new tabs get their copies")
	Copies.hide(cx)
	check(Leader.hidden(), "hiding sets the hidden flag in the window file")
	check(#Fake.copies_in(t4) == 0 and #Fake.copies_in(t5) == 0, "hiding closes every copy")
	check(table.find(Fake.world().sessions[deck].tabs, t1) == nil, "a tab that held only a copy closes")
	Copies.ensure(cx)
	check(#Fake.copies_in(t4) == 0, "no copy opens while the list is hidden")
	Copies.show_all(cx)
	check(not Leader.hidden(), "showing clears the hidden flag")
	check(#Fake.copies_in(t4) == 1 and #Fake.copies_in(t5) == 1, "showing opens a copy in every tab")
	local focused = Fake.world().focused
	check(focused ~= nil and Fake.world().panes[focused].block ~= nil, "showing focuses the list")
end

-- The diagnostics dump: the window's file is written at once with what each module holds, the host in view is asked
-- for its own, and with no answer in 10 s the window's path alone is copied and the toast says the host's is missing.
do
	local path = Diag.write(cx)
	check(path ~= nil, "the window dump is written")
	local dump = Fake.files()[path :: string]
	check(dump.leader ~= nil and dump.copies ~= nil and dump.pusher ~= nil, "the dump holds each module's state")
	local copy = Fake.copies_in(t4)[1]
	Diag.ask_host(cx, copy, "devbox")
	local asked = false
	for _, e in Fake.world().events do
		if e.pane == copy and e.act == "diag" then
			asked = true
		end
	end
	check(asked, "the copy in view is asked for the host's dump")
	check(Diag.asking(), "the window waits for the host's answer")
	Fake.advance(10000)
	check(not Diag.asking(), "the wait ends after 10 s")
	local copied = Fake.world().copied
	check(copied[#copied] == "laptop:" .. (path :: string), "the window's path alone is copied, named by machine")
	local toasts = Fake.world().toasts
	check(toasts[#toasts].text == "host dump unavailable", "the toast says the host's dump is missing")
end

print("Window: " .. checks .. " checks passed")
