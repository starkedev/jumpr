# Changelog

All notable changes to Jumpr are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).
Update with `tern plugin install github.com/starkedev/jumpr --force` on each machine.

## [Unreleased]

## [0.3.1] - 2026-11-19

### Fixed

- A new Claude agent no longer shows a red "No conversation found with session ID" line when it starts.
  Jumpr now checks whether the agent's conversation exists before it runs `claude`, and resumes it only when it does.
  It looks where Claude keeps its files: in `CLAUDE_CONFIG_DIR` when you set it, and in `~/.claude` otherwise.

## [0.3.0] - 2026-11-18

### Changed

- Claude and Codex now run as their real CLIs, `claude` and `codex`, in the agent's tab, instead of through Tern's ACP chat, so your claude.ai connectors and artifacts work.
  Other agents, such as `copilot`, still start through the ACP chat.
  Install `claude` and `codex` on each machine that runs those agents; they no longer need an ACP adapter.
- Restart running Claude agents to get your connectors: exit each one in its tab, then press Enter on its row.
  It comes back in the real CLI, in the same conversation when Jumpr knew its id, and through Claude's own conversation picker otherwise.
  Codex agents started through the ACP chat come back in the real CLI too, through Codex's own picker.
- Restarts are exact: a Claude agent always returns to its own conversation, by an id Jumpr gives it when you start it, and on Linux it follows a `/clear` to the new one.
  A Codex agent returns to its own conversation once Jumpr has found it in Codex's files, after the first message; until then a restart opens Codex's own picker, and Jumpr learns the one you pick.
  Neither ever falls back to "the last conversation in this folder", which could be another agent's.
- Claude and Codex rows show running, waiting for you and idle from the CLI's own status, as omp's do.
- `o` and `q` on a Claude or Codex agent type only when the agent reports itself idle, the text and then Enter; at any other time the message is held until it does, so it never lands in a startup screen, a permission question or a picker.
- Update Jumpr on every machine together: the window's machine and the agents' machine must both run this version.
  The two halves now speak a new protocol version, and a mismatch shows a banner naming the machine to update.
  No stored data changes: your groups, labels and agents carry over.

  Known limits: Codex's `/new` is not followed; a `CODEX_HOME` outside `~/.codex` is ignored, so Codex restarts go through the picker; a Codex you start by hand in the same folder within minutes of a Codex agent can be mistaken for its conversation; and after a restart of Tern's session daemon, a Codex agent retyped as plain `codex` starts a new conversation (see Known limitations in the README).

## [0.2.6] - 2026-11-17

### Changed

- `V` carries an agent past its group's edge into the next or previous group, so one key both reorders and regroups; Esc still puts it back where it was picked up.
- The list no longer ticks every second: the head line leaves out the status age while the status is fresh, and ages read `<1m`, then minutes, hours and days. It redraws about once a minute instead of every second, which matters with many copies open.
- `d` on an agent whose program has already gone removes it from the list, instead of putting it back with "stop failed". An agent still running where the window can't see it stays listed, with the stop reported as failed.

## [0.2.5] - 2026-11-17

### Fixed

- Zen mode (`z`) now draws the list down the middle of the window at a readable width, as it was meant to, instead of stretching it across the whole tab.

## [0.2.4] - 2026-11-17

### Added

- `z` turns on zen mode, for rearranging and looking around: the list takes over its whole tab, drawn down the middle at a readable width, and moving through it no longer brings each agent's tab to the front.
  `z` leaves zen mode, as do Esc (while Esc returns to your pane, the default), going to an agent with Enter, and hiding the list; the head line says `zen` while it is on.
  Update Jumpr on the machine your Tern window runs on too: a window still on an older Jumpr only shows `zen` in the head line and stops the previews.
  A list key you had moved to `z` goes back to its default, since `z` now has its own action.

## [0.2.3] - 2026-11-16

### Added

- `N` starts a new agent of a kind you pick: a picker lists omp, `claude`, `codex`, `copilot` and your default agent, starting on the default, and Enter starts the highlighted one in the selected group as `n` would.
  The default agent `n` starts is left as it was; the picker is also in the `?` menu, and its key can be changed on the settings page.
  A list key you had moved to `N` goes back to its default, since `N` now has its own action; "Reset all keys" on the settings page clears the leftover setting.

## [0.2.2] - 2026-11-16

### Changed

- The list renders far less with many copies open: one agent's status change renders each copy once instead of once per copy per message, a status snapshot that changes nothing the rows show renders no copy at all, and the copy a key was pressed in renders before the others (they follow on the host's next turn, once per run of keys).
  With 13 copies open this took a status change from 169 renders to 13, and the every-30-second full snapshot from 169 to none.

  Measured live on a machine with 13 copies and 6 agents: the half-second freeze the periodic snapshot used to cause is gone, and the list's own thread dropped from 15–18% of a core to about 9%.
  No stored data changes, and machines may update one at a time: the protocol is unchanged.

## [0.2.1] - 2026-11-16

### Added

- An omp agent in `/vibe` mode counts as running while one of its workers has a turn running, and its pill says `vibing`.
  That holds even when the agent itself sits idle at its prompt, as it does after Esc ends omp's wait for a worker.
  A question or an error still shows first, and with no worker running the row reads as before.
  Jumpr reads this from the agent's own session file on the agent's machine, every 5 seconds while a list is open (see "What it runs and writes" in the README).

  The reader follows the one session file omp's own `--continue` picks and reads only what omp wrote since the last look, so it works with an omp of any version that writes the same records, and costs one small process per machine, not per agent.
  Tested live on Linux (Tern 0.9.21, omp 18.20.2) and the reader's shell on macOS; only omp 18.20 has been observed writing the records (see Known limitations in the README).

  No stored data changes, and machines may update one at a time: the protocol is unchanged from 0.2.0.

## [0.2.0] - 2026-11-16

The list is no longer tied to omp: `n` starts the machine's default agent, which can be omp or any agent Tern's ACP chat runs, such as `claude`, `codex` or `copilot`.
A settings page, opened with `,` from the list or "Jumpr: settings" from the palette, sets the default agent, the Esc behaviour, the global chords and the list's own keys.
Enter on an exited agent resumes its own conversation where the CLI's session can be looked up, and continues or opens Tern's picker otherwise.
Requires Tern 0.9.18 or newer, and every machine updated together: a machine left on an older Jumpr shows the update banner over an empty, read-only list until it is updated.
Tested with a Tern 0.9.18 window, on hosts running Tern 0.9.18.

### Added

- Agents of any kind: the default agent can be omp, as before, or any agent Tern's ACP chat knows (`claude`, `codex`, `copilot`, or one you added in Tern).
  An ACP agent is listed, shows running, waiting, idle, error and exited, takes `o` and `q`, stops with `d` and restarts with Enter, like an omp agent.
  `d` also removes an agent whose chat failed to start.
  Claude Code is the one tried so far; other agents take the same path.
- A settings page in its own tab, opened with `,` from the list or "Jumpr: settings" from the palette, with three pages, each naming the machine its values belong to: the default agent (a value of the machine whose list you are looking at), the Esc behaviour and the three global chords (values of the window you pressed the key in), and every list key (a value of the list's machine).
  A global chord is pressed in its box, or typed as text such as `ctrl+alt+k`, takes effect without a restart, is refused when another action holds it, and Reset restores the default.
  A list key is captured by Enter on its row and shown as typed; a taken or reserved key is refused with a reason, Reset on its row or Backspace restores the default, and "Reset all keys" restores every key; the `?` menu, the legend and the hints follow at once.
  A text box opens with its text selected, so typing replaces it.
  The page's own navigation keys are fixed, so no binding can lock you out of it, and closing the page returns to the pane you were in.
- Exact restart for Claude Code where the CLI's session can be looked up (on Linux): Jumpr learns the agent's conversation id from Claude's own session files, matched by the `JUMPR_ID` it started the agent with, and Enter on the exited agent resumes its own conversation.
  Where no session can be looked up (macOS, other agents), Enter continues the conversation when the agent was the last of its kind to close in its folder, and opens Tern's conversation picker otherwise.
- `o` on an exited agent, or one whose start failed, starts it again and sends the message once it is idle, instead of only holding the message.
  When the restart would open Tern's conversation picker, the message is held and Enter opens the picker: the picker pane reports working, not idle, so the message waits until a conversation is picked and the chat goes idle.
- An agent's row keeps its conversation's title after the agent exits or restarts, until the chat names itself again, instead of falling back to `claude 1`.

### Changed

- Tern 0.9.18 or newer is required.
- Stored data is upgraded in place when this version first loads it, with nothing lost; agents started by 0.1.4 are still recognised and restartable.
- A machine still on an older Jumpr that reads the upgraded data shows the "newer version" banner over an empty, read-only list until it is updated, and writes nothing, so its data is untouched.
- Every machine must be updated together, the window machines and the machines running the agents: with mixed versions the version banner or toast names the machine left behind, and nothing is started.

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

[Unreleased]: https://github.com/starkedev/jumpr/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/starkedev/jumpr/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/starkedev/jumpr/compare/v0.2.6...v0.3.0
[0.2.6]: https://github.com/starkedev/jumpr/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/starkedev/jumpr/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/starkedev/jumpr/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/starkedev/jumpr/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/starkedev/jumpr/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/starkedev/jumpr/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/starkedev/jumpr/compare/v0.1.4...v0.2.0
[0.1.4]: https://github.com/starkedev/jumpr/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/starkedev/jumpr/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/starkedev/jumpr/releases/tag/v0.1.2
[0.1.1]: https://github.com/starkedev/jumpr/releases/tag/v0.1.1
[0.1.0]: https://github.com/starkedev/jumpr/releases/tag/v0.1.0
