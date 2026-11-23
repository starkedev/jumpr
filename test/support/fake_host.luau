--!strict
-- An in-memory machine for the host half's tests: the second adapter behind the list's `compat` (lib/host/runtime.luau).
-- It holds the host's pane list, its kv, the folders that exist, the files it can list and read, the grep answers a
-- session lookup gets, the text typed into panes, the URLs each copy opened, the renders, and a clock and timers a
-- test steps. JSON is a table of values by token, so a test can send a copy a message the way the window does and
-- read back what the list decoded. A session file is planted the same way: its body is a token from `json`.

local compat = require("../../lib/compat")
local Runtime = require("../../lib/host/runtime")
local Store = require("../../lib/host/store")

local M = {}

-- Wall-clock ms at fake time 0.
local WALL_BASE = 1800000000000

-- A copy's block: its pane, working folder and width, and what the list did to it.
export type Block = {
	pane: number,
	cwd: string?,
	cols: number,
	opened: { string },
	renders: number,
	focus: { string },
	reveals: { string },
}

type Timer = { due: number, order: number, fn: () -> (), cancelled: boolean }

export type Machine = {
	-- The fake, as the list's `compat`.
	compat: Runtime.Io,
	-- The host's panes (`pane_list`), by id.
	panes: { [number]: boolean },
	-- What reading the pane list costs: how many times it was read.
	pane_reads: number,
	-- kv, and whether a write fails.
	kv: { [string]: any },
	kv_fails: boolean,
	kv_writes: number,
	-- When set, a kv write raises this error inside the call, as Tern's kv does, and compat's wrapper turns it into
	-- the failure the list sees.
	kv_raises: string?,
	-- The folders that exist on this machine. A folder lists under its parent, and `fs_remove` removes it as Tern's
	-- does (whole), so a test sees a folder that was removed.
	dirs: { [string]: boolean },
	-- The text typed into each pane, in order, and whether typing fails.
	typed: { { pane: number, text: string } },
	write_fails: boolean,
	files: { [string]: string },
	-- The user's home, when the test has set one. Nil until then.
	home: string?,
	-- How many times the list asked for home.
	home_reads: number,
	-- Exit status a quiet grep of `/proc/<pid>/environ` should report. A missing pid answers 1.
	grep: { [string]: number },
	-- Argument vectors `run_status` was given, in order.
	probes: { { string } },
	-- Argument vectors `run_output` was given, in order, each with `answer`, which the test calls with the stdout the
	-- process printed (nil: it failed). Nothing answers until the test does.
	outputs: { { argv: { string }, answer: (stdout: string?) -> () } },
	-- Directories `fs_list` was asked for, in order; the spool's own folders (`/data/requests`, `/data/replies`) go to
	-- `spool_lists` instead, so the lookups' listings are counted alone.
	lists: { string },
	spool_lists: { string },
	-- Files (or folders) written with `fs_write`, and removed with `fs_remove`, in order.
	file_writes: { string },
	removed: { string },
	-- Paths `is_dir` was asked about, in order, so a test can see a normal request never lists its own file.
	dir_checks: { string },
	-- A planted read error: `fs_read` of that path answers nil and the error, as compat does when Tern raises.
	read_errors: { [string]: string },
	-- Whether `fs_remove` fails (the file stays), for every path or for one path with its planted error.
	remove_fails: boolean,
	remove_errors: { [string]: string },
	logs: { string },
	now: number,
	-- Encodes a value as the JSON a window would send.
	json: (value: any) -> string,
	-- Moves the clock on by `ms`, running the timers that fall due on the way, in due order.
	advance: (ms: number) -> (),
}

-- A new machine whose kv holds `deck` (none: an empty kv).
function M.machine(deck: Store.Deck?): Machine
	local timers: { Timer } = {}
	local order = 0
	local json_values: { [string]: any } = {}
	local json_count = 0
	local m: Machine
	local function encode(value: any, _pretty: boolean?): string
		json_count += 1
		local token = "json#" .. tostring(json_count)
		json_values[token] = value
		return token
	end
	local function block(cx: BlockCx): Block
		local b: any = cx
		return b
	end
	local function names_under(path: string): { string }
		local prefix = if string.sub(path, -1) == "/" then path else path .. "/"
		local names: { string } = {}
		local function add(entry: string)
			if string.sub(entry, 1, #prefix) == prefix then
				local rest = string.sub(entry, #prefix + 1)
				if rest ~= "" and string.find(rest, "/", 1, true) == nil and table.find(names, rest) == nil then
					table.insert(names, rest)
				end
			end
		end
		for file_path in m.files do
			add(file_path)
		end
		for dir_path, there in m.dirs do
			if there then
				add(dir_path)
			end
		end
		table.sort(names)
		return names
	end
	local fake: Runtime.Io = {
		pane_list = function(): ({ any }?, string?)
			m.pane_reads += 1
			local out = {}
			for pane in m.panes do
				table.insert(out, { pane = pane, title = "omp" })
			end
			return out, nil
		end,
		pane_write = function(pane: number, text: string): (boolean, string?)
			if m.write_fails or not m.panes[pane] then
				return false, "pane " .. tostring(pane) .. " is gone"
			end
			table.insert(m.typed, { pane = pane, text = text })
			return true, nil
		end,
		open = function(cx: BlockCx, url: string): (boolean, string?)
			table.insert(block(cx).opened, url)
			return true, nil
		end,
		render = function(cx: BlockCx): (boolean, string?)
			local b = block(cx)
			b.renders += 1
			return true, nil
		end,
		focus_field = function(cx: BlockCx, id: string?): (boolean, string?)
			table.insert(block(cx).focus, id or "none")
			return true, nil
		end,
		reveal = function(cx: BlockCx, id: string): (boolean, string?)
			table.insert(block(cx).reveals, id)
			return true, nil
		end,
		cwd_of = function(cx: BlockCx): (string?, string?)
			return block(cx).cwd, nil
		end,
		cols = function(cx: BlockCx): (number?, string?)
			return block(cx).cols, nil
		end,
		pane_of = function(cx: BlockCx): (number?, string?)
			return block(cx).pane, nil
		end,
		is_dir = function(path: string): (boolean, string?)
			table.insert(m.dir_checks, path)
			return m.dirs[path] == true, nil
		end,
		git_common_dir = function(_folder: string, cb: (string?) -> ()): (boolean, string?)
			-- The process answers later, as `tern.process.run` does: no folder is in a repository here.
			m.compat.timer(0, function()
				cb(nil)
			end)
			return true, nil
		end,
		fs_write = function(path: string, text: string): (boolean, string?)
			table.insert(m.file_writes, path)
			m.files[path] = text
			return true, nil
		end,
		fs_list = function(path: string): ({ string }?, string?)
			if string.find(path, "^/data/requests/?$") ~= nil or string.find(path, "^/data/replies/?$") ~= nil then
				table.insert(m.spool_lists, path)
			else
				table.insert(m.lists, path)
			end
			local names = names_under(path)
			if #names == 0 and m.dirs[path] ~= true then
				return nil, nil
			end
			return names, nil
		end,
		fs_exists = function(path: string): (boolean, string?)
			return m.files[path] ~= nil or m.dirs[path] == true, nil
		end,
		fs_remove = function(path: string): (boolean, string?)
			if m.remove_fails then
				return false, "Permission denied (os error 13)"
			end
			local planted = m.remove_errors[path]
			if planted ~= nil then
				return false, planted
			end
			if m.dirs[path] == true then
				m.dirs[path] = nil
			elseif m.files[path] ~= nil then
				m.files[path] = nil
			else
				return false, "not found: " .. path
			end
			table.insert(m.removed, path)
			return true, nil
		end,
		fs_read = function(path: string, max_bytes: number?): (string?, string?)
			if string.find(path, "/environ", 1, true) ~= nil or string.match(path, "%.key$") ~= nil then
				error("refusing to read " .. path)
			end
			local planted = m.read_errors[path]
			if planted ~= nil then
				return nil, planted
			end
			local text = m.files[path]
			if text == nil then
				-- Tern's bounded read requires a regular file and raises on a directory, so a folder is a failed
				-- read rather than a missing file. The spool tells the two apart with `is_dir` only then.
				if m.dirs[path] == true then
					return nil, "Is a directory (os error 21)"
				end
				return nil, nil
			end
			-- Tern refuses a file past `max_bytes` rather than cutting it short.
			if max_bytes ~= nil and #text > max_bytes then
				return nil, "file is larger than " .. tostring(max_bytes) .. " bytes"
			end
			return text, nil
		end,
		run_status = function(argv: { string }, cb: (status: number?) -> ()): (boolean, string?)
			table.insert(m.probes, table.clone(argv))
			local proc = argv[6]
			local pid = if type(proc) == "string" then string.match(proc, "^/proc/(%d+)/environ$") else nil
			local status = if pid ~= nil then m.grep[pid] else nil
			cb(if status == nil then 1 else status)
			return true, nil
		end,
		run_output = function(argv: { string }, cb: (stdout: string?) -> ()): (boolean, string?)
			table.insert(m.outputs, { argv = table.clone(argv), answer = cb })
			return true, nil
		end,
		home = function(): string?
			m.home_reads += 1
			return m.home
		end,
		kv_get = function(key: string): (any, string?)
			return m.kv[key], nil
		end,
		kv_set = function(key: string, value: any): (boolean, string?)
			local raises = m.kv_raises
			if raises ~= nil then
				return compat.attempt(function()
					error(raises, 0)
				end)
			end
			if m.kv_fails then
				return false, "kv is read-only"
			end
			m.kv_writes += 1
			m.kv[key] = value
			return true, nil
		end,
		now = function(): number
			return m.now
		end,
		wall_ms = function(): number
			local clock = m.now
			return WALL_BASE + (if type(clock) == "number" then math.floor(clock) else 0)
		end,
		timer = function(ms: number, fn: (cx: WindowCx?) -> ()): TimerHandle
			order += 1
			local t: Timer = {
				due = m.now + ms,
				order = order,
				fn = function()
					fn(nil)
				end,
				cancelled = false,
			}
			table.insert(timers, t)
			local handle: any = {
				cancel = function(_self: any)
					t.cancelled = true
				end,
			}
			return handle
		end,
		log_warn = function(text: string)
			table.insert(m.logs, text)
		end,
		data_dir = function(): string
			return "/data"
		end,
		json_encode = encode,
		json_decode = function(text: string): (any, string?)
			local value = json_values[text]
			if value == nil then
				return nil, "not JSON"
			end
			return value, nil
		end,
	}
	m = {
		compat = fake,
		panes = {},
		pane_reads = 0,
		kv = {},
		kv_fails = false,
		kv_writes = 0,
		kv_raises = nil,
		dirs = {},
		typed = {},
		write_fails = false,
		files = {},
		home = nil,
		home_reads = 0,
		grep = {},
		probes = {},
		outputs = {},
		lists = {},
		spool_lists = {},
		file_writes = {},
		removed = {},
		dir_checks = {},
		read_errors = {},
		remove_fails = false,
		remove_errors = {},
		logs = {},
		now = 0,
		json = function(value: any): string
			return encode(value)
		end,
		advance = function(ms: number)
			local target = m.now + ms
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
				m.now = math.max(m.now, best.due)
				if not best.cancelled then
					best.fn()
				end
			end
			m.now = target
		end,
	}
	if deck ~= nil then
		m.kv[Store.KEY] = deck
	end
	return m
end

-- A copy's block in pane `pane`.
function M.block(pane: number): (BlockCx, Block)
	local b: Block = { pane = pane, cwd = "/work", cols = 60, opened = {}, renders = 0, focus = {}, reveals = {} }
	local cx: any = b
	return cx, b
end

-- Wall-clock ms at fake time `now`.
function M.wall(now: number): number
	return WALL_BASE + math.floor(now)
end

return M
