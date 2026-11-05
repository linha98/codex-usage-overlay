import Foundation

// 保存最后一条完整日志的位置和任务状态。没有新的生命周期事件不代表空闲。
struct SessionLifecycle {
    var offset: UInt64
    var event: String?

    static func read(_ url: URL, previous: SessionLifecycle?) -> SessionLifecycle? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        do {
            let end = try file.seekToEnd()
            if var state = previous, state.offset <= end {
                try file.seek(toOffset: state.offset)
                var pending = Data()
                while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending[..<newline]
                        if let event = lifecycleEvent(in: Data(line)) { state.event = event }
                        state.offset += UInt64(line.count + 1)
                        pending = Data(pending[pending.index(after: newline)...])
                    }
                }
                // 尚未写完的一行留到下一次读取，不能把它当作一条有效事件。
                return state
            }

            // 首次读取从后往前查找；开始事件即使在几 MB 以外也不会漏掉。
            var cursor = end
            var remainder = Data()
            var completedEnd: UInt64?
            while cursor > 0 {
                let count = min(cursor, 64 * 1024)
                cursor -= count
                try file.seek(toOffset: cursor)
                var block = try file.read(upToCount: Int(count)) ?? Data()
                block.append(remainder)
                if completedEnd == nil {
                    guard let newline = block.lastIndex(of: 10) else {
                        remainder = block
                        continue
                    }
                    completedEnd = cursor + UInt64(newline) + 1
                    block = Data(block[...newline])
                }
                let lines = block.split(separator: 10, omittingEmptySubsequences: false)
                for line in lines.dropFirst().reversed() {
                    if let event = lifecycleEvent(in: Data(line)) {
                        return SessionLifecycle(offset: completedEnd ?? 0, event: event)
                    }
                }
                remainder = lines.first.map { Data($0) } ?? Data()
            }
            return SessionLifecycle(offset: completedEnd ?? 0, event: lifecycleEvent(in: remainder))
        } catch {
            return nil
        }
    }

    private static func lifecycleEvent(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String,
              ["task_started", "task_complete", "turn_aborted"].contains(type) else { return nil }
        return type
    }
}
