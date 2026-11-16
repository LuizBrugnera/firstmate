#!/usr/bin/env bash
# usage: drive.sh <repo-root> <label>
set -u
REPO=$1; LABEL=$2; T=$(cat /tmp/lavish-utf8-dir)
. "$REPO/tests/lib.sh"
export LAVISH_AXI_PORT=4791 LAVISH_AXI_STATE_DIR=$T/lavish-state BROWSER=/bin/true
TMP_ROOT=$T/homes-$LABEL; mkdir -p $TMP_ROOT
TASKS_AXI_BIN=$(command -v tasks-axi)
home="$TMP_ROOT/h"; mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
fm_test_tasks_toml "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fb=$(fm_fakebin "$home"); fm_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
cap(){ PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
pe(){ PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" "$ROOT/bin/fm-procevent.sh" "$@"; }
board="$T/board/board-$LABEL.html"; cp $T/board/board.html "$board"
(cd $T/board && lavish-axi "$board" >/dev/null 2>&1) || { echo "open failed"; exit 1; }
key=$(curl -s http://127.0.0.1:4791/api/poll?file=x >/dev/null; ls -t $T/lavish-state 2>/dev/null >/dev/null; lavish-axi "$board" 2>/dev/null | sed -n 's/.*session\/\([0-9a-f]*\)".*/\1/p')
echo "== [$LABEL] lavish session key: $key"
cap hold sample-accent-call --title "Escolher rota" --reason "captain choice pending" --repo sample >/dev/null || echo "hold1 failed"
cap hold sample-arrow-call --title "Escolher ação" --reason "captain choice pending" --repo sample >/dev/null || echo "hold2 failed"
cap hold sample-latin-call --title "Latin1 only" --reason "captain choice pending" --repo sample >/dev/null || echo "hold4 failed"
cap hold sample-chat-call --title "Chat control" --reason "captain choice pending" --repo sample >/dev/null || echo "hold3 failed"
sid=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$board" 2>/dev/null || echo lavish-b0a4d0000000f1e3)
echo "== source id: $sid"
pe register lavish "$sid" -- lavish-axi poll "$board" >/dev/null || echo "register failed"
cap bind "$sid" >/dev/null || echo "bind failed"
# Captain answers on the board (same JSON the bearings/decision board posts)
python3 - "$key" <<'PY'
import json,sys,urllib.request
key=sys.argv[1]
def ctx(q,note): return "Context data: "+json.dumps({"schema":"fm-bearings-answer.v1","question":q,"selection":"","note":note},ensure_ascii=False)
body={"prompts":[
 {"tag":"choice","text":"Decisão: não, só depois da revisão","prompt":ctx("sample-accent-call","não, só depois da revisão — ação já é ótima, coração")},
  {"tag":"choice","text":"Opção: sim","prompt":ctx("sample-latin-call","sim, mas só após a revisão; coração e ação")},
 {"tag":"choice","text":"Ação: revisar → depois","prompt":ctx("sample-arrow-call","revisar → depois, pôr ê/õ/ç")}],
 "endSession":True}
req=urllib.request.Request(f"http://127.0.0.1:4791/api/{key}/prompts",data=json.dumps(body,ensure_ascii=False).encode("utf-8"),headers={"Content-Type":"application/json; charset=utf-8","Origin":"http://127.0.0.1:4791","Host":"127.0.0.1:4791"},method="POST")
print("== board POST:",urllib.request.urlopen(req).read().decode()[:120])
PY
echo "== procevent start"; timeout 90 bash -c "$(declare -f pe); home='$home'; ROOT='$ROOT'; TASKS_AXI_BIN='$TASKS_AXI_BIN'; pe start '$sid'" 2>&1 | tail -5
# Chat control path
printf "%s\n" "não, só depois da revisão — ação já é ótima, coração" > "$home/chat-decision.txt"
cap answer sample-chat-call --decision-file "$home/chat-decision.txt" 2>&1 | tail -2
for t in sample-accent-call sample-latin-call sample-arrow-call sample-chat-call; do echo "== tasks-axi show $t"; (cd "$home" && tasks-axi show $t --full) | grep -E "state:|Answer|body" | sed "s/.*Captain decision://" ; done
