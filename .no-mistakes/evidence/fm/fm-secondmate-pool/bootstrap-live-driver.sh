#!/usr/bin/env bash
# Seed a real secondmate home from a primary (fixed tree), then run the real
# bin/fm-bootstrap.sh in detect-only mode in both homes under two treehouse versions.
set -u
TREE=$(cd "$1" && pwd -P)
. "$TREE/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-live)
trap fm_test_cleanup EXIT
USER_HOME="$TMP_ROOT/user-home"; mkdir -p "$USER_HOME"; export HOME="$USER_HOME"
primary="$TMP_ROOT/primary"; mate="$TMP_ROOT/mate"; origin="$TMP_ROOT/remotes/app.git"
fm_test_spawn_home "$primary" codex
fm_git_init_commit "$primary/projects/app"; fm_git_add_origin "$primary/projects/app" "$origin"
printf -- '- app [direct-PR] - app project (added 2026-09-09)\n' > "$primary/data/projects.md"
FM_ROOT_OVERRIDE='' FM_HOME="$primary" FM_SECONDMATE_CHARTER='connect' FM_SECONDMATE_SCOPE='connect' \
  "$ROOT/bin/fm-home-seed.sh" connect "$mate" app >/dev/null 2>&1 || { echo "seed failed"; exit 2; }
echo "seeded mate: marker=$(cat "$mate/.fm-secondmate-home" 2>/dev/null | head -1) state-exists=$([ -d "$mate/state" ] && echo yes || echo no)"
mkdir -p "$primary/config" "$mate/config"
printf '%s\n' manual > "$primary/config/backlog-backend"; printf '%s\n' manual > "$mate/config/backlog-backend"
run_bs() {  # <label> <home> <path-prefix>
  local label=$1 home=$2 prefix=$3 out st
  out=$(PATH="$prefix:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1); st=$?
  echo "## $label (treehouse $(PATH="$prefix:$PATH" treehouse --version)) exit=$st"
  echo "$out" | grep -E 'treehouse' | sed 's/^/   /' || echo "   (no treehouse line)"
}
run_bs "primary home"    "$primary" /tmp/fm-th-install.iAOsLQ
run_bs "secondmate home" "$mate"    /tmp/fm-th-install.iAOsLQ
run_bs "primary home"    "$primary" /tmp/fm-old-treehouse
run_bs "secondmate home" "$mate"    /tmp/fm-old-treehouse
# detect-only read-only contract: a secondmate home with no state/ must not gain one
rm -rf "$mate/state"
PATH="/tmp/fm-th-install.iAOsLQ:$PATH" FM_HOME="$mate" FM_ROOT_OVERRIDE="$mate" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1; st=$?
echo "## detect-only in secondmate home with state/ removed: exit=$st state-exists-after=$([ -e "$mate/state" ] && echo YES-BUG || echo no)"
