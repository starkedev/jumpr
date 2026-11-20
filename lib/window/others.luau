--!strict
-- "Jumpr: hide or show other panes": the focused tab down to its core, the copy of the list and the tab's agent, and
-- back again. A hide parks every other tiled pane of the tab (its extras: shells, editors, a second agent) in Tern's
-- parked pile, where their programs keep running, wherever focus is in the tab, and remembers which panes it parked and
-- the tab's split tree before it; focus that was in an extra goes to the agent. Pressed again in that tab, it deals
-- those panes back beside the panes they sat beside (`plan`) and gives the splits it made their old shares, focus
-- staying where it is. Panes already in the tab move only while the tab is just as the hide left it (a copy of the list
-- closed and opened again since counts as the same); once the user has changed it, nothing in it moves. A copy of the
-- list is never moved or resized by name: the panes come back around it. Floating blocks are never touched, a pane
-- Jumpr did not park is never dealt back, a pane that closed meanwhile is skipped, and a zoomed tab (zen mode included)
-- is refused with a toast. The memory is this window's own, one per tab, and never in kv: a plugin reload loses it,
-- and the panes then stay in Tern's parked pile, from which Tern's Parked panes brings them back.

local compat = require("../compat")
local protocol = require("../shared/protocol")
local agents = require("./agents")
local block = require("./block")
local diag = require("./diag")
local zen = require("./zen")

local M = {}

-- A tab's split tree as a hide recorded it: a pane at a leaf; at a split, its orientation, its first side's share and
-- its two sides ([1] left or top, [2] right or bottom).
export type Tree = { pane: number?, split: ("right" | "down")?, ratio: number?, [number]: Tree }
-- One move of a rebuild: `pane`, first dealt back from the parked pile when `unpark`, goes beside `target` on its `dir`
-- side. With no target it is only dealt back (beside the tab's focused block): the first pane of a tab that kept none.
export type Step = { pane: number, unpark: boolean, target: number?, dir: Dir? }
-- A split a rebuild makes, to be given back its recorded share: `a` is a pane on its first side, `b` one on its second,
-- and `step` the step that makes it.
export type Sized = { split: "right" | "down", ratio: number, a: number, b: number, step: number }
export type Plan = { steps: { Step }, sized: { Sized } }

-- What a hide parked in one tab, in reading order, the tab's split tree before it, and the copies of the list that tree
-- held, in reading order.
type Hidden = { tree: Tree, panes: { number }, copies: { number } }

local hidden: { [number]: Hidden } = {}

-- The moves leave the focus where it is.
local STAY: Reveal = { focus = false }
-- Tern resizes by cells and records shares, so a resize first moves the divider this many cells to measure the share
-- a cell is worth on that split.
local PROBE_CELLS = 4
-- A share this close to the recorded one is left as it is: well under a cell of any tab.
local NEAR = 0.002

local function key(id: number): string
	return string.format("%.0f", id)
end

-- A split tree as Tern reports it, copied with only what a rebuild reads; nil when it is none. A split missing a side
-- stands for the side it has.
local function copy_tree(node: any): Tree?
	if typeof(node) ~= "table" then
		return nil
	end
	if typeof(node.pane) == "number" then
		return { pane = node.pane }
	end
	local first, second = copy_tree(node[1]), copy_tree(node[2])
	if first == nil or second == nil then
		return first or second
	end
	local split: "right" | "down" = if node.split == "down" then "down" else "right"
	local out: Tree = { split = split, ratio = if typeof(node.ratio) == "number" then node.ratio else 0.5 }
	out[1], out[2] = first, second
	return out
end

-- The panes of `node` in reading order (left and top first), added to `out`.
local function leaves(node: Tree, out: { number }): { number }
	local pane = node.pane
	if pane ~= nil then
		table.insert(out, pane)
	else
		leaves(node[1], out)
		leaves(node[2], out)
	end
	return out
end

-- The core pane a hide keeps beside the copies of the list, among the tab's tiled panes `tiled`: the tab's agent, a
-- deck agent pane (`is_agent`), wherever focus is, so the panes around it are the extras. Of two agents or more, the
-- focused one, else the one the jumpr key goes back to (`back`), else the lowest, which the tab is named after while
-- the list has focus. A tab with no agent keeps the focused pane when it is one of them and no copy, else `back` when
-- it is one, else its lowest pane that is no copy (focus in the list). nil when every tiled pane is a copy.
function M.keeper(
	tiled: { number },
	focused: number?,
	back: number?,
	is_copy: (number) -> boolean,
	is_agent: (number) -> boolean
): number?
	local function here(pane: number?): boolean
		return pane ~= nil and table.find(tiled, pane) ~= nil and not is_copy(pane)
	end
	local agent: number? = nil
	local other: number? = nil
	for _, pane in tiled do
		if is_copy(pane) then
			continue
		end
		if is_agent(pane) then
			if agent == nil or pane < agent then
				agent = pane
			end
		elseif other == nil or pane < other then
			other = pane
		end
	end
	if agent ~= nil then
		if here(focused) and is_agent(focused :: number) then
			return focused
		end
		if here(back) and is_agent(back :: number) then
			return back
		end
		return agent
	end
	if here(focused) then
		return focused
	end
	if here(back) then
		return back
	end
	return other
end

-- `node` with only the panes in `keep`, a split left with one side collapsing into that side; nil when it keeps none.
local function restrict(node: Tree, keep: { [number]: boolean }): Tree?
	local pane = node.pane
	if pane ~= nil then
		return if keep[pane] then node else nil
	end
	local first, second = restrict(node[1], keep), restrict(node[2], keep)
	if first == nil or second == nil then
		return first or second
	end
	local out: Tree = { split = node.split, ratio = node.ratio }
	out[1], out[2] = first, second
	return out
end

-- Whether two trees hold the same panes in the same splits, whatever their shares.
local function same_shape(x: Tree?, y: Tree?): boolean
	if x == nil or y == nil then
		return x == nil and y == nil
	end
	if x.pane ~= nil or y.pane ~= nil then
		return x.pane == y.pane
	end
	return x.split == y.split and same_shape(x[1], y[1]) and same_shape(x[2], y[2])
end

-- `node` with each pane `swap` names replaced by the pane it maps to.
local function renamed(node: Tree, swap: { [number]: number }): Tree
	local pane = node.pane
	if pane ~= nil then
		local to = swap[pane]
		return if to ~= nil then { pane = to } else node
	end
	local out: Tree = { split = node.split, ratio = node.ratio }
	out[1], out[2] = renamed(node[1], swap), renamed(node[2], swap)
	return out
end

-- How to deal back what a hide parked. `tree` is the tab's split tree before the hide, `now` its tree now (nil when
-- nothing is tiled there), `parked` the panes to deal back, `hid` every pane the hide parked, and `copies` the copies
-- of the list in the tab now.
-- Each side of a recorded split with none of its panes in the tab now comes back beside a pane of the other side,
-- outermost split first, with its own panes placed around the first of them. Panes in the tab move only while the tab
-- is just as the hide left it (`intact`), and never a copy of the list: then a side that faced a hidden one comes back
-- around its copy of the list when it holds one, the other panes placed beside the copy, so the tree comes back exactly
-- with the copy left where it is; a side with no copy comes back around its pane facing the hidden side. A tab holding
-- a pane the tree did not (opened since), a pane the hide parked (dealt back by hand), two copies of the list, or its
-- panes in other splits than the tree had them, is not intact, and no pane in it moves: a hidden side comes back beside
-- the facing pane alone. The facing pane lies along the divider, and across a split the other way in the larger side,
-- unless only the smaller one holds a pane that is no copy. A pane neither in the tab nor in `parked` (closed since)
-- is left out, its split collapsing into the other side. Pure.
function M.plan(
	tree: Tree,
	now: Tree?,
	parked: { [number]: boolean },
	hid: { [number]: boolean },
	copies: { [number]: boolean }
): Plan
	local present: { [number]: boolean } = {}
	local intact = true
	local listed = 0
	if now ~= nil then
		for _, pane in leaves(now, {}) do
			present[pane] = true
			if hid[pane] then
				intact = false
			end
			if copies[pane] then
				listed += 1
			end
		end
	end
	intact = intact and listed <= 1 and same_shape(now, restrict(tree, present))
	local steps: { Step } = {}
	local sized: { Sized } = {}
	local shows: { [Tree]: number } = {}
	local stays: { [Tree]: number } = {}

	-- How many panes of `node` show once rebuilt, and how many of those are in the tab now.
	local function count(node: Tree): (number, number)
		local known = shows[node]
		if known ~= nil then
			return known, stays[node]
		end
		local s, h = 0, 0
		local pane = node.pane
		if pane ~= nil then
			if present[pane] then
				s, h = 1, 1
			elseif parked[pane] then
				s = 1
			end
		else
			local s1, h1 = count(node[1])
			local s2, h2 = count(node[2])
			s, h = s1 + s2, h1 + h2
		end
		shows[node], stays[node] = s, h
		return s, h
	end

	-- The first pane of `node` in reading order that shows once rebuilt and, when `staying`, is in the tab now.
	local function first(node: Tree, staying: boolean): number?
		local s, h = count(node)
		if s == 0 or (staying and h == 0) then
			return nil
		end
		local pane = node.pane
		if pane ~= nil then
			return pane
		end
		return first(node[1], staying) or first(node[2], staying)
	end

	-- The pane that stands for `node`, which shows: its first in the tab, else its first to deal back.
	local function pick(node: Tree): number
		return (first(node, true) or first(node, false)) :: number
	end

	local function holds(node: Tree, pane: number): boolean
		if node.pane ~= nil then
			return node.pane == pane
		end
		return holds(node[1], pane) or holds(node[2], pane)
	end

	local function axis(node: Tree): "right" | "down"
		return if node.split == "down" then "down" else "right"
	end

	-- The side of a pane on which `node`'s second side (or first) lies.
	local function side(node: Tree, second: boolean): Dir
		if axis(node) == "down" then
			return if second then "down" else "up"
		end
		return if second then "right" else "left"
	end

	-- Whether `node` holds a pane in the tab now that is no copy of the list.
	local function has_other(node: Tree): boolean
		local pane = node.pane
		if pane ~= nil then
			return present[pane] == true and not copies[pane]
		end
		return has_other(node[1]) or has_other(node[2])
	end

	-- The copy of the list among `node`'s panes, nil when it holds none.
	local function copy_in(node: Tree): number?
		local pane = node.pane
		if pane ~= nil then
			return if copies[pane] then pane else nil
		end
		return copy_in(node[1]) or copy_in(node[2])
	end

	-- The pane in the tab of `node`, which holds one, that faces a side lying past `node` across a split of `along`:
	-- past its far edge (right or bottom) when `far`, else past its near one. At a split of `along` that is in the side
	-- touching the edge; at a split the other way in the larger side, unless only the smaller holds a pane that is no
	-- copy of the list; each while it holds a pane in the tab.
	local function facing(node: Tree, along: "right" | "down", far: boolean): number
		local pane = node.pane
		if pane ~= nil then
			return pane
		end
		local a, b = node[1], node[2]
		local _, ha = count(a)
		local _, hb = count(b)
		local first_side: boolean
		if axis(node) == along then
			first_side = not far
		else
			local oa, ob = has_other(a), has_other(b)
			first_side = if oa ~= ob then oa else (node.ratio or 0.5) >= 0.5
		end
		if hb == 0 or (ha > 0 and first_side) then
			return facing(a, along, far)
		end
		return facing(b, along, far)
	end

	-- The pane of `node`, which holds one in the tab, that a side lying past it comes back beside: while the tab is
	-- intact, its copy of the list when it holds one, so the panes placed again around it never include the list; else
	-- its pane facing that side.
	local function anchor(node: Tree, along: "right" | "down", far: boolean): number
		local copy = if intact then copy_in(node) else nil
		return copy or facing(node, along, far)
	end

	local function bring(pane: number, target: number?, dir: Dir?)
		table.insert(steps, { pane = pane, unpark = not present[pane], target = target, dir = dir })
	end

	-- `node`'s split is made again by the last step, with `a` on its first side and `b` on its second.
	local function made(node: Tree, a: number, b: number)
		table.insert(sized, { split = axis(node), ratio = node.ratio or 0.5, a = a, b = b, step = #steps })
	end

	-- Places every pane of `node` that shows around `rep`, which stands for the whole of `node` now.
	local function place(node: Tree, rep: number)
		if node.pane ~= nil then
			return
		end
		local a, b = node[1], node[2]
		if count(a) == 0 then
			place(b, rep)
		elseif count(b) == 0 then
			place(a, rep)
		elseif holds(a, rep) then
			local other = pick(b)
			bring(other, rep, side(node, true))
			made(node, rep, other)
			place(a, rep)
			place(b, other)
		else
			local other = pick(a)
			bring(other, rep, side(node, false))
			made(node, other, rep)
			place(a, other)
			place(b, rep)
		end
	end

	-- Rebuilds `node`, which holds a pane in the tab now. A side with none comes back beside the anchor of the other;
	-- the other side is then placed again around its anchor while the tab is intact, else only rebuilt in turn.
	local function restore(node: Tree)
		if node.pane ~= nil then
			return
		end
		local a, b = node[1], node[2]
		local sa, ha = count(a)
		local sb, hb = count(b)
		if sa == 0 then
			restore(b)
		elseif sb == 0 then
			restore(a)
		elseif ha > 0 and hb > 0 then
			restore(a)
			restore(b)
		elseif ha > 0 then
			local anchor_pane, other = anchor(a, axis(node), true), pick(b)
			bring(other, anchor_pane, side(node, true))
			made(node, anchor_pane, other)
			place(b, other)
			if intact then
				place(a, anchor_pane)
			else
				restore(a)
			end
		else
			local anchor_pane, other = anchor(b, axis(node), false), pick(a)
			bring(other, anchor_pane, side(node, false))
			made(node, other, anchor_pane)
			place(a, other)
			if intact then
				place(b, anchor_pane)
			else
				restore(b)
			end
		end
	end

	local shown, staying = count(tree)
	if staying > 0 then
		restore(tree)
	elseif shown > 0 then
		local rep = pick(tree)
		bring(rep, nil, nil)
		place(tree, rep)
	end
	return { steps = steps, sized = sized }
end

-- Runs a plan's moves in order and stops at the first Tern refuses: how many moves it finished, and, when one was
-- refused, why and which call it was ("unpark" or "move").
local function run(cx: WindowCx, steps: { Step }): (number, string?, string?)
	for i, step in steps do
		if step.unpark then
			local ok, err = compat.unpark(cx, step.pane, STAY)
			if not ok then
				return i - 1, err, "unpark"
			end
		end
		local target: number?, dir: Dir? = step.target, step.dir
		if target ~= nil and dir ~= nil then
			local ok, err = compat.move(cx, step.pane, target, dir, STAY)
			if not ok then
				return i - 1, err, "move"
			end
		end
	end
	return #steps, nil, nil
end

-- The nodes from `node` down to the leaf of `pane`, appended to `out`; nil when `node` does not hold it.
local function path(node: Tree, pane: number, out: { Tree }): { Tree }?
	table.insert(out, node)
	if node.pane == pane then
		return out
	end
	if node.pane == nil and (path(node[1], pane, out) ~= nil or path(node[2], pane, out) ~= nil) then
		return out
	end
	table.remove(out)
	return nil
end

-- The split of `root` with `a` on its first side and `b` on its second, nil when there is none.
local function split_between(root: Tree, a: number, b: number): Tree?
	local to_a, to_b = path(root, a, {}), path(root, b, {})
	if to_a == nil or to_b == nil then
		return nil
	end
	local i = 1
	while to_a[i + 1] ~= nil and to_a[i + 1] == to_b[i + 1] do
		i += 1
	end
	local node = to_a[i]
	if node.pane ~= nil or to_a[i + 1] ~= node[1] or to_b[i + 1] ~= node[2] then
		return nil
	end
	return node
end

-- The share of the split between `s.a` and `s.b` in `tab` now, and that split; nil when the tab holds no split of that
-- orientation with them on those sides.
local function share_of(cx: WindowCx, tab: number, s: Sized): (number?, Tree?)
	local layout = compat.tab_layout(cx, tab)
	local root = if layout ~= nil then copy_tree(layout.root) else nil
	local node = if root ~= nil then split_between(root, s.a, s.b) else nil
	if node == nil or node.split ~= s.split then
		return nil, nil
	end
	return node.ratio, node
end

-- The panes of `node` along its far edge (right or bottom) across splits of `split` when `far`, else along its near
-- edge (left or top), in reading order.
local function along_edge(node: Tree, split: "right" | "down", far: boolean, out: { number }): { number }
	local pane = node.pane
	if pane ~= nil then
		table.insert(out, pane)
	elseif node.split == split then
		along_edge(if far then node[2] else node[1], split, far, out)
	else
		along_edge(node[1], split, far, out)
		along_edge(node[2], split, far, out)
	end
	return out
end

-- A pane that moves the divider of split `node` (of `split`) when resized, and never a copy of the list (`is_copy`):
-- a pane of the first side along the divider, growing toward it, else one of the second side's, growing back toward
-- it; with the way it grows and whether that grows the first side. nil when only copies touch the divider.
local function divider_pane(node: Tree, split: "right" | "down", is_copy: (number) -> boolean): (number?, Dir, boolean)
	local toward: Dir = if split == "down" then "down" else "right"
	local back: Dir = if split == "down" then "up" else "left"
	for _, pane in along_edge(node[1], split, true, {}) do
		if not is_copy(pane) then
			return pane, toward, true
		end
	end
	for _, pane in along_edge(node[2], split, false, {}) do
		if not is_copy(pane) then
			return pane, back, false
		end
	end
	return nil, toward, true
end

-- Gives a split the rebuild made its recorded share: a first move of `PROBE_CELLS` measures the share a cell is worth
-- there (taken as measured, whichever side's share Tern counts), and one more move covers the rest. It resizes a pane
-- beside the divider that is no copy of the list, so the list is never resized by name; a divider only copies touch
-- is left as it is. A split that is not where the rebuild meant to make it (Tern dealt or moved a pane elsewhere) is
-- logged and left, and so is a divider that does not move.
local function resize_to(cx: WindowCx, tab: number, s: Sized, is_copy: (number) -> boolean)
	local before, node = share_of(cx, tab, s)
	if before == nil or node == nil then
		local between = key(s.a) .. (if s.split == "down" then " above " else " left of ") .. key(s.b)
		diag.error("others", "resize in tab " .. key(tab) .. ": no split puts " .. between)
		return
	end
	if math.abs(s.ratio - before) < NEAR then
		return
	end
	local pane: number?, dir: Dir, grows_first: boolean = divider_pane(node, s.split, is_copy)
	if pane == nil then
		return
	end
	local probe = if (s.ratio > before) == grows_first then PROBE_CELLS else -PROBE_CELLS
	local ok, err = compat.resize(cx, pane, dir, probe)
	local after = if ok then share_of(cx, tab, s) else nil
	if after == nil then
		diag.error("others", "resize in tab " .. key(tab) .. ": " .. (err or "the split is gone"))
		return
	end
	local per_cell = (after - before) / probe
	if per_cell == 0 then
		return
	end
	local cells = math.round((s.ratio - after) / per_cell)
	if cells ~= 0 then
		compat.resize(cx, pane, dir, cells)
	end
end

-- The layout of `tab`; nil, with a toast, when it cannot be read or a block is zoomed over it. A zoomed tab is left
-- to the user: zen mode (this window's copy of the list zoomed for the list's own zen) ends in the list, since
-- unzooming it here would leave the list in zen, showing no agent's tab as the selection moves; Tern's Zoom block
-- ends by running it again.
local function unzoomed(cx: WindowCx, tab: number): TabLayout?
	local layout, err = compat.tab_layout(cx, tab)
	if layout == nil then
		local why = err or "the tab is gone"
		diag.error("others", "read tab " .. key(tab) .. ": " .. why)
		compat.toast(cx, "error", "Jumpr could not read this tab's panes", why)
		return nil
	end
	if not layout.zoomed then
		return layout
	end
	if layout.focus == zen.zoomed_copy() then
		compat.toast(
			cx,
			"info",
			"Jumpr: the list is in zen mode in this tab",
			"Leave zen mode in the list, then try again"
		)
	else
		compat.toast(
			cx,
			"info",
			"Jumpr: a block is zoomed in this tab",
			"Run Zoom block to give the tab back, then try again"
		)
	end
	return nil
end

-- Parks every tiled pane of `tab` (tree `tree`) but its core, the copies of the list and the pane to keep (`keeper`),
-- and remembers them. Returns the pane focus belongs on: the kept pane when focus was in an extra, else the focused
-- pane (on the agent, in the list, or on a floating block).
local function hide(
	cx: WindowCx,
	tab: number,
	tree: Tree,
	focused: number,
	items: { [number]: compat.PaneItem }
): number
	local tiled = leaves(tree, {})
	local function is_copy(pane: number): boolean
		local item = items[pane]
		return item ~= nil and item.block == protocol.BLOCK_KIND
	end
	local host = compat.current_host(cx)
	local back = if host ~= nil then block.back_pane(host.name) else nil
	local keep = M.keeper(tiled, focused, back, is_copy, agents.is_agent)
	local parked: { number } = {}
	local copies: { number } = {}
	local failed: string? = nil
	for _, pane in tiled do
		if is_copy(pane) then
			table.insert(copies, pane)
		elseif pane ~= keep then
			local ok, err = compat.park(cx, pane)
			if ok then
				table.insert(parked, pane)
			elseif failed == nil then
				failed = err
			end
		end
	end
	if #parked > 0 then
		hidden[tab] = { tree = tree, panes = parked, copies = copies }
	end
	if failed ~= nil then
		diag.error("others", "hide in tab " .. key(tab) .. ": " .. failed)
		compat.toast(cx, "error", "Jumpr could not hide every other pane", failed)
	elseif #parked == 0 then
		compat.toast(cx, "info", "Jumpr: no other panes to hide in this tab")
	end
	local extra = keep ~= nil and focused ~= keep and table.find(tiled, focused) ~= nil and not is_copy(focused)
	return if extra then keep :: number else focused
end

-- Deals back what a hide parked in `tab` (`rec`) beside the panes in the tab now (`now`), as `plan` lays it out, and
-- gives the splits it made their old shares. The copies of the list are interchangeable: a copy the hide left that has
-- closed since (the jumpr key closes every copy, and showing the list again opens new ones) stands for a copy in the
-- tab now that the tree never held, in reading order. A move Tern refuses stops the rest, and only the splits made
-- before it are sized; the toast says whether panes are left in Parked panes. False, having done nothing, when none of
-- the hidden panes is still parked: each closed, or was brought back by hand.
local function show(cx: WindowCx, tab: number, now: Tree?, rec: Hidden, items: { [number]: compat.PaneItem }): boolean
	local parked: { [number]: boolean } = {}
	local hid: { [number]: boolean } = {}
	local any = false
	for _, pane in rec.panes do
		hid[pane] = true
		local item = items[pane]
		if item ~= nil and item.parked then
			parked[pane] = true
			any = true
		end
	end
	if not any then
		return false
	end
	local function is_copy(pane: number): boolean
		local item = items[pane]
		return item ~= nil and item.block == protocol.BLOCK_KIND
	end
	local recorded: { [number]: boolean } = {}
	for _, pane in leaves(rec.tree, {}) do
		recorded[pane] = true
	end
	local copies: { [number]: boolean } = {}
	local fresh: { number } = {}
	if now ~= nil then
		for _, pane in leaves(now, {}) do
			if is_copy(pane) then
				copies[pane] = true
				if not recorded[pane] then
					table.insert(fresh, pane)
				end
			end
		end
	end
	local swap: { [number]: number } = {}
	local swapped = false
	for _, pane in rec.copies do
		if not copies[pane] and #fresh > 0 then
			swap[pane] = table.remove(fresh, 1) :: number
			swapped = true
		end
	end
	local plan = M.plan(if swapped then renamed(rec.tree, swap) else rec.tree, now, parked, hid, copies)
	local done, why, refused = run(cx, plan.steps)
	for _, s in plan.sized do
		if s.step <= done then
			resize_to(cx, tab, s, is_copy)
		end
	end
	if why ~= nil then
		-- Still parked: the pane whose unpark Tern refused, and every later pane the plan was to deal back.
		local left = if refused == "unpark" then 1 else 0
		for i = done + 2, #plan.steps do
			if plan.steps[i].unpark then
				left += 1
			end
		end
		local text = if refused == "move"
			then "Jumpr could not put a hidden pane back in its place"
			else "Jumpr could not bring back every hidden pane"
		if left > 0 then
			text ..= "; Parked panes has the rest"
		end
		diag.error("others", "show in tab " .. key(tab) .. ": " .. why)
		compat.toast(cx, "error", text, why)
	end
	return true
end

-- "Jumpr: hide or show other panes", in the tab of the focused pane: brings back what a hide parked there while any
-- of it is still parked, else hides the tab's extras. Focus stays on the pane it was on, unless the hide took that pane
-- away, when it goes to the agent.
function M.toggle(cx: WindowCx)
	local focused = compat.session_focused(cx)
	local tab = if focused ~= nil then compat.session_tab_of(cx, focused) else nil
	if focused == nil or tab == nil then
		compat.toast(cx, "info", "Jumpr: no tab has focus")
		return
	end
	local layout = unzoomed(cx, tab)
	if layout == nil then
		return
	end
	local list, err = compat.session_panes(cx)
	if list == nil then
		diag.error("others", "read panes: " .. tostring(err))
		compat.toast(cx, "error", "Jumpr could not read this window's panes", err)
		return
	end
	local items: { [number]: compat.PaneItem } = {}
	for _, item in list do
		items[item.pane] = item
	end
	local tree = copy_tree(layout.root)
	local rec = hidden[tab]
	hidden[tab] = nil
	local shown = rec ~= nil and show(cx, tab, tree, rec, items)
	local land = focused
	if not shown and tree ~= nil then
		land = hide(cx, tab, tree, focused, items)
	end
	if compat.session_focused(cx) ~= land then
		compat.focus(cx, land)
	end
end

-- `tab_closed`: a tab whose other panes are hidden is gone, and its memory goes too. The panes still parked run on in
-- Tern's parked pile, which a toast says.
function M.tab_closed(cx: WindowCx, tab: number)
	local rec = hidden[tab]
	if rec == nil then
		return
	end
	hidden[tab] = nil
	local n = 0
	for _, pane in rec.panes do
		local item = compat.session_pane(cx, pane)
		if item ~= nil and item.parked then
			n += 1
		end
	end
	if n > 0 then
		compat.toast(
			cx,
			"info",
			"Jumpr: a tab closed while its other panes were hidden",
			(if n == 1 then "1 pane runs on" else n .. " panes run on") .. " in Parked panes"
		)
	end
end

diag.provide("others", function(): any
	local out: { [string]: { string } } = {}
	for tab, rec in hidden do
		local panes: { string } = {}
		for _, pane in rec.panes do
			table.insert(panes, key(pane))
		end
		out[key(tab)] = panes
	end
	return { hidden = out }
end)

return M
