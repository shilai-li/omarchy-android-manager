#!/usr/bin/env bash
# Watch whether a phone is locked and whether it is awake. Read-only.
#
#   lockstate.sh <device-id>
#
# One persistent `adb shell` for the life of a mirror with the screen-off
# option. The loop runs on the phone, checks once a second, and prints a line
# only when the answer changes (the first one at once), for
# Android.parseLockState:
#
#   isKeyguardShowing=true|false mWakefulness=Awake|Asleep|Dozing|Dreaming
#
# It replaced a fresh adb connection and helper every second (nine processes
# on this side each time). No deadline: the service stops it with the mirror,
# and killing the host's adb ends the loop on the phone too.

. "${BASH_SOURCE[0]%/*}/guard.sh"

id=${1:-}
am_valid_id "$id" || am_fail "not a device id"

readonly WATCH='
last=""
while :; do
  k=$(dumpsys window 2>/dev/null | grep -m1 -oE "isKeyguardShowing=(true|false)")
  w=$(dumpsys power 2>/dev/null | grep -m1 -oE "mWakefulness=[A-Za-z]+")
  now="$k $w"
  if [ "$now" != "$last" ]; then echo "$now"; last=$now; fi
  sleep 1
done
'

exec adb -s "$id" shell "$WATCH"
