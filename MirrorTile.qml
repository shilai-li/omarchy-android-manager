import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons

// One attached mirror's place in the panel: a hole the phone's own scrcpy
// window is moved under.
//
// The window is a real scrcpy window (borderless, floated by the service's
// Hyprland rule), so the mouse, keyboard and clipboard are scrcpy's own and
// behave exactly as when detached. While this tile is shown it tells the
// service where it is on screen, in Hyprland layout pixels, and the service
// moves the window there. Once the window is there, the panel cuts this tile
// out of its input mask and its painted background (setHole), so the window
// shows through and gets the clicks.
//
// Sending the window back out of sight is the panel's job, not this tile's:
// the Mirrors row rebuilds its tiles whenever the mirror list changes, so a
// tile being destroyed says nothing about whether the panel is still open.
//
// Placement is re-checked a few times a second while shown: the panel's
// width follows the tiles, and its position follows the bar.
Item {
  id: tile

  property var service: null
  property var panel: null
  property string deviceKey: ""
  property var mirror: null
  property bool shown: false
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  readonly property bool attached: !!mirror && mirror.mode === "attached"
  readonly property bool placed: tile.attached && !!mirror.shown

  function place() {
    if (!tile.service || !tile.attached || !tile.shown) return
    var win = tile.QsWindow.window
    var monitor = win && win.screen ? Hyprland.monitorFor(win.screen) : null
    if (!monitor || !monitor.activeWorkspace || tile.width <= 0 || tile.height <= 0) return
    var p = tile.mapToItem(null, 0, 0)
    tile.service.showWindow(tile.deviceKey, {
      x: monitor.x + p.x, y: monitor.y + p.y, w: tile.width, h: tile.height
    }, monitor.activeWorkspace.id)
  }

  function syncHole() {
    if (tile.panel) tile.panel.setHole(tile, tile.placed && tile.shown)
  }

  // Deferred: these fire while the panel's bindings are being updated, and
  // placing changes the service's mirror list those bindings read.
  onShownChanged: Qt.callLater(tile.place)
  onPlacedChanged: Qt.callLater(tile.syncHole)
  onPanelChanged: Qt.callLater(tile.syncHole)
  Component.onCompleted: Qt.callLater(tile.syncHole)
  Component.onDestruction: if (tile.panel) tile.panel.setHole(tile, false)

  Timer {
    interval: 200
    repeat: true
    triggeredOnStart: true
    running: tile.shown && tile.attached
    onTriggered: tile.place()
  }

  Text {
    anchors.centerIn: parent
    visible: !tile.placed
    textFormat: Text.PlainText
    text: "starting…"
    color: Qt.darker(tile.foreground, 2.0)
    font.family: tile.fontFamily
    font.pixelSize: Style.font.caption
  }
}
