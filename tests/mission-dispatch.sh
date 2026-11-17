#!/usr/bin/env bash
# Mission dispatch with open stdin, and malformed commands outside tmux.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$here" <<'PYTEST'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="tmux-mission-dispatch.") as temporary:
    tmp = Path(temporary)
    project = tmp / "project"
    project.mkdir()
    stubs = tmp / "stubs"
    stubs.mkdir()
    calls = tmp / "calls"
    # Never connect to a server, run an agent, or open a real picker.
    for name in ("tmux", "fzf", "claude", "codex"):
        stub = stubs / name
        stub.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$MISSION_CALLS"\nexit 91\n')
        stub.chmod(0o755)
    env = dict(os.environ, PATH=str(stubs) + os.pathsep + os.environ["PATH"],
               XDG_STATE_HOME=str(tmp / "state"), MISSION_CALLS=str(calls))
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)

    def run(args, open_stdin=False, expected=0):
        process = subprocess.Popen(args, cwd=project, env=env,
                                   stdin=subprocess.PIPE if open_stdin else subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            # wait(), not communicate(): keep the pipe open without sending EOF.
            process.wait(timeout=5)
            stdout = process.stdout.read().decode()
            stderr = process.stderr.read().decode()
            assert process.returncode == expected, (args, process.returncode, stderr)
            return stdout, stderr
        except subprocess.TimeoutExpired:
            raise AssertionError("command blocked with open stdin: " + repr(args)) from None
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

    direct = [str(root / "bin/tmux-agents-mission")]
    dispatcher = [str(root / "bin/tmux-agents")]
    assert run(direct + ["add", "Dispatch test", "--from", "tester"])[0] == "M1\n"
    for command in (direct, dispatcher + ["mission"]):
        for open_stdin in (False, True):
            title = "open stdin" if open_stdin else "closed stdin"
            assert run(command + ["set", "M1", "--title", title, "--from", "tester"],
                       open_stdin=open_stdin) == ("", "")
            record = tmp / "state/tmux-agents/missions/project/M1.mission"
            assert "title=" + title in record.read_text().splitlines()
    for args in (["--from", "tester", "mission", "set", "M1", "--status", "active"],
                 ["misspelled-command"], ["--unknown"]):
        for open_stdin in (False, True):
            stdout, stderr = run(dispatcher + args, open_stdin=open_stdin, expected=1)
            assert stdout == "", stdout
            assert "unknown argument: " + args[0] in stderr, stderr
    assert not calls.exists(), calls.read_text() if calls.exists() else ""
    print("PASS: mission dispatch ignores stdin; malformed commands fail before picker/tmux")
PYTEST
