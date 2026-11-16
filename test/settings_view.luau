--!strict
-- Settings page props: the machine each page names, how list keys show, and the hint of a selected text row. Pure
-- test harness: no `tern` (the props are plain tables; only `view` wraps them in a node).

local Protocol = require("../lib/shared/protocol")
local Settings = require("../lib/host/settings")
local SettingsView = require("../lib/host/settings_view")

local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local CFG = Protocol.cfg_msg({
	machine = "laptop",
	em = "A",
	chords = { toggle_focus = { "ctrl+alt+j" }, hide_list = { "ctrl+alt+shift+j" }, last_tab = { "ctrl+alt+;" } },
	defaults = { toggle_focus = "ctrl+alt+j", hide_list = "ctrl+alt+shift+j", last_tab = "ctrl+alt+;" },
})

local function context(keys: { [string]: string }): Settings.Context
	return { settings = { agent = "codex", keys = keys }, readonly = false, cfg = CFG }
end

local function key(name: string, text: string?): Settings.Event
	return { kind = "key", name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
end

local function on_page(page: string): Settings.State
	local state = Settings.new()
	state.page = page
	return state
end

local function names(text: any, machine: string): boolean
	return type(text) == "string" and string.find(text, machine, 1, true) ~= nil
end

local function nav_label(props: { [string]: any }, page: string): any
	for _, item in props.pages do
		if item.id == page then
			return item.label
		end
	end
	return nil
end

local function row(props: { [string]: any }, id: string): any
	for _, section in props.sections do
		for _, item in section.rows do
			if item.id == id then
				return item
			end
		end
	end
	return nil
end

-- Every page names the machine its values belong to: the list's host, or the window's machine.
do
	local ctx = context({})
	for _, page in { "agents", "window", "keys" } do
		local props = SettingsView.props(on_page(page), ctx, "devbox")
		local machine = if page == "window" then "laptop" else "devbox"
		check(names(nav_label(props, page), machine), "the " .. page .. " nav label names " .. machine)
		check(names(props.lead, machine), "the " .. page .. " lead names " .. machine)
	end
end

-- A list key shows exactly as bound, in a text field that gets Tern's Reset once the key is changed.
do
	local props = SettingsView.props(on_page("keys"), context({ new = "A" }), "devbox")
	local new, down, next_group = row(props, "new"), row(props, "down"), row(props, "next_group")
	check(new.control.value == "A", "a changed key shows as bound")
	check(
		new.control.k == "text" and new.changed == true and new.defaultLabel == "n",
		"a changed key row is a text field naming its default, which Tern draws with Reset"
	)
	check(down.control.value == "j" and next_group.control.value == "J", "j and J show as different keys")
	check(down.changed == false, "an unchanged key row offers no Reset")
end

-- A text row's hint says while its whole draft is selected, and changes back once the selection drops.
do
	local ctx = context({})
	local state = select(1, Settings.reduce(Settings.new(), ctx, { kind = "ui", ev = "activate", item = "other" }))
	local selected = row(SettingsView.props(state, ctx, "devbox"), "other").hint
	state = select(1, Settings.reduce(state, ctx, key("left")))
	check(
		selected ~= row(SettingsView.props(state, ctx, "devbox"), "other").hint,
		"the agent-id row's hint follows its selection"
	)

	local chord = select(1, Settings.reduce(Settings.new(), ctx, key("]", "]")))
	chord = select(1, Settings.reduce(chord, ctx, key("j", "j")))
	chord = select(1, Settings.reduce(chord, ctx, key("enter")))
	local chord_selected = row(SettingsView.props(chord, ctx, "devbox"), "toggle_focus").hint
	chord = select(1, Settings.reduce(chord, ctx, key("end")))
	check(
		chord_selected ~= row(SettingsView.props(chord, ctx, "devbox"), "toggle_focus").hint,
		"a chord row's hint follows its selection"
	)
end

-- The editing prop Tern reads keeps to its documented keys; the selection stays in the page's own state.
do
	local ctx = context({})
	local state = select(1, Settings.reduce(Settings.new(), ctx, { kind = "ui", ev = "activate", item = "other" }))
	local editing = SettingsView.props(state, ctx, "devbox").editing
	local documented: { [string]: boolean } = { row = true, option = true, draft = true, cursor = true }
	local only_documented = editing ~= nil
	if editing ~= nil then
		for field in editing do
			if documented[field] == nil then
				only_documented = false
			end
		end
	end
	check(state.all_selected == true and only_documented, "the selection flag is not in the editing prop")
end

print("Settings view: " .. checks .. " checks passed")
