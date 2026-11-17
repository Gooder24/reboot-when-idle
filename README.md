# reboot-when-idle

Reboot a Linux machine after updates, but only while nothing works on it. Made for home servers and old
laptops that run AI coding agents (Claude Code and others) unattended, day and night.

Automatic updates are easy (`unattended-upgrades`); the reboot a new kernel needs is not. Its own
`Automatic-Reboot` fires at a fixed hour whatever runs, and `Automatic-Reboot-WithUsers=false` never fires on
a machine with an autologin console. An agent halfway through a refactor, a background build it started, a
training job: a reboot kills them all. `reboot-when-idle` waits for a quiet moment, and when the reboot means
a new kernel, makes sure a kernel that does not work cannot strand a machine nobody can walk up to.

Part of [KarchiOS Headless](https://github.com/Gooder24/karchi-os-headless-debian), a Debian 13 install for
laptops that run agents around the clock, next to [laptop-server](https://github.com/Gooder24/laptop-server);
works on its own on any systemd distribution.

## Requirements

- Linux with systemd. Tested on Debian 13 only.
- bash, procps, iproute2 and awk. The Debian package depends on them.
- For a new kernel to be tried once: GRUB (`grub-common`) with `update-grub`. Without it a new kernel waits, see below.
- Root is needed to install and for the nightly timer. One scenario in `make test` runs a command with `sudo -n` (as root) when passwordless sudo is set up, and is skipped otherwise.

## Quick start

```sh
make check
```

This checks the syntax and runs the self-test in a few seconds, without root. `make test` then runs the scenarios on this machine (about a minute; nothing reboots), and [Install](#install) puts the tool on it.

## What it does

Every night between 03:00 and 04:00 (each machine at a time of its own) a timer asks:

**Is a reboot due?** A newer kernel is installed than the one running, a package asked for it
(`/run/reboot-required`), or the machine has been up for 30 days.

**Is something working?** Any of these holds the reboot:

| what holds the reboot | how it is seen |
|---|---|
| an agent turn, and its background tasks and scheduled prompts | agent hooks (below): a prompt arrives, a tool is called, the turn ends |
| a conversation that just paused | for 30 minutes after a turn, while you read the answer and type the next prompt |
| whatever people or agents started in a login session: over SSH (`ssh box make`), in a terminal, an agent's command, also one detached with `nohup`, `setsid` or `&` | the session's cgroup; shells, the agents themselves, what runs them (e.g. T3 Code's server) and the helpers an agent starts with itself do not count |
| a job you started anywhere | `reboot-when-idle hold <command>` |
| anything holding a systemd shutdown lock | `systemd-inhibit --what=shutdown --mode=block` |
| apt, dpkg, unattended-upgrades | their lock files |
| a person | a terminal typed on in the last 30 minutes |

Work running for more than 12 hours (a dev server, an editor left open) counts as a server, not as work;
`status` still lists it.

If something works it looks again every 10 minutes for three hours, then leaves it for the next night. When
it is quiet it announces the reboot for 60 seconds: an agent prompt arriving then is turned away with a
message saying the machine is rebooting, and any work starting meanwhile calls the reboot off.

**A new kernel boots once, on trial.** It must be fully installed (its initrd is there, dpkg finished). GRUB keeps starting the kernel last known to work; the new one is
started once (`grub-reboot`). If the network comes up with it within 10 minutes it becomes the default. If it
does not, the machine reboots back; if it crashes (`panic=10`) or hangs (the hardware watchdog), GRUB starts
the old kernel by itself. A kernel that failed is not tried again — `status` says so — until a newer one
arrives. If the network is down with the old kernel too, the problem was not the kernel and it tries again.

Where GRUB cannot do this (no `make enable`, another boot loader), a new kernel waits and `status` says so:
every reboot would start it untried, so nothing reboots until you set up GRUB or set
`KERNEL_WITHOUT_TRIAL=reboot`. With several machines, `KERNEL_WAIT_DAYS` on all but one lets one machine
try each new kernel first.

## Install

From the source, into `/usr/local`:

```sh
make test                      # the scenarios on this machine; nothing reboots
sudo make install enable
```

or `make deb && sudo apt install ./reboot-when-idle_*_all.deb` (into `/usr`).

`enable` changes these things on the machine:

- `/etc/default/grub.d/reboot-when-idle.cfg`: `GRUB_DEFAULT=saved` and `panic=10`, then `update-grub` and
  `grub-set-default` to the running kernel. A manual reboot keeps the kernel that works; the timer moves to
  a new one.
- `/etc/systemd/system.conf.d/reboot-when-idle.conf`: `RuntimeWatchdogSec=2min`, from the next boot.
  Without a watchdog device it does nothing.
- the timer, two boot services (`reboot-when-idle-boot`, `reboot-when-idle-trial`) and `/run/reboot-when-idle/hold`.

It does not install or configure automatic updates; on Debian/Ubuntu that is `unattended-upgrades` with its
own `Automatic-Reboot` left off.

## Tell it when an agent works

Claude Code: merge [hooks/claude-code.json](hooks/claude-code.json) into `~/.claude/settings.json` of the user
the agents run as. The installed copy, `/usr/share/reboot-when-idle/claude-code-hooks.json` (or under
`/usr/local/share` after `make install`), has the paths of your installation. Claude Code reloads settings while
it runs. The hooks take about 10 ms, print nothing and never fail a turn.

Any other agent with hooks: call `reboot-when-idle hook prompt` when a prompt arrives, `hook tool` before a
tool call, `hook end` when the turn is over and `hook close` when the session ends, each with JSON carrying
`session_id` (or `conversation_id`, and optionally `cwd`) on stdin. The hold lasts as long as the agent's
process lives; a turn with no tool call for two hours (interrupted) stops counting until its next tool call,
an ended turn counts as a paused conversation for `PAUSE_MINUTES`, and one that ends with `background_tasks`
or `session_crons` (Claude Code sends both) still counts as working. Mapped from each agent's documentation
(October 2026), not tested here:

| agent | `hook prompt` | `hook tool` | `hook end` | notes |
|---|---|---|---|---|
| Codex CLI (`~/.codex/hooks.json`) | UserPromptSubmit | PreToolUse | Stop, Interrupt (`close`: SessionEnd) | a hook runs after you trust it in `/hooks` |
| Gemini CLI (`settings.json`) | BeforeAgent | BeforeTool | AfterAgent (`close`: SessionEnd) | AfterAgent may not fire; `HOLD_HOURS` covers it |
| GitHub Copilot CLI | userPromptSubmitted | preToolUse | agentStop (`close`: sessionEnd) | also reads `.claude/settings.json` hooks |
| Cursor CLI (`~/.cursor/hooks.json`) | beforeSubmitPrompt | preToolUse | stop (`close`: sessionEnd) | sends `conversation_id`; with `-p` only tool hooks fire |
| Goose | UserPromptSubmit | PreToolUse | Stop (`close`: SessionEnd) | |
| Aider, OpenCode, Amp | — | — | — | no shell hooks: `reboot-when-idle hold aider`, or a plugin |

Commands any agent leaves running are seen through the login session they run in. An agent that is not a
login session's process (a systemd service, a container) is not; run its work under `hold`.

Anything else: `reboot-when-idle hold make -j8 all`. The hold ends with the command, however it ends.

## Commands

```
reboot-when-idle status                is a reboot due, what would hold it back now, what needs a look
reboot-when-idle hold <command> [arg]  run a command; no automatic reboot while it runs
reboot-when-idle hook prompt|tool|end  agent hooks
reboot-when-idle run                   the nightly timer (root)
reboot-when-idle boot early|check      at boot (root)
reboot-when-idle --self-test
```

What happened at night: `journalctl -u reboot-when-idle -u reboot-when-idle-trial`.

## Settings

`/etc/reboot-when-idle.conf` (shell syntax), all optional:

| setting | default | meaning |
|---|---|---|
| `MAX_UPTIME_DAYS` | 30 | reboot after this long even without updates |
| `RETRY_SECONDS` | 600 | how often to look again while something works |
| `TRY_SECONDS` | 10800 | how long one night's attempt lasts |
| `GRACE_SECONDS` | 60 | announced to agents before the reboot |
| `TYPING_MINUTES` | 30 | a terminal typed on this recently means someone works |
| `PAUSE_MINUTES` | 30 | how long a conversation holds after an agent's turn |
| `AGENT_COMMAND_HOURS` | 12 | work running longer counts as a server |
| `HOLD_HOURS` | 2 | an agent turn quiet this long no longer counts |
| `KERNEL_WITHOUT_TRIAL` | wait | or `reboot`: a new kernel GRUB cannot start once on trial |
| `KERNEL_WAIT_DAYS` | 0 | a new kernel waits this long here |
| `AGENT_NAMES` | claude codex gemini … | programs that are agents, not work |
| `TRIAL_NETWORK_SECONDS` | 600 | how long a new kernel gets to bring the network up |
| `NETWORK_CHECK` | `ip route get 1.1.1.1` | what "the network is up" means |
| `DRY_RUN` | 0 | 1: only say what would be done |

The time of night is in the timer: `systemctl edit reboot-when-idle.timer`.

## Limits

- A kernel that dies before systemd starts (very early) is started again and again: GRUB cannot write its
  environment on btrfs, so the one-time entry is used up from Linux, early in the boot.
- Agents without hooks are seen only by what runs in their login session; between two commands such an
  agent is not seen working.
- Work that leaves the login session (a `systemd-run` unit, a Docker container) is not seen: use `hold`.
- Microcode and library updates that do not create `/run/reboot-required` wait for `MAX_UPTIME_DAYS`.
- An agent that never stops (an endless loop of tool calls) holds the reboot for good; after a week `status`
  asks for a look.
- One machine's view only: machines spread their reboots over the hour by their machine-id, not by talking
  to each other.

## Similar tools

`unattended-upgrades` (`Automatic-Reboot`) reboots at a fixed time; `needrestart` says what needs a restart;
kured and Zincati coordinate reboots of Kubernetes and Fedora CoreOS fleets; [reboop](https://github.com/ludios/reboop)
(NixOS) refuses to reboot while tmux, a build or an inhibitor lock is around. None of them knows about agent
turns, and none boots a new kernel on trial on a plain GRUB system.

## Tests

`make check` runs the self-test (version logic, GRUB entries, hook input, lock parsing, agent programs).
`make test` runs about 50 scenarios on the live machine — agent turns, paused conversations, background tasks
at the end of a turn, interrupted turns, killed agents, detached commands, zombies, reused pids, a dev server
left running, apt, someone typing, a reboot that fails, work starting during the announcement, every kernel
trial outcome, a half-installed kernel, a kernel without a trial setup, no network at all, hostile files in
the hold directory — with GRUB, the reboot, the network check and the login sessions replaced by stand-ins in
a temporary directory. The scenario that holds a shutdown lock runs with `sudo -n` (as root) and is skipped without passwordless sudo.

## Accessibility

The tool is text in a terminal: its output has no colour and no pointer input. [ACCESSIBILITY.md](ACCESSIBILITY.md) says what has been checked, what has not (a screen reader check is still to be run), and how to report a barrier.

## License

MIT
