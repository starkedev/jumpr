--!strict
-- The host's requests to the window (lib/host/requests.luau): building a request, the ledger of requests waiting
-- for a reply, what a reply settles, and what happens when none comes.

local Protocol = require("../lib/shared/protocol")
local Requests = require("../lib/host/requests")
local Store = require("../lib/host/store")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local NOW = 100000
local WALL = 1800000000000

-- Machine devbox, deck session `deck`, with a live agent `a` and a pending start `p`.
local function deck(): Store.Deck
	local d = Store.empty()
	d.session = { name = "deck", host = "devbox" }
	table.insert(d.groups, { gid = "g1", name = "work", cwd = "/work", folded = false })
	d.agents.a = {
		gid = "g1",
		pos = 1,
		dir = "~/.omp/deck/a",
		cwd = "/work",
		created_ms = WALL - 1000,
		state = "live",
		pane = 11,
		label = "fixer",
	}
	d.agents.p = { gid = "g1", pos = 2, dir = "~/.omp/deck/p", cwd = "/work", created_ms = WALL, state = "pending" }
	d.next_req = 5
	return d
end

local uids = 0
local function new_uid(): string
	uids += 1
	return "uid" .. tostring(uids)
end

-- A request takes `r` from the deck and advances it; the URL names the host, the deck session and the fields.
do
	local ledger = Requests.new()
	local d = deck()
	local sender = Requests.new_sender(nil, d, false, new_uid)
	local url, out = Requests.request(ledger, sender, d, false, "jump", { id = "a" }, NOW, new_uid)
	local req = Protocol.parse_url(url)
	check(req ~= nil and req.verb == "jump" and req.r == 5 and req.b == sender.b, "r comes from next_req")
	check(req ~= nil and req.host == "devbox" and req.sn == "deck" and req.fields.id == "a", "host, session, fields")
	check(out.next_req == 6 and d.next_req == 5, "the returned deck counts on; the input deck is untouched")
	-- kv reset below the sender's last r: a new uid, so the window never drops the request as a repeat.
	local before = sender.b
	Requests.request(ledger, sender, d, false, "jump", { id = "a" }, NOW, new_uid)
	check(sender.b ~= before, "a restarted r takes a new block uid")
	-- Read-only data: r counted in memory, the deck unchanged.
	local ro = Requests.new_sender(nil, d, true, new_uid)
	local ro_url, ro_out = Requests.request(ledger, ro, d, true, "jump", { id = "a" }, NOW, new_uid)
	local ro_req = Protocol.parse_url(ro_url)
	check(ro_req ~= nil and ro_req.r == 1 and ro_out == d, "read-only counts r in memory and keeps the deck")
end

-- A saved block uid is kept only while next_req counts on from it.
do
	local d = deck()
	check(Requests.new_sender("saved", d, false, new_uid).b == "saved", "a saved uid is kept")
	check(Requests.new_sender("saved", d, true, new_uid).b ~= "saved", "not with read-only data")
	local reset = deck()
	reset.next_req = 1
	check(Requests.new_sender("saved", reset, false, new_uid).b ~= "saved", "not after next_req restarted")
end

-- Only start and stop wait for a reply; jump and show are remembered; the pending list is oldest first.
do
	local ledger = Requests.new()
	local d = deck()
	local sender = Requests.new_sender(nil, d, false, new_uid)
	local _, d2 = Requests.request(ledger, sender, d, false, "stop", { id = "a" }, NOW, new_uid)
	local _, d3 = Requests.request(ledger, sender, d2, false, "start", { id = "p", cwd = "/work" }, NOW, new_uid)
	Requests.request(ledger, sender, d3, false, "hello", {}, NOW, new_uid)
	local pending = Requests.pending(ledger)
	check(#pending == 2 and pending[1].verb == "stop" and pending[2].verb == "start", "start and stop wait, in order")
	Requests.clear_start(ledger, "p")
	pending = Requests.pending(ledger)
	check(#pending == 1 and pending[1].verb == "stop", "a binding clears the pending start")
end

-- No reply: a start still pending at REPLY_MS fails with no_reply; before that nothing happens; a stop with none is
-- taken back and said.
do
	local ledger = Requests.new()
	local d = deck()
	d.agents.a.state = "stopping"
	d.agents.a.stop_ms = WALL
	local sender = Requests.new_sender(nil, d, false, new_uid)
	local _, d2 = Requests.request(ledger, sender, d, false, "start", { id = "p", cwd = "/work" }, NOW, new_uid)
	local _, d3 = Requests.request(ledger, sender, d2, false, "stop", { id = "a" }, NOW, new_uid)
	local early, early_notices = Requests.expire(ledger, d3, NOW + Requests.REPLY_MS - 1, WALL)
	check(early == d3 and #early_notices == 0, "before the reply limit nothing expires")
	local out, notices, errors = Requests.expire(ledger, d3, NOW + Requests.REPLY_MS, WALL + 1)
	check(out.agents.p.failed == true, "a start with no reply is marked failed")
	check(out.agents.a.state == "live", "a stop with no reply is taken back")
	check(#notices == 1 and #errors == 1 and errors[1] == "stop a: no reply", "and it is said and logged")
	check(#Requests.pending(ledger) == 0, "both leave the ledger")
end

-- Replies: a failed start is marked failed and named; a successful one just leaves the ledger; a failed stop is taken
-- back; a failed jump or show names its agent, and a jump forgotten after a minute names none.
do
	local ledger = Requests.new()
	local d = deck()
	d.agents.a.state = "stopping"
	d.agents.a.stop_ms = WALL
	local sender = Requests.new_sender(nil, d, false, new_uid)
	local b = sender.b
	local _, d2 = Requests.request(ledger, sender, d, false, "start", { id = "p", cwd = "/work" }, NOW, new_uid)
	local _, d3 = Requests.request(ledger, sender, d2, false, "stop", { id = "a" }, NOW, new_uid)
	local _, d4 = Requests.request(ledger, sender, d3, false, "show", { id = "a" }, NOW, new_uid)
	local _, d5 = Requests.request(ledger, sender, d4, false, "jump", { id = "a" }, NOW, new_uid)
	local failed, notice, line = Requests.reply(ledger, b, 5, false, "no session", d5, WALL)
	check(failed.agents.p.failed == true, "a failed start is marked failed")
	check(notice == "start p failed on devbox: no session", "and named by agent and machine")
	check(line == "start p failed: no session", "and logged")
	local stopped, stop_notice = Requests.reply(ledger, b, 6, false, "", d5, WALL)
	check(stopped.agents.a.state == "live", "a failed stop is taken back")
	check(stop_notice ~= nil and string.find(stop_notice, "no reason given", 1, true) ~= nil, "with no reason given")
	local _, show_notice = Requests.reply(ledger, b, 7, false, "gone", d5, WALL)
	check(show_notice == "show fixer failed on devbox: gone", "a failed show names its agent")
	local same, ok_notice = Requests.reply(ledger, b, 8, true, nil, d5, WALL)
	check(same == d5 and ok_notice == nil, "a successful jump says nothing")
	Requests.expire(ledger, d5, NOW + 60 * 1000, WALL)
	local _, late = Requests.reply(ledger, b, 8, false, "gone", d5, WALL)
	check(late ~= nil and string.find(late, "jump to ", 1, true) == 1, "a forgotten jump still says a jump failed")
	check(#Requests.pending(ledger) == 0, "every reply left the ledger")
end

print("Requests: " .. checks .. " checks passed")
