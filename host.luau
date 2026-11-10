--!strict
-- Host entry, run by every machine's daemon. Wiring only: it registers the list block and the host hooks, and hands
-- each of their inputs to the machine's list (lib/host/runtime.luau), which holds all the state and logic and reaches
-- the machine through compat. The block's nodes are built here from the list's frame (`view.view`).

local compat = require("./lib/compat")
local runtime = require("./lib/host/runtime")
local view = require("./lib/host/view")

local TICK_MS = 1000

math.randomseed(os.time() + math.floor(tern.now()))

local list = runtime.new(compat, function(n: number): number
	return math.random(n)
end)

local def: BlockDef<runtime.Copy> = {
	features = { "edit" :: "edit" },

	init = function(cx: BlockCx, args: { string }, saved: any): runtime.Copy
		return list.open(cx, args, saved)
	end,

	view = function(blk: runtime.Copy, cx: BlockCx): BlockView
		return view.view(list.frame(blk, cx))
	end,

	title = function(_blk: runtime.Copy): string?
		return list.title()
	end,

	key = function(blk: runtime.Copy, key: Key, cx: BlockCx): boolean?
		return list.key(blk, key, cx)
	end,

	event = function(blk: runtime.Copy, ev: UiEvent, cx: BlockCx)
		list.event(blk, ev, cx)
	end,

	save = function(blk: runtime.Copy): any
		return list.saved(blk)
	end,

	resize = function(blk: runtime.Copy, _cols: number, _rows: number, cx: BlockCx)
		list.resized(blk, cx)
	end,
}

tern.block.define("list", def)

-- One omp per agent: a second start of an agent this machine already runs spawns a line saying so instead.
tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	local instead = list.spawn(spec)
	if instead == nil then
		return nil
	end
	return { program = instead.program, args = instead.args, cwd = spec.cwd, env = spec.env }
end)

tern.on("command_started", function(ev: CommandStartedEvent, _cx: EffectCx)
	list.command_started(ev)
end)

tern.on("pane_exited", function(ev: PaneExitedEvent, _cx: EffectCx)
	list.pane_exited(ev)
end)

tern.on("title", function(ev: TitleEvent, _cx: EffectCx)
	list.label_changed(ev.pane)
end)

tern.on("cwd", function(ev: CwdEvent, _cx: EffectCx)
	list.label_changed(ev.pane)
end)

local function tick()
	list.tick()
	tern.timer(TICK_MS, tick)
end

tern.timer(TICK_MS, tick)
