--!strict
-- Pure key reducer for the list block. No `tern` here:
-- `reduce(ui, deck, rows, event, now, rand) -> (ui, deck, effects)` returns a new UI, the deck (the same table
-- when unchanged) and an ordered list of effects for the host to run.
--
-- Events (the host normalises Tern's input into these):
--   {kind = "key", name, text?, ctrl?, alt?, shift?, meta?}  a key press as Tern sends it (Key; paste arrives as
--     name = "paste" with the pasted text). Tern sends Enter, Tab and Escape to the key handler even with
--     native editing on, so the input line submits on the "enter" key and there is no submit event.
--   {kind = "edit", text}  the open input line's whole new text, for a host that applies Tern's native edit events.
--   {kind = "git_root", folder, common_dir?}  the answer to a `git_root` effect.
--   {kind = "folder_checked", purpose, folder, ok, gid?, id?, text?, cli?}  the answer to a `check_folder` effect: its
--     fields echoed back, plus `ok`, whether `folder` is a directory on this machine.
--   {kind = "show_due", id}  the 120 ms pause after a list-mode move onto agent `id` elapsed.
--   {kind = "click", gid?, id?}  a pointer click on a row of the list (the host maps the clicked node with
--     view.clicked): `id` an agent, else `gid` a group's header. List mode only; every other mode ignores it, so a
--     click never answers a question, submits a line or drops a row being moved.
--   {kind = "tile", text, alt?}  a pointer click on a count tile (the host maps the clicked node with
--     view.clicked_tile): `text` is the tile's filter key, handled exactly as that key pressed in list mode (so a
--     click on the tile whose filter is the only one on clears it, as the key does); with `alt` (Option) held it is
--     the tile's combine key instead, which adds the status to the filter or drops it. List mode only, like `click`.
--   {kind = "follow", id}  the window's last-tab chord landed in the tab of agent `id`, so the list highlights it
--     (list mode only). Never answered with a `show`: the tab is already in front.
-- Effects, run in order:
--   {kind = "save_kv"}  write jumpr.v1 (added on every deck change, before any request or write).
--   {kind = "request", verb, fields}  a jumpr:// request; fields are strings, never a URL.
--   {kind = "write", id, text}  send `text` to the agent with deck id `id` now (`o`). The host stamps the record's
--     `last_send_ms` and saves it before typing (`queue.send`), and picks the pane from its own bindings, so no pane
--     id passes through here.
--   {kind = "git_root", folder}  find the folder's git common dir on this machine.
--   {kind = "check_folder", purpose, folder, gid?, id?, text?, cli?}  check that `folder` is a directory on this
--     machine and answer with `folder_checked`. Purposes: "folder" (the g folder line), "new" (n, with the group
--     `gid`, the first prompt `text` and, from the `N` picker, the agent `cli`; without it, the default agent),
--     "retry" (Enter on a failed pending row `id`) and "restart" (Enter on an exited row `id`); Enter in that row's
--     `o` line asks for either too. Tern starts a pane whose folder is missing in the home directory, and omp then
--     moves itself to a temp dir, so nothing is stored or started in a folder this machine does not have.
--   {kind = "show", id}  arm the 120 ms timer whose firing feeds `show_due` back.
--   {kind = "render"}  something visible changed (the block's key handler returns false without it).

local Agent = require("../shared/agent")
local identity = require("../shared/identity")
local keymap = require("./keymap")
local model = require("./model")
local queue = require("./queue")
local status = require("../shared/status")
local store = require("./store")

local M = {}

export type Selection = model.Selection

-- mode: "list" | "input" | "confirm" | "pick" | "order" | "menu". purpose (input): "search" | "new" | "folder" |
-- "group" | "label" | "send" | "queue"; (confirm): "stop" | "drop" | "group"; (pick): "move" | "kind".
-- text: the open input line. title: its prompt (the question, in confirm). search, filter (a status code from
-- `status.ORDER`, never its key), show_src: list state.
-- notice: a one-line message, cleared by the next key. em: Esc mode from the latest status ("A" | "B").
-- show_pending: the deck id a list-mode move rested on, waiting for the 120 ms pause; every other key clears it.
-- block_cwd: the block's own folder (g prefill). folder, touched, then_n, n_cli: the g flow (the confirmed folder,
-- whether the name line was edited, whether n continues after it, and the agent the `N` picker chose for it).
-- target_gid (n, N, confirm group, V on a header), target_id (r, o, q, d, m, V on an agent). pick: the highlighted
-- group's gid in the `m` picker (a gid, so a group swept while the picker is open cannot shift it onto another), or
-- the highlighted agent in the `N` picker, whose choices are `kinds` (read once, as it opens). order_at: where the row
-- `V` picked up stood (in its group, or among the groups), for Esc to put it back. menu: the highlighted item's index
-- in the `?` menu (its items are always the same, in the same order, so an index stays on the same command).
export type UI = {
	mode: string,
	purpose: string?,
	text: string,
	title: string?,
	selection: Selection?,
	search: string?,
	filter: string?,
	show_src: boolean,
	show_pending: string?,
	notice: string?,
	em: string,
	block_cwd: string?,
	folder: string?,
	touched: boolean,
	then_n: boolean,
	n_cli: string?,
	target_gid: string?,
	target_id: string?,
	pick: string?,
	kinds: { string }?,
	order_at: number?,
	menu: number?,
}

-- The block's save() fields (the block uid is the host's).
export type Saved = { selection: Selection?, search: string?, filter: string?, show_src: boolean }

export type Event = {
	kind: string,
	name: string?,
	text: string?,
	ctrl: boolean?,
	alt: boolean?,
	shift: boolean?,
	meta: boolean?,
	folder: string?,
	common_dir: string?,
	id: string?,
	ok: boolean?,
	purpose: string?,
	gid: string?,
	cli: string?,
}

export type Effect = {
	kind: string,
	verb: string?,
	fields: { [string]: string }?,
	folder: string?,
	id: string?,
	text: string?,
	purpose: string?,
	gid: string?,
	cli: string?,
}

M.DUPLICATE = "duplicate: two panes share this agent"
M.STARTING = "starting — wait"
M.SELECT_AGENT = "select an agent"
M.BAD_FOLDER = "folder name not supported"
M.FOLDER_MISSING = "folder not found on "
M.SINGLE_LINE = "single line only"
M.DELETING = "group is being deleted"
M.ASKING = "agent is asking — answer it in its tab"
function M.HELD(map: keymap.Map): string
	return "a queued message is already waiting — press " .. map.key_of.queue .. " to edit it"
end
M.STOPPING = "already stopping"
M.REMOVING = "being removed — wait"
M.EMPTY_MESSAGE = "type a message"
M.PANE_GONE = "pane gone — message queued"
M.RESTARTING = "restarting — message queued"
M.PICK_QUEUED = "queued — Enter picks its conversation"
M.CHANGED = "nothing done: that row changed"
M.GROUP_GONE = "group is gone"
M.ORDER_FILTERED = "clear the search and filter to reorder"
M.SELECT_GROUP = "select a group"
M.SELECT_ROW = "select a row"

local ID_TRIES = 64

local function valid_selection(sel: any): Selection?
	if type(sel) ~= "table" then
		return nil
	end
	if sel.kind == "agent" and type(sel.id) == "string" then
		return { kind = "agent", id = sel.id, gid = if type(sel.gid) == "string" then sel.gid else nil }
	elseif sel.kind == "header" and type(sel.gid) == "string" then
		return { kind = "header", gid = sel.gid }
	end
	return nil
end

-- A fresh UI, restoring the save() fields when `saved` holds valid ones. A saved filter is a status code; a saved
-- filter from before the codes were words (a key such as "!", which then meant running) is no code, so it is dropped
-- rather than read under the key's new meaning.
function M.new_ui(saved: any?): UI
	local s: any = if type(saved) == "table" then saved else {}
	return {
		mode = "list",
		purpose = nil,
		text = "",
		title = nil,
		selection = valid_selection(s.selection),
		search = if type(s.search) == "string" and s.search ~= "" then s.search else nil,
		filter = status.filter_clean(s.filter),
		show_src = s.show_src == true,
		show_pending = nil,
		notice = nil,
		em = "A",
		block_cwd = nil,
		folder = nil,
		touched = false,
		then_n = false,
		n_cli = nil,
		target_gid = nil,
		target_id = nil,
		pick = nil,
		kinds = nil,
		order_at = nil,
		menu = nil,
	}
end

function M.saved_ui(ui: UI): Saved
	return { selection = ui.selection, search = ui.search, filter = ui.filter, show_src = ui.show_src }
end

-- The deck id whose `q` line is open. The queue sweep leaves that agent's message alone meanwhile, so a cancel or an
-- edit is never raced by a send of the text it is about to replace.
function M.editing(ui: UI): string?
	if ui.mode == "input" and ui.purpose == "queue" then
		return ui.target_id
	end
	return nil
end

-- The answer to a `check_folder` effect, to feed back to `reduce`: its fields, and whether the folder is a
-- directory on this machine.
function M.folder_checked(effect: Effect, ok: boolean): Event
	return {
		kind = "folder_checked",
		purpose = effect.purpose,
		folder = effect.folder,
		ok = ok,
		gid = effect.gid,
		id = effect.id,
		text = effect.text,
		cli = effect.cli,
	}
end

local function same_selection(a: Selection?, b: Selection?): boolean
	if a == nil or b == nil then
		return a == b
	end
	return a.kind == b.kind and a.id == b.id and a.gid == b.gid
end

local function ui_changed(a: UI, b: UI): boolean
	return a.mode ~= b.mode
		or a.purpose ~= b.purpose
		or a.text ~= b.text
		or a.title ~= b.title
		or not same_selection(a.selection, b.selection)
		or a.search ~= b.search
		or a.filter ~= b.filter
		or a.show_src ~= b.show_src
		or a.notice ~= b.notice
		or a.folder ~= b.folder
		or a.then_n ~= b.then_n
		or a.n_cli ~= b.n_cli
		or a.pick ~= b.pick
		or a.menu ~= b.menu
end

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

local function last_segment(path: string): string
	return string.match(path, "([^/]+)$") or path
end

-- The g folder line as a folder: trimmed, without trailing slashes (a lone "/" stays).
local function folder_of(text: string): string
	local folder = trim(text)
	if #folder > 1 then
		folder = string.gsub(folder, "/+$", "")
	end
	return folder
end

-- The character a key types, read from key.text (Tern fills it with the typed character), else from its single-character name.
local function char_of(ev: Event): string?
	if ev.ctrl or ev.alt or ev.meta then
		return nil
	end
	if ev.text ~= nil and ev.text ~= "" then
		return ev.text
	end
	local name = ev.name
	if name ~= nil and #name == 1 then
		return if ev.shift then string.upper(name) else name
	end
	return nil
end

-- Back to list mode from any other (input, confirm or pick), clearing what that mode held.
local function close_mode(ui: UI)
	ui.mode = "list"
	ui.purpose = nil
	ui.text = ""
	ui.title = nil
	ui.folder = nil
	ui.touched = false
	ui.then_n = false
	ui.n_cli = nil
	ui.target_gid = nil
	ui.target_id = nil
	ui.pick = nil
	ui.kinds = nil
	ui.order_at = nil
	ui.menu = nil
end

local function open_input(ui: UI, purpose: string, title: string, text: string)
	ui.mode = "input"
	ui.purpose = purpose
	ui.title = title
	ui.text = text
	ui.touched = false
end

local function find_group(deck: store.Deck, gid: string?): (store.Group?, number?)
	for i, g in deck.groups do
		if g.gid == gid then
			return g, i
		end
	end
	return nil, nil
end

local function fresh_id(rand: (number) -> number, taken: (string) -> boolean): string?
	for _ = 1, ID_TRIES do
		local id = identity.new_id(rand)
		if not taken(id) then
			return id
		end
	end
	return nil
end

-- State threaded through one reduce call.
type Step = {
	ui: UI,
	deck: store.Deck,
	effects: { Effect },
	rows: { model.Row },
	now: number,
	rand: (number) -> number,
	map: keymap.Map,
}

local function save(s: Step)
	table.insert(s.effects, { kind = "save_kv" })
end

local function request(s: Step, verb: string, fields: { [string]: string })
	table.insert(s.effects, { kind = "request", verb = verb, fields = fields })
end

-- The refusal for a folder this machine does not have.
local function folder_missing(s: Step): string
	return M.FOLDER_MISSING .. model.host_label(s.deck)
end

local function selected_row(s: Step): model.Row?
	local i = model.index_of(s.rows, s.ui.selection)
	return if i ~= nil then s.rows[i] else nil
end

local function move_to(s: Step, i: number)
	if #s.rows == 0 then
		return
	end
	local row = s.rows[math.clamp(i, 1, #s.rows)]
	s.ui.selection = model.select_row(row)
end

-- Where a movement key takes a highlight at `at` among `last` items: the mapped down/up actions and ↓/↑ move by
-- one (from nothing highlighted, to the first), the mapped last action and End go to the last, and Home goes to the
-- first. Nil for any other key; the caller clamps.
local function moved(map: keymap.Map, name: string?, ch: string?, at: number?, last: number): number?
	local action = if ch ~= nil then map.action_of[ch] else nil
	if name == "down" or action == "down" then
		return if at ~= nil then at + 1 else 1
	elseif name == "up" or action == "up" then
		return if at ~= nil then at - 1 else 1
	elseif name == "end" or action == "last" then
		return last
	elseif name == "home" then
		return 1
	end
	return nil
end

-- Where the mapped next-group and previous-group actions take the selection at `at` among `rows`: next to the next
-- group's header row, previous to the preceding one, and previous from an agent row to its own group's header first.
-- At the first or last group it stays put, as down/up stop at the list's ends; from nothing highlighted it goes to
-- the first row. Only rows in `rows` count, so folded and hidden agents are passed over. Nil for any other key.
local function group_moved(map: keymap.Map, ch: string?, rows: { model.Row }, at: number?): number?
	local action = if ch ~= nil then map.action_of[ch] else nil
	if action ~= "next_group" and action ~= "prev_group" then
		return nil
	end
	if at == nil then
		return 1
	end
	local step = if action == "next_group" then 1 else -1
	local i = at + step
	while rows[i] ~= nil do
		if rows[i].kind == "header" then
			return i
		end
		i += step
	end
	return at
end

-- A move in list mode just set the selection (`before` is the selection it started from). Landing on a different
-- `live`, non-duplicate agent row emits `show(id)` and marks it pending (that agent's tab comes to the front
-- once no other key follows within the pause); a header, `pending`, `exited`, duplicate or parked row leaves the tab
-- as it is, and so does a move that stayed put. A parked agent has no tab to show: moving past it must not give it one,
-- which Enter does.
local function after_move(s: Step, before: Selection?)
	local row = selected_row(s)
	if same_selection(before, s.ui.selection) then
		return
	end
	if row ~= nil and row.kind == "agent" and row.live and not row.dup and not row.parked and row.id ~= nil then
		s.ui.show_pending = row.id
		table.insert(s.effects, { kind = "show", id = row.id })
	end
end

local function set_folded(s: Step, gid: string, folded: boolean?)
	local g = find_group(s.deck, gid)
	if g == nil then
		return
	end
	local want = if folded == nil then not g.folded else folded
	if g.folded == want then
		return
	end
	local out = store.clone(s.deck)
	local ng = find_group(out, gid)
	if ng ~= nil then
		ng.folded = want
	end
	s.deck = out
	save(s)
end

-- `n` starts the agent at once: the group's folder is checked on this machine before anything is stored or sent.
-- With no group to start in (so no rows either), the g flow runs first, prefilled with the block's folder, then n.
-- `cli` is the agent the `N` picker chose; nil starts the default agent.
local function start_n(s: Step, gid: string?, cli: string?)
	local g = find_group(s.deck, gid)
	if g == nil then
		g = s.deck.groups[1]
	end
	if g == nil then
		open_input(s.ui, "folder", "folder", s.ui.block_cwd or "")
		s.ui.then_n = true
		s.ui.n_cli = cli
		return
	end
	if g.deleting == true then
		close_mode(s.ui)
		s.ui.notice = M.DELETING
		return
	end
	table.insert(s.effects, { kind = "check_folder", purpose = "new", folder = g.cwd, gid = g.gid, cli = cli })
end

-- Where Enter on `id`'s row would start the agent again: "restart" for an exited record, "retry" for a failed
-- start that is not being removed, nil for any other record.
local function start_purpose(r: store.Record): string?
	if r.state == "exited" then
		return "restart"
	end
	if r.state == "pending" and r.failed == true and r.cancel ~= true then
		return "retry"
	end
	return nil
end

-- Starts agent `id` again where Enter on its row would (see `start_purpose`), once its folder is checked on this
-- machine (`retry` and `restart` take the answer). Enter on a row and Enter in its `o` line both start an agent
-- again through here.
local function start_again(s: Step, id: string, r: store.Record): boolean
	local purpose = start_purpose(r)
	if purpose == nil then
		return false
	end
	table.insert(s.effects, { kind = "check_folder", purpose = purpose, folder = r.cwd, id = id })
	return true
end

local function enter_agent(s: Step, row: model.Row)
	local id = row.id :: string
	local r = s.deck.agents[id]
	if r == nil then
		return
	end
	if row.dup then
		s.ui.notice = M.DUPLICATE
		return
	end
	if start_again(s, id, r) then
		return
	end
	if r.state == "pending" then
		s.ui.notice = if r.cancel == true then M.REMOVING else M.STARTING
		return
	end
	request(s, "jump", { id = id })
end

-- Puts the conversation id on a resume request. Every other mode leaves it off: the window reads sid only then.
local function attach_sid(fields: { [string]: string }, mode: string, sid: string?)
	if mode == "resume" and sid ~= nil then
		fields.sid = sid
	end
end

-- The retry Enter asked for, once its folder is checked: still a failed, pending record in the
-- checked folder (anything else changed meanwhile, and nothing is done), and the folder is still there.
-- The start mode is read from the stored record before failed and ended_ms are cleared. A resume also
-- carries that conversation id; other modes do not.
local function retry(s: Step, ev: Event)
	local id = ev.id :: string
	local r = s.deck.agents[id]
	if r == nil or r.state ~= "pending" or r.failed ~= true or r.cancel == true or r.cwd ~= ev.folder then
		return
	end
	if ev.ok ~= true then
		s.ui.notice = folder_missing(s)
		return
	end
	local mode, sid = model.restart_mode(r, id, s.deck)
	local out = store.clone(s.deck)
	local nr = out.agents[id]
	nr.created_ms = s.now
	nr.failed = nil
	nr.ended_ms = nil
	s.deck = out
	save(s)
	local fields: { [string]: string } = { id = id, cwd = nr.cwd, cli = r.cli, mode = mode, label = nr.label or "" }
	attach_sid(fields, mode, sid)
	request(s, "start", fields)
end

-- The restart Enter asked for on an exited row, once its folder is checked: still exited in the checked folder
-- (anything else changed meanwhile, and nothing is done), and the folder is still there. The record goes back to
-- `pending` with the same deck id and the mode chosen from its stored history before any field is cleared; a
-- resume also carries that conversation id. `land` asks the window to focus the new pane, since Enter means "go to it".
local function restart(s: Step, ev: Event)
	local id = ev.id :: string
	local r = s.deck.agents[id]
	if r == nil or r.state ~= "exited" or r.cwd ~= ev.folder then
		return
	end
	if ev.ok ~= true then
		s.ui.notice = folder_missing(s)
		return
	end
	local mode, sid = model.restart_mode(r, id, s.deck)
	local out = store.clone(s.deck)
	local nr = out.agents[id]
	nr.state = "pending"
	nr.created_ms = s.now
	nr.exit = nil
	nr.ended_ms = nil
	nr.stop_ms = nil
	nr.pane = nil
	s.deck = out
	save(s)
	local fields: { [string]: string } =
		{ id = id, cwd = nr.cwd, cli = r.cli, mode = mode, label = nr.label or "", land = "1" }
	attach_sid(fields, mode, sid)
	request(s, "start", fields)
end

-- The mapped send and queue actions on the selected row open a message input. Both refuse on a header ("select an
-- agent") and on a duplicate. Send also refuses on an agent that is asking (typed text would answer its question)
-- and, when the pane is gone, with a message already held (queue edits that one). Queue opens with the held text.
local function message_key(s: Step, row: model.Row?, action: string)
	local ui = s.ui
	if action ~= "send" and action ~= "queue" then
		return
	end
	if row == nil then
		return
	end
	if row.kind ~= "agent" then
		ui.notice = M.SELECT_AGENT
		return
	end
	if row.dup then
		ui.notice = M.DUPLICATE
		return
	end
	local id = row.id :: string
	local held = queue.held(s.deck.queue, id)
	if action == "send" then
		if row.asking == true then
			ui.notice = M.ASKING
			return
		end
		if not row.live and held ~= nil then
			ui.notice = M.HELD(s.map)
			return
		end
		open_input(ui, "send", "send", "")
	else
		open_input(ui, "queue", "queue", if held ~= nil then held.text else "")
	end
	ui.target_id = id
end

-- Deletes group `gid` (the empty group at once, else its agents are stopped): saves, then one `stop` request per
-- agent that was live.
local function delete_group(s: Step, gid: string)
	local out, stops = model.delete_group(s.deck, gid, s.now)
	if out == s.deck then
		return
	end
	s.deck = out
	save(s)
	for _, id in stops do
		request(s, "stop", { id = id })
	end
end

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

-- `d`: a confirm question by row kind, or a refusal. A `deleting` header stops its agents that came back to `live`
-- again with no question, and an empty group goes at once.
local function delete_key(s: Step, row: model.Row?)
	local ui = s.ui
	if row == nil then
		return
	end
	if row.kind == "header" then
		local g = find_group(s.deck, row.gid)
		if g == nil then
			return
		end
		local live = 0
		local ids = model.group_ids(s.deck, g.gid)
		for _, id in ids do
			if s.deck.agents[id].state == "live" then
				live += 1
			end
		end
		if g.deleting == true then
			if live == 0 then
				ui.notice = M.STOPPING
			else
				delete_group(s, g.gid)
			end
		elseif #ids == 0 then
			delete_group(s, g.gid)
		else
			ui.mode = "confirm"
			ui.purpose = "group"
			ui.target_gid = g.gid
			ui.title = if live > 0
				then "delete group " .. g.name .. " and stop its " .. plural(live, "agent") .. "? y/n"
				else "delete group " .. g.name .. "? y/n"
		end
		return
	end
	if row.dup then
		ui.notice = M.DUPLICATE
		return
	end
	local id = row.id :: string
	local r = s.deck.agents[id]
	if r == nil then
		return
	end
	if r.state == "stopping" then
		ui.notice = M.STOPPING
	elseif r.state == "pending" and r.failed ~= true then
		ui.notice = if r.cancel == true then M.REMOVING else M.STARTING
	elseif r.state == "live" then
		ui.mode = "confirm"
		ui.purpose = "stop"
		ui.target_id = id
		ui.title = "stop " .. row.label .. " on " .. model.host_label(s.deck) .. "? y/n"
	else
		ui.mode = "confirm"
		ui.purpose = "drop"
		ui.target_id = id
		ui.title = "remove " .. row.label .. " from the list? y/n"
	end
end

-- `m`: the group picker, on the agent's own group. Refused on a record that is being stopped or removed.
local function move_key(s: Step, row: model.Row?)
	if row == nil then
		return
	end
	if row.kind ~= "agent" then
		s.ui.notice = M.SELECT_AGENT
		return
	end
	local r = s.deck.agents[row.id :: string]
	if r ~= nil and r.state == "stopping" then
		s.ui.notice = M.STOPPING
		return
	end
	if r ~= nil and r.cancel == true then
		s.ui.notice = M.REMOVING
		return
	end
	s.ui.mode = "pick"
	s.ui.purpose = "move"
	s.ui.title = "move to"
	s.ui.target_id = row.id
	s.ui.pick = row.gid
end

-- `N`: the agent picker, on the default agent. Enter starts a new agent of the highlighted kind as `n` would, in the
-- selected row's group. A group that is being deleted refuses, as `n` does.
local function kind_key(s: Step, row: model.Row?)
	local ui = s.ui
	local gid = if row ~= nil then row.gid else nil
	local g = find_group(s.deck, gid)
	if g ~= nil and g.deleting == true then
		ui.notice = M.DELETING
		return
	end
	local default = s.deck.settings.agent
	ui.mode = "pick"
	ui.purpose = "kind"
	ui.title = "new agent"
	ui.kinds = Agent.options(default)
	ui.pick = default
	ui.target_gid = gid
end

-- `V` picks the selected row up to reorder it (`order` mode): an agent within its group (`target_id`), or a group
-- header among the groups (`target_gid`). Refused while a search or filter hides rows (checked first, since the
-- filter may hide every row), since a step past a hidden row would look like nothing happened.
local function order_key(s: Step, row: model.Row?)
	if s.ui.search ~= nil or s.ui.filter ~= nil then
		s.ui.notice = M.ORDER_FILTERED
		return
	end
	if row == nil then
		return
	end
	if row.kind == "header" then
		local _, at = find_group(s.deck, row.gid)
		if at == nil then
			return
		end
		s.ui.mode = "order"
		s.ui.title = "moving group " .. row.label
		s.ui.target_gid = row.gid
		s.ui.order_at = at
		return
	end
	local id = row.id :: string
	local r = s.deck.agents[id]
	if r == nil then
		return
	end
	s.ui.mode = "order"
	s.ui.title = "moving " .. row.label
	s.ui.target_id = id
	s.ui.order_at = table.find(model.group_ids(s.deck, r.gid), id)
end

-- One command in the `?` menu. key: the key it stands for, as the chip shows it. label: what it does on the selected
-- row; short: the one word the legend shows for it, where the legend shows it. enabled: whether the selected row
-- suits it; refusal: the notice a pick of it gets when it does not. event: the key the menu sends to the list, so a
-- pick runs exactly what pressing that key in the list runs.
export type MenuItem = {
	key: string,
	label: string,
	short: string?,
	enabled: boolean,
	refusal: string?,
	event: Event,
}

-- The menu's commands in order: what acts on the selected row first, then starting things, the view, and moving.
-- needs: "row" (any selected row), "agent" or "group" (a selected row of that kind); nil for none. Enter and the
-- status rows carry fixed keys; every list command carries its action id and resolves its current key in menu_items.
type MenuSpec = { action: string?, key: string?, label: string, short: string?, needs: string? }
local MENU: { MenuSpec } = {
	{ key = "⏎", label = "", needs = "row" },
	{ action = "send", label = "send a message", short = "send", needs = "agent" },
	{ action = "queue", label = "queue a message", needs = "agent" },
	{ action = "rename", label = "rename", needs = "agent" },
	{ action = "move", label = "move to another group", needs = "agent" },
	{ action = "reorder", label = "reorder", short = "move", needs = "row" },
	{ action = "stop", label = "", needs = "row" },
	{ action = "new", label = "new agent", short = "new" },
	{ action = "new_kind", label = "new agent, pick kind" },
	{ action = "group", label = "new group", short = "group" },
	{ action = "search", label = "search" },
	-- (per `status.ORDER` entry a "<word> only" item, then per entry an "add or drop <word>" item, go here in its order)
	{ key = "0", label = "every status" },
	{ action = "sources", label = "show status sources" },
	{ action = "settings", label = "settings" },
	{ action = "fold", label = "fold group", needs = "group" },
	{ action = "unfold", label = "open group", needs = "group" },
	{ action = "next_group", label = "next group" },
	{ action = "prev_group", label = "previous group" },
	{ action = "down", label = "down" },
	{ action = "up", label = "up" },
}

-- The status filters sit just before "every status": one "only" item per ranked status in the one priority order,
-- then the keys that add a status to a combined filter or drop it, in the same order.
do
	local at = #MENU + 1
	for i, spec in MENU do
		if spec.key == "0" then
			at = i
		end
	end
	for i, st in status.ORDER do
		table.insert(MENU, at + i - 1, { key = st.key, label = st.word .. " only" })
	end
	for i, st in status.ORDER do
		table.insert(MENU, at + #status.ORDER + i - 1, { key = st.add, label = "add or drop " .. st.word })
	end
end

-- What Enter and stop do on `row`, as the menu's label and the legend's word.
local function row_words(row: model.Row?): (string, string, string, string)
	if row ~= nil and row.kind == "header" then
		if row.folded then
			return "open group", "open", "delete group", "delete"
		end
		return "fold group", "fold", "delete group", "delete"
	elseif row ~= nil and row.state == "exited" then
		return "restart agent", "restart", "remove from the list", "remove"
	elseif row ~= nil and row.state == "pending" and row.failed then
		return "retry the start", "retry", "remove from the list", "remove"
	end
	return "go to agent", "go", "stop agent", "stop"
end

-- The command menu's items for the selected row `row` (nil: none), always in the same action order. Each action's
-- chip and event use the resolved key so picking it is equivalent to pressing that key in the list.
function M.menu_items(row: model.Row?, map: keymap.Map): { MenuItem }
	local enter, enter_short, stop, stop_short = row_words(row)
	local out: { MenuItem } = {}
	for _, spec in MENU do
		local label, short = spec.label, spec.short
		if spec.key == "⏎" then
			label, short = enter, enter_short
		elseif spec.action == "stop" then
			label, short = stop, stop_short
		end
		local refusal: string? = nil
		if spec.needs == "row" and row == nil then
			refusal = M.SELECT_ROW
		elseif spec.needs == "agent" and (row == nil or row.kind ~= "agent") then
			refusal = M.SELECT_AGENT
		elseif spec.needs == "group" and (row == nil or row.kind ~= "header") then
			refusal = M.SELECT_GROUP
		end
		local key = if spec.action ~= nil then map.key_of[spec.action] else spec.key :: string
		local event: Event = if spec.key == "⏎"
			then { kind = "key", name = "enter" }
			else { kind = "key", name = key, text = key }
		table.insert(out, {
			key = key,
			label = label,
			short = short,
			enabled = refusal == nil,
			refusal = refusal,
			event = event,
		})
	end
	return out
end

local function list_key(s: Step, ev: Event)
	local ui = s.ui
	local name = ev.name
	local ch = char_of(ev)
	local action = if ch ~= nil then s.map.action_of[ch] else nil
	local row = selected_row(s)
	local before = ui.selection
	local at = model.index_of(s.rows, before)
	local target = moved(s.map, name, ch, at, #s.rows) or group_moved(s.map, ch, s.rows, at)
	if name == "escape" then
		if ui.em == "B" then
			return
		end
		if ui.search ~= nil then
			ui.search = nil
		elseif ui.filter ~= nil then
			ui.filter = nil
		else
			request(s, "back", {})
		end
	elseif ev.ctrl or ev.alt or ev.meta then
		return
	elseif target ~= nil then
		move_to(s, target)
		after_move(s, before)
	elseif name == "enter" or name == "tab" then
		if row == nil then
			return
		end
		if row.kind == "header" then
			set_folded(s, row.gid, nil)
		elseif name == "enter" then
			enter_agent(s, row)
		end
	elseif status.by_key(ch) ~= nil then
		-- The status filter keys set one filter (or clear it when it is the only one on), even over a combined filter.
		local code = (status.by_key(ch) :: status.Status).code
		ui.filter = if ui.filter == code then nil else code
	elseif status.by_add_key(ch) ~= nil then
		-- The status add keys add their status to the filter or drop it, as an alt+click on its tile does.
		ui.filter = status.filter_toggle(ui.filter, (status.by_add_key(ch) :: status.Status).code)
	elseif ch == "0" then
		ui.filter = nil
	elseif action == "fold" or action == "unfold" then
		if row ~= nil and row.kind == "header" then
			set_folded(s, row.gid, action == "fold")
		end
	elseif action == "search" then
		open_input(ui, "search", "search", ui.search or "")
	elseif action == "menu" then
		ui.mode = "menu"
		ui.title = "commands"
		ui.menu = 1
	elseif action == "sources" then
		ui.show_src = not ui.show_src
	elseif action == "settings" then
		request(s, "settings", {})
	elseif action == "new" then
		start_n(s, if row ~= nil then row.gid else nil)
	elseif action == "new_kind" then
		kind_key(s, row)
	elseif action == "group" then
		local r = if row ~= nil and row.id ~= nil then s.deck.agents[row.id] else nil
		open_input(ui, "folder", "folder", if r ~= nil then r.cwd else (ui.block_cwd or ""))
	elseif action == "stop" then
		delete_key(s, row)
	elseif action == "move" then
		move_key(s, row)
	elseif action == "reorder" then
		order_key(s, row)
	elseif action == "send" or action == "queue" then
		message_key(s, row, action)
	elseif action == "rename" then
		if row == nil then
			return
		end
		if row.kind ~= "agent" then
			ui.notice = M.SELECT_AGENT
			return
		end
		local id = row.id :: string
		local r = s.deck.agents[id]
		if r == nil then
			return
		end
		open_input(ui, "label", "label", r.label or "")
		ui.target_id = id
	end
end

-- A key in the command menu: the mapped down/up actions and arrows move the highlight, Home and End go to the first
-- and last command. Enter picks the highlighted command and a command's own mapped key picks it directly (movement
-- actions move instead). A pick closes the menu and sends its mapped key to the list, so it runs exactly what that
-- key runs there. A command the selected row does not suit refuses with its notice and the menu stays open. Esc or
-- the mapped menu action closes the menu; anything else does nothing.
local function menu_key(s: Step, ev: Event)
	local ui = s.ui
	local name = ev.name
	local ch = char_of(ev)
	local action = if ch ~= nil then s.map.action_of[ch] else nil
	local items = M.menu_items(selected_row(s), s.map)
	local at = math.clamp(ui.menu or 1, 1, #items)
	if name == "escape" or action == "menu" then
		close_mode(ui)
		return
	end
	if ev.ctrl or ev.alt or ev.meta then
		return
	end
	local moving = name == "up"
		or name == "down"
		or name == "home"
		or name == "end"
		or action == "down"
		or action == "up"
	local to = if moving then moved(s.map, name, ch, at, #items) else nil
	if to ~= nil then
		ui.menu = math.clamp(to, 1, #items)
		return
	end
	local pick: number? = nil
	if name == "enter" then
		pick = at
	elseif ch ~= nil then
		for i, item in items do
			if item.key == ch then
				pick = i
				break
			end
		end
	end
	if pick == nil then
		return
	end
	local item = items[pick]
	if not item.enabled then
		ui.menu = pick
		ui.notice = item.refusal
		return
	end
	close_mode(ui)
	list_key(s, item.event)
end

-- The group `gid` an n start aims at, or nil with its notice: a group that is gone or being deleting refuses.
local function n_group(s: Step, gid: string?): store.Group?
	local g = find_group(s.deck, gid)
	if g == nil then
		s.ui.notice = M.GROUP_GONE
		return nil
	end
	if g.deleting == true then
		s.ui.notice = M.DELETING
		return nil
	end
	return g
end

-- The n start, once its group's folder is checked: only while the same group still passes and still owns that
-- folder (anything else changed meanwhile, and nothing is done). A folder that is gone refuses with the notice;
-- nothing is stored or started.
local function new_checked(s: Step, ev: Event)
	local ui = s.ui
	local g = n_group(s, ev.gid)
	if g == nil or g.cwd ~= ev.folder then
		return
	end
	if ev.ok ~= true then
		ui.notice = folder_missing(s)
		return
	end
	local deck = s.deck
	local id = fresh_id(s.rand, function(candidate: string): boolean
		return deck.agents[candidate] ~= nil
	end)
	if id == nil then
		ui.notice = "could not make a new id"
		return
	end
	local pos = 0
	for _, r in deck.agents do
		if r.gid == g.gid and r.pos > pos then
			pos = r.pos
		end
	end
	local cli = ev.cli or deck.settings.agent
	local out = store.clone(deck)
	out.agents[id] = {
		gid = g.gid,
		pos = pos + 1,
		cwd = g.cwd,
		created_ms = s.now,
		state = "pending",
		cli = cli,
	}
	s.deck = out
	ui.selection = { kind = "agent", id = id, gid = g.gid }
	save(s)
	request(s, "start", { id = id, cwd = g.cwd, cli = cli, mode = "new" })
end

-- Enter on the g folder line: a folder name `start` could never take is refused here; any other is checked on
-- this machine before the name line opens.
local function submit_folder(s: Step)
	local folder = folder_of(s.ui.text)
	if not identity.valid_cwd(folder) then
		s.ui.notice = M.BAD_FOLDER
		return
	end
	table.insert(s.effects, { kind = "check_folder", purpose = "folder", folder = folder })
end

-- The g folder, once checked: only while the folder line still holds that folder. A missing folder keeps the line
-- open with the refusal, so no group can store it; a directory opens the name line and asks git for its root.
local function folder_checked(s: Step, ev: Event)
	local ui = s.ui
	local folder = ev.folder :: string
	if ui.mode ~= "input" or ui.purpose ~= "folder" or folder_of(ui.text) ~= folder then
		return
	end
	if ev.ok ~= true then
		ui.notice = folder_missing(s)
		return
	end
	open_input(ui, "group", "group name", last_segment(folder))
	ui.folder = folder
	table.insert(s.effects, { kind = "git_root", folder = folder })
end

local function submit_group(s: Step)
	local ui = s.ui
	local name = trim(ui.text)
	if name == "" then
		ui.notice = "type a group name"
		return
	end
	local folder = ui.folder :: string
	local then_n, n_cli = ui.then_n, ui.n_cli
	for _, g in s.deck.groups do
		if g.name == name then
			close_mode(ui)
			ui.selection = { kind = "header", gid = g.gid }
			ui.notice = "group " .. name .. " already exists — selected"
			if then_n then
				start_n(s, g.gid, n_cli)
			end
			return
		end
	end
	local deck = s.deck
	local gid = fresh_id(s.rand, function(candidate: string): boolean
		return find_group(deck, candidate) ~= nil
	end)
	if gid == nil then
		ui.notice = "could not make a new id"
		return
	end
	local row = selected_row(s)
	local _, at = find_group(deck, if row ~= nil then row.gid else nil)
	local out = store.clone(deck)
	table.insert(out.groups, if at ~= nil then at + 1 else #out.groups + 1, {
		gid = gid,
		name = name,
		cwd = folder,
		folded = false,
	})
	s.deck = out
	close_mode(ui)
	ui.selection = { kind = "header", gid = gid }
	save(s)
	if then_n then
		start_n(s, gid, n_cli)
	end
end

-- Enter on the r line: saves the deck label (the name of record) and asks the window to name the agent's Tern tab
-- with it (an empty label clears the tab's name). A pending agent's tab is named when `start` creates it instead.
local function submit_label(s: Step)
	local ui = s.ui
	local id = ui.target_id
	local label: string? = trim(ui.text)
	if label == "" then
		label = nil
	end
	close_mode(ui)
	local r = if id ~= nil then s.deck.agents[id] else nil
	if id == nil or r == nil or r.label == label then
		return
	end
	local out = store.clone(s.deck)
	out.agents[id].label = label
	s.deck = out
	save(s)
	if r.state == "live" then
		request(s, "name", { id = id, label = label or "" })
	end
end

-- The row of agent `id` among the shown rows (nil when a filter or search hides it now).
local function row_of(s: Step, id: string): model.Row?
	for _, row in s.rows do
		if row.kind == "agent" and row.id == id then
			return row
		end
	end
	return nil
end

-- Enter in the `o` input. Asks the host to send the text now when the agent is live (the host stamps and saves the
-- send before typing). An agent that Enter on its row would start again (exited, or a failed start) is started again
-- the same way, and the text is held as its queued message, which the queue sends once the agent is idle.
-- A start that would open Tern's conversation picker is not started (a typed message could land in the picker):
-- only the message is held, and the notice says Enter picks the conversation. Any other agent whose pane is gone
-- (a start under way or being removed, a stop under way) only holds the text. With a message already held it
-- refuses, and nothing is started.
-- The row is read again here, because status may have changed while the line was open; a row a filter now hides
-- is judged from its record alone.
local function submit_send(s: Step)
	local ui = s.ui
	local id = ui.target_id
	local text = trim(ui.text)
	local r = if id ~= nil then s.deck.agents[id] else nil
	if id == nil or r == nil then
		close_mode(ui)
		ui.notice = "agent is gone"
		return
	end
	if text == "" then
		ui.notice = M.EMPTY_MESSAGE
		return
	end
	local row = row_of(s, id)
	local live = if row ~= nil then row.live else (r.state == "live" and r.pane ~= nil)
	close_mode(ui)
	if row ~= nil and row.dup then
		ui.notice = M.DUPLICATE
	elseif row ~= nil and row.asking == true then
		ui.notice = M.ASKING
	elseif live then
		table.insert(s.effects, { kind = "write", id = id, text = text })
	elseif queue.held(s.deck.queue, id) ~= nil then
		ui.notice = M.HELD(s.map)
	else
		-- The mode the start would use, read from the stored record before anything changes, as `restart` and
		-- `retry` read it: a picker start is not started here, so the held message cannot be typed into the picker.
		local mode = model.restart_mode(r, id, s.deck)
		local out = store.clone(s.deck)
		out.queue = queue.set(s.deck.queue, id, text, s.now)
		s.deck = out
		save(s)
		if start_purpose(r) == nil then
			ui.notice = M.PANE_GONE
		elseif mode == "pick" then
			ui.notice = M.PICK_QUEUED
		else
			start_again(s, id, r)
			ui.notice = M.RESTARTING
		end
	end
end

-- Enter in the `q` input: the text replaces the agent's held message, empty text cancels it ("queued message
-- cancelled"), and empty text with nothing held closes the line with no notice and stores nothing.
local function submit_queue(s: Step)
	local ui = s.ui
	local id = ui.target_id
	local text = trim(ui.text)
	local r = if id ~= nil then s.deck.agents[id] else nil
	close_mode(ui)
	if id == nil or r == nil then
		ui.notice = "agent is gone"
		return
	end
	local row = row_of(s, id)
	if row ~= nil and row.dup then
		ui.notice = M.DUPLICATE
		return
	end
	local q, notice = queue.set(s.deck.queue, id, text, s.now)
	if q ~= s.deck.queue then
		local out = store.clone(s.deck)
		out.queue = q
		s.deck = out
		save(s)
	end
	ui.notice = notice
end

-- A key in the `d` question: only `y` carries it out, anything else (n, Esc, a stray key) closes it. A record that
-- changed while the question was open (the agent exited, an exited one bound again) is left alone, with a notice.
local function confirm_key(s: Step, ev: Event)
	local ui = s.ui
	local purpose, id, gid = ui.purpose, ui.target_id, ui.target_gid
	local ch = char_of(ev)
	close_mode(ui)
	if ch ~= "y" and ch ~= "Y" then
		return
	end
	if purpose == "group" and gid ~= nil then
		delete_group(s, gid)
	elseif purpose == "stop" and id ~= nil then
		local out = model.stop_agent(s.deck, id, s.now)
		if out ~= s.deck then
			s.deck = out
			save(s)
			request(s, "stop", { id = id })
		else
			ui.notice = M.CHANGED
		end
	elseif purpose == "drop" and id ~= nil then
		local out = model.drop_record(s.deck, id, s.now)
		if out ~= s.deck then
			s.deck = out
			save(s)
		else
			ui.notice = M.CHANGED
		end
	end
end

-- Moves the agent to the end of group `target` (nothing when it already is the last agent there).
local function move_agent(s: Step, id: string, target: store.Group)
	local r = s.deck.agents[id]
	if r == nil then
		return
	end
	local last = 0
	for other, o in s.deck.agents do
		if o.gid == target.gid and other ~= id and o.pos > last then
			last = o.pos
		end
	end
	if r.gid == target.gid and r.pos > last then
		return
	end
	local out = store.clone(s.deck)
	out.agents[id].gid = target.gid
	out.agents[id].pos = last + 1
	s.deck = out
	s.ui.selection = { kind = "agent", id = id, gid = target.gid }
	save(s)
end

-- A key in the `N` agent picker: the mapped down/up actions and arrows move the highlight, Enter starts a new agent
-- of that kind as `n` would, and Esc or anything else leaves it unchanged.
local function kind_pick_key(s: Step, ev: Event)
	local ui = s.ui
	local kinds = ui.kinds or {}
	local name = ev.name
	local ch = char_of(ev)
	local last = #kinds
	local at = math.clamp(table.find(kinds, ui.pick or "") or 1, 1, math.max(last, 1))
	local action = if ch ~= nil then s.map.action_of[ch] else nil
	local stepping = name == "up" or name == "down" or action == "down" or action == "up"
	local to = if stepping then moved(s.map, name, ch, at, last) else nil
	if to ~= nil then
		ui.pick = kinds[math.clamp(to, 1, math.max(last, 1))]
	elseif name == "enter" then
		local cli, gid = ui.pick, ui.target_gid
		close_mode(ui)
		-- The group the picker opened on, swept meanwhile, refuses rather than starting in another.
		if gid ~= nil and find_group(s.deck, gid) == nil then
			ui.notice = M.GROUP_GONE
			return
		end
		if cli ~= nil then
			start_n(s, gid, cli)
		end
	elseif name == "escape" then
		close_mode(ui)
	end
end

-- A key in the move picker: the mapped down/up actions and arrows move the highlight (the mapped last action, Home
-- and End are the list's, not the picker's), Enter moves the agent there, and Esc or anything else leaves it
-- unchanged. A group that is being deleted refuses, and one swept meanwhile is gone.
local function pick_key(s: Step, ev: Event)
	if s.ui.purpose == "kind" then
		kind_pick_key(s, ev)
		return
	end
	local ui = s.ui
	local name = ev.name
	local ch = char_of(ev)
	local groups = s.deck.groups
	local last = #groups
	local _, found = find_group(s.deck, ui.pick)
	local at = math.clamp(found or 1, 1, math.max(last, 1))
	local function highlight(i: number)
		local g = groups[math.clamp(i, 1, math.max(last, 1))]
		if g ~= nil then
			ui.pick = g.gid
		end
	end
	local action = if ch ~= nil then s.map.action_of[ch] else nil
	local stepping = name == "up" or name == "down" or action == "down" or action == "up"
	local to = if stepping then moved(s.map, name, ch, at, last) else nil
	if to ~= nil then
		highlight(to)
	elseif name == "enter" then
		local id = ui.target_id
		local target = find_group(s.deck, ui.pick)
		close_mode(ui)
		if id == nil then
			return
		end
		if target == nil then
			ui.notice = M.GROUP_GONE
			return
		end
		if target.deleting == true then
			ui.notice = M.DELETING
			return
		end
		move_agent(s, id, target)
	elseif name == "escape" then
		close_mode(ui)
	end
end

-- `list` with the item at `from` moved to `to` (clamped), or nil when that is where it already is.
local function reordered<T>(list: { T }, from: number, to: number): { T }?
	to = math.clamp(to, 1, #list)
	if to == from then
		return nil
	end
	local out = table.clone(list)
	local item = table.remove(out, from) :: T
	table.insert(out, to, item)
	return out
end

-- Puts agent `id` at index `to` among its group's agents, renumbering the group's `pos` 1..n. Saves when the order
-- changed; nothing when it is already there.
local function place_agent(s: Step, id: string, to: number)
	local r = s.deck.agents[id]
	if r == nil then
		return
	end
	local ids = model.group_ids(s.deck, r.gid)
	local from = table.find(ids, id)
	local order = if from ~= nil then reordered(ids, from, to) else nil
	if order == nil then
		return
	end
	local out = store.clone(s.deck)
	for i, other in order do
		out.agents[other].pos = i
	end
	s.deck = out
	save(s)
end

-- Puts group `gid` at index `to` among the groups (their array order is the list's). Saves when the order changed.
local function place_group(s: Step, gid: string, to: number)
	local _, from = find_group(s.deck, gid)
	if from == nil then
		return
	end
	local out = store.clone(s.deck)
	local order = reordered(out.groups, from, to)
	if order == nil then
		return
	end
	out.groups = order
	s.deck = out
	save(s)
end

-- A key in reorder mode: the mapped down/up actions and arrows step the held row one place (an agent within its
-- group, a group among the groups); the mapped last action, End and Home send it to an end. Enter or the mapped
-- reorder action drops it where it is; Esc puts it back where the action picked it up. Every step saves, as a move
-- does. A row that went away meanwhile ends the mode.
local function order_mode_key(s: Step, ev: Event)
	local ui = s.ui
	local at: number?, count: number
	local place: (number) -> ()
	local gid, id = ui.target_gid, ui.target_id
	if gid ~= nil then
		local _, i = find_group(s.deck, gid)
		if i == nil then
			close_mode(ui)
			return
		end
		at, count = i, #s.deck.groups
		place = function(to: number)
			place_group(s, gid, to)
		end
	else
		local r = if id ~= nil then s.deck.agents[id] else nil
		if id == nil or r == nil then
			close_mode(ui)
			return
		end
		local ids = model.group_ids(s.deck, r.gid)
		at, count = table.find(ids, id), #ids
		place = function(to: number)
			place_agent(s, id, to)
		end
	end
	local name = ev.name
	local ch = char_of(ev)
	local action = if ch ~= nil then s.map.action_of[ch] else nil
	local to = moved(s.map, name, ch, at, count)
	if to ~= nil then
		place(to)
	elseif name == "enter" or action == "reorder" then
		close_mode(ui)
	elseif name == "escape" then
		place(ui.order_at or count)
		close_mode(ui)
	end
end

local function set_text(s: Step, text: string)
	local ui = s.ui
	if ui.text == text then
		return
	end
	ui.text = text
	ui.touched = true
	if ui.purpose == "search" then
		ui.search = if text ~= "" then text else nil
	end
end

-- A key in the open input line: Escape, Enter and Tab. Typing, paste and backspace edit the line at its caret in
-- the host (`input.key`), which sends the whole new line as an `edit` event.
local function input_key(s: Step, ev: Event)
	local ui = s.ui
	local name = ev.name
	if name == "escape" then
		if ui.purpose == "search" then
			ui.search = nil
		end
		close_mode(ui)
	elseif name == "enter" then
		if string.find(ui.text, "[\r\n]") ~= nil then
			ui.notice = M.SINGLE_LINE
			return
		end
		local purpose = ui.purpose
		if purpose == "search" then
			close_mode(ui)
		elseif purpose == "folder" then
			submit_folder(s)
		elseif purpose == "group" then
			submit_group(s)
		elseif purpose == "label" then
			submit_label(s)
		elseif purpose == "send" then
			submit_send(s)
		elseif purpose == "queue" then
			submit_queue(s)
		end
	elseif name == "tab" then
		return
	end
end

local function git_root(s: Step, ev: Event)
	local ui = s.ui
	local folder = ev.folder
	if folder == nil or ui.mode ~= "input" or ui.purpose ~= "group" or ui.folder ~= folder or ui.touched then
		return
	end
	ui.text = model.label_from_common_dir(ev.common_dir, folder)
end

-- `show_due`: the pause after a move elapsed. Asks the window to show the agent's tab only when the mode is still
-- list, the mark is still this id and the selection is still on that agent, `live` and not a duplicate.
local function show_due(s: Step, id: string)
	local pending = s.ui.show_pending
	s.ui.show_pending = nil
	if s.ui.mode ~= "list" or pending ~= id then
		return
	end
	local row = selected_row(s)
	if row == nil or row.kind ~= "agent" or row.id ~= id or not row.live or row.dup then
		return
	end
	request(s, "show", { id = id })
end

-- A click on a row: the selection moves onto it as a j/k move would (a different live agent arms `show`), and a
-- click on a group's header also folds or opens it, as Enter does. A row that is not drawn now (gone, folded away,
-- hidden by a filter or search) and any mode but list change nothing. A click on the row already selected keeps a
-- pending show, since the user is pointing at the agent the pause is about to bring forward.
local function click(s: Step, ev: Event)
	if s.ui.mode ~= "list" then
		return
	end
	local target: Selection? = if ev.id ~= nil
		then { kind = "agent", id = ev.id }
		elseif ev.gid ~= nil then { kind = "header", gid = ev.gid }
		else nil
	local i = model.index_of(s.rows, target)
	if i == nil then
		return
	end
	local before = s.ui.selection
	s.ui.notice = nil
	move_to(s, i)
	if not same_selection(before, s.ui.selection) then
		s.ui.show_pending = nil
		after_move(s, before)
	end
	local row = s.rows[i]
	if row.kind == "header" then
		set_folded(s, row.gid, nil)
	end
end

-- `follow`: the last-tab chord moved focus into agent `id`'s tab, so the highlight moves there too, without a `show`
-- (the tab is already in front, so the window is never asked to switch again). A row drawn now is selected; an agent
-- whose group is folded (no search or filter on) selects that group's header, as the selection of a folded-away agent
-- always does; an agent the search or filter hides, an unknown id and every mode but list leave the selection as it
-- is. A show still waiting for its pause is dropped either way: the chord is the newer move, and the show would
-- switch the tab back.
local function follow(s: Step, id: string)
	if s.ui.mode ~= "list" then
		return
	end
	s.ui.show_pending = nil
	local i = model.index_of(s.rows, { kind = "agent", id = id })
	if i == nil and s.ui.search == nil and s.ui.filter == nil then
		local r = s.deck.agents[id]
		local g = if r ~= nil then find_group(s.deck, r.gid) else nil
		if g ~= nil and g.folded then
			i = model.index_of(s.rows, { kind = "header", gid = g.gid })
		end
	end
	if i ~= nil then
		s.ui.selection = model.select_row(s.rows[i])
	end
end

function M.reduce(
	ui: UI,
	deck: store.Deck,
	rows: { model.Row },
	event: Event,
	now: number,
	rand: (number) -> number
): (UI, store.Deck, { Effect })
	local map = keymap.resolve(deck.settings.keys)
	local s: Step = { ui = table.clone(ui), deck = deck, effects = {}, rows = rows, now = now, rand = rand, map = map }
	if event.kind == "key" then
		s.ui.notice = nil
		s.ui.show_pending = nil
		if s.ui.mode == "input" then
			input_key(s, event)
		elseif s.ui.mode == "list" then
			list_key(s, event)
		elseif s.ui.mode == "confirm" then
			confirm_key(s, event)
		elseif s.ui.mode == "pick" then
			pick_key(s, event)
		elseif s.ui.mode == "order" then
			order_mode_key(s, event)
		elseif s.ui.mode == "menu" then
			menu_key(s, event)
		end
	elseif event.kind == "edit" then
		s.ui.show_pending = nil
		if s.ui.mode == "input" and event.text ~= nil then
			set_text(s, event.text)
		end
	elseif event.kind == "show_due" then
		if event.id ~= nil then
			show_due(s, event.id)
		end
	elseif event.kind == "click" then
		click(s, event)
	elseif event.kind == "tile" then
		local st = status.by_key(event.text)
		if s.ui.mode == "list" and st ~= nil then
			local ch = if event.alt then st.add else st.key
			s.ui.notice = nil
			s.ui.show_pending = nil
			list_key(s, { kind = "key", name = ch, text = ch })
		end
	elseif event.kind == "follow" then
		if event.id ~= nil then
			follow(s, event.id)
		end
	elseif event.kind == "git_root" then
		git_root(s, event)
	elseif event.kind == "folder_checked" and event.folder ~= nil then
		if event.purpose == "folder" then
			folder_checked(s, event)
		elseif event.purpose == "new" then
			new_checked(s, event)
		elseif event.purpose == "retry" and event.id ~= nil then
			retry(s, event)
		elseif event.purpose == "restart" and event.id ~= nil then
			restart(s, event)
		end
	end
	if s.deck ~= deck or ui_changed(ui, s.ui) then
		table.insert(s.effects, { kind = "render" })
	end
	return s.ui, s.deck, s.effects
end

return M
