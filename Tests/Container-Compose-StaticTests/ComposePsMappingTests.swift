//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import XCTest
@testable import ContainerComposeCore
import Foundation

final class ComposePsMappingTests: XCTestCase {

    // MARK: - Cycle 1: Data Model + Command Registration

    func testPsStateRawValues() throws {
        XCTAssertEqual(ComposePs.PsState.running.rawValue, "running")
        XCTAssertEqual(ComposePs.PsState.stopped.rawValue, "stopped")
        XCTAssertEqual(ComposePs.PsState.stopping.rawValue, "stopping")
        XCTAssertEqual(ComposePs.PsState.unknown.rawValue, "unknown")
        XCTAssertEqual(ComposePs.PsState.missing.rawValue, "missing")
    }

    func testPsStatusCodableRoundTrip() throws {
        let status = ComposePs.PsStatus(
            service: "web",
            container: "myapp-web",
            state: .running,
            id: "abcdef123456",
            ip: "192.168.64.2",
            ports: ["0.0.0.0:8080->80/tcp"],
            started: Date(timeIntervalSince1970: 1713000000)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(status)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComposePs.PsStatus.self, from: data)
        XCTAssertEqual(decoded.service, "web")
        XCTAssertEqual(decoded.container, "myapp-web")
        XCTAssertEqual(decoded.state, .running)
        XCTAssertEqual(decoded.id, "abcdef123456")
        XCTAssertEqual(decoded.ip, "192.168.64.2")
        XCTAssertEqual(decoded.ports, ["0.0.0.0:8080->80/tcp"])
        XCTAssertEqual(decoded.started, Date(timeIntervalSince1970: 1713000000))
    }

    func testPsStatusMissingStateCodable() throws {
        let status = ComposePs.PsStatus(
            service: "db",
            container: "myapp-db",
            state: .missing,
            id: nil,
            ip: nil,
            ports: nil,
            started: nil
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(ComposePs.PsStatus.self, from: data)
        XCTAssertEqual(decoded.state, .missing)
        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.ip)
        XCTAssertNil(decoded.ports)
        XCTAssertNil(decoded.started)
    }

    func testPsStatusJSONKeys() throws {
        let status = ComposePs.PsStatus(
            service: "api", container: "myapp-api", state: .running,
            id: "abc123", ip: "10.0.0.1", ports: ["80->8080/tcp"],
            started: nil
        )
        let data = try JSONEncoder().encode(status)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(json.keys.contains("service"))
        XCTAssertTrue(json.keys.contains("container"))
        XCTAssertTrue(json.keys.contains("state"))
        XCTAssertTrue(json.keys.contains("id"))
        XCTAssertTrue(json.keys.contains("ip"))
        XCTAssertTrue(json.keys.contains("ports"))
        // Note: started is nil, so default Codable omits the key
        XCTAssertTrue(json["started"] == nil || json["started"] is NSNull, "started should be absent or null when nil")
    }

    func testPsStatusPortsArrayEncoding() throws {
        let status = ComposePs.PsStatus(
            service: "web", container: "myapp-web", state: .running,
            id: nil, ip: nil,
            ports: ["0.0.0.0:15432->5432/tcp", "0.0.0.0:15433->5432/tcp"],
            started: nil
        )
        let data = try JSONEncoder().encode(status)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ports = json["ports"] as! [String]
        XCTAssertEqual(ports.count, 2)
        XCTAssertEqual(ports[0], "0.0.0.0:15432->5432/tcp")
        XCTAssertEqual(ports[1], "0.0.0.0:15433->5432/tcp")
    }

    func testPsStatusStartedDateISO8601() throws {
        let date = Date(timeIntervalSince1970: 1713000000)
        let status = ComposePs.PsStatus(
            service: "web", container: "myapp-web", state: .running,
            id: nil, ip: nil, ports: nil, started: date
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let startedStr = json["started"] as! String
        XCTAssertTrue(startedStr.contains("2024"))
    }

    func testComposePsCommandConfiguration() throws {
        XCTAssertEqual(ComposePs.configuration.commandName, "ps")
    }

    func testComposePsIsRegisteredAsSubcommand() throws {
        XCTAssertTrue(Main.configuration.subcommands.contains(where: { $0 == ComposePs.self }))
    }

    // MARK: - Cycle 2: Service-to-Container Matching (15 tests)

    /// Helper: create a minimal Service with image and optional container_name
    private func makeService(image: String? = "nginx:alpine", containerName: String? = nil) -> Service {
        Service(image: image, container_name: containerName)
    }

    func testMatchByContainerNameOverride() throws {
        let services: [(name: String, service: Service)] = [
            ("db", makeService(image: "postgres:15", containerName: "my-db"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "my-db", id: "abc123def456", state: .running, ip: "192.168.64.3", ports: ["5432/tcp"], startedDate: Date())
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "myapp", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].service, "db")
        XCTAssertEqual(result[0].state, .running)
        XCTAssertEqual(result[0].container, "my-db")
        XCTAssertEqual(result[0].ip, "192.168.64.3")
    }

    func testMatchByProjectServiceConvention() throws {
        let services: [(name: String, service: Service)] = [
            ("web", makeService(image: "nginx:alpine"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "myapp-web", id: "myapp-web", state: .running, ip: "192.168.64.2", ports: ["80/tcp"], startedDate: Date())
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "myapp", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].service, "web")
        XCTAssertEqual(result[0].container, "myapp-web")
    }

    func testUnmatchedServiceShowsMissing() throws {
        let services: [(name: String, service: Service)] = [
            ("cache", makeService(image: "redis:alpine"))
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "myapp", containers: [], serviceFilter: nil)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].state, .missing)
        XCTAssertNil(result[0].id)
        XCTAssertNil(result[0].ip)
        XCTAssertNil(result[0].ports)
        XCTAssertNil(result[0].started)
    }

    func testStoppedContainerMatches() throws {
        let services: [(name: String, service: Service)] = [
            ("db", makeService(image: "postgres:15", containerName: "my-db"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "my-db", id: "my-db", state: .stopped, ip: nil, ports: [], startedDate: nil)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "myapp", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result[0].state, .stopped)
    }

    func testStoppingContainerMatches() throws {
        let services: [(name: String, service: Service)] = [
            ("web", makeService(image: "nginx"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "myapp-web", id: "myapp-web", state: .stopping, ip: nil, ports: [], startedDate: nil)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "myapp", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result[0].state, .stopping)
    }

    func testUnknownStatusContainer() throws {
        let services: [(name: String, service: Service)] = [
            ("api", makeService(image: "node:20", containerName: "my-api"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "my-api", id: "my-api", state: .unknown, ip: nil, ports: [], startedDate: nil)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "myapp", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result[0].state, .unknown)
    }

    func testMultipleServicesPartialMatch() throws {
        let services: [(name: String, service: Service)] = [
            ("web", makeService(image: "nginx")),
            ("db", makeService(image: "postgres")),
            ("cache", makeService(image: "redis"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "myapp-web", id: "myapp-web", state: .running, ip: "10.0.0.1", ports: ["80/tcp"], startedDate: Date()),
            ComposePs.ContainerInfo(name: "myapp-db", id: "myapp-db", state: .running, ip: "10.0.0.2", ports: ["5432/tcp"], startedDate: Date())
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "myapp", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].state, .running)   // web
        XCTAssertEqual(result[1].state, .running)   // db
        XCTAssertEqual(result[2].state, .missing)   // cache
    }

    func testContainerNameOverrideTakesPriority() throws {
        let services: [(name: String, service: Service)] = [
            ("db", makeService(image: "postgres", containerName: "custom-db"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "custom-db", id: "custom-db", state: .running, ip: "10.0.0.1", ports: [], startedDate: Date()),
            ComposePs.ContainerInfo(name: "myapp-db", id: "myapp-db", state: .stopped, ip: nil, ports: [], startedDate: nil)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "myapp", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].container, "custom-db")
        XCTAssertEqual(result[0].state, .running)
    }

    func testMatchingPopulatesIP() throws {
        let services: [(name: String, service: Service)] = [
            ("api", makeService(image: "node", containerName: "my-api"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "my-api", id: "my-api", state: .running, ip: "192.168.64.10", ports: [], startedDate: nil)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "app", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result[0].ip, "192.168.64.10")
    }

    func testMatchingPopulatesPorts() throws {
        let services: [(name: String, service: Service)] = [
            ("web", makeService(image: "nginx", containerName: "my-web"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "my-web", id: "my-web", state: .running, ip: nil, ports: ["0.0.0.0:8080->80/tcp", "0.0.0.0:8443->443/tcp"], startedDate: nil)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "app", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result[0].ports, ["0.0.0.0:8080->80/tcp", "0.0.0.0:8443->443/tcp"])
    }

    func testMatchingPopulatesStartedDate() throws {
        let date = Date(timeIntervalSince1970: 1713000000)
        let services: [(name: String, service: Service)] = [
            ("web", makeService(image: "nginx", containerName: "my-web"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "my-web", id: "my-web", state: .running, ip: nil, ports: [], startedDate: date)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "app", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result[0].started, date)
    }

    func testMatchingTruncatesID() throws {
        let services: [(name: String, service: Service)] = [
            ("web", makeService(image: "nginx", containerName: "my-web"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "my-web", id: "abcdefghijklmnopqrstuvwx", state: .running, ip: nil, ports: [], startedDate: nil)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "app", containers: containers, serviceFilter: nil)
        XCTAssertEqual(result[0].id, "abcdefghijkl")
        XCTAssertEqual(result[0].id?.count, 12)
    }

    func testMatchingWithEmptyServicesList() throws {
        let result = ComposePs.matchServicesToContainers(services: [], projectName: "app", containers: [], serviceFilter: nil)
        XCTAssertTrue(result.isEmpty)
    }

    func testMatchingFiltersByServiceName() throws {
        let services: [(name: String, service: Service)] = [
            ("web", makeService(image: "nginx")),
            ("db", makeService(image: "postgres"))
        ]
        let containers = [
            ComposePs.ContainerInfo(name: "app-web", id: "app-web", state: .running, ip: nil, ports: [], startedDate: nil),
            ComposePs.ContainerInfo(name: "app-db", id: "app-db", state: .running, ip: nil, ports: [], startedDate: nil)
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "app", containers: containers, serviceFilter: "db")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].service, "db")
    }

    func testMatchingFilterNonexistentService() throws {
        let services: [(name: String, service: Service)] = [
            ("web", makeService(image: "nginx"))
        ]
        let result = ComposePs.matchServicesToContainers(services: services, projectName: "app", containers: [], serviceFilter: "nonexistent")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Cycle 3: Table + JSON Output Formatting (17 tests)

    private func makeRunningStatus(service: String, container: String, id: String = "abc123", ip: String = "192.168.64.2", ports: [String] = ["8080->80/tcp"]) -> ComposePs.PsStatus {
        ComposePs.PsStatus(service: service, container: container, state: .running, id: id, ip: ip, ports: ports, started: Date())
    }

    private func makeMissingStatus(service: String, container: String) -> ComposePs.PsStatus {
        ComposePs.PsStatus(service: service, container: container, state: .missing, id: nil, ip: nil, ports: nil, started: nil)
    }

    private func makeStoppedStatus(service: String, container: String) -> ComposePs.PsStatus {
        ComposePs.PsStatus(service: service, container: container, state: .stopped, id: "abc123", ip: nil, ports: nil, started: nil)
    }

    func testTableHeaderColumns() throws {
        let output = ComposePs.formatPsTable([])
        XCTAssertTrue(output.contains("SERVICE"))
        XCTAssertTrue(output.contains("STATE"))
        XCTAssertTrue(output.contains("ID"))
        XCTAssertTrue(output.contains("IP"))
        XCTAssertTrue(output.contains("PORTS"))
        XCTAssertTrue(output.contains("STARTED"))
    }

    func testTableRunningRow() throws {
        let statuses = [makeRunningStatus(service: "web", container: "myapp-web")]
        let output = ComposePs.formatPsTable(statuses)
        XCTAssertTrue(output.contains("web"))
        XCTAssertTrue(output.contains("running"))
        XCTAssertTrue(output.contains("abc123"))
        XCTAssertTrue(output.contains("192.168.64.2"))
        XCTAssertTrue(output.contains("8080->80/tcp"))
    }

    func testTableMissingRow() throws {
        let statuses = [makeMissingStatus(service: "cache", container: "myapp-cache")]
        let output = ComposePs.formatPsTable(statuses)
        XCTAssertTrue(output.contains("cache"))
        XCTAssertTrue(output.contains("missing"))
    }

    func testTableStoppedRow() throws {
        let statuses = [makeStoppedStatus(service: "db", container: "myapp-db")]
        let output = ComposePs.formatPsTable(statuses)
        XCTAssertTrue(output.contains("stopped"))
    }

    func testTableMultipleRows() throws {
        let statuses = [
            makeRunningStatus(service: "web", container: "myapp-web"),
            makeRunningStatus(service: "db", container: "myapp-db", id: "def456", ip: "10.0.0.1"),
            makeMissingStatus(service: "cache", container: "myapp-cache")
        ]
        let output = ComposePs.formatPsTable(statuses)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        // header + separator + 3 data rows = at least 5
        XCTAssertTrue(lines.count >= 5)
    }

    func testTableEmptyServices() throws {
        let output = ComposePs.formatPsTable([])
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Only header + separator, no data rows
        XCTAssertTrue(lines.count <= 3)
    }

    func testIDTruncationTo12Chars() throws {
        let status = ComposePs.PsStatus(service: "web", container: "myapp-web", state: .running,
            id: "abcdefghijklmnopqrstuvwx", ip: nil, ports: nil, started: nil)
        let output = ComposePs.formatPsTable([status])
        XCTAssertTrue(output.contains("abcdefghijkl"))
        XCTAssertFalse(output.contains("abcdefghijklmnop"))
    }

    func testPortsFormatting() throws {
        let statuses = [makeRunningStatus(service: "web", container: "myapp-web", ports: ["8080->80/tcp", "8443->443/tcp"])]
        let output = ComposePs.formatPsTable(statuses)
        XCTAssertTrue(output.contains("8080->80/tcp"))
        XCTAssertTrue(output.contains("8443->443/tcp"))
    }

    func testNoPortsShowsDash() throws {
        let status = ComposePs.PsStatus(service: "web", container: "myapp-web", state: .running,
            id: "abc123", ip: "10.0.0.1", ports: nil, started: nil)
        let output = ComposePs.formatPsTable([status])
        // Nil ports should show "-" in PORTS column
        XCTAssertTrue(output.contains("-") || !output.contains("PORTS"))
    }

    func testSummaryAllRunning() throws {
        let statuses = [
            makeRunningStatus(service: "web", container: "a"),
            makeRunningStatus(service: "db", container: "b"),
            makeRunningStatus(service: "cache", container: "c")
        ]
        let summary = ComposePs.formatSummary(statuses)
        XCTAssertTrue(summary.contains("3/3 services running"))
    }

    func testSummaryPartialRunning() throws {
        let statuses = [
            makeRunningStatus(service: "web", container: "a"),
            makeStoppedStatus(service: "db", container: "b"),
            makeMissingStatus(service: "cache", container: "c"),
            makeRunningStatus(service: "api", container: "d")
        ]
        let summary = ComposePs.formatSummary(statuses)
        XCTAssertTrue(summary.contains("2/4 services running"))
        XCTAssertTrue(summary.contains("1 stopped"))
        XCTAssertTrue(summary.contains("1 missing"))
    }

    func testSummaryAllMissing() throws {
        let statuses = [
            makeMissingStatus(service: "web", container: "a"),
            makeMissingStatus(service: "db", container: "b")
        ]
        let summary = ComposePs.formatSummary(statuses)
        XCTAssertTrue(summary.contains("0/2 services running"))
        XCTAssertTrue(summary.contains("2 missing"))
    }

    func testSummaryEmptyServices() throws {
        let summary = ComposePs.formatSummary([])
        XCTAssertTrue(summary.contains("0/0 services running"))
    }

    func testJsonOutputValidJSON() throws {
        let statuses = [makeRunningStatus(service: "web", container: "myapp-web")]
        let output = try ComposePs.formatPsJSON(statuses)
        let data = Data(output.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any])
    }

    func testJsonOutputMatchesSchema() throws {
        let statuses = [makeRunningStatus(service: "web", container: "myapp-web")]
        let output = try ComposePs.formatPsJSON(statuses)
        let data = Data(output.utf8)
        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let entry = json[0]
        XCTAssertTrue(entry.keys.contains("service"))
        XCTAssertTrue(entry.keys.contains("container"))
        XCTAssertTrue(entry.keys.contains("state"))
        XCTAssertTrue(entry.keys.contains("id"))
        XCTAssertTrue(entry.keys.contains("ip"))
        XCTAssertTrue(entry.keys.contains("ports"))
    }

    func testJsonOutputEmptyArray() throws {
        let output = try ComposePs.formatPsJSON([])
        let data = Data(output.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        let array = json as! [Any]
        XCTAssertTrue(array.isEmpty)
    }

    func testJsonOutputPortsArray() throws {
        let statuses = [makeRunningStatus(service: "web", container: "myapp-web", ports: ["8080->80/tcp"])]
        let output = try ComposePs.formatPsJSON(statuses)
        let data = Data(output.utf8)
        let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertTrue(json[0]["ports"] is [String])
    }
}
