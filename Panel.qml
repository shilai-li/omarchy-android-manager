import QtQuick
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Android.js" as Android

// The panel: the phones adb can see, one phone in detail, the three ways
// onto Wi-Fi, and the running mirrors. Every phone, process and setting lives
// on Service.qml; this owns the cursor, the filter, which view is up and the
// text in its fields, and nothing else.
//
// Drawn the way the shell's Studio Effects panel is: groups on cards separated by space, facts
// in the header as pills, round discs filled with the accent only for what is
// on, a row of segments for each exclusive choice, switches for on/off, and
// the keys as chips at the bottom. One highlight at a time: rows paint from
// CursorSurface's `hasCursor`, and a click moves that same cursor.
//
// Keys are handled here rather than by PanelKeyCatcher: typing filters the
// list, and the catcher's h/j/k/l/x bindings would make half the alphabet
// impossible to type. In the Wi-Fi view the text fields own the keyboard and
// only what they leave unclaimed reaches handleKey.
Panel {
  id: root
  moduleName: "shilai_li.android-manager"
  ipcTarget: "shilai_li.android-manager"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot, not this nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property var service: hostWidget ? hostWidget.service : null

  // ---- Read-out of the service. Guarded throughout: the panel is built
  //      before the widget has found the service.
  readonly property var allRows: service ? service.rows : []
  readonly property var rows: Android.filterRows(allRows, filterText)
  readonly property string errorText: service ? service.errorText : ""
  readonly property string noticeText: service ? service.noticeText : ""
  readonly property bool adbMissing: !!service && service.adbMissing
  readonly property bool scrcpyMissing: !!service && service.scrcpyMissing

  property string view: "list"        // list | details | wifi | mirrors
  property int wifiTab: 0             // 0 USB → port, 1 pairing code, 2 manual
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: true
  property int optionIndex: 0
  property int suggestionIndex: -1
  property int mirrorIndex: 0

  // The phone the details and Wi-Fi views are about, followed by key so a
  // rescan that reorders the list does not swap it for another phone.
  property string focusKey: ""
  readonly property var currentRow: selectedIndex >= 0 && selectedIndex < rows.length ? rows[selectedIndex] : null
  readonly property var focusRow: {
    for (var i = 0; i < allRows.length; i++) if (allRows[i].key === focusKey) return allRows[i]
    return null
  }
  // The phones plugged in over USB: the ones the :port tab can switch.
  readonly property var usbRows: root.allRows.filter(function(r) { return root.service && root.service.usbTarget(r) !== "" })
  // The phone the :port tab works on: the one in view if it is on USB,
  // otherwise the first one that is, so a plugged-in phone is never missed.
  readonly property var usbRow: root.usbRows.indexOf(root.focusRow) >= 0 ? root.focusRow : (root.usbRows.length > 0 ? root.usbRows[0] : null)

  // Every running mirror, attached or in a window, in a stable order.
  readonly property var mirrorList: {
    var list = []
    var mirrors = root.service ? root.service.mirrors : ({})
    for (var key in mirrors) {
      var row = null
      for (var i = 0; i < root.allRows.length; i++) if (root.allRows[i].key === key) row = root.allRows[i]
      list.push({ key: key, mirror: mirrors[key], row: row, name: row ? row.name : key })
    }
    list.sort(function(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0 })
    return list
  }
  // The mirrors' keys in display order, as one string: it changes only when a
  // mirror starts or stops, not when one is placed or moved.
  readonly property string mirrorKeys: root.mirrorList.map(function(e) { return e.key }).join("\n")

  function mirrorEntry(key) {
    for (var i = 0; i < root.mirrorList.length; i++) if (root.mirrorList[i].key === key) return root.mirrorList[i]
    return { key: key, mirror: { mode: "" }, row: null, name: key }
  }

  readonly property var currentMirror: mirrorIndex >= 0 && mirrorIndex < mirrorList.length ? mirrorList[mirrorIndex] : null
  onMirrorListChanged: root.mirrorIndex = Android.clampIndex(root.mirrorIndex, root.mirrorList.length)
  readonly property int windowCount: root.mirrorList.length - (root.service ? root.service.attachedCount : 0)

  // ---- The Mirrors view's geometry. Each attached phone is a card: a header
  //      (disc, name, round buttons) over the phone's tile and its rail of
  //      buttons. A phone in its own window keeps the same card, the tile
  //      and rail's place holding a note instead, so detaching or attaching
  //      never resizes the panel.
  //
  //      Each tile has its phone's shape — the screen it reported, held
  //      upright — and they all share one
  //      height: as tall as the screen leaves room for, shorter when the row
  //      would not fit across. The chrome above and below the tiles is
  //      estimated from font sizes rather than measured, because the wrapped
  //      key chips below would otherwise depend on the tiles' own width.
  readonly property int cardPad: Style.space(12)
  readonly property int cardHeadHeight: Style.space(36)
  readonly property int cardGap: Style.space(10)
  readonly property int railGap: Style.space(10)
  readonly property int railWidth: Style.space(48)
  readonly property int railButton: Style.space(38)
  readonly property int cardsGap: Style.space(12)
  readonly property int sectionGap: Style.space(12)

  function isAttached(entry) { return entry.mirror.mode === "attached" }

  function mirrorAspect(entry) {
    var screen = entry.row && entry.row.info ? entry.row.info.screen : null
    return Android.screenAspect(screen)
  }
  readonly property var tileAspects: {
    var out = []
    for (var i = 0; i < root.mirrorList.length; i++) out.push(root.mirrorAspect(root.mirrorList[i]))
    return out
  }
  // Everything across the row that does not grow with the tiles' height.
  readonly property int fixedCardsWidth: {
    var w = 0
    for (var i = 0; i < root.mirrorList.length; i++)
      w += 2 * root.cardPad + root.railGap + root.railWidth + 2 * root.tileInset
    return w + root.cardsGap * Math.max(0, root.mirrorList.length - 1)
  }
  readonly property real lineCaption: Style.font.caption * 1.4
  readonly property int mirrorChrome: Math.ceil((root.headerBar ? root.headerBar.implicitHeight : 0) + root.segmentHeight
    + 2 * root.cardPad + root.cardHeadHeight + root.cardGap
    + 3 * (root.lineCaption + Style.space(6)) + root.lineCaption
    + 5 * root.sectionGap + Style.space(8))

  // The card's own padding and border, left and right: the card is
  // contentWidth wide, and the tiles have to fit inside those insets.
  readonly property real cardInsetX: root.card
    ? root.card.contentLeftInset + root.card.contentRightInset
    : Style.space(48)
  readonly property int tileHeight: Android.fitTileHeight(root.tileAspects,
    panel.availableCardWidth > 0 ? panel.availableCardWidth - root.cardInsetX - 2 : Style.space(900),
    panel.availableCardHeight > 0 ? panel.availableCardHeight - panel.verticalContentInset - root.mirrorChrome : Style.space(560),
    0, Style.space(240), root.fixedCardsWidth)

  // The phone's window sits inside the tile's border, tileInset in on every
  // side, so it is the inner hole that has to have the phone's shape. Giving
  // the outer tile that shape made the hole a little too wide for a tall
  // phone, and scrcpy letterboxed it with dark bars at the top and bottom.
  readonly property int tileInset: Math.max(1, Style.space(2))
  function tileWidthFor(entry) {
    var inner = Math.round((root.tileHeight - 2 * root.tileInset) * root.mirrorAspect(entry))
    return Math.max(Style.space(150), inner + 2 * root.tileInset)
  }
  function cardWidthFor(entry) {
    return 2 * root.cardPad + root.tileWidthFor(entry) + root.railGap + root.railWidth
  }
  readonly property int cardsHeight: root.tileAspects.length > 0
    ? 2 * root.cardPad + root.cardHeadHeight + root.cardGap + root.tileHeight
    : Style.space(380)
  readonly property int tilesWidth: {
    var w = 0
    for (var i = 0; i < root.mirrorList.length; i++) w += root.cardWidthFor(root.mirrorList[i])
    return w + root.cardsGap * Math.max(0, root.mirrorList.length - 1)
  }
  // The header's own width, so a panel with one phone is as narrow as it can
  // be without the header crowding. From the title's full text width and the
  // same reserve the title gives up (titleText's width below): measuring the
  // row instead read the title's already-elided width, so the panel and the
  // title shrank each other until the title was only "…".
  readonly property real headerMinWidth: root.titleLabel && root.headerPills
    ? root.titleLabel.implicitWidth + Style.space(48) + root.headerPills.implicitWidth : 0

  // ---- The Devices | Mirrors switch stays on the same pixels in both views.
  //      The card is centred under the bar icon (KeyboardPanel.cardOrigin),
  //      so the Mirrors view, wider, moves the card's left edge; the switch
  //      keeps the list view's width and is shifted inside the wider card to
  //      where the list view put it.
  readonly property int listCardWidth: panel.fittedContentWidth(Math.max(Style.space(380),
    Math.ceil(root.listHeaderWidth + root.cardInsetX)))

  // The Devices header's width, measured from its text rather than from the
  // items on screen, so it is known in every view: the Mirrors view needs it
  // to keep the Devices | Mirrors switch where the list put it. Same parts
  // as the header: title, the 48 the title leaves, and each pill's text,
  // padding and dot.
  readonly property var listStatus: root.statusFor("list")
  readonly property real listHeaderWidth: listTitleMetrics.advanceWidth + Style.space(48)
    + (listFactMetrics.text !== "" ? listFactMetrics.advanceWidth + Style.space(14) : 0)
    + (root.listStatus ? Style.space(6) + listStatusMetrics.advanceWidth + Style.space(14)
      + (root.listStatus.tone === "on" ? Style.space(11) : 0) : 0)
    + Style.space(4)

  TextMetrics {
    id: listTitleMetrics
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
    text: "Android"
  }
  TextMetrics {
    id: listFactMetrics
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    text: root.factFor("list")
  }
  TextMetrics {
    id: listStatusMetrics
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: root.listStatus && root.listStatus.tone !== "quiet" ? 0.5 : 0
    text: root.listStatus ? root.listStatus.text : ""
  }

  function cardXFor(w) {
    var pos = panel.barPos
    var x = pos === "left" ? panel.barW + panel.gap
      : pos === "right" ? panel.screenW - panel.barW - w - panel.gap
      : panel.anchorScreenPos.x + panel.anchorW / 2 - w / 2
    return Math.round(Math.max(panel.margin, Math.min(x, panel.screenW - w - panel.margin)))
  }

  readonly property real columnWidth: root.column ? root.column.width : 0
  readonly property real switchWidth: Math.min(root.listCardWidth - root.cardInsetX, root.columnWidth)
  readonly property real switchX: root.view === "mirrors"
    ? Math.max(0, Math.min(root.cardXFor(root.listCardWidth) - root.cardXFor(panel.contentWidth), root.columnWidth - root.switchWidth))
    : 0

  // ---- Holes. An attached mirror's tile, once its scrcpy window has been
  //      moved under it, is cut out of this panel: out of the input mask, so
  //      clicks reach the window, and out of the painted background, so it
  //      shows through. KeyboardPanel paints the card itself, so while there
  //      are holes its fill is made transparent and `cardFill` below paints
  //      it instead, with the holes left out. Each mirror card's own tint
  //      leaves its hole out the same way.
  property var holes: []

  function setHole(item, on) {
    var had = root.holes.indexOf(item) !== -1
    var next = root.holes.filter(function(h) { return h && h !== item })
    if (on) next.push(item)
    root.holes = next
    root.refreshHoleRects()
    if (on && !had && root.opened) refocusTimer.restart()
  }

  // A new phone window takes keyboard focus as it maps, and Hyprland then
  // hands it back to the last focused window, not to this panel, so the
  // panel's keys stop working until it is clicked. Take it back once the
  // window has been placed and that has settled.
  Timer {
    id: refocusTimer
    interval: 700
    onTriggered: if (root.opened) panel.beginFocusPrime()
  }

  // On open, KeyboardPanel animates card.shown (duration: 180ms) with a
  // 0.97 -> 1.0 scale transform. Wait for that settle before placing mirror
  // windows and cutting holes, so scrcpy doesn't map to a transient scale.
  property bool openingSettling: false

  Timer {
    id: openSettleTimer
    interval: Style.duration(200)
    onTriggered: root.openingSettling = false
  }

  function holeAt(i) { return i < root.holes.length ? root.holes[i] : null }

  // Attached windows leave the screen whenever their tiles are not on it:
  // the panel closing, or another view taking its place.
  readonly property bool mirrorsShown: root.opened && root.view === "mirrors" && !root.resizing && !root.openingSettling
  onMirrorsShownChanged: if (!root.mirrorsShown) Qt.callLater(root.hideMirrorWindows)

  function hideMirrorWindows() {
    if (!root.service || root.mirrorsShown) return
    for (var key in root.service.mirrors) root.service.hideWindow(key)
  }

  // ---- The content is built the first time the panel opens (KeyboardPanel's
  //      lazy `content`), not on every monitor at shell start. The items the
  //      code up here reaches are these, null until then; everything that
  //      must run while the panel is closed lives on Service.qml.
  readonly property Item cardFill: panel.loadedContent ? panel.loadedContent.cardFill : null
  readonly property Item column: panel.loadedContent ? panel.loadedContent.column : null
  readonly property Item headerBar: panel.loadedContent ? panel.loadedContent.headerBar : null
  readonly property Item titleLabel: panel.loadedContent ? panel.loadedContent.titleLabel : null
  readonly property Item headerPills: panel.loadedContent ? panel.loadedContent.headerPills : null
  readonly property Item listScroll: panel.loadedContent ? panel.loadedContent.listScroll : null
  readonly property Item detailsScroll: panel.loadedContent ? panel.loadedContent.detailsScroll : null
  readonly property Item detailsColumn: panel.loadedContent ? panel.loadedContent.detailsColumn : null
  readonly property Item ipField: panel.loadedContent ? panel.loadedContent.ipField : null
  readonly property Item portField: panel.loadedContent ? panel.loadedContent.portField : null
  readonly property Item pairAddressField: panel.loadedContent ? panel.loadedContent.pairAddressField : null
  readonly property Item pairCodeField: panel.loadedContent ? panel.loadedContent.pairCodeField : null
  readonly property Item manualField: panel.loadedContent ? panel.loadedContent.manualField : null
  readonly property Item keys: panel.loadedContent

  // KeyboardPanel's card, found by walking up from the content rather than a
  // fixed number of parents: shell internals, so check it after shell updates.
  readonly property var card: {
    var item = root.keys ? root.keys.parent : null
    while (item && item.contentLeftInset === undefined) item = item.parent
    return item
  }
  // Painted only while the windows are meant to be on screen. Closing (or
  // switching views) fills the card back in the same frame, so it fades out
  // whole, the way the shell's own panels do, instead of showing the desktop
  // through an empty hole while the windows are put away.
  readonly property bool holesOpen: root.mirrorsShown && root.holes.length > 0
  onHolesOpenChanged: {
    if (root.holesOpen) Qt.callLater(panel.beginFocusPrime)
  }

  // A Binding, not an assignment: assigning card.color replaced the shell's
  // own binding to the theme, so after the first attached mirror the card
  // kept that moment's background through every later theme change.
  Binding {
    target: root.card
    property: "color"
    value: "transparent"
    when: root.holesOpen && root.card !== null && root.card.color !== undefined
    restoreMode: Binding.RestoreBinding
  }

  // Each hole in cardFill's coordinates, refreshed while there are holes.
  property var holeRects: []

  function refreshHoleRects() {
    var out = []
    for (var i = 0; i < root.holes.length; i++) {
      var h = root.holes[i]
      if (!root.cardFill) break
      var p = h.mapToItem(cardFill, 0, 0)
      out.push({ x: p.x, y: p.y, w: h.width, h: h.height })
    }
    root.holeRects = out
  }

  function holeRect(i) { return i < root.holeRects.length ? root.holeRects[i] : { x: 0, y: 0, w: 0, h: 0 } }

  Timer {
    interval: 100
    repeat: true
    triggeredOnStart: true
    running: root.holesOpen
    onTriggered: root.refreshHoleRects()
  }

  // ---- Theme. Nothing here names a color; the palette does.
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color surface: Commons.Color.popups.background
  readonly property color dim: Qt.darker(contentForeground, 1.5)
  readonly property color dimmer: Qt.darker(contentForeground, 2.0)
  readonly property color accentColor: Style.selectedStateColor(contentForeground, Commons.Color.accent)
  readonly property color hoverFill: Style.hoverFillFor(contentForeground, Commons.Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(contentForeground, Commons.Color.accent)

  // Cards are a tint of the text color laid over the panel, so they sit on any
  // theme without a color of their own. Something switched on is filled with
  // the accent and carries its glyph in the panel's own color.
  readonly property color tint: Util.alpha(contentForeground, 0.06)
  readonly property color quietFill: Util.alpha(contentForeground, 0.12)
  readonly property color hairline: Util.alpha(contentForeground, 0.14)
  readonly property color onFill: Commons.Color.accent
  readonly property color urgentFill: Util.alpha(Commons.Color.urgent, 0.16)

  // The theme decides whether anything is round. Square corners stay square;
  // rounded ones grow a step, because the cards here are larger than a row.
  readonly property bool rounded: Style.cornerRadius > 0
  readonly property int cardRadius: rounded ? Math.max(Style.cornerRadius * 2, Style.space(12)) : 0
  readonly property int innerRadius: Math.max(0, root.cardRadius - Style.space(6))

  readonly property int rowHeight: Math.max(Style.space(54), Style.font.body + Style.font.caption + Style.space(24))
  readonly property int listPad: Style.space(6)
  readonly property int listHeight: Math.max(rowHeight, Math.min(rows.length * rowHeight, rowHeight * 5))
  readonly property int segmentHeight: Math.max(Style.space(34), Style.font.bodySmall + Style.space(18))
  readonly property int choiceHeight: Math.max(Style.space(30), Style.font.bodySmall + Style.space(14))

  // Material Design glyphs from the Nerd Font the bar uses.
  readonly property string glyphPhone: "\u{F011C}"
  readonly property string glyphSearch: "\u{F0349}"
  readonly property string glyphMirror: "\u{F0379}"
  readonly property string glyphWifi: "\u{F05A9}"
  readonly property string glyphUsb: "\u{F0553}"
  readonly property string glyphCamera: "\u{F0100}"
  readonly property string glyphShell: "\u{F018D}"
  readonly property string glyphLink: "\u{F0337}"
  readonly property string glyphOut: "\u{F0DAD}"      // application-export: to its own window
  readonly property string glyphIn: "\u{F0DAE}"       // application-import: into the panel
  readonly property string glyphStop: "\u{F04DB}"
  readonly property string glyphWindow: "\u{F05AF}"
  readonly property string glyphBack: "\u{F0141}"
  readonly property string glyphPackage: "\u{F03D3}"

  function colorFor(state) {
    if (state === Android.STATE_MIRRORING) return root.accentColor
    if (state === Android.STATE_UNAUTHORIZED) return Commons.Color.urgent
    if (state === Android.STATE_READY) return root.contentForeground
    return root.dimmer
  }

  function isAbsent(row) {
    return !!row && (row.state === Android.STATE_REMEMBERED || row.state === Android.STATE_OFFLINE)
  }

  function onWifi(row) {
    if (!row) return false
    for (var i = 0; i < row.transports.length; i++)
      if (row.transports[i].kind === "wifi" && row.transports[i].state === "device") return true
    return false
  }

  function transportLabel(row) {
    if (!row) return ""
    return row.transport === "wifi" ? "wi-fi" : row.transport
  }

  // A mirror's settings, short, under its name on the card.
  function mirrorSub(entry) {
    var row = entry.row
    if (!row) return ""
    var o = row.options
    return [root.transportLabel(row), o.maxSize === 0 ? "native" : String(o.maxSize), o.maxFps + " fps"].join(" · ")
  }

  // ---- The header: the facts, as pills. Everything below it is a control.
  readonly property string titleText: root.view === "details" ? (root.focusRow ? root.focusRow.name : "")
    : root.view === "wifi" ? "Connect over Wi-Fi" : "Android"
  readonly property bool subView: root.view === "details" || root.view === "wifi"

  function factFor(view) {
    var s = root.service
    if (view === "details") {
      var r = root.focusRow
      if (!r) return ""
      return root.transportLabel(r) + (r.info && r.info.release ? " · Android " + r.info.release : "")
    }
    if (view === "wifi") {
      if (root.wifiTab === 0) return root.usbRows.length + " on USB"
      if (root.wifiTab === 1) return "Android 11+"
      return "adb connect"
    }
    if (!s) return "starting…"
    if (!s.scanned) return "looking…"
    if (s.adbMissing) return ""
    if (view === "mirrors" && root.mirrorList.length > 0)
      return s.attachedCount + " in the panel" + (root.windowCount > 0 ? " · " + root.windowCount + " in a window" : "")
    // The version alone: Arch's adb reports "37.0.0-android-tools".
    var version = function(v) { return String(v).replace(/-.*$/, "") }
    return "adb " + version(s.tools.adb) + " · " + (s.scrcpyMissing ? "no scrcpy" : "scrcpy " + version(s.tools.scrcpy))
  }  readonly property string factText: root.factFor(root.view)


  // { text, tone } or null. Shape as well as color: a theme may give
  // `urgent` the accent's hue.
  function statusFor(view) {
    var s = root.service
    if (!s) return null
    if (view === "details") {
      var r = root.focusRow
      if (!r) return null
      if (r.state === Android.STATE_MIRRORING) return { text: "MIRRORING", tone: "on" }
      if (r.state === Android.STATE_UNAUTHORIZED) return { text: "◐ WAITING", tone: "urgent" }
      if (root.isAbsent(r)) return { text: "○ " + (r.state === Android.STATE_OFFLINE ? "OFFLINE" : "NOT CONNECTED"), tone: "quiet" }
      return null
    }
    if (view === "wifi") return s.wifiRunning || s.netRunning ? { text: "WORKING…", tone: "quiet" } : null
    if (s.adbMissing) return { text: "✕ NOT INSTALLED", tone: "urgent" }
    if (s.mirrorCount > 0) return { text: s.mirrorCount + " MIRRORING", tone: "on" }
    if (s.waitingCount > 0) return { text: "◐ " + s.waitingCount + " WAITING", tone: "urgent" }
    if (s.scrcpyMissing) return { text: "✕ NOT INSTALLED", tone: "urgent" }
    return null
  }  readonly property var statusPill: root.statusFor(root.view)


  // What the keys do from here, as key and meaning.
  readonly property var keyHints: {
    var method = ["^1 ^2 ^3", "method"]
    if (root.view === "mirrors") {
      if (root.mirrorList.length === 0) return [["tab", "devices"], ["esc", "close"]]
      var here = root.currentMirror && !root.isAttached(root.currentMirror) ? [["enter", "focus window"]] : []
      return [["←→", "pick"]].concat(here, [["^d", "window / panel"], ["^a", "all into panel"], ["^x", "stop"],
        ["tab", "devices"], ["esc", "hide · mirrors keep running"]])
    }
    if (root.view === "details")
      return [["↑↓", "option"], ["→", "change"], ["space", "toggle"], ["enter", "mirror"], ["^s", "screenshot"],
        ["^t", "shell"], ["← esc", "back"]]
    if (root.view === "wifi") {
      if (root.wifiTab === 0)
        return (root.usbRows.length > 1 ? [["↑↓", "pick phone"]] : [])
          .concat([["tab", "next field"], ["enter", "switch + connect"], method, ["esc", "back"]])
      if (root.wifiTab === 1)
        return [["↑↓", "pick phone"], ["tab", "next field"], ["enter", "pair"], ["^r", "search again"], method, ["esc", "back"]]
      return [["↑↓", "remembered"], ["enter", "connect"], method, ["esc", "back"]]
    }
    if (root.adbMissing) return [["^r", "recheck"], ["esc", "close"]]
    if (root.allRows.length === 0) return [["^p", "pair"], ["^o", "ip:port"], ["^r", "rescan"], ["esc", "close"]]
    var row = root.currentRow
    if (row && row.state === Android.STATE_UNAUTHORIZED)
      return [["↑↓", "move"], ["→", "details"], ["^r", "rescan"], ["esc", "close"]]
    if (root.isAbsent(row))
      return [["↑↓", "move"], ["enter", "reconnect"], ["→", "details"], ["^w", "wi-fi"], ["^f", "forget"], ["esc", "close"]]
    return [["↑↓", "move"], ["enter", "mirror"], ["→", "details"], ["^w", "wi-fi"], ["^p", "pair"], ["^d", "disconnect"],
      ["^m", "mirrors"], ["esc", "close"]]
  }

  // ---- Lifecycle.
  function open() {
    root.openingSettling = true
    openSettleTimer.restart()
    if (root.service && root.service.attachedCount > 0) root.showMirrors()
    else root.showList()
    root.filterText = ""
    root.cursorActive = true
    if (root.service) {
      root.service.clearMessages()
      root.service.refresh()
    }
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  // The hide goes first. This is a full-screen layer-shell surface holding
  // keyboard focus: anything that throws before the hide lands leaves the user
  // behind a surface that eats every key, with a bar that no longer answers.
  function close() {
    root.openingSettling = false
    openSettleTimer.stop()
    root.controller.hide()
    root.setCenterHoverRevealSuppressed(false)
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // The `bar` a plugin gets is a facade on which this flag is readonly; the
  // setter is the supported route, and assigning would throw.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  // The view is chosen again by open(). Closing leaves it as it is, so the
  // card fades out as it stood rather than jumping to the list first.
  onOpenedChanged: {
    if (root.opened) {
      root.openingSettling = true
      openSettleTimer.restart()
    } else {
      root.openingSettling = false
      openSettleTimer.stop()
    }
  }

  // While the panel is up, the battery and the like are worth keeping fresh.
  // Nothing runs on this timer while it is closed.
  Timer {
    interval: 10000
    repeat: true
    running: root.opened && root.view !== "wifi"
    onTriggered: if (root.service) root.service.refresh()
  }

  // ---- Views.
  // ---- Switching views (Devices, Mirrors, a phone's details, Wi-Fi) grows
  //      or shrinks the card rather than jumping. Only a switch made with the
  //      panel open animates: a mirror starting, stopping or reporting its
  //      frame changes the size too, and those stay instant. While it runs
  //      the content is clipped to the card, and the phones' windows wait:
  //      they follow their tiles only five times a second, so they would
  //      trail a moving card.
  readonly property int resizeDuration: Style.duration(240)
  property bool resizing: false

  function beginResize(nextView) {
    if (!root.opened || root.view === nextView) return
    root.resizing = true
    resizeTimer.restart()
  }

  Timer {
    id: resizeTimer
    interval: root.resizeDuration + 40
    onTriggered: root.resizing = false
  }

  function showList() {
    root.beginResize("list")
    root.view = "list"
    Qt.callLater(function() {
      if (root.keys) root.keys.forceActiveFocus()
      root.ensureVisible()
    })
  }

  function showMirrors() {
    root.beginResize("mirrors")
    root.view = "mirrors"
    root.mirrorIndex = Android.clampIndex(root.mirrorIndex, root.mirrorList.length)
    Qt.callLater(function() { if (root.keys) root.keys.forceActiveFocus() })
  }

  function showDetails() {
    if (!root.currentRow) return
    root.focusKey = root.currentRow.key
    root.optionIndex = 0
    if (root.detailsScroll) root.detailsScroll.contentY = 0
    root.beginResize("details")
    root.view = "details"
    Qt.callLater(function() { if (root.keys) root.keys.forceActiveFocus() })
  }

  function showWifi(tab) {
    var row = root.view === "list" ? root.currentRow : root.focusRow
    root.focusKey = row ? row.key : ""
    root.beginResize("wifi")
    root.view = "wifi"
    root.setWifiTab(tab)
  }

  function setWifiTab(tab) {
    root.wifiTab = tab
    if (!root.keys) return
    root.suggestionIndex = -1
    var row = root.focusRow
    if (tab === 0) {
      row = root.usbRow
      ipField.text = row && row.info && row.info.ip ? row.info.ip : ""
      portField.text = String(Android.DEFAULT_PORT)
      Qt.callLater(function() { (ipField.text === "" ? ipField : portField).forceActiveFocus() })
    } else if (tab === 1) {
      pairAddressField.text = ""
      pairCodeField.text = ""
      if (root.service) root.service.discover()
      Qt.callLater(function() { pairAddressField.forceActiveFocus() })
    } else {
      manualField.text = row && row.address ? row.address : ""
      Qt.callLater(function() { manualField.forceActiveFocus() })
    }
  }

  // ---- Actions on the phone under the cursor (list) or in view (details).
  function actionRow() { return root.view === "list" ? root.currentRow : root.focusRow }

  function mirror() {
    var row = root.actionRow()
    if (!row || !root.service) return
    if (root.isAbsent(row)) {
      // Enter on a phone that is not there means "get it back", which for a
      // remembered Wi-Fi phone is a connect to its last address.
      if (row.address) root.service.reconnect(row.key)
      return
    }
    // A phone that is already mirroring is shown, never stopped: a toggle
    // stopped one phone while the user reached for another. Stopping is ^x
    // or ■ in the Mirrors view.
    if (root.service.mirrorFor(row.key)) {
      for (var j = 0; j < root.mirrorList.length; j++) if (root.mirrorList[j].key === row.key) root.mirrorIndex = j
      root.showMirrors()
      return
    }
    root.service.startMirror(row.key, "")
    var m = root.service.mirrorFor(row.key)
    if (m && m.mode === "attached") {
      for (var i = 0; i < root.mirrorList.length; i++) if (root.mirrorList[i].key === row.key) root.mirrorIndex = i
      root.showMirrors()
    }
  }

  // ---- The Mirrors view's actions, on the card under the cursor.
  function toggleAttach() {
    var t = root.currentMirror
    if (!t || !root.service) return
    if (t.mirror.mode === "attached") root.service.detach(t.key)
    else root.service.attach(t.key)
  }

  function stopCurrentMirror() {
    var t = root.currentMirror
    if (t && root.service) root.service.stopMirror(t.key)
  }

  // A mirror in its own window is somewhere behind this full-screen panel, so
  // the panel goes first.
  function focusMirrorWindow(entry) {
    if (!entry || !root.service || root.isAttached(entry)) return
    var key = entry.key
    root.close()
    root.service.focusWindow(key)
  }

  // ^w: the :port tab when a phone is on USB, this one or, if this one is
  // already up over Wi-Fi, another that is plugged in. A phone that is
  // offline or only remembered gets the manual tab with its address instead.
  function wifi() {
    var row = root.actionRow()
    var down = root.isAbsent(row)
    var onUsb = row && root.usbRows.indexOf(row) >= 0
    root.showWifi(onUsb || (!down && root.usbRows.length > 0) ? 0 : 2)
  }

  function disconnect() {
    var row = root.actionRow()
    if (row && root.service) root.service.disconnect(row.key)
  }

  function screenshot() {
    var row = root.actionRow()
    if (row && root.service) root.service.screenshot(row.key)
  }

  function openShell() {
    var row = root.actionRow()
    if (row && root.service && root.service.openShell(row.key)) root.close()
  }

  function forget() {
    var row = root.actionRow()
    if (row && root.service && row.state === Android.STATE_REMEMBERED) root.service.forget(row.key)
  }

  function stepOption(delta) {
    var row = root.focusRow
    if (!row || !root.service) return
    var spec = Android.OPTION_SPECS[root.optionIndex]
    root.service.setOptions(row.key, Android.stepOption(row.options, spec.key, delta))
  }

  function setOption(key, value) {
    var row = root.focusRow
    if (!row || !root.service) return
    var o = Android.normalizeOptions(row.options)
    o[key] = value
    root.service.setOptions(row.key, o)
  }

  // The details view scrolls; keep the option under the cursor in sight.
  readonly property int detailsChrome: Math.ceil((root.headerBar ? root.headerBar.implicitHeight : 0)
    + 3 * (root.lineCaption + Style.space(6)) + root.lineCaption + 3 * root.sectionGap + Style.space(8))

  function revealOption(item) {
    if (!root.detailsScroll) return
    var top = item.mapToItem(detailsColumn, 0, 0).y
    var bottom = top + item.height
    if (top < detailsScroll.contentY) detailsScroll.contentY = top
    else if (bottom > detailsScroll.contentY + detailsScroll.height) detailsScroll.contentY = bottom - detailsScroll.height
  }

  // A choice's value as the segments and the value beside them show it.
  function choiceLabel(spec, v, long) {
    if (spec.key === "maxSize") return v === 0 ? "native" : String(v) + (long ? " px" : "")
    if (spec.key === "bitRate") return v + (long ? " Mbps" : "M")
    return String(v) + (long ? " fps" : "")
  }

  readonly property var optionNotes: ({
    audio: "Phone sound plays here",
    stayAwake: "While plugged in",
    screenOff: "Phone dark, mirror on",
    record: "To a file in ~/Videos"
  })

  // The options as the details view lays them out: the choices on one card,
  // the switches on the next. `index` is the cursor's, into OPTION_SPECS.
  function optionGroup(toggles) {
    var out = []
    for (var i = 0; i < Android.OPTION_SPECS.length; i++)
      if (!!Android.OPTION_SPECS[i].toggle === toggles) out.push({ index: i, spec: Android.OPTION_SPECS[i] })
    return out
  }

  function submitWifi() {
    if (!root.service || !root.keys) return
    if (root.wifiTab === 0) {
      if (!root.usbRow) { root.service.setError("Plug the phone in over USB first"); return }
      root.service.startWifi(root.usbRow.key, portField.text.trim(), ipField.text.trim())
    } else if (root.wifiTab === 1) {
      root.service.pairAddress(pairAddressField.text, pairCodeField.text.trim())
      pairCodeField.text = ""
    } else {
      root.service.connectAddress(manualField.text)
    }
  }

  // ↑↓ in the pairing and manual tabs walk a list of addresses into the
  // field: phones advertising a pairing port, or the ones remembered.
  readonly property var suggestions: {
    if (root.view !== "wifi" || !root.service) return []
    var list = []
    if (root.wifiTab === 1) {
      var found = root.service.discovered
      for (var i = 0; i < found.length; i++)
        if (found[i].kind === "pairing") list.push({ label: found[i].name, address: found[i].address })
    } else if (root.wifiTab === 2) {
      for (var j = 0; j < root.allRows.length; j++)
        if (root.allRows[j].address) list.push({ label: root.allRows[j].name, address: root.allRows[j].address })
    }
    return list
  }

  function pickSuggestion(index) {
    if (index < 0 || index >= root.suggestions.length) return
    root.suggestionIndex = index
    var address = root.suggestions[index].address
    if (root.wifiTab === 1) {
      pairAddressField.text = address
      pairCodeField.forceActiveFocus()
    } else {
      manualField.text = address
    }
  }

  function stepSuggestion(delta) {
    if (root.wifiTab === 0) {
      if (root.usbRows.length < 2) return
      var at = root.usbRows.indexOf(root.usbRow)
      root.focusKey = root.usbRows[Android.moveIndex(at, delta, root.usbRows.length)].key
      root.setWifiTab(0)
      return
    }
    if (root.suggestions.length === 0) return
    var next = Android.moveIndex(root.suggestionIndex < 0 && delta < 0 ? 0 : root.suggestionIndex, delta, root.suggestions.length)
    root.suggestionIndex = Math.max(0, next)
    var address = root.suggestions[root.suggestionIndex].address
    if (root.wifiTab === 1) pairAddressField.text = address
    else manualField.text = address
  }

  // ---- Cursor.
  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    root.cursorActive = true
    Qt.callLater(root.ensureVisible)
  }

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    root.cursorActive = true
    root.selectedIndex = Android.moveIndex(root.selectedIndex, delta, root.rows.length)
    root.ensureVisible()
  }

  function ensureVisible() {
    if (!root.listScroll) return
    var top = root.selectedIndex * root.rowHeight
    var bottom = top + root.rowHeight
    if (top < listScroll.contentY) listScroll.contentY = top
    else if (bottom > listScroll.contentY + listScroll.height) listScroll.contentY = bottom - listScroll.height
  }

  onRowsChanged: root.selectedIndex = Android.clampIndex(root.selectedIndex, root.rows.length)

  // ---- Keys.
  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

    if (root.view === "wifi") {
      if (event.key === Qt.Key_Escape) { root.showList(); return true }
      if (ctrl && event.key === Qt.Key_1) { root.setWifiTab(0); return true }
      if (ctrl && event.key === Qt.Key_2) { root.setWifiTab(1); return true }
      if (ctrl && event.key === Qt.Key_3) { root.setWifiTab(2); return true }
      if (ctrl && event.key === Qt.Key_R) {
        if (root.service) root.wifiTab === 1 ? root.service.discover() : root.service.refresh(true)
        return true
      }
      if (event.key === Qt.Key_Down) { root.stepSuggestion(1); return true }
      if (event.key === Qt.Key_Up) { root.stepSuggestion(-1); return true }
      return false
    }

    if (root.view === "mirrors") {
      if (event.key === Qt.Key_Escape) { root.close(); return true }
      if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) { root.showList(); return true }
      // A held key repeats, and a repeated ^d would flip the mirror back and
      // forth (seen once, on a busy machine whose key release came late).
      if (ctrl && event.isAutoRepeat && (event.key === Qt.Key_D || event.key === Qt.Key_A || event.key === Qt.Key_X)) return true
      if (ctrl && event.key === Qt.Key_D) { root.toggleAttach(); return true }
      if (ctrl && event.key === Qt.Key_A) { if (root.service) root.service.attachAll(); return true }
      if (ctrl && event.key === Qt.Key_X) { root.stopCurrentMirror(); return true }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.focusMirrorWindow(root.currentMirror); return true }
      if (event.key === Qt.Key_Left) { root.mirrorIndex = Android.moveIndex(root.mirrorIndex, -1, root.mirrorList.length); return true }
      if (event.key === Qt.Key_Right) { root.mirrorIndex = Android.moveIndex(root.mirrorIndex, 1, root.mirrorList.length); return true }
      return ctrl
    }

    if (ctrl && event.key === Qt.Key_M) { root.showMirrors(); return true }

    if (event.key === Qt.Key_Escape) {
      if (root.view === "details") root.showList()
      else if (root.filterText !== "") root.setFilter("")
      else root.close()
      return true
    }

    if (ctrl && event.key === Qt.Key_W) { root.wifi(); return true }
    if (ctrl && event.key === Qt.Key_P) { root.showWifi(1); return true }
    if (ctrl && event.key === Qt.Key_O) { root.showWifi(2); return true }
    if (ctrl && event.key === Qt.Key_D) { root.disconnect(); return true }
    if (ctrl && event.key === Qt.Key_S) { root.screenshot(); return true }
    if (ctrl && event.key === Qt.Key_T) { root.openShell(); return true }
    if (ctrl && event.key === Qt.Key_F) { root.forget(); return true }
    if (ctrl && event.key === Qt.Key_R) { if (root.service) root.service.refresh(true); return true }

    if (root.view === "details") {
      // ← goes back, as in the SSH manager; → and space still step an option
      // forward (they wrap), shift+space backwards.
      if (event.key === Qt.Key_Left || event.key === Qt.Key_Backspace) { root.showList(); return true }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.mirror(); return true }
      if (event.key === Qt.Key_Down) { root.optionIndex = Android.moveIndex(root.optionIndex, 1, Android.OPTION_SPECS.length); return true }
      if (event.key === Qt.Key_Up) { root.optionIndex = Android.moveIndex(root.optionIndex, -1, Android.OPTION_SPECS.length); return true }
      if (event.key === Qt.Key_Right) { root.stepOption(1); return true }
      if (event.key === Qt.Key_Space) { root.stepOption((event.modifiers & Qt.ShiftModifier) ? -1 : 1); return true }
      return false
    }

    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
      return true
    }
    if (event.key === Qt.Key_Down) { root.moveCursor(1); return true }
    if (event.key === Qt.Key_Up) { root.moveCursor(-1); return true }
    if (event.key === Qt.Key_Right) { root.showDetails(); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.mirror(); return true }

    if (Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
      return true
    }
    if (!ctrl && event.text && event.text.length === 1
        && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      root.setFilter(root.filterText + event.text)
      return true
    }
    return false
  }

  // Tab walks the fields of the current Wi-Fi tab and wraps; Enter submits.
  // Qt's own focus chain would leave the panel, so the order is spelled out.
  readonly property var fieldOrder: !root.keys ? []
    : root.wifiTab === 0 ? [ipField, portField]
    : root.wifiTab === 1 ? [pairAddressField, pairCodeField] : [manualField]

  function focusStep(delta) {
    var order = root.fieldOrder
    if (order.length === 0) return
    for (var i = 0; i < order.length; i++) {
      if (!order[i].activeFocus) continue
      order[(i + delta + order.length) % order.length].forceActiveFocus()
      return
    }
    order[0].forceActiveFocus()
  }

  // ---- Pieces.

  component Label: Text {
    textFormat: Text.PlainText
    color: root.contentForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.body
  }

  // A section's name, over its card.
  component Caption: Label {
    color: root.dim
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 0.5
    leftPadding: Style.space(6)
  }

  // Explanatory text between the cards: dimmer than the controls.
  component Note: Label {
    width: parent ? parent.width : 0
    color: root.dim
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
    leftPadding: Style.space(6)
    rightPadding: Style.space(6)
  }

  component Card: Rectangle {
    width: parent ? parent.width : 0
    radius: root.cardRadius
    color: root.tint
  }

  // A round face: the accent when on, a quiet tint when off, the urgent tint
  // for what is waiting on the user. Square on a theme with square corners.
  component Disc: Rectangle {
    id: disc
    property string tone: "quiet"       // on | quiet | urgent
    property bool muted: false
    property string glyph: ""
    property real size: Style.space(38)
    width: size
    height: size
    radius: root.rounded ? size / 2 : 0
    color: disc.tone === "on" ? root.onFill : disc.tone === "urgent" ? root.urgentFill : root.quietFill
    opacity: disc.muted ? 0.45 : 1

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    Label {
      anchors.centerIn: parent
      text: disc.glyph
      color: disc.tone === "on" ? root.surface : disc.tone === "urgent" ? Commons.Color.urgent : root.contentForeground
      font.pixelSize: Math.round(disc.size * 0.46)
    }
  }

  // A fact in the header. `on` is the accent, for a running mirror only.
  component Pill: Rectangle {
    id: pill
    property alias text: pillText.text
    property string tone: "quiet"       // on | quiet | urgent
    property bool dot: false
    readonly property color ink: pill.tone === "on" ? root.surface : pill.tone === "urgent" ? Commons.Color.urgent : root.dim
    width: pillRow.implicitWidth + Style.space(14)
    height: pillText.implicitHeight + Style.space(6)
    radius: root.rounded ? height / 2 : 0
    color: pill.tone === "on" ? root.onFill : pill.tone === "urgent" ? root.urgentFill : root.quietFill

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      Rectangle {
        visible: pill.dot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(6)
        height: width
        radius: width / 2
        color: pill.ink
      }
      Label {
        id: pillText
        color: pill.ink
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: pill.tone === "quiet" ? 0 : 0.5
      }
    }
  }

  // One exclusive choice: a row of segments, the chosen one filled.
  component Segments: Rectangle {
    id: segments
    property var labels: []
    property int current: -1
    property int segmentHeight: root.segmentHeight
    signal picked(int index)

    width: parent ? parent.width : 0
    height: segments.segmentHeight
    radius: root.rounded ? Style.space(10) : 0
    color: root.tint

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(3)

      Repeater {
        model: segments.labels

        Rectangle {
          id: segment
          required property int index
          required property string modelData
          readonly property bool on: segments.current === segment.index
          width: parent.width / Math.max(1, segments.labels.length)
          height: parent.height
          radius: root.rounded ? Style.space(8) : 0
          color: segment.on ? Util.alpha(root.contentForeground, 0.2) : "transparent"

          Behavior on color { ColorAnimation { duration: Style.duration(120) } }

          Label {
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - Style.space(6))
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: segment.modelData
            color: segment.on ? root.contentForeground : root.dim
            font.bold: segment.on
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: segments.picked(segment.index)
          }
        }
      }
    }
  }

  // A thing a phone can do, or a way onto Wi-Fi: a disc beside a name and
  // what it is doing. Lit only while it is on.
  component PowerTile: CursorSurface {
    id: tile
    property string label: ""
    property string status: ""
    property string glyph: ""
    property bool on: false
    property bool unavailable: false
    signal activated()

    height: Style.space(12) * 2 + Style.space(38)
    radius: root.cardRadius
    hasCursor: false
    color: root.tint
    foreground: root.contentForeground
    accent: Commons.Color.accent

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: tile.unavailable ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!tile.unavailable) tile.activated()
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Disc {
        tone: tile.on ? "on" : "quiet"
        muted: tile.unavailable
        glyph: tile.glyph
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(38) - Style.space(22)
        spacing: Style.space(1)

        Label {
          width: parent.width
          text: tile.label
          font.bold: true
          elide: Text.ElideRight
          color: tile.unavailable ? root.dim : root.contentForeground
        }
        Label {
          width: parent.width
          text: tile.status
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }

  // One of the details view's three actions: a large disc over its name.
  component ActionTile: CursorSurface {
    id: action
    property string label: ""
    property string glyph: ""
    property bool on: false
    property bool unavailable: false
    signal activated()

    height: actionColumn.implicitHeight + Style.space(24)
    radius: root.cardRadius
    hasCursor: false
    color: root.tint
    foreground: root.contentForeground
    accent: Commons.Color.accent

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: action.unavailable ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!action.unavailable) action.activated()
    }

    Column {
      id: actionColumn
      anchors.centerIn: parent
      spacing: Style.space(8)

      Disc {
        anchors.horizontalCenter: parent.horizontalCenter
        size: Style.space(44)
        tone: action.on ? "on" : "quiet"
        muted: action.unavailable
        glyph: action.glyph
      }
      Label {
        anchors.horizontalCenter: parent.horizontalCenter
        text: action.label
        color: action.on ? root.contentForeground : root.dim
        font.bold: action.on
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // A round icon button: the card headers' detach and stop.
  component RoundButton: Button {
    property real size: Style.space(36)
    width: size
    height: size
    radius: root.rounded ? size / 2 : 0
    background: root.quietFill
    foreground: root.contentForeground
    accent: root.accentColor
    fontFamily: root.contentFontFamily
    iconSize: Math.round(size * 0.42)
    horizontalPadding: 0
    verticalPadding: 0
  }

  // A view's one main action, full width.
  component WideButton: Button {
    width: parent ? parent.width : 0
    height: Style.space(44)
    radius: root.innerRadius
    background: root.quietFill
    foreground: enabled ? root.contentForeground : root.dim
    accent: root.accentColor
    fontFamily: root.contentFontFamily
  }

  // One button on a tile's rail: an icon, its name on hover.
  component RailButton: Button {
    required property var modelData
    property string deviceKey: ""
    property int tileIndex: 0
    width: root.railButton
    height: root.railButton
    radius: root.rounded ? root.railButton / 2 : 0
    iconText: modelData.icon
    iconSize: Math.round(Style.font.icon * 1.3)
    tooltipText: modelData.label
    foreground: root.contentForeground
    accent: root.accentColor
    fontFamily: root.contentFontFamily
    onClicked: {
      root.mirrorIndex = tileIndex
      if (!root.service) return
      if (modelData.key === "screenshot") root.service.screenshot(deviceKey)
      else root.service.pressKey(deviceKey, modelData.key)
    }
  }

  component KeyHint: Row {
    id: keyHint
    required property var modelData
    spacing: Style.space(4)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: keyText.implicitWidth + Style.space(8)
      height: keyText.implicitHeight + Style.space(2)
      radius: root.rounded ? Style.space(4) : 0
      color: root.quietFill

      Label {
        id: keyText
        anchors.centerIn: parent
        text: keyHint.modelData[0]
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
    Label {
      anchors.verticalCenter: parent.verticalCenter
      text: keyHint.modelData[1]
      color: root.dim
      font.pixelSize: Style.font.caption
    }
  }

  // A missing tool: what is missing, what still works, and the fix.
  component MissingCard: Card {
    id: missing
    property string title: ""
    property string body: ""
    property string fix: ""
    height: missingColumn.implicitHeight + Style.space(36)

    Column {
      id: missingColumn
      anchors.centerIn: parent
      width: parent.width - Style.space(36)
      spacing: Style.space(12)

      Disc {
        anchors.horizontalCenter: parent.horizontalCenter
        size: Style.space(52)
        tone: "urgent"
        glyph: root.glyphPackage
      }
      Column {
        width: parent.width
        spacing: Style.space(4)

        Label {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: missing.title
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }
        Label {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: missing.body
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
      Rectangle {
        width: parent.width
        height: fixText.implicitHeight + Style.space(18)
        radius: root.innerRadius
        color: root.quietFill

        Label {
          id: fixText
          anchors.centerIn: parent
          width: parent.width - Style.space(20)
          horizontalAlignment: Text.AlignHCenter
          text: missing.fix
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }

  // Caption over an input, as the Wi-Fi tabs lay them out.
  component Field: Column {
    id: field
    required property string label
    spacing: Style.space(5)

    Caption { text: field.label }
  }

  component Input: TextField {
    width: parent ? parent.width : 0
    foreground: root.contentForeground
    accent: root.accentColor
    font.family: root.contentFontFamily

    onAccepted: root.submitWifi()
    Keys.onTabPressed: function(event) { root.focusStep(1); event.accepted = true }
    Keys.onBacktabPressed: function(event) { root.focusStep(-1); event.accepted = true }
  }

  // One phone: a disc that is lit while it mirrors, its name, how it is
  // connected, and what it is doing. A click picks it; a double click does
  // what enter does, a right click opens it.
  component DeviceRow: CursorSurface {
    id: row

    required property int index
    required property var modelData
    readonly property bool waiting: row.modelData.state === Android.STATE_UNAUTHORIZED

    width: parent ? parent.width : 0
    height: root.rowHeight
    radius: root.innerRadius
    hasCursor: root.cursorActive && root.selectedIndex === index
    foreground: root.contentForeground
    accent: Commons.Color.accent
    fill: root.hoverFill
    currentFill: root.selectedFill

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        root.cursorActive = true
        root.selectedIndex = row.index
        if (mouse.button === Qt.RightButton) root.showDetails()
      }
      onDoubleClicked: function(mouse) { if (mouse.button === Qt.LeftButton) root.mirror() }
    }

    Disc {
      id: rowDisc
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      tone: row.modelData.state === Android.STATE_MIRRORING ? "on" : row.waiting ? "urgent" : "quiet"
      muted: root.isAbsent(row.modelData)
      glyph: row.waiting ? "◐" : root.glyphPhone
    }

    Column {
      anchors.left: rowDisc.right
      anchors.leftMargin: Style.space(12)
      anchors.right: side.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Label {
        width: parent.width
        text: row.modelData.name
        color: root.isAbsent(row.modelData) ? root.dim : root.contentForeground
        font.bold: true
        elide: Text.ElideRight
      }
      Label {
        width: parent.width
        text: Android.rowSubtitle(row.modelData)
        color: root.dim
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    Column {
      id: side
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(Math.max(statusText.implicitWidth, metaText.implicitWidth), row.width * 0.36)
      spacing: Style.space(2)

      Label {
        id: statusText
        width: parent.width
        horizontalAlignment: Text.AlignRight
        text: Android.markFor(row.modelData.state) + " " + Android.rowStatus(row.modelData)
        color: root.colorFor(row.modelData.state)
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideLeft
      }
      Label {
        id: metaText
        width: parent.width
        horizontalAlignment: Text.AlignRight
        text: Android.rowMeta(row.modelData)
        color: root.dim
        font.pixelSize: Style.font.caption
        elide: Text.ElideLeft
      }
    }
  }

  // A found or remembered address in the Wi-Fi tabs.
  component AddressRow: CursorSurface {
    id: address
    required property int index
    required property var modelData
    property string glyph: root.glyphPhone
    property string note: ""

    width: parent ? parent.width : 0
    height: root.rowHeight
    radius: root.innerRadius
    hasCursor: root.suggestionIndex === index
    foreground: root.contentForeground
    accent: Commons.Color.accent
    fill: root.hoverFill
    currentFill: root.selectedFill

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.pickSuggestion(address.index)
    }

    Disc {
      id: addressDisc
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      glyph: address.glyph
    }
    Column {
      anchors.left: addressDisc.right
      anchors.leftMargin: Style.space(12)
      anchors.right: addressText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Label {
        width: parent.width
        text: address.modelData.label
        font.bold: true
        elide: Text.ElideRight
      }
      Label {
        width: parent.width
        visible: address.note !== ""
        text: address.note
        color: root.dim
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
    Label {
      id: addressText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, address.width * 0.5)
      horizontalAlignment: Text.AlignRight
      text: address.modelData.address
      color: root.dim
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideLeft
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    // Every view is at least as wide as its header, so the title is never
    // cut to "…"; the list's width is computed (listCardWidth) so the Mirrors
    // view can line its switch up with it.
    contentWidth: root.view === "list" ? root.listCardWidth
      : panel.fittedContentWidth(Math.max(Style.space(380), Math.ceil(Math.max(root.headerMinWidth,
          root.view === "mirrors" ? root.tilesWidth : 0) + root.cardInsetX)))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    Behavior on contentWidth {
      enabled: root.resizing
      NumberAnimation { duration: root.resizeDuration; easing.type: Easing.OutCubic }
    }
    Behavior on contentHeight {
      enabled: root.resizing
      NumberAnimation { duration: root.resizeDuration; easing.type: Easing.OutCubic }
    }

    // The whole screen catches clicks (to dismiss), except the holes.
    mask: Region {
      width: panel.screenW
      height: panel.screenH
      Region { item: root.holeAt(0); intersection: Intersection.Subtract }
      Region { item: root.holeAt(1); intersection: Intersection.Subtract }
      Region { item: root.holeAt(2); intersection: Intersection.Subtract }
    }

    content: Item {
      id: keys
      // Reached from the panel's own code through the root properties of the
      // same names (null until the first open).
      property alias cardFill: cardFill
      property alias column: column
      property alias headerBar: headerBar
      property alias titleLabel: titleLabel
      property alias headerPills: headerPills
      property alias listScroll: listScroll
      property alias detailsScroll: detailsScroll
      property alias detailsColumn: detailsColumn
      property alias ipField: ipField
      property alias portField: portField
      property alias pairAddressField: pairAddressField
      property alias pairCodeField: pairCodeField
      property alias manualField: manualField
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      focus: true
      clip: root.resizing

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { event.accepted = root.handleKey(event) }

      // The card's fill while there are holes in it, inside the card's border.
      Shape {
        id: cardFill
        visible: root.holesOpen && root.card !== null
        z: -1
        x: root.card ? -(root.card.contentLeftInset - root.card.borderLeft) : 0
        y: root.card ? -(root.card.contentTopInset - root.card.borderTop) : 0
        width: root.card ? root.card.width - root.card.borderLeft - root.card.borderRight : 0
        height: root.card ? root.card.height - root.card.borderTop - root.card.borderBottom : 0
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          fillColor: Commons.Color.popups.background
          strokeWidth: -1
          fillRule: ShapePath.OddEvenFill

          PathRectangle {
            width: cardFill.width
            height: cardFill.height
            radius: root.card ? Math.max(0, root.card.radius - root.card.borderLeft) : 0
          }
          PathRectangle { x: root.holeRect(0).x; y: root.holeRect(0).y; width: root.holeRect(0).w; height: root.holeRect(0).h }
          PathRectangle { x: root.holeRect(1).x; y: root.holeRect(1).y; width: root.holeRect(1).w; height: root.holeRect(1).h }
          PathRectangle { x: root.holeRect(2).x; y: root.holeRect(2).y; width: root.holeRect(2).w; height: root.holeRect(2).h }
        }
      }

      Column {
        id: column
        width: parent.width
        spacing: root.sectionGap

        // ---- Header: what this is, and the facts as pills.
        Item {
          id: headerBar
          width: parent.width
          implicitHeight: Math.max(titleRow.implicitHeight, headerPills.implicitHeight)

          Row {
            id: titleRow
            anchors.left: parent.left
            anchors.leftMargin: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(7)

            Label {
              anchors.verticalCenter: parent.verticalCenter
              text: root.subView ? root.glyphBack : root.glyphPhone
              color: !root.subView && root.service && root.service.mirrorCount > 0 ? Commons.Color.accent : root.dim
              font.pixelSize: Style.font.icon

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                enabled: root.subView
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showList()
              }
            }
            Label {
              id: titleLabel
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, headerBar.width - headerPills.implicitWidth - Style.space(48))
              text: root.titleText
              font.bold: true
              font.pixelSize: Style.font.subtitle
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerPills
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Pill {
              visible: root.factText !== ""
              text: root.factText
            }
            Pill {
              visible: root.statusPill !== null
              text: root.statusPill ? root.statusPill.text : ""
              tone: root.statusPill ? root.statusPill.tone : "quiet"
              dot: root.statusPill !== null && root.statusPill.tone === "on"
            }
          }
        }

        // ---- Devices | Mirrors.
        Segments {
          x: root.switchX
          width: root.switchWidth
          visible: (root.view === "list" || root.view === "mirrors") && !root.adbMissing
          labels: ["Devices " + root.allRows.length, "Mirrors " + root.mirrorList.length]
          current: root.view === "mirrors" ? 1 : 0
          onPicked: function(index) { index === 1 ? root.showMirrors() : root.showList() }
        }

        // ---- Devices.
        Column {
          width: parent.width
          visible: root.view === "list"
          spacing: root.sectionGap

          // Typing filters; this only shows what has been typed.
          Rectangle {
            width: parent.width
            visible: !root.adbMissing && root.allRows.length > 0
            height: Math.max(Style.space(40), Style.font.body + Style.space(22))
            radius: root.innerRadius
            color: root.tint

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Label {
                anchors.verticalCenter: parent.verticalCenter
                text: root.glyphSearch
                color: root.dim
                font.pixelSize: Style.font.icon
              }
              Label {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(40)
                text: root.filterText === "" ? "Filter devices…" : root.filterText
                color: root.filterText === "" ? root.dim : root.contentForeground
                elide: Text.ElideRight
              }
            }
          }

          Card {
            visible: root.rows.length > 0
            height: root.listHeight + 2 * root.listPad

            Flickable {
              id: listScroll
              x: root.listPad
              y: root.listPad
              width: parent.width - 2 * root.listPad
              height: root.listHeight
              contentWidth: width
              contentHeight: root.rows.length * root.rowHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              Column {
                width: listScroll.width
                Repeater {
                  model: root.view === "list" ? root.rows : []
                  delegate: DeviceRow {}
                }
              }
            }
          }

          Note {
            visible: !root.service || !root.service.scanned
            text: "Looking for phones…"
          }

          Note {
            visible: root.rows.length === 0 && root.allRows.length > 0
            text: "No phone matches “" + root.filterText + "”"
          }

          // The phone under the cursor, as two things to press.
          Column {
            width: parent.width
            visible: root.currentRow !== null && root.currentRow.state !== Android.STATE_UNAUTHORIZED
            spacing: Style.space(6)

            Caption { text: root.currentRow ? root.currentRow.name : "" }

            Row {
              width: parent.width
              spacing: Style.space(10)

              PowerTile {
                width: (parent.width - parent.spacing) / 2
                readonly property var row: root.currentRow
                glyph: root.glyphMirror
                on: !!row && row.state === Android.STATE_MIRRORING
                unavailable: !!row && !root.isAbsent(row) && root.scrcpyMissing
                label: root.isAbsent(row) ? "Reconnect" : on ? "Mirroring" : "Mirror"
                status: !row ? ""
                  : root.isAbsent(row) ? (row.address ? row.address : "plug in once")
                  : root.scrcpyMissing ? "needs scrcpy"
                  : on ? (row.mirror && row.mirror.mode === "attached" ? "In the panel" : "In its own window")
                  : "Off"
                onActivated: root.mirror()
              }
              PowerTile {
                width: (parent.width - parent.spacing) / 2
                readonly property var row: root.currentRow
                glyph: root.glyphWifi
                on: root.onWifi(row)
                label: "Wi-Fi :" + Android.DEFAULT_PORT
                status: !row ? ""
                  : on ? row.address.replace(/:[0-9]+$/, "")
                  : root.usbRows.indexOf(row) >= 0 ? "Off USB"
                  : root.isAbsent(row) ? "Connect by address"
                  : "Off"
                onActivated: root.wifi()
              }
            }
          }

          // A phone that has not been allowed yet.
          Card {
            visible: root.currentRow !== null && root.currentRow.state === Android.STATE_UNAUTHORIZED
            height: askColumn.implicitHeight + Style.space(28)

            Column {
              id: askColumn
              anchors.centerIn: parent
              width: parent.width - Style.space(32)
              spacing: Style.space(6)

              Label {
                width: parent.width
                text: "The phone is asking"
                font.bold: true
              }
              Label {
                width: parent.width
                text: "Unlock it and tap Allow on “Allow USB debugging?”. Tick “Always allow from this computer” to skip this next time."
                color: root.dim
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Label {
                width: parent.width
                text: "The list updates on its own."
                color: root.dim
                font.pixelSize: Style.font.caption
              }
            }
          }

          MissingCard {
            visible: root.scrcpyMissing && !root.adbMissing
            title: "scrcpy is not installed"
            body: "Phones still list and connect through adb. Mirroring needs scrcpy."
            fix: "sudo pacman -S scrcpy"
          }

          MissingCard {
            visible: root.adbMissing
            title: "adb is not installed"
            body: "Without android-tools no phone can be listed or reached."
            fix: "sudo pacman -S android-tools"
          }

          // No phones at all: how to get one here.
          Column {
            width: parent.width
            visible: !!root.service && root.service.scanned && !root.adbMissing && root.allRows.length === 0
            spacing: root.sectionGap

            Disc {
              anchors.horizontalCenter: parent.horizontalCenter
              size: Style.space(52)
              glyph: root.glyphPhone
            }
            Label {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "No phones"
              font.bold: true
              font.pixelSize: Style.font.subtitle
            }
            Card {
              height: stepsColumn.implicitHeight + Style.space(12)

              Column {
                id: stepsColumn
                x: Style.space(14)
                y: Style.space(6)
                width: parent.width - Style.space(28)

                Repeater {
                  model: ["Plug the phone in with a data cable", "Turn on Developer options › USB debugging",
                    "Already on Wi-Fi? Pair it with a code"]
                  delegate: Item {
                    required property int index
                    required property string modelData
                    width: parent.width
                    height: Math.max(Style.space(40), stepText.implicitHeight + Style.space(16))

                    PanelSeparator {
                      visible: index > 0
                      anchors.top: parent.top
                      width: parent.width
                      foreground: root.contentForeground
                      strength: 0.08
                    }
                    Rectangle {
                      id: stepNumber
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(22)
                      height: width
                      radius: root.rounded ? width / 2 : 0
                      color: root.quietFill

                      Label {
                        anchors.centerIn: parent
                        text: String(index + 1)
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                    Label {
                      id: stepText
                      anchors.left: stepNumber.right
                      anchors.leftMargin: Style.space(12)
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(10)

              PowerTile {
                width: (parent.width - parent.spacing) / 2
                glyph: root.glyphLink
                label: "Pairing code"
                status: "Android 11+"
                onActivated: root.showWifi(1)
              }
              PowerTile {
                width: (parent.width - parent.spacing) / 2
                glyph: root.glyphWifi
                label: "ip:port"
                status: "adb connect"
                onActivated: root.showWifi(2)
              }
            }
          }
        }

        // ---- Mirrors.
        Card {
          visible: root.view === "mirrors" && root.mirrorList.length === 0
          width: parent.width
          height: emptyMirrors.implicitHeight + Style.space(40)

          Column {
            id: emptyMirrors
            anchors.centerIn: parent
            width: parent.width - Style.space(40)
            spacing: Style.space(10)

            Disc {
              anchors.horizontalCenter: parent.horizontalCenter
              size: Style.space(52)
              glyph: root.glyphMirror
            }
            Label {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "No mirrors running"
              font.bold: true
              font.pixelSize: Style.font.subtitle
            }
            Label {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "Pick a phone under Devices and press enter."
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }

        Row {
          visible: root.view === "mirrors" && root.mirrorList.length > 0
          spacing: root.cardsGap

          Repeater {
            // Keyed by phone, through a string, so the cards survive every
            // change to a mirror's state: an array model would rebuild them
            // all, and a rebuilt tile flicks its window's hole off and on.
            model: root.view === "mirrors" && root.mirrorKeys !== "" ? root.mirrorKeys.split("\n") : []
            delegate: Item {
              id: mirrorCard
              required property int index
              required property string modelData
              readonly property var entry: root.mirrorEntry(modelData)
              readonly property bool attached: root.isAttached(entry)
              readonly property bool picked: root.mirrorIndex === index
              readonly property int tileWidth: root.tileWidthFor(entry)
              readonly property int bodyY: root.cardPad + root.cardHeadHeight + root.cardGap

              width: root.cardWidthFor(entry)
              height: root.cardsHeight

              // The card's tint, with the phone's hole left out: anything
              // painted there would sit over the phone's window.
              Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                  fillColor: root.tint
                  strokeWidth: -1
                  fillRule: ShapePath.OddEvenFill

                  PathRectangle { width: mirrorCard.width; height: mirrorCard.height; radius: root.cardRadius }
                  PathRectangle {
                    x: root.cardPad + root.tileInset
                    y: mirrorCard.bodyY + root.tileInset
                    width: mirrorCard.attached ? mirrorCard.tileWidth - 2 * root.tileInset : 0
                    height: mirrorCard.attached ? root.tileHeight - 2 * root.tileInset : 0
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.mirrorIndex = mirrorCard.index
              }

              // Name, settings, and the card's two buttons.
              Item {
                x: root.cardPad
                y: root.cardPad
                width: parent.width - 2 * root.cardPad
                height: root.cardHeadHeight

                Disc {
                  id: cardDisc
                  size: root.cardHeadHeight
                  tone: "on"
                  glyph: root.glyphPhone
                }
                Column {
                  anchors.left: cardDisc.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: cardButtons.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Label {
                    width: parent.width
                    text: mirrorCard.entry.name
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Label {
                    width: parent.width
                    text: root.mirrorSub(mirrorCard.entry)
                    color: root.dim
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
                Row {
                  id: cardButtons
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  // One button both ways, like ^d: out to its own window, or
                  // back into the panel.
                  RoundButton {
                    iconText: mirrorCard.attached ? root.glyphOut : root.glyphIn
                    tooltipText: mirrorCard.attached ? "Move to its own window  ^d" : "Back into the panel  ^d"
                    onClicked: {
                      root.mirrorIndex = mirrorCard.index
                      root.toggleAttach()
                    }
                  }
                  RoundButton {
                    iconText: root.glyphStop
                    tooltipText: "Stop mirroring  ^x"
                    onClicked: if (root.service) root.service.stopMirror(mirrorCard.entry.key)
                  }
                }
              }

              // In the panel: the phone's tile, and its rail of buttons.
              Row {
                visible: mirrorCard.attached
                x: root.cardPad
                y: mirrorCard.bodyY
                spacing: root.railGap

                Rectangle {
                  width: mirrorCard.tileWidth
                  height: root.tileHeight
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: mirrorCard.picked ? Math.max(1, Style.space(2)) : 1
                  border.color: mirrorCard.picked ? root.accentColor : root.hairline

                  Loader {
                    id: tileLoader
                    anchors.fill: parent
                    anchors.margins: root.tileInset
                    active: mirrorCard.attached
                    source: Qt.resolvedUrl("MirrorTile.qml")

                    Binding { target: tileLoader.item; property: "service"; value: root.service; when: tileLoader.item !== null }
                    Binding { target: tileLoader.item; property: "panel"; value: root; when: tileLoader.item !== null }
                    Binding { target: tileLoader.item; property: "deviceKey"; value: mirrorCard.entry.key; when: tileLoader.item !== null }
                    Binding { target: tileLoader.item; property: "mirror"; value: mirrorCard.entry.mirror; when: tileLoader.item !== null }
                    Binding { target: tileLoader.item; property: "shown"; value: root.mirrorsShown; when: tileLoader.item !== null }
                    Binding { target: tileLoader.item; property: "foreground"; value: root.contentForeground; when: tileLoader.item !== null }
                    Binding { target: tileLoader.item; property: "fontFamily"; value: root.contentFontFamily; when: tileLoader.item !== null }
                  }
                }

                // The phone's buttons: keys over adb, and a screenshot, in
                // three groups spread down the phone's height.
                Rectangle {
                  width: root.railWidth
                  height: root.tileHeight
                  radius: root.rounded ? Math.min(root.cardRadius, root.railWidth / 2) : 0
                  color: root.tint

                  Column {
                    anchors.top: parent.top
                    anchors.topMargin: Style.space(5)
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(2)
                    Repeater {
                      model: mirrorCard.attached ? Android.mirrorActions(0) : []
                      delegate: RailButton { deviceKey: mirrorCard.entry.key; tileIndex: mirrorCard.index }
                    }
                  }
                  Column {
                    anchors.centerIn: parent
                    spacing: Style.space(2)
                    Repeater {
                      model: mirrorCard.attached ? Android.mirrorActions(1) : []
                      delegate: RailButton { deviceKey: mirrorCard.entry.key; tileIndex: mirrorCard.index }
                    }
                  }
                  Column {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(5)
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(2)
                    Repeater {
                      model: mirrorCard.attached ? Android.mirrorActions(2) : []
                      delegate: RailButton { deviceKey: mirrorCard.entry.key; tileIndex: mirrorCard.index }
                    }
                  }
                }
              }

              // In its own window: where it went, and the way back.
              Item {
                visible: !mirrorCard.attached
                x: root.cardPad
                y: mirrorCard.bodyY
                width: parent.width - 2 * root.cardPad
                height: parent.height - mirrorCard.bodyY - root.cardPad

                Shape {
                  id: dashed
                  readonly property real stroke: Math.max(1, Style.space(2))
                  anchors.fill: parent
                  preferredRendererType: Shape.CurveRenderer

                  ShapePath {
                    fillColor: "transparent"
                    strokeColor: mirrorCard.picked ? root.accentColor : root.hairline
                    strokeWidth: dashed.stroke
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [3, 3]

                    PathRectangle {
                      x: dashed.stroke / 2
                      y: dashed.stroke / 2
                      width: dashed.width - dashed.stroke
                      height: dashed.height - dashed.stroke
                      radius: root.innerRadius
                    }
                  }
                }

                Column {
                  anchors.centerIn: parent
                  width: parent.width - Style.space(32)
                  spacing: Style.space(14)

                  Disc {
                    anchors.horizontalCenter: parent.horizontalCenter
                    size: Style.space(56)
                    glyph: root.glyphWindow
                  }
                  Column {
                    width: parent.width
                    spacing: Style.space(4)

                    Label {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      text: "In its own window"
                      font.bold: true
                    }
                    Label {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      text: "Floating, sized to the phone"
                      color: root.dim
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.WordWrap
                    }
                  }
                  Column {
                    width: parent.width
                    spacing: Style.space(6)

                    WideButton {
                      text: "Focus the window"
                      tooltipText: "enter"
                      onClicked: root.focusMirrorWindow(mirrorCard.entry)
                    }
                  }
                }
              }
            }
          }
        }

        // ---- Details: what to do with the phone, how it mirrors, what it is.
        //      Taller than a 1080-high screen leaves room for, so it scrolls,
        //      and the cursor's option is kept in view.
        Flickable {
          id: detailsScroll
          width: parent.width
          visible: root.view === "details" && root.focusRow !== null
          height: Math.min(detailsColumn.implicitHeight, panel.availableCardHeight > 0
            ? Math.max(Style.space(240), panel.availableCardHeight - panel.verticalContentInset - root.detailsChrome)
            : detailsColumn.implicitHeight)
          contentWidth: width
          contentHeight: detailsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: detailsColumn
            width: parent.width
            spacing: root.sectionGap

            Row {
              width: parent.width
              spacing: Style.space(10)

              ActionTile {
                width: (parent.width - 2 * parent.spacing) / 3
                readonly property var row: root.focusRow
                glyph: root.glyphMirror
                on: !!row && row.state === Android.STATE_MIRRORING
                unavailable: !row || row.state === Android.STATE_UNAUTHORIZED || (!root.isAbsent(row) && root.scrcpyMissing)
                label: root.isAbsent(row) ? "Reconnect" : on ? "Mirroring" : "Mirror"
                onActivated: root.mirror()
              }
              ActionTile {
                width: (parent.width - 2 * parent.spacing) / 3
                glyph: root.glyphCamera
                unavailable: !root.focusRow || root.focusRow.target === ""
                label: "Screenshot"
                onActivated: root.screenshot()
              }
              ActionTile {
                width: (parent.width - 2 * parent.spacing) / 3
                glyph: root.glyphShell
                unavailable: !root.focusRow || root.focusRow.target === ""
                label: "Shell"
                onActivated: root.openShell()
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Caption { text: "MIRROR · saved for this phone" }

              Card {
                height: choicesColumn.implicitHeight + Style.space(8)

                Column {
                  id: choicesColumn
                  x: Style.space(4)
                  y: Style.space(4)
                  width: parent.width - Style.space(8)
                  spacing: Style.space(2)

                  Repeater {
                    model: root.view === "details" ? root.optionGroup(false) : []
                    delegate: CursorSurface {
                      id: choice
                      required property var modelData
                      readonly property var spec: modelData.spec
                      readonly property var value: root.focusRow ? Android.normalizeOptions(root.focusRow.options)[spec.key] : null

                      width: parent.width
                      height: choiceColumn.implicitHeight + Style.space(14)
                      radius: root.innerRadius
                      hasCursor: root.optionIndex === modelData.index
                      foreground: root.contentForeground
                      accent: Commons.Color.accent
                      fill: root.hoverFill
                      currentFill: root.selectedFill
                      onHasCursorChanged: if (hasCursor) root.revealOption(choice)

                      Column {
                        id: choiceColumn
                        x: Style.space(6)
                        y: Style.space(7)
                        width: parent.width - Style.space(12)
                        spacing: Style.space(6)

                        Item {
                          width: parent.width
                          height: choiceName.implicitHeight

                          Label {
                            id: choiceName
                            x: Style.space(4)
                            text: choice.spec.label
                            color: root.dim
                            font.pixelSize: Style.font.bodySmall
                            font.bold: true
                          }
                          // An arrow on the selected setting, so it is
                          // discoverable that → changes it.
                          Label {
                            anchors.right: parent.right
                            anchors.rightMargin: Style.space(4)
                            text: {
                              var v = root.choiceLabel(choice.spec, choice.value, true)
                              return choice.hasCursor ? v + " ›" : v
                            }
                            color: choice.hasCursor ? root.accentColor : root.dim
                            font.pixelSize: Style.font.bodySmall
                            font.bold: true
                          }
                        }
                        Segments {
                          segmentHeight: root.choiceHeight
                          labels: choice.spec.choices.map(function(v) { return root.choiceLabel(choice.spec, v, false) })
                          current: choice.spec.choices.indexOf(choice.value)
                          onPicked: function(index) {
                            root.optionIndex = choice.modelData.index
                            root.setOption(choice.spec.key, choice.spec.choices[index])
                          }
                        }
                      }
                    }
                  }
                }
              }

              Card {
                height: togglesColumn.implicitHeight + Style.space(8)

                Column {
                  id: togglesColumn
                  x: Style.space(4)
                  y: Style.space(4)
                  width: parent.width - Style.space(8)

                  Repeater {
                    model: root.view === "details" ? root.optionGroup(true) : []
                    delegate: CursorSurface {
                      id: toggleRow
                      required property int index
                      required property var modelData
                      readonly property var spec: modelData.spec

                      width: parent.width
                      height: Math.max(Style.space(50), toggleText.implicitHeight + Style.space(16))
                      radius: root.innerRadius
                      hasCursor: root.optionIndex === modelData.index
                      foreground: root.contentForeground
                      accent: Commons.Color.accent
                      fill: root.hoverFill
                      currentFill: root.selectedFill
                      onHasCursorChanged: if (hasCursor) root.revealOption(toggleRow)

                      PanelSeparator {
                        visible: toggleRow.index > 0
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(10)
                        width: parent.width - Style.space(20)
                        foreground: root.contentForeground
                        strength: 0.08
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.optionIndex = toggleRow.modelData.index
                          root.stepOption(1)
                        }
                      }

                      Column {
                        id: toggleText
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(10)
                        anchors.right: toggleSwitch.left
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(1)

                        Label {
                          width: parent.width
                          text: toggleRow.spec.label
                          font.bold: true
                          elide: Text.ElideRight
                        }
                        Label {
                          width: parent.width
                          text: root.optionNotes[toggleRow.spec.key] || ""
                          color: root.dim
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                      }

                      ToggleSwitch {
                        id: toggleSwitch
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        interactive: false
                        trackHeight: Style.space(18)
                        checked: !!root.focusRow && Android.normalizeOptions(root.focusRow.options)[toggleRow.spec.key] === true
                        foreground: root.contentForeground
                      }
                    }
                  }
                }
              }

              Label {
                width: parent.width
                leftPadding: Style.space(6)
                rightPadding: Style.space(6)
                text: root.focusRow ? Android.commandPreview(root.focusRow, "window", { title: root.focusRow.name }) : ""
                color: root.dim
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Caption { text: "DEVICE" }

              Card {
                height: infoColumn.implicitHeight + Style.space(8)

                Column {
                  id: infoColumn
                  x: Style.space(14)
                  y: Style.space(4)
                  width: parent.width - Style.space(28)

                  Repeater {
                    model: root.view === "details" && root.focusRow ? Android.infoRows(root.focusRow) : []
                    delegate: Item {
                      required property int index
                      required property var modelData
                      width: parent.width
                      height: infoKey.implicitHeight + Style.space(16)

                      PanelSeparator {
                        visible: index > 0
                        anchors.top: parent.top
                        width: parent.width
                        foreground: root.contentForeground
                        strength: 0.08
                      }
                      Label {
                        id: infoKey
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.k
                        color: root.dim
                        font.pixelSize: Style.font.bodySmall
                      }
                      Label {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, parent.width - infoKey.implicitWidth - Style.space(12))
                        horizontalAlignment: Text.AlignRight
                        text: modelData.v
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideLeft
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---- Wi-Fi: the three ways on.
        Segments {
          visible: root.view === "wifi"
          labels: ["USB → :" + Android.DEFAULT_PORT, "Pairing code", "ip:port"]
          current: root.wifiTab
          onPicked: function(index) { root.setWifiTab(index) }
        }

        // ---- Wi-Fi: USB → port.
        Column {
          width: parent.width
          visible: root.view === "wifi" && root.wifiTab === 0
          spacing: root.sectionGap

          // The phone this switches, and ↑↓ to pick another.
          Card {
            height: Style.space(44) + Style.space(20)

            Disc {
              id: usbDisc
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              size: Style.space(44)
              muted: root.usbRow === null
              glyph: root.glyphUsb
            }
            Column {
              anchors.left: usbDisc.right
              anchors.leftMargin: Style.space(12)
              anchors.right: usbPick.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Label {
                width: parent.width
                text: root.usbRow ? root.usbRow.name : "No phone on USB"
                color: root.usbRow ? root.contentForeground : root.dim
                font.bold: true
                elide: Text.ElideRight
              }
              Label {
                width: parent.width
                text: root.usbRow ? "On USB · the phone this switches" : "Plug one in and allow USB debugging"
                color: root.dim
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }
            KeyHint {
              id: usbPick
              anchors.right: parent.right
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.usbRows.length > 1
              modelData: ["↑↓", (root.usbRows.indexOf(root.usbRow) + 1) + " of " + root.usbRows.length]
            }
          }

          Note {
            text: "Tells adb on the phone to listen on the port, then connects over Wi-Fi. "
              + "Unplug once it shows as wi-fi. It lasts until the phone reboots."
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Field {
              label: "PHONE IP · read from the phone if empty"
              width: (parent.width - parent.spacing) * 0.66
              Input { id: ipField; placeholderText: "192.168.1.20" }
            }
            Field {
              label: "PORT"
              width: (parent.width - parent.spacing) * 0.34
              Input { id: portField; placeholderText: String(Android.DEFAULT_PORT); inputMethodHints: Qt.ImhDigitsOnly }
            }
          }

          // ✓ ● ○ as each step happens.
          Card {
            id: wifiStepsCard
            readonly property var steps: root.service && root.service.wifiKey === (root.usbRow ? root.usbRow.key : root.focusKey)
              ? root.service.wifiSteps : []
            visible: steps.length > 0
            height: wifiStepsColumn.implicitHeight + Style.space(12)

            Column {
              id: wifiStepsColumn
              x: Style.space(14)
              y: Style.space(6)
              width: parent.width - Style.space(28)

              Repeater {
                model: wifiStepsCard.steps
                delegate: Item {
                  id: step
                  required property int index
                  required property var modelData
                  readonly property string status: modelData.status
                  width: parent.width
                  height: Math.max(Style.space(42), stepLabel.implicitHeight + Style.space(18))

                  PanelSeparator {
                    visible: step.index > 0
                    anchors.top: parent.top
                    width: parent.width
                    foreground: root.contentForeground
                    strength: 0.08
                  }
                  Rectangle {
                    id: stepDot
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    height: width
                    radius: root.rounded ? width / 2 : 0
                    color: step.status === "ok" ? root.onFill
                      : step.status === "run" ? Util.alpha(Commons.Color.accent, 0.22)
                      : step.status === "fail" ? root.urgentFill
                      : Util.alpha(root.contentForeground, 0.08)

                    Label {
                      anchors.centerIn: parent
                      text: step.status === "ok" ? "✓" : step.status === "fail" ? "✕" : step.status === "run" ? "●" : "○"
                      color: step.status === "ok" ? root.surface
                        : step.status === "run" ? root.accentColor
                        : step.status === "fail" ? Commons.Color.urgent : root.dim
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                  Label {
                    id: stepLabel
                    anchors.left: stepDot.right
                    anchors.leftMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    width: (parent.width - stepDot.width - Style.space(12)) * 0.5
                    text: step.modelData.label
                    color: step.status === "wait" ? root.dim : root.contentForeground
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Label {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: (parent.width - stepDot.width - Style.space(12)) * 0.5 - Style.space(8)
                    horizontalAlignment: Text.AlignRight
                    text: step.modelData.detail
                    color: step.status === "run" ? root.accentColor : step.status === "fail" ? Commons.Color.urgent : root.dim
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideLeft
                  }
                }
              }
            }
          }

          WideButton {
            enabled: root.usbRow !== null && !(root.service && root.service.wifiRunning)
            text: !root.usbRow ? "Plug a phone in first"
              : root.service && root.service.wifiRunning ? "Switching " + root.usbRow.name + " to :" + (portField.text.trim() || Android.DEFAULT_PORT) + "…"
              : "Switch " + root.usbRow.name + " to Wi-Fi"
            onClicked: root.submitWifi()
          }
        }

        // ---- Wi-Fi: pairing code (Android 11+).
        Column {
          width: parent.width
          visible: root.view === "wifi" && root.wifiTab === 1
          spacing: root.sectionGap

          Note {
            text: "On the phone: Developer options › Wireless debugging › Pair device with pairing code. "
              + "Phones showing that screen appear below."
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Caption { text: "ON THIS NETWORK" }

            Card {
              visible: root.view === "wifi" && root.wifiTab === 1 && root.suggestions.length > 0
              height: pairList.implicitHeight + 2 * root.listPad

              Column {
                id: pairList
                x: root.listPad
                y: root.listPad
                width: parent.width - 2 * root.listPad

                Repeater {
                  model: root.view === "wifi" && root.wifiTab === 1 ? root.suggestions : []
                  delegate: AddressRow { glyph: root.glyphLink; note: "waiting for a code" }
                }
              }
            }

            Note {
              font.pixelSize: Style.font.caption
              text: root.service && root.service.discovering ? "Searching…"
                : root.suggestions.length > 0 ? "^r to look again"
                : "None found yet. Type the address the phone shows, or ^r to look again."
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Field {
              label: "ADDRESS"
              width: (parent.width - parent.spacing) * 0.58
              Input { id: pairAddressField; placeholderText: "192.168.1.20:41235" }
            }
            Field {
              label: "PAIRING CODE"
              width: (parent.width - parent.spacing) * 0.42
              Input { id: pairCodeField; placeholderText: "6 digits"; inputMethodHints: Qt.ImhDigitsOnly }
            }
          }

          Note {
            font.pixelSize: Style.font.caption
            text: "The code goes to adb on its prompt, never on the command line."
          }

          WideButton {
            enabled: !(root.service && root.service.netRunning)
            text: root.service && root.service.netRunning ? "Pairing…" : "Pair + connect"
            onClicked: root.submitWifi()
          }
        }

        // ---- Wi-Fi: manual address.
        Column {
          width: parent.width
          visible: root.view === "wifi" && root.wifiTab === 2
          spacing: root.sectionGap

          Note {
            text: "adb connect to an address. The port is " + Android.DEFAULT_PORT + " unless you type one."
          }

          Column {
            width: parent.width
            visible: root.suggestions.length > 0
            spacing: Style.space(6)

            Caption { text: "REMEMBERED" }

            Card {
              height: rememberedList.implicitHeight + 2 * root.listPad

              Column {
                id: rememberedList
                x: root.listPad
                y: root.listPad
                width: parent.width - 2 * root.listPad

                Repeater {
                  model: root.view === "wifi" && root.wifiTab === 2 ? root.suggestions : []
                  delegate: AddressRow {}
                }
              }
            }
          }

          Field {
            label: "ADDRESS"
            width: parent.width
            Input { id: manualField; placeholderText: "192.168.1.20:" + Android.DEFAULT_PORT }
          }

          WideButton {
            enabled: !(root.service && root.service.netRunning)
            text: root.service && root.service.netRunning ? "Connecting…" : "Connect"
            onClicked: root.submitWifi()
          }
        }

        // ---- What just happened, then the keys.
        Label {
          width: parent.width
          visible: root.errorText !== "" || root.noticeText !== ""
          leftPadding: Style.space(6)
          rightPadding: Style.space(6)
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.caption
          text: root.errorText !== "" ? root.errorText : root.noticeText
          color: root.errorText !== "" ? Commons.Color.urgent : root.accentColor
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
          strength: 0.08
        }

        Flow {
          width: parent.width
          spacing: Style.space(10)

          Label {
            visible: root.view === "mirrors" && root.mirrorList.length > 0
            text: "click a phone to use it"
            color: root.dim
            font.pixelSize: Style.font.caption
          }
          Repeater {
            model: root.keyHints
            delegate: KeyHint {}
          }
        }
      }
    }
  }
}
