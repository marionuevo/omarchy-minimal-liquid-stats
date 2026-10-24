import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Always-visible sensor readout polled from stats.py every 2s: water
// reservoir temp, pump and radiator fan RPM, CPU/GPU temp and usage, RAM and
// disk usage. Each reading is an icon and two stacked rows, like
// marionuevo.netgraph: the number on top and, below, a meter (outline = the
// whole range, fill = the current value) for the usage or, for the pump and
// fans, the rpm within their range. Water has only its number; RAM and disk
// only their meter.
//
// Clicking opens the fan mode picker (Panel.qml). The row itself stays a
// plain read-out; the click target exists only because fan control has to
// live somewhere, and the loop's own widget is where you look for it.
BarWidget {
    id: root
    moduleName: "marionuevo.minimal-liquid-stats"

    property var stats: ({})

    readonly property color fg: button.foreground
    readonly property string fontFamily: button.fontFamily

    // Top of each meter: what Full mode reaches on this build (README).
    readonly property real fanMax: 2200
    readonly property real pumpMax: 4800

    function fmt(value, unit) {
        return ((value === undefined || value === null) ? "--" : String(value)) + unit
    }

    // 0-1 for a meter; null (no reading) leaves it empty.
    function fraction(value, lo, hi) {
        if (value === undefined || value === null || !(hi > lo)) return null
        return Math.max(0, Math.min(1, (value - lo) / (hi - lo)))
    }

    function parseStats(raw) {
        try {
            var parsed = JSON.parse(String(raw || "").trim())
            if (parsed) {
                root.stats = parsed
                if (panelLoader.item) panelLoader.item.stats = parsed
            }
        } catch (e) {
            // keep last good values on parse failure
        }
    }

    // ---- Fan mode popup. Shape contract for shell.summon/hide/toggle
    //      routing: Bar.findPanelWidget requires open/close/opened on the
    //      bar-widget root.
    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

    function open() { if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

    readonly property real openPanelIndicatorWidth: readings.implicitWidth
    readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

    // Forwarded so this widget can stand in for the panel as the bar's popout
    // identity: Bar.requestPopout prefers closeForPopoutSwitch over close.
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        if ("bar" in target) target.bar = root.bar
        if ("settings" in target) target.settings = root.settings
        if ("anchorItem" in target) target.anchorItem = button
        if ("hostWidget" in target) target.hostWidget = root
        if ("stats" in target) target.stats = root.stats
    }

    implicitWidth: button.anchors.leftMargin + button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    // Widest top row, a temperature or an rpm ("4770" takes the same
    // width); every number and meter takes this width, so the widget keeps
    // its width as readings change and the widgets to the right don't shift.
    TextMetrics {
        id: widest
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        text: "99°C"
    }

    // One reading: its icon and one or more cells (the fans have two).
    component Reading: Row {
        property string icon
        default property alias cells: cellRow.data
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        spacing: Style.space(4)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.icon
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: button.fontSize
            renderType: Text.NativeRendering
        }

        Row {
            id: cellRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
        }
    }

    // Two rows: the number on top (empty for a meter alone) and the meter
    // below (none with `meter: false`).
    component Cell: Column {
        id: cell
        property string value: ""
        property bool meter: true
        property var fill: null
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined

        Text {
            visible: cell.value !== ""
            width: widest.width
            horizontalAlignment: Text.AlignRight
            text: cell.value
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
        }

        Meter {
            visible: cell.meter
            fill: cell.fill
        }
    }

    // A text row tall, so the meter sits where a second line of text would.
    // The outline is the whole range; the fill, inset from it, the value.
    component Meter: Item {
        id: meter
        property var fill: null
        width: widest.width
        height: widest.height

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 7
            radius: 2
            color: "transparent"
            border.width: 1
            border.color: root.fg
            opacity: 0.55
        }

        Rectangle {
            x: track.x + 2
            anchors.verticalCenter: track.verticalCenter
            width: meter.fill === null ? 0 : (track.width - 4) * meter.fill
            height: track.height - 4
            radius: 1
            color: root.fg
        }
    }

    // The hairline between readings; marionuevo.separator draws a stronger
    // one between widgets.
    component Gap: Item {
        width: Style.space(15)
        height: 1
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined

        Rectangle {
            anchors.centerIn: parent
            width: 1
            height: Math.round((root.bar ? root.bar.barSize : Style.bar.sizeHorizontal) * 0.45)
            color: root.fg
            opacity: 0.3
        }
    }

    WidgetButton {
        id: button
        anchors.left: parent.left
        // No gap of its own before the readings: marionuevo.separator sets
        // the space between widgets. The margins are tuned so the separator
        // lines on either side sit centered.
        anchors.leftMargin: 2.5
        anchors.verticalCenter: parent.verticalCenter
        bar: root.bar
        // WidgetButton sizes itself by its plain-text label; here the label
        // is hidden and the width comes from the readings instead.
        text: " "
        labelVisible: false
        horizontalMargin: 7
        fixedWidth: readings.implicitWidth + button.scaledHorizontalMargin * 2

        Row {
            id: readings
            anchors.centerIn: parent

            Reading {
                icon: "󱪅"
                Cell { value: root.fmt(root.stats.water, "°C"); meter: false }
            }

            Gap {}

            Reading {
                icon: "󰖏"
                Cell {
                    value: root.fmt(root.stats.pump, "")
                    fill: root.fraction(root.stats.pump, 0, root.pumpMax)
                }
            }

            Gap {}

            Reading {
                icon: "󰈐"
                Cell {
                    value: root.fmt(root.stats.fanTop, "")
                    fill: root.fraction(root.stats.fanTop, 0, root.fanMax)
                }
                Cell {
                    value: root.fmt(root.stats.fanBottom, "")
                    fill: root.fraction(root.stats.fanBottom, 0, root.fanMax)
                }
            }

            Gap {}

            Reading {
                icon: ""
                Cell {
                    value: root.fmt(root.stats.cpuTemp, "°C")
                    fill: root.fraction(root.stats.cpu, 0, 100)
                }
            }

            Gap {}

            Reading {
                icon: "󰢮"
                Cell {
                    value: root.fmt(root.stats.gpuTemp, "°C")
                    fill: root.fraction(root.stats.gpu, 0, 100)
                }
            }

            Gap {}

            Reading {
                icon: ""
                Cell { fill: root.fraction(root.stats.ram, 0, 100) }
            }

            Gap {}

            Reading {
                icon: "󰋊"
                Cell { fill: root.fraction(root.stats.disk, 0, 100) }
            }
        }

        onPressed: function(b) {
            root.togglePanel()
        }
    }

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
        target: "marionuevo.minimal-liquid-stats"

        function open(): void { root.open() }
        function close(): void { root.close() }
        function show(): void { root.open() }
        function hide(): void { root.close() }
        function toggle(): void { root.togglePanel() }
    }

    Process {
        id: statsProc
        command: ["python3", String(Qt.resolvedUrl("stats.py")).replace(/^file:\/\//, "")]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.parseStats(text)
        }
    }

    Timer {
        id: statsTimer
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: statsProc.running = true
    }
}
