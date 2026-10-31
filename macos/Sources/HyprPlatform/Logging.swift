import os

/// Loggers for the platform layer (`log stream --predicate 'subsystem == "dev.codesmith28.hyprmac"'`).
enum Log {
    static let subsystem = "dev.codesmith28.hyprmac"
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let spaces = Logger(subsystem: subsystem, category: "spaces")
    static let executor = Logger(subsystem: subsystem, category: "executor")
    static let events = Logger(subsystem: subsystem, category: "events")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let mover = Logger(subsystem: subsystem, category: "mover")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
}
