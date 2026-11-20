--!strict
-- Global chord defaults and pure plans for reading, changing and resetting Jumpr's keybindings. Pure: no `tern`.

local protocol = require("../shared/protocol")

local M = {}

local ACTION_PREFIX = "plugin.jumpr."
local MAX_CHORD_LENGTH = 40

export type Keymap = { [string]: { string } }
export type Defaults = { [string]: string }
export type BindPlan = { refuse: string?, bind: string?, unbind: { string } }

local MAC_DEFAULTS: Defaults = {
	toggle_focus = "cmd+j",
	hide_list = "cmd+shift+j",
	last_tab = "cmd+\\",
	other_panes = "cmd+`",
}
local OTHER_DEFAULTS: Defaults = {
	toggle_focus = "ctrl+alt+j",
	hide_list = "ctrl+alt+shift+j",
	last_tab = "ctrl+alt+;",
	other_panes = "super+`",
}

-- The modifiers Tern's keybinds parser knows, spelled as its docs spell them: `alt` and `opt` name one key, as do
-- `cmd` and `super`.
local MODIFIERS: { [string]: boolean } = {
	ctrl = true,
	alt = true,
	opt = true,
	shift = true,
	cmd = true,
	super = true,
}

local ACTION_BY_ID: { [string]: string } = {}
for _, action in protocol.CHORD_ACTIONS do
	ACTION_BY_ID[ACTION_PREFIX .. action.id] = action.id
end

-- The full Tern action id for a Jumpr chord action.
function M.id(action: string): string
	return ACTION_PREFIX .. action
end

-- The default chord for every global action on this OS.
function M.defaults(os: string): Defaults
	local known = if os == "macos" or os == "ios" then MAC_DEFAULTS else OTHER_DEFAULTS
	local out: Defaults = {}
	for _, action in protocol.CHORD_ACTIONS do
		local chord = known[action.id]
		if chord ~= nil then
			out[action.id] = chord
		end
	end
	return out
end

-- Whether `key`, the last part of a chord, names a key as Tern spells one: letters, digits and `_` (`j`, `plus` for
-- the `+` key, `page_up`, `f12`, `digit_1`), or one character as the layout types it (`;`, `\`, `é`).
local function valid_key(key: string): boolean
	return string.find(key, "^[%w_]+$") ~= nil or utf8.len(key) == 1
end

-- Whether one chord of a sequence is spelled as Tern reads it: every part before the last a modifier Tern knows
-- (Tern refuses `cmd+j+k`: `j` is no modifier), then one key, and not a lone modifier, which Tern reads as a tap and
-- takes only in a sequence of taps.
local function valid_step(step: string): boolean
	local parts = string.split(step, "+")
	for i = 1, #parts - 1 do
		if not MODIFIERS[parts[i]] then
			return false
		end
	end
	local key = parts[#parts]
	return valid_key(key) and (#parts > 1 or not MODIFIERS[key])
end

-- Whether a chord is bounded, holds no space or control character, contains a modifier separator, and spells each
-- chord of a `>` sequence (`ctrl+a>c`: Ctrl+A, then C) as Tern's keybinds parser reads it.
function M.valid_chord(chord: string): boolean
	if
		#chord == 0
		or #chord > MAX_CHORD_LENGTH
		or string.find(chord, "[%s%c]") ~= nil
		or string.find(chord, "+", 1, true) == nil
	then
		return false
	end
	for _, step in string.split(chord, ">") do
		if not valid_step(step) then
			return false
		end
	end
	return true
end

-- Canonical spelling for comparing chords after Tern reorders their modifiers or names them another way.
function M.normalise(chord: string): string
	return protocol.normalise_chord(chord)
end

-- The sorted effective chords that currently run each Jumpr global action.
function M.current(keymap: Keymap): { [string]: { string } }
	local out: { [string]: { string } } = {}
	for _, action in protocol.CHORD_ACTIONS do
		out[action.id] = {}
	end
	for chord, holders in keymap do
		for _, holder in holders do
			local action = ACTION_BY_ID[holder]
			if action ~= nil then
				table.insert(out[action], chord)
			end
		end
	end
	for _, chords in out do
		table.sort(chords)
	end
	return out
end

-- Plans one bind only when its destination has no other holder, then removes this action's old chords.
function M.plan_bind(keymap: Keymap, _defaults: Defaults, action: string, chord: string): BindPlan
	local action_id = M.id(action)
	local destination = M.normalise(chord)
	for mapped_chord, holders in keymap do
		if M.normalise(mapped_chord) == destination then
			for _, holder in holders do
				if holder ~= action_id then
					return { refuse = "taken by " .. holder, bind = nil, unbind = {} }
				end
			end
		end
	end

	local unbind: { string } = {}
	for old_chord, old_holders in keymap do
		if M.normalise(old_chord) ~= destination and table.find(old_holders, action_id) ~= nil then
			table.insert(unbind, old_chord)
		end
	end
	table.sort(unbind)
	return { refuse = nil, bind = chord, unbind = unbind }
end

-- Copies raw user overrides while removing this action and the override that suppresses its default chord, however
-- Tern spells that chord (a bind of `cmd+shift+j` is stored as `shift+cmd+j`).
function M.reset_table(
	raw_overrides: { [string]: any },
	defaults: Defaults,
	action: string,
	empty: any
): { [string]: any }
	local out: { [string]: any } = {}
	local action_id = M.id(action)
	local default = defaults[action]
	local default_key = if default ~= nil then M.normalise(default) else nil
	for chord, value in raw_overrides do
		if type(value) == "table" then
			if #value == 0 then
				if M.normalise(chord) ~= default_key then
					out[chord] = empty
				end
			elseif table.find(value, action_id) == nil then
				out[chord] = value
			else
				local kept = table.create(#value - 1) :: { any }
				for _, holder in value do
					if holder ~= action_id then
						table.insert(kept, holder)
					end
				end
				if #kept > 0 then
					out[chord] = kept
				end
			end
		elseif value ~= action_id then
			out[chord] = value
		end
	end
	return out
end

return M
