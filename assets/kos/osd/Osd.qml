import Quickshell
import Quickshell.Io
import QtQuick
import qs.desktop.modules.common
import qs.desktop.modules.osd

// Minimal IPC surface for the global shortcuts: the script already changed the
// device; this only paints what it changed.
Scope {
    id: root

    IpcHandler {
        target: "osd"
        function volume(value: int, muted: bool): void {
            OsdService.showVolume(value, muted)
        }
        function brightness(value: int): void {
            OsdService.showBrightness(value)
        }
        function hide(): void {
            OsdService.dismiss()
        }
    }

    OsdWindow {
        targetScreen: ScreenLifecycle.activeScreen
    }
}
