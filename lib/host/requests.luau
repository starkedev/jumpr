--!strict
-- The host's requests to the window: building each `jumpr://` URL from a copy's sender, the ledger of requests that
-- wait for a reply (`start`, `stop`) or are remembered to name their agent in a failure (`jump`, `show`), what a
-- reply settles, and what happens when none comes. Pure: no `tern`; the host passes the deck in, saves what comes
-- back, keeps the ledger, and writes the returned error lines to its error ring.

local model = require("./model")
local protocol = require("../shared/protocol")
local store = require("./store")

local M = {}

-- No `res` to a start or stop this long after it was sent: the start fails (`no_reply`), the stop is taken back.
M.REPLY_MS = 10 * 1000
-- A jump or show failure still names its agent this long after it was sent.
local SENT_KEEP_MS = 60 * 1000

-- A request that waits for its `res` (start, stop), or a jump remembered to name its agent in a failure notice.
export type Sent = { verb: string, id: string?, b: string, r: number, sent_ms: number }

-- The block sending a request: its uid `b`, the last `r` it sent, and its in-memory count for read-only data.
export type Sender = { b: string, last_r: number?, mem_r: number }

-- The machine's requests waiting for a reply, and the jumps and shows remembered, by `b:r`.
export type Ledger = { pending: { [string]: Sent }, jumps: { [string]: Sent } }

function M.new(): Ledger
	return { pending = {}, jumps = {} }
end

-- A block's sender. It keeps the uid saved by `save()` only while `next_req` still counts on from it; with no
-- saved uid, read-only data (`r` counted in memory from 1) or `next_req` restarted (kv reset) it takes a new one,
-- so the window never drops its requests as repeats.
function M.new_sender(saved_uid: any, deck: store.Deck, readonly: boolean, new_uid: () -> string): Sender
	local keep = type(saved_uid) == "string" and saved_uid ~= "" and not readonly and deck.next_req > 1
	return { b = if keep then saved_uid else new_uid(), last_r = nil, mem_r = 0 }
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
-- counted in memory and the deck is unchanged. Only `start` and `stop` are recorded as waiting for a reply, and
-- `jump` and `show` are remembered. The URL names the deck session (`sn`) beside the stored host name, so a window
-- can tell this list's requests from another host's.
function M.request(
	ledger: Ledger,
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
	local url = protocol.request_url(verb, sender.b, r, host_name(deck), fields, deck.session.name)
	local sent: Sent = { verb = verb, id = fields.id, b = sender.b, r = r, sent_ms = now }
	if protocol.expects_reply(verb) then
		ledger.pending[key(sender.b, r)] = sent
	elseif verb == "jump" or verb == "show" then
		ledger.jumps[key(sender.b, r)] = sent
	end
	return url, out
end

-- A binding settled the start of `id`: its pending `start` request is cleared, whatever the reply route did.
function M.clear_start(ledger: Ledger, id: string)
	for k, p in ledger.pending do
		if p.verb == "start" and p.id == id then
			ledger.pending[k] = nil
		end
	end
end

-- The reply to request `r` of block `b` (`ok`, with the window's `err`): a failed start is marked failed, a failed
-- stop is taken back, and a failed jump or show names its agent. Returns the deck (the same table when unchanged),
-- the notice for the list, and the line for the error ring; both nil when there is nothing to say.
function M.reply(
	ledger: Ledger,
	b: string,
	r: number,
	ok: boolean,
	err: string?,
	deck: store.Deck,
	wall: number
): (store.Deck, string?, string?)
	local k = key(b, r)
	local why = if err ~= nil and err ~= "" then err else "no reason given"
	local host = model.host_label(deck)
	local p = ledger.pending[k]
	if p ~= nil then
		ledger.pending[k] = nil
		if not ok and p.verb == "start" and p.id ~= nil then
			local label = model.agent_label(deck, p.id)
			return model.start_failed(deck, p.id, "res", wall),
				"start " .. label .. " failed on " .. host .. ": " .. why,
				"start " .. p.id .. " failed: " .. why
		end
		if not ok and p.verb == "stop" and p.id ~= nil then
			local failed, notice = model.stop_failed(deck, p.id)
			local line = "stop " .. p.id .. " failed: " .. why
			if notice ~= nil then
				return failed, notice .. ": " .. why, line
			end
			return deck, nil, line
		end
		return deck, nil, nil
	end
	if ok then
		return deck, nil, nil
	end
	local jump = ledger.jumps[k]
	ledger.jumps[k] = nil
	local id = if jump ~= nil then jump.id else nil
	local verb = if jump ~= nil and jump.verb == "show" then "show" else "jump"
	return deck,
		(if verb == "show" then "show " else "jump to ")
			.. model.agent_label(deck, id)
			.. " failed on "
			.. host
			.. ": "
			.. why,
		verb .. " " .. (id or "?") .. " failed: " .. why
end

-- The host timer's reply rule: a start with no `res` within `REPLY_MS` goes through
-- `model.start_failed(…, "no_reply")`, and a stop with none through `model.stop_failed`, whose notice comes back
-- (the stop may have happened with the reply lost: the record still goes when `pane_exited` arrives within 60 s of
-- `stop_ms`). Also forgets old jumps. Returns the deck, the notices, and the lines for the error ring.
function M.expire(ledger: Ledger, deck: store.Deck, now: number, wall: number): (store.Deck, { string }, { string })
	local out = deck
	local notices: { string } = {}
	local errors: { string } = {}
	for k, p in ledger.pending do
		if now - p.sent_ms >= M.REPLY_MS then
			ledger.pending[k] = nil
			if p.verb == "start" and p.id ~= nil then
				out = model.start_failed(out, p.id, "no_reply", wall)
			elseif p.verb == "stop" and p.id ~= nil then
				local failed, notice = model.stop_failed(out, p.id)
				out = failed
				if notice ~= nil then
					table.insert(errors, "stop " .. p.id .. ": no reply")
					table.insert(notices, notice)
				end
			end
		end
	end
	for k, p in ledger.jumps do
		if now - p.sent_ms >= SENT_KEEP_MS then
			ledger.jumps[k] = nil
		end
	end
	return out, notices, errors
end

-- The requests waiting for a reply, oldest `r` first, for the diagnostics dump.
function M.pending(ledger: Ledger): { Sent }
	local out: { Sent } = {}
	for _, p in ledger.pending do
		table.insert(out, p)
	end
	table.sort(out, function(a: Sent, b: Sent): boolean
		return a.r < b.r
	end)
	return out
end

return M
