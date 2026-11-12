# Changelog

All notable changes to Jumpr are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).
Update with `tern plugin install github.com/starkedev/jumpr --force` on each machine.

## [Unreleased]

## [0.1.4] - 2026-11-12

On Linux and Windows the jumpr key now works out of the box: it is Ctrl+Alt+J there, since Tern's own Super+J joins lines in its editor.
macOS keeps ⌘J.
The README gains a "Change the keys" section showing how to give Jumpr's commands chords of your own.

### Added

- The README has a "Change the keys" section: Jumpr's three chords are ordinary Tern keybinds, so `"ctrl+alt+k": "plugin.jumpr.toggle_focus"` under `keybinds` in Tern's `settings.json`, then "Reload settings", makes `ctrl+alt+k` the jumpr key.

### Changed

- On Linux and Windows the default chords are now Ctrl+Alt+J (the jumpr key), Ctrl+Alt+Shift+J (hide the list) and Ctrl+Alt+; (last tab), so the jumpr key works out of the box: Tern's own Win/Super+J joins lines in its editor and left Jumpr's Super+J out, and tiling window managers take Super chords.
  macOS keeps ⌘J, ⌘⇧J and ⌘\.

## [0.1.3] - 2026-11-10

Filters now combine: `1` `2` `3` `4`, or Option+click on a count tile, add a status to the filter or drop it.
So `2` then `3` shows the agents waiting for you and the running ones together, and every tile in the filter is outlined.
A plain click and `! @ # $` still show one status only.
Tested with Tern 0.9.13 and 0.9.14 windows, on hosts running Tern 0.9.10, 0.9.13 and 0.9.14.

### Added

- Filters combine: `1` `2` `3` `4` add error, waiting, running or idle to the filter, or drop it, so `2` then `3` shows waiting and running agents together.
  Option+click (alt+click) on a count tile does the same; a plain click and `! @ # $` still show one status only.
  Every tile in the filter is outlined, the head line names them all (`filter @ waiting + # running`), the `?` menu lists the new keys, and dropping the last one clears the filter.

## [0.1.2] - 2026-11-10

The count tiles at the top of the list are now clickable, each as its filter key.
With two computers' Tern windows on one machine, `n` starts one agent, not two, and statuses no longer flicker between the windows.
An agent you park in Tern stays on the list as `in no tab`, and `Enter` brings it back into a tab of its own.
The machine running the agents now lets only one omp run per agent, whoever starts the second one.
Tested with Tern 0.9.13 windows, on hosts running Tern 0.9.10 and 0.9.13.

### Added

- The four count tiles at the top of the list (error, waiting, running, idle) are clickable: a click turns on that tile's filter, exactly as its key (`!` `@` `#` `$`) does, a click on the outlined tile clears it, and a click on another tile switches to it.
  A tile with nobody in it still filters, and the list says nothing matches.
  Like clicks on rows, tile clicks only act in the list itself.

### Changed

- New README screenshots: the list beside a waiting agent's tab, the command menu, and a parked agent's row, plus a short recording of moving through the list, going into an agent and back with `cmd+\`.

### Fixed

- `cmd+\` now toggles between the last two tabs you actually worked in: moving through the list with `j`/`k` (which shows each agent's tab) no longer counts as visiting those tabs, so the chord goes back to the tab you last worked in rather than the last agent you scrolled past. Pressed from the list, it goes to the tab you last worked in, or to the one before that when you are already in it.
- With two computers' Tern windows attached to the same machine, an agent's status no longer flickers when you open a fresh list, and no longer settles on idle when it is waiting. When the windows disagree (one has not seen the agent's finished turn yet, the other attached after it), the list follows the window that most recently saw the agent change, and the more urgent status when neither did. An agent one window no longer lists stays on the list while another window still reports it.
- When Jumpr cannot save its data (for example when the plugin's data folder is read-only), the list now says why in one line, such as "jumpr data not saved on devbox: Permission denied (os error 13)", instead of following it with a Lua stack traceback. Every other error Jumpr passes on from a Tern call (in the list, a toast or the diagnostics) is cut to its one-line reason the same way, and the full error, traceback included, goes to Tern's log.
- Restarting an exited agent with Enter no longer leaves its row stuck on `error · duplicate` until you close the old pane by hand.
  The old pane, whose program has exited, stays open so you can still read what it printed, but it no longer counts as a second copy of the agent: the row shows the restarted agent's status, Enter jumps to it, and held messages are typed into it.
  Two running panes for one agent are still flagged as a duplicate.
- A copy of the list that the window cannot reach (its block never started on the other machine, so Tern answers "no program runs in that pane") no longer floods Tern's log with two lines and a traceback every second.
  The window says so once per copy, then tries it less and less often (up to every 30 s); once it answers again it gets the whole list at once and its normal updates.
  Tern's log keeps one full copy of each error's traceback per session.
- An agent you park in Tern (it keeps running in no tab) now says `in no tab` on its row, beside its status.
  `Enter` on it brings it back into a tab of its own, with its copy of the list, and goes to it; before, `Enter` dropped it into whichever tab you were looking at, beside another agent.
  Moving onto its row leaves your tabs as they are, where before the list showed a "has no tab" error.
  When Tern cannot bring it back (an older session daemon, including one that answers as if it had and moves nothing), the list says why in one line and the agent stays parked.
  An agent with one pane parked and another in a tab is still flagged as a duplicate.
- With two computers' Tern windows attached to the same machine, `n` no longer starts the agent twice (one omp in a tab and a second one in no tab, its row stuck on `duplicate`).
  Both windows still act on the start, but the machine now lets only the first omp for an agent run: the second pane prints that the agent already runs and closes, and the list says "a second start was stopped".
  The same guard stops a new pane started by hand with the session folder of an agent that is already running; a restart of an exited agent is not affected.

## [0.1.1] - 2026-11-09

### Added

- README screenshots.

### Changed

- README credits agent-deck as the inspiration for the key layout and workflow.

### Fixed

- With two computers' Tern windows attached to the same machine, the list's head no longer flips between their two names for it (such as `devbox` and `me@devbox`); the name changes only when no attached window uses it any more.
- With two computers' windows attached, a jump, start, stop or other request from the list acts only in the window where you pressed the key, never in both, and the other computer shows no "unknown machine" toast.
- A window whose focus sits in another machine's list no longer takes a request from this machine's list for that other machine (a false "agent … is not running on …" toast); a request is acted on only for the list that sent it.
- In a narrow list the `?` menu's title is no longer cut off: it reads just "commands 1/22", with the keys on a dim line of their own that wraps rather than cuts, and the key legend's spacing is tighter so it fits a narrower pane on one line.
- After `cmd+\` (⌘\, Super+\) jumps to your last tab, the list now highlights that tab's agent instead of staying on the row it was on; for an agent folded away it highlights the group's header, and it stays put when a search or filter hides the agent or an input, question, picker or menu is open.

## [0.1.0] - 2026-11-09

The first release.
Tested on Tern 0.9.10 and 0.9.11.

### Added

#### The list

- A list of a machine's omp agents, grouped by project folder, in a copy on the left of every tab of one Tern session per machine.
- Count tiles for error, waiting, running and idle agents, a card per group with a coloured count per status, and a key legend.
- Each agent row shows its status, how long it has been in it, its folder when it is not the group's, and what is waiting on it.
- Status comes from Tern's own agent tracking: running, waiting for you, idle, error, stopped.
- Moving the selection onto a live agent brings its tab to the front after a 120 ms pause, so the agent itself is the preview.
- Agents on remote machines Tern is attached to work as local ones do, one list per machine.

#### Keys and mouse

- `cmd+j` (⌘J, Super+J) toggles the list: show and focus it, or go back to your pane and hide it.
- `cmd+shift+j` hides the list from anywhere; `cmd+\` jumps to the last tab's agent pane and back.
- `j`/`k` and arrows move, `J`/`K` step between groups, `G`/`End`/`Home` jump to the ends.
- `Enter` focuses an agent, restarts an exited one in its own session, or folds a group; `Tab`, `h` and `l` fold too.
- `n` starts an agent in the group's folder, `g` makes a group from an existing folder, named after its git repository.
- `r` renames an agent and its tab, `m` moves it to another group, `V` reorders agents within a group or reorders the groups.
- `d` stops an agent or deletes a group after a `y/n`, keeping the agent's conversation on disk.
- `o` sends a message now; `q` queues one, sent once the agent is idle.
- `/` searches labels, folders and group names; `!` error, `@` waiting, `#` running and `$` idle filter by status (Shift+1 to Shift+4, in priority order), `0` clears.
- `i` shows where each row's status comes from.
- `?` opens a command menu listing every list key with what it does; the count tiles show each filter symbol (! @ # $) beside its count, in the same order, and the head line names the active filter in words.
- Clicking a group header folds it; clicking an agent selects it.
- Palette commands for every chord, plus "Jumpr: diagnostics", which copies the paths of a window dump and a host dump.

#### Under the hood

- Agents are recognised by the omp session folder Jumpr starts them with, `~/.omp/deck/<id>`, so restarting one resumes its conversation.
- The host half keeps the list in Tern's per-plugin `kv` store; the window half never writes it.
- Every message between the halves carries a protocol version, and a mismatch shows a banner naming the machine to update.
- `scripts/check.sh` runs stylua, the unit suites, a strict `luau-lsp` type check and design-rule checks.

[Unreleased]: https://github.com/starkedev/jumpr/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/starkedev/jumpr/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/starkedev/jumpr/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/starkedev/jumpr/releases/tag/v0.1.2
[0.1.1]: https://github.com/starkedev/jumpr/releases/tag/v0.1.1
[0.1.0]: https://github.com/starkedev/jumpr/releases/tag/v0.1.0
