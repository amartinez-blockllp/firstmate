#!/usr/bin/env bash
# Live driver: a real firstmate checkout (clone of the target commit) acting as
# a secondmate home, real treehouse 2.3.0 slots, and the real Claude Code CLI
# in a private pty with a throwaway CLAUDE_CONFIG_DIR (no login, no prompt sent).
# Usage: live-driver.sh <lab> <evidence-dir> <base-sha>
set -u
LAB=$1 E=$2 BASE=$3
export HOME=$LAB/user-home
unset XDG_STATE_HOME TREEHOUSE_ROOT CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT
MATE=$LAB/mate
PROMPT_RE='Allow external CLAUDE\.md file imports|disable external imports|allow external imports'
READY_RE='bypass permissions on|shift\+tab to cycle|/effort'

# The base commit's copy of the two scripts, for the before/after contrast.
mkdir -p "$LAB/base/bin"
git -C "$MATE" show "$BASE:bin/fm-claude-trust.sh" > "$LAB/base/bin/fm-claude-trust.sh"
git -C "$MATE" show "$BASE:bin/fm-primary-scope-lib.sh" > "$LAB/base/bin/fm-primary-scope-lib.sh"
chmod +x "$LAB/base/bin/"*.sh

new_config() {  # <name> -> dir
  local c=$LAB/cfg-$1
  rm -rf "$c"; mkdir -p "$c"
  printf '{"hasCompletedOnboarding":true}\n' > "$c/.claude.json"
  printf '{"skipDangerousModePermissionPrompt":true}\n' > "$c/settings.json"
  printf '%s\n' "$c"
}

# probe <name> <cwd> <config>: launch claude, type /context once it is ready,
# save the screen, and report prompt/composer/memory-file findings.
probe() {
  local name=$1 cwd=$2 c=$3 out=$E/$1.screen.txt
  python3 "$E/screen.py" "$cwd" 45 "$PROMPT_RE|$READY_RE" "$out" "/context" -- \
    env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$c" \
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --debug
  if grep -Eq "$PROMPT_RE" "$out"; then echo "  [$name] screen: IMPORT PROMPT SHOWN (\"Allow external CLAUDE.md file imports?\")"
  else echo "  [$name] screen: no import prompt"; fi
  if grep -Eq "$READY_RE" "$out" && ! grep -Eq "$PROMPT_RE" "$out"; then echo "  [$name] screen: reached the ready composer"; fi
  if grep -q 'Memory files' "$out"; then
    echo "  [$name] /context Memory files section:"; grep -oE 'Memory files.{0,250}' "$out" | head -3 | sed 's/^/     /'
  else echo "  [$name] /context: no Memory files section"; fi
  echo "  [$name] claude --debug memory lines:"
  grep -hiE 'CLAUDE\.md|AGENTS\.md|external include|memory file' "$c"/debug/*.txt 2>/dev/null | sed -E 's/^[0-9T:.Z-]+ //' | sort -u | head -8 | sed 's/^/     /'
}

store() { echo "  store ($1/.claude.json projects):"; node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(j.projects??{},null,2))' "$1/.claude.json" | sed 's/^/     /'; }

pool_new=$(bash -c '. "$1/bin/fm-primary-scope-lib.sh"; fm_treehouse_pool_root "$1"' _ "$MATE")
pool_old=$(bash -c '. "$1"; fm_treehouse_pool_root "$2"' _ "$LAB/base/bin/fm-primary-scope-lib.sh" "$MATE")
echo "secondmate home (real firstmate checkout at $(git -C "$MATE" rev-parse --short HEAD)): $MATE"
echo "  CLAUDE.md in home: $(grep -v '^<!--' "$MATE/CLAUDE.md")"
echo "  pool root, this change : $pool_new"
echo "  pool root, base $BASE: $pool_old"

lease() {  # <root> -> slot path
  (cd "$MATE/projects/app" && treehouse get --lease --no-fetch --root "$1" 2>/dev/null)
}

echo
echo "=== S2: new worker slot (this change) - trust registered by this change's fm-claude-trust.sh"
SLOT_NEW=$(lease "$pool_new"); echo "  slot: $SLOT_NEW"
C=$(new_config s2); CLAUDE_CONFIG_DIR=$C "$MATE/bin/fm-claude-trust.sh" "$SLOT_NEW" "$MATE/projects/app" | sed 's/^/  /'
store "$C"; probe s2-new-slot "$SLOT_NEW" "$C"

echo
echo "=== S3: regression reproduction - base $BASE pools in-home; base trust script"
SLOT_OLD=$(lease "$pool_old"); echo "  slot: $SLOT_OLD"
C=$(new_config s3); CLAUDE_CONFIG_DIR=$C "$LAB/base/bin/fm-claude-trust.sh" "$SLOT_OLD" "$MATE/projects/app" | sed 's/^/  /'
store "$C"; probe s3-base-inhome-slot "$SLOT_OLD" "$C"

MAIN_REAL=$(cd "$MATE/projects/app" && pwd -P)
seed_yes() {  # <config> : someone once answered Yes on the main-checkout entry
  node -e 'const fs=require("fs");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));j.projects??={};j.projects[k]={allowedTools:["Bash(ls)"],hasTrustDialogAccepted:true,hasClaudeMdExternalIncludesWarningShown:true,hasClaudeMdExternalIncludesApproved:true};fs.writeFileSync(s,JSON.stringify(j,null,2)+"\n")' "$1/.claude.json" "$MAIN_REAL"
}

echo
echo "=== S4a: hazard control - in-home slot, a stored Yes on the main checkout entry, base trust script"
C=$(new_config s4a); seed_yes "$C"
CLAUDE_CONFIG_DIR=$C "$LAB/base/bin/fm-claude-trust.sh" "$SLOT_OLD" "$MATE/projects/app" | sed 's/^/  /'
store "$C"; probe s4a-base-inhome-stored-yes "$SLOT_OLD" "$C"

echo
echo "=== S4b: in-flight in-home slot, a stored Yes, this change's trust script (backstop)"
C=$(new_config s4b); seed_yes "$C"
CLAUDE_CONFIG_DIR=$C "$MATE/bin/fm-claude-trust.sh" "$SLOT_OLD" "$MATE/projects/app" | sed 's/^/  /'
store "$C"; probe s4b-new-inhome-stored-yes "$SLOT_OLD" "$C"

printf '%s\n%s\n' "$SLOT_NEW" "$SLOT_OLD" > "$LAB/slots"
