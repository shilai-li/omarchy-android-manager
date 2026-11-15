#!/usr/bin/env bash
# One persistent shell on one phone, carrying an attached mirror's input.
#
#   input.sh <device-id>
#
# The service writes one `input keyevent …` line per press of the buttons
# beside an attached tile, built by Android.keyInput from a fixed list of key
# names. Touch and typing go through scrcpy's own window, not here. One shell
# for the life of the mirror rather than one adb process per press.
#
# No deadline: it lives as long as the mirror, and the service stops it with
# the mirror.

. "${BASH_SOURCE[0]%/*}/guard.sh"

id=${1:-}
am_valid_id "$id" || am_fail "not a device id"
exec adb -s "$id" shell
