import Foundation

struct BoringHTTPResult {
    let status: Int
    let body: Data
}

enum BoringTransport {
    /// Runs the blocking BoringSSL request off the main actor.
    static func post(host: String,
                     path: String,
                     headers: [String: String],
                     body: Data) async -> BoringHTTPResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var status: Int = 0
                var error: NSError?
                let data = BoringHTTPPost(host, path, headers, body, &status, &error)
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: BoringHTTPResult(status: status, body: data))
            }
        }
    }
}