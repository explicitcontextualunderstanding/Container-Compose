//===----------------------------------------------------------------------===//
// RelayTest.swift
// Experimental debug hook for validating Network.framework entitlements
// and native --publish feasibility.
//===----------------------------------------------------------------------===//

import ArgumentParser
import Foundation
import Network
import os.log

public struct RelayTest: AsyncParsableCommand, Sendable {
    public static let configuration = CommandConfiguration(
        commandName: "relay-test",
        abstract: "Experiment 2: Standalone relay bridge for entitlement validation.",
        discussion: "Bridges a local TCP port to a target TCP port or Unix socket."
    )

    @Option(name: .long, help: "Local TCP port to listen on.")
    var source: UInt16

    @Option(name: .long, help: "Target endpoint (port number or /path/to/socket).")
    var target: String

    @Flag(name: .shortAndLong, help: "Enable verbose logging.")
    var verbose: Bool = false

    // Exclude logger from Decodable synthesis
    private enum CodingKeys: String, CodingKey {
        case source, target, verbose
    }

    public init() {}

    public func run() async throws {
        print("🚀 [EXPERIMENT 2] Starting interactive relay bridge...")
        print("   Source: TCP \(source)")
        print("   Target: \(target)")

        let targetEndpoint: NWEndpoint
        if let port = UInt16(target) {
            targetEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        } else {
            targetEndpoint = .unix(path: target)
            print("   Polling for target socket readiness via SocketHealth...")
            let status = await SocketHealth.waitForSocket(socketPath: target)
            if !status.isReady {
                print("⚠️  Warning: Target socket not ready: \(status.error?.description ?? "Unknown error")")
                print("   Continuing anyway to probe listener behavior...")
            }
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: source)!)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == EACCES {
                print("❌ FATAL: Permission Denied (EACCES) while binding to port \(source).")
                print("   This confirms AMFI/TCC is blocking host-side listeners.")
            } else {
                print("❌ FATAL: Failed to start listener: \(error)")
            }
            throw error
        }
        
        listener.newConnectionHandler = { connection in
            print("🔗 [INCOMING] New connection received from \(connection.endpoint)")
            let bridge = BidirectionalBridge(
                source: connection,
                targetEndpoint: targetEndpoint,
                verbose: self.verbose
            )
            
            Task {
                await bridge.start()
            }
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("✅ [LISTENING] Ready on TCP \(source). Press Ctrl+C to stop.")
            case .failed(let error):
                print("❌ [LISTENER FAILED] \(error)")
            default:
                break
            }
        }

        listener.start(queue: .global())

        // Keep the command running
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

// MARK: - BidirectionalBridge

actor BidirectionalBridge {
    private let source: NWConnection
    private let target: NWConnection
    private let verbose: Bool
    private let id = UUID().uuidString.prefix(4)

    init(source: NWConnection, targetEndpoint: NWEndpoint, verbose: Bool) {
        self.source = source
        self.target = NWConnection(to: targetEndpoint, using: .tcp)
        self.verbose = verbose
    }

    func start() async {
        source.start(queue: .global())
        target.start(queue: .global())

        // Monitor target connection state
        let targetConnected = await withCheckedContinuation { continuation in
            target.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("   [\(self.id)] ✅ Connected to target.")
                    continuation.resume(returning: true)
                case .failed(let error):
                    print("   [\(self.id)] ❌ Failed to connect to target: \(error)")
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
        }

        guard targetConnected else {
            close()
            return
        }

        async let forward = pipe(from: source, to: target, label: "SRC→TGT")
        async let reverse = pipe(from: target, to: source, label: "TGT→SRC")

        _ = await (forward, reverse)
        
        close()
    }

    private func pipe(from input: NWConnection, to output: NWConnection, label: String) async {
        while true {
            do {
                let data = try await receive(from: input)
                guard !data.isEmpty else {
                    if verbose { print("   [\(id)] \(label): Connection closed by peer") }
                    break
                }
                
                try await send(data: data, to: output)
                
                // Interactive byte-level logging
                print("   [\(id)] \(label): Transferred \(data.count) bytes")
                if verbose && data.count < 1024 {
                    if let str = String(data: data, encoding: .utf8) {
                        print("      Data: \(str.replacingOccurrences(of: "\n", with: "\\n"))")
                    } else {
                        print("      Data: [Binary \(data.count) bytes]")
                    }
                }
            } catch {
                print("   [\(id)] \(label) Error: \(error.localizedDescription)")
                break
            }
        }
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        source.cancel()
        target.cancel()
        print("   [\(id)] 🔌 Bridge closed.")
    }
}
