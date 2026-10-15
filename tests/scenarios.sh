#!/bin/bash
# Scenarios on a live machine, expected and unexpected. Nothing reboots and nothing outside a temporary
# directory changes: GRUB, the reboot and the network check are stand-ins writing into it, holds and state
# live in it, fake agent commands carry a marker of their own. Needs no root (one scenario uses sudo -n).
#   tests/scenarios.sh            all of them
#   tests/scenarios.sh <name>...  only these (names as listed by the run)
set -u
tool=$(cd "$(dirname "$0")/.." && pwd)/reboot-when-idle
T=$(mktemp -d /tmp/rwi-test.XXXXXX)
marker=rwi-fake-agent-$$
running=$(uname -r)
newer=${running%%.*}.999.0+${running#*+}   # same flavour, newer than the running kernel
newest=${running%%.*}.1000.0+${running#*+}
older=${running%%.*}.0.1+${running#*+}
passed=0 failures=()

cleanup() {
  jobs -p | xargs -r kill 2> /dev/null
  pkill -f -- "$marker" 2> /dev/null  # only our fake agent commands carry it
  wait 2> /dev/null
  rm -rf "$T"
}
trap cleanup EXIT

fake() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1" && chmod +x "$T/bin/$1"; }
mkdir -p "$T/bin"
fake grub-editenv "f=$T/grubenv"'; case $1 in list) cat "$f" ;; -) [[ $2 == unset ]] && sed -i "/^$3=/d" "$f" ;; esac'
fake grub-reboot "f=$T/grubenv"'; sed -i "/^next_entry=/d" "$f"; echo "next_entry=$1" >> "$f"'"; echo \"grub-reboot \$1\" >> $T/log"
fake grub-set-default "f=$T/grubenv"'; sed -i "/^saved_entry=/d" "$f"; echo "saved_entry=$1" >> "$f"'"; echo \"grub-set-default \$1\" >> $T/log"
fake reboot "echo reboot >> $T/log; touch $T/rebooted; exit \$(cat $T/reboot-exit)"
fake network "exit \$(cat $T/net)"
cp /bin/sleep "$T/bin/apt-get"

entry() { echo "gnulinux-advanced-u1>gnulinux-$1-advanced-u1"; }

grubcfg() {  # grubcfg [--no-saved] <kernel>...: a grub.cfg like Debian's
  local saved=1 k
  [[ $1 != --no-saved ]] || { saved=0; shift; }
  echo 'if [ "${next_entry}" ] ; then'
  echo '   set default="${next_entry}"'
  echo 'else'
  ((saved)) && echo '   set default="${saved_entry}"' || echo '   set default="0"'
  echo 'fi'
  echo "menuentry 'Debian GNU/Linux' \$menuentry_id_option 'gnulinux-simple-u1' {"
  echo "submenu 'Advanced options for Debian GNU/Linux' \$menuentry_id_option 'gnulinux-advanced-u1' {"
  for k; do
    printf "\tmenuentry 'Debian GNU/Linux, with Linux %s' \$menuentry_id_option 'gnulinux-%s-advanced-u1' {\n" "$k" "$k"
    printf "\tmenuentry 'Debian GNU/Linux, with Linux %s (recovery mode)' \$menuentry_id_option 'gnulinux-%s-recovery-u1' {\n" "$k" "$k"
  done
}

machine() {  # machine <kernel>...: a fresh machine with these kernels installed besides the running one
  local k
  jobs -p | xargs -r kill 2> /dev/null
  pkill -f -- "$marker" 2> /dev/null
  wait 2> /dev/null
  rm -rf "$T/run" "$T/state" "$T/boot" "$T/rebooted" "$T/cg"
  mkdir -p "$T/run/hold" "$T/boot" "$T/cg/session-1.scope" && chmod 1777 "$T/run/hold"
  : > "$T/cg/session-1.scope/cgroup.procs"
  : > "$T/grubenv"
  : > "$T/log"
  echo 0 > "$T/net"
  echo 0 > "$T/reboot-exit"
  for k in "$running" "$@"; do touch "$T/boot/vmlinuz-$k" "$T/boot/initrd.img-$k"; done
  grubcfg "$running" "$@" > "$T/grub.cfg"
  cat > "$T/conf" << EOF
RUN_DIR=$T/run
STATE_DIR=$T/state
BOOT_DIR=$T/boot
GRUB_CFG=$T/grub.cfg
GRUB_EDITENV=$T/bin/grub-editenv
GRUB_REBOOT=$T/bin/grub-reboot
GRUB_SET_DEFAULT=$T/bin/grub-set-default
REBOOT_COMMAND=$T/bin/reboot
NETWORK_CHECK=$T/bin/network
AGENT_COMMAND_PATTERN=$marker
SESSION_CGROUPS="$T/cg/*.scope"
RETRY_SECONDS=1
TRY_SECONDS=5
GRACE_SECONDS=1
TRIAL_NETWORK_SECONDS=2
EOF
}

set_conf() { echo "$1" >> "$T/conf"; }
rwi() { REBOOT_WHEN_IDLE_CONF=$T/conf "$tool" "$@"; }
trial() { printf 'kernel=%s\nfrom=%s\nstate=%s\nreason=test\ndate=2026-10-01 03:30\n' "$@" > "$T/state/trial"; }
state() { sed -n "s/^state=//p" "$T/state/trial" 2> /dev/null; }

agent() {  # agent <session> <seconds> [event]: a process like an agent (not a shell) that runs the hook, then lives
  AGENT_OUT=$T/agent-$1 python3 - "$tool" "$T/conf" "$1" "$2" "${3:-prompt}" << 'PY' &
import json, os, subprocess, sys, time
tool, conf, session, seconds, event = sys.argv[1:]
r = subprocess.run([tool, 'hook', event], text=True, capture_output=True,
                   input=json.dumps({'session_id': session, 'cwd': '/work/' + session}),
                   env=dict(os.environ, REBOOT_WHEN_IDLE_CONF=conf))
open(os.environ['AGENT_OUT'], 'w').write(f'{r.returncode}\n{r.stdout}{r.stderr}')
time.sleep(float(seconds))
PY
  sleep 0.4
}

agent_json() {  # agent_json <json> <seconds> [event]: like agent, with the hook input as given
  python3 -c '
import os, subprocess, sys, time
subprocess.run([sys.argv[1], "hook", sys.argv[5]], input=sys.argv[3], text=True,
               env=dict(os.environ, REBOOT_WHEN_IDLE_CONF=sys.argv[2]))
time.sleep(float(sys.argv[4]))' "$tool" "$T/conf" "$1" "$2" "${3:-prompt}" &
  sleep 0.4
}

agent_command() { bash -c "sleep $1; : $marker" & }  # an agent's command, as pgrep sees it

check() {  # check <what should be so> <command...>
  if "${@:2}"; then
    passed=$((passed + 1))
    printf '  ok    %s\n' "$1"
  else
    failures+=("$scenario: $1")
    printf '  FAIL  %s\n' "$1"
  fi
}
has() { grep -q -- "$2" "$1" 2> /dev/null; }
hasnt() { ! grep -q -- "$2" "$1" 2> /dev/null; }
rebooted() { [[ -e $T/rebooted ]]; }
not_rebooted() { [[ ! -e $T/rebooted ]]; }

# --- expected -----------------------------------------------------------------------------------------

s_idle_new_kernel() {
  machine "$newer"
  rwi run > "$T/out" 2>&1
  check 'reboots' rebooted
  check 'pins the running kernel as the default' has "$T/log" "grub-set-default $(entry "$running")"
  check 'starts the new kernel once' has "$T/log" "grub-reboot $(entry "$newer")"
  check 'records a pending trial' [ "$(state)" = pending ]
  check 'remembers the reboot and why' has "$T/state/last-reboot" "kernel $newer is installed"
  check 'announces the grace period' has "$T/out" 'rebooting in 1 s unless work starts'
}

s_nothing_due() {
  machine
  rwi run > "$T/out" 2>&1
  check 'does not reboot' not_rebooted
  check 'says so' has "$T/out" 'no reboot due'
}

s_dry_run() {
  machine "$newer"
  set_conf DRY_RUN=1
  rwi run > "$T/out" 2>&1
  check 'does not reboot' not_rebooted
  check 'touches no GRUB setting' [ ! -s "$T/log" ]
  check 'says what it would do' has "$T/out" 'would reboot'
}

s_agent_turn() {
  machine "$newer"
  agent s1 30
  (sleep 2.5 && echo '{"session_id":"s1"}' | rwi hook close) &
  rwi run > "$T/out" 2>&1
  check 'waits while the turn runs' has "$T/out" 'waiting: python3 in /work/s1'
  check 'reboots once the session is closed' rebooted
}

s_background_command_after_turn() {
  machine "$newer"
  agent_command 3
  rwi run > "$T/out" 2>&1
  check 'waits for the command an agent left running' has "$T/out" 'an agent runs 1 command'
  check 'reboots after it' rebooted
}

s_dev_server_left_running() {
  machine "$newer"
  set_conf AGENT_COMMAND_HOURS=0
  agent_command 30
  rwi status > "$T/status" 2>&1
  rwi run > "$T/out" 2>&1
  check 'a command older than AGENT_COMMAND_HOURS does not hold' rebooted
  check 'status still mentions it' has "$T/status" 'not counted: 1 agent command'
}

s_hold_command() {
  machine "$newer"
  rwi hold sleep 3 &
  sleep 0.3
  rwi run > "$T/out" 2>&1
  check 'waits for the held command' has "$T/out" 'waiting: sleep 3'
  check 'reboots after it' rebooted
  rwi hold sh -c 'exit 7'
  check 'hold passes the exit code on' [ $? = 7 ]
}

s_several_agents() {
  machine "$newer"
  agent s1 10
  agent s2 10
  agent s3 10
  rwi status > "$T/status" 2>&1
  check 'all three turns are listed' [ "$(grep -c 'python3 in /work/s' "$T/status")" = 3 ]
}

s_apt_running() {
  machine "$newer"
  "$T/bin/apt-get" 3 &
  sleep 0.3
  rwi run > "$T/out" 2>&1
  check 'waits for apt' has "$T/out" 'the package manager runs'
  check 'reboots after it' rebooted
}

s_someone_typing() {
  machine "$newer"
  script -qc 'sleep 3' /dev/null > /dev/null 2>&1 &
  sleep 0.5
  rwi status > "$T/status" 2>&1
  check 'a fresh terminal counts as someone working' has "$T/status" 'someone typed on a terminal'
}

s_logind_lock() {
  sudo -n true 2> /dev/null || { echo '  skip  (needs sudo -n)'; return; }
  machine "$newer"
  sudo -n systemd-inhibit --what=shutdown --mode=block --who=Backup --why='copying' sleep 3 &
  sleep 0.5
  rwi run > "$T/out" 2>&1
  check 'waits for a lock that blocks shutdown' has "$T/out" 'Backup holds a lock: copying'
  check 'reboots after it' rebooted
}

s_failed_trial_not_retried() {
  machine "$newer"
  mkdir -p "$T/state"
  trial "$newer" "$running" failed
  rwi run > "$T/out" 2>&1
  rwi status > "$T/status" 2>&1
  check 'does not reboot into a kernel that failed' not_rebooted
  check 'status asks for a look' has "$T/status" "kernel $newer failed its trial boot"
}

s_newer_than_failed() {
  machine "$newer" "$newest"
  mkdir -p "$T/state"
  trial "$newer" "$running" failed
  rwi run > "$T/out" 2>&1
  check 'tries a kernel newer than the failed one' has "$T/log" "grub-reboot $(entry "$newest")"
}

# --- boot ---------------------------------------------------------------------------------------------

s_boot_early() {
  machine
  echo "next_entry=$(entry "$newer")" > "$T/grubenv"
  rwi boot early > "$T/out" 2>&1
  check 'uses up the one-time entry' hasnt "$T/grubenv" next_entry
  rwi boot early > "$T/out" 2>&1
  check 'without one it does nothing' [ ! -s "$T/out" ]
}

s_trial_works() {
  machine "$older"
  mkdir -p "$T/state"
  trial "$running" "$older" pending
  rwi boot check > "$T/out" 2>&1
  check 'keeps the new kernel' [ "$(state)" = ok ]
  check 'makes it the default' has "$T/grubenv" "saved_entry=$(entry "$running")"
}

s_trial_no_network() {
  machine "$older"
  mkdir -p "$T/state"
  trial "$running" "$older" pending
  echo 1 > "$T/net"
  rwi boot check > "$T/out" 2>&1
  check 'gives up on the kernel' [ "$(state)" = reverted ]
  check 'reboots back' rebooted
  check 'does not make it the default' hasnt "$T/grubenv" saved_entry
}

s_trial_back_with_network() {
  machine "$newer"
  mkdir -p "$T/state"
  trial "$newer" "$running" reverted
  rwi boot check > "$T/out" 2>&1
  check 'the old kernel has a network, so the new one failed' [ "$(state)" = failed ]
  rwi status > "$T/status" 2>&1
  check 'and is not due any more' has "$T/status" 'no reboot due'
}

s_trial_network_down_everywhere() {
  machine "$newer"
  mkdir -p "$T/state"
  trial "$newer" "$running" reverted
  echo 1 > "$T/net"
  rwi boot check > "$T/out" 2>&1
  check 'no network with either kernel is not the kernel'"'"'s fault' [ "$(state)" = retry ]
  rwi status > "$T/status" 2>&1
  check 'so it is due again' has "$T/status" "kernel $newer is installed"
}

s_trial_crashed() {
  machine "$newer"
  mkdir -p "$T/state"
  trial "$newer" "$running" pending
  rwi boot check > "$T/out" 2>&1
  check 'a trial kernel that is not running failed' [ "$(state)" = failed ]
  check 'says why' has "$T/out" 'did not come up'
}

s_saved_entry_removed() {
  machine
  echo "saved_entry=$(entry "$older")" > "$T/grubenv"
  rwi boot check > "$T/out" 2>&1
  check 'GRUB is pointed at the running kernel again' has "$T/grubenv" "saved_entry=$(entry "$running")"
}

s_half_installed_kernel() {
  machine "$newer"
  rm "$T/boot/initrd.img-$newer"
  rwi run > "$T/out" 2>&1
  rwi status > "$T/status" 2>&1
  check 'does not reboot into a kernel without its initrd' not_rebooted
  check 'status asks for a look' has "$T/status" "kernel $newer looks half-installed"
}

s_kernel_waits_days() {
  machine "$newer"
  set_conf KERNEL_WAIT_DAYS=3
  rwi run > "$T/out" 2>&1
  rwi status > "$T/status" 2>&1
  check 'a kernel installed today waits KERNEL_WAIT_DAYS' not_rebooted
  check 'status says until when' has "$T/status" "kernel $newer waits until"
}

s_conversation_paused() {
  machine "$newer"
  agent s1 30
  agent s1 30 end
  rwi status > "$T/status" 2>&1
  check 'right after a turn the conversation holds' has "$T/status" 'a conversation with python3 in /work/s1, paused 0 min ago'
  agent s1 30 prompt
  check 'the next prompt makes it a turn again' hasnt "$T/run/hold/agent-s1" 'paused=1'
  agent s1 30 end
  touch -d '31 minutes ago' "$T/run/hold/agent-s1"
  rwi run > "$T/out" 2>&1
  check 'after PAUSE_MINUTES it lets go' rebooted
}

s_background_task_at_turn_end() {
  machine "$newer"
  agent_json '{"session_id":"s1","cwd":"/work/s1","background_tasks":[{"id":"b1","status":"running"}],"session_crons":[]}' 30 end
  check 'a turn ending with background tasks still works' grep -q '^paused=$' "$T/run/hold/agent-s1"
  agent_json '{"session_id":"s2","cwd":"/work/s2","background_tasks":[],"session_crons":[{"id":"c1"}]}' 30 end
  check 'so does one with scheduled prompts' grep -q '^paused=$' "$T/run/hold/agent-s2"
  agent_json '{"session_id":"s3","cwd":"/work/s3","background_tasks":[],"session_crons":[]}' 30 end
  check 'one with neither is a paused conversation' grep -q '^paused=[0-9]' "$T/run/hold/agent-s3"
}

s_work_in_login_sessions() {
  machine "$newer"
  local scope=$T/cg/session-1.scope/cgroup.procs pids
  # an agent (argv0 claude) with a helper it starts at once and a command it runs through a shell
  bash -c "exec -a claude python3 -c '
import subprocess, time
subprocess.Popen([\"sleep\", \"30.01\"])
time.sleep(1.5)
subprocess.Popen([\"bash\", \"-c\", \"sleep 30.02; true\"])
time.sleep(30)'" &
  sleep 2
  bash -c 'nohup sleep 30.03 > /dev/null 2>&1 &'  # detached: its parent is gone at once
  sleep 0.3
  local agent helper command shell detached work
  agent=$(pgrep -f '^claude -c') helper=$(pgrep -fx 'sleep 30.01') command=$(pgrep -fx 'sleep 30.02')
  shell=$(pgrep -fx 'bash -c sleep 30.02; true') detached=$(pgrep -fx 'sleep 30.03')
  printf '%s\n' "$agent" "$helper" "$command" "$shell" "$detached" > "$scope"
  rwi status > "$T/status" 2>&1
  work=$(grep 'running in login sessions' "$T/status")
  check 'a command the agent runs through a shell counts' grep -q "sleep (pid $command," <<< "$work"
  check 'a detached command counts' grep -q "sleep (pid $detached," <<< "$work"
  check 'a helper the agent started at once does not' grep -vq "pid $helper," <<< "$work"
  check 'the agent and shells do not' grep -vqE "pid ($agent|$shell)," <<< "$work"
  # from a shell of its own: what this script starts counts as the fake agent's helper
  REBOOT_WHEN_IDLE_CONF=$T/conf bash -c '{ sleep 0.3; "$0" status; } | { echo "$BASHPID" >> "$1"; exec cat; }' \
    "$tool" "$scope" > "$T/piped"
  check 'what reads the status through a pipe does not (status | grep)' hasnt "$T/piped" 'cat (pid'
  set_conf AGENT_COMMAND_HOURS=0
  rwi status > "$T/status" 2>&1
  check 'older than AGENT_COMMAND_HOURS it is a server' has "$T/status" 'not counted, running longer'
}

# --- unexpected ---------------------------------------------------------------------------------------

s_interrupted_turn() {
  machine "$newer"
  agent s1 30
  touch -d '3 hours ago' "$T/run/hold/agent-s1"
  rwi run > "$T/out" 2>&1
  check 'a turn quiet for HOLD_HOURS (interrupted) no longer holds' rebooted
  agent s1 30 tool
  rwi status > "$T/status" 2>&1
  check 'its next tool call holds again' has "$T/status" 'python3 in /work/s1'
}

s_agent_killed() {
  machine "$newer"
  agent s1 30
  pkill -9 -f "python3 - $tool $T/conf s1"
  sleep 0.3
  rwi run > "$T/out" 2>&1
  check 'a dead agent does not hold' rebooted
  check 'its file is cleaned up' [ ! -e "$T/run/hold/agent-s1" ]
}

s_held_command_killed() {
  machine "$newer"
  rwi hold sleep 30 &
  sleep 0.3
  local pid
  pid=$(ls "$T/run/hold" | sed -n 's/^command-//p')
  kill -TERM "$pid"
  sleep 0.3
  rwi run > "$T/out" 2>&1
  check 'a killed held command stops holding' rebooted
}

s_zombie() {
  machine "$newer"
  REBOOT_WHEN_IDLE_CONF=$T/conf python3 -c '
import os, sys, time
if os.fork() == 0:
    os.execvp(sys.argv[1], [sys.argv[1], "hold", "true"])
time.sleep(4)' "$tool" &
  sleep 1
  REBOOT_WHEN_IDLE_CONF=$T/conf rwi status > "$T/status" 2>&1
  check 'a zombie does not hold' has "$T/status" 'nothing is working now'
}

s_reused_pid() {
  machine "$newer"
  printf 'pid=%s\nstart=1\nkind=command\nwhat=long gone\n' $$ > "$T/run/hold/command-$$"
  rwi status > "$T/status" 2>&1
  check 'a pid now used by another process does not hold' has "$T/status" 'nothing is working now'
}

s_hostile_hold_files() {
  machine "$newer"
  ln -s /etc/passwd "$T/run/hold/agent-link"
  printf 'pid=1; rm -rf /\nwhat=$(id)\n' > "$T/run/hold/junk"
  printf 'pid=1\nkind=command\nwhat=init forever\n' > "$T/run/hold/no-start"
  rwi run > "$T/out" 2>&1
  check 'junk, links and holds without a start time are ignored' rebooted
  check 'nothing was executed from them' hasnt "$T/out" 'uid='
}

s_garbage_hook_input() {
  machine
  echo 'not json' | rwi hook prompt
  check 'garbage on stdin is fine' [ $? = 0 ]
  echo '{"session_id":"../../etc/x"}' | rwi hook prompt
  check 'a session id with a path in it is refused' [ -z "$(ls -A "$T/run/hold")" ]
  rm -rf "$T/run"
  echo '{"session_id":"s1"}' | rwi hook prompt 2> "$T/err"
  check 'a missing hold directory does not fail the agent' [ $? = 0 ]
  check 'nor print anything' [ ! -s "$T/err" ]
}

s_cursor_style_hook() {
  machine
  agent_json '{"conversation_id":"c1","workspace_roots":["/work"]}' 3
  check 'an agent that says conversation_id instead of session_id holds too' [ -e "$T/run/hold/agent-c1" ]
}

s_prompt_while_rebooting() {
  machine
  echo 'kernel X is installed' > "$T/run/rebooting"
  agent s1 2
  check 'a new prompt is turned away during the grace period' [ "$(head -1 "$T/agent-s1")" = 2 ]
  check 'with a reason the user sees' has "$T/agent-s1" 'This machine is rebooting now'
  check 'and does not hold' [ ! -e "$T/run/hold/agent-s1" ]
  touch -d '1 hour ago' "$T/run/rebooting"
  agent s2 2
  check 'an old marker (failed reboot) turns nobody away' [ "$(head -1 "$T/agent-s2")" = 0 ]
}

s_work_starts_in_grace() {
  machine "$newer"
  set_conf GRACE_SECONDS=2
  set_conf TRY_SECONDS=12
  (sleep 1 && rwi hold sleep 2) &
  rwi run > "$T/out" 2>&1
  check 'calls the reboot off' has "$T/out" 'work started meanwhile'
  check 'reboots once that work is done' rebooted
}

s_never_quiet() {
  machine "$newer"
  set_conf TRY_SECONDS=3
  rwi hold sleep 30 &
  sleep 0.3
  rwi run > "$T/out" 2>&1
  check 'gives up for the night without rebooting' not_rebooted
  check 'says so' has "$T/out" 'no quiet moment this night'
  check 'remembers since when it is due' [ -e "$T/state/due-since" ]
  touch -d '8 days ago' "$T/state/due-since"
  rwi status > "$T/status" 2>&1
  check 'after a week it asks for a look' has "$T/status" 'every night something was working'
}

s_reboot_command_fails() {
  machine "$newer"
  echo 1 > "$T/reboot-exit"
  set_conf TRY_SECONDS=2
  rwi run > "$T/out" 2>&1
  check 'says the reboot failed' has "$T/out" 'the reboot command failed'
  check 'leaves no one-time entry behind' hasnt "$T/grubenv" next_entry
  check 'leaves no pending trial behind' [ "$(state)" != pending ]
  check 'takes the announcement back' [ ! -e "$T/run/rebooting" ]
}

s_untried_kernel_waits() {
  machine "$newer"
  grubcfg --no-saved "$running" "$newer" > "$T/grub.cfg"
  set_conf MAX_UPTIME_DAYS=0
  set_conf TRY_SECONDS=2
  rwi run > "$T/out" 2>&1
  rwi status > "$T/status" 2>&1
  check 'without a trial setup a new kernel waits, by default' not_rebooted
  check 'so do other reasons, since any reboot would start that kernel' has "$T/out" 'no reboot due'
  check 'status says why and what to do' has "$T/status" 'GRUB here cannot start it once'
}

s_grub_without_saved_default() {
  machine "$newer"
  grubcfg --no-saved "$running" "$newer" > "$T/grub.cfg"
  set_conf KERNEL_WITHOUT_TRIAL=reboot
  rwi run > "$T/out" 2>&1
  check 'reboots without a trial setup' rebooted
  check 'touches no GRUB setting' [ ! -s "$T/grubenv" ]
  check 'still remembers the kernel, so it cannot loop' [ "$(state)" = pending ]
}

s_grub_entry_missing() {
  machine "$newer"
  grubcfg "$running" > "$T/grub.cfg"
  set_conf TRY_SECONDS=2
  rwi run > "$T/out" 2>&1
  check 'does not reboot into a kernel GRUB does not list' not_rebooted
  check 'marks it failed' [ "$(state)" = failed ]
}

s_hold_dir_missing() {
  machine "$newer"
  rm -rf "$T/run"
  rwi run > "$T/out" 2>&1
  check 'run makes the hold directory again' [ -d "$T/run/hold" ]
  check 'and reboots' rebooted
}

s_no_network_at_all() {
  machine "$newer"
  if ! unshare -rn true 2> /dev/null; then echo '  skip  (no user namespaces)'; return; fi
  unshare -rn env REBOOT_WHEN_IDLE_CONF="$T/conf" "$tool" run > "$T/out" 2>&1
  check 'works without any network' rebooted
}

s_hook_is_fast() {
  machine
  agent s1 20
  local start end i
  start=$(date +%s%N)
  for i in $(seq 50); do echo '{"session_id":"s1","cwd":"/work/s1"}' | rwi hook tool; done
  end=$(date +%s%N)
  echo "        $(((end - start) / 50000000)) ms per tool call"
  check 'a tool-call hook takes under 50 ms' [ $(((end - start) / 50000000)) -lt 50 ]
}

all=$(declare -F | sed -n 's/^declare -f s_//p')
for scenario in ${@:-$all}; do
  echo "$scenario"
  "s_$scenario"
done
echo
echo "$passed passed, ${#failures[@]} failed"
for f in "${failures[@]}"; do echo "  FAIL $f"; done
[[ ${#failures[@]} -eq 0 ]]
