--!strict
-- Pure module that turns the deck, the host's panes and the latest status into rows, plus the pure record
-- transitions (bind, failed start, exit, reconcile, group sweep). No `tern` here: everything comes in as
-- arguments. Functions that return a deck return the same table when nothing changed, so a caller can save only
-- when `new ~= old`.

local harness = require("../harness")
local status = require("../shared/status")
local store = require("./store")

local M = {}

-- One entry of the host's pane list (pane, cwd, program, title).
export type Pane = { pane: number, cwd: string?, program: string?, title: string? }
-- Live host panes per deck id.
export type PaneSets = { [string]: { [number]: true } }
-- The latest status entries per deck id (two or more = a duplicate).
export type StatusById = { [string]: { status.Entry } }
-- What `rows` reads from the block's UI state.
export type View = { search: string?, filter: string? }
-- kind "agent" with id (and the gid it was last seen in), or kind "header" with gid.
export type Selection = { kind: string, id: string?, gid: string? }

-- kind: "header" | "agent".
-- Both kinds: gid, label, code (agent: its status code; header: status.worst of its agents, nil when none ranks),
-- queued, dup, dim, depth (header 0, agent 1), live.
-- Header only: count (agents in the group), tally (how many of them have each status code), folded, deleting, stuck
-- (deleting while one of its agents is `live`).
-- Agent only: id, cwd, state, failed, cancel (a pending record that is being removed), src (the status entries'
-- sources, for the `i` overlay), asking (a status entry says `waiting_input`: typed text would answer it), hold
-- (why a held `q` message has not been sent; nil with none held).
export type Row = {
	kind: string,
	gid: string,
	id: string?,
	label: string,
	code: status.Code?,
	queued: boolean,
	dup: boolean,
	dim: boolean,
	depth: number,
	live: boolean,
	count: number?,
	tally: { [string]: number }?,
	folded: boolean?,
	deleting: boolean?,
	stuck: boolean?,
	cwd: string?,
	state: string?,
	failed: boolean?,
	cancel: boolean?,
	src: string?,
	asking: boolean?,
	hold: string?,
}

local STOP_WINDOW_MS = 60 * 1000
-- A pending start with no pane after this long is failed or, with `cancel` set, deleted.
M.NO_PANE_MS = 30 * 1000

local function set_size(set: { [number]: true }?): number
	local n = 0
	if set ~= nil then
		for _ in set do
			n += 1
		end
	end
	return n
end

-- Whether typed text can reach the agent: its record is `live` and a pane is bound. The one rule `rows` and the queue
-- sweep share.
function M.is_live(record: store.Record, set: { [number]: true }?): boolean
	return record.state == "live" and set_size(set) > 0
end

-- Whether two panes (or two status entries) claim one deck id: a duplicate, which the list flags and refuses to act on.
function M.is_dup(set: { [number]: true }?, entries: { status.Entry }?): boolean
	return set_size(set) >= 2 or (entries ~= nil and #entries >= 2)
end

-- Why a held `q` message waits, from the same inputs `queue.due` reads; nil with nothing held. `health` is the
-- machine's status health ("ok" | "stale" | "unavailable").
function M.hold(held: store.QueueEntry?, health: string, live: boolean, dup: boolean): string?
	if held == nil then
		return nil
	end
	if held.err ~= nil and held.err ~= "" then
		return "failed: " .. held.err
	end
	if dup then
		return "duplicate"
	end
	if not live then
		return "pane gone"
	end
	if health == "unavailable" then
		return "status unavailable"
	end
	if health == "stale" then
		return "status stale"
	end
	return "waiting for idle"
end

local function contains(haystack: string?, needle: string): boolean
	return haystack ~= nil and string.find(string.lower(haystack), needle, 1, true) ~= nil
end

-- The ids of a group's agents in display order (pos, then id so equal positions stay stable).
function M.group_ids(deck: store.Deck, gid: string): { string }
	local ids: { string } = {}
	for id, r in deck.agents do
		if r.gid == gid then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a: string, b: string): boolean
		local pa, pb = deck.agents[a].pos, deck.agents[b].pos
		if pa ~= pb then
			return pa < pb
		end
		return a < b
	end)
	return ids
end

-- The pane the row's default label reads its title from: the record's cached pane when it is in the set,
-- else the lowest pane in the set.
local function bound_pane(record: store.Record, set: { [number]: true }?): number?
	if set == nil then
		return nil
	end
	if record.pane ~= nil and set[record.pane] then
		return record.pane
	end
	local best: number? = nil
	for pane in set do
		if best == nil or pane < best then
			best = pane
		end
	end
	return best
end

-- One agent's status code: its entry's, or the worst of several (a duplicate).
local function agent_code(r: store.Record, entries: { status.Entry }, fresh: boolean): status.Code
	if #entries > 1 then
		local each: { status.Code } = {}
		for _, e in entries do
			table.insert(each, status.code(e, fresh, r))
		end
		return status.worst(each) or each[1]
	end
	return status.code(entries[1], fresh, r)
end

-- How many of `codes` are each code.
local function tally_of(codes: { status.Code }): { [string]: number }
	local out: { [string]: number } = {}
	for _, code in codes do
		out[code] = (out[code] or 0) + 1
	end
	return out
end

-- How many agents have each status code, over every agent on the deck (folded and filtered groups included): the
-- count tiles at the top of the list.
function M.tally(deck: store.Deck, status_by_id: StatusById, health: string): { [string]: number }
	local fresh = health == "ok"
	local codes: { status.Code } = {}
	for id, r in deck.agents do
		table.insert(codes, agent_code(r, status_by_id[id] or {}, fresh))
	end
	return tally_of(codes)
end

-- `health` is the machine's status health ("ok" | "stale" | "unavailable"): only "ok" makes entries fresh, and the
-- other two name the reason a held message waits.
function M.rows(
	deck: store.Deck,
	panes: { Pane },
	pane_sets: PaneSets,
	status_by_id: StatusById,
	ui: View,
	health: string
): { Row }
	local fresh = health == "ok"
	local titles: { [number]: string } = {}
	for _, p in panes do
		if p.title ~= nil then
			titles[p.pane] = p.title
		end
	end
	local search = if ui.search ~= nil and ui.search ~= "" then string.lower(ui.search) else nil
	local filter = ui.filter
	local active = filter ~= nil or search ~= nil
	local out: { Row } = {}
	for _, group in deck.groups do
		local agents: { Row } = {}
		local codes: { status.Code } = {}
		local shown: { Row } = {}
		local stuck = false
		for n, id in M.group_ids(deck, group.gid) do
			local r = deck.agents[id]
			local set = pane_sets[id]
			local entries: { status.Entry } = status_by_id[id] or {}
			local code = agent_code(r, entries, fresh)
			local srcs: { string } = {}
			for _, e in entries do
				if e.src ~= nil and e.src ~= "" then
					table.insert(srcs, e.src)
				end
			end
			local label: string
			if r.label ~= nil and r.label ~= "" then
				label = r.label
			else
				local pane = bound_pane(r, set)
				label = harness.clean_title(if pane ~= nil then titles[pane] else nil) or ("omp " .. n)
			end
			local live = M.is_live(r, set)
			local dup = M.is_dup(set, entries)
			local asking = false
			for _, e in entries do
				if e.s == "q" then
					asking = true
				end
			end
			if group.deleting == true and r.state == "live" then
				stuck = true
			end
			local row: Row = {
				kind = "agent",
				gid = group.gid,
				id = id,
				label = label,
				code = code,
				queued = deck.queue[id] ~= nil,
				dup = dup,
				dim = code == "stopped",
				depth = 1,
				live = live,
				cwd = r.cwd,
				state = r.state,
				failed = r.failed == true,
				cancel = r.cancel == true,
				src = if #srcs > 0 then table.concat(srcs, ", ") else nil,
				asking = asking,
				hold = M.hold(deck.queue[id], health, live, dup),
			}
			table.insert(agents, row)
			table.insert(codes, code)
			if
				status.matches(code, filter)
				and (
					search == nil
					or contains(label, search)
					or contains(r.cwd, search)
					or contains(group.name, search)
				)
			then
				table.insert(shown, row)
			end
		end

		local header_shown = not active
			or #shown > 0
			or (filter == nil and search ~= nil and contains(group.name, search))
		if header_shown then
			table.insert(out, {
				kind = "header",
				gid = group.gid,
				label = group.name,
				code = status.worst(codes),
				queued = false,
				dup = false,
				dim = false,
				depth = 0,
				live = false,
				count = #agents,
				tally = tally_of(codes),
				folded = group.folded,
				deleting = group.deleting == true,
				stuck = stuck,
			})
			if active or not group.folded then
				for _, row in shown do
					table.insert(out, row)
				end
			end
		end
	end
	return out
end

-- The index of the selected row, or nil when it is not in `rows`.
function M.index_of(rows: { Row }, sel: Selection?): number?
	if sel == nil then
		return nil
	end
	for i, row in rows do
		if row.kind == sel.kind and (if sel.kind == "agent" then row.id == sel.id else row.gid == sel.gid) then
			return i
		end
	end
	return nil
end

-- The selection a row stands for.
function M.select_row(row: Row): Selection
	if row.kind == "agent" then
		return { kind = "agent", id = row.id, gid = row.gid }
	end
	return { kind = "header", gid = row.gid }
end

-- Keeps the selection on the same deck id or group id across renders. An agent hidden by a fold (or a filter)
-- moves to its group's header when that is shown; anything else falls back to the first row (nil when none).
-- `deck` tells which group a hidden agent is in now.
function M.clamp_selection(rows: { Row }, sel: Selection?, deck: store.Deck): Selection?
	local i = M.index_of(rows, sel)
	if i ~= nil then
		return M.select_row(rows[i])
	end
	if sel ~= nil and sel.kind == "agent" and sel.id ~= nil then
		local r = deck.agents[sel.id]
		local gid = if r ~= nil then r.gid else sel.gid
		local h = M.index_of(rows, { kind = "header", gid = gid })
		if h ~= nil then
			return M.select_row(rows[h])
		end
	end
	if #rows == 0 then
		return nil
	end
	return M.select_row(rows[1])
end

-- A pane bound to the record (spawn or command_started matched its deck id). Pure: returns a new record and the
-- verdict. "stop": the record was pending with `cancel` (its group is being deleted); it is now `stopping` and the
-- caller must send `stop`. "live": nothing to send; the record is `live` (a `stopping` record stays `stopping`).
-- Binding caches `pane` and clears `failed`, `ended_ms` and `exit`; the caller also clears the
-- record's pending `start` request, whatever the reply route did.
function M.on_bind(record: store.Record, pane: number): (store.Record, string)
	local r = table.clone(record)
	r.pane = pane
	r.failed = nil
	r.ended_ms = nil
	r.exit = nil
	if r.state == "pending" and r.cancel == true then
		r.cancel = nil
		r.state = "stopping"
		return r, "stop"
	end
	if r.state ~= "stopping" then
		r.state = "live"
	end
	return r, "live"
end

-- A start that failed: reason "res" (error reply) or "no_reply" (10 s) sets `failed` and never deletes;
-- "no_pane" (30 s with no pane) deletes a `cancel` record and otherwise sets `failed`. Setting `failed` sets
-- `ended_ms = now_ms`. Acts only on a record still `pending`.
function M.start_failed(deck: store.Deck, id: string, reason: string, now_ms: number): store.Deck
	local r = deck.agents[id]
	if r == nil or r.state ~= "pending" then
		return deck
	end
	if reason == "no_pane" and r.cancel == true then
		local out = store.clone(deck)
		out.agents[id] = nil
		out.queue[id] = nil
		return out
	end
	if r.failed == true then
		return deck
	end
	local out = store.clone(deck)
	local nr = out.agents[id]
	nr.failed = true
	nr.ended_ms = now_ms
	return out
end

-- The pane of a `live` or `stopping` record went away: "delete" when the record is `stopping` or a stop was sent
-- in the last 60 s (even if it went back to `live`), otherwise "exited". The caller sets `ended_ms` on exited.
function M.on_exit(record: store.Record, now_ms: number): string
	if record.state == "stopping" or (record.stop_ms ~= nil and now_ms - record.stop_ms <= STOP_WINDOW_MS) then
		return "delete"
	end
	return "exited"
end

-- Applies `on_exit` to one `live` or `stopping` record: deletes it (and its held message) or marks it `exited`
-- with `exit`, `ended_ms = now_ms` and no cached pane. Any other state is left alone.
function M.apply_exit(deck: store.Deck, id: string, exit: number?, now_ms: number): store.Deck
	local r = deck.agents[id]
	if r == nil or (r.state ~= "live" and r.state ~= "stopping") then
		return deck
	end
	local out = store.clone(deck)
	if M.on_exit(r, now_ms) == "delete" then
		out.agents[id] = nil
		out.queue[id] = nil
	else
		local nr = out.agents[id]
		nr.state = "exited"
		nr.exit = exit
		nr.ended_ms = now_ms
		nr.pane = nil
	end
	return out
end

-- A `live` or `stopping` record whose cached pane is not in `live_panes` (the host's listed panes) is
-- handled as `on_exit` would: deleted, or `exited` with `ended_ms = now_ms` and no exit status.
function M.reconcile_states(deck: store.Deck, live_panes: { [number]: boolean }, now_ms: number): store.Deck
	local gone: { string } = {}
	for id, r in deck.agents do
		if (r.state == "live" or r.state == "stopping") and (r.pane == nil or not live_panes[r.pane]) then
			table.insert(gone, id)
		end
	end
	local out = deck
	for _, id in gone do
		out = M.apply_exit(out, id, nil, now_ms)
	end
	return out
end

-- Removes `deleting` groups that have no records left.
function M.sweep_groups(deck: store.Deck): store.Deck
	local used: { [string]: boolean } = {}
	for _, r in deck.agents do
		used[r.gid] = true
	end
	local function swept(g: store.Group): boolean
		return g.deleting == true and not used[g.gid]
	end
	local any = false
	for _, g in deck.groups do
		if swept(g) then
			any = true
		end
	end
	if not any then
		return deck
	end
	local out = store.clone(deck)
	local keep: { store.Group } = {}
	for _, g in out.groups do
		if not swept(g) then
			table.insert(keep, g)
		end
	end
	out.groups = keep
	return out
end

-- What `d` then `y` does to a failed pending row: "delete" once `NO_PANE_MS` have passed since `created_ms` with no
-- pane, otherwise "cancel" (the record is kept and stopped if a late binding shows its pane).
function M.drop_failed(record: store.Record, now: number): string
	if record.pane == nil and now - record.created_ms >= M.NO_PANE_MS then
		return "delete"
	end
	return "cancel"
end

-- Removes the record of `id` and its held message, in `out` (a clone the caller owns).
local function delete_record(out: store.Deck, id: string)
	out.agents[id] = nil
	out.queue[id] = nil
end

-- Takes an exited or failed pending record off the list in `out`: an exited one is deleted, a failed pending one
-- goes through `drop_failed`. A held message goes with the record. Other records are left to the caller.
local function drop_in(out: store.Deck, id: string, now: number)
	local r = out.agents[id]
	if r == nil then
		return
	end
	if r.state == "exited" then
		delete_record(out, id)
	elseif r.state == "pending" and r.failed == true then
		if M.drop_failed(r, now) == "delete" then
			delete_record(out, id)
		else
			r.cancel = true
			out.queue[id] = nil
		end
	end
end

-- `d` then `y` on an exited or failed pending row: deletes it, or marks a young failed pending record `cancel`.
-- Any other record is left alone (the same deck comes back).
function M.drop_record(deck: store.Deck, id: string, now: number): store.Deck
	local r = deck.agents[id]
	if r == nil or not (r.state == "exited" or (r.state == "pending" and r.failed == true)) then
		return deck
	end
	local out = store.clone(deck)
	drop_in(out, id, now)
	return out
end

-- `d` then `y` on a live agent: the record becomes `stopping` with `stop_ms = now` (a `pane_exited` within 60 s
-- deletes it) and its held message is dropped. The caller sends `stop`. A record that is not `live` is left alone.
function M.stop_agent(deck: store.Deck, id: string, now: number): store.Deck
	local r = deck.agents[id]
	if r == nil or r.state ~= "live" then
		return deck
	end
	local out = store.clone(deck)
	out.agents[id].state = "stopping"
	out.agents[id].stop_ms = now
	out.queue[id] = nil
	return out
end

-- Deletes group `gid` with its agents. Live agents become `stopping` and their ids come back for the caller to send
-- `stop` to; a pending agent that has not failed is marked `cancel` (stopped when its pane binds); failed pending
-- records go through `drop_failed` and exited records are deleted; every held message of the group is dropped. The
-- group is removed at once when no agent is left, else marked `deleting` and removed by `sweep_groups` after the
-- last record goes. Calling it again on a `deleting` group stops the agents that came back to `live`.
function M.delete_group(deck: store.Deck, gid: string, now: number): (store.Deck, { string })
	local found = false
	for _, g in deck.groups do
		if g.gid == gid then
			found = true
		end
	end
	if not found then
		return deck, {}
	end
	local out = store.clone(deck)
	local stops: { string } = {}
	for _, id in M.group_ids(deck, gid) do
		local r = out.agents[id]
		if r.state == "live" then
			r.state = "stopping"
			r.stop_ms = now
			out.queue[id] = nil
			table.insert(stops, id)
		elseif r.state == "pending" and r.failed ~= true then
			r.cancel = true
			out.queue[id] = nil
		elseif r.state == "pending" or r.state == "exited" then
			drop_in(out, id, now)
		end
	end
	local left = false
	for _, r in out.agents do
		if r.gid == gid then
			left = true
		end
	end
	local keep: { store.Group } = {}
	for _, g in out.groups do
		if g.gid ~= gid then
			table.insert(keep, g)
		elseif left then
			g.deleting = true
			table.insert(keep, g)
		end
	end
	out.groups = keep
	return out, stops
end

-- This machine's name in a notice: the deck session's host, or "this machine" before a copy has named it.
function M.host_label(deck: store.Deck): string
	local host = deck.session.host
	return if host ~= nil and host ~= "" then host else "this machine"
end

-- An agent's name in a notice: its deck label, else its deck id ("agent" with no id).
function M.agent_label(deck: store.Deck, id: string?): string
	if id == nil then
		return "agent"
	end
	local r = deck.agents[id]
	if r ~= nil and r.label ~= nil and r.label ~= "" then
		return r.label
	end
	return id
end

-- A `stop` that failed (an error reply, or none within 10 s): a `stopping` record goes back to `live`, with the
-- notice "stop failed on <host>". Its `stop_ms` stays, so a `pane_exited` within 60 s still deletes it (the stop
-- may have happened with the reply lost). Any other record is left alone (the same deck, no notice).
function M.stop_failed(deck: store.Deck, id: string): (store.Deck, string?)
	local r = deck.agents[id]
	if r == nil or r.state ~= "stopping" then
		return deck, nil
	end
	local out = store.clone(deck)
	out.agents[id].state = "live"
	return out, "stop failed on " .. M.host_label(deck)
end

-- A `cancel` record whose pane bound comes back `stopping` with no `stop_ms` (`on_bind`): stamps `stop_ms = now` on
-- every such record and gives their ids, ordered, for the host to send `stop` to once. A record `d` stopped already
-- carries its stamp, so it is never asked twice. The same deck comes back when there is none.
function M.stamp_stops(deck: store.Deck, now: number): (store.Deck, { string })
	local ids: { string } = {}
	for id, r in deck.agents do
		if r.state == "stopping" and r.stop_ms == nil then
			table.insert(ids, id)
		end
	end
	if #ids == 0 then
		return deck, ids
	end
	table.sort(ids)
	local out = store.clone(deck)
	for _, id in ids do
		out.agents[id].stop_ms = now
	end
	return out, ids
end

-- A block's launch args (session=<name>, host=<name>): stores the deck session's name and the host name in `deck.session` when
-- either differs (nil leaves a name as it is), stamping `set_ms`. A new block (`restored` false) opened in a
-- session with another name than the stored one gives the notice "jumpr moved from session <old>"; the groups stay,
-- since they live in kv. Returns the same deck when nothing changed.
function M.apply_launch(
	deck: store.Deck,
	name: string?,
	host: string?,
	restored: boolean,
	now_ms: number
): (store.Deck, string?)
	local session = deck.session
	local rename = name ~= nil and name ~= session.name
	local rehost = host ~= nil and host ~= session.host
	if not rename and not rehost then
		return deck, nil
	end
	local notice: string? = nil
	if rename and not restored and session.name ~= nil then
		notice = "jumpr moved from session " .. session.name
	end
	local out = store.clone(deck)
	if rename then
		out.session.name = name
	end
	if rehost then
		out.session.host = host
	end
	out.session.set_ms = now_ms
	return out, notice
end

local function last_segment(path: string): string
	local trimmed = string.gsub(path, "/+$", "")
	return string.match(trimmed, "([^/]+)$") or trimmed
end

-- A group name from git's `--git-common-dir` answer. `<repo>/.git` gives the repo folder's name; a bare repo
-- `<name>.git` gives `<name>`; nil or empty gives `folder`'s last path segment.
function M.label_from_common_dir(common_dir: string?, folder: string): string
	local dir = common_dir or ""
	dir = string.gsub(dir, "^%s+", "")
	dir = string.gsub(dir, "[%s/]+$", "")
	if dir ~= "" then
		local repo = string.match(dir, "([^/]+)/%.git$")
		if repo ~= nil then
			return repo
		end
		local bare = string.match(dir, "([^/]+)%.git$")
		if bare ~= nil and bare ~= "" then
			return bare
		end
	end
	return last_segment(folder)
end

return M
