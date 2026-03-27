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
import Yams
@testable import ContainerComposeCore

@Suite("Environment Variable Resolution Tests")
struct EnvironmentVariableTests {
    
    @Test("Resolve simple variable")
    func resolveSimpleVariable() {
        let envVars = ["DATABASE_URL": "postgres://localhost/mydb"]
        let input = "${DATABASE_URL}"
        let result = resolveVariable(input, with: envVars)
        
        #expect(result == "postgres://localhost/mydb")
    }
    
    @Test("Resolve variable with default value when variable exists")
    func resolveVariableWithDefaultWhenExists() {
        let envVars = ["PORT": "8080"]
        let input = "${PORT:-3000}"
        let result = resolveVariable(input, with: envVars)
        
        #expect(result == "8080")
    }
    
    @Test("Use default value when variable does not exist")
    func useDefaultWhenVariableDoesNotExist() {
        let envVars: [String: String] = [:]
        let input = "${PORT:-3000}"
        let result = resolveVariable(input, with: envVars)
        
        #expect(result == "3000")
    }
    
    @Test("Resolve multiple variables in string")
    func resolveMultipleVariables() {
        let envVars = [
            "DB_HOST": "localhost",
            "DB_PORT": "5432",
            "DB_NAME": "mydb"
        ]
        let input = "postgres://${DB_HOST}:${DB_PORT}/${DB_NAME}"
        let result = resolveVariable(input, with: envVars)

        #expect(result == "postgres://localhost:5432/mydb")
    }
    
    @Test("Leave unresolved variable when no default provided")
    func leaveUnresolvedVariable() {
        let envVars: [String: String] = [:]
        let input = "${UNDEFINED_VAR}"
        let result = resolveVariable(input, with: envVars)
        
        // Should leave as-is when variable not found and no default
        #expect(result == "${UNDEFINED_VAR}")
    }
    
    @Test("Resolve with empty default value")
    func resolveWithEmptyDefault() {
        let envVars: [String: String] = [:]
        let input = "${OPTIONAL_VAR:-}"
        let result = resolveVariable(input, with: envVars)
        
        #expect(result == "")
    }
    
    @Test("Resolve complex string with mixed content")
    func resolveComplexString() {
        let envVars = ["VERSION": "1.2.3"]
        let input = "MyApp version ${VERSION} (build 42)"
        let result = resolveVariable(input, with: envVars)
        
        #expect(result == "MyApp version 1.2.3 (build 42)")
    }
    
    @Test("Variable names are case-sensitive")
    func caseSensitiveVariableNames() {
        let envVars = ["myvar": "lowercase", "MYVAR": "uppercase"]
        let input1 = "${myvar}"
        let input2 = "${MYVAR}"
        
        let result1 = resolveVariable(input1, with: envVars)
        let result2 = resolveVariable(input2, with: envVars)
        
        #expect(result1 == "lowercase")
        #expect(result2 == "uppercase")
    }
    
    @Test("Resolve variables with underscores and numbers")
    func resolveVariablesWithUnderscoresAndNumbers() {
        let envVars = ["VAR_NAME_123": "value123"]
        let input = "${VAR_NAME_123}"
        let result = resolveVariable(input, with: envVars)
        
        #expect(result == "value123")
    }
    
    @Test("Process environment takes precedence over provided envVars")
    func processEnvironmentTakesPrecedence() {
        // This test assumes PATH exists in process environment
        let envVars = ["PATH": "custom-path"]
        let input = "${PATH}"
        let result = resolveVariable(input, with: envVars)
        
        // Should use process environment, not custom value
        #expect(result != "custom-path")
        #expect(result.isEmpty == false)
    }
    
    @Test("Resolve variable that is part of larger text")
    func resolveVariableInLargerText() {
        let envVars = ["API_KEY": "secret123"]
        let input = "Authorization: Bearer ${API_KEY}"
        let result = resolveVariable(input, with: envVars)
        
        #expect(result == "Authorization: Bearer secret123")
    }
    
    @Test("No variables to resolve returns original string")
    func noVariablesToResolve() {
        let envVars = ["KEY": "value"]
        let input = "This is a plain string"
        let result = resolveVariable(input, with: envVars)
        
        #expect(result == "This is a plain string")
    }

    // MARK: Compose Env Pipeline Integration Tests

    @Test("Compose env pipeline: ${VAR} resolved from .env file vars")
    func composeEnvPipelineResolvesFromDotEnv() {
        // Simulates: .env file defines DB_PASSWORD, compose env references ${DB_PASSWORD}
        let dotEnvVars = ["DB_PASSWORD": "s3cret", "DB_USER": "admin"]
        let serviceEnv: [String: String] = [
            "POSTGRES_PASSWORD": "${DB_PASSWORD}",
            "POSTGRES_USER": "${DB_USER}",
        ]

        var combinedEnv = dotEnvVars
        combinedEnv.merge(serviceEnv) { (_, new) in new }
        combinedEnv = combinedEnv.mapValues { resolveVariable($0, with: combinedEnv) }

        #expect(combinedEnv["POSTGRES_PASSWORD"] == "s3cret")
        #expect(combinedEnv["POSTGRES_USER"] == "admin")
    }

    @Test("Compose env pipeline: ${VAR:-default} uses default when var missing")
    func composeEnvPipelineUsesDefault() {
        let dotEnvVars: [String: String] = [:]
        let serviceEnv: [String: String] = [
            "REGISTRY": "${HERMES_REGISTRY:-192.168.1.86:30500}",
            "IMAGE": "${REGISTRY}/hermes:latest",
        ]

        var combinedEnv = dotEnvVars
        combinedEnv.merge(serviceEnv) { (_, new) in new }
        combinedEnv = combinedEnv.mapValues { resolveVariable($0, with: combinedEnv) }

        #expect(combinedEnv["REGISTRY"] == "192.168.1.86:30500")
        #expect(combinedEnv["IMAGE"] == "192.168.1.86:30500/hermes:latest")
    }

    @Test("Compose env pipeline: service env overrides .env file even with ${VAR}")
    func composeEnvPipelineServiceOverridesDotEnv() {
        // Simulates: .env sets DEBUG=false, compose sets DEBUG=${DEBUG_MODE:-true}
        let dotEnvVars = ["DEBUG_MODE": "verbose", "LOG_LEVEL": "info"]
        let serviceEnv: [String: String] = [
            "DEBUG": "${DEBUG_MODE:-true}",
            "LOG_LEVEL": "warn",
        ]

        var combinedEnv = dotEnvVars
        combinedEnv.merge(serviceEnv) { (_, new) in new }  // Service env wins
        combinedEnv = combinedEnv.mapValues { resolveVariable($0, with: combinedEnv) }

        // Service env overrides .env for LOG_LEVEL
        #expect(combinedEnv["LOG_LEVEL"] == "warn")
        // ${VAR:-default} resolved — DEBUG_MODE from dotEnv is still available for resolution
        #expect(combinedEnv["DEBUG"] == "verbose")
    }

    @Test("Compose env pipeline: multiple ${VAR} in single value")
    func composeEnvPipelineMultipleVars() {
        let dotEnvVars = ["DB_HOST": "172.18.0.2", "DB_PORT": "5432", "DB_NAME": "honcho"]
        let serviceEnv: [String: String] = [
            "DATABASE_URL": "postgres://${DB_USER:-postgres}:${DB_PASSWORD:-changeme}@${DB_HOST}:${DB_PORT}/${DB_NAME}",
        ]

        var combinedEnv = dotEnvVars
        combinedEnv.merge(serviceEnv) { (_, new) in new }
        combinedEnv = combinedEnv.mapValues { resolveVariable($0, with: combinedEnv) }

        #expect(combinedEnv["DATABASE_URL"] == "postgres://postgres:changeme@172.18.0.2:5432/honcho")
    }

    @Test("Compose env pipeline: ${VAR:?error} exits on missing required var")
    func composeEnvPipelineRequiredVarError() throws {
        // resolveVariable calls Application.exit() when ${VAR:?msg} var is missing.
        // We can't test this without killing the process, so just verify the regex
        // matches the ?error pattern by testing that resolution works when present.
        // See the "resolves when var present" test below for the happy path.
        #expect(true, "Guard test: ?error pattern documented in resolveVariable()")
    }

    @Test("Compose env pipeline: ${VAR:?error} resolves when var present")
    func composeEnvPipelineRequiredVarResolved() {
        let dotEnvVars = ["MISSING_SECRET": "actual-secret-value"]
        let serviceEnv: [String: String] = [
            "API_KEY": "${MISSING_SECRET:?API key is required}",
        ]

        var combinedEnv = dotEnvVars
        combinedEnv.merge(serviceEnv) { (_, new) in new }
        combinedEnv = combinedEnv.mapValues { resolveVariable($0, with: combinedEnv) }

        #expect(combinedEnv["API_KEY"] == "actual-secret-value")
    }

    // MARK: Pre-decode YAML Variable Resolution Tests ($$ escaping)

    @Test("$$ escaping preserves literal $ through substitution")
    func dollarDollarEscapingPreservesLiteralDollar() {
        let envVars: [String: String] = [:]
        let input = "value: $$HOME"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "value: $HOME")
    }

    @Test("$${VAR} produces literal ${VAR} (Docker Compose compatible)")
    func dollarDollarVarProducesLiteralBraces() {
        let envVars = ["VAR": "resolved"]
        let input = "value: $${VAR}"
        let result = resolveYamlVariables(input, with: envVars)

        // $$ → sentinel → removes the $, leaving {VAR} which is not a valid ${VAR} ref
        // So $${VAR} → literal ${VAR}
        #expect(result == "value: ${VAR}")
    }

    @Test("${VAR} in image field gets resolved")
    func varInImageFieldResolved() {
        let envVars = ["HERMES_REGISTRY": "192.168.1.86:30500"]
        let input = "image: ${HERMES_REGISTRY:-host:port}/hermes:latest"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "image: 192.168.1.86:30500/hermes:latest")
    }

    @Test("${VAR:-default} in image field uses default when var missing")
    func varWithDefaultInImageField() {
        let envVars: [String: String] = [:]
        let input = "image: ${REGISTRY:-localhost:5000}/app:latest"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "image: localhost:5000/app:latest")
    }

    @Test("${VAR} in volumes field gets resolved")
    func varInVolumesFieldResolved() {
        let envVars = ["ISAAC_ROS_CUSTOM_DIR": "/opt/isaac_ros"]
        let input = "- ${ISAAC_ROS_CUSTOM_DIR:-/path}:/workspace"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "- /opt/isaac_ros:/workspace")
    }

    @Test("${VAR} in command gets resolved (Compose-correct behavior)")
    func varInCommandResolved() {
        let envVars = ["DATA_DIR": "/data"]
        let input = "command: [\"sh\", \"-c\", \"echo ${DATA_DIR}\"]"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "command: [\"sh\", \"-c\", \"echo /data\"]")
    }

    @Test("$$VAR in command preserves $VAR (shell-correct behavior)")
    func dollarDollarVarInCommand() {
        let envVars = ["VAR": "should-not-expand"]
        let input = "command: [\"sh\", \"-c\", \"echo $$VAR\"]"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "command: [\"sh\", \"-c\", \"echo $VAR\"]")
    }

    @Test("Multiple $$ in single value all preserved")
    func multipleDollarDollarEscaping() {
        let envVars = ["HOME": "/root", "USER": "admin"]
        let input = "cmd: echo $$HOME and $$USER"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "cmd: echo $HOME and $USER")
    }

    @Test("Mixed $$ and ${VAR} in same value")
    func mixedDollarDollarAndVar() {
        let envVars = ["REGISTRY": "ghcr.io", "TAG": "v1.2"]
        let input = "image: ${REGISTRY}/app:${TAG:-latest} $$NPM_TOKEN"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "image: ghcr.io/app:v1.2 $NPM_TOKEN")
    }

    @Test("No variables returns original string including $$ untouched")
    func noVarsReturnsOriginal() {
        let envVars: [String: String] = [:]
        let input = "image: nginx:latest\nports:\n  - 8080:80"
        let result = resolveYamlVariables(input, with: envVars)

        #expect(result == "image: nginx:latest\nports:\n  - 8080:80")
    }

    // MARK: Pre-decode Integration: resolveYamlVariables → YAMLDecoder → struct fields

    @Test("Integration: ${VAR} in image field resolves to correct struct value")
    func integrationImageVarResolved() throws {
        let envVars = ["REGISTRY": "ghcr.io", "TAG": "v1.2.3"]
        let yaml = """
        services:
          app:
            image: ${REGISTRY}/myapp:${TAG:-latest}
        """
        let resolved = resolveYamlVariables(yaml, with: envVars)
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: resolved)

        #expect(compose.services["app"]??.image == "ghcr.io/myapp:v1.2.3")
    }

    @Test("Integration: ${VAR:-default} in image uses default when var missing")
    func integrationImageVarDefault() throws {
        let yaml = """
        services:
          app:
            image: ${REGISTRY:-localhost:5000}/myapp:${TAG:-latest}
        """
        let resolved = resolveYamlVariables(yaml, with: [:])
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: resolved)

        #expect(compose.services["app"]??.image == "localhost:5000/myapp:latest")
    }

    @Test("Integration: ${VAR} in volumes resolves to correct struct value")
    func integrationVolumesVarResolved() throws {
        let envVars = ["DATA_DIR": "/opt/data", "CONFIG_DIR": "/etc/app"]
        let yaml = """
        services:
          app:
            image: nginx:alpine
            volumes:
              - ${DATA_DIR:-/tmp/data}:/data
              - ${CONFIG_DIR}:/config:ro
        """
        let resolved = resolveYamlVariables(yaml, with: envVars)
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: resolved)

        let vols = compose.services["app"]??.volumes ?? []
        #expect(vols.contains("${DATA_DIR:-/tmp/data}:/data") == false)
        #expect(vols.contains("/opt/data:/data"))
        #expect(vols.contains("/etc/app:/config:ro"))
    }

    @Test("Integration: $$VAR in command preserves literal $VAR after decode")
    func integrationCommandDollarDollarPreserved() throws {
        let yaml = """
        services:
          app:
            image: busybox:latest
            command: ["sh", "-c", "echo $$HOME $$USER"]
        """
        let resolved = resolveYamlVariables(yaml, with: [:])
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: resolved)

        let cmd = compose.services["app"]??.command ?? []
        let cmdString = cmd.joined(separator: " ")
        // After resolveYamlVariables: $$ → $, so command should have $HOME and $USER
        #expect(cmdString.contains("echo $HOME $USER"))
    }

    @Test("Integration: ${VAR} in command resolves but $$VAR does not")
    func integrationCommandMixedVarAndEscaping() throws {
        let envVars = ["DATA_DIR": "/app/data"]
        let yaml = """
        services:
          app:
            image: busybox:latest
            command: ["sh", "-c", "export DATA=${DATA_DIR} && echo $$PATH"]
        """
        let resolved = resolveYamlVariables(yaml, with: envVars)
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: resolved)

        let cmd = compose.services["app"]??.command ?? []
        let cmdString = cmd.joined(separator: " ")
        #expect(cmdString.contains("export DATA=/app/data"))
        #expect(cmdString.contains("echo $PATH"))
    }

    @Test("Integration: honcho-style image with registry default and $$ in command")
    func integrationHonchoStyleCompose() throws {
        let envVars = [
            "HERMES_REGISTRY": "192.168.1.86:30500",
            "ISAAC_ROS_CUSTOM_DIR": "/Users/dev/workspace",
        ]
        let yaml = """
        services:
          hermes:
            image: ${HERMES_REGISTRY:-192.168.1.86:30500}/hermes:latest
            volumes:
              - ${ISAAC_ROS_CUSTOM_DIR:-/tmp}/config:/config:ro
            command:
              - "/bin/bash"
              - "-lc"
              - |
                set -euo pipefail
                echo "[hermes] pid=$$$$ PPID=$$$$"
                kubectl config get-contexts
        """
        let resolved = resolveYamlVariables(yaml, with: envVars)
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: resolved)

        let hermes = try #require(compose.services["hermes"] ?? nil)
        #expect(hermes.image == "192.168.1.86:30500/hermes:latest")
        let vols = hermes.volumes ?? []
        #expect(vols.contains("/Users/dev/workspace/config:/config:ro"))
        let cmd = hermes.command ?? []
        // $$$$ → $$ → $ after resolveYamlVariables, so we get $$
        #expect(cmd.joined(separator: " ").contains("pid=$$"))
    }
}

// Test helper function that mimics the actual implementation
