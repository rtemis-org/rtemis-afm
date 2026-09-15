// RtemisAFMCommand.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

import ArgumentParser
import Foundation
import Logging
import RtemisAFM

// The command-line entry point. `swift-argument-parser` turns the structs
// below into `rtemis-afm`, `rtemis-afm serve`, `rtemis-afm status` and
// `rtemis-afm version`, complete with `--help`. `@main` marks the type whose
// `main()` the program starts in; `AsyncParsableCommand` gives it an
// async `run()` so the server can be awaited directly.

@main
struct RtemisAFMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rtemis-afm",
        abstract: "Serve Apple's on-device Foundation Model to rtemislive over the OpenAI chat wire.",
        version: RtemisAFM.version,
        subcommands: [Serve.self, Status.self, Version.self],
        defaultSubcommand: Serve.self
    )
}

// MARK: - serve

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the bridge (the default).")

    @Option(name: .long, help: "Port to listen on (loopback only).")
    var port: Int = RtemisAFM.defaultPort

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Additional allowed browser origin; repeatable. `https://live.rtemis.org`, `http://localhost:*` and `http://127.0.0.1:*` are always allowed.",
            valueName: "origin"
        )
    )
    var allowOrigin: [String] = []

    @Flag(name: .long, help: "Log one line per request (never prompt or completion text).")
    var verbose = false

    @Option(name: .long, help: "How many generations may run at once; extra requests queue.")
    var concurrency: Int = 2

    func validate() throws {
        guard (1...65535).contains(port) else { throw ValidationError("--port must be between 1 and 65535") }
        guard concurrency >= 1 else { throw ValidationError("--concurrency must be at least 1") }
        for origin in allowOrigin where OriginRule.parse(origin) == nil {
            throw ValidationError("--allow-origin \"\(origin)\" is not an origin (expected scheme://host[:port] or scheme://host:*)")
        }
    }

    func run() async throws {
        // swift-log needs a backend before the first logger is made. The
        // stderr handler prints one line per message. `--verbose` shows the
        // bridge's `info` lines (requests, ignored schema keywords); without
        // it only warnings and errors appear. Hummingbird's own `debug`
        // chatter stays off in both cases.
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = verbose ? .info : .warning
            return handler
        }
        let logger = Logger(label: "rtemis-afm")

        let backend = FoundationModelsBackend(concurrency: concurrency, logger: logger)
        let status = backend.status()

        // Say up front whether chat can work, in words the user can act on.
        if !status.available {
            print("⚠️  \(status.userMessage)")
        }

        let origins = OriginRule.defaults + allowOrigin.compactMap(OriginRule.parse)
        let configuration = ServerConfiguration(port: port, allowedOrigins: origins, verbose: verbose)
        let app = BridgeServer.makeApplication(configuration: configuration, backend: backend, logger: logger)

        print("""
        rtemis-afm \(RtemisAFM.version) — Apple Foundation Model bridge
        Listening on http://localhost:\(port) for https://live.rtemis.org
        Go back to rtemislive and pick Apple Intelligence. Ctrl-C to stop.
        """)
        if verbose {
            print("Allowed origins: \(origins.map(describe).joined(separator: ", "))")
            print("Model: \(status.available ? "available" : "unavailable (\(status.unavailableReason ?? "?"))"), context window \(status.contextWindow) tokens")
        }

        // Runs until SIGINT/SIGTERM, then shuts down gracefully.
        try await app.runService()
    }

    private func describe(_ rule: OriginRule) -> String {
        switch rule {
        case .exact(let origin): return origin
        case .anyPort(let scheme, let host): return "\(scheme)://\(host):*"
        }
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check a running bridge: GET /health, exit 0 if the model is available.")

    @Option(name: .long, help: "Port of the running bridge.")
    var port: Int = RtemisAFM.defaultPort

    func run() async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            print("rtemis-afm is not running on port \(port) (\(error.localizedDescription))")
            throw ExitCode(1)
        }
        struct Health: Decodable {
            struct Model: Decodable { var availability: String; var reason: String? }
            var version: String
            var model: Model
        }
        let health = try JSONDecoder().decode(Health.self, from: data)
        if health.model.availability == "available" {
            print("rtemis-afm \(health.version) is running on port \(port); model available.")
        } else {
            let status = ModelStatus(available: false, unavailableReason: health.model.reason, contextWindow: 0, capabilities: [])
            print("rtemis-afm \(health.version) is running on port \(port), but: \(status.userMessage)")
            throw ExitCode(1)
        }
    }
}

// MARK: - version

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the version.")

    func run() {
        print(RtemisAFM.version)
    }
}
