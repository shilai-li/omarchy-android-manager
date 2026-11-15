#!/usr/bin/env bash
# adb over the network, three verbs:
#
#   connect.sh connect <host:port>       `adb connect`
#   connect.sh disconnect <host:port>    `adb disconnect`
#   connect.sh pair <host:port>          `adb pair`, the code read from stdin
#   connect.sh mdns                      phones advertising Wireless debugging
#
# Prints adb's own answer; Android.parseConnect / parsePair read it, because
# `adb connect` exits 0 when it fails.

. "${BASH_SOURCE[0]%/*}/guard.sh"

verb=${1:-}
target=${2:-}

case $verb in
  connect | disconnect | pair)
    am_valid_address "$target" || am_fail "not an address: host:port"
    ;;
  mdns) ;;
  *) am_fail "unknown verb" ;;
esac

case $verb in
  connect)
    am_adb "$AM_CONNECT_SECONDS" connect "$target" 2>&1 | tr -d '\r' | tail -n 3
    ;;
  disconnect)
    am_adb "$AM_ADB_SECONDS" disconnect "$target" 2>&1 | tr -d '\r' | tail -n 3
    ;;
  pair)
    # The code arrives on stdin and leaves on adb's stdin, at its prompt —
    # never on argv, which every process on the machine can read in /proc.
    IFS= read -r code || code=""
    [[ $code =~ ^[0-9]{6,10}$ ]] || am_fail "the pairing code is the 6 digits the phone shows"
    am_input=$code am_adb "$AM_CONNECT_SECONDS" pair "$target" 2>&1 | tr -d '\r' | tail -n 3
    ;;
  mdns)
    am_adb "$AM_ADB_SECONDS" mdns services 2>&1 | tr -d '\r' | head -n 64
    ;;
esac
exit 0
