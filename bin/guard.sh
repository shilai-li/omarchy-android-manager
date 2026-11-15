# Shared guards for every helper. Sourced, never executed:
#
#   . "${BASH_SOURCE[0]%/*}/guard.sh"
#
# Three things live here because getting any of them wrong once is enough.
#
# **Ceilings.** adb waits a long time on a phone that has gone away: `adb
# connect` to an address nobody answers on, `adb shell` to a device that just
# dropped off the network. These helpers run inside a shell that stays up for
# the whole login session, so every adb call has a deadline that takes its
# whole process group with it.
#
# **Arguments, not strings.** A device id, an address and a pairing code are
# data from a cable, a network or a text field. They reach adb as single argv
# entries after they have been checked against what such a thing can look
# like, and nothing here ever builds a command line out of them or `eval`s.
#
# **A fixed PATH.** The ambient PATH belongs to whatever started the shell,
# possibly hours ago; `adb` and `scrcpy` are not names to resolve through it.

PATH=/usr/bin:/bin
export PATH

# adb's and the phone's messages are matched as ASCII, and ${#var} should
# count bytes.
LC_ALL=C
export LC_ALL

# Constants on purpose: an environment variable that could raise them would be
# one more thing to have to trust.
readonly AM_ADB_SECONDS=8          # one local adb request (devices, tcpip…)
readonly AM_PROBE_SECONDS=6        # one device-side probe over `adb shell`
readonly AM_CONNECT_SECONDS=12     # one `adb connect` / `adb pair`
readonly AM_CAPTURE_SECONDS=20     # one screenshot
readonly AM_MAX_PROBE_BYTES=16384  # what one phone may say about itself
readonly AM_MAX_PROBE_LINES=160
readonly AM_MAX_STORE_BYTES=65536  # the remembered-device file

am_uid=$(id -u)
am_reason=""

am_fail() {
  printf 'E %s\n' "$*"
  exit 1
}

# What a device id from `adb devices` can look like: a USB serial, ip:port,
# or an mDNS service name. Mirrors Android.validDeviceId.
am_valid_id() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]
}

am_valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

am_valid_host() {
  local h=$1
  [ ${#h} -ge 1 ] && [ ${#h} -le 253 ] || return 1
  if [[ $h =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    local IFS=. part
    for part in $h; do [ "$part" -le 255 ] || return 1; done
    return 0
  fi
  [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

# "host:port" with both halves valid.
am_valid_address() {
  local a=$1
  [[ $a == *:* ]] || return 1
  am_valid_host "${a%:*}" && am_valid_port "${a##*:}"
}

# Run a command with a hard deadline and take its descendants with it.
#
# coreutils `timeout` runs the command in its own process group and, unless
# told --foreground, signals the whole group: adb forks, and a child left
# holding the pipe would keep the caller waiting. SIGTERM at the deadline,
# SIGKILL two seconds later if anything is still there. (This used to be a
# background `sleep` watcher, which outlived every helper by its full
# deadline: 6–8 s of a stray `sleep` per adb call.)
#
# stdin is /dev/null unless `am_input` is set, in which case it is fed that
# text: the one caller that needs it is `adb pair`, whose code must not go on
# argv where any process can read it out of /proc.
#
# Returns the command's status, or 124 when the deadline killed it.
am_run_bounded() {
  local secs=$1 rc; shift
  if [ -n "${am_input+x}" ]; then
    timeout --kill-after=2 "$secs" "$@" <<<"$am_input"
  else
    timeout --kill-after=2 "$secs" "$@" </dev/null
  fi
  rc=$?
  case $rc in
    124 | 137) return 124 ;;
  esac
  return "$rc"
}

am_adb() {
  local secs=$1; shift
  am_run_bounded "$secs" adb "$@"
}

# True when every existing component of an absolute path is an ordinary entry
# owned by this user or by root, and none of them is a symlink — so a read or
# write of our own state file cannot be redirected by swapping a directory on
# the way. Same check as the SSH manager's guard.
am_path_ok() {
  local path=$1 rest component prefix="" info kind owner

  case $path in
    /*) ;;
    *) am_reason="not an absolute path"; return 1 ;;
  esac

  rest=${path#/}
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$component" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
    [ -n "$component" ] || continue
    case $component in
      . | ..) am_reason="path is not canonical"; return 1 ;;
    esac
    prefix="$prefix/$component"
    info=$(stat -c '%F|%u' -- "$prefix" 2>/dev/null) || return 0
    kind=${info%%|*}
    owner=${info##*|}
    if [ "$kind" = "symbolic link" ]; then
      am_reason="$prefix is a symbolic link"; return 1
    fi
    if [ "$owner" != "$am_uid" ] && [ "$owner" != "0" ]; then
      am_reason="$prefix is owned by uid $owner"; return 1
    fi
  done
  return 0
}

# Where the remembered devices live. XDG_STATE_HOME only if it is an absolute
# path; anything else falls back to the spec's default.
am_state_dir() {
  local base=${XDG_STATE_HOME:-}
  case $base in
    /*) ;;
    *) base="$HOME/.local/state" ;;
  esac
  printf '%s/omarchy-android-manager' "$base"
}

# Make the state directory one level at a time, each level checked, never
# `mkdir -p` (which follows whatever a path points at right now).
am_ensure_state_dir() {
  local dir path="" rest component
  dir=$(am_state_dir)
  am_path_ok "$dir" || return 1
  rest=${dir#/}
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$component" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
    path="$path/$component"
    [ -d "$path" ] && continue
    mkdir -m 700 -- "$path" 2>/dev/null || { am_reason="cannot create $path"; return 1; }
    am_path_ok "$path" || return 1
  done
  return 0
}
