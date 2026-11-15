--!strict
-- Per-kind lookup of a live conversation id from that CLI's own session files.
-- Not pure: file reads and grep go through the `compat` argument, and this module never touches `tern`.

local Agent = require("../shared/agent")
local Identity = require("../shared/identity")

local M = {}

local CLAUDE = "claude"
local MAX_BYTES = 65536
local MAX_PROBES = 30
local WARN_LIST = "cannot list sessions"
local WARN_MISSING = "no sessions folder"
local WARN_READ = "cannot read session file"
local WARN_JSON = "bad session file"
local WARN_GREP = "cannot start grep"

-- The compat calls the lookup uses. `log_warn` is optional so a caller without it still type-checks;
-- the production compat has it, and each distinct reason is warned once.
export type Compat = {
	-- Entry names of a directory; nil and a reason when it cannot be listed (missing is nil, nil).
	fs_list: (path: string) -> ({ string }?, string?),
	fs_read: (path: string, max_bytes: number?) -> (string?, string?),
	json_decode: (text: string) -> (any, string?),
	-- Runs argv with no shell and calls back with the exit status, or nil when it could not start.
	-- The start result is ignored; a callback of nil is the failure.
	run_status: (argv: { string }, cb: (status: number?) -> ()) -> ...any,
	log_warn: ((text: string) -> ())?,
}

type Hit = { pid: string, sid: string }

local warned: { [string]: boolean } = {}

local function warn(compat: Compat, reason: string)
	if warned[reason] then
		return
	end
	warned[reason] = true
	local log_warn = compat.log_warn
	if log_warn == nil then
		return
	end
	pcall(function()
		log_warn("jumpr: session lookup: " .. reason)
	end)
end

local function sessions_dir(home: string): string
	if string.sub(home, -1) == "/" then
		return home .. ".claude/sessions"
	end
	return home .. "/.claude/sessions"
end

-- The pid is the digits in `<pid>.json`. Only those digits are put into a path.
local function pid_of(name: string): string?
	return string.match(name, "^(%d+)%.json$")
end

local function consider(
	compat: Compat,
	dir: string,
	name: string,
	cwd: string,
	taken: { [string]: boolean },
	same: { Hit },
	rest: { Hit }
)
	local pid = pid_of(name)
	if pid == nil then
		return
	end
	local text, read_err = compat.fs_read(dir .. "/" .. pid .. ".json", MAX_BYTES)
	if read_err ~= nil then
		warn(compat, WARN_READ)
		return
	end
	if text == nil then
		return
	end
	local raw, decode_err = compat.json_decode(text)
	if decode_err ~= nil or type(raw) ~= "table" then
		warn(compat, WARN_JSON)
		return
	end
	local fields: any = raw
	local sid = fields.sessionId
	if type(sid) ~= "string" then
		return
	end
	if not Agent.valid_session(sid) or taken[sid] == true then
		return
	end
	local hit: Hit = { pid = pid, sid = sid }
	local file_cwd = fields.cwd
	if type(file_cwd) == "string" and file_cwd == cwd then
		same[#same + 1] = hit
	else
		rest[#rest + 1] = hit
	end
end

-- Same folder first, then every other folder, and at most 30 probes in all.
local function probe_queue(same: { Hit }, rest: { Hit }): { Hit }
	local queue: { Hit } = {}
	for _, hit in same do
		if #queue >= MAX_PROBES then
			return queue
		end
		queue[#queue + 1] = hit
	end
	for _, hit in rest do
		if #queue >= MAX_PROBES then
			return queue
		end
		queue[#queue + 1] = hit
	end
	return queue
end

-- True when Jumpr can look up conversations for this kind. Today that is Claude Code only.
function M.has(kind: string): boolean
	return kind == CLAUDE
end

-- Looks for the live conversation of agent `id` and calls back once with its id, or nil when none is proven.
-- `cwd` only orders the search. The proof is a quiet grep for `JUMPR_ID=<id>` in that process's environment.
function M.find(
	compat: Compat,
	home: string,
	kind: string,
	id: string,
	cwd: string,
	taken: { [string]: boolean },
	cb: (sid: string?) -> ()
)
	if not M.has(kind) or not Identity.valid_id(id) then
		cb(nil)
		return
	end

	local dir = sessions_dir(home)
	local names, list_err = compat.fs_list(dir)
	if names == nil then
		warn(compat, if list_err ~= nil then WARN_LIST else WARN_MISSING)
		cb(nil)
		return
	end

	local same: { Hit } = {}
	local rest: { Hit } = {}
	for _, name in names do
		consider(compat, dir, name, cwd, taken, same, rest)
	end
	local queue = probe_queue(same, rest)
	if #queue == 0 then
		cb(nil)
		return
	end

	local answered = false
	local function finish(sid: string?)
		if answered then
			return
		end
		answered = true
		cb(sid)
	end

	local function prove(at: number)
		if answered then
			return
		end
		if at > #queue then
			finish(nil)
			return
		end
		local hit = queue[at] :: Hit
		-- `-q` answers yes or no. The plugin never reads the process environment.
		local argv = { "grep", "-q", "-z", "-x", "JUMPR_ID=" .. id, "/proc/" .. hit.pid .. "/environ" }
		compat.run_status(argv, function(status: number?)
			if answered then
				return
			end
			if status == nil then
				warn(compat, WARN_GREP)
				finish(nil)
				return
			end
			if status == 0 then
				finish(hit.sid)
				return
			end
			prove(at + 1)
		end)
	end

	prove(1)
end

return M
