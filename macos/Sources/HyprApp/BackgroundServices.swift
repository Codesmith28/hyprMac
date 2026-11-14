import Foundation
import HyprKit

/// Config-file watcher, tied to one running controller.
final class BackgroundServices {
    private let watcher: ConfigWatcher

    init(controller: TilingController, configPath: URL) {
        watcher = ConfigWatcher(path: configPath) { [weak controller] in
            // Same path as the menu item and SIGHUP: errors keep the previous settings and notify.
            controller?.reloadConfig()
        }
    }

    func start() { watcher.start() }

    func stop() { watcher.stop() }
}
