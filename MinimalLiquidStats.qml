import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Always-visible sensor readout: water reservoir temp, CPU/GPU temp, and
// CPU/GPU/RAM/disk usage. No popup, no click target — just icon+value pairs
// polled from stats.py every 2s.
BarWidget {
    id: root
    moduleName: "marionuevo.minimal-liquid-stats"

    property var stats: ({})

    function fmt(value, unit) {
        return (value === undefined || value === null) ? ("--" + unit) : (value + unit)
    }

    readonly property string displayText:
        "󱪅 " + fmt(stats.water, "°C") + "  " +
        " " + fmt(stats.cpuTemp, "°C") + "/" + fmt(stats.cpu, "%") + "  " +
        "󰢮 " + fmt(stats.gpuTemp, "°C") + "/" + fmt(stats.gpu, "%") + "  " +
        " " + fmt(stats.ram, "%") + "  " +
        "󰋊 " + fmt(stats.disk, "%")

    function parseStats(raw) {
        try {
            var parsed = JSON.parse(String(raw || "").trim())
            if (parsed) root.stats = parsed
        } catch (e) {
            // keep last good values on parse failure
        }
    }

    implicitWidth: spacer.width + button.implicitWidth
    implicitHeight: button.implicitHeight

    Item {
        id: spacer
        width: Style.space(12)
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }

    WidgetButton {
        id: button
        anchors.left: spacer.right
        anchors.verticalCenter: parent.verticalCenter
        bar: root.bar
        text: root.displayText
        interactive: false
        pressable: false
        horizontalMargin: 8.5
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
