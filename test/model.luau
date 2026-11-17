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
		cli = "omp",
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

-- Rows: groups in array order, agents by pos; default labels use the agent kind and cleaned pane title.
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

	agent(deck, "e", "g2", 3, { cli = "copilot" })
	sets.e = { [300] = true }
	local panes = table.clone(PANES)
	table.insert(panes, { pane = 300, title = "GitHub Copilot" })
	local defaults = Model.rows(deck, panes, sets, st, NONE, "ok")
	check(find(defaults, "e").label == "copilot 3", "a default ACP title uses the CLI-aware fallback label")
	panes[4].title = "Fix the parser"
	local titled = Model.rows(deck, panes, sets, st, NONE, "ok")
	check(find(titled, "e").label == "Fix the parser", "an ACP agent uses its custom pane title")
end

-- A live agent's title is cleaned for its own kind: a codex title drops its ` | <folder>`, a bare folder name is
-- codex's default, and another agent's ` | ` stays.
do
	local deck, sets, st = sample()
	agent(deck, "e", "g2", 3, { cli = "codex" })
	agent(deck, "f", "g2", 4, { cli = "omp" })
	sets.e = { [300] = true }
	sets.f = { [400] = true }
	local panes = table.clone(PANES)
	table.insert(panes, { pane = 300, title = "⠼ Fix the bug | myrepo" })
	table.insert(panes, { pane = 400, title = "fix A | B" })
	local rows = Model.rows(deck, panes, sets, st, NONE, "ok")
	check(find(rows, "e").label == "Fix the bug", "a codex title drops its folder")
	check(find(rows, "f").label == "fix A | B", "an omp title keeps its ` | `")
	panes[4].title = "myrepo"
	check(
		find(Model.rows(deck, panes, sets, st, NONE, "ok"), "e").label == "codex 3",
		"a bare codex folder is a default"
	)
end

-- ready: the row's one entry, on fresh status, is an idle the agent reported itself (`Status.reported_idle`), its
-- finish seen or unseen. A pane that only reads not busy, any other state, stale status, no status and a duplicate's
-- two entries are not.
do
	local deck, sets, st = sample()
	local function ready(entries: { Status.Entry }, health: string?): boolean?
		st.a = entries
		return find(Model.rows(deck, PANES, sets, st, NONE, health or "ok"), "a").ready
	end
	local reported: Status.Entry = { s = "i", src = Status.SRC_AGENTS }
	check(ready({ reported }) == true, "an idle from Tern's agent state is ready")
	check(ready({ { s = "i", u = true, src = "agents" } }) == true, "so is one with an unseen finish")
	check(ready({ { s = "i", src = Status.SRC_PANE } }) == nil, "a pane that only reads not busy is not")
	check(ready({ { s = "w", src = "agents" } }) == nil, "a working agent is not")
	check(ready({ { s = "q", src = "agents" } }) == nil, "an asking agent is not")
	check(ready({ reported }, "stale") == nil, "nor an idle on stale status")
	check(ready({}) == nil, "nor a row with no status")
	check(ready({ reported, reported }) == nil, "nor a duplicate")
end

-- A row's label is the user's own label, else its pane's usable title, else the title its record remembers, else
-- `<agent> <n>`: a pane whose title is not usable (empty, or a restarted chat's default name) and an exited agent
-- show the remembered title, and search finds it as the label.
do
	local deck, sets, st = sample()
	deck.agents.a.title = "auth tokens"
	deck.agents.b.title = "old parser"
	deck.agents.c.title = "website copy"
	deck.agents.d.title = "notes cleanup"
	agent(deck, "e", "g2", 3, { cli = "copilot", title = "Fix the parser" })
	sets.e = { [300] = true }
	local panes = table.clone(PANES)
	table.insert(panes, { pane = 300, title = "GitHub Copilot" })
	local rows = Model.rows(deck, panes, sets, st, NONE, "ok")
	check(find(rows, "a").label == "Auth Fix", "the user's own label wins over a remembered title")
	check(find(rows, "b").label == "refactor parser", "a usable pane title wins over the remembered one")
	check(find(rows, "c").label == "website copy", "an empty pane title shows the remembered one")
	check(find(rows, "e").label == "Fix the parser", "a restarted chat's default name shows the remembered one")
	check(find(rows, "d").state == "exited" and find(rows, "d").label == "notes cleanup", "an exited row shows it")
	check(
		labels(Model.rows(deck, panes, sets, st, { search = "cleanup" }, "ok")) == "#notes,notes cleanup",
		"search finds a remembered title as the label"
	)
end

-- remember_titles keeps each bound agent's usable pane title on its record. A new usable title gives a new deck;
-- the same titles again, a turned spinner frame, titles that are not usable (empty, the agent's default) and an agent
-- with no bound pane (exited) give the same deck, so nothing is saved and the remembered title stays.
do
	local deck, sets, _ = sample()
	local panes = table.clone(PANES)
	panes[1] = { pane = 100, title = "auth tokens" }
	local out = Model.remember_titles(deck, panes, sets)
	check(out ~= deck, "a usable title gives a new deck")
	check(out.agents.b.title == "refactor parser", "the title is remembered without its spinner frame")
	check(out.agents.a.title == "auth tokens", "an agent with its own label remembers its pane title too")
	check(out.agents.c.title == nil and out.agents.d.title == nil, "an empty title or no pane remembers nothing")
	check(deck.agents.b.title == nil, "remember_titles leaves its input untouched")
	check(Model.remember_titles(out, panes, sets) == out, "the same titles again give the same deck")
	local spun = table.clone(panes)
	spun[2] = { pane = 200, title = "⠙ refactor parser" }
	check(Model.remember_titles(out, spun, sets) == out, "a turned spinner frame gives the same deck")
	local unusable = table.clone(panes)
	unusable[1] = { pane = 100, title = "omp" }
	unusable[2] = { pane = 200, title = "" }
	check(Model.remember_titles(out, unusable, sets) == out, "titles that are not usable give the same deck")
	check(out.agents.a.title == "auth tokens" and out.agents.b.title == "refactor parser", "the remembered ones stay")
	local renamed = table.clone(panes)
	renamed[2] = { pane = 200, title = "parser tests" }
	check(Model.remember_titles(out, renamed, sets).agents.b.title == "parser tests", "a new usable title replaces it")
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
		cli = "omp",
		cwd = "/home/a/g1",
		created_ms = NOW,
		state = "pending",
		failed = true,
		ended_ms = NOW,
	}
	local bound, verdict = Model.on_bind(pending, 42)
	check(verdict == "live" and bound.state == "live" and bound.pane == 42, "a pending record binds live")
	check(bound.failed == nil and bound.ended_ms == nil, "binding clears failed and ended")
	check(bound.ran == true, "binding records that the agent has run")
	check(
		pending.state == "pending" and pending.failed == true and pending.ran == nil,
		"on_bind leaves its input untouched"
	)
	local deck = Store.empty()
	deck.agents.p = bound
	local after_exit = Model.apply_exit(deck, "p", 0, NOW + 1)
	check(after_exit.agents.p.state == "exited" and after_exit.agents.p.ran == true, "an exit preserves the ran mark")
	local exited: Store.Record = table.clone(pending)
	exited.state, exited.failed, exited.exit, exited.ended_ms = "exited", nil, 0, NOW - 5
	local again, v2 = Model.on_bind(exited, 43)
	check(v2 == "live" and again.state == "live" and again.ended_ms == nil, "an exited record binds live again")
	check(again.ran == true, "rebinding an exited record records that it ran")
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
	local none: { [string]: boolean } = {}
	local deck = Store.empty()
	local first, n1 = Model.apply_launch(deck, "main", "devbox", false, NOW, none, false)
	check(
		first ~= deck and first.session.name == "main" and first.session.host == "devbox",
		"first launch stores names"
	)
	check(first.session.set_ms == NOW and n1 == nil, "first launch stamps set_ms with no notice")
	check(deck.session.name == nil, "the input deck is untouched")
	local same, n2 = Model.apply_launch(first, "main", "devbox", false, NOW + 1, none, true)
	check(same == first and n2 == nil, "the same names change nothing")
	local kept, n3 = Model.apply_launch(first, nil, nil, false, NOW + 1, none, true)
	check(kept == first and n3 == nil, "missing args change nothing")
	local moved, n4 = Model.apply_launch(first, "other", nil, false, NOW + 2, none, true)
	check(moved.session.name == "other" and moved.session.host == "devbox", "a new session name is stored")
	check(n4 == "jumpr moved from session main", "a new block in another session warns")
	local restored, n5 = Model.apply_launch(first, "other", nil, true, NOW + 2, none, true)
	check(restored.session.name == "other" and n5 == nil, "a restored block updates the name silently")
	-- The launching window names the host its own way: a launch never takes a name a live window still uses.
	local live = { devbox = true, ["me@devbox"] = true }
	local stolen = Model.apply_launch(first, nil, "me@devbox", false, NOW + 3, live, true)
	check(stolen == first, "a launch cannot take the host name a live window still uses")
	local early = Model.apply_launch(first, nil, "me@devbox", false, NOW + 3, { ["me@devbox"] = true }, false)
	check(early == first, "before the windows have had a minute, a launch keeps the stored host name")
	local rehosted, n6 = Model.apply_launch(first, nil, "devbox2", false, NOW + 3, { devbox2 = true }, true)
	check(
		rehosted.session.host == "devbox2" and rehosted.session.name == "main" and n6 == nil,
		"a host name no live window uses is replaced"
	)
	local filled = Model.apply_launch(Store.empty(), nil, "me@devbox", false, NOW, live, false)
	check(filled.session.host == "devbox", "a missing host name takes the lowest live name, whoever launched")
end

-- pick_host keeps a name any live window uses, and picks the same name whichever window spoke.
do
	local both = { devbox = true, ["me@devbox"] = true }
	check(Model.pick_host("devbox", "me@devbox", both, true) == "devbox", "a live stored name stays")
	check(Model.pick_host("me@devbox", "devbox", both, true) == "me@devbox", "whichever spelling is stored stays")
	check(Model.pick_host("devbox", nil, both, true) == "devbox", "no offered name keeps the stored one")
	check(Model.pick_host("devbox", "", both, true) == "devbox", "an empty offered name keeps the stored one")
	check(Model.pick_host(nil, "me@devbox", both, false) == "devbox", "a missing name takes the lowest live name")
	check(Model.pick_host(nil, "devbox", both, false) == "devbox", "the same pick from either window")
	check(Model.pick_host(nil, "devbox", {}, false) == "devbox", "with no live window the offered name fills a gap")
	check(
		Model.pick_host("old", "devbox", { devbox = true }, false) == "old",
		"an unsettled host keeps an unheard name"
	)
	check(
		Model.pick_host("old", "devbox", { devbox = true }, true) == "devbox",
		"a settled host replaces an unused name"
	)
end

-- heal_session: two window machines naming the host two ways, alternating, never move the label; a real rename
-- (the old name out of use) heals once with one notice.
do
	local deck = Store.empty()
	deck.session.name = "devbox"
	deck.session.host = "devbox"
	local both = { devbox = true, ["me@devbox"] = true }
	local notices = 0
	local d = deck
	for i = 1, 10 do
		local hn = if i % 2 == 0 then "devbox" else "me@devbox"
		local out, notice = Model.heal_session(d, "devbox", hn, both, true, NOW + i)
		if notice ~= nil then
			notices += 1
		end
		d = out
	end
	check(d == deck and d.session.host == "devbox", "alternating window names leave the stored host name alone")
	check(notices == 0, "alternating window names give no notice")
	-- The window naming it "devbox" went quiet a minute ago: only "me@devbox" is live.
	local only = { ["me@devbox"] = true }
	local healed, n1 = Model.heal_session(d, "devbox", "me@devbox", only, true, NOW + 70000)
	check(healed.session.host == "me@devbox" and healed.session.set_ms == NOW + 70000, "an unused name heals")
	check(n1 == "host name changed from devbox to me@devbox", "the heal gives one notice")
	local again, n2 = Model.heal_session(healed, "devbox", "devbox", both, true, NOW + 71000)
	check(again == healed and n2 == nil, "the old window coming back does not take the label back")
	local renamed, n3 = Model.heal_session(healed, "deck", nil, only, true, NOW + 72000)
	check(renamed.session.name == "deck" and renamed.session.host == "me@devbox", "the session name still heals")
	check(n3 == "deck session renamed from devbox to deck", "with its own notice")
	local early, n4 = Model.heal_session(deck, "devbox", "me@devbox", only, false, NOW)
	check(early == deck and n4 == nil, "after a host restart the stored name waits a minute for its window")
	local fresh = Model.heal_session(Store.empty(), "devbox", "me@devbox", only, false, NOW)
	check(fresh.session.host == "me@devbox", "a missing host name is filled at once")
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

-- stop_gone: a stop the window found nothing to stop for deletes the stopping record as a finished stop would, with
-- its closed stamp, and sweeps the deleting group it empties; any other record is left alone.
do
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	group(deck, "g2", "notes")
	local work = Store.closed_key("copilot", "/work")
	agent(deck, "a", "g1", 1, { cli = "copilot", cwd = "/work", ran = true })
	agent(deck, "k", "g2", 1)
	local deleting, stops = Model.delete_group(deck, "g1", NOW)
	check(#stops == 1 and deleting.agents.a.state == "stopping", "the group's live agent is stopping")
	local gone = Model.stop_gone(deleting, "a", NOW + 500)
	check(gone.agents.a == nil, "stop_gone deletes the stopping record")
	check(gone.closed[work] == "a", "it stamps the closed key, as a stop whose pane exited does")
	check(#gone.groups == 1 and gone.groups[1].gid == "g2", "and the deleting group it empties is swept")
	check(deleting.agents.a ~= nil and deleting.agents.a.state == "stopping", "stop_gone leaves its input untouched")
	check(Model.stop_gone(deleting, "k", NOW) == deleting, "a live record is left alone")
	check(Model.stop_gone(deleting, "missing", NOW) == deleting, "an unknown id changes nothing")
	local back = Model.stop_failed(deleting, "a")
	check(Model.stop_gone(back, "a", NOW) == back, "a record already taken back to live is left alone")
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

-- An agent whose vibe workers have a turn running counts as running everywhere a code is read (its row, its group's
-- header, the tiles, the filters) and its row is marked vibing; a question still wins and leaves no mark.
do
	local deck, sets, st = sample()
	st.a = Status.with_vibing({ { s = "i", u = true, src = "agents" } })
	local rows = Model.rows(deck, PANES, sets, st, NONE, "ok")
	local a = find(rows, "a")
	check(a.code == "running" and a.vibing == true, "a vibing row is running and marked vibing")
	check(find(rows, "c").code == "running" and find(rows, "c").vibing == nil, "a plain working row is not vibing")
	local tally = rows[1].tally :: { [string]: number }
	check(tally.running == 1 and tally.waiting == 1 and tally.idle == nil, "the header counts it under running")
	local tiles = Model.tally(deck, st, "ok")
	check(tiles.running == 2 and tiles.waiting == 1 and tiles.idle == nil, "the tiles count it under running")
	check(
		labels(Model.rows(deck, PANES, sets, st, { filter = "running" }, "ok")) == "#Webapp,Auth Fix,#notes,omp 1",
		"the running filter shows the vibing row"
	)
	check(#Model.rows(deck, PANES, sets, st, { filter = "idle" }, "ok") == 0, "the idle filter does not show it")
	check(find(Model.rows(deck, PANES, sets, st, NONE, "stale"), "a").vibing == nil, "stale status marks nothing")
	st.b = Status.with_vibing(st.b)
	local b = find(Model.rows(deck, PANES, sets, st, NONE, "ok"), "b")
	check(b.code == "waiting" and b.vibing == nil, "an asking agent with a vibe worker running is waiting, not vibing")
end

-- Restart mode for an ACP kind: a proven session wins, then never-ran, then the last closed agent, otherwise the
-- picker.
do
	local deck = Store.empty()
	local work = Store.closed_key("copilot", "/work")
	agent(deck, "proved", "g1", 1, {
		cli = "copilot",
		cwd = "/work",
		state = "exited",
		ran = true,
		session = "sess-1",
		exit = 0,
		ended_ms = NOW,
	})
	agent(deck, "fresh", "g1", 2, { cli = "copilot", cwd = "/work", state = "exited", exit = 0, ended_ms = NOW })
	agent(deck, "marked", "g1", 3, {
		cli = "copilot",
		cwd = "/work",
		state = "exited",
		ran = false,
		exit = 0,
		ended_ms = NOW,
	})
	agent(deck, "last", "g1", 4, {
		cli = "copilot",
		cwd = "/work",
		state = "exited",
		ran = true,
		exit = 0,
		ended_ms = NOW,
	})
	agent(deck, "other", "g1", 5, {
		cli = "copilot",
		cwd = "/work",
		state = "exited",
		ran = true,
		exit = 0,
		ended_ms = NOW,
	})
	deck.closed[work] = "proved"
	local mode, sid = Model.restart_mode(deck.agents.proved, "proved", deck)
	check(mode == "resume" and sid == "sess-1", "a session resumes even when this agent closed last")
	deck.closed[work] = "fresh"
	local fresh_mode, fresh_sid = Model.restart_mode(deck.agents.fresh, "fresh", deck)
	check(fresh_mode == "new" and fresh_sid == nil, "an agent that never ran starts new")
	deck.agents.fresh.session = "sess-2"
	local proved_fresh, proved_fresh_sid = Model.restart_mode(deck.agents.fresh, "fresh", deck)
	check(proved_fresh == "resume" and proved_fresh_sid == "sess-2", "a session resumes even when the agent never ran")
	deck.closed[work] = "marked"
	local marked_mode, marked_sid = Model.restart_mode(deck.agents.marked, "marked", deck)
	check(
		marked_mode == "new" and marked_sid == nil,
		"a record marked as never ran starts new even when it is the stamp"
	)
	deck.closed[work] = "last"
	local last_mode, last_sid = Model.restart_mode(deck.agents.last, "last", deck)
	check(last_mode == "continue" and last_sid == nil, "the last closed agent of its kind continues")
	local other_mode, other_sid = Model.restart_mode(deck.agents.other, "other", deck)
	check(other_mode == "pick" and other_sid == nil, "another agent in that folder opens the picker")
end

-- Restart mode for claude and codex (real CLIs): a stored session resumes; with none they never continue, even as
-- the last closed agent in their folder, so a restart can never land in another live agent's conversation.
do
	local function exited(cli: string, fields: { [string]: any }?): Store.Record
		local deck = Store.empty()
		local base: { [string]: any } = { cli = cli, cwd = "/work", state = "exited", ran = true, exit = 0 }
		for k, v in (fields or {}) :: { [string]: any } do
			base[k] = v
		end
		base.ended_ms = NOW
		agent(deck, "x", "g1", 1, base)
		return deck.agents.x
	end
	local deck = Store.empty()
	deck.closed[Store.closed_key("claude", "/work")] = "x"
	deck.closed[Store.closed_key("codex", "/work")] = "x"
	local uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"

	-- The record ran (bound a pane) and is the last closed in its folder, but whether it was ever prompted is unknown:
	-- the id drawn at creation resumes regardless, since the launch line resumes it or starts it fresh.
	local claude_mode, claude_sid = Model.restart_mode(exited("claude", { session = uuid }), "x", deck)
	check(claude_mode == "resume" and claude_sid == uuid, "a ran, possibly never-prompted claude session resumes")
	local unbound_mode, unbound_sid = Model.restart_mode(exited("claude", { session = uuid, ran = false }), "x", deck)
	check(unbound_mode == "resume" and unbound_sid == uuid, "a claude retry before it ever bound keeps its id")
	local bare_mode, bare_sid = Model.restart_mode(exited("claude"), "x", deck)
	check(bare_mode == "pick" and bare_sid == nil, "claude without a session opens the picker, never continues")
	local bare_new = Model.restart_mode(exited("claude", { ran = false }), "x", deck)
	check(bare_new == "pick", "claude without a session picks even before it bound: it has no new line without an id")

	local codex_mode, codex_sid = Model.restart_mode(exited("codex", { session = uuid }), "x", deck)
	check(codex_mode == "resume" and codex_sid == uuid, "codex with a proven thread resumes it")
	local unproven_mode, unproven_sid = Model.restart_mode(exited("codex"), "x", deck)
	check(unproven_mode == "pick" and unproven_sid == nil, "codex without a thread opens the picker, never continues")
	local fresh_mode, fresh_sid = Model.restart_mode(exited("codex", { ran = false }), "x", deck)
	check(fresh_mode == "new" and fresh_sid == nil, "a codex agent that never bound starts new")
	local upper_mode, upper_sid = Model.restart_mode(exited("claude", { session = string.upper(uuid) }), "x", deck)
	check(upper_mode == "pick" and upper_sid == nil, "claude with a non-uuid session picks as if it had none")
	local odd_mode, odd_sid = Model.restart_mode(exited("codex", { session = "thread-1" }), "x", deck)
	check(odd_mode == "pick" and odd_sid == nil, "codex that ran with a non-uuid thread picks")
	local odd_new = Model.restart_mode(exited("codex", { session = "thread-1", ran = false }), "x", deck)
	check(odd_new == "new", "codex that never ran with a non-uuid thread starts new")

	local omp_mode = Model.restart_mode(exited("omp", { session = uuid }), "x", deck)
	check(omp_mode == "new", "omp is unchanged: always new")
	deck.closed[Store.closed_key("copilot", "/work")] = "x"
	check(Model.restart_mode(exited("copilot"), "x", deck) == "continue", "an ACP kind still continues as last closed")
end

-- A non-omp close stamps its own kind and folder. A pane exit without a stop does not.
do
	local deck = Store.empty()
	local work = Store.closed_key("copilot", "/work")
	local other = Store.closed_key("copilot", "/other")
	local gemini = Store.closed_key("gemini", "/work")
	agent(deck, "a", "g1", 1, { cli = "copilot", cwd = "/work", ran = true })
	agent(deck, "b", "g1", 2, { cli = "copilot", cwd = "/other", ran = true })
	agent(deck, "c", "g1", 3, { cli = "gemini", cwd = "/work", ran = true })
	local stamped = Model.stamp_closed(deck, "a")
	check(stamped ~= deck and stamped.closed[work] == "a", "a non-omp close stamps a copy")
	check(deck.closed[work] == nil, "stamping leaves the input untouched")
	check(Model.stamp_closed(stamped, "a") == stamped, "the same stamp changes nothing")
	local folder = Model.stamp_closed(stamped, "b")
	check(folder.closed[work] == "a" and folder.closed[other] == "b", "another folder gets its own stamp")
	local kind = Model.stamp_closed(stamped, "c")
	check(kind.closed[work] == "a" and kind.closed[gemini] == "c", "another kind gets its own stamp")
	local exited = Model.apply_exit(deck, "a", 0, NOW)
	check(
		exited.agents.a.state == "exited" and exited.agents.a.ran == true,
		"a pane exit without a stop keeps the record"
	)
	check(next(exited.closed) == nil, "that exit does not stamp")
	check(Model.stamp_closed(deck, "missing") == deck, "an unknown id never stamps")
end

-- omp never stamps and always starts new, even with a session and a closed stamp.
do
	local deck = Store.empty()
	local key = Store.closed_key("omp", "/home/a/g1")
	agent(deck, "o", "g1", 1, { state = "stopping", stop_ms = NOW, ran = true, session = "sess" })
	agent(deck, "still", "g1", 2, { state = "exited", ran = true, session = "sess", exit = 0, ended_ms = NOW })
	deck.closed[key] = "still"
	check(Model.stamp_closed(deck, "o") == deck, "omp never stamps")
	local out = Model.apply_exit(deck, "o", 0, NOW)
	check(out.agents.o == nil, "a stopped omp record is still deleted")
	check(out.closed[key] == "still", "the delete does not write an omp stamp")
	local mode, sid = Model.restart_mode(deck.agents.still, "still", deck)
	check(mode == "new" and sid == nil, "omp always starts new")
end

-- A stop that deletes an ACP record stamps it closed, so an earlier exit in that folder is no longer last.
do
	local deck = Store.empty()
	local work = Store.closed_key("copilot", "/work")
	local other = Store.closed_key("copilot", "/other")
	local gemini = Store.closed_key("gemini", "/work")
	agent(deck, "early", "g1", 1, {
		cli = "copilot",
		cwd = "/work",
		state = "exited",
		ran = true,
		exit = 0,
		ended_ms = NOW - 5,
	})
	agent(deck, "late", "g1", 2, { cli = "copilot", cwd = "/work", state = "stopping", stop_ms = NOW, ran = true })
	agent(deck, "recent", "g1", 3, { cli = "copilot", cwd = "/recent", ran = true, stop_ms = NOW - 1000 })
	agent(deck, "elsewhere", "g1", 4, {
		cli = "copilot",
		cwd = "/other",
		state = "exited",
		ran = true,
		exit = 0,
		ended_ms = NOW - 5,
	})
	agent(deck, "otherkind", "g1", 5, {
		cli = "gemini",
		cwd = "/work",
		state = "exited",
		ran = true,
		exit = 0,
		ended_ms = NOW - 5,
	})
	deck.closed[work] = "early"
	deck.closed[other] = "elsewhere"
	deck.closed[gemini] = "otherkind"
	deck.queue.late = { text = "hold", at_ms = NOW }
	local out = Model.apply_exit(deck, "late", 0, NOW)
	check(out.agents.late == nil and out.queue.late == nil, "a stop deletes the record and its held message")
	check(out.closed[work] == "late", "the deleted record is stamped closed before it goes")
	check(deck.agents.late ~= nil and deck.closed[work] == "early", "the stop delete leaves its input untouched")
	local mode, sid = Model.restart_mode(out.agents.early, "early", out)
	check(mode == "pick" and sid == nil, "the earlier exit is no longer the last closed")
	local kept, kept_sid = Model.restart_mode(out.agents.elsewhere, "elsewhere", out)
	check(kept == "continue" and kept_sid == nil and out.closed[other] == "elsewhere", "another folder is left alone")
	local kind, kind_sid = Model.restart_mode(out.agents.otherkind, "otherkind", out)
	check(kind == "continue" and kind_sid == nil and out.closed[gemini] == "otherkind", "another kind is left alone")
	local recent = Model.apply_exit(deck, "recent", 0, NOW)
	check(recent.agents.recent == nil, "a live record whose stop is still inside the window is deleted")
	check(recent.closed[Store.closed_key("copilot", "/recent")] == "recent", "that delete stamps closed too")
end

-- Reconcile exits and deletes in an arbitrary order, so it cannot leave a last-closed stamp.
do
	local deck = Store.empty()
	local work = Store.closed_key("copilot", "/work")
	agent(deck, "a", "g1", 1, { cli = "copilot", cwd = "/work", ran = true, pane = 1 })
	agent(deck, "b", "g1", 2, { cli = "copilot", cwd = "/work", ran = true, pane = 2 })
	deck.closed[work] = "a"
	local out = Model.reconcile_states(deck, {}, NOW)
	check(out.agents.a.state == "exited" and out.agents.b.state == "exited", "both missing panes exit together")
	check(out.agents.a.ran == true and out.agents.b.ran == true, "reconcile keeps the ran mark")
	check(out.closed[work] == nil, "reconcile clears the shared closed key")
	local mode_a, sid_a = Model.restart_mode(out.agents.a, "a", out)
	local mode_b, sid_b = Model.restart_mode(out.agents.b, "b", out)
	check(mode_a == "pick" and sid_a == nil, "the earlier stamp is not trusted")
	check(mode_b == "pick" and sid_b == nil, "the other record is not trusted either")
	check(deck.closed[work] == "a" and deck.agents.a.state == "live", "reconcile leaves its input untouched")

	local mixed = Store.empty()
	local other = Store.closed_key("copilot", "/other")
	agent(mixed, "early", "g1", 1, {
		cli = "copilot",
		cwd = "/work",
		state = "exited",
		ran = true,
		exit = 0,
		ended_ms = NOW - 5,
	})
	agent(mixed, "late", "g1", 2, {
		cli = "copilot",
		cwd = "/work",
		state = "stopping",
		stop_ms = NOW,
		ran = true,
		pane = 9,
	})
	agent(mixed, "live", "g1", 3, { cli = "copilot", cwd = "/work", ran = true, pane = 10 })
	agent(mixed, "away", "g1", 4, { cli = "copilot", cwd = "/other", ran = true, pane = 11 })
	mixed.closed[work] = "early"
	mixed.closed[other] = "away"
	local cleared = Model.reconcile_states(mixed, { [11] = true }, NOW)
	check(cleared.agents.late == nil, "a stopping record with no listed pane is deleted")
	check(cleared.agents.live.state == "exited", "a live record with no listed pane exits")
	check(cleared.closed[work] == nil, "reconcile clears the stamp a stop delete just wrote")
	local survivor, survivor_sid = Model.restart_mode(cleared.agents.early, "early", cleared)
	check(survivor == "pick" and survivor_sid == nil, "the survivor is not treated as last closed")
	check(cleared.agents.away.state == "live" and cleared.closed[other] == "away", "another folder's stamp stays")
	check(Model.restart_mode(cleared.agents.away, "away", cleared) == "continue", "that folder still continues")

	local both = Store.empty()
	agent(both, "s1", "g1", 1, { cli = "copilot", cwd = "/work", state = "stopping", ran = true, pane = 1 })
	agent(both, "s2", "g1", 2, { cli = "copilot", cwd = "/work", state = "stopping", ran = true, pane = 2 })
	both.closed[work] = "s1"
	local deleted = Model.reconcile_states(both, {}, NOW)
	check(deleted.agents.s1 == nil and deleted.agents.s2 == nil, "both stopping records are deleted")
	check(deleted.closed[work] == nil, "neither delete leaves a closed stamp")

	local omp = Store.empty()
	agent(omp, "o", "g1", 1, { pane = 1 })
	omp.closed[work] = "keep"
	local omp_out = Model.reconcile_states(omp, {}, NOW)
	check(omp_out.agents.o.state == "exited", "a missing omp pane still exits")
	check(omp_out.closed[work] == "keep", "reconciling omp does not clear an ACP stamp")
end

-- set_session stores a different proven id on a live non-omp record, and leaves every other record alone. A stored
-- claude id is replaced only by the pane's own `claude` process (the `/clear` rule).
do
	local deck = Store.empty()
	agent(deck, "a", "g1", 1, { cli = "copilot", session = "old" })
	local replaced = Model.set_session(deck, "a", "new")
	check(replaced ~= deck and replaced.agents.a.session == "new", "a different id replaces an ACP agent's session")
	check(deck.agents.a.session == "old", "set_session leaves its input untouched")
	check(Model.set_session(replaced, "a", "new") == replaced, "an equal id leaves the deck")
	local none = Store.empty()
	agent(none, "b", "g1", 1, { cli = "copilot" })
	local filled = Model.set_session(none, "b", "sid")
	check(filled.agents.b.session == "sid", "a record with no session takes the proven id")
	check(none.agents.b.session == nil, "filling a session leaves the input untouched")
	check(Model.set_session(deck, "missing", "x") == deck, "an unknown id is left alone")
	local omp = Store.empty()
	agent(omp, "o", "g1", 1)
	check(Model.set_session(omp, "o", "sid") == omp, "omp never stores a session")
	check(Model.set_session(omp, "o", "sid", true) == omp, "omp never stores one even from its own process")
	local exited = Store.empty()
	agent(exited, "e", "g1", 1, { cli = "copilot", state = "exited", session = "old", exit = 0, ended_ms = NOW })
	check(Model.set_session(exited, "e", "new") == exited, "an exited record keeps its session")
	local stopping = Store.empty()
	agent(stopping, "s", "g1", 1, { cli = "copilot", state = "stopping", session = "old" })
	check(Model.set_session(stopping, "s", "new") == stopping, "a stopping record is left alone")
	local pending = Store.empty()
	agent(pending, "p", "g1", 1, { cli = "copilot", state = "pending", session = "old" })
	check(Model.set_session(pending, "p", "new") == pending, "a pending record is left alone")

	local claude = Store.empty()
	agent(claude, "c", "g1", 1, { cli = "claude", session = "old" })
	check(Model.set_session(claude, "c", "nested") == claude, "a nested claude never replaces the stored id")
	check(Model.set_session(claude, "c", "nested", false) == claude, "nor does any lookup not from the pane's own")
	local cleared = Model.set_session(claude, "c", "after-clear", true)
	check(cleared.agents.c.session == "after-clear", "the pane's own claude replaces it after /clear")
	check(claude.agents.c.session == "old", "that replacement leaves its input untouched")
	local claude_exited = Store.empty()
	agent(claude_exited, "c", "g1", 1, { cli = "claude", state = "exited", session = "old", exit = 0, ended_ms = NOW })
	check(Model.set_session(claude_exited, "c", "new", true) == claude_exited, "an exited claude keeps its session")
	local claude_none = Store.empty()
	agent(claude_none, "c", "g1", 1, { cli = "claude" })
	check(Model.set_session(claude_none, "c", "sid").agents.c.session == "sid", "a claude with no session takes one")
	local codex = Store.empty()
	agent(codex, "x", "g1", 1, { cli = "codex", session = "old" })
	check(Model.set_session(codex, "x", "new").agents.x.session == "new", "a codex thread is replaced as before")
end

print("Model: " .. checks .. " checks passed")
