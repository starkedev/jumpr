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
local Compat = require("../compat")
local identity = require("../shared/identity")
local input = require("./input")
local keys = require("./keys")
local model = require("./model")
local protocol = require("../shared/protocol")
local queue = require("./queue")
local requests = require("./requests")
local store = require("./store")
local transport = require("./transport")
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
	frame: (blk: Copy, cx: BlockCx) -> view.Frame,
	title: () -> string?,
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

	-- Renders every copy but `except`: a key or edit in one copy changes the state all of them show.
	local function render_others(except: Copy)
		for blk in blocks do
			if blk ~= except then
				render(blk)
			end
		end
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
		local rows = model.rows(
			d,
			any,
			bind.pane_sets(binding),
			transport.status_by_id(link, now),
			sh.ui,
			transport.health(link, now)
		)
		sh.ui.selection = model.clamp_selection(rows, sh.ui.selection, d)
		snap_rows = rows
		return rows
	end

	local dispatch: (blk: Copy, ev: keys.Event) -> boolean

	-- Types `text` and Enter into the pane bound to deck id `id` (the host's own pane, picked from its bindings). The
	-- caller has already saved the deck, so a reload between the save and this call cannot send twice.
	local function type_into(id: string, text: string): (boolean, string?)
		local pane = bind.pane_for(binding, ensure(), id)
		if pane == nil then
			return false, "pane gone"
		end
		return compat.pane_write(pane, text .. "\r")
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
				if not send(blk, e.verb, e.fields or {}) then
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
			rows = rows,
			cursor = sh.caret.cursor,
			host = d.session.host,
			h = if newest ~= nil then newest.h else nil,
			health = health,
			age_ms = transport.age(link, now),
			row_age = transport.row_ages(link, now),
			tally = model.tally(d, transport.status_by_id(link, now), health),
			version = transport.version(link, now),
			dupb = blk.status.latest.dupb,
			readonly = readonly,
			load_banner = load_banner,
			save_error = save_error,
			cols = compat.cols(blk.cx) or 32,
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

	local function step()
		touch()
		local now, w = compat.now(), wall()
		local d, bound = bind.apply_queued(binding, ensure())
		for _, id in bound do
			requests.clear_start(ledger, id)
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
		local changed = commit(d)
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

		if next(blocks) == nil then
			return
		end
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

	-- The spawn filter: string work only, never kv; the binding is applied on the next tick. A second omp for an
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
