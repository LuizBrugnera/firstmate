#!/usr/bin/env bash
# Adversarial live scenarios for hc caller-terminal inheritance, against private real hc cores.
set -u
ROOT=$1
HC_ROOT=$(mktemp -d /tmp/fmhcA.XXXXXX)
FM_HOME_DIR="$HC_ROOT/home"; WORK_DIR="$HC_ROOT/work"
mkdir -p "$FM_HOME_DIR" "$WORK_DIR" "$HC_ROOT/config" "$HC_ROOT/data" "$HC_ROOT/cache"
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
A="fmA$$"; B="fmB$$"
export HC_SESSION=$A
export XDG_STATE_HOME="$HC_ROOT" XDG_RUNTIME_DIR="$HC_ROOT" XDG_CONFIG_HOME="$HC_ROOT/config"
export XDG_DATA_HOME="$HC_ROOT/data" XDG_CACHE_HOME="$HC_ROOT/cache"
export FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$FM_HOME_DIR"
cleanup() { HC_SESSION=$A hc server stop --json >/dev/null 2>&1; HC_SESSION=$B hc server stop --json >/dev/null 2>&1; rm -rf "$HC_ROOT"; }
trap cleanup EXIT
. "$ROOT/bin/fm-backend.sh"; fm_backend_source hc || exit 2
HT=$(fm_backend_hometag)
FAILS=0
check() { if [ "$1" = "$2" ]; then echo "PASS - $3 (got: $1)"; else echo "FAIL - $3 (want: $2, got: $1)"; FAILS=$((FAILS+1)); fi; }
wait_file() { local i=0; while [ $i -lt 200 ]; do [ -s "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }
desc() { fm_backend_hc_cli "$1" get --json "$2" | jq -r '[.parent // "none", .labels["herdr.space"] // ""] | @tsv' | tr '\t' ' '; }
HC_SESSION=$A hc server status --json >/dev/null || exit 3
HC_SESSION=$B hc server status --json >/dev/null || exit 3
mk() { # <session> <space> -> address
  HC_SESSION=$1 hc run --bg --json --no-parent --label herdr.space=$2 --cwd "$WORK_DIR" | jq -r '.address // empty'; }
inner() { # <file> <label> <session> -> script that runs create_task
  cat > "$HC_ROOT/$1.sh" <<EOF
unset HC_SESSION
. '$ROOT/bin/fm-backend.sh'; fm_backend_source hc
fm_backend_hc_create_task '$3' '$2' '$WORK_DIR' > '$HC_ROOT/$2.addr' 2> '$HC_ROOT/$2.err'
EOF
}
ENVP="FM_HOME='$FM_HOME_DIR' FM_ROOT_OVERRIDE='$FM_HOME_DIR'"

FM=$(mk $A fm-space); echo "stand-in Firstmate terminal: $A:$FM ($(fm_backend_hc_cli $A get --json $FM | jq -c '{pid,state,labels}'))"

# 1. Wrapper/launcher holding the foreground: create_task runs two bash levels below the shell.
inner s1 fm-wrapped $A
fm_backend_hc_cli $A send --json "$FM" "$ENVP bash -c 'bash -c \"sleep 2; bash $HC_ROOT/s1.sh\"'" >/dev/null
sleep 1; echo "  foreground while wrapper runs: $(fm_backend_hc_cli $A get --json $FM | jq -c '{pid, fg: .foreground.pid}')"
wait_file "$HC_ROOT/fm-wrapped.addr" || echo "  no addr: $(cat $HC_ROOT/fm-wrapped.err)"
C1=$(cat "$HC_ROOT/fm-wrapped.addr"); check "$(desc $A $C1)" "$FM fm-space" "1 wrapper holding foreground: child of Firstmate in its space"

# 2. FM_HC_SPACE override from inside.
inner s2 fm-override $A
fm_backend_hc_cli $A send --json "$FM" "$ENVP FM_HC_SPACE=chosen bash $HC_ROOT/s2.sh" >/dev/null
wait_file "$HC_ROOT/fm-override.addr"; C2=$(cat "$HC_ROOT/fm-override.addr")
check "$(desc $A $C2)" "$FM chosen" "2 FM_HC_SPACE wins over caller space, parent kept"

# 3. Inherited id through a daemonized process (setsid -f escapes the shell's tree, like a tmux/Herdr server).
inner s3 fm-daemon $A
fm_backend_hc_cli $A send --json "$FM" "$ENVP setsid -f bash $HC_ROOT/s3.sh </dev/null >/dev/null 2>&1" >/dev/null
wait_file "$HC_ROOT/fm-daemon.addr"; C3=$(cat "$HC_ROOT/fm-daemon.addr")
check "$(desc $A $C3)" "none fm-$HT" "3 daemonized descendant with inherited HC_TERMINAL_ID: no parent, home space"

# 3b. Inherited id through a real tmux server started inside the Firstmate terminal (private socket).
inner s3b fm-tmux $A
fm_backend_hc_cli $A send --json "$FM" "TMUX_TMPDIR=$HC_ROOT tmux -L fmhcadv new-session -d -s x \"$ENVP bash $HC_ROOT/s3b.sh\"" >/dev/null
wait_file "$HC_ROOT/fm-tmux.addr"; C3b=$(cat "$HC_ROOT/fm-tmux.addr")
check "$(desc $A $C3b)" "none fm-$HT" "3b inherited id inside a tmux server started in the terminal: no parent, home space"
TMUX_TMPDIR=$HC_ROOT tmux -L fmhcadv kill-server 2>/dev/null

# 4. Id from another session: a terminal in core B creates a task in core A. Make sure core A has a live
#    terminal with the SAME address (unrelated), so only the session/ancestry checks can reject it.
FB=$(mk $B space-b); echo "  core B terminal: $B:$FB (core A has $FM live with same-style address)"
inner s4 fm-foreign $A
fm_backend_hc_cli $B send --json "$FB" "$ENVP bash $HC_ROOT/s4.sh" >/dev/null
wait_file "$HC_ROOT/fm-foreign.addr"; C4=$(cat "$HC_ROOT/fm-foreign.addr")
check "$(desc $A $C4)" "none fm-$HT" "4 id from another session (address collides with a live A terminal): no parent"

# 5. Stale / unknown id from outside.
C5=$(HC_TERMINAL_ID=t999 fm_backend_hc_create_task $A fm-stale "$WORK_DIR" 2>&1) || echo "  error: $C5"
check "$(desc $A $C5)" "none fm-$HT" "5 unknown HC_TERMINAL_ID: no parent, no error"

# 5b. A live but non-ancestor terminal id set by hand from outside.
C5b=$(HC_TERMINAL_ID=$FM fm_backend_hc_create_task $A fm-nonanc "$WORK_DIR" 2>&1) || echo "  error: $C5b"
check "$(desc $A $C5b)" "none fm-$HT" "5b live non-ancestor terminal id: no parent, home space"

# 6. --outlive-parent: closing the Firstmate terminal leaves its children running.
fm_backend_hc_cli $A kill --json "$FM" >/dev/null 2>&1
sleep 1
check "$(fm_backend_hc_cli $A get --json $FM 2>/dev/null | jq -r '.state // "gone"' || echo gone)" finished "6a Firstmate terminal state after close"
for c in $C1 $C2; do check "$(fm_backend_hc_cli $A get --json $c | jq -r .state)" live "6 child $c still live after its Firstmate terminal closed"; done

# 6b. After the parent is gone, a stale id from a previously-valid Firstmate falls back.
C6=$(HC_TERMINAL_ID=$FM fm_backend_hc_create_task $A fm-after "$WORK_DIR" 2>&1) || echo "  error: $C6"
check "$(desc $A $C6)" "none fm-$HT" "6b stale id of the closed Firstmate terminal: no parent"

echo "--- core A listing"; fm_backend_hc_cli $A ls --json | jq -c '(if type=="array" then .[] else (.terminals // .items // [])[] end) | {address, parent, state, space: .labels["herdr.space"], tab: .labels["herdr.tab"]}' 2>/dev/null
echo "FAILS=$FAILS"
