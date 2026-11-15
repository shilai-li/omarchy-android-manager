import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Android.js" as Android

// The headless half of the Android manager, and the only place that runs
// anything.
//
// It is a `service` rather than part of the bar widget because a mirror has
// to outlive the widget. A bar surface exists per monitor and is torn down and
// rebuilt on a monitor change, a theme reload or a plugin update; a scrcpy
// owned by one of those would die with it, and two monitors would each think
// they owned the phones. There is one service, `keepLoaded`, and every widget
// and panel is a read-out of it that calls back into it.
//
// What runs, and when:
//
//   - `adb track-devices` for as long as the service lives. It only listens:
//     adb pushes a line when a phone appears, leaves or changes state, and
//     that line is what triggers a scan. Nothing polls the phones while the
//     panel is closed.
//   - bin/scan.sh on that trigger and when the panel opens: `adb devices -l`
//     plus read-only getprops on each authorized phone.
//   - everything else — Wi-Fi, pairing, connecting, mirroring, screenshots —
//     only because the user pressed something.
//
// Every helper is one of this plugin's scripts, started through an absolute
// /usr/bin/bash with a fixed PATH, with a deadline on this side as well as in
// the script.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "shilai_li.android-manager"
  readonly property string home: Quickshell.env("HOME")

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    if (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.slice(0, -1)
    return decodeURIComponent(url)
  }

  readonly property string shellBin: "/usr/bin/bash"
  readonly property var trustedEnv: ({ "PATH": "/usr/bin:/bin" })
  readonly property var panelEnv: ({ "PATH": "/usr/bin:/bin", "SDL_APP_ID": Android.PANEL_APP_ID })
  readonly property var windowEnv: ({ "PATH": "/usr/bin:/bin", "SDL_APP_ID": Android.WINDOW_APP_ID })

  function script(name) { return [root.shellBin, root.pluginDir + "/bin/" + name] }

  // ---- What adb said, and what we remember.
  property var scan: Android.parseScan("")
  property bool scanned: false
  property bool rescanWanted: false
  property double lastScanAt: 0
  property var store: ({})
  property bool storeLoaded: false

  // key → { mode, target, proc, stopping, error }. Reassigned whole on every
  // change, because QML only notices a property being set, not a nested edit.
  property var mirrors: ({})

  readonly property var mirrorStates: {
    var out = ({})
    for (var key in root.mirrors) out[key] = { mode: root.mirrors[key].mode }
    return out
  }

  readonly property var rows: Android.buildRows(root.scan, root.store, root.mirrorStates)
  // adb's and scrcpy's versions, or "missing", as last read. A scan reads the
  // versions only when asked (first scan, ^r, a tool missing): they cost
  // most of a scan's time and do not change.
  property var tools: ({ adb: "", scrcpy: "" })
  property bool versionsWanted: true
  readonly property bool adbMissing: root.scanned && root.tools.adb === "missing"
  readonly property bool scrcpyMissing: root.scanned && root.tools.scrcpy === "missing"
  readonly property bool scanning: scanProc.running

  readonly property int mirrorCount: Object.keys(root.mirrors).length
  readonly property int readyCount: {
    var n = 0
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].state === Android.STATE_READY || root.rows[i].state === Android.STATE_MIRRORING) n++
    return n
  }
  readonly property int waitingCount: {
    var n = 0
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].state === Android.STATE_UNAUTHORIZED) n++
    return n
  }

  // What the bar icon shows: broken > needs you > mirroring > connected > none.
  readonly property string barState: {
    if (root.adbMissing) return "broken"
    if (root.waitingCount > 0) return "attention"
    if (root.mirrorCount > 0) return "mirroring"
    if (root.readyCount > 0) return "connected"
    return "idle"
  }

  // One line of the most recent thing that went wrong, and one line of the
  // most recent thing that went right and is worth saying (a saved
  // screenshot). The panel shows whichever is set.
  property string errorText: ""
  property string noticeText: ""

  function setError(text) { root.errorText = Android.plainLabel(text, 200); root.noticeText = "" }
  function setNotice(text) { root.noticeText = Android.plainLabel(text, 200); root.errorText = "" }
  function clearMessages() { root.errorText = ""; root.noticeText = "" }

  function rowByKey(key) {
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].key === key) return root.rows[i]
    return null
  }

  function usbTarget(row) {
    if (!row) return ""
    for (var i = 0; i < row.transports.length; i++) {
      var t = row.transports[i]
      if (t.kind === "usb" && t.state === "device") return t.id
    }
    return ""
  }

  // ---- Scanning.
  // `versions` asks adb and scrcpy for their versions again (^r, IPC).
  function refresh(versions) {
    if (versions === true) root.versionsWanted = true
    if (scanProc.running) { root.rescanWanted = true; return }
    var ask = root.versionsWanted || root.tools.adb === "missing" || root.tools.scrcpy === "missing"
    root.versionsWanted = false
    scanProc.command = root.script("scan.sh").concat(ask ? ["versions"] : [])
    scanProc.running = true
  }

  function applyScan(text) {
    root.scan = Android.parseScan(text)
    root.scanned = true
    root.lastScanAt = Date.now()
    // A scan without versions reports a tool only when it is missing.
    var t = root.scan.tools
    if ((t.adb !== "" && t.adb !== root.tools.adb) || (t.scrcpy !== "" && t.scrcpy !== root.tools.scrcpy))
      root.tools = { adb: t.adb !== "" ? t.adb : root.tools.adb, scrcpy: t.scrcpy !== "" ? t.scrcpy : root.tools.scrcpy }
    if (root.scan.errors.length > 0) root.setError(root.scan.errors[0])
    root.rememberSeen()
    if (!root.autoRestored && root.storeLoaded) {
      root.autoRestored = true
      root.triggerAutoRestore()
    }
    if (root.rescanWanted) {
      root.rescanWanted = false
      Qt.callLater(root.refresh)
    }
  }

  // An authorized phone is remembered by its serial: its name, so it can be
  // shown when it is not connected, and its Wi-Fi address once it has one, so
  // it can be reconnected after a reboot without retyping it. Written only
  // when something actually changed.
  function rememberSeen() {
    if (!root.storeLoaded) return
    var next = root.store
    var changed = false
    for (var i = 0; i < root.rows.length; i++) {
      var row = root.rows[i]
      if (!row.info || !row.info.serialno || row.info.serialno !== row.key) continue
      var prev = next[row.key]
      var name = row.info.model || ""
      var address = row.address || (prev ? prev.address : "")
      var isConnected = (row.state === Android.STATE_READY || row.state === Android.STATE_MIRRORING)
      var conn = (prev && prev.connected) || isConnected
      if (prev && prev.name === name && prev.address === address && prev.connected === conn) continue
      next = Android.rememberDevice(next, row.key, { name: name, address: address, connected: conn })
      changed = true
    }
    if (changed) root.saveStore(next)
  }

  // ---- The store.
  property string pendingStore: ""

  function saveStore(next) {
    root.store = next
    if (storeWriteProc.running) {
      // Coalesce: the write in flight is followed by one more with the
      // latest state, never a queue of stale ones.
      root.pendingStore = Android.serializeStore(next)
      return
    }
    storeWriteProc.payload = Android.serializeStore(next)
    storeWriteProc.running = true
  }

  function setOptions(key, options) {
    root.saveStore(Android.rememberDevice(root.store, key, { options: options }))
  }

  function forget(key) {
    root.saveStore(Android.forgetDevice(root.store, key))
  }

  // ---- Wi-Fi on a port (5555 unless the user changes it).
  property string wifiKey: ""
  property string wifiOutput: ""
  readonly property bool wifiRunning: wifiProc.running
  readonly property var wifiSteps: Android.parseWifi(root.wifiOutput)

  function startWifi(key, port, ip) {
    var row = root.rowByKey(key)
    var target = root.usbTarget(row)
    if (target === "") { root.setError("Plug the phone in over USB first"); return false }
    if (!Android.validPort(port)) { root.setError("Not a port: " + port); return false }
    if (ip !== "" && !Android.validHost(ip)) { root.setError("Not an address: " + ip); return false }
    if (wifiProc.running) return false
    root.clearMessages()
    root.wifiKey = key
    root.wifiOutput = ""
    wifiProc.command = root.script("wifi.sh").concat(ip === "" ? [target, String(port)] : [target, String(port), ip])
    wifiProc.running = true
    return true
  }

  function finishWifi() {
    var steps = root.wifiSteps
    var last = steps[3]
    if (last.status === "ok") {
      var row = root.rowByKey(root.wifiKey)
      root.saveStore(Android.rememberDevice(root.store, root.wifiKey, {
        name: row ? row.name : "", address: last.detail, connected: true
      }))
      root.setNotice("Connected over Wi-Fi at " + last.detail + " — you can unplug it")
    } else {
      for (var i = 0; i < steps.length; i++) {
        if (steps[i].status === "fail") { root.setError(steps[i].label + ": " + steps[i].detail); break }
      }
    }
    root.refresh()
  }

  // ---- adb connect / disconnect / pair / mdns.
  property string netVerb: ""
  property string netTarget: ""
  property string pairCode: ""
  property var lastNet: null
  readonly property bool netRunning: netProc.running
  property var discovered: []
  readonly property bool discovering: mdnsProc.running

  function markAddressConnected(target, isConn) {
    if (!root.storeLoaded) return
    var next = root.store
    var changed = false
    for (var k in next) {
      if (next[k] && next[k].address === target) {
        if (next[k].connected !== isConn) {
          next = Android.rememberDevice(next, k, { connected: isConn })
          changed = true
        }
      }
    }
    if (changed) root.saveStore(next)
  }

  function runNet(verb, address, code) {
    if (netProc.running) return false
    var addr = Android.parseAddress(address)
    if (!addr) { root.setError("Not an address: " + address); return false }
    root.clearMessages()
    root.netVerb = verb
    root.netTarget = addr.text
    root.pairCode = code || ""
    root.lastNet = null
    netProc.command = root.script("connect.sh").concat([verb, addr.text])
    netProc.running = true
    return true
  }

  function connectAddress(address) { return root.runNet("connect", address, "") }
  function pairAddress(address, code) { return root.runNet("pair", address, code) }

  function disconnect(key) {
    var row = root.rowByKey(key)
    if (!row) return false
    root.saveStore(Android.rememberDevice(root.store, key, { connected: false, mirror: "" }))
    for (var i = 0; i < row.transports.length; i++) {
      var t = row.transports[i]
      if (t.kind === "wifi" && Android.parseAddress(t.id, null)) return root.runNet("disconnect", t.id, "")
    }
    root.setError(row.name + " is not connected over Wi-Fi")
    return false
  }

  // A remembered phone's last address, or the address the user typed.
  function reconnect(key) {
    var row = root.rowByKey(key)
    if (!row || !row.address) { root.setError("No Wi-Fi address remembered for this phone"); return false }
    return root.connectAddress(row.address)
  }

  function finishNet(output) {
    var verb = root.netVerb
    root.pairCode = ""
    // A refusal from the helper itself ("E the pairing code is…") reads the
    // same as adb's own failure text once the record marker is off.
    var text = String(output).replace(/^E /, "")
    if (verb === "connect") {
      var c = Android.parseConnect(text)
      root.lastNet = { verb: verb, ok: c.ok, message: c.message }
      if (c.ok) {
        root.setNotice(c.message)
        root.markAddressConnected(root.netTarget, true)
      } else {
        root.setError(c.message)
      }
    } else if (verb === "disconnect") {
      root.markAddressConnected(root.netTarget, false)
      root.lastNet = { verb: verb, ok: true, message: Android.plainLabel(text, 160) }
    } else if (verb === "pair") {
      var p = Android.parsePair(text)
      root.lastNet = { verb: verb, ok: p.ok, message: p.message }
      if (p.ok) root.setNotice(p.message + " — now connect to the address under “IP address & Port”")
      else root.setError(p.message)
    } else {
      root.lastNet = { verb: verb, ok: true, message: Android.plainLabel(text, 160) }
    }
    root.refresh()

    if (root.autoConnectQueue && root.autoConnectQueue.length > 0) {
      var nextAddr = root.autoConnectQueue[0]
      root.autoConnectQueue = root.autoConnectQueue.slice(1)
      Qt.callLater(function() {
        if (!root.connectAddress(nextAddr) && root.autoConnectQueue.length > 0) {
          var again = root.autoConnectQueue[0]
          root.autoConnectQueue = root.autoConnectQueue.slice(1)
          root.connectAddress(again)
        }
      })
    }
  }

  function discover() {
    if (!mdnsProc.running) mdnsProc.running = true
  }

  // ---- Mirrors. One scrcpy per phone, never two.
  //
  // Every mirror is a real scrcpy window, with scrcpy's own mouse, keyboard,
  // clipboard and latency. A "window" mirror is an ordinary one. An
  // "attached" one is borderless and titled for its panel slot: the Hyprland
  // rule set up here floats it, undecorated, on a special workspace out of
  // sight, and while the panel shows its tile, the panel asks for it to be
  // moved exactly under a hole in the panel (showWindow), and back out of
  // sight when it hides (hideWindow). Switching between the two keeps the
  // same scrcpy: its window is re-decorated and moved (switchMirror), so
  // sound and picture never stop. The title and app id stay what the window
  // was opened with, so once found a window is known by its address.
  //
  // Up to Android.MAX_ATTACHED are attached at once, each holding a slot
  // number that is in its title; past that, mirrors open in a window.
  readonly property int maxAttached: Android.MAX_ATTACHED
  property bool panelRuleReady: false
  property string panelRuleError: ""

  readonly property int attachedCount: {
    var n = 0
    for (var key in root.mirrors) if (root.mirrors[key].mode === "attached") n++
    return n
  }

  function mirrorFor(key) { return root.mirrors[key] || null }

  function setMirrors(next) { root.mirrors = next }

  function updateMirror(key, fields) {
    if (!root.mirrors[key]) return
    var next = ({})
    for (var k in root.mirrors) next[k] = root.mirrors[k]
    var m = ({})
    for (var f in root.mirrors[key]) m[f] = root.mirrors[key][f]
    for (var g in fields) m[g] = fields[g]
    next[key] = m
    root.setMirrors(next)
  }

  function slotInUse(n) {
    for (var key in root.mirrors) if (root.mirrors[key].slot === n) return true
    return false
  }

  function freeSlot() {
    for (var n = 1; n <= root.maxAttached; n++) if (!root.slotInUse(n)) return n
    return 0
  }

  // Why this phone cannot be attached right now, or "" when it can.
  function attachRefusal(row) {
    if (!root.panelRuleReady) return "Hyprland did not take the window rule" + (root.panelRuleError !== "" ? " (" + root.panelRuleError + ")" : "")
    if (!root.freeSlot()) return "All " + root.maxAttached + " panel mirrors are in use"
    return ""
  }

  // `mode` is "attached", "window", or empty for "attached if it can be".
  // When it cannot, it opens a window rather than refusing: the phone still
  // gets mirrored.
  function startMirror(key, mode) {
    root.cancelResume(key)
    var row = root.rowByKey(key)
    if (!row || row.target === "") { root.setError("That phone is not connected"); return false }
    if (root.scrcpyMissing) { root.setError("scrcpy is not installed"); return false }
    if (root.mirrors[key]) return true

    var slot = 0
    var want = mode || "attached"
    var notice = ""
    if (want === "attached") {
      var refusal = root.attachRefusal(row)
      if (refusal !== "") {
        want = "window"
        notice = refusal + " — opened in a window"
      } else {
        slot = root.freeSlot()
      }
    }

    var extra = { title: row.name, slot: slot }
    if (row.options.record) extra.recordPath = root.home + "/Videos/android-" + Android.titleSafe(row.name).replace(/ /g, "-")
      + "-" + Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss") + ".mp4"
    var args = Android.scrcpyArgs(row.options, want, extra)

    var proc = mirrorComponent.createObject(root, {
      key: key,
      environment: want === "attached" ? root.panelEnv : root.windowEnv,
      command: root.script("mirror.sh").concat([row.target], args)
    })
    if (!proc) { root.setError("Could not start scrcpy"); return false }

    var next = ({})
    for (var k in root.mirrors) next[k] = root.mirrors[k]
    next[key] = {
      mode: want, target: row.target, proc: proc, slot: slot,
      title: slot ? Android.panelTitle(row.name, slot) : "Android · " + Android.titleSafe(row.name),
      address: "", wanted: null, shown: null,
      screenOff: !!row.options.screenOff, lockState: ""
    }
    root.setMirrors(next)
    root.saveStore(Android.rememberDevice(root.store, key, { connected: true, mirror: want }))
    if (notice !== "") root.setNotice(notice)
    else root.clearMessages()
    // scrcpy starts only once the rules are (re)installed: a config reload may
    // have dropped them, and a window that maps without its rule opens tiled
    // in the middle of the screen.
    //
    // Then the phone is woken and its keyguard dismissed (bin/unlock.sh, only
    // what is needed). If it is still locked, a PIN only the user can enter,
    // scrcpy starts without --turn-screen-off so the user can unlock it on the
    // phone; the lock watcher turns the screen off once it is unlocked.
    root.withPanelRule(function() {
      if (proc.stopping) { root.mirrorExited(proc, 0); return }
      root.unlockPhone(row.target, function(result) {
        if (proc.stopping) { root.mirrorExited(proc, 0); return }
        if (result.locked && row.options.screenOff) {
          extra.deferScreenOff = true
          proc.command = root.script("mirror.sh").concat([row.target], Android.scrcpyArgs(row.options, want, extra))
        }
        proc.running = true
      })
    })
    return true
  }

  // bin/unlock.sh; `then`, if given, gets Android.parseUnlock's answer.
  function unlockPhone(target, then) {
    var done = then || function() {}
    if (!target) { done(Android.parseUnlock("")); return }
    var p = unlockComponent.createObject(root, { command: root.script("unlock.sh").concat([target]) })
    if (!p) { done(Android.parseUnlock("")); return }
    p.done = done
    p.running = true
  }

  Component {
    id: unlockComponent
    Process {
      id: unlockProc
      property var done: null
      environment: root.trustedEnv
      stdout: StdioCollector { id: unlockOut; waitForEnd: true }
      onExited: function(code) {
        var cb = unlockProc.done
        unlockProc.done = null
        if (cb) cb(Android.parseUnlock(unlockOut.text))
        unlockProc.destroy()
      }
    }
  }

  // ---- Keeping the phone unlocked, its own screen dark.
  //
  // For as long as a mirror with the screen-off option runs, bin/lockstate.sh
  // keeps one `adb shell` open on its phone, and the loop there prints a line
  // only when the lock or wake state changes: no adb connection or helper per
  // check. Started once the mirror's window is found (screenKeys needs its
  // address), stopped with the mirror.
  readonly property bool anyScreenOff: {
    for (var key in root.mirrors) if (root.mirrors[key].screenOff) return true
    return false
  }

  // key → its lockstate.sh Process.
  property var lockWatchers: ({})

  function startLockWatch(key) {
    var m = root.mirrors[key]
    if (!m || !m.screenOff || m.address === "" || root.lockWatchers[key]) return
    var p = lockComponent.createObject(root, {
      key: key, mirrorProc: m.proc, command: root.script("lockstate.sh").concat([m.target])
    })
    if (!p) return
    var next = ({})
    for (var k in root.lockWatchers) next[k] = root.lockWatchers[k]
    next[key] = p
    root.lockWatchers = next
    p.running = true
  }

  function stopLockWatch(key) {
    var p = root.lockWatchers[key]
    if (!p) return
    var next = ({})
    for (var k in root.lockWatchers) if (k !== key) next[k] = root.lockWatchers[k]
    root.lockWatchers = next
    p.running = false
  }

  function lockChanged(key, proc, state) {
    var m = root.mirrors[key]
    if (!m || m.proc !== proc || state.locked === null || state.awake === null) return
    var now = !state.awake ? "asleep" : (state.locked ? "locked" : "unlocked")
    if (now === m.lockState) return
    if (now === "locked" || now === "asleep") {
      // Still locked after this means a PIN or pattern: turn the phone's own
      // screen on so it can be unlocked there, since some lock screens show
      // black in the mirror.
      root.unlockPhone(m.target, function(result) {
        var cur = root.mirrors[key]
        if (result.locked && cur && cur.proc === proc) root.dispatchAll(Android.screenKeys(cur.address, true))
      })
    } else if (now === "unlocked") {
      root.dispatchAll(Android.screenKeys(m.address, false))
    }
    root.updateMirror(key, { lockState: now })
  }

  Component {
    id: lockComponent
    Process {
      id: lockProc
      property string key: ""
      property var mirrorProc: null
      environment: root.trustedEnv
      stdout: SplitParser {
        onRead: function(line) { root.lockChanged(lockProc.key, lockProc.mirrorProc, Android.parseLockState(line)) }
      }
      onExited: {
        if (root.lockWatchers[lockProc.key] === lockProc) {
          var next = ({})
          for (var k in root.lockWatchers) if (k !== lockProc.key) next[k] = root.lockWatchers[k]
          root.lockWatchers = next
        }
        lockProc.destroy()
      }
    }
  }

  // A watcher that ended on its own (adb restarted, the Wi-Fi link blinked)
  // while its mirror still runs is started again. Its first line repeats the
  // state, which changes nothing unless the state did.
  Timer {
    interval: 5000
    repeat: true
    running: root.anyScreenOff
    onTriggered: { for (var key in root.mirrors) root.startLockWatch(key) }
  }

  property var ruleWaiters: []

  function withPanelRule(then) {
    root.ruleWaiters = root.ruleWaiters.concat([then])
    if (!panelRuleProc.running) panelRuleProc.running = true
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") { root.withPanelRule(function() {}); decoProc.running = true }
      else if (event.name === "activespecial") root.noteSpecial(event.data)
      else if (event.name === "focusedmon") root.noteFocusedMonitor(event.data)
      else {
        var w = Android.parseWindowEvent(event.name, event.data)
        if (w) root.noteWindow(w.address, w.title)
      }
    }
  }

  function stopMirror(key) {
    root.cancelResume(key)
    root.saveStore(Android.rememberDevice(root.store, key, { mirror: "" }))
    var m = root.mirrors[key]
    if (!m) return
    m.proc.restartAs = ""
    root.terminate(m.proc)
  }

  // SIGTERM, and SIGKILL if scrcpy is still there a few seconds later.
  function terminate(proc) {
    proc.stopping = true
    proc.stopAt = Date.now()
    proc.signal(15)
    if (!killTimer.running) killTimer.start()
  }

  // One shot, from terminate(): SIGKILL whatever has had its 3 s, and come
  // back for any stop that has not.
  Timer {
    id: killTimer
    interval: 3100
    onTriggered: {
      var waiting = false
      for (var key in root.mirrors) {
        var p = root.mirrors[key].proc
        if (!p.stopping || p.stopAt <= 0) continue
        if (Date.now() - p.stopAt >= 3000) p.signal(9)
        else waiting = true
      }
      if (waiting) killTimer.start()
    }
  }

  function toggleMirror(key) {
    if (root.mirrors[key]) root.stopMirror(key)
    else root.startMirror(key, "")
  }

  function switchMirror(key, mode) {
    var m = root.mirrors[key]
    if (!m || m.mode === mode) return false
    if (mode === "attached") {
      var refusal = root.attachRefusal(root.rowByKey(key))
      if (refusal !== "") { root.setError(refusal); return false }
    }
    root.saveStore(Android.rememberDevice(root.store, key, { mirror: mode }))

    // The same scrcpy, its window moved and re-decorated: no gap in sound or
    // picture, and a recording stays one file. The title keeps whatever it
    // was opened with, so from here on the window is known by its address.
    if (m.address !== "") {
      // A detached window keeps the size it had in the panel's tile.
      var list = []
      if (mode === "window") {
        var mon = Hyprland.focusedMonitor
        list = Android.hyprDetach(m.address, mon && mon.activeWorkspace ? mon.activeWorkspace.id : 0, root.deco)
      } else {
        list = Android.hyprAttach(m.address)
      }
      if (list.length > 0) {
        root.dispatchAll(list)
        root.updateMirror(key, { mode: mode, slot: mode === "attached" ? root.freeSlot() : 0, wanted: null, shown: null })
        return true
      }
    }

    // Its window was never found: start it again in the other mode.
    m.proc.restartAs = mode
    root.terminate(m.proc)
    return true
  }

  // The user's border and rounding, for a mirror moved to its own window.
  // Read at start and after every config reload (a theme change).
  property var deco: ({ border: 2, rounding: 0 })

  Process {
    id: decoProc
    command: ["/usr/bin/hyprctl", "-j", "--batch", "getoption general:border_size; getoption decoration:rounding"]
    environment: root.trustedEnv
    stdout: StdioCollector { id: decoOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) root.deco = Android.parseDeco(decoOut.text) }
  }

  function detach(key) { return root.switchMirror(key, "window") }
  function attach(key) { return root.switchMirror(key, "attached") }

  function attachAll() {
    for (var key in root.mirrors) if (root.mirrors[key].mode === "window") root.attach(key)
  }

  function mirrorExited(proc, exitCode) {
    var key = proc.key
    var mode = ""
    var next = ({})
    for (var k in root.mirrors) {
      if (root.mirrors[k].proc !== proc) next[k] = root.mirrors[k]
      else mode = root.mirrors[k].mode
    }
    root.setMirrors(next)
    root.stopInput(key)
    root.stopLockWatch(key)
    var row = root.rowByKey(key)
    var name = row ? row.name : key
    if (!proc.stopping && proc.restartAs === "" && exitCode === 2 && mode !== "") {
      // scrcpy's "device disconnected". Come back when the phone does.
      if (!root.scheduleResume(key, mode)) {
        root.saveStore(Android.rememberDevice(root.store, key, { mirror: "" }))
        root.setError("Mirror of " + name + " keeps dropping, so it was stopped" + (proc.lastError !== "" ? ": " + proc.lastError : ""))
      }
    } else if (!proc.stopping && exitCode !== 0) {
      root.saveStore(Android.rememberDevice(root.store, key, { mirror: "" }))
      root.setError("Mirror of " + name + " stopped" + (proc.lastError !== "" ? ": " + proc.lastError : ""))
    }
    var again = proc.restartAs
    proc.destroy()
    // A detach or an attach: the old scrcpy is gone, start the new one.
    if (again !== "") Qt.callLater(function() { root.startMirror(key, again) })
  }

  // ---- Resuming a mirror whose phone dropped off adb.
  //
  // scrcpy exits with 2 when the device disconnects (0 when its window is
  // closed, 1 on an error), and some phones drop every adb connection on
  // their own: ColorOS restarts adbd whenever the phone locks or unlocks, to
  // switch USB file transfer off and on, and starting scrcpy on a sleeping
  // OnePlus wakes and unlocks it — so its first mirror died two seconds in
  // and the second one, started by hand, stayed up. Such a mirror is started
  // again, the same way, once the phone is back. Three drops in 30 s and it
  // stays stopped.
  //
  // key → { mode, notBefore, until }
  property var resumes: ({})
  // key → times of recent drops, for the three-in-30-s limit
  property var dropTimes: ({})

  function scheduleResume(key, mode) {
    var now = Date.now()
    var recent = (root.dropTimes[key] || []).filter(function(t) { return now - t < 30000 })
    recent.push(now)
    var times = ({})
    for (var k in root.dropTimes) times[k] = root.dropTimes[k]
    times[key] = recent
    root.dropTimes = times
    if (recent.length > 3) return false
    var next = ({})
    for (var j in root.resumes) next[j] = root.resumes[j]
    // adbd takes a second or two to come back; starting sooner only fails.
    next[key] = { mode: mode, notBefore: now + 1500, until: now + 15000 }
    root.resumes = next
    var row = root.rowByKey(key)
    root.setNotice((row ? row.name : key) + " dropped its adb connection — mirroring again when it is back")
    root.refresh()
    return true
  }

  function cancelResume(key) {
    if (!root.resumes[key]) return
    var next = ({})
    for (var k in root.resumes) if (k !== key) next[k] = root.resumes[k]
    root.resumes = next
  }

  readonly property bool resuming: Object.keys(root.resumes).length > 0

  Timer {
    interval: 500
    repeat: true
    running: root.resuming
    onTriggered: {
      var now = Date.now()
      for (var key in root.resumes) {
        var r = root.resumes[key]
        if (now < r.notBefore) continue
        var row = root.rowByKey(key)
        if (row && row.target !== "" && row.state === Android.STATE_READY) {
          root.startMirror(key, r.mode)
        } else if (now > r.until) {
          root.cancelResume(key)
          root.saveStore(Android.rememberDevice(root.store, key, { mirror: "" }))
          root.setError("Mirror of " + (row ? row.name : key) + " stopped: the phone did not come back")
        }
      }
      // adb track-devices already rescans when the phone comes back; this is
      // only the net under it.
      if (root.resuming && Date.now() - root.lastScanAt > 2000) root.refresh()
    }
  }

  // ---- Attached windows.
  //
  // `wanted` is where the panel wants the window ({ x, y, w, h, ws } in
  // Hyprland layout pixels) or null for out of sight; `shown` is what was
  // last dispatched. They differ until the window has been found.

  function sameRect(a, b) {
    return !!a && !!b && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h && a.ws === b.ws
  }

  function dispatchAll(list) {
    for (var i = 0; i < list.length; i++) Hyprland.dispatch(list[i])
  }

  // When a showing tile last asked for each window. Mutated in place, not
  // reassigned: it is bookkeeping for the timer below, not something to bind.
  property var wantedAt: ({})

  function showWindow(key, rect, workspace) {
    var m = root.mirrors[key]
    if (!m || m.mode !== "attached" || !rect) return
    root.wantedAt[key] = Date.now()
    var want = { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.w), h: Math.round(rect.h), ws: workspace }
    if (sameRect(m.wanted, want) && sameRect(m.shown, want)) return
    var shown = m.shown
    if (m.address !== "") {
      var list = Android.hyprShow(m.address, workspace, want)
      root.dispatchAll(list)
      if (list.length > 0) shown = want
    }
    root.updateMirror(key, { wanted: want, shown: shown })
  }

  function hideWindow(key) {
    var m = root.mirrors[key]
    if (!m || m.mode !== "attached") return
    if (m.shown && m.address !== "") root.dispatchAll(Android.hyprHide(m.address))
    if (m.wanted || m.shown) root.updateMirror(key, { wanted: null, shown: null })
  }

  // A mirror in its own window, brought forward on a click in the panel.
  // Looked up by its title now: a window-mode mirror's address is only
  // tracked when screen off needs it.
  function focusWindow(key) {
    var m = root.mirrors[key]
    if (!m || m.mode === "attached") return false
    if (m.address !== "") { root.dispatchAll(Android.hyprFocus(m.address)); return true }
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < tops.length; i++) {
      if (tops[i].title !== m.title) continue
      var list = Android.hyprFocus(tops[i].address)
      if (list.length === 0) continue
      root.dispatchAll(list)
      return true
    }
    root.setError("Its window is not open yet")
    return false
  }

  // A just-started attached scrcpy's window, found by its title once Hyprland
  // lists it, then put wherever the panel already wants it.
  readonly property bool anyUnfound: {
    for (var key in root.mirrors) {
      var m = root.mirrors[key]
      if (m.address === "") return true
    }
    return false
  }

  function findWindows() {
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var key in root.mirrors) {
      var m = root.mirrors[key]
      if (m.address !== "") continue
      for (var i = 0; i < tops.length; i++) {
        if (tops[i].title !== m.title) continue
        var address = Android.hyprAddress(tops[i].address)
        if (address === "") continue
        root.updateMirror(key, { address: address })
        root.startLockWatch(key)
        var w = root.mirrors[key].wanted
        if (w && m.mode === "attached") root.showWindow(key, w, w.ws)
        break
      }
    }
  }

  // A window no tile has asked for lately goes out of sight, whatever the
  // reason: the panel closing, its view changing, the panel being rebuilt or
  // reloaded. A showing tile asks five times a second, so 700 ms of silence
  // means nobody is showing it. The panel also hides them at once on close;
  // this is the net under that.
  readonly property bool anyPlaced: {
    for (var key in root.mirrors) {
      var m = root.mirrors[key]
      if (m.mode === "attached" && (m.shown || m.wanted)) return true
    }
    return false
  }

  Timer {
    interval: 300
    repeat: true
    running: root.anyPlaced
    onTriggered: {
      var now = Date.now()
      for (var key in root.mirrors) {
        var m = root.mirrors[key]
        if (m.mode === "attached" && (m.shown || m.wanted) && now - (root.wantedAt[key] || 0) > 700) root.hideWindow(key)
      }
    }
  }

  // The hiding workspace must never be on screen. Hyprland opens a special
  // workspace when a window on it takes focus — a click, an activation
  // request, the window being hidden while focused — and then the "hidden"
  // phones sit in plain view over a blurred desktop (the user hit exactly
  // that). Close it whenever a monitor shows it. toggle_special acts on the
  // focused monitor, so only that one is handled; and after toggling, wait
  // for a fresh monitor list before toggling again, or the second toggle
  // would open it right back.
  property double specialClosedAt: 0

  function closeHidingWorkspace() {
    var mons = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < mons.length; i++) {
      var o = mons[i].lastIpcObject
      if (!o || !o.specialWorkspace || o.specialWorkspace.name !== Android.PANEL_WORKSPACE) continue
      if (!mons[i].focused || Date.now() - root.specialClosedAt < 1000) continue
      Hyprland.dispatch("hl.dsp.workspace.toggle_special(\"" + Android.PANEL_WORKSPACE.replace(/^special:/, "") + "\")")
      root.specialClosedAt = Date.now()
      var next = ({})
      for (var k in root.specialShownOn) next[k] = root.specialShownOn[k]
      next[mons[i].name] = false
      root.specialShownOn = next
    }
  }

  // Driven by Hyprland's events rather than polling: `activespecial>>name,
  // monitor` says which special workspace a monitor now shows (an empty name
  // when it closes), and `focusedmon>>monitor,workspace` which monitor has
  // focus. toggle_special only acts on the focused monitor, so a monitor that
  // opened the hiding workspace without focus is closed once it gets focus.
  property var specialShownOn: ({})
  property string focusedMonitorName: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""

  function noteSpecial(data) {
    var text = String(data || "")
    var comma = text.lastIndexOf(",")
    if (comma < 0) return
    var next = ({})
    for (var k in root.specialShownOn) next[k] = root.specialShownOn[k]
    next[text.slice(comma + 1)] = text.slice(0, comma) === Android.PANEL_WORKSPACE
    root.specialShownOn = next
    root.closeShownSpecial()
  }

  function noteFocusedMonitor(data) {
    var text = String(data || "")
    var comma = text.indexOf(",")
    root.focusedMonitorName = comma < 0 ? text : text.slice(0, comma)
    root.closeShownSpecial()
  }

  function closeShownSpecial() {
    if (!root.specialShownOn[root.focusedMonitorName]) return
    var next = ({})
    for (var k in root.specialShownOn) next[k] = root.specialShownOn[k]
    next[root.focusedMonitorName] = false
    root.specialShownOn = next
    Hyprland.dispatch("hl.dsp.workspace.toggle_special(\"" + Android.PANEL_WORKSPACE.replace(/^special:/, "") + "\")")
    root.specialClosedAt = Date.now()
  }

  // A slow net under the events, for a workspace that was already open when
  // the shell started or an event that never came.
  Timer {
    interval: 5000
    repeat: true
    triggeredOnStart: true
    running: root.attachedCount > 0
    onTriggered: {
      Hyprland.refreshMonitors()
      hidingCheck.restart()
    }
  }

  // Read the monitors once the refresh above has answered, never a list from
  // before the last toggle (closeHidingWorkspace skips a second toggle within
  // a second of the first, which covers the refresh's own delay).
  Timer {
    id: hidingCheck
    interval: 300
    onTriggered: root.closeHidingWorkspace()
  }

  // Panel and window-mode scrcpy windows this service does not own (a scrcpy
  // left over from an earlier shell, say) are closed: nothing would ever hide
  // or manage them again.
  function sweepWindows() {
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var re = new RegExp(Android.PANEL_TITLE_RE)
    for (var i = 0; i < tops.length; i++) {
      var t = tops[i]
      var isPanel = re.test(t.title)
      var isWindow = /^Android · [^·]+$/.test(t.title)
      if (!isPanel && !isWindow) continue
      var address = Android.hyprAddress(t.address)
      if (address === "") continue
      var ours = false
      for (var key in root.mirrors) {
        var m = root.mirrors[key]
        if (m.address === address || (m.address === "" && m.title === t.title)) ours = true
      }
      if (!ours) Hyprland.dispatch("hl.dsp.window.close({ window = \"address:" + address + "\" })")
    }
  }

  // ---- Restoring previous connection and mirror status on shell restart.
  property bool autoRestored: false
  property var autoConnectQueue: []

  function triggerAutoRestore() {
    root.sweepWindows()
    autoRestoreTimer.start()
  }

  Timer {
    id: autoRestoreTimer
    interval: 350
    repeat: false
    onTriggered: root.executeAutoRestore()
  }

  function scheduleAutoMirror(key, mode) {
    var now = Date.now()
    var next = ({})
    for (var j in root.resumes) next[j] = root.resumes[j]
    next[key] = { mode: mode, notBefore: now + 500, until: now + 30000 }
    root.resumes = next
  }

  function executeAutoRestore() {
    var toConnect = []

    for (var key in root.store) {
      var dev = root.store[key]
      if (!dev) continue
      var row = root.rowByKey(key)
      var isReady = row && (row.state === Android.STATE_READY || row.state === Android.STATE_MIRRORING)

      if (dev.connected && !isReady && dev.address && Android.parseAddress(dev.address, null)) {
        toConnect.push(dev.address)
      }

      if (dev.mirror === "attached" || dev.mirror === "window") {
        if (isReady) {
          root.startMirror(key, dev.mirror)
        } else {
          root.scheduleAutoMirror(key, dev.mirror)
        }
      }
    }

    if (toConnect.length > 0) {
      root.autoConnectQueue = toConnect.slice(1)
      root.connectAddress(toConnect[0])
    }
  }

  // A window Hyprland just opened or retitled: a mirror waiting for its
  // window takes it; one of this plugin's titles nobody owns (left by an
  // earlier shell) is closed. Startup sweeps once (triggerAutoRestore); after
  // that these events are what finds and sweeps windows, not a poll.
  function noteWindow(address, title) {
    var isPanel = new RegExp(Android.PANEL_TITLE_RE).test(title)
    if (!isPanel && !/^Android · [^·]+$/.test(title)) return
    var owner = ""
    for (var key in root.mirrors) {
      var m = root.mirrors[key]
      if (m.address === address || (m.address === "" && m.title === title)) owner = key
    }
    if (owner === "") {
      Hyprland.dispatch("hl.dsp.window.close({ window = \"address:" + address + "\" })")
      return
    }
    var mine = root.mirrors[owner]
    if (mine.address !== "") return
    root.updateMirror(owner, { address: address })
    root.startLockWatch(owner)
    var w = root.mirrors[owner].wanted
    if (w && mine.mode === "attached") root.showWindow(owner, w, w.ws)
  }

  // The net under openwindow: a window whose event was missed is still found.
  Timer {
    interval: 2000
    repeat: true
    running: root.anyUnfound
    onTriggered: {
      Hyprland.refreshToplevels()
      root.findWindows()
    }
  }

  Process {
    id: panelRuleProc
    command: ["/usr/bin/hyprctl", "eval", Android.PANEL_RULE_LUA]
    environment: root.trustedEnv
    stdout: StdioCollector { id: panelRuleOut; waitForEnd: true }
    onExited: function(exitCode) {
      var text = String(panelRuleOut.text).trim()
      root.panelRuleReady = exitCode === 0 && text === "ok"
      root.panelRuleError = root.panelRuleReady ? "" : Android.plainLabel(text || ("exit " + exitCode), 120)
      // Started even if the rule failed: the window then opens tiled for a
      // moment, and showWindow floats it anyway.
      var waiters = root.ruleWaiters
      root.ruleWaiters = []
      for (var i = 0; i < waiters.length; i++) waiters[i]()
    }
  }

  Component {
    id: mirrorComponent

    Process {
      id: mirrorProc
      property string key: ""
      property bool stopping: false
      property string restartAs: ""
      property string lastError: ""
      property double stopAt: 0

      environment: root.trustedEnv
      // scrcpy talks a lot; only its errors are worth keeping, and only the
      // latest one.
      stdout: SplitParser {
        onRead: function(line) {
          if (/^(ERROR|E )/.test(line)) mirrorProc.lastError = Android.plainLabel(line.replace(/^ERROR:\s*|^E /, ""), 160)
        }
      }
      stderr: SplitParser {
        onRead: function(line) {
          if (/^ERROR/.test(line)) mirrorProc.lastError = Android.plainLabel(line.replace(/^ERROR:\s*/, ""), 160)
        }
      }
      onExited: function(exitCode) { root.mirrorExited(mirrorProc, exitCode) }
    }
  }

  // ---- The ◁ ○ □ buttons under an attached tile: one persistent `adb shell`
  //      per phone, fed `input keyevent` lines. Started on the first press,
  //      stopped with the mirror. Everything else goes straight into the
  //      scrcpy window.
  property var inputProcs: ({})

  function sendInput(key, line) {
    if (!line) return
    var m = root.mirrors[key]
    if (!m || m.mode !== "attached") return
    var p = root.inputProcs[key]
    if (!p) {
      p = inputComponent.createObject(root, { key: key, command: root.script("input.sh").concat([m.target]) })
      if (!p) return
      var next = ({})
      for (var k in root.inputProcs) next[k] = root.inputProcs[k]
      next[key] = p
      root.inputProcs = next
      p.pending = [line]
      p.running = true
      return
    }
    if (p.started) p.write(line + "\n")
    else p.pending = p.pending.concat([line])
  }

  function stopInput(key) {
    var p = root.inputProcs[key]
    if (!p) return
    var next = ({})
    for (var k in root.inputProcs) if (k !== key) next[k] = root.inputProcs[k]
    root.inputProcs = next
    p.running = false
  }

  function pressKey(key, name) { root.sendInput(key, Android.keyInput(name)) }

  Component {
    id: inputComponent

    Process {
      id: inputProc
      property string key: ""
      property var pending: []
      property bool started: false

      environment: root.trustedEnv
      stdinEnabled: true
      onStarted: {
        inputProc.started = true
        for (var i = 0; i < inputProc.pending.length; i++) inputProc.write(inputProc.pending[i] + "\n")
        inputProc.pending = []
      }
      onExited: {
        if (root.inputProcs[inputProc.key] === inputProc) {
          var next = ({})
          for (var k in root.inputProcs) if (k !== inputProc.key) next[k] = root.inputProcs[k]
          root.inputProcs = next
        }
        inputProc.destroy()
      }
    }
  }

  // ---- One-shot actions.
  function screenshot(key) {
    var row = root.rowByKey(key)
    if (!row || row.target === "") { root.setError("That phone is not connected"); return false }
    if (shotProc.running) return false
    var stem = "android-" + Android.titleSafe(row.name).replace(/ /g, "-") + "-" + Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss")
    shotProc.command = root.script("screenshot.sh").concat([row.target, stem])
    shotProc.running = true
    return true
  }

  function finishShot(text) {
    var line = String(text).split("\n")[0]
    if (line.indexOf("E ") === 0) root.setError("Screenshot: " + line.slice(2))
    else if (line !== "") root.setNotice("Saved " + line.replace(root.home, "~"))
  }

  // An interactive `adb shell` in the user's own terminal. The binaries are
  // resolved through a fixed PATH; the device id is a positional argument,
  // never spliced into the script.
  readonly property string terminalScript:
    'trusted() { PATH=/usr/bin:/bin command -v -- "$1"; }\n'
    + 'term=$(trusted xdg-terminal-exec) || exit 1\n'
    + 'adb=$(trusted adb) || exit 1\n'
    + 'session=$(trusted setsid) || session=""\n'
    + 'app=$(trusted uwsm-app) || app=""\n'
    + 'if [ -n "$app" ]; then set -- "$app" -- "$term" "$adb" -s "$1" shell; else set -- "$term" "$adb" -s "$1" shell; fi\n'
    + 'if [ -n "$session" ]; then exec "$session" "$@"; fi\n'
    + 'exec "$@"'

  function openShell(key) {
    var row = root.rowByKey(key)
    if (!row || row.target === "" || !Android.validDeviceId(row.target)) { root.setError("That phone is not connected"); return false }
    Quickshell.execDetached([root.shellBin, "-c", root.terminalScript, "android-manager", row.target])
    return true
  }

  function statusJson() {
    var list = []
    for (var i = 0; i < root.rows.length; i++) {
      var r = root.rows[i]
      list.push({ name: r.name, state: r.state, transport: r.transport })
    }
    return JSON.stringify({
      adb: root.tools.adb, scrcpy: root.tools.scrcpy,
      mirrors: root.mirrorCount, attached: root.attachedCount, devices: list
    })
  }

  // ---- Lifecycle.
  Component.onCompleted: {
    storeReadProc.running = true
    panelRuleProc.running = true
    decoProc.running = true
  }

  // Nothing this service started outlives it. Mirrors included: a scrcpy
  // nobody can see or stop from the panel is worse than one that stopped.
  Component.onDestruction: {
    trackProc.running = false
    for (var i in root.inputProcs) root.inputProcs[i].running = false
    for (var w in root.lockWatchers) root.lockWatchers[w].running = false
    for (var k in root.mirrors) {
      root.mirrors[k].proc.stopping = true
      root.mirrors[k].proc.running = false
    }
    // The Hyprland rule stays: it matches only this plugin's panel titles, and
    // switching it off here could race the next service's own rule on a
    // shell restart and switch that one off instead.
  }

  component Deadline: Timer {
    id: deadline
    required property var proc
    required property string what
    property int seconds: 60
    interval: deadline.seconds * 1000
    repeat: false
    running: deadline.proc.running
    onTriggered: {
      deadline.proc.signal(15)
      deadline.proc.running = false
      root.setError(deadline.what + " took too long and was stopped")
    }
  }

  Process {
    id: storeReadProc
    command: root.script("store.sh").concat(["read"])
    environment: root.trustedEnv
    stdout: StdioCollector { id: storeOut; waitForEnd: true }
    onExited: function(exitCode) {
      var text = storeOut.text
      if (exitCode !== 0 || text.indexOf("E ") === 0) {
        root.setError("Could not read the remembered devices: " + text.replace(/^E /, ""))
        root.store = ({})
      } else {
        root.store = Android.parseStore(text)
      }
      root.storeLoaded = true
      root.refresh()
      trackProc.running = true
    }
  }

  Process {
    id: storeWriteProc
    property string payload: ""
    command: root.script("store.sh").concat(["write"])
    environment: root.trustedEnv
    stdinEnabled: true
    stdout: StdioCollector { id: storeWriteOut; waitForEnd: true }
    onStarted: {
      storeWriteProc.write(String(Android.utf8Length(storeWriteProc.payload)) + "\n")
      storeWriteProc.write(storeWriteProc.payload)
    }
    onExited: {
      if (storeWriteOut.text.indexOf("ok") !== 0)
        root.setError("Could not save the remembered devices: " + storeWriteOut.text.replace(/^E /, ""))
      if (root.pendingStore !== "") {
        storeWriteProc.payload = root.pendingStore
        root.pendingStore = ""
        Qt.callLater(function() { storeWriteProc.running = true })
      }
    }
  }

  Process {
    id: scanProc
    environment: root.trustedEnv
    stdout: StdioCollector { id: scanOut; waitForEnd: true }
    onExited: root.applyScan(scanOut.text)
  }

  // adb's own change feed. Each message is a length-prefixed device list; the
  // content is not parsed here — any message means "something changed", and
  // the scan that follows is what gets read. Debounced, because a phone being
  // plugged in arrives as several messages in a row.
  Process {
    id: trackProc
    command: ["/usr/bin/adb", "track-devices"]
    environment: root.trustedEnv
    stdout: SplitParser { onRead: function(line) { trackDebounce.restart() } }
    onExited: trackRestart.start()
  }

  Timer {
    id: trackDebounce
    interval: 400
    onTriggered: root.refresh()
  }

  // adb's server restarts (an update, `adb kill-server`), and the feed ends
  // with it. Come back, but not in a tight loop.
  Timer {
    id: trackRestart
    interval: 5000
    onTriggered: if (!root.adbMissing) trackProc.running = true
  }

  Process {
    id: wifiProc
    environment: root.trustedEnv
    stdout: SplitParser { onRead: function(line) { root.wifiOutput += line + "\n" } }
    onExited: root.finishWifi()
  }

  Process {
    id: netProc
    environment: root.trustedEnv
    stdinEnabled: true
    stdout: StdioCollector { id: netOut; waitForEnd: true }
    // The pairing code goes over stdin to the helper and from there to adb's
    // own prompt. It never sits on a command line.
    onStarted: {
      if (root.netVerb === "pair") netProc.write(root.pairCode + "\n")
    }
    onExited: root.finishNet(netOut.text)
  }

  Process {
    id: mdnsProc
    command: root.script("connect.sh").concat(["mdns"])
    environment: root.trustedEnv
    stdout: StdioCollector { id: mdnsOut; waitForEnd: true }
    onExited: root.discovered = Android.parseMdns(mdnsOut.text)
  }

  Process {
    id: shotProc
    environment: root.trustedEnv
    stdout: StdioCollector { id: shotOut; waitForEnd: true }
    onExited: root.finishShot(shotOut.text)
  }

  Deadline { proc: storeReadProc; what: "Reading the remembered devices"; seconds: 10 }
  Deadline { proc: storeWriteProc; what: "Saving the remembered devices"; seconds: 10 }
  Deadline { proc: scanProc; what: "Looking for phones" }
  Deadline { proc: wifiProc; what: "Switching to Wi-Fi" }
  Deadline { proc: netProc; what: "Talking to adb"; seconds: 30 }
  Deadline { proc: mdnsProc; what: "Looking for phones on the network"; seconds: 15 }
  Deadline { proc: shotProc; what: "Taking the screenshot"; seconds: 40 }
}
