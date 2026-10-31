import Foundation
import Testing
@testable import PyIDE
@testable import PyIDECore

/// Attaches to a real `python -m debugpy --listen` program and inspects its threads.
@MainActor
@Suite(.serialized) struct DebugSessionTests {
    nonisolated static var canRun: Bool {
        PythonEnvironment.interpreter(for: nil) != nil && DebugpyLocator.isInstalledInSupportDirectory
    }

    private func waitUntil(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test(.enabled(if: canRun), .timeLimit(.minutes(1)))
    func attachesAndSwitchesThreads() async throws {
        let python = try #require(PythonEnvironment.interpreter(for: nil))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pyide-dbg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let program = dir.appendingPathComponent("app.py")
        try """
            import threading, time

            def worker():
                while True:
                    time.sleep(0.05)

            threading.Thread(target=worker, name="worker", daemon=True).start()
            time.sleep(0.3)
            answer = 42
            print("answer", answer)
            """.write(to: program, atomically: true, encoding: .utf8)

        let port = Int.random(in: 40_000...60_000)
        let debuggee = Process()
        debuggee.executableURL = python
        debuggee.arguments = ["-m", "debugpy", "--listen", "127.0.0.1:\(port)", "--wait-for-client", program.path]
        debuggee.environment = DebugpyLocator.adapterEnvironment(base: ProcessInfo.processInfo.environment,
                                                                 useSupportDirectory: true)
        let output = Pipe()
        debuggee.standardOutput = output
        debuggee.standardError = output
        try debuggee.run()
        defer { if debuggee.isRunning { debuggee.terminate() } }

        let key = Workspace.key(for: program)
        let session = DebugSession(breakpoints: [key: [SourceBreakpoint(line: 10)]],
                                   target: .connect(host: "127.0.0.1", port: port))
        // No delay needed: the session retries while the listener starts.
        session.start(python: python, cwd: dir, environment: ProcessInfo.processInfo.environment,
                      useSupportDirectory: true)
        defer { session.stop() }

        try await waitUntil { session.isStopped && session.threads.count >= 2 && !session.frames.isEmpty }
        #expect(session.isStopped, "console: \(session.console)")
        #expect(session.frames.first?.line == 10)
        let main = try #require(session.stoppedThreadID)
        let worker = try #require(session.threads.first { $0.name == "worker" })

        session.select(thread: worker.id)
        try await waitUntil { session.frames.first?.name == "worker" }
        #expect(session.frames.first?.name == "worker")
        #expect(session.selectedThreadID == worker.id)

        // Back on the main thread, continue: the program finishes on its own.
        session.select(thread: main)
        try await waitUntil { session.frames.first?.line == 10 }
        session.resume()
        try await waitUntil { !debuggee.isRunning }
        #expect(!debuggee.isRunning)
        let printed = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        #expect(printed.contains("answer 42"), "output: \(printed)")
    }

    @Test(.enabled(if: canRun), .timeLimit(.minutes(1)))
    func detachLeavesProgramRunning() async throws {
        let python = try #require(PythonEnvironment.interpreter(for: nil))
        let port = Int.random(in: 40_000...60_000)
        let debuggee = Process()
        debuggee.executableURL = python
        debuggee.arguments = ["-m", "debugpy", "--listen", "127.0.0.1:\(port)", "-c", "import time; time.sleep(30)"]
        debuggee.environment = DebugpyLocator.adapterEnvironment(base: ProcessInfo.processInfo.environment,
                                                                 useSupportDirectory: true)
        debuggee.standardOutput = FileHandle.nullDevice
        debuggee.standardError = FileHandle.nullDevice
        try debuggee.run()
        defer { if debuggee.isRunning { debuggee.terminate() } }

        let session = DebugSession(breakpoints: [:], target: .connect(host: "127.0.0.1", port: port))
        session.start(python: python, cwd: nil, environment: ProcessInfo.processInfo.environment,
                      useSupportDirectory: true)
        try await waitUntil { session.state == .running }
        #expect(session.state == .running, "console: \(session.console)")
        session.stop()
        try await Task.sleep(for: .seconds(1.5))
        #expect(debuggee.isRunning, "detaching must not kill the program")
        #expect(session.console.contains("detached"))
    }
}
