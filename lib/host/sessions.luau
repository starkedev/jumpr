--!strict
-- Per-kind lookup of a live conversation id from that CLI's own files: a Claude Code conversation by its process, a
-- Codex thread by its rollout file.
-- Not pure: file reads, listings and processes go through the `compat` argument, and this module never touches `tern`.

local Identity = require("../shared/identity")

local M = {}

local CLAUDE = "claude"
local MAX_BYTES = 65536
local MAX_PROBES = 30
-- `/proc/<pid>/stat` is one line of a few hundred bytes, `/proc/<pid>/comm` at most 16.
local STAT_BYTES = 4096
local COMM_BYTES = 64
-- How many ancestors of a `claude` are walked to prove it is the pane's own. Its launch line puts at most `sh` between
-- it and the pane shell, so a longer chain of processes carrying the agent's id proves nothing.
local MAX_ANCESTORS = 8
local WARN_LIST = "cannot list sessions"
local WARN_MISSING = "no sessions folder"
local WARN_READ = "cannot read session file"
local WARN_JSON = "bad session file"
local WARN_GREP = "cannot start grep"

local CODEX = "codex"
-- A Codex thread is stamped when it starts, once Codex's startup screens (an update offer, the folder-trust dialog)
-- are passed, and its rollout file appears at its first prompt. A thread that started from a minute before its agent's
-- start was asked for to ten minutes after can be that agent's.
local EARLY_MS = 60 * 1000
local LATE_MS = 10 * 60 * 1000
local MINUTE_MS = 60 * 1000
local DAY_MS = 24 * 60 * 60 * 1000
-- Codex files a rollout under its thread's start date in local time (UTC when it cannot tell the zone). The zone is not
-- known here, so every date that start can have anywhere is listed: local clocks run from 12 h behind UTC to 14 h
-- ahead. The folders run up to today's, at most eight days of them from the start's own date.
local WEST_MS = 12 * 60 * 60 * 1000
local EAST_MS = 14 * 60 * 60 * 1000
local MAX_DAYS = 8
-- A thread id is a UUID v7, whose first 48 bits are its start in epoch ms: a rollout whose name says its thread started
-- more than this outside the window is never read.
local NAME_SLACK_MS = 60 * 1000
-- At most this many rollouts are read in one lookup. With more to read it proves nothing: one it did not read could be
-- a second candidate.
local MAX_THREADS = 30
-- Line 1 of a rollout is its `session_meta` record, about 22 KB (Codex's instructions fill it), with the thread's id,
-- start and folder in its first 600 bytes or so: this much of it is read, and nothing after it.
local HEAD_BYTES = 2048
-- Starts each file in a reader's answer; JSON text never holds this byte.
local MARK = "\030"
-- Codex's UTC stamp: `YYYY-MM-DDTHH:MM:SS`, an optional fraction, then `Z`.
local STAMP = "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(%.?%d*)Z$"
-- A rollout's name: `rollout-`, its thread's local start to the second, its thread id, `.jsonl`.
local ROLLOUT_NAME = "^rollout%-%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%d%-(.+)%.jsonl$"
local WARN_ROLLOUT_LIST = "cannot list codex sessions"
local WARN_ROLLOUT_READ = "cannot read codex rollouts"
local WARN_ROLLOUT_BAD = "bad codex rollout file"
local WARN_ROLLOUT_MANY = "too many codex threads to tell apart"

-- Prints, for each rollout named after the byte count ($1), the mark, `-`, a space and its path on one line, then the
-- start of its first line: at most $1 bytes, and nothing after that line, so no conversation text is read. A file that
-- cannot be read gives its mark line alone.
local READ_SCRIPT = [[n=$1
shift
for f do
	printf '\036- %s\n' "$f"
	head -c "$n" "$f" 2>/dev/null | head -n 1
done
exit 0]]

-- Searches the sessions folder ($1) for rollouts modified in the last $2 minutes, at most $3 of them, and prints each
-- as READ_SCRIPT does ($4 bytes) with its modification time (epoch seconds) in place of the `-`. `-mmin` counts whole
-- minutes, so the caller keeps only those written at or after the restart. `stat -c` is GNU's and busybox's, `stat -f`
-- the BSDs' and macOS's.
local FIND_SCRIPT = [[find "$1" -type f -name 'rollout-*.jsonl' -mmin "-$2" 2>/dev/null |
	head -n "$3" |
	while IFS= read -r f; do
		t=$( { stat -c %Y "$f" || stat -f %m "$f"; } 2>/dev/null ) || continue
		printf '\036%s %s\n' "$t" "$f"
		head -c "$4" "$f" 2>/dev/null | head -n 1
	done
exit 0]]

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
	-- Runs argv and calls back once with its stdout, or nil when it failed, timed out or could not start.
	-- The start result is ignored; a callback of nil is the failure.
	run_output: (argv: { string }, cb: (stdout: string?) -> ()) -> ...any,
	log_warn: ((text: string) -> ())?,
}

-- A proven conversation: its id `sid`, held by the pane's own `claude`, process `pid`, which started at `start` (the
-- start time in `/proc/<pid>/stat`, which tells that process from a later one given the same pid).
export type Proof = { sid: string, pid: string, start: string }

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

-- The fields of the session file of `pid` (digits only), or nil: no file, or one that cannot be read or decoded
-- (warned once per reason).
local function session_file(compat: Compat, dir: string, pid: string): any?
	local text, read_err = compat.fs_read(dir .. "/" .. pid .. ".json", MAX_BYTES)
	if read_err ~= nil then
		warn(compat, WARN_READ)
		return nil
	end
	if text == nil then
		return nil
	end
	local raw, decode_err = compat.json_decode(text)
	if decode_err ~= nil or type(raw) ~= "table" then
		warn(compat, WARN_JSON)
		return nil
	end
	return raw
end

-- The conversation id in a session file's fields when it is a uuid, the only shape Claude Code's launch line takes.
local function sid_in(fields: any): string?
	local sid = fields.sessionId
	if type(sid) ~= "string" or not Identity.valid_uuid(sid) then
		return nil
	end
	return sid
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
	local fields = session_file(compat, dir, pid)
	if fields == nil then
		return
	end
	local sid = sid_in(fields)
	if sid == nil or taken[sid] == true then
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

-- A process's parent pid and start time, from `/proc/<pid>/stat` (never its environment); nil when the process is
-- gone or the line does not read. The name in that line is in parentheses and may hold spaces or `)`, so the fields
-- are counted after its last `)`: the 2nd is the parent pid, the 20th the start time.
local function stat_of(compat: Compat, pid: string): (string?, string?)
	local text = compat.fs_read("/proc/" .. pid .. "/stat", STAT_BYTES)
	if text == nil then
		return nil, nil
	end
	local rest = string.match(text, "^.*%)%s+(.*)$")
	if rest == nil then
		return nil, nil
	end
	local parent: string? = nil
	local start: string? = nil
	local n = 0
	for field in string.gmatch(rest, "%S+") do
		n += 1
		if n == 2 then
			parent = field
		elseif n == 20 then
			start = field
			break
		end
	end
	if parent == nil or start == nil or string.find(parent, "^%d+$") == nil or string.find(start, "^%d+$") == nil then
		return nil, nil
	end
	return parent, start
end

-- A process's name, from `/proc/<pid>/comm` without its newline; nil when the process is gone.
local function name_of(compat: Compat, pid: string): string?
	local text = compat.fs_read("/proc/" .. pid .. "/comm", COMM_BYTES)
	if text == nil then
		return nil
	end
	return (string.gsub(text, "%s+$", ""))
end

-- Asks grep whether process `pid`'s environment holds exactly `JUMPR_ID=<id>`; `cb` gets its exit status (0: it
-- does) or nil when grep could not start. `-q` answers yes or no: the plugin never reads the environment.
local function carries(compat: Compat, id: string, pid: string, cb: (status: number?) -> ())
	compat.run_status({ "grep", "-q", "-z", "-x", "JUMPR_ID=" .. id, "/proc/" .. pid .. "/environ" }, cb)
end

-- Proves that `pid`, a process carrying the agent's `JUMPR_ID`, is the pane's own `claude`: no other process named
-- `claude` is among its ancestors up to the first one without that `JUMPR_ID`. On a resume its parent is the launch
-- line's `sh`; on a fresh start `sh` has exec'd it, so its parent is the pane shell. A `claude` the agent started
-- itself (claude → bash → claude) has the agent's `claude` above it, so it never counts. `cb` gets the process's
-- start time when it is proven, else nil: also when a process on the way cannot be read, or the walk passes
-- MAX_ANCESTORS. Nil also when grep cannot start, which is warned.
local function own_claude(compat: Compat, id: string, pid: string, cb: (start: string?) -> ())
	local parent, start = stat_of(compat, pid)
	if parent == nil or start == nil then
		cb(nil)
		return
	end
	local function climb(ancestor: string, depth: number)
		-- Pid 0 is no process: nothing above this one carries the id.
		if ancestor == "0" then
			cb(start)
			return
		end
		if depth > MAX_ANCESTORS then
			cb(nil)
			return
		end
		carries(compat, id, ancestor, function(status: number?)
			if status == nil then
				warn(compat, WARN_GREP)
				cb(nil)
				return
			end
			-- The first ancestor without the agent's id (the pane shell, or one above it) ends the agent's processes.
			if status ~= 0 then
				cb(start)
				return
			end
			local name = name_of(compat, ancestor)
			if name == nil or name == CLAUDE then
				cb(nil)
				return
			end
			local above = stat_of(compat, ancestor)
			if above == nil then
				cb(nil)
				return
			end
			climb(above, depth + 1)
		end)
	end
	climb(parent, 1)
end

-- True when Jumpr can look up conversations for this kind: Claude Code's (`find`) and Codex's threads (`find_thread`).
function M.has(kind: string): boolean
	return kind == CLAUDE or kind == CODEX
end

-- Looks for the live conversation of claude agent `id` and calls back once with its proof, or nil when none is proven;
-- any other kind gets nil at once (a codex agent's thread is `find_thread`'s). `cwd` only orders the search; a
-- conversation another record holds (`taken`) is never a candidate. A candidate's process must carry `JUMPR_ID=<id>`
-- (a quiet grep of its environment) and be the pane's own `claude` (`own_claude`), so a `claude` the agent ran itself
-- never gives its conversation.
function M.find(
	compat: Compat,
	home: string,
	kind: string,
	id: string,
	cwd: string,
	taken: { [string]: boolean },
	cb: (proof: Proof?) -> ()
)
	if kind ~= CLAUDE or not Identity.valid_id(id) then
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
	local function finish(proof: Proof?)
		if answered then
			return
		end
		answered = true
		cb(proof)
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
		carries(compat, id, hit.pid, function(status: number?)
			if answered then
				return
			end
			if status == nil then
				warn(compat, WARN_GREP)
				finish(nil)
				return
			end
			if status ~= 0 then
				prove(at + 1)
				return
			end
			own_claude(compat, id, hit.pid, function(start: string?)
				if answered then
					return
				end
				if start == nil then
					prove(at + 1)
					return
				end
				finish({ sid = hit.sid, pid = hit.pid, start = start })
			end)
		end)
	end

	prove(1)
end

-- The conversation the proven `claude` holds now, read again from its session file: `/clear` and a resume inside
-- claude change it while the process lives on. No grep runs: `find` proved the process, and its start time says it
-- is still that one. Nil when it is gone (no such pid, or the pid is another process now) or its session file is gone
-- or holds no usable id; the caller then looks the agent up again with `find`.
function M.current(compat: Compat, home: string, proof: Proof): string?
	if string.find(proof.pid, "^%d+$") == nil then
		return nil
	end
	local _, start = stat_of(compat, proof.pid)
	if start == nil or start ~= proof.start then
		return nil
	end
	local fields = session_file(compat, sessions_dir(home), proof.pid)
	return if fields ~= nil then sid_in(fields) else nil
end

-- Codex threads ------------------------------------------------------------------------------------------------------

-- Another codex agent in the same folder that holds no thread yet: when its latest start was asked for and, once it
-- ended, when (epoch ms). A thread that started in its window, before it ended, may be its own.
export type Rival = { created_ms: number, ended_ms: number? }

-- One codex agent's lookup: its folder; when its latest start was asked for and the wall clock now (epoch ms); whether
-- that start opened Codex's resume picker (`codex resume` with no id) rather than starting a new thread; the threads
-- other records hold; and the other codex agents in its folder that hold none.
export type Ask = {
	cwd: string,
	created_ms: number,
	now_ms: number,
	picked: boolean,
	taken: { [string]: boolean },
	rivals: { Rival },
}

-- What line 1 of a rollout says of its thread: its id, when it started (epoch ms) and its folder.
type Meta = { id: string, start_ms: number, cwd: string }

local function codex_dir(home: string): string
	if string.sub(home, -1) == "/" then
		return home .. ".codex/sessions"
	end
	return home .. "/.codex/sessions"
end

-- Days from 1970-01-01 to a proleptic Gregorian date, in integers only.
local function days_from_civil(y: number, m: number, d: number): number
	local year = if m <= 2 then y - 1 else y
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (if m > 2 then m - 3 else m + 9) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- The proleptic Gregorian date `days` after 1970-01-01, as year, month and day.
local function civil_from_days(days: number): (number, number, number)
	local z = days + 719468
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return yoe + era * 400 + (if m <= 2 then 1 else 0), m, d
end

-- Epoch ms of a Codex stamp, or nil when it is not one; a fraction is kept to the millisecond.
local function stamp_ms(text: string): number?
	local parts = { string.match(text, STAMP) }
	if #parts ~= 7 then
		return nil
	end
	local frac = parts[7]
	if frac ~= "" and string.find(frac, "^%.%d+$") == nil then
		return nil
	end
	local y = tonumber(parts[1]) :: number
	local mo = tonumber(parts[2]) :: number
	local d = tonumber(parts[3]) :: number
	local h = tonumber(parts[4]) :: number
	local mi = tonumber(parts[5]) :: number
	local s = tonumber(parts[6]) :: number
	if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then
		return nil
	end
	local ms = if frac == "" then 0 else tonumber(string.sub(frac .. "00", 2, 4)) :: number
	return (((days_from_civil(y, mo, d) * 24 + h) * 60 + mi) * 60 + s) * 1000 + ms
end

-- The thread id a rollout's name carries when it is a name Codex writes, else nil, so no other name ever becomes a
-- path the lookup reads.
local function thread_of(name: string): string?
	local id = string.match(name, ROLLOUT_NAME)
	if id == nil or not Identity.valid_uuid(id) then
		return nil
	end
	return id
end

-- When a UUID v7 thread id says its thread started (epoch ms, its first 48 bits); nil for another version.
local function v7_ms(id: string): number?
	if string.sub(id, 15, 15) ~= "7" then
		return nil
	end
	return tonumber(string.sub(id, 1, 8) .. string.sub(id, 10, 13), 16)
end

-- The index of the first character at or after `i` that is not JSON whitespace.
local function skip_space(text: string, i: number): number
	local _, last = string.find(text, "^[ \t\r\n]*", i)
	return if last ~= nil then last + 1 else i
end

-- The JSON string that opens at `i` (its quote): its text, or nil when it holds an escape, and the index after its
-- closing quote, which is nil when the head ends inside it. No value the lookup needs is written with an escape: an id,
-- a stamp, and an agent's folder (`Identity.valid_cwd`).
local function json_string(text: string, i: number): (string?, number?)
	local at = i + 1
	local escaped = false
	while true do
		local q = string.find(text, '["\\]', at)
		if q == nil then
			return nil, nil
		end
		if string.sub(text, q, q) == '"' then
			return if escaped then nil else string.sub(text, i + 1, q - 1), q + 1
		end
		escaped = true
		at = q + 2
	end
end

-- The text of the JSON string value at `at`; nil when the value there is not a string or holds an escape.
local function string_at(text: string, at: number): string?
	if string.sub(text, at, at) ~= '"' then
		return nil
	end
	return (json_string(text, at))
end

-- The index after the JSON value that starts at `i`, or nil when the head ends inside it. Strings, objects and arrays
-- are walked; any other value runs to the next `,`, `}` or `]`.
local function skip_value(text: string, i: number): number?
	local c = string.sub(text, i, i)
	if c == '"' then
		local _, after = json_string(text, i)
		return after
	end
	if c == "{" or c == "[" then
		local depth = 0
		local at = i
		while true do
			local p = string.find(text, '[%[%]{}"]', at)
			if p == nil then
				return nil
			end
			local ch = string.sub(text, p, p)
			if ch == '"' then
				local _, after = json_string(text, p)
				if after == nil then
					return nil
				end
				at = after
			else
				depth += if ch == "{" or ch == "[" then 1 else -1
				at = p + 1
				if depth == 0 then
					return at
				end
			end
		end
	end
	local stop = string.find(text, "[,}%]]", i)
	if stop == nil or stop == i then
		return nil
	end
	return stop
end

-- Walks the members of the JSON object that opens at `i` (its brace) in a head that may end anywhere: `visit` gets each
-- member's name and the index its value starts at, and returns true to stop there. A nested object's members are never
-- visited. The walk also stops where the object or the head ends, or the text is not JSON.
local function walk(text: string, i: number, visit: (name: string, at: number) -> boolean)
	local at = skip_space(text, i + 1)
	while string.sub(text, at, at) == '"' do
		local name, after = json_string(text, at)
		if after == nil then
			return
		end
		at = skip_space(text, after)
		if string.sub(text, at, at) ~= ":" then
			return
		end
		at = skip_space(text, at + 1)
		if name ~= nil and visit(name, at) then
			return
		end
		local past = skip_value(text, at)
		if past == nil then
			return
		end
		at = skip_space(text, past)
		if string.sub(text, at, at) ~= "," then
			return
		end
		at = skip_space(text, at + 1)
	end
end

-- The thread a rollout's head describes, or nil when the head is not that of a `session_meta` line: its `type`, read
-- before its `payload` object, whose own `id`, `timestamp` and `cwd` (never a nested object's) are strings without
-- escapes, the id a uuid and the stamp a UTC one. The head may end anywhere after them.
local function meta_of(head: string): Meta?
	if string.sub(head, 1, 1) ~= "{" then
		return nil
	end
	local kind: string? = nil
	local payload: number? = nil
	walk(head, 1, function(name: string, at: number): boolean
		if name == "type" then
			kind = string_at(head, at)
		elseif name == "payload" then
			payload = at
			return true
		end
		return false
	end)
	local open = payload
	if kind ~= "session_meta" or open == nil or string.sub(head, open, open) ~= "{" then
		return nil
	end
	local id: string?, stamp: string?, cwd: string? = nil, nil, nil
	local broken = false
	walk(head, open, function(name: string, at: number): boolean
		if name == "id" or name == "timestamp" or name == "cwd" then
			local value = string_at(head, at)
			if value == nil then
				broken = true
				return true
			end
			if name == "id" then
				id = id or value
			elseif name == "timestamp" then
				stamp = stamp or value
			else
				cwd = cwd or value
			end
		end
		return id ~= nil and stamp ~= nil and cwd ~= nil
	end)
	if broken or id == nil or stamp == nil or cwd == nil or not Identity.valid_uuid(id) then
		return nil
	end
	local start = stamp_ms(stamp)
	if start == nil then
		return nil
	end
	return { id = id, start_ms = start, cwd = cwd }
end

-- The date folders a new thread of this start can be filed under: from the earliest date its start can have in any
-- zone to the latest date today can have, but at most MAX_DAYS days on from the start's own date.
local function date_folders(root: string, ask: Ask): { string }
	local first = (ask.created_ms - EARLY_MS - WEST_MS) // DAY_MS
	local last = math.min((ask.now_ms + EAST_MS) // DAY_MS, (ask.created_ms + EAST_MS) // DAY_MS + MAX_DAYS - 1)
	local out: { string } = {}
	for day = first, last do
		local y, m, d = civil_from_days(day)
		out[#out + 1] = string.format("%s/%04d/%02d/%02d", root, y, m, d)
	end
	return out
end

-- The rollouts a new thread of this start can be, path to thread id: every Codex rollout name in its date folders
-- whose thread no other record holds and whose id, when a UUID v7, did not start well outside the window. A missing
-- folder holds none; one that cannot be listed is warned. Nil when there are more than MAX_THREADS.
local function in_window(compat: Compat, root: string, ask: Ask): { [string]: string }?
	local lo = ask.created_ms - EARLY_MS - NAME_SLACK_MS
	local hi = ask.created_ms + LATE_MS + NAME_SLACK_MS
	local out: { [string]: string } = {}
	local count = 0
	for _, dir in date_folders(root, ask) do
		local names, err = compat.fs_list(dir)
		if names == nil then
			if err ~= nil then
				warn(compat, WARN_ROLLOUT_LIST)
			end
		else
			for _, name in names do
				local id = thread_of(name)
				local born = if id ~= nil then v7_ms(id) else nil
				if id ~= nil and ask.taken[id] ~= true and (born == nil or (born >= lo and born <= hi)) then
					out[dir .. "/" .. name] = id
					count += 1
				end
			end
		end
	end
	if count > MAX_THREADS then
		warn(compat, WARN_ROLLOUT_MANY)
		return nil
	end
	return out
end

-- The thread id of a path the picker's search printed: a Codex rollout name in a date folder of the sessions folder.
local function searched_thread(root: string, path: string): string?
	local prefix = root .. "/"
	if string.sub(path, 1, #prefix) ~= prefix then
		return nil
	end
	local name = string.match(string.sub(path, #prefix + 1), "^%d%d%d%d/%d%d/%d%d/([^/]+)$")
	if name == nil then
		return nil
	end
	return thread_of(name)
end

-- The thread id of a file the reader printed, when this lookup may count it: one it named (`asked`), printed with no
-- time, or, for a picked thread, a rollout the search found that was modified at or after the restart (`stamp`, in
-- epoch seconds) and that no other record holds.
local function rollout_id(root: string, ask: Ask, asked: { [string]: string }?, stamp: string, path: string): string?
	if asked ~= nil then
		return if stamp == "-" then asked[path] else nil
	end
	if string.find(stamp, "^%d+$") == nil or (tonumber(stamp) :: number) * 1000 < ask.created_ms then
		return nil
	end
	local id = searched_thread(root, path)
	if id == nil or ask.taken[id] == true then
		return nil
	end
	return id
end

-- True when a thread that started at `start_ms` started in the window of another codex agent in the folder that holds
-- no thread, before that agent ended: it may be that agent's.
local function contested(ask: Ask, start_ms: number): boolean
	for _, rival in ask.rivals do
		local last = rival.created_ms + LATE_MS
		local ended = rival.ended_ms
		if ended ~= nil and ended < last then
			last = ended
		end
		if start_ms >= rival.created_ms - EARLY_MS and start_ms <= last then
			return true
		end
	end
	return false
end

-- Whether the rollout of thread `id` (one no other record holds), by its head, is a candidate: the `session_meta` line
-- of that very thread, in the agent's folder and not started in a rival's window; a new thread must also have started
-- in this start's window. A head that is not that thread's `session_meta` line is warned once.
local function counts(compat: Compat, ask: Ask, id: string, head: string): boolean
	local meta = meta_of(head)
	if meta == nil or meta.id ~= id then
		if head ~= "" then
			warn(compat, WARN_ROLLOUT_BAD)
		end
		return false
	end
	if meta.cwd ~= ask.cwd or contested(ask, meta.start_ms) then
		return false
	end
	return ask.picked or (meta.start_ms >= ask.created_ms - EARLY_MS and meta.start_ms <= ask.created_ms + LATE_MS)
end

-- The one thread a reader's answer proves, or nil: none qualifies, two do, the reader failed, or the search printed
-- more than MAX_THREADS files (one it did not print could be a second candidate).
local function settle(compat: Compat, root: string, ask: Ask, asked: { [string]: string }?, stdout: string?): string?
	if stdout == nil then
		warn(compat, WARN_ROLLOUT_READ)
		return nil
	end
	local files = 0
	local only: string? = nil
	local several = false
	for _, chunk in string.split(stdout, MARK) do
		local stamp, path, head = string.match(chunk, "^(%S+) ([^\n]*)\n(.*)$")
		if stamp ~= nil and path ~= nil and head ~= nil then
			files += 1
			local id = rollout_id(root, ask, asked, stamp, path)
			if id ~= nil and counts(compat, ask, id, head) then
				if only ~= nil and only ~= id then
					several = true
				end
				only = id
			end
		end
	end
	if files > MAX_THREADS then
		warn(compat, WARN_ROLLOUT_MANY)
		return nil
	end
	return if several then nil else only
end

-- Looks for the thread of a codex agent and calls back once with its id, or nil when none is proven. Line 1 of every
-- rollout (`session_meta`) names its thread, when it started and its folder; only its first HEAD_BYTES are read.
-- A new thread (the start ran `codex`) is one that started in the window, EARLY_MS before the start was asked for to
-- LATE_MS after: its rollout is looked for in the date folders that start can have, by name. A thread picked in the
-- resume picker can be any age, but resuming appends to its rollout, so it is one modified at or after the restart,
-- found by one search of the whole sessions folder. Either way the thread must be in the agent's folder, no other
-- record's, and not started in the window of another codex agent there that holds no thread (it may be theirs), and
-- exactly one thread may qualify: two agents started together in one folder prove neither, and each restarts through
-- the picker.
function M.find_thread(compat: Compat, home: string, ask: Ask, cb: (sid: string?) -> ())
	local answered = false
	local function finish(sid: string?)
		if answered then
			return
		end
		answered = true
		cb(sid)
	end

	local root = codex_dir(home)
	if ask.picked then
		local minutes = math.max(1, math.ceil((ask.now_ms - ask.created_ms) / MINUTE_MS) + 1)
		local argv = {
			"sh",
			"-c",
			FIND_SCRIPT,
			"sh",
			root,
			string.format("%d", minutes),
			string.format("%d", MAX_THREADS + 1),
			string.format("%d", HEAD_BYTES),
		}
		compat.run_output(argv, function(stdout: string?)
			finish(settle(compat, root, ask, nil, stdout))
		end)
		return
	end

	local asked = in_window(compat, root, ask)
	if asked == nil or next(asked) == nil then
		finish(nil)
		return
	end
	local paths: { string } = {}
	for path in asked do
		paths[#paths + 1] = path
	end
	table.sort(paths)
	local argv = { "sh", "-c", READ_SCRIPT, "sh", string.format("%d", HEAD_BYTES) }
	for _, path in paths do
		argv[#argv + 1] = path
	end
	compat.run_output(argv, function(stdout: string?)
		finish(settle(compat, root, ask, asked, stdout))
	end)
end

return M
