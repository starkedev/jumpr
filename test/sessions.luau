--!strict
-- Session lookup behaviour: only a proven conversation id comes back, through an injected compat. The proof is a quiet
-- grep of the candidate's environment and a walk up its ancestors through `/proc/<pid>/stat` and `/proc/<pid>/comm`.
-- Pure test harness: no `tern`.

local Sessions = require("../lib/host/sessions")

local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local HOME = "/work"
local SESSIONS = "/work/.claude/sessions"
local CWD = "/work/app"
local OTHER = "/other/app"
local ID = "agent-1"
local MAX_BYTES = 65536
-- The pane shell every planted `claude` runs under unless a case says otherwise. It carries no agent's id.
local SHELL = "64000"

-- A Claude Code conversation id (a uuid) numbered `n`.
local function uuid(n: number): string
	return string.format("%08x-0000-4000-8000-000000000000", n)
end

-- One process as `/proc` shows it: its parent pid, its name and its start time.
type Proc = { parent: string, name: string, start: string }

type World = {
	home: string,
	sessions: string,
	id: string,
	names: { string },
	files: { [string]: string },
	objects: { [string]: any },
	read_err: { [string]: string },
	status: { [string]: number },
	unstarted: { [string]: boolean },
	procs: { [string]: Proc },
	missing: boolean,
	list_err: string?,
	hold: boolean,
	listed: { string },
	reads: { string },
	limits: { number },
	proc_reads: { string },
	proc_limits: { number },
	probes: { { string } },
	warnings: { string },
	pending: { (number?) -> () },
}

local function new_world(): World
	return {
		home = HOME,
		sessions = SESSIONS,
		id = ID,
		names = {},
		files = {},
		objects = {},
		read_err = {},
		status = {},
		unstarted = {},
		procs = { [SHELL] = { parent = "1", name = "fish", start = "1" } },
		missing = false,
		list_err = nil,
		hold = false,
		listed = {},
		reads = {},
		limits = {},
		proc_reads = {},
		proc_limits = {},
		probes = {},
		warnings = {},
		pending = {},
	}
end

-- Plants process `pid`, a child of `parent` named `name`; when `carries`, its environment holds the agent's id.
local function spawn(world: World, pid: string, name: string, parent: string, carries: boolean)
	world.procs[pid] = { parent = parent, name = name, start = "1000" .. pid }
	if carries then
		world.status[pid] = 0
	end
end

-- Plants the session file of `pid` and that pid as a `claude` under the pane shell; `status` is its grep's answer.
local function add(world: World, pid: string, sid: string, cwd: string, status: number)
	local name = pid .. ".json"
	local body = "body-" .. pid
	world.names[#world.names + 1] = name
	world.files[name] = body
	world.objects[body] = { sessionId = sid, cwd = cwd, pid = "../evil" }
	world.status[pid] = status
	world.procs[pid] = { parent = SHELL, name = "claude", start = "1000" .. pid }
end

local function add_name(world: World, name: string)
	world.names[#world.names + 1] = name
end

local function add_bad(world: World, pid: string)
	local name = pid .. ".json"
	world.names[#world.names + 1] = name
	world.files[name] = "not-json-" .. pid
end

local function add_unreadable(world: World, pid: string)
	local name = pid .. ".json"
	world.names[#world.names + 1] = name
	world.read_err[name] = "denied"
end

-- `/proc/<pid>/stat` as the kernel writes it: the name in parentheses, then the state, the parent pid, 17 more
-- fields and the start time.
local function stat_line(pid: string, p: Proc): string
	return string.format("%s (%s) S %s %s%s 0 0\n", pid, p.name, p.parent, string.rep("0 ", 17), p.start)
end

local function compat_of(world: World): Sessions.Compat
	return {
		fs_list = function(path: string): ({ string }?, string?)
			world.listed[#world.listed + 1] = path
			if world.missing then
				return nil, nil
			end
			if world.list_err ~= nil then
				return nil, world.list_err
			end
			return world.names, nil
		end,
		fs_read = function(path: string, max_bytes: number?): (string?, string?)
			assert(string.find(path, "environ", 1, true) == nil, "environ was read into the plugin")
			assert(string.match(path, "%.key$") == nil, "a key file was read")
			local pid, what = string.match(path, "^/proc/(%d+)/(%a+)$")
			if pid ~= nil and what ~= nil then
				if what ~= "stat" and what ~= "comm" then
					error("an unexpected /proc file was read: " .. path)
				end
				world.proc_reads[#world.proc_reads + 1] = path
				world.proc_limits[#world.proc_limits + 1] = if max_bytes == nil then -1 else max_bytes
				local p = world.procs[pid]
				if p == nil then
					return nil, nil
				end
				return if what == "comm" then p.name .. "\n" else stat_line(pid, p), nil
			end
			world.reads[#world.reads + 1] = path
			world.limits[#world.limits + 1] = if max_bytes == nil then -1 else max_bytes
			local prefix = world.sessions .. "/"
			local name = if string.sub(path, 1, #prefix) == prefix then string.sub(path, #prefix + 1) else ""
			if string.match(name, "^%d+%.json$") == nil then
				error("a hostile name became a read path: " .. path)
			end
			local err = world.read_err[name]
			if err ~= nil then
				return nil, err
			end
			return world.files[name], nil
		end,
		json_decode = function(text: string): (any, string?)
			local raw = world.objects[text]
			if raw == nil then
				return nil, "bad json"
			end
			return raw, nil
		end,
		run_status = function(argv: { string }, cb: (status: number?) -> ())
			local proc = argv[6]
			local flags_ok = argv[1] == "grep" and argv[2] == "-q" and argv[3] == "-z" and argv[4] == "-x"
			if not flags_ok or #argv ~= 6 or proc == nil then
				error("grep was not a quiet exact match of one digit pid")
			end
			if argv[5] ~= "JUMPR_ID=" .. world.id then
				error("grep pattern was not the agent id")
			end
			local pid = string.match(proc, "^/proc/(%d+)/environ$")
			if pid == nil then
				error("a non-numeric name was passed to grep")
			end
			local recorded: { string } = table.clone(argv)
			world.probes[#world.probes + 1] = recorded
			if world.hold then
				world.pending[#world.pending + 1] = cb
				return
			end
			if world.unstarted[pid] then
				cb(nil)
				return
			end
			local status = world.status[pid]
			cb(if status == nil then 1 else status)
		end,
		run_output = function(_argv: { string }, _cb: (stdout: string?) -> ())
			error("a claude lookup ran a reader")
		end,
		log_warn = function(text: string)
			world.warnings[#world.warnings + 1] = text
		end,
	}
end

-- One lookup: the proven conversation id (nil when none), how many times it called back, and the proof itself.
local function run(
	world: World,
	kind: string,
	id: string,
	cwd: string,
	taken: { [string]: boolean }
): (string?, number, Sessions.Proof?)
	world.id = id
	local calls = 0
	local got: Sessions.Proof? = nil
	Sessions.find(compat_of(world), world.home, kind, id, cwd, taken, function(proof: Sessions.Proof?)
		calls += 1
		got = proof
	end)
	local proof = got
	return if proof ~= nil then proof.sid else nil, calls, proof
end

local function pids_are(world: World, expected: { string }): boolean
	if #world.probes ~= #expected then
		return false
	end
	for i, pid in expected do
		if world.probes[i][6] ~= "/proc/" .. pid .. "/environ" then
			return false
		end
	end
	return true
end

-- The pids grep was asked about, comma-joined, for a failure message.
local function probed(world: World): string
	local out: { string } = {}
	for _, argv in world.probes do
		table.insert(out, string.match(argv[6], "^/proc/(%d+)/environ$") or "?")
	end
	return table.concat(out, ",")
end

local function reads_are_bounded(world: World): boolean
	if #world.limits ~= #world.reads then
		return false
	end
	for _, limit in world.limits do
		if limit ~= MAX_BYTES then
			return false
		end
	end
	return true
end

-- Every `/proc` read is bounded, by a few KiB at most.
local function proc_reads_are_bounded(world: World): boolean
	for _, limit in world.proc_limits do
		if limit <= 0 or limit > 4096 then
			return false
		end
	end
	return true
end

-- Claude Code conversations and Codex threads can be looked up; no other kind can.
check(Sessions.has("claude"), "claude conversations can be looked up")
check(Sessions.has("codex"), "codex threads can be looked up")
check(not Sessions.has("omp"), "omp conversations are not looked up")
check(not Sessions.has("copilot"), "a kind without a recipe is not looked up")
check(not Sessions.has("Claude") and not Sessions.has("Codex"), "kind lookup is case-sensitive")
check(not Sessions.has(""), "an empty kind is not looked up")

-- The conversation whose grep exits 0 is returned, and later files are not probed. Its parent, the pane shell (`sh`
-- exec'd `claude` on a fresh start), does not carry the agent's id, so one more grep proves it the pane's own.
do
	local world = new_world()
	add(world, "101", uuid(101), CWD, 1)
	add(world, "102", uuid(102), CWD, 0)
	add(world, "103", uuid(103), CWD, 0)
	local sid, calls, proof = run(world, "claude", ID, CWD, {})
	check(sid == uuid(102), "the conversation whose grep exits 0 is returned")
	check(calls == 1, "a proven lookup calls back once")
	check(proof ~= nil and proof.pid == "102" and proof.start == "1000102", "the proof names its process and start")
	check(pids_are(world, { "101", "102", SHELL }), "grep stops at the first proof, then asks its parent")
	check(#world.reads == 3, "each digit json file is read before probing")
	check(reads_are_bounded(world), "each session file is read at most 65536 bytes")
	check(world.listed[1] == SESSIONS, "the lookup lists the sessions folder")
	check(world.probes[1][5] == "JUMPR_ID=" .. ID and world.probes[3][5] == "JUMPR_ID=" .. ID, "grep asks for its id")
	check(table.concat(world.proc_reads, ",") == "/proc/102/stat", "the walk reads the proven process's stat only")
	check(proc_reads_are_bounded(world), "a /proc read is bounded")
end

-- A key file is never read, and a non-numeric name never becomes a path.
do
	local world = new_world()
	add_name(world, "12.key")
	add_name(world, "99.deadbeef.key")
	add_name(world, "notes.txt")
	add_name(world, "abc.json")
	add_name(world, "../701.json")
	add_name(world, "701.json/../../etc/passwd")
	add_name(world, ".json")
	add_name(world, "701.JSON")
	add_name(world, " 701.json")
	add_name(world, "701.json ")
	add_name(world, "701.json.bak")
	add_name(world, "pid.json")
	add_name(world, "701.json\n")
	add(world, "701", uuid(701), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == uuid(701), "a digit json file is still found beside hostile names")
	check(calls == 1, "a lookup beside hostile names calls back once")
	check(#world.reads == 1, "only the digit json file is read")
	check(world.reads[1] == SESSIONS .. "/701.json", "the read path is rebuilt from digits")
	check(pids_are(world, { "701", SHELL }), "a non-numeric name is never passed to grep")
	check(reads_are_bounded(world), "the one session read is bounded")
end

-- A listing of only key files reads nothing and calls back nil.
do
	local world = new_world()
	add_name(world, "12.key")
	add_name(world, "44.abc.key")
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "key files alone prove no conversation")
	check(calls == 1, "a key-only listing calls back once")
	check(#world.reads == 0, "a key file is not read")
	check(#world.probes == 0, "a key file is not passed to grep")
end

-- Same-folder proof wins over an earlier other-folder file that would also match.
do
	local world = new_world()
	add(world, "201", uuid(201), OTHER, 0)
	add(world, "202", uuid(202), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == uuid(202), "a same-folder proof is returned before other folders")
	check(calls == 1, "a same-folder proof calls back once")
	check(pids_are(world, { "202", SHELL }), "the other folder is not probed after a same-folder proof")
end

-- A match in another folder is found after the same-folder files miss.
do
	local world = new_world()
	add(world, "301", uuid(301), OTHER, 0)
	add(world, "302", uuid(302), CWD, 1)
	add(world, "303", uuid(303), CWD, 2)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == uuid(301), "a proof in another folder is still found")
	check(calls == 1, "an other-folder proof calls back once")
	check(pids_are(world, { "302", "303", "301", SHELL }), "same-folder files are probed before other folders")
end

-- A folder path that only shares a prefix is not treated as the same folder.
do
	local world = new_world()
	add(world, "311", uuid(311), CWD .. "-extra", 0)
	add(world, "312", uuid(312), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == uuid(312), "folder equality is exact")
	check(calls == 1, "an exact-folder proof calls back once")
	check(pids_are(world, { "312", SHELL }), "a prefix of the folder is probed with the other files")
end

-- A taken conversation is skipped, and a false flag does not hide one.
do
	local world = new_world()
	add(world, "401", uuid(401), CWD, 0)
	add(world, "402", uuid(402), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, { [uuid(401)] = true })
	check(sid == uuid(402), "a taken conversation is not returned")
	check(calls == 1, "a lookup that skips a taken id calls back once")
	check(pids_are(world, { "402", SHELL }), "a taken conversation is not probed")
end

do
	local world = new_world()
	add(world, "411", uuid(411), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, { [uuid(411)] = true })
	check(sid == nil, "a listing of only taken conversations proves nothing")
	check(calls == 1, "a taken-only listing calls back once")
	check(#world.probes == 0, "a taken-only listing runs no grep")
end

do
	local world = new_world()
	add(world, "421", uuid(421), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, { [uuid(421)] = false })
	check(sid == uuid(421), "a false taken flag does not hide a conversation")
	check(calls == 1, "a false taken flag still calls back once")
end

-- A session id that is not a lowercase uuid (the only shape Claude Code's launch line takes) is not a candidate, even
-- when its grep would match.
do
	local world = new_world()
	add(world, "501", "a/b", CWD, 0)
	add(world, "502", "--continue", CWD, 0)
	add(world, "503", "", CWD, 0)
	add(world, "504", string.rep("s", 65), CWD, 0)
	add(world, "506", "plain-session-id", CWD, 0)
	add(world, "507", string.upper(uuid(507)), CWD, 0)
	add(world, "508", uuid(508) .. "x", CWD, 0)
	add(world, "509", "{" .. uuid(509) .. "}", CWD, 0)
	add(world, "505", uuid(505), OTHER, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == uuid(505), "only a uuid can be returned")
	check(calls == 1, "an invalid session id still calls back once")
	check(pids_are(world, { "505", SHELL }), "an invalid session id is not probed")
end

-- No proof calls back nil: every grep misses, including a missing process environment.
do
	local world = new_world()
	add(world, "601", uuid(601), CWD, 2)
	add(world, "602", uuid(602), OTHER, 1)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "no matching process calls back nil")
	check(calls == 1, "a miss calls back once")
	check(pids_are(world, { "601", "602" }), "a non-zero grep tries the next file")
	check(#world.warnings == 0, "a grep miss is not a warning")
	check(#world.proc_reads == 0, "and nothing is walked")
end

-- Bad JSON calls back nil when nothing else can be proved, and two bad files warn once.
do
	local world = new_world()
	add_bad(world, "701")
	add_bad(world, "702")
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "bad JSON calls back nil")
	check(calls == 1, "bad JSON calls back once")
	check(#world.probes == 0, "bad JSON is not probed")
	check(#world.warnings == 1, "two bad files warn once")
	check(world.warnings[1] == "jumpr: session lookup: bad session file", "the bad-file warning names that reason")
end

do
	local again = new_world()
	add_bad(again, "703")
	local sid, calls = run(again, "claude", ID, CWD, {})
	check(sid == nil, "a later bad file still calls back nil")
	check(calls == 1, "a later bad file calls back once")
	check(#again.warnings == 0, "a repeated bad-file reason is not warned again")
end

-- A bad file does not hide a later proof.
do
	local world = new_world()
	add_bad(world, "711")
	add(world, "712", uuid(712), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == uuid(712), "a bad file does not hide a proven conversation")
	check(calls == 1, "a proof after bad JSON calls back once")
	check(pids_are(world, { "712", SHELL }), "only the readable conversation is probed")
end

-- A missing folder and a list error call back nil.
do
	local world = new_world()
	world.missing = true
	add(world, "801", uuid(801), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "a missing sessions folder calls back nil")
	check(calls == 1, "a missing folder calls back once")
	check(#world.reads == 0, "a missing folder reads nothing")
	check(#world.probes == 0, "a missing folder runs no grep")
	check(#world.warnings == 1, "a missing folder warns once")
	check(world.warnings[1] == "jumpr: session lookup: no sessions folder", "the warning names the missing folder")
end

do
	local again = new_world()
	again.missing = true
	local sid, calls = run(again, "claude", ID, CWD, {})
	check(sid == nil, "a repeated missing folder calls back nil")
	check(calls == 1, "a repeated missing folder calls back once")
	check(#again.warnings == 0, "a repeated missing-folder reason is not warned again")
end

do
	local world = new_world()
	world.list_err = "permission denied"
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "a list error calls back nil")
	check(calls == 1, "a list error calls back once")
	check(#world.reads == 0, "a list error reads nothing")
	check(world.warnings[1] == "jumpr: session lookup: cannot list sessions", "a list error warns once")
end

-- A read error does not hide a proven conversation, and it warns once.
do
	local world = new_world()
	add_unreadable(world, "901")
	add_unreadable(world, "902")
	add(world, "903", uuid(903), OTHER, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == uuid(903), "a read error does not hide a proven conversation")
	check(calls == 1, "a proof after a read error calls back once")
	check(#world.warnings == 1, "two read errors warn once")
	check(world.warnings[1] == "jumpr: session lookup: cannot read session file", "warning names the read error")
end

-- A kind without a recipe, and an unsafe agent id, call back nil without listing.
do
	local world = new_world()
	add(world, "1001", uuid(1001), CWD, 0)
	local sid, calls = run(world, "omp", ID, CWD, {})
	check(sid == nil, "omp calls back nil")
	check(calls == 1, "omp calls back once")
	check(#world.listed == 0, "omp lists no sessions folder")
	check(#world.reads == 0, "omp reads no session file")
	check(#world.probes == 0, "omp runs no grep")
end

-- `find` is Claude Code's recipe: a codex agent's thread is `find_thread`'s, so `find` lists nothing for one.
do
	local world = new_world()
	add(world, "1011", uuid(1011), CWD, 0)
	local sid, calls = run(world, "codex", ID, CWD, {})
	check(sid == nil, "find calls back nil for a codex agent")
	check(calls == 1, "find calls back once for a codex agent")
	check(#world.listed == 0 and #world.probes == 0, "find lists and probes nothing for a codex agent")
end

do
	local world = new_world()
	add(world, "1021", uuid(1021), CWD, 0)
	local sid, calls = run(world, "claude", "a;b", CWD, {})
	check(sid == nil, "an unsafe agent id calls back nil")
	check(calls == 1, "an unsafe agent id calls back once")
	check(#world.listed == 0, "an unsafe agent id lists nothing")
	check(#world.probes == 0, "an unsafe agent id is not passed to grep")
end

-- At most 30 conversations are probed, and same-folder files consume that budget first.
do
	local world = new_world()
	add(world, "2000", uuid(2000), OTHER, 0)
	for n = 1, 30 do
		add(world, tostring(n), uuid(n), CWD, 1)
	end
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "a match past the 30-probe budget is not returned")
	check(calls == 1, "a capped lookup calls back once")
	check(#world.reads == 31, "every digit json file is still read")
	check(#world.probes == 30, "at most 30 conversations are probed")
	check(reads_are_bounded(world), "a long listing is still read with a bound")
	local saw_other = false
	for _, argv in world.probes do
		if argv[6] == "/proc/2000/environ" then
			saw_other = true
		end
	end
	check(not saw_other, "same-folder files consume the probe budget first")
end

-- grep that cannot start ends the lookup, even when a later file would match.
do
	local world = new_world()
	add(world, "3001", uuid(3001), CWD, 0)
	add(world, "3002", uuid(3002), CWD, 0)
	world.unstarted["3001"] = true
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "a missing grep calls back nil")
	check(calls == 1, "a missing grep calls back once")
	check(pids_are(world, { "3001" }), "a missing grep does not probe the next file")
	check(world.warnings[1] == "jumpr: session lookup: cannot start grep", "a missing grep warns once")
end

-- The lookup waits for grep, the walk waits for its own grep, and a second answer is ignored.
do
	local world = new_world()
	world.hold = true
	add(world, "4001", uuid(4001), CWD, 0)
	local calls = 0
	local got: Sessions.Proof? = nil
	world.id = ID
	Sessions.find(compat_of(world), world.home, "claude", ID, CWD, {}, function(proof: Sessions.Proof?)
		calls += 1
		got = proof
	end)
	check(calls == 0, "find waits for grep before calling back")
	check(#world.pending == 1, "one grep is started before it answers")
	world.pending[1](0)
	check(calls == 0 and #world.pending == 2, "a yes starts the walk, which asks the parent next")
	world.pending[2](1)
	check(calls == 1, "the walk's answer calls back once")
	local proof = got
	check(proof ~= nil and proof.sid == uuid(4001), "the held proof is the conversation id")
	world.pending[1](0)
	world.pending[2](1)
	check(calls == 1 and #world.pending == 2, "a second grep answer does not call back or ask again")
end

-- A trailing slash on the home directory still lists and reads the sessions folder.
do
	local world = new_world()
	world.home = "/work/"
	add(world, "5001", uuid(5001), CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == uuid(5001), "a trailing slash on home still finds the conversation")
	check(calls == 1, "a trailing-slash home calls back once")
	check(world.listed[1] == SESSIONS, "a trailing slash is not doubled into the sessions path")
	check(world.reads[1] == SESSIONS .. "/5001.json", "a trailing slash does not change the read path")
end

-- On a resume `claude` is a child of the launch line's `sh`, which carries the agent's id: the walk reads its name,
-- passes it and stops at the pane shell, which does not carry the id.
do
	local world = new_world()
	spawn(world, "30", "sh", SHELL, true)
	add(world, "31", uuid(31), CWD, 0)
	world.procs["31"].parent = "30"
	local sid, calls, proof = run(world, "claude", ID, CWD, {})
	check(sid == uuid(31) and calls == 1, "a claude under the line's sh is the pane's own")
	check(proof ~= nil and proof.pid == "31" and proof.start == "100031", "the proof is that process")
	check(pids_are(world, { "31", "30", SHELL }), "each ancestor up to the pane shell is asked: " .. probed(world))
	check(
		table.concat(world.proc_reads, ",") == "/proc/31/stat,/proc/30/comm,/proc/30/stat",
		"by its stat and name only: " .. table.concat(world.proc_reads, ",")
	)
	check(proc_reads_are_bounded(world), "every /proc read is bounded")
end

-- An ACP chat's `claude` sits under the ACP adapter (node) and `tern acp`, which carry the id too: still the pane's own.
do
	local world = new_world()
	spawn(world, "8", "tern", SHELL, true)
	spawn(world, "9", "node-MainThread", "8", true)
	add(world, "42", uuid(42), CWD, 0)
	world.procs["42"].parent = "9"
	local sid = run(world, "claude", ID, CWD, {})
	check(sid == uuid(42), "an ACP chat's claude is the pane's own")
	check(pids_are(world, { "42", "9", "8", SHELL }), "up to the pane shell: " .. probed(world))
end

-- A `claude` the agent ran itself (claude → bash → claude) carries the agent's id too, but the agent's own `claude` is
-- above it: it is refused and the next candidate, the agent's own, is proven. Alone it proves nothing.
do
	local function nested(world: World)
		spawn(world, "40", "bash", "31", true)
		spawn(world, "120", "claude", "40", true)
		world.names[#world.names + 1] = "120.json"
		world.files["120.json"] = "body-120"
		world.objects["body-120"] = { sessionId = uuid(120), cwd = CWD }
	end

	local world = new_world()
	nested(world)
	add(world, "31", uuid(31), CWD, 0)
	local sid, calls, proof = run(world, "claude", ID, CWD, {})
	check(sid == uuid(31) and calls == 1, "the agent's own claude gives the conversation, never the nested one")
	check(proof ~= nil and proof.pid == "31", "its proof is the agent's own process")
	check(pids_are(world, { "120", "40", "31", "31", SHELL }), "the nested one is walked up to it: " .. probed(world))

	local alone = new_world()
	spawn(alone, "31", "claude", SHELL, true)
	nested(alone)
	local none, called = run(alone, "claude", ID, CWD, {})
	check(none == nil and called == 1, "a nested claude alone proves nothing")
end

-- The walk ends at the first ancestor without the agent's id, so a `claude` above that (one that does not carry the
-- id) does not count, and its name is never read.
do
	local world = new_world()
	spawn(world, "29", "claude", SHELL, false)
	spawn(world, "30", "sh", "29", true)
	add(world, "31", uuid(31), CWD, 0)
	world.procs["31"].parent = "30"
	local sid = run(world, "claude", ID, CWD, {})
	check(sid == uuid(31), "a claude outside the agent's processes does not count")
	check(pids_are(world, { "31", "30", "29" }), "the walk stops at the first ancestor without the id")
	check(table.find(world.proc_reads, "/proc/29/comm") == nil, "whose name is not read")
end

-- The name in `/proc/<pid>/stat` is read after its last `)`, so a name holding spaces and parentheses does not shift
-- the parent pid.
do
	local world = new_world()
	spawn(world, "30", "a) (b c", SHELL, true)
	add(world, "31", uuid(31), CWD, 0)
	world.procs["31"].parent = "30"
	local sid = run(world, "claude", ID, CWD, {})
	check(sid == uuid(31), "an odd name above the claude still reads")
	check(pids_are(world, { "31", "30", SHELL }), "and its parent pid is the right field: " .. probed(world))
end

-- A process with no parent (pid 0) has nothing above it: proven with no further grep.
do
	local world = new_world()
	add(world, "31", uuid(31), CWD, 0)
	world.procs["31"].parent = "0"
	local sid = run(world, "claude", ID, CWD, {})
	check(sid == uuid(31) and pids_are(world, { "31" }), "a process with no parent is proven at once")
end

-- The walk refuses what it cannot read or ask: a candidate whose process is gone, an ancestor carrying the id whose
-- name or stat cannot be read, and an ancestor whose grep cannot start.
do
	local gone = new_world()
	add(gone, "31", uuid(31), CWD, 0)
	gone.procs["31"] = nil
	local sid = run(gone, "claude", ID, CWD, {})
	check(sid == nil and pids_are(gone, { "31" }), "a candidate whose process is gone proves nothing")

	local unnamed = new_world()
	add(unnamed, "31", uuid(31), CWD, 0)
	unnamed.procs["31"].parent = "30"
	unnamed.status["30"] = 0
	local none = run(unnamed, "claude", ID, CWD, {})
	check(none == nil and pids_are(unnamed, { "31", "30" }), "an ancestor that cannot be read proves nothing")

	local unasked = new_world()
	add(unasked, "31", uuid(31), CWD, 0)
	unasked.unstarted[SHELL] = true
	local unproven, calls = run(unasked, "claude", ID, CWD, {})
	check(unproven == nil and calls == 1, "an ancestor grep that cannot start proves nothing")
end

-- At most eight ancestors are walked: the pane shell as the eighth still proves the claude, a ninth does not.
do
	local function chain(carrying: number): World
		local world = new_world()
		local parent = SHELL
		for n = 1, carrying do
			local pid = tostring(500 + n)
			spawn(world, pid, "sh", parent, true)
			parent = pid
		end
		add(world, "31", uuid(31), CWD, 0)
		world.procs["31"].parent = parent
		return world
	end
	local seven = chain(7)
	local sid = run(seven, "claude", ID, CWD, {})
	check(sid == uuid(31) and #seven.probes == 9, "seven ancestors carrying the id, then the shell, prove it")
	local eight = chain(8)
	local none = run(eight, "claude", ID, CWD, {})
	check(none == nil and #eight.probes == 9, "eight carrying the id leave the shell past the bound: nothing proven")
end

-- `current` reads the proven claude's session file again: after `/clear` it gives the new id, with no grep and no
-- listing. A pid that names another process now (another start time) or none, a session file that is gone or holds no
-- usable id, and a pid that is not digits give nil, and nothing outside the session file and `/proc` is read.
do
	local world = new_world()
	add(world, "101", uuid(101), CWD, 0)
	local _, _, found = run(world, "claude", ID, CWD, {})
	check(found ~= nil, "a proof to follow")
	local proof = found :: Sessions.Proof
	local compat = compat_of(world)
	check(Sessions.current(compat, HOME, proof) == uuid(101), "the proven claude still holds its conversation")
	local probes, listed = #world.probes, #world.listed
	world.objects["body-101"].sessionId = uuid(102)
	check(Sessions.current(compat, HOME, proof) == uuid(102), "after /clear it gives the new id")
	check(#world.probes == probes and #world.listed == listed, "with no grep and no listing")

	world.procs["101"].start = "999"
	check(Sessions.current(compat, HOME, proof) == nil, "a pid that names another process now gives nil")
	world.procs["101"].start = "1000101"
	world.objects["body-101"].sessionId = "plain-session-id"
	check(Sessions.current(compat, HOME, proof) == nil, "an id that is not a uuid gives nil")
	world.objects["body-101"].sessionId = uuid(102)
	world.files["101.json"] = nil
	check(Sessions.current(compat, HOME, proof) == nil, "a session file that is gone gives nil")
	world.files["101.json"] = "body-101"
	world.procs["101"] = nil
	check(Sessions.current(compat, HOME, proof) == nil, "a process that is gone gives nil")
	local reads = #world.reads + #world.proc_reads
	check(
		Sessions.current(compat, HOME, { sid = uuid(1), pid = "1/../2", start = "1" }) == nil
			and #world.reads + #world.proc_reads == reads,
		"a pid that is not digits gives nil and reads nothing"
	)
end

-- Codex threads ------------------------------------------------------------------------------------------------------

local CODEX_ROOT = "/work/.codex/sessions"
local SECOND = 1000
local MINUTE = 60 * SECOND
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR
-- 2027-01-15T08:00:00Z: when the agent's start was asked for, unless a case says otherwise.
local T0 = 1800000000000

-- A machine's Codex sessions folder: its date folders' rollout names, what each rollout holds, when each was last
-- modified (epoch seconds), text appended to every reader's answer, and what the lookup did.
type Rollouts = {
	folders: { [string]: { string } },
	list_err: { [string]: string },
	texts: { [string]: string },
	mtimes: { [string]: number },
	now_s: number,
	extra: string,
	broken: boolean,
	hold: boolean,
	listed: { string },
	runs: { { string } },
	pending: { () -> () },
	warnings: { string },
}

-- A machine whose clock reads `now_ms`.
local function new_rollouts(now_ms: number): Rollouts
	return {
		folders = {},
		list_err = {},
		texts = {},
		mtimes = {},
		now_s = now_ms // SECOND,
		extra = "",
		broken = false,
		hold = false,
		listed = {},
		runs = {},
		pending = {},
		warnings = {},
	}
end

-- What `head -c <bytes> | head -n 1` prints of a file holding `text`.
local function line_one(text: string, bytes: number): string
	local head = string.sub(text, 1, bytes)
	local cut = string.find(head, "\n", 1, true)
	return if cut ~= nil then string.sub(head, 1, cut) else head
end

-- The lookup's compat on this machine. Its reader answers as the real scripts would: with the head of line 1 of each
-- rollout it names, or, for the picker's search (its first argument the sessions folder), of each rollout modified
-- less than the given minutes ago (as GNU `find -mmin` counts), at most the given number of them.
local function rollouts_compat(w: Rollouts): Sessions.Compat
	return {
		fs_list = function(path: string): ({ string }?, string?)
			table.insert(w.listed, path)
			local err = w.list_err[path]
			if err ~= nil then
				return nil, err
			end
			return w.folders[path], nil
		end,
		fs_read = function(path: string, _max_bytes: number?): (string?, string?)
			error("a file was read whole into the plugin: " .. path)
		end,
		json_decode = function(_text: string): (any, string?)
			error("a rollout head was decoded as JSON")
		end,
		run_status = function(_argv: { string }, _cb: (status: number?) -> ())
			error("a codex lookup ran grep")
		end,
		run_output = function(argv: { string }, cb: (stdout: string?) -> ())
			table.insert(w.runs, table.clone(argv))
			if argv[1] ~= "sh" or argv[2] ~= "-c" or argv[4] ~= "sh" then
				error("the reader was not one sh -c script")
			end
			local out = ""
			if argv[5] == CODEX_ROOT then
				local minutes = tonumber(argv[6]) :: number
				local most = tonumber(argv[7]) :: number
				local bytes = tonumber(argv[8]) :: number
				local found: { string } = {}
				for path, mtime in w.mtimes do
					if w.now_s - mtime < minutes * 60 then
						table.insert(found, path)
					end
				end
				table.sort(found)
				for i, path in found do
					if i <= most then
						local text = line_one(w.texts[path] or "", bytes)
						out ..= "\030" .. string.format("%d", w.mtimes[path]) .. " " .. path .. "\n" .. text
					end
				end
			else
				local bytes = tonumber(argv[5]) :: number
				for i = 6, #argv do
					local path = argv[i]
					if
						string.find(path, "^/work/%.codex/sessions/%d%d%d%d/%d%d/%d%d/rollout%-[^/]+%.jsonl$") == nil
					then
						error("a name that is not a rollout's became a reader path: " .. path)
					end
					out ..= "\030- " .. path .. "\n" .. line_one(w.texts[path] or "", bytes)
				end
			end
			out ..= w.extra
			local function answer()
				cb(if w.broken then nil else out)
			end
			if w.hold then
				table.insert(w.pending, answer)
			else
				answer()
			end
		end,
		log_warn = function(text: string)
			table.insert(w.warnings, text)
		end,
	}
end

-- A Codex thread id: a UUID v7 for a thread that started at `ms`, told apart by `n`.
local function thread_id(ms: number, n: number): string
	local hex = string.format("%012x", ms)
	return string.format("%s-%s-7%03x-8000-000000000000", string.sub(hex, 1, 8), string.sub(hex, 9, 12), n)
end

-- Codex's UTC stamp for epoch ms `ms`.
local function stamp(ms: number): string
	return os.date("!%Y-%m-%dT%H:%M:%S", ms // SECOND) .. string.format(".%03dZ", ms % SECOND)
end

-- A rollout as Codex writes it: line 1 its `session_meta` record, cut short of the instructions that fill most of it,
-- then a line of the conversation.
local function rollout_text(id: string, start: string, cwd: string): string
	local meta = '{"timestamp":"'
		.. start
		.. '","ordinal":0,"type":"session_meta","payload":{"account_scoped":true,"creator_user_id":"user-x",'
		.. '"session_id":"'
		.. id
		.. '","id":"'
		.. id
		.. '","timestamp":"'
		.. start
		.. '","cwd":"'
		.. cwd
		.. '","runtime_workspace_roots":["'
		.. cwd
		.. '"],"originator":"codex-tui","base_instructions":{"text":"You are Codex.'
		.. string.rep(" Read the repository first.", 100)
		.. '"}}}\n'
	return meta .. '{"timestamp":"' .. start .. '","type":"response_item","payload":{"content":"the conversation"}}\n'
end

-- Files a rollout of thread `id`, which started at `ms`, holding `text`, under the date folder and name a machine
-- `east` ms ahead of UTC gives it; returns its path.
local function file(w: Rollouts, id: string, ms: number, text: string, east: number?): string
	local seconds = (ms + (east or 0)) // SECOND
	local dir = CODEX_ROOT .. "/" .. os.date("!%Y/%m/%d", seconds)
	local name = "rollout-" .. os.date("!%Y-%m-%dT%H-%M-%S", seconds) .. "-" .. id .. ".jsonl"
	local names = w.folders[dir] or {}
	table.insert(names, name)
	w.folders[dir] = names
	w.texts[dir .. "/" .. name] = text
	return dir .. "/" .. name
end

-- Files thread `n` of folder `cwd`, which started at `ms`; returns its id and its rollout's path.
local function thread(w: Rollouts, n: number, ms: number, cwd: string, east: number?): (string, string)
	local id = thread_id(ms, n)
	return id, file(w, id, ms, rollout_text(id, stamp(ms), cwd), east)
end

-- The lookup of a codex agent in CWD whose latest start was asked for at `created` (and opened the resume picker when
-- `picked`), run at `now`.
local function ask_at(created: number, now: number, picked: boolean?): Sessions.Ask
	return { cwd = CWD, created_ms = created, now_ms = now, picked = picked == true, taken = {}, rivals = {} }
end

-- One codex lookup: the thread it proved (nil when none) and how many times it called back.
local function look(w: Rollouts, ask: Sessions.Ask, home: string?): (string?, number)
	local calls = 0
	local got: string? = nil
	Sessions.find_thread(rollouts_compat(w), home or HOME, ask, function(sid: string?)
		calls += 1
		got = sid
	end)
	return got, calls
end

-- The arguments after the script of reader run `n`, space-joined, for a failure message.
local function given(w: Rollouts, n: number): string
	local argv = w.runs[n]
	return if argv ~= nil then table.concat(argv, " ", 5) else "(no reader)"
end

-- No date folder (Codex has filed no thread yet): nothing is proven, read or warned. The folders tried are every date
-- the start can have in any zone (12 h west of UTC to 14 h east), up to the latest date it is now.
do
	local w = new_rollouts(T0 + 30 * SECOND)
	local sid, calls = look(w, ask_at(T0, T0 + 30 * SECOND))
	check(sid == nil and calls == 1, "no date folder proves nothing, and calls back once")
	check(#w.runs == 0 and #w.warnings == 0, "no date folder is neither read nor warned")
	check(
		table.concat(w.listed, ",") == CODEX_ROOT .. "/2027/01/14," .. CODEX_ROOT .. "/2027/01/15",
		"the start's dates in any zone are listed: " .. table.concat(w.listed, ",")
	)
end

-- Days later the folders still start at the start's dates, and run at most eight days on.
do
	local w = new_rollouts(T0 + 20 * DAY)
	look(w, ask_at(T0, T0 + 20 * DAY))
	check(
		#w.listed == 9 and w.listed[1] == CODEX_ROOT .. "/2027/01/14" and w.listed[9] == CODEX_ROOT .. "/2027/01/22",
		"at most eight days of folders from the start's date: " .. table.concat(w.listed, ",")
	)
end

-- One thread of the agent's folder that started in the window is proven: its rollout, named in a date folder, is read
-- by one `sh -c` reader given that path and the bytes of line 1 to read.
do
	local w = new_rollouts(T0 + 2 * MINUTE)
	local id, path = thread(w, 1, T0 + 40 * SECOND, CWD)
	local sid, calls = look(w, ask_at(T0, T0 + 2 * MINUTE))
	check(sid == id and calls == 1, "the one thread started in the window is proven")
	check(#w.runs == 1 and given(w, 1) == "2048 " .. path, "one reader reads its line 1: " .. given(w, 1))
end

-- The three fields are found wherever they sit in the payload, past nested objects and arrays holding the same names,
-- and the head may end anywhere after them.
do
	local w = new_rollouts(T0 + MINUTE)
	local start = T0 + 20 * SECOND
	local id = thread_id(start, 2)
	file(
		w,
		id,
		start,
		'{ "type" : "session_meta" , "payload" : { "git" : { "id" : "'
			.. thread_id(start, 3)
			.. '", "cwd" : "'
			.. OTHER
			.. '" }, "list" : [ 1, { "cwd" : "/x" }, "]}" ], "count" : 12.5e3 , "flag" : null, "cwd" : "'
			.. CWD
			.. '", "timestamp" : "'
			.. stamp(start)
			.. '", "id" : "'
			.. id
			.. '", "instructions" : "'
			.. string.rep("x", 4000)
	)
	check(look(w, ask_at(T0, T0 + MINUTE)) == id, "the payload's own fields are found in any order")
end

-- Two threads of the folder started in the window (two agents started there together): neither is proven.
do
	local w = new_rollouts(T0 + 3 * MINUTE)
	thread(w, 1, T0 + 20 * SECOND, CWD)
	thread(w, 2, T0 + 90 * SECOND, CWD)
	local sid, calls = look(w, ask_at(T0, T0 + 3 * MINUTE))
	check(sid == nil and calls == 1, "two threads started in the window prove neither")
end

-- The window runs from a minute before the start was asked for to ten minutes after, both ends included.
do
	local cases = {
		{ at = T0 - MINUTE, proven = true, what = "a thread started a minute early" },
		{ at = T0 - MINUTE - SECOND, proven = false, what = "a thread started just over a minute early" },
		{ at = T0 + 10 * MINUTE, proven = true, what = "a thread started ten minutes late" },
		{ at = T0 + 10 * MINUTE + SECOND, proven = false, what = "a thread started just over ten minutes late" },
	}
	for _, case in cases do
		local w = new_rollouts(T0 + 20 * MINUTE)
		local id = thread(w, 1, case.at, CWD)
		local sid = look(w, ask_at(T0, T0 + 20 * MINUTE))
		check((sid == id) == case.proven, case.what .. (if case.proven then " is proven" else " is not proven"))
	end
end

-- A rollout whose name says its thread started well outside the window is not read, nor one whose thread another
-- record holds; a false taken flag hides nothing.
do
	local w = new_rollouts(T0 + MINUTE)
	local _, early = thread(w, 1, T0 - 3 * MINUTE, CWD)
	local _, late = thread(w, 2, T0 + 12 * MINUTE, CWD)
	local held = thread(w, 3, T0 + 10 * SECOND, CWD)
	local id, path = thread(w, 4, T0 + 20 * SECOND, CWD)
	local ask = ask_at(T0, T0 + 20 * MINUTE)
	ask.taken = { [held] = true, [id] = false }
	check(look(w, ask) == id, "the thread no other record holds is proven")
	check(given(w, 1) == "2048 " .. path, "only its rollout is read: " .. given(w, 1))
	check(not string.find(given(w, 1), early, 1, true) and not string.find(given(w, 1), late, 1, true), "nor others")
end

-- A thread of another folder, or of a folder that only shares a prefix with the agent's, is not the agent's.
do
	local w = new_rollouts(T0 + MINUTE)
	thread(w, 1, T0 + 10 * SECOND, OTHER)
	thread(w, 2, T0 + 20 * SECOND, CWD .. "-extra")
	thread(w, 3, T0 + 30 * SECOND, "/work")
	local sid, calls = look(w, ask_at(T0, T0 + MINUTE))
	check(sid == nil and calls == 1, "threads of other folders prove nothing")
	local id = thread(w, 4, T0 + 40 * SECOND, CWD)
	check(look(w, ask_at(T0, T0 + MINUTE)) == id, "beside them the agent's own thread is proven")
end

-- Codex files a rollout under its thread's local start date, which can be a day either side of the UTC one: a thread
-- that started at 10:31 UTC is filed on the 14th 12 h west, the 15th at UTC and in New Zealand, the 16th 14 h east.
do
	local created = T0 + 2 * HOUR + 30 * MINUTE
	for _, east in { 0, 13 * HOUR, 14 * HOUR, -8 * HOUR, -12 * HOUR } do
		local w = new_rollouts(created + 5 * MINUTE)
		local id, path = thread(w, 1, created + MINUTE, CWD, east)
		local sid = look(w, ask_at(created, created + 5 * MINUTE))
		check(sid == id, "a thread filed under " .. path .. " is found")
		check(
			table.concat(w.listed, ",")
				== CODEX_ROOT .. "/2027/01/14," .. CODEX_ROOT .. "/2027/01/15," .. CODEX_ROOT .. "/2027/01/16",
			"the start's dates in every zone are listed: " .. table.concat(w.listed, ",")
		)
	end
end

-- Only the names Codex gives rollouts become reader paths: never another file, nor an id that is not a lowercase uuid.
do
	local w = new_rollouts(T0 + MINUTE)
	local id, path = thread(w, 1, T0 + 10 * SECOND, CWD)
	local dir = CODEX_ROOT .. "/2027/01/15"
	local stamped = "rollout-2027-01-15T08-00-20-"
	local others = {
		"notes.txt",
		"../" .. stamped .. thread_id(T0 + 20 * SECOND, 3) .. ".jsonl",
		stamped .. string.upper(thread_id(T0 + 20 * SECOND, 4)) .. ".jsonl",
		stamped .. thread_id(T0 + 20 * SECOND, 5) .. ".jsonl.bak",
		"rollout-" .. thread_id(T0 + 20 * SECOND, 6) .. ".jsonl",
		stamped .. "x;rm -rf ~.jsonl",
		stamped .. thread_id(T0 + 20 * SECOND, 7) .. ".jsonl\n",
	}
	for _, name in others do
		table.insert(w.folders[dir], name)
	end
	check(look(w, ask_at(T0, T0 + MINUTE)) == id, "a rollout is still found beside other names")
	check(#w.runs == 1 and given(w, 1) == "2048 " .. path, "and only it is read: " .. given(w, 1))
end

-- A rollout whose head is not the `session_meta` line of the thread its name carries is no candidate, which is warned
-- once, and it does not hide the agent's thread. An empty head (a rollout that could not be read) is not warned.
do
	local w = new_rollouts(T0 + MINUTE)
	local function id_at(n: number): string
		return thread_id(T0 + n * SECOND, n)
	end
	local function at(n: number): string
		return stamp(T0 + n * SECOND)
	end
	local cut = rollout_text(id_at(5), at(5), CWD)
	local heads: { [number]: string } = {
		[1] = "not json",
		[2] = '{"type":"response_item","payload":{"id":"'
			.. id_at(2)
			.. '","timestamp":"'
			.. at(2)
			.. '","cwd":"'
			.. CWD
			.. '"}}',
		[3] = rollout_text(id_at(99), at(3), CWD),
		[4] = (string.gsub(rollout_text(id_at(4), at(4), CWD), '"cwd":"/work/app"', '"cwd":"\\/work\\/app"', 1)),
		[5] = string.sub(cut, 1, (string.find(cut, '"cwd"', 1, true) :: number) - 1),
		[6] = rollout_text(id_at(6), "2027-13-01T00:00:06Z", CWD),
		[7] = rollout_text(id_at(7), "2027-01-15T08:00:07", CWD),
		[8] = '{"type":"session_meta","payload":"' .. id_at(8) .. '"}',
		[9] = '{"payload":{"id":"'
			.. id_at(9)
			.. '","timestamp":"'
			.. at(9)
			.. '","cwd":"'
			.. CWD
			.. '"},"type":"session_meta"}',
		[10] = (string.gsub(rollout_text(id_at(10), at(10), CWD), '"id":"[^"]*"', '"id":10', 1)),
		[11] = "",
	}
	for n, head in heads do
		file(w, id_at(n), T0 + n * SECOND, head)
	end
	local sid, calls = look(w, ask_at(T0, T0 + MINUTE))
	check(sid == nil and calls == 1, "malformed heads prove nothing")
	check(#w.runs == 1 and #w.runs[1] == 16, "every one of them was read: " .. given(w, 1))
	check(
		#w.warnings == 1 and w.warnings[1] == "jumpr: session lookup: bad codex rollout file",
		"they are warned once: " .. table.concat(w.warnings, "; ")
	)
	local id = thread(w, 20, T0 + 20 * SECOND, CWD)
	check(look(w, ask_at(T0, T0 + MINUTE)) == id, "beside them the agent's own thread is proven")
	check(#w.warnings == 1, "a repeated bad-file reason is not warned again")
end

-- A date folder that cannot be listed is warned once, and the other folders are still read.
do
	local w = new_rollouts(T0 + MINUTE)
	local id = thread(w, 1, T0 + 10 * SECOND, CWD)
	w.list_err[CODEX_ROOT .. "/2027/01/14"] = "permission denied"
	check(look(w, ask_at(T0, T0 + MINUTE)) == id, "a folder that cannot be listed does not hide the next one's thread")
	check(w.warnings[1] == "jumpr: session lookup: cannot list codex sessions", "and is warned")
end

-- A reader that fails proves nothing and is warned once.
do
	local w = new_rollouts(T0 + MINUTE)
	thread(w, 1, T0 + 10 * SECOND, CWD)
	w.broken = true
	local sid, calls = look(w, ask_at(T0, T0 + MINUTE))
	check(sid == nil and calls == 1, "a failed reader proves nothing")
	check(w.warnings[1] == "jumpr: session lookup: cannot read codex rollouts", "and is warned")
end

-- At most 30 rollouts are read in one lookup: with 31 to read none is (one left unread could be a second candidate),
-- and that is warned once; 30 are read.
do
	local w = new_rollouts(T0 + MINUTE)
	local id = thread(w, 1, T0 + SECOND, CWD)
	for n = 2, 30 do
		thread(w, n, T0 + n * SECOND, OTHER)
	end
	check(look(w, ask_at(T0, T0 + MINUTE)) == id and #w.runs[1] == 35, "30 rollouts are read in one lookup")
	thread(w, 31, T0 + 31 * SECOND, OTHER)
	local sid, calls = look(w, ask_at(T0, T0 + MINUTE))
	check(sid == nil and calls == 1 and #w.runs == 1, "31 to read prove nothing, and none is read")
	check(w.warnings[1] == "jumpr: session lookup: too many codex threads to tell apart", "which is warned")
end

-- A thread that started in the window of another codex agent in the folder that holds no thread may be that agent's:
-- it is proven for neither. It counts again once that agent ended before the thread started, or when the thread
-- started before that agent's window.
do
	local w = new_rollouts(T0 + 5 * MINUTE)
	local id = thread(w, 1, T0 + 40 * SECOND, CWD)
	local ask = ask_at(T0, T0 + 5 * MINUTE)
	ask.rivals = { { created_ms = T0 + 20 * SECOND } }
	check(look(w, ask) == nil, "a thread in another agent's window is proven for neither")
	ask.rivals = { { created_ms = T0 + 20 * SECOND, ended_ms = T0 + 30 * SECOND } }
	check(look(w, ask) == id, "an agent that ended before the thread started does not hold it back")
	ask.rivals = { { created_ms = T0 + 2 * MINUTE } }
	check(look(w, ask) == id, "nor does one whose window opens after the thread started")
end

-- The lookup waits for its reader, and a second answer is ignored.
do
	local w = new_rollouts(T0 + MINUTE)
	local id = thread(w, 1, T0 + 10 * SECOND, CWD)
	w.hold = true
	local calls = 0
	local got: string? = nil
	Sessions.find_thread(rollouts_compat(w), HOME, ask_at(T0, T0 + MINUTE), function(sid: string?)
		calls += 1
		got = sid
	end)
	check(calls == 0 and #w.pending == 1, "the lookup waits for its reader")
	w.pending[1]()
	w.pending[1]()
	check(calls == 1 and got == id, "its answer calls back once")
end

-- A trailing slash on the home directory is not doubled into the sessions folder.
do
	local w = new_rollouts(T0 + MINUTE)
	local id = thread(w, 1, T0 + 10 * SECOND, CWD)
	check(look(w, ask_at(T0, T0 + MINUTE), "/work/") == id, "a trailing-slash home still finds the thread")
	check(w.listed[1] == CODEX_ROOT .. "/2027/01/14", "under the same folders")
end

-- A thread picked in Codex's resume picker can be any age, but resuming appends to its rollout: the one rollout of the
-- agent's folder modified at or after the restart proves it. One search of the whole sessions folder finds it, for
-- the minutes since the restart (rounded up, and one more), at most 31 files and 2048 bytes of each line 1.
do
	local w = new_rollouts(T0 + 90 * SECOND)
	local old, path = thread(w, 1, T0 - 30 * DAY, CWD)
	w.mtimes[path] = (T0 + 40 * SECOND) // SECOND
	local sid, calls = look(w, ask_at(T0, T0 + 90 * SECOND, true))
	check(sid == old and calls == 1, "the folder's one rollout written since the restart is proven")
	check(#w.listed == 0 and #w.runs == 1, "by one search, listing no date folder")
	check(given(w, 1) == CODEX_ROOT .. " 3 31 2048", "of the sessions folder: " .. given(w, 1))
end

-- Rollouts written before the restart (within the search's whole minutes), of another folder, or of a thread another
-- record holds do not count; two of the folder written since the restart prove neither.
do
	local w = new_rollouts(T0 + 90 * SECOND)
	local function written(n: number, cwd: string, at: number): string
		local id, path = thread(w, n, T0 - n * DAY, cwd)
		w.mtimes[path] = at // SECOND
		return id
	end
	local mine = written(1, CWD, T0 + 30 * SECOND)
	written(2, CWD, T0 - 30 * SECOND)
	written(3, OTHER, T0 + 40 * SECOND)
	local held = written(4, CWD, T0 + 50 * SECOND)
	local ask = ask_at(T0, T0 + 90 * SECOND, true)
	ask.taken = { [held] = true }
	check(look(w, ask) == mine, "only the rollout of the folder written since the restart counts")
	check(#w.runs == 1 and #w.listed == 0, "from one search")
	written(5, CWD, T0 + 60 * SECOND)
	check(look(w, ask) == nil, "two of the folder written since the restart prove neither")
end

-- The picker can start a new thread instead: written since the restart, it is proven the same way.
do
	local w = new_rollouts(T0 + 3 * MINUTE)
	local id, path = thread(w, 1, T0 + 30 * SECOND, CWD)
	w.mtimes[path] = (T0 + 2 * MINUTE) // SECOND
	check(look(w, ask_at(T0, T0 + 3 * MINUTE, true)) == id, "a new thread started from the picker is proven")
end

-- The new thread of another codex agent in the folder, written since the restart, is left to that agent.
do
	local w = new_rollouts(T0 + 3 * MINUTE)
	local old, path = thread(w, 1, T0 - DAY, CWD)
	w.mtimes[path] = (T0 + 2 * MINUTE) // SECOND
	local _, theirs = thread(w, 2, T0 + 50 * SECOND, CWD)
	w.mtimes[theirs] = (T0 + 2 * MINUTE + 5 * SECOND) // SECOND
	local ask = ask_at(T0, T0 + 3 * MINUTE, true)
	check(look(w, ask) == nil, "an unknown agent's thread written since makes two")
	ask.rivals = { { created_ms = T0 + 40 * SECOND } }
	check(look(w, ask) == old, "another agent's new thread is left to it, and the picked one is proven")
end

-- A reader's answer is checked line by line: a rollout the lookup did not name, a time on a named one, no time or a bad
-- time from the search, and a path outside the sessions folder's date folders never count.
do
	local w = new_rollouts(T0 + MINUTE)
	local id = thread(w, 1, T0 + 10 * SECOND, CWD)
	local other = thread_id(T0 + 20 * SECOND, 2)
	local text = rollout_text(other, stamp(T0 + 20 * SECOND), CWD)
	local named = CODEX_ROOT .. "/2027/01/15/rollout-2027-01-15T08-00-20-" .. other .. ".jsonl"
	w.extra = "\030- " .. named .. "\n" .. text .. "\0301800000030 " .. named .. "\n" .. text
	check(look(w, ask_at(T0, T0 + MINUTE)) == id, "rollouts the lookup did not name do not count")

	local picked = new_rollouts(T0 + MINUTE)
	local old, path = thread(picked, 1, T0 - DAY, CWD)
	picked.mtimes[path] = (T0 + 30 * SECOND) // SECOND
	local after = string.format("%d ", (T0 + 40 * SECOND) // SECOND)
	local name = "rollout-2027-01-15T08-00-20-" .. other .. ".jsonl"
	picked.extra = "\030- "
		.. named
		.. "\n"
		.. text
		.. "\0301800000x40 "
		.. named
		.. "\n"
		.. text
		.. "\030"
		.. after
		.. "/elsewhere/.codex/sessions/2027/01/15/"
		.. name
		.. "\n"
		.. text
		.. "\030"
		.. after
		.. CODEX_ROOT
		.. "/"
		.. name
		.. "\n"
		.. text
		.. "\030"
		.. after
		.. CODEX_ROOT
		.. "/2027/01/15/x/"
		.. name
		.. "\n"
		.. text
		.. "\030"
		.. after
		.. CODEX_ROOT
		.. "/2027/01/15/notes.jsonl\n"
		.. text
	check(look(picked, ask_at(T0, T0 + MINUTE, true)) == old, "a search's malformed lines do not count")
end

-- A search that prints more than 30 rollouts proves nothing, even when the one of the agent's folder is among them: one
-- it did not print could be a second candidate. It is asked for 31 at most, so it can say there were more; with 30 the
-- folder's one rollout is proven.
do
	local w = new_rollouts(T0 + MINUTE)
	local paths: { string } = {}
	local mine = ""
	for n = 1, 40 do
		local id, path = thread(w, n, T0 - n * DAY, if n == 40 then CWD else OTHER)
		w.mtimes[path] = (T0 + n * SECOND) // SECOND
		paths[n] = path
		if n == 40 then
			mine = id
		end
	end
	local sid, calls = look(w, ask_at(T0, T0 + MINUTE, true))
	check(sid == nil and calls == 1, "a search past 30 rollouts proves nothing")
	check(string.find(given(w, 1), " 31 2048$") ~= nil, "it asks for 31 rollouts at most: " .. given(w, 1))
	for n = 1, 10 do
		w.mtimes[paths[n]] = nil
	end
	check(look(w, ask_at(T0, T0 + MINUTE, true)) == mine, "with 30 printed, the folder's one rollout is proven")
end

print("Sessions: " .. checks .. " checks passed")
