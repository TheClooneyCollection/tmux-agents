#!/usr/bin/env bash
# Syntax and ShellCheck coverage for every repository shell entry point.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
command -v shellcheck >/dev/null || { echo 'ERROR: shellcheck is required' >&2; exit 1; }
files=(install.sh)
while IFS= read -r -d '' file; do
  case "$file" in
    *.sh) files+=("$file") ;;
    *) IFS= read -r first <"$file" || true
       case "$first" in '#!'*sh*) files+=("$file") ;; esac ;;
  esac
done < <(find bin tests ci -type f -print0)
failed=0
for file in "${files[@]}"; do
  /bin/bash -n "$file" || failed=1
done
shellcheck --version
shellcheck --external-sources --source-path=SCRIPTDIR --source-path=. --source-path=bin --shell=bash "${files[@]}" || failed=1
[ "$failed" -eq 0 ] || exit 1
printf 'PASS: bash syntax and ShellCheck (%s files)\n' "${#files[@]}"
