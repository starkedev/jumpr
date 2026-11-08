--!strict
-- Host-side binding of deck ids to panes, on the host side. The `spawn` filter and
-- `command_started` read the deck id out of the command line and record the host pane in memory only; the host
-- timer applies those bindings to `jumpr.v1` on its next tick, outside the filter. The stored `pane` of a record is a
-- cache of one: the in-memory sets hold every live pane per deck id (two or more = a duplicate).
-- No I/O here: the host passes the deck and the pane list in, and saves any deck that comes back changed.

local identity = require("../shared/identity")
local model = require("./model")
local store = require("./store")

local M = {}

-- A binding seen by a hook, waiting for the next timer tick.
export type Bind = { id: string, pane: number }

export type State = {
	-- Live host panes per deck id.
	sets: model.PaneSets,
	-- Bindings in arrival order, applied by `apply_queued`.
	queued: { Bind },
}

-- What the hooks pass in (the shapes of SpawnSpec, CommandStartedEvent and PaneExitedEvent this module reads).
export type Spec = { program: string?, args: { string }?, env: { [string]: string }? }
export type Started = { pane: number, line: string? }
export type Exited = { pane: number, status: number? }

-- A start with no pane after this long is marked failed (`model.start_failed(…, "no_pane")`).
M.NO_PANE_MS = model.NO_PANE_MS

function M.new(): State
	return { sets = {}, queued = {} }
end

local function lowest(set: { [number]: true }?): number?
	if set == nil then
		return nil
	end
	local best: number? = nil
	for pane in set do
		if best == nil or pane < best then
			best = pane
		end
	end
	return best
end

local function remove_pane(state: State, id: string, pane: number)
	local set = state.sets[id]
	if set == nil then
		return
	end
	set[pane] = nil
	if next(set) == nil then
		state.sets[id] = nil
	end
end

-- A deck id seen in `text` for `pane`. With the deck loaded, an id with no record is ignored (an omp session Jumpr did not start is never listed);
-- before it loads, the record check waits for `apply_queued`.
local function seen(state: State, deck: store.Deck?, text: string, pane: number?)
	if pane == nil then
		return
	end
	local id = identity.match(text)
	if id == nil then
		return
	end
	if deck ~= nil and deck.agents[id] == nil then
		return
	end
	local set = state.sets[id]
	if set == nil then
		set = {}
		state.sets[id] = set
	end
	set[pane] = true
	table.insert(state.queued, { id = id, pane = pane })
end

-- The `spawn` filter: string work only. Joins program and args with spaces and records `env.TERN_PANE`.
-- Returns nil, so the spawn is never changed.
function M.on_spawn(state: State, deck: store.Deck?, spec: Spec): nil
	local parts: { string } = { spec.program or "" }
	local args: { string } = spec.args or {}
	for _, arg in args do
		table.insert(parts, arg)
	end
	local env: { [string]: string } = spec.env or {}
	local pane = tonumber(env.TERN_PANE)
	seen(state, deck, table.concat(parts, " "), pane)
	return nil
end

-- `command_started`: the same rule on the typed command line (covers an agent restored after a restart).
function M.on_command_started(state: State, deck: store.Deck?, ev: Started)
	seen(state, deck, ev.line or "", ev.pane)
end

-- Applies the bindings the hooks recorded: each record becomes live through `model.on_bind` (a bind settles a
-- pending start whatever the reply route did). A binding whose pane a render's reconcile already dropped (the pane
-- not listed yet) still applies and puts the pane back in its set; the next reconcile decides whether it runs.
-- Exited panes never get here: `on_exited` removes their queued bindings. A `cancel` record that binds becomes
-- `stopping` with no `stop_ms`; the host's timer sends its `stop`. Returns the deck (the same table when nothing
-- changed) and the ids that bound (the host clears their pending `start` request).
function M.apply_queued(state: State, deck: store.Deck): (store.Deck, { string })
	local queued = state.queued
	state.queued = {}
	local out = deck
	local bound: { string } = {}
	for _, b in queued do
		local r = out.agents[b.id]
		if r == nil then
			remove_pane(state, b.id, b.pane)
		else
			local set = state.sets[b.id]
			if set == nil then
				set = {}
				state.sets[b.id] = set
			end
			set[b.pane] = true
			table.insert(bound, b.id)
			local settled = r.state == "live"
				and r.pane == b.pane
				and r.failed == nil
				and r.ended_ms == nil
				and r.exit == nil
			if not settled then
				-- A `cancel` record comes back `stopping` with no `stop_ms`: the host timer sends its stop.
				local nr = model.on_bind(r, b.pane)
				if out == deck then
					out = store.clone(deck)
				end
				out.agents[b.id] = nr
			end
		end
	end
	return out, bound
end

local function id_of_pane(state: State, deck: store.Deck, pane: number): string?
	for id, set in state.sets do
		if set[pane] then
			return id
		end
	end
	for id, r in deck.agents do
		if r.pane == pane then
			return id
		end
	end
	return nil
end

-- `pane_exited`: drops the pane's queued bindings and removes it from its id's set. While another pane of a
-- duplicate stays bound the record moves to that pane; otherwise `model.apply_exit` marks it exited (or deletes it
-- after a stop), then `sweep_groups`.
function M.on_exited(state: State, deck: store.Deck, ev: Exited, now_ms: number): store.Deck
	local keep: { Bind } = {}
	for _, b in state.queued do
		if b.pane ~= ev.pane then
			table.insert(keep, b)
		end
	end
	state.queued = keep
	local id = id_of_pane(state, deck, ev.pane)
	if id == nil then
		return deck
	end
	remove_pane(state, id, ev.pane)
	local r = deck.agents[id]
	if r == nil then
		return deck
	end
	local rest = lowest(state.sets[id])
	if rest ~= nil then
		if r.pane == rest then
			return deck
		end
		local out = store.clone(deck)
		out.agents[id].pane = rest
		return out
	end
	if r.pane ~= nil and r.pane ~= ev.pane then
		-- Bound elsewhere: reconcile decides once the pane list shows whether that pane still runs.
		return deck
	end
	return model.sweep_groups(model.apply_exit(deck, id, ev.status, now_ms))
end

-- The pane ids in the host's pane list (each item has a numeric `pane`; other fields are ignored).
function M.live_set(panes: { any }): { [number]: boolean }
	local live: { [number]: boolean } = {}
	for _, p in panes do
		if type(p) == "table" and type(p.pane) == "number" then
			live[p.pane] = true
		end
	end
	return live
end

-- A block's pane may be missing from the pane list just after `init` (the daemon lists it a little later), so a
-- block is dropped from the render set only after this many timer ticks without it.
M.GRACE_TICKS = 3

-- The count of consecutive ticks `pane` has been missing from `live`: 0 when listed (or unknown), else one more.
-- The caller drops the block once the count reaches `GRACE_TICKS`.
function M.missing(count: number, pane: number?, live: { [number]: boolean }): number
	if pane == nil or live[pane] then
		return 0
	end
	return count + 1
end

-- Runs on each render with the host's pane list: drops gone panes from every set, seeds a live record's set from
-- its cached pane after a reload, moves a duplicate's record to its remaining pane, then applies
-- `model.reconcile_states` (a live or stopping record whose pane is gone, as if `pane_exited` had come) and
-- `model.sweep_groups`.
function M.reconcile(state: State, deck: store.Deck, panes: { any }, now_ms: number): store.Deck
	local live = M.live_set(panes)
	for id, set in state.sets do
		for pane in set do
			if not live[pane] then
				set[pane] = nil
			end
		end
		if next(set) == nil then
			state.sets[id] = nil
		end
	end
	local out = deck
	for id, r in deck.agents do
		if r.state == "live" or r.state == "stopping" then
			local set = state.sets[id]
			if r.pane ~= nil and live[r.pane] then
				if set == nil then
					state.sets[id] = { [r.pane] = true }
				end
			else
				local rest = lowest(set)
				if rest ~= nil then
					if out == deck then
						out = store.clone(deck)
					end
					out.agents[id].pane = rest
				end
			end
		end
	end
	out = model.reconcile_states(out, live, now_ms)
	return model.sweep_groups(out)
end

-- Pending starts with no pane `NO_PANE_MS` after `created_ms` go through `model.start_failed(…, "no_pane")`.
function M.expire_starts(state: State, deck: store.Deck, now_ms: number): store.Deck
	local out = deck
	for id, r in deck.agents do
		if r.state == "pending" and now_ms - r.created_ms >= M.NO_PANE_MS and state.sets[id] == nil then
			out = model.start_failed(out, id, "no_pane", now_ms)
		end
	end
	return out
end

-- Whether `pane` is bound to any deck id (a title change there can change a row's default label).
function M.bound(state: State, pane: number): boolean
	for _, set in state.sets do
		if set[pane] then
			return true
		end
	end
	return false
end

-- The host pane typed text goes to for `id`: the record's cached pane while it is bound, else the lowest bound
-- pane; nil when none is bound.
function M.pane_for(state: State, deck: store.Deck, id: string): number?
	local set = state.sets[id]
	if set == nil then
		return nil
	end
	local r = deck.agents[id]
	if r ~= nil and r.pane ~= nil and set[r.pane] then
		return r.pane
	end
	return lowest(set)
end

-- The sets `model.rows` reads.
function M.pane_sets(state: State): model.PaneSets
	return state.sets
end

-- The binding cache as JSON-safe tables, for the diagnostics dump.
function M.dump(state: State): { [string]: any }
	local sets: { [string]: { number } } = {}
	for id, set in state.sets do
		local panes: { number } = {}
		for pane in set do
			table.insert(panes, pane)
		end
		table.sort(panes)
		sets[id] = panes
	end
	local queued: { { [string]: any } } = {}
	for _, b in state.queued do
		table.insert(queued, { id = b.id, pane = b.pane })
	end
	return { sets = sets, queued = queued }
end

return M
