--!strict
-- An in-memory Tern window for the window half's tests: the second adapter behind lib/compat.luau.
-- It gives a fake `WindowCx` (hosts, sessions, tabs, panes, agents, focus and the layout calls the plugin makes), and
-- replaces compat's clock, timers, log, data folder, files, JSON and tab-strip calls with ones a test steps.
-- The real compat wrappers still run between the plugin and the fake cx, so their normalisation is exercised too.
-- JSON crosses unchanged: what the plugin encodes is the table itself, so a test reads a sent message as a table.
-- Each test file runs in its own process, so the window modules' state starts fresh in every file.

local Compat = require("../../lib/compat")

local M = {}

-- What the fake JSON null is, so a test can tell an explicit null from a missing value.
M.NULL = table.freeze({ json_null = true })

-- Wall-clock ms at fake time 0.
local WALL_BASE = 1700000000000

export type Pane = {
	pane: number,
	host: number,
	session: number,
	tab: number?,
	title: string,
	kind: string,
	block: string?,
	line: string?,
	command: string?,
	state: string?,
	alert: boolean,
	busy: boolean,
	exited: number?,
	-- In no host's pane list (`cx.hosts:list()`), as a pane the window cannot place on a machine.
	unhosted: boolean?,
}

export type Host = { id: number, name: string, kind: string, state: string, sessions: { number } }
export type Session = { id: number, name: string, host: number, tabs: { number } }
export type Event = { pane: number, act: string, value: any }
export type Toast = { level: string, text: string, sub: string? }

type Timer = { due: number, order: number, fn: (cx: WindowCx?) -> (), cancelled: boolean }

export type World = {
	hosts: { Host },
	sessions: { [number]: Session },
	panes: { [number]: Pane },
	-- Each tab's panes, left to right.
	order: { [number]: { number } },
	current_host: number?,
	current_session: number?,
	-- A session generation shown but no longer listed (see `view_stale`).
	stale: Session?,
	focused: number?,
	-- The pane last focused in each tab.
	tab_focus: { [number]: number },
	-- What the plugin did, in order.
	events: { Event },
	toasts: { Toast },
	copied: { string },
	named: { [number]: string? },
	switches: { number },
	stopped: { number },
	closed: { number },
	opened: { number },
	-- Knobs: what `new_block` answers ("ok", "missing" for no Ready plugin, else an error text); whether a session
	-- switch is seen at once or only once the test moves the view itself; the panes listed but with no program
	-- running (a block that never started), whose events Tern refuses.
	block_result: string,
	switch_lags: boolean,
	dead: { [number]: boolean },
	-- How many view events the plugin tried to send each pane, whether Tern took them or not.
	event_attempts: { [number]: number },
	-- What `cx.layout:arrange` does: nil works; else it raises this text, as a session daemon that cannot serve it does.
	arrange_raises: string?,
	-- When set, `cx.layout:arrange` answers as if it worked (a new tab holding the blocks) but moves nothing.
	arrange_noop: boolean,
	-- Each `cx.layout:arrange` spec the plugin passed, in order.
	arranged: { any },
}

local world: World
local next_id = 0
local now = 0
local timer_order = 0
local timers: { Timer } = {}
local files: { [string]: any } = {}
local logs: { string } = {}
local fs_fails = false

local function fresh_world(): World
	return {
		hosts = {},
		sessions = {},
		panes = {},
		order = {},
		current_host = nil,
		current_session = nil,
		stale = nil,
		focused = nil,
		tab_focus = {},
		events = {},
		toasts = {},
		copied = {},
		named = {},
		switches = {},
		stopped = {},
		closed = {},
		opened = {},
		block_result = "ok",
		switch_lags = false,
		dead = {},
		event_attempts = {},
		arrange_raises = nil,
		arrange_noop = false,
		arranged = {},
	}
end

world = fresh_world()

local function id(): number
	next_id += 1
	return next_id
end

local function host_by_id(hid: number): Host?
	for _, h in world.hosts do
		if h.id == hid then
			return h
		end
	end
	return nil
end

-- The panes of a tab, left to right.
local function tab_panes(tab: number): { number }
	return table.clone(world.order[tab] or {})
end

local function session_of_tab(tab: number): Session?
	for _, s in world.sessions do
		for _, t in s.tabs do
			if t == tab then
				return s
			end
		end
	end
	return nil
end

-- Removes `pane`. When it had focus, focus moves as Tern moves it: to the pane left in its tab, else (the tab
-- closed with it) to the pane last focused in the tab that takes its place in the session (else the one before),
-- or that tab's rightmost pane when none was.
local function remove_pane(pane: number)
	local p = world.panes[pane]
	if p == nil then
		return
	end
	world.panes[pane] = nil
	local had_focus = world.focused == pane
	if had_focus then
		world.focused = nil
	end
	local tab = p.tab
	if tab == nil then
		return
	end
	local in_tab = world.order[tab]
	if in_tab ~= nil then
		local at = table.find(in_tab, pane)
		if at ~= nil then
			table.remove(in_tab, at)
		end
	end
	local left = tab_panes(tab)
	if #left > 0 then
		if had_focus then
			world.focused = left[1]
		end
		return
	end
	local s = session_of_tab(tab)
	if s == nil then
		return
	end
	local index = table.find(s.tabs, tab)
	if index == nil then
		return
	end
	table.remove(s.tabs, index)
	if had_focus then
		local next_tab = s.tabs[index] or s.tabs[index - 1]
		if next_tab ~= nil then
			local last = world.tab_focus[next_tab]
			local panes = tab_panes(next_tab)
			world.focused = if last ~= nil and world.panes[last] ~= nil then last else panes[#panes]
		end
	end
end

local function pane_info(p: Pane): any
	return {
		pane = p.pane,
		title = p.title,
		cwd = "/",
		program = if p.kind == "plugin" then nil else "zsh",
		kind = p.kind,
		tab = p.tab,
		focused = world.focused == p.pane,
		floating = false,
		parked = p.tab == nil,
		busy = p.busy,
		running = if p.line ~= nil then { line = p.line } else nil,
		exited = p.exited,
		error = nil,
		alert = p.alert,
		block = p.block,
	}
end

local function managed_host(h: Host): any
	local panes: { number } = {}
	for pane, p in world.panes do
		if p.host == h.id and not p.unhosted then
			table.insert(panes, pane)
		end
	end
	table.sort(panes)
	return {
		id = h.id,
		name = h.name,
		kind = h.kind,
		address = nil,
		state = h.state,
		detail = nil,
		identity = nil,
		current = world.current_host == h.id,
		rtt_ms = nil,
		sessions = table.clone(h.sessions),
		panes = panes,
	}
end

local function managed_session(s: Session): any
	return {
		id = s.id,
		name = s.name,
		host = s.host,
		current = world.current_session == s.id,
		locked = false,
		note = nil,
		tabs = #s.tabs,
	}
end

local function view_session(session: number)
	local s = world.sessions[session]
	if s ~= nil then
		world.current_session = session
		world.stale = nil
		world.current_host = s.host
	end
end

local fake_cx: any = {
	agents = {
		list = function(_self: any): { any }
			local out = {}
			for _, p in world.panes do
				if p.kind == "agent" then
					table.insert(out, {
						pane = p.pane,
						command = if p.command ~= nil then p.command else M.NULL,
						cwd = "/",
						state = p.state or "idle",
					})
				end
			end
			return out
		end,
		stop = function(_self: any, pane: number)
			if world.panes[pane] == nil then
				error("no agent block " .. tostring(pane))
			end
			table.insert(world.stopped, pane)
			remove_pane(pane)
		end,
	},
	hosts = {
		list = function(_self: any): { any }
			local out = {}
			for _, h in world.hosts do
				table.insert(out, managed_host(h))
			end
			return out
		end,
		current = function(_self: any): any
			local h = if world.current_host ~= nil then host_by_id(world.current_host) else nil
			if h == nil then
				error("no host in view")
			end
			return managed_host(h)
		end,
		terminal = function(_self: any, _host: any, opts: { cwd: string, command: string }): number
			local session = world.current_session
			assert(session ~= nil, "a terminal needs a session in view")
			local tab = M.tab(session)
			return M.agent(tab, nil, opts.command)
		end,
	},
	session = {
		panes = function(_self: any): { any }
			local out = {}
			for _, p in world.panes do
				table.insert(out, pane_info(p))
			end
			table.sort(out, function(a: any, b: any): boolean
				return a.pane < b.pane
			end)
			return out
		end,
		pane = function(_self: any, pane: number): any
			local p = world.panes[pane]
			return if p ~= nil then pane_info(p) else nil
		end,
		event = function(_self: any, pane: number, ev: { [string]: any })
			world.event_attempts[pane] = (world.event_attempts[pane] or 0) + 1
			if world.panes[pane] == nil then
				error("no pane " .. tostring(pane))
			end
			if world.dead[pane] then
				-- As Tern raises it: the reason, then the Lua stack traceback.
				error(
					"runtime error: no program runs in that pane\nstack traceback:\n\t[C]: in ?\n\tcompat.luau: in function 'act'",
					0
				)
			end
			table.insert(world.events, { pane = pane, act = ev.act, value = ev.value })
		end,
		focused = function(_self: any): number?
			return world.focused
		end,
		tab_of = function(_self: any, pane: number): number?
			local p = world.panes[pane]
			return if p ~= nil then p.tab else nil
		end,
		sessions = function(_self: any): { any }
			local out = {}
			for _, s in world.sessions do
				table.insert(out, {
					id = s.id,
					name = s.name,
					current = world.current_session == s.id,
					locked = false,
					tabs = table.clone(s.tabs),
				})
			end
			return out
		end,
		tabs = function(_self: any): { any }
			local out = {}
			for _, s in world.sessions do
				for i, t in s.tabs do
					local panes = tab_panes(t)
					table.insert(out, {
						id = t,
						session = s.id,
						color = nil,
						position = i,
						pane = panes[1],
						name = world.named[t],
						cwd = "/",
						program = "zsh",
						title = "",
						panes = #panes,
						busy = false,
					})
				end
			end
			return out
		end,
		layout = function(_self: any, tab: number): any
			local panes = tab_panes(tab)
			if #panes == 0 then
				return nil
			end
			-- A left-to-right chain of splits.
			local node: any = { pane = panes[#panes] }
			for i = #panes - 1, 1, -1 do
				node = { { pane = panes[i] }, node }
			end
			return { root = node }
		end,
	},
	sessions = {
		list = function(_self: any): { any }
			local out = {}
			for _, s in world.sessions do
				table.insert(out, managed_session(s))
			end
			return out
		end,
		current = function(_self: any): any
			local s = if world.stale ~= nil
				then world.stale
				elseif world.current_session ~= nil then world.sessions[world.current_session]
				else nil
			if s == nil then
				error("no session in view")
			end
			return managed_session(s)
		end,
		switch = function(_self: any, session: number)
			table.insert(world.switches, session)
			if not world.switch_lags then
				view_session(session)
			end
		end,
	},
	layout = {
		-- Focusing a parked pane deals it into the tab in view, beside the focused pane, as Tern does.
		focus = function(_self: any, pane: number)
			local p = world.panes[pane]
			if p == nil then
				error("no pane " .. tostring(pane))
			end
			if p.tab == nil then
				local at = if world.focused ~= nil then world.panes[world.focused] else nil
				if at ~= nil and at.tab ~= nil then
					local tab: number = at.tab
					p.tab = tab
					p.session = at.session
					table.insert(world.order[tab], pane)
				end
			end
			world.focused = pane
			if p.tab ~= nil then
				world.tab_focus[p.tab] = pane
			end
			view_session(p.session)
		end,
		-- Each group with no `tab` becomes a new first tab of the session holding the blocks it names (a parked one is
		-- dealt into it); the answer lists the session's tabs as Tern's does. Focus does not move.
		arrange = function(_self: any, spec: any): ({ any }?, string?)
			table.insert(world.arranged, spec)
			if world.arrange_raises ~= nil then
				error(world.arrange_raises, 0)
			end
			local s = world.sessions[spec.session]
			if s == nil then
				return nil, "unknown session"
			end
			if world.arrange_noop then
				return { { id = id(), position = 1, name = "", blocks = table.clone(spec.tabs[1].blocks) } }, nil
			end
			for i, group in spec.tabs do
				assert(group.tab == nil, "the fake regroups into new tabs only")
				local t = id()
				table.insert(s.tabs, i, t)
				world.order[t] = {}
				for _, pane in group.blocks do
					local p = world.panes[pane]
					assert(p ~= nil and p.tab == nil, "the fake deals parked panes only")
					p.tab = t
					p.session = s.id
					table.insert(world.order[t], pane)
				end
			end
			local out = {}
			for i, t in s.tabs do
				table.insert(out, { id = t, position = i, name = "", blocks = tab_panes(t) })
			end
			return out, nil
		end,
		name_tab = function(_self: any, tab: number, name: string?)
			world.named[tab] = name
		end,
		close = function(_self: any, pane: number)
			if world.panes[pane] == nil then
				error("no pane " .. tostring(pane))
			end
			table.insert(world.closed, pane)
			remove_pane(pane)
		end,
	},
	new_block = function(_self: any, kind: string, _args: { string }?, _how: any, opts: any): number?
		if world.block_result == "missing" then
			return nil
		elseif world.block_result ~= "ok" then
			error(world.block_result, 0)
		end
		local target = world.panes[opts.target]
		assert(target ~= nil and target.tab ~= nil, "new_block beside a tiled pane")
		local tab: number = target.tab
		-- A copy opens left of the tab's leftmost pane.
		local pane = M.pane(tab, { kind = "plugin", block = kind, title = "jumpr", left = true })
		table.insert(world.opened, tab)
		return pane
	end,
	toast = function(_self: any, level: string, text: string, sub: string?)
		table.insert(world.toasts, { level = level, text = text, sub = sub })
	end,
	copy = function(_self: any, text: string)
		table.insert(world.copied, text)
	end,
}

M.cx = fake_cx :: WindowCx

-- The world in view now: hosts, sessions, panes and what the plugin did to them.
function M.world(): World
	return world
end

-- Starts a new world (hosts, sessions, panes, records); the clock, pending timers and files stay, as they would in
-- a window whose machines changed.
function M.reset_world()
	world = fresh_world()
end

-- A host named `name` ("local" or "remote"); returns its id.
function M.host(name: string, kind: string?): number
	local h: Host = { id = id(), name = name, kind = kind or "remote", state = "connected", sessions = {} }
	table.insert(world.hosts, h)
	return h.id
end

-- A session named `name` on host `hid`; returns its id.
function M.session(hid: number, name: string): number
	local s: Session = { id = id(), name = name, host = hid, tabs = {} }
	world.sessions[s.id] = s
	local h = host_by_id(hid)
	assert(h ~= nil, "unknown host")
	table.insert(h.sessions, s.id)
	return s.id
end

-- A new tab at the end of session `sid`; returns its id.
function M.tab(sid: number): number
	local s = world.sessions[sid]
	assert(s ~= nil, "unknown session")
	local t = id()
	table.insert(s.tabs, t)
	return t
end

export type PaneOpts = {
	kind: string?,
	block: string?,
	title: string?,
	line: string?,
	command: string?,
	-- Opens it on the tab's left rather than its right.
	left: boolean?,
	-- Left out of every host's pane list.
	unhosted: boolean?,
}

-- A pane in `tab`, on its right (on its left with `left`).
function M.pane(tab: number, opts: PaneOpts?): number
	local none: PaneOpts = {}
	local o: PaneOpts = opts or none
	local s = session_of_tab(tab)
	assert(s ~= nil, "unknown tab")
	local pane = id()
	local in_tab = world.order[tab]
	if in_tab == nil then
		in_tab = {}
		world.order[tab] = in_tab
	end
	table.insert(in_tab, if o.left then 1 else #in_tab + 1, pane)
	world.panes[pane] = {
		pane = pane,
		host = s.host,
		session = s.id,
		tab = tab,
		title = o.title or "zsh",
		kind = o.kind or "terminal",
		block = o.block,
		line = o.line,
		command = o.command,
		state = nil,
		alert = false,
		busy = false,
		exited = nil,
		unhosted = o.unhosted,
	}
	return pane
end

-- A parked pane of session `sid` (in no tab), as a copy hidden from every tab is.
function M.parked(sid: number, opts: PaneOpts?): number
	local none: PaneOpts = {}
	local o: PaneOpts = opts or none
	local s = world.sessions[sid]
	assert(s ~= nil, "unknown session")
	local pane = id()
	world.panes[pane] = {
		pane = pane,
		host = s.host,
		session = s.id,
		tab = nil,
		title = o.title or "zsh",
		kind = o.kind or "terminal",
		block = o.block,
		line = o.line,
		command = o.command,
		state = nil,
		alert = false,
		busy = false,
		exited = nil,
		unhosted = o.unhosted,
	}
	return pane
end

-- An omp agent in `tab` for deck id `deck` (or running `command` as given), titled `title`; returns its pane.
function M.agent(tab: number, deck: string?, command: string?, title: string?): number
	local line = command or ("omp --continue --session-dir ~/.omp/deck/" .. tostring(deck))
	local pane = M.pane(tab, { kind = "agent", title = title or "omp", line = line, command = line })
	world.panes[pane].state = "idle"
	return pane
end

-- Shows session `sid` (and its host) in the window.
function M.view(sid: number)
	view_session(sid)
end

-- Shows host `hid` with a session generation the window no longer lists, as a reconnect or reload can report for a
-- moment: `cx.sessions:current()` names a session `name` (on `session_host`, else `hid`) that is in no host's
-- session list and no session row.
function M.view_stale(hid: number, name: string, session_host: number?)
	world.current_host = hid
	world.current_session = nil
	world.stale = { id = id(), name = name, host = session_host or hid, tabs = {} }
end

-- Focuses `pane` as a click would, without telling the plugin.
function M.focus(pane: number)
	local p = world.panes[pane]
	assert(p ~= nil, "unknown pane")
	world.focused = pane
	if p.tab ~= nil then
		world.tab_focus[p.tab] = pane
	end
	view_session(p.session)
end

-- Closes `pane` as the user would, without telling the plugin.
function M.close(pane: number)
	remove_pane(pane)
end

-- Parks `pane` as the user's Park pane does, without telling the plugin: its program runs on in no tab, its tab
-- closes when it was the tab's only pane, and focus moves as a close would move it.
function M.park(pane: number)
	local p = world.panes[pane]
	assert(p ~= nil and p.tab ~= nil, "park a pane in a tab")
	remove_pane(pane)
	p.tab = nil
	world.panes[pane] = p
end

-- The copies of the list (plugin blocks) in `tab`, lowest first.
function M.copies_in(tab: number): { number }
	local out: { number } = {}
	for _, pane in tab_panes(tab) do
		if world.panes[pane].block ~= nil then
			table.insert(out, pane)
		end
	end
	return out
end

-- The status messages (`act = "st"`) sent so far, oldest first, optionally only those to `pane`.
function M.status_sent(pane: number?): { any }
	local out = {}
	for _, e in world.events do
		if e.act == "st" and (pane == nil or e.pane == pane) then
			table.insert(out, e.value)
		end
	end
	return out
end

-- Clock and timers ----------------------------------------------------------------------------------------------------

-- Fake monotonic ms.
function M.now(): number
	return now
end

-- Fake wall-clock ms, as compat.wall_ms gives it.
function M.wall(): number
	return WALL_BASE + math.floor(now)
end

-- Moves the clock on by `ms`, running every timer that falls due on the way, in due order (ties in arming order),
-- with the window cx; a timer armed while running runs too when it falls due within `ms`.
function M.advance(ms: number)
	local target = now + ms
	while true do
		local best: Timer? = nil
		local best_i = 0
		for i, t in timers do
			if
				t.due <= target
				and (best == nil or t.due < best.due or (t.due == best.due and t.order < best.order))
			then
				best, best_i = t, i
			end
		end
		if best == nil then
			break
		end
		table.remove(timers, best_i)
		now = math.max(now, best.due)
		if not best.cancelled then
			best.fn(fake_cx)
		end
	end
	now = target
end

-- How many armed timers have not run or been cancelled.
function M.pending_timers(): number
	local n = 0
	for _, t in timers do
		if not t.cancelled then
			n += 1
		end
	end
	return n
end

-- Files and logs --------------------------------------------------------------------------------------------------------

-- The files the plugin wrote (by path), as the plugin's JSON gave them.
function M.files(): { [string]: any }
	return files
end

-- Makes every file write fail (true) or work again (false).
function M.fail_writes(fail: boolean)
	fs_fails = fail
end

-- The lines the plugin wrote to Tern's log.
function M.logs(): { string }
	return logs
end

-- The installed adapter ------------------------------------------------------------------------------------------------

Compat.now = function(): number
	return now
end
Compat.wall_ms = M.wall
Compat.timer = function(ms: number, fn: (cx: WindowCx?) -> ()): TimerHandle
	timer_order += 1
	local t: Timer = { due = now + ms, order = timer_order, fn = fn, cancelled = false }
	table.insert(timers, t)
	local handle: any = {
		cancel = function(_self: any)
			t.cancelled = true
		end,
	}
	return handle
end
Compat.log_warn = function(text: string)
	table.insert(logs, text)
end
Compat.data_dir = function(): string
	return "/data"
end
Compat.json_encode = function(value: any, _pretty: boolean?): string
	local same: any = value
	return same
end
Compat.json_decode = function(text: string): (any, string?)
	return text, nil
end
Compat.json_array = function(): { any }
	return {}
end
Compat.json_null = function(): any
	return M.NULL
end
Compat.fs_read = function(path: string, _max_bytes: number?): (string?, string?)
	return files[path], nil
end
Compat.fs_write = function(path: string, text: string): (boolean, string?)
	if fs_fails then
		return false, "disk full"
	end
	files[path] = text
	return true, nil
end
Compat.chrome_refresh = function(): (boolean, string?)
	return true, nil
end
Compat.process_run_version = function(cb: (string?) -> ()): (boolean, string?)
	cb("tern 0.0.0 (test)")
	return true, nil
end

return M
