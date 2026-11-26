#!/usr/bin/env bash
# Compatibility entry point for existing local build commands.
exec "$(dirname "${BASH_SOURCE[0]}")/build-ios-ipa.sh" "$@"
