--!strict
-- The jumpr:// requests a list sends its window, run against the fake window: version skew, safe command
-- construction for every launch mode, hostile launch fields, the singleton settings page, and stopping an agent.

local Fake = require("./support/fake_window")
local Chords = require("../lib/window/chords")
local Leader = require("../lib/window/leader")
local Protocol = require("../lib/shared/protocol")
local Pusher = require("../lib/window/pusher")
local Router = require("../lib/window/router")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local cx = Fake.cx
Router.set_defaults(Chords.defaults("linux"), Fake.rearm_chords)

-- This machine, and a machine devbox with deck session `deck` (one tab: a copy of the list and an agent) and a
-- second session `notes`.
Fake.host("laptop", "local")
local h = Fake.host("devbox")
local deck = Fake.session(h, "deck")
local notes = Fake.session(h, "notes")
local t1 = Fake.tab(deck)
Fake.agent(t1, "agent-a")
local copy = Fake.pane(t1, { kind = "plugin", block = Protocol.BLOCK_KIND, left = true })
local notes_tab = Fake.tab(notes)
Fake.pane(notes_tab)
Fake.view(deck)
Fake.focus(copy)
Leader.take()
Pusher.rebuild(cx)

-- The replies (`act = "res"`) sent so far.
local function replies(): { any }
	local out = {}
	for _, e in Fake.world().events do
		if e.act == "res" then
			table.insert(out, e.value)
		end
	end
	return out
end

local function last_toast(): Fake.Toast?
	local toasts = Fake.world().toasts
	return toasts[#toasts]
end

local function tab_has_command(tab: number, command: string): boolean
	for _, pane in Fake.world().order[tab] do
		local p = Fake.world().panes[pane]
		if p.kind == "agent" and p.line == command then
			return true
		end
	end
	return false
end

-- A request from a newer version names this machine to update; one from an older version names the sender. Neither
-- is acted on, and the log names the verb and `p` but never the rest of the query (it can carry a prompt).
do
	local newer = Protocol.P + 1
	local url = string.format("jumpr://jump?p=%d&b=blk&r=1&host=devbox&prompt=secret%%20words", newer)
	local verb = Router.handle(cx, url, copy)
	check(verb == nil, "a newer version's request is not acted on")
	local toast = last_toast()
	check(
		toast ~= nil and toast.text == "Jumpr on devbox is newer: update Jumpr on laptop",
		"a newer version names this machine to update"
	)
	Router.handle(cx, "jumpr://jump?b=blk&r=2&host=devbox&prompt=secret%20words", copy)
	toast = last_toast()
	check(
		toast ~= nil and toast.text == "Jumpr on devbox is older: update Jumpr on devbox",
		"an older version (no p) names the sending machine to update"
	)
	local logged = table.concat(Fake.logs(), "\n")
	check(
		string.find(logged, "jump request from devbox with p=" .. tostring(newer), 1, true) ~= nil,
		"the log names the verb and p"
	)
	check(string.find(logged, "secret", 1, true) == nil, "the log never holds the rest of the query")
end

-- A start for a machine whose deck session is not in view starts nothing and is answered with why; the same request
-- seen again is not answered twice.
do
	Fake.view(notes)
	local url = Protocol.request_url(
		"start",
		"blk",
		10,
		"devbox",
		{ id = "agent-new", cwd = "/work", cli = "omp", mode = "new" },
		"deck"
	)
	check(Router.handle(cx, url, nil) == "start", "a start naming no pane is acted on by its host's name")
	local r = replies()
	check(#r == 1 and r[1].ok == false and r[1].r == 10, "the start is answered with a failure")
	check(
		r[1].err == "agent agent-new not started: the deck session of devbox is not in view",
		"the failure says the deck session is not in view"
	)
	check(#Fake.world().sessions[deck].tabs == 1, "no agent tab is opened")
	check(Router.handle(cx, url, nil) == nil and #replies() == 1, "a request seen again is dropped")
end

-- An omp start from the copy in focus opens a tab, answers ok, labels it, gives it a copy and leaves focus in the
-- list.
do
	Fake.view(deck)
	Fake.focus(copy)
	local url = Protocol.request_url(
		"start",
		"blk",
		11,
		"devbox",
		{ id = "agent-new", cwd = "/work", cli = "omp", mode = "new", label = "fix" },
		"deck"
	)
	check(Router.handle(cx, url, copy) == "start", "an omp start from the focused copy is acted on")
	local r = replies()
	check(#r == 2 and r[2].ok == true and r[2].r == 11, "the omp start is answered ok")
	local tabs = Fake.world().sessions[deck].tabs
	check(#tabs == 2, "the omp agent opens in a new tab of the deck session")
	local new_tab = tabs[2]
	check(#Fake.copies_in(new_tab) == 1, "the new tab gets its own copy of the list")
	check(Fake.world().named[new_tab] == "fix", "the new tab is named with the agent's label")
	check(Fake.world().focused == copy, "focus stays in the list")
	check(
		tab_has_command(new_tab, "omp --continue --session-dir ~/.omp/deck/agent-new"),
		"the omp agent runs its established command"
	)
end

-- Every ACP launch mode is rebuilt from its validated fields and passed to the terminal unchanged. Copilot stands for
-- every agent that still runs through Tern's ACP chat.
do
	local cases: { { id: string, mode: string, sid: string?, command: string } } = {
		{
			id = "acp-new",
			mode = "new",
			sid = nil,
			command = "env JUMPR_ID=acp-new tern acp copilot",
		},
		{
			id = "acp-resume",
			mode = "resume",
			sid = "session-1",
			command = "env JUMPR_ID=acp-resume tern acp copilot --resume session-1",
		},
		{
			id = "acp-continue",
			mode = "continue",
			sid = nil,
			command = "env JUMPR_ID=acp-continue tern acp copilot --continue",
		},
		{
			id = "acp-pick",
			mode = "pick",
			sid = nil,
			command = "env JUMPR_ID=acp-pick tern acp copilot --sessions",
		},
	}
	for i, case in cases do
		Fake.focus(copy)
		local fields: { [string]: string } = {
			id = case.id,
			cwd = "/work",
			cli = "copilot",
			mode = case.mode,
		}
		if case.sid ~= nil then
			fields.sid = case.sid
		end
		local url = Protocol.request_url("start", "blk", 20 + i, "devbox", fields, "deck")
		check(Router.handle(cx, url, copy) == "start", case.mode .. " mode is acted on")
		local tabs = Fake.world().sessions[deck].tabs
		check(tab_has_command(tabs[#tabs], case.command), case.mode .. " mode uses the exact ACP command")
	end
end

-- Claude Code and the Codex CLI run as themselves in the new tab, never through the ACP chat. A claude start, new or
-- resumed, runs the one line on the record's conversation id (it resumes the conversation, or starts it under that id
-- when it has no messages yet); pick opens Claude Code's picker. Codex starts new, resumes a thread by id, or opens its
-- picker. Each start is answered ok.
do
	local uuid = "01234567-0123-4456-b012-345670123456"
	local thread = "019a7d6e-2f3b-7c41-9d2e-5b6a7c8d9e0f"
	local function claude(id: string): string
		return "env JUMPR_ID=" .. id .. " sh -c 'claude --resume " .. uuid .. " || claude --session-id " .. uuid .. "'"
	end
	local cases: { { id: string, cli: string, mode: string, sid: string?, command: string } } = {
		{ id = "claude-new", cli = "claude", mode = "new", sid = uuid, command = claude("claude-new") },
		{ id = "claude-resume", cli = "claude", mode = "resume", sid = uuid, command = claude("claude-resume") },
		{
			id = "claude-pick",
			cli = "claude",
			mode = "pick",
			sid = nil,
			command = "env JUMPR_ID=claude-pick claude --resume",
		},
		{ id = "codex-new", cli = "codex", mode = "new", sid = nil, command = "env JUMPR_ID=codex-new codex" },
		{
			id = "codex-resume",
			cli = "codex",
			mode = "resume",
			sid = thread,
			command = "env JUMPR_ID=codex-resume codex resume " .. thread,
		},
		{
			id = "codex-pick",
			cli = "codex",
			mode = "pick",
			sid = nil,
			command = "env JUMPR_ID=codex-pick codex resume",
		},
	}
	for i, case in cases do
		Fake.focus(copy)
		local fields: { [string]: string } = { id = case.id, cwd = "/work", cli = case.cli, mode = case.mode }
		if case.sid ~= nil then
			fields.sid = case.sid
		end
		-- Their own sender: a sender's request numbers only grow, and the later cases here number theirs from 30.
		local url = Protocol.request_url("start", "cli-blk", i, "devbox", fields, "deck")
		local what = case.cli .. " " .. case.mode
		check(Router.handle(cx, url, copy) == "start", what .. " is acted on")
		local tabs = Fake.world().sessions[deck].tabs
		check(tab_has_command(tabs[#tabs], case.command), what .. " runs exactly: " .. case.command)
		local r = replies()
		check(r[#r].b == "cli-blk" and r[#r].r == i and r[#r].ok == true, what .. " is answered ok")
	end

	-- Neither CLI has a continue mode, and a claude start needs a conversation id that is a uuid: each is refused in
	-- one line and opens no pane.
	local refused: { { cli: string, mode: string, sid: string? } } = {
		{ cli = "claude", mode = "continue" },
		{ cli = "codex", mode = "continue" },
		{ cli = "claude", mode = "new" },
		{ cli = "claude", mode = "new", sid = "session-1" },
		{ cli = "claude", mode = "resume", sid = string.upper(uuid) },
		{ cli = "codex", mode = "resume", sid = "session-1" },
	}
	for i, case in refused do
		Fake.focus(copy)
		local before = #Fake.world().sessions[deck].tabs
		local fields: { [string]: string } =
			{ id = "cli-bad-" .. tostring(i), cwd = "/work", cli = case.cli, mode = case.mode }
		if case.sid ~= nil then
			fields.sid = case.sid
		end
		local url = Protocol.request_url("start", "cli-blk", 10 + i, "devbox", fields, "deck")
		local what = case.cli .. " " .. case.mode .. " with " .. tostring(case.sid)
		check(Router.handle(cx, url, copy) == "start", what .. " is handled as a refusal")
		check(#Fake.world().sessions[deck].tabs == before, what .. " opens no pane")
		local r = replies()
		local reply = r[#r]
		check(
			reply.r == 10 + i and reply.ok == false and string.find(reply.err, "\n", 1, true) == nil,
			what .. " gets a one-line refusal"
		)
	end
end

-- Missing or hostile launch parts are answered with one-line refusals and cannot open a pane.
do
	local bad = {
		{ cli = "claude", mode = "resume" },
		{ cli = "claude", mode = "unknown" },
		{ cli = "a;b", mode = "new" },
		{ cli = "--continue", mode = "new" },
	}
	for i, fields in bad do
		Fake.focus(copy)
		local before = #Fake.world().sessions[deck].tabs
		local launch = {
			id = "bad-" .. tostring(i),
			cwd = "/work",
			cli = fields.cli,
			mode = fields.mode,
		}
		local url = Protocol.request_url("start", "blk", 30 + i, "devbox", launch, "deck")
		check(Router.handle(cx, url, copy) == "start", "bad launch " .. tostring(i) .. " is handled as a refusal")
		check(#Fake.world().sessions[deck].tabs == before, "bad launch " .. tostring(i) .. " opens no pane")
		local r = replies()
		local reply = r[#r]
		check(
			reply.ok == false and string.find(reply.err, "\n", 1, true) == nil,
			"bad launch " .. tostring(i) .. " gets a one-line reply"
		)
	end
end

-- Settings opens as a tab with launch args, and a second request focuses that pane instead of opening another.
do
	Fake.focus(copy)
	local first = Protocol.request_url("settings", "blk", 40, "devbox", {}, "deck")
	check(Router.handle(cx, first, copy) == "settings", "the settings request is acted on")
	local opened = Fake.world().new_blocks
	local item = opened[#opened]
	check(
		item ~= nil and item.kind == Protocol.SETTINGS_KIND and item.how == "tab",
		"settings opens its block in a tab"
	)
	local session_name, host_name = Protocol.parse_launch_args(item.args or {})
	check(session_name == "deck" and host_name == "devbox", "settings receives the deck session launch args")
	local settings_pane = item.pane
	check(Fake.world().focused == settings_pane, "the new settings pane receives focus")
	local opened_count = #Fake.world().new_blocks
	Fake.focus(copy)
	local second = Protocol.request_url("settings", "blk", 41, "devbox", {}, "deck")
	check(Router.handle(cx, second, copy) == "settings", "a second settings request is acted on")
	check(#Fake.world().new_blocks == opened_count, "a second settings request opens no block")
	check(Fake.world().focused == settings_pane, "a second settings request focuses the existing pane")
	Fake.close(settings_pane)
	Fake.world().block_result = "missing"
	Fake.focus(copy)
	local missing = Protocol.request_url("settings", "blk", 42, "devbox", {}, "deck")
	check(Router.handle(cx, missing, copy) == "settings", "an unavailable settings block is handled")
	check(#Fake.world().new_blocks == opened_count, "an unavailable settings block opens no pane")
	local toast = last_toast()
	check(
		toast ~= nil and toast.text == "Jumpr is not installed on devbox: run tern plugin link <checkout> there",
		"an unavailable settings block explains that Jumpr is not installed"
	)
	Fake.world().block_result = "ok"
end

-- Window settings route only through the focused settings pane and preserve every unrelated keybinding.
do
	local settings_tab = Fake.tab(deck)
	local settings_pane =
		Fake.pane(settings_tab, { kind = "plugin", block = Protocol.SETTINGS_KIND, title = "Jumpr settings" })
	Pusher.rebuild(cx)

	local function cfg_events(): { any }
		local out = {}
		for _, event in Fake.world().events do
			if event.pane == settings_pane and event.act == "cfg" then
				table.insert(out, event.value)
			end
		end
		return out
	end

	local function same_raw(a: { [string]: any }, b: { [string]: any }): boolean
		for chord, value in a do
			local other = b[chord]
			if type(value) == "table" then
				if type(other) ~= "table" or #value ~= #other then
					return false
				end
				for i, holder in value do
					if other[i] ~= holder then
						return false
					end
				end
			elseif other ~= value then
				return false
			end
		end
		for chord in b do
			if a[chord] == nil then
				return false
			end
		end
		return true
	end

	Fake.focus(settings_pane)
	local read = Protocol.request_url("cfg", "cfg-window", 1, "devbox", { op = "read" }, "deck")
	check(Router.handle(cx, read, settings_pane) == "cfg", "a read from the focused settings pane is acted on")
	local events = cfg_events()
	check(#events == 1, "a read sends one cfg event to its settings pane")
	local cfg = events[1]
	check(
		cfg.p == Protocol.P
			and cfg.machine == "laptop"
			and cfg.em == "A"
			and cfg.defaults.toggle_focus == "ctrl+alt+j"
			and cfg.defaults.hide_list == "ctrl+alt+shift+j"
			and cfg.defaults.last_tab == "ctrl+alt+;"
			and cfg.chords.toggle_focus[1] == "ctrl+alt+j"
			and cfg.chords.hide_list[1] == "ctrl+alt+shift+j"
			and cfg.chords.last_tab[1] == "ctrl+alt+;",
		"the read reports this window's machine, mode and three effective defaults"
	)

	local newer_cfg = string.gsub(
		Protocol.request_url("cfg", "cfg-newer", 1, "devbox", { op = "read" }, "deck"),
		"p=%d+",
		"p=" .. tostring(Protocol.P + 1),
		1
	)
	check(Router.handle(cx, newer_cfg, settings_pane) == nil, "a newer cfg request is refused")
	check(#cfg_events() == 1, "a cfg request from another protocol version gets no cfg reply")

	-- The same request is first seen outside the focused settings window, then acted on where that pane is focused.
	local routed = Protocol.request_url("cfg", "cfg-routed", 1, "devbox", { op = "read" }, "deck")
	Fake.focus(copy)
	local before_events = #cfg_events()
	local before_logs = #Fake.logs()
	check(
		Router.handle(cx, routed, settings_pane) == nil,
		"a cfg request is dropped outside its focused settings window"
	)
	check(#cfg_events() == before_events, "the other window sends no cfg event")
	check(#Fake.logs() == before_logs + 1, "the other window logs the dropped cfg request once")
	Fake.focus(settings_pane)
	check(Router.handle(cx, routed, settings_pane) == "cfg", "the focused settings window acts on the same cfg request")
	check(#cfg_events() == before_events + 1, "exactly the focused window answers the routed request")

	local unrelated = {
		["ctrl+u"] = "editor.undo",
		["ctrl+alt+empty"] = {},
	}
	Fake.set_keybinds(unrelated)
	local bind = Protocol.request_url("cfg", "cfg-window", 2, "devbox", {
		op = "bind",
		action = "toggle_focus",
		chord = "ctrl+alt+k",
	}, "deck")
	local before_bind_reply = #cfg_events()
	check(Router.handle(cx, bind, settings_pane) == "cfg", "a valid chord bind is acted on")
	check(#cfg_events() == before_bind_reply, "a bind reply waits for the re-armed keymap")
	local raw = Fake.keybinds()
	check(raw["ctrl+alt+k"] == "plugin.jumpr.toggle_focus", "the new chord is bound to the selected action")
	check(type(raw["ctrl+alt+j"]) == "table" and #raw["ctrl+alt+j"] == 0, "the action's old default chord is unbound")
	check(
		raw["ctrl+u"] == "editor.undo" and type(raw["ctrl+alt+empty"]) == "table" and #raw["ctrl+alt+empty"] == 0,
		"bind preserves unrelated overrides, including an empty one"
	)
	check(next(Fake.world().plugin_keybinds) == nil, "a settings write drops the plugin layer for the current tick")
	Fake.advance(0)
	events = cfg_events()
	check(#events == before_bind_reply + 1, "the bind reply is sent on the next tick")
	cfg = events[#events]
	check(
		#cfg.chords.toggle_focus == 1
			and cfg.chords.toggle_focus[1] == "ctrl+alt+k"
			and cfg.chords.hide_list[1] == "ctrl+alt+shift+j"
			and cfg.chords.last_tab[1] == "ctrl+alt+;",
		"the deferred bind reply sees the other defaults while the user suppression still wins"
	)

	local reset = Protocol.request_url("cfg", "cfg-window", 4, "devbox", {
		op = "reset",
		action = "toggle_focus",
	}, "deck")
	local before_reset_reply = #cfg_events()
	check(Router.handle(cx, reset, settings_pane) == "cfg", "reset is acted on")
	check(#cfg_events() == before_reset_reply, "a reset reply waits for the re-armed keymap")
	raw = Fake.keybinds()
	check(raw["ctrl+alt+k"] == nil and raw["ctrl+alt+j"] == nil, "reset removes only the selected action's overrides")
	check(
		raw["ctrl+u"] == "editor.undo" and type(raw["ctrl+alt+empty"]) == "table" and #raw["ctrl+alt+empty"] == 0,
		"reset preserves unrelated overrides, including an empty one"
	)
	Fake.advance(0)
	events = cfg_events()
	check(#events == before_reset_reply + 1, "the reset reply is sent on the next tick")
	cfg = events[#events]
	check(
		#cfg.chords.toggle_focus == 1
			and cfg.chords.toggle_focus[1] == "ctrl+alt+j"
			and cfg.chords.hide_list[1] == "ctrl+alt+shift+j"
			and cfg.chords.last_tab[1] == "ctrl+alt+;",
		"the deferred reset reply sees every re-armed plugin default"
	)

	local refused_raw = {
		["ctrl+u"] = "editor.undo",
		["ctrl+alt+empty"] = {},
		["ctrl+alt+x"] = "editor.copy",
	}
	Fake.set_keybinds(refused_raw)
	local taken = Protocol.request_url("cfg", "cfg-window", 5, "devbox", {
		op = "bind",
		action = "toggle_focus",
		chord = "ctrl+alt+x",
	}, "deck")
	Router.handle(cx, taken, settings_pane)
	events = cfg_events()
	cfg = events[#events]
	check(cfg.err == "taken by editor.copy", "a taken chord is refused with its holder named")
	check(same_raw(Fake.keybinds(), refused_raw), "a refused chord changes no override")

	local unknown = Protocol.request_url("cfg", "cfg-window", 6, "devbox", {
		op = "bind",
		action = "editor.copy",
		chord = "ctrl+alt+y",
	}, "deck")
	Router.handle(cx, unknown, settings_pane)
	events = cfg_events()
	cfg = events[#events]
	check(
		cfg.err == "unknown chord action: editor.copy" and same_raw(Fake.keybinds(), refused_raw),
		"an action outside CHORD_ACTIONS is refused without a write"
	)
	local hostile = Protocol.request_url("cfg", "cfg-window", 7, "devbox", {
		op = "bind",
		action = "toggle_focus",
		chord = "rm -rf",
	}, "deck")
	Router.handle(cx, hostile, settings_pane)
	events = cfg_events()
	cfg = events[#events]
	check(cfg.err == "invalid chord" and same_raw(Fake.keybinds(), refused_raw), "a hostile chord is refused")

	local esc = Protocol.request_url("cfg", "cfg-window", 8, "devbox", { op = "esc", v = "B" }, "deck")
	check(Router.handle(cx, esc, settings_pane) == "cfg", "Esc mode B is acted on")
	local stored_mode: string? = nil
	for _, value in Fake.files() do
		if type(value) == "table" and value.esc_mode ~= nil then
			stored_mode = value.esc_mode
		end
	end
	check(stored_mode == "B" and Leader.esc_mode() == "B", "Esc mode B is stored in window.json")
	Fake.advance(250)
	local status = Fake.status_sent(copy)
	check(#status > 0 and status[#status].em == "B", "the dirty status push carries Esc mode B")

	local bad_modifier = Protocol.request_url("cfg", "cfg-window", 9, "devbox", {
		op = "bind",
		action = "toggle_focus",
		chord = "cmd+j+k",
	}, "deck")
	Router.handle(cx, bad_modifier, settings_pane)
	events = cfg_events()
	cfg = events[#events]
	check(
		cfg.err == "invalid chord" and same_raw(Fake.keybinds(), refused_raw),
		"a letter where a modifier goes is refused as an invalid chord, with no write"
	)
end

-- Zen: the focused copy that asks zooms its tab with Tern's "Zoom block", once; off gives the tab back. A copy that
-- is not focused in this window asks for nothing here, so another window's key never zooms this one's pane.
do
	Fake.view(deck)
	Fake.focus(copy)
	local world = Fake.world()
	local tab = world.panes[copy].tab :: number
	local function zen(r: number, on: string, from: number): string?
		return Router.handle(cx, Protocol.request_url("zen", "zen-blk", r, "devbox", { on = on }, "deck"), from)
	end
	check(zen(1, "1", copy) == "zen" and world.zoomed[tab] == true, "zen on zooms the copy's tab")
	check(#world.actions_run == 1 and world.actions_run[1] == "Zoom block", "with Tern's Zoom block action")
	check(zen(2, "1", copy) == "zen" and #world.actions_run == 1, "zen on in a zoomed tab runs nothing")
	check(zen(3, "0", copy) == "zen" and world.zoomed[tab] == false, "zen off gives the tab back")
	check(zen(4, "0", copy) == "zen" and #world.actions_run == 2, "zen off in a tab not zoomed runs nothing")
	local other = Fake.pane(tab)
	Fake.focus(other)
	check(zen(5, "1", copy) == nil and world.zoomed[tab] == false, "an unfocused copy's zen is dropped")
	Fake.close(other)

	-- Zen turned on in one tab's copy and left from another tab's copy gives the first tab back.
	Fake.focus(copy)
	check(zen(6, "1", copy) == "zen" and world.zoomed[tab] == true, "zen on in the first tab")
	local t2 = Fake.tab(deck)
	Fake.agent(t2, "agent-z")
	local copy2 = Fake.pane(t2, { kind = "plugin", block = Protocol.BLOCK_KIND, left = true })
	Pusher.rebuild(cx)
	Fake.focus(copy2)
	check(zen(7, "0", copy2) == "zen" and world.zoomed[tab] == false, "zen off from another tab's copy unzooms it")
	check(world.focused == copy2, "and focus stays where the key was pressed")

	-- Going back from a zoomed copy gives its tab back first.
	Fake.focus(copy)
	check(zen(8, "1", copy) == "zen" and world.zoomed[tab] == true, "zen on again")
	Router.handle(cx, Protocol.request_url("back", "zen-blk", 9, "devbox", {}, "deck"), copy)
	check(world.zoomed[tab] == false, "back gives the zoomed tab back")
	Fake.close(copy2)
	Fake.focus(copy)
end

-- Stop: `cx.agents:stop` closes the agent's pane and the stop is answered at once. A pane it answers for but leaves
-- open, as Tern did for a chat whose agent never started, is closed a moment later and only then answered; a pane that
-- goes by itself meanwhile is not closed again, and one that cannot be closed is answered with a plain error, so the
-- list puts the agent back. An agent with no pane at all is answered with an error marked `gone`, so the list deletes
-- it.
do
	Fake.view(deck)
	Fake.focus(copy)
	local fake_cx: any = cx
	local real_stop = fake_cx.agents.stop
	local real_close = fake_cx.layout.close
	-- Panes whose `agents:stop` answers and leaves them open, and panes whose `layout:close` fails.
	local leaves_open: { [number]: boolean } = {}
	local cannot_close: { [number]: boolean } = {}
	fake_cx.agents.stop = function(self: any, pane: number)
		if leaves_open[pane] then
			table.insert(Fake.world().stopped, pane)
			return
		end
		real_stop(self, pane)
	end
	fake_cx.layout.close = function(self: any, pane: number)
		if cannot_close[pane] then
			error("the pane is busy", 0)
		end
		real_close(self, pane)
	end
	local r = 0
	local function stop(id: string): string?
		r += 1
		return Router.handle(cx, Protocol.request_url("stop", "stop-blk", r, "devbox", { id = id }, "deck"), copy)
	end
	-- The answers to these stops that reached the copy that sent them (every copy on the machine gets each one).
	local function answers(): { any }
		local out = {}
		for _, e in Fake.world().events do
			if e.act == "res" and e.pane == copy and e.value.b == "stop-blk" then
				table.insert(out, e.value)
			end
		end
		return out
	end
	local function last_answer(): any
		local all = answers()
		return all[#all]
	end
	local function closed(pane: number): boolean
		return table.find(Fake.world().closed, pane) ~= nil
	end

	local omp = Fake.agent(Fake.tab(deck), "agent-stop")
	local before = #answers()
	check(stop("agent-stop") == "stop", "a stop is acted on")
	check(Fake.world().panes[omp] == nil and not closed(omp), "agents:stop closes an omp agent's pane")
	check(#answers() == before + 1 and last_answer().ok == true, "and the stop is answered ok at once")
	Fake.advance(1000)
	check(#answers() == before + 1 and not closed(omp), "nothing more happens after the wait")

	local chat = Fake.agent(Fake.tab(deck), nil, "env JUMPR_ID=chat-dead tern acp bad")
	leaves_open[chat] = true
	before = #answers()
	check(stop("chat-dead") == "stop", "a stop of a chat that never started is acted on")
	check(Fake.world().panes[chat] ~= nil and #answers() == before, "its pane outlives agents:stop, with no answer yet")
	Fake.advance(999)
	check(Fake.world().panes[chat] ~= nil and #answers() == before, "the pane gets a moment to go by itself")
	Fake.advance(1)
	check(Fake.world().panes[chat] == nil and closed(chat), "then it is closed")
	check(#answers() == before + 1 and last_answer().ok == true, "and only then is the stop answered ok")

	-- A Claude Code pane, found by the id on its `sh -c` line, that exits by itself during the moment.
	local uuid = "01234567-0123-4456-b012-345670123456"
	local claude_line = "env JUMPR_ID=chat-slow sh -c 'claude --resume "
		.. uuid
		.. " || claude --session-id "
		.. uuid
		.. "'"
	local slow = Fake.agent(Fake.tab(deck), nil, claude_line)
	leaves_open[slow] = true
	before = #answers()
	stop("chat-slow")
	Fake.close(slow)
	Fake.advance(1000)
	check(not closed(slow), "a pane that went by itself during the moment is not closed again")
	check(#answers() == before + 1 and last_answer().ok == true, "and the stop is answered ok")

	local stuck = Fake.agent(Fake.tab(deck), nil, "env JUMPR_ID=chat-stuck tern acp bad")
	leaves_open[stuck] = true
	cannot_close[stuck] = true
	before = #answers()
	stop("chat-stuck")
	Fake.advance(1000)
	local answer = last_answer()
	check(
		#answers() == before + 1
			and answer.ok == false
			and answer.err == "could not stop agent chat-stuck on devbox: the pane is busy",
		"a pane neither call closes is answered with an error, so the list puts the agent back"
	)
	check(answer.gone == nil, "that error is not marked gone: a pane was there")

	before = #answers()
	check(stop("agent-none") == "stop", "a stop of an agent with no pane is acted on")
	answer = last_answer()
	check(
		#answers() == before + 1
			and answer.ok == false
			and answer.gone == true
			and answer.err == "agent agent-none is not running on devbox",
		"an agent with no pane is answered at once with an error marked gone, so the list deletes it"
	)
	Fake.advance(1000)
	check(#answers() == before + 1, "and nothing more is answered after the wait")

	fake_cx.agents.stop = real_stop
	fake_cx.layout.close = real_close
end

print("Router: " .. checks .. " checks passed")
