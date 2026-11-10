--!strict

local Status = require("../lib/shared/status")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function code_is(entry: Status.Entry?, fresh: boolean, record: Status.RecordState?, want: string, why: string)
	local got = Status.code(entry, fresh, record)
	check(got == want, string.format("%s: got %s, want %s", why, got, want))
end

local LIVE = { state = "live" }

-- error: delivery_error, PaneInfo.error, exit ≠ 0, and an unseen failed turn. Error outranks every other row.
code_is({ s = "w", e = "delivery failed" }, true, LIVE, "error", "delivery_error")
code_is({ s = "i", e = "pane error" }, true, LIVE, "error", "PaneInfo.error")
code_is({ s = "q", e = "x" }, true, LIVE, "error", "an error outranks waiting")
code_is({ s = "x", e = "exit 2" }, true, LIVE, "error", "exit status ≠ 0 from the window")
code_is({ s = "x" }, true, { state = "exited", exit = 1 }, "error", "exit status ≠ 0 from the host record")
code_is({ s = "i", u = true, f = true }, true, LIVE, "error", "the last turn failed and is unseen")
code_is({ s = "i", u = false, f = true }, true, LIVE, "idle", "a failed turn already looked at is idle")
code_is({ s = "i", e = "" }, true, LIVE, "idle", "an empty error string is no error")

-- waiting: waiting_input, or idle with an unseen finish.
code_is({ s = "q" }, true, LIVE, "waiting", "waiting_input")
code_is({ s = "q", u = false }, true, LIVE, "waiting", "waiting_input already seen")
code_is({ s = "i", u = true }, true, LIVE, "waiting", "idle with an unseen finish")

-- running.
code_is({ s = "w" }, true, LIVE, "running", "working")
code_is({ s = "w", u = true }, true, LIVE, "running", "working with an old unseen flag")

-- idle and seen.
code_is({ s = "i" }, true, LIVE, "idle", "idle with no unseen flag")
code_is({ s = "i", u = false }, true, nil, "idle", "idle and seen, no record")

-- stopped: exited with status 0.
code_is({ s = "x" }, true, LIVE, "stopped", "exited with no error")
code_is({ s = "x" }, true, { state = "exited", exit = 0 }, "stopped", "exited with status 0")

-- unknown: no status for the id, or stale status.
code_is(nil, true, nil, "unknown", "no entry and no record")
code_is(nil, true, LIVE, "unknown", "no entry for a live record")
code_is(nil, true, { state = "pending" }, "unknown", "no entry for a pending record")
code_is({ s = "w" }, false, LIVE, "unknown", "stale working status")
code_is({ s = "q", e = "x" }, false, LIVE, "unknown", "stale error status")
code_is({ s = "?" }, true, LIVE, "unknown", "an unrecognised state")

-- No entry and an exited host record: stopped for exit 0, `error` for exit ≠ 0.
code_is(nil, true, { state = "exited", exit = 0 }, "stopped", "no entry, exited 0")
code_is(nil, true, { state = "exited", exit = 3 }, "error", "no entry, exited 3")
code_is(nil, true, { state = "exited" }, "stopped", "no entry, exited with no status")
code_is({ s = "w" }, false, { state = "exited", exit = 0 }, "stopped", "a stale entry for an exited record")
code_is({ s = "w" }, false, { state = "exited", exit = 1 }, "error", "a stale entry for a failed exited record")

-- The one order: error, waiting, running, idle, keyed along the shifted number row.
local want_order = { { "error", "!" }, { "waiting", "@" }, { "running", "#" }, { "idle", "$" } }
check(#Status.ORDER == #want_order, "four ranked statuses")
for i, w in want_order do
	local st = Status.ORDER[i]
	check(st.code == w[1] and st.key == w[2] and st.word == w[1], "ORDER[" .. i .. "] is " .. w[1] .. " on " .. w[2])
	check(Status.of(w[1]) == st, "of finds " .. w[1])
	check(Status.by_key(w[2]) == st, "by_key finds " .. w[2])
end
check(Status.of("stopped") == nil and Status.of("unknown") == nil, "stopped and unknown are not ranked")
check(Status.by_key("&") == nil and Status.by_key("0") == nil, "& and 0 are no status key")
check(Status.of("!") == nil, "a key is not a code")

-- worst ranks error, waiting, running, idle for folded headers (unchanged).
check(Status.worst({ "idle", "running", "waiting", "error" }) == "error", "error ranks first")
check(Status.worst({ "idle", "running", "waiting" }) == "waiting", "waiting ranks before running and idle")
check(Status.worst({ "idle", "running" }) == "running", "running ranks before idle")
check(Status.worst({ "idle", "stopped", "unknown" }) == "idle", "stopped and unknown never rank")
check(Status.worst({ "unknown", "stopped" }) == nil, "only stopped and unknown gives nil")
check(Status.worst({}) == nil, "no codes gives nil")

-- matches: no filter shows everything; unknown and stopped match no filter.
for _, c in { "error", "waiting", "running", "idle", "stopped", "unknown" } do
	check(Status.matches(c, nil), "no filter matches " .. c)
end
for _, f in { "error", "waiting", "running", "idle" } do
	check(Status.matches(f, f), f .. " matches its own filter")
	check(not Status.matches("unknown", f), "unknown matches no filter (" .. f .. ")")
	check(not Status.matches("stopped", f), "stopped matches no filter (" .. f .. ")")
end
check(not Status.matches("running", "waiting"), "a code does not match another filter")
check(not Status.matches("idle", "error"), "idle does not match the error filter")

-- rank: the place in the one order, and everything unranked after it.
check(Status.rank("error") == 1 and Status.rank("waiting") == 2, "error ranks first, waiting second")
check(Status.rank("running") == 3 and Status.rank("idle") == 4, "running third, idle fourth")
check(Status.rank("stopped") == 5 and Status.rank("unknown") == 5, "stopped and unknown rank after every status")

-- The questions an entry answers, for every state letter.
type Answers = { s: string, working: boolean, asking: boolean, idle: boolean }
local answers: { Answers } = {
	{ s = "w", working = true, asking = false, idle = false },
	{ s = "q", working = false, asking = true, idle = false },
	{ s = "i", working = false, asking = false, idle = true },
	{ s = "x", working = false, asking = false, idle = false },
}
for _, want in answers do
	local e: Status.Entry = { s = want.s }
	check(Status.working(e) == want.working, want.s .. ": working")
	check(Status.asking(e) == want.asking, want.s .. ": asking")
	check(Status.idle(e) == want.idle, want.s .. ": idle")
end
check(Status.idle({ s = "i", u = true }), "an idle agent with an unseen finish is still idle")

-- The three samenesses: what the window saw (change time and source aside), what is sent (everything), and what a
-- row shows (change time aside).
do
	local base: Status.Entry = { s = "i", u = true, src = "agents", c = 1000 }
	local restamped: Status.Entry = { s = "i", u = true, src = "agents", c = 2000 }
	local other_src: Status.Entry = { s = "i", u = true, src = "other", c = 1000 }
	local changed: Status.Entry = { s = "i", src = "agents", c = 1000 }
	check(Status.seen_key(base) == Status.seen_key(restamped), "a new change time is not a new sighting")
	check(Status.seen_key(base) == Status.seen_key(other_src), "the source is not part of a sighting")
	check(Status.seen_key(base) ~= Status.seen_key(changed), "a cleared unseen flag is a new sighting")
	check(Status.wire_key({ base }) ~= Status.wire_key({ restamped }), "a new change time is sent again")
	check(Status.wire_key({ base }) ~= Status.wire_key({ other_src }), "a new source is sent again")
	check(Status.wire_key({ base }) == Status.wire_key({ base }), "the same entries are not sent again")
	check(Status.same_display({ base }, { restamped }), "a new change time leaves the row as it was")
	check(not Status.same_display({ base }, { other_src }), "a new source changes the row")
	check(not Status.same_display({ base }, { base, base }), "a second pane changes the row")
	check(Status.same_display(nil, nil) and not Status.same_display({ base }, nil), "nil is only the same as nil")
end

-- The sending side: the first message to a copy is the whole list; later ones carry the changed ids and name the gone
-- ones; a full one carries everything and names nothing gone.
do
	local a1: { Status.Entry } = { { s = "w", src = "agents" } }
	local b1: { Status.Entry } = { { s = "i", src = "agents" } }
	local first = Status.diff(nil, { a = a1, b = b1 }, false)
	check(first.full and first.changed.a == a1 and first.changed.b == b1, "first contact sends a full snapshot")
	check(#first.gone == 0, "a full snapshot names nothing gone")
	local same = Status.diff(first.keys, { a = a1, b = b1 }, false)
	check(not same.full and next(same.changed) == nil and #same.gone == 0, "nothing changed sends an empty diff")
	local a2: { Status.Entry } = { { s = "i", src = "agents", c = 5000 } }
	local moved = Status.diff(first.keys, { a = a2 }, false)
	check(moved.changed.a == a2 and moved.changed.b == nil, "a diff carries only the changed id")
	check(#moved.gone == 1 and moved.gone[1] == "b", "a diff names the id no longer listed")
	local stamped = Status.diff(moved.keys, { a = { { s = "i", src = "agents", c = 6000 } } }, false)
	check(stamped.changed.a ~= nil, "a new change time alone is sent again")
	local resync = Status.diff(moved.keys, { b = b1 }, true)
	check(resync.full and resync.changed.b == b1 and #resync.gone == 0, "a full resync names nothing gone")
end

-- The receiving side: what another machine sent is read defensively, an empty list is gone, and every carried id is
-- stamped with the message's arrival number.
do
	-- What arrived, as untyped as JSON from another machine.
	local raw: any = {
		full = true,
		seq = 1,
		a = {
			ok = { { s = "w", u = true, e = "", src = "agents", c = 0 } :: any, "junk", { u = true } },
			typed = { { s = "i", u = "yes", f = 1, e = 3, src = 4, c = "5" } },
			bad = "not a list",
		},
	}
	local win = Status.apply(nil, raw, 7, 100)
	local ok = win.a.ok
	check(ok ~= nil and #ok == 1, "only the entries of a list are kept")
	check(ok[1].s == "w" and ok[1].u == true and ok[1].src == "agents", "an entry keeps its fields")
	check(ok[1].e == nil and ok[1].c == nil, "an empty error and a zero change time are left out")
	local typed = win.a.typed[1]
	check(
		typed.u == nil and typed.f == nil and typed.e == nil and typed.src == nil and typed.c == nil,
		"wrong types go"
	)
	check(win.a.bad == nil and win.carried.bad == 7, "an id with no entries is carried as gone")
	check(win.carried.ok == 7 and win.carried.typed == 7 and win.seq == 1, "every id carries the arrival number")
	local same, carried = Status.apply(win, { full = false, seq = 2, a = { ok = {} } }, 8, 200)
	check(same == win and carried, "a diff updates the window in place and carries something")
	check(win.a.ok == nil and win.carried.ok == 8 and win.carried.typed == 7, "a diff's empty list is gone")
	local _, nothing = Status.apply(win, { full = false, seq = 3, a = {} }, 9, 300)
	check(not nothing, "an empty diff carries nothing")
	local resync, any = Status.apply(win, { full = true, seq = 4, a = {} }, 10, 400)
	check(resync ~= win and any, "a full message replaces the window and always counts")
	check(resync.carried.typed == 10 and resync.a.typed == nil, "ids a full message leaves out are carried as gone")
end

-- Round trip: what the sender's diffs say, applied by the receiver, merges back to exactly the sender's entries,
-- through first contact, a change, a re-stamp and a gone id.
do
	local copy: { [string]: Status.Window } = {}
	local keys: { [string]: string }? = nil
	local mark = 0
	local function send(entries: { [string]: { Status.Entry } })
		local d = Status.diff(keys, entries, false)
		local a: { [string]: any } = table.clone(d.changed)
		for _, id in d.gone do
			a[id] = {}
		end
		mark += 1
		copy.w = Status.apply(copy.w, { full = d.full, seq = mark, a = a }, mark, 1000)
		keys = d.keys
		local got = Status.merged({ copy }, 1000, 3000)
		for id, list in entries do
			check(got[id] ~= nil and Status.wire_key(got[id]) == Status.wire_key(list), "step " .. mark .. ": " .. id)
		end
		for id in got do
			check(entries[id] ~= nil, "step " .. mark .. ": nothing extra (" .. id .. ")")
		end
	end
	send({ a = { { s = "w", src = "agents" } }, b = { { s = "q", src = "agents" } } })
	send({ a = { { s = "i", u = true, src = "agents", c = 900 } }, b = { { s = "q", src = "agents" } } })
	send({ a = { { s = "i", u = true, src = "agents", c = 950 } }, b = { { s = "q", src = "agents" } } })
	send({ a = { { s = "i", u = true, src = "agents", c = 950 } } })
	send({ a = { { s = "i", u = true, src = "agents", c = 950 }, { s = "w", src = "agents" } } })
end

-- Merging the windows' reports. `deliver` gives copy `copy` a full message from window `w` as the next arrival.
local T = 100000
local STALE_MS = 3000
local arrival = 0
local function deliver(copy: { [string]: Status.Window }, w: string, a: { [string]: { Status.Entry } })
	arrival += 1
	copy[w] = Status.apply(copy[w], { full = true, seq = arrival, a = a }, arrival, T)
end

-- The code the list shows for deck id `id` from the copies' merged view; "none" when no window lists it.
local function shown(copies: { { [string]: Status.Window } }, id: string): string
	local list = Status.merged(copies, T, STALE_MS)[id]
	if list == nil then
		return "none"
	end
	return Status.code(list[1], true, nil)
end

-- One copy and two windows that report the same agent differently, delivered in both orders: the newest observed
-- change wins whichever message arrived last.
local function both_orders(
	one: { [string]: { Status.Entry } },
	two: { [string]: { Status.Entry } },
	want: string,
	why: string
)
	for _, order in { { "desk", "laptop" }, { "laptop", "desk" } } do
		local copy: { [string]: Status.Window } = {}
		local by_w: { [string]: { [string]: { Status.Entry } } } = { desk = one, laptop = two }
		deliver(copy, order[1], by_w[order[1]])
		deliver(copy, order[2], by_w[order[2]])
		local got = shown({ copy }, "x")
		check(got == want, string.format("%s (%s last): got %s, want %s", why, order[2], got, want))
	end
end

-- An unseen finish one window saw happen beats another window's first look, which saw no transition.
both_orders(
	{ x = { { s = "i", u = true, c = T - 60000, src = "agents" } } },
	{ x = { { s = "i", src = "agents" } } },
	"waiting",
	"an observed unseen finish beats a baseline idle"
)
-- A window that looked at the agent later clears it, whichever window spoke last.
both_orders(
	{ x = { { s = "i", u = true, c = T - 60000, src = "agents" } } },
	{ x = { { s = "i", c = T - 5000, src = "agents" } } },
	"idle",
	"a newer observed clear beats an older unseen finish"
)
-- Two windows that saw the same finish a moment apart: the more urgent status shows.
both_orders(
	{ x = { { s = "i", u = true, c = T - 10000, src = "agents" } } },
	{ x = { { s = "i", c = T - 8500, src = "agents" } } },
	"waiting",
	"observations within the tie window go by urgency"
)
-- A window that sends no observation time (an older window half) counts as a baseline.
both_orders(
	{ x = { { s = "i", u = true, src = "agents" } } },
	{ x = { { s = "i", src = "agents" } } },
	"waiting",
	"two baselines go by urgency"
)
both_orders(
	{ x = { { s = "i", u = true, src = "agents" } } },
	{ x = { { s = "i", c = T - 5000, src = "agents" } } },
	"idle",
	"an observed clear beats an older window's baseline unseen finish"
)
both_orders(
	{ x = { { s = "i", src = "agents" } } },
	{ x = { { s = "q", src = "agents" } } },
	"waiting",
	"an older window's question beats a baseline idle"
)

-- Equal time and urgency: the lower window uid's entries, never the later arrival.
for _, order in { { "aaa", "bbb" }, { "bbb", "aaa" } } do
	local copy: { [string]: Status.Window } = {}
	local by_w: { [string]: { [string]: { Status.Entry } } } = {
		aaa = { x = { { s = "i", src = "first" } } },
		bbb = { x = { { s = "i", src = "second" } } },
	}
	deliver(copy, order[1], by_w[order[1]])
	deliver(copy, order[2], by_w[order[2]])
	local list = Status.merged({ copy }, T, STALE_MS).x
	check(list ~= nil and list[1].src == "first", "a full tie goes to the lower window uid, " .. order[2] .. " last")
end

-- A fresh copy of the list: both windows send it their first full snapshot, then both answer its hello with a full
-- snapshot to every copy. The waiting agent never flickers to idle on the way.
do
	local old_copy: { [string]: Status.Window } = {}
	local desk: { [string]: { Status.Entry } } = { x = { { s = "i", u = true, c = T - 60000, src = "agents" } } }
	local laptop: { [string]: { Status.Entry } } = { x = { { s = "i", src = "agents" } } }
	deliver(old_copy, "desk", desk)
	deliver(old_copy, "laptop", laptop)
	check(shown({ old_copy }, "x") == "waiting", "before the fresh copy the agent is waiting")
	local fresh: { [string]: Status.Window } = {}
	local steps: { { copy: { [string]: Status.Window }, w: string } } = {
		{ copy = fresh, w = "desk" },
		{ copy = fresh, w = "laptop" },
		{ copy = old_copy, w = "laptop" },
		{ copy = fresh, w = "laptop" },
		{ copy = old_copy, w = "desk" },
		{ copy = fresh, w = "desk" },
		{ copy = fresh, w = "laptop" },
	}
	for i, step in steps do
		deliver(step.copy, step.w, if step.w == "desk" then desk else laptop)
		local got = shown({ old_copy, fresh }, "x")
		check(got == "waiting", string.format("fresh copy step %d (%s): got %s, want waiting", i, step.w, got))
	end
end

-- Gone: a window that stops listing an agent leaves another window's live report standing; a window's own newest
-- report wins over its older one in another copy; an agent no window lists is gone.
do
	local a: { [string]: Status.Window } = {}
	local b: { [string]: Status.Window } = {}
	deliver(a, "desk", { x = { { s = "q", src = "agents" } } })
	deliver(a, "laptop", { x = { { s = "q", src = "agents" } } })
	deliver(a, "laptop", {})
	check(shown({ a, b }, "x") == "waiting", "one window's gone leaves the other's live report")
	deliver(b, "desk", { x = { { s = "q", src = "agents" } } })
	deliver(b, "desk", {})
	check(shown({ a, b }, "x") == "none", "a window's newer gone in another copy outranks its older report")
	deliver(a, "desk", {})
	check(shown({ a, b }, "x") == "none", "an agent no window lists is gone")
end

-- A window silent past the stale limit is left out of the merge.
do
	local copy: { [string]: Status.Window } = {}
	deliver(copy, "desk", { x = { { s = "i", u = true, c = T - 60000, src = "agents" } } })
	deliver(copy, "laptop", { x = { { s = "i", src = "agents" } } })
	copy.desk.at_ms = T - STALE_MS - 1
	check(shown({ copy }, "x") == "idle", "a stale window's report is left out")
end

-- An exited pane left open beside the agent's running one is history: `current` leaves it out, and the merge reads
-- every window's list through it. A list of exited panes only, or of running ones only, is kept as it is.
do
	local dead: Status.Entry = { s = "x", e = "exit status 1" }
	local idle: Status.Entry = { s = "i" }
	local mixed = Status.current({ dead, idle })
	check(#mixed == 1 and mixed[1] == idle, "the exited entry beside a running one is left out")
	local gone = { dead, dead }
	check(Status.current(gone) == gone, "a list of exited entries only is kept")
	local two = { idle, idle }
	check(Status.current(two) == two, "two running entries are kept: a duplicate")
	local win = Status.apply(nil, { seq = 1, full = true, a = { id = { dead, idle } } }, 1, 0)
	local merged = Status.merged({ { w = win } }, 0, 1000)
	check(#merged.id == 1 and merged.id[1].s == "i", "the merge leaves the exited pane out")
end

print("Status: " .. checks .. " checks passed")
