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
import Foundation

/// Skips the test if legacy validation is disabled.
/// Used for redundant tests that are now covered by Pkl schemas.
/// Set LEGACY_VALIDATION=1 to force-run these tests.
public func skipIfLegacyValidationDisabled() throws {
    try XCTSkipIf(
        ProcessInfo.processInfo.environment["LEGACY_VALIDATION"] != "1",
        "Legacy test gated behind LEGACY_VALIDATION=1"
    )
}
