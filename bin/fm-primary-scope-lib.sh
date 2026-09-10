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
# ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/treehouse-pools/<id>-<hash>,
# where <id> is the home's secondmate id and <hash> the first 12 hex digits of
# the git blob hash of its resolved path, so treehouse lays that home's pools
# out under <root>/.treehouse/<repo>-<hash>/<slot>/<repo> and every slot is a
# linked worktree of THAT home's own project clone. Treehouse keys a pool by
# repository identity rather than clone path, so without a home-scoped root a
# secondmate seeded with a project the primary also cloned is handed the
# primary's pool - slots that are worktrees of the primary's clone - which the
# secondmate's spawn correctly refuses as not a worktree of the project it is
# spawning, blocking every ship task for that project in that home.
#
# The root lives OUTSIDE the home on purpose. A home is a firstmate checkout
# whose CLAUDE.md imports firstmate's own AGENTS.md, and Claude Code loads the
# CLAUDE.md of every ancestor of a worker's directory, so a pool inside the home
# stalls every new Claude worker on an external-import prompt and would hand
# it the supervisor contract as its own instructions. The per-user state base is
# the one firstmate already owns for process-event claims; it is outside every
# home and outside the user-level treehouse root that `treehouse prune --all`
# sweeps, the id keeps it readable, the path hash keeps two homes that share an
# id apart, and both inputs are stable, so the root survives restarts.
# bin/fm-teardown.sh removes it when it retires the home. A root that would
# still sit under any firstmate checkout (a directory holding bin/fm-spawn.sh
# beside AGENTS.md or CLAUDE.md) is refused with its reason on stderr, as is a
# relative or unset state base; an unresolvable home fails quietly.
fm_treehouse_pool_root() {  # <home>
  local home=${1:-$FM_HOME} id base hash root dir
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  fm_root_is_secondmate_home "$home" || return 0
  IFS= read -r id < "$home/.fm-secondmate-home" || return 1
  id=${id//[[:space:]]/}
  base=${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}
  case $base in
    /*) ;;
    *)
      echo "error: cannot place secondmate $id's task-worktree pool: XDG_STATE_HOME or HOME must be an absolute path" >&2
      return 1
      ;;
  esac
  hash=$(printf '%s' "$home" | git hash-object --stdin 2>/dev/null) || return 1
  root="${base%/}/firstmate/treehouse-pools/$id-${hash:0:12}"
  # Every home is itself such a checkout, so this also refuses a root inside
  # the home, however the state base spells its way there.
  if dir=$(fm_path_under_firstmate_checkout "$root"); then
    echo "error: secondmate $id's task-worktree pool $root would sit under the firstmate checkout $dir, whose instructions every worker there would load" >&2
    return 1
  fi
  printf '%s\n' "$root"
}

# Print the nearest firstmate checkout at or above the absolute path $1 - a
# directory holding bin/fm-spawn.sh beside AGENTS.md or CLAUDE.md, whose
# CLAUDE.md Claude Code loads for every worker below it - and return 0, or
# return 1 when there is none. fm_treehouse_pool_root refuses a pool root this
# matches, and bin/fm-claude-trust.sh declines Claude's external imports only
# for a task worktree this matches.
fm_path_under_firstmate_checkout() {  # <absolute-path>
  local dir=$1
  while [ -n "$dir" ]; do
    if [ -f "$dir/bin/fm-spawn.sh" ] && { [ -e "$dir/AGENTS.md" ] || [ -e "$dir/CLAUDE.md" ]; }; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=${dir%/*}
  done
  return 1
}

# Whether the installed treehouse honours `treehouse get --root`, the single
# version-floor probe (treehouse 2.2.0 or newer) that bin/fm-bootstrap.sh reports
# as MISSING and bin/fm-spawn.sh refuses on, for a home whose
# fm_treehouse_pool_root is non-empty. Probing --help rather than a version
# number keeps a vendored or development build honest about what it accepts.
fm_treehouse_supports_root() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--root([^[:alnum:]_-]|$)'
}
