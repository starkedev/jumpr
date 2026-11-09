--!strict
-- The status pusher. It finds the `jumpr.list` blocks (the copies of the list, one per tab
-- of a machine's deck session) per host, keeps the map of host -> copies and tab -> copy that the router and
-- `copies` read, and sends each copy `act = "st"` messages through compat.session_event: diffs of changed deck ids
-- (a gone id is an empty list) coalesced on a 250 ms timer (at most 4 per second per copy), an empty diff as a 1 s
-- heartbeat, and a full snapshot on the window half's start (startup.ensure), budget resumed, hello and every 30 s.
-- A copy this window has not sent to yet (created or first seen after the start) gets its first snapshot on first
-- contact. Every window pushes; the block keeps the newest message per window uid.
-- The scan also finds two copies in one tab (`dupb`), records the session holding each host's copies in the
-- window file (leader only), and rebuilds the tab -> agent title map the tab-title formatter reads. `follow` sends the
-- copies one focus message (`act = "fo"`) when the last-tab chord lands on an agent, so the list highlights it.

local compat = require("../compat")
local harness = require("../harness")
local protocol = require("../shared/protocol")
local status = require("../shared/status")
local agents = require("./agents")
local leader = require("./leader")
local diag = require("./diag")

local M = {}

local BLOCK_KIND = protocol.BLOCK_KIND
local COALESCE_MS = 250
local HEARTBEAT_MS = 1000
-- A heartbeat goes to a copy that got nothing for this long, so beats and changes stay at most 4 per second.
local QUIET_MS = 750
local FULL_EVERY_BEATS = 30

-- One copy of the list the window sees, and the tab holding it.
type Block = { pane: number, host: string, session: string?, tab: number? }

-- The host fields the scan joins a block to.
type HostRef = { name: string, sessions: { number } }
type Sent = { sigs: { [string]: string }, last: { [string]: { status.Entry } }, at: number }

local blocks_by_host: { [string]: { number } } = {}
local block_of: { [number]: Block } = {}
-- The copies in each tab (more than one is a duplicate), lowest pane first.
local copies_by_tab: { [number]: { number } } = {}
-- The title of the agent pane in each tab that holds a copy, for the tab-title formatter.
local agent_titles: { [number]: string } = {}
-- The tabs holding a copy that also hold a pane that is not a copy (a copy alone in its tab is not in it).
local accompanied: { [number]: boolean } = {}
local host_state: { [string]: string } = {}
local sent: { [number]: Sent } = {}
-- The last `seq` sent per copy pane, never dropped: a copy that drops out of one scan keeps counting on, since
-- the block remembers this window's last seq (a renumbered pane's restart is read as such from its full
-- message).
local seqs: { [number]: number } = {}
local dirty = false
local coalescing = false
local started = false
local beats = 0
-- Timer diagnostics: `fires` counts the chain's armings (one more than the callbacks that ran),
-- `nil_tcx` callbacks that ran without a window context, so a chain that never started or died shows as counts that
-- stay 0 or stop moving.
local fires = 0
local nil_tcx = 0
local last_beat_ms = 0

-- The last scan error logged per source ("scan", "sessions"), and the block panes already logged as having no
-- host: the 1 s beat re-scans, so a failure that persists logs once, and again only when its text changes.
local scan_logged: { [string]: string? } = {}
local no_host_logged: { [number]: boolean } = {}

local function pane_key(pane: number): string
	return string.format("%.0f", pane)
end

local function log_scan(source: string, text: string)
	if scan_logged[source] ~= text then
		scan_logged[source] = text
		diag.error("pusher", text)
	end
end

-- Whether two title maps hold the same titles.
local function same_titles(a: { [number]: string }, b: { [number]: string }): boolean
	for tab, title in a do
		if b[tab] ~= title then
			return false
		end
	end
	for tab in b do
		if a[tab] == nil then
			return false
		end
	end
	return true
end

-- Finds the copies: their host (hosts_list .panes), their session and tab (the session holding the copy's tab; for
-- a parked copy, the host's only session when it has one). `read_hosts` and `read_panes` are the caller's read when
-- it already made one, else they are read here.
function M.scan(cx: WindowCx, read_hosts: { ManagedHost }?, read_panes: { compat.PaneItem }?): boolean
	local hosts, hosts_err = read_hosts, nil
	if hosts == nil then
		hosts, hosts_err = compat.hosts_list(cx)
	end
	local panes, panes_err = read_panes, nil
	if panes == nil then
		panes, panes_err = compat.session_panes(cx)
	end
	if hosts == nil or panes == nil then
		log_scan("scan", "scan: " .. tostring(hosts_err or panes_err))
		return false
	end
	scan_logged.scan = nil
	local tabs, tabs_err = compat.session_tabs(cx)
	if tabs == nil then
		log_scan("sessions", "scan sessions: " .. tostring(tabs_err))
	else
		scan_logged.sessions = nil
	end
	local session_of_tab: { [number]: string } = {}
	local session_name: { [number]: string } = {}
	local tab_list: { SessionInfo } = tabs or {}
	for _, s in tab_list do
		session_name[s.id] = s.name
		for _, t in s.tabs do
			session_of_tab[t] = s.name
		end
	end
	local host_of: { [number]: HostRef } = {}
	local new_state: { [string]: string } = {}
	for _, h in hosts do
		new_state[h.name] = h.state
		for _, p in h.panes do
			host_of[p] = { name = h.name, sessions = h.sessions }
		end
	end
	local by_host: { [string]: { number } } = {}
	local by_pane: { [number]: Block } = {}
	local by_tab: { [number]: { number } } = {}
	local no_host: { [number]: boolean } = {}
	for _, p in panes do
		if p.block == BLOCK_KIND then
			local h = host_of[p.pane]
			if h == nil then
				no_host[p.pane] = true
				if not no_host_logged[p.pane] then
					diag.error("pusher", "deck block " .. pane_key(p.pane) .. " has no host")
				end
			else
				local session: string? = nil
				if p.tab ~= nil then
					session = session_of_tab[p.tab]
				end
				if session == nil and #h.sessions == 1 then
					session = session_name[h.sessions[1]]
				end
				by_pane[p.pane] = { pane = p.pane, host = h.name, session = session, tab = p.tab }
				local list = by_host[h.name]
				if list == nil then
					list = {}
					by_host[h.name] = list
				end
				table.insert(list, p.pane)
				if p.tab ~= nil then
					local in_tab = by_tab[p.tab]
					if in_tab == nil then
						in_tab = {}
						by_tab[p.tab] = in_tab
					end
					table.insert(in_tab, p.pane)
				end
			end
		end
	end
	no_host_logged = no_host
	for _, list in by_host do
		table.sort(list)
	end
	for _, list in by_tab do
		table.sort(list)
	end
	-- The agent pane's title per tab holding a copy: the deck agent bound in the tab, else the tab's lowest pane
	-- that is not a copy.
	local titles: { [number]: string } = {}
	local chosen: { [number]: { pane: number, agent: boolean } } = {}
	for _, p in panes do
		local tab = p.tab
		if tab ~= nil and by_tab[tab] ~= nil and p.block ~= BLOCK_KIND then
			local is_agent = agents.is_agent(p.pane)
			local have = chosen[tab]
			if have == nil or (is_agent and not have.agent) or (is_agent == have.agent and p.pane < have.pane) then
				chosen[tab] = { pane = p.pane, agent = is_agent }
				local title = harness.clean_title(p.title)
				if title ~= nil then
					titles[tab] = title
				else
					titles[tab] = nil
				end
			end
		end
	end
	for pane in sent do
		if by_pane[pane] == nil then
			sent[pane] = nil
		end
	end
	local titles_changed = not same_titles(agent_titles, titles)
	blocks_by_host, block_of, copies_by_tab, host_state = by_host, by_pane, by_tab, new_state
	agent_titles = titles
	accompanied = {}
	for tab in chosen do
		accompanied[tab] = true
	end
	-- The leader records the session holding each host's copies (the file is written only when a name changes).
	if leader.leading() then
		for host, list in by_host do
			local b = by_pane[list[1]]
			if b ~= nil and b.session ~= nil and leader.deck_session(host) ~= b.session then
				leader.set_deck_session(host, b.session)
			end
		end
	end
	if titles_changed then
		local ok, err = compat.chrome_refresh()
		if not ok then
			log_scan("chrome", "tab titles: " .. tostring(err))
		end
	end
	return true
end

-- The binding and the copy map from one read of hosts and panes, so pane_created, pane_closed, budget resumed and
-- the 30 s resync each read the pane list once, to keep events cheap; window_start runs it too, through start. false when the read
-- failed.
function M.rebuild(cx: WindowCx): boolean
	local hosts, hosts_err = compat.hosts_list(cx)
	local panes, panes_err = compat.session_panes(cx)
	if hosts == nil or panes == nil then
		diag.error("agents", "rebuild: " .. tostring(hosts_err or panes_err))
		log_scan("scan", "scan: " .. tostring(hosts_err or panes_err))
		return false
	end
	agents.rebuild(cx, hosts, panes)
	return M.scan(cx, hosts, panes)
end

-- A stable text for one id's entries, to tell a changed id from an unchanged one.
local function signature(list: { status.Entry }): string
	local parts: { string } = {}
	for _, e in list do
		table.insert(
			parts,
			table.concat({
				e.s,
				if e.u then "u" else "",
				if e.f then "f" else "",
				e.e or "",
				e.src or "",
			}, "\31")
		)
	end
	return table.concat(parts, "\30")
end

-- Whether `pane` shares its tab with another copy of the list.
local function duplicate_in_tab(b: Block): boolean
	if b.tab == nil then
		return false
	end
	local in_tab = copies_by_tab[b.tab]
	return in_tab ~= nil and #in_tab > 1
end

-- Sends one status message to `pane`: the whole list when `full`, else the ids changed since the last send.
local function send(cx: WindowCx, pane: number, full: boolean): boolean
	local b = block_of[pane]
	if b == nil then
		return false
	end
	local entries = agents.entries(b.host)
	local s = sent[pane]
	-- First contact with this copy: a diff from nothing is the whole list, so it goes as a full snapshot.
	if s == nil then
		full = true
	end
	local last_sigs: { [string]: string } = if s ~= nil then s.sigs else {}
	local a: { [string]: any } = {}
	local sigs: { [string]: string } = {}
	for id, list in entries do
		local sig = signature(list)
		sigs[id] = sig
		if full or last_sigs[id] ~= sig then
			a[id] = list
		end
	end
	-- A gone id is an empty list: tern.json.decode drops null members, so JSON null would never arrive.
	if not full then
		for id in last_sigs do
			if sigs[id] == nil then
				a[id] = tern.json.array()
			end
		end
	end
	local seq = (seqs[pane] or 0) + 1
	local msg = protocol.status_msg(
		leader.uid(),
		seq,
		full,
		os.time() * 1000,
		host_state[b.host],
		b.session,
		b.host,
		duplicate_in_tab(b),
		leader.esc_mode(),
		a
	)
	local ok, err = compat.session_event(cx, pane, { ev = "action", act = "st", value = tern.json.encode(msg) })
	if not ok then
		diag.error("pusher", "status to the deck list on " .. b.host .. ": " .. tostring(err))
		return false
	end
	seqs[pane] = seq
	sent[pane] = { sigs = sigs, last = entries, at = tern.now() }
	return true
end

-- Sends to every copy: full snapshots, or diffs to the copies quiet for at least `quiet_ms`.
local function push_all(cx: WindowCx, full: boolean, quiet_ms: number)
	local now = tern.now()
	for pane in block_of do
		local s = sent[pane]
		if full or s == nil or now - s.at >= quiet_ms then
			send(cx, pane, full)
		end
	end
end

-- Re-arms itself until every copy has got the change, keeping 250 ms between messages to one copy.
local function coalesce(delay: number)
	coalescing = true
	tern.timer(delay, function(tcx: WindowCx?)
		coalescing = false
		if tcx == nil or not dirty then
			return
		end
		local now = tern.now()
		local wait = 0
		for pane in block_of do
			local s = sent[pane]
			if s ~= nil and now - s.at < COALESCE_MS then
				wait = math.max(wait, COALESCE_MS - (now - s.at))
			end
		end
		if wait > 0 then
			coalesce(wait)
			return
		end
		dirty = false
		push_all(tcx, false, 0)
	end)
end

-- Something changed: send the changed ids within 250 ms.
function M.mark_dirty()
	dirty = true
	if not coalescing then
		coalesce(COALESCE_MS)
	end
end

-- The binding rebuilt and a full snapshot to every copy (the start, budget resumed, the 30 s resync).
function M.full(cx: WindowCx)
	M.rebuild(cx)
	dirty = false
	push_all(cx, true, 0)
end

-- The 1 s beat: a re-scan, so h, sn, hn and dupb are current, then a heartbeat (an empty diff, or the pending
-- changes) to every copy quiet for 750 ms; every 30th beat sends a full snapshot, which rebuilds the binding. A
-- pending change stays the coalescer's to finish.
local function beat(cx: WindowCx)
	beats += 1
	last_beat_ms = tern.now()
	if beats % FULL_EVERY_BEATS == 0 then
		M.full(cx)
		return
	end
	M.scan(cx)
	push_all(cx, false, QUIET_MS)
end

-- Scans, sends full snapshots and starts the heartbeat (once per VM; startup.ensure calls it once).
function M.start(cx: WindowCx)
	M.full(cx)
	if started then
		return
	end
	started = true
	local function arm()
		fires += 1
		tern.timer(HEARTBEAT_MS, function(tcx: WindowCx?)
			arm()
			if tcx ~= nil then
				beat(tcx)
			else
				nil_tcx += 1
			end
		end)
	end
	arm()
end

-- `jumpr://hello`: a full snapshot to every copy on `host`. Returns how many got it.
function M.hello(cx: WindowCx, host: string): number
	M.scan(cx)
	local n = 0
	local panes: { number } = blocks_by_host[host] or {}
	for _, pane in panes do
		if send(cx, pane, true) then
			n += 1
		end
	end
	return n
end

-- The last-tab chord landed on deck agent pane `pane`: a focus message (`act = "fo"`, naming the agent by deck id) to
-- every copy of its host in this window, so the list highlights that agent. Nothing goes out for a pane that is no
-- deck agent or a host with no copy here (a hidden list). Status messages never carry focus, so the highlight moves
-- only on the chord and never fights a user moving in the list. Returns how many copies got it.
function M.follow(cx: WindowCx, pane: number): number
	local host, id = agents.agent_of(pane)
	if host == nil or id == nil then
		return 0
	end
	local value = tern.json.encode(protocol.focus_msg(leader.uid(), id))
	local n = 0
	local panes: { number } = blocks_by_host[host] or {}
	for _, copy in panes do
		local ok, err = compat.session_event(cx, copy, { ev = "action", act = protocol.FOCUS_ACT, value = value })
		if ok then
			n += 1
		else
			diag.error("pusher", "focus to the deck list on " .. host .. ": " .. tostring(err))
		end
	end
	return n
end

-- The copies on `host` (the replies go to all of them), lowest pane first.
function M.blocks_for(host: string): { number }
	return table.clone(blocks_by_host[host] or {})
end

-- The deck session of `host`: the session holding its (first) copy.
function M.session_of(host: string): string?
	local list = blocks_by_host[host]
	if list == nil or #list == 0 then
		return nil
	end
	local b = block_of[list[1]]
	return if b ~= nil then b.session else nil
end

-- The host whose copies sit in deck session `session`, from the last scan; nil when none does, or when two hosts
-- hold a session of that name (session names are only unique per host).
function M.host_with_session(session: string): string?
	local found: string? = nil
	for host in blocks_by_host do
		if M.session_of(host) == session then
			if found ~= nil then
				return nil
			end
			found = host
		end
	end
	return found
end

function M.is_block(pane: number): boolean
	return block_of[pane] ~= nil
end

-- The copy of the list in `tab` (the lowest when duplicated), from the last scan; nil when the tab has none.
function M.copy_in_tab(tab: number?): number?
	if tab == nil then
		return nil
	end
	local in_tab = copies_by_tab[tab]
	return if in_tab ~= nil then in_tab[1] else nil
end

-- Whether `tab` holds a pane other than its copies, from the last scan (a copy alone in its tab is not).
function M.accompanied(tab: number): boolean
	return accompanied[tab] == true
end

-- Every tab that holds a copy of the list, with its copies, from the last scan.
function M.copies_by_tab(): { [number]: { number } }
	local out: { [number]: { number } } = {}
	for tab, list in copies_by_tab do
		out[tab] = table.clone(list)
	end
	return out
end

-- The host and session of the copy `pane` (nil when it is not a copy in the last scan).
function M.block_info(pane: number): (string?, string?)
	local b = block_of[pane]
	if b == nil then
		return nil, nil
	end
	return b.host, b.session
end

-- The title the tab-title formatter shows for a tab whose focused pane is a copy: the agent's title in that tab,
-- nil when there is none (or the focused pane is not a copy). Only reads the map the scan rebuilt (4 ms budget).
function M.agent_title(tab: number, focused: number): string?
	if block_of[focused] == nil then
		return nil
	end
	return agent_titles[tab]
end

diag.provide("pusher", function(): any
	local out: { [string]: any } = { fires = fires, beats = beats, nil_tcx = nil_tcx, last_beat_ms = last_beat_ms }
	for pane, b in block_of do
		local s = sent[pane]
		out[pane_key(pane)] = {
			host = b.host,
			session = if b.session ~= nil then b.session else tern.json.null,
			tab = if b.tab ~= nil then pane_key(b.tab) else tern.json.null,
			seq = seqs[pane] or 0,
			last = if s ~= nil then s.last else {},
		}
	end
	local tabs: { [string]: { string } } = {}
	for tab, list in copies_by_tab do
		local keys: { string } = {}
		for _, pane in list do
			table.insert(keys, pane_key(pane))
		end
		tabs[pane_key(tab)] = keys
	end
	return { window = leader.uid(), blocks = out, copies_per_tab = tabs, host_state = host_state }
end)

return M
