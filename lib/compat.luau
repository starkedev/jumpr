--!strict
-- The one seam to Tern. Every `cx` call and every `tern.pane`, `tern.kv`, `tern.fs`,
-- `tern.process` and `tern.chrome` call in the plugin goes through this file, so a Tern API change breaks one file.
--
-- Conventions:
-- * Every function runs its Tern call through `pcall` and returns `(value, err?)`; `err` is a string exactly when
--   the call failed. For a call with no result the value is `true` on success and `false` on failure.
-- * Window functions take the window `cx` (WindowCx) first, host block functions the block `cx` (BlockCx); calls
--   on the `tern` global take no `cx`.
-- * Field reads that differ between Tern versions are normalised here: optional fields that arrive as
--   `tern.json.null` (or any other wrong type) become nil, `AgentBlock.command` is a string or nil, and
--   `PaneInfo.running.line` is flattened to `PaneItem.line`, a string or nil.

local M = {}

-- A pane as the window (`cx.session:panes()`) or the host (`tern.pane.list()`) lists it, normalised.
export type PaneItem = {
	pane: number,
	title: string,
	cwd: string?,
	program: string?,
	-- Native block kind ("terminal", "agent", "plugin", ...); window only.
	kind: string?,
	-- Containing tab; window only, nil for a parked pane.
	tab: number?,
	focused: boolean,
	floating: boolean,
	parked: boolean,
	busy: boolean,
	-- The command line running in it (`PaneInfo.running.line`); window terminal/agent only.
	line: string?,
	-- Program exit status; window only.
	exited: number?,
	-- Startup error; window only.
	error: string?,
	-- Unseen alert; window only.
	alert: boolean,
	-- Plugin-qualified block kind ("jumpr.list"); window only.
	block: string?,
}

-- An agent block as `cx.agents:list()` gives it, normalised.
export type AgentItem = {
	pane: number,
	-- The command it was started with; nil when Tern reports none (JSON null).
	command: string?,
	cwd: string,
	-- "idle" | "working" | "waiting_input" | "exited", as Tern reports it.
	state: string,
	-- Why a queued prompt could not be delivered.
	delivery_error: string?,
}

-- What `terminal_start` passes to `cx.hosts:terminal`.
export type TerminalOpts = {
	cwd: string,
	command: string,
}

local function str(x: any): string?
	if typeof(x) == "string" then
		return x
	end
	return nil
end

local function num(x: any): number?
	if typeof(x) == "number" then
		return x
	end
	return nil
end

local function flag(x: any): boolean
	return x == true
end

-- Runs `f` and returns its result, or nil and the error text.
local function call<T>(f: () -> T): (T?, string?)
	local ok, res = pcall(f)
	if ok then
		return res, nil
	end
	return nil, tostring(res)
end

-- Runs `f`, which returns nothing: true, or false and the error text.
local function act(f: () -> ()): (boolean, string?)
	-- Typed as returning anything, so the error value pcall adds on failure type-checks.
	local ok, err = pcall(f :: () -> ...any)
	if ok then
		return true, nil
	end
	return false, tostring(err)
end

local function pane_item(p: PaneInfo): PaneItem
	local running: any = p.running
	local line: string? = nil
	if typeof(running) == "table" then
		line = str(running.line)
	end
	return {
		pane = p.pane,
		title = str(p.title) or "",
		cwd = str(p.cwd),
		program = str(p.program),
		kind = str(p.kind),
		tab = num(p.tab),
		focused = flag(p.focused),
		floating = flag(p.floating),
		parked = flag(p.parked),
		busy = flag(p.busy),
		line = line,
		exited = num(p.exited),
		error = str(p.error),
		alert = flag(p.alert),
		block = str(p.block),
	}
end

local function pane_items(list: { PaneInfo }): { PaneItem }
	local out: { PaneItem } = {}
	for _, p in list do
		table.insert(out, pane_item(p))
	end
	return out
end

local function agent_item(a: AgentBlock): AgentItem
	return {
		pane = a.pane,
		command = str(a.command),
		cwd = str(a.cwd) or "",
		state = str(a.state) or "unknown",
		delivery_error = str(a.delivery_error),
	}
end

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Window: agents ---------------------------------------------------------------------------------------------------

-- Every agent block in every session (`cx.agents:list()`).
function M.agents_list(cx: WindowCx): ({ AgentItem }?, string?)
	local list, err = call(function(): { AgentBlock }
		return cx.agents:list()
	end)
	if list == nil then
		return nil, err
	end
	local out: { AgentItem } = {}
	for _, a in list do
		table.insert(out, agent_item(a))
	end
	return out, nil
end

-- Opens a shell tab on the host in view (`cx.hosts:terminal`); returns its pane id. A terminal-started omp still
-- appears in `agents:list()` (checked against Tern), so status, binding and messages all keep working.
function M.terminal_start(cx: WindowCx, opts: TerminalOpts): (number?, string?)
	return call(function(): number
		return cx.hosts:terminal(nil, { cwd = opts.cwd, command = opts.command })
	end)
end

-- Closes an agent block and ends its program (`cx.agents:stop`).
function M.agents_stop(cx: WindowCx, pane: number): (boolean, string?)
	return act(function()
		cx.agents:stop(pane)
	end)
end

-- Window: panes, tabs, sessions, hosts ------------------------------------------------------------------------------

-- Every pane in the window, parked ones and other sessions' included (`cx.session:panes()`).
function M.session_panes(cx: WindowCx): ({ PaneItem }?, string?)
	local list, err = call(function(): { PaneInfo }
		return cx.session:panes()
	end)
	if list == nil then
		return nil, err
	end
	return pane_items(list), nil
end

-- One pane by id (`cx.session:pane`); nil, with no error, when the window has no such pane.
function M.session_pane(cx: WindowCx, pane: number): (PaneItem?, string?)
	local info, err = call(function(): PaneInfo?
		return cx.session:pane(pane)
	end)
	if info == nil then
		return nil, err
	end
	return pane_item(info), nil
end

-- Sends a view event to a block (`cx.session:event`); the status route uses `{ev = "action", act = ..., ...}`.
function M.session_event(cx: WindowCx, pane: number, ev: { [string]: any }): (boolean, string?)
	return act(function()
		cx.session:event(pane, ev)
	end)
end

-- The focused pane id (`cx.session:focused()`); nil, with no error, when none is.
function M.session_focused(cx: WindowCx): (number?, string?)
	return call(function(): number?
		return cx.session:focused()
	end)
end

-- The tab holding a tiled or floating pane (`cx.session:tab_of`); nil, with no error, for none.
function M.session_tab_of(cx: WindowCx, pane: number): (number?, string?)
	return call(function(): number?
		return cx.session:tab_of(pane)
	end)
end

-- Every named session with its ordered tab ids (`cx.session:sessions()`), to find the session a tab is in.
function M.session_tabs(cx: WindowCx): ({ SessionInfo }?, string?)
	return call(function(): { SessionInfo }
		return cx.session:sessions()
	end)
end

-- Every tab with its focused pane (`cx.session:tabs()`), for the last-tab toggle's jump.
function M.tabs_list(cx: WindowCx): ({ TabInfo }?, string?)
	return call(function(): { TabInfo }
		return cx.session:tabs()
	end)
end

-- The leftmost (top-left) tiled pane of a tab, from `cx.session:layout`; nil, with no error, for an unknown tab.
function M.leftmost_pane(cx: WindowCx, tab: number): (number?, string?)
	local layout, err = call(function(): TabLayout?
		return cx.session:layout(tab)
	end)
	if layout == nil then
		return nil, err
	end
	local node: any = layout.root
	while typeof(node) == "table" do
		local pane = num(node.pane)
		if pane ~= nil then
			return pane, nil
		end
		node = node[1]
	end
	return nil, nil
end

-- Every tiled pane of a tab in reading order (left/top first), from `cx.session:layout`; nil for an unknown tab.
function M.tab_panes(cx: WindowCx, tab: number): ({ number }?, string?)
	local layout, err = call(function(): TabLayout?
		return cx.session:layout(tab)
	end)
	if layout == nil then
		return nil, err
	end
	local out: { number } = {}
	local function walk(node: any)
		if typeof(node) ~= "table" then
			return
		end
		local pane = num(node.pane)
		if pane ~= nil then
			table.insert(out, pane)
			return
		end
		walk(node[1])
		walk(node[2])
	end
	walk(layout.root)
	return out, nil
end

-- Every session on every attached host, with its host slot (`cx.sessions:list()`).
function M.sessions_list(cx: WindowCx): ({ ManagedSession }?, string?)
	return call(function(): { ManagedSession }
		return cx.sessions:list()
	end)
end

-- The session in view (`cx.sessions:current()`).
function M.current_session(cx: WindowCx): (ManagedSession?, string?)
	return call(function(): ManagedSession
		return cx.sessions:current()
	end)
end

-- Every attached host, with its state, sessions and window pane ids (`cx.hosts:list()`).
function M.hosts_list(cx: WindowCx): ({ ManagedHost }?, string?)
	return call(function(): { ManagedHost }
		return cx.hosts:list()
	end)
end

-- The host of the session in view (`cx.hosts:current()`).
function M.current_host(cx: WindowCx): (ManagedHost?, string?)
	return call(function(): ManagedHost
		return cx.hosts:current()
	end)
end

-- Window: layout --------------------------------------------------------------------------------------------------

-- Focuses a pane, switching the view to its session when another is shown (`cx.layout:focus`).
function M.focus(cx: WindowCx, pane: number): (boolean, string?)
	return act(function()
		cx.layout:focus(pane)
	end)
end

-- Opens a plugin block (`cx:new_block`); nil, with no error, when the host has no Ready plugin defining `kind`.
function M.new_block(cx: WindowCx, kind: string, args: { string }?, how: How?, opts: BlockOpts?): (number?, string?)
	return call(function(): number?
		return cx:new_block(kind, args, how, opts)
	end)
end

-- Switches the view to a session by its id (`cx.sessions:switch`). By id, never by name: two hosts can hold
-- sessions of the same name, and a name could switch to the other host's.
function M.session_switch(cx: WindowCx, session: number): (boolean, string?)
	return act(function()
		cx.sessions:switch(session)
	end)
end

-- Names a tab (`cx.layout:name_tab`); a nil or blank name restores the tab's pane label.
function M.name_tab(cx: WindowCx, tab: number, name: string?)
	return act(function()
		cx.layout:name_tab(tab, name)
	end)
end

-- Registers the tab-title formatter (`tern.chrome.tab_title`); `fn` maps a tab to its title, nil to keep Tern's.
function M.tab_title(fn: (tab: TabInfo) -> string?): (boolean, string?)
	return act(function()
		tern.chrome.tab_title(fn)
	end)
end

-- Asks Tern to redraw the tab strip after a formatter's titles change (`tern.chrome.refresh`).
function M.chrome_refresh(): (boolean, string?)
	return act(function()
		tern.chrome.refresh()
	end)
end

-- Closes a pane with no confirmation (`cx.layout:close`), the `stop` fallback.
function M.close(cx: WindowCx, pane: number): (boolean, string?)
	return act(function()
		cx.layout:close(pane)
	end)
end

-- Window: feedback ------------------------------------------------------------------------------------------------

-- Shows a window toast (`cx:toast`); `sub` is a second line.
function M.toast(cx: WindowCx, level: ToastLevel, text: string, sub: string?): (boolean, string?)
	return act(function()
		cx:toast(level, text, sub)
	end)
end

-- Copies text to the clipboard (`cx:copy`).
function M.copy(cx: WindowCx, text: string): (boolean, string?)
	return act(function()
		cx:copy(text)
	end)
end

-- Host block ------------------------------------------------------------------------------------------------------

-- Opens a URL through the window's `tern.route.link` (`cx:open`); every `jumpr://` request goes this way.
function M.open(cx: BlockCx, url: string): (boolean, string?)
	return act(function()
		cx:open(url)
	end)
end

-- Re-renders the block's view (`cx:render()`), after changes from timers, hooks or processes.
function M.render(cx: BlockCx): (boolean, string?)
	return act(function()
		cx:render()
	end)
end

-- Gives a view node the surface's focus (caret and native edits) with a raw TSP op (`cx:frame`); nil clears it.
function M.focus_field(cx: BlockCx, id: string?): (boolean, string?)
	return act(function()
		local target: any = if id ~= nil then id else tern.json.null
		cx:frame({ { "focus", target } })
	end)
end

-- Scrolls a view node into view, the least distance needed, with a raw TSP op (`cx:frame`); a node in the block's
-- main region scrolls that region.
function M.reveal(cx: BlockCx, id: string): (boolean, string?)
	return act(function()
		cx:frame({ { "reveal", id, "nearest" } })
	end)
end

-- The block's width in cells (`cx.cols`).
function M.cols(cx: BlockCx): (number?, string?)
	return call(function(): number?
		return num(cx.cols)
	end)
end

-- The block's own pane id on its host (`cx.pane`).
function M.pane_of(cx: BlockCx): (number?, string?)
	return call(function(): number?
		return num(cx.pane)
	end)
end

-- The block's working directory (`cx.cwd`); nil, with no error, when Tern does not know it.
function M.cwd_of(cx: BlockCx): (string?, string?)
	return call(function(): string?
		return str(cx.cwd)
	end)
end

-- Host panes ------------------------------------------------------------------------------------------------------

-- Types `text` into a pane's pty on this host (`tern.pane.write`); end it with "\r" to submit it.
function M.pane_write(pane: number, text: string): (boolean, string?)
	return act(function()
		tern.pane.write(pane, text)
	end)
end

-- Every pane on this host (`tern.pane.list()`), normalised.
function M.pane_list(): ({ PaneItem }?, string?)
	local list, err = call(function(): { PaneInfo }
		return tern.pane.list()
	end)
	if list == nil then
		return nil, err
	end
	return pane_items(list), nil
end

-- kv (host half only: the window half never writes kv) ---------------------------------------------------------------

-- The JSON value stored under `key` (`tern.kv.get`); nil, with no error, when none is.
function M.kv_get(key: string): (any, string?)
	return call(function(): any
		return tern.kv.get(key)
	end)
end

-- Stores a JSON value under `key` (`tern.kv.set`); nil deletes it.
function M.kv_set(key: string, value: any): (boolean, string?)
	return act(function()
		tern.kv.set(key, value)
	end)
end

-- Files -------------------------------------------------------------------------------------------------------------

-- Reads a file (`tern.fs.read`), at most `max_bytes` when given; nil, with no error, when it does not exist.
function M.fs_read(path: string, max_bytes: number?): (string?, string?)
	return call(function(): string?
		if not tern.fs.exists(path) then
			return nil
		end
		return tern.fs.read(path, max_bytes)
	end)
end

-- Writes a file, replacing it (`tern.fs.write`), and first creates its parent directory if that is missing.
function M.fs_write(path: string, text: string): (boolean, string?)
	return act(function()
		local dir = string.match(path, "^(.*)/[^/]*$")
		if dir ~= nil and dir ~= "" and not tern.fs.exists(dir) then
			tern.fs.mkdir(dir)
		end
		tern.fs.write(path, text)
	end)
end

-- Whether `path` is a directory on this machine: it exists (`tern.fs.exists`) and lists as one (`tern.fs.list`,
-- which raises on anything else). False, with the error, when the check itself fails (a file, no permission).
function M.is_dir(path: string): (boolean, string?)
	local found, err = call(function(): boolean
		if not tern.fs.exists(path) then
			return false
		end
		tern.fs.list(path)
		return true
	end)
	return found == true, err
end

-- Processes ---------------------------------------------------------------------------------------------------------

-- Finds the common git directory of `folder` on this machine by running
-- `git -C <folder> rev-parse --path-format=absolute --git-common-dir` (`tern.process.run`, an argument vector, never
-- a shell). `cb` gets the trimmed absolute path, or nil when git fails, times out or `folder` is not in a repo. If
-- the process cannot start, `cb(nil)` runs before this returns, and the result is false with the error.
function M.git_common_dir(folder: string, cb: (string?) -> ()): (boolean, string?)
	local argv = { "git", "-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir" }
	local ok, err = act(function()
		tern.process.run(argv, { timeout_ms = 5000 }, function(res: ProcessResult, _cx: WindowCx?)
			local path = if res.status == 0 then trim(str(res.stdout) or "") else ""
			cb(if path ~= "" then path else nil)
		end)
	end)
	if not ok then
		cb(nil)
	end
	return ok, err
end

-- Reads Tern's version by running `tern --version` (`tern.process.run`). `cb` gets the trimmed first line
-- ("tern 0.9.10 (2ad447b)"), or nil on failure. If the process cannot start, `cb(nil)` runs before this returns.
function M.process_run_version(cb: (string?) -> ()): (boolean, string?)
	local ok, err = act(function()
		tern.process.run({ "tern", "--version" }, { timeout_ms = 5000 }, function(res: ProcessResult, _cx: WindowCx?)
			local first = if res.status == 0 then string.match(str(res.stdout) or "", "^[^\n]*") else nil
			local version = if first ~= nil then trim(first) else ""
			cb(if version ~= "" then version else nil)
		end)
	end)
	if not ok then
		cb(nil)
	end
	return ok, err
end

return M
