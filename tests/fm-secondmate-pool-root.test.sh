#!/usr/bin/env bash
# End-to-end regression for a secondmate home's per-home Treehouse pool root
# (bin/fm-wake-lib.sh's fm_treehouse_pool_root), against the real treehouse.
#
# Treehouse keys a pool by repository identity rather than clone path, so a
# secondmate seeded with a project the primary has also cloned used to be handed
# the primary's pool: slots that are worktrees of the PRIMARY's clone, which the
# secondmate's spawn rejects as not a worktree of the project it is spawning.
# This suite seeds a throwaway secondmate home from a primary that already holds
# the project (bin/fm-home-seed.sh), spawns a scout there through the real
# bin/fm-spawn.sh with a fake terminal that actually executes the typed
# `treehouse get` line, and asserts the pooled worktree's git common dir is the
# SECONDMATE's clone, not the primary's. The primary's own spawn of the same
# project must keep landing in treehouse's default pool, and bin/fm-teardown.sh
# must return the secondmate's slot under the recorded root.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-secondmate-pool-root)
USER_HOME="$TMP_ROOT/user-home"
PANES="$TMP_ROOT/panes"
mkdir -p "$USER_HOME" "$PANES"
# Every treehouse call in this suite, the version probe and the exit-time slot
# release included, resolves its default pool under this throwaway home, never
# the developer's real ~/.treehouse.
export HOME="$USER_HOME"

treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--root([^[:alnum:]_-]|$)' \
  || { echo "skip: installed treehouse lacks get --root (2.2.0 or newer required)"; exit 0; }

# Every pane shell the fake terminal started, and every slot it acquired, is
# released on exit even when an assertion fails midway. A slot is returned under
# the root it was allocated under, read back from the pooled path's
# <root>/.treehouse/<pool>/<slot>/<repo> layout that the assertions below pin:
# <mate>/state for the secondmate's pane, the throwaway home for the primary's.
cleanup_panes() {
  local pid_file pid wt_file wt root out
  for pid_file in "$PANES"/*/shell.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  for wt_file in "$PANES"/*/path; do
    [ -f "$wt_file" ] || continue
    wt=$(cat "$wt_file")
    [ -d "$wt" ] || continue
    root=${wt%/.treehouse/*}
    if ! out=$(cd "$wt" && treehouse return --root "$root" --force "$wt" 2>&1); then
      printf 'cleanup: treehouse return --root %s --force %s failed:\n%s\n' "$root" "$wt" "$out" >&2
    fi
  done
  fm_test_cleanup
}
trap cleanup_panes EXIT

# The pane's shell: treehouse runs it inside the acquired worktree, so it
# publishes that directory as the pane's cwd and then idles like a real shell
# would, keeping the slot in use until returned.
write_pane_shell() {
  cat > "$TMP_ROOT/pane-shell" <<'SH'
#!/usr/bin/env bash
pwd -P > "${FM_FAKE_PANE_DIR:?}/path.tmp"
mv "$FM_FAKE_PANE_DIR/path.tmp" "$FM_FAKE_PANE_DIR/path"
printf '%s\n' "$$" > "$FM_FAKE_PANE_DIR/shell.pid"
exec sleep 600
SH
  chmod +x "$TMP_ROOT/pane-shell"
}

# A fake tmux whose pane is real enough to prove the worktree binding: the
# window's -c directory becomes the pane cwd, a typed `treehouse get ...` line
# is executed there in the background with the pane shell above, and
# pane_current_path reports whatever directory that shell reached.
write_executing_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
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
    exit 0
    ;;
  send-keys)
    shift
    text=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift ;;
        *) text=$1; break ;;
      esac
    done
    case "$text" in
      'treehouse get'*)
        (
          cd "$(cat "$pane/cwd")" || exit 1
          export SHELL="${FM_FAKE_PANE_SHELL:?}"
          export FM_FAKE_PANE_DIR="$pane"
          eval "$text"
        ) </dev/null >"$pane/treehouse.log" 2>&1 &
        ;;
    esac
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_path*)
          if [ -f "$pane/path" ]; then cat "$pane/path"; else cat "$pane/cwd" 2>/dev/null; fi
          exit 0
          ;;
      esac
    done
    printf 'firstmate\n'
    exit 0
    ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

common_dir_of() {  # <dir>
  local dir
  dir=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P
}

# run_spawn <home> <pane-dir> <id> <project> [args...]
run_spawn() {
  local home=$1 pane=$2 id=$3 project=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="${TMUX:-fake,1,0}" \
    FM_FAKE_PANE_DIR="$pane" FM_FAKE_PANE_SHELL="$TMP_ROOT/pane-shell" FM_TMUX_LOG="$pane/calls.log" \
    PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "$@" 2>&1
}

test_seeded_secondmate_pools_worktrees_of_its_own_clone() {
  local primary mate origin id mate_id out status wt wt_common mate_common primary_common pane
  primary="$TMP_ROOT/primary"
  mate="$TMP_ROOT/mate"
  origin="$TMP_ROOT/remotes/app.git"
  write_pane_shell
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
  write_executing_tmux "$FAKEBIN"

  # The primary already holds the project.
  fm_test_spawn_home "$primary" codex
  fm_git_init_commit "$primary/projects/app"
  fm_git_add_origin "$primary/projects/app" "$origin"
  printf -- '- app [direct-PR] - app project (added 2026-09-09)\n' > "$primary/data/projects.md"

  # Seed a secondmate home with that same project through the real seeder.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$primary" HOME="$USER_HOME" \
    FM_SECONDMATE_CHARTER='connect domain work on app' FM_SECONDMATE_SCOPE='connect domain work on app' \
    "$ROOT/bin/fm-home-seed.sh" connect "$mate" app 2>&1)
  status=$?
  expect_code 0 "$status" "seeding the secondmate home should succeed"$'\n'"$out"
  assert_present "$mate/.fm-secondmate-home" "the seeded home carries no secondmate identity marker"
  mate_common=$(common_dir_of "$mate/projects/app") || fail "the seeded project clone is not a git repository"
  primary_common=$(common_dir_of "$primary/projects/app") || fail "the primary project clone is not a git repository"
  assert_not_equals "$primary_common" "$mate_common" "seeding did not give the secondmate its own clone"
  mkdir -p "$mate/config" "$mate/state"
  printf 'codex\n' > "$mate/config/crew-harness"
  touch "$mate/state/.last-watcher-beat"

  # A scout spawned in the secondmate home for the shared project.
  mate_id='mate-pool-root-r1'
  fm_test_spawn_brief "$mate" "$mate_id"
  pane="$PANES/mate"
  out=$(run_spawn "$mate" "$pane" "$mate_id" "$mate/projects/app" --scout)
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# secondmate spawn\n%s\nexit=%s\n' "$out" "$status"
    printf '# pane treehouse log\n'; cat "$pane/treehouse.log" 2>/dev/null || true
  fi
  expect_code 0 "$status" "the secondmate should spawn for a project the primary also holds"$'\n'"$out"
  wt=$(sed -n 's/^worktree=//p' "$mate/state/$mate_id.meta")
  [ -n "$wt" ] && [ -d "$wt" ] || fail "the secondmate spawn recorded no live worktree"
  wt_common=$(common_dir_of "$wt") || fail "the recorded worktree is not a git worktree: $wt"
  assert_equals "$mate_common" "$wt_common" \
    "the secondmate's pooled worktree is not a worktree of the secondmate's own clone"
  assert_not_equals "$primary_common" "$wt_common" \
    "the secondmate's pooled worktree belongs to the primary's clone"
  case "$wt" in
    "$(cd "$mate" && pwd -P)/state/.treehouse/"*) ;;
    *) fail "the secondmate's slot was not pooled under its own state/: $wt" ;;
  esac
  assert_grep "treehouse_root=$(cd "$mate" && pwd -P)/state" "$mate/state/$mate_id.meta" \
    "the secondmate spawn did not record its pool root"
  out=$(cd "$mate/projects/app" && treehouse status --root "$mate/state" 2>&1)
  assert_contains "$out" "$wt" "treehouse does not list the slot under the secondmate's root"$'\n'"$out"
  pass "a seeded secondmate pools a shared project's worktree from its own clone"

  # The primary's own spawn of the same project stays in treehouse's default pool.
  id='primary-pool-root-r1'
  fm_test_spawn_brief "$primary" "$id"
  pane="$PANES/primary"
  out=$(run_spawn "$primary" "$pane" "$id" "$primary/projects/app" --scout)
  status=$?
  expect_code 0 "$status" "the primary should keep spawning from the default pool"$'\n'"$out"
  wt=$(sed -n 's/^worktree=//p' "$primary/state/$id.meta")
  [ -n "$wt" ] && [ -d "$wt" ] || fail "the primary spawn recorded no live worktree"
  wt_common=$(common_dir_of "$wt") || fail "the primary's recorded worktree is not a git worktree: $wt"
  assert_equals "$primary_common" "$wt_common" \
    "the primary's pooled worktree is not a worktree of the primary's clone"
  case "$wt" in
    "$USER_HOME/.treehouse/"*) ;;
    *) fail "the primary's slot left treehouse's default pool: $wt" ;;
  esac
  assert_no_grep 'treehouse_root=' "$primary/state/$id.meta" \
    "the primary spawn recorded a pool root although it uses the default pool"
  pass "the primary's spawn of the same project keeps its default pool"

  # Teardown returns the secondmate's slot under the root the spawn recorded.
  wt=$(sed -n 's/^worktree=//p' "$mate/state/$mate_id.meta")
  mkdir -p "$mate/data/$mate_id"
  printf 'scout findings\n' > "$mate/data/$mate_id/report.md"
  # The scout's captain-call completion gate and the secondmate's parent binding
  # are not under test here; satisfy them the way the teardown and secondmate
  # suites do, with a reviewed-decisions record and the primary's record of the
  # launched secondmate.
  printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$mate/state/$mate_id.meta"
  fm_write_secondmate_meta "$primary/state/connect.meta" "$(cd "$mate" && pwd -P)" "firstmate:fm-connect" app codex
  pane="$PANES/mate"
  out=$(env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$mate" HOME="$USER_HOME" \
    FM_TEARDOWN_GUARD_DONE=1 FM_STATE_OVERRIDE="$mate/state" FM_DATA_OVERRIDE="$mate/data" \
    FM_CONFIG_OVERRIDE="$mate/config" FM_FAKE_PANE_DIR="$pane" FM_TMUX_LOG="$pane/calls.log" \
    "$ROOT/bin/fm-teardown.sh" "$mate_id" 2>&1)
  status=$?
  expect_code 0 "$status" "teardown of the secondmate's scout should succeed"$'\n'"$out"
  assert_absent "$mate/state/$mate_id.meta" "teardown left the secondmate's task record behind"
  out=$(cd "$mate/projects/app" && treehouse status --root "$mate/state" 2>&1)
  assert_contains "$out" "available" "the secondmate's slot was not returned to its own pool"$'\n'"$out"
  assert_not_contains "$out" "in-use" "the secondmate's slot is still in use after teardown"$'\n'"$out"
  rm -f "$pane/path"
  pass "teardown returns the secondmate's slot under its recorded root"
}

test_seeded_secondmate_pools_worktrees_of_its_own_clone

echo "# all fm-secondmate-pool-root tests passed"
