--!strict
-- An in-memory machine for the host half's tests: the second adapter behind the list's `compat` (lib/host/runtime.luau).
-- It holds the host's pane list, its kv, the folders that exist, the text typed into panes, the URLs each copy opened,
-- the renders, and a clock and timers a test steps. JSON is a table of values by token, so a test can send a copy a
-- message the way the window does and read back what the list decoded.

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
	-- When set, a kv write raises this error inside the call, as Tern's kv does, and compat's wrapper turns it into
	-- the failure the list sees.
	kv_raises: string?,
	-- The folders that exist on this machine.
	dirs: { [string]: boolean },
	-- The text typed into each pane, in order, and whether typing fails.
	typed: { { pane: number, text: string } },
	write_fails: boolean,
	files: { [string]: string },
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
			m.files[path] = text
			return true, nil
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
			m.kv[key] = value
			return true, nil
		end,
		now = function(): number
			return m.now
		end,
		wall_ms = function(): number
			return WALL_BASE + math.floor(m.now)
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
		kv_raises = nil,
		dirs = {},
		typed = {},
		write_fails = false,
		files = {},
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
