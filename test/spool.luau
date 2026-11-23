--!strict

local Identity = require("../lib/shared/identity")
local Keys = require("../lib/host/keys")
local Model = require("../lib/host/model")
local Spool = require("../lib/host/spool")
local Store = require("../lib/host/store")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local NOW = 1800000000000
local BRIEF = "/home/dev/briefs/nightly.md"

-- A rand that walks a fixed list of draws, each folded into [1, n] as `rand(n)` must be; new_id takes 8 draws.
local function rand_from(draws: { number }): (number) -> number
	local i = 0
	return function(n: number): number
		i += 1
		return (draws[(i - 1) % #draws + 1] - 1) % n + 1
	end
end
local DRAWS = { 1, 2, 3, 4, 5, 6, 7, 8 } -- "abcdefgh"

local function always(_: string): boolean
	return true
end

local function never(_: string): boolean
	return false
end

-- A request file's text from its lines, `end` added last.
local function text_of(lines: { string }): string
	return table.concat(lines, "\n") .. "\nend\n"
end

-- A valid request with `over` replacing (or, with "", dropping) its lines by key, and `extra` lines appended.
local function request(over: { [string]: string }?, extra: { string }?): string
	local base: { { string } } = {
		{ "v", "1" },
		{ "ts", tostring(NOW - 1000) },
		{ "group", "webapp" },
		{ "cwd", "/home/dev/webapp" },
		{ "prompt_file", BRIEF },
	}
	local lines: { string } = {}
	for _, kv in base do
		local value = if over ~= nil and over[kv[1]] ~= nil then over[kv[1]] else kv[2]
		if value ~= "" then
			table.insert(lines, kv[1] .. "=" .. value)
		end
	end
	local more: { string } = extra or {}
	for _, line in more do
		table.insert(lines, line)
	end
	return text_of(lines)
end

local function refused(text: string, want: string, what: string)
	local req, err = Spool.parse(text, "rq2a3b4c", NOW)
	check(req == nil and err == want, what .. " (got " .. tostring(err) .. ")")
end

local function parsed(text: string, what: string): Spool.Request
	local req, err = Spool.parse(text, "rq2a3b4c", NOW)
	check(req ~= nil and err == nil, what .. " (got " .. tostring(err) .. ")")
	return req :: Spool.Request
end

local function deep_equal(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deep_equal(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function deep_copy(t: any): any
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in t do
		out[k] = deep_copy(v)
	end
	return out
end

-- A deck named for session `deck` on host `devbox`, with group "webapp" (g1) holding live agents a (pos 1) and
-- b (pos 3), and group "notes" (g2) holding live agent c.
local function sample(): Store.Deck
	local deck = Store.empty()
	deck.session = { name = "deck", host = "devbox", set_ms = NOW - 5000 }
	table.insert(deck.groups, { gid = "g1", name = "webapp", cwd = "/home/dev/webapp", folded = false })
	table.insert(deck.groups, { gid = "g2", name = "notes", cwd = "/home/dev/notes", folded = true })
	local function live(id: string, gid: string, pos: number)
		deck.agents[id] = {
			gid = gid,
			pos = pos,
			cwd = "/home/dev/wt/" .. id,
			created_ms = NOW - 9000,
			state = "live",
			pane = pos,
			cli = "omp",
		}
	end
	live("a", "g1", 1)
	live("b", "g1", 3)
	live("c", "g2", 1)
	return deck
end

local function req_of(over: { [string]: string }?, extra: { string }?): Spool.Request
	return parsed(request(over, extra), "the fixture request parses")
end

-- Parse: a whole request, its fields, and the forms that pass.
do
	local req = parsed(request(nil, { "label=  nightly run  ", "cli=omp" }), "a full request parses")
	check(req.rid == "rq2a3b4c" and req.ts == NOW - 1000, "rid from the caller, ts as a number")
	check(req.group == "webapp" and req.cwd == "/home/dev/webapp", "group and cwd")
	check(req.cli == "omp" and req.prompt_file == BRIEF, "cli omp and the prompt file")
	check(req.label == "nightly run", "the label is trimmed")

	local min = parsed(request({ cwd = "" }), "a request without cwd, cli or label parses")
	check(min.cwd == nil and min.label == nil and min.cli == "omp", "absent cwd and label stay nil; cli is omp")

	local no_newline = string.sub(request(), 1, -2)
	check(string.sub(no_newline, -3) == "end", "fixture: no trailing newline")
	parsed(no_newline, "a last line `end` without a newline parses")

	check(parsed(request({ group = "  web app  " }), "spaces around the group").group == "web app", "group is trimmed")
	check(parsed(request(nil, { "label=   " }), "a blank label").label == nil, "a blank label is no label")
	parsed(request({ group = string.rep("g", 40) }), "a 40-character group name passes")
	parsed(request(nil, { "label=" .. string.rep("l", 60) }), "a 60-character label passes")
	parsed(request({ ts = tostring(NOW - 60000) }), "a request exactly 60 s old passes")
	parsed(request({ ts = tostring(NOW + 5000) }), "a request 5 s ahead passes")
	parsed(request({ group = "café" }), "a group name with non-ASCII letters passes")
	parsed(request(nil, { "label=a=b" }), "a value may hold `=`; the line splits at the first")
end

-- Parse: every refusal, one line in plain words.
do
	local bad_rid, rid_err = Spool.parse(request(), "../kv", NOW)
	check(bad_rid == nil and rid_err == "bad request name", "a rid that is no deck id is refused")
	refused(
		request(nil, { "label=" .. string.rep("x", Spool.MAX_BYTES) }),
		"request is larger than 4096 bytes",
		"an oversize request"
	)
	refused("", "request is incomplete: its last line is not end", "an empty file")
	refused("v=1\nts=" .. (NOW - 1000) .. "\n", "request is incomplete: its last line is not end", "no end line")
	refused("v=1\nen", "request is incomplete: its last line is not end", "a file cut mid-way through end")
	refused(request() .. "v=1\n", "request is incomplete: its last line is not end", "a line after end")
	refused(request(nil, { "end" }), "line 6 is not key=value", "an end that is not last")
	refused(request(nil, { "" }), "line 6 is not key=value", "a blank line")
	refused(request(nil, { "just words" }), "line 6 is not key=value", "a line without =")
	refused(request(nil, { "colour=red" }), "unknown key colour", "an unknown key")
	refused(request(nil, { "id=abcdefgh" }), "unknown key id", "a body id is an unknown key (rid is the file name)")
	refused(request(nil, { "two words=x" }), "line 6 has an unknown key", "an unknown key is echoed only when plain")
	refused(request(nil, { "=x" }), "line 6 has an unknown key", "an empty key")
	refused(request(nil, { "group=other" }), "key group is given twice", "a repeated key")
	refused(request(nil, { "label=a", "label=b" }), "key label is given twice", "a repeated optional key")
	refused(request({ group = "web\rapp" }), "group holds a control character", "a carriage return in a value")
	refused(request(nil, { "label=a\tb" }), "label holds a control character", "a tab in a value")
	refused(request({ v = "" }), "request has no v", "no v")
	refused(request({ ts = "" }), "request has no ts", "no ts")
	refused(request({ group = "" }), "request has no group", "no group")
	refused(request({ prompt_file = "" }), "request has no prompt_file", "no prompt_file")
	refused(request({ v = "2" }), "request version must be 1; update Jumpr or the script", "another version")
	refused(request({ ts = "soon" }), "ts is not a time in milliseconds", "a ts that is no number")
	refused(request({ ts = "-5" }), "ts is not a time in milliseconds", "a negative ts")
	refused(request({ ts = "1.5" }), "ts is not a time in milliseconds", "a fractional ts")
	refused(request({ ts = string.rep("9", 17) }), "ts is not a time in milliseconds", "a ts too long to be a time")
	refused(request({ ts = tostring(NOW - 60001) }), "request is more than 60 s old", "a stale request")
	refused(request({ ts = tostring(NOW + 5001) }), "request is from the future; check the clock", "a future request")
	refused(request({ group = "   " }), "group name is empty", "a blank group name")
	refused(
		request({ group = string.rep("g", 41) }),
		"group name is longer than 40 characters",
		"a 41-character group name"
	)
	refused(request({ group = "-rf" }), "group name may not start with -", "a group name starting with -")
	local bad_cwd = "cwd must be an absolute folder of letters, digits, spaces and _ - . / with no .. part"
	refused(request({ cwd = "home/dev/webapp" }), bad_cwd, "a relative cwd")
	refused(request({ cwd = "/home/dev/../root" }), bad_cwd, "a cwd with ..")
	refused(request({ cwd = "/home/dev/it's" }), bad_cwd, "a cwd with a quote")
	refused(request(nil, { "cli=claude" }), "only omp agents can be started from a script", "a claude start")
	refused(request(nil, { "cli=" }), "only omp agents can be started from a script", "an empty cli")
	local bad_prompt = "prompt file must be an absolute path of letters, digits and _ - . / with no .. part"
	refused(request({ prompt_file = "briefs/nightly.md" }), bad_prompt, "a relative prompt file")
	refused(request({ prompt_file = "/home/dev/my brief.md" }), bad_prompt, "a prompt file with a space")
	refused(request({ prompt_file = "/home/dev/../etc/passwd" }), bad_prompt, "a prompt file with ..")
	refused(request({ prompt_file = "/home/dev/-brief.md" }), bad_prompt, "a prompt file segment starting with -")
	refused(request({ prompt_file = "/home/dev/'brief'.md" }), bad_prompt, "a prompt file with quotes")
	refused(
		request(nil, { "label=" .. string.rep("l", 61) }),
		"label is longer than 60 characters",
		"a 61-character label"
	)
	refused(request(nil, { "label=--help" }), "label may not start with -", "a label starting with -")
end

-- Place into an existing group: the agent goes last (max pos + 1), in the group's folder, as a pending omp record.
do
	local deck = sample()
	local before = deep_copy(deck)
	local asked: { string } = {}
	local placed, err = Spool.place(deck, req_of({ cwd = "" }), NOW, rand_from(DRAWS), function(dir: string): boolean
		table.insert(asked, dir)
		return true
	end)
	check(placed ~= nil and err == nil, "placed into webapp")
	local p = placed :: Spool.Placement
	check(p.id == "abcdefgh" and p.gid == "g1", "the id is drawn with rand; the group is the named one")
	check(#p.deck.groups == 2, "no group is added")
	check(
		deep_equal(p.deck.agents.abcdefgh, {
			gid = "g1",
			pos = 4,
			cwd = "/home/dev/webapp",
			created_ms = NOW,
			state = "pending",
			cli = "omp",
		}),
		"the record: pending omp, pos = max + 1, the group's folder, created now, no label"
	)
	check(#asked == 1 and asked[1] == "/home/dev/webapp", "the folder is checked on this machine")
	check(p.deck ~= deck and deep_equal(deck, before), "the caller's deck is untouched")
end

-- A found group with a different --cwd: the group is used as is; the record gets the request's folder.
do
	local deck = sample()
	local placed = Spool.place(deck, req_of({ cwd = "/home/dev/wt/feature" }), NOW, rand_from(DRAWS), always)
	local p = placed :: Spool.Placement
	check(
		p.gid == "g1" and p.deck.agents[p.id].cwd == "/home/dev/wt/feature",
		"the record runs in the request's folder"
	)
	check(p.deck.groups[1].cwd == "/home/dev/webapp", "the group keeps its own folder")
end

-- The group is found by its exact (trimmed) name, folded or not; the agent goes after that group's own agents.
do
	local placed = Spool.place(sample(), req_of({ group = " notes ", cwd = "" }), NOW, rand_from(DRAWS), always)
	local p = placed :: Spool.Placement
	check(p.gid == "g2" and p.deck.agents[p.id].pos == 2, "a folded group is used, its pos counted on its own")
	check(p.deck.groups[2].folded == true, "and stays folded")
	local none, err = Spool.place(sample(), req_of({ group = "Notes", cwd = "" }), NOW, rand_from(DRAWS), always)
	check(none == nil and err == "no group named Notes; pass --cwd to create it", "the name match is exact")
end

-- A missing group: created (appended last) only with a cwd that is a folder here; else refused, nothing made.
do
	local deck = sample()
	local before = deep_copy(deck)
	local none, err = Spool.place(deck, req_of({ group = "nightly", cwd = "" }), NOW, rand_from(DRAWS), always)
	check(none == nil and err == "no group named nightly; pass --cwd to create it", "no cwd: refused")

	local missing, merr =
		Spool.place(deck, req_of({ group = "nightly", cwd = "/home/dev/nightly" }), NOW, rand_from(DRAWS), never)
	check(
		missing == nil and merr == "folder not found on devbox: /home/dev/nightly",
		"a cwd that is no folder: refused"
	)
	check(deep_equal(deck, before), "neither refusal changes the deck")

	local placed, perr =
		Spool.place(deck, req_of({ group = "nightly", cwd = "/home/dev/nightly" }), NOW, rand_from(DRAWS), always)
	check(placed ~= nil and perr == nil, "with a cwd, the group is created")
	local p = placed :: Spool.Placement
	check(#p.deck.groups == 3, "one group is added")
	check(
		deep_equal(p.deck.groups[3], { gid = p.gid, name = "nightly", cwd = "/home/dev/nightly", folded = false }),
		"appended last, named as asked, in the request's folder, unfolded"
	)
	check(Identity.valid_id(p.gid) and Identity.valid_id(p.id), "the new gid and deck id are valid ids")
	check(
		p.gid ~= p.deck.groups[1].gid and p.gid ~= p.deck.groups[2].gid and before.agents[p.id] == nil,
		"neither is already taken"
	)
	local r = p.deck.agents[p.id]
	check(r.gid == p.gid and r.pos == 1 and r.cwd == "/home/dev/nightly", "the first agent of the new group")
	check(deep_equal(deck, before), "the caller's deck is untouched")
end

-- A group being deleted refuses with keys' own message, and no second group of that name is made.
do
	local deck = sample()
	deck.groups[1].deleting = true
	local before = deep_copy(deck)
	local placed, err = Spool.place(deck, req_of(), NOW, rand_from(DRAWS), always)
	check(placed == nil and err == "group is being deleted", "refused with the d message")
	check(err == Keys.DELETING, "the very message keys shows")
	check(deep_equal(deck, before) and #deck.groups == 2, "no duplicate group, nothing stored")
end

-- dir_ok false for a found group's folder: refused, nothing stored.
do
	local deck = sample()
	local before = deep_copy(deck)
	local placed, err = Spool.place(deck, req_of({ cwd = "" }), NOW, rand_from(DRAWS), never)
	check(placed == nil and err == "folder not found on devbox: /home/dev/webapp", "a missing folder refuses")
	check(deep_equal(deck, before), "nothing stored")
	deck.session.host = nil
	local _, unnamed = Spool.place(deck, req_of({ cwd = "" }), NOW, rand_from(DRAWS), never)
	check(unnamed == "folder not found on this machine: /home/dev/webapp", "an unnamed host reads as this machine")
end

-- Cold start: a deck with its session named and no groups or agents yet.
do
	local deck = Store.empty()
	deck.session = { name = "deck", host = "devbox", set_ms = NOW - 5000 }
	local placed, err = Spool.place(deck, req_of(), NOW, rand_from(DRAWS), always)
	check(placed ~= nil and err == nil, "the first request on an empty deck places")
	local p = placed :: Spool.Placement
	check(#p.deck.groups == 1 and p.deck.groups[1].name == "webapp", "its group is created")
	check(p.deck.agents[p.id].pos == 1 and p.deck.session.name == "deck", "pos 1; the session is kept")
	check(#deck.groups == 0 and next(deck.agents) == nil, "the caller's empty deck stays empty")
end

-- The label is stored on the record (the name of record `r` saves), and only when given.
do
	local placed = Spool.place(sample(), req_of(nil, { "label=nightly diffo" }), NOW, rand_from(DRAWS), always)
	local p = placed :: Spool.Placement
	check(p.deck.agents[p.id].label == "nightly diffo", "label on the record")
end

-- An id already taken is drawn again, in each id space on its own.
do
	local deck = sample()
	deck.agents.abcdefgh = table.clone(deck.agents.a)
	local placed =
		Spool.place(deck, req_of(), NOW, rand_from({ 1, 2, 3, 4, 5, 6, 7, 8, 2, 2, 2, 2, 2, 2, 2, 2 }), always)
	local p = placed :: Spool.Placement
	check(p.id == "bbbbbbbb", "a taken deck id is skipped")
end

-- Status × operation: whatever state the deck's records are in, a spool start leaves every one of them as it was,
-- in the caller's deck and in the new one.
do
	local deck = sample()
	deck.agents.p = {
		gid = "g1",
		pos = 5,
		cwd = "/home/dev/webapp",
		created_ms = NOW - 100,
		state = "pending",
		cli = "omp",
		failed = true,
		ended_ms = NOW - 50,
	}
	deck.agents.s = {
		gid = "g1",
		pos = 6,
		cwd = "/home/dev/webapp",
		created_ms = NOW - 100,
		state = "stopping",
		pane = 6,
		stop_ms = NOW - 10,
		cli = "claude",
		session = "01234567-0123-4456-b012-345670123456",
	}
	deck.agents.x = {
		gid = "g2",
		pos = 2,
		cwd = "/home/dev/notes",
		created_ms = NOW - 100,
		state = "exited",
		exit = 1,
		ended_ms = NOW - 20,
		cli = "omp",
		label = "old one",
		ran = true,
	}
	local before = deep_copy(deck)
	for _, case in { { group = "webapp", cwd = "" }, { group = "notes", cwd = "" }, { group = "fresh", cwd = "/tmp" } } do
		local placed = Spool.place(deck, req_of(case), NOW, rand_from(DRAWS), always)
		local p = placed :: Spool.Placement
		for id, r in before.agents do
			check(deep_equal(p.deck.agents[id], r), "record " .. id .. " (" .. r.state .. ") unchanged by a start")
		end
		check(deep_equal(deck, before), "the caller's deck is untouched")
	end
end

-- Contract drift: `n` on a group through Keys.reduce and a spool start into the same group, on the same deck, clock
-- and draws, store the same record but for the label.
do
	local deck = sample()
	local rand = rand_from(DRAWS)
	local ui = Keys.new_ui(nil)
	ui.selection = { kind = "header", gid = "g1" }
	local rows = Model.rows(deck, {}, {}, {}, ui, "ok")
	local ui2, deck2, effects = Keys.reduce(ui, deck, rows, { kind = "key", name = "n", text = "n" }, NOW, rand)
	local effect: Keys.Effect? = nil
	for _, e in effects do
		if e.kind == "check_folder" then
			effect = e
		end
	end
	check(effect ~= nil and deck2 == deck, "n asks for the folder check first")
	local _, keyed = Keys.reduce(
		ui2,
		deck2,
		Model.rows(deck2, {}, {}, {}, ui2, "ok"),
		Keys.folder_checked(effect :: Keys.Effect, true),
		NOW,
		rand_from(DRAWS)
	)
	local placed = Spool.place(deck, req_of({ cwd = "" }, { "label=nightly" }), NOW, rand_from(DRAWS), always)
	local p = placed :: Spool.Placement
	local n_record = keyed.agents[p.id]
	check(n_record ~= nil, "n and the spool draw the same id")
	local spool_record = table.clone(p.deck.agents[p.id]) :: any
	check(spool_record.label == "nightly", "the spool record carries the label")
	spool_record.label = nil
	check(deep_equal(n_record, spool_record), "the records are otherwise identical")
	for id in deck.agents do
		check(deep_equal(keyed.agents[id], p.deck.agents[id]), "both leave record " .. id .. " alike")
	end
end

-- Reply: keys in a fixed order whatever the table's, argv one line per word in order, end last.
do
	local ok = Spool.reply({
		label = "nightly",
		cwd = "/home/dev/webapp",
		session = "deck",
		gid = "g1",
		id = "abcdefgh",
		ok = "1",
	}, { "omp", "--session-dir", "/home/dev/.omp/deck/abcdefgh", "@" .. BRIEF })
	check(ok == table.concat({
		"ok=1",
		"id=abcdefgh",
		"gid=g1",
		"session=deck",
		"cwd=/home/dev/webapp",
		"argv=omp",
		"argv=--session-dir",
		"argv=/home/dev/.omp/deck/abcdefgh",
		"argv=@" .. BRIEF,
		"label=nightly",
		"end",
		"",
	}, "\n"), "an ok reply: " .. ok)
	check(
		Spool.reply({ error = "no group named nightly; pass --cwd to create it", ok = "0" })
			== "ok=0\nerror=no group named nightly; pass --cwd to create it\nend\n",
		"an error reply"
	)
	check(Spool.reply({}) == "end\n", "an empty reply is just end")
	check(not pcall(Spool.reply, { error = "two\nlines", ok = "0" }), "a newline in a value raises")
	check(not pcall(Spool.reply, { ok = "1" }, { "omp\r" }), "a control byte in an argv word raises")
	check(not pcall(Spool.reply, { colour = "red" }), "an unknown key raises")
	check(not pcall(Spool.reply, { argv = "omp" }), "argv is only ever the list, never a field")
end

print("Spool: " .. checks .. " checks passed")
