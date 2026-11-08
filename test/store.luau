--!strict

local Store = require("../lib/host/store")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local DAY = 24 * 60 * 60 * 1000
local NOW = 1800000000000

local function record(state: string, fields: { [string]: any }?): Store.Record
	local r: Store.Record = {
		gid = "g1",
		pos = 1,
		dir = "~/.omp/deck/aaaa",
		cwd = "/home/a/src/webapp",
		created_ms = NOW - DAY,
		state = state,
	}
	for k, v in (fields or {}) :: { [string]: any } do
		(r :: any)[k] = v
	end
	return r
end

local function sample(): Store.Deck
	local deck = Store.empty()
	deck.session = { name = "main", host = "devbox", set_ms = NOW }
	deck.groups = { { gid = "g1", name = "webapp", cwd = "/home/a/src/webapp", folded = false } }
	deck.agents = { a = record("live", { pane = 7 }) }
	deck.next_req = 4
	return deck
end

-- nil gives the empty deck, writable, with no banner and no backup.
do
	local deck, readonly, banner, backup = Store.migrate(nil, NOW)
	check(deck.schema == 1 and #deck.groups == 0 and next(deck.agents) == nil, "nil gives empty")
	check(next(deck.queue) == nil and deck.next_req == 1, "empty has no queue and next_req 1")
	check(not readonly and banner == nil and backup == nil, "nil is writable with no banner or backup")
end

-- Schema 1 passes through as it is.
do
	local raw = sample()
	local deck, readonly, banner, backup = Store.migrate(raw, NOW)
	check(deck == raw, "schema 1 is used as it is")
	check(not readonly and banner == nil and backup == nil, "schema 1 is writable")
end

-- Schema 2 is read-only with the banner, and never backed up.
do
	local raw = sample()
	raw.schema = 2
	local deck, readonly, banner, backup = Store.migrate(raw, NOW)
	check(readonly, "a newer schema is read-only")
	check(banner == "jumpr data is from a newer version; update this machine", "a newer schema shows the banner")
	check(backup == nil, "a newer schema is not backed up")
	check(deck.groups[1].name == "webapp", "a newer schema that still reads shows its groups")
end

-- A malformed value gives empty plus a backup under jumpr.bad.<ms>.
do
	local bad: { any } = {
		"not a table",
		{ groups = {} },
		{ schema = 0, session = {}, groups = {}, agents = {}, queue = {}, next_req = 1 },
		{ schema = 1, session = {}, groups = { { gid = "g1" } }, agents = {}, queue = {}, next_req = 1 },
		{
			schema = 1,
			session = {},
			groups = {},
			agents = { a = { gid = "g1", state = "flying" } },
			queue = {},
			next_req = 1,
		},
	}
	for i, raw in bad do
		local deck, readonly, banner, backup = Store.migrate(raw, NOW)
		check(next(deck.agents) == nil and #deck.groups == 0, "malformed value " .. i .. " gives empty")
		check(not readonly and banner == nil, "malformed value " .. i .. " is writable with no banner")
		check(backup ~= nil and backup.key == "jumpr.bad." .. NOW, "malformed value " .. i .. " is backed up")
		check(backup ~= nil and backup.value == raw, "the backup keeps the malformed value " .. i)
	end
end

-- gc drops exited and failed pending records by ended_ms (not created_ms), and orphaned queue entries.
do
	local deck = sample()
	deck.agents.old_exit = record("exited", { created_ms = NOW - 10 * DAY, ended_ms = NOW - 8 * DAY, exit = 0 })
	deck.agents.recent_exit = record("exited", { created_ms = NOW - 10 * DAY, ended_ms = NOW - 1 * DAY, exit = 0 })
	deck.agents.old_failed = record("pending", { failed = true, ended_ms = NOW - 8 * DAY })
	deck.agents.old_pending = record("pending", { created_ms = NOW - 9 * DAY })
	deck.agents.live_old = record("live", { created_ms = NOW - 30 * DAY })
	deck.queue.a = { text = "hi", at_ms = NOW }
	deck.queue.gone = { text = "orphan", at_ms = NOW }
	deck.groups[2] = { gid = "empty", name = "empty", cwd = "/home/a/empty", folded = true }
	local out = Store.gc(deck, NOW)
	check(out.agents.old_exit == nil, "exited 8 days ago is dropped")
	check(out.agents.recent_exit ~= nil, "created 10 days ago, exited 1 day ago is kept")
	check(out.agents.old_failed == nil, "a failed pending record ended 8 days ago is dropped")
	check(out.agents.old_pending ~= nil, "a pending record that has not failed is kept")
	check(out.agents.live_old ~= nil and out.agents.a ~= nil, "live records are kept")
	check(out.queue.a ~= nil and out.queue.gone == nil, "an orphaned queue entry is dropped, a held one kept")
	check(#out.groups == 2, "gc never drops a group, even an empty one")
	check(deck.agents.old_exit ~= nil and deck.queue.gone ~= nil, "gc leaves its input untouched")
	check(Store.gc(out, NOW) == out, "gc with nothing to drop returns the same deck")
end

-- I/O: load and save go through the injected compat.
do
	local kv: { [string]: any } = {}
	local fail: string? = nil
	local compat: Store.Compat = {
		kv_get = function(key: string): (any, string?)
			if fail ~= nil then
				return nil, fail
			end
			return kv[key], nil
		end,
		kv_set = function(key: string, value: any): (any, string?)
			if fail ~= nil then
				return false, fail
			end
			kv[key] = value
			return true, nil
		end,
	}
	local deck, readonly = Store.load(compat, NOW)
	check(not readonly and next(deck.agents) == nil, "load with no key gives a writable empty deck")
	local ok = Store.save(compat, sample(), false)
	check(ok and kv["jumpr.v1"].groups[1].name == "webapp", "save writes jumpr.v1")
	local loaded = Store.load(compat, NOW)
	check(loaded.agents.a.pane == 7, "load reads jumpr.v1 back")

	kv["jumpr.v1"] = { schema = 1 }
	local repaired, ro, banner = Store.load(compat, NOW)
	check(not ro and next(repaired.agents) == nil, "a malformed jumpr.v1 loads empty")
	check(kv["jumpr.bad." .. NOW] ~= nil and kv["jumpr.bad." .. NOW].schema == 1, "load writes the backup key")
	check(banner ~= nil and string.find(banner, "jumpr.bad.", 1, true) ~= nil, "load names the backup")

	kv["jumpr.v1"] = sample()
	local before = kv["jumpr.v1"]
	check(Store.save(compat, Store.empty(), true), "save while read-only reports ok")
	check(kv["jumpr.v1"] == before, "save while read-only writes nothing")

	fail = "kv down"
	local _, ro2, banner2 = Store.load(compat, NOW)
	check(ro2 and banner2 ~= nil, "a failed read is read-only with a banner")
	local ok2, err2 = Store.save(compat, sample(), false)
	check(not ok2 and err2 == "kv down", "a failed save returns the error")
end

print("Store: " .. checks .. " checks passed")
