#!/usr/bin/env bash
# Regression tests for the per-home Treehouse pool root that fm-spawn applies
# and fm-teardown replays (bin/fm-primary-scope-lib.sh's fm_treehouse_pool_root).
#
# A secondmate home must type `treehouse get --root <per-home root>` into its
# task pane and record that root, which must sit outside the home with no
# firstmate instructions anywhere above its slots; a primary home must keep
# typing the plain `treehouse get` with byte-identical metadata; a secondmate
# home must refuse to spawn, before any endpoint exists, on a treehouse without
# --root or a pool root under a firstmate checkout; and teardown must return
# each slot under its own recorded root, old in-home roots included. These cases drive the
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
# isolated pool worktree the fake pane reports. A secondmate home is shaped like
# the firstmate checkout a real one is - bin/fm-spawn.sh beside an AGENTS.md
# that its CLAUDE.md imports - because that is what a worker must never sit
# under. Echoes home|project|pool|fakebin|log|xdg, where xdg is a state base
# outside every home.
make_case() {
  local name=$1 id=$2 shape=$3 case_dir primary home project pool fakebin log
  case_dir="$TMP_ROOT/$name"
  primary="$case_dir/primary"
  fakebin=$(fm_fakebin "$case_dir/fake")
  write_recording_tmux "$fakebin"
  write_recording_treehouse "$fakebin"
  log="$case_dir/calls.log"
  : > "$log"
  mkdir -p "$primary/state" "$case_dir/xdg-state"
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
    mkdir -p "$home/bin"
    printf '#!/usr/bin/env bash\n' > "$home/bin/fm-spawn.sh"
    printf '# Firstmate\n' > "$home/AGENTS.md"
    printf '@AGENTS.md\n' > "$home/CLAUDE.md"
  fi
  project="$home/projects/app"
  fm_git_init_commit "$project"
  fm_git_add_origin "$project" "$case_dir/app.origin.git"
  pool="$case_dir/pool/1/app"
  mkdir -p "$(dirname "$pool")"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  printf '%s\n' "$home|$project|$pool|$fakebin|$log|$(cd "$case_dir/xdg-state" && pwd -P)"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR CALL_LOG XDG_DIR <<EOF
$1
EOF
}

# run_spawn <id> [args...]: spawns with the case's outside-the-home state base,
# unless SPAWN_XDG_STATE_HOME is set (empty leaves the fixture's HOME, which
# lives inside the home, to name the base).
run_spawn() {
  local id=$1
  shift
  FM_TMUX_LOG="$CALL_LOG" FM_FAKE_TREEHOUSE_GET_HELP="${TREEHOUSE_GET_HELP:-Usage: treehouse get [--lease] [--root string]}" \
    FM_TEST_XDG_STATE_HOME="${SPAWN_XDG_STATE_HOME-$XDG_DIR}" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

pool_root_of() {  # <home> <xdg-state-home>
  XDG_STATE_HOME=$2 bash -c '. "$1"; fm_treehouse_pool_root "$2"' _ "$ROOT/bin/fm-primary-scope-lib.sh" "$1"
}

# Claude Code loads the CLAUDE.md of every ancestor of a worker's directory, so a
# slot anywhere under a firstmate checkout hands the worker that checkout's
# instructions. Walk the whole chain above a would-be slot path.
assert_no_instructions_above() {  # <path> <msg>
  local dir=$1
  while [ -n "$dir" ]; do
    if [ -e "$dir/CLAUDE.md" ] || [ -e "$dir/AGENTS.md" ]; then
      fail "$2: $dir holds agent instructions"
    fi
    dir=${dir%/*}
  done
}

test_secondmate_home_pools_outside_the_home() {
  local rec id out status root home_real default_lock scoped_lock
  id='pool-root-mate-r1'
  rec=$(make_case mate "$id" secondmate)
  read_case "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a secondmate home should spawn from its own pool root"$'\n'"$out"
  root=$(sed -n 's/^treehouse_root=//p' "$HOME_DIR/state/$id.meta")
  case "$root" in
    "$XDG_DIR/firstmate/treehouse-pools/mate-"?*) ;;
    *) fail "the per-home pool root is not a per-home directory under the user state base: ${root:-<none>}" ;;
  esac
  case "$root/" in
    "$home_real"/*) fail "the per-home pool root still sits inside the home: $root" ;;
  esac
  assert_no_instructions_above "$root/.treehouse/app-0000/1/app" \
    "a slot under the per-home pool root would load firstmate's instructions"
  assert_contains "$(cat "$CALL_LOG")" \
    "send-keys"$'\x1f'"-t"$'\x1f'"@spawnwid"$'\x1f'"treehouse get --root '$root'"$'\x1f'"Enter" \
    "the secondmate pane was not told to pool under the recorded per-home root"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "the spawn did not publish its pool worktree"
  assert_equals "$root" "$(pool_root_of "$HOME_DIR" "$XDG_DIR")" \
    "the per-home pool root is not stable across resolutions"

  default_lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR") || fail "could not resolve the default-pool lock"
  scoped_lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR" "$root") || fail "could not resolve the per-home pool lock"
  assert_not_equals "$default_lock" "$scoped_lock" \
    "a secondmate's private pool shares the primary's default-pool lock"
  case "$scoped_lock" in
    "$(cd "$HOME_DIR/.." && pwd -P)/primary/state/"*) ;;
    *) fail "the per-home pool lock is not anchored in the local root home: $scoped_lock" ;;
  esac
  pass "a secondmate home pools outside itself, with no firstmate instructions above its slots"
}

test_pool_root_is_unique_per_home() {
  local base a b root_a root_b
  base="$TMP_ROOT/unique"
  a="$base/one/mate"
  b="$base/two/mate"
  mkdir -p "$a" "$b" "$base/xdg"
  printf 'mate\n' > "$a/.fm-secondmate-home"
  printf 'mate\n' > "$b/.fm-secondmate-home"
  root_a=$(pool_root_of "$a" "$base/xdg") || fail "could not resolve the first home's pool root"
  root_b=$(pool_root_of "$b" "$base/xdg") || fail "could not resolve the second home's pool root"
  assert_not_equals "$root_a" "$root_b" "two homes sharing a secondmate id share one pool root"
  assert_equals "" "$(pool_root_of "$base" "$base/xdg")" "an unmarked (primary) home was given a pool root"
  pass "the pool root is unique per home even when two homes share an id"
}

test_secondmate_home_refuses_a_pool_root_under_a_firstmate_checkout() {
  local rec id out status
  id='pool-root-inside-r1'
  rec=$(make_case inside "$id" secondmate)
  read_case "$rec"

  # The fixture's HOME lives inside the home, so an unset state base lands there.
  out=$(SPAWN_XDG_STATE_HOME='' run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate home pooled its worktrees under its own firstmate checkout"$'\n'"$out"
  assert_contains "$out" "firstmate checkout" \
    "the refusal did not say the pool root would sit under a firstmate checkout"
  assert_not_contains "$(cat "$CALL_LOG")" "new-window" \
    "the refusal created an endpoint before proving the pool root was safe"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused spawn published task metadata"

  out=$(SPAWN_XDG_STATE_HOME='relative/state' run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate home accepted a relative state base"$'\n'"$out"
  assert_contains "$out" "absolute path" "the refusal did not name the relative state base"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused spawn published task metadata"
  pass "a secondmate home refuses a pool root under a firstmate checkout or a relative state base"
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

# A home that already holds a slot allocated under the old in-home root
# (<home>/state, before the root moved outside the home) keeps returning that
# slot where it was allocated, while a slot allocated under the new root returns
# under the new one: teardown replays each task's recorded treehouse_root=
# rather than resolving the pool root afresh.
test_teardown_returns_each_slot_under_its_recorded_root() {
  local case_dir mate fakebin log state data config out status kind root id wt proj
  case_dir="$TMP_ROOT/teardown"
  mate="$case_dir/mate"
  mkdir -p "$mate" "$case_dir/xdg-state"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  fakebin=$(fm_fakebin "$case_dir/fake")
  write_recording_tmux "$fakebin"
  write_recording_treehouse "$fakebin"
  log="$case_dir/calls.log"
  state="$case_dir/state"
  data="$case_dir/data"
  config="$case_dir/config"
  mkdir -p "$state" "$config"
  touch "$state/.last-watcher-beat"
  for kind in old new; do
    id="pool-root-teardown-$kind"
    proj="$case_dir/$kind-project"
    wt="$case_dir/$kind-wt"
    fm_git_worktree "$proj" "$wt" "fm/$id"
    if [ "$kind" = old ]; then
      root="$(cd "$mate" && pwd -P)/state"
    else
      root=$(pool_root_of "$mate" "$case_dir/xdg-state") || fail "could not resolve the new per-home pool root"
    fi
    mkdir -p "$data/$id"
    printf 'scout findings\n' > "$data/$id/report.md"
    fm_write_meta "$state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "treehouse_root=$root" \
      "harness=codex" "kind=scout" "mode=no-mistakes" "yolo=off" \
      "decisions_reviewed=1" "decision_keys="
    printf '%s|%s|%s\n' "$id" "$wt" "$root" >> "$case_dir/tasks"
  done
  assert_not_equals "$(sed -n '1p' "$case_dir/tasks" | cut -d'|' -f3)" \
    "$(sed -n '2p' "$case_dir/tasks" | cut -d'|' -f3)" "the mixed case did not record two different roots"

  while IFS='|' read -r id wt root; do
    : > "$log"
    out=$(env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_TEARDOWN_GUARD_DONE=1 \
      FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
      XDG_STATE_HOME="$case_dir/xdg-state" FM_TMUX_LOG="$log" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
    status=$?
    expect_code 0 "$status" "teardown of $id whose slot lives under a recorded root should succeed"$'\n'"$out"
    assert_contains "$(cat "$log")" \
      "treehouse"$'\x1f'"return"$'\x1f'"--root"$'\x1f'"$root"$'\x1f'"--force"$'\x1f'"$wt" \
      "teardown of $id did not return its slot under the root the spawn recorded"
  done < "$case_dir/tasks"
  pass "teardown returns an old in-home slot and a new outside slot each under its recorded root"
}

test_secondmate_home_pools_outside_the_home
test_pool_root_is_unique_per_home
test_secondmate_home_refuses_a_pool_root_under_a_firstmate_checkout
test_primary_home_keeps_the_default_pool
test_secondmate_home_refuses_treehouse_without_root_support
test_teardown_returns_each_slot_under_its_recorded_root

echo "# all fm-spawn-pool-root tests passed"
