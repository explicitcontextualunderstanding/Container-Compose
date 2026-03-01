#!/bin/bash
# Simple static checks for compose files to ensure required keys are present
set -euo pipefail

ROOT=".devcontainer"
FILES=("$ROOT/docker-compose.apple.yml" "$ROOT/docker-compose.dev.yml")

missing=0
for f in "${FILES[@]}"; do
  if [[ -f "$f" ]]; then
    echo "Checking $f"
    if ! grep -q "restart:" "$f"; then
      echo "  FAIL: restart: not found in $f" >&2
      missing=1
    else
      echo "  OK: restart present"
    fi
    if ! grep -q "dns_search" "$f" && ! grep -q "dns-search" "$f"; then
      echo "  WARN: dns_search not found in $f" >&2
    else
      echo "  OK: dns_search present"
    fi
  else
    echo "Skipping missing file: $f"
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "One or more required keys missing" >&2
  exit 2
fi

echo "Static compose checks passed"
