--!strict
-- Behavioral checks for list-action order, key resolution and override refusals. Pure: no `tern`.

local Keymap = require("../lib/host/keymap")

local checks = 0
local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local expected = {
	{ id = "down", key = "j", label = "next row" },
	{ id = "up", key = "k", label = "previous row" },
	{ id = "next_group", key = "J", label = "next group" },
	{ id = "prev_group", key = "K", label = "previous group" },
	{ id = "last", key = "G", label = "last row" },
	{ id = "fold", key = "h", label = "fold group" },
	{ id = "unfold", key = "l", label = "open group" },
	{ id = "new", key = "n", label = "new agent" },
	{ id = "new_kind", key = "N", label = "new agent, pick kind" },
	{ id = "group", key = "g", label = "new group" },
	{ id = "rename", key = "r", label = "rename" },
	{ id = "move", key = "m", label = "move to another group" },
	{ id = "reorder", key = "V", label = "reorder" },
	{ id = "stop", key = "d", label = "stop agent" },
	{ id = "send", key = "o", label = "send a message" },
	{ id = "queue", key = "q", label = "queue a message" },
	{ id = "sources", key = "i", label = "show status sources" },
	{ id = "search", key = "/", label = "search" },
	{ id = "menu", key = "?", label = "commands" },
	{ id = "settings", key = ",", label = "settings" },
}

-- Actions stay in settings-page order and defaults resolve in both directions.
do
	local map = Keymap.resolve({})
	check(#Keymap.ACTIONS == #expected, "every settings-page action is declared")
	for i, want in expected do
		local action = Keymap.ACTIONS[i]
		check(
			action.id == want.id and action.key == want.key and action.label == want.label,
			"action " .. tostring(i) .. " keeps its settings-page identity"
		)
		check(map.key_of[want.id] == want.key, want.id .. " resolves to its default key")
		check(map.action_of[want.key] == want.id, want.key .. " resolves to its default action")
	end
end

-- An override moves one action and leaves its old default key free.
do
	local map = Keymap.resolve({ new = "a" })
	check(map.key_of.new == "a" and map.action_of.a == "new", "an override moves the action to its new key")
	check(map.action_of.n == nil, "an override frees the action's old default key")
end

-- Overrides can use defaults freed by another override without depending on table iteration order.
do
	local map = Keymap.resolve({ new = "a", down = "n" })
	check(map.key_of.new == "a" and map.key_of.down == "n", "coordinated overrides use a key another action frees")
	check(map.action_of.a == "new" and map.action_of.n == "down", "coordinated overrides resolve back to both actions")
	check(map.action_of.j == nil, "coordinated overrides free every old key")
end

-- A key held by another action is refused by name and its override is ignored.
do
	local overrides = { new = "j" }
	local map = Keymap.resolve(overrides)
	check(map.key_of.new == "n" and map.action_of.j == "down", "a colliding override leaves both defaults in place")
	check(Keymap.check(overrides, "new", "j") == "taken by next row", "a collision names the action holding the key")
end

-- Reserved status and confirmation keys can never shadow their structural actions.
do
	local reserved = { "!", "@", "#", "$", "1", "2", "3", "4", "0", "y", "Y" }
	for _, key in reserved do
		local map = Keymap.resolve({ new = key })
		check(Keymap.RESERVED[key] == true, key .. " is declared reserved")
		check(map.key_of.new == "n" and map.action_of[key] == nil, key .. " cannot override a list action")
		check(Keymap.check({}, "new", key) == "reserved", key .. " is refused as reserved")
	end
end

-- Invalid keys are ignored and report the bounded refusal.
do
	check(Keymap.resolve({ new = "" }).key_of.new == "n", "an empty override is ignored")
	check(Keymap.resolve({ new = "ab" }).key_of.new == "n", "a multi-character override is ignored")
	check(Keymap.resolve({ new = " " }).key_of.new == "n", "an invisible override is ignored")
	check(Keymap.check({}, "new", "") == "one character", "an empty key asks for one character")
	check(Keymap.check({}, "new", "ab") == "one character", "a long key asks for one character")
	check(Keymap.check({}, "new", " ") == "one character", "an invisible key asks for one character")
end

-- An action may keep its own effective key, whether default or overridden.
do
	check(Keymap.check({}, "new", "n") == nil, "an action may keep its default key")
	check(Keymap.check({ new = "a" }, "new", "a") == nil, "an action may keep its overridden key")
end

print("Keymap: " .. checks .. " checks passed")
