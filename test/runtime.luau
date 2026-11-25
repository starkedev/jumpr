--!strict
-- The host half's list (lib/host/runtime.luau), run against the fake machine: keys across copies, the effects keys
-- asks for (a folder check, a message typed, a tab shown), messages from the window, the pane bindings the hooks
-- feed, the reply rule, and the pane-list snapshot. Every case builds its own list and machine.

local Agent = require("../lib/shared/agent")
local Bind = require("../lib/host/bind")
local Compat = require("../lib/compat")
local Fake = require("./support/fake_host")
local Protocol = require("../lib/shared/protocol")
local Requests = require("../lib/host/requests")
local Runtime = require("../lib/host/runtime")
local Spool = require("../lib/host/spool")
local Store = require("../lib/host/store")
local View = require("../lib/host/view")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local ARGS = { "session=deck", "host=devbox" }

local function record(pos: number, fields: { [string]: any }?): Store.Record
	local r: Store.Record =
		{ gid = "g1", pos = pos, cwd = "/work", created_ms = Fake.wall(0) - 1000, state = "live", cli = "omp" }
	for k, v in (fields or {}) :: { [string]: any } do
		(r :: any)[k] = v
	end
	return r
end

-- Machine devbox, deck session `deck`: group work (/work) with live agents agent-a (pane 11) and agent-b (pane 12).
local function deck(): Store.Deck
	local d = Store.empty()
	d.session = { name = "deck", host = "devbox" }
	table.insert(d.groups, { gid = "g1", name = "work", cwd = "/work", folded = false })
	d.agents["agent-a"] = record(1, { pane = 11 })
	d.agents["agent-b"] = record(2, { pane = 12 })
	return d
end

-- A list on a machine holding `d`, with its panes listed; random draws are always 1, so a new id is "aaaaaaaa".
-- A nil deck is an empty one: `open` collects stale records before the test installs anything else.
local function list_on(d: Store.Deck?): (Runtime.Runtime, Fake.Machine)
	local m = Fake.machine(d or Store.empty())
	m.panes = { [11] = true, [12] = true, [101] = true, [102] = true }
	local list = Runtime.new(m.compat, function(_n: number): number
		return 1
	end)
	return list, m
end

local function open(list: Runtime.Runtime, pane: number): (Runtime.Copy, BlockCx, Fake.Block)
	local cx, b = Fake.block(pane)
	local copy = list.open(cx, ARGS, nil)
	list.frame(copy, cx)
	return copy, cx, b
end

local function press(list: Runtime.Runtime, copy: Runtime.Copy, cx: BlockCx, name: string, text: string?): boolean
	local k: any = { name = name, text = text or (if #name == 1 then name else nil) }
	return list.key(copy, k, cx)
end

local function typed(list: Runtime.Runtime, copy: Runtime.Copy, cx: BlockCx, text: string)
	for i = 1, #text do
		press(list, copy, cx, string.sub(text, i, i))
	end
end

-- The requests a copy opened with verb `verb`, parsed.
local function requests(b: Fake.Block, verb: string): { Protocol.Request }
	local out = {}
	for _, url in b.opened do
		local req = Protocol.parse_url(url)
		if req ~= nil and req.verb == verb then
			table.insert(out, req)
		end
	end
	return out
end

local function stored(m: Fake.Machine): Store.Deck
	return m.kv[Store.KEY]
end

local HOME = "/home/dev"
-- The pane shell the planted processes run under: it carries no agent's id.
local SHELL_PID = "7"
-- Claude Code conversation ids (uuids, the only shape its launch line takes).
local SID_A = "aaaaaaaa-0000-4000-8000-00000000000a"
local SID_B = "bbbbbbbb-0000-4000-8000-00000000000b"
local SID_C = "cccccccc-0000-4000-8000-00000000000c"

-- Plants process `pid` as `/proc` shows it: its name, its parent and its start time (`/proc/<pid>/stat`, read after
-- the name's last `)`), and, when `carries`, the agent's id in its environment, which only grep's exit status tells.
local function proc(m: Fake.Machine, pid: string, name: string, parent: string, carries: boolean, start: string?)
	local stamp = start or ("1000" .. pid)
	m.files["/proc/" .. pid .. "/stat"] =
		string.format("%s (%s) S %s %s%s 0 0\n", pid, name, parent, string.rep("0 ", 17), stamp)
	m.files["/proc/" .. pid .. "/comm"] = name .. "\n"
	if carries then
		m.grep[pid] = 0
	else
		m.grep[pid] = nil
	end
end

-- Plants one Claude session file and, when `yes`, its `claude` carrying the agent's id as the pane shell's child, as
-- the launch line's `sh` leaves it by exec, on a fresh start and on a resume alike.
local function plant(m: Fake.Machine, pid: string, sid: string, cwd: string, yes: boolean)
	m.home = HOME
	m.files[HOME .. "/.claude/sessions/" .. pid .. ".json"] = m.json({ sessionId = sid, cwd = cwd })
	if yes then
		proc(m, SHELL_PID, "fish", "1", false)
		proc(m, pid, "claude", SHELL_PID, true)
	end
end

-- A pane running the ACP chat a claude agent ran before it ran as its CLI, still bound after the update.
local function spawn_claude(list: Runtime.Runtime, m: Fake.Machine, pane: number, id: string)
	m.panes[pane] = true
	list.spawn({
		program = "/bin/fish",
		args = { "-c", "env JUMPR_ID=" .. id .. " tern acp claude" },
		env = { TERN_PANE = tostring(pane) },
	})
end

-- The Claude Code line the window runs for claude agent `id` on conversation `sid`.
local function claude_line(id: string, sid: string): string
	return Agent.command("claude", id, "new", sid) :: string
end

-- A pane the window started with `line`, as Tern's spawn filter sees it: the pane shell running it.
local function spawn_line(list: Runtime.Runtime, m: Fake.Machine, pane: number, line: string): Bind.Replace?
	m.panes[pane] = true
	return list.spawn({ program = "/bin/fish", args = { "-c", line }, env = { TERN_PANE = tostring(pane) } })
end

-- One group and one claude record. Fields override the pending start.
local function claude_deck(id: string, fields: { [string]: any }?): Store.Deck
	local d = Store.empty()
	d.session = { name = "deck", host = "devbox" }
	table.insert(d.groups, { gid = "g1", name = "work", cwd = "/work", folded = false })
	local extra: { [string]: any } = { cli = "claude", state = "pending" }
	for k, v in (fields or {}) :: { [string]: any } do
		extra[k] = v
	end
	d.agents[id] = record(1, extra)
	return d
end

-- Enter on the last row, after its folder is known to exist. Nil when no start was sent.
local function restart_fields(
	list: Runtime.Runtime,
	copy: Runtime.Copy,
	cx: BlockCx,
	b: Fake.Block,
	m: Fake.Machine
): { [string]: string }?
	m.dirs["/work"] = true
	press(list, copy, cx, "G")
	press(list, copy, cx, "enter")
	local starts = requests(b, "start")
	local start = starts[#starts]
	return if start ~= nil then start.fields else nil
end

-- A status message from window `w` as the window sends it.
local function status_action(m: Fake.Machine, w: string, seq: number, a: { [string]: any }, p: number?): any
	local msg = {
		p = p or Protocol.P,
		w = w,
		seq = seq,
		full = true,
		t = Fake.wall(m.now),
		h = "connected",
		sn = "deck",
		hn = "devbox",
		dupb = false,
		em = "A",
		a = a,
	}
	return { ev = "action", act = "st", value = m.json(msg) }
end

-- A key in one copy changes the list every copy shows: the keyed copy renders first (Tern does it when the key
-- hook returns) and the others follow on the host's next turn, coalesced, so a run of keys renders them once.
do
	local list, m = list_on(deck())
	local c1, cx1, b1 = open(list, 101)
	local c2, cx2, b2 = open(list, 102)
	local before1, before2 = b1.renders, b2.renders
	check(press(list, c1, cx1, "j"), "a move in a copy changes its view")
	check(b1.renders == before1 and b2.renders == before2, "no copy is rendered inside the key hook")
	m.advance(0)
	check(b2.renders == before2 + 1 and b1.renders == before1, "the other copy is rendered after, the keyed one is not")
	local moved = press(list, c1, cx1, "j")
	moved = press(list, c1, cx1, "k") or moved
	moved = press(list, c1, cx1, "j") or moved
	check(moved, "a run of moves changes its view")
	m.advance(0)
	check(b2.renders == before2 + 2, "a run of keys renders the other copy once per flush, not once per key")
	local f2 = list.frame(c2, cx2)
	check(f2.ui.selection ~= nil and f2.ui.selection.id == "agent-b", "the other copy shows the moved selection")
end

-- A move onto an agent asks the window to show its tab only after a 120 ms pause; a move inside the pause replaces it.
do
	local list, m = list_on(deck())
	local c, cx, b = open(list, 101)
	press(list, c, cx, "j")
	m.advance(100)
	check(#requests(b, "show") == 0, "no tab is shown during the pause")
	press(list, c, cx, "j")
	m.advance(119)
	check(#requests(b, "show") == 0, "a second move restarts the pause")
	m.advance(1)
	local shows = requests(b, "show")
	check(#shows == 1 and shows[1].fields.id == "agent-b", "only the last agent's tab is shown")
end

-- `n` checks the group's folder on this machine first: a gone folder stores and starts nothing; an existing one stores
-- a pending record before the window is asked to start it.
do
	local list, m = list_on(deck())
	local c, cx, b = open(list, 101)
	press(list, c, cx, "n")
	local f = list.frame(c, cx)
	check(f.ui.notice == "folder not found on devbox", "a gone folder is refused: " .. tostring(f.ui.notice))
	check(#requests(b, "start") == 0, "nothing is started")
	check(stored(m).agents.aaaaaaaa == nil, "no record is stored")
	m.dirs["/work"] = true
	press(list, c, cx, "n")
	local starts = requests(b, "start")
	check(#starts == 1 and starts[1].fields.id == "aaaaaaaa", "an existing folder starts the agent")
	local r = stored(m).agents.aaaaaaaa
	check(r ~= nil and r.state == "pending", "the pending record is saved")
	-- No reply within the reply limit marks the start failed.
	m.advance(Requests.REPLY_MS)
	list.tick()
	check(stored(m).agents.aaaaaaaa.failed == true, "a start with no reply is marked failed")
end

-- A failed start reply names the agent and the machine. Enter on the failed row retries it after the same folder
-- check: a gone folder starts nothing, an existing one starts it again.
do
	local list, m = list_on(deck())
	m.dirs["/work"] = true
	local c, cx, b = open(list, 101)
	press(list, c, cx, "n")
	local start = requests(b, "start")[1]
	local reply = m.json({ p = Protocol.P, b = start.b, r = start.r, ok = false, err = "no session" })
	list.event(c, { ev = "action", act = "res", value = reply } :: any, cx)
	local f = list.frame(c, cx)
	check(f.ui.notice ~= nil and string.find(f.ui.notice, "failed on devbox: no session", 1, true) ~= nil, "named")
	check(stored(m).agents.aaaaaaaa.failed == true, "a failed start is marked failed")
	press(list, c, cx, "G")
	local sel = list.frame(c, cx).ui.selection
	check(sel ~= nil and sel.id == "aaaaaaaa", "the failed row is selected")
	m.dirs["/work"] = nil
	press(list, c, cx, "enter")
	check(list.frame(c, cx).ui.notice == "folder not found on devbox", "a retry in a gone folder is refused")
	check(#requests(b, "start") == 1 and stored(m).agents.aaaaaaaa.failed == true, "nothing is started again")
	m.dirs["/work"] = true
	press(list, c, cx, "enter")
	check(#requests(b, "start") == 2, "a retry in an existing folder starts the agent again")
	check(stored(m).agents.aaaaaaaa.failed == nil, "and clears the failure")
end

-- `g` checks a new group's folder on this machine (the line starts with the copy's own folder): a gone folder keeps
-- the folder line open and stores nothing; an existing one goes on to the name line.
do
	local list, m = list_on(deck())
	local c, cx = open(list, 101)
	press(list, c, cx, "g")
	check(list.frame(c, cx).ui.text == "/work", "the folder line starts with the copy's folder")
	press(list, c, cx, "enter")
	local f = list.frame(c, cx)
	check(f.ui.notice == "folder not found on devbox", "a gone folder is refused")
	check(f.ui.mode == "input" and f.ui.purpose == "folder", "the folder line stays open")
	check(#stored(m).groups == 1, "no group is stored")
	m.dirs["/work"] = true
	press(list, c, cx, "enter")
	f = list.frame(c, cx)
	check(f.ui.purpose == "group", "an existing folder opens the name line")
end

-- `o` types the message only once the deck that records it is saved: with kv refusing the save nothing is typed and
-- the message is held; with kv working it is typed into the agent's pane.
do
	local list, m = list_on(deck())
	local c, cx = open(list, 101)
	press(list, c, cx, "j")
	m.kv_fails = true
	press(list, c, cx, "o")
	typed(list, c, cx, "hi")
	press(list, c, cx, "enter")
	check(#m.typed == 0, "nothing is typed when kv cannot take the save")
	local f = list.frame(c, cx)
	check(f.ui.notice ~= nil and string.find(f.ui.notice, "not sent on devbox", 1, true) ~= nil, "the list says so")
	m.kv_fails = false
	local list2, m2 = list_on(deck())
	local c2, cx2 = open(list2, 101)
	press(list2, c2, cx2, "j")
	press(list2, c2, cx2, "o")
	typed(list2, c2, cx2, "hi")
	press(list2, c2, cx2, "enter")
	check(#m2.typed == 1 and m2.typed[1].pane == 11 and m2.typed[1].text == "hi\r", "the message is typed")
	check(stored(m2).agents["agent-a"].last_send_ms ~= nil, "and the send is recorded")
end

-- kv refusing a save the way Tern's kv does (it raises, and the error text carries the Lua stack traceback after the
-- reason): the list says why in one line, and the traceback goes to Tern's log, never to the list.
do
	local logged: { string } = {}
	local log_warn = Compat.log_warn
	Compat.log_warn = function(text: string)
		table.insert(logged, text)
	end
	local list, m = list_on(deck())
	local c, cx = open(list, 101)
	press(list, c, cx, "j")
	m.kv_raises = "Permission denied (os error 13)\n"
		.. "stack traceback:\n"
		.. "\t[C]: in function 'set'\n"
		.. "\t./lib/compat.luau:95: in function 'act'\n"
		.. "\t./lib/host/store.luau:226: in function 'save'"
	press(list, c, cx, "o")
	typed(list, c, cx, "hi")
	press(list, c, cx, "enter")
	local f = list.frame(c, cx)
	check(#m.typed == 0, "nothing is typed when kv refuses the save")
	check(
		f.save_error == "jumpr data not saved on devbox: Permission denied (os error 13)",
		"the list says why in one line: " .. tostring(f.save_error)
	)
	check(f.ui.notice ~= nil and string.find(f.ui.notice, "\n", 1, true) == nil, "the notice is one line too")
	local traced = false
	for _, line in logged do
		if string.find(line, "stack traceback:", 1, true) ~= nil then
			traced = true
		end
	end
	check(traced, "the traceback goes to Tern's log")
	Compat.log_warn = log_warn
end

-- A multi-line paste into the `o` line, as Tern sends it (a `paste` key with the text): the host puts it in the line
-- at the caret, keys gets the whole line, and Enter refuses it as more than one line, typing and stamping nothing.
do
	local list, m = list_on(deck())
	local c, cx = open(list, 101)
	press(list, c, cx, "j")
	press(list, c, cx, "o")
	local paste: any = { name = "paste", text = "line one\nline two" }
	list.key(c, paste, cx)
	check(list.frame(c, cx).ui.text == "line one\nline two", "the paste lands in the line, newline and all")
	press(list, c, cx, "enter")
	local f = list.frame(c, cx)
	check(f.ui.notice == "single line only" and f.ui.mode == "input", "Enter refuses a multi-line message")
	check(#m.typed == 0, "nothing is typed")
	check(
		stored(m).agents["agent-a"].last_send_ms == nil and stored(m).queue["agent-a"] == nil,
		"nothing stamped or held"
	)
end

-- `q` holds a message until the agent is idle: with no status nothing is typed; a status message saying the agent
-- is idle types it and clears the hold.
do
	local list, m = list_on(deck())
	local c, cx = open(list, 101)
	press(list, c, cx, "j")
	press(list, c, cx, "q")
	typed(list, c, cx, "later")
	press(list, c, cx, "enter")
	check(stored(m).queue["agent-a"] ~= nil, "the message is held")
	list.tick()
	check(#m.typed == 0, "with no status nothing is typed")
	list.event(c, status_action(m, "win1", 1, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx)
	check(#m.typed == 1 and m.typed[1].text == "later\r", "an idle status types the held message")
	check(stored(m).queue["agent-a"] == nil, "and clears the hold")
end

-- Machine devbox's deck with agent-a (pane 11) running as `cli`; agent-b (pane 12) stays omp.
local function cli_deck(cli: string): Store.Deck
	local d = deck()
	d.agents["agent-a"].cli = cli
	if cli == "claude" then
		d.agents["agent-a"].session = SID_A
	end
	return d
end

-- A claude or codex agent is typed into only once it has itself reported idle: while its pane only reads not busy,
-- `o` holds the text. Then it gets the text alone, saved as sent first, and Enter as a second write 200 ms later into
-- the same pane (written together, its prompt takes both as one paste). An omp agent still gets one write.
do
	for _, cli in { "claude", "codex" } do
		local list, m = list_on(cli_deck(cli))
		local c, cx = open(list, 101)
		list.event(c, status_action(m, "win1", 1, { ["agent-a"] = { { s = "i", src = "pane" } } }), cx)
		press(list, c, cx, "j")
		press(list, c, cx, "o")
		typed(list, c, cx, "hi")
		press(list, c, cx, "enter")
		check(#m.typed == 0, cli .. ": a pane that only reads not busy is not typed into")
		check(
			stored(m).queue["agent-a"] ~= nil and stored(m).queue["agent-a"].text == "hi",
			cli .. ": the text is held"
		)
		check(list.frame(c, cx).ui.notice == "not idle yet — message queued", cli .. ": and the list says so")
		list.event(c, status_action(m, "win1", 2, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx)
		check(#m.typed == 1 and m.typed[1].pane == 11 and m.typed[1].text == "hi", cli .. ": its idle types the text")
		check(stored(m).queue["agent-a"] == nil, cli .. ": saved as sent before it went")
		m.advance(199)
		check(#m.typed == 1, cli .. ": no Enter with it")
		m.advance(1)
		check(#m.typed == 2 and m.typed[2].pane == 11 and m.typed[2].text == "\r", cli .. ": Enter 200 ms later")

		press(list, c, cx, "o")
		typed(list, c, cx, "more")
		press(list, c, cx, "enter")
		check(#m.typed == 3 and m.typed[3].text == "more", cli .. ": o on its reported idle types the text at once")
		check(stored(m).agents["agent-a"].last_send_ms == Fake.wall(m.now), cli .. ": the send is recorded with it")
		m.advance(200)
		check(#m.typed == 4 and m.typed[4].pane == 11 and m.typed[4].text == "\r", cli .. ": then its Enter")

		press(list, c, cx, "j")
		press(list, c, cx, "o")
		typed(list, c, cx, "ok")
		press(list, c, cx, "enter")
		m.advance(1000)
		check(#m.typed == 5 and m.typed[5].pane == 12 and m.typed[5].text == "ok\r", "omp still gets one write")
	end
end

-- The pane gone before the Enter (closed, or its program exited), or the Enter's write failing: no Enter is typed
-- anywhere, and the message comes back as a failed `o` does: the send's stamp rolled back, the text held with why,
-- and the list says so.
do
	-- Agent-a of kind `cli`, idle as it reported; `o` types "hi" into it, then `between` runs before the Enter is due.
	local function sent_then(
		cli: string,
		between: (Runtime.Runtime, Fake.Machine) -> ()
	): (Fake.Machine, string?, number)
		local list, m = list_on(cli_deck(cli))
		local c, cx, b = open(list, 101)
		list.event(c, status_action(m, "win1", 1, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx)
		press(list, c, cx, "j")
		press(list, c, cx, "o")
		typed(list, c, cx, "hi")
		press(list, c, cx, "enter")
		check(#m.typed == 1 and m.typed[1].text == "hi", cli .. ": the text goes")
		local renders = b.renders
		between(list, m)
		m.advance(200)
		return m, list.frame(c, cx).ui.notice, b.renders - renders
	end
	local cases = {
		{
			name = "a closed pane",
			cli = "claude",
			why = "pane gone",
			between = function(list: Runtime.Runtime, m: Fake.Machine)
				m.panes[11] = nil
				list.tick()
			end,
		},
		{
			name = "a pane whose program exited",
			cli = "codex",
			why = "pane gone",
			between = function(list: Runtime.Runtime, _m: Fake.Machine)
				list.pane_exited({ pane = 11, status = 0 })
			end,
		},
		{
			name = "a failed write",
			cli = "claude",
			why = "pane 11 is gone",
			between = function(_list: Runtime.Runtime, m: Fake.Machine)
				m.write_fails = true
			end,
		},
	}
	for _, case in cases do
		local m, notice, renders = sent_then(case.cli, case.between)
		check(#m.typed == 1, case.name .. ": no Enter is typed")
		local held = stored(m).queue["agent-a"]
		check(held ~= nil and held.text == "hi" and held.err == case.why, case.name .. ": the text is held with why")
		check(stored(m).agents["agent-a"].last_send_ms == nil, case.name .. ": the send's stamp goes back")
		local said = "message for agent-a not sent on devbox: " .. case.why
		check(notice == said and renders > 0, case.name .. ": the list says so: " .. tostring(notice))
	end
end

-- A reload between the text and its Enter never sends the message twice: the deck saved before the text holds no
-- message, so the reloaded list types nothing again (the Enter went with the old timer).
do
	local list, m = list_on(cli_deck("codex"))
	local c, cx = open(list, 101)
	press(list, c, cx, "j")
	press(list, c, cx, "q")
	typed(list, c, cx, "later")
	press(list, c, cx, "enter")
	list.event(c, status_action(m, "win1", 1, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx)
	check(#m.typed == 1 and m.typed[1].text == "later", "the held message's text goes")
	local again, m2 = list_on(stored(m))
	local c2, cx2 = open(again, 101)
	again.event(c2, status_action(m2, "win1", 1, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx2)
	again.tick()
	m2.advance(1000)
	check(#m2.typed == 0, "the reloaded list types nothing again")
end

-- The window pushes one agent's change to every copy, and a full snapshot to every copy every 30 s: a change
-- renders each copy once, and a message that changes nothing the rows show renders none — not one render per copy
-- per message, which with many copies cost more than the list could keep up with.
do
	local list, m = list_on(deck())
	local c1, cx1, b1 = open(list, 101)
	local c2, cx2, b2 = open(list, 102)
	local c3, cx3, b3 = open(list, 103)
	local r1, r2, r3 = b1.renders, b2.renders, b3.renders
	local entries = { ["agent-a"] = { { s = "w", src = "agents" } } }
	list.event(c1, status_action(m, "win1", 1, entries), cx1)
	check(b1.renders == r1 + 1 and b2.renders == r2 + 1 and b3.renders == r3 + 1, "a change renders every copy once")
	r1, r2, r3 = b1.renders, b2.renders, b3.renders
	list.event(c2, status_action(m, "win1", 2, entries), cx2)
	list.event(c3, status_action(m, "win1", 3, entries), cx3)
	check(
		b1.renders == r1 and b2.renders == r2 and b3.renders == r3,
		"the same change at the other copies renders nothing"
	)
	m.advance(30000)
	-- The silence turned the header's health to "stale", so the first snapshot after it changes the head line
	-- and renders once; the same snapshot at the other copies changes nothing.
	list.event(c1, status_action(m, "win1", 4, entries), cx1)
	check(
		b1.renders == r1 + 1 and b2.renders == r2 + 1 and b3.renders == r3 + 1,
		"a snapshot after silence renders once"
	)
	r1, r2, r3 = b1.renders, b2.renders, b3.renders
	list.event(c2, status_action(m, "win1", 5, entries), cx2)
	list.event(c3, status_action(m, "win1", 6, entries), cx3)
	check(
		b1.renders == r1 and b2.renders == r2 and b3.renders == r3,
		"a full snapshot that changes nothing renders nothing"
	)
end
-- A status message from another protocol version shows the banner and changes nothing else.
do
	local list, m = list_on(deck())
	local c, cx = open(list, 101)
	local saved = stored(m)
	list.event(c, status_action(m, "win1", 1, { ["agent-a"] = { { s = "q", src = "agents" } } }, Protocol.P + 1), cx)
	local f = list.frame(c, cx)
	check(f.version == "bad_p_newer", "the banner names a newer version")
	check(stored(m) == saved, "nothing is saved")
	for _, row in f.rows do
		if row.id == "agent-a" then
			check(row.code == "unknown", "the other version's status is not shown")
		end
	end
end

-- Runtime settings are loaded on first use. A valid default is saved and every list copy is rendered; the next new
-- agent uses it. An invalid default is refused without a save or render, and the returned settings cannot mutate the deck.
do
	local list, m = list_on(deck())
	local c1, cx1, b1 = open(list, 101)
	local _c2, _cx2, b2 = open(list, 102)
	local before1, before2 = b1.renders, b2.renders
	check(list.host_name() == "devbox", "the runtime reports the list machine's name")
	check(not list.readonly(), "an ordinary deck is writable")
	check(list.set_agent("claude") == nil, "a valid default agent is accepted")
	check(b1.renders == before1 + 1 and b2.renders == before2 + 1, "changing the default agent renders every list copy")
	check(stored(m).settings.agent == "claude", "the default agent is saved")
	local detached = list.settings()
	detached.agent = "codex"
	check(list.settings().agent == "claude", "settings are returned as a detached value")
	local saved, writes = stored(m), m.kv_writes
	before1, before2 = b1.renders, b2.renders
	local invalid = list.set_agent("a b")
	check(invalid ~= nil and string.find(invalid, "\n", 1, true) == nil, "an invalid default returns a one-line reason")
	check(stored(m) == saved and stored(m).settings.agent == "claude", "an invalid default changes nothing")
	check(
		m.kv_writes == writes and b1.renders == before1 and b2.renders == before2,
		"an invalid default is neither saved nor rendered"
	)
	m.dirs["/work"] = true
	press(list, c1, cx1, "n")
	local starts = requests(b1, "start")
	check(#starts == 1 and starts[1].fields.cli == "claude", "the default agent kind is sent for a new agent")
	check(stored(m).agents.aaaaaaaa.cli == "claude", "the new record keeps the default agent kind")
end

-- A key override is saved and reaches every copy at once: the old key stops dispatching and the new key starts an
-- agent. A nil key restores the default.
do
	local list, m = list_on(deck())
	local c1, cx1, b1 = open(list, 101)
	local c2, cx2, b2 = open(list, 102)
	local before1, before2 = b1.renders, b2.renders
	check(list.set_key("new", "a") == nil, "a free list key is accepted")
	check(b1.renders == before1 + 1 and b2.renders == before2 + 1, "changing a key renders every list copy")
	check(stored(m).settings.keys.new == "a", "the key override is saved")
	local f1, f2 = list.frame(c1, cx1), list.frame(c2, cx2)
	check(
		f1.map.key_of.new == "a" and f2.map.key_of.new == "a" and f1.map.action_of.n == nil,
		"every frame carries the resolved override"
	)
	m.dirs["/work"] = true
	press(list, c1, cx1, "n")
	check(#requests(b1, "start") == 0 and #requests(b2, "start") == 0, "the old key no longer starts an agent")
	press(list, c2, cx2, "a")
	check(#requests(b2, "start") == 1, "the new key starts an agent in another copy")
	check(
		list.set_key("new", nil) == nil and list.settings().keys.new == nil and stored(m).settings.keys.new == nil,
		"a nil key restores and saves its default"
	)
end

-- A reset whose default key another action now holds is refused, so no action is left without a working key.
do
	local list, m = list_on(deck())
	local _c, _cx, b = open(list, 101)
	check(list.set_key("down", "x") == nil, "moving an action off its default is accepted")
	check(list.set_key("up", "j") == nil, "another action can take the freed default")
	local saved, writes, renders = stored(m), m.kv_writes, b.renders
	check(list.set_key("down", nil) == "taken by previous row", "a reset names the holder of the default")
	check(list.settings().keys.down == "x", "the refused reset keeps the override")
	check(stored(m) == saved and m.kv_writes == writes and b.renders == renders, "a refused reset changes nothing")
	check(list.set_key("up", nil) == nil, "resetting the holder frees the default")
	check(list.set_key("down", nil) == nil, "and the first reset then restores its default")
end

-- Reset clears every override, saves the defaults and renders every copy; dispatch follows the restored map.
do
	local list, m = list_on(deck())
	local c, cx, b1 = open(list, 101)
	local _c2, _cx2, b2 = open(list, 102)
	check(list.set_key("new", "a") == nil and list.set_key("group", "b") == nil, "two key overrides are accepted")
	local before1, before2 = b1.renders, b2.renders
	check(list.reset_keys() == nil, "all list keys can be reset")
	check(b1.renders == before1 + 1 and b2.renders == before2 + 1, "resetting keys renders every list copy")
	check(next(stored(m).settings.keys) == nil, "reset saves an empty override table")
	local f = list.frame(c, cx)
	check(f.map.key_of.new == "n" and f.map.key_of.group == "g", "reset restores the default map")
	m.dirs["/work"] = true
	press(list, c, cx, "a")
	check(#requests(b1, "start") == 0, "an old override does nothing after reset")
	press(list, c, cx, "n")
	check(#requests(b1, "start") == 1, "the default key starts an agent after reset")
end

-- A key held by another action is refused without changing, saving or rendering the deck.
do
	local list, m = list_on(deck())
	local _c, _cx, b = open(list, 101)
	local saved, writes, renders = stored(m), m.kv_writes, b.renders
	check(list.set_key("new", "j") == "taken by next row", "a colliding key names its holder")
	check(stored(m) == saved and next(list.settings().keys) == nil, "a colliding key changes nothing")
	check(m.kv_writes == writes and b.renders == renders, "a colliding key is neither saved nor rendered")
end

-- A settings block has its own sender but shares the list's saved request counter. It may send only cfg, so it cannot
-- turn its route into an agent launch.
do
	local m = Fake.machine(deck())
	m.panes = { [11] = true, [12] = true, [101] = true }
	local draws = 0
	local list = Runtime.new(m.compat, function(_n: number): number
		draws += 1
		return if draws <= 8 then 1 else 2
	end)
	local c, cx, b = open(list, 101)
	local sender = list.new_sender()
	check(sender.b ~= c.sender.b, "the settings block has a sender isolated from the list copy")
	local ok, reason = list.send_from(cx, sender, "cfg", { op = "read" })
	local cfgs = requests(b, "cfg")
	local cfg = cfgs[1]
	check(ok and reason == nil and #cfgs == 1, "a cfg request is opened")
	check(
		string.sub(b.opened[1], 1, 12) == "jumpr://cfg?"
			and cfg.p == Protocol.P
			and cfg.fields.op == "read"
			and cfg.b == sender.b,
		"the cfg URL carries the protocol, operation and settings sender"
	)
	check(cfg.r == 1 and stored(m).next_req == 2, "cfg advances the shared saved request counter")
	press(list, c, cx, "j")
	m.advance(120)
	local shows = requests(b, "show")
	check(
		#shows == 1 and shows[1].b == c.sender.b and shows[1].b ~= cfg.b and shows[1].r == 2,
		"the next list request keeps the list sender and follows the shared counter"
	)
	local opened, saved, writes = #b.opened, stored(m), m.kv_writes
	local started, refused = list.send_from(cx, sender, "start", { id = "agent-new", cwd = "/work" })
	check(
		not started and refused ~= nil and string.find(refused, "\n", 1, true) == nil,
		"a settings sender refuses start with a one-line reason"
	)
	check(
		#b.opened == opened and stored(m) == saved and m.kv_writes == writes,
		"a refused start opens nothing and does not advance or save the deck"
	)
end

-- A deck from a newer Jumpr version is read-only: changing its settings is refused without replacing, saving or
-- rendering it.
do
	local d = deck()
	d.schema = Store.SCHEMA + 1
	local list, m = list_on(d)
	local _c, _cx, b = open(list, 101)
	check(list.readonly(), "a newer deck is read-only")
	local saved, writes, renders = m.kv[Store.KEY], m.kv_writes, b.renders
	local agent_reason = list.set_agent("claude")
	local key_reason = list.set_key("new", "a")
	local reset_reason = list.reset_keys()
	check(
		agent_reason == "settings are read-only"
			and key_reason == "settings are read-only"
			and reset_reason == "settings are read-only",
		"a read-only deck refuses every settings change with a one-line reason"
	)
	check(m.kv[Store.KEY] == saved and m.kv_writes == writes, "a read-only deck is unchanged")
	check(
		b.renders == renders and list.settings().agent == "omp" and next(list.settings().keys) == nil,
		"read-only settings are neither rendered nor applied"
	)
end

-- A copy whose pane stays missing from the pane list for three ticks drops out: it is no longer rendered.
do
	local list, m = list_on(deck())
	local c1, cx1 = open(list, 101)
	local _c2, _cx2, b2 = open(list, 103)
	for _ = 1, 3 do
		m.advance(1000)
		list.tick()
	end
	local before = b2.renders
	press(list, c1, cx1, "j")
	check(b2.renders == before, "a copy missing for three ticks is not rendered any more")
end

-- The hooks bind panes to records: a pending agent binds through the spawn filter on the next tick; the same session
-- folder typed into another shell (no spawn, so nothing stops it) makes the row a duplicate; the pane exiting leaves
-- one; the last exit marks the record exited; and a pane exiting within a minute of its stop deletes the record.
do
	local d = deck()
	d.agents["agent-c"] = record(3, { state = "pending" })
	d.agents["agent-b"].state = "stopping"
	d.agents["agent-b"].stop_ms = Fake.wall(0) - 1000
	local list, m = list_on(d)
	local c, cx = open(list, 101)
	local function spawn(pane: number)
		m.panes[pane] = true
		list.spawn({
			program = "omp",
			args = { "--continue", "--session-dir", "~/.omp/deck/agent-c" },
			env = { TERN_PANE = tostring(pane) },
		})
	end
	local function row_c(): any
		for _, row in list.frame(c, cx).rows do
			if row.id == "agent-c" then
				return row
			end
		end
		return nil
	end
	spawn(21)
	check(stored(m).agents["agent-c"].state == "pending", "the spawn filter never saves")
	list.tick()
	local r = stored(m).agents["agent-c"]
	check(r.state == "live" and r.pane == 21, "the next tick binds the record to its pane")
	m.panes[22] = true
	list.command_started({ pane = 22, line = "omp --continue --session-dir ~/.omp/deck/agent-c" })
	list.tick()
	check(row_c().dup == true, "a second pane of the same folder is a duplicate")
	m.panes[22] = nil
	list.pane_exited({ pane = 22, status = 0 })
	check(row_c().dup == false and stored(m).agents["agent-c"].state == "live", "one pane left is no duplicate")
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	check(stored(m).agents["agent-c"].state == "exited", "the last pane exiting marks the record exited")
	m.panes[12] = nil
	list.pane_exited({ pane = 12, status = 0 })
	check(stored(m).agents["agent-b"] == nil, "a pane exiting within a minute of its stop deletes the record")
end

-- Enter on an agent whose pane exited restarts it in a new pane, and the exited pane stays open: the window then
-- reports both panes for the deck id, the exited one as "x". A pane whose program exited is no duplicate, so the
-- restarted row shows the new pane's status, Enter on it jumps, and a held message is typed into it. Two running
-- panes for one deck id are still a duplicate.
do
	local list, m = list_on(deck())
	m.dirs["/work"] = true
	local c, cx, b = open(list, 101)
	local function row_a(): any
		for _, row in list.frame(c, cx).rows do
			if row.id == "agent-a" then
				return row
			end
		end
		return nil
	end
	local dead = { s = "x", e = "exit status 1", src = "agents" }
	local seq = 0
	local function report(entries: { any })
		seq += 1
		list.event(c, status_action(m, "win1", seq, { ["agent-a"] = entries }), cx)
	end
	report({ { s = "i", src = "agents" } })
	list.pane_exited({ pane = 11, status = 1 })
	report({ dead })
	local row = row_a()
	check(row.state == "exited" and row.code == "error" and row.dup == false, "the exited agent shows as an error")
	press(list, c, cx, "j")
	press(list, c, cx, "enter")
	local starts = requests(b, "start")
	check(#starts == 1 and starts[1].fields.id == "agent-a", "Enter on the exited row restarts it")
	m.panes[13] = true
	list.spawn({
		program = "omp",
		args = { "--continue", "--session-dir", "~/.omp/deck/agent-a" },
		env = { TERN_PANE = "13" },
	})
	list.tick()
	check(stored(m).agents["agent-a"].state == "live", "the new pane binds the record")
	report({ dead, { s = "i", src = "agents" } })
	row = row_a()
	check(row.dup == false, "the exited pane left open is no duplicate")
	check(row.code == "idle", "the row shows the running pane's status: " .. tostring(row.code))
	press(list, c, cx, "enter")
	check(list.frame(c, cx).ui.notice ~= "duplicate: two panes share this agent", "Enter is not refused")
	check(#requests(b, "jump") == 1, "Enter on the restarted row jumps to it")
	press(list, c, cx, "q")
	typed(list, c, cx, "later")
	press(list, c, cx, "enter")
	list.tick()
	check(#m.typed == 1 and m.typed[1].pane == 13, "a held message is typed into the running pane")
	report({ dead, { s = "i", src = "agents" }, { s = "i", src = "agents" } })
	check(row_a().dup == true, "two running panes for one deck id are still a duplicate")
end

-- o on an agent whose pane exited restarts it as Enter does and holds the message for it: nothing is typed while the
-- new pane starts or works, and once the restarted pane reports idle, beside the exited pane left open, the message
-- is typed into it and is no longer held.
do
	local list, m = list_on(deck())
	m.dirs["/work"] = true
	local c, cx, b = open(list, 101)
	local dead = { s = "x", e = "exit status 1", src = "agents" }
	local seq = 0
	local function report(entries: { any })
		seq += 1
		list.event(c, status_action(m, "win1", seq, { ["agent-a"] = entries }), cx)
	end
	report({ { s = "i", src = "agents" } })
	list.pane_exited({ pane = 11, status = 1 })
	report({ dead })
	press(list, c, cx, "j")
	press(list, c, cx, "o")
	typed(list, c, cx, "go-on")
	press(list, c, cx, "enter")
	local starts = requests(b, "start")
	check(
		#starts == 1 and starts[1].fields.id == "agent-a" and starts[1].fields.land == "1",
		"o on the exited row restarts it as Enter does"
	)
	local held = stored(m).queue["agent-a"]
	check(held ~= nil and held.text == "go-on", "the message is held and saved")
	check(list.frame(c, cx).ui.notice == "restarting — message queued", "the list says so")
	list.tick()
	check(#m.typed == 0, "nothing is typed while the agent starts")
	m.panes[13] = true
	list.spawn({
		program = "omp",
		args = { "--continue", "--session-dir", "~/.omp/deck/agent-a" },
		env = { TERN_PANE = "13" },
	})
	list.tick()
	check(stored(m).agents["agent-a"].state == "live", "the new pane binds the record")
	check(stored(m).queue["agent-a"] ~= nil, "the message is still held")
	report({ dead, { s = "w", src = "agents" } })
	list.tick()
	check(#m.typed == 0, "nothing is typed while the restarted agent works")
	report({ dead, { s = "i", src = "agents" } })
	check(
		#m.typed == 1 and m.typed[1].pane == 13 and m.typed[1].text == "go-on\r",
		"once it is idle the message is typed into the restarted pane"
	)
	check(stored(m).queue["agent-a"] == nil, "and is no longer held")
end

-- An agent restarted twice whose second pane exited too: both exited panes stay open, and the row is an exited
-- agent, not a duplicate, so Enter restarts it again.
do
	local d = deck()
	d.agents["agent-a"] = record(1, { state = "exited", exit = 1 })
	local list, m = list_on(d)
	m.dirs["/work"] = true
	local c, cx, b = open(list, 101)
	local dead = { s = "x", e = "exit status 1", src = "agents" }
	list.event(c, status_action(m, "win1", 1, { ["agent-a"] = { dead, dead } }), cx)
	local row: any = nil
	for _, r in list.frame(c, cx).rows do
		if r.id == "agent-a" then
			row = r
		end
	end
	check(row.dup == false and row.code == "error", "two exited panes are no duplicate")
	press(list, c, cx, "j")
	press(list, c, cx, "enter")
	check(#requests(b, "start") == 1, "Enter restarts the agent again")
end

-- The pane list read for one view serves the other copies' views for up to 200 ms; a hook or the time limit reads it
-- again.
do
	local list, m = list_on(deck())
	local c1, cx1 = open(list, 101)
	local c2, cx2 = open(list, 102)
	m.advance(300)
	local reads = m.pane_reads
	list.frame(c1, cx1)
	list.frame(c2, cx2)
	check(m.pane_reads == reads + 1, "one read serves a burst of views")
	m.advance(250)
	list.frame(c1, cx1)
	check(m.pane_reads == reads + 2, "a view after 200 ms reads the pane list again")
	list.command_started({ pane = 30, line = "ls" })
	list.frame(c2, cx2)
	check(m.pane_reads == reads + 3, "a hook in between reads it again")
end

-- An agent whose only running pane is parked: its row keeps its status (never `unknown`) and says it runs in no tab;
-- moving onto it gives it no tab, and Enter asks the window to jump to it, which deals it back into a tab.
do
	local list, m = list_on(deck())
	local c, cx, b = open(list, 101)
	list.event(c, status_action(m, "win1", 1, { ["agent-a"] = { { s = "i", src = "agents", k = true } } }), cx)
	local f = list.frame(c, cx)
	local row: any = nil
	for _, each in f.rows do
		if each.id == "agent-a" then
			row = each
		end
	end
	check(row ~= nil and row.code == "idle" and row.parked == true, "the parked agent keeps its status, marked parked")
	local parts = View.meta_parts(f, row, "/work")
	check(table.find(parts, "in no tab") ~= nil, "its row says it runs in no tab: " .. table.concat(parts, " · "))
	check(table.find(parts, "⏎ brings it back") ~= nil, "and that Enter brings it back")
	press(list, c, cx, "j")
	m.advance(200)
	check(#requests(b, "show") == 0, "moving onto it shows no tab")
	press(list, c, cx, "enter")
	local jumps = requests(b, "jump")
	check(#jumps == 1 and jumps[1].fields.id == "agent-a", "Enter jumps to it")
	list.event(c, status_action(m, "win1", 2, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx)
	for _, each in list.frame(c, cx).rows do
		if each.id == "agent-a" then
			row = each
		end
	end
	check(row.parked == nil, "back in a tab, the row is an ordinary one")
end

-- The safe removals. A stop an older window answers with a plain "not running" error (no `gone` mark) while this
-- machine still runs a pane for the agent (parked or not, the host cannot tell) keeps the record; the same answer once
-- no pane runs it here removes it, and removing it touches no file. A start that never got a pane stays, failed.
do
	local list, m = list_on(deck())
	local c, cx, b = open(list, 101)
	local function stop_answered_not_running(id: string)
		local stops = requests(b, "stop")
		local stop = stops[#stops]
		check(stop ~= nil and stop.fields.id == id, "d then y asks the window to stop " .. id)
		local reply = m.json({
			p = Protocol.P,
			b = stop.b,
			r = stop.r,
			ok = false,
			err = "agent " .. id .. " is not running on devbox",
		})
		list.event(c, { ev = "action", act = "res", value = reply } :: any, cx)
	end
	press(list, c, cx, "j")
	press(list, c, cx, "d")
	press(list, c, cx, "y")
	stop_answered_not_running("agent-a")
	m.advance(1000)
	list.tick()
	check(stored(m).agents["agent-a"] ~= nil, "a pane still runs it here: the record stays")
	check(stored(m).agents["agent-a"].state == "live", "and is live again")
	press(list, c, cx, "d")
	press(list, c, cx, "y")
	m.panes[11] = nil
	stop_answered_not_running("agent-a")
	m.advance(1000)
	list.tick()
	m.advance(Bind.MISSING_GRACE_MS)
	list.tick()
	check(stored(m).agents["agent-a"] == nil, "no pane runs it here: the record is removed")
	check(next(m.files) == nil, "removing it writes or removes no file")
	m.dirs["/work"] = true
	press(list, c, cx, "n")
	local id = requests(b, "start")[1].fields.id
	m.advance(30 * 1000)
	list.tick()
	local r = stored(m).agents[id]
	check(r ~= nil and r.state == "pending" and r.failed == true, "a start that never got a pane stays, failed")
end

-- `d` then `y` on an agent the window cannot find: the window answers the stop with an error marked `gone`. Here
-- this machine still runs the agent's pane (its program has not exited), so the mark is not believed: the agent goes
-- back to live and the list says the stop failed, rather than hiding a running agent. (With no running pane the mark
-- deletes the record; test/requests.luau pins that.) A stop that fails with the pane there, and one that gets no
-- answer, put the agent back to live and say the stop failed too.
do
	-- A fresh list stops agent-a, and the stop is answered as the window would: an error `err`, marked `gone` when
	-- asked, or no answer at all when `err` is nil.
	local function stop_agent_a(err: string?, gone: boolean?): (Fake.Machine, Runtime.Runtime, Runtime.Copy, BlockCx)
		local list, m = list_on(deck())
		local c, cx, b = open(list, 101)
		press(list, c, cx, "j")
		press(list, c, cx, "d")
		press(list, c, cx, "y")
		local stops = requests(b, "stop")
		local stop = stops[#stops]
		check(stop ~= nil and stop.fields.id == "agent-a", "d then y asks the window to stop agent-a")
		if err ~= nil then
			local reply = m.json({ p = Protocol.P, b = stop.b, r = stop.r, ok = false, err = err, gone = gone })
			list.event(c, { ev = "action", act = "res", value = reply } :: any, cx)
		end
		return m, list, c, cx
	end

	local m, list, c, cx = stop_agent_a("agent agent-a is not running on devbox", true)
	check(stored(m).agents["agent-a"].state == "live", "gone while this machine runs the pane keeps the agent")
	local f = list.frame(c, cx)
	check(f.ui.notice ~= nil and string.find(f.ui.notice, "stop failed", 1, true) == 1, "and says the stop failed")
	check(stored(m).agents["agent-b"].state == "live", "the other agent is untouched")

	local busy = "could not stop agent agent-a on devbox: the pane is busy"
	local m2, list2, c2, cx2 = stop_agent_a(busy, nil)
	check(stored(m2).agents["agent-a"].state == "live", "a stop that fails with its pane there puts it back")
	local notice = list2.frame(c2, cx2).ui.notice
	check(notice == "stop failed on devbox: " .. busy, "and says the stop failed: " .. tostring(notice))

	local m3, list3, c3, cx3 = stop_agent_a(nil, nil)
	m3.advance(Requests.REPLY_MS)
	list3.tick()
	check(stored(m3).agents["agent-a"].state == "live", "a stop with no answer puts the agent back")
	notice = list3.frame(c3, cx3).ui.notice
	check(notice == "stop failed on devbox", "and says the stop failed: " .. tostring(notice))
end

-- `d` then `y` on an exited agent takes it off the list with no stop sent.
do
	local d = deck()
	d.agents["agent-a"] = record(1, { state = "exited", exit = 0, ended_ms = Fake.wall(0) - 500 })
	local list, m = list_on(d)
	local c, cx, b = open(list, 101)
	press(list, c, cx, "j")
	press(list, c, cx, "d")
	press(list, c, cx, "y")
	check(stored(m).agents["agent-a"] == nil, "an exited agent is removed")
	check(#requests(b, "stop") == 0, "with no stop sent")
end

-- An agent whose pane closed by hand, with no stop asked (its tab closed): the row stays, as an exited agent Enter
-- restarts.
do
	local list, m = list_on(deck())
	open(list, 101)
	m.panes[12] = nil
	list.pane_exited({ pane = 12, status = 0 })
	m.advance(1000)
	list.tick()
	local r = stored(m).agents["agent-b"]
	check(r ~= nil and r.state == "exited", "closing an agent's tab by hand keeps its row, exited")
end

-- One omp per agent. Two windows acting on one start spawn the same session folder twice within milliseconds: the
-- spawn filter lets the first run and replaces the second with a line that says so and exits, which is never bound;
-- the row is no duplicate and the list says a second start was stopped.
do
	local d = deck()
	d.agents["agent-c"] = record(3, { state = "pending" })
	local list, m = list_on(d)
	local c, cx = open(list, 101)
	local function spawn(pane: number): any
		m.panes[pane] = true
		return list.spawn({
			program = "/bin/fish",
			args = { "-l", "-c", "omp --continue --session-dir ~/.omp/deck/agent-c" },
			env = { TERN_PANE = tostring(pane) },
		})
	end
	check(spawn(21) == nil, "the first start runs as it is")
	local instead = spawn(22)
	check(instead ~= nil, "the second start of the same agent is replaced")
	local said = if instead ~= nil then table.concat(instead.args, " ") else ""
	check(
		string.find(said, "agent agent-c already runs in pane 21", 1, true) ~= nil
			and string.find(said, "omp", 1, true) == nil,
		"by a line naming the running pane, which starts no omp: " .. said
	)
	-- The replacement prints its line and exits 0, so Tern closes its pane; an omp left running would stay.
	if instead ~= nil then
		m.panes[22] = nil
		list.pane_exited({ pane = 22, status = 0 })
	end
	list.tick()
	local r = stored(m).agents["agent-c"]
	check(r.state == "live" and r.pane == 21, "the first pane is the agent's")
	local f = list.frame(c, cx)
	local row: any = nil
	for _, each in f.rows do
		if each.id == "agent-c" then
			row = each
		end
	end
	check(row ~= nil and row.dup == false, "the row is no duplicate")
	check(
		f.ui.notice == "agent agent-c already runs in pane 21: a second start was stopped",
		"the list says a second start was stopped: " .. tostring(f.ui.notice)
	)
end

-- The same duplicate guard covers every identity carried by JUMPR_ID: an ACP chat, Claude Code's line (its `sh -c`
-- included) and the Codex CLI. The first process binds and a second spawn of that line for the running agent is
-- replaced, so only one pane runs the agent and nothing it would start runs twice.
do
	type Case = { cli: string, line: string, word: string }
	local cases: { Case } = {
		{ cli = "copilot", line = "env JUMPR_ID=abcdefgh tern acp copilot", word = "tern acp" },
		{ cli = "claude", line = claude_line("abcdefgh", SID_A), word = "claude" },
		{ cli = "codex", line = "env JUMPR_ID=abcdefgh codex", word = "codex" },
	}
	for _, case in cases do
		local d = deck()
		local session = if case.cli == "claude" then SID_A else nil
		d.agents.abcdefgh = record(3, { state = "pending", cli = case.cli, session = session })
		local list, m = list_on(d)
		local c, cx = open(list, 101)
		check(spawn_line(list, m, 21, case.line) == nil, "the first " .. case.cli .. " start runs as it is")
		local instead = spawn_line(list, m, 22, case.line)
		check(instead ~= nil, "a second " .. case.cli .. " start of the same agent is replaced")
		local said = if instead ~= nil then table.concat(instead.args, " ") else ""
		check(
			string.find(said, "agent abcdefgh already runs in pane 21", 1, true) ~= nil
				and string.find(said, case.word, 1, true) == nil,
			"the replacement names the running pane and starts no " .. case.cli .. ": " .. said
		)
		m.panes[22] = nil
		list.pane_exited({ pane = 22, status = 0 })
		list.tick()
		local r = stored(m).agents.abcdefgh
		check(r.state == "live" and r.pane == 21, "only the first " .. case.cli .. " pane binds")
		check(
			list.frame(c, cx).ui.notice == "agent abcdefgh already runs in pane 21: a second start was stopped",
			"the list says a second " .. case.cli .. " start was stopped"
		)
	end
end

-- An agent whose pane exited is not running: restarting it spawns omp as it is.
do
	local d = deck()
	d.agents["agent-c"] = record(3, { state = "pending" })
	local list, m = list_on(d)
	open(list, 101)
	local spec = function(pane: number): any
		return {
			program = "omp",
			args = { "--continue", "--session-dir", "~/.omp/deck/agent-c" },
			env = { TERN_PANE = tostring(pane) },
		}
	end
	m.panes[21] = true
	list.spawn(spec(21))
	list.tick()
	list.pane_exited({ pane = 21, status = 1 })
	check(stored(m).agents["agent-c"].state == "exited", "the agent exited")
	m.panes[23] = true
	check(list.spawn(spec(23)) == nil, "the restart is not stopped by the exited pane")
	list.tick()
	local r = stored(m).agents["agent-c"]
	check(r.state == "live" and r.pane == 23, "the restart binds")
end

-- A pane started by hand with a live agent's session folder (here after a plugin reload, so the running pane is known
-- only from the stored record) is stopped the same way; a session folder Jumpr does not list is left alone.
do
	local list, m = list_on(deck())
	open(list, 101)
	list.tick()
	m.panes[30] = true
	local instead = list.spawn({
		program = "omp",
		args = { "--continue", "--session-dir", "~/.omp/deck/agent-a" },
		env = { TERN_PANE = "30" },
	})
	check(instead ~= nil, "a second omp for a live agent started by hand is stopped")
	m.panes[31] = true
	check(list.spawn({
		program = "omp",
		args = { "--continue", "--session-dir", "~/.omp/deck/zzzzzzzz" },
		env = { TERN_PANE = "31" },
	}) == nil, "an omp session the list does not hold is left alone")
end

-- A click on a count tile is its filter key: it sets that filter, a second click on the active tile clears it, a click
-- on another tile switches to it, and a tile with nobody in it still filters (nothing matches). Every copy follows,
-- as it follows keys; with the search line open a click changes nothing.
do
	local list, m = list_on(deck())
	local c1, cx1 = open(list, 101)
	local c2, cx2 = open(list, 102)
	list.event(c1, status_action(m, "win1", 1, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx1)
	local function tile(code: string)
		list.event(c1, { ev = "action", act = View.CLICK, id = "main.tiles." .. code } :: any, cx1)
	end
	local function agent_ids(f: any): string
		local ids: { string } = {}
		for _, row in f.rows do
			if row.kind == "agent" and row.id ~= nil then
				table.insert(ids, row.id)
			end
		end
		return table.concat(ids, ",")
	end
	tile("idle")
	local f = list.frame(c1, cx1)
	check(
		f.ui.filter == "idle" and agent_ids(f) == "agent-a",
		"a click on the idle tile filters to idle: " .. agent_ids(f)
	)
	check(list.frame(c2, cx2).ui.filter == "idle", "every copy follows the click")
	tile("idle")
	check(list.frame(c1, cx1).ui.filter == nil, "a second click on the active tile clears the filter")
	tile("running")
	tile("error")
	f = list.frame(c1, cx1)
	check(f.ui.filter == "error", "a click on another tile switches the filter")
	check(agent_ids(f) == "", "a tile with nobody in it still filters: nothing matches")
	press(list, c1, cx1, "@")
	check(list.frame(c1, cx1).ui.filter == "waiting", "the key and the tile set the same filter")
	tile("waiting")
	check(list.frame(c1, cx1).ui.filter == nil, "and a click on the tile the key turned on clears it")
	press(list, c1, cx1, "/")
	tile("idle")
	f = list.frame(c1, cx1)
	check(f.ui.mode == "input" and f.ui.filter == nil, "with the search line open a click changes nothing")
end

-- Combined filters. An alt (Option) click on a tile (Tern lists `alt` in the event's `mods`) adds that status to the
-- filter and drops it again; dropping the last clears the filter; a plain click after that sets one filter; `1 2 3 4`
-- do what an alt+click does, and mix with clicks; `! @ # $` still set one filter. Every active tile is outlined, the
-- head line names every status in the filter, and a combined filter nobody matches still says nothing matches.
do
	local list, m = list_on(deck())
	local c, cx = open(list, 101)
	list.event(
		c,
		status_action(m, "win1", 1, {
			["agent-a"] = { { s = "q", src = "agents" } },
			["agent-b"] = { { s = "w", src = "agents" } },
		}),
		cx
	)
	local function tile(code: string, alt: boolean?)
		local ev: any = { ev = "action", act = View.CLICK, id = "main.tiles." .. code }
		if alt then
			ev.mods = { "alt" }
		end
		list.event(c, ev, cx)
	end
	local function shown(): string
		local ids: { string } = {}
		for _, row in list.frame(c, cx).rows do
			if row.kind == "agent" and row.id ~= nil then
				table.insert(ids, row.id)
			end
		end
		return table.concat(ids, ",")
	end
	local function filter(): string?
		return list.frame(c, cx).ui.filter
	end
	local function outlined(): string
		local f = list.frame(c, cx)
		local on: { string } = {}
		for _, t in View.tile_parts(f.tally, f.ui.filter) do
			if t.on then
				table.insert(on, t.code)
			end
		end
		return table.concat(on, ",")
	end
	tile("waiting")
	check(filter() == "waiting" and shown() == "agent-a", "a plain click sets one filter")
	tile("running", true)
	check(filter() == "waiting,running", "alt+click adds running: " .. tostring(filter()))
	check(shown() == "agent-a,agent-b", "the list shows waiting and running agents together: " .. shown())
	check(outlined() == "waiting,running", "both tiles are outlined: " .. outlined())
	local head = table.concat(View.head_parts(list.frame(c, cx)), " · ")
	check(string.find(head, "filter @ waiting + # running", 1, true) ~= nil, "the head names both: " .. head)
	tile("waiting", true)
	check(filter() == "running" and shown() == "agent-b", "alt+click on an active tile drops it")
	tile("running", true)
	check(filter() == nil and shown() == "agent-a,agent-b", "dropping the last one clears the filter")
	tile("error", true)
	tile("idle", true)
	check(filter() == "error,idle" and shown() == "", "a combined filter nobody matches shows nothing")
	check(View.empty_text(list.frame(c, cx)) == "nothing matches", "and says nothing matches")
	check(outlined() == "error,idle", "and outlines both tiles")
	tile("running")
	check(filter() == "running" and shown() == "agent-b", "a plain click after a combined filter sets one filter")
	press(list, c, cx, "2")
	check(filter() == "waiting,running", "2 adds waiting, as an alt+click does")
	tile("waiting", true)
	check(filter() == "running", "an alt+click drops what the key added")
	press(list, c, cx, "3")
	check(filter() == nil, "3 drops the last one and clears the filter")
	press(list, c, cx, "1")
	press(list, c, cx, "1")
	check(filter() == nil, "1 twice turns error on and off again")
	press(list, c, cx, "1")
	press(list, c, cx, "2")
	press(list, c, cx, "@")
	check(filter() == "waiting", "@ over a combined filter sets waiting alone")
	press(list, c, cx, "/")
	press(list, c, cx, "3")
	local f = list.frame(c, cx)
	check(f.ui.mode == "input" and f.ui.filter == "waiting", "in the search line a digit is typed, not a filter")
end

-- The pids whose environment grep was asked about, in order, comma-joined.
local function pids_probed(m: Fake.Machine): string
	local out: { string } = {}
	for _, argv in m.probes do
		table.insert(out, string.match(argv[6] or "", "^/proc/(%d+)/environ$") or "?")
	end
	return table.concat(out, ",")
end

-- A claude agent from before claude ran as its CLI (its record holds no conversation id, its pane runs the ACP chat)
-- is still looked up. The chat's `claude` carries the agent's id under the ACP adapter (node) and `tern acp`, which
-- carry it too, and no other `claude` is above it, so within two ticks the record holds its conversation. Enter
-- after the pane exits resumes it in Claude Code.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id))
	plant(m, "42", SID_A, "/work", false)
	proc(m, SHELL_PID, "fish", "1", false)
	proc(m, "8", "tern", SHELL_PID, true)
	proc(m, "9", "node-MainThread", "8", true)
	proc(m, "42", "claude", "9", true)
	local c, cx, b = open(list, 101)
	spawn_claude(list, m, 21, id)
	list.tick()
	list.tick()
	check(stored(m).agents[id].session == SID_A, "within two ticks the record holds the proven session")
	check(pids_probed(m) == "42,9,8,7", "the claude, then each ancestor up to the pane shell: " .. pids_probed(m))
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	local fields = restart_fields(list, c, cx, b, m)
	check(fields ~= nil and fields.mode == "resume" and fields.sid == SID_A, "Enter after exit requests mode=resume")
	check(
		fields ~= nil and Agent.command(fields.cli, id, "resume", fields.sid) == claude_line(id, SID_A),
		"which runs Claude Code on that conversation"
	)
end

-- The same lookup runs while no list copy is open, and Enter after that still asks to resume.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id))
	plant(m, "42", SID_A, "/work", true)
	spawn_claude(list, m, 21, id)
	list.tick()
	list.tick()
	check(stored(m).agents[id].session == SID_A, "a hidden list still stores the proven session")
	local c, cx, b = open(list, 101)
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	local fields = restart_fields(list, c, cx, b, m)
	check(
		fields ~= nil and fields.mode == "resume" and fields.sid == SID_A,
		"Enter after a hidden lookup still requests mode=resume"
	)
end

-- A claude agent from `n` starts on the conversation id drawn for it: the pane running that line binds it, and Enter
-- after it exits runs the very same line, so whether or not the conversation ever had a message it comes back to it.
do
	local d = deck()
	d.settings.agent = "claude"
	local list, m = list_on(d)
	m.dirs["/work"] = true
	local c, cx, b = open(list, 101)
	press(list, c, cx, "n")
	local start = requests(b, "start")[1]
	local sid = start.fields.sid
	check(sid == "00000000-0000-4000-8000-000000000000", "the start carries the id drawn for it: " .. tostring(sid))
	check(stored(m).agents.aaaaaaaa.session == sid, "and the record holds it")
	local line = Agent.command(start.fields.cli, start.fields.id, start.fields.mode :: Agent.Mode, sid)
	check(line == claude_line("aaaaaaaa", sid), "the window runs Claude Code on it: " .. tostring(line))
	spawn_line(list, m, 21, line :: string)
	list.tick()
	check(stored(m).agents.aaaaaaaa.state == "live", "the pane running that line binds the agent")
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	local fields = restart_fields(list, c, cx, b, m)
	check(fields ~= nil and fields.mode == "resume" and fields.sid == sid, "Enter after exit resumes that id")
	check(
		fields ~= nil and Agent.command(fields.cli, fields.id, "resume", fields.sid) == line,
		"with the very same line"
	)
end

-- A proven claude is followed: its session file is read again every 3 s, with no grep and no listing, so `/clear`
-- (which gives the live claude a new conversation id) moves the stored id, and Enter after the pane exits resumes the
-- new conversation. This agent resumed its conversation, and the line's `sh` exec'd `claude` for that too, so its
-- `claude` is the pane shell's direct child.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id, { session = SID_A }))
	plant(m, "31", SID_A, "/work", true)
	local c, cx, b = open(list, 101)
	spawn_line(list, m, 21, claude_line(id, SID_A))
	list.tick()
	check(stored(m).agents[id].state == "live", "the agent binds")
	check(pids_probed(m) == "31,7", "a claude the line's sh exec'd is the pane's own: " .. pids_probed(m))
	check(stored(m).agents[id].session == SID_A, "and its conversation is the stored one")
	local probes, lists = #m.probes, #m.lists
	m.files[HOME .. "/.claude/sessions/31.json"] = m.json({ sessionId = SID_B, cwd = "/work" })
	m.advance(2999)
	list.tick()
	check(stored(m).agents[id].session == SID_A, "the file is not read again before 3 s")
	m.advance(1)
	list.tick()
	check(stored(m).agents[id].session == SID_B, "after /clear the stored id follows the live one")
	check(#m.probes == probes and #m.lists == lists, "following reads that one file: no grep, no listing")
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	local fields = restart_fields(list, c, cx, b, m)
	check(
		fields ~= nil and fields.mode == "resume" and fields.sid == SID_B,
		"Enter resumes the conversation /clear began"
	)
end

-- A followed claude that is gone sends its agent back to the lookup, which proves the claude now running for it: here
-- the agent's line ran again at the shell prompt a retyped line leaves its pane at, so the pane stayed bound.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id, { session = SID_A }))
	plant(m, "31", SID_A, "/work", true)
	spawn_line(list, m, 21, claude_line(id, SID_A))
	list.tick()
	check(stored(m).agents[id].session == SID_A and #m.lists == 1, "the first claude is proven")
	m.files[HOME .. "/.claude/sessions/31.json"] = nil
	m.files["/proc/31/stat"] = nil
	m.files["/proc/31/comm"] = nil
	m.grep["31"] = nil
	plant(m, "32", SID_C, "/work", true)
	m.advance(3000)
	list.tick()
	check(stored(m).agents[id].session == SID_A and #m.lists == 1, "a gone claude changes nothing by itself")
	list.tick()
	check(#m.lists == 2, "the agent is looked up again on the next tick")
	check(stored(m).agents[id].session == SID_C, "and the claude now running for it gives the stored id")
end

-- A claude the agent ran itself (its Bash tool running `claude`) carries the agent's id too, but the agent's own
-- claude is above it, so it never gives its conversation and the stored id stays. The pane's own claude, once its
-- session file shows (after a /clear here), moves it, though the nested claude's file is probed first.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id, { session = SID_A }))
	m.home = HOME
	proc(m, SHELL_PID, "fish", "1", false)
	proc(m, "31", "claude", SHELL_PID, true)
	proc(m, "40", "bash", "31", true)
	proc(m, "120", "claude", "40", true)
	m.files[HOME .. "/.claude/sessions/120.json"] = m.json({ sessionId = SID_C, cwd = "/work" })
	spawn_line(list, m, 21, claude_line(id, SID_A))
	list.tick()
	check(pids_probed(m) == "120,40,31", "its ancestors are asked up to the agent's own claude: " .. pids_probed(m))
	check(stored(m).agents[id].session == SID_A, "a nested claude never replaces the stored id")
	m.files[HOME .. "/.claude/sessions/31.json"] = m.json({ sessionId = SID_B, cwd = "/work" })
	m.advance(3000)
	list.tick()
	check(pids_probed(m) == "120,40,31,120,40,31,31,7", "the nested one is refused again: " .. pids_probed(m))
	check(stored(m).agents[id].session == SID_B, "and the pane's own claude moves the stored id")
end

-- The record's own session is not treated as taken, so a re-proof of it still greps.
do
	local d = claude_deck("abcdefgh", { state = "live", pane = 21, session = SID_A, ran = true })
	d.agents.bbbbbbbb = record(2, { cli = "claude", state = "live", pane = 22, session = SID_B, ran = true })
	local list, m = list_on(d)
	m.panes[21] = true
	m.panes[22] = true
	plant(m, "42", SID_A, "/work", true)
	list.tick()
	check(pids_probed(m) == "42,7", "the file that holds its own session is probed, then its parent")
	check(stored(m).agents.abcdefgh.session == SID_A, "a matching proof leaves the stored session")
end

-- Two live claude agents: one lookup per tick, then the other on the next tick.
do
	local d = claude_deck("abcdefgh")
	d.agents.bbbbbbbb = record(2, { cli = "claude", state = "pending" })
	local list, m = list_on(d)
	plant(m, "11", SID_A, "/work", true)
	plant(m, "22", SID_B, "/work", true)
	spawn_claude(list, m, 21, "abcdefgh")
	spawn_claude(list, m, 22, "bbbbbbbb")
	list.tick()
	local first = 0
	if stored(m).agents.abcdefgh.session ~= nil then
		first += 1
	end
	if stored(m).agents.bbbbbbbb.session ~= nil then
		first += 1
	end
	check(#m.lists == 1 and first == 1, "one lookup runs per tick")
	list.tick()
	check(
		#m.lists == 2 and stored(m).agents.abcdefgh.session ~= nil and stored(m).agents.bbbbbbbb.session ~= nil,
		"the other agent is looked up on the next tick"
	)
	check(stored(m).agents.abcdefgh.session ~= stored(m).agents.bbbbbbbb.session, "neither takes the other's")
end

-- No session file: tries wait 3 s and stop after ten. A claude agent with no conversation id never continues the
-- folder's newest one (it may be another agent's), so Enter opens the picker, though the real exit stamped it.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id))
	m.home = HOME
	local c, cx, b = open(list, 101)
	spawn_claude(list, m, 21, id)
	list.tick()
	m.advance(2999)
	list.tick()
	check(#m.lists == 1, "a lookup waits 3 s")
	m.advance(1)
	list.tick()
	check(#m.lists == 2, "a lookup runs again at 3 s")
	for _ = 3, 10 do
		m.advance(3000)
		list.tick()
	end
	check(#m.lists == 10, "ten misses are tried")
	m.advance(3000)
	list.tick()
	check(#m.lists == 10, "it stops after ten misses")
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	local fields = restart_fields(list, c, cx, b, m)
	check(fields ~= nil and fields.mode == "pick" and fields.sid == nil, "Enter after a missed lookup opens the picker")
	check(stored(m).closed[Store.closed_key("claude", "/work")] == id, "a real pane exit stamps closed")
end

-- Codex threads live in rollout files under the sessions folder, filed by date.
local CODEX_SESSIONS = HOME .. "/.codex/sessions"
local DAY_MS = 24 * 60 * 60 * 1000

-- A Codex thread id: a UUID v7 for a thread that started at `ms`, told apart by `n`.
local function thread_id(ms: number, n: number): string
	local hex = string.format("%012x", ms)
	return string.format("%s-%s-7%03x-8000-000000000000", string.sub(hex, 1, 8), string.sub(hex, 9, 12), n)
end

-- Plants the rollout of thread `id`, which started at `ms` in folder `cwd`, under its UTC date: line 1 as Codex writes
-- it, cut short. Returns its path.
local function plant_thread(m: Fake.Machine, id: string, ms: number, cwd: string): string
	local seconds = ms // 1000
	local stamp = os.date("!%Y-%m-%dT%H:%M:%S", seconds) .. string.format(".%03dZ", ms % 1000)
	local name = "rollout-" .. os.date("!%Y-%m-%dT%H-%M-%S", seconds) .. "-" .. id .. ".jsonl"
	local path = CODEX_SESSIONS .. "/" .. os.date("!%Y/%m/%d", seconds) .. "/" .. name
	m.files[path] = '{"timestamp":"'
		.. stamp
		.. '","type":"session_meta","payload":{"id":"'
		.. id
		.. '","timestamp":"'
		.. stamp
		.. '","cwd":"'
		.. cwd
		.. '","base_instructions":{"text":"You are Codex."}}}'
	return path
end

-- Answers codex reader `n` (the n-th output) as its script would here: each rollout it names with that file's line 1,
-- or, for the picker's search (its first argument the sessions folder), each rollout in `written`, which maps a path to
-- its modification time in epoch seconds.
local function answer_reader(m: Fake.Machine, n: number, written: { [string]: number }?)
	local run = m.outputs[n]
	local out = ""
	if run.argv[5] == CODEX_SESSIONS then
		local times: { [string]: number } = written or {}
		local paths: { string } = {}
		for path in times do
			table.insert(paths, path)
		end
		table.sort(paths)
		for _, path in paths do
			out ..= "\030" .. string.format("%d", times[path]) .. " " .. path .. "\n" .. (m.files[path] or "")
		end
	else
		for i = 6, #run.argv do
			out ..= "\030- " .. run.argv[i] .. "\n" .. (m.files[run.argv[i]] or "")
		end
	end
	run.answer(out)
end

-- The line the window runs to start codex agent `id` in `mode`.
local function codex_line(id: string, mode: Agent.Mode, sid: string?): string
	return Agent.command("codex", id, mode, sid) :: string
end

-- A codex agent started new runs `codex`, and its thread's rollout appears at its first prompt. Each lookup lists the
-- date folders its start can be filed under until the rollout is there; then that rollout's line 1 (a thread started in
-- the window, in the agent's folder) proves the thread. The record holds it from then on and is not looked up again,
-- and Enter after the pane exits resumes it.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id, { cli = "codex" }))
	m.home = HOME
	local c, cx, b = open(list, 101)
	spawn_line(list, m, 21, codex_line(id, "new"))
	list.tick()
	check(stored(m).agents[id].state == "live", "the codex agent binds")
	check(
		table.concat(m.lists, ",") == CODEX_SESSIONS .. "/2027/01/14," .. CODEX_SESSIONS .. "/2027/01/15",
		"its lookup lists the date folders its start can be filed under: " .. table.concat(m.lists, ",")
	)
	check(#m.outputs == 0, "with no rollout there yet nothing is read")
	local tid = thread_id(Fake.wall(0) + 5000, 1)
	local path = plant_thread(m, tid, Fake.wall(0) + 5000, "/work")
	m.advance(3000)
	list.tick()
	check(#m.outputs == 1 and m.outputs[1].argv[6] == path, "the next lookup reads the new rollout's line 1")
	answer_reader(m, 1)
	check(stored(m).agents[id].session == tid, "which proves the thread, and the record holds it")
	local lists = #m.lists
	m.advance(3000)
	list.tick()
	m.advance(30000)
	list.tick()
	check(#m.lists == lists and #m.outputs == 1, "a codex agent that holds its thread is not looked up again")
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	local fields = restart_fields(list, c, cx, b, m)
	check(fields ~= nil and fields.mode == "resume" and fields.sid == tid, "Enter after the pane exits resumes it")
	check(
		fields ~= nil and codex_line(id, "resume", fields.sid) == "env JUMPR_ID=" .. id .. " codex resume " .. tid,
		"with codex resume on that thread"
	)
end

-- A codex agent with no thread that ran before restarts in Codex's resume picker. The thread picked there can be any
-- age, so its lookup is one search of the whole sessions folder for the folder's rollouts written since the restart,
-- and the one written proves the picked thread.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id, { cli = "codex", state = "exited", ran = true }))
	m.home = HOME
	local c, cx, b = open(list, 101)
	m.advance(60000)
	local fields = restart_fields(list, c, cx, b, m)
	check(fields ~= nil and fields.mode == "pick" and fields.sid == nil, "it restarts in the picker")
	local restarted = stored(m).agents[id].created_ms
	spawn_line(list, m, 21, codex_line(id, "pick"))
	list.tick()
	check(
		#m.lists == 0 and #m.outputs == 1 and m.outputs[1].argv[5] == CODEX_SESSIONS,
		"its lookup is one search of the sessions folder"
	)
	local tid = thread_id(Fake.wall(0) - 20 * DAY_MS, 1)
	local path = plant_thread(m, tid, Fake.wall(0) - 20 * DAY_MS, "/work")
	answer_reader(m, 1, { [path] = restarted // 1000 + 30 })
	check(
		stored(m).agents[id].session == tid,
		"the folder's rollout written since the restart proves the picked thread"
	)
end

-- A codex agent's rollout appears only at its first prompt, which can come at any time: after ten tries 3 s apart its
-- lookup goes on every 30 s for as long as it holds no thread, and proves the thread once it is there.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id, { cli = "codex" }))
	m.home = HOME
	spawn_line(list, m, 21, codex_line(id, "new"))
	list.tick()
	for _ = 2, 10 do
		m.advance(3000)
		list.tick()
	end
	check(#m.lists == 20, "ten tries 3 s apart, each listing two date folders: " .. #m.lists)
	m.advance(29999)
	list.tick()
	check(#m.lists == 20, "then none for 30 s")
	m.advance(1)
	list.tick()
	check(#m.lists == 22, "then one every 30 s")
	local tid = thread_id(Fake.wall(0) + 5000, 1)
	plant_thread(m, tid, Fake.wall(0) + 5000, "/work")
	m.advance(30000)
	list.tick()
	check(#m.outputs == 1, "a rollout that appeared later is read")
	answer_reader(m, 1)
	check(stored(m).agents[id].session == tid, "and proves the thread")
end

-- Two codex agents started together in one folder: the one thread there started in both their windows, so it may be
-- either agent's and is proven for neither (each restarts through the picker).
do
	local d = claude_deck("abcdefgh", { cli = "codex" })
	d.agents.bcdefghi = record(2, { cli = "codex", state = "pending" })
	local list, m = list_on(d)
	m.home = HOME
	plant_thread(m, thread_id(Fake.wall(0) + 5000, 1), Fake.wall(0) + 5000, "/work")
	spawn_line(list, m, 21, codex_line("abcdefgh", "new"))
	spawn_line(list, m, 22, codex_line("bcdefghi", "new"))
	list.tick()
	list.tick()
	check(#m.outputs == 2, "each agent's lookup reads the rollout, one per tick")
	answer_reader(m, 1)
	answer_reader(m, 2)
	check(
		stored(m).agents.abcdefgh.session == nil and stored(m).agents.bcdefghi.session == nil,
		"the thread is proven for neither"
	)
end

-- A codex agent that holds its thread is never looked up: no folder is listed and nothing is read or probed.
do
	local d = claude_deck("abcdefgh", { cli = "codex", state = "live", pane = 21, ran = true, session = SID_C })
	local list, m = list_on(d)
	m.home = HOME
	m.panes[21] = true
	list.tick()
	m.advance(3000)
	list.tick()
	check(#m.lists == 0 and #m.outputs == 0 and #m.probes == 0, "a codex agent holding its thread is not looked up")
end

-- After a Tern daemon restart the restored pane retypes the agent's line at a login shell: no spawn names the agent
-- (Tern's agent block has no command then), and the typed line alone binds it, Claude Code's `sh -c` line included.
do
	local lines: { [string]: string } = {
		claude = claude_line("abcdefgh", SID_A),
		codex = "env JUMPR_ID=abcdefgh codex resume 019a7d6e-2f3b-7c41-9d2e-5b6a7c8d9e0f",
	}
	for cli, typed_line in lines do
		local d = claude_deck("abcdefgh", { cli = cli, state = "live", pane = 21, ran = true })
		local list, m = list_on(d)
		local c, cx = open(list, 101)
		m.panes[23] = true
		list.command_started({ pane = 23, line = typed_line })
		list.tick()
		local r = stored(m).agents.abcdefgh
		check(r.state == "live" and r.pane == 23, "the retyped " .. cli .. " line binds the agent to its pane")
		local row: any = nil
		for _, each in list.frame(c, cx).rows do
			if each.id == "abcdefgh" then
				row = each
			end
		end
		check(row ~= nil and row.live and not row.dup, "its row is live and no duplicate")
	end
end

-- A reconcile marks the record exited without a stamp, so Enter asks for the picker.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id))
	m.home = HOME
	local c, cx, b = open(list, 101)
	spawn_claude(list, m, 21, id)
	list.tick()
	m.panes[21] = nil
	list.tick()
	check(stored(m).agents[id].state == "live", "a pane missing from one listing does not end the agent")
	m.advance(Bind.MISSING_GRACE_MS)
	list.tick()
	check(stored(m).agents[id].state == "exited", "a pane missing past the grace is marked exited")
	check(stored(m).closed[Store.closed_key("claude", "/work")] == nil, "a reconcile does not stamp closed")
	local fields = restart_fields(list, c, cx, b, m)
	check(fields ~= nil and fields.mode == "pick" and fields.sid == nil, "Enter after a reconcile requests pick")
end

-- Leaving a duplicate's other pane does not stamp. The last pane does.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id))
	spawn_claude(list, m, 21, id)
	list.tick()
	m.panes[22] = true
	list.command_started({ pane = 22, line = "env JUMPR_ID=" .. id .. " tern acp claude" })
	list.tick()
	m.panes[22] = nil
	list.pane_exited({ pane = 22, status = 0 })
	check(stored(m).agents[id].state == "live", "one pane left keeps the record live")
	check(stored(m).closed[Store.closed_key("claude", "/work")] == nil, "moving a duplicate does not stamp closed")
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	check(stored(m).closed[Store.closed_key("claude", "/work")] == id, "the last pane exiting stamps closed")
end

-- An omp pane exit marks the record exited and does not stamp closed.
do
	local list, m = list_on(deck())
	m.panes[11] = nil
	list.pane_exited({ pane = 11, status = 0 })
	check(stored(m).agents["agent-a"].state == "exited", "an omp pane exit marks the record exited")
	check(stored(m).closed[Store.closed_key("omp", "/work")] == nil, "an omp exit does not stamp closed")
end

-- An omp agent never starts a session lookup, even when a session file is planted. Its vibe poll reads home and
-- lists its own deck folder, and nothing else: no probe, no listing under the Claude sessions.
do
	local list, m = list_on(deck())
	plant(m, "42", SID_A, "/work", true)
	open(list, 101)
	list.tick()
	m.advance(3000)
	list.tick()
	local omp_lists = 0
	for _, path in m.lists do
		if string.find(path, "/.omp/deck/", 1, true) ~= nil then
			omp_lists += 1
		end
	end
	check(
		#m.probes == 0 and omp_lists == #m.lists and #m.lists > 0,
		"an omp agent never triggers a lookup, only its own vibe poll"
	)
end

-- An agent's last usable pane title is remembered on its record and saved once: a turned spinner frame or a title that
-- is not usable (a chat's default name) saves nothing and leaves it. The row keeps showing it after the pane exits
-- and after a restart whose chat shows only its default name, until the chat names itself again, and the restart
-- does not name the tab with it.
do
	local id = "abcdefgh"
	local list, m = list_on(claude_deck(id))
	local titles: { [number]: string } = {}
	local listed = m.compat.pane_list
	m.compat.pane_list = function(): ({ Compat.PaneItem }?, string?)
		local panes, err = listed()
		if panes ~= nil then
			for _, p in panes do
				p.title = titles[p.pane] or p.title
			end
		end
		return panes, err
	end
	local c, cx, b = open(list, 101)
	local function record_of(): Store.Record
		return stored(m).agents[id]
	end
	local function label(): string?
		for _, row in list.frame(c, cx).rows do
			if row.id == id then
				return row.label
			end
		end
		return nil
	end
	titles[21] = "Claude Code"
	spawn_claude(list, m, 21, id)
	list.tick()
	check(record_of().state == "live" and record_of().title == nil, "a chat's default name is not remembered")
	check(label() == "claude 1", "the row shows the default label")
	local writes = m.kv_writes
	titles[21] = "⠋ Fix the parser"
	list.tick()
	check(record_of().title == "Fix the parser", "a usable title is remembered without its spinner frame")
	check(m.kv_writes == writes + 1, "and saved once: " .. tostring(m.kv_writes - writes))
	titles[21] = "⠙ Fix the parser"
	list.tick()
	check(m.kv_writes == writes + 1, "a turned spinner frame saves nothing")
	titles[21] = "Claude Code"
	list.tick()
	check(m.kv_writes == writes + 1 and record_of().title == "Fix the parser", "a default name saves nothing")
	check(label() == "Fix the parser", "the row shows the remembered title while its pane shows none")
	m.panes[21] = nil
	list.pane_exited({ pane = 21, status = 0 })
	check(record_of().state == "exited" and label() == "Fix the parser", "an exited row shows it")
	local fields = restart_fields(list, c, cx, b, m)
	check(fields ~= nil and fields.label == "", "the restart does not name the tab with it")
	titles[22] = "Claude Code"
	spawn_claude(list, m, 22, id)
	list.tick()
	check(record_of().state == "live", "the restarted chat binds")
	check(label() == "Fix the parser", "its row keeps the remembered title while the chat shows its default name")
	titles[22] = "Parser tests"
	list.tick()
	check(record_of().title == "Parser tests" and label() == "Parser tests", "until the chat names itself again")
end

-- Vibe mode: while a copy is open the list reads each live omp agent's own session file for its workers' turns.
local VIBE_FILE = "2027-01-15T07-00-00-000Z_s1.jsonl"

-- Plants omp agent `id`'s session file, so a poll has a file to read.
local function plant_omp(m: Fake.Machine, id: string)
	m.home = HOME
	m.files[HOME .. "/.omp/deck/" .. id .. "/" .. VIBE_FILE] = ""
end

-- One vibe lifecycle line as omp writes it, for worker `worker`, stamped `stamp` (UTC; fake time 0 is
-- 2027-01-15T08:00:00.000Z).
local function lifecycle(m: Fake.Machine, worker: string, action: string, stamp: string): string
	return m.json({
		type = "custom",
		customType = "vibe-session-lifecycle",
		data = { version = 1, id = worker, ownerId = "Main", action = action, turn = 1 },
		timestamp = stamp,
	})
end

-- Answers poll `n` as its shell does for one file: the header (the mark, the file it chose, the mark again, its
-- size), then the lines.
local function answer(m: Fake.Machine, n: number, size: number, lines: { string })
	local out = "\030" .. HOME .. "/.omp/deck/agent-a/" .. VIBE_FILE .. "\030" .. tostring(size) .. "\n"
	for _, line in lines do
		out ..= line .. "\n"
	end
	m.outputs[n].answer(out)
end

local function row_of(f: View.Frame, id: string): any
	for _, row in f.rows do
		if row.id == id then
			return row
		end
	end
	return nil
end

-- A worker turn that started makes the idle agent's row running and vibing, and the tally counts it as running; the
-- answer re-renders the copy. Polls are 5 s apart, each reads on from where the last stopped, and the turn settling
-- returns the row to idle.
do
	local list, m = list_on(deck())
	plant_omp(m, "agent-a")
	local c, cx, b = open(list, 101)
	local seq = 0
	local function report()
		seq += 1
		list.event(c, status_action(m, "win1", seq, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx)
	end
	report()
	list.tick()
	check(#m.outputs == 1, "a tick with a copy open starts one poll")
	local argv = m.outputs[1].argv
	check(
		#argv == 7
			and argv[1] == "sh"
			and argv[5] == "0"
			and argv[6] == "-"
			and argv[7] == HOME .. "/.omp/deck/agent-a/" .. VIBE_FILE,
		"the poll reads the agent's session file from its start: " .. table.concat(argv, " ")
	)
	check(row_of(list.frame(c, cx), "agent-a").code == "idle", "before the answer the row is idle")
	local renders = b.renders
	answer(m, 1, 120, { lifecycle(m, "W1", "turn-started", "2027-01-15T07:59:59.000Z") })
	check(b.renders == renders + 1, "a changed answer renders the copy")
	local f = list.frame(c, cx)
	local row = row_of(f, "agent-a")
	check(row.code == "running" and row.vibing == true, "a running worker turn makes the idle row running and vibing")
	check((f.tally.running or 0) == 1 and (f.tally.idle or 0) == 0, "the tally counts the vibing agent as running")
	m.advance(4999)
	report()
	list.tick()
	check(#m.outputs == 1, "no poll starts within 5 s of the last")
	m.advance(1)
	report()
	list.tick()
	check(#m.outputs == 2 and m.outputs[2].argv[5] == "120", "a poll 5 s later reads on from the last size")
	answer(m, 2, 200, { lifecycle(m, "W1", "turn-settled", "2027-01-15T08:00:04.000Z") })
	f = list.frame(c, cx)
	row = row_of(f, "agent-a")
	check(row.code == "idle" and row.vibing == nil, "a settled turn returns the row to idle")
	check((f.tally.running or 0) == 0 and f.tally.idle == 1, "and the tally counts it idle again")
end

-- No poll starts while no copy is open; the first tick with one open polls.
do
	local list, m = list_on(deck())
	plant_omp(m, "agent-a")
	list.tick()
	m.advance(5000)
	list.tick()
	check(#m.outputs == 0, "no poll starts with no copy open")
	open(list, 101)
	list.tick()
	check(#m.outputs == 1, "a tick after a copy opens polls")
end

-- A live ACP agent has no omp session file and is never polled.
do
	local list, m = list_on(claude_deck("abcdefgh", { state = "live", pane = 21, ran = true }))
	m.panes[21] = true
	plant_omp(m, "abcdefgh")
	open(list, 101)
	list.tick()
	m.advance(5000)
	list.tick()
	local omp_lists = 0
	for _, path in m.lists do
		if string.find(path, "/.omp/", 1, true) ~= nil then
			omp_lists += 1
		end
	end
	check(#m.outputs == 0 and omp_lists == 0, "a live ACP agent is never polled")
end

-- A new process for the agent (it binds again) ends what its last process left running: the row stops vibing at
-- once, a turn stamped before the bind is ignored, and one stamped after it counts.
do
	local list, m = list_on(deck())
	plant_omp(m, "agent-a")
	m.advance(20000)
	local c, cx, b = open(list, 101)
	local seq = 0
	local function report()
		seq += 1
		list.event(c, status_action(m, "win1", seq, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx)
	end
	report()
	list.tick()
	answer(m, 1, 120, { lifecycle(m, "W1", "turn-started", "2027-01-15T08:00:10.000Z") })
	check(row_of(list.frame(c, cx), "agent-a").vibing == true, "with no bind seen the file's history is trusted")
	local renders = b.renders
	list.command_started({ pane = 11, line = "omp --continue --session-dir ~/.omp/deck/agent-a" })
	list.tick()
	check(b.renders > renders, "the bind renders the copy")
	local row = row_of(list.frame(c, cx), "agent-a")
	check(row.code == "idle" and row.vibing == nil, "the bind ends the last process's worker turns")
	m.advance(5000)
	report()
	list.tick()
	check(#m.outputs == 2, "the next poll starts")
	answer(m, 2, 200, { lifecycle(m, "W2", "turn-started", "2027-01-15T08:00:19.000Z") })
	row = row_of(list.frame(c, cx), "agent-a")
	check(row.code == "idle" and row.vibing == nil, "a turn stamped before the bind is ignored")
	m.advance(5000)
	report()
	list.tick()
	check(#m.outputs == 3, "a third poll starts")
	answer(m, 3, 280, { lifecycle(m, "W3", "turn-started", "2027-01-15T08:00:21.000Z") })
	row = row_of(list.frame(c, cx), "agent-a")
	check(row.code == "running" and row.vibing == true, "a turn stamped after the bind counts")
end

-- A changed vibe answer renders every open copy, and a list that opens again starts from a fresh answer: with no
-- copy open the follower is cleared, so no pill the closed lists never saw survives.
do
	local list, m = list_on(deck())
	plant_omp(m, "agent-a")
	local c1, cx1, b1 = open(list, 101)
	local c2, cx2, b2 = open(list, 102)
	local seq = 0
	local function report()
		seq += 1
		list.event(c1, status_action(m, "win1", seq, { ["agent-a"] = { { s = "i", src = "agents" } } }), cx1)
	end
	report()
	list.tick()
	local r1, r2 = b1.renders, b2.renders
	answer(m, 1, 120, { lifecycle(m, "W1", "turn-started", "2027-01-15T08:00:10.000Z") })
	check(b1.renders > r1 and b2.renders > r2, "a changed answer renders every open copy")
	check(row_of(list.frame(c2, cx2), "agent-a").vibing == true, "the second copy shows the vibing row")
	-- Both copies close (their panes leave the list): after the grace ticks the follower is cleared, and a copy
	-- that opens again sees no stale pill.
	m.panes[101] = nil
	m.panes[102] = nil
	list.tick()
	list.tick()
	list.tick()
	local c3, cx3, b3 = open(list, 103)
	check(row_of(list.frame(c3, cx3), "agent-a").vibing == nil, "a reopened list shows no stale vibing pill")
	m.advance(5000)
	list.tick()
	check(#m.outputs == 2, "the reopened list polls again")
	answer(m, 2, 140, { lifecycle(m, "W1", "turn-settled", "2027-01-15T08:00:30.000Z") })
	check(b3.renders == 1, "an answer that changes nothing after a clear renders nothing")
end

-- The spool: a script's request files in the plugin's data folder (`/data` on the fake machine), served by the host
-- timer with or without a copy of the list open.
local BRIEF = "/abs/brief.md"

-- Machine devbox, deck session `deck`, no groups yet.
local function spool_deck(): Store.Deck
	local d = Store.empty()
	d.session = { name = "deck", host = "devbox" }
	return d
end

-- The home, the agent's folder and the brief the requests name.
local function spool_ready(m: Fake.Machine)
	m.home = HOME
	m.dirs["/srv/jobs"] = true
	m.files[BRIEF] = "Reply with just the word ready, then stop.\n"
end

-- A request as the script writes it, stamped now; `body` replaces the lines after `ts` (default: group jobs created
-- in /srv/jobs, the brief).
local function request_text(m: Fake.Machine, body: { string }?, ts: number?): string
	local lines = body or { "group=jobs", "cwd=/srv/jobs", "prompt_file=" .. BRIEF }
	local stamp = string.format("%d", ts or Fake.wall(m.now))
	return "v=1\nts=" .. stamp .. "\n" .. table.concat(lines, "\n") .. "\nend\n"
end

local function request_path(name: string): string
	return "/data/requests/" .. name .. ".req"
end

local function drop_request(m: Fake.Machine, name: string, text: string)
	m.files[request_path(name)] = text
end

-- The reply to request `rid`: its single fields and its argv lines in order; nil when there is none.
local function reply_of(m: Fake.Machine, rid: string): ({ [string]: string }?, { string })
	local text = m.files["/data/replies/" .. rid .. ".reply"]
	local argv: { string } = {}
	if text == nil then
		return nil, argv
	end
	local fields: { [string]: string } = {}
	for _, line in string.split(text, "\n") do
		local key, value = string.match(line, "^([^=]*)=(.*)$")
		if key == "argv" and value ~= nil then
			table.insert(argv, value)
		elseif key ~= nil and value ~= nil then
			fields[key] = value
		end
	end
	check(string.sub(text, -4) == "end\n", "a reply ends with its end line")
	return fields, argv
end

-- The error a refused request's reply carries; nil when it has no reply or was not refused.
local function refusal(m: Fake.Machine, rid: string): string?
	local fields = reply_of(m, rid)
	if fields == nil or fields.ok ~= "0" then
		return nil
	end
	return fields.error
end

-- Headless cold start: no copy of the list is open and the deck has no groups. The request is removed, the new group
-- and a pending record are saved, and the reply carries the start line; the tab the script then opens binds the
-- record through the spawn hook (the line Tern 0.9.29's spawn filter showed for `tern new tab … -- omp …`).
do
	local list, m = list_on(spool_deck())
	spool_ready(m)
	drop_request(
		m,
		"rq000001",
		request_text(m, { "group=jobs", "cwd=/srv/jobs", "prompt_file=" .. BRIEF, "label=nightly" })
	)
	list.tick()
	check(m.files[request_path("rq000001")] == nil, "the request file is removed")
	local d = stored(m)
	check(
		#d.groups == 1 and d.groups[1].name == "jobs" and d.groups[1].cwd == "/srv/jobs",
		"a missing group is created in the request's folder"
	)
	local fields, argv = reply_of(m, "rq000001")
	check(fields ~= nil and fields.ok == "1", "the reply says ok")
	local f = fields :: { [string]: string }
	local id = f.id
	local r = d.agents[id]
	check(r ~= nil and r.state == "pending" and r.cli == "omp", "a pending omp record is saved")
	check(r.gid == f.gid and r.gid == d.groups[1].gid and r.pos == 1, "in the new group, first")
	check(r.cwd == "/srv/jobs" and r.label == "nightly", "with the request's folder and label")
	check(
		f.session == "deck" and f.cwd == "/srv/jobs" and f.label == "nightly" and f.error == nil,
		"the reply names the deck session, the folder and the label"
	)
	check(
		table.concat(argv, "|") == "omp|--session-dir|/home/dev/.omp/deck/" .. id .. "|@" .. BRIEF,
		"the reply's argv starts omp in the agent's deck folder with the brief: " .. table.concat(argv, "|")
	)
	check(table.find(m.dir_checks, "/srv/jobs") ~= nil, "the agent's folder is still checked")
	check(
		table.find(m.dir_checks, request_path("rq000001")) == nil,
		"a served request file is not listed as a directory"
	)
	check(table.find(m.dir_checks, BRIEF) == nil, "the brief is not listed as a directory")
	check(next(m.spool_lists) ~= nil and #m.lists == 0, "the spool's listings are counted apart")
	spawn_line(list, m, 21, "omp --session-dir /home/dev/.omp/deck/" .. id .. " @/abs/brief.md")
	list.tick()
	local bound = stored(m).agents[id]
	check(bound.state == "live" and bound.pane == 21, "the tab the script opened binds the record live")
end

-- Two requests in one tick, into a group that exists: distinct ids, positions after the group's last agent, each
-- served in name order.
do
	local d = spool_deck()
	table.insert(d.groups, { gid = "g1", name = "jobs", cwd = "/srv/jobs", folded = false })
	d.agents["agent-a"] = record(1, { cwd = "/srv/jobs" })
	local m = Fake.machine(d)
	local n = 0
	local list = Runtime.new(m.compat, function(k: number): number
		n += 1
		return (n % k) + 1
	end)
	spool_ready(m)
	drop_request(m, "rq-b", request_text(m, { "group=jobs", "prompt_file=" .. BRIEF }))
	drop_request(m, "rq-a", request_text(m, { "group=jobs", "prompt_file=" .. BRIEF }))
	list.tick()
	local a = reply_of(m, "rq-a")
	local b = reply_of(m, "rq-b")
	check(a ~= nil and a.ok == "1" and b ~= nil and b.ok == "1", "both requests are served in one tick")
	local fa, fb = a :: { [string]: string }, b :: { [string]: string }
	check(fa.id ~= fb.id and fa.gid == "g1" and fb.gid == "g1", "distinct ids, in the existing group")
	local saved = stored(m)
	check(saved.agents[fa.id].pos == 2 and saved.agents[fb.id].pos == 3, "positions follow the group's last agent")
	check(#saved.groups == 1 and saved.agents["agent-a"].pos == 1, "no group is added and the other agent stays")
end

-- Requests that are refused before anything is stored: a bad file name is removed with no reply (and logged), and an
-- invalid, stale, unreadable or oversized request gets an error reply. At most four are served a tick; the bad name,
-- never served, does not count.
do
	local list, m = list_on(spool_deck())
	spool_ready(m)
	local before = stored(m)
	drop_request(m, "bad.name", request_text(m))
	drop_request(m, "rq-invalid", request_text(m, { "group=jobs", "prompt_file=" .. BRIEF, "colour=red" }))
	drop_request(m, "rq-stale", request_text(m, nil, Fake.wall(m.now) - 61 * 1000))
	drop_request(m, "rq-unread", request_text(m))
	m.read_errors[request_path("rq-unread")] = "Permission denied (os error 13)"
	drop_request(m, "rq-xbig", string.rep("x", Spool.MAX_BYTES + 10))
	-- One byte over the limit is still read (the read allows one more), so the parser names the limit.
	drop_request(m, "rq-zbig", string.rep("x", Spool.MAX_BYTES + 1))
	list.tick()
	local left = 0
	for path in m.files do
		if string.sub(path, 1, 15) == "/data/requests/" then
			left += 1
		end
	end
	check(left == 1 and m.files[request_path("rq-zbig")] ~= nil, "four requests are served a tick, the fifth waits")
	list.tick()
	check(m.files[request_path("rq-zbig")] == nil, "the fifth is served on the next tick")
	check(m.files["/data/replies/bad.name.reply"] == nil, "a bad request name gets no reply")
	check(m.files[request_path("bad.name")] == nil, "and is removed")
	local logged = false
	for _, line in m.logs do
		if string.find(line, "bad name: bad.name.req", 1, true) ~= nil then
			logged = true
		end
	end
	check(logged, "and logged")
	check(
		refusal(m, "rq-invalid") == "unknown key colour",
		"an invalid request is refused: " .. tostring(refusal(m, "rq-invalid"))
	)
	check(refusal(m, "rq-stale") == "request is more than 60 s old", "a stale request is refused")
	check(
		refusal(m, "rq-unread") == "request could not be read: Permission denied (os error 13)",
		"an unreadable request is refused: " .. tostring(refusal(m, "rq-unread"))
	)
	check(
		refusal(m, "rq-xbig") == "request could not be read: file is larger than " .. (Spool.MAX_BYTES + 1) .. " bytes",
		"a request past what the read allows is refused unread: " .. tostring(refusal(m, "rq-xbig"))
	)
	check(
		refusal(m, "rq-zbig") == "request is larger than " .. Spool.MAX_BYTES .. " bytes",
		"a request one byte over is refused by its size: " .. tostring(refusal(m, "rq-zbig"))
	)
	check(stored(m) == before and m.kv_writes == 0, "nothing is stored")
end

-- A request whose file cannot be removed is not acted on: nothing is stored and no reply is written. It is served
-- on the first tick that removes it.
do
	local list, m = list_on(spool_deck())
	spool_ready(m)
	drop_request(m, "rq000001", request_text(m))
	m.remove_fails = true
	list.tick()
	check(m.files[request_path("rq000001")] ~= nil, "the request stays")
	check(reply_of(m, "rq000001") == nil and m.kv_writes == 0, "nothing is stored or answered")
	m.remove_fails = false
	list.tick()
	local fields = reply_of(m, "rq000001")
	check(fields ~= nil and fields.ok == "1", "the next tick serves it")
	check(m.files[request_path("rq000001")] == nil, "once it is removed")
	local count = 0
	for _ in stored(m).agents do
		count += 1
	end
	check(count == 1, "and starts one agent")
end

-- A reply that cannot be rendered (a control byte in the deck's session name) refuses the request before the deck is
-- committed: no group, no record, no kv write, so no pending record waits for a tab no script will open.
do
	local d = spool_deck()
	d.session.name = "de\tck"
	local list, m = list_on(d)
	spool_ready(m)
	local before = stored(m)
	drop_request(m, "rq000001", request_text(m))
	list.tick()
	local why = refusal(m, "rq000001")
	check(
		why == "the reply could not be rendered: spool reply value for session holds a control character",
		"an unrenderable reply refuses the request: " .. tostring(why)
	)
	check(stored(m) == before and m.kv_writes == 0, "nothing is stored")
	check(m.files[request_path("rq000001")] == nil, "and the request is used up")
end

-- Four requests whose files cannot be removed do not hold back a fifth: only requests served count against the four
-- a tick.
do
	local list, m = list_on(spool_deck())
	spool_ready(m)
	for i = 1, 4 do
		local name = "rq-stuck" .. i
		drop_request(m, name, request_text(m))
		m.remove_errors[request_path(name)] = "Permission denied (os error 13)"
	end
	drop_request(m, "rq-takes", request_text(m))
	list.tick()
	local fields = reply_of(m, "rq-takes")
	check(fields ~= nil and fields.ok == "1", "the fifth request is served in the same tick")
	for i = 1, 4 do
		local name = "rq-stuck" .. i
		check(m.files[request_path(name)] ~= nil and reply_of(m, name) == nil, name .. " stays, unanswered")
	end
	local count = 0
	for _ in stored(m).agents do
		count += 1
	end
	check(count == 1, "and only the fifth starts an agent")
end

-- A folder named like a spool file is never removed, as a request or by the hourly sweep, and is logged once while
-- it stays; a request with a bad name that cannot be removed is logged once too, not every tick.
do
	local hour = 60 * 60 * 1000
	local list, m = list_on(spool_deck())
	spool_ready(m)
	local folders = {
		"/data/requests/x.req",
		"/data/requests/bad.dir.req",
		"/data/requests/x.tmp",
		"/data/replies/x.reply",
		"/data/replies/x.tmp",
	}
	for _, path in folders do
		m.dirs[path] = true
	end
	drop_request(m, "bad.name", request_text(m))
	m.remove_errors[request_path("bad.name")] = "Permission denied (os error 13)"
	for _ = 1, 3 do
		m.advance(hour)
		list.tick()
	end
	check(#m.removed == 0, "nothing is removed: " .. table.concat(m.removed, " "))
	for _, path in folders do
		check(m.dirs[path] == true, "the folder " .. path .. " stays")
	end
	local function logged(text: string): number
		local n = 0
		for _, line in m.logs do
			if string.find(line, text, 1, true) ~= nil then
				n += 1
			end
		end
		return n
	end
	check(logged("left alone: x.req") == 1, "a folder named as a request is logged once")
	check(logged("left alone: bad.dir.req") == 1, "so is one with a bad name")
	check(logged("not removed: bad.name.req") == 1, "a bad name that cannot be removed is logged once")
end

-- `tern.fs.remove` is recursive: a folder that read as empty text (were Tern ever to read a directory) is still
-- checked and left, never removed, and logged once; an empty plain file is refused and removed as before.
do
	local list, m = list_on(spool_deck())
	spool_ready(m)
	local folder = request_path("rq-dirtext")
	m.files[folder] = ""
	m.dirs[folder] = true
	drop_request(m, "rq-empty", "")
	list.tick()
	list.tick()
	check(m.dirs[folder] == true and m.files[folder] ~= nil, "a folder read as text stays")
	check(table.find(m.removed, folder) == nil, "and is never removed")
	check(reply_of(m, "rq-dirtext") == nil, "nor answered")
	local n = 0
	for _, line in m.logs do
		if string.find(line, "left alone: rq-dirtext.req", 1, true) ~= nil then
			n += 1
		end
	end
	check(n == 1, "and is logged once")
	check(m.files[request_path("rq-empty")] == nil, "an empty plain file is still removed")
	local fields = reply_of(m, "rq-empty")
	check(fields ~= nil and fields.ok ~= "1", "and refused")
end

-- A deck that cannot take the agent refuses the request with a reply and changes nothing: a read-only deck, a deck
-- no copy of the list has named yet, a missing brief.
do
	local ro = spool_deck()
	ro.schema = Store.SCHEMA + 1
	local cases: { { name: string, deck: Store.Deck, setup: ((Fake.Machine) -> ())?, want: string } } = {
		{ name = "a read-only deck", deck = ro, want = "the Jumpr list on devbox is read-only" },
		{
			name = "a deck with no session name",
			deck = Store.empty(),
			want = "open the Jumpr list on this machine once, then retry",
		},
		{
			name = "a missing brief",
			deck = spool_deck(),
			setup = function(m: Fake.Machine)
				m.files[BRIEF] = nil
			end,
			want = "prompt file not found on devbox: " .. BRIEF,
		},
	}
	for _, case in cases do
		local list, m = list_on(case.deck)
		spool_ready(m)
		if case.setup ~= nil then
			case.setup(m)
		end
		local before = stored(m)
		drop_request(m, "rq000001", request_text(m))
		list.tick()
		check(refusal(m, "rq000001") == case.want, case.name .. " is refused: " .. tostring(refusal(m, "rq000001")))
		check(stored(m) == before and m.kv_writes == 0, case.name .. " stores nothing")
	end
end

-- kv refusing the save: the request is refused, the deck in memory goes back to what kv holds, and no agent is
-- started; the next request after kv recovers stores only its own agent.
do
	local list, m = list_on(spool_deck())
	spool_ready(m)
	local before = stored(m)
	m.kv_fails = true
	drop_request(m, "rq000001", request_text(m))
	list.tick()
	local why = refusal(m, "rq000001")
	check(
		why ~= nil and string.find(why, "not saved on devbox", 1, true) ~= nil,
		"an unsaved deck refuses the request: " .. tostring(why)
	)
	check(stored(m) == before, "kv is unchanged")
	m.kv_fails = false
	drop_request(
		m,
		"rq000002",
		request_text(m, { "group=other", "cwd=/srv/jobs", "prompt_file=" .. BRIEF, "label=second" })
	)
	list.tick()
	local fields = reply_of(m, "rq000002")
	check(fields ~= nil and fields.ok == "1", "the next request is served")
	local saved = stored(m)
	local count = 0
	for _, r in saved.agents do
		count += 1
		check(r.label == "second", "only the second request's agent is stored")
	end
	check(count == 1 and #saved.groups == 1 and saved.groups[1].name == "other", "the refused group was rolled back")
end

-- A spool step that raises is kept in the error ring: the rest of the tick still runs and renders the open copy.
do
	local d = deck()
	d.agents["agent-c"] = record(3, { state = "pending", created_ms = Fake.wall(0) - 31 * 1000 })
	local list, m = list_on(d)
	local _c, _cx, b = open(list, 101)
	local fs_list = m.compat.fs_list
	m.compat.fs_list = function(path: string): ({ string }?, string?)
		if path == "/data/requests" then
			error("spool exploded")
		end
		return fs_list(path)
	end
	local renders = b.renders
	list.tick()
	check(stored(m).agents["agent-c"].failed == true, "the start that never got a pane still fails")
	check(b.renders > renders, "and the copy is rendered")
	for _, line in m.logs do
		check(string.find(line, "timer:", 1, true) == nil, "the tick did not abort: " .. line)
	end
end

-- A quiet tick, with no request (a half-written one does not count), writes, removes and runs nothing.
do
	local list, m = list_on(deck())
	m.files["/data/requests/rq000001.tmp"] = "v=1\n"
	list.tick()
	list.tick()
	check(#m.file_writes == 0 and #m.removed == 0 and m.kv_writes == 0, "a quiet tick writes and removes nothing")
	check(#m.probes == 0 and #m.outputs == 0, "and runs no process")
	check(#m.spool_lists == 2 and m.spool_lists[1] == "/data/requests", "one listing of the requests a tick")
	check(m.files["/data/requests/rq000001.tmp"] ~= nil, "a half-written request is left alone")
end

-- The hourly sweep removes leftover replies and half-written files only once two sweeps in a row have seen them;
-- anything else in the folders is never touched.
do
	local hour = 60 * 60 * 1000
	local list, m = list_on(deck())
	m.files["/data/replies/old.reply"] = "ok=1\nend\n"
	m.files["/data/replies/old.tmp"] = "ok="
	m.files["/data/requests/old.tmp"] = "v=1\n"
	m.files["/data/replies/notes.txt"] = "mine"
	m.advance(hour)
	list.tick()
	check(#m.removed == 0, "the first sweep that sees a file keeps it")
	m.files["/data/replies/new.reply"] = "ok=1\nend\n"
	m.advance(hour - 1)
	list.tick()
	check(#m.removed == 0, "nothing is swept between the hourly passes")
	m.advance(1)
	list.tick()
	check(
		m.files["/data/replies/old.reply"] == nil
			and m.files["/data/replies/old.tmp"] == nil
			and m.files["/data/requests/old.tmp"] == nil,
		"the next sweep removes what the last one saw"
	)
	check(m.files["/data/replies/new.reply"] ~= nil, "a file the last sweep did not see stays")
	check(m.files["/data/replies/notes.txt"] ~= nil, "a file of another kind is never removed")
	m.advance(hour)
	list.tick()
	check(m.files["/data/replies/new.reply"] == nil, "and goes one sweep later")
end

-- A pane that leaves the pane list for a moment (a plugin reload while the daemon takes its panes over) and comes
-- back within the grace keeps its agent live and bound.
do
	local list, m = list_on(deck())
	open(list, 101)
	m.panes[11] = nil
	list.tick()
	m.panes[11] = true
	m.advance(Bind.MISSING_GRACE_MS)
	list.tick()
	local r = stored(m).agents["agent-a"]
	check(r.state == "live" and r.pane == 11, "a pane back within the grace keeps its agent live and bound")
end

-- The grace clock starts again after a gap with no reconcile (the list was closed): a pane missed once, long ago,
-- does not end its agent the moment it is missed again.
do
	local list, m = list_on(deck())
	open(list, 101)
	m.panes[11] = nil
	list.tick()
	m.advance(2 * Bind.MISSING_GRACE_MS)
	list.tick()
	check(stored(m).agents["agent-a"].state == "live", "a miss after a long gap starts a new grace")
	m.advance(Bind.MISSING_GRACE_MS)
	list.tick()
	check(stored(m).agents["agent-a"].state == "exited", "and ends the agent once that grace runs out")
end

-- An agent ended while its pane still runs (the window still reports it): Enter links it back to the one unbound
-- pane with its remembered title and jumps there, and starts no second process. With no such single pane, Enter
-- still jumps (the window finds its own pane) and starts nothing, and the list says it is not linked.
do
	local Keys = require("../lib/host/keys")
	local TITLE = "Add agy to Jumpr agents"
	-- `exits`: agent-a starts live on pane 11 and that pane's program exits before the window's (stale) report.
	local function ended_but_running(
		titles: { [number]: string },
		exits: boolean?
	): (Fake.Machine, View.Frame, Fake.Block)
		local d = deck()
		d.agents["agent-a"] = if exits
			then record(1, { pane = 11, title = TITLE, ran = true })
			else record(1, { state = "exited", ended_ms = Fake.wall(0), title = TITLE, ran = true })
		local list, m = list_on(d)
		m.panes[13] = true
		local listed = m.compat.pane_list
		m.compat.pane_list = function(): ({ Compat.PaneItem }?, string?)
			local panes, err = listed()
			if panes ~= nil then
				for _, p in panes do
					p.title = titles[p.pane] or p.title
				end
			end
			return panes, err
		end
		local c, cx, b = open(list, 101)
		if exits then
			list.pane_exited({ pane = 11, status = 0 })
		end
		local entries = { ["agent-a"] = { { s = "w", src = "agents" } }, ["agent-b"] = { { s = "i", src = "agents" } } }
		list.event(c, status_action(m, "win1", 1, entries), cx)
		check(row_of(list.frame(c, cx), "agent-a").runs == true, "an ended agent the window reports running runs")
		m.dirs["/work"] = true
		press(list, c, cx, "j")
		press(list, c, cx, "enter")
		return m, list.frame(c, cx), b
	end

	local m, f, b = ended_but_running({ [11] = TITLE, [13] = "Other" })
	local r = stored(m).agents["agent-a"]
	check(#requests(b, "start") == 0, "Enter starts no second process")
	check(r.state == "live" and r.pane == 11, "it links the agent back to the pane with its title")
	local jumps = requests(b, "jump")
	check(#jumps == 1 and jumps[1].fields.id == "agent-a", "and jumps to it")
	check(f.ui.notice == Keys.RELINKED, "the list says it is linked again: " .. tostring(f.ui.notice))
	check(row_of(f, "agent-a").runs == nil and row_of(f, "agent-a").live, "its row is live again")

	local misses: { [string]: { [number]: string } } = {
		["no pane has its title"] = { [11] = "Other" },
		["two panes have it"] = { [11] = TITLE, [13] = TITLE },
	}
	for name, titles in misses do
		local m2, f2, b2 = ended_but_running(titles)
		check(#requests(b2, "start") == 0, name .. ": Enter starts no second process")
		check(stored(m2).agents["agent-a"].state == "exited", name .. ": the record stays ended")
		check(#requests(b2, "jump") == 1, name .. ": Enter still jumps")
		check(f2.ui.notice == Keys.RELINK_MISSED, name .. ": the list says it is not linked")
	end

	-- The pane whose program exited stays open with the title, but is never linked back to.
	local m3, f3, b3 = ended_but_running({ [11] = TITLE, [13] = "Other" }, true)
	check(#requests(b3, "start") == 0, "an exited pane: Enter starts no second process")
	check(stored(m3).agents["agent-a"].state == "exited", "an exited pane is never linked back to")
	check(f3.ui.notice == Keys.RELINK_MISSED, "an exited pane: the list says it is not linked")
end

print("Runtime: " .. checks .. " checks passed")
