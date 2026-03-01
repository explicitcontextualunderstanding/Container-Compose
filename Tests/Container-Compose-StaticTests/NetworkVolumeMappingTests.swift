import XCTest
@testable import ContainerComposeCore
import Yams

final class NetworkVolumeMappingTests: XCTestCase {
    
    func testNetworkMapping_Basic() throws {
        let network = try YAMLDecoder().decode(Network.self, from: "name: my-net")
        let args = ComposeUp.makeNetworkCreateArgs(name: "my-net", config: network)
        
        XCTAssertEqual(args, ["my-net"])
    }
    
    func testNetworkMapping_Internal() throws {
        let network = try YAMLDecoder().decode(Network.self, from: "internal: true")
        let args = ComposeUp.makeNetworkCreateArgs(name: "my-net", config: network)
        
        XCTAssertTrue(args.contains("--internal"))
        XCTAssertEqual(args.last, "my-net")
    }
    
    func testNetworkMapping_Labels() throws {
        let yaml = """
        labels:
          com.example.description: "Test Network"
          type: "frontend"
        """
        let network = try YAMLDecoder().decode(Network.self, from: yaml)
        let args = ComposeUp.makeNetworkCreateArgs(name: "my-net", config: network)
        
        XCTAssertTrue(args.contains("--label"))
        XCTAssertTrue(args.contains("type=frontend"))
        XCTAssertTrue(args.contains("com.example.description=Test Network"))
    }
    
    func testNetworkMapping_Subnet() throws {
        let yaml = """
        ipam:
          config:
            - subnet: 172.20.0.0/16
        """
        let network = try YAMLDecoder().decode(Network.self, from: yaml)
        let args = ComposeUp.makeNetworkCreateArgs(name: "my-net", config: network)
        
        XCTAssertTrue(args.contains("--subnet"))
        XCTAssertTrue(args.contains("172.20.0.0/16"))
    }
    
    func testVolumeMapping_Basic() throws {
        let volume = try YAMLDecoder().decode(Volume.self, from: "name: my-vol")
        let args = ComposeUp.makeVolumeCreateArgs(name: "my-vol", config: volume)
        
        XCTAssertEqual(args, ["my-vol"])
    }
    
    func testVolumeMapping_Labels() throws {
        let yaml = """
        labels:
          storage: "ssd"
        """
        let volume = try YAMLDecoder().decode(Volume.self, from: yaml)
        let args = ComposeUp.makeVolumeCreateArgs(name: "my-vol", config: volume)
        
        XCTAssertTrue(args.contains("--label"))
        XCTAssertTrue(args.contains("storage=ssd"))
    }
    
    func testVolumeMapping_Opts() throws {
        let yaml = """
        driver_opts:
          type: "nfs"
          device: ":/path/to/dir"
        """
        let volume = try YAMLDecoder().decode(Volume.self, from: yaml)
        let args = ComposeUp.makeVolumeCreateArgs(name: "my-vol", config: volume)
        
        XCTAssertTrue(args.contains("--opt"))
        XCTAssertTrue(args.contains("type=nfs"))
        XCTAssertTrue(args.contains("device=:/path/to/dir"))
    }
}
