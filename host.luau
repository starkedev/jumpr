--!strict
-- Host entry, run by every machine's daemon (its block, lens and hook handlers). Wiring only: the logic lives in
-- lib/host/ and lib/shared/. The deck data, the binding cache, the request bookkeeping and the list state are
-- module-level, so the host VM keeps them while copies of the list close and open (hide and show, a daemon restart
-- restoring them): every copy is a thin view of one list state per machine. The deck loads on first use,
-- so the spawn, command_started and pane_exited hooks work before any block opens. Each open copy keeps its own cx,
-- sender (`b`), status route and caret focus; its rows come from the merged status of every copy.
-- Two clocks: tern.now() (monotonic) times status age and replies; wall-clock ms (os.time) stamps what is
-- stored in jumpr.v1 (created_ms, ended_ms, set_ms), which must survive a daemon restart.

local bind = require("./lib/host/bind")
local compat = require("./lib/compat")
local identity = require("./lib/shared/identity")
local input = require("./lib/host/input")
local keys = require("./lib/host/keys")
local model = require("./lib/host/model")
local protocol = require("./lib/shared/protocol")
local queue = require("./lib/host/queue")
local store = require("./lib/host/store")
local transport = require("./lib/host/transport")
local view = require("./lib/host/view")

local TICK_MS = 1000
local GC_EVERY_MS = 60 * 60 * 1000
-- A copy's init hello waits this long: the pusher's first-contact full snapshot normally lands first (~250 ms after
-- the copies open), and the hello is only sent if this copy still has no status of its own.
local HELLO_DELAY_MS = 400
local LABEL_DEBOUNCE_MS = 150
-- A list-mode move onto an agent waits this long for another key before its tab is shown, so a quick run of moves never flips tabs.
local SHOW_PAUSE_MS = 120
-- The pane list and rows built for one burst of views are reused for at most this long.
local SNAPSHOT_TTL_MS = 200

math.randomseed(os.time() + math.floor(tern.now()))

-- One open copy of the list. `missing` counts timer ticks its pane was not listed; `shown` is the clock text of
-- its last view; `focused` says whether its dock input holds the caret focus; `revealed` is the selection key it
-- last scrolled into view, and `reveal_due` asks the next view to reveal it again (a new or resized copy).
type Block = {
	cx: BlockCx,
	pane: number?,
	sender: transport.Sender,
	status: transport.Status,
	focused: boolean,
	missing: number,
	shown: string?,
	revealed: string?,
	reveal_due: boolean,
}

-- The list state one machine has, shared by every copy: the keys' UI (selection, search, filter, mode, input,
-- show_src, notice, show_pending) and the dock input's caret (nil: at the end) for the text `edit_text`.
type Shared = { ui: keys.UI, cursor: number?, edit_text: string? }

local deck: store.Deck? = nil
local readonly = false
local load_banner: string? = nil
local save_error: string? = nil
local binding = bind.new()
local link = transport.new()
local blocks: { [Block]: true } = {}
local shared: Shared? = nil
local last_gc = tern.now()
local label_timer = false
local show_gen = 0

local function wall(): number
	return os.time() * 1000
end

local function rand(n: number): number
	return math.random(n)
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
	local fresh: Shared = { ui = keys.new_ui(saved), cursor = nil, edit_text = nil }
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
local snap_panes: { compat.PaneItem }? = nil
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
local function drop(blk: Block)
	blocks[blk] = nil
	transport.unregister(link, blk.status)
	touch()
end

-- A copy joins both, again if a view or key arrives after it was dropped; a copy that opens while the shared input
-- is open gets the caret too.
local function adopt(blk: Block)
	if blocks[blk] then
		return
	end
	blocks[blk] = true
	transport.register(link, blk.status)
	touch()
	sync_focus()
end

local function render(blk: Block)
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
local function render_others(except: Block)
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
			tern.timer(0, function()
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
local function sync_reveal(blk: Block, f: view.Frame)
	local id, key = view.reveal(f.rows, f.ui.selection, blk.revealed, blk.reveal_due)
	blk.revealed, blk.reveal_due = key, false
	if id == nil then
		return
	end
	tern.timer(0, function()
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
local function send(blk: Block, verb: string, fields: { [string]: string }): boolean
	local url, d = transport.request(link, blk.sender, ensure(), readonly, verb, fields, tern.now(), new_uid)
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
local function panes_now(): { compat.PaneItem }?
	local now = tern.now()
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
	local now = tern.now()
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

local dispatch: (blk: Block, ev: keys.Event) -> boolean

-- Types `text` and Enter into the pane bound to deck id `id` (the host's own pane, picked from its bindings). The
-- caller has already saved the deck, so a reload between the save and this call cannot send twice.
local function type_into(id: string, text: string): (boolean, string?)
	local pane = bind.pane_for(binding, ensure(), id)
	if pane == nil then
		return false, "pane gone"
	end
	return compat.pane_write(pane, text .. "\r")
end

-- Types `text` into agent `id` once the deck that records the send is saved. If kv could not take that save,
-- nothing is typed (a restart would read the old deck and send it again). Clears the id's `seen_working` first.
local function type_saved(id: string, text: string): (boolean, string?)
	if save_error ~= nil then
		return false, "jumpr data not saved"
	end
	transport.sent(link, id)
	return type_into(id, text)
end

-- Types the held messages that are due: each is deleted from the queue and its record stamped `last_send_ms`, the
-- deck is saved, and only then is the text typed (`type_saved`). A failed write keeps the message held with its
-- error, for the next idle. True when anything changed.
local function flush_due(due: { queue.Due }): boolean
	local changed = false
	for _, item in due do
		local current = ensure()
		local held = current.queue[item.id]
		if held ~= nil then
			local _, marked = queue.mark_sent(current.queue, current, item.id, wall())
			commit(marked)
			changed = true
			local ok, err = type_saved(item.id, held.text)
			if ok then
				list().ui.notice = "queued message sent"
			else
				local failed = store.clone(ensure())
				failed.queue = queue.mark_failed(failed.queue, item.id, held, tostring(err))
				commit(failed)
				list().ui.notice = "queued message for "
					.. model.agent_label(failed, item.id)
					.. " not sent on "
					.. model.host_label(failed)
					.. ": "
					.. tostring(err)
			end
		end
	end
	return changed
end

-- Arms the one 120 ms timer a list-mode move waits on (a newer move replaces it); when it fires, `show_due` goes
-- back through keys.reduce for that copy, which asks the window to show the agent's tab only if no other key
-- followed.
local function arm_show(blk: Block, id: string)
	show_gen += 1
	local gen = show_gen
	tern.timer(SHOW_PAUSE_MS, function()
		if gen ~= show_gen then
			return
		end
		local target: Block? = if blocks[blk] then blk else next(blocks)
		if target ~= nil and dispatch(target, { kind = "show_due", id = id }) then
			render_all()
		end
	end)
end

-- Runs keys.reduce's effects in order; true when one of them is `render` or a request could not be sent. A
-- `check_folder` is answered on this machine at once, and its answer goes back through keys.reduce once the rest
-- of these effects have run.
local function run(blk: Block, effects: { keys.Effect }): boolean
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
				if blocks[blk] and dispatch(blk, { kind = "git_root", folder = folder, common_dir = common_dir }) then
					render_all()
				end
			end)
		elseif e.kind == "check_folder" and e.folder ~= nil then
			local ok = compat.is_dir(e.folder)
			table.insert(answers, {
				kind = "folder_checked",
				purpose = e.purpose,
				folder = e.folder,
				ok = ok,
				gid = e.gid,
				id = e.id,
				text = e.text,
			})
		elseif e.kind == "write" and e.id ~= nil then
			-- `o`: the record's `last_send_ms` was saved by the `save_kv` just before this effect.
			local id: string = e.id
			local text = e.text or ""
			local ok, err = type_saved(id, text)
			if not ok then
				local d = ensure()
				list().ui.notice = "message for "
					.. model.agent_label(d, id)
					.. " not sent on "
					.. model.host_label(d)
					.. ": "
					.. tostring(err)
				commit(queue.unsent(d, id, text, e.prev, tostring(err), wall()))
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
dispatch = function(blk: Block, ev: keys.Event): boolean
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
	if sh.ui.mode ~= "input" then
		sh.cursor, sh.edit_text = nil, nil
	elseif sh.ui.text ~= sh.edit_text then
		sh.cursor, sh.edit_text = nil, sh.ui.text
	end
	sync_focus()
	return rendered
end

-- The input line edited at the caret: keys gets the whole new line as an edit event. True when the view changed.
local function edit_line(blk: Block, text: string, cursor: number): boolean
	local sh = list()
	local moved = cursor ~= input.clamp_cursor(sh.ui.text, sh.cursor)
	sh.cursor, sh.edit_text = cursor, text
	local rendered = dispatch(blk, { kind = "edit", text = text })
	return rendered or moved
end

local function frame(blk: Block, rows: { model.Row }): view.Frame
	local d = ensure()
	local sh = list()
	local now = tern.now()
	local newest = transport.newest(link)
	local health = transport.health(link, now)
	return {
		ui = sh.ui,
		rows = rows,
		cursor = sh.cursor,
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

local def: BlockDef<Block> = {
	features = { "edit" :: "edit" },

	init = function(cx: BlockCx, args: { string }, saved: any): Block
		local now = wall()
		commit(store.gc(ensure(), now))
		local name, host = protocol.parse_launch_args(args or {})
		local d, notice = model.apply_launch(ensure(), name, host, saved ~= nil, now)
		commit(d)
		if notice ~= nil then
			tern.log.warn("jumpr: " .. notice)
		end
		local sh = state_for(saved)
		if notice ~= nil then
			sh.ui.notice = notice
		end
		local s: any = if type(saved) == "table" then saved else {}
		local blk: Block = {
			cx = cx,
			pane = compat.pane_of(cx),
			sender = transport.new_sender(s.uid, d, readonly, new_uid),
			status = transport.new_status(),
			focused = false,
			missing = 0,
			shown = nil,
			revealed = nil,
			reveal_due = true,
		}
		adopt(blk)
		tern.timer(HELLO_DELAY_MS, function()
			if blocks[blk] and blk.status.last_ms == nil and not send(blk, "hello", {}) then
				render(blk)
			end
		end)
		return blk
	end,

	view = function(blk: Block, cx: BlockCx): BlockView
		blk.cx = cx
		adopt(blk)
		local f = frame(blk, rows_for())
		blk.shown = view.clock_key(f)
		sync_reveal(blk, f)
		return view.view(f)
	end,

	title = function(_blk: Block): string?
		return view.title(if deck ~= nil then deck.session.host else nil)
	end,

	key = function(blk: Block, key: Key, cx: BlockCx): boolean?
		blk.cx = cx
		local sh = list()
		local ev = key_event(key)
		local rendered: boolean
		local text, cursor = nil, nil
		if sh.ui.mode == "input" then
			text, cursor = input.key(sh.ui.text, sh.cursor, ev)
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
	end,

	event = function(blk: Block, ev: UiEvent, cx: BlockCx)
		blk.cx = cx
		local sh = list()
		if ev.ev == "action" and ev.act == view.CLICK then
			-- A click on a row (view.clicked maps its node id back to it) goes through keys.reduce like a key, so
			-- every copy follows it as it follows keys.
			local row = view.clicked(ev.id)
			if row ~= nil and dispatch(blk, { kind = "click", gid = row.gid, id = row.id }) then
				render_all()
			end
		elseif ev.ev == "action" then
			touch()
			local out = transport.on_action(link, blk.status, ev, {
				deck = ensure(),
				readonly = readonly,
				b = blk.sender.b,
				now = tern.now(),
				wall = wall(),
				io = compat,
				data_dir = tern.plugin.data,
				binding = function(): any
					return bind.dump(binding)
				end,
				sets = bind.pane_sets(binding),
				skip = keys.editing(sh.ui),
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
			if changed or out.render or out.notice ~= nil or failed then
				render_all()
			end
		elseif ev.ev == "edit" and sh.ui.mode == "input" then
			local text, cursor = input.apply_edit(sh.ui.text, ev)
			if text ~= nil and cursor ~= nil and edit_line(blk, text, cursor) then
				render_all()
			end
		end
	end,

	save = function(blk: Block): any
		local s = keys.saved_ui(list().ui)
		return {
			uid = blk.sender.b,
			selection = s.selection,
			search = s.search,
			filter = s.filter,
			show_src = s.show_src,
		}
	end,

	resize = function(blk: Block, _cols: number, _rows: number, cx: BlockCx)
		blk.cx = cx
		blk.reveal_due = true
	end,
}

tern.block.define("list", def)

-- Host hooks --------------------------------------------------------------------------------------------------------

-- The spawn filter: string work only, never kv; the binding is applied on the next timer tick.
tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	touch()
	local ok, err = pcall(bind.on_spawn, binding, deck, spec)
	if not ok then
		transport.note_error(link, "spawn hook: " .. tostring(err))
	end
	return nil
end)

tern.on("command_started", function(ev: CommandStartedEvent, _cx: EffectCx)
	touch()
	bind.on_command_started(binding, ensure(), ev)
end)

tern.on("pane_exited", function(ev: PaneExitedEvent, _cx: EffectCx)
	touch()
	if commit(bind.on_exited(binding, ensure(), ev, wall())) then
		render_all()
	end
end)

-- A title or cwd change on a bound pane can change a row's default label: render once the burst settles.
local function label_changed(pane: number)
	if label_timer or not bind.bound(binding, pane) then
		return
	end
	label_timer = true
	tern.timer(LABEL_DEBOUNCE_MS, function()
		label_timer = false
		touch()
		render_all()
	end)
end

tern.on("title", function(ev: TitleEvent, _cx: EffectCx)
	label_changed(ev.pane)
end)

tern.on("cwd", function(ev: CwdEvent, _cx: EffectCx)
	label_changed(ev.pane)
end)

-- The host timer ----------------------------------------------------------------------------------------------------

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
	local now, w = tern.now(), wall()
	local d, bound = bind.apply_queued(binding, ensure())
	for _, id in bound do
		transport.clear_start(link, id)
	end
	local expired, notices = transport.expire(link, d, now, w)
	d = bind.expire_starts(binding, expired, w)
	if now - last_gc >= GC_EVERY_MS then
		last_gc = now
		d = store.gc(d, w)
	end
	local changed = commit(d)
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

local function tick()
	local ok, err = pcall(step :: () -> ...any)
	if not ok then
		transport.note_error(link, "timer: " .. tostring(err))
		tern.log.warn("jumpr: timer: " .. tostring(err))
	end
	tern.timer(TICK_MS, tick)
end

tern.timer(TICK_MS, tick)
