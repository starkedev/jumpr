--!strict
-- The jumpr:// request handler. The leader window handles list requests; a cfg request goes only to the window
-- focused in its settings pane. A request is parsed and version-checked, dropped when its `r` is at or below the
-- last handled `r` for its block uid `b`, and dispatched to its verb handler.
-- A host opens each URL in every window attached to it, on every machine, and each machine names that host its own
-- way, so the window finds the host with `protocol.request_host`: it acts when its focus is in a copy of the list
-- that sent the request (the URL's deck session `sn`), and the URL's `host` by exact name is only the fallback when
-- the link names no pane or the host sends no `sn`.
-- Replies (`act = "res"`) go through compat.session_event to every deck block on the request's host, carrying `b`;
-- when none can be sent, a toast shows the error. Errors name the machine and the agent.

local compat = require("../compat")
local agent = require("../shared/agent")
local identity = require("../shared/identity")
local protocol = require("../shared/protocol")
local agents = require("./agents")
local block = require("./block")
local copies = require("./copies")
local chords = require("./chords")
local diag = require("./diag")
local leader = require("./leader")
local pusher = require("./pusher")

local M = {}

local last_r: { [string]: number } = {}
-- URL host names already logged as unknown, so a request from another machine's spelling logs once.
local told_unknown: { [string]: boolean } = {}
-- How long a pane may still be open after `cx.agents:stop` answered for it before `stop` closes it: long enough for a
-- remote host's own close to arrive, short enough that the row does not linger.
local STOP_GRACE_MS = 1000

local default_chords = chords.defaults("linux")
local rearm_chords: (() -> ())? = nil
local chord_actions: { [string]: boolean } = {}
for _, action in protocol.CHORD_ACTIONS do
	chord_actions[action.id] = true
end

-- Sets the defaults for this window's OS and the entrypoint callback that re-registers them.
function M.set_defaults(defaults: { [string]: string }, rearm: (() -> ())?)
	default_chords = table.clone(defaults)
	rearm_chords = rearm
end

local function rearm()
	local fn = rearm_chords
	if fn ~= nil then
		fn()
	end
end

local function known_host(cx: WindowCx, name: string): boolean
	local hosts = compat.hosts_list(cx)
	if hosts == nil then
		return false
	end
	for _, h in hosts do
		if h.name == name then
			return true
		end
	end
	return false
end

-- Sends a `res` to every deck block on the request's host; toasts when none could be sent.
local function reply(cx: WindowCx, req: protocol.Request, ok: boolean, err: string?)
	local value = compat.json_encode(protocol.reply(req.b, req.r, ok, err))
	local sent = 0
	local last_err: string? = "no jumpr list on " .. req.host
	for _, pane in pusher.blocks_for(req.host) do
		local done, why = compat.session_event(cx, pane, { ev = "action", act = "res", value = value })
		if done then
			sent += 1
		else
			last_err = why
		end
	end
	if sent == 0 then
		diag.error("router", req.verb .. " reply to " .. req.host .. ": " .. tostring(last_err))
		local text = if ok then "Jumpr: " .. req.verb .. " done on " .. req.host else tostring(err)
		compat.toast(
			cx,
			if ok then "info" else "error",
			text,
			"the reply could not reach the list: " .. tostring(last_err)
		)
	end
end

-- A refused or failed request: logged, then answered with an error.
local function fail(cx: WindowCx, req: protocol.Request, text: string)
	diag.error("router", text)
	reply(cx, req, false, text)
end

local function jump(cx: WindowCx, req: protocol.Request)
	local id = req.fields.id or ""
	local pane = agents.pane_for(req.host, id)
	if pane == nil then
		agents.rebuild(cx)
		pane = agents.pane_for(req.host, id)
	end
	if pane == nil then
		local text = "agent " .. id .. " is not running on " .. req.host
		fail(cx, req, text)
		compat.toast(cx, "error", "Jumpr: " .. text)
		return
	end
	-- Focusing a parked pane would deal it into whichever tab is in view, beside another agent; it gets its own tab.
	if agents.parked(pane) then
		local tab, why = copies.deal(cx, req.host, id, pane)
		if tab == nil then
			local text = tostring(why)
			fail(cx, req, text)
			compat.toast(cx, "error", "Jumpr: " .. text)
			return
		end
	end
	local ok, err = compat.focus(cx, pane)
	if not ok then
		local text = "could not jump to agent " .. id .. " on " .. req.host .. ": " .. tostring(err)
		fail(cx, req, text)
		compat.toast(cx, "error", "Jumpr: " .. text)
	end
end

local function start(cx: WindowCx, req: protocol.Request)
	local id = req.fields.id or ""
	if not identity.valid_id(id) then
		fail(cx, req, "refused a start on " .. req.host .. ": bad agent id")
		return
	end
	local cwd = req.fields.cwd or ""
	if not identity.valid_cwd(cwd) then
		fail(cx, req, "refused agent " .. id .. " on " .. req.host .. ": folder not supported: " .. cwd)
		return
	end
	local cli = req.fields.cli or ""
	if not agent.valid_kind(cli) then
		fail(cx, req, "refused agent " .. id .. " on " .. req.host .. ": bad agent kind")
		return
	end
	local mode = req.fields.mode or ""
	if not agent.valid_mode(mode) then
		fail(cx, req, "refused agent " .. id .. " on " .. req.host .. ": bad start mode")
		return
	end
	local command = agent.command(cli, id, mode :: agent.Mode, req.fields.sid)
	if command == nil then
		fail(cx, req, "refused agent " .. id .. " on " .. req.host .. ": bad launch arguments")
		return
	end
	local host = compat.current_host(cx)
	local session = compat.current_session(cx)
	local deck_session = pusher.session_of(req.host)
	if
		host == nil
		or session == nil
		or host.name ~= req.host
		or deck_session == nil
		or session.name ~= deck_session
	then
		fail(cx, req, "agent " .. id .. " not started: the deck session of " .. req.host .. " is not in view")
		return
	end
	local before = compat.session_focused(cx)
	-- A shell tab, not `agents:start`: no first prompt is required, and a terminal-started omp still appears in
	-- `agents:list()` (checked against Tern), so status and binding flow as before.
	local pane, err = compat.terminal_start(cx, { cwd = cwd, command = command })
	if pane == nil then
		fail(cx, req, "could not start agent " .. id .. " on " .. req.host .. ": " .. tostring(err))
		return
	end
	reply(cx, req, true, nil)
	-- The new agent's tab gets its own copy of the list, before focus returns to the list.
	copies.ensure(cx)
	local label = req.fields.label or ""
	if label ~= "" then
		local tab = compat.session_tab_of(cx, pane)
		if tab ~= nil then
			compat.name_tab(cx, tab, label)
		end
	end
	-- Enter on an exited row restarts it with `land`: focus goes to the agent, as Enter on a live row would.
	if req.fields.land == "1" then
		local ok, why = compat.focus(cx, pane)
		if not ok then
			diag.error("router", "focus restarted agent " .. id .. " on " .. req.host .. ": " .. tostring(why))
		end
		return
	end
	-- Focus stays in the list after `n`: Enter on the new row jumps.
	if before ~= nil and pusher.is_block(before) then
		local ok, why = compat.focus(cx, before)
		if not ok then
			diag.error("router", "refocus the list on " .. req.host .. ": " .. tostring(why))
		end
	end
end

-- Opens the one settings page for `host`. The deck session must be in view, because launch args name that session.
local function open_settings_for(cx: WindowCx, host_name: string): boolean
	local host = compat.current_host(cx)
	local session = compat.current_session(cx)
	local deck_session = pusher.session_of(host_name)
	if
		host == nil
		or session == nil
		or host.name ~= host_name
		or deck_session == nil
		or session.name ~= deck_session
	then
		local text = "settings not opened: the deck session of " .. host_name .. " is not in view"
		diag.error("router", text)
		compat.toast(cx, "error", "Jumpr: " .. text)
		return false
	end
	local panes, panes_err = compat.session_panes(cx)
	if panes == nil then
		local text = "could not find settings on " .. host_name .. ": " .. tostring(panes_err)
		diag.error("router", text)
		compat.toast(cx, "error", "Jumpr: " .. text)
		return false
	end
	for _, pane in panes do
		if pane.block == protocol.SETTINGS_KIND and table.find(host.panes, pane.pane) ~= nil then
			local ok, err = compat.focus(cx, pane.pane)
			if not ok then
				local text = "could not focus settings on " .. host_name .. ": " .. tostring(err)
				diag.error("router", text)
				compat.toast(cx, "error", "Jumpr: " .. text)
			end
			return ok
		end
	end
	local opts: BlockOpts = { focus = true }
	local pane, err =
		compat.new_block(cx, protocol.SETTINGS_KIND, protocol.launch_args(session.name, host_name), "tab", opts)
	if pane ~= nil then
		return true
	end
	if err == nil then
		local text = "Jumpr is not installed on " .. host_name .. ": run tern plugin link <checkout> there"
		diag.error("router", "not installed on " .. host_name)
		compat.toast(cx, "error", text)
	else
		local text = "could not open settings on " .. host_name .. ": " .. err
		diag.error("router", text)
		compat.toast(cx, "error", "Jumpr: " .. text)
	end
	return false
end

-- Opens or focuses settings for the host in view. Palette commands use the same path as `jumpr://settings`.
function M.open_settings(cx: WindowCx): boolean
	pusher.scan(cx)
	local host = compat.current_host(cx)
	if host == nil then
		diag.error("router", "settings not opened: no host in view")
		compat.toast(cx, "error", "Jumpr: settings not opened: no host in view")
		return false
	end
	return open_settings_for(cx, host.name)
end

-- `jumpr://name`: names the agent's Tern tab with its deck label (an empty label clears the name). Fire and
-- forget: the label is already saved on the host, the tab name is cosmetic, and a pending agent's tab is named
-- when `start` creates it, so a pane that is not running yet is not an error.
local function name(cx: WindowCx, req: protocol.Request)
	local id = req.fields.id or ""
	local pane = agents.pane_for(req.host, id)
	if pane == nil then
		agents.rebuild(cx)
		pane = agents.pane_for(req.host, id)
	end
	local tab = if pane ~= nil then compat.session_tab_of(cx, pane) else nil
	if tab == nil then
		diag.error("router", "name agent " .. id .. " on " .. req.host .. ": no running pane with a tab")
		return
	end
	local label = req.fields.label or ""
	compat.name_tab(cx, tab, if label ~= "" then label else nil)
end

-- Whether the window lists no `pane` any more; a pane the window could not read is not taken as gone.
local function gone(cx: WindowCx, pane: number): boolean
	local p, err = compat.session_pane(cx, pane)
	return p == nil and err == nil
end

-- Closes `pane` with `cx.layout:close` when it is still open after `cx.agents:stop` answered for it. Nil once the pane
-- is gone (one that went while its close failed counts), else why it could not be closed.
local function close_left_open(cx: WindowCx, req: protocol.Request, id: string, pane: number): string?
	if gone(cx, pane) then
		return nil
	end
	diag.error("router", "agents:stop left agent " .. id .. " open on " .. req.host .. ": closing its pane")
	local ok, err = compat.close(cx, pane)
	if ok or gone(cx, pane) then
		return nil
	end
	return tostring(err)
end

-- The one reply to a stop: ok, or the failure, logged, toasted and answered as an error so the block puts the record
-- back to `live`.
local function answer_stop(cx: WindowCx, req: protocol.Request, id: string, failure: string?)
	if failure == nil then
		reply(cx, req, true, nil)
		return
	end
	local text = "could not stop agent " .. id .. " on " .. req.host .. ": " .. failure
	fail(cx, req, text)
	compat.toast(cx, "error", "Jumpr: " .. text)
end

-- `jumpr://stop`: closes the agent's pane (every pane when a duplicate has two), after the block asked for
-- confirmation. `cx.agents:stop` first; when it refuses (an agent restored by a shell command
-- line may not be an agent block), `cx.layout:close` instead. Tern's docs say `agents:stop` closes the block, yet a
-- chat whose agent never started was seen to stay open after it, so a pane still open `STOP_GRACE_MS` after
-- `agents:stop` answered for it is closed with `cx.layout:close`, and the reply waits for that look. An agent the
-- window does not know, or a pane neither call closes, is answered with an error, so the block puts the record back
-- to `live`. Closing a tab's last agent lets `copies.tidy` close the lone copy left behind and move focus to the copy
-- in the tab Tern shows next.
local function stop(cx: WindowCx, req: protocol.Request)
	local id = req.fields.id or ""
	if not identity.valid_id(id) then
		fail(cx, req, "refused a stop on " .. req.host .. ": bad agent id")
		return
	end
	local panes = agents.panes_for(req.host, id)
	if #panes == 0 then
		agents.rebuild(cx)
		panes = agents.panes_for(req.host, id)
	end
	if #panes == 0 then
		fail(cx, req, "agent " .. id .. " is not running on " .. req.host)
		return
	end
	local failure: string? = nil
	local still_open: { number } = {}
	for _, pane in panes do
		local ok, err = compat.agents_stop(cx, pane)
		if ok then
			if not gone(cx, pane) then
				table.insert(still_open, pane)
			end
		else
			diag.error("router", "agents:stop on " .. req.host .. " for " .. id .. ": " .. tostring(err))
			ok, err = compat.close(cx, pane)
			if not ok then
				failure = tostring(err)
			end
		end
	end
	if #still_open == 0 then
		answer_stop(cx, req, id, failure)
		return
	end
	-- With no window to look in, no reply goes: the block takes the stop back once its wait for one is over.
	compat.timer(STOP_GRACE_MS, function(later: WindowCx?)
		if later == nil then
			diag.error("router", "stop " .. id .. " on " .. req.host .. ": no window to check its pane in")
			return
		end
		for _, pane in still_open do
			failure = close_left_open(later, req, id, pane) or failure
		end
		answer_stop(later, req, id, failure)
	end)
end

-- `jumpr://show`: the copy in the agent's tab, focused. A stale request (the deck session is not in view) is dropped
-- with no reply; a real failure is answered with `res`, which the list shows as its notice (no toast: it follows
-- every move).
local function show(cx: WindowCx, req: protocol.Request)
	local ok, err = copies.show(cx, req.host, req.fields.id or "")
	if ok or err == "stale" then
		return
	end
	fail(cx, req, tostring(err))
end

local function back(cx: WindowCx, req: protocol.Request)
	local ok, err = block.back(cx, req.host)
	if not ok then
		diag.error("router", "back on " .. req.host .. ": " .. tostring(err))
	end
end

local function send_cfg(cx: WindowCx, pane: number, err: string?)
	local keymap, keymap_err = compat.actions_keys(cx)
	local effective: { [string]: { string } }
	if keymap == nil then
		err = err or ("could not read keybindings: " .. tostring(keymap_err))
		effective = {}
	else
		effective = keymap
	end
	local msg = protocol.cfg_msg({
		machine = diag.local_name(cx),
		em = leader.esc_mode(),
		chords = chords.current(effective),
		defaults = table.clone(default_chords),
		err = err,
	})
	local ok, send_err = compat.session_event(cx, pane, { ev = "action", act = "cfg", value = compat.json_encode(msg) })
	if not ok then
		diag.error("router", "cfg reply: " .. tostring(send_err))
	end
end

local function cfg(cx: WindowCx, req: protocol.Request, pane: number)
	local op = req.fields.op or ""
	local err: string? = nil
	local wrote = false
	if op == "read" then
		-- The reply below is the read.
	elseif op == "esc" then
		if not leader.set_esc_mode(req.fields.v or "") then
			err = "invalid Esc mode"
		else
			pusher.mark_dirty()
		end
	elseif op == "bind" then
		local action = req.fields.action or ""
		local chord = req.fields.chord or ""
		if not chord_actions[action] then
			err = "unknown chord action: " .. action
		elseif not chords.valid_chord(chord) then
			err = "invalid chord"
		else
			local keymap, why = compat.actions_keys(cx)
			if keymap == nil then
				err = "could not read keybindings: " .. tostring(why)
			else
				local plan = chords.plan_bind(keymap, default_chords, action, chord)
				if plan.refuse ~= nil then
					err = plan.refuse
				elseif plan.bind ~= nil then
					local ok, bind_err = compat.settings_bind(cx, plan.bind, chords.id(action))
					if not ok then
						err = "could not bind chord: " .. tostring(bind_err)
					else
						for _, old in plan.unbind do
							local removed, unbind_err = compat.settings_unbind(cx, old)
							if not removed then
								err = "could not unbind chord: " .. tostring(unbind_err)
								break
							end
						end
						rearm()
						wrote = true
					end
				end
			end
		end
	elseif op == "reset" then
		local action = req.fields.action or ""
		if not chord_actions[action] then
			err = "unknown chord action: " .. action
		else
			local raw, why = compat.settings_keybinds_raw(cx)
			if raw == nil then
				err = "could not read keybindings: " .. tostring(why)
			else
				local reset = chords.reset_table(raw, default_chords, action, compat.json_array())
				local ok, set_err = compat.settings_set_keybinds(cx, reset)
				if not ok then
					err = "could not reset chord: " .. tostring(set_err)
				else
					rearm()
					wrote = true
				end
			end
		end
	else
		err = "unknown cfg operation: " .. op
	end
	-- A write re-registers the plugin's chords, which take effect only when this handler returns, so its reply is
	-- sent one tick later, when the keymap already holds them; every other op answers at once.
	if wrote then
		compat.timer(0, function(later: WindowCx?)
			send_cfg(later :: WindowCx, pane, err)
		end)
	else
		send_cfg(cx, pane, err)
	end
end

local function reject_version(cx: WindowCx, url: string, version: string, from: string?)
	local there = from or "the other machine"
	-- The verb word and `p` only: the query can carry a prompt, which never goes into tern.log or the ring.
	local verb = string.match(url, "^jumpr://(%a+)%?") or "?"
	local p = tonumber(string.match(url, "[?&]p=([^&]*)") or "")
	diag.error(
		"router",
		string.format(
			"%s request from %s with p=%s (%s)",
			verb,
			there,
			if p ~= nil then tostring(p) else "none",
			version
		)
	)
	if version == "bad_p_newer" then
		compat.toast(cx, "error", "Jumpr on " .. there .. " is newer: update Jumpr on " .. diag.local_name(cx))
	else
		compat.toast(cx, "error", "Jumpr on " .. there .. " is older: update Jumpr on " .. there)
	end
end

-- Handles one jumpr:// URL. A cfg request routes first to its focused settings pane; every other verb is handled
-- only by the leader window. Returns the verb handled, or nil when the request was dropped.
function M.handle(cx: WindowCx, url: string, pane: number?): string?
	local url_verb = string.match(url, "^jumpr://(%a+)%?")
	if url_verb == "cfg" then
		pusher.scan(cx)
		local settings_host: string?, settings_session: string? = nil, nil
		if pane ~= nil then
			settings_host, settings_session = pusher.settings_info(pane)
		end
		local focused = compat.session_focused(cx)
		if pane == nil or settings_host == nil or settings_session == nil or focused ~= pane then
			diag.error("router", "cfg dropped: its settings pane is not focused in this window")
			return nil
		end
		local version, from = protocol.check_url(url)
		if version == "bad_p_newer" or version == "bad_p_older" then
			reject_version(cx, url, version, from)
			return nil
		end
		local req = protocol.parse_url(url)
		if req == nil then
			diag.error("router", "not a jumpr request: " .. (string.match(url, "^[%a]+://%a*") or "?"))
			return nil
		end
		local last = last_r[req.b]
		if last ~= nil and req.r <= last then
			return nil
		end
		last_r[req.b] = req.r
		req.host = settings_host
		req.sn = settings_session
		cfg(cx, req, pane)
		return req.verb
	end

	if not leader.is_leader() then
		return nil
	end
	local version, from = protocol.check_url(url)
	if version == "bad_p_newer" or version == "bad_p_older" then
		reject_version(cx, url, version, from)
		return nil
	end
	local req = protocol.parse_url(url)
	if req == nil then
		diag.error("router", "not a jumpr request: " .. (string.match(url, "^[%a]+://%a*") or "?"))
		return nil
	end
	local last = last_r[req.b]
	if last ~= nil and req.r <= last then
		return nil
	end
	last_r[req.b] = req.r
	pusher.scan(cx)
	local pane_host: string?, pane_session: string? = nil, nil
	if pane ~= nil then
		pane_host, pane_session = pusher.block_info(pane)
	end
	local focused: number? = nil
	if pane_host ~= nil then
		focused = compat.session_focused(cx)
	end
	local host, route = protocol.request_host({
		answer = req.verb == "hello" or req.verb == "diag",
		pane = pane,
		pane_host = pane_host,
		pane_session = pane_session,
		focused = focused,
		url_host = req.host,
		url_session = req.sn,
		known = known_host(cx, req.host),
		session_host = if req.sn ~= nil then pusher.host_with_session(req.sn) else nil,
	})
	if host == nil then
		-- Another machine's window names this host another way, so an unknown name is expected and never toasted.
		if route == "unknown" and not told_unknown[req.host] then
			told_unknown[req.host] = true
			diag.error("router", req.verb .. " for a machine this window does not know as " .. req.host)
		end
		return nil
	end
	req.host = host
	if req.verb == "hello" then
		pusher.hello(cx, req.host)
	elseif req.verb == "jump" then
		jump(cx, req)
	elseif req.verb == "name" then
		name(cx, req)
	elseif req.verb == "start" then
		start(cx, req)
	elseif req.verb == "settings" then
		open_settings_for(cx, req.host)
	elseif req.verb == "show" then
		show(cx, req)
	elseif req.verb == "stop" then
		stop(cx, req)
	elseif req.verb == "back" then
		back(cx, req)
	elseif req.verb == "diag" then
		if not diag.asking() then
			return nil
		end
		diag.host_dump_arrived(cx, req.host, req.fields.path or "")
	else
		diag.error("router", req.verb .. " from " .. req.host .. " is not handled in this version")
		return nil
	end
	return req.verb
end

diag.provide("router", function(): any
	return { last_r = table.clone(last_r) }
end)

return M
