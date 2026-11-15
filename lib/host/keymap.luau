--!strict
-- List actions, their default keys and the pure resolution and validation of user key overrides. Pure: no `tern`.

local M = {}

export type Action = { id: string, key: string, label: string }
export type Map = { key_of: { [string]: string }, action_of: { [string]: string } }

-- Settings-page order. The command menu keeps its own action order.
M.ACTIONS = table.freeze({
	table.freeze({ id = "down", key = "j", label = "next row" }),
	table.freeze({ id = "up", key = "k", label = "previous row" }),
	table.freeze({ id = "next_group", key = "J", label = "next group" }),
	table.freeze({ id = "prev_group", key = "K", label = "previous group" }),
	table.freeze({ id = "last", key = "G", label = "last row" }),
	table.freeze({ id = "fold", key = "h", label = "fold group" }),
	table.freeze({ id = "unfold", key = "l", label = "open group" }),
	table.freeze({ id = "new", key = "n", label = "new agent" }),
	table.freeze({ id = "group", key = "g", label = "new group" }),
	table.freeze({ id = "rename", key = "r", label = "rename" }),
	table.freeze({ id = "move", key = "m", label = "move to another group" }),
	table.freeze({ id = "reorder", key = "V", label = "reorder" }),
	table.freeze({ id = "stop", key = "d", label = "stop agent" }),
	table.freeze({ id = "send", key = "o", label = "send a message" }),
	table.freeze({ id = "queue", key = "q", label = "queue a message" }),
	table.freeze({ id = "sources", key = "i", label = "show status sources" }),
	table.freeze({ id = "search", key = "/", label = "search" }),
	table.freeze({ id = "menu", key = "?", label = "commands" }),
	table.freeze({ id = "settings", key = ",", label = "settings" }),
}) :: { Action }

-- Status filtering and confirmation keys stay structural and cannot be shadowed by a list action.
M.RESERVED = table.freeze({
	["!"] = true,
	["@"] = true,
	["#"] = true,
	["$"] = true,
	["1"] = true,
	["2"] = true,
	["3"] = true,
	["4"] = true,
	["0"] = true,
	y = true,
	Y = true,
}) :: { [string]: boolean }

local ACTION_BY_ID: { [string]: Action } = {}
local DEFAULT_HOLDER: { [string]: string } = {}
for _, action in M.ACTIONS do
	ACTION_BY_ID[action.id] = action
	DEFAULT_HOLDER[action.key] = action.id
end

-- An action's default key (nil for an unknown action), for checking that a reset can restore it.
local DEFAULT_OF: { [string]: string } = {}
for _, action in M.ACTIONS do
	DEFAULT_OF[action.id] = action.key
end
M.DEFAULT_OF = DEFAULT_OF

local function visible(key: string): boolean
	return #key == 1 and string.match(key, "^%g$") ~= nil
end

local function candidates(overrides: { [string]: string }): ({ [string]: boolean }, { [string]: number })
	local active: { [string]: boolean } = {}
	local destinations: { [string]: number } = {}
	for _, action in M.ACTIONS do
		local key = overrides[action.id]
		if key ~= nil and visible(key) and M.RESERVED[key] ~= true then
			active[action.id] = true
			destinations[key] = (destinations[key] or 0) + 1
		end
	end
	for _, action in M.ACTIONS do
		if active[action.id] and (destinations[overrides[action.id]] or 0) > 1 then
			active[action.id] = nil
		end
	end
	return active, destinations
end

-- Removes candidates that need a default key whose owner cannot move, including dependencies exposed by a refusal.
local function accepted(overrides: { [string]: string }): { [string]: boolean }
	local active = candidates(overrides)
	local changed = true
	while changed do
		changed = false
		for _, action in M.ACTIONS do
			if active[action.id] then
				local holder = DEFAULT_HOLDER[overrides[action.id]]
				if holder ~= nil and holder ~= action.id and not active[holder] then
					active[action.id] = nil
					changed = true
				end
			end
		end
	end
	return active
end

-- Resolves defaults with every valid, non-colliding override applied in settings-page order.
function M.resolve(overrides: { [string]: string }): Map
	local active = accepted(overrides)
	local key_of: { [string]: string } = {}
	local action_of: { [string]: string } = {}
	for _, action in M.ACTIONS do
		local key = if active[action.id] then overrides[action.id] else action.key
		key_of[action.id] = key
		action_of[key] = action.id
	end
	return { key_of = key_of, action_of = action_of }
end

-- Returns why a key cannot be assigned, or nil when it is free or already belongs to this action.
function M.check(overrides: { [string]: string }, action: string, key: string): string?
	if not visible(key) then
		return "one character"
	end
	if M.RESERVED[key] == true then
		return "reserved"
	end
	local holder = M.resolve(overrides).action_of[key]
	if holder ~= nil and holder ~= action then
		return "taken by " .. (ACTION_BY_ID[holder] :: Action).label
	end
	return nil
end

return M
