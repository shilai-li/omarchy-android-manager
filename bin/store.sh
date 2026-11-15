#!/usr/bin/env bash
# The remembered-device file: phones seen before, their Wi-Fi address and
# their mirror options. The only file this plugin writes.
#
#   store.sh read     prints the file, or nothing when there is none yet
#   store.sh write    reads "<byte count>\n<bytes>" on stdin and replaces it
#
# The length prefix is there because the service holds the pipe open for the
# life of the session: a helper waiting for end-of-file would wait forever.
# A write lands as a 0600 file renamed into place, so a crash leaves the old
# file or the new one and never half of each.

. "${BASH_SOURCE[0]%/*}/guard.sh"

verb=${1:-}
file="$(am_state_dir)/devices.json"

case $verb in
  read)
    am_path_ok "$file" || am_fail "$am_reason"
    [ -e "$file" ] || exit 0
    info=$(stat -c '%F|%u|%s' -- "$file" 2>/dev/null) || exit 0
    kind=${info%%|*}; info=${info#*|}
    owner=${info%%|*}; size=${info##*|}
    case $kind in
      "regular file" | "regular empty file") ;;
      *) am_fail "$file is $kind, not a regular file" ;;
    esac
    [ "$owner" = "$am_uid" ] || am_fail "$file is owned by uid $owner"
    [ "$size" -le "$AM_MAX_STORE_BYTES" ] || am_fail "$file is larger than $AM_MAX_STORE_BYTES bytes"
    head -c "$AM_MAX_STORE_BYTES" -- "$file"
    ;;

  write)
    IFS= read -r count || am_fail "no length"
    [[ $count =~ ^[0-9]{1,6}$ ]] || am_fail "bad length"
    [ "$count" -le "$AM_MAX_STORE_BYTES" ] || am_fail "too large"
    am_ensure_state_dir || am_fail "$am_reason"
    dir=$(am_state_dir)

    tmp=$(umask 077; mktemp -p "$dir" ".devices.XXXXXX") || am_fail "cannot write to $dir"
    trap 'rm -f -- "$tmp"' EXIT
    head -c "$count" >"$tmp"
    got=$(stat -c %s -- "$tmp")
    [ "$got" = "$count" ] || am_fail "short write ($got of $count bytes)"
    am_path_ok "$file" || am_fail "$am_reason"
    mv -f -- "$tmp" "$file" || am_fail "cannot replace $file"
    trap - EXIT
    printf 'ok\n'
    ;;

  *) am_fail "unknown verb" ;;
esac
