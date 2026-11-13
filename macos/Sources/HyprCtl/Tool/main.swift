import Foundation
import HyprControl

exit(ControlCLI.run(arguments: CommandLine.arguments,
                    out: { print($0) },
                    err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }))
