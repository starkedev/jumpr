--!strict
-- Block rendering with `tern.ui`. Formatting only: the host builds a `Frame` (rows,
-- UI state, status health and ages, banners, the block's width) and this turns it into a BlockView. Rows carry
-- `role` words (`deck.item deck.err deck.sel …`) that styles.css matches with `[data-role~='…']`. Every row is drawn:
-- the block's main region scrolls itself, and the host keeps the selection in view with a reveal (`M.reveal`).

local keys = require("./keys")
local input = require("./input")
local model = require("./model")
local store = require("./store")
local status = require("../shared/status")

local M = {}

export type Frame = {
	ui: keys.UI,
	rows: { model.Row },
	-- the groups in order, for the `M` picker
	groups: { store.Group },
	-- The dock input's caret, in UTF-16 units (nil: at the end).
	cursor: number?,
	-- jumpr.v1.session.host
	host: string?,
	-- the host's connection state from the latest status message
	h: string?,
	-- "ok" | "stale" | "unavailable"
	health: string,
	-- since the last status message
	age_ms: number?,
	-- since each deck id's status last changed (each agent's age, and the `i` overlay)
	row_age: { [string]: number },
	-- how many agents have each status code, over the whole deck (the count tiles)
	tally: { [string]: number },
	-- "bad_p_newer" | "bad_p_older" | nil
	version: string?,
	dupb: boolean,
	readonly: boolean,
	-- store.load's banner (newer data, unreadable data kept as a backup)
	load_banner: string?,
	-- the last failed kv save
	save_error: string?,
	cols: number,
}

-- The dock input's node id (a child keyed "input" of the dock), for the focus op.
M.INPUT_ID = "dock.input"

-- The keys that give the cards stable node ids (a block names a child `<parent id>.<key>`): the cards column, each
-- group's head, and each agent (prefixed, so no deck id can collide with the head's key).
local CARDS_KEY = "cards"
local HEAD_KEY = "head"
local ITEM_KEY = "a-"

-- The action a click on a row sends (`{ev = "action", id = <the row's node id>, act = CLICK}`); the host maps the id
-- back to the row with `M.clicked`. Not one of Tern's own names (toggle, copy, open, zoom, select, activate).
M.CLICK = "row"

-- The styles.css role of a status code: a ranked status's own (`status.ORDER`), else stopped or unknown.
local function code_role(code: string?): string
	local st = status.of(code)
	if st ~= nil then
		return st.role
	end
	return if code == "stopped" then "deck.stopped" else "deck.unknown"
end

-- Formatting -------------------------------------------------------------------------------------------------------

-- `s` cut to `n` cells, ending in "…" when cut.
local function cut(s: string, n: number): string
	if n <= 0 then
		return ""
	end
	local len = utf8.len(s)
	if len == nil then
		return if #s <= n then s else string.sub(s, 1, math.max(n - 1, 0)) .. "…"
	end
	if len <= n then
		return s
	end
	local stop = utf8.offset(s, n)
	if stop == nil then
		return s
	end
	return string.sub(s, 1, stop - 1) .. "…"
end

local function line(text: string, role: string, cols: number): Node
	return tern.ui.node("text", { spans = { cut(text, cols) }, wrap = "none", role = role })
end

-- A message that must be read whole (banners, notices): wraps instead of being cut.
local function para(text: string, role: string): Node
	return tern.ui.node("text", { spans = { text }, wrap = "word", role = role })
end

local function with_role(node: Node, role: string): Node
	local p: { [string]: any } = node.p or {}
	p.role = role
	node.p = p
	return node
end

-- Makes a row's node clickable in list mode (Tern gives it .sf-act and the pointing hand); in any other mode a click
-- does nothing, so the row offers none.
local function clickable(f: Frame, node: Node): Node
	if f.ui.mode == "list" then
		local p: { [string]: any } = node.p or {}
		p.actions = { click = M.CLICK }
		node.p = p
	end
	return node
end

-- Whole seconds, so the text changes (and the block re-renders) at most once a second.
local function seconds(ms: number): string
	return string.format("%ds", math.floor(math.max(ms, 0) / 1000))
end

-- "status unavailable", "status stale" or "status <age>".
function M.status_label(health: string, age_ms: number?): string
	if health == "unavailable" or age_ms == nil then
		return "status unavailable"
	elseif health == "stale" then
		return "status stale"
	end
	return "status " .. seconds(age_ms)
end

local function row_age(f: Frame, row: model.Row): string
	local age = if row.id ~= nil then f.row_age[row.id] else nil
	if age == nil or f.health ~= "ok" then
		return "no status"
	end
	return (row.src or "status") .. " " .. seconds(age)
end

-- The head's parts in order: the host, its connection state, the filter (its key and what it means), the search and
-- the status age. The view draws each part whole and wraps between parts.
function M.head_parts(f: Frame): { string }
	local parts: { string } = { f.host or "unknown host" }
	if f.h ~= nil and f.h ~= "" then
		table.insert(parts, f.h)
	end
	local st = status.of(f.ui.filter)
	if st ~= nil then
		table.insert(parts, "filter " .. st.key .. " " .. st.word)
	end
	if f.ui.search ~= nil and f.ui.mode ~= "input" then
		table.insert(parts, "/" .. f.ui.search)
	end
	table.insert(parts, M.status_label(f.health, f.age_ms))
	return parts
end

local function banners(f: Frame): { string }
	local host = f.host or "this machine"
	local out: { string } = {}
	if f.version == "bad_p_newer" then
		table.insert(out, "the window machine runs a newer Jumpr: update Jumpr on " .. host)
	elseif f.version == "bad_p_older" then
		table.insert(out, "the window machine runs an older Jumpr: update Jumpr on the window machine")
	end
	if f.dupb then
		table.insert(out, "duplicate jumpr list in this tab on " .. host .. ": close one")
	end
	if f.readonly then
		table.insert(out, "read-only data on " .. host)
	end
	if f.load_banner ~= nil then
		table.insert(out, f.load_banner)
	end
	if f.save_error ~= nil then
		table.insert(out, f.save_error)
	end
	return out
end

export type Tile = { code: string, key: string, n: number, word: string, on: boolean }

-- The count tiles' contents, left to right in `status.ORDER` (what needs you first): each status code, its filter
-- key, how many agents have it, what it means, and whether its filter is on. The key shows on the tile beside the
-- count, so the tile says what each key means.
function M.tile_parts(tally: { [string]: number }, filter: string?): { Tile }
	local out: { Tile } = {}
	for _, st in status.ORDER do
		table.insert(
			out,
			{ code = st.code, key = st.key, n = tally[st.code] or 0, word = st.word, on = filter == st.code }
		)
	end
	return out
end

-- An age as one short unit: 12s, 4m, 3h, 2d.
local function short_age(ms: number): string
	local s = math.floor(math.max(ms, 0) / 1000)
	if s < 60 then
		return string.format("%ds", s)
	elseif s < 3600 then
		return string.format("%dm", math.floor(s / 60))
	elseif s < 86400 then
		return string.format("%dh", math.floor(s / 3600))
	end
	return string.format("%dd", math.floor(s / 86400))
end

-- How long the agent has been in its status, when the status is fresh.
local function age_of(f: Frame, row: model.Row): string?
	local age = if row.id ~= nil then f.row_age[row.id] else nil
	if age == nil or f.health ~= "ok" then
		return nil
	end
	return short_age(age)
end

-- Every time-dependent text the view shows (the header's status age, each agent's age, and with `i` each row's
-- source age): the host re-renders on its timer only when this changes.
function M.clock_key(f: Frame): string
	local parts = { M.status_label(f.health, f.age_ms), f.version or "" }
	for _, row in f.rows do
		if row.kind == "agent" then
			table.insert(parts, age_of(f, row) or "")
			if f.ui.show_src then
				table.insert(parts, row_age(f, row))
			end
		end
	end
	return table.concat(parts, "|")
end

-- The pill on an agent's first line: its record state when that says more than the status does.
local function pill(row: model.Row): (string, string)
	if row.state == "pending" then
		if row.cancel then
			return "removing", "deck.pending"
		elseif row.failed then
			return "failed", "deck.err"
		end
		return "starting", "deck.pending"
	elseif row.state == "stopping" then
		return "stopping", "deck.pending"
	elseif row.state == "exited" and row.code ~= "error" then
		-- A non-zero exit is an error: it keeps the red error pill, as the tiles count it.
		return "exited", "deck.stopped"
	end
	local code = row.code or "unknown"
	local st = status.of(code)
	return if st ~= nil then st.word else code, code_role(code)
end

-- The last path segment of `path`.
local function base(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

-- An agent's dim second line: how long in this state, its folder when it is not the group's, and anything
-- waiting on it (a failed start, a held message, a duplicate).
local function meta(f: Frame, row: model.Row, group_cwd: string?): string
	local parts: { string } = {}
	local age = age_of(f, row)
	if age ~= nil then
		table.insert(parts, age)
	end
	if row.cwd ~= nil and row.cwd ~= group_cwd then
		table.insert(parts, base(row.cwd))
	end
	if row.state == "exited" then
		table.insert(parts, "⏎ restarts")
	elseif row.state == "pending" and row.failed and not row.cancel then
		table.insert(parts, "⏎ retries")
	end
	if row.dup then
		table.insert(parts, "duplicate")
	end
	if row.queued then
		table.insert(parts, "⧗ " .. (row.hold or "queued"))
	end
	if f.ui.show_src then
		table.insert(parts, row_age(f, row))
	end
	return table.concat(parts, " · ")
end

-- A leaf of text. Inside an `el` tree only `el` children render (a `text` node there draws empty), so every leaf of
-- the tiles, cards and legend is an `el` span.
local function text_node(text: string, role: string): Node
	return tern.ui.el("span", { text = text, role = role })
end

-- A div with role words, keyed when its node needs a stable id.
local function div(role: string, children: { Node }, key: string?): Node
	return tern.ui.el("div", { role = role, key = key }, children)
end

-- The head line: each part whole, a "·" after every part but the last, wrapping between parts (never cut).
local function head(f: Frame): Node
	local parts = M.head_parts(f)
	local out: { Node } = {}
	for i, part in parts do
		table.insert(out, text_node(if i < #parts then part .. " ·" else part, "deck.head-part"))
	end
	return div("deck.head", out, "head")
end

local function moving(f: Frame, row: model.Row): boolean
	if f.ui.mode ~= "order" then
		return false
	end
	if row.kind == "agent" then
		return row.id ~= nil and row.id == f.ui.target_id
	end
	return f.ui.target_gid ~= nil and row.gid == f.ui.target_gid
end

local function state_words(f: Frame, row: model.Row, selected: boolean, extra: string): string
	local words = { extra }
	if selected then
		table.insert(words, "deck.sel")
	end
	if moving(f, row) then
		table.insert(words, "deck.moving")
	end
	return table.concat(words, " ")
end

-- The count tiles: every agent on the deck, folded and filtered groups included. Each shows its filter key beside
-- the count and the word under it; the tile whose filter is on is marked.
local function tiles(f: Frame): Node
	local out: { Node } = {}
	for _, t in M.tile_parts(f.tally, f.ui.filter) do
		local role = "deck.tile "
			.. code_role(t.code)
			.. (if t.n == 0 then " deck.zero" else "")
			.. (if t.on then " deck.on" else "")
		table.insert(
			out,
			div(role, {
				div("deck.tile-top", {
					text_node(t.key, "deck.tile-key"),
					text_node(tostring(t.n), "deck.tile-n"),
				}),
				text_node(t.word, "deck.tile-label"),
			})
		)
	end
	return div("deck.tiles", out)
end

-- A group card's head: fold arrow and name, then one dot and count per status its agents are in.
local function card_head(f: Frame, row: model.Row, selected: boolean): Node
	local name = (if row.folded then "▸ " else "▾ ") .. row.label
	local children: { Node } = { text_node(name, "deck.card-name") }
	if row.stuck then
		table.insert(children, text_node("delete stuck — d retries", "deck.card-note deck.err"))
	elseif row.deleting then
		table.insert(children, text_node("deleting", "deck.card-note"))
	end
	local dots: { Node } = {}
	local shown = 0
	for _, st in status.ORDER do
		local n = if row.tally ~= nil then row.tally[st.code] else nil
		if n ~= nil and n > 0 then
			shown += n
			table.insert(dots, text_node("● " .. tostring(n), "deck.dot " .. st.role))
		end
	end
	-- Stopped agents, and every agent while status is stale, have no tile: a hollow dot keeps the group's count.
	local rest = (row.count or 0) - shown
	if rest > 0 then
		table.insert(dots, text_node("○ " .. tostring(rest), "deck.dot deck.unknown"))
	end
	table.insert(children, div("deck.dots", dots))
	return clickable(f, div(state_words(f, row, selected, "deck.card-head"), children, HEAD_KEY))
end

-- One agent in a card: status dot, label and pill on the first line, the dim meta line under it.
local function agent_item(f: Frame, row: model.Row, selected: boolean, group_cwd: string?): Node
	local word, word_role = pill(row)
	local dot_role = code_role(row.code)
	local extra = "deck.item"
	if row.dim then
		extra ..= " deck.dim"
	end
	if row.dup then
		extra ..= " deck.dup"
	end
	local first = div("deck.item-top", {
		text_node("●", "deck.dot " .. dot_role),
		text_node(cut(row.label, math.max(f.cols - 14, 4)), "deck.item-label"),
		text_node(word, "deck.pill " .. word_role),
	})
	local children = { first }
	local m = meta(f, row, group_cwd)
	if m ~= "" then
		table.insert(children, text_node(cut(m, math.max(f.cols - 4, 4)), "deck.item-meta"))
	end
	return clickable(
		f,
		div(state_words(f, row, selected, extra), children, if row.id ~= nil then ITEM_KEY .. row.id else nil)
	)
end

-- One card per group, every row drawn: the block's main region scrolls, so nothing is windowed here.
local function cards(f: Frame, sel: number?): { Node }
	local cwd_of: { [string]: string } = {}
	for _, g in f.groups do
		cwd_of[g.gid] = g.cwd
	end
	local out: { Node } = {}
	local current: { Node }? = nil
	local gid: string? = nil
	local function close()
		if current ~= nil then
			table.insert(out, div("deck.card", current, gid))
			current = nil
		end
	end
	for i, row in f.rows do
		if row.kind == "header" then
			close()
			gid = row.gid
			current = { card_head(f, row, i == sel) }
		else
			if current == nil then
				gid = row.gid
				current = {}
			end
			table.insert(current :: { Node }, agent_item(f, row, i == sel, cwd_of[row.gid]))
		end
	end
	close()
	return out
end

-- The id Tern gives the selected row's node: `main.cards.<gid>.head` for a group, `main.cards.<gid>.a-<id>` for an
-- agent (the keys `cards`, `card_head` and `agent_item` set). Nil when the selection is not on a drawn row.
function M.node_id(rows: { model.Row }, selection: model.Selection?): string?
	local i = model.index_of(rows, selection)
	if i == nil then
		return nil
	end
	local row = rows[i]
	local base = "main." .. CARDS_KEY .. "." .. row.gid .. "."
	if row.kind == "header" then
		return base .. HEAD_KEY
	end
	return if row.id ~= nil then base .. ITEM_KEY .. row.id else nil
end

-- The row a clicked node id names, the inverse of `node_id`: `{gid}` for a group's head, `{id, gid}` for an agent.
-- Nil for any other id. Deck ids and group ids never hold a ".", so the id splits at its dots.
function M.clicked(node: string?): { gid: string, id: string? }?
	if node == nil then
		return nil
	end
	local gid, key = string.match(node, "^main%." .. CARDS_KEY .. "%.([^%.]+)%.([^%.]+)$")
	if gid == nil or key == nil then
		return nil
	end
	if key == HEAD_KEY then
		return { gid = gid }
	end
	if #key > #ITEM_KEY and string.sub(key, 1, #ITEM_KEY) == ITEM_KEY then
		return { gid = gid, id = string.sub(key, #ITEM_KEY + 1) }
	end
	return nil
end

-- Whether a view should bring the selection into view. `last` is the key the previous call returned for this copy;
-- the selection is revealed when it is on another node or at another place in the list than then, or always when
-- `force` (a new or resized copy). Returns the node id to reveal (nil: none) and the key to keep for the next call,
-- so a re-render that moves nothing (the status clock) never scrolls the list away from where the user put it.
function M.reveal(rows: { model.Row }, selection: model.Selection?, last: string?, force: boolean): (string?, string?)
	local id = M.node_id(rows, selection)
	if id == nil then
		return nil, nil
	end
	local key = id .. "#" .. tostring(model.index_of(rows, selection))
	if force or key ~= last then
		return id, key
	end
	return nil, key
end

-- The keys the legend shows, by the selected row's kind; `?` and the menu cover the rest.
local LEGEND_HEADER: { string } = { "⏎", "n", "g", "d" }
local LEGEND_AGENT: { string } = { "⏎", "n", "o", "d" }

-- A key chip and its word.
local function chip(out: { Node }, key: string, word: string)
	table.insert(out, text_node(key, "deck.key"))
	table.insert(out, text_node(word, "deck.key-label"))
end

-- The key legend under the list: what the main keys do on the selected row, then `?` for every other command. The
-- words are the `?` menu's own (keys.menu_items), so the two never disagree.
local function legend(f: Frame): Node
	local rows = f.rows
	local sel = model.index_of(rows, f.ui.selection)
	local row = if sel ~= nil then rows[sel] else nil
	local shown: { string } = if row ~= nil and row.kind == "header" then LEGEND_HEADER else LEGEND_AGENT
	local word: { [string]: string } = {}
	for _, item in keys.menu_items(row) do
		word[item.key] = item.short or item.label
	end
	-- Our own chips, not the `key` span style: that one uppercases, and case matters (the menu's V is shift+v).
	local out: { Node } = {}
	for _, key in shown do
		chip(out, key, word[key])
	end
	chip(out, "?", "menu")
	return div("deck.legend", out)
end

-- The most groups the `M` picker, and the most commands the `?` menu, draw at once.
local PICK_ROWS = 8
local MENU_ROWS = 10

-- The first and last of `total` items a list of at most `rows` lines draws, keeping item `at` (clamped) in view, and
-- that index.
local function window(total: number, at: number, rows: number): (number, number, number)
	local sel = math.clamp(at, 1, math.max(total, 1))
	local first = 1
	if total > rows then
		first = math.clamp(sel - math.floor(rows / 2), 1, total - rows + 1)
	end
	return first, math.min(total, first + rows - 1), sel
end

-- The picker's window. The highlight is a gid (the first group when it is gone).
local function pick_window(f: Frame): (number, number, number)
	local at = 1
	for i, g in f.groups do
		if g.gid == f.ui.pick then
			at = i
		end
	end
	return window(#f.groups, at, PICK_ROWS)
end

-- The `?` menu's title: its name and where the highlight is, kept short so a narrow pane never cuts it.
function M.menu_title(title: string?, at: number, total: number): string
	return string.format("%s %d/%d", title or "commands", at, total)
end

-- The `?` menu's keys, drawn dim under its title and wrapped, never cut; one line from 29 columns.
M.MENU_HINT = "j/k · Enter or key runs · Esc"

-- The `?` menu: a title, its keys, then a window of commands, each a key chip and what it does on the selected
-- row; the highlighted one marked, one the row does not suit dimmed.
local function menu(f: Frame): { Node }
	local sel = model.index_of(f.rows, f.ui.selection)
	local row: model.Row? = if sel ~= nil then f.rows[sel] else nil
	local items = keys.menu_items(row)
	local first, last, at = window(#items, f.ui.menu or 1, MENU_ROWS)
	local out: { Node } = {
		line(M.menu_title(f.ui.title, at, #items), "deck.pick-title", f.cols),
		para(M.MENU_HINT, "deck.menu-hint"),
	}
	local list: { Node } = {}
	for i = first, last do
		local item = items[i]
		local role = "deck.menu-item"
			.. (if i == at then " deck.sel" else "")
			.. (if item.enabled then "" else " deck.off")
		table.insert(
			list,
			div(role, {
				text_node(item.key, "deck.key"),
				text_node(cut(item.label, math.max(f.cols - 6, 4)), "deck.menu-label"),
			})
		)
	end
	table.insert(out, div("deck.menu", list))
	return out
end

local function dock(f: Frame): Node?
	local ui = f.ui
	local children: { Node } = {}
	if ui.mode == "input" then
		table.insert(
			children,
			tern.ui.node("input", {
				key = "input",
				text = ui.text,
				cursor = input.clamp_cursor(ui.text, f.cursor),
				prompt = { tern.ui.span((ui.title or "input") .. " ", "muted") },
				role = "deck.input",
			})
		)
	end
	if ui.mode == "confirm" and ui.title ~= nil then
		table.insert(children, para(ui.title, "deck.confirm"))
	end
	if ui.mode == "pick" then
		local first, last, sel = pick_window(f)
		table.insert(children, line((ui.title or "pick") .. " (j/k, Enter, Esc)", "deck.pick-title", f.cols))
		for i = first, last do
			local g = f.groups[i]
			local text = (if i == sel then "› " else "  ")
				.. g.name
				.. (if g.deleting == true then " (deleting)" else "")
			table.insert(children, line(text, if i == sel then "deck.pick deck.sel" else "deck.pick", f.cols))
		end
	end
	if ui.mode == "menu" then
		for _, node in menu(f) do
			table.insert(children, node)
		end
	end
	if ui.mode == "order" then
		table.insert(
			children,
			line((ui.title or "moving") .. " (j/k, Enter or V drops, Esc puts back)", "deck.pick-title", f.cols)
		)
	end
	if ui.mode == "list" and (ui.notice == nil or ui.notice == "") then
		table.insert(children, legend(f))
	end
	if ui.notice ~= nil and ui.notice ~= "" then
		table.insert(children, para(ui.notice, "deck.notice"))
	end
	if #children == 0 then
		return nil
	end
	return with_role(tern.ui.col(children), "deck.dock")
end

function M.view(f: Frame): BlockView
	local cols = math.max(f.cols, 1)
	local top: { Node } = { head(f), tiles(f) }
	for _, text in banners(f) do
		table.insert(top, para(text, "deck.banner"))
	end
	local rows = f.rows
	if #rows == 0 then
		local empty = if f.ui.filter ~= nil or f.ui.search ~= nil then "nothing matches" else "no groups: g adds one"
		table.insert(top, line(empty, "deck.empty", cols))
	else
		table.insert(top, div("deck.cards", cards(f, model.index_of(rows, f.ui.selection)), CARDS_KEY))
	end
	return { main = with_role(tern.ui.col(top), "deck.main"), dock = dock(f) }
end

-- The pane title.
function M.title(host: string?): string
	if host == nil or host == "" then
		return "Jumpr"
	end
	return "Jumpr · " .. host
end

return M
