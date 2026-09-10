#!/usr/bin/env bash
# Regression tests for the per-home Treehouse pool root that fm-spawn applies
# and fm-teardown replays (bin/fm-primary-scope-lib.sh's fm_treehouse_pool_root).
#
# A secondmate home must type `treehouse get --root <home>/state` into its
# task pane and record that root, a primary home must keep typing the plain
# `treehouse get` with byte-identical metadata, a secondmate home must refuse
# to spawn on a treehouse without --root before any endpoint exists, and
# teardown must return the slot under the recorded root. These cases drive the
# real scripts against a recording fake terminal; the end-to-end proof against
# the real treehouse lives in tests/fm-secondmate-pool-root.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-root)

# A fake tmux that records every invocation (\x1f-separated, one per line) to
# FM_TMUX_LOG, hands new windows the stable id @spawnwid, reports
# FM_FAKE_PANE_PATH as the pane's cwd, and otherwise answers like
# tests/fixtures.sh's spawn stub.
write_recording_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  new-window)
    printf '@spawnwid\n'
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
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

# A fake treehouse that records every invocation to FM_TMUX_LOG and answers
# `get --help` with FM_FAKE_TREEHOUSE_GET_HELP.
write_recording_treehouse() {  # <fakebin>
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_GET_HELP:-}"
fi
exit 0
SH
  chmod +x "$1/treehouse"
}

# make_case <name> <id> <primary|secondmate>: a primary home, or a secondmate
# home bound to a primary, with one origin-backed project and a pre-made
# isolated pool worktree the fake pane reports. Echoes
# home|project|pool|fakebin|log.
make_case() {
  local name=$1 id=$2 shape=$3 case_dir primary home project pool fakebin log
  case_dir="$TMP_ROOT/$name"
  primary="$case_dir/primary"
  fakebin=$(fm_fakebin "$case_dir/fake")
  write_recording_tmux "$fakebin"
  write_recording_treehouse "$fakebin"
  log="$case_dir/calls.log"
  : > "$log"
  mkdir -p "$primary/state"
  if [ "$shape" = secondmate ]; then
    home="$case_dir/mate"
  else
    home=$primary
  fi
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  if [ "$shape" = secondmate ]; then
    printf 'mate\n' > "$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=local\n'
      printf 'parent_home=%s\n' "$(cd "$primary" && pwd -P)"
    } > "$home/.fm-secondmate-parent"
  fi
  project="$home/projects/app"
  fm_git_init_commit "$project"
  fm_git_add_origin "$project" "$case_dir/app.origin.git"
  pool="$case_dir/pool/1/app"
  mkdir -p "$(dirname "$pool")"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  printf '%s\n' "$home|$project|$pool|$fakebin|$log"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR CALL_LOG <<EOF
$1
EOF
}

run_spawn() {  # <id> [args...]
  local id=$1
  shift
  FM_TMUX_LOG="$CALL_LOG" FM_FAKE_TREEHOUSE_GET_HELP="${TREEHOUSE_GET_HELP:-Usage: treehouse get [--lease] [--root string]}" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

test_secondmate_home_pools_under_its_own_root() {
  local rec id out status expected_root default_lock scoped_lock
  id='pool-root-mate-r1'
  rec=$(make_case mate "$id" secondmate)
  read_case "$rec"
  expected_root="$(cd "$HOME_DIR" && pwd -P)/state"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a secondmate home should spawn from its own pool root"$'\n'"$out"
  assert_contains "$(cat "$CALL_LOG")" \
    "send-keys"$'\x1f'"-t"$'\x1f'"@spawnwid"$'\x1f'"treehouse get --root '$expected_root'"$'\x1f'"Enter" \
    "the secondmate pane was not told to pool under the home's own state/"
  assert_grep "treehouse_root=$expected_root" "$HOME_DIR/state/$id.meta" \
    "the spawn did not record the per-home pool root for teardown"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "the spawn did not publish its pool worktree"

  default_lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR") || fail "could not resolve the default-pool lock"
  scoped_lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR" "$expected_root") || fail "could not resolve the per-home pool lock"
  assert_not_equals "$default_lock" "$scoped_lock" \
    "a secondmate's private pool shares the primary's default-pool lock"
  case "$scoped_lock" in
    "$(cd "$HOME_DIR/.." && pwd -P)/primary/state/"*) ;;
    *) fail "the per-home pool lock is not anchored in the local root home: $scoped_lock" ;;
  esac
  pass "a secondmate home types treehouse get --root <home>/state, records it, and locks its own pool"
}

test_primary_home_keeps_the_default_pool() {
  local rec id out status
  id='pool-root-primary-r1'
  rec=$(make_case primary "$id" primary)
  read_case "$rec"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a primary home should spawn from treehouse's default pool"$'\n'"$out"
  assert_contains "$(cat "$CALL_LOG")" \
    "send-keys"$'\x1f'"-t"$'\x1f'"@spawnwid"$'\x1f'"treehouse get"$'\x1f'"Enter" \
    "the primary pane was not told to run the plain treehouse get"
  assert_not_contains "$(cat "$CALL_LOG")" "--root" \
    "a primary home passed a pool root or probed treehouse for one"
  assert_not_contains "$(cat "$CALL_LOG")" "treehouse"$'\x1f'"get"$'\x1f'"--help" \
    "a primary home probed treehouse get --help although it never needs --root"
  assert_no_grep 'treehouse_root=' "$HOME_DIR/state/$id.meta" \
    "a primary home's metadata gained a pool-root field"
  pass "a primary home keeps the plain treehouse get and byte-identical metadata"
}

test_secondmate_home_refuses_treehouse_without_root_support() {
  local rec id out status
  id='pool-root-old-r1'
  rec=$(make_case old-treehouse "$id" secondmate)
  read_case "$rec"

  out=$(TREEHOUSE_GET_HELP='Usage: treehouse get [--lease] [--lease-holder <holder>]' run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate home spawned on a treehouse that cannot pool under a root"$'\n'"$out"
  assert_contains "$out" "treehouse 2.2.0 or newer" \
    "the refusal did not name the treehouse upgrade the home needs"
  assert_not_contains "$(cat "$CALL_LOG")" "new-window" \
    "the refusal created an endpoint before proving the pool root was usable"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused spawn published task metadata"
  pass "a secondmate home refuses to spawn on a treehouse without --root, before any endpoint exists"
}

test_teardown_returns_the_slot_under_the_recorded_root() {
  local case_dir id proj wt fakebin log state data config out status root
  case_dir="$TMP_ROOT/teardown"
  id='pool-root-teardown-r1'
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fakebin=$(fm_fakebin "$case_dir/fake")
  write_recording_tmux "$fakebin"
  write_recording_treehouse "$fakebin"
  log="$case_dir/calls.log"
  state="$case_dir/state"
  data="$case_dir/data"
  config="$case_dir/config"
  mkdir -p "$state" "$data/$id" "$config"
  printf 'scout findings\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  root="$case_dir/mate/state"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "treehouse_root=$root" \
    "harness=codex" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="

  : > "$log"
  out=$(env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_TEARDOWN_GUARD_DONE=1 \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_TMUX_LOG="$log" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "teardown of a scout whose slot lives under a recorded root should succeed"$'\n'"$out"
  assert_contains "$(cat "$log")" \
    "treehouse"$'\x1f'"return"$'\x1f'"--root"$'\x1f'"$root"$'\x1f'"--force"$'\x1f'"$wt" \
    "teardown did not return the slot under the root the spawn recorded"
  pass "teardown returns a pooled slot under the root recorded at spawn"
}

test_secondmate_home_pools_under_its_own_root
test_primary_home_keeps_the_default_pool
test_secondmate_home_refuses_treehouse_without_root_support
test_teardown_returns_the_slot_under_the_recorded_root

echo "# all fm-spawn-pool-root tests passed"
