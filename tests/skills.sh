#!/usr/bin/env bash
# Static skill discovery checks; no network, tmux server or YAML dependency.
# Uses the repository's single-line name/description frontmatter convention.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
shopt -s nullglob
files=("$here"/skills/*/SKILL.md)
if [ "${#files[@]}" -eq 0 ]; then
  echo 'FAIL  no skills/*/SKILL.md files'
  exit 1
fi

for file in "${files[@]}"; do
  if [ ! -s "$file" ]; then
    echo "FAIL  $file: empty skill file"
    exit 1
  fi
done

awk '
function fail(message) {
  print "FAIL  " file ": " message
  failures++
}
function scalar(value, quote) {
  sub(/^[[:space:]]+/, "", value)
  sub(/[[:space:]]+$/, "", value)
  quote = substr(value, 1, 1)
  if ((quote == "\"" || quote == sprintf("%c", 39)) &&
      substr(value, length(value), 1) == quote)
    value = substr(value, 2, length(value) - 2)
  sub(/^[[:space:]]+/, "", value)
  sub(/[[:space:]]+$/, "", value)
  return value
}
function finish(    parts, n, folder) {
  if (file == "") return
  if (!started || !closed) fail("missing or unclosed frontmatter")
  if (name == "") fail("name must be non-empty")
  if (description == "") fail("description must be non-empty")
  n = split(file, parts, "/")
  folder = parts[n - 1]
  if (name != "" && name != folder) fail("name must match folder " folder)
  if (name != "" && seen[name]++) fail("duplicate skill name " name)
  if (failures == before) print "ok    " folder
}
FNR == 1 {
  finish()
  file = FILENAME
  started = ($0 == "---")
  closed = 0
  name = description = ""
  before = failures
  next
}
started && !closed && $0 == "---" { closed = 1; next }
started && !closed && /^(name|description):/ {
  key = $0
  sub(/:.*/, "", key)
  value = $0
  sub(/^[^:]*:/, "", value)
  value = scalar(value)
  if (key == "name") name = value
  else description = value
}
END {
  finish()
  exit (failures != 0)
}
' "${files[@]}"
