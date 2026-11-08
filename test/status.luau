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

print("Status: " .. checks .. " checks passed")
