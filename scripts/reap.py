#!/usr/bin/env python3
"""Run a command as a child subreaper (ADR 0003 D12).

What the command leaves behind (Gradle's single-use daemon, a server that was not
stopped, a background job) is re-parented here instead of to PID 1, which in some
containers reaps nothing and collects every such process as a zombie. Each one is
reaped here.

  reap.py [--wait] [--grace SECONDS] -- COMMAND [ARGS...]

When COMMAND exits, the processes it left behind get SIGTERM, and SIGKILL after the
grace period (10 s). With --wait they are waited for instead: a service that outlives
COMMAND, with this started in the background. The exit status is COMMAND's.
"""
import ctypes
import os
import signal
import sys
import time

PR_SET_CHILD_SUBREAPER = 36


def descendants(root):
    """Every process below root, by the parent pids in /proc."""
    children = {}
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        try:
            with open(f'/proc/{d}/stat') as f:
                # the command name may hold spaces and parentheses: the fields after the
                # last ')' are the state and the parent pid
                ppid = int(f.read().rsplit(')', 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            continue
        children.setdefault(ppid, []).append(int(d))
    found, todo = [], [root]
    while todo:
        for c in children.get(todo.pop(), []):
            found.append(c)
            todo.append(c)
    return found


def comm(pid):
    try:
        with open(f'/proc/{pid}/comm') as f:
            return f.read().strip()
    except OSError:
        return '?'


def reap_exited():
    """Reap what has exited; False once no child is left."""
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return False
        if pid == 0:
            return True


def main(argv):
    wait, grace = False, 10.0
    while argv and argv[0] != '--':
        a = argv.pop(0)
        if a == '--wait':
            wait = True
        elif a == '--grace' and argv:
            grace = float(argv.pop(0))
        else:
            sys.exit(__doc__)
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1:]

    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        sys.exit('reap.py: prctl(PR_SET_CHILD_SUBREAPER): ' + os.strerror(ctypes.get_errno()))

    child = os.fork()
    if child == 0:
        try:
            os.execvp(cmd[0], cmd)
        except OSError as e:
            print(f'reap.py: {cmd[0]}: {e.strerror}', file=sys.stderr)
            os._exit(127)

    done = False

    def forward(signum, _frame):
        # to COMMAND while it runs, to what it left behind afterwards
        for p in ([child] if not done else descendants(os.getpid())):
            try:
                os.kill(p, signum)
            except ProcessLookupError:
                pass

    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, forward)

    status = None
    while status is None:
        try:
            pid, st = os.waitpid(-1, 0)
        except ChildProcessError:
            break
        if pid == child:
            status = st
    done = True

    me = os.getpid()
    if wait:
        while True:
            try:
                os.waitpid(-1, 0)
            except ChildProcessError:
                break
    else:
        for sig, limit in ((signal.SIGTERM, grace), (signal.SIGKILL, 5.0)):
            left = descendants(me)
            if not left:
                break
            print(f'reap.py: {cmd[0]} left {len(left)} process(es) behind; sending '
                  f'{signal.Signals(sig).name}: ' + ' '.join(f'{p}({comm(p)})' for p in left),
                  file=sys.stderr)
            for p in left:
                try:
                    os.kill(p, sig)
                except ProcessLookupError:
                    pass
            end = time.monotonic() + limit
            while reap_exited() and time.monotonic() < end:
                time.sleep(0.1)
        reap_exited()

    if status is None:
        return 1
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
