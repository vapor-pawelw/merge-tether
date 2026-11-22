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
