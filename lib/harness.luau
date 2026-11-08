--!strict
-- `spinnerTitle` and `spinnerTitleSuffix` below are copied from agent-nav (https://github.com/Arcadia822/tern-agent-nav),
-- window.luau lines 1879-1901. Copyright (c) 2026 Arcadia. Licensed under the MIT licence; the full licence text is
-- in ./NOTICE. One change: `spinnerTitleSuffix` read the code point at the last byte, which is a continuation byte
-- for a braille frame, so it never matched; it now reads the last character's first byte (marked below).
-- Pure: no `tern`.

local M = {}

-- Begin copied from agent-nav window.luau lines 1879-1901.
-- Terminal agents that never report `busy` (Codex) mark a working turn with a
-- braille spinner frame (U+2800..U+28FF) at the start of their title.
local function spinnerTitle(title: string?): (boolean, string?)
	if type(title) ~= "string" then
		return false, title
	end
	local first = utf8.codepoint(title, 1, 1)
	if first and first >= 0x2800 and first <= 0x28FF then
		local rest = string.match(string.sub(title, utf8.offset(title, 2) or (#title + 1)), "^%s*(.-)$")
		return true, rest
	end
	return false, title
end
-- Codex appends a braille spinner frame to its title while a turn runs
-- ("task · dir · ⠼") instead of a leading frame.
local function spinnerTitleSuffix(title: string?): boolean
	if type(title) ~= "string" or title == "" then
		return false
	end
	-- The last character can be multi-byte; codepoint at a continuation byte errors.
	-- Jumpr's change: start at the last character's first byte (`utf8.offset(title, -1)`), not at `#title`.
	local ok, last = pcall(utf8.codepoint, title, utf8.offset(title, -1) or #title)
	return ok and last ~= nil and last >= 0x2800 and last <= 0x28FF
end
-- End copied from agent-nav.

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

-- The pane title with a leading or trailing braille spinner frame removed; nil when what is left is empty or "omp".
-- A title that is not valid UTF-8 is only trimmed.
function M.clean_title(title: string?): string?
	if title == nil then
		return nil
	end
	local text = trim(title)
	if text ~= "" and utf8.len(text) ~= nil then
		local _, rest = spinnerTitle(text)
		text = trim(rest or "")
		if spinnerTitleSuffix(text) then
			text = trim(string.sub(text, 1, (utf8.offset(text, -1) :: number) - 1))
		end
	end
	if text == "" or text == "omp" then
		return nil
	end
	return text
end

return M
