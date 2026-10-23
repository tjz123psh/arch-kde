pragma Singleton
import QtQuick

// One transient surface for volume and brightness. The service is owned by the
// shell, not by the caller: a key-repeat storm restarts the same 1.5 s timer
// instead of stacking windows.
QtObject {
    id: root

    property bool visible: false
    property string kind: "volume"   // "volume" | "brightness"
    property int percent: 0
    property bool muted: false

    function showVolume(value, mutedValue) {
        kind = "volume"
        percent = Math.max(0, Math.min(100, Math.round(Number(value) || 0)))
        muted = Boolean(mutedValue)
        visible = true
        hideTimer.restart()
    }

    function showBrightness(value) {
        kind = "brightness"
        percent = Math.max(0, Math.min(100, Math.round(Number(value) || 0)))
        muted = false
        visible = true
        hideTimer.restart()
    }

    function dismiss() {
        hideTimer.stop()
        visible = false
    }

    property Timer hideTimer: Timer {
        interval: 1500
        repeat: false
        onTriggered: root.visible = false
    }
}
