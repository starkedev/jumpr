--!strict
-- The host half's kv data, `jumpr.v1`. A `Deck` is Jumpr's stored list for one machine: its groups, its agent
-- records (keyed by deck id, the `<id>` in the agent's `~/.omp/deck/<id>` session folder) and the held messages.
-- Pure functions (empty, migrate, gc, clone) plus two thin I/O functions that take `compat` as an argument,
-- so the pure part runs under plain `luau` without the `tern` global.

local M = {}

export type Group = { gid: string, name: string, cwd: string, folded: boolean, deleting: boolean? }

-- state: "pending" | "live" | "stopping" | "exited".
export type Record = {
	gid: string,
	label: string?,
	pos: number,
	dir: string,
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
}

export type QueueEntry = { text: string, at_ms: number, err: string? }

export type Deck = {
	schema: number,
	session: { name: string?, host: string?, set_ms: number? },
	groups: { Group },
	agents: { [string]: Record },
	queue: { [string]: QueueEntry },
	next_req: number,
}

-- The two compat calls the I/O half uses; a non-nil second return is a failure.
export type Compat = {
	kv_get: (key: string) -> (any, string?),
	kv_set: (key: string, value: any) -> (any, string?),
}

M.KEY = "jumpr.v1"
M.SCHEMA = 1
M.NEWER_BANNER = "jumpr data is from a newer version; update this machine"

local GC_MS = 7 * 24 * 60 * 60 * 1000
local STATES = { pending = true, live = true, stopping = true, exited = true }

function M.empty(): Deck
	return { schema = M.SCHEMA, session = {}, groups = {}, agents = {}, queue = {}, next_req = 1 }
end

-- A copy of the deck one level deep: new deck, session, groups array, group tables, agents map, records,
-- queue map and queue entries. Pure functions change the copy and leave the caller's deck untouched.
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

-- Whether `raw` has the schema-1 shape (any schema number); every element is checked so the model never
-- meets a field of the wrong type.
local function valid_shape(raw: any): boolean
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
		if type(id) ~= "string" or not valid_record(r) then
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

-- (deck, readonly, banner?, backup?).
-- nil gives empty(); schema 1 is used as it is; a newer schema is read-only with a banner (shown as stored when
-- its shape still reads as schema 1, else empty); anything else (no schema, an older one or a bad shape) gives
-- empty() plus a backup {key = "jumpr.bad.<now_ms>", value = raw} for the I/O layer to write.
function M.migrate(raw: any, now_ms: number): (Deck, boolean, string?, { key: string, value: any }?)
	if raw == nil then
		return M.empty(), false, nil, nil
	end
	if type(raw) == "table" and type(raw.schema) == "number" and raw.schema > M.SCHEMA then
		local shown = if valid_shape(raw) then raw :: Deck else M.empty()
		return shown, true, M.NEWER_BANNER, nil
	end
	if type(raw) == "table" and raw.schema == M.SCHEMA and valid_shape(raw) then
		return raw :: Deck, false, nil, nil
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
