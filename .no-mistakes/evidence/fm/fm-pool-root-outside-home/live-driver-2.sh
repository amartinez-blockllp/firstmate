#!/usr/bin/env bash
# Live driver part 2: primary-home byte identity and pool-root refusals.
# Usage: live-driver-2.sh <lab> <evidence-dir>
set -u
LAB=$1 E=$2
export HOME=$LAB/user-home
unset XDG_STATE_HOME TREEHOUSE_ROOT
MATE=$LAB/mate
WTSRC=$(git -C "$MATE" remote get-url origin)

echo "=== S5: primary home - worker slot in treehouse's default pool, a user's own stored Yes"
PRI=$LAB/primary
[ -d "$PRI" ] || git clone -q "$WTSRC" "$PRI"
[ -d "$PRI/projects/app" ] || git clone -q "$LAB/remotes/app.git" "$PRI/projects/app"
echo "  primary is a firstmate checkout: $(ls "$PRI/bin/fm-spawn.sh" "$PRI/CLAUDE.md" | tr '\n' ' ')"
echo "  fm_treehouse_pool_root primary -> '$(bash -c '. "$1/bin/fm-primary-scope-lib.sh"; fm_treehouse_pool_root "$1"' _ "$PRI")' (empty = plain treehouse get)"
PSLOT=$(cd "$PRI/projects/app" && treehouse get --lease --no-fetch 2>/dev/null); echo "  real treehouse default-pool slot: $PSLOT"
PMAIN=$(cd "$PRI/projects/app" && pwd -P)
for v in new base; do
  c=$LAB/cfg-s5-$v; rm -rf "$c"; mkdir -p "$c"
  node -e 'const fs=require("fs");const [s,k]=process.argv.slice(1);fs.writeFileSync(s,JSON.stringify({hasCompletedOnboarding:true,theme:"dark",projects:{[k]:{allowedTools:["Bash(make)"],hasTrustDialogAccepted:true,hasClaudeMdExternalIncludesWarningShown:true,hasClaudeMdExternalIncludesApproved:true},"/elsewhere/proj":{hasClaudeMdExternalIncludesApproved:true}}},null,2)+"\n")' "$c/.claude.json" "$PMAIN"
done
cp "$LAB/cfg-s5-new/.claude.json" "$E/s5-store-before.json"
CLAUDE_CONFIG_DIR=$LAB/cfg-s5-new "$PRI/bin/fm-claude-trust.sh" "$PSLOT" "$PRI/projects/app" | sed 's/^/  this change: /'
CLAUDE_CONFIG_DIR=$LAB/cfg-s5-base "$LAB/base/bin/fm-claude-trust.sh" "$PSLOT" "$PRI/projects/app" | sed 's/^/  base 8ac686e: /'
cp "$LAB/cfg-s5-new/.claude.json" "$E/s5-store-after-this-change.json"
cp "$LAB/cfg-s5-base/.claude.json" "$E/s5-store-after-base.json"
echo "  sha1 after, this change: $(shasum "$LAB/cfg-s5-new/.claude.json" | cut -c1-40)"
echo "  sha1 after, base       : $(shasum "$LAB/cfg-s5-base/.claude.json" | cut -c1-40)"
cmp -s "$LAB/cfg-s5-new/.claude.json" "$LAB/cfg-s5-base/.claude.json" && echo "  RESULT: stores byte-identical" || echo "  RESULT: stores DIFFER"
echo "  main-checkout entry after this change:"
node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(j.projects[process.argv[2]]))' "$LAB/cfg-s5-new/.claude.json" "$PMAIN" | sed 's/^/     /'
echo "  worktree entry after this change:"
node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(j.projects[process.argv[2]]))' "$LAB/cfg-s5-new/.claude.json" "$PSLOT" | sed 's/^/     /'
printf '%s\n' "$PSLOT" > "$LAB/pslot"

echo
echo "=== S6: adversarial pool-root placements for the secondmate home"
tryroot() {  # <label> <XDG_STATE_HOME value or __unset__> [HOME]
  local out rc
  if [ "$2" = __unset__ ]; then
    out=$(env -u XDG_STATE_HOME HOME="${3:-$HOME}" bash -c '. "$1/bin/fm-primary-scope-lib.sh"; fm_treehouse_pool_root "$1"' _ "$MATE" 2>&1); rc=$?
  else
    out=$(XDG_STATE_HOME="$2" HOME="${3:-$HOME}" bash -c '. "$1/bin/fm-primary-scope-lib.sh"; fm_treehouse_pool_root "$1"' _ "$MATE" 2>&1); rc=$?
  fi
  printf '  %-44s rc=%s  %s\n' "$1" "$rc" "$out"
}
tryroot "XDG_STATE_HOME inside the home"             "$MATE/state"
tryroot "XDG_STATE_HOME spelled into home via .."    "$LAB/user-home/../mate/state"
tryroot "XDG_STATE_HOME relative"                    "rel/state"
tryroot "XDG unset, HOME inside the home"            __unset__ "$MATE/user"
tryroot "XDG unset, HOME empty"                      __unset__ ""
ln -sfn "$MATE/state" "$LAB/state-link"
tryroot "XDG_STATE_HOME a symlink into the home"     "$LAB/state-link"
