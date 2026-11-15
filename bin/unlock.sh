#!/usr/bin/env bash
# Wake a phone and dismiss its keyguard, but only what is needed.
#
#   unlock.sh <device-id>
#
# The service calls this when a mirror starts and whenever a phone locks
# while mirrored, so the mirrored screen stays unlocked while the physical
# screen stays off.
#
# The phone is asked first, and each key goes only where it applies: wake
# only an asleep phone, dismiss only a keyguard that is showing, and the menu
# key (which unlocks a swipe keyguard on some phones) only if it is still
# showing after that. Sent blindly, the menu key reached whatever app was in
# front of an unlocked phone.
#
# Prints what it did, one word per line (woke, dismissed, menu), then
# `locked` if the keyguard is still up after all that: a PIN, pattern or
# password only the user can enter. Nothing when the phone was already awake
# and unlocked. Android.parseUnlock reads it.
#
# Some phones (ColorOS on the OnePlus PJZ110) keep their lock screen out of
# every screen capture, scrcpy's included, so a locked one shows black in the
# mirror and can only be unlocked on the phone itself. That is why the
# service keeps the physical screen on while this says `locked`.

. "${BASH_SOURCE[0]%/*}/guard.sh"

id=${1:-}
am_valid_id "$id" || am_fail "not a device id"

readonly UNLOCK='
locked() { dumpsys window 2>/dev/null | grep -qm1 "isKeyguardShowing=true"; }
if ! dumpsys power 2>/dev/null | grep -qm1 "mWakefulness=Awake"; then
  input keyevent KEYCODE_WAKEUP 2>/dev/null; echo woke
fi
if locked; then
  wm dismiss-keyguard 2>/dev/null; echo dismissed
  sleep 0.3
  if locked; then input keyevent KEYCODE_MENU 2>/dev/null; echo menu; sleep 0.2; fi
  if locked; then echo locked; fi
fi
'

am_adb "$AM_PROBE_SECONDS" -s "$id" shell "$UNLOCK" 2>/dev/null | tr -d '\r'
exit 0
