--!strict
-- The host half's kv data, `jumpr.v1`. A `Deck` is Jumpr's stored list for one machine: its groups, agent
-- records, held messages, settings and which agent of a kind closed last in a folder.
-- Pure functions (empty, migrate, gc, clone, closed_key) plus two thin I/O functions that take `compat` as an
-- argument, so the pure part runs under plain `luau` without the `tern` global.

local Agent = require("../shared/agent")

local M = {}

export type Group = { gid: string, name: string, cwd: string, folded: boolean, deleting: boolean? }

-- state: "pending" | "live" | "stopping" | "exited".
export type Record = {
	gid: string,
	label: string?,
	pos: number,
	cwd: string,
	created_ms: number,
	pane: number?,
	state: string,
	cancel: boolean?,
	failed: boolean?,
	exit: number?,
	ended_ms: number?,
	stop_ms: number?,
	last_send_ms: number?,
	-- Which agent this record runs: "omp", "claude", "codex" or an ACP agent id.
	cli: string,
	-- The conversation id this record resumes; never set for omp. A claude record gets its own v4 uuid at creation
	-- (`claude --session-id`); a codex record gets its thread's UUID v7 once the rollout lookup proves it; an ACP
	-- kind gets the id its session lookup last proved. Records from the ACP era keep what they stored.
	session: string?,
	-- Whether this agent has bound to a pane at least once.
	ran: boolean?,
	-- The last usable title its pane showed (`model.remember_titles`), which its row shows while no pane shows one.
	-- Kept here only: never sent to the window or used to name a tab.
	title: string?,
}

export type QueueEntry = { text: string, at_ms: number, err: string? }

export type Settings = { agent: string, keys: { [string]: string } }

export type Deck = {
	schema: number,
	session: { name: string?, host: string?, set_ms: number? },
	groups: { Group },
	agents: { [string]: Record },
	queue: { [string]: QueueEntry },
	next_req: number,
	settings: Settings,
	closed: { [string]: string },
}

-- The two compat calls the I/O half uses; a non-nil second return is a failure.
export type Compat = {
	kv_get: (key: string) -> (any, string?),
	kv_set: (key: string, value: any) -> (any, string?),
}

M.KEY = "jumpr.v1"
M.SCHEMA = 2
M.NEWER_BANNER = "jumpr data is from a newer version; update this machine"

-- The closed-stamp key for one agent kind in one folder.
function M.closed_key(cli: string, cwd: string): string
	return cli .. "\n" .. cwd
end

local GC_MS = 7 * 24 * 60 * 60 * 1000
local STATES = { pending = true, live = true, stopping = true, exited = true }

function M.empty(): Deck
	return {
		schema = M.SCHEMA,
		session = {},
		groups = {},
		agents = {},
		queue = {},
		next_req = 1,
		settings = { agent = Agent.OMP, keys = {} },
		closed = {},
	}
end

-- A copy of the deck one level deep, including the nested settings keys. Pure functions change the copy and
-- leave the caller's deck untouched.
function M.clone(deck: Deck): Deck
	local groups: { Group } = table.create(#deck.groups)
	for i, group in deck.groups do
		groups[i] = table.clone(group)
	end
	local agents: { [string]: Record } = {}
	for id, record in deck.agents do
		agents[id] = table.clone(record)
	end
	local queue: { [string]: QueueEntry } = {}
	for id, entry in deck.queue do
		queue[id] = table.clone(entry)
	end
	return {
		schema = deck.schema,
		session = table.clone(deck.session),
		groups = groups,
		agents = agents,
		queue = queue,
		next_req = deck.next_req,
		settings = { agent = deck.settings.agent, keys = table.clone(deck.settings.keys) },
		closed = table.clone(deck.closed),
	}
end

local function opt(value: any, kind: string): boolean
	return value == nil or type(value) == kind
end

local function valid_group(g: any): boolean
	return type(g) == "table"
		and type(g.gid) == "string"
		and type(g.name) == "string"
		and type(g.cwd) == "string"
		and type(g.folded) == "boolean"
		and opt(g.deleting, "boolean")
end

local function valid_record(r: any): boolean
	return type(r) == "table"
		and type(r.gid) == "string"
		and opt(r.label, "string")
		and type(r.pos) == "number"
		and type(r.cwd) == "string"
		and type(r.created_ms) == "number"
		and opt(r.pane, "number")
		and type(r.state) == "string"
		and STATES[r.state] == true
		and opt(r.cancel, "boolean")
		and opt(r.failed, "boolean")
		and opt(r.exit, "number")
		and opt(r.ended_ms, "number")
		and opt(r.stop_ms, "number")
		and opt(r.last_send_ms, "number")
		and type(r.cli) == "string"
		and Agent.valid_kind(r.cli)
		and opt(r.session, "string")
		and opt(r.ran, "boolean")
		and opt(r.title, "string")
end

local function valid_record_v1(r: any): boolean
	return type(r) == "table"
		and type(r.gid) == "string"
		and opt(r.label, "string")
		and type(r.pos) == "number"
		and type(r.dir) == "string"
		and type(r.cwd) == "string"
		and type(r.created_ms) == "number"
		and opt(r.pane, "number")
		and type(r.state) == "string"
		and STATES[r.state] == true
		and opt(r.cancel, "boolean")
		and opt(r.failed, "boolean")
		and opt(r.exit, "number")
		and opt(r.ended_ms, "number")
		and opt(r.stop_ms, "number")
		and opt(r.last_send_ms, "number")
end

local function valid_entry(e: any): boolean
	return type(e) == "table" and type(e.text) == "string" and type(e.at_ms) == "number" and opt(e.err, "string")
end

local function valid_settings(settings: any): boolean
	if
		type(settings) ~= "table"
		or type(settings.agent) ~= "string"
		or not Agent.valid_kind(settings.agent)
		or type(settings.keys) ~= "table"
	then
		return false
	end
	for action, key in settings.keys do
		if type(action) ~= "string" or type(key) ~= "string" then
			return false
		end
	end
	return true
end

local function valid_closed(closed: any): boolean
	if type(closed) ~= "table" then
		return false
	end
	for key, id in closed do
		if type(key) ~= "string" or type(id) ~= "string" then
			return false
		end
	end
	return true
end

-- Whether `raw` has the common deck shape. `legacy` selects the record shape used before agent kinds were stored.
local function valid_common_shape(raw: any, legacy: boolean): boolean
	if type(raw) ~= "table" or type(raw.schema) ~= "number" or type(raw.next_req) ~= "number" then
		return false
	end
	local session = raw.session
	if
		type(session) ~= "table"
		or not opt(session.name, "string")
		or not opt(session.host, "string")
		or not opt(session.set_ms, "number")
	then
		return false
	end
	if type(raw.groups) ~= "table" or type(raw.agents) ~= "table" or type(raw.queue) ~= "table" then
		return false
	end
	for i, g in raw.groups do
		if type(i) ~= "number" or not valid_group(g) then
			return false
		end
	end
	for id, r in raw.agents do
		local record_ok = if legacy then valid_record_v1(r) else valid_record(r)
		if type(id) ~= "string" or not record_ok then
			return false
		end
	end
	for id, e in raw.queue do
		if type(id) ~= "string" or not valid_entry(e) then
			return false
		end
	end
	return true
end

local function valid_shape_v1(raw: any): boolean
	return valid_common_shape(raw, true)
end

local function valid_shape(raw: any): boolean
	return valid_common_shape(raw, false) and valid_settings(raw.settings) and valid_closed(raw.closed)
end

local function record_from(raw_record: any, upgrade: boolean, now_ms: number): Record
	local stop_ms = raw_record.stop_ms
	local ran = raw_record.ran
	if upgrade then
		if raw_record.state == "stopping" and stop_ms == nil then
			stop_ms = now_ms
		end
		if raw_record.state == "live" or raw_record.state == "stopping" or raw_record.state == "exited" then
			ran = true
		end
	end
	return {
		gid = raw_record.gid,
		label = raw_record.label,
		pos = raw_record.pos,
		cwd = raw_record.cwd,
		created_ms = raw_record.created_ms,
		pane = raw_record.pane,
		state = raw_record.state,
		cancel = raw_record.cancel,
		failed = raw_record.failed,
		exit = raw_record.exit,
		ended_ms = raw_record.ended_ms,
		stop_ms = stop_ms,
		last_send_ms = raw_record.last_send_ms,
		cli = if upgrade then Agent.OMP else raw_record.cli,
		session = if upgrade then nil else raw_record.session,
		ran = ran,
		title = if upgrade then nil else raw_record.title,
	}
end

local function upgrade_v1(raw: any, now_ms: number): Deck
	local groups: { Group } = table.create(#raw.groups)
	for i, group in raw.groups do
		groups[i] = {
			gid = group.gid,
			name = group.name,
			cwd = group.cwd,
			folded = group.folded,
			deleting = group.deleting,
		}
	end
	local agents: { [string]: Record } = {}
	for id, old_record in raw.agents do
		agents[id] = record_from(old_record, true, now_ms)
	end
	local queue: { [string]: QueueEntry } = {}
	for id, entry in raw.queue do
		queue[id] = { text = entry.text, at_ms = entry.at_ms, err = entry.err }
	end
	return {
		schema = M.SCHEMA,
		session = {
			name = raw.session.name,
			host = raw.session.host,
			set_ms = raw.session.set_ms,
		},
		groups = groups,
		agents = agents,
		queue = queue,
		next_req = raw.next_req,
		settings = { agent = Agent.OMP, keys = {} },
		closed = {},
	}
end

-- A newer value is never returned as the stored table. The display keeps the stored schema number and only the
-- fields this schema reads, so later edits cannot change the raw value or its unknown fields.
local function display_copy(raw: any): Deck
	local groups: { Group } = table.create(#raw.groups)
	for i, group in raw.groups do
		groups[i] = {
			gid = group.gid,
			name = group.name,
			cwd = group.cwd,
			folded = group.folded,
			deleting = group.deleting,
		}
	end
	local agents: { [string]: Record } = {}
	for id, record in raw.agents do
		agents[id] = record_from(record, false, 0)
	end
	local queue: { [string]: QueueEntry } = {}
	for id, entry in raw.queue do
		queue[id] = { text = entry.text, at_ms = entry.at_ms, err = entry.err }
	end
	local keys: { [string]: string } = {}
	for action, key in raw.settings.keys do
		keys[action] = key
	end
	local closed: { [string]: string } = {}
	for key, id in raw.closed do
		closed[key] = id
	end
	return {
		schema = raw.schema,
		session = {
			name = raw.session.name,
			host = raw.session.host,
			set_ms = raw.session.set_ms,
		},
		groups = groups,
		agents = agents,
		queue = queue,
		next_req = raw.next_req,
		settings = { agent = raw.settings.agent, keys = keys },
		closed = closed,
	}
end

-- (deck, readonly, banner?, backup?).
-- nil gives empty(); schema 1 is upgraded in a copy; schema 2 is used as it is; a newer schema is read-only
-- with a banner (shown from a detached copy when its shape still reads, else empty); anything else gives
-- empty() plus a backup {key = "jumpr.bad.<now_ms>", value = raw} for the I/O layer to write.
function M.migrate(raw: any, now_ms: number): (Deck, boolean, string?, { key: string, value: any }?)
	if raw == nil then
		return M.empty(), false, nil, nil
	end
	if type(raw) == "table" and type(raw.schema) == "number" and raw.schema > M.SCHEMA then
		local shown = if valid_shape(raw) then display_copy(raw) else M.empty()
		return shown, true, M.NEWER_BANNER, nil
	end
	if type(raw) == "table" and raw.schema == M.SCHEMA and valid_shape(raw) then
		return raw :: Deck, false, nil, nil
	end
	if type(raw) == "table" and raw.schema == 1 and valid_shape_v1(raw) then
		return upgrade_v1(raw, now_ms), false, nil, nil
	end
	return M.empty(), false, nil, { key = "jumpr.bad." .. tostring(math.floor(now_ms)), value = raw }
end

-- Drops exited and failed pending records whose ended_ms is over 7 days old, and queue entries whose record is
-- gone. Groups are never dropped. Returns the same table when nothing is dropped.
function M.gc(deck: Deck, now_ms: number): Deck
	local drop: { string } = {}
	for id, r in deck.agents do
		local ended = r.state == "exited" or (r.state == "pending" and r.failed == true)
		if ended and r.ended_ms ~= nil and now_ms - r.ended_ms > GC_MS then
			table.insert(drop, id)
		end
	end
	local orphan = false
	for id in deck.queue do
		if deck.agents[id] == nil then
			orphan = true
		end
	end
	if #drop == 0 and not orphan then
		return deck
	end
	local out = M.clone(deck)
	for _, id in drop do
		out.agents[id] = nil
	end
	for id in deck.queue do
		if out.agents[id] == nil then
			out.queue[id] = nil
		end
	end
	return out
end

-- (deck, readonly, banner?). A failed read, or a malformed value whose backup cannot be written, gives a
-- read-only empty deck so a later save never overwrites data that could not be kept.
function M.load(compat: Compat, now_ms: number): (Deck, boolean, string?)
	local raw, err = compat.kv_get(M.KEY)
	if err ~= nil then
		return M.empty(), true, "jumpr data unreadable: " .. err
	end
	local deck, readonly, banner, backup = M.migrate(raw, now_ms)
	if backup ~= nil then
		local _, set_err = compat.kv_set(backup.key, backup.value)
		if set_err ~= nil then
			return deck, true, "jumpr data unreadable and not backed up: " .. set_err
		end
		return deck, readonly, "jumpr data was unreadable; kept as " .. backup.key
	end
	return deck, readonly, banner
end

-- (ok, err?). A no-op returning true while read-only.
function M.save(compat: Compat, deck: Deck, readonly: boolean): (boolean, string?)
	if readonly then
		return true, nil
	end
	local _, err = compat.kv_set(M.KEY, deck)
	if err ~= nil then
		return false, err
	end
	return true, nil
end

return M
