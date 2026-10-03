import XCTest
@testable import DriveTracker

@MainActor
final class DownloadCoordinatorTests: XCTestCase {
    func testChunkedResponseUsesKnownDriveSize() {
        let progress = DownloadCoordinator.ProgressState.transfer(bytesWritten: 250, responseSize: -1, expectedSize: 1_000)
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertEqual(progress.totalBytes, 1_000)
        XCTAssertEqual(progress.bytesWritten, 250)
    }

    func testPercentageIsAvailableBeforeFirstByte() {
        let progress = DownloadCoordinator.ProgressState.transfer(bytesWritten: 0, responseSize: 0, expectedSize: 1_000)
        XCTAssertEqual(progress.totalBytes, 1_000)
        XCTAssertEqual(progress.fraction, 0)
    }

    func testResponseSizeOverridesStaleDriveMetadata() {
        let progress = DownloadCoordinator.ProgressState.transfer(bytesWritten: 500, responseSize: 2_000, expectedSize: 1_000)
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertEqual(progress.totalBytes, 2_000)
    }

    func testUnknownSizeKeepsActualByteCountWithoutInventingPercentage() {
        let progress = DownloadCoordinator.ProgressState.transfer(bytesWritten: 500, responseSize: -1, expectedSize: nil)
        XCTAssertEqual(progress.totalBytes, 0)
        XCTAssertEqual(progress.bytesWritten, 500)
        XCTAssertEqual(progress.fraction, 0)
    }

    func testProgressStaysWithinValidRange() {
        XCTAssertEqual(DownloadCoordinator.ProgressState.transfer(bytesWritten: 2_000, responseSize: -1, expectedSize: 1_000).fraction, 1)
        XCTAssertEqual(DownloadCoordinator.ProgressState.transfer(bytesWritten: -5, responseSize: 100, expectedSize: nil).fraction, 0)
    }

    func testTaskMetadataKeepsEachDownloadSizeSeparate() {
        let registry = TaskMetadataRegistry()
        registry.set(expectedFileName: "first.mp4", expectedSize: 1_000, for: 1)
        registry.set(expectedFileName: "second.mp4", expectedSize: 2_000, for: 2)
        XCTAssertEqual(registry.get(for: 1)?.size, 1_000)
        XCTAssertEqual(registry.get(for: 2)?.size, 2_000)
        registry.remove(for: 1)
        XCTAssertNil(registry.get(for: 1))
        XCTAssertEqual(registry.get(for: 2)?.fileName, "second.mp4")
    }

    func testDownloadAllOverlapsTwoTransfersAndRunsEveryFileOnce() async {
        var active = 0
        var peak = 0
        var completed: [Int] = []
        await DownloadBatch.run((0..<5).map { index in
            {
                active += 1
                peak = max(peak, active)
                try? await Task.sleep(for: .milliseconds(20))
                completed.append(index)
                active -= 1
            }
        })
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(completed.sorted(), Array(0..<5))
        XCTAssertEqual(active, 0)
    }

    func testCancellingBatchStopsQueuedFiles() async {
        var started = 0
        let task = Task {
            await DownloadBatch.run((0..<6).map { _ in
                {
                    started += 1
                    try? await Task.sleep(for: .seconds(10))
                }
            })
        }
        while started < 2 { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertEqual(started, 2)
    }
}
