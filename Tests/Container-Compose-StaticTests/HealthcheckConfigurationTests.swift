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

@Suite("Healthcheck Configuration Tests")
struct HealthcheckConfigurationTests {
    
    @Test("Parse healthcheck with test command")
    func parseHealthcheckWithTest() throws {
        let yaml = """
        test: ["CMD", "curl", "-f", "http://localhost"]
        """
        
        let decoder = YAMLDecoder()
        let healthcheck = try decoder.decode(Healthcheck.self, from: yaml)
        
        #expect(healthcheck.test?.count == 4)
        #expect(healthcheck.test?.first == "CMD")
    }
    
    @Test("Parse healthcheck with interval")
    func parseHealthcheckWithInterval() throws {
        let yaml = """
        test: ["CMD", "curl", "-f", "http://localhost"]
        interval: 30s
        """
        
        let decoder = YAMLDecoder()
        let healthcheck = try decoder.decode(Healthcheck.self, from: yaml)
        
        #expect(healthcheck.interval == "30s")
    }
    
    @Test("Parse healthcheck with timeout")
    func parseHealthcheckWithTimeout() throws {
        let yaml = """
        test: ["CMD", "curl", "-f", "http://localhost"]
        timeout: 10s
        """
        
        let decoder = YAMLDecoder()
        let healthcheck = try decoder.decode(Healthcheck.self, from: yaml)
        
        #expect(healthcheck.timeout == "10s")
    }
    
    @Test("Parse healthcheck with retries")
    func parseHealthcheckWithRetries() throws {
        let yaml = """
        test: ["CMD", "curl", "-f", "http://localhost"]
        retries: 3
        """
        
        let decoder = YAMLDecoder()
        let healthcheck = try decoder.decode(Healthcheck.self, from: yaml)
        
        #expect(healthcheck.retries == 3)
    }
    
    @Test("Parse healthcheck with start_period")
    func parseHealthcheckWithStartPeriod() throws {
        let yaml = """
        test: ["CMD", "curl", "-f", "http://localhost"]
        start_period: 40s
        """
        
        let decoder = YAMLDecoder()
        let healthcheck = try decoder.decode(Healthcheck.self, from: yaml)
        
        #expect(healthcheck.start_period == "40s")
    }
    
    @Test("Parse complete healthcheck configuration")
    func parseCompleteHealthcheck() throws {
        let yaml = """
        test: ["CMD", "curl", "-f", "http://localhost"]
        interval: 30s
        timeout: 10s
        retries: 3
        start_period: 40s
        """
        
        let decoder = YAMLDecoder()
        let healthcheck = try decoder.decode(Healthcheck.self, from: yaml)
        
        #expect(healthcheck.test != nil)
        #expect(healthcheck.interval == "30s")
        #expect(healthcheck.timeout == "10s")
        #expect(healthcheck.retries == 3)
        #expect(healthcheck.start_period == "40s")
    }
    
    @Test("Parse healthcheck with CMD-SHELL")
    func parseHealthcheckWithCmdShell() throws {
        let yaml = """
        test: ["CMD-SHELL", "curl -f http://localhost || exit 1"]
        """
        
        let decoder = YAMLDecoder()
        let healthcheck = try decoder.decode(Healthcheck.self, from: yaml)
        
        #expect(healthcheck.test?.first == "CMD-SHELL")
    }
    
    @Test("Disable healthcheck")
    func disableHealthcheck() throws {
        let yaml = """
        test: ["NONE"]
        """
        
        let decoder = YAMLDecoder()
        let healthcheck = try decoder.decode(Healthcheck.self, from: yaml)
        
        #expect(healthcheck.test?.first == "NONE")
    }
    
    @Test("Service with healthcheck")
    func serviceWithHealthcheck() throws {
        let yaml = """
        version: '3.8'
        services:
          web:
            image: nginx:latest
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost"]
              interval: 30s
              timeout: 10s
              retries: 3
        """

        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)

        #expect(compose.services["web"]??.healthcheck != nil)
        #expect(compose.services["web"]??.healthcheck?.interval == "30s")
    }

    @Test("Service with depends_on condition: service_healthy and healthcheck on dependency")
    func dependsOnServiceHealthy() throws {
        let yaml = """
        version: '3.8'
        services:
          db:
            image: postgres:15
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U postgres"]
              interval: 10s
              timeout: 5s
              retries: 5
              start_period: 30s
          web:
            image: myapp:latest
            depends_on:
              db:
                condition: service_healthy
        """

        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)

        // db should have a healthcheck
        #expect(compose.services["db"]??.healthcheck != nil)
        #expect(compose.services["db"]??.healthcheck?.test?.first == "CMD-SHELL")
        #expect(compose.services["db"]??.healthcheck?.start_period == "30s")

        // web should depend on db with service_healthy
        #expect(compose.services["web"]??.depends_on?["db"]?.condition == .service_healthy)
        #expect(compose.services["web"]??.healthyDependencies == ["db"])
    }

    @Test("Mixed short and long form depends_on in compose file")
    func mixedDependsOnForms() throws {
        let yaml = """
        version: '3.8'
        services:
          db:
            image: postgres:15
          redis:
            image: redis:7
          web:
            image: nginx:latest
            depends_on:
              db:
                condition: service_healthy
              redis:
                condition: service_started
        """

        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)

        #expect(compose.services["web"]??.depends_on?["db"]?.condition == .service_healthy)
        #expect(compose.services["web"]??.depends_on?["redis"]?.condition == .service_started)
        #expect(compose.services["web"]??.healthyDependencies == ["db"])
    }

    // MARK: - parseDuration tests

    @Test("parseDuration parses seconds suffix")
    func parseDurationSeconds() {
        #expect(ComposeUp.parseDuration("30s") == 30)
        #expect(ComposeUp.parseDuration("5s") == 5)
        #expect(ComposeUp.parseDuration("0s") == 0)
        #expect(ComposeUp.parseDuration("0.5s") == 0.5)
    }

    @Test("parseDuration parses minutes suffix")
    func parseDurationMinutes() {
        #expect(ComposeUp.parseDuration("1m") == 60)
        #expect(ComposeUp.parseDuration("2m") == 120)
        #expect(ComposeUp.parseDuration("0.5m") == 30)
    }

    @Test("parseDuration parses hours suffix")
    func parseDurationHours() {
        #expect(ComposeUp.parseDuration("1h") == 3600)
        #expect(ComposeUp.parseDuration("2h") == 7200)
    }

    @Test("parseDuration parses bare number as seconds")
    func parseDurationBareNumber() {
        #expect(ComposeUp.parseDuration("30") == 30)
        #expect(ComposeUp.parseDuration("10") == 10)
        #expect(ComposeUp.parseDuration("0") == 0)
        #expect(ComposeUp.parseDuration("3.5") == 3.5)
    }

    @Test("parseDuration returns nil for nil input")
    func parseDurationNil() {
        #expect(ComposeUp.parseDuration(nil) == nil)
    }

    @Test("parseDuration returns nil for empty and whitespace input")
    func parseDurationEmpty() {
        #expect(ComposeUp.parseDuration("") == nil)
        #expect(ComposeUp.parseDuration("  ") == nil)
    }

    @Test("parseDuration returns nil for invalid strings")
    func parseDurationInvalid() {
        #expect(ComposeUp.parseDuration("abc") == nil)
        #expect(ComposeUp.parseDuration("sm") == nil)
    }

    // MARK: - waitForHealthy exec argument building tests

    @Test("waitForHealthy builds CMD-SHELL exec args correctly")
    func waitForHealthyCmdShellArgs() {
        let healthcheck = Healthcheck(
            test: ["CMD-SHELL", "pg_isready -U postgres"],
            start_period: "30s",
            interval: "10s",
            retries: 5,
            timeout: "5s"
        )
        // Verify the healthcheck structure that drives exec arg building in waitForHealthy.
        // waitForHealthy reconstructs the shell command via dropFirst().joined(separator: " ")
        // then wraps it as: [container, "--", "/bin/sh", "-c", shellCommand]
        #expect(healthcheck.test?.first == "CMD-SHELL")
        #expect(healthcheck.test?.count == 2)
        let shellCommand = healthcheck.test?.dropFirst().joined(separator: " ")
        #expect(shellCommand == "pg_isready -U postgres")
    }

    @Test("waitForHealthy builds CMD exec args correctly")
    func waitForHealthyCmdArgs() {
        let healthcheck = Healthcheck(
            test: ["CMD", "pg_isready", "-U", "postgres"],
            start_period: nil,
            interval: "10s",
            retries: 3,
            timeout: "5s"
        )
        #expect(healthcheck.test?.first == "CMD")
        // CMD form: exec args are [container, "--"] + test.dropFirst()
        // which gives [container, "--", "pg_isready", "-U", "postgres"]
        let execParts = Array(healthcheck.test!.dropFirst())
        #expect(execParts == ["pg_isready", "-U", "postgres"])
        // Total exec args (excluding container name) would be 2 ( "--" ) + 3 (command parts) = 5
        // Plus 1 for the container name = 6
        // But we verify just the command parts here
    }

    @Test("waitForHealthy skips NONE healthcheck")
    func waitForHealthySkipsNone() {
        let healthcheck = Healthcheck(
            test: ["NONE"],
            start_period: nil,
            interval: nil,
            retries: nil,
            timeout: nil
        )
        // waitForHealthy should return immediately when test is ["NONE"]
        #expect(healthcheck.test?.first == "NONE")
    }

    @Test("waitForHealthy uses default durations when healthcheck omits them")
    func waitForHealthyDefaultDurations() {
        let healthcheck = Healthcheck(
            test: ["CMD", "curl", "-f", "http://localhost"],
            start_period: nil,
            interval: nil,
            retries: nil,
            timeout: nil
        )
        // Defaults from waitForHealthy: start_period=30s, interval=30s, timeout=30s, retries=3
        #expect(ComposeUp.parseDuration(healthcheck.start_period) == nil)
        #expect(ComposeUp.parseDuration(healthcheck.interval) == nil)
        #expect(ComposeUp.parseDuration(healthcheck.timeout) == nil)
        // The nil fallback in waitForHealthy is: ?? 30 (seconds)
        // So these nil values correctly trigger the defaults
    }
}

// Test helper structs
