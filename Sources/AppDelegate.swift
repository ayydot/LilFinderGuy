import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    var character: CharacterWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory policy: no Dock icon, no Cmd+Tab entry – pure background app
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        character = CharacterWindow()
    }

    // Keep alive even with no foreground windows
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
