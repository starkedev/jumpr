--!strict
-- Rendering for the settings block. Not pure: it builds Tern UI nodes.

local Agent = require("../shared/agent")
local protocol = require("../shared/protocol")
local keymap = require("./keymap")
local settings = require("./settings")

local M = {}

type Option = { value: string, label: string }
type ChoiceControl = { k: string, value: string, style: string, mono: boolean, options: { Option } }
type TextControl = { k: string, value: string, placeholder: string, mono: boolean }
type SwitchControl = { k: string, on: boolean }
type ActionControl = { k: string, act: string, label: string }
type Row = {
	id: string,
	label: string,
	hint: string,
	warning: string?,
	disabled: string?,
	changed: boolean?,
	defaultLabel: string?,
	control: ChoiceControl | TextControl | SwitchControl | ActionControl,
}

-- A text row's hint while its whole draft is selected: Tern's prefs node draws only the caret.
local SELECTED_HINT = "Type to replace, or use the arrow keys to edit."

-- Whether text row `row` is open with its whole draft selected.
local function all_selected(state: settings.State, row: string): boolean
	local editing = state.editing
	return state.all_selected == true and editing ~= nil and editing.row == row
end

local function choice_options(current: string): { Option }
	local options: { Option } = {}
	for _, value in settings.agent_options(current) do
		table.insert(options, { value = value, label = value })
	end
	return options
end

local function agent_rows(state: settings.State, ctx: settings.Context, new_key: string): { Row }
	local disabled = if ctx.readonly then "Settings are read-only on this machine." else nil
	local current = ctx.settings.agent
	return {
		{
			id = "agent",
			label = "Default agent",
			hint = "The agent started by " .. new_key .. " in the list.",
			warning = if state.focus == "agent" then state.notice else nil,
			disabled = disabled,
			changed = current ~= Agent.OMP,
			defaultLabel = Agent.OMP,
			control = {
				k = "choice",
				value = current,
				style = "menu",
				mono = true,
				options = choice_options(current),
			},
		},
		{
			id = "other",
			label = "Other agent",
			hint = if all_selected(state, "other") then SELECTED_HINT else "Any agent id known to Tern's ACP chat.",
			warning = if state.focus == "other" then state.notice else nil,
			disabled = disabled,
			control = {
				k = "text",
				value = current,
				placeholder = "Agent id",
				mono = true,
			},
		},
	}
end

local function window_rows(state: settings.State, ctx: settings.Context): { Row }
	local cfg = ctx.cfg
	if cfg == nil then
		return {
			{
				id = "waiting",
				label = "Window settings",
				hint = "Waiting for the window.",
				warning = state.notice,
				disabled = "Waiting for the window.",
				control = { k = "text", value = "", placeholder = "Waiting", mono = true },
			},
		}
	end
	local rows: { Row } = {
		{
			id = "esc",
			label = "Esc returns to your pane",
			hint = "Turn off to keep focus in the list when it closes.",
			warning = if state.focus == "esc" then state.notice else nil,
			control = { k = "switch", on = cfg.em == "A" },
		},
	}
	for _, action in protocol.CHORD_ACTIONS do
		local current = cfg.chords[action.id] or {}
		local default = cfg.defaults[action.id] or ""
		local changed = #current ~= 1 or protocol.normalise_chord(current[1]) ~= protocol.normalise_chord(default)
		table.insert(rows, {
			id = action.id,
			label = action.label,
			hint = if all_selected(state, action.id)
				then SELECTED_HINT
				else "Press the chord, or type it, then press Enter.",
			warning = if state.focus == action.id then state.notice else nil,
			changed = changed,
			defaultLabel = default,
			control = {
				k = "text",
				value = table.concat(current, ", "),
				placeholder = "No chord",
				mono = true,
			},
		})
	end
	return rows
end

local function key_rows(state: settings.State, ctx: settings.Context, map: keymap.Map): { Row }
	local disabled = if ctx.readonly then "Settings are read-only on this machine." else nil
	local rows: { Row } = {}
	for _, action in keymap.ACTIONS do
		local capturing = state.editing ~= nil and state.editing.row == action.id
		local key = map.key_of[action.id]
		table.insert(rows, {
			id = action.id,
			label = action.label,
			hint = if capturing then "Press a key. Backspace resets it." else "Press Enter to change this key.",
			warning = if state.focus == action.id then state.notice else nil,
			disabled = disabled,
			changed = key ~= action.key,
			defaultLabel = action.key,
			-- A text field, not keycaps, so the key shows in its own case (`j`, `J`) and a changed row gets Tern's
			-- Reset; the empty placeholder leaves only the caret while the row waits for a key.
			control = { k = "text", value = key, placeholder = "", mono = true },
		})
	end
	table.insert(rows, {
		id = "reset_keys",
		label = "Reset all keys",
		hint = "Restore every list key to its default.",
		warning = if state.focus == "reset_keys" then state.notice else nil,
		disabled = disabled,
		control = { k = "action", act = "reset_keys", label = "Reset all" },
	})
	return rows
end

-- The prefs node's props. Every page names the machine its values belong to: the list's host for the agent and the
-- list keys, the window's machine for Esc and the chords.
function M.props(state: settings.State, ctx: settings.Context, host: string?): { [string]: any }
	local host_machine = if host ~= nil and host ~= "" then host else "this machine"
	local cfg = ctx.cfg
	local window_machine = if cfg ~= nil and cfg.machine ~= "" then cfg.machine else nil
	local map = keymap.resolve(ctx.settings.keys)
	local new_key = map.key_of.new
	local on_agents = state.page == "agents"
	local on_window = state.page == "window"
	local rows = if on_window
		then window_rows(state, ctx)
		elseif on_agents then agent_rows(state, ctx, new_key)
		else key_rows(state, ctx, map)
	-- Until the window answers, its lead names no machine.
	local on_machine = if window_machine ~= nil then ", on " .. window_machine else ""
	return {
		id = "settings",
		title = "Jumpr settings",
		lead = if on_window
			then "Esc and the chords for the Tern window in front of you"
				.. on_machine
				.. ". They apply to every list this window shows."
			elseif on_agents then "The agent " .. new_key .. " starts in " .. host_machine .. "'s list."
			else "The keys of " .. host_machine .. "'s list.",
		pages = {
			{ id = "agents", label = "Agents · " .. host_machine, icon = "sliders" },
			{ id = "window", label = "This window · " .. (window_machine or "waiting…"), icon = "keyboard" },
			{ id = "keys", label = "List keys · " .. host_machine, icon = "list" },
		},
		page = state.page,
		focus = state.focus,
		editing = state.editing,
		sections = {
			{
				id = if on_window then "window-settings" elseif on_agents then "agent-defaults" else "list-keys",
				title = if on_window then "Window behaviour" elseif on_agents then "Agent defaults" else "List keys",
				rows = rows,
			},
		},
	}
end

function M.view(state: settings.State, ctx: settings.Context, host: string?): BlockView
	local prefs = tern.ui.node("prefs", M.props(state, ctx, host))
	return { main = tern.ui.col({ prefs }) }
end

return M
