import os

/// Structured logging, one category per area, so both people and AI assistants can follow what the
/// app did. Messages read as `event key=value key=value`, which greps well and stays unambiguous.
///
///     scripts/logs.sh              stream everything live
///     scripts/logs.sh 10m          what happened in the last 10 minutes
///     scripts/logs.sh 1h capture   one category only
///
/// Levels: `debug` for chatty state changes (hidden unless you ask for them), `info` for things
/// you did, `notice` for things the app did on its own, `error` for failures.
enum Log {
    static let subsystem = "com.leonmiltiadou.stackshot"

    /// Launch, permissions, menus, settings.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Cards arriving and leaving, the panel's size, shrinking, tucking, desktops.
    static let stack = Logger(subsystem: subsystem, category: "stack")
    /// Frozen-screen picking and saving screenshots.
    static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Screen recordings and GIFs.
    static let recording = Logger(subsystem: subsystem, category: "recording")
    /// The screenshots folder: new files, filing, tidying, moving off the Desktop.
    static let library = Logger(subsystem: subsystem, category: "library")
    /// Copy, trash, pin, text, share: what you did with a card.
    static let actions = Logger(subsystem: subsystem, category: "actions")
    /// Global shortcuts and the keys on a hovered card.
    static let keys = Logger(subsystem: subsystem, category: "keys")
    /// The annotation editor and the recording preview.
    static let editor = Logger(subsystem: subsystem, category: "editor")
}
