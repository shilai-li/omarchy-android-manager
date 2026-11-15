#!/usr/bin/env bash
# One scrcpy, for one phone, for as long as it runs.
#
#   mirror.sh <device-id> <scrcpy option>…
#
# The options are built by Android.scrcpyArgs; this checks each one against
# the short list it may be, then execs scrcpy so the service's process *is*
# scrcpy and a SIGTERM reaches it directly. No deadline: a mirror runs until
# the user stops it, the phone goes away, or the service stops it.

. "${BASH_SOURCE[0]%/*}/guard.sh"

id=${1:-}
shift || true
am_valid_id "$id" || am_fail "not a device id"
command -v scrcpy >/dev/null 2>&1 || am_fail "scrcpy is not installed"

# Patterns live in variables: written inline, bash would hand the escaped
# characters to the regex engine with their backslashes, and inside a bracket
# expression a backslash is just one more allowed character. A window title is
# "Android · <name>", or with " · panel <n>" for an attached mirror.
title_re='^--window-title=Android · [A-Za-z0-9 ._+()-]{1,40}( · panel [1-9])?$'

home=${HOME:-}
records=0
for arg in "$@"; do
  case $arg in
    --no-audio | --stay-awake | --turn-screen-off | --window-borderless) continue ;;
  esac
  [[ $arg =~ ^--max-size=[0-9]{3,4}$ ]] && continue
  [[ $arg =~ ^--video-bit-rate=[0-9]{1,3}M$ ]] && continue
  [[ $arg =~ ^--max-fps=[0-9]{2,3}$ ]] && continue
  [[ $arg =~ $title_re ]] && continue
  if [[ $arg =~ ^--record=(.+)$ ]]; then
    file=${BASH_REMATCH[1]}
    dir=${file%/*}
    records=$((records + 1))
    [ "$records" -eq 1 ] || am_fail "refusing a second --record"
    # Only into a directory under $HOME that already exists, as a new .mp4 —
    # never over something, never through a symlink.
    if [[ $file == "$home"/*.mp4 ]] && [[ $file != *..* ]] && [ -d "$dir" ] \
      && [ ! -e "$file" ] && am_path_ok "$dir"; then
      continue
    fi
    am_fail "refusing to record to $file"
  fi
  am_fail "unexpected scrcpy option: $arg"
done

# Waking and unlocking the phone is the service's job (bin/unlock.sh, which
# checks first); doing it here too sent the keys twice.
exec scrcpy --serial="$id" "$@"
