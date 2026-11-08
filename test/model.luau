--!strict

local Model = require("../lib/host/model")
local Status = require("../lib/shared/status")
local Store = require("../lib/host/store")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local NOW = 1800000000000

local function group(deck: Store.Deck, gid: string, name: string, folded: boolean?)
	table.insert(deck.groups, { gid = gid, name = name, cwd = "/home/a/" .. name, folded = folded == true })
end

local function agent(deck: Store.Deck, id: string, gid: string, pos: number, fields: { [string]: any }?)
	local r: Store.Record = {
		gid = gid,
		pos = pos,
		dir = "~/.omp/deck/" .. id,
		cwd = "/home/a/" .. gid,
		created_ms = NOW - 1000,
		state = "live",
		pane = pos * 100,
	}
	for k, v in (fields or {}) :: { [string]: any } do
		(r :: any)[k] = v
	end
	-- `pane = nil` in a table constructor sets nothing: a pending or exited record has no pane.
	if r.state == "pending" or r.state == "exited" then
		r.pane = nil
	end
	deck.agents[id] = r
end

-- Two groups: "Webapp" (a: idle, b: waiting) and "notes" (c: working, d: exited 0).
local function sample(): (Store.Deck, Model.PaneSets, Model.StatusById)
	local deck = Store.empty()
	group(deck, "g1", "Webapp")
	group(deck, "g2", "notes")
	agent(deck, "a", "g1", 1, { label = "Auth Fix" })
	agent(deck, "b", "g1", 2)
	agent(deck, "c", "g2", 1, { cwd = "/srv/Website" })
	agent(deck, "d", "g2", 2, { state = "exited", exit = 0, pane = nil })
	local sets: Model.PaneSets = { a = { [100] = true }, b = { [200] = true }, c = { [100 + 1] = true } }
	deck.agents.c.pane = 101
	local st: Model.StatusById = {
		a = { { s = "i", src = "agents" } },
		b = { { s = "q", src = "agents" } },
		c = { { s = "w", src = "agents" } },
	}
	return deck, sets, st
end

local PANES: { Model.Pane } = {
	{ pane = 100, title = "omp" },
	{ pane = 200, title = "⠋ refactor parser" },
	{ pane = 101, title = "" },
}

local function labels(rows: { Model.Row }): string
	local out = {}
	for _, row in rows do
		table.insert(out, (if row.kind == "header" then "#" else "") .. row.label)
	end
	return table.concat(out, ",")
end

local function find(rows: { Model.Row }, id: string): Model.Row
	for _, row in rows do
		if row.id == id then
			return row
		end
	end
	error("missing row " .. id)
end

local NONE: Model.View = {}

-- Rows: groups in array order, agents by pos; default labels from the cleaned pane title, else "omp <n>".
do
	local deck, sets, st = sample()
	local rows = Model.rows(deck, PANES, sets, st, NONE, "ok")
	check(labels(rows) == "#Webapp,Auth Fix,refactor parser,#notes,omp 1,omp 2", "rows and labels: " .. labels(rows))
	check(rows[1].depth == 0 and rows[2].depth == 1, "headers have depth 0, agents depth 1")
	local d = find(rows, "d")
	check(d.code == "stopped" and d.dim, "a stopped row is dimmed")
	check(not find(rows, "a").dim, "an idle row is not dimmed")
	check(find(rows, "a").live and not d.live, "live needs a live record with a bound pane")
	check(find(rows, "a").src == "agents", "an agent row carries its status source")
end

-- A folded group hides its agents.
do
	local deck, sets, st = sample()
	deck.groups[1].folded = true
	local rows = Model.rows(deck, PANES, sets, st, NONE, "ok")
	check(labels(rows) == "#Webapp,#notes,omp 1,omp 2", "a folded group shows only its header: " .. labels(rows))
	check(rows[1].folded == true and rows[1].count == 2, "the folded header keeps its count")
end

-- A filter shows matching agents inside a folded group without changing `folded`.
do
	local deck, sets, st = sample()
	deck.groups[1].folded = true
	local rows = Model.rows(deck, PANES, sets, st, { filter = "waiting" }, "ok")
	check(
		labels(rows) == "#Webapp,refactor parser",
		"the waiting filter shows b under its folded header: " .. labels(rows)
	)
	check(deck.groups[1].folded == true, "filtering does not unfold the group")
	local stopped = Model.rows(deck, PANES, sets, st, { filter = "idle" }, "ok")
	check(labels(stopped) == "#Webapp,Auth Fix", "the idle filter shows only idle, never a stopped row")
end

-- Each key's filter (`status.ORDER`) shows exactly the agents in its status, one agent per status here.
do
	local deck, sets, st = sample()
	st.c = { { s = "w", e = "boom", src = "agents" } }
	agent(deck, "e", "g2", 3)
	sets.e = { [300] = true }
	st.e = { { s = "w", src = "agents" } }
	local panes = table.clone(PANES)
	table.insert(panes, { pane = 300, title = "omp" })
	for _, ranked in Status.ORDER do
		local shown: { string } = {}
		for _, row in Model.rows(deck, panes, sets, st, { filter = ranked.code }, "ok") do
			if row.kind == "agent" then
				check(row.code == ranked.code, ranked.key .. " shows only " .. ranked.code .. " agents")
				table.insert(shown, row.id :: string)
			end
		end
		check(#shown == 1, ranked.key .. " (" .. ranked.code .. ") shows its one agent: " .. table.concat(shown, ","))
	end
end

-- Search is a case-insensitive substring match on label, cwd and group name.
do
	local deck, sets, st = sample()
	check(labels(Model.rows(deck, PANES, sets, st, { search = "auth" }, "ok")) == "#Webapp,Auth Fix", "search by label")
	check(labels(Model.rows(deck, PANES, sets, st, { search = "WEBSITE" }, "ok")) == "#notes,omp 1", "search by cwd")
	check(
		labels(Model.rows(deck, PANES, sets, st, { search = "weba" }, "ok")) == "#Webapp,Auth Fix,refactor parser",
		"search by group name shows the whole group"
	)
	check(#Model.rows(deck, PANES, sets, st, { search = "zzz" }, "ok") == 0, "no match shows nothing")
	deck.groups[2].folded = true
	check(
		labels(Model.rows(deck, PANES, sets, st, { search = "website" }, "ok")) == "#notes,omp 1",
		"search shows matches inside a folded group"
	)
end

-- A header shows its agent count and the worst code of its agents.
do
	local deck, sets, st = sample()
	local rows = Model.rows(deck, PANES, sets, st, NONE, "ok")
	check(rows[1].count == 2 and rows[1].code == "waiting", "Webapp: 2 agents, worst waiting")
	check(rows[4].count == 2 and rows[4].code == "running", "notes: 2 agents, worst running")
	st.a = { { s = "i", e = "boom" } }
	check(Model.rows(deck, PANES, sets, st, NONE, "ok")[1].code == "error", "an error outranks waiting in the header")
	local stale = Model.rows(deck, PANES, sets, st, NONE, "stale")
	check(find(stale, "a").code == "unknown" and stale[1].code == nil, "stale status gives unknown and no worst")
end

-- dup from two bound panes in the pane set, and from two status entries for one id.
do
	local deck, sets, st = sample()
	sets.a = { [100] = true, [300] = true }
	st.b = { { s = "q" }, { s = "w" } }
	local rows = Model.rows(deck, PANES, sets, st, NONE, "ok")
	check(find(rows, "a").dup, "two live panes in the set make a duplicate")
	check(find(rows, "b").dup, "two status entries make a duplicate")
	check(find(rows, "b").code == "waiting", "a duplicate shows the worst of its entries")
	check(not find(rows, "c").dup, "one pane and one entry is not a duplicate")
end

-- The selection stays on the same id after a reorder, and moves to the header when a fold hides it.
do
	local deck, sets, st = sample()
	local sel: Model.Selection = { kind = "agent", id = "b", gid = "g1" }
	deck.agents.b.pos = 0
	local rows = Model.rows(deck, PANES, sets, st, NONE, "ok")
	local kept = Model.clamp_selection(rows, sel, deck)
	check(kept ~= nil and kept.kind == "agent" and kept.id == "b", "the selection follows the id after a reorder")
	check(Model.index_of(rows, kept) == 2, "b is now the first agent row")
	deck.groups[1].folded = true
	local folded = Model.clamp_selection(Model.rows(deck, PANES, sets, st, NONE, "ok"), sel, deck)
	check(folded ~= nil and folded.kind == "header" and folded.gid == "g1", "a fold moves the selection to its header")
	local header = Model.clamp_selection(rows, { kind = "header", gid = "g2" }, deck)
	check(header ~= nil and header.gid == "g2", "a header selection stays on its group")
	check(Model.clamp_selection({}, sel, deck) == nil, "no rows gives no selection")
end

-- label_from_common_dir.
do
	check(Model.label_from_common_dir("/home/a/src/webapp/.git", "/home/a/src/webapp") == "webapp", "normal repo")
	check(
		Model.label_from_common_dir("/home/a/src/webapp/.git\n", "/home/a/wt/webapp-auth") == "webapp",
		"a worktree shares its repo's name"
	)
	check(Model.label_from_common_dir(nil, "/home/a/notes") == "notes", "not a repo gives the folder's name")
	check(Model.label_from_common_dir("", "/home/a/notes/") == "notes", "empty gives the folder's name")
	check(Model.label_from_common_dir("/src/webapp.git", "/src/wt/x") == "webapp", "a bare repo drops .git")
end

-- on_bind: a binding clears a pending start's failed mark; an exited record becomes live again.
do
	local pending: Store.Record = {
		gid = "g1",
		pos = 1,
		dir = "~/.omp/deck/p",
		cwd = "/home/a/g1",
		created_ms = NOW,
		state = "pending",
		failed = true,
		ended_ms = NOW,
	}
	local bound, verdict = Model.on_bind(pending, 42)
	check(verdict == "live" and bound.state == "live" and bound.pane == 42, "a pending record binds live")
	check(bound.failed == nil and bound.ended_ms == nil, "binding clears failed and ended")
	check(pending.state == "pending" and pending.failed == true, "on_bind leaves its input untouched")
	local exited: Store.Record = table.clone(pending)
	exited.state, exited.failed, exited.exit, exited.ended_ms = "exited", nil, 0, NOW - 5
	local again, v2 = Model.on_bind(exited, 43)
	check(v2 == "live" and again.state == "live" and again.ended_ms == nil, "an exited record binds live again")
end

-- start_failed acts only on pending records.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	agent(deck, "p", "g1", 1, { state = "pending", pane = nil })
	agent(deck, "l", "g1", 2)
	check(Model.start_failed(deck, "l", "res", NOW) == deck, "start_failed on a live record is a no-op")
	for _, reason in { "res", "no_reply", "no_pane" } do
		local out = Model.start_failed(deck, "p", reason, NOW)
		local r = out.agents.p
		check(r.failed == true and r.ended_ms == NOW, reason .. " marks a pending record failed")
		check(deck.agents.p.failed == nil, reason .. " leaves the input deck untouched")
	end
	check(Model.start_failed(deck, "missing", "res", NOW) == deck, "start_failed on an unknown id is a no-op")
end

-- reconcile_states marks a live record whose pane is gone as exited.
do
	local deck, _, _ = sample()
	local out = Model.reconcile_states(deck, { [200] = true, [101] = true }, NOW)
	check(out.agents.a.state == "exited" and out.agents.a.ended_ms == NOW, "a live record whose pane is gone exits")
	check(out.agents.b.state == "live" and out.agents.c.state == "live", "records with a listed pane stay live")
	check(deck.agents.a.state == "live", "reconcile leaves its input untouched")
	check(Model.reconcile_states(out, { [200] = true, [101] = true }, NOW) == out, "nothing gone returns the same deck")
end

-- on_exit: a stop sent in the last 60 s deletes, otherwise the record exits.
do
	local deck, _, _ = sample()
	check(Model.on_exit(deck.agents.a, NOW) == "exited", "no recent stop marks the record exited")
	deck.agents.a.stop_ms = NOW - 30 * 1000
	check(Model.on_exit(deck.agents.a, NOW) == "delete", "a stop within 60 s deletes, even when live again")
	deck.agents.a.stop_ms = NOW - 61 * 1000
	check(Model.on_exit(deck.agents.a, NOW) == "exited", "a stop over 60 s ago marks it exited")
end

-- sweep_groups removes deleting groups with no records left, and nothing else.
do
	local deck, _, _ = sample()
	group(deck, "g3", "empty")
	check(Model.sweep_groups(deck) == deck, "an empty group that is not deleting stays")
	deck.groups[3].deleting = true
	deck.groups[2].deleting = true
	local out = Model.sweep_groups(deck)
	check(#out.groups == 2 and out.groups[2].gid == "g2", "only the empty deleting group is removed")
end

-- apply_launch stores the launch names and warns when a new block opens in another session.
do
	local deck = Store.empty()
	local first, n1 = Model.apply_launch(deck, "main", "devbox", false, NOW)
	check(
		first ~= deck and first.session.name == "main" and first.session.host == "devbox",
		"first launch stores names"
	)
	check(first.session.set_ms == NOW and n1 == nil, "first launch stamps set_ms with no notice")
	check(deck.session.name == nil, "the input deck is untouched")
	local same, n2 = Model.apply_launch(first, "main", "devbox", false, NOW + 1)
	check(same == first and n2 == nil, "the same names change nothing")
	local kept, n3 = Model.apply_launch(first, nil, nil, false, NOW + 1)
	check(kept == first and n3 == nil, "missing args change nothing")
	local moved, n4 = Model.apply_launch(first, "other", nil, false, NOW + 2)
	check(moved.session.name == "other" and moved.session.host == "devbox", "a new session name is stored")
	check(n4 == "jumpr moved from session main", "a new block in another session warns")
	local restored, n5 = Model.apply_launch(first, "other", nil, true, NOW + 2)
	check(restored.session.name == "other" and n5 == nil, "a restored block updates the name silently")
	local rehosted, n6 = Model.apply_launch(first, nil, "devbox2", false, NOW + 3)
	check(rehosted.session.host == "devbox2" and rehosted.session.name == "main" and n6 == nil, "a host change alone")
end

-- hold: one case per reason, from the same inputs queue.due reads.
do
	local held: Store.QueueEntry = { text = "go", at_ms = NOW }
	check(Model.hold(nil, "ok", true, false) == nil, "nothing held gives no reason")
	check(Model.hold(held, "ok", true, false) == "waiting for idle", "live, fresh, not idle yet: waiting for idle")
	check(Model.hold(held, "stale", true, false) == "status stale", "stale status")
	check(Model.hold(held, "unavailable", true, false) == "status unavailable", "no status yet")
	check(Model.hold(held, "ok", true, true) == "duplicate", "a duplicate")
	check(Model.hold(held, "ok", false, false) == "pane gone", "no live pane")
	local failed: Store.QueueEntry = { text = "go", at_ms = NOW, err = "boom" }
	check(Model.hold(failed, "ok", true, false) == "failed: boom", "a failed send names its error")
	check(Model.hold(failed, "stale", false, true) == "failed: boom", "the error comes before the other reasons")

	local deck, sets, st = sample()
	deck.queue.a = held
	deck.queue.b = held
	deck.queue.c = held
	deck.queue.d = failed
	sets.b = {}
	sets.c = { [101] = true, [102] = true }
	local rows = Model.rows(deck, PANES, sets, st, NONE, "ok")
	check(find(rows, "a").hold == "waiting for idle" and find(rows, "a").queued, "row a: waiting for idle")
	check(find(rows, "b").hold == "pane gone", "row b: its pane is gone")
	check(find(rows, "c").hold == "duplicate", "row c: two panes")
	check(find(rows, "d").hold == "failed: boom", "row d: failed")
	check(Model.rows(deck, PANES, sets, st, NONE, "stale")[2].hold == "status stale", "a stale health reaches the row")
	check(Model.rows(deck, PANES, sets, st, NONE, "unavailable")[2].hold == "status unavailable", "and unavailable")
	local plain, plain_sets, plain_st = sample()
	local plain_rows = Model.rows(plain, PANES, plain_sets, plain_st, NONE, "ok")
	check(find(plain_rows, "a").hold == nil and not find(plain_rows, "a").queued, "no hold unqueued")
end

-- asking: a status entry with s = "q" marks the row, whatever its status code.
do
	local deck, sets, st = sample()
	local rows = Model.rows(deck, PANES, sets, st, NONE, "ok")
	check(find(rows, "b").asking == true and find(rows, "a").asking == false, "only the waiting_input row is asking")
	check(find(rows, "c").asking == false, "a working row is not asking")
end

-- delete_group: stops live agents, cancels or drops pending ones, deletes exited ones and held messages.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	group(deck, "g2", "notes")
	agent(deck, "l1", "g1", 1)
	agent(deck, "l2", "g1", 2)
	agent(deck, "x", "g1", 3, { state = "exited", exit = 0, pane = nil, ended_ms = NOW - 5 })
	agent(deck, "n", "g2", 1)
	deck.queue.l1 = { text = "one", at_ms = NOW }
	deck.queue.x = { text = "two", at_ms = NOW }
	deck.queue.n = { text = "other group", at_ms = NOW }
	local out, stops = Model.delete_group(deck, "g1", NOW)
	check(#stops == 2 and stops[1] == "l1" and stops[2] == "l2", "two live agents give two stop ids, in order")
	check(out.agents.l1.state == "stopping" and out.agents.l1.stop_ms == NOW, "they become stopping with stop_ms")
	check(out.agents.x == nil, "the exited record is deleted")
	check(out.queue.l1 == nil and out.queue.x == nil, "and the group's held messages go")
	check(out.queue.n ~= nil and out.agents.n.state == "live", "another group is untouched")
	check(out.groups[1].gid == "g1" and out.groups[1].deleting == true, "the group is marked deleting")
	check(deck.groups[1].deleting == nil and deck.agents.x ~= nil, "the input deck is untouched")
	-- Both exit (pane_exited deletes a stopping record); sweep_groups then removes the group.
	local gone = Model.apply_exit(Model.apply_exit(out, "l1", 0, NOW + 1), "l2", 0, NOW + 1)
	check(gone.agents.l1 == nil and gone.agents.l2 == nil, "pane_exited deletes both stopping records")
	local swept = Model.sweep_groups(gone)
	check(#swept.groups == 1 and swept.groups[1].gid == "g2", "the group disappears after the second exit")
	check(#Model.sweep_groups(Model.apply_exit(out, "l1", 0, NOW + 1)).groups == 2, "not after only the first")

	local empty = Store.empty()
	group(empty, "g1", "webapp")
	local none, no_stops = Model.delete_group(empty, "g1", NOW)
	check(#none.groups == 0 and #no_stops == 0, "an empty group is removed at once")
	check(Model.delete_group(empty, "missing", NOW) == empty, "an unknown group changes nothing")
end

-- delete_group with a failed pending record: under 30 s old it is cancelled, over 30 s it is deleted.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	agent(deck, "young", "g1", 1, {
		state = "pending",
		pane = nil,
		failed = true,
		created_ms = NOW - 10000,
		ended_ms = NOW - 1,
	})
	local out, stops = Model.delete_group(deck, "g1", NOW)
	check(#stops == 0 and out.agents.young ~= nil and out.agents.young.cancel == true, "under 30 s old: marked cancel")
	check(out.groups[1].deleting == true, "the group waits for it")
	local aged = Store.empty()
	group(aged, "g1", "webapp")
	agent(aged, "old", "g1", 1, {
		state = "pending",
		pane = nil,
		failed = true,
		created_ms = NOW - 40000,
		ended_ms = NOW - 1,
	})
	local gone, none = Model.delete_group(aged, "g1", NOW)
	check(#none == 0 and gone.agents.old == nil and #gone.groups == 0, "over 30 s old: deleted, and the group with it")
	check(Model.drop_failed(deck.agents.young, NOW) == "cancel", "drop_failed: cancel under 30 s")
	check(Model.drop_failed(aged.agents.old, NOW) == "delete", "drop_failed: delete over 30 s")
	local bound = table.clone(aged.agents.old)
	bound.pane = 9
	check(Model.drop_failed(bound, NOW) == "cancel", "drop_failed: a record with a pane is cancelled, never deleted")
end

-- A pending agent in a deleted group is marked cancel; its bind then gives stop; an error res keeps it.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	agent(deck, "p", "g1", 1, { state = "pending", pane = nil })
	local out, stops = Model.delete_group(deck, "g1", NOW)
	check(#stops == 0 and out.agents.p.cancel == true and out.agents.p.state == "pending", "pending: marked cancel")
	local bound, verdict = Model.on_bind(out.agents.p, 42)
	check(verdict == "stop" and bound.state == "stopping" and bound.cancel == nil, "on_bind gives stop")
	-- An error res on a cancel record keeps it, and a later on_bind still gives stop.
	local kept = Model.start_failed(out, "p", "res", NOW + 1)
	check(kept.agents.p ~= nil and kept.agents.p.cancel == true and kept.agents.p.failed == true, "res keeps a cancel")
	local _, again = Model.on_bind(kept.agents.p, 43)
	check(again == "stop", "a later on_bind still gives stop")
	-- The 30 s no-pane path deletes a cancel record.
	local deleted = Model.start_failed(out, "p", "no_pane", NOW + 30000)
	check(deleted.agents.p == nil, "start_failed with no_pane deletes a cancel record")
	check(Model.start_failed(deck, "p", "no_pane", NOW).agents.p.failed == true, "and only marks any other pending one")
end

-- A deleting header with a live agent is stuck; a stopping record whose pane vanished is deleted and swept.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	agent(deck, "a", "g1", 1)
	agent(deck, "b", "g1", 2)
	local deleting, _ = Model.delete_group(deck, "g1", NOW)
	local sets: Model.PaneSets = { a = { [100] = true }, b = { [200] = true } }
	check(Model.rows(deleting, PANES, sets, {}, NONE, "ok")[1].stuck == false, "all stopping: not stuck")
	local back, notice = Model.stop_failed(deleting, "a")
	check(back.agents.a.state == "live" and back.agents.a.stop_ms == NOW, "stop_failed puts the record back to live")
	check(notice == "stop failed on this machine", "with its notice: " .. tostring(notice))
	check(deleting.agents.a.state == "stopping", "stop_failed leaves its input untouched")
	local rows = Model.rows(back, PANES, sets, {}, NONE, "ok")
	check(rows[1].deleting == true and rows[1].stuck == true, "the deleting header is now stuck")
	check(Model.stop_failed(back, "a") == back, "a live record is left alone")
	check(select(2, Model.stop_failed(deleting, "missing")) == nil, "an unknown id gives no notice")
	deleting.session.host = "devbox"
	check(select(2, Model.stop_failed(deleting, "a")) == "stop failed on devbox", "the notice names the host")
	-- Neither pane is listed any more and no pane_exited came: reconcile deletes both, the group is swept.
	local reconciled = Model.reconcile_states(deleting, {}, NOW + 5000)
	check(reconciled.agents.a == nil and reconciled.agents.b == nil, "stopping records with no pane are deleted")
	check(#Model.sweep_groups(reconciled).groups == 0, "and the deleting group is swept")
end

-- stop_agent and drop_record: the single-agent transitions behind d then y.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	agent(deck, "a", "g1", 1)
	agent(deck, "x", "g1", 2, { state = "exited", exit = 1, pane = nil, ended_ms = NOW - 5 })
	deck.queue.a = { text = "hold", at_ms = NOW }
	local stopped = Model.stop_agent(deck, "a", NOW)
	check(
		stopped.agents.a.state == "stopping" and stopped.agents.a.stop_ms == NOW and stopped.queue.a == nil,
		"stop_agent"
	)
	check(Model.stop_agent(stopped, "a", NOW) == stopped, "a record that is not live is left alone")
	check(Model.stop_agent(deck, "x", NOW) == deck, "an exited record is left alone")
	check(Model.drop_record(deck, "x", NOW).agents.x == nil, "drop_record deletes an exited record")
	check(Model.drop_record(deck, "a", NOW) == deck, "and leaves a live one")
	check(Model.on_exit(stopped.agents.a, NOW + 1000) == "delete", "a stopped record's pane_exited deletes it")
end

-- A cancel row reads as removing.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	agent(deck, "p", "g1", 1, { state = "pending", pane = nil, failed = true, cancel = true })
	local rows = Model.rows(deck, PANES, {}, {}, NONE, "ok")
	check(find(rows, "p").cancel == true and find(rows, "p").failed == true, "the row carries cancel")
end

-- stamp_stops: a stopping record with no stop_ms (a cancelled start that bound) is stamped once.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	agent(deck, "p", "g1", 1, { state = "pending", pane = nil, cancel = true })
	local bound = Model.on_bind(deck.agents.p, 42)
	deck.agents.p = bound
	agent(deck, "s", "g1", 2, { state = "stopping", stop_ms = NOW - 5 })
	agent(deck, "l", "g1", 3)
	local out, ids = Model.stamp_stops(deck, NOW)
	check(#ids == 1 and ids[1] == "p", "only the record with no stop_ms is asked for")
	check(out.agents.p.stop_ms == NOW and out.agents.s.stop_ms == NOW - 5, "it is stamped; the other keeps its stamp")
	check(deck.agents.p.stop_ms == nil, "the input deck is untouched")
	local again, none = Model.stamp_stops(out, NOW + 1000)
	check(again == out and #none == 0, "a second call finds nothing: never asked twice")
end

-- The count tiles (`tally`) count every agent by the code its row shows, folded groups included; each header's
-- `tally` sums to its agent count; a duplicate counts once.
do
	local deck, sets, st = sample()
	local open = Model.rows(deck, PANES, sets, st, {}, "ok")
	local want: { [string]: number } = {}
	for _, row in open do
		if row.kind == "agent" then
			local code = row.code :: string
			want[code] = (want[code] or 0) + 1
		end
	end
	deck.groups[2].folded = true
	local folded = Model.rows(deck, PANES, sets, st, {}, "ok")
	check(
		labels(folded) == "#Webapp,Auth Fix,refactor parser,#notes",
		"the folded group's agents are not rows: " .. labels(folded)
	)
	local got = Model.tally(deck, st, "ok")
	for code, n in want do
		check(got[code] == n, "the tiles count " .. code .. " as the rows do, folded or not")
	end
	for _, row in folded do
		if row.kind == "header" then
			local sum = 0
			for _, n in (row.tally or {}) :: { [string]: number } do
				sum += n
			end
			check(sum == row.count, "a header's tally sums to its agents: " .. row.label)
		end
	end
	st.a = { { s = "q", src = "agents" }, { s = "i", src = "tern" } }
	local dup = Model.tally(deck, st, "ok")
	local total = 0
	for _, n in dup do
		total += n
	end
	check(total == 4, "a duplicate counts once, so the tiles still total four agents")
	local stale = Model.tally(deck, st, "stale")
	check(stale.waiting == nil, "stale status counts nobody as waiting")
end

print("Model: " .. checks .. " checks passed")
