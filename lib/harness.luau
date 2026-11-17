--!strict
-- `spinnerTitle` and `spinnerTitleSuffix` below are copied from agent-nav (https://github.com/Arcadia822/tern-agent-nav),
-- window.luau lines 1879-1901. Copyright (c) 2026 Arcadia. Licensed under the MIT licence; the full licence text is
-- in ./NOTICE. One change: `spinnerTitleSuffix` read the code point at the last byte, which is a continuation byte
-- for a braille frame, so it never matched; it now reads the last character's first byte (marked below).
-- Pure: no `tern`.

local agent = require("./shared/agent")

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

-- Claude Code's status glyphs, each shown before its title and a space (`✳ Claude Code` at start). Dingbats only:
-- omp's leading card icon is a private-use character, so it is never one of these.
local CLAUDE_GLYPHS: { string } = { "✳", "✢", "✶", "✻", "✽" }

-- The title without a leading Claude Code status glyph and the space after it; a glyph alone leaves nothing.
local function strip_claude_glyph(text: string): string
	for _, glyph in CLAUDE_GLYPHS do
		if
			string.sub(text, 1, #glyph) == glyph and (#text == #glyph or string.find(text, "^%s", #glyph + 1) ~= nil)
		then
			return trim(string.sub(text, #glyph + 1))
		end
	end
	return text
end

-- The title without Codex's approval prefix, `[ . ] Action Required | ` alternating with `[ ! ] Action Required | `,
-- so the label does not flip while Codex waits.
local function strip_action_required(text: string): string
	local rest = string.match(text, "^%[ [^%s%]] %] Action Required | (.*)$")
	if rest ~= nil then
		return trim(rest)
	end
	if string.find(text, "^%[ [^%s%]] %] Action Required$") ~= nil then
		return ""
	end
	return text
end

-- The title before its last ` | `: Codex shows `<thread title> | <folder>`, and a thread title may hold ` | ` itself.
local function strip_folder(text: string): string
	local last: number? = nil
	local from = 1
	while true do
		local at = string.find(text, " | ", from, true)
		if at == nil then
			break
		end
		last = at
		from = at + 1
	end
	if last == nil then
		return text
	end
	return trim(string.sub(text, 1, last - 1))
end

-- The stable part of a pane title, so a row's label does not flip with its agent's state: a leading or trailing
-- braille spinner frame, Codex's `Action Required` prefix and a leading Claude Code status glyph are removed, and for
-- codex (`kind`) the trailing ` | <folder>` too. Nil when what is left is empty or a default agent title, which for
-- codex includes the bare folder name it shows before a thread has a title (`agent.is_default_title`).
-- Without `kind` the folder part is kept: other agents' titles may hold ` | `.
-- A title that is not valid UTF-8 is only trimmed.
function M.clean_title(title: string?, kind: string?): string?
	if title == nil then
		return nil
	end
	local text = trim(title)
	if text ~= "" and utf8.len(text) ~= nil then
		local _, rest = spinnerTitle(text)
		text = strip_claude_glyph(strip_action_required(trim(rest or "")))
		if spinnerTitleSuffix(text) then
			text = trim(string.sub(text, 1, (utf8.offset(text, -1) :: number) - 1))
		end
	end
	if text == "" or agent.is_default_title(text, kind) then
		return nil
	end
	if kind == agent.CODEX then
		text = strip_folder(text)
		if text == "" then
			return nil
		end
	end
	return text
end

return M
