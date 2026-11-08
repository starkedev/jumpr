--!strict

local Status = require("../lib/shared/status")
local View = require("../lib/host/view")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function frame(fields: { [string]: any }, ui: { [string]: any }?): any
	local f: { [string]: any } = { health = "ok", age_ms = 3000, ui = ui or { mode = "list" } }
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

print("View: " .. checks .. " checks passed")
