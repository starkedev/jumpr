--!strict
-- The block side of both routes between the halves: status in, requests out.
-- Status, replies and the diagnostics action arrive as view `action` events (`act = "st" | "res" | "diag"`, the
-- JSON in `value`); requests leave as `jumpr://` URLs the host opens through `compat.open`. Every message carries
-- the protocol version, and a mismatch is kept as a banner, never handled silently.
-- Agents are named by deck id only, never by a pane id from the other half. The host passes the deck in and saves any deck that comes back
-- changed; file writes go through the `io` it passes (Tern is reached only through compat).
--
-- Two kinds of state: `State` is the machine's (requests waiting for a reply, remembered jumps, the error ring, and
-- the merged view over every copy's status: arrival marks, row ages), `Status` is one copy's (the window numbers
-- `seq` per block pane, so a recreated copy starts its status afresh: the window's first message to it is a full
-- snapshot, a full message at or below the last `seq` is read as a restart of the numbering, and a first diff,
-- after a host-side restart under the same pane, is a gap, which asks for one with `jumpr://hello`). The rows,
-- health, age and version banner every copy shows come from the machine's merged view.

local model = require("./model")
local protocol = require("../shared/protocol")
local queue = require("./queue")
local status = require("../shared/status")
local store = require("./store")

local M = {}

-- No status for this long: "status stale".
M.STALE_MS = 3000
-- No `res` to a start this long after it was sent: `model.start_failed(…, "no_reply")`.
M.REPLY_MS = 10 * 1000
-- A window silent this long is forgotten.
local WINDOW_FORGET_MS = 60 * 1000
-- A jump failure `res` still names its agent this long after the jump was sent.
local SENT_KEEP_MS = 60 * 1000
local ERRORS_KEPT = 50

-- A request that waits for its `res` (start, stop), or a jump remembered to name its agent in a failure notice.
export type Sent = { verb: string, id: string?, b: string, r: number, sent_ms: number }

-- The newest status from one window uid: its entries per deck id, and which accepted message last carried each id
-- (`Status.arrived` at that message, so two windows' messages in the same millisecond still have an order; also for
-- ids it reported gone, whose entries are then nil).
export type Window = {
	seq: number,
	at_ms: number,
	a: { [string]: { status.Entry } },
	carried: { [string]: number },
}

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
	windows: { [string]: Window },
	last_seq: { [string]: number },
	-- When the last status message arrived (tern.now() ms); nil until the first one.
	last_ms: number?,
	latest: Latest,
	-- "bad_p_newer" | "bad_p_older" per window uid (`?` for a reply or diag that names none) while that window
	-- speaks another protocol version; an accepted message from the window clears it, and it ages out.
	versions: { [string]: Verdict },
}

-- The machine's request bookkeeping, error ring, and the copies' statuses it merges.
export type State = {
	pending: { [string]: Sent },
	jumps: { [string]: Sent },
	errors: { string },
	statuses: { [Status]: boolean },
	-- Accepted status messages so far, across every copy: orders `Window.carried`.
	arrived: number,
	-- When each deck id's merged entries last changed (tern.now() ms), for the `i` overlay's per-row age.
	changed: { [string]: number },
	-- Deck ids a working status was seen for since their last send. Once per machine, in memory only: false
	-- after a plugin reload, so the 30 s rule of `queue.due` applies then.
	seen_working: { [string]: boolean },
}

-- The block sending a request: its uid `b`, the last `r` it sent, and its in-memory count for read-only data.
export type Sender = { b: string, last_r: number?, mem_r: number }

export type Io = { fs_write: (path: string, text: string) -> (boolean, string?) }

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
}

export type Req = { verb: string, fields: { [string]: string } }

-- The result of one action: the deck (the same table when unchanged), a notice for the receiving block,
-- requests to send, held messages that are due (the host marks each sent, saves, then types it) and whether
-- anything visible changed.
export type Outcome = {
	deck: store.Deck,
	notice: string?,
	requests: { Req },
	due: { queue.Due },
	render: boolean,
}

function M.new(): State
	return { pending = {}, jumps = {}, errors = {}, statuses = {}, arrived = 0, changed = {}, seen_working = {} }
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

-- A block's sender. It keeps the uid saved by `save()` only while `next_req` still counts on from it; with no
-- saved uid, read-only data (`r` counted in memory from 1) or `next_req` restarted (kv reset) it takes a new one,
-- so the window never drops its requests as repeats.
function M.new_sender(saved_uid: any, deck: store.Deck, readonly: boolean, new_uid: () -> string): Sender
	local keep = type(saved_uid) == "string" and saved_uid ~= "" and not readonly and deck.next_req > 1
	return { b = if keep then saved_uid else new_uid(), last_r = nil, mem_r = 0 }
end

-- Keeps one line in the error ring (the last 50 go into the diagnostics dump).
function M.note_error(state: State, text: string)
	table.insert(state.errors, text)
	while #state.errors > ERRORS_KEPT do
		table.remove(state.errors, 1)
	end
end

local function key(b: string, r: number): string
	return b .. ":" .. string.format("%d", r)
end

local function host_name(deck: store.Deck): string
	local host = deck.session.host
	if host == nil or host == "" then
		return "unknown"
	end
	return host
end

-- The URL of a request from `sender`, and the deck with `next_req` advanced (the host saves it, then opens the
-- URL). `r` comes from `deck.next_req`; when that restarted below the sender's last `r` (kv reset to empty) the
-- sender takes a new random `b`, so the window never drops its requests as repeats. With read-only data `r` is
-- counted in memory and the deck is unchanged. Only `start` and `stop` are recorded as waiting for a reply.
function M.request(
	state: State,
	sender: Sender,
	deck: store.Deck,
	readonly: boolean,
	verb: string,
	fields: { [string]: string },
	now: number,
	new_uid: () -> string
): (string, store.Deck)
	local r: number
	local out = deck
	if readonly then
		sender.mem_r += 1
		r = sender.mem_r
	else
		r = math.max(math.floor(deck.next_req), 1)
		if sender.last_r ~= nil and r <= sender.last_r then
			sender.b = new_uid()
		end
		out = store.clone(deck)
		out.next_req = r + 1
	end
	sender.last_r = r
	local url = protocol.request_url(verb, sender.b, r, host_name(deck), fields)
	local sent: Sent = { verb = verb, id = fields.id, b = sender.b, r = r, sent_ms = now }
	if protocol.expects_reply(verb) then
		state.pending[key(sender.b, r)] = sent
	elseif verb == "jump" or verb == "show" then
		state.jumps[key(sender.b, r)] = sent
	end
	return url, out
end

-- A binding settled the start of `id`: its pending `start` request is cleared, whatever the reply route did.
function M.clear_start(state: State, id: string)
	for k, p in state.pending do
		if p.verb == "start" and p.id == id then
			state.pending[k] = nil
		end
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

-- The host timer's reply rule: a start with no `res` within `REPLY_MS` goes through
-- `model.start_failed(…, "no_reply")`, and a stop with none through `model.stop_failed`, whose notice comes back
-- (the stop may have happened with the reply lost: the record still goes when `pane_exited` arrives within 60 s of
-- `stop_ms`). Also forgets old jumps.
function M.expire(state: State, deck: store.Deck, now: number, wall: number): (store.Deck, { string })
	local out = deck
	local notices: { string } = {}
	for k, p in state.pending do
		if now - p.sent_ms >= M.REPLY_MS then
			state.pending[k] = nil
			if p.verb == "start" and p.id ~= nil then
				out = model.start_failed(out, p.id, "no_reply", wall)
			elseif p.verb == "stop" and p.id ~= nil then
				local failed, notice = model.stop_failed(out, p.id)
				out = failed
				if notice ~= nil then
					M.note_error(state, "stop " .. p.id .. ": no reply")
					table.insert(notices, notice)
				end
			end
		end
	end
	for k, p in state.jumps do
		if now - p.sent_ms >= SENT_KEEP_MS then
			state.jumps[k] = nil
		end
	end
	return out, notices
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

-- The entries per deck id, merged across every copy's windows: for each id, the list from the copy and
-- window whose message carrying it arrived last (never two lists joined, which would fake a duplicate). A copy or
-- window whose last message is over `STALE_MS` old is skipped as a whole (per window, never per entry, so
-- unchanged agents keep their entries).
function M.status_by_id(state: State, now: number): model.StatusById
	local best: { [string]: number } = {}
	local out: model.StatusById = {}
	for st in state.statuses do
		for _, win in st.windows do
			if now - win.at_ms <= M.STALE_MS then
				for id, n in win.carried do
					local seen = best[id]
					if seen == nil or n > seen then
						best[id] = n
						out[id] = win.a[id]
					end
				end
			end
		end
	end
	return out
end

local function decode(value: any): any
	if type(value) ~= "string" then
		return nil
	end
	local ok, res = pcall(tern.json.decode, value)
	if not ok then
		return nil
	end
	return res
end

local function entries_of(list: any): { status.Entry }
	local out: { status.Entry } = {}
	if type(list) ~= "table" then
		return out
	end
	for _, e in ipairs(list) do
		if type(e) == "table" and type(e.s) == "string" then
			table.insert(out, {
				s = e.s,
				u = if e.u == true then true else nil,
				f = if e.f == true then true else nil,
				e = if type(e.e) == "string" and e.e ~= "" then e.e else nil,
				src = if type(e.src) == "string" then e.src else nil,
			})
		end
	end
	return out
end

local function same_entries(a: { status.Entry }?, b: { status.Entry }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	if #a ~= #b then
		return false
	end
	for i, x in a do
		local y = b[i]
		if x.s ~= y.s or x.u ~= y.u or x.f ~= y.f or x.e ~= y.e or x.src ~= y.src then
			return false
		end
	end
	return true
end

-- Merges one message into its window. A full snapshot replaces the window's entries (ids it no longer lists count
-- as carried gone by this message); a diff replaces only the ids it carries, an empty list meaning gone. Carried ids
-- are stamped with this message's arrival number. An id this message carries gets a new `changed` time only when
-- its merged-for-display entries (`status_by_id`) differ from before, so a second window reporting the same
-- entries, or a window that went quiet resuming with them, leaves the row's age alone.
local function merge(state: State, st: Status, w: string, msg: { [string]: any }, now: number): boolean
	state.arrived += 1
	local mark = state.arrived
	local old = st.windows[w]
	-- The display before this message, with the receiving window counted as live (its own silence is not a change).
	if old ~= nil then
		old.at_ms = now
	end
	local before = M.status_by_id(state, now)
	local full = msg.full == true
	local win: Window
	if old == nil or full then
		win = { seq = msg.seq, at_ms = now, a = {}, carried = {} }
		if old ~= nil then
			for id, n in old.carried do
				win.carried[id] = n
			end
			for id in old.a do
				win.carried[id] = mark
			end
		end
	else
		win = old
		win.seq = msg.seq
		win.at_ms = now
	end
	local any = false
	if type(msg.a) == "table" then
		for id, list in msg.a do
			if type(id) == "string" then
				local entries = entries_of(list)
				if #entries > 0 then
					win.a[id] = entries
				else
					win.a[id] = nil
				end
				win.carried[id] = mark
				any = true
			end
		end
	end
	st.windows[w] = win
	local after = M.status_by_id(state, now)
	for id, n in win.carried do
		if n == mark then
			if not same_entries(before[id], after[id]) then
				state.changed[id] = now
			end
			local merged = after[id]
			if merged ~= nil then
				for _, e in merged do
					if e.s == "w" then
						state.seen_working[id] = true
					end
				end
			end
		end
	end
	return any or full
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
	local msg = decode(value)
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

	local requests: { Req } = {}
	if verdict == "gap" then
		table.insert(requests, { verb = "hello", fields = {} })
	end

	-- Section 6: the stored session name and host name heal from sn/hn.
	local notices: { string } = {}
	local session = deck.session
	local sn, hn = latest.sn, latest.hn
	if (sn ~= nil and sn ~= session.name) or (hn ~= nil and hn ~= session.host) then
		local out = store.clone(deck)
		if sn ~= nil and sn ~= session.name then
			if session.name ~= nil then
				table.insert(notices, "deck session renamed from " .. session.name .. " to " .. sn)
			end
			out.session.name = sn
		end
		if hn ~= nil and hn ~= session.host then
			if session.host ~= nil then
				table.insert(notices, "host name changed from " .. session.host .. " to " .. hn)
			end
			out.session.host = hn
		end
		out.session.set_ms = ctx.wall
		deck = out
		render = true
	end
	local notice = if #notices > 0 then table.concat(notices, "; ") else nil
	-- Every held message is checked, not only the changed ids: a fresh status can make an unchanged idle agent due
	-- (the window came back after a reload).
	local due = M.due(state, deck, ctx.sets, ctx.now, ctx.wall, ctx.skip)
	return { deck = deck, notice = notice, requests = requests, due = due, render = render }
end

local function on_reply(state: State, st: Status, value: any, ctx: Ctx): Outcome
	local deck = ctx.deck
	local msg = decode(value)
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
	local k = key(ctx.b, msg.r)
	local ok = msg.ok == true
	local err = if type(msg.err) == "string" and msg.err ~= "" then msg.err else "no reason given"
	local host = model.host_label(deck)
	local p = state.pending[k]
	if p ~= nil then
		state.pending[k] = nil
		if not ok and p.verb == "start" and p.id ~= nil then
			local label = model.agent_label(deck, p.id)
			M.note_error(state, "start " .. p.id .. " failed: " .. err)
			return {
				deck = model.start_failed(deck, p.id, "res", ctx.wall),
				notice = "start " .. label .. " failed on " .. host .. ": " .. err,
				requests = {},
				due = {},
				render = true,
			}
		end
		if not ok and p.verb == "stop" and p.id ~= nil then
			M.note_error(state, "stop " .. p.id .. " failed: " .. err)
			local failed, notice = model.stop_failed(deck, p.id)
			if notice ~= nil then
				return { deck = failed, notice = notice .. ": " .. err, requests = {}, due = {}, render = true }
			end
		end
		return none(deck, false)
	end
	if ok then
		return none(deck, false)
	end
	local jump = state.jumps[k]
	state.jumps[k] = nil
	local id = if jump ~= nil then jump.id else nil
	local verb = if jump ~= nil and jump.verb == "show" then "show" else "jump"
	M.note_error(state, verb .. " " .. (id or "?") .. " failed: " .. err)
	return {
		deck = deck,
		notice = (if verb == "show" then "show " else "jump to ")
			.. model.agent_label(deck, id)
			.. " failed on "
			.. host
			.. ": "
			.. err,
		requests = {},
		due = {},
		render = true,
	}
end

local function pending_list(state: State): { Sent }
	local out: { Sent } = {}
	for _, p in state.pending do
		table.insert(out, p)
	end
	table.sort(out, function(a: Sent, b: Sent): boolean
		return a.r < b.r
	end)
	return out
end

local function on_diag(state: State, st: Status, value: any, ctx: Ctx): Outcome
	local deck = ctx.deck
	local msg = decode(value)
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
		pending = pending_list(state),
		binding = ctx.binding(),
		errors = state.errors,
	}
	local encoded, text = pcall(tern.json.encode, dump, true)
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

-- A view `action` event for the block whose status is `st`. `act = "st"` (status), `"res"` (a reply) or `"diag"`
-- (write the host dump, then `jumpr://diag` with its path); the JSON is in `value`. An unsplit `st=<json>` is
-- accepted too.
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
	end
	-- An act this version does not know: still read its version (a missing `p` reads as older), so a message from
	-- another version shows the banner; one of this version is logged, never dropped silently.
	local msg = decode(value)
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
