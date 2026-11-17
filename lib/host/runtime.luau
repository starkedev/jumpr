--!strict
-- The host half's list: one machine's deck data, its pane bindings, the copies of the list open on it, their shared
-- list state and the status the windows send them. It answers every block, hook and timer input the host entry
-- registers, and reaches the machine only through the `compat` it is given (lib/compat.luau in production, a fake in
-- tests).
-- Every copy is a thin view of one list state per machine: the state lives here, so it survives copies closing and
-- opening (hide and show, a daemon restart restoring them), and the deck loads on first use, so the hooks work before
-- any copy opens. Each copy keeps its own cx, sender (`b`), status route and caret focus; its rows come from the
-- merged status of every copy. Two clocks: `compat.now()` (monotonic) times status age and replies; `compat.wall_ms()`
-- stamps what is stored in jumpr.v1 (created_ms, ended_ms, set_ms), which must survive a daemon restart.

local bind = require("./bind")
local Agent = require("../shared/agent")
local Compat = require("../compat")
local identity = require("../shared/identity")
local input = require("./input")
local keymap = require("./keymap")
local keys = require("./keys")
local model = require("./model")
local protocol = require("../shared/protocol")
local queue = require("./queue")
local requests = require("./requests")
local sessions = require("./sessions")
local status = require("../shared/status")
local store = require("./store")
local transport = require("./transport")
local vibe = require("./vibe")
local view = require("./view")

local M = {}

local GC_EVERY_MS = 60 * 60 * 1000
-- A copy's init hello waits this long: the pusher's first-contact full snapshot normally lands first (~250 ms after
-- the copies open), and the hello is only sent if this copy still has no status of its own.
local HELLO_DELAY_MS = 400
local LABEL_DEBOUNCE_MS = 150
-- A list-mode move onto an agent waits this long for another key before its tab is shown, so a quick run of moves never flips tabs.
local SHOW_PAUSE_MS = 120
-- The pane list and rows built for one burst of views are reused for at most this long.
local SNAPSHOT_TTL_MS = 200
-- A conversation lookup waits this long between tries, and gives up after this many tries since the record last bound.
-- A proven claude's session file is read again this often, so its stored conversation id follows `/clear`.
local LOOKUP_GAP_MS = 3000
local LOOKUP_MAX = 10
-- A codex agent's rollout appears only at its first prompt, which can come at any time: after its quick tries its
-- lookup goes on this often for as long as it holds no thread.
local LOOKUP_SLOW_MS = 30000
-- While a copy is open, the live omp agents' session files are read for running vibe worker turns this often.
local VIBE_EVERY_MS = 5000
-- A claude or codex agent's Enter is typed this long after its text: written together, its prompt takes both as one
-- paste and the Enter as a new line (Codex always, Claude past 62 characters), and Codex needs 30 ms between them.
local ENTER_DELAY_MS = 200
-- What the list needs of the machine and of its copies' blocks: compat in production.
export type Io = {
	pane_list: () -> ({ Compat.PaneItem }?, string?),
	pane_write: (pane: number, text: string) -> (boolean, string?),
	open: (cx: BlockCx, url: string) -> (boolean, string?),
	render: (cx: BlockCx) -> (boolean, string?),
	focus_field: (cx: BlockCx, id: string?) -> (boolean, string?),
	reveal: (cx: BlockCx, id: string) -> (boolean, string?),
	cwd_of: (cx: BlockCx) -> (string?, string?),
	cols: (cx: BlockCx) -> (number?, string?),
	pane_of: (cx: BlockCx) -> (number?, string?),
	is_dir: (path: string) -> (boolean, string?),
	git_common_dir: (folder: string, cb: (string?) -> ()) -> (boolean, string?),
	fs_write: (path: string, text: string) -> (boolean, string?),
	fs_list: (path: string) -> ({ string }?, string?),
	fs_read: (path: string, max_bytes: number?) -> (string?, string?),
	run_status: (argv: { string }, cb: (status: number?) -> ()) -> (boolean, string?),
	run_output: (argv: { string }, cb: (stdout: string?) -> ()) -> (boolean, string?),
	home: () -> string?,
	kv_get: (key: string) -> (any, string?),
	kv_set: (key: string, value: any) -> (boolean, string?),
	now: () -> number,
	wall_ms: () -> number,
	timer: (ms: number, fn: (cx: WindowCx?) -> ()) -> TimerHandle,
	log_warn: (text: string) -> (),
	data_dir: () -> string,
	json_encode: (value: any, pretty: boolean?) -> string,
	json_decode: (text: string) -> (any, string?),
}

-- One open copy of the list. `missing` counts timer ticks its pane was not listed; `shown` is the clock text of
-- its last view; `focused` says whether its dock input holds the caret focus; `revealed` is the selection key it
-- last scrolled into view, and `reveal_due` asks the next view to reveal it again (a new or resized copy).
export type Copy = {
	cx: BlockCx,
	pane: number?,
	sender: requests.Sender,
	status: transport.Status,
	focused: boolean,
	missing: number,
	shown: string?,
	revealed: string?,
	reveal_due: boolean,
}

-- The list state one machine has, shared by every copy: the keys' UI (selection, search, filter, mode, input,
-- show_src, notice, show_pending) and the dock input's caret.
type Shared = { ui: keys.UI, caret: input.Caret }

-- The list's interface: the block, hook and timer inputs the host entry registers.
export type Runtime = {
	open: (cx: BlockCx, args: { string }, saved: any) -> Copy,
	new_sender: () -> requests.Sender,
	send_from: (
		cx: BlockCx,
		sender: requests.Sender,
		verb: string,
		fields: { [string]: string }
	) -> (boolean, string?),
	frame: (blk: Copy, cx: BlockCx) -> view.Frame,
	title: () -> string?,
	settings: () -> store.Settings,
	readonly: () -> boolean,
	set_agent: (kind: string) -> string?,
	set_key: (action: string, key: string?) -> string?,
	reset_keys: () -> string?,
	host_name: () -> string?,
	key: (blk: Copy, key: Key, cx: BlockCx) -> boolean,
	event: (blk: Copy, ev: UiEvent, cx: BlockCx) -> (),
	saved: (blk: Copy) -> any,
	resized: (blk: Copy, cx: BlockCx) -> (),
	spawn: (spec: bind.Spec) -> bind.Replace?,
	command_started: (ev: bind.Started) -> (),
	pane_exited: (ev: bind.Exited) -> (),
	label_changed: (pane: number) -> (),
	tick: () -> (),
}

-- The list of one machine, given its `Io` and a random source (`rand(n)` is an integer in [1, n]).
function M.new(compat: Io, rand: (number) -> number): Runtime
	local deck: store.Deck? = nil
	local readonly = false
	local load_banner: string? = nil
	local save_error: string? = nil
	local binding = bind.new()
	local link = transport.new()
	local follower = vibe.new()
	local last_vibe: number? = nil
	local ledger = requests.new()
	local blocks: { [Copy]: true } = {}
	local shared: Shared? = nil
	local last_gc = compat.now()
	local label_timer = false
	local show_gen = 0

	local function wall(): number
		return compat.wall_ms()
	end

	local function new_uid(): string
		return identity.new_id(rand)
	end

	local function save(d: store.Deck)
		local ok, err = store.save(compat, d, readonly)
		if ok then
			save_error = nil
		else
			local text = "jumpr data not saved on " .. model.host_label(d) .. ": " .. tostring(err)
			save_error = text
			transport.note_error(link, text)
		end
	end

	-- The deck, loaded on first use. Data that load replaced (malformed, backed up) is saved at once.
	local function ensure(): store.Deck
		if deck ~= nil then
			return deck
		end
		local d, ro, banner = store.load(compat, wall())
		readonly = ro
		load_banner = banner
		deck = d
		if banner ~= nil and not ro then
			save(d)
		end
		return d
	end

	-- The list state, created on first use from `saved` (the first copy restored after a daemon restart seeds it;
	-- later copies keep it).
	local function state_for(saved: any): Shared
		local existing = shared
		if existing ~= nil then
			return existing
		end
		local fresh: Shared = { ui = keys.new_ui(saved), caret = { cursor = nil, edited = nil } }
		shared = fresh
		return fresh
	end

	local function list(): Shared
		return state_for(nil)
	end

	-- The copy zen mode was turned on in (the one the window zoomed), while zen is on.
	local zen_copy: Copy? = nil

	-- A snapshot of the host's pane list and the rows built from it serves a burst of views (a key in one copy renders
	-- every copy): it stays valid while nothing calls `touch` and for at most SNAPSHOT_TTL_MS.
	local rev = 0
	local snap_rev = -1
	local snap_at = 0
	local snap_panes: { Compat.PaneItem }? = nil
	local snap_rows: { model.Row }? = nil

	local function touch()
		rev += 1
	end

	-- Keeps `d` as the deck and saves it when it is a new table; true when it changed.
	local function commit(d: store.Deck): boolean
		if d == deck then
			return false
		end
		deck = d
		save(d)
		touch()
		return true
	end

	local sync_focus: () -> ()

	-- A copy leaves the render set and the machine's merged status together.
	local function drop(blk: Copy)
		blocks[blk] = nil
		transport.unregister(link, blk.status)
		touch()
	end

	-- A copy joins both, again if a view or key arrives after it was dropped; a copy that opens while the shared input
	-- is open gets the caret too.
	local function adopt(blk: Copy)
		if blocks[blk] then
			return
		end
		blocks[blk] = true
		transport.register(link, blk.status)
		touch()
		sync_focus()
	end

	local function render(blk: Copy)
		local ok = compat.render(blk.cx)
		if not ok then
			drop(blk)
		end
	end

	local function render_all()
		for blk in blocks do
			render(blk)
		end
	end

	-- Ends zen once the copy it was turned on in is gone (the list hidden, its tab closed, a render that found it
	-- closed), so the copies left are not kept from showing agents' tabs.
	local function end_lost_zen()
		if zen_copy ~= nil and not blocks[zen_copy] then
			zen_copy = nil
			list().ui.zen = false
			render_all()
		end
	end

	-- Renders every copy but `except`, deferred to the host's next turn and coalesced: a key or edit in one copy
	-- changes the state all of them show, but the copy it happened in is the one being watched, and Tern renders it
	-- as soon as the key hook returns — so it must not wait behind the others, and a run of keys renders the others
	-- once, not once each.
	local others_dirty: { [Copy]: true } = {}
	local others_scheduled = false
	local function render_others(except: Copy)
		for blk in blocks do
			if blk ~= except then
				others_dirty[blk] = true
			end
		end
		if next(others_dirty) == nil or others_scheduled then
			return
		end
		others_scheduled = true
		compat.timer(0, function()
			others_scheduled = false
			for blk in others_dirty do
				others_dirty[blk] = nil
				if blocks[blk] then
					render(blk)
				end
			end
		end)
	end

	-- Moves the caret to the dock input when one opens and clears it when it closes, after the view that adds or
	-- removes the field has gone out; every copy follows the shared mode.
	sync_focus = function()
		local want = list().ui.mode == "input"
		for blk in blocks do
			if blk.focused ~= want then
				blk.focused = want
				compat.timer(0, function()
					if blocks[blk] then
						compat.focus_field(blk.cx, if want then view.INPUT_ID else nil)
					end
				end)
			end
		end
	end

	-- Scrolls the selection into view in `blk` after the view that draws it has gone out, only when the selection moved
	-- to another row or place since the last reveal (or the copy is new or resized), so a clock re-render never scrolls
	-- the list away from where the user put it. A rejected reveal goes to the error ring the diagnostics dump shows.
	local function sync_reveal(blk: Copy, f: view.Frame)
		local id, key = view.reveal(f.rows, f.ui.selection, blk.revealed, blk.reveal_due)
		blk.revealed, blk.reveal_due = key, false
		if id == nil then
			return
		end
		compat.timer(0, function()
			if blocks[blk] then
				local ok, err = compat.reveal(blk.cx, id)
				if not ok then
					transport.note_error(link, "reveal failed: " .. tostring(err))
				end
			end
		end)
	end

	-- Sends one jumpr:// request from `blk`: next_req is saved before the URL is opened. False when it could not be
	-- opened; the notice then says so.
	local function send(blk: Copy, verb: string, fields: { [string]: string }): boolean
		local url, d = requests.request(ledger, blk.sender, ensure(), readonly, verb, fields, compat.now(), new_uid)
		commit(d)
		local ok, err = compat.open(blk.cx, url)
		if not ok then
			transport.note_error(link, "open " .. verb .. " failed: " .. tostring(err))
			local what = if fields.id ~= nil then verb .. " " .. model.agent_label(d, fields.id) else verb
			list().ui.notice = what .. " not sent on " .. model.host_label(d) .. ": " .. tostring(err)
		end
		return ok
	end

	-- The host's pane list, fetched once per snapshot and reconciled into the records; nil when the read failed.
	local function panes_now(): { Compat.PaneItem }?
		local now = compat.now()
		local cached = snap_panes
		if cached ~= nil and snap_rev == rev and now - snap_at < SNAPSHOT_TTL_MS then
			return cached
		end
		local panes = compat.pane_list()
		if panes ~= nil then
			commit(bind.reconcile(binding, ensure(), panes, wall()))
		end
		snap_panes = panes
		snap_rows = nil
		snap_rev, snap_at = rev, now
		return panes
	end

	-- The merged status as a row or tile shows it: each vibing omp agent's entries are marked (`status.with_vibing`).
	-- The map is copied only when an agent is vibing, so what transport returned is never changed.
	local function shown_status(now: number): model.StatusById
		local by_id = transport.status_by_id(link, now)
		local out: model.StatusById? = nil
		for id in vibe.vibing(follower) do
			local entries = by_id[id]
			if entries ~= nil and #entries > 0 then
				local copy = out or table.clone(by_id)
				copy[id] = status.with_vibing(entries)
				out = copy
			end
		end
		return out or by_id
	end

	-- The rows every copy shows: one pane list, the machine's merged status, the shared UI. The shared selection is
	-- clamped against these rows.
	local function rows_for(): { model.Row }
		local panes = panes_now()
		local cached = snap_rows
		if cached ~= nil then
			return cached
		end
		local d = ensure()
		local sh = list()
		local now = compat.now()
		local any: any = panes or {}
		local rows = model.rows(d, any, bind.pane_sets(binding), shown_status(now), sh.ui, transport.health(link, now))
		sh.ui.selection = model.clamp_selection(rows, sh.ui.selection, d)
		snap_rows = rows
		return rows
	end

	local dispatch: (blk: Copy, ev: keys.Event) -> boolean

	-- Types `text` and Enter into the pane bound to deck id `id` (the host's own pane, picked from its bindings). The
	-- caller has already saved the deck, so a reload between the save and this call cannot send twice. A claude or
	-- codex agent gets its Enter as a second write `ENTER_DELAY_MS` later, into the same pane only: when that pane is
	-- no longer the agent's by then, or the write fails, the deck and notice `late` gives are kept, as for a failed
	-- write. A reload in between loses that Enter, and the text is never typed twice.
	local function type_into(id: string, text: string, late: queue.Late): (boolean, string?)
		local d = ensure()
		local pane = bind.pane_for(binding, d, id)
		if pane == nil then
			return false, "pane gone"
		end
		local r = d.agents[id]
		if r == nil or not Agent.is_cli(r.cli) then
			return compat.pane_write(pane, text .. "\r")
		end
		local ok, err = compat.pane_write(pane, text)
		if not ok then
			return false, err
		end
		compat.timer(ENTER_DELAY_MS, function()
			local entered, why = false, "pane gone"
			if bind.pane_for(binding, ensure(), id) == pane then
				local wrote, write_err = compat.pane_write(pane, "\r")
				entered, why = wrote, tostring(write_err)
			end
			if not entered then
				local kept, notice = late(ensure(), why)
				commit(kept)
				list().ui.notice = notice
				render_all()
			end
		end)
		return true, nil
	end

	-- What `queue.send` and `queue.flush` need: a save that makes the deck the one held here and says whether kv took
	-- it, the typing, and the status side's note that a message went.
	local function send_ports(): queue.Ports
		return {
			save = function(d: store.Deck): boolean
				commit(d)
				return save_error == nil
			end,
			write = type_into,
			sent = function(id: string)
				transport.sent(link, id)
			end,
			now = wall(),
		}
	end

	-- Types the held messages that are due (`queue.flush`). True when anything changed.
	local function flush_due(due: { queue.Due }): boolean
		local _, changed, notice = queue.flush(ensure(), due, send_ports())
		if notice ~= nil then
			list().ui.notice = notice
		end
		return changed
	end

	-- Arms the one 120 ms timer a list-mode move waits on (a newer move replaces it); when it fires, `show_due` goes
	-- back through keys.reduce for that copy, which asks the window to show the agent's tab only if no other key
	-- followed.
	local function arm_show(blk: Copy, id: string)
		show_gen += 1
		local gen = show_gen
		compat.timer(SHOW_PAUSE_MS, function()
			if gen ~= show_gen then
				return
			end
			local target: Copy? = if blocks[blk] then blk else next(blocks)
			if target ~= nil and dispatch(target, { kind = "show_due", id = id }) then
				render_all()
			end
		end)
	end

	-- Runs keys.reduce's effects in order; true when one of them is `render` or a request could not be sent. A
	-- `check_folder` is answered on this machine at once, and its answer goes back through keys.reduce once the rest
	-- of these effects have run.
	local function run(blk: Copy, effects: { keys.Effect }): boolean
		local rendered = false
		local answers: { keys.Event } = {}
		for _, e in effects do
			if e.kind == "save_kv" then
				save(ensure())
			elseif e.kind == "request" and e.verb ~= nil then
				local fields: { [string]: string } = e.fields or {}
				if e.verb == "zen" then
					zen_copy = if fields.on == "1" then blk else nil
				end
				if not send(blk, e.verb, fields) then
					rendered = true
				end
			elseif e.kind == "git_root" and e.folder ~= nil then
				local folder: string = e.folder
				compat.git_common_dir(folder, function(common_dir: string?)
					if
						blocks[blk] and dispatch(blk, { kind = "git_root", folder = folder, common_dir = common_dir })
					then
						render_all()
					end
				end)
			elseif e.kind == "check_folder" and e.folder ~= nil then
				table.insert(answers, keys.folder_checked(e, (compat.is_dir(e.folder))))
			elseif e.kind == "write" and e.id ~= nil then
				-- `o`: queue.send stamps and saves the record before typing, and rolls back what it could not type.
				local _, notice = queue.send(ensure(), e.id, e.text or "", send_ports())
				if notice ~= nil then
					list().ui.notice = notice
					rendered = true
				end
			elseif e.kind == "show" and e.id ~= nil then
				arm_show(blk, e.id)
			elseif e.kind == "render" then
				rendered = true
			end
		end
		for _, ev in answers do
			if dispatch(blk, ev) then
				rendered = true
			end
		end
		return rendered
	end

	-- One input event through keys.reduce; true when the view changed. The caret stays where it was while the input
	-- line holds the text the host last edited; any other new text (a prefill, a refill) puts it at the end.
	dispatch = function(blk: Copy, ev: keys.Event): boolean
		local sh = list()
		touch()
		local rows = rows_for()
		sh.ui.block_cwd = compat.cwd_of(blk.cx)
		local newest = transport.newest(link)
		sh.ui.em = if newest ~= nil then newest.em else "A"
		local ui, d, effects = keys.reduce(sh.ui, ensure(), rows, ev, wall(), rand)
		sh.ui = ui
		deck = d
		touch()
		local rendered = run(blk, effects)
		sh.caret = input.follow(sh.caret, sh.ui.mode == "input", sh.ui.text)
		sync_focus()
		return rendered
	end

	-- The input line edited at the caret: keys gets the whole new line as an edit event. True when the view changed.
	local function edit_line(blk: Copy, text: string, cursor: number): boolean
		local sh = list()
		local moved = cursor ~= input.clamp_cursor(sh.ui.text, sh.caret.cursor)
		sh.caret = { cursor = cursor, edited = text }
		local rendered = dispatch(blk, { kind = "edit", text = text })
		return rendered or moved
	end

	local function frame(blk: Copy, rows: { model.Row }): view.Frame
		local d = ensure()
		local sh = list()
		local now = compat.now()
		local newest = transport.newest(link)
		local health = transport.health(link, now)
		return {
			ui = sh.ui,
			map = keymap.resolve(d.settings.keys),
			rows = rows,
			cursor = sh.caret.cursor,
			host = d.session.host,
			h = if newest ~= nil then newest.h else nil,
			health = health,
			age_ms = transport.age(link, now),
			row_age = transport.row_ages(link, now),
			tally = model.tally(d, shown_status(now), health),
			version = transport.version(link, now),
			dupb = blk.status.latest.dupb,
			readonly = readonly,
			load_banner = load_banner,
			save_error = save_error,
			-- Zen draws the list at most `view.ZEN_COLS` wide, in the middle of its pane.
			cols = if sh.ui.zen then math.min(compat.cols(blk.cx) or 32, view.ZEN_COLS) else compat.cols(blk.cx) or 32,
			groups = d.groups,
		}
	end

	local function key_event(key: Key): keys.Event
		return {
			kind = "key",
			name = key.name,
			text = key.text,
			ctrl = key.ctrl,
			alt = key.alt,
			shift = key.shift,
			meta = key.meta,
		}
	end

	-- A cancelled start whose pane bound comes back `stopping` with no `stop_ms` (its group was deleted while it started):
	-- `model.stamp_stops` stamps it, the stamp is saved first, then the window is asked to stop it through any open copy.
	-- With no copy open it waits for the next tick that has one. True when it changed anything.
	local function send_stops(): boolean
		local blk = next(blocks)
		if blk == nil then
			return false
		end
		local out, ids = model.stamp_stops(ensure(), wall())
		if #ids == 0 then
			return false
		end
		commit(out)
		for _, id in ids do
			send(blk, "stop", { id = id })
		end
		return true
	end
	-- Tries since the record last bound, and the proof once one is found: from then on the proven claude is followed
	-- (`follow_sessions`) rather than looked up, until the next bind or until it is gone. `picked` says whether the
	-- start the record last bound from opened Codex's resume picker, which decides how its thread is proven.
	type Hunt = {
		attempts: number,
		last_ms: number,
		running: boolean,
		settled: boolean,
		gen: number,
		proof: sessions.Proof?,
		picked: boolean,
	}
	local hunts: { [string]: Hunt } = {}

	local function hunt_of(id: string): Hunt
		local h = hunts[id]
		if h == nil then
			h = { attempts = 0, last_ms = 0, running = false, settled = false, gen = 0, picked = false }
			hunts[id] = h
		end
		return h
	end

	-- A bind starts the lookup again, including one that already holds a conversation id, and starts the agent's vibe
	-- workers over: a turn its last process left running never settles. A bind that settles a start (`prior`, the record
	-- before it, is pending) notes how that start ran: a codex agent with no thread that had run before restarts in
	-- Codex's resume picker (`model.restart_mode`); any other bind (a second pane, a retyped line) keeps what it was.
	-- True when the agent was vibing until now.
	local function note_bound(id: string, prior: store.Record?): boolean
		local h = hunt_of(id)
		h.gen += 1
		h.attempts = 0
		h.settled = false
		h.last_ms = 0
		h.proof = nil
		if prior ~= nil and prior.state == "pending" then
			h.picked = prior.ran == true
		end
		local was_vibing = vibe.vibing(follower)[id] ~= nil
		vibe.restarted(follower, id, wall())
		return was_vibing
	end

	-- Every other record's conversation id. This record's own id is left out, so a re-proof of it still counts.
	local function taken_except(d: store.Deck, id: string): { [string]: boolean }
		local taken: { [string]: boolean } = {}
		for other, rec in d.agents do
			local sid = rec.session
			if other ~= id and sid ~= nil then
				taken[sid] = true
			end
		end
		return taken
	end

	-- Reads each due proven claude's session file again (`sessions.current`, no grep): `/clear` and a resume inside
	-- claude change the live conversation id, and the stored id follows it unless another record holds that one. A
	-- claude that is gone sends its agent back to the lookup, with a fresh run of tries. Returns the deck.
	local function follow_sessions(d: store.Deck, ids: { string }, now: number, home: string): store.Deck
		local out = d
		for _, id in ids do
			local h = hunt_of(id)
			local proof = h.proof
			if proof ~= nil then
				h.last_ms = now
				local sid = sessions.current(compat :: sessions.Compat, home, proof)
				if sid == nil then
					h.proof = nil
					h.settled = false
					h.attempts = 0
				elseif not taken_except(out, id)[sid] then
					out = model.set_session(out, id, sid, true)
				end
			end
		end
		return out
	end

	-- Whether a lookup with `attempts` tries since the last bind, the last of them `since` ms ago, is due: at once after
	-- a bind, then every LOOKUP_GAP_MS up to LOOKUP_MAX tries; a codex agent's goes on every LOOKUP_SLOW_MS after that.
	local function lookup_due(attempts: number, since: number, codex: boolean): boolean
		if attempts == 0 then
			return true
		end
		if attempts < LOOKUP_MAX then
			return since >= LOOKUP_GAP_MS
		end
		return codex and since >= LOOKUP_SLOW_MS
	end

	-- The other codex agents in folder `cwd` that hold no thread, for `sessions.find_thread`: a thread that started in
	-- the window of one of them, before it ended, may be its own.
	local function codex_rivals(d: store.Deck, id: string, cwd: string): { sessions.Rival }
		local out: { sessions.Rival } = {}
		for other, rec in d.agents do
			if other ~= id and rec.cli == Agent.CODEX and rec.cwd == cwd and rec.session == nil then
				table.insert(out, { created_ms = rec.created_ms, ended_ms = rec.ended_ms })
			end
		end
		return out
	end

	-- The hunt a lookup's answer belongs to, its run over; nil when the agent bound again since the lookup started.
	local function answered(id: string, gen: number): Hunt?
		local current = hunts[id]
		if current == nil then
			return nil
		end
		current.running = false
		return if current.gen == gen then current else nil
	end

	-- Only a kind whose conversation can be looked up. A proven claude is followed every LOOKUP_GAP_MS; otherwise one
	-- live agent per tick is looked up and its answer arrives later: a miss retries after the gap, ten times since the
	-- last bind. A proof is of the pane's own claude, so its id is stored even over a different one (`/clear` moved it).
	-- A codex agent is looked up only while it holds no thread, and a thread once stored is settled: nothing follows
	-- it. Its rollout appears only at its first prompt, so after its ten tries it is looked up every LOOKUP_SLOW_MS.
	local function lookup_sessions(d: store.Deck, now: number)
		local follows: { string } = {}
		local ids: { string } = {}
		for id, rec in d.agents do
			local codex = rec.cli == Agent.CODEX
			if rec.state == "live" and sessions.has(rec.cli) and not (codex and rec.session ~= nil) then
				local h = hunts[id]
				local attempts = if h ~= nil then h.attempts else 0
				local running = h ~= nil and h.running
				local settled = h ~= nil and h.settled
				local since = now - (if h ~= nil then h.last_ms else 0)
				if h ~= nil and h.proof ~= nil then
					if since >= LOOKUP_GAP_MS then
						table.insert(follows, id)
					end
				elseif not running and not settled and lookup_due(attempts, since, codex) then
					table.insert(ids, id)
				end
			end
		end
		if #follows == 0 and #ids == 0 then
			return
		end
		local home = compat.home()
		if home == nil then
			return
		end
		table.sort(follows)
		local out = follow_sessions(d, follows, now, home)
		if commit(out) then
			render_all()
		end
		table.sort(ids)
		local id = ids[1]
		if id == nil then
			return
		end
		local rec = out.agents[id]
		local h = hunt_of(id)
		h.attempts += 1
		h.last_ms = now
		h.running = true
		local gen = h.gen
		local taken = taken_except(out, id)
		if rec.cli == Agent.CODEX then
			local ask: sessions.Ask = {
				cwd = rec.cwd,
				created_ms = rec.created_ms,
				now_ms = wall(),
				picked = h.picked,
				taken = taken,
				rivals = codex_rivals(out, id, rec.cwd),
			}
			sessions.find_thread(compat :: sessions.Compat, home, ask, function(sid: string?)
				local current = answered(id, gen)
				if current == nil or sid == nil then
					return
				end
				current.settled = true
				if commit(model.set_session(ensure(), id, sid)) then
					render_all()
				end
			end)
			return
		end
		sessions.find(compat :: sessions.Compat, home, rec.cli, id, rec.cwd, taken, function(proof: sessions.Proof?)
			local current = answered(id, gen)
			if current == nil or proof == nil then
				return
			end
			current.settled = true
			current.proof = proof
			if commit(model.set_session(ensure(), id, proof.sid, true)) then
				render_all()
			end
		end)
	end

	-- Reads the live omp agents' session files for running vibe worker turns, at most every VIBE_EVERY_MS. An answer
	-- that changes which agents are vibing rebuilds the rows and renders every copy.
	local function poll_vibe(now: number)
		local last = last_vibe
		if last ~= nil and now - last < VIBE_EVERY_MS then
			return
		end
		local home = compat.home()
		if home == nil then
			return
		end
		last_vibe = now
		local ids: { string } = {}
		for id, rec in ensure().agents do
			if rec.cli == Agent.OMP and rec.state == "live" then
				table.insert(ids, id)
			end
		end
		table.sort(ids)
		vibe.poll(follower, compat :: vibe.Compat, home, ids, function(changed: boolean)
			if changed then
				touch()
				render_all()
			end
		end)
	end

	local function step()
		touch()
		local now, w = compat.now(), wall()
		local before = ensure()
		local d, bound = bind.apply_queued(binding, before)
		local unvibed = false
		for _, id in bound do
			requests.clear_start(ledger, id)
			if note_bound(id, before.agents[id]) then
				unvibed = true
			end
		end
		local expired, notices, errors = requests.expire(ledger, d, now, w)
		for _, line in errors do
			transport.note_error(link, line)
		end
		d = bind.expire_starts(binding, expired, w)
		if now - last_gc >= GC_EVERY_MS then
			last_gc = now
			d = store.gc(d, w)
		end
		local changed = commit(d) or unvibed
		for _, b in bind.take_blocked(binding) do
			table.insert(
				notices,
				"agent "
					.. model.agent_label(d, b.id)
					.. " already runs in pane "
					.. string.format("%.0f", b.running)
					.. ": a second start was stopped"
			)
		end
		if #notices > 0 and shared ~= nil then
			shared.ui.notice = table.concat(notices, "; ")
			changed = true
		end
		if send_stops() then
			changed = true
		end

		-- An agent can start or exit while the list is hidden, so the lookup runs before that return.
		lookup_sessions(ensure(), now)
		end_lost_zen()
		if next(blocks) == nil then
			-- No copy is open, so nothing shows a pill: what the follower last learned is dropped, and a list
			-- that opens again starts from a fresh answer rather than one the lists never saw.
			vibe.clear(follower)
			return
		end
		poll_vibe(now)
		local panes = panes_now()
		if panes ~= nil then
			local live = bind.live_set(panes)
			for blk in blocks do
				blk.missing = bind.missing(blk.missing, blk.pane, live)
				if blk.missing >= bind.GRACE_TICKS then
					drop(blk)
				end
			end
		end
		end_lost_zen()

		-- Rows are the same for every copy: built once per tick, and only while a copy exists.
		if next(blocks) == nil then
			return
		end
		-- Held messages that are due now: `q` on an agent that is already idle, and the 30 s rule after a reload.
		if flush_due(transport.due(link, ensure(), bind.pane_sets(binding), now, w, keys.editing(list().ui))) then
			changed = true
		end
		local rows = rows_for()
		for blk in blocks do
			transport.forget(blk.status, now)
			if changed or view.clock_key(frame(blk, rows)) ~= blk.shown then
				render(blk)
			end
		end
	end

	local rt = {}

	-- A copy opens (the block's `init`): stale data is collected, the launch args name the deck session and host, and
	-- the copy asks for status with a hello unless the window's first full snapshot reaches it first.
	function rt.open(cx: BlockCx, args: { string }, saved: any): Copy
		local now = wall()
		commit(store.gc(ensure(), now))
		local name, host = protocol.parse_launch_args(args or {})
		local clock = compat.now()
		local d, notice = model.apply_launch(
			ensure(),
			name,
			host,
			saved ~= nil,
			now,
			transport.live_hosts(link, clock),
			transport.settled(link, clock)
		)
		commit(d)
		if notice ~= nil then
			compat.log_warn("jumpr: " .. notice)
		end
		local sh = state_for(saved)
		if notice ~= nil then
			sh.ui.notice = notice
		end
		local s: any = if type(saved) == "table" then saved else {}
		local blk: Copy = {
			cx = cx,
			pane = compat.pane_of(cx),
			sender = requests.new_sender(s.uid, d, readonly, new_uid),
			status = transport.new_status(),
			focused = false,
			missing = 0,
			shown = nil,
			revealed = nil,
			reveal_due = true,
		}
		adopt(blk)
		compat.timer(HELLO_DELAY_MS, function()
			if blocks[blk] and blk.status.last_ms == nil and not send(blk, "hello", {}) then
				render(blk)
			end
		end)
		return blk
	end

	-- What a copy shows now (the block's `view`, before it is built into nodes); the selection is revealed after it.
	function rt.frame(blk: Copy, cx: BlockCx): view.Frame
		blk.cx = cx
		adopt(blk)
		local f = frame(blk, rows_for())
		blk.shown = view.clock_key(f)
		sync_reveal(blk, f)
		return f
	end

	-- The copies' title: the host the list is for.
	function rt.title(): string?
		return view.title(if deck ~= nil then deck.session.host else nil)
	end

	-- A detached copy of this machine's settings, so the runtime remains the deck's only owner.
	function rt.settings(): store.Settings
		local current = ensure().settings
		return { agent = current.agent, keys = table.clone(current.keys) }
	end

	-- Whether settings changes are refused because the stored deck cannot be written safely.
	function rt.readonly(): boolean
		ensure()
		return readonly
	end

	-- A settings block gets an identity separate from every list copy while sharing the deck's request counter.
	function rt.new_sender(): requests.Sender
		return requests.new_sender(nil, ensure(), readonly, new_uid)
	end

	-- Sends the settings block's window request after advancing and saving the shared request counter.
	function rt.send_from(
		cx: BlockCx,
		sender: requests.Sender,
		verb: string,
		fields: { [string]: string }
	): (boolean, string?)
		if verb ~= "cfg" then
			return false, "settings blocks may send cfg only"
		end
		local url, d = requests.request(ledger, sender, ensure(), readonly, verb, fields, compat.now(), new_uid)
		commit(d)
		local ok, err = compat.open(cx, url)
		if not ok then
			local reason = err or "request could not be opened"
			transport.note_error(link, "open cfg failed: " .. reason)
			return false, reason
		end
		return true, nil
	end

	-- Changes the default agent after validation, then persists it and refreshes every list copy.
	function rt.set_agent(kind: string): string?
		if not Agent.valid_kind(kind) then
			return "agent kind not supported"
		end
		local d = ensure()
		if readonly then
			return "settings are read-only"
		end
		local out = store.clone(d)
		out.settings.agent = kind
		commit(out)
		render_all()
		return save_error
	end

	-- Changes one list action's key after validation, then persists it and refreshes every list copy.
	-- A nil key removes the override and restores the action's default, which is refused when another action
	-- holds that default key: an action left with no working key would strand the list.
	function rt.set_key(action: string, key: string?): string?
		local d = ensure()
		if readonly then
			return "settings are read-only"
		end
		if key ~= nil then
			local reason = keymap.check(d.settings.keys, action, key)
			if reason ~= nil then
				return reason
			end
		else
			local default = keymap.DEFAULT_OF[action]
			if default ~= nil then
				local reason = keymap.check(d.settings.keys, action, default)
				if reason ~= nil then
					return reason
				end
			end
		end
		local out = store.clone(d)
		if key == nil then
			out.settings.keys[action] = nil
		else
			out.settings.keys[action] = key
		end
		commit(out)
		render_all()
		return save_error
	end

	-- Restores every list action's default key, then persists and refreshes every list copy.
	function rt.reset_keys(): string?
		local d = ensure()
		if readonly then
			return "settings are read-only"
		end
		local out = store.clone(d)
		out.settings.keys = {}
		commit(out)
		render_all()
		return save_error
	end

	-- The machine name stored by the list's launch arguments.
	function rt.host_name(): string?
		return ensure().session.host
	end

	-- A key in a copy; true when the view changed (every other copy is rendered too).
	function rt.key(blk: Copy, key: Key, cx: BlockCx): boolean
		blk.cx = cx
		local sh = list()
		local ev = key_event(key)
		local rendered: boolean
		local text, cursor = nil, nil
		if sh.ui.mode == "input" then
			text, cursor = input.key(sh.ui.text, sh.caret.cursor, ev)
		end
		if text ~= nil and cursor ~= nil then
			rendered = edit_line(blk, text, cursor)
		else
			rendered = dispatch(blk, ev)
		end
		if rendered then
			render_others(blk)
		end
		return rendered
	end

	-- A view event in a copy: a click on a row, a message from the window (`action`), or an edit of the input line.
	function rt.event(blk: Copy, ev: UiEvent, cx: BlockCx)
		blk.cx = cx
		local sh = list()
		if ev.ev == "action" and ev.act == view.CLICK then
			-- A click on a row (view.clicked maps its node id back to it) or on a count tile (view.clicked_tile maps it
			-- to the tile's filter key) goes through keys.reduce like a key, so every copy follows it as it follows keys.
			-- A block event lists the modifiers held in `mods` (absent with none), so an alt (Option) click on a tile is
			-- known.
			local row = view.clicked(ev.id)
			local tile = if row == nil then view.clicked_tile(ev.id) else nil
			local mods: any = ev.mods
			local alt = type(mods) == "table" and table.find(mods, "alt") ~= nil
			local event: keys.Event? = if row ~= nil
				then { kind = "click", gid = row.gid, id = row.id }
				elseif tile ~= nil then { kind = "tile", text = tile, alt = alt }
				else nil
			if event ~= nil and dispatch(blk, event) then
				render_all()
			end
		elseif ev.ev == "action" then
			touch()
			local out = transport.on_action(link, blk.status, ev, {
				deck = ensure(),
				readonly = readonly,
				b = blk.sender.b,
				now = compat.now(),
				wall = wall(),
				io = compat,
				data_dir = compat.data_dir(),
				binding = function(): any
					return bind.dump(binding)
				end,
				sets = bind.pane_sets(binding),
				skip = keys.editing(sh.ui),
				requests = ledger,
			})
			local changed = commit(out.deck)
			if flush_due(out.due) then
				changed = true
			end
			if out.notice ~= nil then
				sh.ui.notice = out.notice
			end
			local failed = false
			for _, req in out.requests do
				if not send(blk, req.verb, req.fields) then
					failed = true
				end
			end
			-- A focus message moves the shared highlight onto the agent the last-tab chord landed on (every copy).
			if out.follow ~= nil and dispatch(blk, { kind = "follow", id = out.follow }) then
				changed = true
			end
			if changed or out.render or out.notice ~= nil or failed then
				render_all()
			end
		elseif ev.ev == "edit" and sh.ui.mode == "input" then
			local text, cursor = input.apply_edit(sh.ui.text, ev)
			if text ~= nil and cursor ~= nil and edit_line(blk, text, cursor) then
				render_all()
			end
		end
	end

	-- What a copy keeps across a daemon restart (the block's `save`).
	function rt.saved(blk: Copy): any
		local s = keys.saved_ui(list().ui)
		return {
			uid = blk.sender.b,
			selection = s.selection,
			search = s.search,
			filter = s.filter,
			show_src = s.show_src,
		}
	end

	-- A copy was resized: its next view reveals the selection again.
	function rt.resized(blk: Copy, cx: BlockCx)
		blk.cx = cx
		blk.reveal_due = true
	end

	-- The spawn filter: string work only, never kv; the binding is applied on the next tick. A second process for an
	-- agent that already runs here comes back as the replacement to spawn instead.
	function rt.spawn(spec: bind.Spec): bind.Replace?
		touch()
		local ok, res = pcall(bind.on_spawn, binding, deck, spec)
		if not ok then
			transport.note_error(link, "spawn hook: " .. tostring(res))
			return nil
		end
		return res
	end

	-- A shell started a command line in a pane (a typed-again agent after a daemon restart binds here).
	function rt.command_started(ev: bind.Started)
		touch()
		bind.on_command_started(binding, ensure(), ev)
	end

	-- A pane's program exited.
	function rt.pane_exited(ev: bind.Exited)
		touch()
		if commit(bind.on_exited(binding, ensure(), ev, wall())) then
			render_all()
		end
	end

	-- A title or cwd change on a bound pane can change a row's default label: render once the burst settles.
	function rt.label_changed(pane: number)
		if label_timer or not bind.bound(binding, pane) then
			return
		end
		label_timer = true
		compat.timer(LABEL_DEBOUNCE_MS, function()
			label_timer = false
			touch()
			render_all()
		end)
	end

	-- One host timer tick; an error is kept in the error ring and logged, never raised.
	function rt.tick()
		local ok, err = pcall(step :: () -> ...any)
		if not ok then
			transport.note_error(link, "timer: " .. tostring(err))
			compat.log_warn("jumpr: timer: " .. tostring(err))
		end
	end

	return rt
end

return M
