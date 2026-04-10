import XCTest
@testable import ContainerComposeCore

final class RelayTransportTests: XCTestCase {
    
    // MARK: - RelayTransport Tests
    
    func testUnixSocketDescription() {
        let transport = RelayTransport.unixSocket(path: "/tmp/test.sock")
        XCTAssertEqual(transport.description, "unix:/tmp/test.sock")
    }
    
func testVsockDescription() {
	// Plan 88: vsock is deprecated - test remains for backward compatibility
	let transport = RelayTransport.vsock(cid: 3, port: 5432, unixSocketPath: "")
	XCTAssertEqual(transport.description, "vsock:3:5432")
}

func testUDSDescription() {
	// Plan 88: New UDS transport for Virtio-FS
	let transport = RelayTransport.uds(path: "/tmp/test.sock", virtioFSMount: nil)
	XCTAssertEqual(transport.description, "uds:/tmp/test.sock")
}
    
    func testUnixSocketPathExtraction() {
        let path = "/Users/test/.container-compose/sockets/db.sock"
        let transport = RelayTransport.unixSocket(path: path)
        
        if case .unixSocket(let extractedPath) = transport {
            XCTAssertEqual(extractedPath, path)
        } else {
            XCTFail("Expected unixSocket transport")
        }
    }
    
func testVsockParameterExtraction() {
	// Plan 88: vsock is deprecated - test remains for backward compatibility
	let transport = RelayTransport.vsock(cid: 42, port: 8080, unixSocketPath: "")

	if case .vsock(let cid, let port, _) = transport {
		XCTAssertEqual(cid, 42)
		XCTAssertEqual(port, 8080)
	} else {
		XCTFail("Expected vsock transport")
	}
}

func testUDSParameterExtraction() {
	// Plan 88: New UDS transport for Virtio-FS
	let socketPath = "/Users/test/.container-compose/sockets/db.sock"
	let transport = RelayTransport.uds(path: socketPath, virtioFSMount: "/Volumes/apple")

	if case .uds(let path, let mount) = transport {
		XCTAssertEqual(path, socketPath)
		XCTAssertEqual(mount, "/Volumes/apple")
	} else {
		XCTFail("Expected UDS transport")
	}
}
    
    // MARK: - RelayConfiguration Tests
    
    func testRelayConfigurationLegacyInitializer() {
        let config = RelayManager.RelayConfiguration(
            id: "test-relay",
            tcpPort: 5432,
            unixSocketPath: "/tmp/test.sock",
            description: "Test relay"
        )
        
        XCTAssertEqual(config.id, "test-relay")
        XCTAssertEqual(config.tcpPort, 5432)
        XCTAssertEqual(config.unixSocketPath, "/tmp/test.sock")
        XCTAssertNil(config.targetPID)
    }
    
func testRelayConfigurationTransportInitializer() {
    let transport = RelayTransport.vsock(cid: 5, port: 5432, unixSocketPath: "")
    let config = RelayManager.RelayConfiguration(
      id: "vsock-relay",
      tcpPort: 5432,
      transport: transport,
      description: "Vsock relay"
    )

    XCTAssertEqual(config.id, "vsock-relay")
    XCTAssertEqual(config.tcpPort, 5432)
    XCTAssertEqual(config.unixSocketPath, "") // vsock has no unix path
    XCTAssertNil(config.targetPID)
  }
    
    func testRelayConfigurationWithTargetPID() {
        let pid: pid_t = 12345
        let config = RelayManager.RelayConfiguration(
            id: "secure-relay",
            tcpPort: 5432,
            unixSocketPath: "/tmp/test.sock",
            description: "Secure relay",
            targetPID: pid
        )
        
        XCTAssertEqual(config.targetPID, pid)
    }
    
    func testRelayConfigurationUnixSocketBackwardCompatibility() {
        // Test that legacy code using unixSocketPath still works
        let config = RelayManager.RelayConfiguration(
            id: "legacy-relay",
            tcpPort: 5432,
            unixSocketPath: "/tmp/legacy.sock",
            description: "Legacy relay"
        )
        
        // Should still extract path correctly
        XCTAssertEqual(config.unixSocketPath, "/tmp/legacy.sock")
        
        // Should be unixSocket transport internally
        if case .unixSocket(let path) = config.transport {
            XCTAssertEqual(path, "/tmp/legacy.sock")
        } else {
            XCTFail("Expected unixSocket transport for legacy initializer")
        }
    }
    
func testRelayConfigurationVsockTransport() {
	// Plan 88: vsock is deprecated - test remains for backward compatibility
	let transport = RelayTransport.vsock(cid: 10, port: 9000, unixSocketPath: "")
	let config = RelayManager.RelayConfiguration(
		id: "vsock-config",
		tcpPort: 9000,
		transport: transport,
		description: "Vsock configuration"
	)

	// unixSocketPath should return empty string for vsock
	XCTAssertEqual(config.unixSocketPath, "")

	// Transport should be vsock
	if case .vsock(let cid, let port, _) = config.transport {
		XCTAssertEqual(cid, 10)
		XCTAssertEqual(port, 9000)
	} else {
		XCTFail("Expected vsock transport")
	}
}

func testRelayConfigurationUDSTransport() {
	// Plan 88: New UDS transport for Virtio-FS
	let socketPath = "/tmp/uds-test-\(UUID().uuidString).sock"
	defer { try? FileManager.default.removeItem(atPath: socketPath) }

	let transport = RelayTransport.uds(path: socketPath, virtioFSMount: nil)
	let config = RelayManager.RelayConfiguration(
		id: "uds-config",
		tcpPort: 0,
		transport: transport,
		description: "UDS configuration"
	)

	// unixSocketPath should return the UDS path
	XCTAssertEqual(config.unixSocketPath, socketPath)

	// Transport should be UDS
	if case .uds(let path, _) = config.transport {
		XCTAssertEqual(path, socketPath)
	} else {
		XCTFail("Expected UDS transport")
	}
}
    
    // MARK: - Transport Sendable Tests
    
func testTransportIsSendable() {
    // This test verifies that RelayTransport compiles as Sendable
    let transports: [RelayTransport] = [
      .unixSocket(path: "/tmp/a.sock"),
      .vsock(cid: 1, port: 1, unixSocketPath: "")
    ]

    XCTAssertEqual(transports.count, 2)
  }
}
