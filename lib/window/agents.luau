--!strict
-- The window's binding of deck agents and their raw status. It applies
-- `identity.match` to `AgentItem.command` and `PaneItem.line`, joins each pane to its host through
-- `compat.hosts_list(cx)` `.panes`, and keeps `{host name -> {deck id -> {window pane id}}}` in memory. Window pane
-- ids never leave the window: `entries` is keyed by deck id.

local compat = require("../compat")
local identity = require("../shared/identity")
local status = require("../shared/status")
local diag = require("./diag")

local M = {}

-- What the window last saw of one deck agent pane.
type Facts = {
	host: string,
	id: string,
	-- AgentItem.state; nil for a pane that matched only on its running line.
	state: string?,
	alert: boolean,
	busy: boolean,
	error: string?,
	exited: number?,
	delivery_error: string?,
}

local STATE_CODE: { [string]: string } = {
	working = "w",
	waiting_input = "q",
	idle = "i",
	exited = "x",
}

local bindings: { [string]: { [string]: { number } } } = {}
local facts: { [number]: Facts } = {}
-- Panes the last rebuild saw that are not deck agents, so their events skip a rebuild.
local ignored: { [number]: boolean } = {}
-- The last agent_finished result per pane; "failed" until the pane is looked at or starts a new turn.
local finished: { [number]: string } = {}

local function pane_key(pane: number): string
	return string.format("%.0f", pane)
end

-- Re-reads agents and rebuilds the binding. `read_hosts` and `read_panes` are the caller's read when it already made
-- one (a handler reads the pane list once, to keep events cheap), else they are read here. On a failed read the old binding stays.
function M.rebuild(cx: WindowCx, read_hosts: { ManagedHost }?, read_panes: { compat.PaneItem }?): boolean
	local hosts, hosts_err = read_hosts, nil
	if hosts == nil then
		hosts, hosts_err = compat.hosts_list(cx)
	end
	local panes, panes_err = read_panes, nil
	if panes == nil then
		panes, panes_err = compat.session_panes(cx)
	end
	local list, list_err = compat.agents_list(cx)
	if hosts == nil or panes == nil or list == nil then
		diag.error("agents", "rebuild: " .. tostring(hosts_err or panes_err or list_err))
		return false
	end
	local host_of: { [number]: string } = {}
	for _, h in hosts do
		for _, p in h.panes do
			host_of[p] = h.name
		end
	end
	local agent_of: { [number]: compat.AgentItem } = {}
	local order: { number } = {}
	for _, a in list do
		agent_of[a.pane] = a
		table.insert(order, a.pane)
	end
	local pane_of: { [number]: compat.PaneItem } = {}
	for _, p in panes do
		pane_of[p.pane] = p
		if agent_of[p.pane] == nil then
			table.insert(order, p.pane)
		end
	end
	local new_bindings: { [string]: { [string]: { number } } } = {}
	local new_facts: { [number]: Facts } = {}
	local new_ignored: { [number]: boolean } = {}
	for _, pane in order do
		local a = agent_of[pane]
		local p = pane_of[pane]
		local id: string? = nil
		if a ~= nil and a.command ~= nil then
			id = identity.match(a.command)
		end
		if id == nil and p ~= nil and p.line ~= nil then
			id = identity.match(p.line)
		end
		local host = host_of[pane]
		if id == nil or host == nil then
			new_ignored[pane] = true
		else
			new_facts[pane] = {
				host = host,
				id = id,
				state = if a ~= nil then a.state else nil,
				alert = p ~= nil and p.alert,
				busy = p ~= nil and p.busy,
				error = if p ~= nil then p.error else nil,
				exited = if p ~= nil then p.exited else nil,
				delivery_error = if a ~= nil then a.delivery_error else nil,
			}
			local by_id = new_bindings[host]
			if by_id == nil then
				by_id = {}
				new_bindings[host] = by_id
			end
			local list_for = by_id[id]
			if list_for == nil then
				list_for = {}
				by_id[id] = list_for
			end
			table.insert(list_for, pane)
		end
	end
	for _, by_id in new_bindings do
		for _, ps in by_id do
			table.sort(ps)
		end
	end
	for pane in finished do
		if new_facts[pane] == nil then
			finished[pane] = nil
		end
	end
	bindings, facts, ignored = new_bindings, new_facts, new_ignored
	return true
end

-- Refreshes one pane's alert, error, exit status and busy flag.
local function refresh_pane(cx: WindowCx, f: Facts, pane: number)
	local p, err = compat.session_pane(cx, pane)
	if p == nil then
		if err ~= nil then
			diag.error("agents", "pane " .. pane_key(pane) .. " on " .. f.host .. ": " .. err)
		end
		return
	end
	f.alert = p.alert
	f.busy = p.busy
	f.error = p.error
	f.exited = p.exited
end

-- The facts of `pane`, rebuilding first when the pane is new to the window. Nil for a pane that is no deck agent.
local function known(cx: WindowCx, pane: number): Facts?
	local f = facts[pane]
	if f == nil and not ignored[pane] then
		M.rebuild(cx)
		f = facts[pane]
	end
	return f
end

-- `agent_state`: the agent's state changed; a new turn clears the last failure.
function M.on_state(cx: WindowCx, ev: AgentStateEvent): boolean
	local f = known(cx, ev.pane)
	if f == nil then
		return false
	end
	f.state = ev.new
	if ev.new == "working" then
		finished[ev.pane] = nil
	end
	refresh_pane(cx, f, ev.pane)
	return true
end

-- `agent_finished`: remember the result; an exited agent is "x", a closed block leaves the binding.
function M.on_finished(cx: WindowCx, ev: AgentFinishedEvent): boolean
	local f = known(cx, ev.pane)
	if f == nil then
		return false
	end
	if ev.result == "closed" then
		M.rebuild(cx)
		return true
	end
	finished[ev.pane] = ev.result
	if ev.result == "exited" then
		f.state = "exited"
	end
	refresh_pane(cx, f, ev.pane)
	return true
end

-- `focus`: the pane is looked at, so Tern clears its alert and a failed turn counts as seen.
function M.on_focus(pane: number): boolean
	local f = facts[pane]
	if f == nil then
		return false
	end
	f.alert = false
	if finished[pane] == "failed" then
		finished[pane] = "seen"
	end
	return true
end

local function entry(pane: number, f: Facts): status.Entry
	local s: string
	if f.exited ~= nil then
		s = "x"
	elseif f.state ~= nil and STATE_CODE[f.state] ~= nil then
		s = STATE_CODE[f.state]
	elseif f.busy then
		s = "w"
	else
		s = "i"
	end
	local e: string? = nil
	if f.delivery_error ~= nil and f.delivery_error ~= "" then
		e = f.delivery_error
	elseif f.error ~= nil and f.error ~= "" then
		e = f.error
	elseif f.exited ~= nil and f.exited ~= 0 then
		e = "exit status " .. string.format("%d", f.exited)
	end
	return {
		s = s,
		u = if f.alert then true else nil,
		f = if finished[pane] == "failed" then true else nil,
		e = e,
		src = "agents",
	}
end

-- The status entries of every deck agent on `host`: one entry per live pane, keyed by deck id.
function M.entries(host: string): { [string]: { status.Entry } }
	local out: { [string]: { status.Entry } } = {}
	local by_id = bindings[host]
	if by_id == nil then
		return out
	end
	for id, panes in by_id do
		local list: { status.Entry } = {}
		for _, pane in panes do
			local f = facts[pane]
			if f ~= nil then
				table.insert(list, entry(pane, f))
			end
		end
		if #list > 0 then
			out[id] = list
		end
	end
	return out
end

-- The window pane of deck agent `id` on `host` (the first when it is a duplicate), and how many panes it has.
function M.pane_for(host: string, id: string): (number?, number)
	local by_id = bindings[host]
	local panes = if by_id ~= nil then by_id[id] else nil
	if panes == nil or #panes == 0 then
		return nil, 0
	end
	return panes[1], #panes
end

-- Every window pane of deck agent `id` on `host`, lowest first (more than one is a duplicate); empty when none.
function M.panes_for(host: string, id: string): { number }
	local by_id = bindings[host]
	local panes = if by_id ~= nil then by_id[id] else nil
	return if panes ~= nil then table.clone(panes) else {}
end

-- Whether `pane` is a deck agent pane in the binding (the tab-title formatter prefers it among a tab's panes).
function M.is_agent(pane: number): boolean
	return facts[pane] ~= nil
end

-- The host and deck id of agent pane `pane` from the binding; nil for a pane that is no deck agent.
function M.agent_of(pane: number): (string?, string?)
	local f = facts[pane]
	if f == nil then
		return nil, nil
	end
	return f.host, f.id
end

diag.provide("agents", function(): any
	local map: { [string]: { [string]: { string } } } = {}
	for host, by_id in bindings do
		local m: { [string]: { string } } = {}
		for id, panes in by_id do
			local keys: { string } = {}
			for _, pane in panes do
				table.insert(keys, pane_key(pane))
			end
			m[id] = keys
		end
		map[host] = m
	end
	local last: { [string]: string } = {}
	for pane, result in finished do
		last[pane_key(pane)] = result
	end
	local hosts: { [string]: any } = {}
	for host in bindings do
		hosts[host] = M.entries(host)
	end
	return { bindings = map, finished = last, entries = hosts }
end)

return M
