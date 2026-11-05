import Foundation

@main
enum SessionLifecycleCheck {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("session.jsonl")
        let start = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".utf8)
        let complete = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n".utf8)
        let noise = Data(("{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "日志", count: 10000) + "\"}\n").utf8)
        var initial = start
        for _ in 0..<30 { initial.append(noise) }
        try initial.write(to: log)
        var state = SessionLifecycle.read(log, previous: nil)!
        precondition(initial.count > 1024 * 1024 && state.event == "task_started")

        let file = try FileHandle(forWritingTo: log)
        try file.seekToEnd()
        for _ in 0..<30 { try file.write(contentsOf: noise) }
        state = SessionLifecycle.read(log, previous: state)!
        precondition(state.event == "task_started")
        precondition(SessionLifecycle.read(log, previous: nil)?.event == "task_started")

        // 实际日志可能在轮询时刚写到半行；下一次补齐后才能切换状态。
        try file.write(contentsOf: complete.prefix(20))
        state = SessionLifecycle.read(log, previous: state)!
        precondition(state.event == "task_started")
        try file.write(contentsOf: complete.dropFirst(20))
        state = SessionLifecycle.read(log, previous: state)!
        precondition(state.event == "task_complete")
        precondition(SessionLifecycle.read(log, previous: nil)?.event == "task_complete")
        try file.write(contentsOf: start)
        state = SessionLifecycle.read(log, previous: state)!
        precondition(state.event == "task_started")
        try file.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}\n".utf8))
        precondition(SessionLifecycle.read(log, previous: state)?.event == "turn_aborted")
        try file.close()
        print("PASS: long log, incremental output, restart, incomplete line, completion, next task, abort")

        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            print("\(url.lastPathComponent): \(SessionLifecycle.read(url, previous: nil)?.event ?? "unknown")")
        }
    }
}
