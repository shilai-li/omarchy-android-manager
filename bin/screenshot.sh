#!/usr/bin/env bash
# Save what one phone's screen shows now as a PNG in the user's Pictures/omarchy-android-manager.
#
#   screenshot.sh <device-id> <file-stem>
#
# Prints the saved path, or `E <reason>`. Written to a temporary name in the
# same directory and renamed into place only once it is a whole PNG.

. "${BASH_SOURCE[0]%/*}/guard.sh"

id=${1:-}
stem=${2:-}
am_valid_id "$id" || am_fail "not a device id"
[[ $stem =~ ^[A-Za-z0-9._-]{1,80}$ ]] || am_fail "not a file name"

base=$(xdg-user-dir PICTURES 2>/dev/null)
case $base in
  /*) ;;
  *) base="$HOME/Pictures" ;;
esac
[ -d "$base" ] || am_fail "$base does not exist"
am_path_ok "$base" || am_fail "$am_reason"

dir="$base/omarchy-android-manager"
if [ ! -d "$dir" ]; then
  mkdir -p "$dir" || am_fail "cannot create $dir"
fi
am_path_ok "$dir" || am_fail "$am_reason"

final="$dir/$stem.png"
[ -e "$final" ] && am_fail "$final already exists"

tmp=$(mktemp -p "$dir" ".android-shot.XXXXXX") || am_fail "cannot write to $dir"
trap 'rm -f -- "$tmp"' EXIT

am_adb "$AM_CAPTURE_SECONDS" -s "$id" exec-out screencap -p >"$tmp" 2>/dev/null
rc=$?
[ $rc -eq 124 ] && am_fail "the phone took too long"

# A PNG starts with \x89PNG; anything else is adb's error text.
magic=$(head -c 4 -- "$tmp" | od -An -tx1 | tr -d ' \n')
[ "$magic" = "89504e47" ] || am_fail "the phone did not send a picture"

mv -n -- "$tmp" "$final" || am_fail "cannot save $final"
trap - EXIT
printf '%s\n' "$final"
