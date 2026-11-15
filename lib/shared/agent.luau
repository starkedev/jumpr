--!strict
-- Agent kinds: validates CLI and session names, builds launch commands and recognises default titles. Pure: no `tern`.

local Identity = require("./identity")

local M = {}

M.OMP = "omp"

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

-- True when a title is one of the exact defaults shown by a supported agent.
function M.is_default_title(title: string): boolean
	return DEFAULT_TITLES[title] == true
end

-- Builds a shell-safe omp or ACP launch command, or nil when a component is invalid.
function M.command(kind: string, id: string, mode: Mode, sid: string?): string?
	if not M.valid_kind(kind) or not Identity.valid_id(id) or not M.valid_mode(mode) then
		return nil
	end
	if kind == M.OMP then
		return "omp --continue --session-dir ~/.omp/deck/" .. id
	end

	local command = "env JUMPR_ID=" .. id .. " tern acp " .. kind
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
