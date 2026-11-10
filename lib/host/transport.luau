--!strict
-- The block side of the routes between the halves: status, replies, the diagnostics action and focus messages
-- arrive as view `action` events (`act = "st" | "res" | "diag" | "fo"`, the JSON in `value`). Requests leave as
-- `jumpr://` URLs built by `requests`, whose ledger the host keeps and passes in for replies. Every message carries
-- the protocol version, and a mismatch is kept as a banner, never handled silently.
-- Agents are named by deck id only, never by a pane id from the other half. The host passes the deck in and saves
-- any deck that comes back changed; file writes and JSON go through the `io` it passes (Tern is reached only
-- through compat).
--
-- Two kinds of state: `State` is the machine's (the error ring and the merged view over every copy's status:
-- arrival marks, row ages), `Status` is one copy's (the window numbers `seq` per block pane, so a recreated copy
-- starts its status afresh: the window's first message to it is a full snapshot, a full message at or below the last
-- `seq` is read as a restart of the numbering, and a first diff, after a host-side restart under the same pane, is a
-- gap, which asks for one with `jumpr://hello`). The rows, health, age and version banner every copy shows come from
-- the machine's merged view.

local model = require("./model")
local protocol = require("../shared/protocol")
local queue = require("./queue")
local requests = require("./requests")
local status = require("../shared/status")
local store = require("./store")

local M = {}

-- No status for this long: "status stale".
M.STALE_MS = 3000
-- A window silent this long is forgotten.
local WINDOW_FORGET_MS = 60 * 1000
local ERRORS_KEPT = 50

-- The latest message's header fields.
export type Latest = {
	h: string?,
	sn: string?,
	hn: string?,
	dupb: boolean,
	em: string,
	t: number?,
}

-- A protocol-version verdict from one window uid, and when it last arrived (tern.now() ms).
export type Verdict = { v: string, at_ms: number }

-- One copy of the list's status route. Every copy checks its own messages (the window numbers `seq` per block);
-- what the rows show is the machine's merged view over every registered copy.
export type Status = {
	windows: { [string]: status.Window },
	last_seq: { [string]: number },
	-- When the last status message arrived (tern.now() ms); nil until the first one.
	last_ms: number?,
	latest: Latest,
	-- "bad_p_newer" | "bad_p_older" per window uid (`?` for a reply or diag that names none) while that window
	-- speaks another protocol version; an accepted message from the window clears it, and it ages out.
	versions: { [string]: Verdict },
}

-- The machine's error ring, and the copies' statuses it merges.
export type State = {
	errors: { string },
	statuses: { [Status]: boolean },
	-- Accepted status messages so far, across every copy: orders `status.Window.carried`.
	arrived: number,
	-- When each deck id's merged entries last changed (tern.now() ms), for the `i` overlay's per-row age.
	changed: { [string]: number },
	-- Deck ids a working status was seen for since their last send. Once per machine, in memory only: false
	-- after a plugin reload, so the 30 s rule of `queue.due` applies then.
	seen_working: { [string]: boolean },
	-- When the first status message arrived since the host half started (tern.now() ms): the stored host name is
	-- kept until windows have had a minute to be heard.
	since: number?,
}

-- The machine calls an action needs: the diagnostics file write and JSON both ways.
export type Io = {
	fs_write: (path: string, text: string) -> (boolean, string?),
	json_encode: (value: any, pretty: boolean?) -> string,
	json_decode: (text: string) -> (any, string?),
}

-- What `on_action` reads. `now` is tern.now() (intervals); `wall` is wall-clock ms (stored times). `sets` are the
-- live panes per deck id (the held messages' `queue.due` reads them).
export type Ctx = {
	deck: store.Deck,
	readonly: boolean,
	b: string,
	now: number,
	wall: number,
	io: Io,
	data_dir: string,
	-- the binding cache for the host dump, built only when a dump is written
	binding: () -> any,
	sets: model.PaneSets,
	-- the deck id whose `q` line is open (`keys.editing`): never swept
	skip: string?,
	-- the machine's request ledger, which a reply settles
	requests: requests.Ledger,
}

export type Req = { verb: string, fields: { [string]: string } }

-- The result of one action: the deck (the same table when unchanged), a notice for the receiving block,
-- requests to send, held messages that are due (the host marks each sent, saves, then types it), whether
-- anything visible changed, and the deck id a focus message asks the list to highlight (the host feeds it to
-- keys.reduce as a `follow` event).
export type Outcome = {
	deck: store.Deck,
	notice: string?,
	requests: { Req },
	due: { queue.Due },
	render: boolean,
	follow: string?,
}

function M.new(): State
	return {
		errors = {},
		statuses = {},
		arrived = 0,
		changed = {},
		seen_working = {},
		since = nil,
	}
end

function M.new_status(): Status
	return {
		windows = {},
		last_seq = {},
		last_ms = nil,
		latest = { dupb = false, em = "A" },
		versions = {},
	}
end

-- A copy's status joins the machine's merged view (on its `init`) and leaves it (when the copy is dropped).
function M.register(state: State, st: Status)
	state.statuses[st] = true
end

function M.unregister(state: State, st: Status)
	state.statuses[st] = nil
end

-- Keeps one line in the error ring (the last 50 go into the diagnostics dump).
function M.note_error(state: State, text: string)
	table.insert(state.errors, text)
	while #state.errors > ERRORS_KEPT do
		table.remove(state.errors, 1)
	end
end

-- A message was typed to `id`, by `o` or from the queue: the next held message waits for a working status after it,
-- or for `queue.GUARD_MS`.
function M.sent(state: State, id: string)
	state.seen_working[id] = nil
end

-- The held messages that are due now, from the machine's merged status. The host timer calls it every second so
-- `q` on an idle agent and the 30 s rule after a reload fire within a second; `on_action` does the same for each
-- status message. `sets` are the live panes per deck id; `now` is tern.now() and `wall` wall-clock ms; `skip` is the
-- agent whose `q` line is open (`keys.editing`), which is not swept.
function M.due(
	state: State,
	deck: store.Deck,
	sets: model.PaneSets,
	now: number,
	wall: number,
	skip: string?
): { queue.Due }
	return queue.sweep(deck, sets, M.status_by_id(state, now), M.fresh(state, now), state.seen_working, wall, skip)
end

-- Forgets the windows of one copy's status that have been silent for a minute, with their last `seq`: a forgotten
-- window's next message counts as its first, so a diff from it (built on entries already dropped here) asks for a
-- full snapshot with `jumpr://hello` instead of being merged onto nothing. Old version verdicts go too.
function M.forget(st: Status, now: number)
	for w, win in st.windows do
		if now - win.at_ms >= WINDOW_FORGET_MS then
			st.windows[w] = nil
			st.last_seq[w] = nil
		end
	end
	for w, verdict in st.versions do
		if now - verdict.at_ms >= WINDOW_FORGET_MS then
			st.versions[w] = nil
		end
	end
end

-- The names the windows heard within the last minute give this host, over every copy: each window machine names a
-- host as its own host list does, so two machines can give it two names.
function M.live_hosts(state: State, now: number): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for st in state.statuses do
		for _, win in st.windows do
			if win.hn ~= nil and now - win.at_ms < WINDOW_FORGET_MS then
				out[win.hn] = true
			end
		end
	end
	return out
end

-- Whether the windows have had a minute since the host half's first status message to be heard, so a stored host
-- name no live window uses is really out of use (a window that names it may simply not have spoken yet).
function M.settled(state: State, now: number): boolean
	return state.since ~= nil and now - (state.since :: number) >= WINDOW_FORGET_MS
end

-- The machine's status health over every registered copy: "unavailable" until any copy got a message,
-- "stale" once every copy has been silent for `STALE_MS`, else "ok" (fresh while any copy's is).
function M.health(state: State, now: number): string
	local any = false
	for st in state.statuses do
		if st.last_ms ~= nil then
			any = true
			if now - st.last_ms <= M.STALE_MS then
				return "ok"
			end
		end
	end
	return if any then "stale" else "unavailable"
end

function M.fresh(state: State, now: number): boolean
	return M.health(state, now) == "ok"
end

-- Milliseconds since the newest status message of any copy, nil before the first.
function M.age(state: State, now: number): number?
	local newest: number? = nil
	for st in state.statuses do
		if st.last_ms ~= nil and (newest == nil or st.last_ms > newest) then
			newest = st.last_ms
		end
	end
	if newest == nil then
		return nil
	end
	return now - newest
end

-- Milliseconds since each deck id's merged status last changed.
function M.row_ages(state: State, now: number): { [string]: number }
	local out: { [string]: number } = {}
	for id, at in state.changed do
		out[id] = now - at
	end
	return out
end

-- The header fields of the copy whose status message arrived last (`h`, `em`, `sn`, `hn`); nil before any.
function M.newest(state: State): Latest?
	local best: Status? = nil
	for st in state.statuses do
		if st.last_ms ~= nil and (best == nil or st.last_ms > (best.last_ms :: number)) then
			best = st
		end
	end
	return if best ~= nil then best.latest else nil
end

-- The version banner for the machine: the verdict of a window heard from within `STALE_MS`, `bad_p_newer` before
-- `bad_p_older`, so two windows on different versions show one banner at a time rather than alternating.
function M.version(state: State, now: number): string?
	local older = false
	for st in state.statuses do
		for _, verdict in st.versions do
			if now - verdict.at_ms <= M.STALE_MS then
				if verdict.v == "bad_p_newer" then
					return "bad_p_newer"
				end
				older = true
			end
		end
	end
	return if older then "bad_p_older" else nil
end

-- The entries per deck id, merged across every copy's windows by when each window saw the agent change
-- (`status.merged`); a window silent at a copy for over `STALE_MS` is left out there.
function M.status_by_id(state: State, now: number): model.StatusById
	local copies: { { [string]: status.Window } } = {}
	for st in state.statuses do
		table.insert(copies, st.windows)
	end
	return status.merged(copies, now, M.STALE_MS)
end

local function decode(io: Io, value: any): any
	if type(value) ~= "string" then
		return nil
	end
	local res, err = io.json_decode(value)
	if err ~= nil then
		return nil
	end
	return res
end

-- Merges one message into its window (`status.apply`, as the next arrival). An id this message carries gets a new
-- `changed` time only when its merged-for-display entries (`status_by_id`) differ from before, so a second window
-- reporting the same entries, or a window that went quiet resuming with them, leaves the row's age alone.
local function merge(state: State, st: Status, w: string, msg: { [string]: any }, now: number): boolean
	state.arrived += 1
	local mark = state.arrived
	local old = st.windows[w]
	-- The display before this message, with the receiving window counted as live (its own silence is not a change).
	if old ~= nil then
		old.at_ms = now
	end
	local before = M.status_by_id(state, now)
	local win, carried = status.apply(old, msg, mark, now)
	st.windows[w] = win
	local after = M.status_by_id(state, now)
	for id, n in win.carried do
		if n == mark then
			if not status.same_display(before[id], after[id]) then
				state.changed[id] = now
			end
			local merged = after[id]
			if merged ~= nil then
				for _, e in merged do
					if status.working(e) then
						state.seen_working[id] = true
					end
				end
			end
		end
	end
	return carried
end

local function none(deck: store.Deck, render: boolean): Outcome
	return { deck = deck, notice = nil, requests = {}, due = {}, render = render }
end

-- Records a window's version verdict on one copy. True when the machine's banner changed.
local function set_version(state: State, st: Status, w: string?, verdict: string, now: number): boolean
	local before = M.version(state, now)
	st.versions[w or "?"] = { v = verdict, at_ms = now }
	return M.version(state, now) ~= before
end

local function on_status(state: State, st: Status, value: any, ctx: Ctx): Outcome
	local deck = ctx.deck
	local msg = decode(ctx.io, value)
	if type(msg) ~= "table" then
		M.note_error(state, "status message is not JSON")
		return none(deck, false)
	end
	local verdict = protocol.check_status(msg, st.last_seq)
	if verdict == "bad_p_newer" or verdict == "bad_p_older" then
		return none(deck, set_version(state, st, if type(msg.w) == "string" then msg.w else nil, verdict, ctx.now))
	end
	if verdict == "old" then
		return none(deck, false)
	end
	local before_version = M.version(state, ctx.now)
	local render = M.health(state, ctx.now) ~= "ok"
	local w: string = msg.w
	st.versions[w] = nil
	if M.version(state, ctx.now) ~= before_version then
		render = true
	end
	st.last_seq[w] = msg.seq
	if merge(state, st, w, msg, ctx.now) then
		render = true
	end
	st.last_ms = ctx.now
	if state.since == nil then
		state.since = ctx.now
	end
	local latest: Latest = {
		h = if type(msg.h) == "string" then msg.h else nil,
		sn = if type(msg.sn) == "string" and msg.sn ~= "" then msg.sn else nil,
		hn = if type(msg.hn) == "string" and msg.hn ~= "" then msg.hn else nil,
		dupb = msg.dupb == true,
		em = if msg.em == "B" then "B" else "A",
		t = if type(msg.t) == "number" then msg.t else nil,
	}
	local prev = st.latest
	if prev.h ~= latest.h or prev.dupb ~= latest.dupb or prev.em ~= latest.em then
		render = true
	end
	st.latest = latest
	st.windows[w].hn = latest.hn

	local requests: { Req } = {}
	if verdict == "gap" then
		table.insert(requests, { verb = "hello", fields = {} })
	end

	-- The stored names heal from sn and hn; the host name only when no window heard within a minute still uses it.
	local healed, notice = model.heal_session(
		deck,
		latest.sn,
		latest.hn,
		M.live_hosts(state, ctx.now),
		M.settled(state, ctx.now),
		ctx.wall
	)
	if healed ~= deck then
		deck = healed
		render = true
	end
	-- Every held message is checked, not only the changed ids: a fresh status can make an unchanged idle agent due
	-- (the window came back after a reload).
	local due = M.due(state, deck, ctx.sets, ctx.now, ctx.wall, ctx.skip)
	return { deck = deck, notice = notice, requests = requests, due = due, render = render }
end

local function on_reply(state: State, st: Status, value: any, ctx: Ctx): Outcome
	local deck = ctx.deck
	local msg = decode(ctx.io, value)
	if type(msg) ~= "table" then
		M.note_error(state, "reply is not JSON")
		return none(deck, false)
	end
	local verdict = protocol.check_request(msg)
	if verdict ~= "ok" then
		return none(deck, set_version(state, st, nil, verdict, ctx.now))
	end
	if not protocol.reply_for_me(msg, ctx.b) or type(msg.r) ~= "number" then
		return none(deck, false)
	end
	local err = if type(msg.err) == "string" then msg.err else nil
	local deck_after, notice, line = requests.reply(ctx.requests, ctx.b, msg.r, msg.ok == true, err, deck, ctx.wall)
	if line ~= nil then
		M.note_error(state, line)
	end
	if notice == nil then
		return none(deck_after, false)
	end
	return { deck = deck_after, notice = notice, requests = {}, due = {}, render = true }
end

local function on_diag(state: State, st: Status, value: any, ctx: Ctx): Outcome
	local deck = ctx.deck
	local msg = decode(ctx.io, value)
	if type(msg) ~= "table" then
		msg = {}
	end
	local verdict = protocol.check_request(msg)
	if verdict ~= "ok" then
		return none(deck, set_version(state, st, nil, verdict, ctx.now))
	end
	local wall = math.floor(ctx.wall)
	local path = ctx.data_dir .. "/diag-host-" .. string.format("%d", wall) .. ".json"
	local dump = {
		p = protocol.P,
		at_ms = wall,
		host = deck.session.host,
		readonly = ctx.readonly,
		deck = deck,
		status = {
			block = ctx.b,
			windows = st.windows,
			last_seq = st.last_seq,
			age_ms = M.age(state, ctx.now),
			latest = st.latest,
			versions = st.versions,
		},
		pending = requests.pending(ctx.requests),
		binding = ctx.binding(),
		errors = state.errors,
	}
	local encoded, text = pcall(ctx.io.json_encode, dump, true)
	local ok, err = false, nil
	if encoded then
		ok, err = ctx.io.fs_write(path, text)
	else
		err = tostring(text)
	end
	if not ok then
		M.note_error(state, "diag dump failed: " .. tostring(err))
		return {
			deck = deck,
			notice = "diagnostics not written on " .. model.host_label(deck) .. ": " .. tostring(err),
			requests = {},
			due = {},
			render = true,
		}
	end
	return {
		deck = deck,
		notice = nil,
		requests = { { verb = "diag", fields = { path = path } } },
		due = {},
		render = false,
	}
end

-- A focus message: the deck id to highlight, or the version banner for a window on another version. One naming no
-- agent is logged and changes nothing.
local function on_focus(state: State, st: Status, value: any, ctx: Ctx): Outcome
	local msg = decode(ctx.io, value)
	if type(msg) ~= "table" then
		M.note_error(state, "focus message is not JSON")
		return none(ctx.deck, false)
	end
	local verdict, id = protocol.check_focus(msg)
	if verdict ~= "ok" then
		return none(ctx.deck, set_version(state, st, if type(msg.w) == "string" then msg.w else nil, verdict, ctx.now))
	end
	if id == nil then
		M.note_error(state, "focus message names no agent")
		return none(ctx.deck, false)
	end
	return { deck = ctx.deck, notice = nil, requests = {}, due = {}, render = false, follow = id }
end

-- A view `action` event for the block whose status is `st`. `act = "st"` (status), `"res"` (a reply), `"diag"`
-- (write the host dump, then `jumpr://diag` with its path) or `"fo"` (a focus message); the JSON is in `value`. An
-- unsplit `st=<json>` is accepted too.
function M.on_action(state: State, st: Status, ev: { [string]: any }, ctx: Ctx): Outcome
	local act: any = ev.act
	local value: any = ev.value
	if type(act) == "string" and value == nil then
		local a, v = string.match(act, "^(%a+)=(.*)$")
		if a ~= nil then
			act, value = a, v
		end
	end
	if act == "st" then
		return on_status(state, st, value, ctx)
	elseif act == "res" then
		return on_reply(state, st, value, ctx)
	elseif act == "diag" then
		return on_diag(state, st, value, ctx)
	elseif act == protocol.FOCUS_ACT then
		return on_focus(state, st, value, ctx)
	end
	-- An act this version does not know: still read its version (a missing `p` reads as older), so a message from
	-- another version shows the banner; one of this version is logged, never dropped silently.
	local msg = decode(ctx.io, value)
	if type(msg) == "table" then
		local verdict = protocol.check_request(msg)
		if verdict == "bad_p_newer" or verdict == "bad_p_older" then
			return none(
				ctx.deck,
				set_version(state, st, if type(msg.w) == "string" then msg.w else nil, verdict, ctx.now)
			)
		end
	end
	M.note_error(state, "unknown action " .. tostring(act) .. " ignored")
	return none(ctx.deck, false)
end

return M
