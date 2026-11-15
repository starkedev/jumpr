--!strict
-- Follows each live omp agent's session file to learn whether one of its `/vibe` workers has a turn running.
-- Not pure: the listing and the one reader process go through the `compat` argument, and this module never
-- touches `tern`.

local Identity = require("../shared/identity")

local M = {}

local WARN_RUN = "cannot read omp session files"

-- The file name omp gives a session: an ISO timestamp and an id, ending in `.jsonl`.
local SESSION_NAME = "^[%w_%-%.:]+%.jsonl$"

-- omp's UTC stamp, `YYYY-MM-DDTHH:MM:SS.mmmZ`.
local STAMP = "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.(%d%d%d)Z$"

-- Marks a header line in the reader's output; omp's JSON lines never hold this byte.
local HEADER = "\030"

-- Reads each agent's group of arguments — the offset it last read to, the file that offset belongs to (`-` with
-- none), then its session files — and answers with one header and the matching lines. The header names the file
-- the reader chose and that file's size, both after the mark (empty when no file could be read). omp continues
-- the session file its own `--continue` picks: the most recently modified non-empty one, never simply the newest
-- name, so the reader picks the same way. The offset applies only when the reader chooses the same file as
-- before; a different file is read from its start, so none of its records is skipped. Only the lifecycle,
-- `session_exit` and `mode_change` lines among the bytes from the offset up to the size are printed.
local SCRIPT = [[while [ $# -gt 0 ]; do
	n=$1; last=$2; shift 2
	best=
	while [ $# -gt 0 ]; do
		case "$1" in /*) ;; *) break ;; esac
		f=$1; shift
		if [ -s "$f" ] && { [ -z "$best" ] || [ "$f" -nt "$best" ]; }; then best=$f; fi
	done
	if [ -z "$best" ]; then
		printf '\036\n'
		continue
	fi
	[ "$best" = "$last" ] || n=0
	size=$( { wc -c < "$best"; } 2>/dev/null ) || size=
	[ -n "$size" ] && size=$((size + 0))
	printf '\036%s\036%s\n' "$best" "$size"
	if [ -n "$size" ] && [ "$size" -gt "$n" ]; then
		tail -c +"$((n + 1))" "$best" | head -c "$((size - n))" | grep -a -E '^\{"type":"(custom","customType":"(vibe-session-lifecycle|session_exit)"|mode_change")' || :
	fi
done
exit 0]]

-- The compat calls the follower uses. `log_warn` is optional so a caller without it still type-checks.
export type Compat = {
	-- Entry names of a directory, sorted; nil when it cannot be listed or does not exist.
	fs_list: (path: string) -> ({ string }?, string?),
	json_decode: (text: string) -> (any, string?),
	-- Runs argv with no Tern shell and calls back once with its stdout, or nil when it failed, timed out or could
	-- not start. The start result is ignored; a callback of nil is the failure.
	run_output: (argv: { string }, cb: (stdout: string?) -> ()) -> ...any,
	log_warn: ((text: string) -> ())?,
}

-- What the follower holds for one agent: the session file it reads, how far it has read, the workers with a
-- turn in flight, and when its current process started (nil: trust the file's history).
type Agent = {
	path: string?,
	offset: number,
	flight: { [string]: true },
	since_ms: number?,
}

export type Follower = {
	agents: { [string]: Agent },
	busy: boolean,
	-- Raised by `clear`; an answer from a reader started before the raise is dropped.
	gen: number,
}

-- One agent's ask of the reader process, in argv order: its offset, the file that offset was read from (`-` with
-- none) and its session files.
type Read = {
	id: string,
	paths: { string },
	last: string,
	offset: number,
}

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
		log_warn("jumpr: vibe: " .. reason)
	end)
end

local function deck_dir(home: string, id: string): string
	if string.sub(home, -1) == "/" then
		return home .. ".omp/deck/" .. id
	end
	return home .. "/.omp/deck/" .. id
end
-- The session files of agent `id`: every usable name in the sorted listing, newest name last. The reader picks
-- among them the way omp's own `--continue` does, so all of them are passed on and the choice is the reader's.
local function candidates(compat: Compat, home: string, id: string): { string }?
	if not Identity.valid_id(id) then
		return nil
	end
	local dir = deck_dir(home, id)
	local names = compat.fs_list(dir)
	if names == nil then
		return nil
	end
	local out: { string } = {}
	for _, name in names do
		if string.find(name, SESSION_NAME) ~= nil then
			out[#out + 1] = dir .. "/" .. name
		end
	end
	if #out == 0 then
		return nil
	end
	return out
end

local function agent_of(f: Follower, id: string): Agent
	local agent = f.agents[id]
	if agent == nil then
		agent = { path = nil, offset = 0, flight = {}, since_ms = nil }
		f.agents[id] = agent
	end
	return agent
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

-- Epoch ms of omp's `YYYY-MM-DDTHH:MM:SS.mmmZ` stamp, or nil when it is not one.
local function stamp_ms(text: any): number?
	if type(text) ~= "string" then
		return nil
	end
	local parts = { string.match(text, STAMP) }
	if #parts ~= 7 then
		return nil
	end
	local y = tonumber(parts[1]) :: number
	local mo = tonumber(parts[2]) :: number
	local d = tonumber(parts[3]) :: number
	local h = tonumber(parts[4]) :: number
	local mi = tonumber(parts[5]) :: number
	local s = tonumber(parts[6]) :: number
	local ms = tonumber(parts[7]) :: number
	if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then
		return nil
	end
	return (((days_from_civil(y, mo, d) * 24 + h) * 60 + mi) * 60 + s) * 1000 + ms
end

-- Applies one decoded line to the agent's in-flight set, following the rule in file order.
local function apply(agent: Agent, line: any)
	if type(line) ~= "table" then
		return
	end
	local kind = line.type
	if kind == "mode_change" then
		if line.mode ~= "vibe" then
			table.clear(agent.flight)
		end
		return
	end
	if kind ~= "custom" then
		return
	end
	if line.customType == "session_exit" then
		table.clear(agent.flight)
		return
	end
	if line.customType ~= "vibe-session-lifecycle" then
		return
	end
	local data = line.data
	if type(data) ~= "table" then
		return
	end
	local worker = data.id
	if type(worker) ~= "string" then
		return
	end
	local action = data.action
	if action == "turn-started" then
		-- A turn stamped before this process started belongs to a dead one; an unreadable stamp cannot prove
		-- otherwise.
		local since = agent.since_ms
		if since ~= nil then
			local at = stamp_ms(line.timestamp)
			if at == nil or at < since then
				return
			end
		end
		agent.flight[worker] = true
	elseif action == "turn-settled" or action == "tombstone" then
		agent.flight[worker] = nil
	end
end

-- Applies one agent's header — the file the reader chose and its size — and its lines. A header with no size
-- (no file could be read) leaves the agent as it was.
local function settle_file(
	f: Follower,
	compat: Compat,
	read: Read,
	chosen: string,
	size_text: string,
	lines: { string }
)
	if string.find(size_text, "^%d+$") == nil then
		return
	end
	local size = tonumber(size_text) :: number
	local agent = agent_of(f, read.id)
	if agent.path ~= chosen then
		-- omp continued a different file: this one's history starts now.
		agent.path = chosen
		agent.offset = 0
		table.clear(agent.flight)
	end
	if size < read.offset then
		-- The file shrank: it was rewritten, so read it again from the start next time.
		agent.offset = 0
		table.clear(agent.flight)
		return
	end
	for _, text in lines do
		local value, err = compat.json_decode(text)
		if err == nil then
			apply(agent, value)
		end
	end
	agent.offset = size
end

-- Splits the reader's output by header: the n-th header — the mark, the file it chose, the mark again, that
-- file's size — and the lines after it belong to the n-th read.
local function settle_output(f: Follower, compat: Compat, reads: { Read }, stdout: string)
	local at = 0
	local chosen = ""
	local size_text = ""
	local lines: { string } = {}
	local function flush()
		local read = reads[at]
		if read ~= nil then
			settle_file(f, compat, read, chosen, size_text, lines)
		end
	end
	for _, line in string.split(stdout, "\n") do
		if string.sub(line, 1, 1) == HEADER then
			flush()
			at += 1
			local parts = string.split(line, HEADER)
			chosen = parts[2] or ""
			size_text = parts[3] or ""
			lines = {}
		elseif at > 0 and line ~= "" then
			lines[#lines + 1] = line
		end
	end
	flush()
end

-- What a poll's answer may do to the agents the follower held when the poll started: an id the poll does not
-- keep is dropped, and a kept id whose files could not be read is emptied. Agents that appeared while the
-- reader ran (a `restarted` the poll has not seen) are left alone, so their restart time survives the answer.
local function plan_prune(f: Follower, keep: { [string]: boolean }, reading: { [string]: boolean }): { { string } }
	local out: { { string } } = {}
	for id, agent in f.agents do
		if not keep[id] then
			out[#out + 1] = { id, "drop" }
		elseif not reading[id] and agent.path ~= nil then
			out[#out + 1] = { id, "empty" }
		end
	end
	return out
end

local function apply_prune(f: Follower, plan: { { string } })
	for _, step in plan do
		local id = step[1]
		local what = step[2]
		local agent = f.agents[id]
		if agent ~= nil then
			if what == "drop" then
				f.agents[id] = nil
			else
				agent.path = nil
				agent.offset = 0
				table.clear(agent.flight)
			end
		end
	end
end

local function same_set(a: { [string]: true }, b: { [string]: true }): boolean
	for id in a do
		if not b[id] then
			return false
		end
	end
	for id in b do
		if not a[id] then
			return false
		end
	end
	return true
end

function M.new(): Follower
	return { agents = {}, busy = false, gen = 0 }
end

-- A new process started for agent `id` at wall-clock `wall_ms` (epoch ms): nothing of it is in flight yet.
function M.restarted(f: Follower, id: string, wall_ms: number)
	local agent = agent_of(f, id)
	table.clear(agent.flight)
	agent.since_ms = wall_ms
end

-- The agents with a worker turn in flight, as a set of deck ids.
function M.vibing(f: Follower): { [string]: true }
	local out: { [string]: true } = {}
	for id, agent in f.agents do
		if next(agent.flight) ~= nil then
			out[id] = true
		end
	end
	return out
end

-- One poll for the live omp agents `ids` (deck ids). Drops what it holds for any other id. Starts at most one
-- process for all of them; a poll while one is still running does nothing. `done(changed)` runs once when the
-- answer is applied (or the poll failed, with false): `changed` says whether the set `M.vibing` gives changed.
-- With no ids it starts no process and calls `done` at once.
function M.poll(f: Follower, compat: Compat, home: string, ids: { string }, done: (changed: boolean) -> ())
	if f.busy then
		return
	end
	local before = M.vibing(f)
	local keep: { [string]: boolean } = {}
	local reading: { [string]: boolean } = {}
	local reads: { Read } = {}
	for _, id in ids do
		if not keep[id] then
			keep[id] = true
			local paths = candidates(compat, home, id)
			if paths ~= nil then
				local agent = f.agents[id]
				-- The offset belongs to the file it was read from; the reader applies it only when it chooses
				-- that same file again, and reads any other from its start.
				local last = if agent ~= nil then agent.path else nil
				local offset = if last ~= nil and table.find(paths, last) ~= nil then (agent :: Agent).offset else 0
				reads[#reads + 1] = { id = id, paths = paths, last = last or "-", offset = offset }
				reading[id] = true
			end
		end
	end

	-- What the answer may prune is planned now, so an agent that restarted while the reader runs keeps what
	-- `restarted` recorded for it. Nothing changes until the answer is in, so a failed process leaves the
	-- follower as it was.
	local plan = plan_prune(f, keep, reading)
	if #reads == 0 then
		apply_prune(f, plan)
		done(not same_set(before, M.vibing(f)))
		return
	end

	local argv = { "sh", "-c", SCRIPT, "sh" }
	for _, read in reads do
		argv[#argv + 1] = string.format("%d", read.offset)
		argv[#argv + 1] = read.last
		for _, path in read.paths do
			argv[#argv + 1] = path
		end
	end
	f.busy = true
	local answered = false
	local gen = f.gen
	compat.run_output(argv, function(stdout: string?)
		if answered then
			return
		end
		answered = true
		f.busy = false
		if f.gen ~= gen then
			-- The follower was cleared while this reader ran: its answer describes a list nobody asked for.
			done(false)
			return
		end
		if stdout == nil then
			warn(compat, WARN_RUN)
			done(false)
			return
		end
		apply_prune(f, plan)
		settle_output(f, compat, reads, stdout)
		done(not same_set(before, M.vibing(f)))
	end)
end

-- Forgets every agent. Called when no copy of the list is open, so what the follower says starts from nothing
-- when one opens again and no answer the lists missed can leave a pill behind. A reader that is still running
-- keeps its lock; its answer is dropped when it lands.
function M.clear(f: Follower)
	f.gen += 1
	f.agents = {}
end

return M
