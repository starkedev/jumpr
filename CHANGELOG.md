# Changelog

All notable changes to Jumpr are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).
Update with `tern plugin install github.com/starkedev/jumpr --force` on each machine.

## [Unreleased]

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

[Unreleased]: https://github.com/starkedev/jumpr/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/starkedev/jumpr/releases/tag/v0.1.1
[0.1.0]: https://github.com/starkedev/jumpr/releases/tag/v0.1.0
