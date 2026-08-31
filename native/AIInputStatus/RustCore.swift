import Foundation

enum RustCore {
    /// Keep status-error taxonomy deterministic and shared with future clients.
    static func errorKind(_ message: String?) -> Int {
        guard let message, !message.isEmpty else { return 0 }
        return message.withCString { Int(ai_input_classify_error($0)) }
    }

    /// The core sorts an owned copy, so callers retain their original measurements.
    static func p95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let ints = values.map(Int32.init)
        let result = ints.withUnsafeBufferPointer { buffer in
            ai_input_p95(buffer.baseAddress, buffer.count)
        }
        return result >= 0 ? Int(result) : nil
    }
}
