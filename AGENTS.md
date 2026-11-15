# AGENTS.md — omarchy-android-manager

Notes for anyone (agent or human) working in this repo: the decisions made
and the constraints that are not obvious from the code. User-facing docs go in
`README.md`, not here.

**Status.** Built: the device list, details with per-device mirror options,
Wi-Fi via USB on :5555, pairing codes, manual connect, screenshots, `adb
shell`, and mirrors both attached (the Mirrors tab) and in scrcpy windows,
with detach/attach. Nothing needs root. Verified with real phones (Android
13–16, USB and Wi-Fi): attached mirrors placed under their holes and showing
through, hidden when the panel closes or leaves the Mirrors tab, back when it
reopens; two phones attached at once; detach and re-attach; the screen kept
unlocked during a mirror, and a phone with a PIN left lit to unlock by hand.
**Not yet verified:** rotation, a second monitor, three phones at once, and
Wi-Fi :5555 and pairing end to end.

## What it is

**Omarchy Android Manager** (`shilai_li.android-manager`): a bar glyph that
opens the Android devices adb can see, connects them over USB or Wi-Fi, and
mirrors their screens with scrcpy. A mirror can be **attached** (drawn live
inside the panel) or **detached** (an ordinary scrcpy window), and moves
between the two on a key press. QML running inside the already-running
`omarchy-shell` Quickshell process. Two kinds: `service` and `bar-widget`.

Most plugins put their processes on `BarWidget.qml`; here **`Service.qml`
owns them**, on purpose, because a mirror must outlive the bar widget (see
*Layout*). The lessons from building other shell plugins this way are
summarised under *Shell rules* below.

The screens: device list, device details + mirror options, Wi-Fi via USB on
:5555, pairing code, bar icon and empty or error states, mirrors attached,
one mirror detached. The style, as in the shell's Studio Effects panel:
cards separated by space, facts as pills in the header, discs lit with the
accent only for what is on, segments for exclusive choices, switches for
on/off, key chips at the bottom. In the list a click
picks a phone and the two tiles under the list act on it (double click =
enter, right click = details); hover does not move the cursor, because the
pointer crosses other rows on its way down to the tiles.

## Non-negotiables

- **adb and scrcpy are the authority.** Device state comes from `adb devices
  -l` and `adb shell getprop`/`dumpsys`; mirroring is scrcpy. Nothing here
  speaks the adb wire protocol, pushes its own server to the phone, or decodes
  video itself.
- **Never touch a camera.** No `Camera`, `CaptureSession` or `MediaDevices`
  anywhere. QtMultimedia's camera side opens *every* video device on the
  machine to list them. A QML `Camera` also opens the default camera (the
  webcam) the moment it is constructed, before its `cameraDevice` binding
  applies. The user saw the webcam's light flash from exactly that. Attached
  mirrors are scrcpy's own window under a hole in the panel instead (see
  *Attached window* and *Earlier designs*).
- **No root, ever.** The plugin never runs `sudo` and needs nothing installed
  as root.
- **No gesture, no effect on the phone.** Opening the panel may run only
  read-only probes (`adb devices -l`, `getprop`, `dumpsys battery`, the Wi-Fi
  IP). `tcpip`, installs, screenshots, shell and the ◁ ○ □ buttons all need a
  key press or a click. Touch and typing reach the phone only through scrcpy's
  own window, when the user uses it.
- **Network and auto-reconnect.** `adb connect`, `adb pair` and mDNS
  discovery run on a key press or gesture during normal panel interaction.
  On shell restart (`omarchy-restart-shell`), previously connected status is
  preserved: phones that were connected over Wi-Fi (`connected: true` in the
  store) automatically reconnect back, and active mirrors (`mirror: "attached"`
  or `"window"`) automatically resume. Explicitly disconnecting a phone (`^d`)
  or stopping a mirror clears that state so it will not auto-connect.
- **Nothing runs without a ceiling.** Every adb call gets a deadline that kills
  its process group: `adb connect` to a host that has gone away can hang for a
  long time, and this runs inside a shell that stays up all session. Long-lived
  children (scrcpy, the persistent input shell) are tracked so a shell restart
  can find and stop them instead of leaking them.
- **Themed, never styled.** No hex literals and no raw pixel sizes, only
  `Commons.Color.*` and `Style.*`. The mockups' colors are placeholders for
  theme roles: accent = `Commons.Color.accent`, the warning/error hues =
  `urgent` and friends.
- **Minimal is the feature.** Devices, Wi-Fi connect, pairing, mirroring, and
  the few one-shot actions in the details screen (screenshot, install APK,
  shell). No file browser, logcat viewer, app manager or notification mirror.
  Ask before adding a surface.

## Decisions (2026-10-11)

| Decision | Why |
|---|---|
| Bar-widget plugin in `omarchy-shell`, not a standalone app | Matches the user's other plugins; keyboard-first panel |
| Wi-Fi is primarily `adb tcpip 5555` then `adb connect <ip>:5555`; pairing codes (Android 11+) and manual `ip:port` are secondary tabs | The user's real workflow |
| Port defaults to 5555 and is editable | Same |
| Attached mirrors = a borderless scrcpy window that Hyprland floats under a click-through hole in the panel | The user wants the panel mirror to behave exactly like a detached one. Two earlier designs drew the picture in the panel and could not give live input (see *Earlier designs*) |
| Each tile takes its phone's shape at the tallest height that fits | The user wants the mirror at the phone's proportions, not a fixed box |
| Input in both modes = scrcpy's own (mouse, keyboard, clipboard); only ◁ ○ □ under a tile go through `adb shell input keyevent` | It is scrcpy's window either way |
| 3 attached mirrors at most (the user owns three phones); a 4th opens detached | `Android.MAX_ATTACHED`, one place to change |
| Mirror options saved per device (max size, bit rate, fps, audio, stay awake, screen off, record) | Phones and tablets want different settings |
| Status is carried by shape as well as color (`● ◐ ○ ✕`) | Themes may map `urgent` to the accent's hue |

## Layout

```
manifest.json      kinds: service + bar-widget, keepLoaded
Service.qml        the only thing that runs anything: scans, Wi-Fi, pairing,
                   mirrors, screenshots, the remembered-device store
BarWidget.qml      finds the service, paints the icon, hosts the panel, IPC
Panel.qml          list / details / Wi-Fi (three tabs) / Mirrors; cursor, fields
MirrorTile.qml     one attached mirror's hole: reports where it is so the
                   service can put the scrcpy window under it
Android.js         pure: parse adb's answers, merge rows, build scrcpy argv
bin/guard.sh       sourced by all helpers: fixed PATH, deadlines, id checks
bin/scan.sh        adb devices -l + read-only getprops per phone
bin/wifi.sh        USB → adb tcpip <port> → adb connect, step by step
bin/connect.sh     adb connect / disconnect / pair (code on stdin) / mdns
bin/mirror.sh      checks scrcpy options against a whitelist, then execs scrcpy
bin/screenshot.sh  screencap into the user's Pictures/omarchy-android-manager
bin/store.sh       the remembered-device file, read and atomic write
bin/input.sh       one persistent `adb shell` per attached mirror, for the strip
bin/lockstate.sh   one persistent `adb shell` per screen-off mirror: lock/wake changes
test/              bash test/test.sh — node + the helpers, no phone needed
```

**Why a service.** A bar surface exists per monitor and is rebuilt on a
monitor change, a theme reload or a plugin update. A scrcpy owned by a widget
would die with it, and two monitors would each believe they owned the phones.
`Service.qml` is one instance, `keepLoaded`, found from the widget with
`bar.shell.serviceFor(moduleName)` (the scoped facade only hands a plugin its
own). Because it is kept loaded, **changes to `Service.qml` or `Android.js`
need `omarchy-restart-shell`**. In practice `Panel.qml` does too: on
2026-10-14 the shell logged "Local plugin changed, reloading" and kept
showing the old panel until a restart.

**What runs when.** `adb track-devices` for the service's lifetime: it only
listens, and any message triggers a scan (debounced). A scan also runs when
the panel opens and every 10 s while it is open. Nothing else runs without a
key press.

**The store** is `$XDG_STATE_HOME/omarchy-android-manager/devices.json`:
per phone, keyed by `ro.serialno`, its name, last Wi-Fi address and mirror
options. It is parsed as untrusted (`Android.parseStore`) and written only
through `bin/store.sh` (length-prefixed stdin, 0600, renamed into place).

## How it works

**Device identity.** A USB device's id is its serial; a Wi-Fi one's is
`ip:port`. The same phone on both shows twice in `adb devices`, so rows are
merged on `ro.serialno`, preferring the transport that is up.
`unauthorized` and `offline` are states with their own rows, never hidden.

**Wi-Fi on :5555.** With the phone on USB: read the IP (`adb -s S shell ip -f
inet addr show wlan0`), `adb -s S tcpip 5555`, wait for adbd to restart, `adb
connect IP:5555`. Show each step as it happens (the mockup's ✓ ● ○ list). tcpip
mode is lost when the phone reboots, so a remembered device that stays offline
gets "plug in once" rather than an endless retry.

**Pairing code.** `adb pair host:port`, with the code written to stdin at adb's
prompt and **not** passed on argv, because `/proc/<pid>/cmdline` is world-readable.
Discovery is `adb mdns services`.

**Attached window.** An attached mirror is a real scrcpy window:
`--window-borderless --window-title="Android · <name> · panel <slot>"`.

- **The rule.** An attached scrcpy runs with `SDL_APP_ID=omarchy-android-panel`
  (SDL3 reads it, and scrcpy has no flag for it), so its window's class is
  fixed from the first frame. The service installs a runtime window rule
  with `hyprctl eval` (`Android.PANEL_RULE_LUA`, kept in the Lua global
  `omarchy_android_panel_rule`; not a config edit) matching that class. It
  makes the window float with no border, rounding, shadow, blur, dim,
  animation or initial focus, on `special:omarchy-android silent`, i.e. out
  of sight. It also forces full opacity (`1.0 override 1.0 override`):
  Omarchy's Glassy window setting makes every window 0.75 (`.*` in
  `toggles/window-glassy.lua`, since Omarchy a2a2e19, 2026-11-08), which
  showed whatever sat behind the panel through the phone.
  - **A config reload drops runtime rules.** Omarchy reloads Hyprland for
    theme changes and more. Without the rule, a new window opened tiled in
    the middle of the screen and then jumped into the panel. So the rule is
    re-installed before every attached start (scrcpy starts when `hyprctl
    eval` returns) and on Hyprland's `configreloaded` event, and
    `hyprShow` sets floating itself as well.
  - **`focus_on_activate = false` in the rule.** SDL requests activation
    as it shows the window, and with the user's global `focus_on_activate`
    on, Hyprland focused it, which opened the special workspace and dimmed
    the screen (`dim_special` 0.6) for about half a second on every start.
    `no_initial_focus` does not cover activation. Measured by sampling
    `hyprctl monitors` every 30 ms: 16 samples with the special workspace open
    before, 0 after.
  - It is left in place on shell exit: switching it off then could race the
    next service's own rule. It matches nothing else.
- **Finding the window.** By its title, from Hyprland's `openwindow` and
  `windowtitlev2` events (`Android.parseWindowEvent`), and placed at once if
  the panel already wants it: re-attaching shows it in its hole about 0.7 s
  after the key, first frame placed. A 2 s poll of `Hyprland.toplevels` stays
  as the net for a missed event.
- **Showing it.** While a tile is shown it reports its rectangle in layout
  pixels (the item's position in the full-screen panel surface plus the
  monitor's x/y) and the monitor's active workspace, every 200 ms.
  `Service.showWindow` dispatches `Android.hyprShow`: float, resize, move,
  *then* move to that workspace, then pin. The order matters: each dispatch
  is its own request and Hyprland draws in between, so moving to the
  workspace first showed a new window for a moment where the rule had
  centred it (the user saw a flash in the middle when a phone connected with
  the panel open). It dispatches only when the rectangle changed. Hiding
  is unpin, then back to the special workspace. The *panel* hides the
  windows, when it closes or leaves the Mirrors tab, not the tile: the
  Mirrors row is keyed by phone through a string so tiles persist, but a
  tile's destruction still says nothing about the panel.
- **Hiding never depends on one code path.** A showing tile re-asks every
  200 ms, and the service hides any window nobody has asked for in 700 ms.
  The user hit a first-run case where the panel closed and the window stayed
  pinned on screen; this net covers every way a panel can go away (closed,
  other view, rebuilt, reloaded). The service also closes any
  plugin-titled window it does not own, e.g. one left by an earlier shell:
  once at startup, then on `openwindow` (a stray one is gone before
  `hyprctl clients` lists it). The 700 ms net only runs while a window is
  shown or wanted.
- **The hiding workspace must never be shown.** Hyprland opens a special
  workspace on a monitor when a window on it takes focus, and then the
  hidden phones sit in view over a blurred desktop: the user's "panel is
  closed but the phone is still there". The service closes
  `special:omarchy-android` with `toggle_special` (it acts on the focused
  monitor only) as soon as Hyprland's `activespecial` event says a monitor
  shows it, or once `focusedmon` says that monitor got focus. Measured: it
  is gone 2 ms after it opens. It used to poll `hyprctl monitors` every
  400 ms, for as long as any phone was attached, panel open or not. A
  5 s poll stays as a net, for a workspace already open at startup: it
  refreshes the list first and reads it 300 ms later, and skips a second
  toggle within a second, so a stale list cannot reopen it.
- **The hole.** Once the window is placed, the tile registers with
  `Panel.setHole`. The panel then:
  - cuts the tile out of `KeyboardPanel.mask` (a `Region` with `Subtract`
    children), so clicks reach the window and no longer dismiss the panel;
  - makes the card's own fill transparent and paints it itself (`cardFill`,
    an odd-even `Shape`) with the tiles left out, so the window shows
    through. The card is reached as `keys.parent.parent`, which is
    KeyboardPanel's `card`: shell internals, so check it after shell
    updates.
- **Keyboard.** The panel keeps it (it re-primes focus when holes open).
  Clicking into the window gives the keyboard to scrcpy, as with any
  window; clicking the panel takes it back.
- **The strip.** Beside each attached tile, a column of buttons
  (`Android.MIRROR_ACTIONS`): back, home, recents, notifications, volume ±,
  power and screenshot. All are `input keyevent` through `bin/input.sh`
  except the screenshot (`bin/screenshot.sh`, as ^s). None changes a phone
  setting. Its width is fixed, so `fitTileHeight` takes it out of the room
  before the tiles scale, and the card width includes it.
- **Known gap: rotation.** The tile's shape comes from the phone's reported
  screen, held upright. A rotated phone is letterboxed by scrcpy inside the
  same window.

**Starting.** One scrcpy per mirrored device, never two. A mirror started in
the panel is the panel window above, plus the device's options. One started
in its own window is `scrcpy -s S --window-title="Android · <name>"` with the
same options, under `SDL_APP_ID=omarchy-android-window`; a second runtime
rule in `PANEL_RULE_LUA` floats and centres that class (decided 2026-10-12:
tiled, the phone was letterboxed in a whole slot; floating, scrcpy sizes the
window to the phone's shape and keeps it on resize).

**Attach / detach keep the same scrcpy** (since 2026-11-14; before, each
switch restarted it, which cut sound and picture for about a second and
split a recording in two). On Hyprland scrcpy draws no frame of its own, so
everything that differs between the two looks is Hyprland's and can be
changed on the live window with `hl.dsp.window.set_prop`:
- *Detach* (`Android.hyprDetach`): the user's border and rounding (read
  with `hyprctl getoption` at start and on `configreloaded`), shadow, blur,
  animation and dim back on, while still out of sight; then unpinned, moved
  to the focused monitor's workspace and centred.
- *Attach* (`Android.hyprAttach`): all of that off again, `opaque` (an
  `opacity` override does not beat Omarchy's Glassy rule on a window opened
  under the detached rule; `opaque` does), floating, back to the hiding
  workspace; the panel then places it as usual.
- The props survive a config reload (checked with `hyprctl reload`).
- The title and app id stay what the window was opened with, so a window
  is known by its Hyprland address once found, and the service tracks the
  address of every mirror's window, not only attached ones. A mirror whose
  window was never found still falls back to a restart.
- The Mirrors view ignores auto-repeat on ^d / ^a / ^x: once, on a busy
  machine, a late key release repeated ^d and flipped the mirror back.

"Focus the window" on a window card (or enter on it) closes the panel and
dispatches focus and raise on that window (`Android.hyprFocus`). The plugin
never edits the user's Hyprland config files; the runtime rules and
per-window props above are its only changes to Hyprland.

**Resume after a drop.** scrcpy exits 2 when the device disconnects (0 when
its window is closed, 1 on an error). A mirror that ends with 2, not stopped by
the user, is started again the same way once the phone is back as ready (from
1.5 s, for up to 15 s). Three drops in 30 s and it stays stopped with an
error. Why: ColorOS (the OnePlus) restarts adbd on every lock and unlock to
switch USB file transfer, which cuts Wi-Fi adb too, and scrcpy wakes a
sleeping phone on start, so the first mirror of a sleeping OnePlus died about
2 s in, at the unlock (seen in its logcat: `UsbFunc … forceRestart: true`
then "application token died"). Not yet measured: that exit code on a real
drop.

**Screen off, and keeping the screen unlocked.** With the screen-off option
(default: on), mirroring keeps the screen awake (`--stay-awake`) while keeping
the physical screen off (`--turn-screen-off`). On start, the service runs
`bin/unlock.sh` once so the mirrored session starts unlocked. It asks the
phone first and sends only what applies: `KEYCODE_WAKEUP` to an asleep
phone, `wm dismiss-keyguard` to a showing keyguard, and `KEYCODE_MENU` only
if the keyguard is still up after that. (Until 2026-11-14 `bin/mirror.sh`
sent all three blindly as well, so an unlocked phone got a Menu press in
whatever app was open.) During the mirror, `bin/lockstate.sh` keeps one
`adb shell` open whose loop on the phone checks once a second and prints only
when the state changes (it used to be a new adb connection and nine host
processes every second); if the device locks or sleeps, `unlockPhone` dismisses keyguard to
keep the screen unlocked without powering on the physical screen. If the
physical screen wakes, `MOD+o` (`Android.screenKeys`) turns it off again.

**Hiding the panel does not stop mirrors.** The windows wait on the special
workspace. The bar glyph never changes shape: dimmed when idle, the accent
while anything mirrors, `urgent` when something needs the user; the tooltip
names the phones in the panel and in windows.

## Earlier designs (2026-10-11)

Two designs drew the phone's picture inside the panel itself. Both are gone.
Neither could give live input: scrcpy reads input only from its own window,
`--no-window` has none, the shell user cannot write to the touchscreen's
`/dev/input` node (SELinux), and `input motionevent` costs about 41 ms per
event on this phone. The user asked for the panel mirror to behave like the
detached one, hence the window under a hole.

### The pipe player

scrcpy `--no-window --record=<fifo> --record-format=mkv`, played by a QML
`MediaPlayer` that lived on the service, with its `VideoOutput` reparented
into the tile. What it took to work:

- **An idle phone sends about eleven frames, then nothing.** Android repeats
  the last frame ten times, 100 ms apart.
  - With the default playback intent, the player waited to buffer more than
    that and never showed a frame.
  - `LowLatencyStreaming` shows frames as they arrive but drops the first
    few and restarts only at a keyframe. It needed
    `--video-codec-options=i-frame-interval:float=0.05`.
- **Latency.**
  - At `playbackRate` 1.0 the player kept its startup backlog for good:
    410 ms median from pipe to screen. 2.0 drained it, giving 35–60 ms.
  - scrcpy's recorder writes a frame only once the next one exists. So
    `repeat-previous-frame-after:long=33333` was needed to show a settled
    screen in about 70 ms.
- **The pipe.**
  - It had to be held open read-write on scrcpy's side, so opening it never
    blocked.
  - Switching the player's output made it seek, which a pipe cannot do.
  - A scrcpy blocked on a full pipe ignored SIGTERM, so it needed SIGKILL.

Taps were sent on release, drags as one swipe, and typing as `input text`
(ASCII only). The picture was fine; the control was not.

### v4l2loopback slots read as cameras

The first attached design had scrcpy write into three v4l2loopback devices
("Android Mirror 1–3", made by a root systemd unit), and the tile read them
with a QML `Camera`. A spike outside the shell passed: 60 fps, re-takes, and
three readers at about 10% of a core each. In the shell, with a real phone, it
failed twice over:

- **The webcam light flashed.** A QML `Camera` is constructed with the
  default camera (the USB webcam here) and opens it before its `cameraDevice`
  binding applies. `MediaDevices` opens every `/dev/video*` to list them.
  Measured with `inotifywait -e open` on the device nodes.
- **No picture.** A slot allowed two openers: scrcpy and one reader. The
  listing took the second, and the tile's `Camera` then failed with "Device
  or resource busy".

A `MediaPlayer` reading a pipe opened no video device: zero
`qt.multimedia.ffmpeg.v4l2cameradevices` log lines, where `MediaDevices` logs
every camera it finds. Qt's ffmpeg plugin here has no libavdevice, so a
player cannot read a loopback device directly anyway.

**Other software may open `/dev/video*` too,** even with no mirror running
(on the development machine something did, several times a second, and it
was not this plugin). Check `inotifywait -m -e open /dev/video*` before
blaming this plugin for a webcam light.

## Ground truth: read it, don't guess

| What | Path |
|---|---|
| Shell source / UI kit / theme singletons | `/usr/share/omarchy/shell/{,Ui/,Commons/}` |
| Plugin contract, manifests, IPC | `docs/omarchy-shell.md` in the Omarchy repository |
| Bar host and the `bar` facade | `/usr/share/omarchy/shell/plugins/bar/Bar.qml`, `shell/Ui/PluginBarApi.qml` |
| List/cursor idiom | `/usr/share/omarchy/shell/plugins/panels/bluetooth/Panel.qml` |
| scrcpy flags | `scrcpy --help` (5.0.1 here); `--no-window`, `--record`, `--record-format`, `--window-title` |
| adb | `adb help` (android-tools 37) |

## Shell rules

- `import qs.Commons as Commons` beside `import qs.Commons`. Qt ships its own
  `Color`, so a bare `Color.accent` is silently undefined.
- `Style.space(n)`, `Style.font.*`, `Style.cornerRadius` (may be `0`). No raw
  pixels.
- `bar` is a `PluginBarApi` facade: shared state is readonly with a `setX()`
  beside it. Feature-test with `typeof bar.setX === "function"`, never `"x"
  in bar`.
- `close()` hides first, then does everything else. Anything that throws
  before the hide strands a full-screen surface that eats every key.
- Keys are routed by hand (`handleKey` returning `false` for what it does not
  claim), not `PanelKeyCatcher`. Its `h j k l x` would make the filter
  untypable.
- All state, processes and players live on `Service.qml`; the widget and the
  panel are read-outs that call back into it, because there is one of each
  per monitor.
- `.js` helpers stay Qt- and locale-free so they test under plain `node`;
  `.sh` helpers are the only things that touch adb, scrcpy or the filesystem,
  run through `/usr/bin/bash` with a fixed PATH, take arguments positionally,
  and never `eval`. A device name is user data.

## Dev workflow

```bash
bash test/test.sh                                   # node + helpers, no phone needed
rsync -a --delete --exclude .git ./ ~/.config/omarchy/plugins/shilai_li.android-manager/   # a copy: the validator rejects symlinks
omarchy plugin validate ~/.config/omarchy/plugins/shilai_li.android-manager
omarchy-restart-shell                               # after any change to Service.qml or Android.js
omarchy-shell shilai_li.android-manager status      # JSON smoke test
QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell Panel.qml
adb devices -l
```

The shell notices changes in the plugins directory and reloads the plugin,
but that has not been enough to pick up a new `Panel.qml` (the loaded panel
keeps the old one). Restart the shell after any change and confirm on screen,
e.g. that the key hints changed.
qmllint's `[import]`/`[unqualified]`/… cascade outside Quickshell is noise.
Compare categories against a built-in, not counts. Shell errors go to the
`omarchy-shell` journal.

On-device behaviour (does `tcpip` survive a reboot, what the unauthorized
prompt looks like, how a phone's lock screen behaves) needs a real phone:
`adb shell dumpsys window | grep isKeyguardShowing`, `dumpsys power | grep
mWakefulness` and `adb exec-out screencap -p` cover most of it.

## Rules for agents

1. Read the real file before writing: the shell's own panels, the sibling
   plugin, `scrcpy --help`.
2. No new dependencies beyond QML, Quickshell (with its Hyprland module),
   the shell's singletons, Hyprland's `hyprctl`, android-tools and scrcpy.
   Nothing imports QtMultimedia any more.
3. The plugin never runs `sudo`. It writes nothing outside its state file
   under `$XDG_STATE_HOME`, and touches Hyprland only through the runtime
   rule and dispatches described under *Attached window*.
4. Never open, list or reload video devices. A v4l2loopback module may be
   shared with other camera software on the user's machine.
5. Before declaring a feature done: `omarchy plugin validate` clean; the panel
   opens with no device, an unauthorized device, and adb or scrcpy missing;
   attaching a mirror opens no `/dev/video*` (watch with `inotifywait`); and
   unplugging a phone mid-mirror leaves the shell responsive.

## Decisions on reconnection

- When Omarchy shell restarts, phones with `connected: true` in the store
  reconnect to adb over Wi-Fi automatically, and active screen mirrors
  (`attached` or `window`) resume.
- Phones explicitly disconnected with `^d` or `disconnect()` have `connected`
  set to `false` and will not reconnect on restart until selected again.
