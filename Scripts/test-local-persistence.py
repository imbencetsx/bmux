#!/usr/bin/env python3
"""Exercise the actual local tmux PTY helper in an isolated temporary server."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time
import uuid

root = Path(tempfile.mkdtemp(prefix="bmux-local-fixture-", dir="/tmp"))
helper = Path(__file__).resolve().parent.parent / ".build/debug/bmux-launch"
tmux = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
name = "bmux-local-" + str(uuid.uuid4())
environment = dict(os.environ, TMUX_TMPDIR=str(root))
launchers = []
active_fd = None


def query(*arguments):
    return subprocess.check_output(
        [tmux, "-L", "bmux-local-v1", *arguments], env=environment,
        text=True, stderr=subprocess.DEVNULL,
    ).strip()


def drain():
    if active_fd is not None:
        while select.select([active_fd], [], [], 0)[0]:
            try:
                if not os.read(active_fd, 65536):
                    break
            except OSError:
                break


def until(predicate, message):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        drain()
        try:
            if predicate():
                return
        except (FileNotFoundError, json.JSONDecodeError, subprocess.CalledProcessError):
            pass
        time.sleep(.02)
    raise AssertionError(message)


def metadata(filename):
    return json.loads((root / filename).read_text())


def launch(directory):
    global active_fd
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(environment, BMUX_TS=str(root / "transcript"), BMUX_INNER="tmux",
                   BMUX_REMOTE_DIRECTORY_FILE=str(root / "directory.json"),
                   BMUX_COMMAND_FILE=str(root / "command.json"),
                   BMUX_CLOSE_FILE=str(root / "close"), BMUX_REMOTE_SESSION=json.dumps({
                       "name": name, "sshArguments": [], "remoteCommand": ["/bin/sh", "-l"],
                       "local": {"workingDirectory": str(directory)},
                   }))
        os.execve(helper, [str(helper)], env)
    launchers.append((pid, fd))
    active_fd = fd
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    return pid, fd


try:
    directory = root / "folder ' with spaces é"
    directory.mkdir()
    first_pid, first_fd = launch(directory)
    until(lambda: metadata("directory.json") == str(directory.resolve()), "initial directory")
    shell_pid = query("display-message", "-p", "-t", name, "#{pane_pid}")
    os.write(first_fd, b"vim -Nu NONE -n\r")
    until(lambda: metadata("command.json") == "vim", "Vim foreground metadata")
    for index in range(150):
        fcntl.ioctl(first_fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", 20 + index % 20, 60 + index % 60, 0, 0))
        drain()
        time.sleep(.003)
    fcntl.ioctl(first_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 112, 0, 0))
    until(lambda: query("display-message", "-p", "-t", name,
                        "#{pane_width}x#{pane_height}") == "112x36", "final resize")
    os.close(first_fd)
    active_fd = None
    until(lambda: os.waitpid(first_pid, os.WNOHANG)[0] == first_pid, "helper detach")
    launchers.remove((first_pid, first_fd))
    assert query("display-message", "-p", "-t", name, "#{pane_pid}") == shell_pid
    (root / "command.json").unlink()
    _, second_fd = launch(directory)
    until(lambda: metadata("command.json") == "vim", "Vim reattach")
    assert query("display-message", "-p", "-t", name, "#{pane_pid}") == shell_pid
    os.write(second_fd, b":q!\r")
    until(lambda: metadata("command.json") in ("sh", "bash"), "input after reattach")
    (root / "close").touch()
    until(lambda: (root / "close.done").exists(), "explicit close acknowledgment")
    result = subprocess.run([tmux, "-L", "bmux-local-v1", "has-session", "-t", "=" + name],
                            env=environment, capture_output=True)
    assert result.returncode != 0
    print("PASS: local helper metadata, 150 rapid resizes, live Vim reattach, input and explicit close")
finally:
    for pid, fd in launchers:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    subprocess.run([tmux, "-L", "bmux-local-v1", "kill-server"], env=environment,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(root)
