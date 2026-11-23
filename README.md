# Jumpr

A keyboard-driven list of your coding agents for [Tern](https://stencil.so/tern), grouped by project, one list per machine.

![Jumpr's list beside an agent's tab: count tiles for one agent in error, one waiting, one running and two idle above three project groups, with the selected waiting agent's question open in its tab](docs/jumpr.png)

Agents sit in groups, one per project folder, and each row shows whether its agent is running, waiting for you, idle or in error.
Moving through the list brings each agent's tab to the front, so the live agent is the preview, and Enter takes you into it.
It works for agents on the machine in front of you and on remote machines Tern is attached to, one list per machine.
Start omp, Claude Code, Codex or any agent Tern's ACP chat runs, and change the default agent, the chords and the list's keys from the built-in settings page.

- [Requirements](#requirements)
- [Install](#install)
- [Getting started](#getting-started)
- [Keys](#keys)
- [Settings](#settings)
- [Start an agent from a script](#start-an-agent-from-a-script)
- [How it works](#how-it-works)
- [What it runs and writes](#what-it-runs-and-writes)
- [Uninstall](#uninstall)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Credits](#credits)
- [License](#license)

## Requirements

- Tern 0.9.18 or newer, on every machine that runs Jumpr: this version uses the ACP chat's `--resume`, `--continue` and `--sessions` flags and Tern's settings calls.
- `omp` on the login shell's `PATH` of every machine that runs omp agents.
- `claude` (Claude Code) and `codex` (Codex CLI) on the login shell's `PATH` of every machine that runs Claude or Codex agents.
  Jumpr runs these two CLIs themselves in the agent's tab, not through Tern's ACP chat, so they need no ACP adapter.
- Any other agent is started through Tern's ACP chat, so the machine that runs agents needs the CLI and ACP adapter that chat starts.
- `git` on every machine you install Jumpr on, since `tern plugin install` clones the repository with it.
- For starting agents from a script with `jumpr-add` (see [Start an agent from a script](#start-an-agent-from-a-script)): a POSIX `sh` and `tern` on that script's `PATH`, on the machine that runs the agents; tried on Tern 0.9.29.
- Jumpr updated together on the machine showing your Tern window and the machine running your agents (see [Install](#install)).
- macOS or Linux; Windows is untested.

The default agent is omp; the settings page changes it to `claude`, `codex` or any agent Tern's ACP chat runs, such as `copilot`.

## Install

Run this in a terminal on each machine that needs it:

```sh
tern plugin install github.com/starkedev/jumpr
tern plugin list
```

`tern plugin list` should show `jumpr` as ready.

Jumpr has a host half and a window half (see [How it works](#how-it-works)), and each runs on a different machine.
Install it on every machine whose Tern windows you use, and on every machine that runs agents.
When your windows and your agents are on the same computer, that is one install.
To install on a remote host, run the command in a pane on that host.

To update, install again over the old copy, on each machine:

```sh
tern plugin install github.com/starkedev/jumpr --force
```

Tern has no separate update command; `--force` replaces the installed copy and reloads it.
Update every machine together.
The window's half and the agents' half check each other's protocol version, and this version changed it: across a mismatch the list shows a banner naming the machine to update, and the window refuses the list's requests (starting, stopping and going to agents) until that machine is updated.
[CHANGELOG.md](CHANGELOG.md) lists what changed in each version.

## Getting started

1. Open a Tern session on the machine whose agents you want in the list.
2. Press the jumpr key (⌘J on macOS, Ctrl+Alt+J on Linux and Windows) to show the list.
   That session becomes Jumpr's session for that machine, and every tab in it gets a copy of the list on its left.
3. Press `g` and give a project folder to make a group.
   The folder must already exist on that machine; a git repository's group is named after the repository.
4. Press `n` on the group to start an agent in that folder, in a new tab.

`n` starts the machine's default agent, which is omp until you change it.
To start another agent just this once, press `N` instead: it opens a picker of agents (omp, `claude`, `codex`, `copilot`, and your default agent if it is none of them), starting on the default; `j`/`k` move, Enter starts the highlighted one in the selected group, and Esc leaves.
To change what `n` starts, press `,` in the list to open the settings page and set the default agent (see [Settings](#settings)); `claude`, `codex` or any agent Tern's ACP chat runs can be the default.

Only agents started from Jumpr are listed: with `n` or `N`, or from a script with `jumpr-add` (see [Start an agent from a script](#start-an-agent-from-a-script)).
Agents you start yourself in a plain tab are left alone; [How it works](#how-it-works) explains why.

## Keys

### The jumpr key

The jumpr key is ⌘J on macOS and Ctrl+Alt+J on Linux and Windows.
Pressed outside the list, it shows the list if it is hidden and focuses it.
Pressed in the list, it goes back to the pane you came from and hides the list.

| Key | Does | Palette command |
|---|---|---|
| ⌘J · Ctrl+Alt+J | Show and focus the list, or go back and hide it | Jumpr: toggle list |
| ⌘⇧J · Ctrl+Alt+Shift+J | Hide the list from anywhere | Jumpr: hide list |
| ⌘\\ · Ctrl+Alt+; | Jump to the tab you last worked in; press again to come back. Scrolling through the list doesn't count as working in a tab. The list's highlight follows to that tab's agent | Jumpr: last tab |
| ⌘\` · Super+\` | Hide every pane of the tab but the list and the tab's agent, wherever you are in the tab; press again to bring them back where they were (see [Hide the other panes](#hide-the-other-panes)) | Jumpr: hide or show other panes |
| | Focus the list | Jumpr: focus list |
| | Hide or show the list without moving focus | Jumpr: hide or show list |
| | Copy the paths of a diagnostics dump | Jumpr: diagnostics |

### Hide the other panes

⌘\` (Super+\` on Linux and Windows) gives the tab's agent the room of its tab.
Each tab has a core, the list and its agent; every other pane in it (a shell you opened to run a command, an editor, a second agent) is an extra, and ⌘\` hides all the extras together, wherever focus is in the tab.
If ⌘\` switches between Tern windows instead, macOS has kept its "Move focus to next window" shortcut for itself: turn it off in System Settings › Keyboard › Keyboard Shortcuts › Keyboard, or bind another key.
Pressed in an extra, it hides that one too and moves focus to the agent; pressed in the agent or the list, focus stays where it is.
The hidden panes go to Tern's parked panes, and their programs keep running.
Press it again in that tab to bring them back where they were, at their old sizes; focus stays where it is, and the list stays where it is: the other panes come back around it.
The agent is one Jumpr started; in a tab with two, the core keeps the one you are in, else the one the jumpr key would take you back to, else the one whose name the tab shows while you are in the list.
A tab with no agent Jumpr started keeps the pane you are in instead (pressed in the list: the pane the jumpr key would take you back to, when it is in this tab).
Each tab remembers its own hidden panes.
A pane you closed meanwhile stays closed, and a pane you parked yourself is left to you.
If you changed the tab meanwhile (opened a pane, brought one back yourself from Parked panes, or moved one), nothing in the tab moves: each hidden pane comes back beside the pane it sat next to, and the panes you opened or moved stay where you put them.
Hiding and showing the list meanwhile does not count as a change.
Floating blocks (picture in picture) are never hidden.
In zen mode, or with a block zoomed by Zoom block, the chord changes nothing and says so: leave zen mode in the list, or run Zoom block again, first.
The window remembers the hidden panes only until Jumpr reloads or their tab closes; after that, Tern's Parked panes (⌃⇧↑ on a Mac, Ctrl+Shift+↑ on a PC) brings them back one at a time.

### Change the keys

The settings page is the easy way (see [Settings](#settings)): its "List keys" page changes the list's own keys, and its "This window" page takes a new chord for any of the four.
The four chords are ordinary Tern keybinds, so you can also set them by hand under `keybinds` in Tern's `settings.json` (`~/.config/tern/settings.json` on Linux), on each machine whose windows you use:

```json
"keybinds": {
  "ctrl+alt+k": "plugin.jumpr.toggle_focus"
}
```

Then run "Reload settings" from the palette; no restart is needed.
The four commands are `plugin.jumpr.toggle_focus` (the jumpr key), `plugin.jumpr.hide_list`, `plugin.jumpr.last_tab` and `plugin.jumpr.other_panes`.
Ctrl+J is a poor choice of your own: on Linux and Windows it is Tern's own join lines, and in a shell it is Enter.

### In the list

| Key | Does |
|---|---|
| `j` / `k`, `↓` / `↑` | Move the selection by one; past the last row back to the first, and above the first to the last |
| `J` / `K` (Shift+j / Shift+k) | Move to the next or previous group's header; from an agent, `K` goes to its own group's header first |
| `G` / `End`, `Home` | Move to the last or first row |
| `Enter` | On an agent: focus its pane, or restart it, back into its own conversation, if it has exited. A parked agent (running in no tab) gets a tab of its own first. On a group: fold or unfold it |
| `Tab` | Fold or unfold a group |
| `h` / `l` | Fold or unfold the selected group |
| `n` | Start a new agent in the selected group |
| `N` | Pick an agent from a list, then start it in the selected group |
| `g` | New group (asks for a folder first) |
| `r` | Rename the agent, and the name also becomes its tab's name; on a group header, rename the group |
| `m` | Move the agent to another group |
| `V` | Pick the row up to reorder it: an agent, or a group header among the groups. `j` / `k` move it; an agent moved past its group's last or first place goes on into the next group's top or the previous group's bottom (passing over a group being deleted, and opening a folded one). `Enter` or `V` drops it, `Esc` puts it back where it was, in its own group |
| `p` | Tag the agent as priority, or untag it; a tagged agent shows ★ beside its name. The tag stays on the agent when it exits and restarts, and when Tern restarts |
| `d` | Stop the agent and take it off the list, or delete the group (asks `y/n`). An agent that has exited, or whose program no longer runs, comes off the list with nothing to stop. If a running agent cannot be stopped, it stays and the list says the stop failed |
| `o` | Send a message to the agent now. On an exited agent, or one whose start failed, start it again first; the message is sent once it is idle. When its conversation has to be picked, the message is held and Enter opens the picker; it is sent once a conversation is picked and the chat is idle. A Claude Code or Codex agent is typed into only while it reports itself idle; otherwise the message is held until it does |
| `q` | Queue a message, sent once the agent is idle (for Claude Code and Codex, once the agent reports itself idle) |
| `z` | Zen mode: the list takes over the whole tab, centred, and moving through it shows no agent's tab. `z` leaves it, and so does Esc while Esc returns to your pane (the default); going to an agent with Enter leaves it too |
| `i` | Show where each row's status comes from |
| `/` | Search labels, folders and group names |
| `%` (Shift+5) | Show only priority agents, and only the groups that hold one, and the head line says `★ priority only`; press again to show every agent. It combines with a status filter and with the search (an agent must match both), and `Esc` clears it with the status filter |
| `?` | Open the command menu |
| `,` | Open the settings page (see [Settings](#settings)) |

The command menu lists every key in the list with what it does on the selected row.
`j` / `k` or `↓` / `↑` move, `Enter` or the command's own key runs it, and `Esc` or `?` closes it.
Commands the selected row does not suit are dimmed.

<img src="docs/jumpr-menu.png" width="308" alt="The ? command menu open under the list, with go to agent, the first command, highlighted for the selected waiting agent">

### Filters

Filters show only the agents in the states you pick.
The keys run along the shifted number row in priority order, what needs you first:

| Key | Shows |
|---|---|
| `!` (Shift+1) | Error |
| `@` (Shift+2) | Waiting for you |
| `#` (Shift+3) | Running |
| `$` (Shift+4) | Idle |
| `0` | Everything |
| `1` `2` `3` `4` | Add error, waiting, running or idle to the filter, or drop it |

Pressing a filter key a second time clears it.
`! @ # $` always show one status only, even when several are on.
`1 2 3 4` combine them: `2` then `3` shows waiting and running agents together, and pressing a key again drops its status; dropping the last one clears the filter.
The count tiles at the top show the same symbols in the same order, error first: each tile shows its status key next to the count and the word under it (`@ 2` / waiting), and every tile whose status is in the filter is outlined.
Clicking a tile shows that status only, as its key does, and clicking the only outlined tile again clears the filter.
Option+click (alt+click) on a tile adds its status to the filter, or drops it when it is already on, as `1 2 3 4` do.
The head line names the filter in words, for example `filter @ waiting` or `filter @ waiting + # running`.

### Preview and Esc

When a move rests on a live agent for 120 ms, that agent's tab comes to the front.
Any other key in that pause cancels it.
In zen mode (`z`) moves bring no tab to the front: the list fills the window, so you can rearrange and look around without the tabs flicking past.

![Moving through the list with j and k brings each live agent's tab to the front; Enter goes into the waiting agent, and cmd+\ goes back to the tab last worked in, then returns](docs/jumpr.gif)

Esc clears an open input, search or filter first.
With none open, it returns focus to the pane you were in before the list.
Esc never hides the list.
If `esc_mode` in `window.json` (in Jumpr's data folder) is `"B"`, Esc only cancels an open input, and the jumpr key goes back instead.
The settings page's "This window" page flips this (see [Settings](#settings)).

### Mouse

Click a group's header to fold or unfold it, and click an agent to select it, as if you had moved onto it.
Click a count tile to show that status only, as its key does, and Option+click (alt+click) it to add it to the filter or drop it.
Clicks only act in the list itself; while an input, a question, a picker, the command menu or a reorder is open, they do nothing.

## Settings

Press `,` in the list, or run "Jumpr: settings" from the palette, and the settings page opens in a tab of its own.
`[` and `]` move between its three pages, `j` and `k` between a page's rows, Enter opens the focused row, and Esc closes the page and takes you back to the pane you were in.
These keys are fixed, so no key binding can lock you out of the page.
Each page names the machine its values belong to.

![The settings page on its "This window" page: a nav naming each page's machine, the Esc switch, and a chord box for each of the three global chords](docs/jumpr-settings.png)

- **Agents** — the default agent `n` starts: pick a common one from the menu (`claude` and `codex` run their own CLIs), or type any other agent id Tern's ACP chat knows.
  This value belongs to the machine whose list you are looking at.
- **This window** — whether Esc returns to your pane, and the four global chords.
  Open a chord's row and press the chord, or type it as text such as `ctrl+alt+k`, then press Enter.
  A chord Tern or your system already takes never reaches the page, so type that one.
  These values belong to the window you opened the page in, so each window machine sets its own; with several windows open, only the window showing the settings page changes.
  A chord another action holds is refused, Reset puts the default back, and a change takes effect without a restart.
- **List keys** — every key the list uses, one row per action, shown as you type it (`j` and `J` are different keys).
  This value belongs to the machine whose list you are looking at.
  Enter on a row waits for your next key press: a taken or reserved key is refused with a reason.
  Reset on a changed row, or Backspace while it waits, puts that key's default back, and "Reset all keys" restores every default.
  The `?` menu, the legend and the hints follow a change at once.

A text box opens with its text selected, so typing replaces it; an arrow key places the caret to edit it instead.

The mouse works too: click a row to choose it, and click a control to change or pick a value.

## Start an agent from a script

`bin/jumpr-add` starts an omp agent in the list from a script or a timer on the machine that runs the agents, and sends it a brief from a file as its first message.
The agent gets a tab in Jumpr's session and a row in the group you name, and from then on it is an agent like one started with `n`.
It works with no Tern window attached, and opening its tab leaves an attached window's focus where it is.
It has been tried on Tern 0.9.29.

It needs, on the machine that runs the agents: Jumpr installed, its list shown there at least once (that makes Jumpr's session there), Tern's daemon running, and `tern` on the script's `PATH`.

```sh
jumpr-add --group NAME [--cwd DIR] --prompt-file FILE [--label TEXT] [--timeout SECONDS]
```

| Flag | Does |
|---|---|
| `--group NAME` | The group to put the agent in, by its name in the list (trimmed; at most 40 characters, not starting with `-`). The agent goes last in the group. When no group has that name, a new one is made, last in the list, with `--cwd` as its folder; without `--cwd` the request is refused |
| `--cwd DIR` | The agent's folder, made absolute (a symlink stays as given); without it, the group's folder. The folder must exist, and it may be another folder than the group's, as for an agent moved with `m` |
| `--prompt-file FILE` | The brief, sent as the agent's first message. It must exist and not be empty, and its absolute path may hold only letters, digits and `_ - . /` (no spaces) |
| `--label TEXT` | The agent's name in the list and on its tab, as `r` sets it (trimmed; at most 60 characters, not starting with `-`) |
| `--timeout SECONDS` | How long to wait for Jumpr's answer; 20 by default |
| `--help` | Show the usage |

Two variables change where it looks: `TERN`, the `tern` command to run (`tern` by default), and `JUMPR_DATA`, Jumpr's data folder (by default the one under [What it runs and writes](#what-it-runs-and-writes)).

It ends with one of three exit codes:

- `0`: the agent is started, and it prints `started <id>`, the agent's Jumpr id.
- `1`: refused or failed, with the reason on one line: a bad flag, a brief or folder that is missing, `tern` not found, `tern new tab` failing, or Jumpr's own refusal, such as `no group named <name>; pass --cwd to create it`, `group is being deleted`, `folder not found on <machine>: <folder>`, or `open the Jumpr list on this machine once, then retry`.
- `2`: Jumpr did not answer: Jumpr's data folder is missing (Jumpr is not installed there, or has never run), Tern's daemon is not running, or the Jumpr there is older than `jumpr-add`.

`jumpr-add` asks Jumpr's host half for the agent with a request file in Jumpr's data folder, and the host half answers within about a second, whether or not a list is open.
The host half records the agent and answers; `jumpr-add` then opens the agent's tab with `tern new tab`, because Tern's daemon cannot run the `tern` command itself.
A request more than 60 seconds old is never served, and a `jumpr-add` that is stopped while it waits takes its request back, so a killed script never starts an agent later.

When something goes wrong:

- A refused request makes nothing: no group, no row and no tab.
- When Jumpr accepted the request but the tab never opens (`tern new tab` failed, or the script was killed first), the row shows as a failed start after 30 seconds, `failed · ⏎ retries`, and `jumpr-add` exits 1 naming the agent.
  If the tab does open later, the row turns live by itself.
  `Enter` on the failed row starts the agent in its folder without the brief.
- Jumpr checks that the brief exists, and `jumpr-add` that it is not empty; Jumpr never reads it, omp does.
  A brief deleted after Jumpr answered makes omp stop at its start, and the row shows the agent as exited.

To run it by name, link it from a clone of this repository into a folder on your `PATH`, and keep the clone at the version of the Jumpr installed on that machine:

```sh
git clone https://github.com/starkedev/jumpr <clone folder>
ln -s <clone folder>/bin/jumpr-add ~/.local/bin/jumpr-add
```

From a systemd user timer on Linux, a service gets a short `PATH`, so give it the folder that holds `tern` (`command -v tern` shows it):

```ini
# ~/.config/systemd/user/<job>.service
[Unit]
Description=Start a <job> agent in Jumpr

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.local/bin/jumpr-add --group <group> --cwd <project folder> --prompt-file <brief file> --label <label>
```

```ini
# ~/.config/systemd/user/<job>.timer
[Timer]
OnCalendar=<when>

[Install]
WantedBy=timers.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now <job>.timer
```

Give `<project folder>` and `<brief file>` as absolute paths; `%h` is your home folder.

## How it works

### Two halves

A Tern plugin can have two halves that run in different places, and Jumpr uses both.

- The host half runs on the machine that runs the agents.
  It holds the list, starts and stops agents, and draws the list you see.
- The window half runs on the machine showing the Tern window.
  It watches agent status, brings tabs to the front, owns the keys and the palette commands, and carries the list's requests to the host half.

That is why Jumpr is installed on both machines when they differ.
A window without its own install still shows a remote machine's list, but nothing in it works.
Every message between the halves carries a protocol version, so a machine running an older Jumpr is named in a banner instead of failing quietly.

### How agents get into the list

Pressing `n` on a group starts the machine's default agent in a new tab of Jumpr's session, in the group's folder.
An omp agent starts as:

```sh
omp --continue --session-dir ~/.omp/deck/<id>
```

A Claude Code agent runs the real `claude` CLI, on a conversation id Jumpr draws when it makes the agent:

```sh
env JUMPR_ID=<id> sh -c 'if ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/<uuid>.jsonl >/dev/null 2>&1; then exec claude --resume <uuid>; else exec claude --session-id <uuid>; fi'
```

The same line starts the agent and restarts it.
Claude Code writes a conversation's file, `~/.claude/projects/<folder>/<uuid>.jsonl`, at its first message, so the line looks for that file before it runs anything.
When `CLAUDE_CONFIG_DIR` is set, Claude keeps its files there instead, and the line looks in `$CLAUDE_CONFIG_DIR/projects/` to match.
If the file is there, `claude --resume` opens the conversation; if not, `claude --session-id` starts it fresh under that id.
A new agent therefore never tries to resume a conversation that does not exist yet.

A Codex agent runs the real `codex` CLI:

```sh
env JUMPR_ID=<id> codex
```

Any other agent starts through Tern's ACP chat, as:

```sh
env JUMPR_ID=<id> tern acp <agent>
```

`<id>` is a random eight-character id Jumpr gives the agent, and `<uuid>` a random conversation id in the form Claude Code uses.
Jumpr recognises its agents by that id — an omp agent carries it in its session folder under `~/.omp/deck/`, and any other agent carries it in the `JUMPR_ID` on its command — so agents started any other way than `n`, `N` or `jumpr-add` are never listed.

A script on the agents' machine can start an omp agent too, with `jumpr-add` (see [Start an agent from a script](#start-an-agent-from-a-script)).
Its first start sends the brief file as the agent's first message, with the home folder spelled out:

```sh
omp --session-dir <home>/.omp/deck/<id> @<brief file>
```

From then on it is an omp agent like any other: `Enter` restarts it with the `omp --continue` line above, and Jumpr's reopen hook answers `omp --session-dir <home>/.omp/deck/<id>` for that first line, without the brief, so a reopen does not send the brief again.

### Restarts

Restarting an exited agent with `Enter` brings back its own conversation:

- An omp agent resumes from its session folder; one started from a script resumes the same way, without being sent its brief again.
- A Claude Code agent runs its line again, on the conversation Jumpr holds for it.
  `/clear` in Claude moves it to a new conversation id; on Linux Jumpr follows that, so a restart comes back to the conversation you were in.
  An agent whose conversation Jumpr does not know (one an older Jumpr started through the ACP chat without learning its id) opens Claude's own conversation picker instead, as `env JUMPR_ID=<id> claude --resume`, and on Linux Jumpr learns the one you pick.
- A Codex agent's conversation id is chosen by Codex, so Jumpr finds it in Codex's own files after the agent's first message (see [What it runs and writes](#what-it-runs-and-writes)).
  Once found, a restart runs `env JUMPR_ID=<id> codex resume <thread id>`.
  Until then, a restart opens Codex's own picker, `env JUMPR_ID=<id> codex resume`, and Jumpr learns the one you pick; a Codex agent whose first start never ran starts new with `codex` instead.
- Any other agent continues the last conversation of its kind in that folder when Jumpr can prove that is safe, with `--continue`, and opens Tern's conversation picker otherwise, with `--sessions`.

Claude Code and Codex agents are never restarted into "the last conversation in this folder", which could belong to another agent that is still running.
Agents an older Jumpr started through the ACP chat as `claude` or `codex` keep their place in the list, and their next restart runs the real CLI by these rules.
See [Known limitations](#known-limitations).

### Status

Status comes from Tern's own agent tracking: running, waiting for you, idle, error or stopped.
Claude Code and Codex report their own status to Tern, as omp does, so their rows read running, waiting for you and idle in the same way.
A startup screen of either CLI (a folder-trust question, Codex's update offer) or its conversation picker never reports idle, so its row does not read idle while you answer it in the agent's tab.
Each row shows its status, how long it has been in it, its folder when that is not the group's, and what is waiting on it.
That age reads `<1m` for its first minute, then whole minutes, hours and days (`5m`, `2h`, `1d`), so the list redraws for it at most about once a minute.
Press `i` to see where each row's status comes from, with how long ago it changed in the same units (`agents <1m`).
While status is fresh the head line shows no age; it says `status stale` when the window has gone quiet, and `status unavailable` when no status has arrived, and the rows' ages are hidden until status is fresh again.
An omp agent in `/vibe` mode hands its work to background workers.
While one of those workers has a turn running, the agent's row counts as running and its pill says `vibing`, even when the agent itself sits idle at its prompt.
A question or an error still shows first, and with no worker running the row reads as Tern reports it.
An agent you parked in Tern keeps running, and its row keeps its status and says `in no tab`.
Moving onto it leaves your tabs as they are; `Enter` brings it back into a tab of its own, with its copy of the list, and goes to it.

<img src="docs/jumpr-parked.png" width="308" alt="The list with a parked agent selected, its row saying in no tab and that Enter brings it back">

### Sending messages

`o` and `q` type a message into the agent's pane.
Into a Claude Code or Codex agent, Jumpr types only while Tern has the agent's own report that it is idle: the text first, then Enter about 200 ms later, because text and Enter typed together read as a paste whose Enter is a line break (in Codex always, in Claude Code past 62 characters).
At any other time the message is held (`not idle yet — message queued`) and typed at the agent's next idle report, so it never lands in a startup screen, a permission question or a picker, where Enter would confirm whatever is highlighted.

## What it runs and writes

It runs:

- `omp --continue --session-dir ~/.omp/deck/<id>`, in a terminal tab, to start or restart an omp agent.
- `omp --session-dir ~/.omp/deck/<id>`, in place of that line when Tern reopens an omp agent's pane (after Tern's session service restarts, or in a fork): Tern adds `--restore`, `--resume` or `--fork` and the session file, which omp refuses beside `--continue`.
- `omp --session-dir <home>/.omp/deck/<id>`, the line Jumpr's reopen hook returns in place of a script-started omp agent's first line: without the brief, which omp refuses beside `--restore` and which must not be sent twice.
- `env JUMPR_ID=<id> sh -c 'if ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/<uuid>.jsonl >/dev/null 2>&1; then exec claude --resume <uuid>; else exec claude --session-id <uuid>; fi'`, in a terminal tab, to start or restart a Claude Code agent on its conversation, and `env JUMPR_ID=<id> claude --resume` to restart one whose conversation Jumpr does not know, in Claude's own picker.
  The `ls` only answers whether that conversation's file exists; its output is thrown away and no file is read.
- `env JUMPR_ID=<id> codex`, in a terminal tab, to start a Codex agent; `env JUMPR_ID=<id> codex resume <thread id>` to restart one whose conversation Jumpr has found, and `env JUMPR_ID=<id> codex resume` to restart one whose conversation it has not, in Codex's own picker.
- `env JUMPR_ID=<id> tern acp <agent>`, in a terminal tab, to start or restart any other agent through Tern's ACP chat.
  A restart adds `--continue` or `--sessions` to that command.
- `/bin/sh -c 'printf …'` in place of a second start of an agent that already runs (from another window, or by hand): it prints a line saying so and closes, so two processes never share one agent.
- `grep -q -z -x JUMPR_ID=<id> /proc/<pid>/environ`, on Linux, to prove which `claude` process belongs to which Claude Code agent.
  The grep only answers yes or no; a process's environment is never read into the plugin.
  It runs on the `claude` process and on each process above it, up to the first without the agent's id (the pane's shell), and Jumpr reads `/proc/<pid>/stat` (parent and start time) and `/proc/<pid>/comm` (name) of the processes on that walk, so a `claude` the agent started itself is never taken for the agent's own.
  The conversation id comes from Claude Code's own session files: Jumpr lists `~/.claude/sessions/` and reads the `<pid>.json` files there to find it, then reads that `claude`'s file again every 3 seconds while it runs, so the stored id follows `/clear`.
- `sh -c` with `head`, to read Codex's conversation files (rollouts, `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`) and find a Codex agent's conversation.
  Of each file it reads only the start of line 1, at most 2048 bytes and never past that line: the conversation's id, start time and folder, never a message.
  It reads at most 30 files, those named for the days the agent's start can fall on; a conversation counts as the agent's only when it is the one conversation in the agent's folder that started between a minute before the agent's start and ten minutes after it, and no other Codex agent of the list could own it.
  After a restart through Codex's picker it runs `sh -c` with `find`, `head` and `stat` over `~/.codex/sessions` instead, for at most 31 files changed since the restart, read the same way.
  It looks once when the agent starts, then every 3 seconds for ten tries, then every 30 seconds until it finds the conversation, since Codex writes the file only at the first message.
- `git rev-parse --git-common-dir`, to name a group after its repository.
- `sh -c` with `wc`, `tail`, `head` and `grep`, every 5 seconds while a list is open, on each running omp agent's session files (`~/.omp/deck/<id>/`), to tell whether a `/vibe` worker of it is running.
  It follows the one file omp itself continues — the most recently modified non-empty one, as omp's `--continue` picks — and reads only what omp wrote there since the last look.
  Of that file, only omp's bookkeeping records of its vibe workers and modes (a turn starting or ending, a spawn, a tombstone, a mode change, an exit) ever reach the plugin; a conversation's messages never do.
- `tern --version`, for the diagnostics dump.

It types only the text you enter for `o` and `q`, into that agent's pane; into a Claude Code or Codex agent, the text and then Enter, only while the agent reports itself idle (see [Sending messages](#sending-messages)).

`jumpr-add`, when a script runs it, runs `tern new tab <session> --json --cwd <folder> -- omp --session-dir <home>/.omp/deck/<id> @<brief file>` to open the agent's tab in Jumpr's session, and, with `--label`, `tern rename <block> <label>` to name it, `<block>` being the pane id in Tern's `--json` answer.

It writes, in Jumpr's data folder on each machine (`<state>/plugin-data/jumpr/`; `~/.local/state/tern/plugin-data/jumpr/` on Linux, `~/Library/Application Support/Tern/plugin-data/jumpr/` on macOS):

- `jumpr.v1` in `kv.json` on the agents' machine: groups, labels, folds, the agent records (each with the last title its conversation showed), the queued messages and the settings (the default agent and the list keys).
- `window.json` on the window's machine: which window leads, and the window settings.
  A chord change goes into Tern's own `settings.json` keybinds, not into Jumpr's files.
- Diagnostics dumps (`diag-window-<ms>.json` and `diag-host-<ms>.json`), only when you run "Jumpr: diagnostics".
- `requests/` and `replies/` on the agents' machine, for `jumpr-add`: the script writes its request as `requests/<rid>.tmp` and renames it `requests/<rid>.req`; the host half reads and removes each request and writes its answer to `replies/<rid>.reply`, which the script reads and deletes.
  A file no script collected (the answer to a script that was killed, a half-written request) is removed by an hourly sweep once two sweeps in a row have seen it.
  The brief file is never read by Jumpr: the host half only checks that it exists, and omp reads it.

Each omp agent's conversation lives in `~/.omp/deck/<id>`, which omp writes and Jumpr never deletes, even when you stop the agent with `d`; Jumpr reads it only for the `vibing` check above.
A Claude Code or Codex agent's conversation lives in that CLI's own files under `~/.claude` or `~/.codex`, which Jumpr reads only for the lookups above and never writes.
Any other agent's conversation lives where its ACP chat keeps it.
Jumpr makes no network requests of its own.

## Uninstall

On a machine, either turn Jumpr off by adding `"jumpr"` to `plugins_disabled` in Tern's `settings.json`, or remove it:

```sh
tern plugin remove jumpr
```

Agents keep running as ordinary tabs; only the list goes away.
Jumpr's data folder is kept, so a reinstall finds your groups and agents again.
Delete that folder by hand to start fresh.

## Known limitations

- Restarting an exited agent is exact, back into its own conversation, for omp, for Claude Code, and for Codex once Jumpr has found its conversation.
- Claude Code's `/clear` is followed on Linux only: on macOS, which has no `/proc`, a restart after `/clear` returns to the conversation the agent had before it.
- Codex's `/new` is not followed: a restart returns to the conversation Jumpr found first.
- Jumpr reads Codex's files under `~/.codex/sessions` only, so with `CODEX_HOME` set elsewhere it never finds a Codex agent's conversation, and every restart goes through Codex's picker.
- Jumpr follows a Claude agent's `/clear` by reading `~/.claude/sessions` only, so with `CLAUDE_CONFIG_DIR` set elsewhere a `/clear` is not followed, and a restart returns to the conversation the agent had before it.
- A Codex you start by hand in the same folder within about ten minutes of a Codex agent's start can be taken for that agent's conversation, when the agent has not written its own yet.
  Two Codex agents Jumpr starts in one folder at about the same time cannot be told apart: neither conversation is found, and both restart through Codex's picker.
- On macOS, the Codex search after a picker restart reads file times with BSD `stat`, which is untested.
- For any agent other than omp, Claude Code and Codex, Enter on an exited agent continues the last conversation of its kind in that folder when Jumpr can prove that is safe, and opens Tern's conversation picker otherwise.
- Only Claude Code has been tried through the ACP path, before it moved to its own CLI; `copilot` and custom agent ids take that route but are unobserved.
- `vibing` rests on the records omp 18.20 writes to its session file.
  An omp that writes them differently is never shown as vibing, and its row reads as Tern reports it.
  A worker's turn cut off by a crash leaves no end record: if Jumpr did not see the agent start again (it was loaded later), that row can read `vibing` until that worker's next turn settles or until the agent leaves `/vibe`.
- Windows is untested; macOS and Linux are the tested platforms.
- A restart of Tern's session daemon on an agents' machine is untested: groups and records are stored, but how agents rejoin the list afterwards has not been checked.
  Tern may bring a chat back by itself while its row still reads exited, and pressing Enter on that row before the list catches up is untested.
  If Tern types an agent's line again after such a restart, a Claude Code agent comes back to its own conversation, but a Codex agent started with plain `codex` starts a new, empty one; its earlier conversation is untouched, and once Jumpr has found it, the agent's next restart from the list returns to it.
- One window per machine is recommended.
  Several windows elect a leader between them, and that path is only lightly tested.
  If `window.json` cannot be written, every window acts alone, so keep to one window.
- One list per machine: the first session you show the list in is Jumpr's session there; showing it in another session moves it.
- Hiding and showing the other panes of a tab (⌘\`, Super+\`) rests on Tern's park, unpark, move and resize, and has been hand-tested on macOS and on Linux under Hyprland; not yet on Windows.
- `jumpr-add` starts omp agents only, and has been tried on Linux only; on macOS its data folder and its clock (whole seconds there) are untested.

## Troubleshooting

- **The jumpr key does nothing.**
  Check that your window manager or desktop is not taking the chord, or give it one of your own under [Change the keys](#change-the-keys).
- **A remote machine's list shows, but keys and clicks do nothing.**
  The window half is missing on the machine showing the window: install Jumpr there too.
- **A banner says "update Jumpr on …".**
  The two halves run different versions: run the update command on the machine the banner names.
- **An agent you started yourself is not in the list.**
  Only agents started with `n` or `N`, or from a script with `jumpr-add`, are listed (see [How agents get into the list](#how-agents-get-into-the-list)).
- **`jumpr-add` exits 2.**
  Jumpr on that machine did not answer: check that Tern's daemon runs there, that Jumpr is installed there and as new as the script (`tern plugin list`), and that `JUMPR_DATA`, if set, names Jumpr's data folder.
- **Enter on an exited agent opened a picker instead of its conversation.**
  Without a proven conversation id, Jumpr never guesses for Claude Code or Codex, and continues another agent's conversation only when it knows that one is this agent's; pick the right conversation from the picker (see [Known limitations](#known-limitations)).
  For Claude Code (on Linux) and Codex, Jumpr learns the one you pick for the next restart.
- **A message sent with `o` to a Claude Code or Codex agent has not arrived.**
  It is held until the agent reports itself idle: answer any question or startup screen in the agent's tab, and it is typed at the next idle.
- **Something else looks wrong.**
  Run "Jumpr: diagnostics" from the palette.
  It writes a window dump and a host dump to Jumpr's data folder and copies their paths, which you can attach to an issue.
  Tern's own `tern plugin list` shows whether the plugin loaded, and its error if it did not.

## Development

Link a checkout instead of installing it, so Tern reloads the plugin when a file changes:

```sh
git clone https://github.com/starkedev/jumpr
tern plugin link ./jumpr
```

Run `scripts/check.sh` before every commit.
It runs stylua, the unit tests, a strict `luau-lsp` type check and the design-rule checks.
It needs `stylua`, `luau`, `luau-lsp` and `rg` on `PATH`.
The first run also needs `tern`, to write `tern.d.luau` with `tern plugin types .`.

Install the tools from their release pages:

- `stylua`: https://github.com/JohnnyMorganz/StyLua/releases
- `luau`: https://github.com/luau-lang/luau/releases
- `luau-lsp`: https://github.com/JohnnyMorganz/luau-lsp/releases
- `rg` (ripgrep): https://github.com/BurntSushi/ripgrep/releases

`host.luau` and `lib/host/` are the host half, `window.luau` and `lib/window/` the window half, and `lib/shared/` the message shapes, status rules and agent identity both halves use.
The unit suites in `test/` run under plain `luau`.

Bug reports and pull requests are welcome in [GitHub issues](https://github.com/starkedev/jumpr/issues).

## Credits

Jumpr borrows from [tern-agent-nav](https://github.com/Arcadia822/tern-agent-nav) by Arcadia (MIT): the spinner title helpers and the order of the status colours.
See [NOTICE](NOTICE) for the details and its licence.
Jumpr's key layout and workflow are inspired by [agent-deck](https://github.com/asheshgoplani/agent-deck) (MIT); no code is copied from it.

## License

[MIT](LICENSE)
