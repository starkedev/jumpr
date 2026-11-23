--!strict
-- Agent kinds: validates CLI and session names, builds omp, Claude Code CLI, Codex CLI and ACP launch commands and
-- omp's first-start argv, maps launch lines to their reopen form and recognises default titles. Pure: no `tern`.

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

-- The Claude Code CLI line. `new` and `resume` both open the Jumpr-owned session uuid: the line checks for that
-- conversation's transcript (`<config>/projects/<folder>/<uuid>.jsonl`, written at its first prompt, in any folder)
-- before running anything, then resumes it if it exists or creates it under that uuid if not. `<config>` is Claude's
-- own config folder, `$CLAUDE_CONFIG_DIR` when set and `~/.claude` otherwise, expanded by the line's `sh` so the check
-- looks where the `claude` it runs writes. Deciding first means a fresh agent never runs a resume that must fail
-- (Claude prints "No conversation found" for one), and `exec` keeps `claude` the pane shell's direct child. The quoted
-- part holds only constant words and the validated uuid.
local function claude_command(prefix: string, mode: Mode, sid: string?): string?
	if mode == "new" or mode == "resume" then
		if sid == nil or not Identity.valid_uuid(sid) then
			return nil
		end
		return prefix
			.. "sh -c 'if ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/"
			.. sid
			.. ".jsonl >/dev/null 2>&1; then exec claude --resume "
			.. sid
			.. "; else exec claude --session-id "
			.. sid
			.. "; fi'"
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

-- True when a path is absolute and made only of alphanumerics, `_`, `-`, `.` and `/`, with every segment non-empty
-- (no `//` and no trailing `/`), none of them `.` or `..`, and none starting with `-`, so it is one shell word and
-- never a flag.
local function safe_path(path: string): boolean
	if string.find(path, "^/[%w_%-./]+$") == nil then
		return false
	end
	for _, segment in string.split(string.sub(path, 2), "/") do
		if segment == "" or segment == "." or segment == ".." or string.sub(segment, 1, 1) == "-" then
			return false
		end
	end
	return true
end

-- True for a first-message file omp can be handed as `@<path>`: an absolute path of shell-safe segments (no spaces,
-- quotes, `..` or leading `-`).
function M.valid_prompt_file(path: string): boolean
	return safe_path(path)
end

-- The argv that starts a new omp agent in its deck folder `<home>/.omp/deck/<id>`, sending `prompt_file` as its first
-- message when given. No `--continue`: the folder is new. Nil when the id, the home folder or the file is unsafe.
function M.first_argv(id: string, home: string, prompt_file: string?): { string }?
	if not Identity.valid_id(id) or not safe_path(home) then
		return nil
	end
	local argv = { "omp", "--session-dir", home .. "/.omp/deck/" .. id }
	if prompt_file ~= nil then
		if not M.valid_prompt_file(prompt_file) then
			return nil
		end
		table.insert(argv, "@" .. prompt_file)
	end
	return argv
end

-- The deck folder of a first-start line, `omp --session-dir <home>/.omp/deck/<id>` and at most one `@<file>` word
-- (whole word optionally in single or double quotes), or nil for any other shape.
local function first_start_deck(command: string): string?
	local rest = string.match(command, "^omp %-%-session%-dir (.+)$")
	if rest == nil then
		return nil
	end
	local words = string.split(rest, " ")
	local deck = words[1]
	local id = string.match(deck, "/%.omp/deck/([^/]+)$")
	if #words > 2 or not safe_path(deck) or id == nil or not Identity.valid_id(id) then
		return nil
	end
	local prompt = words[2]
	if prompt ~= nil then
		local first = string.sub(prompt, 1, 1)
		if #prompt >= 2 and (first == "'" or first == '"') and string.sub(prompt, -1) == first then
			prompt = string.sub(prompt, 2, -2)
		end
		if string.sub(prompt, 1, 1) ~= "@" or not M.valid_prompt_file(string.sub(prompt, 2)) then
			return nil
		end
	end
	return deck
end

-- The command a reopened omp agent runs before Tern adds `--restore`, `--resume` or `--fork` and its session file:
-- Jumpr's own launch line without `--continue`, which omp refuses beside a named session, or a first-start line from
-- `first_argv` without its `@<file>`, which omp refuses beside `--restore` and which must not be sent twice. Nil for
-- any other command, so a line Jumpr did not write reaches omp as it was.
function M.reopen_command(command: string): string?
	local id = string.match(command, "^omp %-%-continue %-%-session%-dir ~/%.omp/deck/([%w_%-]+)$")
	if id ~= nil and M.command(M.OMP, id, "new") == command then
		return "omp --session-dir ~/.omp/deck/" .. id
	end
	local deck = first_start_deck(command)
	if deck == nil then
		return nil
	end
	return "omp --session-dir " .. deck
end

return M
