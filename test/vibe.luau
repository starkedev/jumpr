--!strict
-- Vibe follower behaviour: which omp agents have a worker turn in flight, read through an injected compat.
-- Pure test harness: no `tern`.

local Vibe = require("../lib/host/vibe")

local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local HOME = "/home/u"
local A = "k2x7abcd"
local B = "m3q4wxyz"
local FILE_1 = "2026-11-15T18-57-06-999Z_0a1b2c3d.jsonl"
local FILE_2 = "2026-11-16T09-00-00-000Z_0e4f5a6b.jsonl"

-- The stamp every line carries unless a test says otherwise, and its epoch ms.
local STAMP = "2026-11-15T18:57:11.771Z"
local T = 1794769031771

type World = {
	dirs: { [string]: { string } },
	values: { [string]: any },
	tokens: number,
	listed: { string },
	runs: { { string } },
	pending: { (stdout: string?) -> () },
}

type Part = { path: string, size: string, lines: { string } }

type Done = { calls: number, changed: boolean? }

local function new_world(): World
	return { dirs = {}, values = {}, tokens = 0, listed = {}, runs = {}, pending = {} }
end

local function dir_of(id: string): string
	return HOME .. "/.omp/deck/" .. id
end

local function path_of(id: string, name: string): string
	return dir_of(id) .. "/" .. name
end

local function files(world: World, id: string, names: { string })
	world.dirs[dir_of(id)] = names
end

local function compat_of(world: World): Vibe.Compat
	return {
		fs_list = function(path: string): ({ string }?, string?)
			world.listed[#world.listed + 1] = path
			local names = world.dirs[path]
			if names == nil then
				return nil, nil
			end
			return table.clone(names), nil
		end,
		json_decode = function(text: string): (any, string?)
			local value = world.values[text]
			if value == nil then
				return nil, "bad json"
			end
			return value, nil
		end,
		run_output = function(argv: { string }, cb: (stdout: string?) -> ())
			if
				argv[1] ~= "sh"
				or argv[2] ~= "-c"
				or argv[4] ~= "sh"
				or #argv < 6
				or string.find(argv[5], "^%d+$") == nil
			then
				error("the reader was not one sh -c with offsets and paths")
			end
			world.runs[#world.runs + 1] = table.clone(argv)
			world.pending[#world.pending + 1] = cb
		end,
	}
end

-- A line the fake decoder turns into `value`.
local function line(world: World, value: any): string
	world.tokens += 1
	local token = "line-" .. world.tokens
	world.values[token] = value
	return token
end

local function life(world: World, worker: string, action: string, stamp: string?): string
	return line(world, {
		type = "custom",
		customType = "vibe-session-lifecycle",
		data = { version = 1, id = worker, ownerId = "Main", action = action, turn = 1 },
		timestamp = stamp or STAMP,
	})
end

local function exit_line(world: World): string
	return line(world, { type = "custom", customType = "session_exit", timestamp = STAMP })
end

local function mode_line(world: World, mode: string): string
	return line(world, { type = "mode_change", timestamp = STAMP, mode = mode })
end

-- The reader's stdout: per agent, a header naming the file it chose and that file's size, then its matching lines.
local function output(parts: { Part }): string
	local out: { string } = {}
	for _, part in parts do
		out[#out + 1] = "\030" .. part.path .. "\030" .. part.size .. "\n"
		for _, text in part.lines do
			out[#out + 1] = text .. "\n"
		end
	end
	return table.concat(out)
end

local function poll(world: World, f: Vibe.Follower, ids: { string }): Done
	local done: Done = { calls = 0, changed = nil }
	Vibe.poll(f, compat_of(world), HOME, ids, function(changed: boolean)
		done.calls += 1
		done.changed = changed
	end)
	return done
end

-- Answers the oldest running reader.
local function answer(world: World, stdout: string?)
	local cb = table.remove(world.pending, 1)
	assert(cb ~= nil, "no reader is waiting for an answer")
	cb(stdout)
end

-- One poll answered at once.
local function step(world: World, f: Vibe.Follower, ids: { string }, parts: { Part }): Done
	local done = poll(world, f, ids)
	answer(world, output(parts))
	return done
end

-- One poll of agent A alone, answered at once with one file's size and lines.
local function read_a(world: World, f: Vibe.Follower, size: string, lines: { string }): Done
	return step(world, f, { A }, { { path = path_of(A, FILE_1), size = size, lines = lines } })
end

local function last_run(world: World): { string }
	return world.runs[#world.runs]
end

local function count(set: { [string]: true }): number
	local n = 0
	for _ in set do
		n += 1
	end
	return n
end

local function is_vibing(f: Vibe.Follower, id: string): boolean
	return Vibe.vibing(f)[id] == true
end

-- A follower holding agent A at offset 120 of FILE_1 with worker W1 in flight.
local function vibing_a(world: World): Vibe.Follower
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	read_a(world, f, "120", { life(world, "W1", "turn-started") })
	assert(is_vibing(f, A), "setup: A is vibing")
	return f
end

-- A started turn makes the agent vibing; its settle clears it. Each poll reads on from the last size.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	local first = poll(world, f, { A })
	check(first.calls == 0, "done waits for the reader")
	check(#world.runs == 1, "one reader is started")
	local argv = last_run(world)
	check(#argv == 7, "one agent gives one offset, its last file and its files")
	check(
		argv[5] == "0" and argv[6] == "-" and argv[7] == path_of(A, FILE_1),
		"the first read starts at offset 0 with no last file"
	)
	check(world.listed[1] == dir_of(A), "the agent's deck folder is listed")
	local started = { life(world, "W1", "spawn"), life(world, "W1", "turn-started") }
	answer(world, output({ { path = path_of(A, FILE_1), size = "120", lines = started } }))
	check(is_vibing(f, A), "a started turn makes the agent vibing")
	check(count(Vibe.vibing(f)) == 1, "only that agent is vibing")

	local second = read_a(world, f, "200", { life(world, "W1", "turn-settled") })
	check(last_run(world)[5] == "120", "the second read starts at the first read's size")
	check(second.calls == 1 and second.changed == true, "a settle reports a change once")
	check(not is_vibing(f, A), "a settled turn clears vibing")

	local third = read_a(world, f, "200", {})
	check(last_run(world)[5] == "200", "the offset advances to the last size")
	check(third.calls == 1 and third.changed == false, "nothing new reports no change")
end

-- Two workers in flight: one settles and the agent is still vibing.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	read_a(world, f, "100", { life(world, "W1", "turn-started"), life(world, "W2", "turn-started") })
	local done = read_a(world, f, "150", { life(world, "W1", "turn-settled") })
	check(is_vibing(f, A), "one worker still running keeps the agent vibing")
	check(done.changed == false, "the set did not change while one worker still runs")
	read_a(world, f, "190", { life(world, "W2", "turn-settled") })
	check(not is_vibing(f, A), "the last settle clears vibing")
end

-- Lines apply in file order within one read.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	read_a(world, f, "100", { life(world, "W1", "turn-started"), life(world, "W1", "turn-settled") })
	check(not is_vibing(f, A), "a start then a settle in one read is not vibing")
	read_a(world, f, "200", { life(world, "W1", "turn-settled"), life(world, "W1", "turn-started") })
	check(is_vibing(f, A), "a settle then a start in one read is vibing")
end

-- A tombstone clears its worker; a revoked tombstone or a spawn starts nothing.
do
	local world = new_world()
	local f = vibing_a(world)
	local done = read_a(world, f, "150", { life(world, "W1", "tombstone") })
	check(not is_vibing(f, A), "a tombstone clears its worker")
	check(done.changed == true, "a tombstone reports a change")
	read_a(world, f, "190", { life(world, "W1", "tombstone-revoked"), life(world, "W2", "spawn") })
	check(not is_vibing(f, A), "a revoked tombstone and a spawn start no turn")
end

-- A tombstone for another worker leaves the running one in flight.
do
	local world = new_world()
	local f = vibing_a(world)
	read_a(world, f, "150", { life(world, "W9", "tombstone") })
	check(is_vibing(f, A), "another worker's tombstone keeps the agent vibing")
end

-- session_exit clears every worker.
do
	local world = new_world()
	local f = vibing_a(world)
	read_a(world, f, "150", { life(world, "W2", "turn-started"), exit_line(world) })
	check(not is_vibing(f, A), "session_exit clears every worker")
end

-- Leaving vibe mode clears every worker; entering it does not.
do
	local world = new_world()
	local f = vibing_a(world)
	read_a(world, f, "150", { mode_line(world, "vibe") })
	check(is_vibing(f, A), "a mode_change to vibe keeps the workers")
	read_a(world, f, "190", { life(world, "W2", "turn-started"), mode_line(world, "none") })
	check(not is_vibing(f, A), "a mode_change to none clears every worker")
	read_a(world, f, "230", { life(world, "W3", "turn-started"), mode_line(world, "plan") })
	check(not is_vibing(f, A), "a mode_change to any other mode clears every worker")
end

-- A turn stamped before the restart belongs to a dead process; at or after it counts.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	Vibe.restarted(f, A, T + 1)
	local done = read_a(world, f, "100", { life(world, "W1", "turn-started") })
	check(not is_vibing(f, A), "a turn 1 ms before since_ms is ignored, even when restarted before the first poll")
	check(done.changed == false, "an ignored turn reports no change")
	read_a(world, f, "200", { life(world, "W2", "turn-started", "2026-11-15T18:57:11.772Z") })
	check(is_vibing(f, A), "a turn stamped exactly at since_ms counts")
end

do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	Vibe.restarted(f, A, T)
	read_a(world, f, "100", { life(world, "W1", "turn-started", "2026-11-15T18:57:12.000Z") })
	check(is_vibing(f, A), "a turn stamped after since_ms counts")
end

-- Without a restart the file's history is trusted, however old.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	read_a(world, f, "100", { life(world, "W1", "turn-started", "1999-01-01T00:00:00.000Z") })
	check(is_vibing(f, A), "with no since_ms an old turn counts")
end

-- A turn with no readable stamp cannot prove it is newer than the restart.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	Vibe.restarted(f, A, 0)
	read_a(world, f, "100", { life(world, "W1", "turn-started", "2026-11-15 18:57:11") })
	check(not is_vibing(f, A), "a malformed stamp is ignored after a restart")
end

-- Stamps are read as UTC across a leap day and month ends.
do
	local cases: { { stamp: string, ms: number } } = {
		{ stamp = "1970-01-01T00:00:00.000Z", ms = 0 },
		{ stamp = "2000-02-29T00:00:00.000Z", ms = 951782400000 },
		{ stamp = "2000-03-01T00:00:00.000Z", ms = 951782400000 + 86400000 },
		{ stamp = "2026-01-01T00:00:00.000Z", ms = 1767225600000 },
		{ stamp = "2025-12-31T23:59:59.999Z", ms = 1767225600000 - 1 },
	}
	for _, case in cases do
		local world = new_world()
		files(world, A, { FILE_1 })
		local before = Vibe.new()
		Vibe.restarted(before, A, case.ms + 1)
		read_a(world, before, "10", { life(world, "W1", "turn-started", case.stamp) })
		check(not is_vibing(before, A), case.stamp .. " is before one ms after it")
		local at = Vibe.new()
		Vibe.restarted(at, A, case.ms)
		read_a(world, at, "10", { life(world, "W1", "turn-started", case.stamp) })
		check(is_vibing(at, A), case.stamp .. " is not before its own ms")
	end
end

-- A restart empties what the agent held at once.
do
	local world = new_world()
	local f = vibing_a(world)
	Vibe.restarted(f, A, T + 1000)
	check(not is_vibing(f, A), "a restart empties the in-flight set")
	read_a(world, f, "150", {})
	check(last_run(world)[5] == "120", "a restart keeps reading from the same offset")
end

-- A newer session file: every usable name is passed on, and the header names the file the reader chose, which
-- is what the follower then reads; a change of chosen file starts that file's history over, keeping since_ms.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	Vibe.restarted(f, A, T)
	read_a(world, f, "120", { life(world, "W1", "turn-started") })
	check(is_vibing(f, A), "setup: A is vibing in the first file")
	files(world, A, { FILE_1, FILE_2, "notes.txt" })
	local done = poll(world, f, { A })
	local argv = last_run(world)
	check(
		argv[5] == "120"
			and argv[6] == path_of(A, FILE_1)
			and argv[7] == path_of(A, FILE_1)
			and argv[8] == path_of(A, FILE_2),
		"every session file is passed on, with the offset of the file it was read from"
	)
	answer(world, output({ { path = path_of(A, FILE_2), size = "50", lines = {} } }))
	check(not is_vibing(f, A), "a newly chosen file starts with an empty set")
	check(done.changed == true, "the switch reports a change")
	read_a(world, f, "90", { life(world, "W2", "turn-started", "2026-11-15T18:57:11.770Z") })
	check(last_run(world)[6] == path_of(A, FILE_2), "the chosen file is read again with its own offset")
	check(not is_vibing(f, A), "since_ms survives a file switch")
end

-- A size below the offset means the file was rewritten: read it again from 0 with an empty set.
do
	local world = new_world()
	local f = vibing_a(world)
	local done = read_a(world, f, "80", {})
	check(not is_vibing(f, A), "a shrunk file empties the set")
	check(done.changed == true, "a shrunk file reports a change")
	read_a(world, f, "80", { life(world, "W1", "turn-started") })
	check(last_run(world)[5] == "0", "a shrunk file is read again from offset 0")
	check(is_vibing(f, A), "the rewritten file's lines apply")
end

-- An equal size reads nothing new and keeps the set.
do
	local world = new_world()
	local f = vibing_a(world)
	read_a(world, f, "120", {})
	check(is_vibing(f, A), "an unchanged size keeps the set")
	read_a(world, f, "120", {})
	check(last_run(world)[5] == "120", "an unchanged size keeps the offset")
end

-- A failed reader changes nothing, not even dropping an agent left out of the poll.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	files(world, B, { FILE_1 })
	local f = Vibe.new()
	step(world, f, { A, B }, {
		{ path = path_of(A, FILE_1), size = "120", lines = { life(world, "W1", "turn-started") } },
		{ path = path_of(B, FILE_1), size = "60", lines = { life(world, "W1", "turn-started") } },
	})
	local done = poll(world, f, { A })
	answer(world, nil)
	check(done.calls == 1 and done.changed == false, "a failed reader calls done(false) once")
	check(is_vibing(f, A) and is_vibing(f, B), "a failed reader leaves every agent as it was")
	step(world, f, { A, B }, {
		{ path = path_of(A, FILE_1), size = "120", lines = {} },
		{ path = path_of(B, FILE_2), size = "60", lines = {} },
	})
	local argv = last_run(world)
	check(argv[5] == "120" and argv[8] == "60", "a failed reader leaves the offsets as they were")
end

-- A poll while the reader runs does nothing; the next one after the answer starts again.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	local first = poll(world, f, { A })
	local second = poll(world, f, { A })
	check(#world.runs == 1, "a poll during a running reader starts no second one")
	check(second.calls == 0, "a skipped poll never calls done")
	answer(
		world,
		output({ { path = path_of(A, FILE_1), size = "120", lines = { life(world, "W1", "turn-started") } } })
	)
	check(first.calls == 1, "the running poll calls done once")
	check(second.calls == 0, "the skipped poll still never calls done")
	local third = poll(world, f, { A })
	check(#world.runs == 2, "a poll after the answer starts a reader")
	answer(world, nil)
	check(third.calls == 1, "a failed poll also frees the follower")
	poll(world, f, { A })
	check(#world.runs == 3, "a poll after a failure starts a reader")
end

-- A second answer from the same reader is ignored.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	local done = poll(world, f, { A })
	local cb = table.remove(world.pending, 1) :: (stdout: string?) -> ()
	cb(output({ { path = path_of(A, FILE_1), size = "20", lines = { life(world, "W1", "turn-started") } } }))
	cb(output({ { path = path_of(A, FILE_1), size = "30", lines = { life(world, "W1", "turn-settled") } } }))
	check(done.calls == 1, "a reader answering twice calls done once")
	check(is_vibing(f, A), "a second answer is not applied")
	read_a(world, f, "30", {})
	check(last_run(world)[5] == "20", "a second answer does not move the offset")
end

-- An id left out of the poll is dropped, and that is a change.
do
	local world = new_world()
	local f = vibing_a(world)
	files(world, B, { FILE_1 })
	local done = step(world, f, { B }, { { path = path_of(B, FILE_1), size = "10", lines = {} } })
	check(not is_vibing(f, A), "an id left out of ids is dropped")
	check(done.changed == true, "dropping a vibing id reports a change")
	local argv = last_run(world)
	check(#argv == 7 and argv[7] == path_of(B, FILE_1), "only the polled ids are read")
end

-- With no ids no reader starts and done runs at once, reporting a drop.
do
	local world = new_world()
	local f = vibing_a(world)
	local done = poll(world, f, {})
	check(#world.runs == 1, "no ids starts no reader")
	check(done.calls == 1 and done.changed == true, "no ids calls done at once with the drop")
	check(count(Vibe.vibing(f)) == 0, "no ids drops every agent")
	local again = poll(world, f, {})
	check(again.calls == 1 and again.changed == false, "no ids and nothing held reports no change")
end

-- A dropped id loses its since_ms: polled again, the file's history is trusted.
do
	local world = new_world()
	local f = vibing_a(world)
	Vibe.restarted(f, A, T + 1)
	poll(world, f, {})
	read_a(world, f, "100", { life(world, "W1", "turn-started") })
	check(is_vibing(f, A), "a dropped id's since_ms is forgotten")
	check(last_run(world)[5] == "0", "a dropped id is read again from offset 0")
end

-- Undecodable lines are skipped and the rest still apply.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	read_a(world, f, "100", { '{"type":"custom","customType"', life(world, "W1", "turn-started"), "garbage" })
	check(is_vibing(f, A), "a line that does not decode is skipped")
	read_a(world, f, "150", {})
	check(last_run(world)[5] == "100", "undecodable lines still advance the offset")
end

-- Decoded lines of the wrong shape are skipped.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	local lifecycle = "vibe-session-lifecycle"
	read_a(world, f, "100", {
		line(world, "a string"),
		line(world, { type = "custom", customType = lifecycle, data = "x" }),
		line(world, { type = "custom", customType = lifecycle, data = { action = "turn-started" } }),
		line(world, { type = "custom", customType = "other", data = { id = "W1", action = "turn-started" } }),
		line(world, { type = "message", data = { id = "W1", action = "turn-started" } }),
	})
	check(not is_vibing(f, A), "lines of the wrong shape start no turn")
	read_a(world, f, "150", { life(world, "W1", "turn-started"), line(world, { type = "x" }) })
	check(is_vibing(f, A), "a line of another type does not clear the set")
end

-- An invalid id never reaches a listing or argv, and is never vibing.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	local bad = { "../" .. A, "a b", "", "k2x7abcd/..", string.rep("a", 65) }
	for _, id in bad do
		Vibe.restarted(f, id, T)
	end
	local ids = table.clone(bad)
	ids[#ids + 1] = A
	step(world, f, ids, { { path = path_of(A, FILE_1), size = "10", lines = { life(world, "W1", "turn-started") } } })
	local argv = last_run(world)
	check(#argv == 7 and argv[7] == path_of(A, FILE_1), "only the valid id is read")
	check(#world.listed == 1 and world.listed[1] == dir_of(A), "an invalid id is never listed")
	check(count(Vibe.vibing(f)) == 1 and is_vibing(f, A), "an invalid id is never vibing")
end

-- A missing folder or one with no usable session name starts no reader and is not vibing.
do
	local world = new_world()
	files(world, B, { "notes.txt", "x.jsonl.bak", ".jsonl", "a b.jsonl", "../x.jsonl" })
	local f = Vibe.new()
	local done = poll(world, f, { A, B })
	check(#world.runs == 0, "no session file starts no reader")
	check(done.calls == 1 and done.changed == false, "no session file calls done at once")
	check(count(Vibe.vibing(f)) == 0, "no session file is not vibing")
end

-- An agent whose folder is gone stops vibing and is read again from 0 when it comes back.
do
	local world = new_world()
	local f = vibing_a(world)
	world.dirs[dir_of(A)] = nil
	local done = poll(world, f, { A })
	check(#world.runs == 1, "a gone folder starts no reader")
	check(done.calls == 1 and done.changed == true, "a gone folder reports the change at once")
	check(not is_vibing(f, A), "a gone folder is not vibing")
	files(world, A, { FILE_1 })
	read_a(world, f, "150", {})
	check(last_run(world)[5] == "0", "a folder that comes back is read from 0")
end
-- Every usable name is passed on and the unusable ones are not; which of them the reader picks is its choice.
do
	local world = new_world()
	files(world, A, { FILE_1, FILE_2, "zz-notes.txt", "zz.jsonl.tmp" })
	local f = Vibe.new()
	poll(world, f, { A })
	local argv = last_run(world)
	check(
		#argv == 8
			and argv[5] == "0"
			and argv[6] == "-"
			and argv[7] == path_of(A, FILE_1)
			and argv[8] == path_of(A, FILE_2),
		"every usable session name is passed on, from offset 0"
	)
end
-- Several agents: headers map to files by order, an empty size leaves its agent alone, missing headers too.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	files(world, B, { FILE_2 })
	local f = Vibe.new()
	step(world, f, { A, B }, {
		{ path = path_of(A, FILE_1), size = "120", lines = { life(world, "W1", "turn-started") } },
		{ path = path_of(B, FILE_2), size = "70", lines = {} },
	})
	check(is_vibing(f, A) and not is_vibing(f, B), "the first header belongs to the first file")
	local argv = last_run(world)
	check(argv[7] == path_of(A, FILE_1) and argv[10] == path_of(B, FILE_2), "files are passed in id order")

	step(world, f, { A, B }, {
		{ path = path_of(A, FILE_1), size = "", lines = {} },
		{ path = path_of(B, FILE_2), size = "90", lines = { life(world, "W5", "turn-started") } },
	})
	check(is_vibing(f, A), "an unreadable file leaves its agent's set alone")
	check(is_vibing(f, B), "the second header belongs to the second file")

	step(
		world,
		f,
		{ A, B },
		{ { path = path_of(A, FILE_1), size = "140", lines = { life(world, "W1", "turn-settled") } } }
	)
	argv = last_run(world)
	check(argv[5] == "120", "an unreadable file leaves its agent's offset alone")
	check(argv[8] == "90", "the second file's offset advanced")
	check(not is_vibing(f, A), "a lone header still applies to the first file")
	check(is_vibing(f, B), "a missing header leaves its agent alone")

	step(world, f, { A, B }, { { path = path_of(A, FILE_1), size = "140", lines = {} } })
	check(last_run(world)[8] == "90", "a missing header leaves its agent's offset alone")
end

-- A repeated id is read once.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	poll(world, f, { A, A })
	check(#last_run(world) == 7, "a repeated id is read once")
end

-- A trailing slash on home is not doubled into the folder.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	Vibe.poll(f, compat_of(world), HOME .. "/", { A }, function(_changed: boolean) end)
	check(world.listed[1] == dir_of(A), "a trailing slash on home is not doubled")
	check(last_run(world)[7] == path_of(A, FILE_1), "a trailing slash on home does not change the path")
end

-- An agent that restarts while a reader is running keeps what `restarted` recorded: the answer may not prune it.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	files(world, B, { FILE_1 })
	local f = Vibe.new()
	step(world, f, { A, B }, {
		{ path = path_of(A, FILE_1), size = "120", lines = { life(world, "W1", "turn-started") } },
		{ path = path_of(B, FILE_1), size = "60", lines = {} },
	})
	check(is_vibing(f, A), "setup: A is vibing")
	-- B restarts while the reader runs: its restart window must survive the answer.
	local done = poll(world, f, { A, B })
	Vibe.restarted(f, B, T + 5000)
	answer(
		world,
		output({
			{ path = path_of(A, FILE_1), size = "140", lines = { life(world, "W1", "turn-settled") } },
			{ path = path_of(B, FILE_1), size = "80", lines = {} },
		})
	)
	check(done.changed == true, "the answer reports A's settle")
	check(not is_vibing(f, A), "the answer applies A's settle")
	check(f.agents[B] ~= nil and f.agents[B].since_ms == T + 5000, "a restart during the reader survives its answer")
	-- A turn B's dead process left running, stamped before the restart, no longer counts.
	step(world, f, { A, B }, {
		{ path = path_of(A, FILE_1), size = "140", lines = {} },
		{
			path = path_of(B, FILE_1),
			size = "90",
			lines = { life(world, "W9", "turn-started", "2026-11-15T18:57:11.770Z") },
		},
	})
	check(not is_vibing(f, B), "a turn stamped before the mid-reader restart is ignored")
end

-- `clear` drops every agent, restart windows included.
do
	local world = new_world()
	local f = vibing_a(world)
	Vibe.restarted(f, A, T)
	Vibe.clear(f)
	check(count(Vibe.vibing(f)) == 0, "clear drops every vibing agent")
	read_a(world, f, "120", { life(world, "W1", "turn-started", "2026-11-15T18:57:11.770Z") })
	check(is_vibing(f, A), "after a clear the file's history is trusted again")
end

-- A reader that is still running when `clear` lands has its answer dropped: it describes a list nobody asked for,
-- and a poll started after the clear applies as usual.
do
	local world = new_world()
	files(world, A, { FILE_1 })
	local f = Vibe.new()
	local stale = poll(world, f, { A })
	Vibe.clear(f)
	answer(
		world,
		output({ { path = path_of(A, FILE_1), size = "120", lines = { life(world, "W1", "turn-started") } } })
	)
	check(stale.calls == 1 and stale.changed == false, "a cleared poll's answer is dropped, reporting no change")
	check(count(Vibe.vibing(f)) == 0 and f.agents[A] == nil, "a cleared poll's answer recreates no agent")
	local fresh = read_a(world, f, "120", { life(world, "W2", "turn-started") })
	check(fresh.changed == true and is_vibing(f, A), "a poll started after the clear applies as usual")
end

print("Vibe: " .. checks .. " checks passed")
