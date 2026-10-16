#!/usr/bin/env python3
"""Read local shell history as data, or pick a command without executing it."""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


def default_file(shell):
    if shell == 'fish':
        name = os.environ.get('fish_history', 'fish')
        if not name or '/' in name:
            return None
        root = os.environ.get('XDG_DATA_HOME') or str(Path.home() / '.local/share')
        return Path(root) / 'fish' / (name + '_history')
    if shell in ('bash', 'zsh'):
        value = os.environ.get('HISTFILE', str(Path.home() / ('.' + shell + '_history')))
        return Path(value) if value else None
    return None


def fish_unescape(value):
    # Fish history is a small YAML-like format, not shell quoting. Only these
    # two escapes are written by fish; leave unknown escapes literally intact.
    return re.sub(br'\\([\\n])', lambda m: b'\n' if m[1] == b'n' else b'\\', value)


def commands(shell, path):
    if path is None or shell not in ('fish', 'bash', 'zsh'):
        return []
    try:
        raw = path.read_bytes()
    except OSError:
        return []
    lines = raw.split(b'\n')
    if lines and lines[-1] == b'':
        lines.pop()
    if shell == 'fish':
        rows = [fish_unescape(line[7:]) for line in lines if line.startswith(b'- cmd: ')]
    elif shell == 'bash':
        # Timestamped bash history has reliable record boundaries. Without
        # timestamps the format cannot distinguish literal newlines from entries.
        timestamp = re.compile(br'^#[0-9]+$')
        if any(timestamp.match(line) for line in lines):
            rows, current = [], []
            for line in lines:
                if timestamp.match(line):
                    if current:
                        rows.append(b'\n'.join(current))
                    current = []
                else:
                    current.append(line)
            if current:
                rows.append(b'\n'.join(current))
        else:
            rows = lines
    else:
        rows, current = [], b''
        for line in lines:
            if not current:
                line = re.sub(br'^: [0-9]+:[0-9]+;', b'', line, count=1)
            # zsh writes a backslash before each embedded newline.
            if line.endswith(b'\\'):
                current += line[:-1] + b'\n'
            else:
                rows.append(current + line)
                current = b''
        if current:
            rows.append(current)
        # zsh's Meta byte encodes otherwise special bytes (including high bytes).
        rows = [re.sub(br'\x83(.)', lambda m: bytes([m[1][0] ^ 32]), row,
                       flags=re.DOTALL) for row in rows]
    seen, result = set(), []
    for row in reversed(rows):
        # NUL cannot occur in a shell command argument or the picker protocol.
        if row.strip() and b'\0' not in row and row not in seen:
            seen.add(row)
            result.append(row)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'Enter: selected history, or new query when no match. '
        'Alt-Enter: use query even with a match. Esc: cancel. '
        'Only saved history is read; no shell startup files are sourced.'))
    parser.add_argument('--shell', required=True)
    parser.add_argument('--history-file', type=Path)
    parser.add_argument('--pick', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.pick and args.output is None:
        parser.error('--pick requires --output')
    if args.output is not None and not args.pick:
        parser.error('--output requires --pick')
    shell = os.path.basename(args.shell)
    rows = commands(shell, args.history_file if args.history_file is not None else default_file(shell))
    data = b''.join(row + b'\0' for row in rows)
    if not args.pick:
        sys.stdout.buffer.write(data)
        return 0
    env = os.environ.copy()
    # User fzf defaults may change the output protocol or run preview commands.
    env.pop('FZF_DEFAULT_OPTS', None)
    env.pop('FZF_DEFAULT_OPTS_FILE', None)
    try:
        picked = subprocess.run([
            'fzf', '--read0', '--print0', '--print-query', '--expect=alt-enter',
            '--no-multi', '--no-sort', '--bind=enter:accept-or-print-query',
            '--prompt=Command> ',
            '--header=Enter: history / new query | Alt-Enter: query | Esc: cancel',
        ], input=data, stdout=subprocess.PIPE, env=env, check=False)
    except OSError as error:
        print('tmux-shell-history: cannot start fzf: ' + str(error), file=sys.stderr)
        return 1
    fields = picked.stdout.split(b'\0')
    # fzf returns 1 for an expected key with no selected match, even when
    # Alt-Enter explicitly accepts a nonempty query. Abort (130) never writes.
    if picked.returncode != 0 and not (
            picked.returncode == 1 and len(fields) >= 3 and fields[1] == b'alt-enter'):
        return 1
    if len(fields) == 2 and fields[-1] == b'':
        # accept-or-print-query emits only the query when there is no match,
        # bypassing --print-query and --expect's usual prefix fields.
        command = fields[0]
    elif len(fields) >= 3:
        query, key = fields[:2]
        selected = fields[2]
        command = query if key == b'alt-enter' or not selected else selected
    else:
        return 1
    if not command.strip() or b'\0' in command:
        return 1
    try:
        fd = os.open(str(args.output), os.O_WRONLY | os.O_CREAT | os.O_TRUNC |
                     getattr(os, 'O_NOFOLLOW', 0), 0o600)
        with os.fdopen(fd, 'wb') as output:
            output.write(command)
    except OSError as error:
        print('tmux-shell-history: cannot write selection: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
