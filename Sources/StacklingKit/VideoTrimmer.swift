import AVFoundation

/// Cuts the start and end off a recording.
enum VideoTrimmer {
    /// Cuts the video down to `range` without re-encoding, then swaps it in place of the original. The
    /// untrimmed original goes to the Trash rather than vanishing, in case you cut too much.
    static func trim(_ url: URL, to range: CMTimeRange) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            Log.editor.error("trim.failed reason=no-export-session file=\(url.lastPathComponent, privacy: .public)")
            throw CocoaError(.fileWriteUnknown)
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        session.timeRange = range
        if #available(macOS 15.0, *) {
            try await session.export(to: temp, as: .mov)
        } else {
            session.outputURL = temp
            session.outputFileType = .mov
            await session.export()
            if let error = session.error { throw error }
        }
        // Keep the untrimmed version recoverable: a copy named "… (untrimmed).mov" goes to the Trash.
        let untrimmed = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (untrimmed)." + url.pathExtension)
        try? FileManager.default.removeItem(at: untrimmed)
        do {
            try FileManager.default.copyItem(at: url, to: untrimmed)
            try FileManager.default.trashItem(at: untrimmed, resultingItemURL: nil)
        } catch {
            Log.editor.error("trim.backup-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
