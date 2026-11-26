#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Pseudo-terminal harness for the interactive tests of sh (test_sh_interactive.sh).

Every session runs in its own session (pty.fork), is capped by a deadline and is
cleaned up by killing exactly the processes of that session (never a group or
pid this module did not create).
"""
import os, pty, re, select, shutil, signal, struct, fcntl, tempfile, termios, time

CSI = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")

def strip(text, cols=80):
    """Interpret terminal output (cursor movement, erase) and return the screen
    text, one line per row, trailing blanks removed."""
    rows = [[]]
    r = c = 0
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\x1b":
            m = CSI.match(text, i)
            if m:
                arg, f = m.group(1), m.group(2)
                num = int(arg) if arg.isdigit() else 1
                if f == "A":
                    r = max(0, r - num)
                elif f == "B":
                    r += num
                    while len(rows) <= r: rows.append([])
                elif f == "C":
                    c += num
                elif f == "D":
                    c = max(0, c - num)
                elif f == "J":
                    del rows[r + 1:]
                    del rows[r][c:]
                elif f == "K":
                    del rows[r][c:]
                elif f == "H":
                    r = c = 0
                i = m.end()
                continue
            i += 2
            continue
        i += 1
        if ch == "\r":
            c = 0
        elif ch == "\n":
            r += 1
            c = 0
            while len(rows) <= r: rows.append([])
        elif ch == "\x07":
            pass
        elif ch == "\b":
            c = max(0, c - 1)
        else:
            row = rows[r]
            while len(row) < c: row.append(" ")
            if c < len(row): row[c] = ch
            else: row.append(ch)
            c += 1
    return "\n".join("".join(x).rstrip() for x in rows)

def session_members(sid):
    res = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % d) as f:
                s = f.read()
            rest = s[s.rindex(")") + 2:].split()
            if int(rest[3]) == sid:
                res.append(int(d))
        except (OSError, ValueError, IndexError):
            pass
    return res

class Session:
    def __init__(self, argv, env=None, rows=24, cols=80, cwd=None):
        e = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TERM": "xterm", "HOME": "/nonexistent",
             "PS1": "$ ", "ENV": "/dev/null", "LC_ALL": "C"}
        e.update(env or {})
        # a command that runs `sh` must get the shell under test, not the system's
        # (bsdrun.sh runs inside the FreeBSD sysroot, where `sh` already is)
        self.inner = None
        target = shutil.which(argv[0])
        if target and os.path.basename(target) != "bsdrun.sh":
            self.inner = tempfile.mkdtemp(prefix="shpty-inner.")
            os.symlink(os.path.abspath(target), os.path.join(self.inner, "sh"))
            e["PATH"] = self.inner + ":" + e.get("PATH", "/usr/bin:/bin")
        pid, fd = pty.fork()
        if pid == 0:
            if cwd:
                os.chdir(cwd)
            os.execvpe(argv[0], argv, e)
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.buf = ""
        self.raw = ""
        self.closed = False

    def _read(self, t):
        r, _, _ = select.select([self.fd], [], [], t)
        if not r:
            return False
        try:
            d = os.read(self.fd, 65536)
        except OSError:
            return False
        if not d:
            return False
        s = d.decode("utf-8", "replace")
        self.buf += s
        self.raw += s
        return True

    def send(self, s):
        os.write(self.fd, s.encode() if isinstance(s, str) else s)

    def expect(self, pat, timeout=4.0):
        """Wait until the (escape-stripped) output since the last match has `pat`;
        returns the text up to and including the match and consumes it."""
        end = time.time() + timeout
        rx = re.compile(pat, re.S)
        while True:
            m = rx.search(strip(self.buf))
            if m:
                txt = strip(self.buf)
                self.buf = ""
                return txt[: m.end()]
            if time.time() > end:
                return None
            self._read(0.05)

    def settle(self, t=0.25):
        end = time.time() + t
        while time.time() < end:
            self._read(0.03)

    def take(self):
        t = strip(self.buf)
        self.buf = ""
        return t

    def run(self, line, timeout=4.0, prompt=r"\$ $"):
        """Send a line, return its output (text between the echo and the next prompt)."""
        self.send(line + "\n")
        out = self.expect(r"\n[^\n]*" + prompt if False else prompt, timeout)
        return out

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.inner:
            shutil.rmtree(self.inner, ignore_errors=True)
        try:
            members = session_members(self.pid)
        except Exception:
            members = [self.pid]
        for p in members:
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()
