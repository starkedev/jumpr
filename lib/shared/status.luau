--!strict
-- The status entry and how it travels. The window fills the raw entry fields as it sees them and sends each copy of
-- the list what changed; the block applies those messages per window, merges the windows' reports, and maps an entry
-- to the code a row shows. Both halves read an entry only through this module, so they agree on it. Pure: no `tern`.

local M = {}

-- One live pane's raw state. s: "w" working | "q" waiting_input | "i" idle | "x" exited. u: unseen finish
-- (PaneInfo.alert). f: last turn failed. e: delivery_error, PaneInfo.error or exit status ≠ 0. src: status source.
-- c: wall-clock ms when the sending window last saw this entry change; absent when it has seen no change since it
-- first saw the pane, so another window that watched the change happen outranks it.
-- k: the pane is parked (its program runs, in no tab); absent means it is in a tab, which is all an older window
-- ever sends.
export type Entry = { s: string, u: boolean?, f: boolean?, e: string?, src: string?, c: number?, k: boolean? }

-- "error" | "waiting" | "running" | "idle" | "stopped" | "unknown".
export type Code = string

-- The host record fields the mapping reads when no usable entry exists.
export type RecordState = { state: string, exit: number? }

-- One ranked status: its code, the filter key (also the symbol a tile and the `?` menu show), the key that adds it to
-- or drops it from a combined filter, the word a pill and a tile show, and the styles.css role that colours it.
export type Status = { code: Code, key: string, add: string, word: string, role: string }

-- The ranked statuses in the one priority order, what needs you first: error, waiting, running, idle, with the
-- filter keys along the shifted number row and the combine keys on the same keys unshifted (on a US layout). Tiles,
-- filter keys, the `?` menu, the head line, pills, roles and the folded-group rank all read this table; `stopped` and
-- `unknown` rank nowhere and match no filter.
M.ORDER = table.freeze({
	table.freeze({ code = "error", key = "!", add = "1", word = "error", role = "deck.err" }),
	table.freeze({ code = "waiting", key = "@", add = "2", word = "waiting", role = "deck.wait" }),
	table.freeze({ code = "running", key = "#", add = "3", word = "running", role = "deck.run" }),
	table.freeze({ code = "idle", key = "$", add = "4", word = "idle", role = "deck.idle" }),
}) :: { Status }

local RANK: { [string]: number } = {}
local BY_CODE: { [string]: Status } = {}
local BY_KEY: { [string]: Status } = {}
local BY_ADD: { [string]: Status } = {}
for i, st in M.ORDER do
	RANK[st.code] = i
	BY_CODE[st.code] = st
	BY_KEY[st.key] = st
	BY_ADD[st.add] = st
end

-- The ranked status with code `code`, or nil (`stopped`, `unknown`, anything else).
function M.of(code: Code?): Status?
	return if code ~= nil then BY_CODE[code] else nil
end

-- The place of `code` in `M.ORDER`, 1 most urgent; `stopped`, `unknown` and anything else rank after every status.
function M.rank(code: Code): number
	return RANK[code] or #M.ORDER + 1
end

-- The ranked status whose filter key is `key`, or nil.
function M.by_key(key: string?): Status?
	return if key ~= nil then BY_KEY[key] else nil
end

-- The ranked status whose combine key is `key`, or nil.
function M.by_add_key(key: string?): Status?
	return if key ~= nil then BY_ADD[key] else nil
end

local function exited_code(record: RecordState?): Code
	if record ~= nil and record.state == "exited" then
		if record.exit ~= nil and record.exit ~= 0 then
			return "error"
		end
		return "stopped"
	end
	return "unknown"
end

-- The mapping table, first match wins, top to bottom. A stale entry (`fresh = false`) counts as no entry: then an
-- `exited` host record gives `stopped` for exit 0 (or no exit status) and `error` otherwise, and anything else `unknown`.
function M.code(entry: Entry?, fresh: boolean, record: RecordState?): Code
	if entry == nil or not fresh then
		return exited_code(record)
	end
	local s = entry.s
	local unseen = entry.u == true
	local exit_failed = s == "x" and record ~= nil and record.exit ~= nil and record.exit ~= 0
	if (entry.e ~= nil and entry.e ~= "") or exit_failed or (entry.f == true and unseen) then
		return "error"
	end
	if s == "q" or (s == "i" and unseen) then
		return "waiting"
	end
	if s == "w" then
		return "running"
	end
	if s == "i" then
		return "idle"
	end
	if s == "x" then
		return "stopped"
	end
	return "unknown"
end

-- The first-ranked code in `M.ORDER` (folded group headers); nil when none of those is present.
function M.worst(codes: { Code }): Code?
	local best: Code? = nil
	local best_rank = math.huge
	for _, c in codes do
		local rank = RANK[c]
		if rank ~= nil and rank < best_rank then
			best, best_rank = c, rank
		end
	end
	return best
end

-- Filters --------------------------------------------------------------------------------------------------------
-- A filter is one status code, or several joined by "," in `M.ORDER`'s order ("waiting,running"); nil is no filter.
-- It stays a plain string so the list's UI state and its saved copy keep their shape, and two filters compare with ==.

-- The codes of `filter`, in `M.ORDER`'s order; empty for nil. Anything that is not a ranked code is left out.
function M.filter_codes(filter: string?): { Code }
	local out: { Code } = {}
	if filter == nil then
		return out
	end
	local has: { [string]: boolean } = {}
	for part in string.gmatch(filter, "[^,]+") do
		has[part] = true
	end
	for _, st in M.ORDER do
		if has[st.code] then
			table.insert(out, st.code)
		end
	end
	return out
end

-- The filter holding exactly `codes` (any order, unranked ones dropped), or nil when none is left.
local function filter_of(codes: { [string]: boolean }): string?
	local out: { string } = {}
	for _, st in M.ORDER do
		if codes[st.code] then
			table.insert(out, st.code)
		end
	end
	return if #out > 0 then table.concat(out, ",") else nil
end

-- `filter` as a valid filter: its ranked codes in order, or nil when it holds none (a saved value from an older
-- version, or anything else, is read through this).
function M.filter_clean(filter: any): string?
	if type(filter) ~= "string" then
		return nil
	end
	local has: { [string]: boolean } = {}
	for _, c in M.filter_codes(filter) do
		has[c] = true
	end
	return filter_of(has)
end

-- Whether `filter` holds `code`.
function M.filter_has(filter: string?, code: Code): boolean
	return table.find(M.filter_codes(filter), code) ~= nil
end

-- `filter` with `code` added when it was not in it, or taken out when it was; nil once the last code goes.
function M.filter_toggle(filter: string?, code: Code): string?
	local has: { [string]: boolean } = {}
	for _, c in M.filter_codes(filter) do
		has[c] = true
	end
	has[code] = not has[code]
	return filter_of(has)
end

-- Whether a row with `code` shows under `filter`. No filter shows everything; `unknown` and `stopped` match no filter.
function M.matches(code: Code, filter: string?): boolean
	if filter == nil then
		return true
	end
	return RANK[code] ~= nil and M.filter_has(filter, code)
end

-- Entries ---------------------------------------------------------------------------------------------------------

-- The agent is working on a turn.
function M.working(e: Entry): boolean
	return e.s == "w"
end

-- The agent asked a question and waits for input (`waiting_input`).
function M.asking(e: Entry): boolean
	return e.s == "q"
end

-- The agent is idle, its finish seen or unseen; a held message may be typed into it.
function M.idle(e: Entry): boolean
	return e.s == "i"
end

-- What an entry says, its change time and source aside: the window stamps a new change time only when this differs.
-- A pane in a tab reads exactly as it did before panes could be parked.
function M.seen_key(e: Entry): string
	local key = table.concat({ e.s, if e.u then "u" else "", if e.f then "f" else "", e.e or "" }, "\31")
	return if e.k then key .. "\31k" else key
end

-- Everything one deck id's entries carry, change times included: the window sends an id again when this differs,
-- so a new change time reaches the block even when the state reads the same.
function M.wire_key(list: { Entry }): string
	local parts: { string } = {}
	for _, e in list do
		local part = table.concat({
			e.s,
			if e.u then "u" else "",
			if e.f then "f" else "",
			e.e or "",
			e.src or "",
			if e.c ~= nil then string.format("%d", e.c) else "",
		}, "\31")
		table.insert(parts, if e.k then part .. "\31k" else part)
	end
	return table.concat(parts, "\30")
end

-- Whether two entry lists show the same on a row (change times aside): the block restarts a row's age only when they
-- differ.
function M.same_display(a: { Entry }?, b: { Entry }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	if #a ~= #b then
		return false
	end
	for i, x in a do
		local y = b[i]
		if x.s ~= y.s or x.u ~= y.u or x.f ~= y.f or x.e ~= y.e or x.src ~= y.src or x.k ~= y.k then
			return false
		end
	end
	return true
end

-- The entries in a list another machine sent: anything that is not an entry is dropped, and a field of the wrong type,
-- an empty error or a change time that is not positive is left out.
local function decode(list: any): { Entry }
	local out: { Entry } = {}
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
				c = if type(e.c) == "number" and e.c > 0 then e.c else nil,
				k = if e.k == true then true else nil,
			})
		end
	end
	return out
end

-- The sending side ------------------------------------------------------------------------------------------------

-- What one status message to one copy carries. `full`: the whole list (the copy's first message is always full).
-- `changed`: the deck ids to send, with their entries. `gone`: deck ids sent before and no longer listed (a diff
-- only; the sender writes each as an empty list). `keys`: the wire keys to remember for the next diff.
export type Diff = {
	full: boolean,
	changed: { [string]: { Entry } },
	gone: { string },
	keys: { [string]: string },
}

-- The message for one copy given what it was last sent (`last_keys`, nil before the first message) and the entries
-- now, as a full snapshot when `full` or on first contact, else the ids whose wire keys changed and the ids gone.
function M.diff(last_keys: { [string]: string }?, entries: { [string]: { Entry } }, full: boolean): Diff
	local whole = full or last_keys == nil
	local last: { [string]: string } = last_keys or {}
	local changed: { [string]: { Entry } } = {}
	local keys: { [string]: string } = {}
	for id, list in entries do
		local key = M.wire_key(list)
		keys[id] = key
		if whole or last[id] ~= key then
			changed[id] = list
		end
	end
	local gone: { string } = {}
	if not whole then
		for id in last do
			if keys[id] == nil then
				table.insert(gone, id)
			end
		end
		table.sort(gone)
	end
	return { full = whole, changed = changed, gone = gone, keys = keys }
end

-- The receiving side ----------------------------------------------------------------------------------------------

-- The newest status from one window uid at one copy: its entries per deck id, which accepted message last carried
-- each id (an arrival number that orders every message the machine accepted, so two windows' messages in the same
-- millisecond still have an order; also for ids it reported gone, whose entries are then nil), and the name its
-- machine gives this host (`hn`).
export type Window = {
	seq: number,
	at_ms: number,
	a: { [string]: { Entry } },
	carried: { [string]: number },
	hn: string?,
}

-- Applies one status message from a window to what that window last sent this copy (`old`, nil for its first), as
-- arrival number `mark` at `now`: a full snapshot replaces the window's entries (ids it no longer lists count as
-- carried gone by this message); a diff replaces only the ids it carries, an empty list meaning gone; every carried
-- id is stamped with `mark`. A diff updates `old` in place. Returns the window and whether the message carried
-- anything (a full one always does).
function M.apply(old: Window?, msg: { [string]: any }, mark: number, now: number): (Window, boolean)
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
				local entries = decode(list)
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
	return win, any or full
end

-- Two windows' observation times this close (ms) count as one moment: the machines' clocks differ a little, and two
-- windows that saw the same finish stamp it a moment apart.
M.TIE_MS = 2000

-- When the window that sent `list` last saw it change (wall-clock ms); 0 when it saw no change.
local function observed(list: { Entry }): number
	local c = 0
	for _, e in list do
		if e.c ~= nil and e.c > c then
			c = e.c
		end
	end
	return c
end

-- The rank of the most urgent status in `list` (1 is the most urgent).
local function urgency(list: { Entry }): number
	local best = math.huge
	for _, e in list do
		best = math.min(best, M.rank(M.code(e, true, nil)))
	end
	return best
end

-- The pane's program exited ("x"). Its pane may stay open after the agent restarts in a new one.
function M.exited(e: Entry): boolean
	return e.s == "x"
end

-- The entries that say how the agent is now. An exited pane beside a running one is history: a restart starts the
-- agent in a new pane and leaves the exited one open, so while any entry is not exited the exited ones are left out.
-- A list with no running entry is returned as it is.
function M.current(list: { Entry }): { Entry }
	local running: { Entry } = {}
	for _, e in list do
		if not M.exited(e) then
			table.insert(running, e)
		end
	end
	if #running == 0 or #running == #list then
		return list
	end
	return running
end

-- The entries per deck id, merged across the windows of every copy (`copies`: each copy's windows by uid). Each
-- window counts once per id, with its newest report over every copy (its last message carrying the id, by arrival);
-- a window whose newest report has the id gone, or that never listed it, has no say. Among the windows that list the
-- id, the one that most recently saw its entry change wins, so a window that has just attached (and saw no change)
-- never overrides one that watched the agent finish. Times within `TIE_MS` of the newest tie, and a tie goes to the
-- more urgent status, then to the lower window uid: never to the later arrival, so two windows reporting differently
-- cannot flip the row back and forth. The winner's list is taken whole (never two lists joined, which would fake a
-- duplicate). A window whose last message to a copy is over `stale_ms` old is skipped there as a whole (per window,
-- never per entry, so unchanged agents keep their entries). Each window's list is read through `current`, so an exited
-- pane left open beside the agent's running one neither ranks, nor shows, nor counts as a duplicate.
function M.merged(copies: { { [string]: Window } }, now: number, stale_ms: number): { [string]: { Entry } }
	local newest: { [string]: { [string]: { n: number, list: { Entry }? } } } = {}
	for _, windows in copies do
		for w, win in windows do
			if now - win.at_ms <= stale_ms then
				for id, n in win.carried do
					local by_w = newest[id]
					if by_w == nil then
						by_w = {}
						newest[id] = by_w
					end
					local have = by_w[w]
					if have == nil or n > have.n then
						local list = win.a[id]
						by_w[w] = { n = n, list = if list ~= nil then M.current(list) else nil }
					end
				end
			end
		end
	end
	local out: { [string]: { Entry } } = {}
	for id, by_w in newest do
		local latest = -math.huge
		for _, r in by_w do
			if r.list ~= nil then
				latest = math.max(latest, observed(r.list))
			end
		end
		local best_w: string? = nil
		local best_list: { Entry }? = nil
		local best_rank = math.huge
		for w, r in by_w do
			local list = r.list
			if list ~= nil and latest - observed(list) <= M.TIE_MS then
				local rank = urgency(list)
				if best_w == nil or rank < best_rank or (rank == best_rank and w < (best_w :: string)) then
					best_w, best_list, best_rank = w, list, rank
				end
			end
		end
		if best_list ~= nil then
			out[id] = best_list
		end
	end
	return out
end

return M
