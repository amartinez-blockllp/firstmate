#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home, plus the per-home Treehouse pool-root
# contract that hangs off the same secondmate-home predicate.
# This file is sourced by hook entrypoints and by bin/fm-bootstrap.sh's
# read-only detection, and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}

# The Treehouse root a home's task worktrees are pooled under: the single owner
# of the per-home pool-root contract that bin/fm-spawn.sh applies at allocation
# and records as treehouse_root= in the task's meta, and that bin/fm-teardown.sh
# replays from that record at return.
#
# A primary home prints nothing: no --root is passed, treehouse's own resolution
# (--root, TREEHOUSE_ROOT, config, then ~/.treehouse) stands, and every existing
# primary pool keeps working unchanged. A secondmate home (a genuine
# .fm-secondmate-home marker, fm_root_is_secondmate_home above) prints
# <home>/state, so treehouse lays that home's pools out under
# <home>/state/.treehouse/<repo>-<hash>/<slot>/<repo>, where every slot is a
# linked worktree of THAT home's own project clone. Treehouse keys a pool by
# repository identity rather than clone path, so without a home-scoped root a
# secondmate seeded with a project the primary also cloned is handed the
# primary's pool - slots that are worktrees of the primary's clone - which the
# secondmate's spawn correctly refuses as not a worktree of the project it is
# spawning, blocking every ship task for that project in that home.
# Fails only when the home cannot be resolved.
fm_treehouse_pool_root() {  # <home>
  local home=${1:-$FM_HOME}
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  fm_root_is_secondmate_home "$home" || return 0
  printf '%s/state\n' "$home"
}

# Whether the installed treehouse honours `treehouse get --root`, the single
# version-floor probe (treehouse 2.2.0 or newer) that bin/fm-bootstrap.sh reports
# as MISSING and bin/fm-spawn.sh refuses on, for a home whose
# fm_treehouse_pool_root is non-empty. Probing --help rather than a version
# number keeps a vendored or development build honest about what it accepts.
fm_treehouse_supports_root() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--root([^[:alnum:]_-]|$)'
}
