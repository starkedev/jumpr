--!strict
-- The leader lock and the window settings file. `tern.plugin.data/window.json` holds
-- `{leader = {uid, hb_ms}, hidden, esc_mode, deck_sessions}`, read and written through compat.fs_read/fs_write; the
-- window never touches tern.kv (the host half owns it). A window takes the lock on any focus event it sees, so the
-- leader is the window in front; the leader rewrites hb_ms every 2 s, and another window takes over once hb_ms is
-- more than 5 s old. Only the leader handles jumpr:// requests and creates blocks; every window pushes status.
-- If window.json cannot be written, this window acts as leader on its own (one window per deck session).

local compat = require("../compat")
local identity = require("../shared/identity")
local diag = require("./diag")

local M = {}

local HEARTBEAT_MS = 2000
local STALE_MS = 5000
local MAX_BYTES = 65536

export type Lock = { uid: string, hb_ms: number }
export type Settings = {
	leader: Lock?,
	hidden: boolean,
	esc_mode: string,
	-- Host name -> the name of its deck session, as last seen holding copies (hiding the list closes every copy,
	-- so this is how the window still knows the session while it is hidden).
	deck_sessions: { [string]: string },
}

-- A new random id each time the window's plugin VM starts, so a restarted window's seq is never read as old.
math.randomseed(os.time() + math.floor((tern.now() % 1000) * 1000))
local function rand(n: number): number
	return math.random(n)
end
local window_uid = identity.new_id(rand) .. identity.new_id(rand)

local state: Settings = { leader = nil, hidden = false, esc_mode = "A", deck_sessions = {} }
local fs_ok = true
local started = false

local function path(): string
	return tern.plugin.data .. "/window.json"
end

-- Wall clock in ms: every window on this machine compares it, so it cannot be tern.now() (per process).
local function wall_ms(): number
	return os.time() * 1000
end

local function normalise(raw: any): Settings
	local s: Settings = { leader = nil, hidden = false, esc_mode = "A", deck_sessions = {} }
	if type(raw) ~= "table" then
		return s
	end
	local l = raw.leader
	if type(l) == "table" and type(l.uid) == "string" and type(l.hb_ms) == "number" then
		s.leader = { uid = l.uid, hb_ms = l.hb_ms }
	end
	s.hidden = raw.hidden == true
	local sessions: { [string]: string } = {}
	if type(raw.deck_sessions) == "table" then
		for host, name in raw.deck_sessions do
			if type(host) == "string" and type(name) == "string" and name ~= "" then
				sessions[host] = name
			end
		end
	end
	s.deck_sessions = sessions
	s.esc_mode = if raw.esc_mode == "B" then "B" else "A"
	return s
end

local function read(): Settings
	local text, err = compat.fs_read(path(), MAX_BYTES)
	if err ~= nil then
		diag.error("leader", "read window.json: " .. err)
	end
	if text == nil then
		return normalise(nil)
	end
	local ok, raw = pcall(tern.json.decode, text)
	if not ok then
		diag.error("leader", "window.json is not JSON: " .. tostring(raw))
		return normalise(nil)
	end
	return normalise(raw)
end

local function write(s: Settings)
	local l = s.leader
	local out = {
		leader = if l ~= nil then { uid = l.uid, hb_ms = l.hb_ms } else tern.json.null,
		hidden = s.hidden,
		deck_sessions = s.deck_sessions,
		esc_mode = s.esc_mode,
	}
	local ok, err = compat.fs_write(path(), tern.json.encode(out, true))
	if not ok then
		if fs_ok then
			diag.error("leader", "write window.json: " .. tostring(err) .. " (acting as leader alone)")
		end
		fs_ok = false
	end
	state = s
end

-- This window's uid (the status messages' `w`).
function M.uid(): string
	return window_uid
end

-- Takes the lock now: this window saw focus, so it is the one in front.
function M.take()
	local s = read()
	s.leader = { uid = window_uid, hb_ms = wall_ms() }
	write(s)
end

-- The 2 s beat: the leader rewrites hb_ms; any window takes a lock that is missing or more than 5 s old.
-- `timer_runs` counts the chain's armings (one more than the callbacks that ran) and `ticks` the ticks they ran,
-- so a chain that never started or died shows in diagnostics as counts that stay 0 or stop moving.
M.timer_runs = 0
M.ticks = 0
M.last_tick_ms = 0

function M.tick()
	M.ticks += 1
	M.last_tick_ms = wall_ms()
	local s = read()
	local l = s.leader
	if l == nil or l.uid == window_uid or wall_ms() - l.hb_ms > STALE_MS then
		s.leader = { uid = window_uid, hb_ms = wall_ms() }
		write(s)
	else
		state = s
	end
end

-- Reads the file, takes a free or stale lock, and starts the heartbeat (once per VM; startup.ensure calls it).
function M.start()
	if started then
		return
	end
	started = true
	M.tick()
	local function beat()
		M.timer_runs += 1
		tern.timer(HEARTBEAT_MS, function(_tcx: WindowCx?)
			beat()
			M.tick()
		end)
	end
	beat()
end

-- Whether this window is the leader, read fresh from window.json (another window may have taken it on focus).
function M.is_leader(): boolean
	if not fs_ok then
		return true
	end
	state = read()
	local l = state.leader
	return l ~= nil and l.uid == window_uid
end

-- The Esc mode sent to blocks as `em`: "A" (default) or "B".
function M.esc_mode(): string
	return state.esc_mode
end

function M.hidden(): boolean
	return state.hidden
end

-- Whether this window held the lock when the file was last read or written (cheap: no file read), for the
-- pusher's once-a-second scan; `is_leader` is the fresh answer.
function M.leading(): boolean
	if not fs_ok then
		return true
	end
	local l = state.leader
	return l ~= nil and l.uid == window_uid
end

-- The name of `host`'s deck session as last recorded, nil when none is.
function M.deck_session(host: string): string?
	return state.deck_sessions[host]
end

function M.set_hidden(hidden: boolean)
	local s = read()
	s.hidden = hidden
	write(s)
end

-- Records `host`'s deck session (leader only; the file is written only when the name changes), or forgets it with nil.
function M.set_deck_session(host: string, name: string?)
	local s = read()
	if s.deck_sessions[host] == name then
		state = s
		return
	end
	local map: { [string]: string? } = s.deck_sessions :: any
	map[host] = name
	write(s)
end

diag.provide("leader", function(): any
	local l = state.leader
	return {
		uid = window_uid,
		leader = if l ~= nil then { uid = l.uid, hb_ms = l.hb_ms } else tern.json.null,
		timer_runs = M.timer_runs,
		ticks = M.ticks,
		last_tick_ms = M.last_tick_ms,
		is_leader = not fs_ok or (l ~= nil and l.uid == window_uid),
		file_ok = fs_ok,
		hidden = state.hidden,
		deck_sessions = state.deck_sessions,
		esc_mode = state.esc_mode,
	}
end)

return M
