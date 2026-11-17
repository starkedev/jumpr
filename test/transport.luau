--!strict

local Protocol = require("../lib/shared/protocol")
local Requests = require("../lib/host/requests")
local Store = require("../lib/host/store")
local Transport = require("../lib/host/transport")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local T = 100000
local NOW = 1800000000000

-- live_hosts: the names every window heard within the last minute gives the host, over every copy.
do
	local state = Transport.new()
	local a = Transport.new_status()
	local b = Transport.new_status()
	Transport.register(state, a)
	Transport.register(state, b)
	a.windows.linux = { seq = 1, at_ms = T, a = {}, carried = {}, hn = "devbox" }
	b.windows.mac = { seq = 1, at_ms = T - 30000, a = {}, carried = {}, hn = "me@devbox" }
	b.windows.old = { seq = 1, at_ms = T - 60000, a = {}, carried = {}, hn = "gone" }
	b.windows.quiet = { seq = 1, at_ms = T, a = {}, carried = {} }
	local live = Transport.live_hosts(state, T)
	check(live.devbox == true and live["me@devbox"] == true, "both machines' names for the host are live")
	check(live.gone == nil, "a window silent for a minute no longer holds its name")
	local count = 0
	for _ in live do
		count += 1
	end
	check(count == 2, "a window that sent no name adds none")
	Transport.unregister(state, b)
	check(Transport.live_hosts(state, T)["me@devbox"] == nil, "a dropped copy's windows no longer count")
end

-- settled: a minute after the first status message since the host half started.
do
	local state = Transport.new()
	check(not Transport.settled(state, T), "before any status the host is not settled")
	state.since = T
	check(not Transport.settled(state, T + 59999), "under a minute it is not")
	check(Transport.settled(state, T + 60000), "a minute after the first status it is")
end

-- One copy's status route on a machine, and window W's message count.
type Route = { state: Transport.State, st: Transport.Status, seq: number, values: { [string]: any } }

local function route(): Route
	local state = Transport.new()
	local st = Transport.new_status()
	Transport.register(state, st)
	return { state = state, st = st, seq = 0, values = {} }
end

-- Agent `a` of kind `cli`, live in pane 11 and holding the message "go"; `fields` override its record (an exited
-- one has no pane).
local function holding(cli: string, fields: { [string]: any }?): Store.Deck
	local deck = Store.empty()
	deck.session = { name = "deck", host = "devbox" }
	table.insert(deck.groups, { gid = "g1", name = "work", cwd = "/w", folded = false })
	local r: Store.Record =
		{ gid = "g1", pos = 1, cwd = "/w", created_ms = NOW - 100000, state = "live", pane = 11, cli = cli }
	for k, v in (fields or {}) :: { [string]: any } do
		(r :: any)[k] = v
	end
	if r.state == "exited" then
		r.pane = nil
	end
	deck.agents.a = r
	deck.queue.a = { text = "go", at_ms = NOW - 100 }
	return deck
end

-- Window W's next full status message at `now`, carrying `entries` for `a` (nil: no pane of it listed yet), as the
-- block takes it (`on_action`); the ids of the held messages it makes due, comma-joined.
local function report(r: Route, deck: Store.Deck, entries: { any }?, now: number): string
	r.seq += 1
	local token = "status#" .. tostring(r.seq)
	r.values[token] = {
		p = Protocol.P,
		w = "W",
		seq = r.seq,
		full = true,
		t = NOW,
		h = "connected",
		sn = "deck",
		hn = "devbox",
		dupb = false,
		em = "A",
		a = if entries ~= nil then { a = entries } else {},
	}
	local live = deck.agents.a.state == "live" and deck.agents.a.pane ~= nil
	local out = Transport.on_action(r.state, r.st, { ev = "action", act = "st", value = token }, {
		deck = deck,
		readonly = false,
		b = "b1",
		now = now,
		wall = NOW,
		io = {
			fs_write = function(_path: string, _text: string): (boolean, string?)
				return true, nil
			end,
			json_encode = function(_value: any, _pretty: boolean?): string
				return ""
			end,
			json_decode = function(text: string): (any, string?)
				return r.values[text], nil
			end,
		},
		data_dir = "/data",
		binding = function(): any
			return {}
		end,
		sets = if live then { a = { [11] = true } } else {},
		skip = nil,
		requests = Requests.new(),
	})
	local ids: { string } = {}
	for _, d in out.due do
		table.insert(ids, d.id)
	end
	return table.concat(ids, ",")
end

-- A claude or codex agent's held message is flushed from the merged status only on an idle the agent reported itself
-- (Tern's agent state): not while it starts (no pane listed yet, or busy on a first screen with no agent state), nor
-- on a pane that only reads not busy (a shell prompt), nor while it works, asks or has exited. An omp agent still
-- takes one on any idle.
do
	type Cell = { name: string, entries: { any }?, fields: { [string]: any }?, due: boolean }
	local cells: { Cell } = {
		{ name = "starting, no pane listed yet", entries = nil, due = false },
		{ name = "starting, busy on a first screen", entries = { { s = "w", src = "pane" } }, due = false },
		{ name = "a pane that only reads not busy", entries = { { s = "i", src = "pane" } }, due = false },
		{ name = "an idle it reported", entries = { { s = "i", src = "agents" } }, due = true },
		{ name = "an unseen finish it reported", entries = { { s = "i", u = true, src = "agents" } }, due = true },
		{ name = "working", entries = { { s = "w", src = "agents" } }, due = false },
		{ name = "asking", entries = { { s = "q", src = "agents" } }, due = false },
		{
			name = "exited",
			entries = { { s = "x", e = "exit status 1", src = "pane" } },
			fields = { state = "exited", exit = 1, ended_ms = NOW - 50 },
			due = false,
		},
	}
	for _, cli in { "claude", "codex" } do
		for _, cell in cells do
			local deck = holding(cli, cell.fields)
			local got = report(route(), deck, cell.entries, T)
			check(got == (if cell.due then "a" else ""), cli .. ", " .. cell.name .. ": due " .. got)
		end
	end
	check(report(route(), holding("omp"), { { s = "i", src = "pane" } }, T) == "a", "omp: any idle, as before")
end

-- A send moments ago holds the next message until a working status after it, or the guard: a claude or codex agent
-- seen working since (the merged status feeds `seen_working` for it too) is due once it reports idle.
do
	for _, cli in { "claude", "codex" } do
		local deck = holding(cli, { last_send_ms = NOW - 5000 })
		local r = route()
		check(report(r, deck, { { s = "i", src = "agents" } }, T) == "", cli .. ": idle right after a send waits")
		check(report(r, deck, { { s = "w", src = "agents" } }, T + 1000) == "", cli .. ": working takes nothing")
		check(r.state.seen_working.a == true, cli .. ": the working status is seen")
		check(
			report(r, deck, { { s = "i", src = "pane" } }, T + 2000) == "",
			cli .. ": a pane alone reading idle waits"
		)
		check(report(r, deck, { { s = "i", src = "agents" } }, T + 3000) == "a", cli .. ": its reported idle is due")
	end
end

print("Transport: " .. checks .. " checks passed")
