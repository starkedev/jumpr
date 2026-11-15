--!strict
-- View formatting and key-bound hint checks under the plain Luau test harness.

local Keymap = require("../lib/host/keymap")
local Status = require("../lib/shared/status")
local View = require("../lib/host/view")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local DEFAULT_MAP = Keymap.resolve({})

local function frame(fields: { [string]: any }, ui: { [string]: any }?): any
	local f: { [string]: any } = {
		health = "ok",
		age_ms = 3000,
		map = DEFAULT_MAP,
		ui = ui or { mode = "list" },
	}
	for k, v in fields do
		f[k] = v
	end
	return f
end

local function same(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for i, v in a do
		if b[i] ~= v then
			return false
		end
	end
	return true
end

-- The head's parts: host, connection, filter, search, status, each whole and in that order.
check(same(View.head_parts(frame({ host = "me@devbox" })), { "me@devbox", "status 3s" }), "host and status alone")
check(
	same(View.head_parts(frame({ host = "me@devbox", h = "connected" })), { "me@devbox", "connected", "status 3s" }),
	"the connection state follows the host"
)
check(
	same(View.head_parts(frame({ host = "h", h = "" })), { "h", "status 3s" }),
	"an empty connection state is left out"
)
check(
	same(
		View.head_parts(frame({ host = "h", h = "connected" }, { mode = "list", filter = "waiting", search = "bra" })),
		{ "h", "connected", "filter @ waiting", "/bra", "status 3s" }
	),
	"filter then search, before the status; the filter says what its key keeps"
)
check(
	same(View.head_parts(frame({ host = "h" }, { mode = "input", search = "bra" })), { "h", "status 3s" }),
	"the search is not repeated while its input line is open"
)
check(View.head_parts(frame({}))[1] == "unknown host", "no host names it unknown")
check(same(View.head_parts(frame({ host = "h", health = "stale" })), { "h", "status stale" }), "a stale status says so")
local long = View.head_parts(frame({ host = "a-very-long-host-name-that-overflows-a-narrow-pane", h = "connected" }))
check(long[1] == "a-very-long-host-name-that-overflows-a-narrow-pane", "a part is never cut")
check(View.head_parts(frame({ host = "h" }, { mode = "list", filter = "error" }))[2] == "filter ! error", "filter !")
check(
	View.head_parts(frame({ host = "h" }, { mode = "list", filter = "running" }))[2] == "filter # running",
	"filter #"
)
check(View.head_parts(frame({ host = "h" }, { mode = "list", filter = "idle" }))[2] == "filter $ idle", "filter $")
check(#View.head_parts(frame({ host = "h" }, { mode = "list", filter = "!" })) == 2, "a key is no filter code")

-- The count tiles: each status's filter key with its count and its word, left to right in the one order (error,
-- waiting, running, idle), and the tile whose filter is on marked.
do
	local tiles = View.tile_parts({ waiting = 2, running = 1 }, "running")
	local shown = {}
	for _, t in tiles do
		table.insert(shown, string.format("%s %d %s%s", t.key, t.n, t.word, if t.on then " on" else ""))
	end
	check(
		same(shown, { "! 0 error", "@ 2 waiting", "# 1 running on", "$ 0 idle" }),
		"tiles: " .. table.concat(shown, ", ")
	)
	check(#tiles == #Status.ORDER, "one tile per ranked status")
	for i, t in tiles do
		check(t.code == Status.ORDER[i].code and t.key == Status.ORDER[i].key, "tile " .. i .. " follows status.ORDER")
	end
	local none = View.tile_parts({}, nil)
	check(#none == 4 and not none[1].on and none[1].n == 0, "no agents and no filter: four empty tiles, none on")
end

-- Node ids: the keys the view sets under main (`<parent id>.<key>`).
local rows: { any } = {
	{ kind = "header", gid = "g1" },
	{ kind = "agent", gid = "g1", id = "aaaa2222" },
	{ kind = "agent", gid = "g1", id = "head" },
	{ kind = "header", gid = "g2" },
	{ kind = "agent", gid = "g2", id = "bbbb3333" },
}
check(View.node_id(rows, { kind = "header", gid = "g1" }) == "main.cards.g1.head", "a group's id is its head")
check(View.node_id(rows, { kind = "agent", id = "aaaa2222" }) == "main.cards.g1.a-aaaa2222", "an agent's id")
check(
	View.node_id(rows, { kind = "agent", id = "head" }) == "main.cards.g1.a-head",
	"an agent never takes the head's id"
)
check(
	View.node_id(rows, { kind = "agent", id = "bbbb3333" }) == "main.cards.g2.a-bbbb3333",
	"an agent in a later group"
)
check(View.node_id(rows, nil) == nil, "no selection has no id")
check(View.node_id(rows, { kind = "agent", id = "gone" }) == nil, "a selection not drawn has no id")
check(View.node_id({}, { kind = "header", gid = "g1" }) == nil, "an empty list has no id")

-- Clicked node ids map back to their rows, the inverse of node_id.
for _, row in rows do
	local sel: any = if row.kind == "header"
		then { kind = "header", gid = row.gid }
		else { kind = "agent", id = row.id }
	local back = View.clicked(View.node_id(rows, sel))
	check(back ~= nil and back.gid == row.gid and back.id == row.id, "node_id round-trips for " .. row.kind)
end
local named_head = View.clicked("main.cards.g1.a-head")
check(named_head ~= nil and named_head.id == "head" and named_head.gid == "g1", "an agent named head")
check(View.clicked(nil) == nil, "no id names no row")
check(View.clicked("main.head") == nil, "the head line is not a row")
check(View.clicked("main.cards.g1") == nil, "a card is not a row")
check(View.clicked("main.cards.g1.a-") == nil, "an item key with no id is not a row")
check(View.clicked("main.cards.g1.other") == nil, "another key is not a row")
check(View.clicked("dock.main.cards.g1.head") == nil, "an id outside main is not a row")

-- A count tile's node id names its filter key, and is never a row.
check(View.clicked_tile("main.tiles.error") == "!", "the error tile is the ! key")
check(View.clicked_tile("main.tiles.idle") == "$", "the idle tile is the $ key")
check(View.clicked_tile("main.tiles.stopped") == nil, "a status with no tile names no key")
check(View.clicked_tile("main.tiles") == nil and View.clicked_tile(nil) == nil, "the tile row itself names no key")
check(View.clicked("main.tiles.error") == nil, "a tile is not a row")
check(View.clicked_tile("main.cards.g1.head") == nil, "a row is not a tile")

-- Hints and titles keep their default wording, use overridden bindings, and keep the default menu hint within a
-- 30-column pane.
check(View.menu_title(nil, 1, 22) == "commands 1/22", "the menu title is its name and place")
check(View.menu_title("pick", 3, 9) == "pick 3/9", "a named menu keeps its name")
check((utf8.len(View.menu_title(nil, 22, 22)) or math.huge) <= 30, "the menu title fits 30 columns")
check(View.menu_hint(DEFAULT_MAP) == "j/k · Enter or key runs · Esc", "the default menu hint is unchanged")
check((utf8.len(View.menu_hint(DEFAULT_MAP)) or math.huge) <= 30, "the default menu keys fit one 30-column line")
check(View.pick_title("move to", DEFAULT_MAP) == "move to (j/k, Enter, Esc)", "the default pick title is unchanged")
check(
	View.order_title("moving agent", DEFAULT_MAP) == "moving agent (j/k, Enter or V drops, Esc puts back)",
	"the default order title is unchanged"
)
check(View.delete_retry_text(DEFAULT_MAP) == "delete stuck — d retries", "the default retry hint is unchanged")
check(View.empty_text(frame({ rows = {} })) == "no groups: g adds one", "the default empty-list hint is unchanged")
check(
	View.empty_text(frame({ rows = {} }, { mode = "list", filter = "waiting" })) == "nothing matches",
	"an empty filtered list still says nothing matches"
)

do
	local map = Keymap.resolve({ down = "a", up = "b", reorder = "c", stop = "e" })
	check(View.menu_hint(map) == "a/b · Enter or key runs · Esc", "the menu hint uses movement overrides")
	check(View.pick_title("move to", map) == "move to (a/b, Enter, Esc)", "the pick title uses movement overrides")
	check(
		View.order_title("moving agent", map) == "moving agent (a/b, Enter or c drops, Esc puts back)",
		"the order title uses movement and drop overrides"
	)
	check(View.delete_retry_text(map) == "delete stuck — e retries", "the retry hint uses the stop override")
end

do
	local map = Keymap.resolve({ group = "a" })
	check(
		View.empty_text(frame({ rows = {}, map = map })) == "no groups: a adds one",
		"the empty-list hint uses the group override"
	)
end

do
	local function shown(row: any, map: any): { string }
		local out: { string } = {}
		for _, item in View.legend_items(row, map) do
			table.insert(out, item.key .. " " .. item.word)
		end
		return out
	end
	check(
		same(shown(rows[1], DEFAULT_MAP), { "⏎ fold", "n new", "g group", "d delete", "? menu" }),
		"the default group legend is unchanged"
	)
	check(
		same(shown(rows[2], DEFAULT_MAP), { "⏎ go", "n new", "o send", "d stop", "? menu" }),
		"the default agent legend is unchanged"
	)

	local map = Keymap.resolve({ new = "a", group = "b", stop = "c", send = "e", menu = "f" })
	check(
		same(shown(rows[1], map), { "⏎ fold", "a new", "b group", "c delete", "f menu" }),
		"the group legend uses its action overrides"
	)
	check(
		same(shown(rows[2], map), { "⏎ go", "a new", "e send", "c stop", "f menu" }),
		"the agent legend uses its action overrides"
	)
end

-- The reveal decision: a new or resized copy reveals, a moved selection reveals, a clock re-render does not.
do
	local sel: any = { kind = "agent", id = "aaaa2222" }
	local id, key = View.reveal(rows, sel, nil, true)
	check(id == "main.cards.g1.a-aaaa2222" and key ~= nil, "a new copy reveals the selection")
	local again, key2 = View.reveal(rows, sel, key, false)
	check(again == nil and key2 == key, "the same selection in the same place is not revealed again")
	local forced = View.reveal(rows, sel, key, true)
	check(forced == "main.cards.g1.a-aaaa2222", "a resize reveals it again")
	local moved = View.reveal(rows, { kind = "agent", id = "bbbb3333" }, key, false)
	check(moved == "main.cards.g2.a-bbbb3333", "a moved selection is revealed")
	local shifted: { any } = { { kind = "header", gid = "g0" }, table.unpack(rows) }
	local pushed = View.reveal(shifted, sel, key, false)
	check(pushed == "main.cards.g1.a-aaaa2222", "the same row at another place in the list is revealed")
	local none, nokey = View.reveal(rows, nil, key, true)
	check(none == nil and nokey == nil, "nothing selected reveals nothing")
	local back = View.reveal(rows, sel, nokey, false)
	check(back == "main.cards.g1.a-aaaa2222", "a selection after none is revealed")
end

-- A vibing row's pill says `vibing` in the running role; a record state that says more (starting, stopping, exited)
-- still shows its own pill first.
do
	local run_role = (Status.of("running") :: Status.Status).role
	local function pill(fields: { [string]: any }): string
		local row: { [string]: any } = { kind = "agent", gid = "g1", id = "a", state = "live", code = "running" }
		for k, v in fields do
			row[k] = v
		end
		local word, role = View.pill(row :: any)
		return word .. " " .. role
	end
	check(pill({}) == "running " .. run_role, "a running row says running")
	check(pill({ vibing = true }) == "vibing " .. run_role, "a vibing row says vibing in the running role")
	check(pill({ state = "pending", vibing = true }) == "starting deck.pending", "a pending record says starting")
	check(pill({ state = "stopping", vibing = true }) == "stopping deck.pending", "a stopping record says stopping")
	check(
		pill({ state = "exited", code = "stopped", vibing = true }) == "exited deck.stopped",
		"an exited record says exited"
	)
end

print("View: " .. checks .. " checks passed")
