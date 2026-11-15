--!strict
-- Session lookup behaviour: only a proven conversation id comes back, through an injected compat.
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
	missing: boolean,
	list_err: string?,
	hold: boolean,
	listed: { string },
	reads: { string },
	limits: { number },
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
		missing = false,
		list_err = nil,
		hold = false,
		listed = {},
		reads = {},
		limits = {},
		probes = {},
		warnings = {},
		pending = {},
	}
end

local function add(world: World, pid: string, sid: string, cwd: string, status: number)
	local name = pid .. ".json"
	local body = "body-" .. pid
	world.names[#world.names + 1] = name
	world.files[name] = body
	world.objects[body] = { sessionId = sid, cwd = cwd, pid = "../evil" }
	world.status[pid] = status
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
		log_warn = function(text: string)
			world.warnings[#world.warnings + 1] = text
		end,
	}
end

local function run(world: World, kind: string, id: string, cwd: string, taken: { [string]: boolean }): (string?, number)
	world.id = id
	local calls = 0
	local got: string? = nil
	Sessions.find(compat_of(world), world.home, kind, id, cwd, taken, function(sid: string?)
		calls += 1
		got = sid
	end)
	return got, calls
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

-- Claude is the only kind with a conversation lookup.
check(Sessions.has("claude"), "claude conversations can be looked up")
check(not Sessions.has("omp"), "omp conversations are not looked up")
check(not Sessions.has("codex"), "a kind without a recipe is not looked up")
check(not Sessions.has("Claude"), "kind lookup is case-sensitive")
check(not Sessions.has(""), "an empty kind is not looked up")

-- The conversation whose grep exits 0 is returned, and later files are not probed.
do
	local world = new_world()
	add(world, "101", "sid-no", CWD, 1)
	add(world, "102", "sid-yes", CWD, 0)
	add(world, "103", "sid-later", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "sid-yes", "the conversation whose grep exits 0 is returned")
	check(calls == 1, "a proven lookup calls back once")
	check(pids_are(world, { "101", "102" }), "grep stops at the first proof")
	check(#world.reads == 3, "each digit json file is read before probing")
	check(reads_are_bounded(world), "each session file is read at most 65536 bytes")
	check(world.listed[1] == SESSIONS, "the lookup lists the sessions folder")
	check(world.probes[1][5] == "JUMPR_ID=" .. ID, "grep asks for this agent's id")
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
	add(world, "701", "safe-sid", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "safe-sid", "a digit json file is still found beside hostile names")
	check(calls == 1, "a lookup beside hostile names calls back once")
	check(#world.reads == 1, "only the digit json file is read")
	check(world.reads[1] == SESSIONS .. "/701.json", "the read path is rebuilt from digits")
	check(pids_are(world, { "701" }), "a non-numeric name is never passed to grep")
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
	add(world, "201", "other-sid", OTHER, 0)
	add(world, "202", "same-sid", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "same-sid", "a same-folder proof is returned before other folders")
	check(calls == 1, "a same-folder proof calls back once")
	check(pids_are(world, { "202" }), "the other folder is not probed after a same-folder proof")
end

-- A match in another folder is found after the same-folder files miss.
do
	local world = new_world()
	add(world, "301", "other-sid", OTHER, 0)
	add(world, "302", "same-a", CWD, 1)
	add(world, "303", "same-b", CWD, 2)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "other-sid", "a proof in another folder is still found")
	check(calls == 1, "an other-folder proof calls back once")
	check(pids_are(world, { "302", "303", "301" }), "same-folder files are probed before other folders")
end

-- A folder path that only shares a prefix is not treated as the same folder.
do
	local world = new_world()
	add(world, "311", "prefix-sid", CWD .. "-extra", 0)
	add(world, "312", "exact-sid", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "exact-sid", "folder equality is exact")
	check(calls == 1, "an exact-folder proof calls back once")
	check(pids_are(world, { "312" }), "a prefix of the folder is probed with the other files")
end

-- A taken conversation is skipped, and a false flag does not hide one.
do
	local world = new_world()
	add(world, "401", "taken-sid", CWD, 0)
	add(world, "402", "free-sid", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, { ["taken-sid"] = true })
	check(sid == "free-sid", "a taken conversation is not returned")
	check(calls == 1, "a lookup that skips a taken id calls back once")
	check(pids_are(world, { "402" }), "a taken conversation is not probed")
end

do
	local world = new_world()
	add(world, "411", "only-taken", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, { ["only-taken"] = true })
	check(sid == nil, "a listing of only taken conversations proves nothing")
	check(calls == 1, "a taken-only listing calls back once")
	check(#world.probes == 0, "a taken-only listing runs no grep")
end

do
	local world = new_world()
	add(world, "421", "free-sid", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, { ["free-sid"] = false })
	check(sid == "free-sid", "a false taken flag does not hide a conversation")
	check(calls == 1, "a false taken flag still calls back once")
end

-- An invalid session id in a file is not a candidate, even when its grep would match.
do
	local world = new_world()
	add(world, "501", "a/b", CWD, 0)
	add(world, "502", "--continue", CWD, 0)
	add(world, "503", "", CWD, 0)
	add(world, "504", string.rep("s", 65), CWD, 0)
	add(world, "505", "good-sid", OTHER, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "good-sid", "only a valid session id can be returned")
	check(calls == 1, "an invalid session id still calls back once")
	check(pids_are(world, { "505" }), "an invalid session id is not probed")
end

-- No proof calls back nil: every grep misses, including a missing process environment.
do
	local world = new_world()
	add(world, "601", "miss-a", CWD, 2)
	add(world, "602", "miss-b", OTHER, 1)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "no matching process calls back nil")
	check(calls == 1, "a miss calls back once")
	check(pids_are(world, { "601", "602" }), "a non-zero grep tries the next file")
	check(#world.warnings == 0, "a grep miss is not a warning")
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
	add(world, "712", "after-bad", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "after-bad", "a bad file does not hide a proven conversation")
	check(calls == 1, "a proof after bad JSON calls back once")
	check(pids_are(world, { "712" }), "only the readable conversation is probed")
end

-- A missing folder and a list error call back nil.
do
	local world = new_world()
	world.missing = true
	add(world, "801", "would-match", CWD, 0)
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
	add(world, "903", "after-read", OTHER, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "after-read", "a read error does not hide a proven conversation")
	check(calls == 1, "a proof after a read error calls back once")
	check(#world.warnings == 1, "two read errors warn once")
	check(world.warnings[1] == "jumpr: session lookup: cannot read session file", "warning names the read error")
end

-- A kind without a recipe, and an unsafe agent id, call back nil without listing.
do
	local world = new_world()
	add(world, "1001", "omp-sid", CWD, 0)
	local sid, calls = run(world, "omp", ID, CWD, {})
	check(sid == nil, "omp calls back nil")
	check(calls == 1, "omp calls back once")
	check(#world.listed == 0, "omp lists no sessions folder")
	check(#world.reads == 0, "omp reads no session file")
	check(#world.probes == 0, "omp runs no grep")
end

do
	local world = new_world()
	add(world, "1011", "codex-sid", CWD, 0)
	local sid, calls = run(world, "codex", ID, CWD, {})
	check(sid == nil, "a kind without a recipe calls back nil")
	check(calls == 1, "a kind without a recipe calls back once")
	check(#world.listed == 0, "a kind without a recipe lists nothing")
end

do
	local world = new_world()
	add(world, "1021", "unsafe-sid", CWD, 0)
	local sid, calls = run(world, "claude", "a;b", CWD, {})
	check(sid == nil, "an unsafe agent id calls back nil")
	check(calls == 1, "an unsafe agent id calls back once")
	check(#world.listed == 0, "an unsafe agent id lists nothing")
	check(#world.probes == 0, "an unsafe agent id is not passed to grep")
end

-- At most 30 conversations are probed, and same-folder files consume that budget first.
do
	local world = new_world()
	add(world, "2000", "other-match", OTHER, 0)
	for n = 1, 30 do
		add(world, tostring(n), "same-" .. tostring(n), CWD, 1)
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
	add(world, "3001", "first-sid", CWD, 0)
	add(world, "3002", "second-sid", CWD, 0)
	world.unstarted["3001"] = true
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == nil, "a missing grep calls back nil")
	check(calls == 1, "a missing grep calls back once")
	check(pids_are(world, { "3001" }), "a missing grep does not probe the next file")
	check(world.warnings[1] == "jumpr: session lookup: cannot start grep", "a missing grep warns once")
end

-- The lookup waits for grep and ignores a second answer.
do
	local world = new_world()
	world.hold = true
	add(world, "4001", "held-sid", CWD, 0)
	local calls = 0
	local got: string? = nil
	world.id = ID
	Sessions.find(compat_of(world), world.home, "claude", ID, CWD, {}, function(sid: string?)
		calls += 1
		got = sid
	end)
	check(calls == 0, "find waits for grep before calling back")
	check(#world.pending == 1, "one grep is started before it answers")
	world.pending[1](0)
	check(calls == 1, "grep's answer calls back once")
	check(got == "held-sid", "the held proof is the conversation id")
	world.pending[1](0)
	check(calls == 1, "a second grep answer does not call back again")
end

-- A trailing slash on the home directory still lists and reads the sessions folder.
do
	local world = new_world()
	world.home = "/work/"
	add(world, "5001", "slash-sid", CWD, 0)
	local sid, calls = run(world, "claude", ID, CWD, {})
	check(sid == "slash-sid", "a trailing slash on home still finds the conversation")
	check(calls == 1, "a trailing-slash home calls back once")
	check(world.listed[1] == SESSIONS, "a trailing slash is not doubled into the sessions path")
	check(world.reads[1] == SESSIONS .. "/5001.json", "a trailing slash does not change the read path")
end

print("Sessions: " .. checks .. " checks passed")
