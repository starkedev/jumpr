--!strict
-- Pure queue transitions for `q` (queue a message for an agent that is busy). No `tern` here: the host
-- passes the deck, the pane sets and the merged status in, saves what comes back, and only then types the text.
-- Each agent holds at most one message, in `deck.queue`, which lives in kv. A held message is sent once, when its
-- agent is idle on a fresh status; `mark_sent` deletes it and stamps the record's `last_send_ms` so a reload between
-- the save and the typing cannot send it twice (at most one message is lost, never two sent).
-- Times here are wall-clock ms, the clock stored in `jumpr.v1`.

local model = require("./model")
local store = require("./store")

local M = {}

export type Queue = { [string]: store.QueueEntry }

-- A held message that is due, with the id it belongs to.
export type Due = { id: string, entry: store.QueueEntry }

M.CANCELLED = "queued message cancelled"
-- After a send, the next message waits for a working status, or this long.
M.GUARD_MS = 30 * 1000

-- The held message of `id`: the text to prefill `q` and the reason `o` refuses on a missing pane.
function M.held(q: Queue, id: string): store.QueueEntry?
	return q[id]
end

local function copy_of(q: Queue): Queue
	local out: Queue = {}
	for id, entry in q do
		out[id] = table.clone(entry)
	end
	return out
end

-- Stores `text` as the agent's only held message, replacing any. Empty text deletes a held message and returns
-- "queued message cancelled"; with nothing held it stores nothing, returns no notice and gives back the same table.
function M.set(q: Queue, id: string, text: string, now: number): (Queue, string?)
	if text == "" then
		if q[id] == nil then
			return q, nil
		end
		local out = copy_of(q)
		out[id] = nil
		return out, M.CANCELLED
	end
	local out = copy_of(q)
	out[id] = { text = text, at_ms = now }
	return out, nil
end

-- The held message of `id` when it may be typed now, else nil. `status_entry` is the pane's single status entry, not
-- its status code, because `waiting` covers both `waiting_input` and idle with an unseen finish: only `s = "i"` is idle
-- (seen or unseen), never `s = "q"`. All of these must hold: the status is `fresh`; the record is `live` with a bound
-- pane (`live`) that is not a duplicate; and there is no `last_send_ms`, or a working status was seen since it
-- (`seen_working`, memory only, false after a reload), or `GUARD_MS` have passed since it.
function M.due(
	q: Queue,
	id: string,
	status_entry: { s: string }?,
	fresh: boolean,
	live: boolean,
	dup: boolean,
	last_send_ms: number?,
	seen_working: boolean,
	now: number
): store.QueueEntry?
	local held = q[id]
	if held == nil or status_entry == nil or status_entry.s ~= "i" then
		return nil
	end
	if not fresh or not live or dup then
		return nil
	end
	if last_send_ms ~= nil and not seen_working and now - last_send_ms < M.GUARD_MS then
		return nil
	end
	return held
end

-- Every held message that is due now, ordered by id. `sets` are the live panes per deck id, `status` the machine's
-- merged entries per deck id, `fresh` whether that status is fresh, `seen_working` the ids a working status was seen
-- for since their last send. `skip` is the one id never swept: the agent whose `q` line is open, so a cancel or an
-- edit is not raced by a send of the text it replaces.
function M.sweep(
	deck: store.Deck,
	sets: model.PaneSets,
	status: model.StatusById,
	fresh: boolean,
	seen_working: { [string]: boolean },
	now: number,
	skip: string?
): { Due }
	local ids: { string } = {}
	for id in deck.queue do
		if id ~= skip then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	local out: { Due } = {}
	for _, id in ids do
		local record = deck.agents[id]
		if record ~= nil then
			local entries = status[id]
			local entry = if entries ~= nil and #entries == 1 then entries[1] else nil
			local entry_due = M.due(
				deck.queue,
				id,
				entry,
				fresh,
				model.is_live(record, sets[id]),
				model.is_dup(sets[id], entries),
				record.last_send_ms,
				seen_working[id] == true,
				now
			)
			if entry_due ~= nil then
				table.insert(out, { id = id, entry = entry_due })
			end
		end
	end
	return out
end

-- A held message was sent (or is about to be typed): deletes it and sets the record's `last_send_ms = now`. The
-- returned deck carries the returned queue. The caller saves it before calling `pane_write`, and clears the id's
-- `seen_working`, so the next message waits for working-then-idle or `GUARD_MS`.
function M.mark_sent(q: Queue, deck: store.Deck, id: string, now: number): (Queue, store.Deck)
	local out = store.clone(deck)
	local rest = copy_of(q)
	rest[id] = nil
	out.queue = rest
	local record = out.agents[id]
	if record ~= nil then
		record.last_send_ms = now
	end
	return rest, out
end

-- The typing failed: keeps the entry held with `err`, for the next idle (the record's `last_send_ms` stays, so the
-- retry waits `GUARD_MS` rather than failing every second).
function M.mark_failed(q: Queue, id: string, entry: store.QueueEntry, err: string): Queue
	local out = copy_of(q)
	out[id] = { text = entry.text, at_ms = entry.at_ms, err = err }
	return out
end

-- An `o` message that was not typed: the record's `last_send_ms` goes back to `prev` (the stamp the send replaced),
-- and the text is kept as the agent's held message with `err` unless one is already held. A new deck.
function M.unsent(deck: store.Deck, id: string, text: string, prev: number?, err: string, now: number): store.Deck
	local out = store.clone(deck)
	local record = out.agents[id]
	if record ~= nil then
		record.last_send_ms = prev
	end
	if out.queue[id] == nil then
		out.queue = M.mark_failed(out.queue, id, { text = text, at_ms = now }, err)
	end
	return out
end

return M
