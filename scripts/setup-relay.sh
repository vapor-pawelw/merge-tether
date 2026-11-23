#!/bin/bash
set +x
set -eu
umask 077

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ -t 0 ]] || fail 'Run the relay setup in a terminal.'
IFS= read -r -p 'Relay HTTPS URL: ' origin
[[ "$origin" =~ [^[:space:]] ]] || fail 'Enter the relay HTTPS URL.'
# Same rules as Project.swift, so a saved origin never breaks project generation.
python3 - "$origin" <<'PY' || fail 'The relay URL must be an HTTPS origin without credentials, path, query or fragment.'
import sys, urllib.parse
raw = sys.argv[1].strip()
try:
    parts = urllib.parse.urlsplit(raw)
    valid = (raw.isascii() and not any(c.isspace() or ord(c) < 32 for c in raw)
             and not any(c in raw for c in '%\\?#') and parts.scheme.lower() == 'https'
             and bool(parts.hostname) and parts.username is None and parts.password is None
             and parts.path in ('', '/') and (parts.port is None or 1 <= parts.port <= 65535))
except ValueError:
    valid = False
sys.exit(0 if valid else 1)
PY
terminal_state="$(stty -g)"
trap 'stty "$terminal_state"' EXIT
stty -echo
printf 'Relay access token: ' >&2
IFS=$' \t' read -r token
stty "$terminal_state"
trap - EXIT
printf '\n' >&2
[[ "$token" =~ ^[A-Za-z0-9_-]{43}$ ]] || fail 'The relay access token must be 43 base64url characters.'

relay_dir="$HOME/Library/Application Support/MergeTether/remote-relay"
mkdir -p "$relay_dir"
staged="$(mktemp -d "$relay_dir/.setup.XXXXXX")"
trap 'rm -rf "$staged"' EXIT
lock="$relay_dir/.setup.lock"
shlock -f "$lock" -p "$$" || fail 'Relay setup is already running. Try again once it finishes.'
trap 'rm -f "$lock"; rm -rf "$staged"' EXIT

printf '%s\n%s\n' "$origin" "$token" > "$staged/pairing.txt"
printf '%s\n' "$origin" > "$staged/build-origin.txt"
mv -fh "$staged/pairing.txt" "$relay_dir/pairing.txt"
mv -fh "$staged/build-origin.txt" "$relay_dir/build-origin.txt"

printf '%s\n' 'Relay setup saved. Generate the Xcode project before building both apps.' \
  '  mise exec -- tuist generate --no-open'
