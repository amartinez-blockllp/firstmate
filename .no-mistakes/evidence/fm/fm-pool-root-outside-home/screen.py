# Launch a command in a private pty, wait for a regex, optionally type keys
# after it settles, and save the de-ANSI'd screen text.
import os, pty, re, select, signal, struct, sys, time, fcntl, termios
cwd, deadline, want, out, keys = sys.argv[1], float(sys.argv[2]), re.compile(sys.argv[3]), sys.argv[4], sys.argv[5]
cmd = sys.argv[sys.argv.index("--") + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 160, 0, 0))
buf, end, settle, typed = b"", time.time() + deadline, None, False
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
        settle = time.time() + 2.5
    if settle is not None and keys and not typed and time.time() > settle - 1.0:
        os.write(fd, keys.encode()); time.sleep(1.0)
        os.write(fd, b"\r")
        typed = True
        settle = time.time() + 4.0
for sig in (signal.SIGTERM, signal.SIGKILL):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        break
    time.sleep(0.5)
open(out, "w").write(plain(buf))
