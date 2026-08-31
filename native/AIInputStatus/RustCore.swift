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
        let result = ints.withUnsafeBufferPointer { buffer in ai_input_p95(buffer.baseAddress, buffer.count) }
        return result >= 0 ? Int(result) : nil
    }

        guard !values.isEmpty else { return nil }
        let states = values.map { Int8($0 == nil ? -1 : ($0 == true ? 1 : 0)) }
        let result = states.withUnsafeBufferPointer { ai_input_success_rate($0.baseAddress, $0.count) }
        return result >= 0 ? Double(result) / 100.0 : nil
    }

    static func chooseBackup(states: [Bool?], latencies: [Int?]) -> Int? {
        guard !states.isEmpty, states.count == latencies.count else { return nil }
        let stateValues = states.map { Int8($0 == nil ? -1 : ($0 == true ? 1 : 0)) }
        let latencyValues = latencies.map { max(0, $0 ?? Int.max / 2) }
        let result = stateValues.withUnsafeBufferPointer { stateBuffer in
            latencyValues.withUnsafeBufferPointer { latencyBuffer in
                ai_input_choose_backup(stateBuffer.baseAddress, latencyBuffer.baseAddress, stateBuffer.count)
            }
        }
        return result >= 0 ? Int(result) : nil
    }
}
