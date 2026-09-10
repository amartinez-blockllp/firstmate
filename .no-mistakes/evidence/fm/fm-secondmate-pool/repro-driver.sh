#!/usr/bin/env bash
# repro.sh <tree> : reproduce "secondmate cannot spawn for a project the primary also holds"
# against the firstmate tree at <tree>, with the REAL treehouse and an isolated HOME.
# Order matches the captain's situation: the primary has already used the project's pool.
set -u
TREE=$(cd "$1" && pwd -P)
. "$TREE/tests/fixtures.sh"
[ "$ROOT" = "$TREE" ] || { echo "fixtures resolved ROOT=$ROOT, expected $TREE" >&2; exit 2; }
echo "### tree under test: $TREE ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || cat "$ROOT/.repro-label"))"
echo "### treehouse: $(treehouse --version)"

TMP_ROOT=$(fm_test_tmproot fm-repro-pool-root)
USER_HOME="$TMP_ROOT/user-home"; PANES="$TMP_ROOT/panes"
mkdir -p "$USER_HOME" "$PANES"
export HOME="$USER_HOME"

cleanup_panes() {
  local pid_file pid wt_file wt root out
  for pid_file in "$PANES"/*/shell.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true); [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  for wt_file in "$PANES"/*/path; do
    [ -f "$wt_file" ] || continue
    wt=$(cat "$wt_file"); [ -d "$wt" ] || continue
    root=${wt%/.treehouse/*}
    out=$(cd "$wt" && treehouse return --root "$root" --force "$wt" 2>&1) || printf 'cleanup: return failed: %s\n' "$out" >&2
  done
  fm_test_cleanup
}
trap cleanup_panes EXIT

cat > "$TMP_ROOT/pane-shell" <<'SH'
#!/usr/bin/env bash
pwd -P > "${FM_FAKE_PANE_DIR:?}/path.tmp"
mv "$FM_FAKE_PANE_DIR/path.tmp" "$FM_FAKE_PANE_DIR/path"
printf '%s\n' "$$" > "$FM_FAKE_PANE_DIR/shell.pid"
exec sleep 600
SH
chmod +x "$TMP_ROOT/pane-shell"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
pane=${FM_FAKE_PANE_DIR:?}
mkdir -p "$pane"
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  new-window)
    prev=
    for a in "$@"; do
      if [ "$prev" = -c ]; then printf '%s\n' "$a" > "$pane/cwd"; fi
      prev=$a
    done
    exit 0 ;;
  send-keys)
    shift; text=
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) shift ;; *) text=$1; break ;; esac
    done
    case "$text" in
      'treehouse get'*)
        printf '%s\n' "$text" >> "$pane/typed.log"
        ( cd "$(cat "$pane/cwd")" || exit 1
          export SHELL="${FM_FAKE_PANE_SHELL:?}" FM_FAKE_PANE_DIR="$pane"
          eval "$text" ) </dev/null >"$pane/treehouse.log" 2>&1 & ;;
    esac
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_path*) if [ -f "$pane/path" ]; then cat "$pane/path"; else cat "$pane/cwd" 2>/dev/null; fi; exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

common_dir_of() { local d; d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1; CDPATH='' cd -- "$d" && pwd -P; }

run_spawn() {  # <home> <pane-dir> <id> <project> [args...]
  local home=$1 pane=$2 id=$3 project=$4; shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="${TMUX:-fake,1,0}" FM_SPAWN_WORKTREE_WAIT_SECS="${FM_SPAWN_WORKTREE_WAIT_SECS:-}" \
    FM_FAKE_PANE_DIR="$pane" FM_FAKE_PANE_SHELL="$TMP_ROOT/pane-shell" FM_TMUX_LOG="$pane/calls.log" \
    PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "$@" 2>&1
}

primary="$TMP_ROOT/primary"; mate="$TMP_ROOT/mate"; origin="$TMP_ROOT/remotes/app.git"
fm_test_spawn_home "$primary" codex
fm_git_init_commit "$primary/projects/app"
fm_git_add_origin "$primary/projects/app" "$origin"
printf -- '- app [direct-PR] - app project (added 2026-09-09)\n' > "$primary/data/projects.md"

echo; echo "### 1. seed secondmate home 'connect' from the primary with the SAME project (bin/fm-home-seed.sh)"
FM_ROOT_OVERRIDE='' FM_HOME="$primary" HOME="$USER_HOME" \
  FM_SECONDMATE_CHARTER='connect domain work on app' FM_SECONDMATE_SCOPE='connect domain work on app' \
  "$ROOT/bin/fm-home-seed.sh" connect "$mate" app 2>&1 | tail -3
echo "seed exit=${PIPESTATUS[0]}"
mkdir -p "$mate/config" "$mate/state"; printf 'codex\n' > "$mate/config/crew-harness"; touch "$mate/state/.last-watcher-beat"
echo "primary clone common dir: $(common_dir_of "$primary/projects/app")"
echo "mate    clone common dir: $(common_dir_of "$mate/projects/app")"

echo; echo "### 2. PRIMARY spawns a scout for app first (its pool now exists in the default root)"
id=primary-r1; fm_test_spawn_brief "$primary" "$id"
out=$(run_spawn "$primary" "$PANES/primary" "$id" "$primary/projects/app" --scout); st=$?
echo "$out"; echo "primary spawn exit=$st"
echo "typed into pane: $(cat "$PANES/primary/typed.log" 2>/dev/null)"
pw=$(sed -n 's/^worktree=//p' "$primary/state/$id.meta" 2>/dev/null)
[ -n "$pw" ] && echo "primary worktree=$pw" && echo "  -> common dir: $(common_dir_of "$pw")"
echo "default pool ($USER_HOME/.treehouse):"; ls "$USER_HOME/.treehouse" 2>/dev/null

echo; echo "### 2b. the primary's scout finishes: its slot is returned and sits AVAILABLE in the default pool"
kill "$(cat "$PANES/primary/shell.pid")" 2>/dev/null; sleep 1
( cd "$primary/projects/app" && treehouse return --force "$pw" 2>&1 | sed 's/^/  | /' )
rm -f "$PANES/primary/path" "$PANES/primary/shell.pid"
( cd "$primary/projects/app" && treehouse status 2>&1 | sed 's/^/  | /' )

echo; echo "### 3. SECONDMATE spawns a scout for the same project"
mid=mate-r1; fm_test_spawn_brief "$mate" "$mid"
out=$(run_spawn "$mate" "$PANES/mate" "$mid" "$mate/projects/app" ${REPRO_SPAWN_ARGS---scout}); st=$?
echo "$out"; echo "secondmate spawn exit=$st"
echo "typed into pane: $(cat "$PANES/mate/typed.log" 2>/dev/null)"
echo "pane treehouse log:"; sed 's/^/  | /' "$PANES/mate/treehouse.log" 2>/dev/null
mw=$(sed -n 's/^worktree=//p' "$mate/state/$mid.meta" 2>/dev/null)
if [ -n "$mw" ]; then
  echo "secondmate worktree=$mw"; echo "  -> common dir: $(common_dir_of "$mw")"
  echo "  -> meta treehouse_root: $(sed -n 's/^treehouse_root=//p' "$mate/state/$mid.meta")"
else
  echo "secondmate published NO task meta (spawn refused)"
  [ -f "$PANES/mate/path" ] && { p=$(cat "$PANES/mate/path"); echo "pane actually landed in: $p"; echo "  -> common dir: $(common_dir_of "$p")"; }
fi
echo "mate private pool ($mate/state/.treehouse):"; ls "$mate/state/.treehouse" 2>/dev/null || echo "  (none)"
echo "default pool ($USER_HOME/.treehouse):"; ls "$USER_HOME/.treehouse" 2>/dev/null
echo; echo "### RESULT: secondmate spawn exit=$st"
exit "$st"
