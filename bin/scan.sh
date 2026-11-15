#!/usr/bin/env bash
# Everything the panel shows, as one record per line (see Android.parseScan):
#
#   T adb <version>|missing        T scrcpy <version>|missing
#                                  (versions only with `scan.sh versions`)
#   D <one `adb devices -l` line>
#   P <id> <one line the phone printed about itself>
#   E <message>
#
# Read-only on the phone: getprop, dumpsys battery, ip, wm size and df. This
# is what runs every time the panel opens, so it does nothing a user would
# have to agree to.

. "${BASH_SOURCE[0]%/*}/guard.sh"

# The device-side half, one constant string. It reaches the phone as a single
# argument to `adb shell`; nothing in it comes from outside this file.
readonly PROBE='
echo "model=$(getprop ro.product.model)"
echo "manufacturer=$(getprop ro.product.manufacturer)"
echo "serialno=$(getprop ro.serialno)"
echo "release=$(getprop ro.build.version.release)"
echo "sdk=$(getprop ro.build.version.sdk)"
echo @battery; dumpsys battery 2>/dev/null
echo @ip; ip -f inet addr show wlan0 2>/dev/null
echo @wm; wm size 2>/dev/null
echo @df; df -k /data 2>/dev/null | tail -n 1
'

# Starting adb and scrcpy just to ask their versions took 40 of a scan's
# 50 ms (scrcpy alone 35), on every scan, for a header that never changes.
# The service asks for them (`scan.sh versions`) on its first scan, on ^r,
# and while a tool is missing; every scan still says when one is missing.
want_versions=0
[ "${1:-}" = versions ] && want_versions=1

if ! command -v adb >/dev/null 2>&1; then
  printf 'T adb missing\n'
elif [ "$want_versions" = 1 ]; then
  version=$(am_adb "$AM_ADB_SECONDS" version 2>/dev/null | sed -n 's/^Version \([0-9][0-9A-Za-z.+-]*\).*/\1/p' | head -n 1)
  printf 'T adb %s\n' "${version:-unknown}"
fi

if ! command -v scrcpy >/dev/null 2>&1; then
  printf 'T scrcpy missing\n'
elif [ "$want_versions" = 1 ]; then
  version=$(am_run_bounded "$AM_ADB_SECONDS" scrcpy --version 2>/dev/null | sed -n 's/^scrcpy \([0-9][0-9A-Za-z.+-]*\).*/\1/p' | head -n 1)
  printf 'T scrcpy %s\n' "${version:-unknown}"
fi

command -v adb >/dev/null 2>&1 || exit 0

listing=$(am_adb "$AM_ADB_SECONDS" devices -l 2>&1)
rc=$?
if [ $rc -eq 124 ]; then
  am_fail "adb devices took too long"
fi

ready=()
while IFS= read -r line; do
  line=${line%$'\r'}
  case $line in
    "" | "List of devices"* | "*"*) continue ;;
  esac
  id=${line%%[[:space:]]*}
  am_valid_id "$id" || continue
  printf 'D %s\n' "$line"
  rest=${line#"$id"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  state=${rest%%[[:space:]]*}
  [ "$state" = "device" ] && ready+=("$id")
done <<<"$listing"

probe() {
  local id=$1 line
  am_adb "$AM_PROBE_SECONDS" -s "$id" shell "$PROBE" 2>/dev/null \
    | head -c "$AM_MAX_PROBE_BYTES" | head -n "$AM_MAX_PROBE_LINES" \
    | while IFS= read -r line; do
        printf 'P %s %s\n' "$id" "${line%$'\r'}"
      done
}

# All phones are asked at once (over Wi-Fi each takes 150-350 ms), and their
# answers are printed one phone after another. Each probe writes into its own
# pipe, which holds all of it: the caps above keep it near 21 KB, under a
# pipe's 64 KB, so no probe waits on the reader.
fds=()
for id in "${ready[@]}"; do
  exec {fd}< <(probe "$id")
  fds+=("$fd")
done
for fd in "${fds[@]}"; do
  cat <&"$fd"
  exec {fd}<&-
done
exit 0
