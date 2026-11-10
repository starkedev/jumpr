--!strict
-- The dock input line: its text edited at the caret, and where the caret is. Pure: no `tern` here, so it runs under
-- plain `luau` in tests. Tern's native edit events and the input node's `cursor` prop count UTF-16 units, and typed
-- text, paste and backspace land at the caret; the host feeds the resulting line to keys.reduce as a whole-line edit
-- event (keys never sees the keystrokes), and view.luau clamps the caret it draws.

local M = {}

-- The key fields this module reads (a host key, as keys.Event carries it).
export type KeyEvent = { name: string?, text: string?, ctrl: boolean?, alt: boolean?, meta: boolean? }

-- Where the caret is (`cursor`, nil: at the end) in the line the host last edited (`edited`).
export type Caret = { cursor: number?, edited: string? }

-- The caret after the line changed to `text`: it stays while the line still holds the text the host last edited,
-- and goes to the end for any other text (a prefill, a refill) or when the line closed (`open` false).
function M.follow(caret: Caret, open: boolean, text: string): Caret
	if not open then
		return { cursor = nil, edited = nil }
	end
	if text ~= caret.edited then
		return { cursor = nil, edited = text }
	end
	return caret
end

-- UTF-16 units in `s` (bytes when `s` is not valid UTF-8).
function M.units(s: string): number
	local ok, n = pcall(function(): number
		local count = 0
		for _, cp in utf8.codes(s) do
			count += if cp > 0xFFFF then 2 else 1
		end
		return count
	end)
	return if ok then n else #s
end

-- The byte position of the character at UTF-16 offset `u` (an offset inside a surrogate pair rounds down; past the
-- end clamps to the end).
local function byte_at(s: string, u: number): number
	local ok, pos = pcall(function(): number
		local n = 0
		for at, cp in utf8.codes(s) do
			local w = if cp > 0xFFFF then 2 else 1
			if n + w > u then
				return at
			end
			n += w
		end
		return #s + 1
	end)
	return if ok then pos else math.clamp(u + 1, 1, #s + 1)
end

-- The caret clamped into `text` (nil or out of range: the end).
function M.clamp_cursor(text: string, cursor: number?): number
	local n = M.units(text)
	if cursor == nil then
		return n
	end
	return math.clamp(math.floor(cursor), 0, n)
end

-- The input line after a native edit event (`{from, to, text, cursor, len}`: replace from..to with text), and the
-- caret after it (`cursor`, else the end of the inserted text); nil when the event was computed against another
-- text (`len` differs) or is malformed.
function M.apply_edit(text: string, ev: { [string]: any }): (string?, number?)
	local from, to, insert, len = ev.from, ev.to, ev.text, ev.len
	if type(from) ~= "number" or type(to) ~= "number" then
		return nil, nil
	end
	if type(len) == "number" and len ~= M.units(text) then
		return nil, nil
	end
	local lo = math.min(from, to)
	local added = if type(insert) == "string" then insert else ""
	local a = byte_at(text, lo)
	local b = byte_at(text, math.max(from, to))
	local out = string.sub(text, 1, a - 1) .. added .. string.sub(text, b)
	local cursor = if type(ev.cursor) == "number" then ev.cursor else lo + M.units(added)
	return out, M.clamp_cursor(out, cursor)
end

-- `insert` typed at the caret: the new line and caret.
function M.insert_at(text: string, cursor: number?, insert: string): (string, number)
	local c = M.clamp_cursor(text, cursor)
	local at = byte_at(text, c)
	local out = string.sub(text, 1, at - 1) .. insert .. string.sub(text, at)
	return out, c + M.units(insert)
end

-- Backspace at the caret: the character before it removed.
function M.delete_before(text: string, cursor: number?): (string, number)
	local c = M.clamp_cursor(text, cursor)
	if c == 0 then
		return text, 0
	end
	local stop = byte_at(text, c)
	local start = byte_at(text, c - 1)
	if start == stop and c >= 2 then
		start = byte_at(text, c - 2)
	end
	local removed = string.sub(text, start, stop - 1)
	return string.sub(text, 1, start - 1) .. string.sub(text, stop), c - math.max(M.units(removed), 1)
end

-- The caret moved one character left (`delta` -1) or right (+1).
function M.move_cursor(text: string, cursor: number?, delta: number): number
	local c = M.clamp_cursor(text, cursor)
	if delta < 0 then
		if c == 0 then
			return 0
		end
		local _, after = M.delete_before(text, c)
		return after
	end
	local at = byte_at(text, c)
	if at > #text then
		return c
	end
	local nxt = utf8.offset(text, 2, at) or (#text + 1)
	return c + M.units(string.sub(text, at, nxt - 1))
end

-- A key in the open input line that edits it at the caret: typed text and paste insert there, backspace deletes
-- before it, left and right move it. Gives the new line and caret, or nil for a key the reducer handles (Enter,
-- Tab, Escape, chords, and the rest).
function M.key(text: string, cursor: number?, ev: KeyEvent): (string?, number?)
	if ev.ctrl or ev.alt or ev.meta then
		return nil, nil
	end
	local name = ev.name
	if name == "enter" or name == "tab" or name == "escape" then
		return nil, nil
	elseif name == "backspace" then
		return M.delete_before(text, cursor)
	elseif name == "left" then
		return text, M.move_cursor(text, cursor, -1)
	elseif name == "right" then
		return text, M.move_cursor(text, cursor, 1)
	elseif ev.text ~= nil and ev.text ~= "" then
		return M.insert_at(text, cursor, ev.text)
	end
	return nil, nil
end

return M
