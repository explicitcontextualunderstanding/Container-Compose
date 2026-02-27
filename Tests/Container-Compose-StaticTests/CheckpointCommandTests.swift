import XCTest
@testable import ContainerComposeCore

final class CheckpointCommandTests: XCTestCase {
    func testMakeCommitArgsIncludesContainerAndImage() throws {
        let container = "proj-web"
        let image = "proj-web:checkpoint-12345"

        // TDD: helper to be implemented that builds container commit/export args
        let args = CheckpointCommand.makeCommitArgs(containerName: container, imageName: image)

        // Accept either 'commit' or 'export' as the upstream CLI made use of one of these verbs
        XCTAssertTrue(args.contains("commit") || args.contains("export"), "Expected commit or export verb in args: \(args)")
        XCTAssertTrue(args.contains(container), "Expected container name present in args: \(args)")
        XCTAssertTrue(args.contains(image), "Expected image name present in args: \(args)")
    }

    func testMakeCommitArgsAcceptsCustomTag() throws {
        let container = "proj-api"
        let customImage = "myregistry.local/proj-api:ckpt-1"

        let args = CheckpointCommand.makeCommitArgs(containerName: container, imageName: customImage)

        XCTAssertTrue(args.contains(container))
        XCTAssertTrue(args.contains(customImage))
    }
}
