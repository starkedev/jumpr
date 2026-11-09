--!strict
-- The window's diagnostics dump.
-- "Jumpr: diagnostics" writes `tern.plugin.data/diag-window-<ms>.json` at once, then asks the block in view for its
-- own dump with `act = "diag"`. When the host answers with `jumpr://diag` (through the router), one text naming both
-- dumps is copied; with no answer within 10 s the window's path alone is copied and "host dump unavailable" is shown.
-- It also keeps the window's last 50 errors, fed by every lib/window module, so the dump never depends on the
-- status route. The other modules register what they hold with `provide`, so this file requires none of them.

local compat = require("../compat")
local protocol = require("../shared/protocol")

local M = {}

local MAX_ERRORS = 50
local HOST_WAIT_MS = 10000

export type ErrorNote = { t: number, where: string, text: string }

-- A dump written and waiting for the host's answer.
type Pending = { token: number, window_path: string, timer: TimerHandle? }

local errors: { ErrorNote } = {}
local providers: { [string]: () -> any } = {}
local version: string? = nil
local version_asked = false
local pending: Pending? = nil
local tokens = 0
local writes = 0

-- Records an error in the ring (last 50) and in Tern's log.
function M.error(where: string, text: string)
	table.insert(errors, { t = os.time(), where = where, text = text })
	while #errors > MAX_ERRORS do
		table.remove(errors, 1)
	end
	tern.log.warn("jumpr: " .. where .. ": " .. text)
end

-- A copy of the error ring, oldest first.
function M.errors(): { ErrorNote }
	return table.clone(errors)
end

-- Registers what a module puts in the dump under `name`; `fn` returns JSON-safe values.
function M.provide(name: string, fn: () -> any)
	providers[name] = fn
end

-- Asks Tern for its version once (an async process), so later dumps carry it.
function M.start()
	if version_asked then
		return
	end
	version_asked = true
	local _, err = compat.process_run_version(function(v: string?)
		version = v
	end)
	if err ~= nil then
		M.error("diag", "tern --version: " .. err)
	end
end

-- The name of the machine this window runs on, as cx.hosts:list() reports it (the router names it in a version
-- toast too).
function M.local_name(cx: WindowCx): string
	local hosts = compat.hosts_list(cx)
	if hosts ~= nil then
		for _, h in hosts do
			if h.kind == "local" then
				return h.name
			end
		end
	end
	return "this machine"
end

local function null_or<T>(v: T?): any
	if v == nil then
		return tern.json.null
	end
	return v
end

local function finish(cx: WindowCx, text: string)
	local p = pending
	if p ~= nil and p.timer ~= nil then
		p.timer:cancel()
	end
	pending = nil
	local ok, err = compat.copy(cx, text)
	if not ok then
		M.error("diag", "copy: " .. tostring(err))
	end
end

-- Copies the window's path alone and says the host's dump is not coming.
local function finish_alone(cx: WindowCx, window_path: string)
	finish(cx, M.local_name(cx) .. ":" .. window_path)
	compat.toast(cx, "error", "host dump unavailable", "copied " .. window_path)
end

-- Writes the window dump now and starts the 10 s wait for the host's. Returns the dump's path, or nil when it
-- could not be written (a toast says so).
function M.write(cx: WindowCx): string?
	writes += 1
	local ms = os.time() * 1000 + writes % 1000
	local path = tern.plugin.data .. "/diag-window-" .. string.format("%d", ms) .. ".json"
	local hosts, hosts_err = compat.hosts_list(cx)
	local dump: { [string]: any } = {
		t = os.time(),
		version = null_or(version),
		protocol = protocol.P,
		hosts = if hosts ~= nil then hosts else { error = tostring(hosts_err) },
		errors = M.errors(),
	}
	for name, fn in providers do
		local ok, v = pcall(fn)
		dump[name] = if ok then v else { error = tostring(v) }
	end
	local ok, err = compat.fs_write(path, tern.json.encode(dump, true))
	if not ok then
		M.error("diag", "write " .. path .. ": " .. tostring(err))
		compat.toast(cx, "error", "Jumpr could not write diagnostics on " .. M.local_name(cx), err)
		return nil
	end
	local old = pending
	if old ~= nil and old.timer ~= nil then
		old.timer:cancel()
	end
	tokens += 1
	local token = tokens
	local p: Pending = { token = token, window_path = path, timer = nil }
	pending = p
	p.timer = tern.timer(HOST_WAIT_MS, function(tcx: WindowCx?)
		local now = pending
		if now == nil or now.token ~= token then
			return
		end
		if tcx == nil then
			pending = nil
			M.error("diag", "host dump wait ended with no window")
			return
		end
		finish_alone(tcx, now.window_path)
	end)
	return path
end

-- Asks the deck block `pane` (on `host`) for its dump. With no block in view the wait ends at once.
function M.ask_host(cx: WindowCx, pane: number?, host: string?)
	local p = pending
	if p == nil then
		return
	end
	if pane == nil then
		finish_alone(cx, p.window_path)
		return
	end
	local value = tern.json.encode({ p = protocol.P })
	local ok, err = compat.session_event(cx, pane, { ev = "action", act = "diag", value = value })
	if not ok then
		M.error("diag", "diag request to " .. tostring(host) .. ": " .. tostring(err))
		finish_alone(cx, p.window_path)
	end
end

-- Whether this window asked a host for its dump and is still waiting: a host's `jumpr://diag` reaches every window
-- attached to it, and only the one that asked copies the text.
function M.asking(): boolean
	return pending ~= nil
end

-- The host wrote its dump at `path` on `host` (a `jumpr://diag` answering this window's ask): copy one text naming
-- both dumps.
function M.host_dump_arrived(cx: WindowCx, host: string, path: string)
	local p = pending
	if p == nil then
		return
	end
	local text = host .. ":" .. path .. "\n" .. M.local_name(cx) .. ":" .. p.window_path
	finish(cx, text)
	compat.toast(cx, "success", "Jumpr diagnostics copied", text)
end

return M
