#!/usr/bin/env bash
# Převede chyby kompilátoru / XCTestu z logu na GitHub anotace,
# aby byly čitelné i přes API (bez stahování celého logu).
log="$1"
ws="${GITHUB_WORKSPACE:-$PWD}"
[ -f "$log" ] || { echo "::error::Log $log neexistuje"; exit 0; }

pattern='^[^ ]+:[0-9]+:([0-9]+:)? (error|fatal error):'
if grep -qE "$pattern" "$log"; then
  grep -E "$pattern" "$log" | sort -u | head -30 | while IFS= read -r line; do
    file="${line%%:*}"; rest="${line#*:}"
    lineno="${rest%%:*}"; rest="${rest#*:}"
    col=""
    if [[ "$rest" =~ ^([0-9]+):(.*)$ ]]; then col="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; fi
    msg="${rest#*error: }"
    msg="${msg//%/%25}"
    rel="${file#"$ws"/}"
    echo "::error file=${rel},line=${lineno}${col:+,col=$col}::${rel}:${lineno}: ${msg}"
  done
else
  grep -iE 'error|failed|fatal' "$log" | tail -10 | while IFS= read -r l; do
    l="${l//%/%25}"
    echo "::error::${l}"
  done
fi
