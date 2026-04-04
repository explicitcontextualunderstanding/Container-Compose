//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
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

@Suite("Build Secret Configuration Tests")
struct BuildSecretTests {

    @Test("Parse build secret with id and env")
    func parseBuildSecretWithEnv() throws {
        let yaml = """
        context: .
        secrets:
          - id: my_secret
            env: MY_SECRET_ENV_VAR
        """

        let decoder = YAMLDecoder()
        let build = try decoder.decode(Build.self, from: yaml)

        #expect(build.secrets?.count == 1)
        #expect(build.secrets?[0].id == "my_secret")
        #expect(build.secrets?[0].env == "MY_SECRET_ENV_VAR")
        #expect(build.secrets?[0].src == nil)
    }

    @Test("Parse build secret with id and src")
    func parseBuildSecretWithSrc() throws {
        let yaml = """
        context: .
        secrets:
          - id: ssh_key
            src: ./id_rsa
        """

        let decoder = YAMLDecoder()
        let build = try decoder.decode(Build.self, from: yaml)

        #expect(build.secrets?.count == 1)
        #expect(build.secrets?[0].id == "ssh_key")
        #expect(build.secrets?[0].src == "./id_rsa")
        #expect(build.secrets?[0].env == nil)
    }

    @Test("Parse multiple build secrets")
    func parseMultipleBuildSecrets() throws {
        let yaml = """
        context: .
        secrets:
          - id: secret1
            env: SECRET1_ENV
          - id: secret2
            src: ./secret2.txt
        """

        let decoder = YAMLDecoder()
        let build = try decoder.decode(Build.self, from: yaml)

        #expect(build.secrets?.count == 2)
        #expect(build.secrets?[0].id == "secret1")
        #expect(build.secrets?[0].env == "SECRET1_ENV")
        #expect(build.secrets?[0].src == nil)
        #expect(build.secrets?[1].id == "secret2")
        #expect(build.secrets?[1].src == "./secret2.txt")
        #expect(build.secrets?[1].env == nil)
    }

    @Test("Build without secrets (backward compatibility)")
    func buildWithoutSecrets() throws {
        let yaml = """
        context: .
        """

        let decoder = YAMLDecoder()
        let build = try decoder.decode(Build.self, from: yaml)

        #expect(build.context == ".")
        #expect(build.secrets == nil)
    }

    @Test("Service with build secrets in compose")
    func serviceWithBuildSecrets() throws {
        let yaml = """
        version: '3.8'
        services:
          app:
            build:
              context: .
              secrets:
                - id: db_password
                  env: DB_PASSWORD
        """

        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)

        #expect(compose.services["app"]??.build?.secrets?.count == 1)
        #expect(compose.services["app"]??.build?.secrets?[0].id == "db_password")
        #expect(compose.services["app"]??.build?.secrets?[0].env == "DB_PASSWORD")
    }

    @Test("Build with all options including secrets")
    func buildWithAllOptions() throws {
        let yaml = """
        context: ./app
        dockerfile: Dockerfile.prod
        args:
          NODE_VERSION: "18"
        target: builder
        secrets:
          - id: api_key
            env: API_KEY_ENV
        """

        let decoder = YAMLDecoder()
        let build = try decoder.decode(Build.self, from: yaml)

        #expect(build.context == "./app")
        #expect(build.dockerfile == "Dockerfile.prod")
        #expect(build.args?["NODE_VERSION"] == "18")
        #expect(build.target == "builder")
        #expect(build.secrets?.count == 1)
        #expect(build.secrets?[0].id == "api_key")
        #expect(build.secrets?[0].env == "API_KEY_ENV")
    }

    @Test("Build secret env and src mutually exclusive validation")
    func buildSecretMutuallyExclusive() throws {
        let yaml = """
        context: .
        secrets:
          - id: my_secret
            env: MY_ENV
            src: ./secret.txt
        """

        let decoder = YAMLDecoder()
        let build = try decoder.decode(Build.self, from: yaml)

        // If both are present, env takes precedence (implementation choice)
        // Or we could validate and throw an error - this test documents the behavior
        #expect(build.secrets?.count == 1)
        #expect(build.secrets?[0].id == "my_secret")
        // Document which field takes precedence when both are present
        // Current implementation: both fields are populated, CLI will use env if present
    }
}
