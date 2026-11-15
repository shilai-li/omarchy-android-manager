#!/usr/bin/env bash
# Move a USB-connected phone to adb over Wi-Fi, the way this user does it by
# hand: `adb tcpip <port>`, then `adb connect <ip>:<port>`.
#
#   wifi.sh <usb-id> <port> [ip]
#
# Reports each step as it happens, for the panel's checklist:
#
#   STEP <0-3> run|ok|fail <detail>
#
# 0 the phone is on USB, 1 its Wi-Fi address, 2 adbd restarted listening on
# the port, 3 connected over Wi-Fi. The last `ok` carries ip:port, which the
# service remembers. tcpip mode lasts until the phone reboots.

. "${BASH_SOURCE[0]%/*}/guard.sh"

id=${1:-}
port=${2:-}
given_ip=${3:-}

am_valid_id "$id" || { printf 'STEP 0 fail not a device id\n'; exit 1; }
am_valid_port "$port" || { printf 'STEP 0 fail not a port\n'; exit 1; }
if [ -n "$given_ip" ] && ! am_valid_host "$given_ip"; then
  printf 'STEP 1 fail not an address\n'; exit 1
fi

state=$(am_adb "$AM_ADB_SECONDS" -s "$id" get-state 2>/dev/null | tr -d '\r')
if [ "$state" != "device" ]; then
  printf 'STEP 0 fail %s is %s\n' "$id" "${state:-not connected}"
  exit 1
fi
printf 'STEP 0 ok %s\n' "$id"

if [ -n "$given_ip" ]; then
  ip=$given_ip
  printf 'STEP 1 ok %s (as given)\n' "$ip"
else
  printf 'STEP 1 run reading wlan0\n'
  ip=$(am_adb "$AM_PROBE_SECONDS" -s "$id" shell 'ip -f inet addr show wlan0' 2>/dev/null \
    | sed -n 's/.*inet \([0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}\)\/.*/\1/p' | head -n 1)
  if [ -z "$ip" ] || ! am_valid_host "$ip"; then
    printf 'STEP 1 fail the phone has no Wi-Fi address — is it on Wi-Fi?\n'
    exit 1
  fi
  printf 'STEP 1 ok %s\n' "$ip"
fi

printf 'STEP 2 run restarting adbd\n'
out=$(am_adb "$AM_ADB_SECONDS" -s "$id" tcpip "$port" 2>&1 | tr -d '\r' | tail -n 1)
case $out in
  *"restarting in TCP mode"*) printf 'STEP 2 ok listening on %s\n' "$port" ;;
  *) printf 'STEP 2 fail %s\n' "${out:-adb did not answer}"; exit 1 ;;
esac

# adbd takes a moment to come back on the new port. A few tries, a second
# apart, rather than one connect that races it.
printf 'STEP 3 run connecting\n'
target="$ip:$port"
last=""
for _ in 1 2 3 4 5 6; do
  sleep 1
  last=$(am_adb "$AM_CONNECT_SECONDS" connect "$target" 2>&1 | tr -d '\r' | tail -n 1)
  case $last in
    "connected to "* | "already connected to "*)
      printf 'STEP 3 ok %s\n' "$target"
      exit 0
      ;;
  esac
done
printf 'STEP 3 fail %s\n' "${last:-adb did not answer}"
exit 1
