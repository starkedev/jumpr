--!strict
-- The window's binding of deck agents and their raw status. It applies
-- `identity.match` to `AgentItem.command` and `PaneItem.line`, joins each pane to its host through
-- `compat.hosts_list(cx)` `.panes`, and keeps `{host name -> {deck id -> {window pane id}}}` in memory. Window pane
-- ids never leave the window: `entries` is keyed by deck id. Each entry carries when this window last saw it change,
-- so the host can prefer the window that watched a change over one that only read the state afterwards.
-- A parked pane (its program running in no tab) is bound like any other and its entry says so. Tern lists a parked
-- pane in its host's panes; should a host listing ever leave one out, it keeps the host this window last bound it to.

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
	-- Parked: the program runs in no tab.
	parked: boolean,
	-- Wall-clock ms when this window last saw the pane's entry change; 0 while it has seen none since it first saw
	-- the pane (a window that attaches after an agent finished never saw the finish).
	c: number,
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

-- The entry the window sends for `pane`, with the time it last saw that entry change (none while it has seen none).
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
		c = if f.c > 0 then f.c else nil,
		k = if f.parked then true else nil,
	}
end

-- What the entry of `pane` reads, its change time aside, to tell a change from a re-read of the same state.
local function seen_as(pane: number, f: Facts): string
	return status.seen_key(entry(pane, f))
end

-- Stamps `f` with the time now when the entry of `pane` reads differently from `before`.
local function stamp(pane: number, f: Facts, before: string)
	if seen_as(pane, f) ~= before then
		f.c = compat.wall_ms()
	end
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
		local host: string? = host_of[pane]
		if host == nil and p ~= nil and p.parked then
			local before = facts[pane]
			host = if before ~= nil then before.host else nil
		end
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
				parked = p ~= nil and p.parked,
				c = 0,
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
	-- A pane already known keeps its change time while its entry reads the same, and is stamped now when it differs.
	for pane, f in new_facts do
		local old = facts[pane]
		if old ~= nil and old.id == f.id and old.host == f.host then
			f.c = if seen_as(pane, old) == seen_as(pane, f) then old.c else compat.wall_ms()
		end
	end
	bindings, facts, ignored = new_bindings, new_facts, new_ignored
	return true
end

-- Refreshes one pane's alert, error, exit status, busy flag and whether it is parked.
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
	f.parked = p.parked
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
	local before = seen_as(ev.pane, f)
	f.state = ev.new
	if ev.new == "working" then
		finished[ev.pane] = nil
	end
	refresh_pane(cx, f, ev.pane)
	stamp(ev.pane, f, before)
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
	local before = seen_as(ev.pane, f)
	finished[ev.pane] = ev.result
	if ev.result == "exited" then
		f.state = "exited"
	end
	refresh_pane(cx, f, ev.pane)
	stamp(ev.pane, f, before)
	return true
end

-- `focus`: the pane is looked at, so Tern clears its alert and a failed turn counts as seen.
function M.on_focus(pane: number): boolean
	local f = facts[pane]
	if f == nil then
		return false
	end
	local before = seen_as(pane, f)
	f.alert = false
	if finished[pane] == "failed" then
		finished[pane] = "seen"
	end
	stamp(pane, f, before)
	return true
end

-- The status entries of every deck agent on `host`, keyed by deck id: one entry per pane, a pane whose program exited
-- included (as "x"; the host leaves it out while the agent runs in another pane).
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

-- The window pane of deck agent `id` on `host`, and how many panes it has. With several, the lowest whose program
-- still runs in a tab, else the lowest still running parked: a restart starts the agent in a new pane and leaves the
-- exited one open, and a jump, a tab name or a shown tab is for the running agent. With none running, the lowest.
function M.pane_for(host: string, id: string): (number?, number)
	local by_id = bindings[host]
	local panes = if by_id ~= nil then by_id[id] else nil
	if panes == nil or #panes == 0 then
		return nil, 0
	end
	local parked: number? = nil
	for _, pane in panes do
		local f = facts[pane]
		if f ~= nil and not status.exited(entry(pane, f)) then
			if not f.parked then
				return pane, #panes
			end
			parked = parked or pane
		end
	end
	return parked or panes[1], #panes
end

-- Whether agent pane `pane` was parked (running in no tab) when the binding last read it.
function M.parked(pane: number): boolean
	local f = facts[pane]
	return f ~= nil and f.parked
end

-- Whether a bound agent pane in `panes` (the window's pane read) was parked or dealt back into a tab since the
-- binding last read it: Tern sends no event for either, so the caller rebuilds the binding when this is true.
function M.park_moved(panes: { compat.PaneItem }): boolean
	for _, p in panes do
		local f = facts[p.pane]
		if f ~= nil and f.parked ~= p.parked then
			return true
		end
	end
	return false
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
