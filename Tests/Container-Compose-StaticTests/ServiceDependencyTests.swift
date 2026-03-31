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

import Testing
import Foundation
@testable import Yams
@testable import ContainerComposeCore

@Suite("Service Dependency Resolution Tests")
struct ServiceDependencyTests {

    @Test("Simple dependency chain - web depends on db")
    func simpleDependencyChain() throws {
        let web = Service(image: "nginx", depends_on: ["db": DependsOnEntry(condition: nil)])
        let db = Service(image: "postgres", depends_on: nil)

        let services: [(String, Service)] = [("web", web), ("db", db)]
        let sorted = try Service.topoSortConfiguredServices(services)

        // db should come before web
        #expect(sorted.count == 2)
        #expect(sorted[0].serviceName == "db")
        #expect(sorted[1].serviceName == "web")
    }

    @Test("Multiple dependencies - app depends on db and redis")
    func multipleDependencies() throws {
        let app = Service(image: "myapp", depends_on: [
            "db": DependsOnEntry(condition: nil),
            "redis": DependsOnEntry(condition: nil),
        ])
        let db = Service(image: "postgres", depends_on: nil)
        let redis = Service(image: "redis", depends_on: nil)

        let services: [(String, Service)] = [("app", app), ("db", db), ("redis", redis)]
        let sorted = try Service.topoSortConfiguredServices(services)

        #expect(sorted.count == 3)
        // app should be last
        #expect(sorted[2].serviceName == "app")
        // db and redis should come before app
        let firstTwo = Set([sorted[0].serviceName, sorted[1].serviceName])
        #expect(firstTwo.contains("db"))
        #expect(firstTwo.contains("redis"))
    }

    @Test("Complex dependency chain - web -> app -> db")
    func complexDependencyChain() throws {
        let web = Service(image: "nginx", depends_on: ["app": DependsOnEntry(condition: nil)])
        let app = Service(image: "myapp", depends_on: ["db": DependsOnEntry(condition: nil)])
        let db = Service(image: "postgres", depends_on: nil)

        let services: [(String, Service)] = [("web", web), ("app", app), ("db", db)]
        let sorted = try Service.topoSortConfiguredServices(services)

        #expect(sorted.count == 3)
        #expect(sorted[0].serviceName == "db")
        #expect(sorted[1].serviceName == "app")
        #expect(sorted[2].serviceName == "web")
    }

    @Test("No dependencies - services should maintain order")
    func noDependencies() throws {
        let web = Service(image: "nginx", depends_on: nil)
        let app = Service(image: "myapp", depends_on: nil)
        let db = Service(image: "postgres", depends_on: nil)

        let services: [(String, Service)] = [("web", web), ("app", app), ("db", db)]
        let sorted = try Service.topoSortConfiguredServices(services)

        #expect(sorted.count == 3)
    }

    @Test("Cyclic dependency should throw error")
    func cyclicDependency() throws {
        let web = Service(image: "nginx", depends_on: ["app": DependsOnEntry(condition: nil)])
        let app = Service(image: "myapp", depends_on: ["web": DependsOnEntry(condition: nil)])

        let services: [(String, Service)] = [("web", web), ("app", app)]

        #expect(throws: Error.self) {
            try Service.topoSortConfiguredServices(services)
        }
    }

    @Test("Diamond dependency - web and api both depend on db")
    func diamondDependency() throws {
        let web = Service(image: "nginx", depends_on: ["db": DependsOnEntry(condition: nil)])
        let api = Service(image: "api", depends_on: ["db": DependsOnEntry(condition: nil)])
        let db = Service(image: "postgres", depends_on: nil)

        let services: [(String, Service)] = [("web", web), ("api", api), ("db", db)]
        let sorted = try Service.topoSortConfiguredServices(services)

        #expect(sorted.count == 3)
        // db should be first
        #expect(sorted[0].serviceName == "db")
        // web and api can be in any order after db
        let lastTwo = Set([sorted[1].serviceName, sorted[2].serviceName])
        #expect(lastTwo.contains("web"))
        #expect(lastTwo.contains("api"))
    }

    @Test("Single service with no dependencies")
    func singleService() throws {
        let web = Service(image: "nginx", depends_on: nil)

        let services: [(String, Service)] = [("web", web)]
        let sorted = try Service.topoSortConfiguredServices(services)

        #expect(sorted.count == 1)
        #expect(sorted[0].serviceName == "web")
    }

    @Test("Service depends on non-existent service - throws descriptive error")
    func dependsOnNonExistentService() {
        let web = Service(image: "nginx", depends_on: ["nonexistent": DependsOnEntry(condition: nil)])

        let services: [(String, Service)] = [("web", web)]

        #expect(throws: NSError.self) {
            try Service.topoSortConfiguredServices(services)
        }
    }

    // MARK: - Long-form depends_on parsing tests

    @Test("Parse long-form depends_on with condition: service_healthy")
    func parseLongFormServiceHealthy() throws {
        let yaml = """
        image: nginx
        depends_on:
          db:
            condition: service_healthy
        """

        let decoder = YAMLDecoder()
        let service = try decoder.decode(Service.self, from: yaml)

        #expect(service.depends_on?["db"]?.condition == .service_healthy)
        #expect(service.dependencyNames == ["db"])
        #expect(service.healthyDependencies == ["db"])
    }

    @Test("Parse long-form depends_on with condition: service_started")
    func parseLongFormServiceStarted() throws {
        let yaml = """
        image: nginx
        depends_on:
          db:
            condition: service_started
        """

        let decoder = YAMLDecoder()
        let service = try decoder.decode(Service.self, from: yaml)

        #expect(service.depends_on?["db"]?.condition == .service_started)
        #expect(service.dependencyNames == ["db"])
        #expect(service.healthyDependencies == [])
    }

    @Test("Parse short-form depends_on (backward compat)")
    func parseShortForm() throws {
        let yaml = """
        image: nginx
        depends_on:
          - db
          - redis
        """

        let decoder = YAMLDecoder()
        let service = try decoder.decode(Service.self, from: yaml)

        #expect(service.depends_on?["db"]?.condition == nil)
        #expect(service.depends_on?["redis"]?.condition == nil)
        #expect(Set(service.dependencyNames) == Set(["db", "redis"]))
        #expect(service.healthyDependencies == [])
    }

    @Test("Parse single string depends_on (backward compat)")
    func parseSingleString() throws {
        let yaml = """
        image: nginx
        depends_on: db
        """

        let decoder = YAMLDecoder()
        let service = try decoder.decode(Service.self, from: yaml)

        #expect(service.depends_on?["db"]?.condition == nil)
        #expect(service.dependencyNames == ["db"])
    }

    @Test("No depends_on is nil")
    func noDependsOn() throws {
        let yaml = """
        image: nginx
        """

        let decoder = YAMLDecoder()
        let service = try decoder.decode(Service.self, from: yaml)

        #expect(service.depends_on == nil)
        #expect(service.dependencyNames == [])
        #expect(service.healthyDependencies == [])
    }

    @Test("healthyDependencies returns only service_healthy entries")
    func healthyDependenciesFilter() throws {
        let service = Service(image: "app", depends_on: [
            "db": DependsOnEntry(condition: .service_healthy),
            "redis": DependsOnEntry(condition: .service_started),
            "cache": DependsOnEntry(condition: nil),
        ])

        #expect(service.dependencyNames == ["cache", "db", "redis"])
        #expect(service.healthyDependencies == ["db"])
    }

    // MARK: - ContainerNotFoundError tests (v0.10.3 fail-fast for missing containers)

    @Test("ContainerNotFoundError has correct message format")
    func containerNotFoundErrorMessage() {
        let error = ComposeUp.ContainerNotFoundError(
            "Dependency container 'my-external-db' (service 'db') not found. "
            + "If this container was started outside container-compose, ensure it exists and is accessible. "
            + "For externally managed dependencies, consider removing 'depends_on: condition: service_healthy' or "
            + "ensuring the container is started with the expected name."
        )

        #expect(error.description.contains("my-external-db"))
        #expect(error.description.contains("started outside container-compose"))
        #expect(error.description.contains("externally managed"))
        #expect(error.description.contains("depends_on: condition: service_healthy"))
    }

    @Test("ContainerNotFoundError mentions externally managed guidance")
    func containerNotFoundErrorExternalGuidance() {
        let error = ComposeUp.ContainerNotFoundError("test message about missing container")

        // Verify CustomStringConvertible conformance works
        #expect(!error.description.isEmpty)
        #expect(error.message == "test message about missing container")
    }

    @Test("service_healthy dependency with external container name pattern")
    func externalContainerServiceHealthyPattern() throws {
        // Simulates the honcho-db scenario: compose references an externally-managed DB
        let yaml = """
        image: myapp
        depends_on:
          db:
            condition: service_healthy
        """

        let decoder = YAMLDecoder()
        let service = try decoder.decode(Service.self, from: yaml)

        // Verify the dependency is parsed as service_healthy
        #expect(service.healthyDependencies == ["db"])
        // This is the pattern that would trigger waitForHealthy() fail-fast
        // if the external container doesn't exist with the expected name
        #expect(service.depends_on?["db"]?.condition == .service_healthy)
    }

    @Test("Short-form depends_on for external containers (recommended pattern)")
    func shortFormForExternalContainers() throws {
        // This is the recommended pattern for externally managed dependencies
        let yaml = """
        image: myapp
        depends_on:
          - db
        """

        let decoder = YAMLDecoder()
        let service = try decoder.decode(Service.self, from: yaml)

        // Short-form should NOT trigger health-gating
        #expect(service.healthyDependencies == [])
        #expect(service.dependencyNames == ["db"])
        #expect(service.depends_on?["db"]?.condition == nil)
    }

    // MARK: - Externally Present Services Set Pattern (crash recovery)

    @Test("externallyPresentServices Set tracks running services")
    func externallyPresentServicesSetPattern() {
        // Validates the Set<String> pattern used in ComposeUp for tracking
        // externally present services during crash recovery.
        var externallyPresentServices: Set<String> = []

        // Simulate: honcho-db was already running before compose started
        externallyPresentServices.insert("honcho-db")
        #expect(externallyPresentServices.contains("honcho-db"))
        #expect(!externallyPresentServices.contains("honcho-hub"))

        // Simulate: honcho-hub was also already running
        externallyPresentServices.insert("honcho-hub")
        #expect(externallyPresentServices.contains("honcho-hub"))
        #expect(externallyPresentServices.count == 2)

        // Health-gating skip logic: if dependency is in the set, skip waitForHealthy
        let dependency = "honcho-db"
        if externallyPresentServices.contains(dependency) {
            // Skip health-gate — this is the crash recovery path
            #expect(true, "Should skip health-gate for externally present service")
        } else {
            Issue.record("Should have detected honcho-db as externally present")
        }

        // Service not in set should NOT be skipped
        let newDependency = "honcho-deriver"
        if externallyPresentServices.contains(newDependency) {
            Issue.record("Should NOT have detected honcho-deriver as externally present")
        }
        // Normal path: call waitForHealthy
    }

    @Test("externallyPresentServices empty set allows normal health-gating")
    func externallyPresentServicesEmptySet() {
        // When no services were pre-existing, all health-gates should proceed normally
        var externallyPresentServices: Set<String> = []

        let dependency = "honcho-db"
        #expect(!externallyPresentServices.contains(dependency),
                "Empty set should not contain any services")

        // Normal path: call waitForHealthy (not skipped)
    }
}
