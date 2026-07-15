#!/usr/bin/env python3
"""Run one command in an isolated process group and capture its output.

The supervisor intentionally stays outside the child session. Ralph tracks the
supervisor by PID/start token and can terminate the complete child process group
without relying on a racy descendant snapshot.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import selectors
import signal
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional


EX_SOFTWARE = 70
EX_IOERR = 74
EX_TEMPFAIL = 75
EX_PROTOCOL = 76


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--ack-file")
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--stdout-file")
    parser.add_argument("--merge-stderr", action="store_true")
    parser.add_argument("--handshake-timeout", type=float, default=5.0)
    parser.add_argument("--kill-after", type=float, default=1.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    args.handshake_timeout = min(max(args.handshake_timeout, 0.1), 30.0)
    args.kill_after = min(max(args.kill_after, 0.0), 30.0)
    return args


def enable_linux_subreaper() -> None:
    """Adopt and reap orphaned descendants when Linux supports prctl."""
    if not sys.platform.startswith("linux"):
        return
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        # PR_SET_CHILD_SUBREAPER from linux/prctl.h.
        libc.prctl(36, 1, 0, 0, 0)
    except (AttributeError, OSError):
        pass


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def atomic_write_state(path: Path, supervisor_pid: int, group_id: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        {
            "schema_version": 1,
            "supervisor_pid": supervisor_pid,
            "group_id": group_id,
        },
        separators=(",", ":"),
    ).encode("ascii") + b"\n"
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        write_all(fd, payload)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, path)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def wait_readable(fd: int, timeout: float) -> bool:
    selector = selectors.DefaultSelector()
    try:
        selector.register(fd, selectors.EVENT_READ)
        return bool(selector.select(timeout))
    finally:
        selector.close()


def wait_for_ack(path: Path, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.is_file():
            return True
        time.sleep(0.02)
    return path.is_file()


def group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def signal_group(group_id: int, signum: int) -> None:
    try:
        os.killpg(group_id, signum)
    except ProcessLookupError:
        pass


def child_exit_code(status: Optional[int]) -> int:
    if status is None:
        return EX_SOFTWARE
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return EX_SOFTWARE


def child_main(
    command: list[str],
    ready_write: int,
    release_read: int,
    output_write: int,
    log_fd: int,
    merge_stderr: bool,
) -> None:
    try:
        os.setsid()
        write_all(ready_write, b"R")
        os.close(ready_write)
        if os.read(release_read, 1) != b"R":
            os._exit(EX_PROTOCOL)
        os.close(release_read)

        os.dup2(output_write, 1)
        os.dup2(output_write if merge_stderr else log_fd, 2)
        os.close(output_write)
        os.close(log_fd)
        os.execvp(command[0], command)
    except BaseException as exc:
        try:
            message = f"ralph process supervisor: {type(exc).__name__}: {exc}\n"
            write_all(2, message.encode("utf-8", errors="replace"))
        except BaseException:
            pass
        os._exit(127)


def supervise(args: argparse.Namespace) -> int:
    state_path = Path(args.state_file)
    ack_path = Path(args.ack_file) if args.ack_file else None
    log_path = Path(args.log_file)
    output_path = Path(args.stdout_file) if args.stdout_file else None

    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.fchmod(log_fd, 0o600)
    output_fd = -1
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(output_fd, 0o600)

    enable_linux_subreaper()
    ready_read, ready_write = os.pipe()
    release_read, release_write = os.pipe()
    output_read, output_write = os.pipe()
    child_pid = os.fork()
    if child_pid == 0:
        os.close(ready_read)
        os.close(release_write)
        os.close(output_read)
        if output_fd >= 0:
            os.close(output_fd)
        child_main(
            args.command,
            ready_write,
            release_read,
            output_write,
            log_fd,
            args.merge_stderr,
        )
        os._exit(EX_SOFTWARE)

    os.close(ready_write)
    os.close(release_read)
    os.close(output_write)
    direct_status: Optional[int] = None
    selector = selectors.DefaultSelector()
    pending_signals: list[int] = []
    termination_deadline: Optional[float] = None
    kill_sent = False

    def queue_signal(signum: int, _frame: object) -> None:
        pending_signals.append(signum)

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM, signal.SIGQUIT):
        signal.signal(signum, queue_signal)

    try:
        if not wait_readable(ready_read, args.handshake_timeout):
            signal_group(child_pid, signal.SIGKILL)
            return EX_TEMPFAIL
        ready = os.read(ready_read, 16)
        if ready != b"R":
            signal_group(child_pid, signal.SIGKILL)
            return EX_PROTOCOL
        os.close(ready_read)
        ready_read = -1

        atomic_write_state(state_path, os.getpid(), child_pid)
        if ack_path is not None and not wait_for_ack(ack_path, args.handshake_timeout):
            signal_group(child_pid, signal.SIGKILL)
            return EX_TEMPFAIL

        for path in (state_path, ack_path):
            if path is not None:
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
        write_all(release_write, b"R")
        os.close(release_write)
        release_write = -1

        os.set_blocking(output_read, False)
        selector.register(output_read, selectors.EVENT_READ)
        output_open = True
        drain_deadline: Optional[float] = None

        while True:
            while pending_signals:
                signum = pending_signals.pop(0)
                signal_group(child_pid, signum)
                deadline = time.monotonic() + args.kill_after
                termination_deadline = min(termination_deadline or deadline, deadline)

            while True:
                try:
                    waited_pid, status = os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    break
                if waited_pid == 0:
                    break
                if waited_pid == child_pid:
                    direct_status = status

            now = time.monotonic()
            alive = group_exists(child_pid)
            if (
                termination_deadline is not None
                and now >= termination_deadline
                and alive
                and not kill_sent
            ):
                signal_group(child_pid, signal.SIGKILL)
                kill_sent = True

            # Self-benchmarking: next, measure CPU on high-volume provider logs
            # before tuning this 50 ms selector interval.
            for key, _ in selector.select(0.05):
                try:
                    chunk = os.read(key.fd, 65536)
                except BlockingIOError:
                    continue
                if chunk:
                    write_all(log_fd, chunk)
                    if output_fd >= 0:
                        write_all(output_fd, chunk)
                else:
                    selector.unregister(key.fd)
                    os.close(key.fd)
                    output_open = False

            if direct_status is not None and not alive:
                if not output_open:
                    break
                if drain_deadline is None:
                    drain_deadline = now + 0.5
                elif now >= drain_deadline:
                    selector.unregister(output_read)
                    os.close(output_read)
                    output_open = False
                    break

        return child_exit_code(direct_status)
    finally:
        selector.close()
        for fd in (ready_read, release_write, output_read, output_fd, log_fd):
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass
        for path in (state_path, ack_path):
            if path is not None:
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
        if group_exists(child_pid):
            signal_group(child_pid, signal.SIGKILL)
        if direct_status is None:
            try:
                _, direct_status = os.waitpid(child_pid, 0)
            except ChildProcessError:
                pass
        while True:
            try:
                waited_pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if waited_pid == 0:
                break


def main() -> int:
    args = parse_args()
    try:
        return supervise(args)
    except (OSError, ValueError) as exc:
        print(f"ralph process supervisor: {type(exc).__name__}: {exc}", file=sys.stderr)
        return EX_IOERR


if __name__ == "__main__":
    raise SystemExit(main())
