--!strict
-- Store schema, migration, copying, collection and injected I/O behavior. Pure test harness: no `tern`.

local Store = require("../lib/host/store")
local Model = require("../lib/host/model")
local Agent = require("../lib/shared/agent")
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
		cwd = "/home/a/src/webapp",
		created_ms = NOW - DAY,
		state = state,
		cli = "omp",
	}
	for k, v in (fields or {}) :: { [string]: any } do
		(r :: any)[k] = v
	end
	return r
end

local function legacy_record(state: string, fields: { [string]: any }?): { [string]: any }
	local r: { [string]: any } = {
		gid = "g1",
		pos = 1,
		dir = "~/.omp/deck/aaaa",
		cwd = "/home/a/src/webapp",
		created_ms = NOW - DAY,
		state = state,
	}
	for k, v in (fields or {}) :: { [string]: any } do
		r[k] = v
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

-- A copy of `value` as kv keeps it: tables are copied all the way down, so what the store reads back shares nothing
-- with what it saved.
local function json_copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out: { [any]: any } = {}
	for k, v in value do
		out[k] = json_copy(v)
	end
	return out
end

-- nil gives the empty deck, writable, with no banner and no backup.
do
	local deck, readonly, banner, backup = Store.migrate(nil, NOW)
	check(deck.schema == 2 and #deck.groups == 0 and next(deck.agents) == nil, "nil gives schema 2 empty")
	check(next(deck.queue) == nil and deck.next_req == 1, "empty has no queue and next_req 1")
	check(deck.settings.agent == "omp" and next(deck.settings.keys) == nil, "empty has default settings")
	check(next(deck.closed) == nil, "empty has no closed stamps")
	check(not readonly and banner == nil and backup == nil, "nil is writable with no banner or backup")
end

-- Schema 1 upgrades all records in copies and adds schema 2 defaults.
do
	local raw: any = {
		schema = 1,
		session = { name = "main", host = "devbox", set_ms = NOW },
		groups = { { gid = "g1", name = "webapp", cwd = "/home/a/src/webapp", folded = false } },
		agents = {
			live = legacy_record("live", { pane = 7 }),
			exited = legacy_record("exited", { exit = 0, ended_ms = NOW }),
			pending = legacy_record("pending"),
		},
		queue = { pending = { text = "later", at_ms = NOW } },
		next_req = 4,
	}
	local deck, readonly, banner, backup = Store.migrate(raw, NOW)
	check(deck.schema == 2, "schema 1 upgrades to schema 2")
	check(not readonly and banner == nil and backup == nil, "schema 1 upgrades writable without a backup")
	check(
		deck.agents.live.cli == "omp" and deck.agents.exited.cli == "omp" and deck.agents.pending.cli == "omp",
		"schema 1 records become omp records"
	)
	check(
		(deck.agents.live :: any).dir == nil
			and (deck.agents.exited :: any).dir == nil
			and (deck.agents.pending :: any).dir == nil,
		"schema 1 record directories are removed"
	)
	check(deck.agents.live.ran == true and deck.agents.exited.ran == true, "records that ran are marked")
	check(deck.agents.pending.ran ~= true, "a pending record is not marked as having run")
	check(
		deck.agents.live.title == nil and deck.agents.exited.title == nil and deck.agents.pending.title == nil,
		"schema 1 records upgrade with no remembered title"
	)
	check(deck.settings.agent == "omp" and next(deck.settings.keys) == nil, "schema 1 gets default settings")
	check(next(deck.closed) == nil, "schema 1 gets no closed stamps")
	check(
		raw.schema == 1
			and raw.agents.live.dir == "~/.omp/deck/aaaa"
			and raw.agents.live.cli == nil
			and raw.agents.live.ran == nil,
		"migration leaves its input records untouched"
	)
	deck.session.name = "changed"
	deck.groups[1].name = "changed"
	deck.agents.live.pos = 9
	deck.queue.pending.text = "changed"
	check(
		raw.session.name == "main"
			and raw.groups[1].name == "webapp"
			and raw.agents.live.pos == 1
			and raw.queue.pending.text == "later",
		"migration copies every mutable part of schema 1"
	)
end

-- A schema 1 stopping record may have no stop time; the upgrade stamps migration time and reloads.
do
	local raw: any = {
		schema = 1,
		session = {},
		groups = {},
		agents = {
			missing = legacy_record("stopping"),
			kept = legacy_record("stopping", { stop_ms = NOW - 1000 }),
			live = legacy_record("live"),
		},
		queue = {},
		next_req = 1,
	}
	local deck, readonly, banner, backup = Store.migrate(raw, NOW)
	check(
		deck.agents.missing.state == "stopping" and deck.agents.missing.stop_ms == NOW,
		"a missing stop time is stamped"
	)
	check(deck.agents.missing.ran == true, "a stopping record is marked as having run")
	check(deck.agents.kept.stop_ms == NOW - 1000, "an existing stop time is kept")
	check(deck.agents.live.stop_ms == nil, "a live record does not gain a stop time")
	check(not readonly and banner == nil and backup == nil, "the stamped upgrade stays writable")
	check(raw.agents.missing.stop_ms == nil, "stamping leaves the schema 1 record untouched")
	local again, again_ro, again_banner, again_backup = Store.migrate(deck, NOW + 1)
	check(
		again == deck and not again_ro and again_banner == nil and again_backup == nil,
		"the upgraded stopping record loads again"
	)
end

-- Schema 2 with an ACP session passes through by identity.
do
	local raw = sample()
	raw.agents.a.cli = "claude"
	raw.agents.a.session = "session-1"
	local deck, readonly, banner, backup = Store.migrate(raw, NOW)
	check(deck == raw, "schema 2 is used as it is")
	check(deck.agents.a.session == "session-1", "schema 2 keeps an ACP session")
	check(not readonly and banner == nil and backup == nil, "schema 2 is writable")
end

-- A record's remembered pane title is an optional schema 2 field: a deck holding one loads as it is, beside a record
-- without one, and keeps it through clone and a kv round trip; a title that is not a string makes the deck
-- malformed, as any mistyped field does. A record field this version does not know is ignored, never rejected, so an
-- older version reading a newer field keeps working.
do
	local raw = sample()
	raw.agents.a.title = "Fix the parser"
	raw.agents.b = record("exited", { exit = 0, ended_ms = NOW })
	local deck, readonly, banner, backup = Store.migrate(raw, NOW)
	check(deck == raw and deck.schema == 2, "a deck holding a remembered title loads as it is, still schema 2")
	check(not readonly and banner == nil and backup == nil, "and stays writable")
	check(deck.agents.a.title == "Fix the parser" and deck.agents.b.title == nil, "beside a record without one")
	check(Store.clone(deck).agents.a.title == "Fix the parser", "clone keeps the title")

	local kv: { [string]: any } = {}
	local compat: Store.Compat = {
		kv_get = function(key: string): (any, string?)
			return json_copy(kv[key]), nil
		end,
		kv_set = function(key: string, value: any): (any, string?)
			kv[key] = json_copy(value)
			return true, nil
		end,
	}
	check(Store.save(compat, deck, false), "the deck saves")
	local loaded, loaded_ro, loaded_banner = Store.load(compat, NOW)
	check(not loaded_ro and loaded_banner == nil, "and loads back writable")
	check(loaded ~= deck and loaded.agents.a.title == "Fix the parser", "the kv round trip keeps the title")
	check(loaded.agents.b.title == nil, "and the record without one")

	local mistyped: any = sample()
	mistyped.agents.a.title = 7
	local empty, _, _, kept = Store.migrate(mistyped, NOW)
	check(next(empty.agents) == nil and kept ~= nil, "a title that is not a string makes the deck malformed")

	local future: any = sample()
	future.agents.a.future = "a later field"
	check(Store.migrate(future, NOW) == future, "a record field this version does not know is ignored")
end

-- Schema 3 is read-only with the banner, shown from a detached copy, and never backed up.
do
	local raw: any = sample()
	raw.schema = 3
	raw.settings.keys.new = "x"
	raw.closed["claude\n/work"] = "a"
	raw.extra = "future"
	raw.agents.a.extra = "future-record"
	raw.agents.a.title = "Fix the parser"
	raw.queue.a = { text = "held", at_ms = NOW, extra = "future-entry" }
	local deck, readonly, banner, backup = Store.migrate(raw, NOW)
	check(readonly, "a newer schema is read-only")
	check(banner == "jumpr data is from a newer version; update this machine", "a newer schema shows the banner")
	check(backup == nil, "a newer schema is not backed up")
	check(
		deck ~= raw and deck.schema == 3 and deck.groups[1].name == "webapp",
		"a readable newer schema is shown as stored"
	)
	check(deck.groups[1] ~= raw.groups[1] and deck.agents.a ~= raw.agents.a, "the display copies groups and records")
	check(deck.settings ~= raw.settings and deck.settings.keys ~= raw.settings.keys, "the display copies settings")
	check(
		deck.closed ~= raw.closed and deck.queue.a ~= raw.queue.a,
		"the display copies closed stamps and held messages"
	)
	check(
		(deck :: any).extra == nil and (deck.agents.a :: any).extra == nil,
		"unknown future fields stay out of the display"
	)
	check(deck.agents.a.title == "Fix the parser", "the display shows a remembered title")
	deck.groups[1].name = "changed"
	deck.agents.a.label = "changed"
	deck.settings.keys.new = "z"
	deck.closed["claude\n/work"] = "b"
	deck.queue.a.text = "changed"
	check(
		raw.groups[1].name == "webapp" and raw.agents.a.label == nil,
		"editing the display leaves stored groups and records"
	)
	check(
		raw.settings.keys.new == "x" and raw.closed["claude\n/work"] == "a",
		"editing the display leaves stored settings"
	)
	check(
		raw.queue.a.text == "held" and raw.extra == "future" and raw.schema == 3,
		"the stored future value stays untouched"
	)
end

-- A malformed newer value is still protected as read-only and is never backed up.
do
	local raw: any = sample()
	raw.schema = 3
	raw.settings = nil
	local deck, readonly, banner, backup = Store.migrate(raw, NOW)
	check(readonly and banner == Store.NEWER_BANNER, "a malformed newer schema stays read-only with the banner")
	check(next(deck.agents) == nil, "a malformed newer schema is shown as empty")
	check(backup == nil, "a malformed newer schema is not backed up")
end

-- A malformed value gives empty plus a backup under jumpr.bad.<ms>.
do
	local bad: { any } = {
		"not a table",
		{ groups = {} },
		{ schema = 0, session = {}, groups = {}, agents = {}, queue = {}, next_req = 1 },
		{
			schema = 2,
			session = {},
			groups = { { gid = "g1" } },
			agents = {},
			queue = {},
			next_req = 1,
			settings = { agent = "omp", keys = {} },
			closed = {},
		},
		{
			schema = 2,
			session = {},
			groups = {},
			agents = { a = { gid = "g1", state = "flying" } },
			queue = {},
			next_req = 1,
			settings = { agent = "omp", keys = {} },
			closed = {},
		},
		{
			schema = 2,
			session = {},
			groups = {},
			agents = {},
			queue = {},
			next_req = 1,
			settings = { agent = "a b", keys = {} },
			closed = {},
		},
		{
			schema = 2,
			session = {},
			groups = {},
			agents = {},
			queue = {},
			next_req = 1,
			settings = { agent = "omp", keys = { new = 7 } },
			closed = {},
		},
		{
			schema = 2,
			session = {},
			groups = {},
			agents = {},
			queue = {},
			next_req = 1,
			settings = { agent = "omp", keys = {} },
			closed = { key = 7 },
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

-- Invalid record agent kinds make a schema 2 deck malformed.
do
	for _, cli in { "a b", "-x" } do
		local raw = sample()
		raw.agents.a.cli = cli
		local deck, readonly, banner, backup = Store.migrate(raw, NOW)
		check(next(deck.agents) == nil, "invalid record agent kind " .. cli .. " gives empty")
		check(not readonly and banner == nil and backup ~= nil, "invalid record agent kind " .. cli .. " is backed up")
	end
end

-- clone copies settings keys and closed stamps.
do
	local deck = sample()
	deck.settings = { agent = "claude", keys = { new = "x" } }
	deck.closed["claude\n/work"] = "a"
	local cloned = Store.clone(deck)
	cloned.settings.agent = "codex"
	cloned.settings.keys.new = "z"
	cloned.closed["claude\n/work"] = "b"
	check(deck.settings.agent == "claude", "clone leaves the input setting agent untouched")
	check(deck.settings.keys.new == "x", "clone gives settings its own keys table")
	check(deck.closed["claude\n/work"] == "a", "clone gives closed its own table")
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
	local saved = sample()
	saved.settings = { agent = "claude", keys = { new = "x" } }
	local ok = Store.save(compat, saved, false)
	check(ok and kv["jumpr.v1"].groups[1].name == "webapp", "save writes the historical jumpr.v1 key")
	local loaded = Store.load(compat, NOW)
	check(loaded.agents.a.pane == 7, "load reads jumpr.v1 back")
	check(loaded.settings.agent == "claude" and loaded.settings.keys.new == "x", "the kv round trip keeps settings")

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

-- closed_key joins a kind and a folder with a newline, so neither side can read as the other.
do
	local key = Store.closed_key("claude", "/work")
	check(key == "claude\n/work", "a closed key is the kind, a newline, then the folder")
	check(Store.closed_key("claude", "/work") == key, "the same pair is the same key")
	check(Store.closed_key("claude", "/other") ~= key, "another folder is another key")
	check(Store.closed_key("codex", "/work") ~= key, "another kind is another key")
	check(Store.closed_key("claude", "") == "claude\n", "an empty folder still keeps the boundary")
	check(Store.closed_key("", "/work") == "\n/work", "an empty kind still keeps the boundary")
end

-- ACP-era records cut over without a migration: an exited claude record with a session, one without, and a codex
-- record that ran without one load through schema 2 (and a newer schema's display copy) field for field, and restart
-- as the CLI agents. Claude resumes its stored id with the checked line (the CLI opens ACP-created conversations),
-- claude without one opens the CLI's own picker, and codex that ran opens `codex resume`'s picker.
do
	local SID = "0b6c4f2e-8a1d-4c3e-9f7a-2d5e6b7c8a9f"
	local function acp_deck(): Store.Deck
		local deck = sample()
		deck.agents = {
			c1 = record("exited", { cli = "claude", session = SID, ran = true, exit = 0, ended_ms = NOW }),
			c2 = record("exited", { cli = "claude", ran = true, exit = 0, ended_ms = NOW }),
			x1 = record("exited", { cli = "codex", ran = true, exit = 0, ended_ms = NOW }),
		}
		return deck
	end
	local raw = acp_deck()
	local deck, readonly = Store.migrate(json_copy(raw), NOW)
	check(not readonly, "an ACP-era deck is writable schema 2")
	for id, r in raw.agents do
		local got = deck.agents[id]
		for k, v in r :: any do
			check((got :: any)[k] == v, "an ACP-era " .. id .. " record keeps " .. k)
		end
	end
	local newer = json_copy(raw)
	newer.schema = 3
	local shown = Store.migrate(newer, NOW)
	for id, r in raw.agents do
		for k, v in r :: any do
			check((shown.agents[id] :: any)[k] == v, "a newer display copy keeps ACP-era " .. id .. " " .. k)
		end
	end

	local mode, sid = Model.restart_mode(deck.agents.c1, "c1", deck)
	check(mode == "resume" and sid == SID, "an ACP-era claude record with a session resumes it")
	check(
		Agent.command("claude", "c1", mode :: Agent.Mode, sid)
			== "env JUMPR_ID=c1 sh -c 'if ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/"
				.. SID
				.. ".jsonl >/dev/null 2>&1; then exec claude --resume "
				.. SID
				.. "; else exec claude --session-id "
				.. SID
				.. "; fi'",
		"it restarts on the checked line with its stored id"
	)
	local mode2, sid2 = Model.restart_mode(deck.agents.c2, "c2", deck)
	check(mode2 == "pick" and sid2 == nil, "an ACP-era claude record without a session picks")
	check(
		Agent.command("claude", "c2", mode2 :: Agent.Mode, sid2) == "env JUMPR_ID=c2 claude --resume",
		"it opens the claude picker"
	)
	local mode3, sid3 = Model.restart_mode(deck.agents.x1, "x1", deck)
	check(mode3 == "pick" and sid3 == nil, "an ACP-era codex record that ran picks")
	check(
		Agent.command("codex", "x1", mode3 :: Agent.Mode, sid3) == "env JUMPR_ID=x1 codex resume",
		"it opens codex resume's picker"
	)

	-- A stored claude session that is not a lowercase uuid still loads, but restarts as if it had none (the picker):
	-- it has no launch line, so resuming it would fail every restart.
	local odd = acp_deck()
	odd.agents.c1.session = string.upper(SID)
	local odd_deck = Store.migrate(odd, NOW)
	check(odd_deck.agents.c1.session == string.upper(SID), "a non-uuid ACP-era session loads unchanged")
	local mode4, sid4 = Model.restart_mode(odd_deck.agents.c1, "c1", odd_deck)
	check(mode4 == "pick" and sid4 == nil, "a non-uuid session restarts as if it had none")
	check(
		Agent.command("claude", "c1", mode4 :: Agent.Mode, sid4) == "env JUMPR_ID=c1 claude --resume",
		"it opens the claude picker"
	)
	check(Agent.command("claude", "c1", "resume", "session-1") == nil, "an id that is not a uuid has no launch line")
end

print("Store: " .. checks .. " checks passed")
