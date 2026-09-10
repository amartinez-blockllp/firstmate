#!/usr/bin/env bash
# Live guard for bin/fm-claude-trust.sh's external-import backstop, against the
# real installed Claude Code.
#
# Claude loads the CLAUDE.md of every ancestor of a worker's directory, and one
# that imports a file outside the worktree raises a blocking "Allow external
# CLAUDE.md file imports?" prompt. The registration pre-answers it No. Whether
# that answer suppresses the prompt is vendor behavior - which store keys, and
# which project entry the vendor reads them from - so it is proven here on the
# real CLI rather than assumed in a stub.
#
# Token-free, so it runs by default wherever claude is installed: every arm
# launches Claude in a private pseudo-terminal against its own throwaway
# CLAUDE_CONFIG_DIR that holds no login, submits no prompt, and is killed once
# the first screen settles. The operator's own store is never read or written.
#
#   control    registration with the import answer removed from both entries
#              must raise the prompt, so the case cannot pass vacuously.
#   keying     the answer on the worktree's entry alone; reported, never failed,
#              naming which entry this build reads the answer from.
#   treatment  the registration as the script writes it must reach the ready
#              composer with no prompt.
#
# Every arm reads more than one rendered signal and lets any of them carry its
# verdict. A failure names the Claude version. docs/verification/runtime-backends.md
# ("Claude external-import prompt") records the latest result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_IMPORTS_LIVE_E2E claude python3 node git

TRUST="$ROOT/bin/fm-claude-trust.sh"
LAB=$(fm_test_tmproot fm-claude-trust-imports-live)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
PROMPT_RE='Allow external CLAUDE\.md file imports|disable external imports|allow external imports'
READY_RE='bypass permissions on|shift\+tab to cycle|/effort'

# A firstmate-shaped home: bin/fm-spawn.sh beside a CLAUDE.md that imports an
# AGENTS.md outside every worktree below it, exactly the pointer a live home
# carries and the shape the registration declines imports under.
HOME_DIR="$LAB/home"
PROJECT="$HOME_DIR/project"
mkdir -p "$HOME_DIR/bin"
: > "$HOME_DIR/bin/fm-spawn.sh"
printf '@AGENTS.md\n' > "$HOME_DIR/CLAUDE.md"
printf 'Sentinel instructions a project worker must never load.\n' > "$HOME_DIR/AGENTS.md"
fm_git_init_commit "$PROJECT"

# run_screen <cwd> <config-dir> <out>: launch the worker the way a crewmate pane
# does and keep what it renders until the prompt or the composer settles.
cat > "$LAB/screen.py" <<'PY'
import os, pty, re, select, signal, struct, sys, time, fcntl, termios
cwd, deadline, want, out = sys.argv[1], float(sys.argv[2]), re.compile(sys.argv[3]), sys.argv[4]
cmd = sys.argv[sys.argv.index("--") + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 160, 0, 0))
buf, end, settle = b"", time.time() + deadline, None
def plain(b):
    t = b.decode("utf-8", "replace")
    t = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", " ", t)
    t = re.sub(r"\x1b[\]P^_].*?(\x07|\x1b\\)", " ", t)
    return re.sub(r"[ \t]+", " ", re.sub(r"\x1b.", " ", t))
while time.time() < (settle or end):
    r, _, _ = select.select([fd], [], [], 0.2)
    if fd in r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        buf += data
    if settle is None and want.search(plain(buf)):
        settle = time.time() + 2.0
for sig in (signal.SIGTERM, signal.SIGKILL):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        break
    time.sleep(0.5)
open(out, "w").write(plain(buf))
PY

run_screen() {
  local cwd=$1 config=$2 out=$3
  python3 "$LAB/screen.py" "$cwd" 45 "$PROMPT_RE|$READY_RE" "$out" -- \
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
    CLAUDE_CONFIG_DIR="$config" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude --dangerously-skip-permissions
}

# new_arm <name>: a fresh linked worktree of the project and a throwaway config
# with onboarding done and the machine-scoped bypass warning accepted, so the
# first screen is the import prompt or the composer. Echoes "<worktree>|<config>".
new_arm() {
  local name=$1 wt config
  wt="$HOME_DIR/pool/$name/project"
  config="$LAB/config-$name"
  mkdir -p "$config" "$(dirname "$wt")"
  git -C "$PROJECT" worktree add --quiet --detach "$wt" HEAD
  printf '{"hasCompletedOnboarding":true}\n' > "$config/.claude.json"
  printf '{"skipDangerousModePermissionPrompt":true}\n' > "$config/settings.json"
  CLAUDE_CONFIG_DIR="$config" "$TRUST" "$wt" "$PROJECT" >/dev/null \
    || fail "fm-claude-trust.sh refused a fresh worktree on claude $CLAUDE_VERSION"
  printf '%s|%s\n' "$(cd "$wt" && pwd -P)" "$config"
}

forget_import_answer() {  # <config> <entry-path...>
  local config=$1
  shift
  node -e 'const fs=require("node:fs");const [s,...keys]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));for(const k of keys){const e=j.projects?.[k];if(e){delete e.hasClaudeMdExternalIncludesWarningShown;delete e.hasClaudeMdExternalIncludesApproved;}}fs.writeFileSync(s,JSON.stringify(j,null,2)+"\n")' \
    "$config/.claude.json" "$@"
}

screen_has() {  # <file> <regex>
  grep -Eq "$2" "$1"
}

project_real=$(cd "$PROJECT" && pwd -P)

IFS='|' read -r wt config <<EOF
$(new_arm control)
EOF
forget_import_answer "$config" "$wt" "$project_real"
run_screen "$wt" "$config" "$LAB/control.txt"
screen_has "$LAB/control.txt" "$PROMPT_RE" \
  || fail "claude $CLAUDE_VERSION raised no import prompt for an unanswered ancestor import, so this guard cannot prove the backstop; screen: $(tail -c 600 "$LAB/control.txt")"
pass "claude $CLAUDE_VERSION: an unanswered ancestor import raises the prompt"

IFS='|' read -r wt config <<EOF
$(new_arm keying)
EOF
forget_import_answer "$config" "$project_real"
run_screen "$wt" "$config" "$LAB/keying.txt"
if screen_has "$LAB/keying.txt" "$PROMPT_RE"; then
  printf 'note: claude %s reads the import answer from the main checkout entry, not the worktree entry\n' "$CLAUDE_VERSION"
else
  printf 'note: claude %s honours the import answer on the worktree entry alone\n' "$CLAUDE_VERSION"
fi

IFS='|' read -r wt config <<EOF
$(new_arm treatment)
EOF
run_screen "$wt" "$config" "$LAB/treatment.txt"
if screen_has "$LAB/treatment.txt" "$PROMPT_RE"; then
  fail "claude $CLAUDE_VERSION still raised the import prompt after fm-claude-trust.sh declined it; screen: $(tail -c 600 "$LAB/treatment.txt")"
fi
screen_has "$LAB/treatment.txt" "$READY_RE" \
  || fail "claude $CLAUDE_VERSION never reached its composer after the import answer was registered; screen: $(tail -c 600 "$LAB/treatment.txt")"
pass "claude $CLAUDE_VERSION: the registered answer suppresses the prompt and the worker reaches its composer"
