import Foundation
import HyprControl
import HyprKit

/// Config-file watcher and `hyprmacctl` control socket, tied to one running controller.
final class BackgroundServices {
    private let watcher: ConfigWatcher
    private let server: ControlServer

    init(controller: TilingController, configPath: URL, version: String) {
        watcher = ConfigWatcher(path: configPath) { [weak controller] in
            // Same path as the menu item and SIGHUP: errors keep the previous settings and notify.
            controller?.reloadConfig()
        }
        server = ControlServer(handler: TilingControlHandler(controller: controller, version: version,
                                                             configPath: configPath.path))
    }

    func start() {
        watcher.start()
        do {
            try server.start()
        } catch {
            // Not fatal: tiling works without the CLI.
            log.error("control socket unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        watcher.stop()
        server.stop()
    }
}
