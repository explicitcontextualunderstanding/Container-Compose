import XCTest
import TestHelpers
@testable import ContainerComposeCore

// MARK: - RelayConfiguration Tests

@available(macOS 12.0, *)
final class RelayConfigurationTests: XCTestCase {

    // MARK: - ServiceRelay Creation Tests

    func testLegacyServiceRelayCreationWithVsock() throws {
        try skipIfLegacyValidationDisabled()
        let relay = ServiceRelay(
            transport: .vsock,
            cid: 3,
            target: nil,
            port: 5432,
            socket: nil
        )

        XCTAssertEqual(relay.transport, .vsock)
        XCTAssertEqual(relay.cid, 3)
        XCTAssertNil(relay.target)
        XCTAssertEqual(relay.port, 5432)
        XCTAssertNil(relay.socket)
    }

    func testLegacyServiceRelayCreationWithTarget() throws {
        try skipIfLegacyValidationDisabled()
        let relay = ServiceRelay(
            transport: .vsock,
            cid: nil,
            target: "test-db",
            port: nil,
            socket: nil
        )

        XCTAssertEqual(relay.transport, .vsock)
        XCTAssertNil(relay.cid)
        XCTAssertEqual(relay.target, "test-db")
        XCTAssertNil(relay.port)
        XCTAssertNil(relay.socket)
    }

    func testLegacyServiceRelayCreationWithUnixSocket() throws {
        try skipIfLegacyValidationDisabled()
        let relay = ServiceRelay(
            transport: .unix,
            cid: nil,
            target: nil,
            port: nil,
            socket: "/tmp/my-service.sock"
        )

        XCTAssertEqual(relay.transport, .unix)
        XCTAssertNil(relay.cid)
        XCTAssertNil(relay.target)
        XCTAssertNil(relay.port)
        XCTAssertEqual(relay.socket, "/tmp/my-service.sock")
    }

    func testLegacyServiceRelayCreationWithTcp() throws {
        try skipIfLegacyValidationDisabled()
        let relay = ServiceRelay(
            transport: .tcp,
            cid: nil,
            target: "backend-service",
            port: 8080,
            socket: nil
        )

        XCTAssertEqual(relay.transport, .tcp)
        XCTAssertNil(relay.cid)
        XCTAssertEqual(relay.target, "backend-service")
        XCTAssertEqual(relay.port, 8080)
        XCTAssertNil(relay.socket)
    }

    // MARK: - Hashable Conformance Tests

    func testLegacyServiceRelayEquality() throws {
        try skipIfLegacyValidationDisabled()
        let relay1 = ServiceRelay(transport: .vsock, cid: 3, target: nil, port: 5432, socket: nil)
        let relay2 = ServiceRelay(transport: .vsock, cid: 3, target: nil, port: 5432, socket: nil)
        let relay3 = ServiceRelay(transport: .vsock, cid: 4, target: nil, port: 5432, socket: nil)

        XCTAssertEqual(relay1, relay2)
        XCTAssertNotEqual(relay1, relay3)
    }

    func testLegacyServiceRelayHashable() throws {
        try skipIfLegacyValidationDisabled()
        let relay1 = ServiceRelay(transport: .vsock, cid: 3, target: "db", port: 5432, socket: "/tmp/db.sock")
        let relay2 = ServiceRelay(transport: .vsock, cid: 3, target: "db", port: 5432, socket: "/tmp/db.sock")

        var hasher1 = Hasher()
        var hasher2 = Hasher()
        relay1.hash(into: &hasher1)
        relay2.hash(into: &hasher2)

        XCTAssertEqual(hasher1.finalize(), hasher2.finalize())
    }

// MARK: - Transport Type Tests

func testLegacyRelayTransportRawValues() throws {
    try skipIfLegacyValidationDisabled()
    XCTAssertEqual(RelayTransport.TransportType.vsock.rawValue, "vsock")
    XCTAssertEqual(RelayTransport.TransportType.unix.rawValue, "unix")
    XCTAssertEqual(RelayTransport.TransportType.tcp.rawValue, "tcp")
}

func testLegacyRelayTransportCodable() throws {
    try skipIfLegacyValidationDisabled()
    let transports: [RelayTransport.TransportType] = [.vsock, .unix, .tcp]

    for transport in transports {
        let encoded = try JSONEncoder().encode(transport)
        let decoded = try JSONDecoder().decode(RelayTransport.TransportType.self, from: encoded)
        XCTAssertEqual(transport, decoded)
    }
}

    // MARK: - YAML Parsing Tests

    func testLegacyServiceRelayDecodingFromYAML() throws {
        try skipIfLegacyValidationDisabled()
        let yaml = """
        transport: vsock
        cid: 3
        port: 5432
        """

        let data = yaml.data(using: .utf8)!
        let decoder = JSONDecoder()

        // Parse as JSON first to simulate YAML parsing
        let json = """
        {"transport": "vsock", "cid": 3, "port": 5432}
        """
        let jsonData = json.data(using: .utf8)!
        let relay = try decoder.decode(ServiceRelay.self, from: jsonData)

        XCTAssertEqual(relay.transport, .vsock)
        XCTAssertEqual(relay.cid, 3)
        XCTAssertEqual(relay.port, 5432)
        XCTAssertNil(relay.target)
        XCTAssertNil(relay.socket)
    }

    func testLegacyServiceRelayDecodingWithTarget() throws {
        try skipIfLegacyValidationDisabled()
        let json = """
        {"transport": "vsock", "target": "test-db"}
        """
        let data = json.data(using: .utf8)!
        let relay = try JSONDecoder().decode(ServiceRelay.self, from: data)

        XCTAssertEqual(relay.transport, .vsock)
        XCTAssertNil(relay.cid)
        XCTAssertEqual(relay.target, "test-db")
    }

    func testLegacyServiceRelayDecodingWithUnixSocket() throws {
        try skipIfLegacyValidationDisabled()
        let json = """
        {"transport": "unix", "socket": "/tmp/honcho.sock"}
        """
        let data = json.data(using: .utf8)!
        let relay = try JSONDecoder().decode(ServiceRelay.self, from: data)

        XCTAssertEqual(relay.transport, .unix)
        XCTAssertEqual(relay.socket, "/tmp/honcho.sock")
    }

    func testLegacyServiceRelayDecodingWithTcp() throws {
        try skipIfLegacyValidationDisabled()
        let json = """
        {"transport": "tcp", "port": 8080, "target": "backend"}
        """
        let data = json.data(using: .utf8)!
        let relay = try JSONDecoder().decode(ServiceRelay.self, from: data)

        XCTAssertEqual(relay.transport, .tcp)
        XCTAssertEqual(relay.port, 8080)
        XCTAssertEqual(relay.target, "backend")
    }

    // MARK: - Service Integration Tests

    func testLegacyServiceWithRelayConfiguration() throws {
        try skipIfLegacyValidationDisabled()
        let relay = ServiceRelay(
            transport: .vsock,
            cid: 3,
            target: nil,
            port: 5432,
            socket: nil
        )

        let service = Service(
            image: "postgres:latest",
            relay: relay
        )

        XCTAssertNotNil(service.relay)
        XCTAssertEqual(service.relay?.transport, .vsock)
        XCTAssertEqual(service.relay?.cid, 3)
    }

    func testLegacyServiceWithoutRelayConfiguration() throws {
        try skipIfLegacyValidationDisabled()
        let service = Service(
            image: "nginx:latest"
        )

        XCTAssertNil(service.relay)
    }

    // MARK: - CID Validation Tests

    func testLegacyCIDUniquenessValidation() throws {
        try skipIfLegacyValidationDisabled()
        // Simulate services with CIDs
        let services: [(serviceName: String, service: Service)] = [
            ("db1", Service(image: "postgres", relay: ServiceRelay(transport: .vsock, cid: 3, port: 5432))),
            ("db2", Service(image: "postgres", relay: ServiceRelay(transport: .vsock, cid: 4, port: 5432))),
            ("db3", Service(image: "postgres", relay: ServiceRelay(transport: .vsock, cid: 5, port: 5432)))
        ]

        // Verify no duplicate CIDs
        var seenCIDs: Set<UInt32> = []
        for (name, svc) in services {
            if let cid = svc.relay?.cid {
                XCTAssertFalse(seenCIDs.contains(cid), "CID \(cid) is duplicated in service \(name)")
                seenCIDs.insert(cid)
            }
        }

        XCTAssertEqual(seenCIDs.count, 3, "Should have 3 unique CIDs")
    }

    func testLegacyDuplicateCIDDetection() throws {
        try skipIfLegacyValidationDisabled()
        let services: [(serviceName: String, service: Service)] = [
            ("db1", Service(image: "postgres", relay: ServiceRelay(transport: .vsock, cid: 3, port: 5432))),
            ("db2", Service(image: "postgres", relay: ServiceRelay(transport: .vsock, cid: 3, port: 5432))) // Duplicate CID
        ]

        var seenCIDs: [UInt32: String] = [:]
        var foundDuplicate = false

        for (name, svc) in services {
            if let cid = svc.relay?.cid {
                if let existing = seenCIDs[cid] {
                    foundDuplicate = true
                    XCTAssertEqual(existing, "db1")
                    XCTAssertEqual(name, "db2")
                }
                seenCIDs[cid] = name
            }
        }

        XCTAssertTrue(foundDuplicate, "Should detect duplicate CID")
    }

    // MARK: - Target Validation Tests

    func testLegacyTargetServiceExistenceValidation() throws {
        try skipIfLegacyValidationDisabled()
        let services: [(serviceName: String, service: Service)] = [
            ("test-db", Service(image: "postgres")),
            ("test-hub", Service(image: "honcho", relay: ServiceRelay(transport: .vsock, target: "test-db")))
        ]

        let serviceNames = Set(services.map { $0.serviceName })

        for (_, svc) in services {
            if let target = svc.relay?.target {
                XCTAssertTrue(serviceNames.contains(target), "Target \(target) should exist in services")
            }
        }
    }

    func testLegacyTargetServiceNotFound() throws {
        try skipIfLegacyValidationDisabled()
        let services: [(serviceName: String, service: Service)] = [
            ("test-hub", Service(image: "honcho", relay: ServiceRelay(transport: .vsock, target: "nonexistent-db")))
        ]

        let serviceNames = Set(services.map { $0.serviceName })
        let target = services[0].service.relay?.target

        XCTAssertNotNil(target)
        XCTAssertFalse(serviceNames.contains(target!), "Target should not exist in services")
    }

    // MARK: - Transport Compatibility Tests

    func testLegacyVsockTransportRequiresCIDOrTarget() throws {
        try skipIfLegacyValidationDisabled()
        // Valid: has CID
        let relayWithCID = ServiceRelay(transport: .vsock, cid: 3, port: 5432)
        XCTAssertTrue(relayWithCID.cid != nil || relayWithCID.target != nil)

        // Valid: has target
        let relayWithTarget = ServiceRelay(transport: .vsock, target: "db")
        XCTAssertTrue(relayWithTarget.cid != nil || relayWithTarget.target != nil)

        // Invalid: neither CID nor target
        let relayInvalid = ServiceRelay(transport: .vsock)
        XCTAssertFalse(relayInvalid.cid != nil || relayInvalid.target != nil)
    }

    func testLegacyUnixTransportRequiresSocket() throws {
        try skipIfLegacyValidationDisabled()
        // Valid: has socket
        let relayValid = ServiceRelay(transport: .unix, socket: "/tmp/test.sock")
        XCTAssertNotNil(relayValid.socket)

        // Invalid: no socket
        let relayInvalid = ServiceRelay(transport: .unix)
        XCTAssertNil(relayInvalid.socket)
    }

    func testLegacyTcpTransportRequiresPortOrTarget() throws {
        try skipIfLegacyValidationDisabled()
        // Valid: has port
        let relayWithPort = ServiceRelay(transport: .tcp, port: 8080)
        XCTAssertTrue(relayWithPort.port != nil || relayWithPort.target != nil)

        // Valid: has target
        let relayWithTarget = ServiceRelay(transport: .tcp, target: "backend")
        XCTAssertTrue(relayWithTarget.port != nil || relayWithTarget.target != nil)

        // Invalid: neither port nor target
        let relayInvalid = ServiceRelay(transport: .tcp)
        XCTAssertFalse(relayInvalid.port != nil || relayInvalid.target != nil)
    }

    // MARK: - Service Hashable Tests

    func testLegacyServiceWithRelayHashable() throws {
        try skipIfLegacyValidationDisabled()
        let relay = ServiceRelay(transport: .vsock, cid: 3, port: 5432)
        let service1 = Service(image: "postgres:latest", relay: relay)
        let service2 = Service(image: "postgres:latest", relay: relay)

        XCTAssertEqual(service1, service2)

        var hasher1 = Hasher()
        var hasher2 = Hasher()
        service1.hash(into: &hasher1)
        service2.hash(into: &hasher2)
        XCTAssertEqual(hasher1.finalize(), hasher2.finalize())
    }

func testLegacyServiceEqualityWithDifferentRelays() throws {
    try skipIfLegacyValidationDisabled()
    let service1 = Service(image: "postgres:latest", relay: ServiceRelay(transport: .vsock, cid: 3))
    let service2 = Service(image: "postgres:latest", relay: ServiceRelay(transport: .vsock, cid: 4))
    let service3 = Service(image: "postgres:latest", relay: nil)

    XCTAssertNotEqual(service1, service2)
    XCTAssertNotEqual(service1, service3)
  }

  // MARK: - Transport Type Preservation Tests (Plan 84 Phase 3)

func testLegacyRelayConfigurationPreservesVsockTransport() throws {
	try skipIfLegacyValidationDisabled()
	// Plan 88: vsock is deprecated - test remains for backward compatibility
	let transport = RelayTransport.vsock(cid: 2, port: 5432, unixSocketPath: "")
	let config = RelayManager.RelayConfiguration(
		id: "test-vsock-relay",
		tcpPort: 5432,
		transport: transport,
		description: "Test vsock relay"
	)

	// Verify transport type is preserved (not converted to unixSocket)
	if case .vsock(let cid, let port, _) = config.transport {
		XCTAssertEqual(cid, 2)
		XCTAssertEqual(port, 5432)
	} else {
		XCTFail("Transport should be .vsock, got \(config.transport)")
	}
}

func testLegacyRelayConfigurationPreservesUDSTransport() throws {
	try skipIfLegacyValidationDisabled()
	// Plan 88: New UDS transport for Virtio-FS
	let socketPath = "/tmp/test-uds-\(UUID().uuidString).sock"
	defer { try? FileManager.default.removeItem(atPath: socketPath) }

	let transport = RelayTransport.uds(path: socketPath, virtioFSMount: "/Volumes/apple")
	let config = RelayManager.RelayConfiguration(
		id: "test-uds-relay",
		tcpPort: 0,
		transport: transport,
		description: "Test UDS relay"
	)

	// Verify transport type is preserved
	if case .uds(let path, let mount) = config.transport {
		XCTAssertEqual(path, socketPath)
		XCTAssertEqual(mount, "/Volumes/apple")
	} else {
		XCTFail("Transport should be .uds, got \(config.transport)")
	}
}

  func testLegacyRelayConfigurationPreservesTcpTransport() throws {
    try skipIfLegacyValidationDisabled()
    let transport = RelayTransport.tcp(host: "0.0.0.0", port: 5432)
    let config = RelayManager.RelayConfiguration(
      id: "test-tcp-relay",
      tcpPort: 5432,
      transport: transport,
      description: "Test TCP relay"
    )

    if case .tcp(let host, let port) = config.transport {
      XCTAssertEqual(host, "0.0.0.0")
      XCTAssertEqual(port, 5432)
    } else {
      XCTFail("Transport should be .tcp, got \(config.transport)")
    }
  }

  func testLegacyRelayConfigurationPreservesUnixSocketTransport() throws {
    try skipIfLegacyValidationDisabled()
    let transport = RelayTransport.unixSocket(path: "/tmp/test.sock")
    let config = RelayManager.RelayConfiguration(
      id: "test-unix-relay",
      tcpPort: 5432,
      transport: transport,
      description: "Test Unix relay"
    )

        if case .unixSocket(let path) = config.transport {
            XCTAssertEqual(path, "/tmp/test.sock")
        } else {
            XCTFail("Transport should be .unixSocket, got \(config.transport)")
        }
    }

    // MARK: - Plan 88 Production Path Tests

  func testLegacyProductionSocketPath() throws {
    try skipIfLegacyValidationDisabled()
    // ACTUAL path from honcho-stack-with-derivers.yml (renamed to test-project)
    let path = "/Users/kieranlal/.containers/Volumes/test-project/test-db-sockets/.s.PGSQL.5432"
    XCTAssertEqual(path.count, 79, "Production path length is 79 characters (25-char margin)")
    XCTAssertLessThan(path.count, 104, "Production socket path must be under AF_UNIX limit")
  }

    func testLegacyHardErrorOnLongSocketPath() throws {
        try skipIfLegacyValidationDisabled()
        // Finding C-2: MUST fail at config time for paths ≥104 chars
        let longPath = String(repeating: "a", count: 110) + ".sock"
        XCTAssertThrowsError(try UDSVirtioFSRelay(
            socketPath: longPath,
            createSignalSocket: true,
            eventLog: RelayEventLog()
        )) { error in
            guard case UDSError.socketPathTooLong = error else {
                return XCTFail("Expected socketPathTooLong error, got: \(error)")
            }
        }
    }

    func testLegacySocketPathLengthMargins() throws {
        try skipIfLegacyValidationDisabled()
        // If path exceeds 104 chars, hard-error at config time
        let basePath = "/Users/kieranlal/.containers/Volumes/"
        let remaining = 104 - basePath.count // ~61 chars
        XCTAssertGreaterThanOrEqual(remaining, 40, "Sufficient margin for project names")
    }
}
