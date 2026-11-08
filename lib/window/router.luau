--!strict
-- The jumpr:// request handler. Only the leader window acts. A
-- request is parsed and version-checked, dropped when its `r` is at or below the last
-- handled `r` for its block uid `b`, and dispatched: hello, jump, show, start, stop, back, diag.
-- Replies (`act = "res"`) go through compat.session_event to every deck block on the request's host, carrying `b`;
-- when none can be sent, a toast shows the error. Errors name the machine and the agent.

local compat = require("../compat")
local identity = require("../shared/identity")
local protocol = require("../shared/protocol")
local agents = require("./agents")
local block = require("./block")
local copies = require("./copies")
local diag = require("./diag")
local leader = require("./leader")
local pusher = require("./pusher")

local M = {}

local last_r: { [string]: number } = {}

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
	local value = tern.json.encode(protocol.reply(req.b, req.r, ok, err))
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
	local command = identity.command_for(identity.dir_for(id))
	if command == nil then
		fail(cx, req, "refused agent " .. id .. " on " .. req.host .. ": bad agent id")
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

-- `jumpr://stop`: closes the agent's pane (every pane when a duplicate has two), after the block asked for
-- confirmation. `cx.agents:stop` first; when it refuses (an agent restored by a shell command
-- line may not be an agent block), `cx.layout:close` instead. An agent the window does not know is answered with an
-- error, so the block puts the record back to `live`. Closing a tab's last agent lets `copies.tidy` close the lone
-- copy left behind and move focus to the copy in the tab Tern shows next.
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
	for _, pane in panes do
		local ok, err = compat.agents_stop(cx, pane)
		if not ok then
			diag.error("router", "agents:stop on " .. req.host .. " for " .. id .. ": " .. tostring(err))
			ok, err = compat.close(cx, pane)
		end
		if not ok then
			failure = tostring(err)
		end
	end
	if failure ~= nil then
		local text = "could not stop agent " .. id .. " on " .. req.host .. ": " .. failure
		fail(cx, req, text)
		compat.toast(cx, "error", "Jumpr: " .. text)
		return
	end
	reply(cx, req, true, nil)
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

-- Handles one jumpr:// URL in the leader window. Returns the verb handled, or nil when the request was dropped.
-- The version is read from the URL before parsing, so a request from another version is never dropped silently,
-- even one whose verb this version does not know.
function M.handle(cx: WindowCx, url: string): string?
	if not leader.is_leader() then
		return nil
	end
	local version, from = protocol.check_url(url)
	if version == "bad_p_newer" or version == "bad_p_older" then
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
	if not known_host(cx, req.host) then
		diag.error("router", req.verb .. " from unknown machine " .. req.host)
		compat.toast(cx, "error", "Jumpr: unknown machine " .. req.host)
		return nil
	end
	pusher.scan(cx)
	if req.verb == "hello" then
		pusher.hello(cx, req.host)
	elseif req.verb == "jump" then
		jump(cx, req)
	elseif req.verb == "name" then
		name(cx, req)
	elseif req.verb == "start" then
		start(cx, req)
	elseif req.verb == "show" then
		show(cx, req)
	elseif req.verb == "stop" then
		stop(cx, req)
	elseif req.verb == "back" then
		back(cx, req)
	elseif req.verb == "diag" then
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
