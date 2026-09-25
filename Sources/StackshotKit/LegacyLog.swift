import os

/// Temporary: keeps files that haven't moved to `Log.<category>` yet compiling. Delete once nothing uses it.
@available(*, deprecated, message: "Use a Log category, e.g. Log.capture")
let log = Log.app
