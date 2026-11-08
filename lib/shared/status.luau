--!strict
-- Status mapping. The window fills the raw entry fields as it sees them; the block applies
-- this one rule, so both halves agree by sharing the module. Pure: no `tern`.

local M = {}

-- One live pane's raw state. s: "w" working | "q" waiting_input | "i" idle | "x" exited. u: unseen finish
-- (PaneInfo.alert). f: last turn failed. e: delivery_error, PaneInfo.error or exit status ≠ 0. src: status source.
export type Entry = { s: string, u: boolean?, f: boolean?, e: string?, src: string? }

-- "error" | "waiting" | "running" | "idle" | "stopped" | "unknown".
export type Code = string

-- The host record fields the mapping reads when no usable entry exists.
export type RecordState = { state: string, exit: number? }

-- One ranked status: its code, the filter key (also the symbol a tile and the `?` menu show), the word a pill and a
-- tile show, and the styles.css role that colours it.
export type Status = { code: Code, key: string, word: string, role: string }

-- The ranked statuses in the one priority order, what needs you first: error, waiting, running, idle, with the
-- filter keys along the shifted number row. Tiles, filter keys, the `?` menu, the head line, pills, roles and the
-- folded-group rank all read this table; `stopped` and `unknown` rank nowhere and match no filter.
M.ORDER = table.freeze({
	table.freeze({ code = "error", key = "!", word = "error", role = "deck.err" }),
	table.freeze({ code = "waiting", key = "@", word = "waiting", role = "deck.wait" }),
	table.freeze({ code = "running", key = "#", word = "running", role = "deck.run" }),
	table.freeze({ code = "idle", key = "$", word = "idle", role = "deck.idle" }),
}) :: { Status }

local RANK: { [string]: number } = {}
local BY_CODE: { [string]: Status } = {}
local BY_KEY: { [string]: Status } = {}
for i, st in M.ORDER do
	RANK[st.code] = i
	BY_CODE[st.code] = st
	BY_KEY[st.key] = st
end

-- The ranked status with code `code`, or nil (`stopped`, `unknown`, anything else).
function M.of(code: Code?): Status?
	return if code ~= nil then BY_CODE[code] else nil
end

-- The ranked status whose filter key is `key`, or nil.
function M.by_key(key: string?): Status?
	return if key ~= nil then BY_KEY[key] else nil
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

-- Whether a row with `code` shows under `filter`. No filter shows everything; `unknown` and `stopped` match no filter.
function M.matches(code: Code, filter: string?): boolean
	if filter == nil then
		return true
	end
	return RANK[code] ~= nil and code == filter
end

return M
