// Pure logic for the Android manager: reading what adb and the helper scripts
// print, merging it into one row per phone, and building scrcpy's arguments.
//
// No Qt and no locale in here, so the whole file runs under plain node for the
// tests (`bash test/test.sh`). QML imports it as a JS resource; node requires
// it through the guard at the bottom. No `.pragma library`: node cannot
// parse it, and nothing here keeps state between calls anyway.
//
// Everything a phone reports about itself — model, manufacturer, serial — is
// text from a device on the other end of a cable or a network. It is shown on
// screen and put in a window title, so it goes through plainLabel first.

var STATE_READY = "ready"
var STATE_MIRRORING = "mirroring"
var STATE_UNAUTHORIZED = "unauthorized"
var STATE_OFFLINE = "offline"
var STATE_REMEMBERED = "remembered"

// Shape carries the state as well as color: a theme may give `urgent` the same
// hue as the accent, and a mark that differs only in color then says nothing.
var MARKS = {
  ready: "●",
  mirroring: "●",
  unauthorized: "◐",
  offline: "○",
  remembered: "○"
}

var MAX_LABEL = 64
var DEFAULT_PORT = 5555

// How many mirrors can be drawn inside the panel at once. The user owns three
// phones; a fourth mirror opens in its own window.
var MAX_ATTACHED = 3

// ---------------------------------------------------------------- labels

// Strip what can make a label render as something other than what it is:
// control characters, and the bidi overrides and isolates that can reorder a
// sentence on screen.
function plainLabel(text, max) {
  var limit = max || MAX_LABEL
  var s = String(text === undefined || text === null ? "" : text)
  s = s.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩﻿]/g, "")
  s = s.replace(/^\s+|\s+$/g, "")
  if (s.length > limit) s = s.slice(0, limit - 1) + "…"
  return s
}

// A window title goes on argv and into the compositor, so it keeps to a
// conservative alphabet rather than whatever the phone calls itself.
function titleSafe(text) {
  var s = plainLabel(text, 40).replace(/[^A-Za-z0-9 ._+()-]/g, "")
  return s === "" ? "device" : s
}

// ---------------------------------------------------------------- addresses

function validPort(port) {
  var s = String(port)
  if (!/^[0-9]{1,5}$/.test(s)) return false
  var n = Number(s)
  return n >= 1 && n <= 65535
}

function validHost(host) {
  var s = String(host || "")
  if (s.length === 0 || s.length > 253) return false
  if (/^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(s)) {
    var parts = s.split(".")
    for (var i = 0; i < 4; i++) if (Number(parts[i]) > 255) return false
    return true
  }
  // A hostname, not a URL and not an option: no leading dash.
  return /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(s)
}

// "192.168.1.5", "192.168.1.5:5555", " 192.168.1.5 : 5555 " → { host, port }
// or null. The port defaults to 5555, the port this user connects on.
function parseAddress(text, defaultPort) {
  var s = String(text || "").replace(/\s+/g, "")
  if (s === "") return null
  var host = s
  var port = defaultPort === undefined ? DEFAULT_PORT : defaultPort
  var colon = s.lastIndexOf(":")
  if (colon !== -1) {
    host = s.slice(0, colon)
    port = s.slice(colon + 1)
  }
  if (!validHost(host) || !validPort(port)) return null
  return { host: host, port: Number(port), text: host + ":" + Number(port) }
}

// What a device id from `adb devices` may look like before it is handed to a
// helper as `-s <id>`: a serial, ip:port, or an mDNS service name.
function validDeviceId(id) {
  return /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(String(id || ""))
}

// ---------------------------------------------------------------- scan

// One `adb devices -l` line: "<id> <state> key:value key:value…".
function parseDeviceLine(line) {
  var parts = String(line).replace(/^\s+|\s+$/g, "").split(/\s+/)
  if (parts.length < 2 || !validDeviceId(parts[0])) return null
  var dev = { id: parts[0], state: parts[1], attrs: {} }
  for (var i = 2; i < parts.length; i++) {
    var colon = parts[i].indexOf(":")
    if (colon > 0) dev.attrs[parts[i].slice(0, colon)] = parts[i].slice(colon + 1)
  }
  dev.transport = transportOf(dev)
  return dev
}

function transportOf(dev) {
  if (/^[0-9.]+:[0-9]+$/.test(dev.id) || dev.id.indexOf("._adb-tls-connect.") !== -1) return "wifi"
  if (/^emulator-[0-9]+$/.test(dev.id)) return "emulator"
  return "usb"
}

// What bin/scan.sh's device-side script printed for one phone, as the lines
// after its "P <id>" prefix: `key=value` getprops, then sections that start
// with "@battery", "@ip", "@wm", "@df".
function parseProbe(lines) {
  var info = {
    model: "", manufacturer: "", serialno: "", release: "", sdk: "",
    battery: null, ip: "", screen: null, storage: null
  }
  var section = ""
  var battery = {}
  for (var i = 0; i < lines.length; i++) {
    var line = String(lines[i])
    if (line.charAt(0) === "@") { section = line.slice(1); continue }

    if (section === "") {
      var eq = line.indexOf("=")
      if (eq > 0) {
        var key = line.slice(0, eq)
        if (key in info && typeof info[key] === "string") info[key] = plainLabel(line.slice(eq + 1))
      }
    } else if (section === "battery") {
      var m = /^\s*(level|status|AC powered|USB powered|Wireless powered):\s*(\S+)/.exec(line)
      if (m) battery[m[1]] = m[2]
    } else if (section === "ip") {
      var ip = /\binet\s+([0-9]{1,3}(?:\.[0-9]{1,3}){3})\//.exec(line)
      if (ip && info.ip === "" && validHost(ip[1])) info.ip = ip[1]
    } else if (section === "wm") {
      // "Override size" wins over "Physical size" when the user has scaled.
      var size = /^(Physical|Override) size:\s*([0-9]+)x([0-9]+)/.exec(line)
      if (size && (info.screen === null || size[1] === "Override"))
        info.screen = { w: Number(size[2]), h: Number(size[3]) }
    } else if (section === "df") {
      // Filesystem 1K-blocks Used Available Use% Mounted-on
      var cols = line.replace(/^\s+/, "").split(/\s+/)
      if (cols.length >= 4 && /^[0-9]+$/.test(cols[1]) && /^[0-9]+$/.test(cols[2]))
        info.storage = { totalKb: Number(cols[1]), usedKb: Number(cols[2]) }
    }
  }

  if (battery.level !== undefined && /^[0-9]+$/.test(battery.level)) {
    info.battery = {
      level: Math.min(100, Number(battery.level)),
      // BatteryManager: 2 charging, 5 full.
      charging: battery.status === "2",
      full: battery.status === "5",
      plugged: battery["AC powered"] === "true" || battery["USB powered"] === "true"
        || battery["Wireless powered"] === "true"
    }
  }
  return info
}

// Everything bin/scan.sh printed, one record per line:
//   T <tool> <version|missing>      adb, scrcpy
//   D <adb devices -l line>
//   P <id> <device-side line>
//   E <message>
function parseScan(text) {
  var out = { tools: { adb: "", scrcpy: "" }, devices: [], errors: [] }
  var probes = ({})
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var kind = line.slice(0, 2)
    var rest = line.slice(2)
    if (kind === "T ") {
      var sp = rest.indexOf(" ")
      var tool = sp === -1 ? rest : rest.slice(0, sp)
      if (tool === "adb" || tool === "scrcpy") out.tools[tool] = plainLabel(sp === -1 ? "" : rest.slice(sp + 1), 40)
    } else if (kind === "D ") {
      var dev = parseDeviceLine(rest)
      if (dev) out.devices.push(dev)
    } else if (kind === "P ") {
      var sp2 = rest.indexOf(" ")
      var id = sp2 === -1 ? rest : rest.slice(0, sp2)
      if (!probes[id]) probes[id] = []
      probes[id].push(sp2 === -1 ? "" : rest.slice(sp2 + 1))
    } else if (kind === "E ") {
      out.errors.push(plainLabel(rest, 200))
    }
  }
  for (var d = 0; d < out.devices.length; d++) {
    var p = probes[out.devices[d].id]
    out.devices[d].info = p ? parseProbe(p) : null
  }
  return out
}

// ---------------------------------------------------------------- rows

// adb lists a phone once per transport: on USB and on Wi-Fi at the same time
// it is two entries. The user owns one phone, so it is one row, keyed by the
// serial the phone reports. A device that has not been authorized cannot be
// asked for its serial, so it stands on its own id.
//
// `store` is what the service remembers: { <serialno>: { name, address,
// options } }. A remembered phone that adb does not list is still a row, so a
// Wi-Fi phone that rebooted out of tcpip mode can be found and reconnected.
// `mirrors` is { <key>: { mode } } for the scrcpy processes running now.
function buildRows(scan, store, mirrors) {
  var rows = []
  var byKey = ({})
  var devices = scan ? scan.devices : []
  var known = store || ({})
  var running = mirrors || ({})

  for (var i = 0; i < devices.length; i++) {
    var dev = devices[i]
    var key = dev.info && dev.info.serialno ? dev.info.serialno : dev.id
    var row = byKey[key]
    if (!row) {
      row = {
        key: key, name: "", transports: [], info: null, remembered: !!known[key],
        address: known[key] && known[key].address ? String(known[key].address) : ""
      }
      byKey[key] = row
      rows.push(row)
    }
    row.transports.push({ id: dev.id, kind: dev.transport, state: dev.state })
    if (dev.info && (!row.info || dev.transport === "usb")) row.info = dev.info
    if (dev.transport === "wifi" && /^[0-9.]+:[0-9]+$/.test(dev.id)) row.address = dev.id
  }

  for (var k in known) {
    if (byKey[k] || !known[k]) continue
    var r = {
      key: k, name: "", transports: [], info: null, remembered: true,
      address: known[k].address ? String(known[k].address) : ""
    }
    byKey[k] = r
    rows.push(r)
  }

  for (var j = 0; j < rows.length; j++) finishRow(rows[j], known[rows[j].key], running[rows[j].key])

  // Usable first, then the ones that need the user, then the absent; stable
  // by name inside each group so rows do not jump around between scans.
  var rank = { mirroring: 0, ready: 0, unauthorized: 1, offline: 2, remembered: 3 }
  rows.sort(function(a, b) {
    var d = rank[a.state] - rank[b.state]
    if (d !== 0) return d
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0
  })
  return rows
}

function finishRow(row, remembered, mirror) {
  var usable = null
  for (var i = 0; i < row.transports.length; i++) {
    var t = row.transports[i]
    if (t.state !== "device") continue
    // USB first: it is faster, and it does not depend on the phone staying on
    // the same network.
    if (!usable || (usable.kind !== "usb" && t.kind === "usb")) usable = t
  }
  row.target = usable ? usable.id : ""
  row.transport = usable ? usable.kind : (row.transports.length > 0 ? row.transports[0].kind : "wifi")

  var name = row.info && row.info.model ? row.info.model : ""
  if (name === "" && remembered && remembered.name) name = plainLabel(remembered.name)
  if (name === "") name = row.key
  row.name = plainLabel(name)

  if (mirror) row.state = STATE_MIRRORING
  else if (usable) row.state = STATE_READY
  else if (hasState(row, "unauthorized")) row.state = STATE_UNAUTHORIZED
  else if (row.transports.length > 0) row.state = STATE_OFFLINE
  else row.state = STATE_REMEMBERED
  row.mirror = mirror || null
  row.options = normalizeOptions(remembered && remembered.options)
  row.connected = remembered ? !!remembered.connected : false
  row.savedMirror = remembered ? (remembered.mirror || "") : ""
}

function hasState(row, state) {
  for (var i = 0; i < row.transports.length; i++) if (row.transports[i].state === state) return true
  return false
}

function markFor(state) { return MARKS[state] || "○" }

function rowSubtitle(row) {
  var parts = []
  var kinds = []
  for (var i = 0; i < row.transports.length; i++) {
    var k = row.transports[i].kind === "wifi" ? "wi-fi" : row.transports[i].kind
    if (kinds.indexOf(k) === -1) kinds.push(k)
  }
  if (kinds.length === 0) kinds.push(row.address ? "wi-fi" : "not connected")
  parts.push(kinds.join(" + "))

  if (row.address && kinds.indexOf("wi-fi") !== -1) parts.push(row.address)
  else if (row.transport === "usb" && row.state !== STATE_REMEMBERED) parts.push(row.key)

  if (row.state === STATE_UNAUTHORIZED) parts.push("model unknown until authorized")
  else if (row.info && row.info.release) parts.push("Android " + row.info.release)
  else if (row.state === STATE_REMEMBERED) parts.push("remembered")
  return parts.join(" · ")
}

function rowStatus(row) {
  if (row.state === STATE_MIRRORING) return row.mirror && row.mirror.mode === "attached" ? "Mirroring" : "Mirroring · window"
  if (row.state === STATE_READY) return "Ready"
  if (row.state === STATE_UNAUTHORIZED) return "Unauthorized"
  if (row.state === STATE_OFFLINE) return "Offline"
  return "Not connected"
}

function rowMeta(row) {
  if (row.state === STATE_UNAUTHORIZED) return "tap Allow on the phone"
  if (row.state === STATE_REMEMBERED || row.state === STATE_OFFLINE) {
    // tcpip mode does not survive a reboot, and that is the usual reason a
    // phone that worked yesterday is not answering on :5555 today.
    return row.address ? "rebooted? plug in once" : ""
  }
  var parts = []
  if (row.state === STATE_MIRRORING) {
    var o = row.options
    parts.push((o.maxSize === 0 ? "native" : o.maxSize + "p") + " · " + o.maxFps + " fps")
  }
  if (row.info && row.info.battery) parts.push(row.info.battery.level + "%")
  return parts.join(" · ")
}

// The details view's left column, in display order.
function infoRows(row) {
  var list = []
  var info = row.info
  list.push({ k: "Serial", v: row.key })
  if (info) {
    if (info.manufacturer || info.model)
      list.push({ k: "Model", v: plainLabel((info.manufacturer + " " + info.model).replace(/^\s+/, "")) })
    if (info.release) list.push({ k: "Android", v: info.release + (info.sdk ? " (API " + info.sdk + ")" : "") })
    if (info.battery) {
      var b = info.battery
      list.push({ k: "Battery", v: b.level + "%" + (b.full ? " · full" : b.charging ? " · charging" : "") })
    }
    if (info.screen) list.push({ k: "Screen", v: info.screen.w + " × " + info.screen.h })
    if (info.storage) list.push({ k: "Storage", v: gb(info.storage.usedKb) + " / " + gb(info.storage.totalKb) + " GB" })
    if (info.ip) list.push({ k: "Wi-Fi IP", v: info.ip })
  }
  if (row.address) list.push({ k: "Wi-Fi adb", v: row.address })
  return list
}

function gb(kb) {
  var v = kb / 1048576
  return v >= 10 ? String(Math.round(v)) : String(Math.round(v * 10) / 10)
}

// ---------------------------------------------------------------- mirror options

var OPTION_SPECS = [
  { key: "maxSize", label: "Max size", choices: [720, 1080, 1440, 1920, 0] },
  { key: "bitRate", label: "Bit rate", choices: [2, 4, 8, 16, 24] },
  { key: "maxFps", label: "Max fps", choices: [30, 60, 90, 120] },
  { key: "audio", label: "Audio", toggle: true },
  { key: "stayAwake", label: "Stay awake", toggle: true },
  { key: "screenOff", label: "Screen off", toggle: true },
  { key: "record", label: "Record", toggle: true }
]

// 1080 is sharp enough to read on a laptop and light enough for Wi-Fi.
var DEFAULT_OPTIONS = {
  maxSize: 1080, bitRate: 8, maxFps: 60,
  audio: true, stayAwake: true, screenOff: true, record: false
}

function normalizeOptions(raw) {
  var o = ({})
  for (var i = 0; i < OPTION_SPECS.length; i++) {
    var spec = OPTION_SPECS[i]
    var v = raw ? raw[spec.key] : undefined
    if (spec.toggle) o[spec.key] = typeof v === "boolean" ? v : DEFAULT_OPTIONS[spec.key]
    else o[spec.key] = spec.choices.indexOf(v) !== -1 ? v : DEFAULT_OPTIONS[spec.key]
  }
  return o
}

function optionValue(spec, options) {
  var v = options[spec.key]
  if (spec.toggle) return v ? "[x] on" : "[ ] off"
  if (spec.key === "maxSize") return v === 0 ? "native" : String(v)
  if (spec.key === "bitRate") return v + "M"
  return String(v)
}

// Space on a toggle flips it; space on a choice steps to the next one.
function stepOption(options, key, delta) {
  var o = normalizeOptions(options)
  for (var i = 0; i < OPTION_SPECS.length; i++) {
    var spec = OPTION_SPECS[i]
    if (spec.key !== key) continue
    if (spec.toggle) o[key] = !o[key]
    else {
      var n = spec.choices.length
      var at = spec.choices.indexOf(o[key])
      o[key] = spec.choices[(((at + (delta || 1)) % n) + n) % n]
    }
  }
  return o
}

// scrcpy's arguments for one device, as an array for argv — never a string
// for a shell. `mode` is "window" or "attached"; `extra` carries the name for
// the title, the panel slot and the recording path, which the caller owns.
//
// Both modes are a real scrcpy window, so both have scrcpy's own mouse,
// keyboard and clipboard. An attached one is borderless and titled with its
// panel slot (panelTitle): the service's Hyprland rule floats it out of
// sight on a special workspace, and the panel moves it under a hole in
// itself while it is open.
function scrcpyArgs(options, mode, extra) {
  var o = normalizeOptions(options)
  var e = extra || ({})
  var args = []
  if (o.maxSize !== 0) args.push("--max-size=" + o.maxSize)
  args.push("--video-bit-rate=" + o.bitRate + "M")
  args.push("--max-fps=" + o.maxFps)
  if (!o.audio) args.push("--no-audio")
  if (o.stayAwake) args.push("--stay-awake")
  // A phone still locked when the mirror starts keeps its own screen on, so
  // the user can unlock it there (some lock screens never reach the mirror);
  // the service turns it off once the phone is unlocked (screenKeys).
  if (o.screenOff && !e.deferScreenOff) args.push("--turn-screen-off")
  if (o.record && e.recordPath) args.push("--record=" + e.recordPath)

  if (mode === "attached") {
    args.push("--window-borderless")
    args.push("--window-title=" + panelTitle(e.title || "", e.slot || 1))
  } else {
    args.push("--window-title=Android · " + titleSafe(e.title || ""))
  }
  return args
}

// The command line as the details view shows it. Display only: the real one
// is the argv array above, passed through bin/mirror.sh.
function commandPreview(row, mode, extra) {
  var target = row && row.target ? row.target : (row ? row.key : "")
  var args = scrcpyArgs(row ? row.options : null, mode, extra)
  var shown = []
  for (var i = 0; i < args.length; i++) {
    shown.push(/\s/.test(args[i]) ? args[i].replace(/=(.*)$/, '="$1"') : args[i])
  }
  return "$ scrcpy -s " + target + " " + shown.join(" ")
}

// ---------------------------------------------------------------- adb answers

// `adb connect` exits 0 when it fails; the text is the only answer.
function parseConnect(text) {
  var s = plainLabel(String(text || "").split("\n").filter(function(l) { return l.trim() !== "" }).pop() || "", 160)
  if (/^already connected to /.test(s)) return { ok: true, already: true, message: s }
  if (/^connected to /.test(s)) return { ok: true, already: false, message: s }
  return { ok: false, already: false, message: s === "" ? "adb did not answer" : s }
}

function parsePair(text) {
  var s = String(text || "")
  var ok = /Successfully paired to /.exec(s)
  var last = plainLabel(s.split("\n").filter(function(l) { return l.trim() !== "" && !/^Enter pairing code/.test(l) }).pop() || "", 160)
  return { ok: !!ok, message: last === "" ? "adb did not answer" : last }
}

// `adb mdns services`: "<name>\t<type>\t<host:port>" per line (adb 34+), or
// the same separated by spaces on older adb.
function parseMdns(text) {
  var list = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var cols = lines[i].replace(/^\s+|\s+$/g, "").split(/\s+/)
    if (cols.length < 3) continue
    if (!/^_adb-tls-(pairing|connect)\._tcp\.?$/.test(cols[1])) continue
    var addr = parseAddress(cols[2], null)
    if (!addr) continue
    list.push({
      name: plainLabel(cols[0], 80),
      kind: cols[1].indexOf("pairing") !== -1 ? "pairing" : "connect",
      address: addr.text
    })
  }
  return list
}

// bin/wifi.sh reports each step as "STEP <n> <ok|fail|run> <detail>".
var WIFI_STEPS = ["Phone on USB", "Read its Wi-Fi IP", "adb tcpip", "adb connect"]

function parseWifi(text) {
  var steps = []
  for (var i = 0; i < WIFI_STEPS.length; i++) steps.push({ label: WIFI_STEPS[i], status: "wait", detail: "" })
  var lines = String(text || "").split("\n")
  for (var j = 0; j < lines.length; j++) {
    var m = /^STEP ([0-3]) (ok|fail|run) ?(.*)$/.exec(lines[j])
    if (!m) continue
    steps[Number(m[1])].status = m[2]
    steps[Number(m[1])].detail = plainLabel(m[3], 80)
  }
  return steps
}

// ---------------------------------------------------------------- store

// The remembered-device store is JSON the service wrote itself, but it lives
// in the user's home where anything can edit it. Read it as untrusted: keep
// only well-formed entries, with only the fields this file knows.
function parseStore(text) {
  var data
  try { data = JSON.parse(String(text || "{}")) } catch (e) { return ({}) }
  var out = ({})
  var devices = data && typeof data === "object" && data.devices && typeof data.devices === "object" ? data.devices : ({})
  var count = 0
  for (var key in devices) {
    if (count >= 64) break
    if (!validDeviceId(key)) continue
    var d = devices[key]
    if (!d || typeof d !== "object") continue
    var addr = typeof d.address === "string" ? parseAddress(d.address, null) : null
    var mirror = d.mirror === "attached" || d.mirror === "window" ? d.mirror : ""
    var connected = typeof d.connected === "boolean" ? d.connected : false
    out[key] = {
      name: typeof d.name === "string" ? plainLabel(d.name) : "",
      address: addr ? addr.text : "",
      options: normalizeOptions(d.options),
      connected: connected,
      mirror: mirror
    }
    count++
  }
  return out
}

function serializeStore(store) {
  return JSON.stringify({ version: 1, devices: store || ({}) }, null, 2) + "\n"
}

function rememberDevice(store, key, fields) {
  var next = ({})
  for (var k in store) next[k] = store[k]
  var prev = next[key] || { name: "", address: "", options: normalizeOptions(null), connected: false, mirror: "" }
  var conn = fields.connected !== undefined ? !!fields.connected : (prev.connected !== undefined ? !!prev.connected : false)
  var mirr = fields.mirror !== undefined ? (fields.mirror === "attached" || fields.mirror === "window" ? fields.mirror : "") : (prev.mirror || "")
  next[key] = {
    name: fields.name !== undefined ? plainLabel(fields.name) : prev.name,
    address: fields.address !== undefined ? String(fields.address) : prev.address,
    options: fields.options !== undefined ? normalizeOptions(fields.options) : prev.options,
    connected: conn,
    mirror: mirr
  }
  return next
}

function forgetDevice(store, key) {
  var next = ({})
  for (var k in store) if (k !== key) next[k] = store[k]
  return next
}

// UTF-8 bytes, which is what Qt writes to a pipe, rather than JavaScript's
// UTF-16 code units. bin/store.sh reads exactly this many.
function utf8Length(text) {
  var n = 0
  var s = String(text)
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++ }
    else n += 3
  }
  return n
}

// What bin/unlock.sh did, and whether the phone is still locked after it
// (a PIN or pattern only the user can enter). Unknown words are ignored.
function parseUnlock(text) {
  var words = String(text || "").split(/\s+/)
  return {
    woke: words.indexOf("woke") !== -1,
    dismissed: words.indexOf("dismissed") !== -1,
    locked: words.indexOf("locked") !== -1
  }
}

// One line from bin/lockstate.sh ("isKeyguardShowing=… mWakefulness=…"):
// whether the keyguard is up and whether the phone is awake. null for
// whatever the phone did not say.
function parseLockState(text) {
  var s = String(text || "")
  var k = /(?:^|\s)isKeyguardShowing=(true|false)(?=\s|$)/.exec(s)
  var w = /(?:^|\s)mWakefulness=([A-Za-z]+)(?=\s|$)/.exec(s)
  return { locked: k ? k[1] === "true" : null, awake: w ? w[1] === "Awake" : null }
}

// The Hyprland dispatches that press scrcpy's own shortcut for the phone's
// physical screen in one window, without focusing it: MOD+o turns it off and
// keeps mirroring, MOD+Shift+o turns it back on (MOD is left Alt by default).
// scrcpy has no other way to do either once it is running.
function screenKeys(address, on) {
  var a = hyprAddress(address)
  if (a === "") return []
  var mods = on ? "ALT SHIFT" : "ALT"
  var press = function(state) {
    return "hl.dsp.send_key_state({ mods = \"" + mods + "\", key = \"o\", state = \"" + state + "\", window = \"address:" + a + "\" })"
  }
  return [press("down"), press("up")]
}

// ---------------------------------------------------------------- attached mirrors

// An attached mirror's window title. The slot keeps two phones of the same
// model apart; PANEL_TITLE_RE is what the Hyprland rule matches.
function panelTitle(name, slot) {
  var n = Math.max(1, Math.min(MAX_ATTACHED, Math.round(Number(slot) || 1)))
  return "Android · " + titleSafe(name) + " · panel " + n
}

var PANEL_TITLE_RE = "^Android · .* · panel [1-9]$"
var PANEL_WORKSPACE = "special:omarchy-android"

// The Wayland app id an attached scrcpy window gets, through SDL3's
// SDL_APP_ID (scrcpy has no flag for it). The rule matches this rather than
// the title: Hyprland applies a rule once, when the window maps, and the id
// is fixed from the window's first frame.
var PANEL_APP_ID = "omarchy-android-panel"

// The app id of a detached ("window") mirror. Its rule only floats and
// centres it: tiled, Hyprland gave it a whole slot and scrcpy letterboxed the
// phone inside it; floating, scrcpy sizes the window to the phone's shape and
// keeps that shape when it is resized.
var WINDOW_APP_ID = "omarchy-android-window"

// Lua for `hyprctl eval`: the rules for this plugin's windows, by app id.
// First the rule every attached window gets as it maps.
// Floating, no border, rounding, shadow, blur, dim or animation, so it can sit
// exactly under the panel's hole; no initial focus; and out of sight on a
// special workspace until the panel shows it.
//
// focus_on_activate off: SDL asks for activation as it shows the window, and
// with the user's focus_on_activate on, Hyprland would focus it — which opens
// the special workspace it is on, dimming the screen behind it for half a
// second (dim_special) before the panel moves it. Kept in a global so running it
// again replaces it instead of stacking a second one. A runtime rule is lost
// whenever Hyprland reloads its config, so the service runs this again before
// every mirror start and after every reload. Then the detached windows' rule
// (WINDOW_APP_ID).
var PANEL_RULE_LUA =
  "if omarchy_android_panel_rule then omarchy_android_panel_rule:set_enabled(false) end; "
  + "omarchy_android_panel_rule = hl.window_rule({ match = { class = \"^" + PANEL_APP_ID + "$\" }, "
  + "float = true, border_size = 0, rounding = 0, no_shadow = true, no_anim = true, no_blur = true, "
  + "no_dim = true, opacity = \"1.0 override 1.0 override\", no_initial_focus = true, focus_on_activate = false, decorate = false, "
  + "workspace = \"" + PANEL_WORKSPACE + " silent\" }); "
  + "if omarchy_android_window_rule then omarchy_android_window_rule:set_enabled(false) end; "
  + "omarchy_android_window_rule = hl.window_rule({ match = { class = \"^" + WINDOW_APP_ID + "$\" }, "
  + "float = true, center = true })"

// Hyprland window addresses as Quickshell and hyprctl print them. Anything
// else is refused: these strings are spliced into Lua.
function hyprAddress(text) {
  var a = String(text || "")
  if (/^[0-9a-f]{1,16}$/.test(a)) a = "0x" + a
  return /^0x[0-9a-f]{1,16}$/.test(a) ? a : ""
}

function hyprInt(n) { return Math.round(Math.max(-100000, Math.min(100000, Number(n) || 0))) }

// The dispatches (each one `Hyprland.dispatch` argument) that put an
// attached window on a workspace at a rect, in layout pixels, pinned so it
// stays put if the user switches workspace with the panel open. Floating is
// set here too, in case the window mapped while the rule was missing.
//
// Sized and moved first, while still out of sight, and only then brought to
// the workspace: each dispatch is its own request and Hyprland draws in
// between, so the other order showed a new window for a moment where the
// rule had centred it, before it jumped into the panel. Empty when
// the address or workspace is not well formed.
function hyprShow(address, workspace, rect) {
  var a = hyprAddress(address)
  var ws = Math.round(Number(workspace))
  if (a === "" || !(ws > 0) || !rect || !(rect.w > 0) || !(rect.h > 0)) return []
  var w = "window = \"address:" + a + "\""
  return [
    "hl.dsp.window.float({ " + w + ", action = \"on\" })",
    "hl.dsp.window.resize({ " + w + ", x = " + hyprInt(rect.w) + ", y = " + hyprInt(rect.h) + " })",
    "hl.dsp.window.move({ " + w + ", x = " + hyprInt(rect.x) + ", y = " + hyprInt(rect.y) + " })",
    "hl.dsp.window.move({ " + w + ", workspace = \"" + ws + "\", follow = false })",
    "hl.dsp.window.pin({ " + w + ", action = \"on\" })"
  ]
}

// Switching a running mirror between the panel and its own window, without
// restarting scrcpy (which cut its audio and video for about a second and
// split a recording in two). The panel rule's look is undone or redone on the
// live window with set_prop: on Hyprland scrcpy draws no frame of its own, so
// the border, rounding and shadow are all Hyprland's. `deco` is the user's
// { border, rounding }, read from Hyprland so a detached mirror looks like
// any other window.
//
// To a window: decorated while still out of sight, then unpinned, moved to
// the workspace and centred. Empty when the address or workspace is bad.
//
// The size is left as it is: the window pops out at the size it had in the
// panel's tile.
function hyprDetach(address, workspace, deco) {
  var a = hyprAddress(address)
  var ws = Math.round(Number(workspace))
  if (a === "" || !(ws > 0)) return []
  var d = deco || ({})
  var border = Math.max(0, Math.min(50, Math.round(Number(d.border)))) || 0
  var rounding = Math.max(0, Math.min(100, Math.round(Number(d.rounding)))) || 0
  var w = "window = \"address:" + a + "\""
  var prop = function(name, value) { return "hl.dsp.window.set_prop({ " + w + ", prop = \"" + name + "\", value = \"" + value + "\" })" }
  return [
    prop("border_size", border), prop("rounding", rounding),
    prop("no_shadow", 0), prop("no_blur", 0), prop("no_anim", 0), prop("no_dim", 0),
    "hl.dsp.window.pin({ " + w + ", action = \"off\" })",
    "hl.dsp.window.move({ " + w + ", workspace = \"" + ws + "\", follow = false })",
    "hl.dsp.window.center({ " + w + " })"
  ]
}


// Into the panel: the panel rule's look, set on the live window (it may have
// been opened as a detached one, under the other rule), floating, and out of
// sight until the panel shows it (hyprShow).
function hyprAttach(address) {
  var a = hyprAddress(address)
  if (a === "") return []
  var w = "window = \"address:" + a + "\""
  var prop = function(name, value) { return "hl.dsp.window.set_prop({ " + w + ", prop = \"" + name + "\", value = \"" + value + "\" })" }
  return [
    prop("border_size", 0), prop("rounding", 0),
    prop("no_shadow", 1), prop("no_blur", 1), prop("no_anim", 1), prop("no_dim", 1),
    // Opaque, as the panel rule makes it: a window opened detached may be
    // under Omarchy's Glassy opacity, and an "opacity" override set here does
    // not beat that rule (tried), "opaque" does.
    prop("opaque", 1),
    "hl.dsp.window.float({ " + w + ", action = \"on\" })",
    "hl.dsp.window.move({ " + w + ", workspace = \"" + PANEL_WORKSPACE + "\", follow = false })"
  ]
}

// `hyprctl -j getoption general:border_size` then `decoration:rounding`, as
// one batch: two JSON objects in a row. The first two "int" values, in order.
function parseDeco(text) {
  var re = /"int"\s*:\s*(-?[0-9]+)/g
  var m1 = re.exec(String(text || ""))
  var m2 = m1 ? re.exec(String(text || "")) : null
  return { border: m1 ? Math.max(0, Number(m1[1])) : 2, rounding: m2 ? Math.max(0, Number(m2[1])) : 0 }
}

// Back out of sight. Unpinned first: a pinned window is on every workspace.
function hyprHide(address) {
  var a = hyprAddress(address)
  if (a === "") return []
  var w = "window = \"address:" + a + "\""
  return [
    "hl.dsp.window.pin({ " + w + ", action = \"off\" })",
    "hl.dsp.window.move({ " + w + ", workspace = \"" + PANEL_WORKSPACE + "\", follow = false })"
  ]
}

// Hyprland's `openwindow>>ADDRESS,WORKSPACE,CLASS,TITLE` and
// `windowtitlev2>>ADDRESS,TITLE` events, as { address, title }, or null for
// any other event or a malformed one. A title may itself contain commas, so
// only the leading fields are split off.
function parseWindowEvent(name, data) {
  var s = String(data || "")
  var fields = name === "openwindow" ? 3 : name === "windowtitlev2" ? 1 : -1
  if (fields < 0) return null
  var at = 0
  var parts = []
  for (var i = 0; i < fields; i++) {
    var comma = s.indexOf(",", at)
    if (comma < 0) return null
    parts.push(s.slice(at, comma))
    at = comma + 1
  }
  var address = hyprAddress(parts[0])
  return address === "" ? null : { address: address, title: s.slice(at) }
}

// A mirror in its own window, brought forward from the panel: focused, which
// switches to its workspace, and raised, since the rule floats it and other
// floating windows may cover it.
function hyprFocus(address) {
  var a = hyprAddress(address)
  if (a === "") return []
  var w = "window = \"address:" + a + "\""
  return [
    "hl.dsp.focus({ " + w + " })",
    "hl.dsp.window.alter_zorder({ mode = \"top\", " + w + " })"
  ]
}

// Width over height for a tile: the screen the phone reported, upright since
// that is how a phone is usually held, else a typical phone.
function screenAspect(screen) {
  if (screen && screen.w > 0 && screen.h > 0) return Math.min(screen.w, screen.h) / Math.max(screen.w, screen.h)
  return 9 / 20
}

// The height every tile gets so that the row of them fits: as tall as the
// room allows, then shorter if the tiles at that height would be too wide
// side by side. `aspects` is one width/height per tile; `extra` is the width
// that does not scale with the height (the button strips), all tiles
// together.
function fitTileHeight(aspects, maxWidth, maxHeight, gap, minHeight, extra) {
  var h = Math.max(0, maxHeight)
  var sum = 0
  for (var i = 0; i < aspects.length; i++) sum += aspects[i] > 0 ? aspects[i] : 9 / 20
  var room = maxWidth - gap * Math.max(0, aspects.length - 1) - Math.max(0, Number(extra) || 0)
  if (sum > 0 && h * sum > room) h = room / sum
  return Math.max(minHeight || 0, Math.floor(h))
}

// The keys the strip beside an attached tile can press: one `input
// keyevent` line for the persistent `adb shell`, from a fixed list. None of
// them changes a setting on the phone.
var INPUT_KEYS = {
  back: "KEYCODE_BACK", home: "KEYCODE_HOME", recents: "KEYCODE_APP_SWITCH",
  notifications: "KEYCODE_NOTIFICATION", volumeUp: "KEYCODE_VOLUME_UP",
  volumeDown: "KEYCODE_VOLUME_DOWN", power: "KEYCODE_POWER"
}

// The rail joined to an attached tile's right edge, in three groups spread
// down its height: navigation at the top, sound and notifications in the
// middle, power and the screenshot at the bottom. Icons are Material Design
// glyphs from the Nerd Font the shell uses. Every key but "screenshot" is in
// INPUT_KEYS; the screenshot goes to ~/Pictures/omarchy-android-manager like ^s.
var MIRROR_ACTIONS = [
  { key: "back", group: 0, icon: "\u{F004D}", label: "Back" },
  { key: "home", group: 0, icon: "\u{F02DC}", label: "Home" },
  { key: "recents", group: 0, icon: "\u{F0763}", label: "Recent apps" },
  { key: "notifications", group: 1, icon: "\u{F009C}", label: "Notifications" },
  { key: "volumeUp", group: 1, icon: "\u{F075D}", label: "Volume up" },
  { key: "volumeDown", group: 1, icon: "\u{F075E}", label: "Volume down" },
  { key: "power", group: 2, icon: "\u{F0425}", label: "Power: lock or wake" },
  { key: "screenshot", group: 2, icon: "\u{F0D5D}", label: "Screenshot to ~/Pictures/omarchy-android-manager" }
]

function mirrorActions(group) {
  return MIRROR_ACTIONS.filter(function(a) { return a.group === group })
}

function keyInput(name) {
  return INPUT_KEYS[name] ? "input keyevent " + INPUT_KEYS[name] : ""
}

// ---------------------------------------------------------------- cursor

function moveIndex(index, delta, count) {
  if (count <= 0) return 0
  return Math.max(0, Math.min(count - 1, index + delta))
}

function clampIndex(index, count) {
  if (count <= 0) return 0
  return Math.max(0, Math.min(count - 1, index))
}

function filterRows(rows, text) {
  var q = String(text || "").toLowerCase()
  if (q === "") return rows
  return rows.filter(function(r) {
    return r.name.toLowerCase().indexOf(q) !== -1 || r.key.toLowerCase().indexOf(q) !== -1
      || (r.address && r.address.indexOf(q) !== -1)
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    STATE_READY: STATE_READY, STATE_MIRRORING: STATE_MIRRORING, STATE_UNAUTHORIZED: STATE_UNAUTHORIZED,
    STATE_OFFLINE: STATE_OFFLINE, STATE_REMEMBERED: STATE_REMEMBERED, MARKS: MARKS,
    DEFAULT_PORT: DEFAULT_PORT, MAX_ATTACHED: MAX_ATTACHED, OPTION_SPECS: OPTION_SPECS, DEFAULT_OPTIONS: DEFAULT_OPTIONS,
    WIFI_STEPS: WIFI_STEPS,
    plainLabel: plainLabel, titleSafe: titleSafe, validPort: validPort, validHost: validHost,
    parseAddress: parseAddress, validDeviceId: validDeviceId, parseDeviceLine: parseDeviceLine,
    parseProbe: parseProbe, parseScan: parseScan, buildRows: buildRows, markFor: markFor,
    rowSubtitle: rowSubtitle, rowStatus: rowStatus, rowMeta: rowMeta, infoRows: infoRows,
    normalizeOptions: normalizeOptions, optionValue: optionValue, stepOption: stepOption,
    scrcpyArgs: scrcpyArgs, commandPreview: commandPreview, parseConnect: parseConnect,
    parsePair: parsePair, parseMdns: parseMdns, parseWifi: parseWifi, parseStore: parseStore,
    serializeStore: serializeStore, rememberDevice: rememberDevice, forgetDevice: forgetDevice,
    utf8Length: utf8Length, moveIndex: moveIndex, clampIndex: clampIndex, filterRows: filterRows,
    screenAspect: screenAspect, fitTileHeight: fitTileHeight, INPUT_KEYS: INPUT_KEYS, keyInput: keyInput,
    MIRROR_ACTIONS: MIRROR_ACTIONS, mirrorActions: mirrorActions,
    panelTitle: panelTitle, PANEL_TITLE_RE: PANEL_TITLE_RE, PANEL_WORKSPACE: PANEL_WORKSPACE, PANEL_APP_ID: PANEL_APP_ID,
    WINDOW_APP_ID: WINDOW_APP_ID,
    PANEL_RULE_LUA: PANEL_RULE_LUA,
    hyprAddress: hyprAddress, parseWindowEvent: parseWindowEvent, hyprShow: hyprShow, hyprDetach: hyprDetach, hyprAttach: hyprAttach, parseDeco: parseDeco, hyprHide: hyprHide, hyprFocus: hyprFocus,
    parseLockState: parseLockState, parseUnlock: parseUnlock, screenKeys: screenKeys
  }
}
