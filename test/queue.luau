--!strict

local Model = require("../lib/host/model")
local Queue = require("../lib/host/queue")
local Store = require("../lib/host/store")
local Transport = require("../lib/host/transport")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local NOW = 1800000000000

-- One live agent `a` (pane 11) holding the message "go", idle on a status entry.
local function sample(): (Store.Deck, Model.PaneSets, Model.StatusById)
	local deck = Store.empty()
	table.insert(deck.groups, { gid = "g1", name = "webapp", cwd = "/w", folded = false })
	deck.agents.a = {
		gid = "g1",
		pos = 1,
		dir = "~/.omp/deck/a",
		cwd = "/w",
		created_ms = NOW - 100000,
		state = "live",
		pane = 11,
	}
	deck.queue.a = { text = "go", at_ms = NOW - 100 }
	return deck, { a = { [11] = true } }, { a = { { s = "i", src = "agents" } } }
end

-- The ids of the held messages due now (the queue sweep, with nothing seen working unless `seen` says so).
local function due_ids(
	deck: Store.Deck,
	sets: Model.PaneSets,
	status: Model.StatusById,
	fresh: boolean,
	seen: { [string]: boolean }?,
	now: number
): string
	local ids = {}
	for _, d in Queue.sweep(deck, sets, status, fresh, seen or {}, now) do
		table.insert(ids, d.id)
	end
	return table.concat(ids, ",")
end

-- Held, then sent exactly once on idle: due, mark_sent deletes it, and nothing is due again.
do
	local deck, sets, status = sample()
	local due = Queue.sweep(deck, sets, status, true, {}, NOW)
	check(#due == 1 and due[1].id == "a" and due[1].entry.text == "go", "an idle agent with a held message is due")
	local q, sent = Queue.mark_sent(deck.queue, deck, "a", NOW)
	check(sent.queue == q and q.a == nil, "mark_sent deletes the entry; the returned deck carries the returned queue")
	check(sent.agents.a.last_send_ms == NOW, "and stamps the record's last_send_ms")
	check(deck.queue.a ~= nil and deck.agents.a.last_send_ms == nil, "the input deck is untouched")
	check(due_ids(sent, sets, status, true, {}, NOW + 1000) == "", "an idle status again sends nothing: it is gone")
	check(due_ids(sent, sets, status, true, { a = true }, NOW + 60000) == "", "nor later, nor after working")
end

-- Not on waiting_input, but on idle with an unseen finish; not while stale, on a duplicate or with no pane.
do
	local deck, sets, status = sample()
	status.a = { { s = "q" } }
	check(due_ids(deck, sets, status, true, nil, NOW) == "", "waiting_input (s = q, shown @) is not due")
	status.a = { { s = "i", u = true } }
	check(due_ids(deck, sets, status, true, nil, NOW) == "a", "idle with an unseen finish (also @) is due")
	status.a = { { s = "w" } }
	check(due_ids(deck, sets, status, true, nil, NOW) == "", "a working agent is not due")
	status.a = { { s = "x" } }
	check(due_ids(deck, sets, status, true, nil, NOW) == "", "an exited status is not due")
	status.a = { { s = "i" } }
	check(due_ids(deck, sets, status, false, nil, NOW) == "", "stale status is not due")
	check(due_ids(deck, sets, {}, true, nil, NOW) == "", "no status entry is not due")
	sets.a = { [11] = true, [12] = true }
	check(due_ids(deck, sets, status, true, nil, NOW) == "", "a duplicate (two panes) is not due")
	sets.a = { [11] = true }
	status.a = { { s = "i" }, { s = "i" } }
	check(due_ids(deck, sets, status, true, nil, NOW) == "", "a duplicate (two status entries) is not due")
	status.a = { { s = "i" } }
	sets.a = {}
	check(due_ids(deck, sets, status, true, nil, NOW) == "", "no bound pane is not due")
end

-- Not due while the record is pending, stopping or exited.
do
	for _, state in { "pending", "stopping", "exited" } do
		local deck, sets, status = sample()
		deck.agents.a.state = state
		check(due_ids(deck, sets, status, true, nil, NOW) == "", "not due while the record is " .. state)
	end
	local deck, sets, status = sample()
	check(due_ids(deck, sets, status, true, nil, NOW) == "a", "the same agent is due once the record is live")
end

-- set replaces a held message and never adds a second one.
do
	local q: Queue.Queue = {}
	local first = Queue.set(q, "a", "one", NOW)
	check(first.a ~= nil and first.a.text == "one" and first.a.at_ms == NOW, "set stores the text")
	check(q.a == nil, "set leaves the input queue untouched")
	local second, notice = Queue.set(first, "a", "two", NOW + 5)
	local n = 0
	for _ in second do
		n += 1
	end
	check(n == 1 and second.a ~= nil and second.a.text == "two" and second.a.at_ms == NOW + 5, "a second set replaces")
	check(notice == nil, "storing gives no notice")
	check(Queue.held(second, "a") == second.a and Queue.held(second, "b") == nil, "held reads one agent's entry")
	local other = Queue.set(second, "b", "three", NOW)
	check(other.a ~= nil and other.b ~= nil, "each agent holds its own")
end

-- set with empty text cancels a held message and says so; with nothing held it stores nothing and says nothing.
do
	local q = Queue.set({}, "a", "one", NOW)
	local cleared, notice = Queue.set(q, "a", "", NOW + 1)
	check(cleared.a == nil and notice == "queued message cancelled", "empty text cancels with the notice")
	check(q.a ~= nil, "cancelling leaves the input queue untouched")
	local empty: Queue.Queue = {}
	local same, none = Queue.set(empty, "a", "", NOW)
	check(same == empty and next(same) == nil and none == nil, "empty text with nothing held stores nothing, no notice")
end

-- A message queued right after a send waits for working-then-idle or 30 s.
do
	local deck, sets, status = sample()
	local _, sent = Queue.mark_sent(deck.queue, deck, "a", NOW)
	sent.queue = Queue.set(sent.queue, "a", "next", NOW + 100)
	check(due_ids(sent, sets, status, true, {}, NOW + 200) == "", "idle right after a send: not due")
	check(due_ids(sent, sets, status, true, {}, NOW + 29999) == "", "still not due just under 30 s")
	check(due_ids(sent, sets, status, true, {}, NOW + 30000) == "a", "due at 30 s")
	check(due_ids(sent, sets, status, true, { a = true }, NOW + 200) == "a", "or at once after a working status")
	check(
		due_ids(sent, sets, status, true, { b = true }, NOW + 200) == "",
		"another agent's working status does not count"
	)
end

-- Reload right after a send: last_send_ms comes back from kv, seen_working is false again.
do
	local deck, sets, status = sample()
	local _, sent = Queue.mark_sent(deck.queue, deck, "a", NOW)
	local reloaded = Store.migrate(Store.clone(sent), NOW + 1)
	check(reloaded.agents.a.last_send_ms == NOW, "last_send_ms survives the kv round trip")
	reloaded.queue = Queue.set(reloaded.queue, "a", "after reload", NOW + 2)
	check(due_ids(reloaded, sets, status, true, {}, NOW + 5000) == "", "an idle status at +5 s is not due")
	check(due_ids(reloaded, sets, status, true, {}, NOW + 30000) == "a", "due at +30 s")
	check(due_ids(reloaded, sets, status, true, { a = true }, NOW + 5000) == "a", "or at once after working then idle")
end

-- After a simulated reload (state rebuilt from the saved kv after mark_sent), nothing is sent again.
do
	local deck, sets, status = sample()
	check(due_ids(deck, sets, status, true, {}, NOW) == "a", "due before the send")
	local _, sent = Queue.mark_sent(deck.queue, deck, "a", NOW)
	local reloaded = Store.migrate(Store.clone(sent), NOW + 1)
	check(next(reloaded.queue) == nil, "the saved deck holds no message")
	check(due_ids(reloaded, sets, status, true, {}, NOW + 1) == "", "so a reload sends nothing again")
	check(due_ids(reloaded, sets, status, true, {}, NOW + 60000) == "", "not even later")
end

-- A failed entry stays held with its error, for the next idle (after the 30 s guard).
do
	local deck, sets, status = sample()
	local entry = deck.queue.a
	local _, sent = Queue.mark_sent(deck.queue, deck, "a", NOW)
	sent.queue = Queue.mark_failed(sent.queue, "a", entry, "pane gone")
	local failed = sent.queue.a
	check(failed ~= nil and failed.text == "go" and failed.err == "pane gone", "the entry stays held with its error")
	check(failed.at_ms == entry.at_ms, "and keeps its time")
	check(deck.queue.a.err == nil, "mark_failed does not change the input")
	check(due_ids(sent, sets, status, true, {}, NOW + 1000) == "", "it is not retried at once")
	check(due_ids(sent, sets, status, true, {}, NOW + 30000) == "a", "it is due again at the next idle after 30 s")
	check(Model.hold(failed, "ok", true, false) == "failed: pane gone", "and the row says why")
end

-- transport keeps seen_working per deck id for the sweep; sent clears it.
do
	local deck, sets = sample()
	local T = 100000
	local state = Transport.new()
	local st = Transport.new_status()
	Transport.register(state, st)
	st.windows.W = { seq = 1, at_ms = T, a = { a = { { s = "i" } } }, carried = { a = 1 } }
	st.last_ms = T
	check(#Transport.due(state, deck, sets, T + 500, NOW) == 1, "a fresh idle status makes the held message due")
	check(#Transport.due(state, deck, sets, T + 4000, NOW) == 0, "a status over 3 s old holds it (stale)")
	check(#Transport.due(Transport.new(), deck, sets, T, NOW) == 0, "with no status at all it is held (unavailable)")
	deck.agents.a.last_send_ms = NOW - 5000
	check(#Transport.due(state, deck, sets, T + 500, NOW) == 0, "a send 5 s ago and nothing seen working: wait")
	state.seen_working.a = true
	check(#Transport.due(state, deck, sets, T + 500, NOW) == 1, "a working status seen since: due at once")
	Transport.sent(state, "a")
	check(state.seen_working.a == nil, "sent clears seen_working for that id")
	check(#Transport.due(state, deck, sets, T + 500, NOW) == 0, "so the next message waits for working-then-idle")
	check(#Transport.due(state, deck, sets, T + 500, NOW + 30000) == 1, "or 30 s")
end

-- The agent whose q line is open is never swept (a cancel or an edit is not raced by a send); the others are.
do
	local deck, sets, status = sample()
	deck.agents.b = {
		gid = "g1",
		pos = 2,
		dir = "~/.omp/deck/b",
		cwd = "/w",
		created_ms = NOW - 100000,
		state = "live",
		pane = 12,
	}
	deck.queue.b = { text = "second agent", at_ms = NOW - 50 }
	sets.b = { [12] = true }
	status.b = { { s = "i" } }
	check(due_ids(deck, sets, status, true, nil, NOW) == "a,b", "both held messages are due")
	local skipped = {}
	for _, d in Queue.sweep(deck, sets, status, true, {}, NOW, "a") do
		table.insert(skipped, d.id)
	end
	check(table.concat(skipped, ",") == "b", "with a's q line open only b is swept")
	check(#Queue.sweep(deck, sets, status, true, {}, NOW, "zzz") == 2, "an id that holds nothing skips nothing")
end

-- An `o` that was not typed: the stamp goes back, and the text is held with the error unless a message is held.
do
	local deck = sample()
	deck.agents.a.last_send_ms = NOW
	local kept = Queue.unsent(deck, "a", "now", NOW - 40000, "no pty", NOW)
	check(kept ~= deck and deck.agents.a.last_send_ms == NOW, "unsent returns a new deck and leaves the old one")
	check(kept.agents.a.last_send_ms == NOW - 40000, "the stamp the send replaced goes back")
	check(kept.queue.a.text == "go" and kept.queue.a.err == nil, "a held message is kept as it was")
	deck.queue = {}
	local held = Queue.unsent(deck, "a", "now", nil, "no pty", NOW)
	check(held.agents.a.last_send_ms == nil, "with no earlier stamp the record has none")
	check(held.queue.a.text == "now" and held.queue.a.err == "no pty", "the text is held with the error")
end

print("Queue: " .. checks .. " checks passed")
