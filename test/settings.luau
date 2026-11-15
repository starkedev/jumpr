--!strict
-- Settings reducer and block-glue tests. Pure test harness: no `tern`.

local Settings = require("../lib/host/settings")
local Protocol = require("../lib/shared/protocol")
local SettingsBlock = require("../lib/host/settings_block")

local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function context(agent: string, readonly: boolean?, cfg: Protocol.WindowCfg?): Settings.Context
	return { settings = { agent = agent, keys = {} }, readonly = readonly == true, cfg = cfg }
end

local function key(name: string, text: string?): Settings.Event
	return { kind = "key", name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
end

local function ui(ev: string, item: string?, act: string?, value: any?): Settings.Event
	return { kind = "ui", ev = ev, item = item, act = act, value = value }
end

type Mods = { ctrl: boolean?, alt: boolean?, shift: boolean?, meta: boolean? }

-- A key pressed with modifiers, as Tern delivers a chord: the key's name and no text.
local function pressed(name: string, mods: Mods): Settings.Event
	return {
		kind = "key",
		name = name,
		ctrl = mods.ctrl == true,
		alt = mods.alt == true,
		shift = mods.shift == true,
		meta = mods.meta == true,
	}
end

local function effect(effects: { Settings.Effect }, kind: string): Settings.Effect?
	for _, item in effects do
		if item.kind == kind then
			return item
		end
	end
	return nil
end

local function clear_draft(state: Settings.State, ctx: Settings.Context): Settings.State
	local out = state
	local draft = if out.editing ~= nil then out.editing.draft or "" else ""
	for _ = 1, #draft do
		out = select(1, Settings.reduce(out, ctx, key("backspace")))
	end
	return out
end

local function type_text(state: Settings.State, ctx: Settings.Context, text: string): Settings.State
	local out = state
	for i = 1, #text do
		local ch = string.sub(text, i, i)
		out = select(1, Settings.reduce(out, ctx, key(ch, ch)))
	end
	return out
end

-- Row movement accepts vim keys and arrows and stops at the ends.
do
	local ctx = context("omp")
	local state = Settings.new()
	state = select(1, Settings.reduce(state, ctx, key("j", "j")))
	check(state.focus == "other", "j moves to the other-agent row")
	state = select(1, Settings.reduce(state, ctx, key("down")))
	check(state.focus == "other", "down stops at the last row")
	state = select(1, Settings.reduce(state, ctx, key("k", "k")))
	check(state.focus == "agent", "k moves to the default-agent row")
	state = select(1, Settings.reduce(state, ctx, key("up")))
	check(state.focus == "agent", "up stops at the first row")
end

-- Settings navigation keeps its fixed keys even when list actions override them.
do
	local ctx = context("omp")
	ctx.settings.keys = { down = "a", up = "b", settings = "c" }
	local state = Settings.new()
	state = select(1, Settings.reduce(state, ctx, key("j", "j")))
	check(state.focus == "other", "j remains the settings next-row key under list overrides")
	state = select(1, Settings.reduce(state, ctx, key("k", "k")))
	check(state.focus == "agent", "k remains the settings previous-row key under list overrides")
	state = select(1, Settings.reduce(state, ctx, key("]", "]")))
	check(state.page == "window", "] remains the settings next-page key under list overrides")
	state = select(1, Settings.reduce(state, ctx, key("[", "[")))
	check(state.page == "agents", "[ remains the settings previous-page key under list overrides")
end

-- Enter opens the choice, j highlights Claude, and Enter chooses it.
do
	local ctx = context("omp")
	local state, effects = Settings.reduce(Settings.new(), ctx, key("enter"))
	check(state.editing ~= nil and state.editing.row == "agent", "enter opens the agent choice")
	check(state.editing ~= nil and state.editing.option == "omp", "the current agent starts highlighted")
	state = select(1, Settings.reduce(state, ctx, key("j", "j")))
	check(state.editing ~= nil and state.editing.option == "claude", "j moves the choice highlight")
	state, effects = Settings.reduce(state, ctx, key("enter"))
	local set = effect(effects, "set_agent")
	check(set ~= nil and set.agent == "claude", "enter chooses the highlighted agent")
	check(state.editing == nil, "choosing an agent closes the menu")
end

-- Space activates the focused text row with the current value ready to edit.
do
	local ctx = context("codex")
	local state = Settings.new()
	state = select(1, Settings.reduce(state, ctx, key("down")))
	state = select(1, Settings.reduce(state, ctx, key("space", " ")))
	check(state.editing ~= nil and state.editing.row == "other", "space opens the focused text row")
	check(state.editing ~= nil and state.editing.draft == "codex", "the text editor starts with the current agent")
	check(state.editing ~= nil and state.editing.cursor == 5, "the text cursor starts at the end")
end

-- Pointer hover previews a menu option and does not choose it.
do
	local ctx = context("omp")
	local state = Settings.new()
	state = select(1, Settings.reduce(state, ctx, ui("select", "other")))
	check(state.focus == "other", "a row pointer selection moves focus")
	local effects
	state, effects = Settings.reduce(state, ctx, ui("select", "agent=codex"))
	check(state.focus == "agent", "a menu option pointer selection focuses its row")
	check(state.editing ~= nil and state.editing.option == "codex", "a menu option pointer selection highlights it")
	check(effect(effects, "set_agent") == nil, "pointing at a menu option does not choose it")
end

-- A menu click is a change on the row, and Reset's nil value restores omp.
do
	local ctx = context("omp")
	local state, effects = Settings.reduce(Settings.new(), ctx, ui("change", "agent", nil, "codex"))
	local set = effect(effects, "set_agent")
	check(set ~= nil and set.agent == "codex", "a menu click chooses that agent")
	state, effects = Settings.reduce(state, context("codex"), ui("change", "agent", nil, nil))
	set = effect(effects, "set_agent")
	check(set ~= nil and set.agent == "omp", "pointer Reset restores omp")
	state, effects = Settings.reduce(state, context("omp"), ui("change", "other", nil, "my-agent"))
	set = effect(effects, "set_agent")
	check(set ~= nil and set.agent == "my-agent", "a change on the custom row chooses that agent")
	state, effects = Settings.reduce(state, context("my-agent"), ui("change", "other", nil, nil))
	set = effect(effects, "set_agent")
	check(set ~= nil and set.agent == "omp", "a nil change on the custom row restores omp")
	state, effects = Settings.reduce(state, context("omp"), ui("change", "agent", nil, "a b"))
	check(state.notice ~= nil and effect(effects, "set_agent") == nil, "an invalid pointer choice is refused")
end

-- Pointer change chooses an agent, and Reset's nil value restores omp.
do
	local ctx = context("omp")
	local state, effects = Settings.reduce(Settings.new(), ctx, ui("change", "agent", nil, "claude"))
	local set = effect(effects, "set_agent")
	check(set ~= nil and set.agent == "claude", "pointer change chooses an agent")
	state, effects = Settings.reduce(state, context("claude"), ui("change", "agent", nil, nil))
	set = effect(effects, "set_agent")
	check(set ~= nil and set.agent == "omp", "pointer Reset restores omp")
end

-- Closing a menu is distinct from closing the page.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, key("enter")))
	local effects
	state, effects = Settings.reduce(state, ctx, ui("action", nil, "close", "agent"))
	check(state.editing == nil, "a row close closes the menu")
	check(effect(effects, "exit") == nil, "a row close does not close the page")
	state, effects = Settings.reduce(state, ctx, ui("action", nil, "close", nil))
	check(effect(effects, "exit") ~= nil, "a bare close closes the page")
end

-- The custom field accepts a valid ACP agent id.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	state = clear_draft(state, ctx)
	state = type_text(state, ctx, "my-agent")
	local effects
	state, effects = Settings.reduce(state, ctx, key("enter"))
	local set = effect(effects, "set_agent")
	check(set ~= nil and set.agent == "my-agent", "a valid custom agent is chosen")
	check(state.editing == nil and state.notice == nil, "a valid custom agent closes cleanly")
end

-- Invalid characters and a leading hyphen are refused as they arrive, not after commit.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	state = clear_draft(state, ctx)
	local effects
	state, effects = Settings.reduce(state, ctx, key("a", "a"))
	state, effects = Settings.reduce(state, ctx, key("space", " "))
	check(state.editing ~= nil and state.editing.draft == "a", "a space is not inserted")
	check(state.notice ~= nil and effect(effects, "set_agent") == nil, "a space shows a character warning")
	state = clear_draft(state, ctx)
	state, effects = Settings.reduce(state, ctx, key("paste", "--continue"))
	check(state.editing ~= nil and state.editing.draft == "", "a leading hyphen is not inserted")
	check(state.notice ~= nil and effect(effects, "set_agent") == nil, "a leading hyphen shows a start warning")
end

-- Escape closes the editor first and closes the page only on the next press.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	local effects
	state, effects = Settings.reduce(state, ctx, key("escape"))
	check(state.editing == nil and effect(effects, "exit") == nil, "first Escape closes the editor")
	state, effects = Settings.reduce(state, ctx, key("escape"))
	check(effect(effects, "exit") ~= nil, "second Escape closes the page")
end

-- Modified printable keys do not edit text.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	local before = if state.editing ~= nil then state.editing.draft else nil
	state = select(
		1,
		Settings.reduce(state, ctx, {
			kind = "key",
			name = "x",
			text = nil,
			ctrl = true,
			alt = false,
			shift = false,
			meta = false,
		})
	)
	check(state.editing ~= nil and state.editing.draft == before, "a modified key does not insert text")
end

-- Read-only settings refuse both pointer and keyboard commits with a warning.
do
	local ctx = context("omp", true)
	local state, effects = Settings.reduce(Settings.new(), ctx, ui("change", "agent", nil, "claude"))
	check(state.notice ~= nil, "read-only pointer change shows a warning")
	check(effect(effects, "set_agent") == nil, "read-only pointer change is refused")
	state = select(1, Settings.reduce(Settings.new(), ctx, key("enter")))
	state = select(1, Settings.reduce(state, ctx, key("j", "j")))
	state, effects = Settings.reduce(state, ctx, key("enter"))
	check(state.notice ~= nil, "read-only keyboard change shows a warning")
	check(effect(effects, "set_agent") == nil, "read-only keyboard change is refused")
end

-- Once End drops the opening selection, text editing uses the stored caret: delete, arrows, home and end.
do
	local ctx = context("codex")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	state = select(1, Settings.reduce(state, ctx, key("end")))
	state = select(1, Settings.reduce(state, ctx, key("left")))
	state = select(1, Settings.reduce(state, ctx, key("left")))
	check(state.editing ~= nil and state.editing.cursor == 3, "left moves the caret back")
	state = select(1, Settings.reduce(state, ctx, key("X", "X")))
	check(state.editing ~= nil and state.editing.draft == "codXex", "a character inserts at the caret")
	state = select(1, Settings.reduce(state, ctx, key("backspace")))
	check(
		state.editing ~= nil and state.editing.draft == "codex" and state.editing.cursor == 3,
		"backspace deletes before the caret"
	)
	state = select(1, Settings.reduce(state, ctx, key("delete")))
	check(
		state.editing ~= nil and state.editing.draft == "codx" and state.editing.cursor == 3,
		"delete removes the character after the caret"
	)
	state = select(1, Settings.reduce(state, ctx, key("home")))
	check(state.editing ~= nil and state.editing.cursor == 0, "home moves the caret to the start")
	state = select(1, Settings.reduce(state, ctx, key("end")))
	check(state.editing ~= nil and state.editing.cursor == 4, "end moves the caret to the end")
end

-- Paste keeps only agent-id characters and stops at 32, with a specific warning.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	state = clear_draft(state, ctx)
	local effects
	state, effects = Settings.reduce(state, ctx, key("paste", "my-\nagent extra"))
	check(
		state.editing ~= nil and state.editing.draft == "my-agentextra",
		"paste drops newlines, spaces and other invalid characters"
	)
	check(state.notice ~= nil and effect(effects, "set_agent") == nil, "a filtered paste warns instead of committing")
	state = clear_draft(state, ctx)
	state, effects = Settings.reduce(state, ctx, key("paste", string.rep("a", 40)))
	check(state.editing ~= nil and state.editing.draft == string.rep("a", 32), "paste stops at 32 characters")
	check(state.notice == "Agent ids are at most 32 characters.", "a long paste names the length limit")
	check(effect(effects, "set_agent") == nil, "a long paste is not committed by itself")
end

-- Opening the agent-id row selects its whole draft: typed text or a paste replaces it, Backspace or Delete clears it,
-- and Escape closes the editor with its selection.
do
	local ctx = context("codex")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	check(state.all_selected == true, "opening the agent-id row selects its whole draft")
	local typed = select(1, Settings.reduce(state, ctx, key("x", "x")))
	check(
		typed.editing ~= nil and typed.editing.draft == "x" and typed.editing.cursor == 1 and typed.all_selected == nil,
		"a typed character replaces the selected draft"
	)
	local pasted = select(1, Settings.reduce(state, ctx, key("paste", "my-agent")))
	check(pasted.editing ~= nil and pasted.editing.draft == "my-agent", "a paste replaces the selected draft")
	for _, name in { "backspace", "delete" } do
		local cleared = select(1, Settings.reduce(state, ctx, key(name)))
		check(
			cleared.editing ~= nil
				and cleared.editing.draft == ""
				and cleared.editing.cursor == 0
				and cleared.all_selected == nil,
			name .. " clears the selected draft"
		)
	end
	local closed = select(1, Settings.reduce(state, ctx, key("escape")))
	check(closed.editing == nil and closed.all_selected == nil, "Escape closes the editor and its selection")
end

-- Left, Right, Home and End drop the selection and leave the caret at that end of the unchanged draft.
do
	local ctx = context("codex")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	local moves = {
		{ name = "left", at = 0 },
		{ name = "home", at = 0 },
		{ name = "right", at = 5 },
		{ name = "end", at = 5 },
	}
	for _, move in moves do
		local moved = select(1, Settings.reduce(state, ctx, key(move.name)))
		check(
			moved.editing ~= nil
				and moved.editing.draft == "codex"
				and moved.editing.cursor == move.at
				and moved.all_selected == nil,
			move.name .. " drops the selection with the caret at that end"
		)
	end
	local moved = select(1, Settings.reduce(state, ctx, key("left")))
	moved = select(1, Settings.reduce(moved, ctx, key("X", "X")))
	check(moved.editing ~= nil and moved.editing.draft == "Xcodex", "after an arrow, typing inserts at the caret")
end

-- Refused text leaves the selected draft whole and selected, and says why.
do
	local ctx = context("codex")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	for _, refused in { key("space", " "), key("paste", "-x") } do
		local out, effects = Settings.reduce(state, ctx, refused)
		check(
			out.editing ~= nil and out.editing.draft == "codex" and out.all_selected == true,
			"refused text keeps the selected draft"
		)
		check(out.notice ~= nil and effect(effects, "set_agent") == nil, "refused text shows a warning")
	end
end

-- Ctrl+A or Cmd+A selects the agent-id row's whole draft again, so typing replaces it.
do
	local ctx = context("codex")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("activate", "other")))
	state = select(1, Settings.reduce(state, ctx, key("left")))
	local select_alls: { Mods } = { { ctrl = true }, { meta = true } }
	for _, mods in select_alls do
		local again = select(1, Settings.reduce(state, ctx, pressed("a", mods)))
		check(
			again.all_selected == true and again.editing ~= nil and again.editing.cursor == 5,
			"select-all selects the whole draft again"
		)
		again = select(1, Settings.reduce(again, ctx, key("z", "z")))
		check(again.editing ~= nil and again.editing.draft == "z", "typing after select-all replaces the draft")
	end
end

local function window_cfg(err: string?): Protocol.WindowCfg
	return Protocol.cfg_msg({
		machine = "laptop",
		em = "A",
		chords = {
			toggle_focus = { "ctrl+alt+j" },
			hide_list = { "ctrl+alt+shift+j" },
			last_tab = { "ctrl+alt+;" },
		},
		defaults = {
			toggle_focus = "ctrl+alt+j",
			hide_list = "ctrl+alt+shift+j",
			last_tab = "ctrl+alt+;",
		},
		err = err,
	})
end

-- Initial state performs no window read.
do
	local state, effects = Settings.reduce(Settings.new(), context("omp"), { kind = "init" })
	check(state.page == "agents", "settings open on the agents page")
	check(#effects == 0, "settings init emits no request")
end

-- Keyboard and pointer navigation read window settings only when they switch pages.
do
	local ctx = context("omp")
	local state, effects = Settings.reduce(Settings.new(), ctx, key("]", "]"))
	local request = effect(effects, "cfg")
	check(state.page == "window", "] switches to the window page")
	check(
		request ~= nil and request.fields ~= nil and request.fields.op == "read",
		"switching pages requests window settings"
	)
	state, effects = Settings.reduce(state, ctx, key("[", "["))
	check(state.page == "agents" and effect(effects, "cfg") == nil, "[ switches back without a window read")
	state, effects = Settings.reduce(state, ctx, key("[", "["))
	check(state.page == "keys" and effect(effects, "cfg") == nil, "[ wraps back to the keys page")
	state, effects = Settings.reduce(state, ctx, key("[", "["))
	request = effect(effects, "cfg")
	check(
		state.page == "window" and request ~= nil and request.fields ~= nil and request.fields.op == "read",
		"[ moves back to the window page and reads it"
	)
	state, effects = Settings.reduce(state, ctx, ui("action", nil, "page", "agents"))
	check(state.page == "agents" and effect(effects, "cfg") == nil, "clicking Agents sends no window read")
	state, effects = Settings.reduce(state, ctx, ui("action", nil, "page", "window"))
	request = effect(effects, "cfg")
	check(
		request ~= nil and request.fields ~= nil and request.fields.op == "read",
		"clicking Window requests its settings"
	)
end

-- A list key captures one visible character and emits its action and key.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, key("]", "]")))
	state = select(1, Settings.reduce(state, ctx, key("]", "]")))
	state = select(1, Settings.reduce(state, ctx, ui("select", "new")))
	state = select(1, Settings.reduce(state, ctx, key("enter")))
	check(state.editing ~= nil and state.editing.row == "new", "Enter waits for the new key")
	local effects
	state, effects = Settings.reduce(state, ctx, key("a", "a"))
	local set = effect(effects, "set_key")
	check(set ~= nil and set.action == "new" and set.key == "a", "a is captured for the new action")
	check(state.editing == nil and state.notice == nil, "an accepted key closes capture cleanly")
end

-- A taken key warns without emitting, and Backspace restores the default.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("action", nil, "page", "keys")))
	state = select(1, Settings.reduce(state, ctx, ui("select", "new")))
	state = select(1, Settings.reduce(state, ctx, key("enter")))
	local effects
	state, effects = Settings.reduce(state, ctx, key("j", "j"))
	check(state.notice == "taken by next row", "a taken key names the action that owns it")
	check(
		state.editing ~= nil and effect(effects, "set_key") == nil,
		"a taken key keeps capture open and emits nothing"
	)
	state, effects = Settings.reduce(state, ctx, key("backspace"))
	local set = effect(effects, "set_key")
	check(set ~= nil and set.action == "new" and set.key == nil, "Backspace restores the action's default key")
	check(state.editing == nil and state.notice == nil, "restoring the default closes capture cleanly")
end

-- Reset all keys emits its dedicated effect from the action row.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("action", nil, "page", "keys")))
	local effects
	state = select(1, Settings.reduce(state, ctx, ui("select", "reset_keys")))
	state, effects = Settings.reduce(state, ctx, key("enter"))
	check(state.focus == "reset_keys", "Enter keeps focus on the Reset all action row")
	check(effect(effects, "reset_keys") ~= nil, "Enter on Reset all emits reset_keys")
	state, effects = Settings.reduce(state, ctx, ui("action", nil, "reset_keys", "reset_keys"))
	check(effect(effects, "reset_keys") ~= nil, "clicking Reset all emits reset_keys")
end

-- A list key's capture shows an empty field with the caret, from Enter or a click on the field, and takes no chord.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("action", nil, "page", "keys")))
	state = select(1, Settings.reduce(state, ctx, ui("select", "new")))
	local entered = select(1, Settings.reduce(state, ctx, key("enter")))
	local clicked = select(1, Settings.reduce(state, ctx, ui("activate", "new")))
	for _, opened in { entered, clicked } do
		check(
			opened.editing ~= nil
				and opened.editing.row == "new"
				and opened.editing.draft == ""
				and opened.editing.cursor == 0,
			"key capture opens on an empty draft with the caret"
		)
	end
	local after, effects = Settings.reduce(entered, ctx, pressed("x", { ctrl = true }))
	check(after.editing ~= nil and effect(effects, "set_key") == nil, "a chord is not captured as a list key")
end

-- Reset on a key row restores that key's default, also during capture, and is refused when settings are read-only.
do
	local ctx = context("omp")
	local state = select(1, Settings.reduce(Settings.new(), ctx, ui("action", nil, "page", "keys")))
	local effects
	state, effects = Settings.reduce(state, ctx, ui("change", "new", nil, nil))
	local set = effect(effects, "set_key")
	check(set ~= nil and set.action == "new" and set.key == nil, "Reset on a key row restores its default")
	check(state.focus == "new" and state.notice == nil, "Reset focuses its row")
	state = select(1, Settings.reduce(state, ctx, key("enter")))
	state, effects = Settings.reduce(state, ctx, ui("change", "new", nil, nil))
	check(
		state.editing == nil and effect(effects, "set_key") ~= nil,
		"Reset during capture restores the default and ends capture"
	)
	local readonly = context("omp", true)
	state = select(1, Settings.reduce(Settings.new(), readonly, ui("action", nil, "page", "keys")))
	state, effects = Settings.reduce(state, readonly, ui("change", "new", nil, nil))
	check(effect(effects, "set_key") == nil, "read-only settings refuse a key row's Reset")
	check(state.notice ~= nil, "a refused Reset shows a warning")
end

-- Window rows follow the protocol action order after the Esc switch.
do
	local cfg = window_cfg(nil)
	local ctx = context("omp", false, cfg)
	local state = select(1, Settings.reduce(Settings.new(), ctx, key("]", "]")))
	check(state.focus == "esc", "the Esc switch is the first window row")
	for _, action in Protocol.CHORD_ACTIONS do
		state = select(1, Settings.reduce(state, ctx, key("j", "j")))
		check(state.focus == action.id, action.id .. " follows protocol chord order")
	end
end

-- Flipping Esc off emits mode B.
do
	local cfg = window_cfg(nil)
	local ctx = context("omp", false, cfg)
	local state = select(1, Settings.reduce(Settings.new(), ctx, key("]", "]")))
	local effects
	state, effects = Settings.reduce(state, ctx, key("enter"))
	local request = effect(effects, "cfg")
	check(
		request ~= nil and request.fields ~= nil and request.fields.op == "esc" and request.fields.v == "B",
		"turning the Esc switch off sends mode B"
	)
	check(state.editing == nil, "the Esc switch does not open an editor")
end

-- A typed chord commits through the bind operation, and Reset uses reset.
do
	local cfg = window_cfg(nil)
	local ctx = context("omp", false, cfg)
	local state = select(1, Settings.reduce(Settings.new(), ctx, key("]", "]")))
	state = select(1, Settings.reduce(state, ctx, key("j", "j")))
	state = select(1, Settings.reduce(state, ctx, key("enter")))
	state = clear_draft(state, ctx)
	state = type_text(state, ctx, "ctrl+alt+k")
	local effects
	state, effects = Settings.reduce(state, ctx, key("enter"))
	local request = effect(effects, "cfg")
	check(
		request ~= nil
			and request.fields ~= nil
			and request.fields.op == "bind"
			and request.fields.action == "toggle_focus"
			and request.fields.chord == "ctrl+alt+k",
		"Enter commits the typed chord"
	)
	state, effects = Settings.reduce(state, ctx, ui("change", "toggle_focus", nil, nil))
	request = effect(effects, "cfg")
	check(
		request ~= nil
			and request.fields ~= nil
			and request.fields.op == "reset"
			and request.fields.action == "toggle_focus",
		"pointer Reset restores the chord default"
	)
end

-- Whether two field tables hold the same fields.
local function same_fields(a: { [string]: string }, b: { [string]: string }): boolean
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- An open chord row takes a pressed chord in Tern's grammar in place of its draft; a closed row ignores it.
do
	local cfg = window_cfg(nil)
	local ctx = context("omp", false, cfg)
	local state = select(1, Settings.reduce(Settings.new(), ctx, key("]", "]")))
	state = select(1, Settings.reduce(state, ctx, key("j", "j")))
	local idle, idle_effects = Settings.reduce(state, ctx, pressed("k", { ctrl = true, alt = true }))
	check(idle.editing == nil and #idle_effects == 0, "a chord pressed on a closed row does nothing")
	state = select(1, Settings.reduce(state, ctx, key("enter")))
	check(state.all_selected == true, "opening a chord row selects its whole draft")
	local cases: { { name: string, mods: Mods, chord: string } } = {
		{ name = "k", mods = { ctrl = true, alt = true }, chord = "ctrl+alt+k" },
		{ name = "k", mods = { ctrl = true, alt = true, shift = true }, chord = "ctrl+alt+shift+k" },
		{ name = "j", mods = { meta = true }, chord = "cmd+j" },
		{ name = "j", mods = { shift = true, meta = true }, chord = "shift+cmd+j" },
		{ name = "\\", mods = { ctrl = true, alt = true, meta = true }, chord = "ctrl+alt+cmd+\\" },
		{ name = ";", mods = { ctrl = true, alt = true }, chord = "ctrl+alt+;" },
		{ name = "+", mods = { ctrl = true }, chord = "ctrl+plus" },
		{ name = "a", mods = { ctrl = true }, chord = "ctrl+a" },
	}
	for _, case in cases do
		local captured = select(1, Settings.reduce(state, ctx, pressed(case.name, case.mods)))
		check(
			captured.editing ~= nil
				and captured.editing.draft == case.chord
				and captured.editing.cursor == #case.chord
				and captured.all_selected == nil,
			"pressing " .. case.chord .. " puts it in place of the chord draft"
		)
	end
end

-- Enter after a pressed chord sends the same bind as the chord typed out.
do
	local cfg = window_cfg(nil)
	local ctx = context("omp", false, cfg)
	local opened = select(1, Settings.reduce(Settings.new(), ctx, key("]", "]")))
	opened = select(1, Settings.reduce(opened, ctx, key("j", "j")))
	opened = select(1, Settings.reduce(opened, ctx, key("enter")))
	local captured = select(1, Settings.reduce(opened, ctx, pressed("k", { ctrl = true, alt = true, shift = true })))
	local typed = type_text(opened, ctx, "ctrl+alt+shift+k")
	local capture_effects: { Settings.Effect } = select(2, Settings.reduce(captured, ctx, key("enter")))
	local typed_effects: { Settings.Effect } = select(2, Settings.reduce(typed, ctx, key("enter")))
	local from_capture = effect(capture_effects, "cfg")
	local from_typing = effect(typed_effects, "cfg")
	local capture_fields = if from_capture ~= nil then from_capture.fields else nil
	local typed_fields = if from_typing ~= nil then from_typing.fields else nil
	check(
		capture_fields ~= nil
			and typed_fields ~= nil
			and capture_fields.op == "bind"
			and capture_fields.chord == "ctrl+alt+shift+k"
			and same_fields(capture_fields, typed_fields),
		"Enter after a pressed chord sends the bind the typed chord sends"
	)
end

-- Each block owns its sender, sends from the block receiving the key, and checks cfg replies.
do
	local cfg = window_cfg(nil)
	local refused = window_cfg("taken by editor.copy")
	refused.chords.toggle_focus = { "ctrl+alt+x" }
	local newer: any = table.clone(cfg)
	newer.p = Protocol.P + 1
	local decoded: { [string]: any } = { good = cfg, refused = refused, newer = newer }
	local null = {}
	local sent: { any } = {}
	local renders = 0
	local sender_n = 0
	local key_changes: { any } = {}
	local reset_calls = 0
	local compat = {
		block_exit = function(_cx: any, _code: number): (boolean, string?)
			return true, nil
		end,
		json_null = function(): any
			return null
		end,
		json_decode = function(text: string): (any, string?)
			local value = decoded[text]
			return value, if value == nil then "bad json" else nil
		end,
		render = function(_cx: any): (boolean, string?)
			renders += 1
			return true, nil
		end,
	}
	local list = {
		settings = function()
			return { agent = "omp", keys = {} }
		end,
		readonly = function(): boolean
			return false
		end,
		new_sender = function(): any
			sender_n += 1
			return { b = "settings-" .. tostring(sender_n) }
		end,
		send_from = function(cx: any, sender: any, verb: string, fields: { [string]: string }): (boolean, string?)
			table.insert(sent, { cx = cx, sender = sender, verb = verb, fields = fields })
			return true, nil
		end,
		set_agent = function(_kind: string): string?
			return nil
		end,
		set_key = function(action: string, bound: string?): string?
			table.insert(key_changes, { action = action, key = bound })
			return if bound == "x" then "list refused the key" else nil
		end,
		reset_keys = function(): string?
			reset_calls += 1
			return "list refused reset"
		end,
		host_name = function(): string?
			return "devbox"
		end,
	}
	local api = SettingsBlock.new(compat :: any, list :: any)
	local cx_a: any = { id = "a" }
	local cx_b: any = { id = "b" }
	local a = api.open(cx_a, {})
	local b = api.open(cx_b, {})
	check(#sent == 0, "opening settings sends no cfg request")
	check(a.sender ~= b.sender, "settings blocks have separate senders")
	api.key(a, key("]", "]") :: any, cx_a)
	api.key(b, key("]", "]") :: any, cx_b)
	check(
		#sent == 2
			and sent[1].cx == cx_a
			and sent[1].sender == a.sender
			and sent[2].cx == cx_b
			and sent[2].sender == b.sender,
		"each cfg request uses the sender and window that received the key"
	)
	api.event(a, { ev = "action", act = "cfg", value = "good" } :: any, cx_a)
	check(a.cfg == cfg and a.state.focus == "esc", "an accepted cfg fills the waiting block")
	api.event(a, { ev = "action", act = "cfg", value = "refused" } :: any, cx_a)
	check(a.cfg == cfg, "a refused cfg operation keeps the previous values")
	check(a.state.notice == "taken by editor.copy", "a refused cfg operation shows its row warning")
	api.event(a, { ev = "action", act = "cfg", value = "newer" } :: any, cx_a)
	check(a.cfg == cfg, "a cfg from another protocol version is not stored")
	check(
		a.state.notice ~= nil and string.find(a.state.notice, "update Jumpr", 1, true) ~= nil,
		"a cfg from another protocol version shows the update notice"
	)
	check(renders == 3, "each cfg reply renders its block")
	api.event(a, { ev = "action", act = "page", value = "keys" } :: any, cx_a)
	api.event(a, { ev = "select", item = "new" } :: any, cx_a)
	api.key(a, key("enter") :: any, cx_a)
	api.key(a, key("a", "a") :: any, cx_a)
	check(
		#key_changes == 1 and key_changes[1].action == "new" and key_changes[1].key == "a",
		"the settings block applies a captured key through the list"
	)
	api.event(a, { ev = "select", item = "new" } :: any, cx_a)
	api.key(a, key("enter") :: any, cx_a)
	api.key(a, key("x", "x") :: any, cx_a)
	check(a.state.notice == "list refused the key", "a list key refusal becomes the row notice")
	api.event(a, { ev = "action", act = "reset_keys", value = "reset_keys" } :: any, cx_a)
	check(reset_calls == 1, "the settings block applies Reset all through the list")
	check(a.state.notice == "list refused reset", "a Reset all refusal becomes the row notice")
	api.event(a, { ev = "change", item = "next_group", value = null } :: any, cx_a)
	check(
		#key_changes == 3 and key_changes[3].action == "next_group" and key_changes[3].key == nil,
		"the settings block applies a key row's Reset through the list"
	)
end

print("Settings: " .. checks .. " checks passed")
