--!strict
-- Agent kinds: validates CLI and session names, builds omp, Claude Code CLI, Codex CLI and ACP launch commands and
-- recognises default titles. Pure: no `tern`.

local Identity = require("./identity")

local M = {}

M.OMP = "omp"
M.CLAUDE = "claude"
M.CODEX = "codex"

export type Mode = "new" | "resume" | "continue" | "pick"

local MAX_KIND_LENGTH = 32
local MAX_SESSION_LENGTH = 64
local MODES: { [string]: boolean } = {
	new = true,
	resume = true,
	["continue"] = true,
	pick = true,
}
local DEFAULT_TITLES: { [string]: boolean } = {
	omp = true,
	["Claude Code"] = true,
	Codex = true,
	["GitHub Copilot"] = true,
}

-- The agents Jumpr offers by name, in the settings page's Default agent menu and the `N` picker.
local COMMON: { string } = { M.OMP, M.CLAUDE, M.CODEX, "copilot" }

-- True when the kind is 1 to 32 characters, starts alphanumeric and contains only alphanumerics, `_` or `-`.
function M.valid_kind(kind: string): boolean
	return #kind >= 1 and #kind <= MAX_KIND_LENGTH and string.find(kind, "^[%w][%w_%-]*$") ~= nil
end

-- True when the session id is 1 to 64 characters, starts alphanumeric and contains only alphanumerics, `_` or `-`.
function M.valid_session(sid: string): boolean
	return #sid >= 1 and #sid <= MAX_SESSION_LENGTH and string.find(sid, "^[%w][%w_%-]*$") ~= nil
end

-- True for one of the four supported launch modes.
function M.valid_mode(mode: string): boolean
	return MODES[mode] == true
end

-- The name shown before an agent supplies its own title.
function M.name(kind: string): string
	if kind == M.OMP then
		return "omp"
	end
	return kind
end

-- True when a title is one of the exact defaults shown by a supported agent. For codex (`kind`), a title with no
-- ` | ` is also a default: Codex shows only its folder name until a thread has a title, then `<title> | <folder>`.
function M.is_default_title(title: string, kind: string?): boolean
	if DEFAULT_TITLES[title] == true then
		return true
	end
	return kind == M.CODEX and title ~= "" and string.find(title, " | ", 1, true) == nil
end

-- True for the kinds Jumpr runs as their real CLI in a terminal pane rather than through Tern's ACP chat.
function M.is_cli(kind: string): boolean
	return kind == M.CLAUDE or kind == M.CODEX
end

-- The agents to choose from: the common ones, then `current` (the default agent) when it is none of them.
function M.options(current: string): { string }
	local options = table.clone(COMMON)
	if table.find(options, current) == nil then
		table.insert(options, current)
	end
	return options
end

-- The Claude Code CLI line. `new` and `resume` both resume the Jumpr-owned session uuid, or create it under that
-- uuid when it does not exist yet; the quoted part holds only constant words and the validated uuid.
local function claude_command(prefix: string, mode: Mode, sid: string?): string?
	if mode == "new" or mode == "resume" then
		if sid == nil or not Identity.valid_uuid(sid) then
			return nil
		end
		return prefix .. "sh -c 'claude --resume " .. sid .. " || claude --session-id " .. sid .. "'"
	elseif mode == "pick" then
		return prefix .. "claude --resume"
	end
	-- `continue` would pick the newest session in the folder, which may belong to another agent.
	return nil
end

-- The Codex CLI line. Codex assigns its own thread id, so `new` starts fresh and `resume` needs the recorded uuid.
local function codex_command(prefix: string, mode: Mode, sid: string?): string?
	if mode == "new" then
		return prefix .. "codex"
	elseif mode == "resume" then
		if sid == nil or not Identity.valid_uuid(sid) then
			return nil
		end
		return prefix .. "codex resume " .. sid
	elseif mode == "pick" then
		return prefix .. "codex resume"
	end
	-- `continue` would pick the newest thread in the folder, which may belong to another agent.
	return nil
end

-- Builds a shell-safe omp, Claude Code CLI, Codex CLI or ACP launch command, or nil when a component is invalid or
-- the kind has no such mode.
function M.command(kind: string, id: string, mode: Mode, sid: string?): string?
	if not M.valid_kind(kind) or not Identity.valid_id(id) or not M.valid_mode(mode) then
		return nil
	end
	if kind == M.OMP then
		return "omp --continue --session-dir ~/.omp/deck/" .. id
	end

	local prefix = "env JUMPR_ID=" .. id .. " "
	if kind == M.CLAUDE then
		return claude_command(prefix, mode, sid)
	elseif kind == M.CODEX then
		return codex_command(prefix, mode, sid)
	end

	local command = prefix .. "tern acp " .. kind
	if mode == "new" then
		return command
	elseif mode == "resume" then
		if sid == nil or not M.valid_session(sid) then
			return nil
		end
		return command .. " --resume " .. sid
	elseif mode == "continue" then
		return command .. " --continue"
	end
	return command .. " --sessions"
end

return M
