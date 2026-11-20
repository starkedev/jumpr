--!strict
-- Behavioral checks for the global chord defaults, validation, mapping and write plans. Pure: no `tern`.

local Chords = require("../lib/window/chords")
local Protocol = require("../lib/shared/protocol")

local checks = 0
local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function same(actual: { string }, expected: { string }): boolean
	if #actual ~= #expected then
		return false
	end
	for i, value in expected do
		if actual[i] ~= value then
			return false
		end
	end
	return true
end

local function count(values: { [string]: string }): number
	local n = 0
	for _ in values do
		n += 1
	end
	return n
end

-- Action ids use the plugin namespace exactly once.
check(Chords.id("toggle_focus") == "plugin.jumpr.toggle_focus", "the toggle action gets its full Tern id")
check(Chords.id("hide_list") == "plugin.jumpr.hide_list", "the hide action gets its full Tern id")

-- macOS and iOS share Command defaults; every other OS gets Ctrl+Alt defaults.
do
	local mac = Chords.defaults("macos")
	local ios = Chords.defaults("ios")
	local linux = Chords.defaults("linux")
	local windows = Chords.defaults("windows")
	check(
		mac.toggle_focus == "cmd+j"
			and mac.hide_list == "cmd+shift+j"
			and mac.last_tab == "cmd+\\"
			and mac.other_panes == "cmd+`",
		"macOS gets the four Command chords"
	)
	check(
		ios.toggle_focus == "cmd+j"
			and ios.hide_list == "cmd+shift+j"
			and ios.last_tab == "cmd+\\"
			and ios.other_panes == "cmd+`",
		"iOS gets the four Command chords"
	)
	check(
		linux.toggle_focus == "ctrl+alt+j"
			and linux.hide_list == "ctrl+alt+shift+j"
			and linux.last_tab == "ctrl+alt+;"
			and linux.other_panes == "super+`",
		"Linux gets the three Ctrl+Alt chords and Super+`"
	)
	check(
		windows.toggle_focus == "ctrl+alt+j"
			and windows.hide_list == "ctrl+alt+shift+j"
			and windows.last_tab == "ctrl+alt+;"
			and windows.other_panes == "super+`",
		"Windows gets the three Ctrl+Alt chords and Super+`"
	)
	check(count(mac) == #Protocol.CHORD_ACTIONS, "defaults contain one chord for every declared global action")
end

-- Chord validation accepts the bounded grammar and requires a modifier separator.
do
	check(Chords.valid_chord("ctrl+alt+k"), "an ordinary modifier chord is valid")
	check(Chords.valid_chord("cmd+\\"), "a backslash chord is valid")
	for _, key in { ";", ",", ".", "/", "[", "]", "'", "`", "=", "-", "#", "é" } do
		check(Chords.valid_chord("ctrl+" .. key), "a chord on the " .. key .. " key is valid")
	end
	check(Chords.valid_chord("ctrl+" .. string.rep("a", 35)), "a 40-character chord is valid")
	check(not Chords.valid_chord("ctrl+" .. string.rep("a", 36)), "a 41-character chord is refused")
	check(not Chords.valid_chord(""), "an empty chord is refused")
	check(not Chords.valid_chord("escape"), "a chord without a plus is refused")
	check(not Chords.valid_chord("ctrl+alt k"), "a chord containing a space is refused")
	check(not Chords.valid_chord("ctrl+\127"), "a chord containing a control character is refused")
	check(not Chords.valid_chord("ctrl+a;b"), "a key that is neither one character nor a key name is refused")
end

-- A pressed chord as the settings page sends it: modifiers in the order ctrl, alt, shift, cmd, then the key as Tern's
-- key event names it, which may be a name with `_`, or `plus` for the `+` key.
do
	check(Chords.valid_chord("ctrl+alt+shift+cmd+page_up"), "every modifier then a named key is valid")
	check(Chords.valid_chord("cmd+plus"), "the + key spelled plus is valid")
	check(Chords.valid_chord("ctrl+f12") and Chords.valid_chord("alt+digit_1"), "function and physical keys are valid")
end

-- Every part before a chord's key is a modifier Tern knows: Tern's bind raises on anything else there.
do
	check(not Chords.valid_chord("cmd+j+k"), "a letter where a modifier goes is refused")
	check(Chords.valid_chord("ctrl+alt+shift+j"), "a chord with several modifiers is valid")
	check(Chords.valid_chord("shift+cmd+j"), "Tern's own reordered spelling is valid")
	check(Chords.valid_chord("opt+super+k"), "the other names of alt and cmd are modifiers")
	check(
		not Chords.valid_chord("meta+k") and not Chords.valid_chord("control+k"),
		"a modifier name Tern does not use is refused"
	)
	check(not Chords.valid_chord("Ctrl+k"), "a modifier is spelled in lower case, as Tern spells it")
	check(
		not Chords.valid_chord("ctrl++") and not Chords.valid_chord("+k") and not Chords.valid_chord("ctrl+"),
		"an empty part is refused"
	)
end

-- A `>` sequence is valid when each of its chords is.
do
	check(Chords.valid_chord("ctrl+a>c"), "a prefix chord then a key is valid")
	check(Chords.valid_chord("ctrl+a>ctrl+c"), "a prefix chord then a chord is valid")
	check(not Chords.valid_chord("ctrl+j+k>c"), "a letter where a modifier goes is refused inside a sequence")
	check(
		not Chords.valid_chord("ctrl+a>") and not Chords.valid_chord(">ctrl+a") and not Chords.valid_chord("ctrl+a>>c"),
		"an empty chord in a sequence is refused"
	)
	check(not Chords.valid_chord("ctrl+a>shift"), "a tap after a chord is refused: Tern takes taps only among taps")
end

-- Normalisation lowercases chords and makes modifier order irrelevant while leaving the key last.
do
	check(Chords.normalise("cmd+shift+j") == "cmd+shift+j", "the default macOS hide chord is already canonical")
	check(
		Chords.normalise("SHIFT+CMD+J") == Chords.normalise("cmd+shift+j"),
		"Tern's reordered macOS hide chord has the same canonical spelling"
	)
end

-- Current mappings include shared chords, sort each action's chords and retain actions with none.
do
	local current = Chords.current({
		["cmd+j"] = { Chords.id("toggle_focus") },
		["ctrl+k"] = { "editor.copy", Chords.id("hide_list") },
		["alt+x"] = { Chords.id("hide_list"), Chords.id("toggle_focus") },
		["unused"] = {},
	})
	check(same(current.toggle_focus, { "alt+x", "cmd+j" }), "the toggle's effective chords are sorted")
	check(same(current.hide_list, { "alt+x", "ctrl+k" }), "a shared chord appears for each Jumpr action it runs")
	check(#current.last_tab == 0, "an action with no effective chord has an empty list")
end

-- A destination held by another action refuses before proposing any bind or unbind.
do
	local defaults = Chords.defaults("linux")
	local plan = Chords.plan_bind({
		[defaults.toggle_focus] = { Chords.id("toggle_focus") },
		["ctrl+alt+k"] = { Chords.id("toggle_focus"), "editor.copy" },
	}, defaults, "toggle_focus", "ctrl+alt+k")
	check(plan.refuse == "taken by editor.copy", "a conflict names the action that holds the destination chord")
	check(plan.bind == nil and #plan.unbind == 0, "a conflict proposes no writes")
end

-- A differently ordered spelling of a held destination is still a conflict.
do
	local defaults = Chords.defaults("macos")
	local plan = Chords.plan_bind({
		["shift+cmd+j"] = { "editor.copy" },
	}, defaults, "hide_list", defaults.hide_list)
	check(plan.refuse == "taken by editor.copy", "a reordered destination still names its conflicting holder")
	check(plan.bind == nil and #plan.unbind == 0, "a reordered conflict proposes no writes")
end

-- A free destination plans one bind and every old chord except that destination, in stable order.
do
	local defaults = Chords.defaults("linux")
	local plan = Chords.plan_bind({
		["ctrl+alt+z"] = { Chords.id("toggle_focus") },
		[defaults.toggle_focus] = { Chords.id("toggle_focus") },
		["ctrl+alt+k"] = { Chords.id("toggle_focus") },
		["ctrl+alt+x"] = { "editor.copy" },
	}, defaults, "toggle_focus", "ctrl+alt+k")
	check(plan.refuse == nil and plan.bind == "ctrl+alt+k", "a conflict-free destination plans its bind")
	check(
		same(plan.unbind, { "ctrl+alt+j", "ctrl+alt+z" }),
		"the bind plan removes only this action's other effective chords"
	)
end

-- A reordered spelling of the destination is not unbound as though it were a different chord.
do
	local defaults = Chords.defaults("macos")
	local plan = Chords.plan_bind({
		["shift+cmd+j"] = { Chords.id("hide_list") },
		["ctrl+alt+h"] = { Chords.id("hide_list") },
	}, defaults, "hide_list", defaults.hide_list)
	check(plan.refuse == nil and plan.bind == "cmd+shift+j", "the canonical macOS hide chord remains bindable")
	check(
		same(plan.unbind, { "ctrl+alt+h" }),
		"the reordered spelling of the destination is kept while a genuinely old chord is unbound"
	)
end

-- Reset removes only the selected action and its default suppression while preserving every unrelated override.
do
	local defaults = Chords.defaults("linux")
	local target = Chords.id("toggle_focus")
	local unrelated_list = { "editor.one", "editor.two" }
	local raw: { [string]: any } = {
		[defaults.toggle_focus] = {},
		[defaults.hide_list] = {},
		["ctrl+alt+k"] = target,
		["ctrl+alt+l"] = { target },
		["ctrl+alt+m"] = { "editor.copy", target, "editor.paste" },
		["ctrl+alt+n"] = "editor.action",
		["ctrl+alt+o"] = unrelated_list,
		["ctrl+alt+p"] = {},
	}
	local empty = { json_array = true }
	local reset = Chords.reset_table(raw, defaults, "toggle_focus", empty)
	check(reset[defaults.toggle_focus] == nil, "reset removes the empty override suppressing the selected default")
	check(reset["ctrl+alt+k"] == nil, "reset removes a string override pointing only at the selected action")
	check(reset["ctrl+alt+l"] == nil, "reset removes a list override pointing only at the selected action")
	check(
		same(reset["ctrl+alt+m"], { "editor.copy", "editor.paste" }),
		"reset removes the selected action from a shared override without removing its other actions"
	)
	check(reset["ctrl+alt+n"] == "editor.action", "reset preserves an unrelated string override")
	check(reset["ctrl+alt+o"] == unrelated_list, "reset passes an unrelated non-empty list through untouched")
	check(reset[defaults.hide_list] == empty, "reset remakes another action's empty default override as a JSON array")
	check(reset["ctrl+alt+p"] == empty, "reset remakes an unrelated empty override as a JSON array")
	check(#raw[defaults.toggle_focus] == 0, "reset does not mutate the raw default override")
	check(#raw["ctrl+alt+m"] == 3, "reset does not mutate a shared raw override")
end

-- Reset finds the selected default's suppression however Tern spells it: a bind of `cmd+shift+j` is stored as
-- `shift+cmd+j`, and a reset that missed it left the default dead.
do
	local defaults = Chords.defaults("macos")
	local empty = { json_array = true }
	local raw: { [string]: any } = { ["shift+cmd+j"] = {} }
	local reset = Chords.reset_table(raw, defaults, "hide_list", empty)
	check(reset["shift+cmd+j"] == nil, "reset removes the default's suppression spelled in Tern's order")
	local other = Chords.reset_table(raw, defaults, "toggle_focus", empty)
	check(other["shift+cmd+j"] == empty, "resetting another action keeps that suppression")
end

print("Chords: " .. checks .. " checks passed")
