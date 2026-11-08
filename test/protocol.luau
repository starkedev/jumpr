--!strict

local Protocol = require("../lib/shared/protocol")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local P = Protocol.P
check(P == 2, "the protocol version is 2")

local function msg(w: string, seq: number, full: boolean): Protocol.StatusMsg
	return Protocol.status_msg(w, seq, full, 1000, "connected", "deck", "devbox", false, "A", {})
end

-- check_status: first message, sequence order, gaps, two windows, versions. It never mutates its argument.
local last: { [string]: number } = {}
check(Protocol.check_status(msg("w1", 0, false), last) == "gap", "a first non-full message gives gap (send hello)")
check(Protocol.check_status(msg("w1", 0, true), last) == "ok", "a first full message is ok")
check(next(last) == nil, "check_status never records the sequence itself")
last.w1 = 5
check(Protocol.check_status(msg("w1", 6, false), last) == "ok", "the next seq is ok")
check(Protocol.check_status(msg("w1", 8, false), last) == "gap", "a sequence gap gives gap (send hello)")
check(Protocol.check_status(msg("w1", 8, true), last) == "ok", "a full snapshot after a gap is ok")
check(Protocol.check_status(msg("w1", 5, false), last) == "old", "a repeated seq gives old")
check(Protocol.check_status(msg("w1", 3, false), last) == "old", "a lower seq in a diff gives old")
check(Protocol.check_status(msg("w1", 5, true), last) == "ok", "a full message at the last seq is a restart")
check(Protocol.check_status(msg("w1", 0, true), last) == "ok", "a full message at seq 0 is a restart")
check(Protocol.check_status(msg("w1", 3, true), last) == "ok", "a full message below the last seq is a restart")
check(last.w1 == 5, "check_status leaves the recorded seq alone")
-- Two window uids are tracked separately.
last.w2 = 100
check(Protocol.check_status(msg("w2", 101, false), last) == "ok", "window w2 follows its own seq")
check(Protocol.check_status(msg("w1", 6, false), last) == "ok", "window w1 is unaffected by w2's seq")
check(Protocol.check_status(msg("w2", 6, false), last) == "old", "w1's seq is old for w2")
check(Protocol.check_status(msg("w3", 0, false), last) == "gap", "a new window uid starts with a gap")
-- Versions: the other side's p against this side's.
local newer = msg("w1", 6, false)
newer.p = P + 1
check(Protocol.check_status(newer, last) == "bad_p_newer", "a newer p gives bad_p_newer")
local older = msg("w1", 6, false)
older.p = P - 1
check(Protocol.check_status(older, last) == "bad_p_older", "an older p gives bad_p_older")
check(Protocol.check_status({ w = "w1", seq = 6, full = true }, last) == "bad_p_older", "no p gives bad_p_older")
check(Protocol.check_status({ p = P, full = true }, last) == "old", "a message with no w or seq is ignored")

-- URLs round-trip with encoded labels.
local LABELS = {
	"fix the tests",
	"a & b = c",
	"100% done?",
	"tabs\tand\nnewline",
	"unicode: ünïcødé — ⠼ 日本語 🚀",
	"#hash +plus /slash ?q 'quote' \"dq\"",
	"",
}
for i, label in LABELS do
	local url = Protocol.request_url("name", "blk 1", i, "devbox host", {
		id = "k2x7abcd",
		cwd = "/home/me/My Projects/a&b",
		label = label,
	})
	check(string.sub(url, 1, 13) == "jumpr://name?", "a name URL opens with its verb: " .. url)
	check(string.find(string.sub(url, 14), "[ \n\t]") == nil, "no raw whitespace survives encoding")
	local req = Protocol.parse_url(url)
	assert(req ~= nil, "a built URL parses: " .. url)
	check(req.verb == "name", "the verb round-trips")
	check(req.p == P, "p round-trips")
	check(req.b == "blk 1", "b round-trips")
	check(req.r == i, "r round-trips")
	check(req.host == "devbox host", "host round-trips")
	check(req.fields.id == "k2x7abcd", "id round-trips")
	check(req.fields.cwd == "/home/me/My Projects/a&b", "cwd round-trips")
	check(req.fields.label == label, string.format("label %q round-trips, got %q", label, req.fields.label or "nil"))
end
local percent = Protocol.request_url("name", "b", 1, "h", { label = "%41 %zz" })
local percent_req = Protocol.parse_url(percent)
check(percent_req ~= nil and percent_req.fields.label == "%41 %zz", "an encoded % is not decoded twice")
check(Protocol.request_url("hello", "b", 2, "h", {}) == "jumpr://hello?p=2&b=b&r=2&host=h", "a verb with no fields")

-- Unknown verbs are rejected, by the parser and the builder.
check(Protocol.parse_url("jumpr://launch?p=1&b=b&r=1&host=h") == nil, "an unknown verb is rejected")
check(Protocol.parse_url("jumpr://Start?p=1&b=b&r=1&host=h") == nil, "verbs are case-sensitive")
check(Protocol.parse_url("https://start?p=1&b=b&r=1&host=h") == nil, "a non-jumpr URL is rejected")
check(not pcall(Protocol.request_url, "launch", "b", 1, "h", {}), "request_url refuses an unknown verb")
for verb in Protocol.VERBS do
	check(Protocol.parse_url(Protocol.request_url(verb, "b", 1, "h", {})) ~= nil, "known verb parses: " .. verb)
end
local verb_count = 0
for _ in Protocol.VERBS do
	verb_count += 1
end
check(verb_count == 8, "eight verbs are known (name joins for the rename)")
do
	local shown = Protocol.parse_url(Protocol.request_url("show", "b", 4, "devbox", { id = "k2x7abcd" }))
	assert(shown ~= nil, "show parses")
	check(shown.verb == "show" and shown.fields.id == "k2x7abcd" and shown.p == P, "show round-trips with its id")
	check(not Protocol.expects_reply("show"), "show expects no reply")
	local named =
		Protocol.parse_url(Protocol.request_url("name", "b", 5, "devbox", { id = "k2x7abcd", label = "auth" }))
	assert(named ~= nil, "name parses")
	check(named.verb == "name" and named.fields.label == "auth", "name round-trips with its label")
	check(not Protocol.expects_reply("name"), "name expects no reply")
end

-- A start URL carrying a dir field parses without dir; request_url never writes one.
local with_dir = Protocol.parse_url("jumpr://start?p=1&b=b&r=1&host=h&id=ab&dir=%2Ftmp%2Fevil&cwd=%2Fx")
assert(with_dir ~= nil, "a start URL with dir still parses")
check(with_dir.fields.dir == nil, "the dir field is dropped")
check(with_dir.fields.id == "ab" and with_dir.fields.cwd == "/x", "the other fields stay")
check(not pcall(Protocol.request_url, "start", "b", 1, "h", { dir = "/tmp" }), "request_url refuses a dir field")
check(not pcall(Protocol.request_url, "start", "b", 1, "h", { host = "x" }), "request_url refuses a URL key as field")

-- Missing b, r or host are rejected.
check(Protocol.parse_url("jumpr://jump?p=1&b=b&r=1&id=ab") == nil, "a URL without host is rejected")
check(Protocol.parse_url("jumpr://jump?p=1&b=b&r=1&host=&id=ab") == nil, "a URL with an empty host is rejected")
check(Protocol.parse_url("jumpr://jump?p=1&r=1&host=h&id=ab") == nil, "a URL without b is rejected")
check(Protocol.parse_url("jumpr://jump?p=1&b=b&host=h&id=ab") == nil, "a URL without r is rejected")
check(Protocol.parse_url("jumpr://jump?p=1&b=b&r=x&host=h") == nil, "a URL with a non-number r is rejected")
check(Protocol.parse_url("jumpr://jump?b=b&r=1&host=h") == nil, "a URL without p is rejected")
check(Protocol.parse_url("jumpr://jump") == nil, "a URL with no query is rejected")

-- check_request on a URL with a newer or older p.
local function url_with_p(p: number): string
	return (string.gsub(Protocol.request_url("jump", "b", 1, "h", { id = "ab" }), "p=%d+", "p=" .. tostring(p), 1))
end
local req_newer = Protocol.parse_url(url_with_p(P + 1))
local req_older = Protocol.parse_url(url_with_p(P - 1))
local req_same = Protocol.parse_url(url_with_p(P))
assert(req_newer ~= nil and req_older ~= nil and req_same ~= nil, "URLs with any p parse")
check(Protocol.check_request(req_newer) == "bad_p_newer", "a newer p gives bad_p_newer")
check(Protocol.check_request(req_older) == "bad_p_older", "an older p gives bad_p_older")
check(Protocol.check_request(req_same) == "ok", "the same p is ok")
check(Protocol.check_request({}) == "bad_p_older", "no p reads as older")

-- check_url: the version of any jumpr:// URL, read before the verb is checked, and its host.
local v_same, h_same = Protocol.check_url(url_with_p(P))
check(v_same == "ok" and h_same == "h", "check_url on a same-version URL is ok and gives its host")
check(Protocol.check_url(url_with_p(P + 1)) == "bad_p_newer", "check_url on a newer p gives bad_p_newer")
check(Protocol.check_url(url_with_p(P - 1)) == "bad_p_older", "check_url on an older p gives bad_p_older")
local v_verb, h_verb = Protocol.check_url("jumpr://launch?p=3&b=x&r=1&host=my%20box")
check(v_verb == "bad_p_newer" and h_verb == "my box", "check_url names a newer p on a verb this side does not know")
local v_none, h_none = Protocol.check_url("jumpr://jump?b=b&r=1")
check(v_none == "bad_p_older" and h_none == nil, "check_url reads a URL without p as older, with no host")
check(Protocol.check_url("jumpr://jump?p=2&p=1&b=b&r=1&host=h") == "ok", "check_url: the first p wins")
check(Protocol.check_url("https://example.com/?p=1") == nil, "check_url: not a jumpr:// URL gives nil")
check(Protocol.check_url("jumpr://jump") == nil, "check_url: a jumpr:// URL with no query gives nil")

-- Replies: the same version check, and a block ignores another block's reply.
local res = Protocol.reply("blk-a", 7, false, "start failed on devbox: no deck session")
check(Protocol.check_request(res) == "ok", "a reply passes the version check")
check(Protocol.reply_for_me(res, "blk-a"), "a reply for this block is mine")
check(not Protocol.reply_for_me(res, "blk-b"), "a reply with another b is not mine")
check(not Protocol.reply_for_me({ p = P, r = 7, ok = true }, "blk-a"), "a reply with no b is not mine")
check(
	res.r == 7 and res.ok == false and res.err == "start failed on devbox: no deck session",
	"a reply carries r, ok, err"
)
local newer_res = Protocol.reply("blk-a", 1, true, nil)
newer_res.p = P + 1
check(Protocol.check_request(newer_res) == "bad_p_newer", "a newer reply gives bad_p_newer")

-- expects_reply: only start and stop.
for verb in Protocol.VERBS do
	check(Protocol.expects_reply(verb) == (verb == "start" or verb == "stop"), "expects_reply for " .. verb)
end
check(not Protocol.expects_reply("launch"), "an unknown verb expects no reply")

-- Every builder emits p = P, and none of their fields is a pane id.
local function keys_of(t: { [string]: any }): { [string]: boolean }
	local out = {}
	for k in t do
		out[k] = true
	end
	return out
end
local function same_keys(got: { [string]: boolean }, want: { string }, what: string)
	local n = 0
	for _ in got do
		n += 1
	end
	check(n == #want, what .. " has exactly the pinned fields")
	for _, k in want do
		check(got[k] == true, what .. " has field " .. k)
	end
end
local function no_pane_key(t: { [string]: any }, what: string)
	for k, v in t do
		check(
			string.find(string.lower(tostring(k)), "pane") == nil,
			what .. " field " .. tostring(k) .. " is a pane id"
		)
		if type(v) == "table" then
			no_pane_key(v, what .. "." .. tostring(k))
		end
	end
end

local full = Protocol.status_msg("w1", 3, true, 1234, "connected", "deck", "devbox", true, "B", {
	k2x7abcd = { { s = "w", u = false, f = false, src = "agents" } },
	ab = { { s = "q" }, { s = "i", u = true, e = "exit 1" } },
})
check(full.p == P, "status_msg emits p = P")
same_keys(keys_of(full), { "p", "w", "seq", "full", "t", "h", "sn", "hn", "dupb", "em", "a" }, "status_msg")
check(full.w == "w1" and full.seq == 3 and full.full == true and full.t == 1234, "status_msg keeps w, seq, full, t")
check(full.h == "connected" and full.sn == "deck" and full.hn == "devbox", "status_msg keeps h, sn, hn")
check(full.dupb == true and full.em == "B" and (full :: any).undocked == nil, "status_msg sends no undocked")
check(#full.a.ab == 2 and full.a.k2x7abcd[1].s == "w", "status_msg keys agents by deck id")
no_pane_key(full, "status_msg")

for verb in Protocol.VERBS do
	local url = Protocol.request_url(verb, "b", 1, "h", { id = "ab" })
	local req = Protocol.parse_url(url)
	assert(req ~= nil, "a built URL parses")
	check(req.p == P, "request_url emits p = P for " .. verb)
	check(string.find(url, "?p=" .. tostring(P) .. "&", 1, true) ~= nil, "p leads the query for " .. verb)
	no_pane_key(req.fields, "request_url " .. verb)
	same_keys(keys_of(req), { "verb", "p", "b", "r", "host", "fields" }, "parsed request")
end

local ok_res = Protocol.reply("b", 1, true, nil)
check(ok_res.p == P, "reply emits p = P")
same_keys(keys_of(ok_res), { "p", "b", "r", "ok" }, "reply with no error")
same_keys(keys_of(res), { "p", "b", "r", "ok", "err" }, "reply with an error")
no_pane_key(res, "reply")

-- Launch args: the window builds them, the block reads them back.
do
	local args = Protocol.launch_args("main", "devbox")
	check(#args == 2 and args[1] == "session=main" and args[2] == "host=devbox", "launch_args gives session= and host=")
	local s, h = Protocol.parse_launch_args(args)
	check(s == "main" and h == "devbox", "parse_launch_args reads launch_args back")
	local spaced_s, spaced_h = Protocol.parse_launch_args(Protocol.launch_args("my deck", "a=b"))
	check(spaced_s == "my deck" and spaced_h == "a=b", "a value keeps spaces and = signs")
	local none_s, none_h = Protocol.parse_launch_args({})
	check(none_s == nil and none_h == nil, "no args gives nil names")
	local empty_s, empty_h = Protocol.parse_launch_args({ "session=", "host=", "junk", "other=x" })
	check(empty_s == nil and empty_h == nil, "empty values and unknown args give nil")
	local first_s = Protocol.parse_launch_args({ "session=one", "session=two" })
	check(first_s == "one", "the first repeated key wins")
end

print("Protocol: " .. checks .. " checks passed")
