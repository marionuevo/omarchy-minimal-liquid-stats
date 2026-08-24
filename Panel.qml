import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Fan mode picker. Three curve presets for the two radiator banks and the
// pump, plus a read-out of what the loop is actually doing right now.
//
// The modes rewrite the chip's SmartFan IV tables rather than forcing a
// fixed duty, so the board keeps regulating against water temp by itself
// and a crashed shell can't strand the fans. See fanmode.py.
//
// MinimalLiquidStats.qml owns the bar label and hands this panel the button
// to anchor against.
Panel {
  id: root
  moduleName: "marionuevo.minimal-liquid-stats"
  ipcTarget: "marionuevo.minimal-liquid-stats"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var stats: ({})

  property string mode: "normal"
  property bool writable: false
  property bool busy: false

  readonly property var modes: [
    { value: "silent", label: "Silent", icon: "󰕿" },
    { value: "normal", label: "Normal", icon: "󰖀" },
    { value: "full",   label: "Full",   icon: "󰕾" }
  ]

  property int cursorIndex: -1
  property bool cursorActive: false

  function scriptPath(name) {
    return String(Qt.resolvedUrl(name)).replace(/^file:\/\//, "")
  }

  function refreshStatus() {
    statusProc.running = true
  }

  function setMode(value) {
    if (busy || !writable || value === "") return
    busy = true
    applyProc.command = ["python3", root.scriptPath("fanmode.py"), String(value)]
    applyProc.running = true
  }

  function selectByDelta(delta) {
    if (modes.length === 0) return
    var start = cursorIndex < 0 ? modeIndex(mode) : cursorIndex
    var next = start + delta
    if (next < 0) next = modes.length - 1
    if (next >= modes.length) next = 0
    cursorIndex = next
  }

  function modeIndex(value) {
    for (var i = 0; i < modes.length; i++)
      if (modes[i].value === value) return i
    return 0
  }

  function activateSelected() {
    if (cursorIndex >= 0 && cursorIndex < modes.length)
      setMode(modes[cursorIndex].value)
  }

  function fmt(value, unit) {
    return (value === undefined || value === null) ? ("--" + unit) : (value + unit)
  }

  onOpenedChanged: {
    if (opened) {
      cursorIndex = modeIndex(mode)
      cursorActive = false
      refreshStatus()
    }
  }

  Process {
    id: statusProc
    command: ["python3", root.scriptPath("fanmode.py"), "--status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "").trim())
          if (parsed) {
            if (parsed.mode) root.mode = String(parsed.mode)
            root.writable = parsed.writable === true
          }
        } catch (e) {
          // leave the last known state alone
        }
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        root.refreshStatus()
      }
    }
    onExited: {
      root.busy = false
      root.refreshStatus()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.selectByDelta(dx !== 0 ? dx : dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: water temp, the thing every curve keys off ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: "󱪅"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.fmt(root.stats.water, "°C")
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
            }

            Text {
              text: "coolant"
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: 0.6
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        PanelSeparator {
          foreground: root.bar ? root.bar.foreground : Color.foreground
        }

        // ---------- Live RPM ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          InfoPair { label: "Pump";       value: root.fmt(root.stats.pump, " rpm") }
          InfoPair { label: "Top rad";    value: root.fmt(root.stats.fanTop, " rpm") }
          InfoPair { label: "Bottom rad"; value: root.fmt(root.stats.fanBottom, " rpm") }
        }

        PanelSeparator {
          foreground: root.bar ? root.bar.foreground : Color.foreground
        }

        // ---------- Mode picker ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "FAN MODE"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Row {
            id: modeRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.modes.length > 0
              ? (width - spacing * (root.modes.length - 1)) / root.modes.length
              : 0

            Repeater {
              model: root.modes

              Button {
                required property var modelData
                required property int index
                width: modeRow.cellWidth
                iconText: String(modelData.icon)
                iconSize: Style.font.title
                text: String(modelData.label)
                fontSize: Style.font.bodySmall
                foreground: root.bar ? root.bar.foreground : Color.foreground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                enabled: root.writable && !root.busy
                opacity: enabled ? 1.0 : 0.45
                active: root.mode === String(modelData.value)
                hasCursor: root.cursorActive && root.cursorIndex === index
                onClicked: root.setMode(String(modelData.value))
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.cursorIndex = index
                  }
                }
              }
            }
          }

          // Only ever shown when the udev rule is missing — the curve files
          // are root-owned until then, so the buttons cannot do anything.
          Text {
            visible: !root.writable
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Fan curves are read-only. Install the udev rule to enable mode switching."
            color: root.bar ? root.bar.foreground : Color.foreground
            opacity: 0.6
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Curves reset to BIOS defaults on reboot."
            color: root.bar ? root.bar.foreground : Color.foreground
            opacity: 0.45
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0

    Text {
      text: parent.label
      color: root.bar ? root.bar.foreground : Color.foreground
      opacity: 0.6
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
      height: 1
    }

    Text {
      text: parent.value
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }
}
