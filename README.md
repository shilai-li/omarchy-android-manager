# Omarchy Android Manager

Your Android phones in the bar: connect them over USB or Wi-Fi, and mirror
their screens with scrcpy — drawn live inside the panel, or in their own
window. For [Omarchy](https://omarchy.org).

```
Android  [Devices 3] [Mirrors 1]           adb 37.0.0 · scrcpy 5.0.1 · 1 mirroring
Filter devices…
──────────────────────────────────────────────────────────────────────────────
● Pixel 8 Pro                                                        Mirroring
  usb + wi-fi · 192.168.10.37:5555 · Android 16              1080p · 60 fps · 82%
● Galaxy Tab S9                                                          Ready
  wi-fi · 192.168.10.42:5555 · Android 15                                  64%
◐ R58N12ABCDE                                                     Unauthorized
  usb · model unknown until authorized                    tap Allow on the phone
──────────────────────────────────────────────────────────────────────────────
↑↓ move  enter mirror  → details  ^w wi-fi :5555  ^p pair  ^d disconnect  ^m mirrors
```

- **It runs the real tools.** adb for everything about the phone, scrcpy for
  the picture. Nothing about either is reimplemented here.
- **The panel mirror is scrcpy's own window.** It sits under a see-through
  hole in the panel, so the mouse, keyboard, clipboard and latency are
  exactly scrcpy's, the same as a detached window. No root, and nothing opens
  a video device, so your webcam stays off.
- **Nothing happens to a phone until you press something.** Opening the panel
  reads; connecting, pairing, mirroring, tapping and typing are all keys.
- **No Electron.** QML in the `omarchy-shell` process you are already running,
  themed by `omarchy theme set`.

## Install

```bash
omarchy plugin add https://github.com/shilai-li/omarchy-android-manager.git --enable
```

You need `android-tools` and `scrcpy` (`sudo pacman -S android-tools scrcpy`).

> Plugins run unsandboxed inside your shell. Read the code before you enable
> it.

## Using it

### Devices

| Key | |
|---|---|
| `enter` | Mirror the phone (inside the panel if fewer than three are there, else in a window); on a phone already mirroring, go to it; on a remembered phone, reconnect |
| `→` | Details: battery, screen, storage, and this phone's mirror options |
| `^w` | Move a USB phone to Wi-Fi: `adb tcpip 5555`, then `adb connect` |
| `^p` | Pair with a code (Android 11+ Wireless debugging) |
| `^o` | Connect to an address (`ip`, or `ip:port`; the port defaults to 5555) |
| `^d` | Disconnect the phone's Wi-Fi connection |
| `^s` | Screenshot into `~/Pictures/omarchy-android-manager` |
| `^t` | `adb shell` in your terminal |
| `^f` | Forget a remembered phone |
| `^m` | Mirrors |
| type | Filter |

A phone on USB and Wi-Fi at the same time is one row, driven over USB. Phones
you have connected before stay in the list after they are gone, with their
last Wi-Fi address; `enter` reconnects. `adb tcpip` lasts until the phone
reboots, so after a reboot plug it in once and press `^w` again.

### Details

`↑↓` picks a mirror option, `→` or `space` changes it (`shift+space`
backwards), and `←` goes back to the list.
Options are saved per phone: max size, bit rate, max fps, audio, stay awake,
screen off while mirroring, and recording to `~/Videos`. The exact `scrcpy`
command they make is shown underneath.

### Mirrors

Up to three phones live in the panel, each at its own screen's shape and as
tall as your screen allows. Each is the phone's real scrcpy window, so it
works exactly like a detached one. The buttons beside it are back, home,
recents, notifications, volume, power and a screenshot.

| Key | |
|---|---|
| `←→` | Pick a mirror |
| `^d` | Detach it into its own window, or attach it back. The same scrcpy keeps running, so sound, picture and a recording carry on |
| `^a` | Attach every mirror that is in a window |
| `enter` | Bring a mirror that is in its own window to the front |
| `^x` | Stop the mirror |
| `tab` | Back to Devices |
| `esc` | Hide the panel — mirrors keep running |

Click into a phone to use it: from then on the keyboard goes to the phone
too, until you click the panel again. While the panel is closed, or on
another tab, the windows wait out of sight on a hidden workspace
(`special:omarchy-android`), still running.

### Screen off and locked phones

With **Screen off** (on by default, per phone in Details) the phone's own
screen stays dark while it mirrors, and the plugin keeps the phone unlocked
so the mirror stays usable. A phone with a PIN, pattern or password can't
be unlocked from here, and some (ColorOS, for one) show their lock screen
black in a mirror, so its own screen is left on until you unlock it on the
phone; then it goes dark.

The plugin adds runtime Hyprland window rules, for its own scrcpy windows
only. It never edits your Hyprland config files.

### A phone drops its mirror when it locks or unlocks

Some phones (OnePlus with ColorOS, for one) switch USB file transfer on at
every unlock and off at every lock, and each switch restarts adb, Wi-Fi
connections included. Starting a mirror wakes the phone, so its first mirror
dies about two seconds in. The plugin mirrors it again once the phone is back,
but the fix is on the phone: Developer options › **Default USB configuration**
› **No data transfer** (charging only). File transfer then has to be picked
from the USB notification when you want it.

## IPC

```bash
omarchy-shell shilai_li.android-manager toggle   # open, close, show, hide, refresh
omarchy-shell shilai_li.android-manager status   # JSON: tools, mirrors, devices
```

## Files

It keeps one file: `~/.local/state/omarchy-android-manager/devices.json` —
the phones it has seen, their last Wi-Fi address, their mirror options, and
which were connected or mirroring, so they come back after a shell restart.
Screenshots go to `~/Pictures/omarchy-android-manager`, recordings (when
turned on) to `~/Videos`.

## Uninstall

```bash
omarchy plugin remove shilai_li.android-manager
rm -r ~/.local/state/omarchy-android-manager
```
