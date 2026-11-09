--!strict

local Keys = require("../lib/host/keys")
local Model = require("../lib/host/model")
local Status = require("../lib/shared/status")
local Store = require("../lib/host/store")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local NOW = 1800000000000

-- A rand that walks a fixed list of draws (each in [1, 32]); new_id takes 8 draws.
local function rand_from(draws: { number }): (number) -> number
	local i = 0
	return function(_n: number): number
		i += 1
		return draws[(i - 1) % #draws + 1]
	end
end
local RAND = rand_from({ 1, 2, 3, 4, 5, 6, 7, 8 }) -- "abcdefgh"

local function group(deck: Store.Deck, gid: string, name: string, folded: boolean?)
	table.insert(deck.groups, { gid = gid, name = name, cwd = "/home/a/" .. name, folded = folded == true })
end

local function agent(deck: Store.Deck, id: string, gid: string, pos: number, fields: { [string]: any }?)
	local r: Store.Record = {
		gid = gid,
		pos = pos,
		dir = "~/.omp/deck/" .. id,
		cwd = "/home/a/wt/" .. id,
		created_ms = NOW - 1000,
		state = "live",
		pane = pos,
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

-- Group "webapp" with live agents a and b; group "notes" with live agent c.
local function sample(): Store.Deck
	local deck = Store.empty()
	group(deck, "g1", "webapp")
	group(deck, "g2", "notes")
	agent(deck, "a", "g1", 1)
	agent(deck, "b", "g1", 2)
	agent(deck, "c", "g2", 1)
	return deck
end

-- One block: its UI, deck, last effects, the pane sets and merged status the rows are built from, and their health.
type Block = {
	ui: Keys.UI,
	deck: Store.Deck,
	effects: { Keys.Effect },
	sets: Model.PaneSets,
	status: Model.StatusById,
	health: string,
}

local function block(deck: Store.Deck): Block
	local sets: Model.PaneSets = {}
	for id, r in deck.agents do
		if r.pane ~= nil then
			sets[id] = { [r.pane] = true }
		end
	end
	local b: Block = { ui = Keys.new_ui(nil), deck = deck, effects = {}, sets = sets, status = {}, health = "ok" }
	b.ui.block_cwd = "/home/a/block"
	return b
end

local function rows(b: Block): { Model.Row }
	return Model.rows(b.deck, {}, b.sets, b.status, b.ui, b.health)
end

local function send(b: Block, event: Keys.Event, rand: ((number) -> number)?)
	local rs = rows(b)
	b.ui.selection = Model.clamp_selection(rs, b.ui.selection, b.deck)
	b.ui, b.deck, b.effects = Keys.reduce(b.ui, b.deck, rs, event, NOW, rand or RAND)
end

local function key(b: Block, name: string, text: string?, rand: ((number) -> number)?)
	send(b, { kind = "key", name = name, text = text }, rand)
end

-- A printable key: Tern sends the lowercase name with the typed text.
local function char(b: Block, c: string)
	key(b, string.lower(c), c)
end

local function type_text(b: Block, s: string)
	for i = 1, #s do
		char(b, string.sub(s, i, i))
	end
end

local function select(b: Block, sel: Model.Selection)
	b.ui.selection = sel
end

local function kinds(effects: { Keys.Effect }): string
	local out = {}
	for _, e in effects do
		table.insert(out, if e.kind == "request" then "request:" .. (e.verb or "?") else e.kind)
	end
	return table.concat(out, ",")
end

local function request_of(effects: { Keys.Effect }, verb: string): { [string]: string }?
	for _, e in effects do
		if e.kind == "request" and e.verb == verb then
			return e.fields
		end
	end
	return nil
end

-- The host's answer to the last `check_folder` effect: its fields echoed back with `ok`.
local function answer(b: Block, ok: boolean, rand: ((number) -> number)?)
	local e: Keys.Effect? = nil
	for _, x in b.effects do
		if x.kind == "check_folder" then
			e = x
		end
	end
	assert(e ~= nil, "a check_folder effect to answer: " .. kinds(b.effects))
	send(b, {
		kind = "folder_checked",
		purpose = e.purpose,
		folder = e.folder,
		ok = ok,
		gid = e.gid,
		id = e.id,
		text = e.text,
	}, rand)
end

-- Filters: each key along the shifted number row sets its status (the filter holds the code, never the key), the
-- same key again clears, another switches, 0 clears; all read from key.text.
do
	local b = block(sample())
	key(b, "1", "!")
	check(b.ui.filter == "error", "! (name 1, text !) sets the error filter")
	check(kinds(b.effects) == "render", "a filter change renders and does not save kv")
	key(b, "1", "!")
	check(b.ui.filter == nil, "! again clears it")
	key(b, "1", "!")
	key(b, "3", "#")
	check(b.ui.filter == "running", "! then # switches to running")
	key(b, "2", "@")
	check(b.ui.filter == "waiting", "# then @ switches to waiting")
	key(b, "2", "@")
	check(b.ui.filter == nil, "@ again clears")
	key(b, "4", "$")
	check(b.ui.filter == "idle", "$ (name 4, text $) sets the idle filter")
	key(b, "7", "&")
	check(b.ui.filter == "idle", "& is no filter key any more and changes nothing")
	char(b, "0")
	check(b.ui.filter == nil, "0 clears the filter")
	char(b, "0")
	check(#b.effects == 0, "0 with no filter changes nothing and does not render")
end

-- Esc in mode A: input, then search, then filter, then back; never a hide.
do
	local b = block(sample())
	key(b, "1", "!")
	char(b, "/")
	type_text(b, "no")
	check(b.ui.mode == "input" and b.ui.search == "no", "the search is live as text arrives")
	key(b, "enter")
	check(b.ui.mode == "list" and b.ui.search == "no", "Enter closes the search line and keeps the search")
	char(b, "g")
	check(b.ui.mode == "input" and b.ui.purpose == "folder", "g opens an input over the search and filter")
	key(b, "escape")
	check(b.ui.mode == "list" and b.ui.search == "no" and b.ui.filter == "error", "Esc first closes the input")
	key(b, "escape")
	check(b.ui.search == nil and b.ui.filter == "error", "then clears the search")
	key(b, "escape")
	check(b.ui.filter == nil, "then clears the filter")
	check(request_of(b.effects, "back") == nil, "no back while something was open")
	key(b, "escape")
	local back = request_of(b.effects, "back")
	check(back ~= nil and next(back) == nil, "with nothing open Esc requests back with no fields")
	for _, e in b.effects do
		check(e.kind ~= "hide" and e.verb ~= "hide", "Esc never gives a hide effect")
	end

	local s = block(sample())
	char(s, "/")
	type_text(s, "gl")
	key(s, "escape")
	check(s.ui.mode == "list" and s.ui.search == nil, "Esc in the search line closes it and clears the search")

	local arrows = block(sample())
	select(arrows, { kind = "agent", id = "a" })
	char(arrows, "/")
	key(arrows, "down")
	check(
		arrows.ui.mode == "input" and arrows.ui.selection ~= nil and arrows.ui.selection.id == "a",
		"↓ in the search line leaves the selection where it is"
	)
end

-- Esc in mode B only cancels inputs.
do
	local b = block(sample())
	b.ui.em = "B"
	key(b, "1", "!")
	b.ui.search = "gl"
	char(b, "g")
	key(b, "escape")
	check(b.ui.mode == "list", "mode B: Esc cancels an input")
	key(b, "escape")
	check(b.ui.search == "gl" and b.ui.filter == "error", "mode B: Esc keeps the search and the filter")
	check(#b.effects == 0, "mode B: Esc in the list gives no effect")
end

-- On a header, h folds, l unfolds, Tab and Enter toggle; every fold change saves kv.
do
	local b = block(sample())
	select(b, { kind = "header", gid = "g1" })
	char(b, "h")
	check(b.deck.groups[1].folded == true, "h folds")
	check(kinds(b.effects) == "save_kv,render", "a fold saves kv and renders")
	char(b, "h")
	check(#b.effects == 0, "h on a folded header changes nothing")
	char(b, "l")
	check(b.deck.groups[1].folded == false, "l unfolds")
	key(b, "tab")
	check(b.deck.groups[1].folded == true, "Tab toggles to folded")
	key(b, "enter")
	check(b.deck.groups[1].folded == false, "Enter toggles back")
	check(b.ui.selection ~= nil and b.ui.selection.kind == "header", "the header stays selected")
end

-- Movement: j/k, ↑/↓, G/End, Home.
do
	local b = block(sample())
	select(b, { kind = "header", gid = "g1" })
	char(b, "j")
	check(b.ui.selection ~= nil and b.ui.selection.id == "a", "j moves down")
	key(b, "down")
	check(b.ui.selection ~= nil and b.ui.selection.id == "b", "↓ moves down")
	char(b, "k")
	check(b.ui.selection ~= nil and b.ui.selection.id == "a", "k moves up")
	key(b, "g", "G")
	check(b.ui.selection ~= nil and b.ui.selection.id == "c", "G goes to the last row")
	char(b, "j")
	check(b.ui.selection ~= nil and b.ui.selection.id == "c" and #b.effects == 0, "j on the last row stays put")
	key(b, "home")
	check(b.ui.selection ~= nil and b.ui.selection.gid == "g1" and b.ui.selection.kind == "header", "Home: first")
	key(b, "end")
	check(b.ui.selection ~= nil and b.ui.selection.id == "c", "End goes to the last row")
	key(b, "up")
	check(b.ui.selection ~= nil and b.ui.selection.kind == "header" and b.ui.selection.gid == "g2", "↑ moves up")
end

-- Group movement: J to the next group's header, K to the previous one (from an agent, its own header first); both
-- stop at the first and last group, pass over a folded group's agents, and count only what a search shows.
do
	local function three(): Store.Deck
		local deck = sample()
		group(deck, "g3", "docs")
		agent(deck, "d", "g3", 1)
		agent(deck, "e", "g3", 2)
		return deck
	end
	local function on_header(b: Block, gid: string): boolean
		local sel = b.ui.selection
		return sel ~= nil and sel.kind == "header" and sel.gid == gid
	end

	local b = block(three())
	select(b, { kind = "agent", id = "a" })
	char(b, "J")
	check(on_header(b, "g2"), "J from an agent goes to the next group's header")
	check(kinds(b.effects) == "render", "landing on a header emits no show")
	char(b, "J")
	check(on_header(b, "g3"), "J from a header goes to the next header")
	char(b, "J")
	check(on_header(b, "g3") and #b.effects == 0, "J on the last group's header stays put")
	select(b, { kind = "agent", id = "e" })
	char(b, "J")
	check(b.ui.selection ~= nil and b.ui.selection.id == "e" and #b.effects == 0, "J in the last group stays put")
	char(b, "K")
	check(on_header(b, "g3"), "K from an agent goes to its own group's header first")
	char(b, "K")
	check(on_header(b, "g2"), "K from a header goes to the previous header")
	char(b, "K")
	check(on_header(b, "g1"), "K again goes to the first header")
	char(b, "K")
	check(on_header(b, "g1") and #b.effects == 0, "K on the first header stays put")
	select(b, { kind = "agent", id = "b" })
	char(b, "K")
	check(on_header(b, "g1"), "K from the first group's agent goes to its header")

	local shifted = block(three())
	select(shifted, { kind = "agent", id = "a" })
	send(shifted, { kind = "key", name = "j", shift = true })
	check(on_header(shifted, "g2"), "shift+j with no text is J")
	send(shifted, { kind = "key", name = "k", shift = true })
	check(on_header(shifted, "g1"), "shift+k with no text is K")

	local folded = three()
	folded.groups[2].folded = true
	local f = block(folded)
	select(f, { kind = "agent", id = "b" })
	char(f, "J")
	check(on_header(f, "g2"), "J lands on a folded group's header")
	char(f, "J")
	check(on_header(f, "g3"), "J from a folded header goes to the next header")
	char(f, "K")
	char(f, "K")
	check(on_header(f, "g1"), "K passes back over the folded group to the header above")

	local searched = block(three())
	searched.ui.search = "docs"
	select(searched, { kind = "header", gid = "g3" })
	char(searched, "K")
	check(on_header(searched, "g3") and #searched.effects == 0, "K with the other groups searched away stays put")
	searched.ui.search = "webapp"
	select(searched, { kind = "agent", id = "a" })
	char(searched, "J")
	check(
		searched.ui.selection ~= nil and searched.ui.selection.id == "a" and #searched.effects == 0,
		"J with the groups below searched away stays put"
	)
	searched.ui.search = nil
	searched.ui.filter = "running"
	for _, id in { "a", "b", "d", "e" } do
		searched.status[id] = { { s = "w" } }
	end
	searched.status.c = { { s = "i" } }
	select(searched, { kind = "header", gid = "g1" })
	char(searched, "J")
	check(on_header(searched, "g3"), "J skips a group the filter hides")

	local held = block(three())
	select(held, { kind = "header", gid = "g1" })
	char(held, "V")
	char(held, "J")
	check(
		held.ui.mode == "order" and held.deck.groups[1].gid == "g1" and #held.effects == 0,
		"J is inert in order mode"
	)
	char(held, "K")
	check(held.ui.mode == "order" and #held.effects == 0, "K is inert in order mode")
end

-- Enter on an agent requests jump.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "b" })
	key(b, "enter")
	local jump = request_of(b.effects, "jump")
	check(jump ~= nil and jump.id == "b", "Enter on an agent requests jump with its id")
	check(kinds(b.effects) == "request:jump", "jump changes no deck and no visible state")
end

-- Enter on a failed pending row retries start with created_ms reset; a renamed agent's label rides along.
do
	local deck = sample()
	agent(deck, "p", "g1", 3, {
		state = "pending",
		pane = nil,
		failed = true,
		ended_ms = NOW - 50,
		created_ms = NOW - 60000,
		label = "flaky-fixer",
		cwd = "/home/a/webapp",
	})
	local b = block(deck)
	select(b, { kind = "agent", id = "p" })
	key(b, "enter")
	check(kinds(b.effects) == "check_folder", "Enter on a failed pending row first checks its folder")
	check(b.effects[1].purpose == "retry" and b.effects[1].folder == "/home/a/webapp", "the retry's folder and id")
	check(b.effects[1].id == "p" and b.deck == deck, "nothing changes before the answer")
	answer(b, true)
	local start = request_of(b.effects, "start")
	check(start ~= nil and start.id == "p", "Enter on a failed pending row requests start again")
	check(start ~= nil and start.cwd == "/home/a/webapp", "the retry keeps the cwd")
	check(start ~= nil and start.prompt == nil and start.label == "flaky-fixer", "no prompt; the label names the tab")
	local r = b.deck.agents.p
	check(r.created_ms == NOW and r.failed == nil and r.ended_ms == nil, "the retry resets created_ms, clears failed")
	check(r.state == "pending", "the record stays pending")
	check(kinds(b.effects) == "save_kv,request:start,render", "the retry saves kv before the request")
	check(deck.agents.p.failed == true, "reduce leaves the input deck untouched")
end

-- (fix/folder-exists) A retry whose folder is gone is refused: no start, the record stays failed.
do
	local deck = sample()
	deck.session.host = "devbox"
	agent(deck, "p", "g1", 3, {
		state = "pending",
		failed = true,
		ended_ms = NOW - 50,
		created_ms = NOW - 60000,
		cwd = "/home/a/gone",
	})
	local b = block(deck)
	select(b, { kind = "agent", id = "p" })
	key(b, "enter")
	answer(b, false)
	check(b.ui.notice == "folder not found on devbox", "the retry refuses: " .. tostring(b.ui.notice))
	check(request_of(b.effects, "start") == nil and kinds(b.effects) == "render", "no start, no save")
	check(b.deck == deck and b.deck.agents.p.failed == true, "the record is unchanged and still failed")
	-- An answer for a record that changed meanwhile (here: another folder) does nothing.
	key(b, "enter")
	b.deck = Store.clone(b.deck)
	b.deck.agents.p.cwd = "/home/a/elsewhere"
	answer(b, true)
	check(request_of(b.effects, "start") == nil and #b.effects == 0, "a stale retry answer starts nothing")
end

-- Enter on an exited row restarts the agent in its own session (same deck id, so `omp --continue` resumes it) and
-- lands on it, after the same folder check as a retry. A gone folder or a row that changed meanwhile starts nothing.
do
	local deck = sample()
	deck.session.host = "devbox"
	agent(deck, "x", "g1", 3, {
		state = "exited",
		pane = nil,
		exit = 0,
		ended_ms = NOW - 50,
		stop_ms = NOW - 600000,
		created_ms = NOW - 600000,
		label = "fixer",
		cwd = "/home/a/webapp",
	})
	local b = block(deck)
	select(b, { kind = "agent", id = "x" })
	key(b, "enter")
	check(kinds(b.effects) == "check_folder", "Enter on an exited row checks its folder, never jumps")
	check(b.effects[1].purpose == "restart" and b.effects[1].id == "x", "the restart's purpose and id")
	check(b.deck == deck, "nothing changes before the answer")
	answer(b, true)
	local start = request_of(b.effects, "start")
	check(start ~= nil and start.id == "x" and start.cwd == "/home/a/webapp", "it starts the same agent in its folder")
	check(start ~= nil and start.label == "fixer" and start.land == "1", "with its label, landing on the agent")
	local r = b.deck.agents.x
	check(r.state == "pending" and r.created_ms == NOW, "the record is pending again from now")
	check(r.exit == nil and r.ended_ms == nil and r.stop_ms == nil, "the old exit is forgotten")
	check(kinds(b.effects) == "save_kv,request:start,render", "the restart saves kv before the request")
	check(deck.agents.x.state == "exited", "reduce leaves the input deck untouched")

	local c = block(deck)
	select(c, { kind = "agent", id = "x" })
	key(c, "enter")
	answer(c, false)
	check(c.ui.notice == "folder not found on devbox", "a gone folder refuses: " .. tostring(c.ui.notice))
	check(request_of(c.effects, "start") == nil and c.deck.agents.x.state == "exited", "no start; still exited")

	local d = block(deck)
	select(d, { kind = "agent", id = "x" })
	key(d, "enter")
	d.deck = Store.clone(d.deck)
	d.deck.agents.x.state = "live" -- it came back on its own meanwhile
	answer(d, true)
	check(request_of(d.effects, "start") == nil and #d.effects == 0, "a stale restart answer starts nothing")
end

-- V picks an agent up and j/k reorder it within its group, saving every step; Enter or V drops it, Esc puts it
-- back where it was picked up. Other groups never change.
do
	local function order(b: Block, gid: string): string
		return table.concat(Model.group_ids(b.deck, gid), ",")
	end
	local deck = sample()
	agent(deck, "x", "g1", 3)
	local b = block(deck)
	select(b, { kind = "agent", id = "b" })
	char(b, "V")
	check(b.ui.mode == "order" and b.ui.target_id == "b", "V picks the selected agent up")
	check(string.sub(b.ui.title or "", 1, 7) == "moving ", "the dock says what is moving: " .. tostring(b.ui.title))
	check(kinds(b.effects) == "render" and b.deck == deck, "picking up changes no data")
	char(b, "k")
	check(order(b, "g1") == "b,a,x", "k moves it up one: " .. order(b, "g1"))
	check(kinds(b.effects) == "save_kv,render", "every step saves")
	check(b.ui.selection ~= nil and b.ui.selection.id == "b", "the selection stays on the moving agent")
	check(order(b, "g2") == "c", "other groups are untouched")
	check(Model.group_ids(deck, "g1")[2] == "b", "reduce leaves the input deck untouched")
	char(b, "k")
	check(order(b, "g1") == "b,a,x" and #b.effects == 0, "at the top of its group it stays, with nothing saved")
	char(b, "G")
	check(order(b, "g1") == "a,x,b", "G sends it to the end of its group: " .. order(b, "g1"))
	key(b, "escape")
	check(order(b, "g1") == "a,b,x" and b.ui.mode == "list", "Esc puts it back where V picked it up")
	check(b.ui.target_id == nil and b.ui.order_at == nil, "and closes the mode")

	select(b, { kind = "agent", id = "a" })
	char(b, "V")
	key(b, "down")
	key(b, "enter")
	check(order(b, "g1") == "b,a,x" and b.ui.mode == "list", "↓ then Enter drops it there")
	char(b, "V")
	char(b, "j")
	char(b, "V")
	check(order(b, "g1") == "b,x,a" and b.ui.mode == "list", "V again drops it too")
	char(b, "j")
	check(b.ui.mode == "list" and order(b, "g1") == "b,x,a", "after the drop, j moves the selection, not the agent")

	-- The agent going away while held ends the mode on the next key, and nothing is saved.
	select(b, { kind = "agent", id = "x" })
	char(b, "V")
	b.deck = Store.clone(b.deck)
	local gone = "x"
	b.deck.agents[gone] = nil
	char(b, "k")
	check(b.ui.mode == "list" and #b.effects == 1 and b.effects[1].kind == "render", "a gone agent ends the mode")
end

-- V on a header reorders the groups the same way: j/k step it, G/Home send it to an end, Esc puts it back, Enter or
-- V drops it. Its agents go with it, untouched; a group swept while held ends the mode.
do
	local function groups(b: Block): string
		local out = {}
		for _, g in b.deck.groups do
			table.insert(out, g.gid)
		end
		return table.concat(out, ",")
	end
	local deck = sample()
	group(deck, "g3", "misc", true)
	local b = block(deck)
	select(b, { kind = "header", gid = "g2" })
	char(b, "V")
	check(b.ui.mode == "order" and b.ui.target_gid == "g2", "V on a header picks the group up")
	check(b.ui.title == "moving group notes", "the dock names the group: " .. tostring(b.ui.title))
	check(kinds(b.effects) == "render" and b.deck == deck, "picking up changes no data")
	char(b, "k")
	check(groups(b) == "g2,g1,g3", "k moves the group up one: " .. groups(b))
	check(kinds(b.effects) == "save_kv,render", "every step saves")
	check(b.ui.selection ~= nil and b.ui.selection.gid == "g2", "the selection stays on the moving header")
	check(table.concat(Model.group_ids(b.deck, "g1"), ",") == "a,b", "its neighbours' agents keep their order")
	check(table.concat(Model.group_ids(b.deck, "g2"), ",") == "c", "and its own agents go with it")
	check(deck.groups[2].gid == "g2", "reduce leaves the input deck untouched")
	char(b, "k")
	check(groups(b) == "g2,g1,g3" and #b.effects == 0, "at the top it stays, with nothing saved")
	char(b, "G")
	check(groups(b) == "g1,g3,g2", "G sends it past a folded group to the end: " .. groups(b))
	key(b, "escape")
	check(groups(b) == "g1,g2,g3" and b.ui.mode == "list", "Esc puts it back where V picked it up")
	check(b.ui.target_gid == nil and b.ui.order_at == nil, "and closes the mode")
	select(b, { kind = "header", gid = "g1" })
	char(b, "V")
	char(b, "j")
	key(b, "enter")
	check(groups(b) == "g2,g1,g3" and b.ui.mode == "list", "j then Enter drops it there")

	char(b, "V")
	b.deck = Store.clone(b.deck)
	table.remove(b.deck.groups, 2)
	char(b, "j")
	check(b.ui.mode == "list" and #b.effects == 1 and b.effects[1].kind == "render", "a swept group ends the mode")
end

-- V refuses while a search or filter hides rows.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	char(b, "!")
	char(b, "V")
	check(
		b.ui.mode == "list" and b.ui.notice == Keys.ORDER_FILTERED,
		"V under a filter refuses: " .. tostring(b.ui.notice)
	)
end

-- Enter on a pending row that has not failed yet refuses.
do
	local deck = sample()
	agent(deck, "p", "g1", 3, { state = "pending", pane = nil })
	local b = block(deck)
	select(b, { kind = "agent", id = "p" })
	key(b, "enter")
	check(b.ui.notice == "starting — wait", "a pending row refuses with starting — wait")
	check(kinds(b.effects) == "render", "the refusal is a notice, not a request")
end

-- On a duplicate row Enter refuses with the notice and no effect.
do
	local b = block(sample())
	b.sets.a = { [1] = true, [9] = true }
	select(b, { kind = "agent", id = "a" })
	key(b, "enter")
	check(b.ui.notice == "duplicate: two panes share this agent", "Enter on a duplicate refuses")
	check(kinds(b.effects) == "render", "the duplicate refusal has no request")
end

-- r on a header refuses; on an agent it sets the label, and an empty label clears it.
do
	local b = block(sample())
	select(b, { kind = "header", gid = "g1" })
	char(b, "r")
	check(b.ui.mode == "list" and b.ui.notice == "select an agent", "r on a header refuses")
	select(b, { kind = "agent", id = "a" })
	char(b, "r")
	check(b.ui.mode == "input" and b.ui.text == "", "r opens the label input with the stored (empty) label")
	type_text(b, "Auth")
	key(b, "enter")
	check(b.deck.agents.a.label == "Auth", "Enter sets the label")
	check(kinds(b.effects) == "save_kv,request:name,render", "a live agent's rename also names its tab")
	local named = request_of(b.effects, "name")
	check(named ~= nil and named.id == "a" and named.label == "Auth", "the name request carries id and label")
	char(b, "r")
	check(b.ui.text == "Auth", "r prefills the current label")
	key(b, "backspace")
	check(b.ui.text == "Aut", "Backspace deletes a character")
	send(b, { kind = "edit", text = "" })
	check(b.ui.text == "", "an edit event replaces the input text")
	key(b, "enter")
	check(b.deck.agents.a.label == nil, "an empty label clears it")
	local cleared = request_of(b.effects, "name")
	check(cleared ~= nil and cleared.label == "", "and the name request clears the tab's name")
end

-- r on a pending agent saves the label but sends no name request: its tab does not exist yet, and `start` names it.
do
	local deck = sample()
	agent(deck, "p", "g1", 3, { state = "pending", pane = nil })
	local b = block(deck)
	select(b, { kind = "agent", id = "p" })
	char(b, "r")
	type_text(b, "soon")
	key(b, "enter")
	check(b.deck.agents.p.label == "soon", "the pending agent's label is saved")
	check(kinds(b.effects) == "save_kv,render", "no name request for a tab that does not exist")
end

local function effect_of(effects: { Keys.Effect }, kind: string): Keys.Effect?
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

-- The deck ids of every stop request, in effect order.
local function stop_ids(effects: { Keys.Effect }): string
	local ids = {}
	for _, e in effects do
		if e.kind == "request" and e.verb == "stop" and e.fields ~= nil then
			table.insert(ids, e.fields.id)
		end
	end
	return table.concat(ids, ",")
end

-- d on a live agent asks first, only y stops it, and the agent's held q message goes with it.
do
	local deck = sample()
	deck.queue.a = { text = "later", at_ms = NOW - 5 }
	deck.session.host = "devbox"
	local b = block(deck)
	select(b, { kind = "agent", id = "a" })
	char(b, "d")
	check(b.ui.mode == "confirm" and b.ui.purpose == "stop" and b.ui.target_id == "a", "d on a live agent asks")
	check(
		b.ui.title == "stop omp 1 on devbox? y/n",
		"the question names the agent and the machine: " .. tostring(b.ui.title)
	)
	check(kinds(b.effects) == "render", "asking stores nothing and sends nothing")
	char(b, "n")
	check(b.ui.mode == "list" and b.deck.agents.a.state == "live", "n closes the question and stops nothing")
	char(b, "d")
	key(b, "escape")
	check(b.ui.mode == "list" and b.deck.agents.a.state == "live", "Esc closes the question and stops nothing")
	char(b, "d")
	char(b, "j")
	check(b.ui.mode == "list" and b.deck.agents.a.state == "live", "any other key cancels too")
	check(b.deck.queue.a ~= nil, "a cancelled d keeps the held message")
	char(b, "d")
	char(b, "y")
	local r = b.deck.agents.a
	check(r.state == "stopping" and r.stop_ms == NOW, "y marks the record stopping and stamps stop_ms")
	check(b.deck.queue.a == nil, "d on a single agent drops its held q message")
	check(kinds(b.effects) == "save_kv,request:stop,render", "kv is saved before the stop request")
	check(stop_ids(b.effects) == "a" and b.ui.mode == "list", "the stop names the deck id; the question is closed")
	char(b, "d")
	check(b.ui.notice == "already stopping" and kinds(b.effects) == "render", "d on a stopping row refuses")
end

-- d on a group header: the group wording, then one stop per live agent; the group stays, deleting.
do
	local deck = sample()
	deck.queue.b = { text = "x", at_ms = NOW }
	local b = block(deck)
	select(b, { kind = "header", gid = "g1" })
	char(b, "d")
	check(b.ui.mode == "confirm" and b.ui.purpose == "group" and b.ui.target_gid == "g1", "d on a header asks")
	check(b.ui.title == "delete group webapp and stop its 2 agents? y/n", "the group wording: " .. tostring(b.ui.title))
	char(b, "y")
	check(kinds(b.effects) == "save_kv,request:stop,request:stop,render", "one stop per live agent, after the save")
	check(stop_ids(b.effects) == "a,b", "each live agent's deck id is named")
	check(b.deck.groups[1].deleting == true, "the group is marked deleting")
	check(b.deck.agents.a.state == "stopping" and b.deck.agents.b.state == "stopping", "its agents are stopping")
	check(b.deck.queue.b == nil, "the group's held messages go")
	check(b.deck.groups[2].deleting == nil and b.deck.agents.c.state == "live", "the other group is untouched")
end

-- d on an empty group removes it at once; on a deleting header it stops the agents that came back to live.
do
	local deck = sample()
	group(deck, "g3", "empty")
	local b = block(deck)
	select(b, { kind = "header", gid = "g3" })
	char(b, "d")
	check(b.ui.mode == "list" and #b.deck.groups == 2, "an empty group goes at once, with no question")
	check(kinds(b.effects) == "save_kv,render", "and sends no request")

	local stuck = sample()
	stuck.groups[1].deleting = true
	stuck.agents.a.state = "stopping"
	local s = block(stuck)
	select(s, { kind = "header", gid = "g1" })
	check(rows(s)[1].stuck == true, "a deleting header with a live agent is stuck")
	char(s, "d")
	check(s.ui.mode == "list", "d on a deleting header asks nothing")
	check(kinds(s.effects) == "save_kv,request:stop,render", "one stop for the agent that is live again")
	check(stop_ids(s.effects) == "b" and s.deck.agents.b.state == "stopping", "only that agent is stopped")
	char(s, "d")
	check(s.ui.notice == "already stopping" and kinds(s.effects) == "render", "nothing live is left to stop")
end

-- d then y on a failed pending row: under 30 s old it is marked cancel with no request, over 30 s it is deleted.
do
	local young = sample()
	agent(young, "p", "g1", 3, {
		state = "pending",
		pane = nil,
		failed = true,
		ended_ms = NOW - 50,
		created_ms = NOW - 10000,
	})
	local b = block(young)
	select(b, { kind = "agent", id = "p" })
	char(b, "d")
	check(b.ui.mode == "confirm" and b.ui.purpose == "drop", "d on a failed pending row asks")
	check(b.ui.title == "remove omp 3 from the list? y/n", "with the removal wording: " .. tostring(b.ui.title))
	char(b, "y")
	check(b.deck.agents.p ~= nil and b.deck.agents.p.cancel == true, "under 30 s old the record is marked cancel")
	check(kinds(b.effects) == "save_kv,render" and request_of(b.effects, "stop") == nil, "with no request effect")
	key(b, "enter")
	check(b.ui.notice == "being removed — wait" and kinds(b.effects) == "render", "Enter on it no longer retries")

	local aged = sample()
	agent(aged, "p", "g1", 3, {
		state = "pending",
		pane = nil,
		failed = true,
		ended_ms = NOW - 50,
		created_ms = NOW - 60000,
	})
	local c = block(aged)
	select(c, { kind = "agent", id = "p" })
	char(c, "d")
	char(c, "y")
	check(c.deck.agents.p == nil, "over 30 s old the record is deleted")
	check(kinds(c.effects) == "save_kv,render", "with no request effect")
end

-- d on an exited row removes it and its held message; on a pending row that has not failed yet it refuses.
do
	local deck = sample()
	agent(deck, "x", "g1", 3, { state = "exited", pane = nil, exit = 0, ended_ms = NOW - 5 })
	deck.queue.x = { text = "never", at_ms = NOW }
	agent(deck, "p", "g1", 4, { state = "pending", pane = nil })
	local b = block(deck)
	select(b, { kind = "agent", id = "x" })
	char(b, "d")
	check(b.ui.purpose == "drop" and b.ui.title == "remove omp 3 from the list? y/n", "the exited-row wording")
	char(b, "y")
	check(b.deck.agents.x == nil and b.deck.queue.x == nil, "y deletes the record and its held message")
	check(kinds(b.effects) == "save_kv,render", "an exited row needs no stop")
	select(b, { kind = "agent", id = "p" })
	char(b, "d")
	check(
		b.ui.notice == "starting — wait" and b.ui.mode == "list",
		"d on a pending row refuses with starting — wait"
	)
	check(kinds(b.effects) == "render", "the refusal is a notice only")
end

-- r, o, q, m and d: a header refuses r, o, q and m with "select an agent".
do
	local b = block(sample())
	select(b, { kind = "header", gid = "g1" })
	for _, c in { "r", "o", "q", "m" } do
		char(b, c)
		check(b.ui.mode == "list" and b.ui.notice == "select an agent", c .. " on a header refuses")
		check(kinds(b.effects):find("save_kv") == nil and next(b.deck.queue) == nil, c .. " on a header stores nothing")
	end
end

-- On a duplicate row o, q and d refuse with the duplicate notice and no effect but the render.
do
	for _, c in { "o", "q", "d" } do
		local b = block(sample())
		b.sets.a = { [1] = true, [9] = true }
		select(b, { kind = "agent", id = "a" })
		char(b, c)
		check(
			b.ui.notice == "duplicate: two panes share this agent" and b.ui.mode == "list",
			c .. " refuses a duplicate"
		)
		check(kinds(b.effects) == "render", c .. " on a duplicate gives only the render")
	end
end

-- o on a live agent: an input line, Enter types the text, and kv is saved with last_send_ms before the write.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	char(b, "o")
	check(b.ui.mode == "input" and b.ui.purpose == "send" and b.ui.title == "send" and b.ui.text == "", "o opens")
	key(b, "enter")
	check(b.ui.notice == "type a message" and b.ui.mode == "input", "an empty message is refused")
	type_text(b, " hello ")
	key(b, "enter")
	check(kinds(b.effects) == "save_kv,write,render", "save_kv comes before the write: " .. kinds(b.effects))
	local w = effect_of(b.effects, "write")
	check(w ~= nil and w.id == "a" and w.text == "hello", "the write names the deck id and the trimmed text")
	check(b.deck.agents.a.last_send_ms == NOW, "the record's last_send_ms is stamped for the guard")
	check(b.ui.mode == "list" and b.deck.queue.a == nil, "the line closes and nothing is held")
end

-- A newline in o input is refused with "single line only", and nothing is typed.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	char(b, "o")
	send(b, { kind = "key", name = "paste", text = "line one\nline two" })
	key(b, "enter")
	check(b.ui.notice == "single line only" and b.ui.mode == "input", "a pasted newline is refused")
	check(effect_of(b.effects, "write") == nil and b.deck.agents.a.last_send_ms == nil, "nothing is typed or stamped")
end

-- o refuses on an asking row (status s = "q"), at the key and again at Enter.
do
	local b = block(sample())
	b.status.a = { { s = "q" } }
	select(b, { kind = "agent", id = "a" })
	char(b, "o")
	check(b.ui.mode == "list" and b.ui.notice == "agent is asking — answer it in its tab", "o refuses on asking")
	check(effect_of(b.effects, "write") == nil, "nothing is typed")
	b.status.a = { { s = "w" } }
	char(b, "o")
	type_text(b, "x")
	b.status.a = { { s = "q" } }
	key(b, "enter")
	check(
		b.ui.notice == "agent is asking — answer it in its tab",
		"and at Enter, when the question appeared meanwhile"
	)
	check(effect_of(b.effects, "write") == nil and b.ui.mode == "list", "still nothing typed")
end

-- o on a missing pane queues the text when nothing is held, and refuses when something is.
do
	local b = block(sample())
	b.sets.a = {}
	select(b, { kind = "agent", id = "a" })
	char(b, "o")
	check(b.ui.mode == "input", "o on a gone pane still opens the line")
	type_text(b, "hi")
	key(b, "enter")
	check(effect_of(b.effects, "write") == nil, "nothing is typed into a gone pane")
	local held = b.deck.queue.a
	check(held ~= nil and held.text == "hi" and held.at_ms == NOW, "the text is kept as the queued message")
	check(b.ui.notice == "pane gone — message queued", "the list says so: " .. tostring(b.ui.notice))
	check(kinds(b.effects) == "save_kv,render", "the held message is saved")
	char(b, "o")
	check(
		b.ui.mode == "list" and b.ui.notice == "a queued message is already waiting — press q to edit it",
		"o refuses"
	)
	check(b.deck.queue.a ~= nil and b.deck.queue.a.text == "hi", "the held message is untouched")

	local late = block(sample())
	late.sets.a = {}
	select(late, { kind = "agent", id = "a" })
	char(late, "o")
	late.deck.queue.a = { text = "first", at_ms = NOW - 9 }
	type_text(late, "second")
	key(late, "enter")
	check(late.ui.notice == "a queued message is already waiting — press q to edit it", "also at Enter")
	check(late.deck.queue.a ~= nil and late.deck.queue.a.text == "first", "the held message is kept, never replaced")
end

-- q: nothing held opens empty; Enter stores one message; a held one prefills, Esc keeps it, Enter replaces it,
-- an empty Enter cancels it, and an empty Enter with nothing held closes the line with no notice and no save.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	char(b, "q")
	check(b.ui.mode == "input" and b.ui.purpose == "queue" and b.ui.title == "queue" and b.ui.text == "", "q opens")
	key(b, "enter")
	check(b.ui.mode == "list" and b.ui.notice == nil and b.deck.queue.a == nil, "empty Enter with nothing held")
	check(kinds(b.effects) == "render", "closes with no save and no notice")
	char(b, "q")
	type_text(b, "later")
	key(b, "enter")
	local held = b.deck.queue.a
	check(held ~= nil and held.text == "later" and held.at_ms == NOW, "Enter stores the message")
	check(kinds(b.effects) == "save_kv,render" and b.ui.notice == nil, "saved, with no notice")
	check(rows(b)[2].queued and rows(b)[2].hold == "waiting for idle", "the row shows it is held")
	char(b, "q")
	check(b.ui.mode == "input" and b.ui.text == "later", "q on a held row prefills the text")
	key(b, "escape")
	check(b.ui.mode == "list" and b.deck.queue.a ~= nil and b.deck.queue.a.text == "later", "Esc keeps it")
	char(b, "q")
	send(b, { kind = "edit", text = "edited" })
	key(b, "enter")
	check(b.deck.queue.a ~= nil and b.deck.queue.a.text == "edited", "Enter with edited text replaces it")
	local n = 0
	for _ in b.deck.queue do
		n += 1
	end
	check(n == 1, "never a second message for one agent")
	char(b, "q")
	send(b, { kind = "edit", text = "" })
	key(b, "enter")
	check(b.deck.queue.a == nil and b.ui.notice == "queued message cancelled", "an empty Enter cancels it")
	check(kinds(b.effects) == "save_kv,render", "the cancel is saved")
end

-- m: the picker starts on the agent's group; Enter moves the agent to the end of the highlighted group.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	char(b, "m")
	check(b.ui.mode == "pick" and b.ui.purpose == "move" and b.ui.pick == "g1", "m opens the picker on its own group")
	char(b, "j")
	char(b, "j")
	check(b.ui.pick == "g2", "j moves the highlight and stops at the last group")
	char(b, "k")
	check(b.ui.pick == "g1", "k moves it back")
	char(b, "G")
	key(b, "end")
	check(b.ui.pick == "g1", "G and End do not move the picker's highlight")
	key(b, "down")
	key(b, "home")
	check(b.ui.pick == "g2", "↓ moves it, Home does not")
	key(b, "up")
	check(b.ui.pick == "g1", "↑ moves it back")
	char(b, "j")
	key(b, "enter")
	local a = b.deck.agents.a
	check(a.gid == "g2" and a.pos == 2, "a is at the end of notes, after c")
	check(b.ui.mode == "list" and b.ui.selection ~= nil and b.ui.selection.gid == "g2", "the selection follows it")
	check(kinds(b.effects) == "save_kv,render", "the move is saved")
	char(b, "m")
	key(b, "escape")
	check(b.ui.mode == "list" and b.deck.agents.a.gid == "g2", "Esc leaves it where it is")
	char(b, "m")
	key(b, "enter")
	check(
		kinds(b.effects) == "render" and b.deck.agents.a.pos == 2,
		"moving to the group it already ends changes nothing"
	)
	select(b, { kind = "agent", id = "c" })
	char(b, "m")
	key(b, "enter")
	check(b.deck.agents.c.pos == 3 and b.deck.agents.a.pos == 2, "within its own group the agent goes to the end")
end

-- `M` (uppercase) is unbound: it opens no picker and changes nothing.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	char(b, "M")
	check(b.ui.mode == "list" and b.ui.purpose == nil and #b.effects == 0, "M does nothing")
	check(b.deck.agents.a.gid == "g1" and b.ui.notice == nil, "no move, no notice")
end

-- The picker holds a gid: a group swept while it is open never shifts the target onto another group.
do
	local deck = sample()
	group(deck, "g3", "docs")
	agent(deck, "d", "g3", 1)
	local b = block(deck)
	select(b, { kind = "agent", id = "d" })
	char(b, "m")
	check(b.ui.pick == "g3", "the picker opens on docs")
	char(b, "k")
	check(b.ui.pick == "g2", "k highlights notes")
	-- webapp (g1) is swept while the picker is open: the groups array shifts under the highlight
	table.remove(b.deck.groups, 1)
	key(b, "enter")
	check(b.deck.agents.d.gid == "g2", "Enter moves the agent to notes, not to the group the old index now names")
	check(b.ui.mode == "list" and b.ui.notice == nil, "and closes the picker")

	local gone = block(sample())
	select(gone, { kind = "agent", id = "a" })
	char(gone, "m")
	char(gone, "j")
	table.remove(gone.deck.groups, 2)
	key(gone, "enter")
	check(gone.ui.notice == "group is gone" and gone.deck.agents.a.gid == "g1", "a highlighted group that went refuses")
end

-- m on a stopping or cancelled record refuses; y after the record changed says so.
do
	local deck = sample()
	deck.agents.a.state = "stopping"
	agent(deck, "p", "g1", 3, { state = "pending", failed = true, cancel = true })
	local b = block(deck)
	select(b, { kind = "agent", id = "a" })
	char(b, "m")
	check(b.ui.mode == "list" and b.ui.notice == "already stopping", "m on a stopping record refuses")
	select(b, { kind = "agent", id = "p" })
	char(b, "m")
	check(b.ui.mode == "list" and b.ui.notice == "being removed — wait", "m on a cancelled record refuses")

	local c = block(sample())
	select(c, { kind = "agent", id = "b" })
	char(c, "d")
	c.deck.agents.b.state = "exited" -- the agent exited while the question was open
	char(c, "y")
	check(c.ui.notice == "nothing done: that row changed" and c.deck.agents.b ~= nil, "y after the row changed says so")
	check(request_of(c.effects, "stop") == nil, "and sends no stop")
end

-- The write effect carries the stamp it replaced; the q line being open is reported by editing().
do
	local deck = sample()
	deck.agents.a.last_send_ms = NOW - 5000
	local b = block(deck)
	select(b, { kind = "agent", id = "a" })
	char(b, "o")
	type_text(b, "hi")
	key(b, "enter")
	local w = effect_of(b.effects, "write")
	check(
		w ~= nil and w.prev == NOW - 5000 and b.deck.agents.a.last_send_ms == NOW,
		"write carries the previous last_send_ms"
	)
	local fresh = block(sample())
	select(fresh, { kind = "agent", id = "b" })
	char(fresh, "o")
	type_text(fresh, "hi")
	key(fresh, "enter")
	local w2 = effect_of(fresh.effects, "write")
	check(w2 ~= nil and w2.prev == nil, "and nil when there was none")

	local e = block(sample())
	select(e, { kind = "agent", id = "a" })
	check(Keys.editing(e.ui) == nil, "no q line open: editing is nil")
	char(e, "q")
	check(Keys.editing(e.ui) == "a", "the q line for a is open")
	key(e, "escape")
	check(Keys.editing(e.ui) == nil, "closed again")
	char(e, "o")
	check(Keys.editing(e.ui) == nil, "an o line is not a q line")
end

-- n and m targeting a deleting group refuse with "group is being deleted".
do
	local deck = sample()
	deck.groups[2].deleting = true
	local b = block(deck)
	select(b, { kind = "header", gid = "g2" })
	char(b, "n")
	check(b.ui.notice == "group is being deleted" and b.ui.mode == "list", "n on a deleting group refuses")
	select(b, { kind = "agent", id = "a" })
	char(b, "m")
	char(b, "j")
	key(b, "enter")
	check(b.ui.notice == "group is being deleted" and b.ui.mode == "list", "m into a deleting group refuses")
	check(b.deck.agents.a.gid == "g1" and kinds(b.effects) == "render", "and moves nothing")
end

-- i toggles show_src, and it is kept in the save() fields.
do
	local b = block(sample())
	char(b, "i")
	check(b.ui.show_src == true, "i turns the overlay on")
	check(Keys.saved_ui(b.ui).show_src == true, "show_src is saved")
	char(b, "i")
	check(b.ui.show_src == false, "i turns it off")
end

-- n starts an agent at once: the group's folder is checked, then a pending record, save_kv, then start.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	char(b, "n")
	check(b.ui.mode == "list" and b.ui.notice == nil, "n asks for nothing")
	check(kinds(b.effects) == "check_folder" and b.deck.agents.abcdefgh == nil, "the group's folder is checked first")
	check(b.effects[1].purpose == "new" and b.effects[1].folder == "/home/a/webapp", "the selected group's folder")
	check(b.effects[1].gid == "g1", "with the group")
	answer(b, true)
	local r = b.deck.agents.abcdefgh
	check(r ~= nil, "the new record is keyed by identity.new_id(rand)")
	check(r.state == "pending" and r.gid == "g1" and r.pos == 3, "pending, in the selected group, at its end")
	check(r.dir == "~/.omp/deck/abcdefgh" and r.cwd == "/home/a/webapp", "dir from the id, cwd from the group")
	check(r.created_ms == NOW, "created now")
	check(kinds(b.effects) == "save_kv,request:start,render", "save_kv comes before the start request")
	local start = request_of(b.effects, "start")
	check(start ~= nil and start.id == "abcdefgh" and start.cwd == "/home/a/webapp", "start names id and cwd")
	check(start ~= nil and start.prompt == nil and start.dir == nil, "start carries no prompt, never dir")
	check(b.ui.mode == "list", "focus stays in the list")

	-- A colliding id is drawn again.
	select(b, { kind = "header", gid = "g2" })
	char(b, "n")
	answer(b, true, rand_from({ 1, 2, 3, 4, 5, 6, 7, 8, 2, 2, 2, 2, 2, 2, 2, 2 }))
	check(b.deck.agents.bbbbbbbb ~= nil and b.deck.agents.bbbbbbbb.gid == "g2", "a taken id is drawn again")
end

-- n with no group yet runs the g flow first, then continues into n.
do
	local b = block(Store.empty())
	char(b, "n")
	check(b.ui.mode == "input" and b.ui.purpose == "folder", "n with no group opens the folder input")
	check(b.ui.text == "/home/a/block", "the folder is prefilled with the block's cwd")
	key(b, "enter")
	check(kinds(b.effects) == "check_folder" and b.ui.purpose == "folder", "the folder is checked first")
	answer(b, true)
	check(b.ui.purpose == "group" and b.ui.text == "block", "then the name, prefilled with the last segment")
	check(kinds(b.effects) == "git_root,render", "confirming the folder asks for its git root")
	check(b.effects[1].folder == "/home/a/block", "git_root names the folder")
	key(b, "enter")
	check(#b.deck.groups == 1 and b.deck.groups[1].name == "block", "the group is created")
	check(b.deck.groups[1].gid == "abcdefgh" and b.deck.groups[1].cwd == "/home/a/block", "gid from new_id")
	check(kinds(b.effects) == "save_kv,check_folder,render", "then n starts at once")
	local n_check = b.effects[2]
	check(
		n_check ~= nil and n_check.gid == "abcdefgh" and n_check.folder == "/home/a/block",
		"in the new group's folder"
	)
	answer(b, true, rand_from({ 1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8 }))
	local start = request_of(b.effects, "start")
	check(start ~= nil and start.cwd == "/home/a/block", "the agent starts in the new group's folder")
	check(b.deck.agents.abcdefgh ~= nil, "the record is stored")
end

-- g: the folder is prefilled from the selected agent; a git_root answer updates the untouched name.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "b" })
	char(b, "g")
	check(b.ui.purpose == "folder" and b.ui.text == "/home/a/wt/b", "g prefills the selected agent's cwd")
	send(b, { kind = "edit", text = "/home/a/wt/webapp-auth/" })
	key(b, "enter")
	check(b.effects[1].folder == "/home/a/wt/webapp-auth", "the checked folder drops the trailing /")
	answer(b, true)
	check(b.ui.purpose == "group" and b.ui.text == "webapp-auth", "the name shows the last segment until git answers")
	send(b, { kind = "git_root", folder = "/home/a/wt/other", common_dir = "/home/a/src/x/.git" })
	check(b.ui.text == "webapp-auth", "an answer for another folder changes nothing")
	send(b, { kind = "git_root", folder = "/home/a/wt/webapp-auth", common_dir = "/home/a/src/webappy/.git" })
	check(b.ui.text == "webappy" and kinds(b.effects) == "render", "the answer updates the untouched name")
	key(b, "enter")
	check(#b.deck.groups == 3 and b.deck.groups[2].name == "webappy", "the new group goes after the selected one")
	check(b.deck.groups[2].cwd == "/home/a/wt/webapp-auth", "it keeps the confirmed folder, trailing / dropped")
	check(b.ui.selection ~= nil and b.ui.selection.gid == b.deck.groups[2].gid, "the new group's header is selected")

	-- A name the user has typed in is not overwritten.
	char(b, "g")
	key(b, "enter")
	answer(b, true)
	char(b, "z")
	send(b, { kind = "git_root", folder = "/home/a/block", common_dir = "/r/repo/.git" })
	check(b.ui.text == "blockz", "an answer never overwrites an edited name")
end

-- A late git_root for a closed input changes nothing.
do
	local b = block(sample())
	char(b, "g")
	key(b, "enter")
	answer(b, true)
	key(b, "escape")
	send(b, { kind = "git_root", folder = "/home/a/block", common_dir = "/home/a/src/webapp/.git" })
	check(b.ui.mode == "list" and b.ui.text == "" and #b.effects == 0, "a late answer changes nothing")
	check(b.deck.groups[1].name == "webapp" and #b.deck.groups == 2, "a late answer adds no group")
end

-- g naming an existing group selects it, adds none and keeps its folder.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "c" })
	char(b, "g")
	send(b, { kind = "edit", text = "/home/a/wt/webapp-auth" })
	key(b, "enter")
	answer(b, true)
	send(b, { kind = "git_root", folder = "/home/a/wt/webapp-auth", common_dir = "/home/a/src/webapp/.git" })
	key(b, "enter")
	check(#b.deck.groups == 2, "no group is added")
	check(b.deck.groups[1].cwd == "/home/a/webapp", "the existing group keeps its stored folder")
	check(b.ui.selection ~= nil and b.ui.selection.kind == "header" and b.ui.selection.gid == "g1", "it is selected")
	check(b.ui.notice == "group webapp already exists — selected", "with the already-exists notice")
	check(request_of(b.effects, "start") == nil and b.ui.mode == "list", "and nothing else happens")
end

-- A g folder with `..` or a character outside [%w_%-./ ] is refused.
do
	for _, folder in { "/home/a/../etc", "/home/a/x;rm", "relative/path", "/home/a/$HOME" } do
		local b = block(sample())
		char(b, "g")
		send(b, { kind = "edit", text = folder })
		key(b, "enter")
		check(b.ui.notice == "folder name not supported", "folder refused: " .. folder)
		check(b.ui.purpose == "folder" and #b.effects == 1, "the folder input stays open: " .. folder)
	end
end

-- (fix/folder-exists) g refuses a folder this machine does not have: the folder line stays open and no group is
-- stored; an existing folder then goes on to the name line.
do
	local deck = sample()
	deck.session.host = "devbox"
	local b = block(deck)
	char(b, "g")
	send(b, { kind = "edit", text = "/home/a/tmp/deck-scratch" })
	key(b, "enter")
	check(kinds(b.effects) == "check_folder" and b.effects[1].purpose == "folder", "g checks the folder first")
	answer(b, false)
	check(b.ui.notice == "folder not found on devbox", "a missing folder is refused: " .. tostring(b.ui.notice))
	check(b.ui.mode == "input" and b.ui.purpose == "folder", "the folder line stays open")
	check(#b.deck.groups == 2 and b.deck == deck and effect_of(b.effects, "git_root") == nil, "no group, no git")
	-- An answer for a folder the line no longer holds does nothing.
	send(b, { kind = "edit", text = "/home/a/notes" })
	send(b, { kind = "folder_checked", purpose = "folder", folder = "/home/a/tmp/deck-scratch", ok = true })
	check(b.ui.purpose == "folder" and #b.effects == 0, "a stale folder answer changes nothing")
	key(b, "enter")
	answer(b, true)
	check(b.ui.purpose == "group" and b.ui.text == "notes", "an existing folder opens the name line")
	check(kinds(b.effects) == "git_root,render", "and asks for its git root")
	key(b, "escape")
	check(#b.deck.groups == 2, "still no group stored")
end

-- (fix/folder-exists) n whose group folder has gone is refused: no record, no save, no start.
do
	local deck = sample()
	deck.session.host = "devbox"
	local b = block(deck)
	select(b, { kind = "header", gid = "g1" })
	char(b, "n")
	check(kinds(b.effects) == "check_folder", "n checks the folder before storing anything")
	answer(b, false)
	check(b.ui.notice == "folder not found on devbox", "n refuses a gone folder: " .. tostring(b.ui.notice))
	check(request_of(b.effects, "start") == nil and kinds(b.effects) == "render", "no start, no save")
	check(b.deck == deck and next(b.deck.agents, nil) ~= nil and b.deck.agents.abcdefgh == nil, "no record")
	-- An answer for a group that no longer exists starts nothing.
	send(b, { kind = "folder_checked", purpose = "new", folder = "/home/a/webapp", gid = "g9", ok = true })
	check(b.deck.agents.abcdefgh == nil and kinds(b.effects) == "render", "a stale n answer starts nothing")
end

-- new_ui restores valid save() fields and drops the rest.
do
	local ui =
		Keys.new_ui({ selection = { kind = "agent", id = "a" }, search = "x", filter = "waiting", show_src = true })
	local saved = Keys.saved_ui(ui)
	check(saved.selection ~= nil and saved.selection.id == "a", "the selection round-trips")
	check(
		saved.search == "x" and saved.filter == "waiting" and saved.show_src,
		"search, filter and show_src round-trip"
	)
	-- A filter saved before the codes were words is a key ("!" then meant running, "&" error): dropped on load, never
	-- read under the key's new meaning. A new key saved by mistake is no code either.
	for _, legacy in { "!", "@", "#", "&", "$" } do
		check(Keys.new_ui({ filter = legacy }).filter == nil, "a legacy saved filter " .. legacy .. " is dropped")
	end
	for _, st in Status.ORDER do
		check(Keys.new_ui({ filter = st.code }).filter == st.code, "a saved " .. st.code .. " filter is restored")
	end
	check(Keys.new_ui({ filter = "stopped" }).filter == nil, "stopped is no filter")
	local junk = Keys.new_ui({ selection = { kind = "agent" }, filter = 4, show_src = "yes" })
	check(junk.selection == nil and junk.filter == nil and junk.show_src == false, "invalid saved fields are dropped")
	check(Keys.new_ui(nil).mode == "list" and Keys.new_ui(nil).em == "A", "a new UI is the list in Esc mode A")
end

-- A move onto a live, non-duplicate agent emits show(id) and marks it pending; other rows emit nothing.
do
	local b = block(sample())
	select(b, { kind = "header", gid = "g1" })
	char(b, "j")
	local shown: Keys.Effect? = nil
	for _, e in b.effects do
		if e.kind == "show" then
			shown = e
		end
	end
	check(shown ~= nil and shown.id == "a", "j onto a live agent emits show(a)")
	check(b.ui.show_pending == "a", "and marks a pending")
	char(b, "j")
	check(b.ui.show_pending == "b" and kinds(b.effects):find("show") ~= nil, "the next move re-marks to b")
	char(b, "k")
	check(b.ui.show_pending == "a", "k back re-marks to a")
	key(b, "g", "G")
	check(b.ui.show_pending == "c", "G onto the last agent shows it")
	key(b, "home")
	check(b.ui.show_pending == nil and kinds(b.effects):find("show") == nil, "Home onto a header emits no show")
	key(b, "end")
	check(b.ui.show_pending == "c", "End onto an agent shows it")
	char(b, "j")
	check(kinds(b.effects):find("show") == nil, "a move that stays put emits no show")
	local d = sample()
	agent(d, "x", "g1", 3, { state = "exited", pane = nil })
	agent(d, "y", "g1", 4, { state = "pending", pane = nil })
	local e = block(d)
	select(e, { kind = "agent", id = "b" })
	char(e, "j")
	check(e.ui.show_pending == nil and kinds(e.effects):find("show") == nil, "an exited row emits no show")
	char(e, "j")
	check(e.ui.show_pending == nil and kinds(e.effects):find("show") == nil, "a pending row emits no show")
	local f = block(sample())
	f.sets.b = { [2] = true, [9] = true }
	select(f, { kind = "agent", id = "a" })
	char(f, "j")
	check(f.ui.show_pending == nil and kinds(f.effects):find("show") == nil, "a duplicate row emits no show")
end

-- show_due asks for the show only while the pause is unbroken.
do
	local b = block(sample())
	select(b, { kind = "header", gid = "g1" })
	char(b, "j")
	send(b, { kind = "show_due", id = "a" })
	local req = request_of(b.effects, "show")
	check(req ~= nil and req.id == "a", "show_due after a move requests show with the id")
	check(b.ui.show_pending == nil, "and consumes the mark")
	send(b, { kind = "show_due", id = "a" })
	check(request_of(b.effects, "show") == nil, "a second show_due does nothing")
	local c = block(sample())
	select(c, { kind = "header", gid = "g1" })
	char(c, "j")
	char(c, "j")
	send(c, { kind = "show_due", id = "a" })
	check(request_of(c.effects, "show") == nil, "a show_due for an earlier id does nothing after a later move")
	local d = block(sample())
	select(d, { kind = "header", gid = "g1" })
	char(d, "j")
	key(d, "enter")
	check(request_of(d.effects, "jump") ~= nil, "Enter in the pause still jumps")
	send(d, { kind = "show_due", id = "a" })
	check(request_of(d.effects, "show") == nil, "and cancels the pending show")
	local e = block(sample())
	select(e, { kind = "header", gid = "g1" })
	char(e, "j")
	key(e, "escape")
	send(e, { kind = "show_due", id = "a" })
	check(request_of(e.effects, "show") == nil, "Esc in the pause cancels the show")
	local f = block(sample())
	select(f, { kind = "header", gid = "g1" })
	char(f, "j")
	char(f, "/")
	send(f, { kind = "show_due", id = "a" })
	check(request_of(f.effects, "show") == nil, "an input opened in the pause cancels the show")
	local g = block(sample())
	select(g, { kind = "header", gid = "g1" })
	char(g, "j")
	char(g, "!")
	send(g, { kind = "show_due", id = "a" })
	check(request_of(g.effects, "show") == nil, "a filter in the pause cancels the show")
	local h = block(sample())
	select(h, { kind = "header", gid = "g1" })
	char(h, "j")
	h.sets.a = {}
	send(h, { kind = "show_due", id = "a" })
	check(request_of(h.effects, "show") == nil, "a row that is no longer live gets no show")
end

-- Clicks: a header click folds or opens the group and selects its header, as Enter does; an agent click selects it
-- as a j/k move onto it would; a row that is not drawn and every mode but list change nothing.
do
	local function click(b: Block, gid: string?, id: string?)
		send(b, { kind = "click", gid = gid, id = id })
	end
	local function selected(b: Block): string
		local sel = b.ui.selection
		if sel == nil then
			return "none"
		end
		return if sel.kind == "header" then "header " .. tostring(sel.gid) else "agent " .. tostring(sel.id)
	end

	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	click(b, "g2")
	check(selected(b) == "header g2", "a header click selects that header")
	check(b.deck.groups[2].folded == true, "and folds its group")
	check(kinds(b.effects) == "save_kv,render", "the fold is saved, and no show is armed on a header")
	click(b, "g2")
	check(selected(b) == "header g2" and b.deck.groups[2].folded == false, "a second click opens it again")
	click(b, "g1")
	check(selected(b) == "header g1" and b.deck.groups[1].folded == true, "a click folds another group")
	click(b, "g1", "a")
	check(selected(b) == "header g1" and #b.effects == 0, "a click on an agent folded away does nothing")
	click(b, "g1")
	check(b.deck.groups[1].folded == false, "the group opens again")

	click(b, "g2", "c")
	check(selected(b) == "agent c", "an agent click selects it")
	local shown = effect_of(b.effects, "show")
	check(shown ~= nil and shown.id == "c" and b.ui.show_pending == "c", "a live agent arms show, as a move does")
	check(b.deck.groups[2].folded == false, "an agent click folds nothing")
	click(b, "g2", "c")
	check(#b.effects == 0 and b.ui.show_pending == "c", "a click on the selected agent keeps the pending show")
	send(b, { kind = "show_due", id = "c" })
	check(request_of(b.effects, "show") ~= nil, "and the show goes out when the pause ends")
	click(b, "g1", "b")
	click(b, "g1")
	send(b, { kind = "show_due", id = "b" })
	check(request_of(b.effects, "show") == nil, "a header click in the pause cancels the show")

	local d = sample()
	agent(d, "x", "g1", 3, { state = "exited", pane = nil })
	local e = block(d)
	click(e, "g1", "x")
	check(selected(e) == "agent x", "an exited agent is selected")
	check(effect_of(e.effects, "show") == nil and e.ui.show_pending == nil, "and arms no show")

	local f = block(sample())
	select(f, { kind = "agent", id = "a" })
	click(f, "g1", "gone")
	check(selected(f) == "agent a" and #f.effects == 0, "a click on an agent that is gone does nothing")
	click(f, "g9")
	check(selected(f) == "agent a" and #f.effects == 0, "a click on a group that is gone does nothing")
	click(f, nil, nil)
	check(#f.effects == 0, "a click naming no row does nothing")
	char(f, "/")
	type_text(f, "notes")
	key(f, "enter")
	click(f, "g1", "a")
	check(selected(f) ~= "agent a" and #f.effects == 0, "a click on a row the search hides does nothing")
	key(f, "escape")

	local g = block(sample())
	select(g, { kind = "agent", id = "a" })
	g.ui.notice = "old news"
	click(g, "g1", "b")
	check(g.ui.notice == nil, "a click clears the notice, as a key does")

	local modes: { { string } } = { { "/", "input" }, { "d", "confirm" }, { "m", "pick" }, { "V", "order" } }
	for _, m in modes do
		local h = block(sample())
		select(h, { kind = "agent", id = "a" })
		char(h, m[1])
		check(h.ui.mode == m[2], m[1] .. " opens " .. m[2] .. " mode")
		local folded = h.deck.groups[2].folded
		click(h, "g2")
		check(
			h.ui.mode == m[2] and selected(h) == "agent a" and h.deck.groups[2].folded == folded and #h.effects == 0,
			"a header click in " .. m[2] .. " mode is ignored"
		)
		click(h, "g2", "c")
		check(selected(h) == "agent a" and #h.effects == 0, "an agent click in " .. m[2] .. " mode is ignored")
	end
end

-- Follow: the last-tab chord landed in an agent's tab, so the highlight moves onto that agent without a `show` (the
-- tab is already in front); a folded-away agent selects its group's header; an agent the search or filter hides, an
-- unknown id and every mode but list leave the selection as it is.
do
	local function follow(b: Block, id: string)
		send(b, { kind = "follow", id = id })
	end
	local function selected(b: Block): string
		local sel = b.ui.selection
		if sel == nil then
			return "none"
		end
		return if sel.kind == "header" then "header " .. tostring(sel.gid) else "agent " .. tostring(sel.id)
	end

	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	follow(b, "c")
	check(selected(b) == "agent c", "follow selects the agent's row")
	check(kinds(b.effects) == "render", "and only renders: no show, no request, no save")
	check(b.ui.show_pending == nil, "and arms no show")
	follow(b, "c")
	check(#b.effects == 0, "following the agent already selected changes nothing")
	follow(b, "gone")
	check(selected(b) == "agent c" and #b.effects == 0, "an unknown id leaves the selection alone")

	local c = block(sample())
	select(c, { kind = "header", gid = "g1" })
	char(c, "j")
	check(c.ui.show_pending == "a", "a move onto a live agent arms its show")
	follow(c, "c")
	check(selected(c) == "agent c" and c.ui.show_pending == nil, "follow in the pause drops the pending show")
	send(c, { kind = "show_due", id = "a" })
	check(request_of(c.effects, "show") == nil, "so the pause ends without switching the tab back")

	local d = sample()
	d.groups[2].folded = true
	local e = block(d)
	select(e, { kind = "agent", id = "a" })
	follow(e, "c")
	check(selected(e) == "header g2", "an agent folded away selects its group's header")
	check(e.deck.groups[2].folded == true and effect_of(e.effects, "save_kv") == nil, "and unfolds nothing")

	local f = block(sample())
	select(f, { kind = "agent", id = "a" })
	char(f, "/")
	type_text(f, "webapp")
	key(f, "enter")
	follow(f, "c")
	check(selected(f) == "agent a" and #f.effects == 0, "an agent the search hides leaves the selection alone")

	local g = sample()
	g.groups[2].folded = true
	local h = block(g)
	select(h, { kind = "agent", id = "a" })
	char(h, "!")
	follow(h, "c")
	check(
		#h.effects == 0 and selected(h) ~= "agent c" and selected(h) ~= "header g2",
		"an agent the filter hides leaves the selection alone"
	)

	local modes: { { string } } = { { "/", "input" }, { "d", "confirm" }, { "m", "pick" }, { "V", "order" } }
	for _, m in modes do
		local k = block(sample())
		select(k, { kind = "agent", id = "a" })
		char(k, m[1])
		follow(k, "c")
		check(
			k.ui.mode == m[2] and selected(k) == "agent a" and #k.effects == 0,
			"follow in " .. m[2] .. " mode is ignored"
		)
	end
	local menu = block(sample())
	select(menu, { kind = "agent", id = "a" })
	key(menu, "/", "?")
	follow(menu, "c")
	check(menu.ui.mode == "menu" and selected(menu) == "agent a", "follow in the ? menu is ignored")
end

-- The `?` menu ------------------------------------------------------------------------------------------------------

-- `?` as Tern sends it (shift+/), and the index of command `k` in the menu.
local function question(b: Block)
	key(b, "/", "?")
end

local function menu_index(k: string): number
	for i, item in Keys.menu_items(nil) do
		if item.key == k then
			return i
		end
	end
	error("no menu item " .. k)
end

-- ? opens the menu on its first command; Esc closes it back to the list with no request (no `back`), and ? closes it
-- too. Nothing else on the list changes.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	question(b)
	check(b.ui.mode == "menu" and b.ui.menu == 1 and b.ui.title == "commands", "? opens the menu")
	check(kinds(b.effects) == "render", "opening the menu only renders")
	key(b, "escape")
	check(b.ui.mode == "list" and b.ui.menu == nil, "Esc closes the menu")
	check(kinds(b.effects) == "render", "Esc in the menu sends no back request")
	question(b)
	question(b)
	check(b.ui.mode == "list" and b.ui.menu == nil, "? again closes the menu")
	check(b.ui.selection ~= nil and b.ui.selection.id == "a", "the selection is untouched")
	question(b)
	send(b, { kind = "key", name = "j", text = "j", ctrl = true })
	check(b.ui.mode == "menu" and b.ui.menu == 1, "a ctrl key does nothing in the menu")
	char(b, "x")
	check(b.ui.mode == "menu" and b.ui.menu == 1 and #b.effects == 0, "a key no command has does nothing")
	send(b, { kind = "click", id = "c" })
	check(b.ui.mode == "menu" and (b.ui.selection :: any).id == "a", "a click does nothing while the menu is open")
end

-- Menu movement: j/↓ down, k/↑ up, End and Home to the ends, stopping at both; the list's selection stays put.
do
	local b = block(sample())
	select(b, { kind = "agent", id = "a" })
	local last = #Keys.menu_items(nil)
	question(b)
	char(b, "k")
	check(b.ui.menu == 1, "k at the first command stays")
	char(b, "j")
	check(b.ui.menu == 2, "j moves down")
	key(b, "down")
	check(b.ui.menu == 3, "↓ moves down")
	key(b, "up")
	check(b.ui.menu == 2, "↑ moves up")
	key(b, "end")
	check(b.ui.menu == last, "End goes to the last command")
	char(b, "j")
	check(b.ui.menu == last, "j at the last command stays")
	key(b, "home")
	check(b.ui.menu == 1, "Home goes to the first command")
	check(b.ui.mode == "menu" and (b.ui.selection :: any).id == "a", "moving in the menu keeps the list's selection")
end

-- A pick runs exactly what the plain key runs: the same mode, prompt, target, filter and effects, whether picked by
-- its own key or by Enter on it. Only `render` is left out, since closing the menu always repaints.
do
	local function state(b: Block): string
		local sel = b.ui.selection
		local effects = {}
		for _, e in b.effects do
			if e.kind ~= "render" then
				table.insert(effects, e)
			end
		end
		return table.concat({
			b.ui.mode,
			b.ui.purpose or "",
			b.ui.title or "",
			b.ui.text,
			b.ui.target_id or "",
			b.ui.target_gid or "",
			b.ui.filter or "",
			tostring(b.ui.show_src),
			b.ui.notice or "",
			if sel ~= nil then sel.kind .. ":" .. (sel.id or sel.gid or "") else "",
			kinds(effects),
		}, "|")
	end
	local function plain(k: string, sel: Model.Selection): string
		local b = block(sample())
		select(b, sel)
		if k == "⏎" then
			key(b, "enter")
		elseif Status.by_key(k) ~= nil then
			key(b, "1", k)
		else
			char(b, k)
		end
		return state(b)
	end
	local function by_key(k: string, sel: Model.Selection): string
		local b = block(sample())
		select(b, sel)
		question(b)
		if Status.by_key(k) ~= nil then
			key(b, "1", k)
		else
			char(b, k)
		end
		return state(b)
	end
	local function by_enter(k: string, sel: Model.Selection): string
		local b = block(sample())
		select(b, sel)
		question(b)
		for _ = 2, menu_index(k) do
			key(b, "down")
		end
		key(b, "enter")
		return state(b)
	end
	local agent_a: Model.Selection = { kind = "agent", id = "a" }
	local header_g1: Model.Selection = { kind = "header", gid = "g1" }
	for _, k in { "o", "q", "r", "m", "V", "d", "n", "g", "/", "!", "@", "#", "$", "0", "i", "J", "K" } do
		local want = plain(k, agent_a)
		check(by_key(k, agent_a) == want, "menu key " .. k .. " runs what " .. k .. " runs: " .. want)
		check(by_enter(k, agent_a) == want, "Enter on " .. k .. " runs what " .. k .. " runs: " .. want)
	end
	for _, k in { "⏎", "j", "k" } do
		local want = plain(k, agent_a)
		check(by_enter(k, agent_a) == want, "Enter on " .. k .. " runs what " .. k .. " runs: " .. want)
	end
	check(string.find(plain("⏎", agent_a), "request:jump", 1, true) ~= nil, "⏎ from the menu jumps to the agent")
	for _, k in { "h", "l", "⏎", "d", "V", "n" } do
		local want = plain(k, header_g1)
		check(by_enter(k, header_g1) == want, "Enter on " .. k .. " on a header runs what " .. k .. " runs")
	end
	for _, k in { "h", "l", "d", "n" } do
		check(by_key(k, header_g1) == plain(k, header_g1), "menu key " .. k .. " on a header runs what it runs")
	end
end

-- A command the selected row does not suit is dimmed, and a pick of it refuses with its notice: the menu stays open
-- on that command and nothing runs.
do
	local b = block(sample())
	select(b, { kind = "header", gid = "g1" })
	local header_row = rows(b)[1]
	for _, item in Keys.menu_items(header_row) do
		local agent_only = item.key == "o" or item.key == "q" or item.key == "r" or item.key == "m"
		check(item.enabled == not agent_only, "on a header " .. item.key .. " enabled is " .. tostring(not agent_only))
	end
	question(b)
	char(b, "o")
	check(b.ui.mode == "menu" and b.ui.notice == Keys.SELECT_AGENT, "o on a header refuses with select an agent")
	check(b.ui.menu == menu_index("o"), "the refusal leaves the highlight on the command")
	check(kinds(b.effects) == "render", "the refusal runs nothing")
	key(b, "home")
	for _ = 2, menu_index("m") do
		key(b, "down")
	end
	key(b, "enter")
	check(b.ui.mode == "menu" and b.ui.notice == Keys.SELECT_AGENT, "Enter on m on a header refuses too")
	key(b, "escape")
	check(b.ui.mode == "list" and b.ui.notice == nil, "Esc then closes the menu")

	local c = block(sample())
	select(c, { kind = "agent", id = "a" })
	question(c)
	char(c, "h")
	check(c.ui.mode == "menu" and c.ui.notice == Keys.SELECT_GROUP, "h on an agent refuses with select a group")
	local deck_before = c.deck
	char(c, "l")
	check(c.ui.notice == Keys.SELECT_GROUP and c.deck == deck_before, "l on an agent refuses and saves nothing")

	local e = block(Store.empty())
	question(e)
	char(e, "d")
	check(e.ui.mode == "menu" and e.ui.notice == Keys.SELECT_ROW, "d with nothing selected refuses with select a row")
	char(e, "n")
	check(e.ui.mode == "input" and e.ui.purpose == "folder", "n with no group still runs, into the g flow")
end

-- The menu's words follow the selected row, and each filter key says what it keeps.
do
	local function item(row: Model.Row?, k: string): Keys.MenuItem
		for _, it in Keys.menu_items(row) do
			if it.key == k then
				return it
			end
		end
		error("no item " .. k)
	end
	check(item(nil, "⏎").label == "go to agent" and item(nil, "d").short == "stop", "an agent's ⏎ goes, d stops")
	local header: any = { kind = "header", gid = "g1", folded = true }
	check(item(header, "⏎").label == "open group" and item(header, "d").label == "delete group", "a folded header")
	header.folded = false
	check(item(header, "⏎").short == "fold", "an open header folds")
	local exited: any = { kind = "agent", gid = "g1", id = "x", state = "exited" }
	check(item(exited, "⏎").short == "restart" and item(exited, "d").short == "remove", "an exited agent")
	local failed: any = { kind = "agent", gid = "g1", id = "x", state = "pending", failed = true }
	check(item(failed, "⏎").short == "retry" and item(failed, "d").short == "remove", "a failed start")
	check(item(nil, "!").label == "error only", "! keeps agents in error")
	check(item(nil, "@").label == "waiting only", "@ keeps waiting agents")
	check(item(nil, "#").label == "running only", "# keeps running agents")
	check(item(nil, "$").label == "idle only", "$ keeps idle agents")
	-- The filter items stand in the one order, together, just before 0.
	local order: { string } = {}
	for _, it in Keys.menu_items(nil) do
		if Status.by_key(it.key) ~= nil or it.key == "0" then
			table.insert(order, it.key)
		end
	end
	check(
		table.concat(order, " ") == "! @ # $ 0",
		"the menu's filters run ! @ # $ then 0: " .. table.concat(order, " ")
	)
	check(menu_index("0") == menu_index("$") + 1 and menu_index("@") == menu_index("!") + 1, "the filters are adjacent")
	local seen: { [string]: boolean } = {}
	for _, it in Keys.menu_items(nil) do
		check(not seen[it.key], "menu key " .. it.key .. " appears once")
		seen[it.key] = true
	end
	check(not seen["?"] and not seen["M"], "the menu offers neither ? nor the unbound M")
end

print("Keys: " .. checks .. " checks passed")
