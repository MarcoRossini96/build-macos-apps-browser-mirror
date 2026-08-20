#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'macOS Window Browser can run only on macOS.\n' >&2
  exit 69
fi

if ! command -v xcrun >/dev/null 2>&1; then
  printf 'Xcode command-line tools are required to compile the native mirror helper.\n' >&2
  exit 69
fi

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/macos-window-browser.XXXXXX")"
helper_path="$runtime_dir/macos-window-browser"

cleanup() {
  rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM HUP

xcrun swiftc "$script_dir/macos_window_mirror.swift" \
  -framework AppKit \
  -framework ScreenCaptureKit \
  -framework Network \
  -framework Security \
  -o "$helper_path"

"$helper_path" "$@"
