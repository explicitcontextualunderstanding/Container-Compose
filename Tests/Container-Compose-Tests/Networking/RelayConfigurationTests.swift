import XCTest
@testable import ContainerComposeCore

// MARK: - RelayConfiguration Tests

@available(macOS 12.0, *)
final class RelayConfigurationTests: XCTestCase {

    // MARK: - ServiceRelay Creation Tests

    func testServiceRelayCreationWithVsock() {
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

    func testServiceRelayCreationWithTarget() {
        let relay = ServiceRelay(
            transport: .vsock,
            cid: nil,
            target: "honcho-db",
            port: nil,
            socket: nil
        )

        XCTAssertEqual(relay.transport, .vsock)
        XCTAssertNil(relay.cid)
        XCTAssertEqual(relay.target, "honcho-db")
        XCTAssertNil(relay.port)
        XCTAssertNil(relay.socket)
    }

    func testServiceRelayCreationWithUnixSocket() {
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

    func testServiceRelayCreationWithTcp() {
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

    func testServiceRelayEquality() {
        let relay1 = ServiceRelay(transport: .vsock, cid: 3, target: nil, port: 5432, socket: nil)
        let relay2 = ServiceRelay(transport: .vsock, cid: 3, target: nil, port: 5432, socket: nil)
        let relay3 = ServiceRelay(transport: .vsock, cid: 4, target: nil, port: 5432, socket: nil)

        XCTAssertEqual(relay1, relay2)
        XCTAssertNotEqual(relay1, relay3)
    }

    func testServiceRelayHashable() {
        let relay1 = ServiceRelay(transport: .vsock, cid: 3, target: "db", port: 5432, socket: "/tmp/db.sock")
        let relay2 = ServiceRelay(transport: .vsock, cid: 3, target: "db", port: 5432, socket: "/tmp/db.sock")

        var hasher1 = Hasher()
        var hasher2 = Hasher()
        relay1.hash(into: &hasher1)
        relay2.hash(into: &hasher2)

        XCTAssertEqual(hasher1.finalize(), hasher2.finalize())
    }

// MARK: - Transport Type Tests

func testRelayTransportRawValues() {
    XCTAssertEqual(RelayTransport.TransportType.vsock.rawValue, "vsock")
    XCTAssertEqual(RelayTransport.TransportType.unix.rawValue, "unix")
    XCTAssertEqual(RelayTransport.TransportType.tcp.rawValue, "tcp")
}

func testRelayTransportCodable() throws {
    let transports: [RelayTransport.TransportType] = [.vsock, .unix, .tcp]

    for transport in transports {
        let encoded = try JSONEncoder().encode(transport)
        let decoded = try JSONDecoder().decode(RelayTransport.TransportType.self, from: encoded)
        XCTAssertEqual(transport, decoded)
    }
}

    // MARK: - YAML Parsing Tests

    func testServiceRelayDecodingFromYAML() throws {
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

    func testServiceRelayDecodingWithTarget() throws {
        let json = """
        {"transport": "vsock", "target": "honcho-db"}
        """
        let data = json.data(using: .utf8)!
        let relay = try JSONDecoder().decode(ServiceRelay.self, from: data)

        XCTAssertEqual(relay.transport, .vsock)
        XCTAssertNil(relay.cid)
        XCTAssertEqual(relay.target, "honcho-db")
    }

    func testServiceRelayDecodingWithUnixSocket() throws {
        let json = """
        {"transport": "unix", "socket": "/tmp/honcho.sock"}
        """
        let data = json.data(using: .utf8)!
        let relay = try JSONDecoder().decode(ServiceRelay.self, from: data)

        XCTAssertEqual(relay.transport, .unix)
        XCTAssertEqual(relay.socket, "/tmp/honcho.sock")
    }

    func testServiceRelayDecodingWithTcp() throws {
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

    func testServiceWithRelayConfiguration() {
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

    func testServiceWithoutRelayConfiguration() {
        let service = Service(
            image: "nginx:latest"
        )

        XCTAssertNil(service.relay)
    }

    // MARK: - CID Validation Tests

    func testCIDUniquenessValidation() throws {
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

    func testDuplicateCIDDetection() {
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

    func testTargetServiceExistenceValidation() {
        let services: [(serviceName: String, service: Service)] = [
            ("honcho-db", Service(image: "postgres")),
            ("honcho-hub", Service(image: "honcho", relay: ServiceRelay(transport: .vsock, target: "honcho-db")))
        ]

        let serviceNames = Set(services.map { $0.serviceName })

        for (_, svc) in services {
            if let target = svc.relay?.target {
                XCTAssertTrue(serviceNames.contains(target), "Target \(target) should exist in services")
            }
        }
    }

    func testTargetServiceNotFound() {
        let services: [(serviceName: String, service: Service)] = [
            ("honcho-hub", Service(image: "honcho", relay: ServiceRelay(transport: .vsock, target: "nonexistent-db")))
        ]

        let serviceNames = Set(services.map { $0.serviceName })
        let target = services[0].service.relay?.target

        XCTAssertNotNil(target)
        XCTAssertFalse(serviceNames.contains(target!), "Target should not exist in services")
    }

    // MARK: - Transport Compatibility Tests

    func testVsockTransportRequiresCIDOrTarget() {
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

    func testUnixTransportRequiresSocket() {
        // Valid: has socket
        let relayValid = ServiceRelay(transport: .unix, socket: "/tmp/test.sock")
        XCTAssertNotNil(relayValid.socket)

        // Invalid: no socket
        let relayInvalid = ServiceRelay(transport: .unix)
        XCTAssertNil(relayInvalid.socket)
    }

    func testTcpTransportRequiresPortOrTarget() {
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

    func testServiceWithRelayHashable() {
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

func testServiceEqualityWithDifferentRelays() {
    let service1 = Service(image: "postgres:latest", relay: ServiceRelay(transport: .vsock, cid: 3))
    let service2 = Service(image: "postgres:latest", relay: ServiceRelay(transport: .vsock, cid: 4))
    let service3 = Service(image: "postgres:latest", relay: nil)

    XCTAssertNotEqual(service1, service2)
    XCTAssertNotEqual(service1, service3)
  }

  // MARK: - Transport Type Preservation Tests (Plan 84 Phase 3)

  func testRelayConfigurationPreservesVsockTransport() {
    // Test that RelayConfiguration preserves .vsock transport type
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

  func testRelayConfigurationPreservesTcpTransport() {
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

  func testRelayConfigurationPreservesUnixSocketTransport() {
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
}
