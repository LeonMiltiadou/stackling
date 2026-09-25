import Foundation
import Vision

/// Runs Vision requests on a queue of their own, never on Swift's shared async threads.
///
/// Vision's `perform` blocks while it waits on its own internal work. Swift's shared pool has only about
/// one thread per core, so a few Vision calls at once (reading text for search while auto-filing compares
/// pictures, say) can occupy every thread and stall everything else. That froze the test run on 3-core CI
/// machines. A dispatch queue adds threads as needed, so blocking there is safe.
enum VisionWork {
    private static let queue = DispatchQueue(label: "io.github.leonmiltiadou.stackling.vision", qos: .utility, attributes: .concurrent)

    /// Vision's types aren't marked Sendable, but each request is used by exactly one caller at a time.
    private struct Handoff<T>: @unchecked Sendable { let value: T }

    static func perform(_ requests: [VNRequest], on image: CGImage) async throws {
        let work = Handoff(value: (requests, image))
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try VNImageRequestHandler(cgImage: work.value.1).perform(work.value.0)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }
}
