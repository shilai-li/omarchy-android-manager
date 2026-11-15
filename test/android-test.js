// Run with: bash test/test.sh
//
// The fixtures are the shapes adb, dumpsys and the phone actually print.
const { check, eq, ok, report } = require("./harness.js")
const A = require("../Android.js")

// What bin/scan.sh prints with a phone on USB and Wi-Fi at once, a tablet on
// Wi-Fi only, and a phone that has not been authorized yet.
const SCAN = [
  "T adb 37.0.0-14910828",
  "T scrcpy 5.0.1",
  "D 37211FDJH0019C         device usb:1-2 product:husky model:Pixel_8_Pro device:husky transport_id:3",
  "D 192.168.10.37:5555     device product:husky model:Pixel_8_Pro device:husky transport_id:6",
  "D 192.168.10.42:5555     device product:gts9wifi model:SM_X710 device:gts9wifi transport_id:4",
  "D R58N12ABCDE            unauthorized usb:1-1 transport_id:5",
  "P 37211FDJH0019C model=Pixel 8 Pro",
  "P 37211FDJH0019C manufacturer=Google",
  "P 37211FDJH0019C serialno=37211FDJH0019C",
  "P 37211FDJH0019C release=16",
  "P 37211FDJH0019C sdk=36",
  "P 37211FDJH0019C @battery",
  "P 37211FDJH0019C Current Battery Service state:",
  "P 37211FDJH0019C   AC powered: false",
  "P 37211FDJH0019C   USB powered: true",
  "P 37211FDJH0019C   status: 2",
  "P 37211FDJH0019C   level: 82",
  "P 37211FDJH0019C @ip",
  "P 37211FDJH0019C 30: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500",
  "P 37211FDJH0019C     inet 192.168.10.37/24 brd 192.168.10.255 scope global wlan0",
  "P 37211FDJH0019C @wm",
  "P 37211FDJH0019C Physical size: 1344x2992",
  "P 37211FDJH0019C @df",
  "P 37211FDJH0019C /dev/block/dm-50 121226628 63962512 57133044  53% /data",
  "P 192.168.10.37:5555 model=Pixel 8 Pro",
  "P 192.168.10.37:5555 serialno=37211FDJH0019C",
  "P 192.168.10.42:5555 model=SM-X710",
  "P 192.168.10.42:5555 manufacturer=samsung",
  "P 192.168.10.42:5555 serialno=R52W70ABCDE",
  "P 192.168.10.42:5555 release=15",
  "P 192.168.10.42:5555 @battery",
  "P 192.168.10.42:5555   level: 64",
  "P 192.168.10.42:5555   status: 3",
  ""
].join("\n")

check("parseScan reads tools and every device", () => {
  const s = A.parseScan(SCAN)
  eq(s.tools, { adb: "37.0.0-14910828", scrcpy: "5.0.1" })
  eq(s.devices.map(d => [d.id, d.state, d.transport]), [
    ["37211FDJH0019C", "device", "usb"],
    ["192.168.10.37:5555", "device", "wifi"],
    ["192.168.10.42:5555", "device", "wifi"],
    ["R58N12ABCDE", "unauthorized", "usb"]
  ])
})

check("parseProbe reads getprops, battery, ip, screen and storage", () => {
  const info = A.parseScan(SCAN).devices[0].info
  eq(info.model, "Pixel 8 Pro")
  eq(info.release, "16")
  eq(info.battery, { level: 82, charging: true, full: false, plugged: true })
  eq(info.ip, "192.168.10.37")
  eq(info.screen, { w: 1344, h: 2992 })
  eq(info.storage, { totalKb: 121226628, usedKb: 63962512 })
})

check("an override size wins over the physical one", () => {
  const info = A.parseProbe(["@wm", "Physical size: 1080x2400", "Override size: 720x1600"])
  eq(info.screen, { w: 720, h: 1600 })
})

check("one phone on USB and Wi-Fi is one row, driven over USB", () => {
  const rows = A.buildRows(A.parseScan(SCAN), {}, {})
  const pixel = rows.find(r => r.key === "37211FDJH0019C")
  eq(pixel.transports.length, 2)
  eq(pixel.target, "37211FDJH0019C", "USB is preferred")
  eq(pixel.address, "192.168.10.37:5555")
  eq(pixel.state, "ready")
  eq(A.rowSubtitle(pixel), "usb + wi-fi · 192.168.10.37:5555 · Android 16")
  eq(rows.length, 3)
})

check("an unauthorized phone stands on its own id and says what to do", () => {
  const rows = A.buildRows(A.parseScan(SCAN), {}, {})
  const r = rows.find(x => x.key === "R58N12ABCDE")
  eq(r.state, "unauthorized")
  eq(r.target, "")
  eq(A.markFor(r.state), "◐")
  eq(A.rowMeta(r), "tap Allow on the phone")
  eq(rows[rows.length - 1].key, "R58N12ABCDE", "sorted after the usable ones")
})

check("a remembered phone that adb does not list is still a row", () => {
  const store = { "AAA111": { name: "Pixel 6a", address: "192.168.10.51:5555", options: {} } }
  const rows = A.buildRows(A.parseScan(SCAN), store, {})
  const r = rows.find(x => x.key === "AAA111")
  eq(r.state, "remembered")
  eq(r.name, "Pixel 6a")
  eq(A.rowSubtitle(r), "wi-fi · 192.168.10.51:5555 · remembered")
  eq(A.rowMeta(r), "rebooted? plug in once")
})

check("a running mirror marks its row", () => {
  const rows = A.buildRows(A.parseScan(SCAN), {}, { "37211FDJH0019C": { mode: "window" } })
  const r = rows.find(x => x.key === "37211FDJH0019C")
  eq(r.state, "mirroring")
  eq(A.rowStatus(r), "Mirroring · window")
  eq(A.rowMeta(r), "1080p · 60 fps · 82%")
})

check("states keep distinct marks without color", () => {
  const marks = ["ready", "unauthorized", "offline"].map(A.markFor)
  eq(new Set(marks).size, 3)
})

check("plainLabel strips controls and bidi overrides and caps length", () => {
  eq(A.plainLabel("Pixel‮8\n"), "Pixel8")
  eq(A.plainLabel("x".repeat(100), 10).length, 10)
})

check("titleSafe keeps a window title to a plain alphabet", () => {
  eq(A.titleSafe("Pixel 8 Pro"), "Pixel 8 Pro")
  eq(A.titleSafe("a;$(rm)`b`"), "a(rm)b")
  eq(A.titleSafe(""), "device")
})

check("parseAddress defaults to port 5555 and refuses junk", () => {
  eq(A.parseAddress("192.168.10.37").text, "192.168.10.37:5555")
  eq(A.parseAddress(" 192.168.10.37 : 41235 ").text, "192.168.10.37:41235")
  eq(A.parseAddress("phone.lan:5555").text, "phone.lan:5555")
  eq(A.parseAddress("999.1.1.1"), null)
  eq(A.parseAddress("-oProxy:5555"), null)
  eq(A.parseAddress("1.2.3.4:70000"), null)
  eq(A.parseAddress(""), null)
})

check("validDeviceId accepts serials, ip:port and mDNS names, nothing else", () => {
  ok(A.validDeviceId("37211FDJH0019C"))
  ok(A.validDeviceId("192.168.10.37:5555"))
  ok(A.validDeviceId("adb-37211FDJH0019C-AbCdEf._adb-tls-connect._tcp"))
  ok(!A.validDeviceId("-s"))
  ok(!A.validDeviceId("a b"))
  ok(!A.validDeviceId("a;b"))
})

check("scrcpyArgs builds a window mirror from the defaults", () => {
  eq(A.scrcpyArgs(null, "window", { title: "Pixel 8 Pro" }), [
    "--max-size=1080", "--video-bit-rate=8M", "--max-fps=60", "--stay-awake",
    "--turn-screen-off", "--window-title=Android · Pixel 8 Pro"
  ])
})

check("scrcpyArgs builds an attached mirror as a borderless panel window", () => {
  const o = A.normalizeOptions({ audio: false, maxSize: 0, screenOff: true })
  eq(A.scrcpyArgs(o, "attached", { title: "Pixel 8 Pro", slot: 2 }), [
    "--video-bit-rate=8M", "--max-fps=60", "--no-audio", "--stay-awake", "--turn-screen-off",
    "--window-borderless", "--window-title=Android · Pixel 8 Pro · panel 2"
  ])
})

check("an attached mirror can record too: it is a real scrcpy window", () => {
  const o = A.normalizeOptions({ record: true })
  const args = A.scrcpyArgs(o, "attached", { title: "x", slot: 1, recordPath: "/home/u/Videos/x.mp4" })
  ok(args.indexOf("--record=/home/u/Videos/x.mp4") !== -1)
})

check("panel titles match the rule, and only panel titles do", () => {
  const re = new RegExp(A.PANEL_TITLE_RE)
  ok(re.test(A.panelTitle("Pixel 8 Pro", 3)))
  ok(re.test(A.panelTitle("a\u202e(b)", 1)), "title-safe name")
  ok(!re.test("Android · Pixel 8 Pro"), "a detached window is left alone")
  eq(A.panelTitle("x", 99), "Android · x · panel " + A.MAX_ATTACHED)
  ok(A.PANEL_RULE_LUA.indexOf('class = "^' + A.PANEL_APP_ID + '$"') !== -1, "the rule matches the app id")
  ok(A.PANEL_RULE_LUA.indexOf('class = "^' + A.WINDOW_APP_ID + '$" }, float = true, center = true') !== -1, "detached windows float")
})

check("recording needs both the option and a path", () => {
  const o = A.normalizeOptions({ record: true })
  ok(A.scrcpyArgs(o, "window", {}).every(a => a.indexOf("--record") !== 0))
  ok(A.scrcpyArgs(o, "window", { recordPath: "/home/u/Videos/x.mp4" }).indexOf("--record=/home/u/Videos/x.mp4") !== -1)
})

check("normalizeOptions drops values that are not on the menu", () => {
  eq(A.normalizeOptions({ maxSize: 99999, bitRate: "8M; rm", audio: "yes" }), A.DEFAULT_OPTIONS)
})

check("stepOption flips toggles and cycles choices both ways", () => {
  const o = A.normalizeOptions(null)
  eq(A.stepOption(o, "audio").audio, false)
  eq(A.stepOption(o, "maxSize", 1).maxSize, 1440)
  eq(A.stepOption(o, "maxSize", -1).maxSize, 720)
  eq(A.stepOption(A.normalizeOptions({ maxSize: 0 }), "maxSize", 1).maxSize, 720, "wraps")
})

check("commandPreview shows the device and quotes the title", () => {
  const rows = A.buildRows(A.parseScan(SCAN), {}, {})
  const r = rows.find(x => x.key === "37211FDJH0019C")
  eq(A.commandPreview(r, "window", { title: r.name }),
     '$ scrcpy -s 37211FDJH0019C --max-size=1080 --video-bit-rate=8M --max-fps=60 --stay-awake --turn-screen-off --window-title="Android · Pixel 8 Pro"')
})

check("parseConnect reads adb's words, not its exit status", () => {
  eq(A.parseConnect("connected to 192.168.10.37:5555\n").ok, true)
  eq(A.parseConnect("already connected to 192.168.10.37:5555").already, true)
  const bad = A.parseConnect("failed to connect to '192.168.10.9:5555': Connection refused\n")
  eq(bad.ok, false)
  eq(bad.message, "failed to connect to '192.168.10.9:5555': Connection refused")
  eq(A.parseConnect("").message, "adb did not answer")
})

check("parsePair", () => {
  eq(A.parsePair("Enter pairing code: Successfully paired to 192.168.10.37:41235 [guid=adb-x]").ok, true)
  const bad = A.parsePair("Enter pairing code: \nFailed: Wrong password or connection was dropped.")
  eq(bad.ok, false)
  eq(bad.message, "Failed: Wrong password or connection was dropped.")
})

check("parseMdns keeps adb's pairing and connect services", () => {
  const list = A.parseMdns([
    "List of discovered mdns services",
    "adb-37211FDJH0019C-AbCdEf\t_adb-tls-pairing._tcp\t192.168.10.37:41235",
    "adb-37211FDJH0019C-AbCdEf\t_adb-tls-connect._tcp\t192.168.10.37:39823",
    "something\t_http._tcp\t192.168.10.1:80"
  ].join("\n"))
  eq(list, [
    { name: "adb-37211FDJH0019C-AbCdEf", kind: "pairing", address: "192.168.10.37:41235" },
    { name: "adb-37211FDJH0019C-AbCdEf", kind: "connect", address: "192.168.10.37:39823" }
  ])
})

check("parseWifi follows the steps as they arrive", () => {
  const steps = A.parseWifi("STEP 0 ok 37211FDJH0019C\nSTEP 1 ok 192.168.10.37\nSTEP 2 run restarting adbd\n")
  eq(steps.map(s => s.status), ["ok", "ok", "run", "wait"])
  eq(steps[1].detail, "192.168.10.37")
})

check("the store survives a round trip and refuses junk", () => {
  let s = A.rememberDevice({}, "37211FDJH0019C", { name: "Pixel 8 Pro", address: "192.168.10.37:5555", connected: true, mirror: "attached" })
  s = A.rememberDevice(s, "37211FDJH0019C", { options: A.stepOption(A.normalizeOptions(null), "audio") })
  const back = A.parseStore(A.serializeStore(s))
  eq(back["37211FDJH0019C"].address, "192.168.10.37:5555")
  eq(back["37211FDJH0019C"].options.audio, false)
  eq(back["37211FDJH0019C"].connected, true)
  eq(back["37211FDJH0019C"].mirror, "attached")
  eq(A.parseStore("not json"), {})
  eq(A.parseStore('{"devices":{"a b":{},"ok":{"address":"; rm -rf ~","name":7}}}'),
     { ok: { name: "", address: "", options: A.DEFAULT_OPTIONS, connected: false, mirror: "" } })
  eq(Object.keys(A.forgetDevice(back, "37211FDJH0019C")), [])

  let disconnected = A.rememberDevice(back, "37211FDJH0019C", { connected: false, mirror: "" })
  eq(disconnected["37211FDJH0019C"].connected, false)
  eq(disconnected["37211FDJH0019C"].mirror, "")

  const rows = A.buildRows(A.parseScan(SCAN), back, {})
  const pixel = rows.find(r => r.key === "37211FDJH0019C")
  eq(pixel.connected, true)
  eq(pixel.savedMirror, "attached")
})

check("utf8Length counts bytes, as Qt writes them", () => {
  eq(A.utf8Length("a·b"), 4)
  eq(A.utf8Length("😀"), 4)
})

check("filterRows matches name, serial and address", () => {
  const rows = A.buildRows(A.parseScan(SCAN), {}, {})
  eq(A.filterRows(rows, "pixel").length, 1)
  eq(A.filterRows(rows, "r52w").length, 1)
  eq(A.filterRows(rows, "10.42").length, 1)
  eq(A.filterRows(rows, "").length, 3)
})

check("screenAspect holds the phone upright, else a typical phone", () => {
  eq(A.screenAspect({ w: 2400, h: 1080 }), 1080 / 2400)
  eq(A.screenAspect({ w: 1080, h: 2400 }), 1080 / 2400)
  eq(A.screenAspect(null), 9 / 20)
})

check("fitTileHeight fills the height, and shrinks when the row is too wide", () => {
  // One phone: the full height.
  eq(A.fitTileHeight([0.45], 1500, 800, 20, 200), 800)
  // Three phones and a rotated one would be 0.45*3+2.2 = 3.55 heights wide.
  eq(A.fitTileHeight([0.45, 0.45, 0.45, 2.2], 1500, 800, 20, 200), Math.floor((1500 - 60) / 3.55))
  // Never below the floor.
  eq(A.fitTileHeight([5, 5, 5], 300, 800, 20, 200), 200)
  // Fixed-width strips come out of the room before the tiles scale.
  eq(A.fitTileHeight([1, 1], 1000, 800, 20, 100, 80), Math.floor((1000 - 20 - 80) / 2))
})

check("hyprShow places by validated address, workspace and whole pixels", () => {
  eq(A.hyprShow("557b53f84270", 1, { x: 100.4, y: 120, w: 300, h: 650 }), [
    'hl.dsp.window.float({ window = "address:0x557b53f84270", action = "on" })',
    'hl.dsp.window.resize({ window = "address:0x557b53f84270", x = 300, y = 650 })',
    'hl.dsp.window.move({ window = "address:0x557b53f84270", x = 100, y = 120 })',
    'hl.dsp.window.move({ window = "address:0x557b53f84270", workspace = "1", follow = false })',
    'hl.dsp.window.pin({ window = "address:0x557b53f84270", action = "on" })'
  ])
  eq(A.hyprShow('0x1" }) os.execute("id', 1, { x: 0, y: 0, w: 1, h: 1 }), [], "not an address")
  eq(A.hyprShow("0x1", 0, { x: 0, y: 0, w: 1, h: 1 }), [], "no workspace")
  eq(A.hyprShow("0x1", 1, { x: 0, y: 0, w: 0, h: 1 }), [], "no size")
  eq(A.hyprHide("0xabc").length, 2)
  eq(A.hyprHide("nope"), [])
  eq(A.hyprFocus("0xabc"), [
    'hl.dsp.focus({ window = "address:0xabc" })',
    'hl.dsp.window.alter_zorder({ mode = "top", window = "address:0xabc" })'
  ])
  eq(A.hyprFocus('0x1" })'), [], "not an address")
})

check("keyInput sends only the strip's keys", () => {
  eq(A.keyInput("back"), "input keyevent KEYCODE_BACK")
  eq(A.keyInput("volumeUp"), "input keyevent KEYCODE_VOLUME_UP")
  eq(A.keyInput("reboot"), "")
})

check("every rail action is a known key or the screenshot, in one of three groups", () => {
  for (const a of A.MIRROR_ACTIONS) ok(a.key === "screenshot" || A.INPUT_KEYS[a.key], a.key)
  eq([0, 1, 2].map(g => A.mirrorActions(g).length), [3, 3, 2])
})

check("parseLockState reads the keyguard and wakefulness, and nothing else", () => {
  eq(A.parseLockState("isKeyguardShowing=true\nmWakefulness=Dozing\n"), { locked: true, awake: false })
  eq(A.parseLockState("isKeyguardShowing=false\r\nmWakefulness=Awake"), { locked: false, awake: true })
  eq(A.parseLockState("E not a device id"), { locked: null, awake: null })
  eq(A.parseLockState("isKeyguardShowing=false mWakefulness=Asleep"), { locked: false, awake: false }, "one line, as the watcher prints")
  eq(A.parseLockState(" mWakefulness=Awake"), { locked: null, awake: true }, "keyguard missing")
})

check("a locked phone's screen-off waits; screenKeys press Alt+O or Alt+Shift+O in one window", () => {
  const o = A.normalizeOptions({ screenOff: true })
  ok(A.scrcpyArgs(o, "window", { title: "x" }).indexOf("--turn-screen-off") !== -1)
  ok(A.scrcpyArgs(o, "window", { title: "x", deferScreenOff: true }).indexOf("--turn-screen-off") === -1)
  const off = A.screenKeys("557b54b44cb0", false)
  eq(off.length, 2)
  ok(/mods = "ALT", key = "o", state = "down", window = "address:0x557b54b44cb0"/.test(off[0]), off[0])
  ok(/state = "up"/.test(off[1]))
  ok(/mods = "ALT SHIFT", key = "o"/.test(A.screenKeys("abc", true)[0]))
  eq(A.screenKeys("nope", false), [])
})

check("parseUnlock says whether the phone is still locked", () => {
  eq(A.parseUnlock("woke\ndismissed\nmenu\nlocked\n"), { woke: true, dismissed: true, locked: true })
  eq(A.parseUnlock("woke\ndismissed\n"), { woke: true, dismissed: true, locked: false })
  eq(A.parseUnlock(""), { woke: false, dismissed: false, locked: false })
  eq(A.parseUnlock("E not a device id"), { woke: false, dismissed: false, locked: false })
})

check("parseWindowEvent reads openwindow and windowtitlev2, commas in titles included", () => {
  eq(A.parseWindowEvent("openwindow", "557b53f84270,special:omarchy-android,omarchy-android-panel,Android · Pixel, 8 · panel 1"),
     { address: "0x557b53f84270", title: "Android · Pixel, 8 · panel 1" })
  eq(A.parseWindowEvent("windowtitlev2", "abc,Android · V2025A"), { address: "0xabc", title: "Android · V2025A" })
  eq(A.parseWindowEvent("openwindow", "abc,1"), null, "too few fields")
  eq(A.parseWindowEvent("openwindow", "zz\" }),1,c,t"), null, "not an address")
  eq(A.parseWindowEvent("closewindow", "abc"), null)
})

check("hyprDetach / hyprAttach re-decorate a live window by validated address", () => {
  const d = A.hyprDetach("557b53f84270", 3, { border: 2, rounding: 6 })
  ok(d.some(x => /prop = "border_size", value = "2"/.test(x)), "border back")
  ok(d.some(x => /prop = "rounding", value = "6"/.test(x)), "rounding back")
  ok(d.indexOf('hl.dsp.window.pin({ window = "address:0x557b53f84270", action = "off" })') !== -1)
  ok(d.some(x => /workspace = "3", follow = false/.test(x)))
  ok(d.findIndex(x => /set_prop/.test(x)) < d.findIndex(x => /workspace = "3"/.test(x)), "decorated before it is shown")
  eq(A.hyprDetach('0x1" }) os.execute("id', 1, {}), [], "not an address")
  eq(A.hyprDetach("0x1", 0, {}), [], "no workspace")
  ok(A.hyprDetach("0x1", 1, { border: "2; x", rounding: -4 }).some(x => /border_size", value = "0"/.test(x)), "junk is 0")
  const at = A.hyprAttach("0xabc")
  ok(at.some(x => /border_size", value = "0"/.test(x)) && at[at.length - 1].indexOf(A.PANEL_WORKSPACE) !== -1)
  eq(A.hyprAttach("nope"), [])
})

check("parseDeco reads border and rounding from a getoption batch", () => {
  eq(A.parseDeco('{"option":"general:border_size","int":2,"set":true}{"option":"decoration:rounding","int":6,"set":true}'), { border: 2, rounding: 6 })
  eq(A.parseDeco(""), { border: 2, rounding: 0 })
})

check("a detached window keeps its size: no resize on the way out", () => {
  ok(!A.hyprDetach("0xabc", 1, { border: 2, rounding: 6 }).some(x => /window.resize/.test(x)))
})

report("android")
