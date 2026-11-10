--!strict
-- The jumpr:// requests a list sends its window, run against the fake window: a request from another protocol
-- version, a start while the deck session is out of view, a request seen twice, and a start in view.

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

-- This machine, and a machine devbox with deck session `deck` (one tab: a copy of the list and an agent) and a
-- second session `notes`.
Fake.host("laptop", "local")
local h = Fake.host("devbox")
local deck = Fake.session(h, "deck")
local notes = Fake.session(h, "notes")
local t1 = Fake.tab(deck)
Fake.agent(t1, "agent-a")
local copy = Fake.pane(t1, { kind = "plugin", block = Protocol.BLOCK_KIND, left = true })
local notes_tab = Fake.tab(notes)
Fake.pane(notes_tab)
Fake.view(deck)
Fake.focus(copy)
Leader.take()
Pusher.rebuild(cx)

-- The replies (`act = "res"`) sent so far.
local function replies(): { any }
	local out = {}
	for _, e in Fake.world().events do
		if e.act == "res" then
			table.insert(out, e.value)
		end
	end
	return out
end

local function last_toast(): Fake.Toast?
	local toasts = Fake.world().toasts
	return toasts[#toasts]
end

-- A request from a newer version names this machine to update; one from an older version names the sender. Neither
-- is acted on, and the log names the verb and `p` but never the rest of the query (it can carry a prompt).
do
	local verb = Router.handle(cx, "jumpr://jump?p=3&b=blk&r=1&host=devbox&prompt=secret%20words", copy)
	check(verb == nil, "a newer version's request is not acted on")
	local toast = last_toast()
	check(
		toast ~= nil and toast.text == "Jumpr on devbox is newer: update Jumpr on laptop",
		"a newer version names this machine to update"
	)
	Router.handle(cx, "jumpr://jump?b=blk&r=2&host=devbox&prompt=secret%20words", copy)
	toast = last_toast()
	check(
		toast ~= nil and toast.text == "Jumpr on devbox is older: update Jumpr on devbox",
		"an older version (no p) names the sending machine to update"
	)
	local logged = table.concat(Fake.logs(), "\n")
	check(string.find(logged, "jump request from devbox with p=3", 1, true) ~= nil, "the log names the verb and p")
	check(string.find(logged, "secret", 1, true) == nil, "the log never holds the rest of the query")
end

-- A start for a machine whose deck session is not in view starts nothing and is answered with why; the same request
-- seen again is not answered twice.
do
	Fake.view(notes)
	local url = Protocol.request_url("start", "blk", 10, "devbox", { id = "agent-new", cwd = "/work" }, "deck")
	check(Router.handle(cx, url, nil) == "start", "a start naming no pane is acted on by its host's name")
	local r = replies()
	check(#r == 1 and r[1].ok == false and r[1].r == 10, "the start is answered with a failure")
	check(
		r[1].err == "agent agent-new not started: the deck session of devbox is not in view",
		"the failure says the deck session is not in view"
	)
	check(#Fake.world().sessions[deck].tabs == 1, "no agent tab is opened")
	check(Router.handle(cx, url, nil) == nil and #replies() == 1, "a request seen again is dropped")
end

-- A start from the copy in focus opens the agent in a new tab of the deck session, answers ok, gives the tab its own
-- copy and its label, and leaves focus in the list.
do
	Fake.view(deck)
	Fake.focus(copy)
	local url =
		Protocol.request_url("start", "blk", 11, "devbox", { id = "agent-new", cwd = "/work", label = "fix" }, "deck")
	check(Router.handle(cx, url, copy) == "start", "a start from the focused copy is acted on")
	local r = replies()
	check(#r == 2 and r[2].ok == true and r[2].r == 11, "the start is answered ok")
	local tabs = Fake.world().sessions[deck].tabs
	check(#tabs == 2, "the agent opens in a new tab of the deck session")
	local new_tab = tabs[2]
	check(#Fake.copies_in(new_tab) == 1, "the new tab gets its own copy of the list")
	check(Fake.world().named[new_tab] == "fix", "the new tab is named with the agent's label")
	check(Fake.world().focused == copy, "focus stays in the list")
	local started = false
	for _, pane in Fake.world().order[new_tab] do
		local p = Fake.world().panes[pane]
		if p.kind == "agent" and p.line == "omp --continue --session-dir ~/.omp/deck/agent-new" then
			started = true
		end
	end
	check(started, "the agent runs omp in its deck session folder")
end

print("Router: " .. checks .. " checks passed")
