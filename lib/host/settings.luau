--!strict
-- Pure state and reducer for the settings page. Pure: no `tern`.

local Agent = require("../shared/agent")
local protocol = require("../shared/protocol")
local input = require("./input")
local keymap = require("./keymap")
local Store = require("./store")

local M = {}

export type Editing = {
	row: string,
	draft: string?,
	cursor: number?,
	option: string?,
}

export type State = {
	page: string,
	focus: string,
	editing: Editing?,
	-- True while the open text row's whole draft is selected: typed text or a paste replaces it, and Backspace or
	-- Delete clears it. It stays out of `editing`, which goes to Tern as the prefs node's prop.
	all_selected: boolean?,
	notice: string?,
}

export type Context = {
	settings: Store.Settings,
	readonly: boolean,
	cfg: protocol.WindowCfg?,
}

export type Event = {
	kind: string,
	name: string?,
	text: string?,
	ctrl: boolean?,
	alt: boolean?,
	shift: boolean?,
	meta: boolean?,
	ev: string?,
	item: string?,
	act: string?,
	value: any?,
}

export type Effect = {
	kind: string,
	agent: string?,
	fields: { [string]: string }?,
	action: string?,
	key: string?,
}

local PAGES = { "agents", "window", "keys" }
local AGENT_ROWS = { "agent", "other" }
local ESC_ROW = "esc"
local WAITING_ROW = "waiting"
local RESET_KEYS_ROW = "reset_keys"
local KEY_ROWS: { string } = {}
local KEY_ACTIONS: { [string]: boolean } = {}
for _, action in keymap.ACTIONS do
	table.insert(KEY_ROWS, action.id)
	KEY_ACTIONS[action.id] = true
end
table.insert(KEY_ROWS, RESET_KEYS_ROW)
local MAX_KIND = 32
local READONLY_NOTICE = "Settings are read-only on this machine."
local CHAR_NOTICE = "Agent ids use letters, numbers, underscores and hyphens."
local START_NOTICE = "Agent ids must start with a letter or number."
local LENGTH_NOTICE = "Agent ids are at most 32 characters."
local EMPTY_NOTICE = "Type an agent id."
local WINDOW_NEWER_NOTICE = "The window runs a newer Jumpr; update Jumpr on this machine."
local WINDOW_OLDER_NOTICE = "The window runs an older Jumpr; update Jumpr on the window machine."

-- Tern's chord grammar (`settings.json` keybinds, which `settings:bind` writes) names the meta key `cmd` on every OS:
-- Cmd on macOS, the Windows or Super key elsewhere. `+` joins a chord's parts, so the `+` key is spelled `plus`.
local META_MODIFIER = "cmd"
local CHORD_KEY_NAMES: { [string]: string } = { ["+"] = "plus" }

function M.new(): State
	return { page = "agents", focus = "agent", editing = nil, all_selected = nil, notice = nil }
end

function M.version_notice(verdict: string): string
	return if verdict == "bad_p_newer" then WINDOW_NEWER_NOTICE else WINDOW_OLDER_NOTICE
end

local function window_rows(ctx: Context): { string }
	if ctx.cfg == nil then
		return { WAITING_ROW }
	end
	local rows = { ESC_ROW }
	for _, action in protocol.CHORD_ACTIONS do
		table.insert(rows, action.id)
	end
	return rows
end

local function rows(state: State, ctx: Context): { string }
	if state.page == "window" then
		return window_rows(ctx)
	elseif state.page == "keys" then
		return KEY_ROWS
	end
	return AGENT_ROWS
end

local function chord_value(ctx: Context, action: string): string
	local cfg = ctx.cfg
	if cfg == nil then
		return ""
	end
	return table.concat(cfg.chords[action] or {}, ", ")
end

local function chord_action(row: string): boolean
	for _, action in protocol.CHORD_ACTIONS do
		if action.id == row then
			return true
		end
	end
	return false
end

local function key_action(row: string): boolean
	return KEY_ACTIONS[row] == true
end

local function copy(state: State): State
	local out = table.clone(state)
	if state.editing ~= nil then
		out.editing = table.clone(state.editing)
	end
	return out
end

-- A copy of `state` with no row open: the editor closes, and its selection with it.
local function closed(state: State): State
	local out = copy(state)
	out.editing = nil
	out.all_selected = nil
	return out
end

local function render(): { Effect }
	return { { kind = "render" } }
end

local function refuse(state: State, notice: string): (State, { Effect })
	local out = closed(state)
	out.notice = notice
	return out, render()
end

local function agent_notice(value: string): string?
	if value == "" then
		return EMPTY_NOTICE
	end
	if input.units(value) > MAX_KIND then
		return LENGTH_NOTICE
	end
	if string.match(value, "^[%w]") == nil then
		return START_NOTICE
	end
	if string.match(value, "[^%w_%-]") ~= nil then
		return CHAR_NOTICE
	end
	if not Agent.valid_kind(value) then
		return CHAR_NOTICE
	end
	return nil
end

local function set_agent(state: State, ctx: Context, value: any): (State, { Effect })
	if ctx.readonly then
		return refuse(state, READONLY_NOTICE)
	end
	if type(value) ~= "string" then
		local out = copy(state)
		out.notice = CHAR_NOTICE
		return out, render()
	end
	local notice = agent_notice(value)
	if notice ~= nil then
		local out = copy(state)
		out.notice = notice
		return out, render()
	end
	local out = closed(state)
	out.notice = nil
	return out, { { kind = "set_agent", agent = value }, { kind = "render" } }
end

local function cfg_effect(state: State, fields: { [string]: string }): (State, { Effect })
	local out = closed(state)
	out.notice = nil
	return out, { { kind = "cfg", fields = fields }, { kind = "render" } }
end

-- Restores one list key to its default: Backspace while its row waits for a key, or the row's Reset.
local function reset_key(state: State, ctx: Context, action: string): (State, { Effect })
	if ctx.readonly then
		return refuse(state, READONLY_NOTICE)
	end
	local out = closed(state)
	out.notice = nil
	return out, { { kind = "set_key", action = action, key = nil }, { kind = "render" } }
end

-- Opens text row `row` on `draft`, the caret at its end and the whole draft selected so that typing replaces it (an
-- empty draft has nothing to select).
local function open_text(state: State, row: string, draft: string): (State, { Effect })
	local out = copy(state)
	out.focus = row
	out.notice = nil
	out.editing = { row = row, draft = draft, cursor = input.units(draft) }
	out.all_selected = if draft ~= "" then true else nil
	return out, render()
end

local function open_row(state: State, ctx: Context, row: string): (State, { Effect })
	if state.page == "keys" then
		if row == RESET_KEYS_ROW then
			if ctx.readonly then
				return refuse(state, READONLY_NOTICE)
			end
			local out = copy(state)
			out.focus = row
			out.notice = nil
			return out, { { kind = "reset_keys" }, { kind = "render" } }
		end
		if not key_action(row) then
			return state, {}
		end
		if ctx.readonly then
			return refuse(state, READONLY_NOTICE)
		end
		local out = copy(state)
		out.focus = row
		out.notice = nil
		-- The field waits empty, showing only the caret, for the key.
		out.editing = { row = row, draft = "", cursor = 0 }
		out.all_selected = nil
		return out, render()
	end
	if state.page == "window" then
		local cfg = ctx.cfg
		if row == ESC_ROW and cfg ~= nil then
			local mode = if cfg.em == "A" then "B" else "A"
			return cfg_effect(state, { op = "esc", v = mode })
		end
		if not chord_action(row) then
			return state, {}
		end
		return open_text(state, row, chord_value(ctx, row))
	end
	if row == "other" then
		return open_text(state, row, ctx.settings.agent)
	elseif row ~= "agent" then
		return state, {}
	end
	local out = copy(state)
	out.focus = row
	out.notice = nil
	local editing: Editing = { row = row, option = ctx.settings.agent }
	out.editing = editing
	out.all_selected = nil
	return out, render()
end

local function switch_page(state: State, ctx: Context, page: string): (State, { Effect })
	if table.find(PAGES, page) == nil then
		return state, {}
	end
	if state.page == page then
		return state, {}
	end
	local out = closed(state)
	out.page = page
	out.notice = nil
	if page == "agents" then
		out.focus = AGENT_ROWS[1]
	elseif page == "window" then
		out.focus = window_rows(ctx)[1]
	else
		out.focus = KEY_ROWS[1]
	end
	local effects = render()
	if page == "window" then
		table.insert(effects, 1, { kind = "cfg", fields = { op = "read" } })
	end
	return out, effects
end

local function shift_page(state: State, ctx: Context, delta: number): (State, { Effect })
	local at = table.find(PAGES, state.page) or 1
	local next_at = ((at - 1 + delta) % #PAGES) + 1
	return switch_page(state, ctx, PAGES[next_at])
end

local function move_focus(state: State, ctx: Context, delta: number): (State, { Effect })
	local page_rows = rows(state, ctx)
	local at = table.find(page_rows, state.focus) or 1
	local next_at = math.clamp(at + delta, 1, #page_rows)
	if page_rows[next_at] == state.focus and state.notice == nil then
		return state, {}
	end
	local out = copy(state)
	out.focus = page_rows[next_at]
	out.notice = nil
	return out, render()
end

local function key_char(event: Event): string?
	if event.ctrl or event.alt or event.meta or event.name == "paste" then
		return nil
	end
	if event.text ~= nil and event.text ~= "" and input.units(event.text) == 1 then
		return event.text
	end
	if event.name ~= nil and #event.name == 1 then
		return event.name
	end
	return nil
end

local function choice_key(state: State, ctx: Context, event: Event): (State, { Effect })
	local editing = state.editing
	if editing == nil then
		return state, {}
	end
	local options = Agent.options(ctx.settings.agent)
	local at = table.find(options, editing.option or ctx.settings.agent) or 1
	local name = event.name
	local ch = key_char(event)
	if name == "down" or ch == "j" then
		at = math.clamp(at + 1, 1, #options)
	elseif name == "up" or ch == "k" then
		at = math.clamp(at - 1, 1, #options)
	elseif name == "enter" then
		return set_agent(state, ctx, options[at])
	else
		return state, {}
	end
	if options[at] == editing.option then
		return state, {}
	end
	local out = copy(state)
	if out.editing ~= nil then
		out.editing.option = options[at]
	end
	out.notice = nil
	return out, render()
end

-- The open text row's new draft and caret: any edit or caret move ends a selection of the whole draft.
local function write_draft(state: State, draft: string, cursor: number, notice: string?): (State, { Effect })
	local out = copy(state)
	if out.editing ~= nil then
		out.editing.draft = draft
		out.editing.cursor = cursor
	end
	out.all_selected = nil
	out.notice = notice
	return out, render()
end

local function delete_after(text: string, cursor: number?): (string, number)
	local at = input.clamp_cursor(text, cursor)
	local nxt = input.move_cursor(text, at, 1)
	if nxt == at then
		return text, at
	end
	return input.delete_before(text, nxt)
end

-- Keeps only characters an agent id may contain, then stops at 32. A leading hyphen or underscore is refused whole.
local function clip_insert(draft: string, cursor: number?, extra: string): (string, number, string?)
	local filtered = string.gsub(extra, "[^%w_%-]", "")
	local dropped = filtered ~= extra
	local at = input.clamp_cursor(draft, cursor)
	if filtered == "" then
		return draft, at, CHAR_NOTICE
	end
	local room = MAX_KIND - input.units(draft)
	local notice = if dropped then CHAR_NOTICE else nil
	if room <= 0 then
		return draft, at, LENGTH_NOTICE
	end
	if input.units(filtered) > room then
		filtered = string.sub(filtered, 1, room)
		notice = LENGTH_NOTICE
	end
	local next_draft, next_cursor = input.insert_at(draft, at, filtered)
	if string.match(next_draft, "^[%w]") == nil then
		return draft, at, START_NOTICE
	end
	return next_draft, next_cursor, notice
end

local function text_key(state: State, ctx: Context, event: Event): (State, { Effect })
	local editing = state.editing
	if editing == nil then
		return state, {}
	end
	local draft = editing.draft or ""
	local cursor = editing.cursor
	if event.name == "enter" then
		if editing.row == "other" then
			return set_agent(state, ctx, draft)
		end
		if chord_action(editing.row) then
			return cfg_effect(state, { op = "bind", action = editing.row, chord = draft })
		end
		return state, {}
	end
	local selected = state.all_selected == true
	if selected then
		-- The whole draft is selected: Backspace or Delete clears it, and an arrow, Home or End drops the selection,
		-- leaving the caret at that end.
		if event.name == "backspace" or event.name == "delete" then
			return write_draft(state, "", 0, nil)
		elseif event.name == "left" or event.name == "home" then
			return write_draft(state, draft, 0, nil)
		elseif event.name == "right" or event.name == "end" then
			return write_draft(state, draft, input.units(draft), nil)
		end
	elseif event.name == "backspace" then
		local next_draft, next_cursor = input.delete_before(draft, cursor)
		if next_draft == draft then
			return state, {}
		end
		return write_draft(state, next_draft, next_cursor, nil)
	elseif event.name == "delete" then
		local next_draft, next_cursor = delete_after(draft, cursor)
		if next_draft == draft then
			return state, {}
		end
		return write_draft(state, next_draft, next_cursor, nil)
	elseif event.name == "left" then
		local next_cursor = input.move_cursor(draft, cursor, -1)
		if next_cursor == input.clamp_cursor(draft, cursor) then
			return state, {}
		end
		return write_draft(state, draft, next_cursor, nil)
	elseif event.name == "right" then
		local next_cursor = input.move_cursor(draft, cursor, 1)
		if next_cursor == input.clamp_cursor(draft, cursor) then
			return state, {}
		end
		return write_draft(state, draft, next_cursor, nil)
	elseif event.name == "home" then
		if input.clamp_cursor(draft, cursor) == 0 then
			return state, {}
		end
		return write_draft(state, draft, 0, nil)
	elseif event.name == "end" then
		local end_at = input.units(draft)
		if input.clamp_cursor(draft, cursor) == end_at then
			return state, {}
		end
		return write_draft(state, draft, end_at, nil)
	end

	local extra: string? = nil
	if event.name == "paste" then
		extra = event.text or ""
	elseif event.name == "space" then
		extra = " "
	else
		extra = key_char(event)
	end
	if extra == nil then
		return state, {}
	end
	-- Typed text goes in at the caret, or in place of the whole draft while it is selected.
	local base = if selected then "" else draft
	local at = if selected then 0 else input.clamp_cursor(draft, cursor)
	local next_draft: string, next_cursor: number, notice: string? = base, at, nil
	if editing.row == "other" then
		next_draft, next_cursor, notice = clip_insert(base, at, extra)
	else
		next_draft, next_cursor = input.insert_at(base, at, extra)
	end
	if next_draft == base then
		-- Nothing went in: the draft and its selection stay, and refused text says why.
		if notice == nil then
			return state, {}
		end
		local out = copy(state)
		out.notice = notice
		return out, render()
	end
	return write_draft(state, next_draft, next_cursor, notice)
end

local function capture_key(state: State, ctx: Context, event: Event): (State, { Effect })
	local editing = state.editing
	if editing == nil or not key_action(editing.row) then
		return state, {}
	end
	if event.name == "backspace" then
		return reset_key(state, ctx, editing.row)
	end
	local ch = key_char(event)
	if ch == nil then
		return state, {}
	end
	local reason = keymap.check(ctx.settings.keys, editing.row, ch)
	if reason ~= nil then
		local out = copy(state)
		out.notice = reason
		return out, render()
	end
	local out = closed(state)
	out.notice = nil
	return out, { { kind = "set_key", action = editing.row, key = ch }, { kind = "render" } }
end

-- The chord a key pressed with ctrl, alt or the meta key spells in Tern's grammar: the modifiers held, in the order
-- ctrl, alt, shift, cmd, then the key.
local function chord_text(event: Event): string?
	local name = event.name
	if name == nil or name == "" then
		return nil
	end
	local parts: { string } = {}
	if event.ctrl then
		table.insert(parts, "ctrl")
	end
	if event.alt then
		table.insert(parts, "alt")
	end
	if event.shift then
		table.insert(parts, "shift")
	end
	if event.meta then
		table.insert(parts, META_MODIFIER)
	end
	table.insert(parts, CHORD_KEY_NAMES[name] or name)
	return table.concat(parts, "+")
end

-- A chord pressed while a chord row is open replaces its draft; Enter then commits it as it would a typed chord.
local function capture_chord(state: State, event: Event): (State, { Effect })
	local chord = chord_text(event)
	if chord == nil then
		return state, {}
	end
	return write_draft(state, chord, input.units(chord), nil)
end

-- Ctrl+A, or Meta+A (Cmd+A on macOS).
local function select_all_key(event: Event): boolean
	return event.name == "a" and (event.ctrl == true or event.meta == true) and not event.alt and not event.shift
end

-- Selects the open agent-id row's whole draft again, the caret at its end.
local function select_all(state: State): (State, { Effect })
	local editing = state.editing
	if editing == nil or state.all_selected then
		return state, {}
	end
	local draft = editing.draft or ""
	if draft == "" then
		return state, {}
	end
	local out = copy(state)
	if out.editing ~= nil then
		out.editing.cursor = input.units(draft)
	end
	out.all_selected = true
	out.notice = nil
	return out, render()
end

local function key_event(state: State, ctx: Context, event: Event): (State, { Effect })
	if event.name == "escape" then
		if state.editing ~= nil then
			local out = closed(state)
			out.notice = nil
			return out, render()
		end
		return state, { { kind = "exit" } }
	end

	local editing = state.editing
	if editing ~= nil then
		if event.name ~= "paste" and (event.ctrl or event.alt or event.meta) then
			-- A chord row captures the chord, the agent-id row takes select-all, and other rows ignore the key.
			if chord_action(editing.row) then
				return capture_chord(state, event)
			elseif editing.row == "other" and select_all_key(event) then
				return select_all(state)
			end
			return state, {}
		end
		if state.page == "keys" then
			return capture_key(state, ctx, event)
		elseif editing.row == "agent" then
			return choice_key(state, ctx, event)
		end
		return text_key(state, ctx, event)
	end

	if event.ctrl or event.alt or event.meta then
		return state, {}
	end
	local ch = key_char(event)
	if ch == "[" then
		return shift_page(state, ctx, -1)
	elseif ch == "]" then
		return shift_page(state, ctx, 1)
	elseif event.name == "down" or ch == "j" then
		return move_focus(state, ctx, 1)
	elseif event.name == "up" or ch == "k" then
		return move_focus(state, ctx, -1)
	elseif event.name == "enter" or (event.name == "space" and state.page ~= "keys") then
		return open_row(state, ctx, state.focus)
	end
	return state, {}
end

local function select_event(state: State, ctx: Context, item: string?): (State, { Effect })
	if item ~= nil and table.find(rows(state, ctx), item) ~= nil then
		if state.focus == item and state.notice == nil then
			return state, {}
		end
		local out = copy(state)
		out.focus = item
		out.notice = nil
		return out, render()
	end
	if state.page == "agents" and item ~= nil then
		local option = string.match(item, "^agent=(.+)$")
		if option ~= nil and table.find(Agent.options(ctx.settings.agent), option) ~= nil then
			local out = copy(state)
			local editing: Editing = { row = "agent", option = option }
			out.focus = "agent"
			out.editing = editing
			out.all_selected = nil
			out.notice = nil
			return out, render()
		end
	end
	return state, {}
end

local function ui_event(state: State, ctx: Context, event: Event): (State, { Effect })
	local row = event.item
	if event.ev == "change" and row ~= nil then
		local focused = copy(state)
		focused.focus = row
		if state.page == "agents" and (row == "agent" or row == "other") then
			return set_agent(focused, ctx, if event.value == nil then Agent.OMP else event.value)
		elseif state.page == "window" and row == ESC_ROW and type(event.value) == "boolean" then
			return cfg_effect(focused, { op = "esc", v = if event.value then "A" else "B" })
		elseif state.page == "window" and chord_action(row) and event.value == nil then
			return cfg_effect(focused, { op = "reset", action = row })
		elseif state.page == "keys" and key_action(row) and event.value == nil then
			return reset_key(focused, ctx, row)
		end
	elseif event.ev == "activate" and row ~= nil then
		return open_row(state, ctx, row)
	elseif event.ev == "select" then
		return select_event(state, ctx, row)
	elseif event.ev == "action" and event.act == "page" and type(event.value) == "string" then
		return switch_page(state, ctx, event.value)
	elseif event.ev == "action" and event.act == "reset_keys" then
		local focused = copy(state)
		focused.focus = RESET_KEYS_ROW
		return open_row(focused, ctx, RESET_KEYS_ROW)
	elseif event.ev == "action" and event.act == "close" then
		if event.value == nil then
			return state, { { kind = "exit" } }
		end
		if state.editing == nil then
			return state, {}
		end
		local out = closed(state)
		out.notice = nil
		return out, render()
	end
	return state, {}
end

function M.reduce(state: State, ctx: Context, event: Event): (State, { Effect })
	if event.kind == "key" then
		return key_event(state, ctx, event)
	elseif event.kind == "ui" then
		return ui_event(state, ctx, event)
	end
	return state, {}
end

return M
