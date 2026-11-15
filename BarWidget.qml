import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bar face of the Android manager. It owns no process and no state: a bar
// surface exists per monitor and is rebuilt on a monitor change or a theme
// reload, and a mirror must not die because the bar was redrawn. Everything
// lives on Service.qml; this widget finds it, paints the icon from it, and
// hosts the panel.
BarWidget {
  id: root
  moduleName: "shilai_li.android-manager"

  // The service is looked up through the scoped shell facade, which only ever
  // hands a plugin its own. It can still be loading when the first widget is
  // built, and a lookup is a function call rather than a binding, so it is
  // asked again until it answers.
  property var service: null

  function findService() {
    if (root.service) return
    var api = root.bar && root.bar.shell ? root.bar.shell : null
    if (api && typeof api.serviceFor === "function") root.service = api.serviceFor(root.moduleName)
  }

  Timer {
    interval: 500
    repeat: true
    running: root.service === null
    onTriggered: root.findService()
  }

  onBarChanged: { root.findService(); root.injectPanel() }
  onSettingsChanged: root.injectPanel()
  Component.onCompleted: root.findService()

  readonly property string barState: root.service ? root.service.barState : "idle"

  readonly property string tooltip: {
    var s = root.service
    if (!s) return "Android: starting…"
    if (s.adbMissing) return "Android: adb is not installed"
    var phones = s.readyCount === 1 ? "1 phone" : s.readyCount + " phones"
    var lines = ["Android · " + (s.mirrorCount > 0 ? s.mirrorCount + " mirroring" : s.readyCount > 0 ? phones : "no phones")]
    var inPanel = []
    var inWindow = []
    for (var i = 0; i < s.rows.length; i++) {
      var m = s.rows[i].mirror
      if (m) (m.mode === "attached" ? inPanel : inWindow).push(s.rows[i].name)
    }
    if (inPanel.length > 0) lines.push(inPanel.join(", ") + " in the panel")
    if (inWindow.length > 0) lines.push(inWindow.join(", ") + " in a window")
    if (s.waitingCount > 0) lines.push(s.waitingCount + " waiting for Allow")
    return lines.join("\n")
  }

  // ---- Panel plumbing. Same shape contract as the shell's own widgets:
  //      Bar.findPanelWidget wants open/close/opened on the widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "shilai_li.android-manager"

    function toggle(): void { root.togglePanel() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function refresh(): void { if (root.service) root.service.refresh(true) }
    function status(): string { return root.service ? root.service.statusJson() : "{}" }
  }

  // The state is in the color *and* in the tooltip; a theme may give
  // `urgent` the accent's hue, so the icon is never the only place it is said.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰄜"
    tooltipText: root.tooltip
    dimmed: root.barState === "idle"
    active: root.barState === "mirroring" || root.barState === "attention" || root.barState === "broken"
    activeColor: root.barState === "mirroring" ? Commons.Color.accent : Commons.Color.urgent

    onPressed: function(b) { root.togglePanel() }
  }
}
