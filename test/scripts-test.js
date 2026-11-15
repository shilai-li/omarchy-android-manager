// Run with: bash test/test.sh
//
// The helpers are the plugin's only contact with adb, scrcpy and the disk, so
// they are run for real — but only along paths that need no phone: argument
// checks that must refuse before anything starts, and the store against a
// throwaway XDG_STATE_HOME.
const { check, eq, ok, report } = require("./harness.js")
const { spawnSync } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")
const A = require("../Android.js")

const BIN = path.join(__dirname, "..", "bin")

function run(script, args, env, input) {
  const r = spawnSync("bash", [path.join(BIN, script)].concat(args), {
    encoding: "utf8",
    timeout: 20000,
    input: input === undefined ? "" : input,
    env: Object.assign({}, process.env, env || {})
  })
  return { out: r.stdout, err: r.stderr, code: r.status }
}

function sandbox() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "android-manager-test-"))
}

check("mirror.sh refuses a bad device id before starting anything", () => {
  const r = run("mirror.sh", ["-s"])
  eq(r.code, 1)
  ok(/not a device id/.test(r.out), r.out)
})

check("mirror.sh refuses options that are not on its list", () => {
  for (const bad of ["--shortcut-mod=lsuper", "--max-size=1080;id", "--window-title=Android · a\\b",
                     "--window-title=x", "--v4l2-sink=/dev/null", "--record=/etc/passwd.mp4",
                     "--record-format=mp4", "--no-window", "--window-title=Android · x · panel 0"]) {
    const r = run("mirror.sh", ["37211FDJH0019C", bad])
    eq(r.code, 1, bad)
  }
})

check("mirror.sh accepts what scrcpyArgs builds (refusal would come first)", () => {
  // Every arg passes the checks, so the only way left to fail is scrcpy not
  // finding the device — not an argument refusal.
  const args = A.scrcpyArgs(A.normalizeOptions({ audio: false, screenOff: true }), "window", { title: "Pixel 8 Pro" })
  const r = run("mirror.sh", ["NO-SUCH-DEVICE-0000"].concat(args))
  ok(!/unexpected scrcpy option|refusing/.test(r.out), r.out)
})

check("mirror.sh accepts an attached mirror's panel window", () => {
  const args = A.scrcpyArgs(null, "attached", { title: "Pixel 8 Pro", slot: 3 })
  const r = run("mirror.sh", ["NO-SUCH-DEVICE-0000"].concat(args))
  ok(!/unexpected scrcpy option|refusing/.test(r.out), r.out)
})

check("mirror.sh refuses a second recording", () => {
  const r = run("mirror.sh", ["37211FDJH0019C", "--record=/home/a.mp4", "--record=/home/b.mp4"])
  eq(r.code, 1)
  ok(/second --record|refusing/.test(r.out), r.out)
})

check("connect.sh refuses what is not host:port", () => {
  for (const bad of ["192.168.1.5", "-oX:5555", "1.2.3.4:0", "a b:5555", "1.2.3.999:5555"]) {
    const r = run("connect.sh", ["connect", bad])
    eq(r.code, 1, bad)
    ok(/not an address/.test(r.out), bad + " → " + r.out)
  }
})

check("connect.sh pair wants the code on stdin, as digits", () => {
  const r = run("connect.sh", ["pair", "192.0.2.1:41235"], {}, "12ab56\n")
  eq(r.code, 1)
  ok(/6 digits/.test(r.out), r.out)
})

check("wifi.sh refuses a bad port or address before touching adb", () => {
  ok(/not a port/.test(run("wifi.sh", ["37211FDJH0019C", "99999"]).out))
  ok(/not an address/.test(run("wifi.sh", ["37211FDJH0019C", "5555", "1.2.3.4;id"]).out))
})

check("screenshot.sh refuses a file stem with a path in it", () => {
  ok(/not a file name/.test(run("screenshot.sh", ["37211FDJH0019C", "../x"]).out))
})

check("mirror.sh no longer sends unlock keys itself", () => {
  ok(!/keyevent|dismiss-keyguard/.test(fs.readFileSync(path.join(BIN, "mirror.sh"), "utf8")))
})

check("unlock.sh refuses a bad device id before touching adb", () => {
  ok(/not a device id/.test(run("unlock.sh", ["-s"]).out))
})

check("lockstate.sh refuses a bad device id before touching adb", () => {
  const r = run("lockstate.sh", ["-s"])
  eq(r.code, 1)
  ok(/not a device id/.test(r.out), r.out)
})

check("store.sh round-trips, creates its directory, and writes 0600", () => {
  const dir = sandbox()
  const env = { XDG_STATE_HOME: path.join(dir, "state") }
  eq(run("store.sh", ["read"], env).out, "", "nothing yet")

  const text = A.serializeStore(A.rememberDevice({}, "37211FDJH0019C", { name: "Pixel · 8", address: "192.168.10.37:5555" }))
  const w = run("store.sh", ["write"], env, A.utf8Length(text) + "\n" + text)
  eq(w.out, "ok\n", w.out + w.err)

  const file = path.join(dir, "state", "omarchy-android-manager", "devices.json")
  eq((fs.statSync(file).mode & 0o777).toString(8), "600")
  eq(run("store.sh", ["read"], env).out, text)
  fs.rmSync(dir, { recursive: true, force: true })
})

check("store.sh refuses a short write and leaves the old file", () => {
  const dir = sandbox()
  const env = { XDG_STATE_HOME: dir }
  run("store.sh", ["write"], env, "3\nold")
  const r = run("store.sh", ["write"], env, "10\nnew")
  eq(r.code, 1)
  eq(run("store.sh", ["read"], env).out, "old")
  fs.rmSync(dir, { recursive: true, force: true })
})

check("store.sh will not read or write through a symlink", () => {
  const dir = sandbox()
  fs.mkdirSync(path.join(dir, "real"))
  fs.symlinkSync(path.join(dir, "real"), path.join(dir, "omarchy-android-manager"))
  const env = { XDG_STATE_HOME: dir }
  eq(run("store.sh", ["write"], env, "2\n{}").code, 1)
  eq(run("store.sh", ["read"], env).code, 1)
  eq(fs.readdirSync(path.join(dir, "real")).length, 0)
  fs.rmSync(dir, { recursive: true, force: true })
})

check("scan.sh reads versions only when asked", () => {
  const plain = A.parseScan(run("scan.sh", []).out)
  eq(plain.tools, { adb: "", scrcpy: "" }, "no versions on an ordinary scan")
})

check("helpers leave no stray process behind", () => {
  const { execSync } = require("child_process")
  const count = () => Number(execSync("ps -eo args= | grep -cE '^sleep (6|8|12|20)$' || true").toString().trim())
  const before = count()
  run("lockstate.sh", ["-s"]); run("unlock.sh", ["NO-SUCH-DEVICE-0000"]); run("scan.sh", ["versions"])
  eq(count(), before)
})

check("scan.sh runs with no phone attached and reports its tools", () => {
  const r = run("scan.sh", ["versions"])
  eq(r.code, 0, r.err)
  const s = A.parseScan(r.out)
  ok(s.tools.adb !== "", "adb reported")
  ok(s.tools.scrcpy !== "", "scrcpy reported")
})

report("scripts")
