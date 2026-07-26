import Foundation
import SwiftData

struct AssignmentSummary: Equatable {
    let added: Int
    let outstanding: Int
    let shortage: Int
}

@MainActor
struct AssignmentEngine {
    @discardableResult
    func ensureAssignments(
        for account: TikTokAccount,
        on date: Date = .now,
        context: ModelContext,
        shuffledBy shuffle: ([VideoAsset]) -> [VideoAsset] = { $0.shuffled() }
    ) throws -> AssignmentSummary {
        guard account.isConfigured, !account.isPaused, !account.isMissingFromDrive else {
            return AssignmentSummary(added: 0, outstanding: account.outstandingCount, shortage: 0)
        }

        let dayKey = DayKey.value(for: date)
        var outstanding = account.videos.filter {
            $0.status == .assigned || $0.status == .downloaded
        }
        let completedToday = account.videos.filter {
            guard let uploadedAt = $0.uploadedAt else { return false }
            return DayKey.value(for: uploadedAt) == dayKey
        }.count
        let targetOutstanding = max(0, account.dailyQuota - completedToday)

        // If the daily target is lowered, return untouched suggestions to the
        // available pool. Downloaded work is never discarded automatically.
        if outstanding.count > targetOutstanding {
            var excess = outstanding.count - targetOutstanding
            let removableAssignments = account.assignments
                .filter { $0.isActive && $0.video?.status == .assigned }
                .sorted { $0.assignedAt > $1.assignedAt }
            for assignment in removableAssignments where excess > 0 {
                assignment.isActive = false
                assignment.updatedAt = date
                if let video = assignment.video {
                    record(
                        .reset,
                        for: video,
                        detail: "Returned to available after daily target changed",
                        context: context
                    )
                }
                excess -= 1
            }
            outstanding = account.videos.filter {
                $0.status == .assigned || $0.status == .downloaded
            }
        }
        let needed = max(0, account.dailyQuota - outstanding.count - completedToday)
        let candidates = account.videos.filter {
            $0.status == .available && !$0.isMissingFromDrive && $0.canDownload
        }
        let selected = Array(shuffle(candidates).prefix(needed))
        let usedSlots = Set(
            account.assignments
                .filter { $0.localDayKey == dayKey }
                .map(\.slot)
        )
        var nextSlot = 1

        for video in selected {
            while usedSlots.contains(nextSlot) {
                nextSlot += 1
            }
            let assignment = DailyAssignment(
                localDayKey: dayKey,
                slot: nextSlot,
                account: account,
                video: video
            )
            context.insert(assignment)
            record(.assigned, for: video, detail: "Suggested for \(dayKey)", context: context)
            nextSlot += 1
        }

        account.updatedAt = .now
        try context.save()
        return AssignmentSummary(
            added: selected.count,
            outstanding: outstanding.count + selected.count,
            shortage: max(0, needed - selected.count)
        )
    }

    @discardableResult
    func selectManually(
        _ video: VideoAsset,
        on date: Date = .now,
        replaceExistingSuggestion: Bool = true,
        context: ModelContext
    ) throws -> DailyAssignment? {
        guard
            video.status == .available,
            !video.isMissingFromDrive,
            video.canDownload,
            let account = video.account,
            account.isConfigured,
            !account.isPaused
        else {
            return nil
        }

        let dayKey = DayKey.value(for: date)
        let replaceable = account.assignments
            .filter { $0.isActive && $0.video?.status == .assigned }
            .sorted { $0.assignedAt < $1.assignedAt }
            .first
        let slot: Int

        if replaceExistingSuggestion,
           let replaceable,
           account.outstandingCount >= account.dailyQuota {
            replaceable.isActive = false
            replaceable.updatedAt = date
            if let oldVideo = replaceable.video {
                record(
                    .replaced,
                    for: oldVideo,
                    detail: "Replaced by a manual folder selection",
                    context: context
                )
            }
            slot = replaceable.slot
        } else {
            let usedSlots = Set(
                account.assignments
                    .filter { $0.localDayKey == dayKey }
                    .map(\.slot)
            )
            slot = (1 ... 1000).first { !usedSlots.contains($0) } ?? usedSlots.count + 1
        }

        let assignment = DailyAssignment(
            localDayKey: dayKey,
            slot: slot,
            assignedAt: date,
            account: account,
            video: video
        )
        context.insert(assignment)
        record(
            .manuallySelected,
            for: video,
            detail: replaceExistingSuggestion
                ? "Selected manually from the Drive folder"
                : "Chosen for immediate download without replacing suggestions",
            context: context
        )
        account.updatedAt = date
        try context.save()
        return assignment
    }

    func replace(_ assignment: DailyAssignment, context: ModelContext) throws -> Bool {
        guard
            assignment.isActive,
            let oldVideo = assignment.video,
            oldVideo.status == .assigned,
            let account = assignment.account
        else {
            return false
        }

        let replacements = account.videos.filter {
            $0 !== oldVideo &&
            $0.status == .available &&
            !$0.isMissingFromDrive &&
            $0.canDownload
        }
        guard let replacement = replacements.randomElement() else { return false }

        assignment.isActive = false
        assignment.updatedAt = .now
        record(.replaced, for: oldVideo, detail: "Returned to available pool", context: context)

        let newAssignment = DailyAssignment(
            localDayKey: assignment.localDayKey,
            slot: assignment.slot,
            account: account,
            video: replacement
        )
        context.insert(newAssignment)
        record(.assigned, for: replacement, detail: "Replacement suggestion", context: context)
        try context.save()
        return true
    }

    func markDownloadStarted(_ video: VideoAsset, context: ModelContext) throws {
        guard video.status == .assigned else { return }
        record(.downloadStarted, for: video, context: context)
        video.updatedAt = .now
        try context.save()
    }

    func markDownloaded(
        _ video: VideoAsset,
        photoIdentifier: String?,
        at date: Date = .now,
        context: ModelContext
    ) throws {
        guard video.status == .assigned || video.status == .downloaded else { return }
        video.downloadedAt = video.downloadedAt ?? date
        video.photoLocalIdentifier = photoIdentifier
        video.isMissingFromPhotos = false
        video.updatedAt = date
        record(.downloadSucceeded, for: video, detail: "Saved to Photos", context: context)
        try context.save()
    }

    /// A verified download is the completion event in this tracker. Keeping
    /// both state changes together prevents a saved video being left in the
    /// intermediate "Downloaded" state after a successful Photos save.
    func completeVerifiedDownload(
        _ video: VideoAsset,
        photoIdentifier: String?,
        at date: Date = .now,
        context: ModelContext
    ) throws {
        guard video.status == .assigned || video.status == .downloaded else { return }
        video.downloadedAt = video.downloadedAt ?? date
        video.uploadedAt = date
        video.photoLocalIdentifier = photoIdentifier
        video.isMissingFromPhotos = false
        video.updatedAt = date
        video.assignments.filter(\.isActive).forEach {
            $0.isActive = false
            $0.completedAt = date
            $0.updatedAt = date
        }
        record(.downloadSucceeded, for: video, detail: "Saved to Photos", context: context)
        record(
            .uploadConfirmed,
            for: video,
            detail: "Completed automatically after a successful download and Photos save",
            context: context
        )
        try context.save()
    }

    @discardableResult
    func shuffleSuggestions(for account: TikTokAccount, context: ModelContext) throws -> Int {
        let suggestions = account.assignments
            .filter { $0.isActive && $0.video?.status == .assigned }
            .sorted { $0.slot < $1.slot }
        guard !suggestions.isEmpty else { return 0 }

        var candidates = account.videos.filter {
            // Shuffle is deliberately stricter than the normal available pool:
            // once a video has been shown as a suggestion, do not surface it
            // again through Shuffle. Only genuinely unseen videos qualify.
            $0.status == .available &&
            $0.assignments.isEmpty &&
            !$0.isMissingFromDrive &&
            $0.canDownload
        }.shuffled()
        guard !candidates.isEmpty else { return 0 }

        var changed = 0
        for assignment in suggestions where !candidates.isEmpty {
            guard let oldVideo = assignment.video else { continue }
            let replacement = candidates.removeFirst()
            assignment.isActive = false
            assignment.updatedAt = .now
            record(.replaced, for: oldVideo, detail: "Shuffled for a new suggestion", context: context)
            let newAssignment = DailyAssignment(
                localDayKey: assignment.localDayKey,
                slot: assignment.slot,
                account: account,
                video: replacement
            )
            context.insert(newAssignment)
            record(.assigned, for: replacement, detail: "Shuffled suggestion", context: context)
            changed += 1
        }
        if changed > 0 {
            account.updatedAt = .now
            try context.save()
        }
        return changed
    }

    func markDownloadFailed(_ video: VideoAsset, error: Error, context: ModelContext) throws {
        record(.downloadFailed, for: video, detail: error.localizedDescription, context: context)
        try context.save()
    }

    func markUploaded(
        _ video: VideoAsset,
        at date: Date = .now,
        detail: String = "Manually confirmed",
        context: ModelContext
    ) throws {
        guard video.downloadedAt != nil, video.uploadedAt == nil else { return }
        video.uploadedAt = date
        video.updatedAt = date
        video.assignments.filter(\.isActive).forEach {
            $0.isActive = false
            $0.completedAt = date
            $0.updatedAt = date
        }
        record(.uploadConfirmed, for: video, detail: detail, context: context)
        try context.save()
    }

    func markCompletedOutsideApp(
        _ video: VideoAsset,
        at date: Date = .now,
        context: ModelContext
    ) throws {
        guard video.uploadedAt == nil else { return }
        video.downloadedAt = video.downloadedAt ?? date
        video.uploadedAt = date
        video.photoLocalIdentifier = nil
        video.isMissingFromPhotos = false
        video.updatedAt = date
        video.assignments.filter(\.isActive).forEach {
            $0.isActive = false
            $0.completedAt = date
            $0.updatedAt = date
        }
        record(
            .uploadConfirmed,
            for: video,
            detail: "Marked completed manually after downloading outside the app",
            context: context
        )
        try context.save()
    }

    func undoUpload(_ video: VideoAsset, context: ModelContext) throws {
        guard video.uploadedAt != nil else { return }
        video.uploadedAt = nil
        video.updatedAt = .now
        if let latest = video.assignments.sorted(by: { $0.assignedAt > $1.assignedAt }).first {
            latest.isActive = true
            latest.completedAt = nil
            latest.updatedAt = .now
        }
        record(.uploadUndone, for: video, detail: "Returned to downloaded", context: context)
        try context.save()
    }

    func resetDownload(_ video: VideoAsset, context: ModelContext) throws {
        guard video.uploadedAt == nil, video.downloadedAt != nil else { return }
        video.downloadedAt = nil
        video.photoLocalIdentifier = nil
        video.isMissingFromPhotos = false
        video.updatedAt = .now
        record(.reset, for: video, detail: "Download status reset", context: context)
        try context.save()
    }

    private func record(
        _ kind: StatusEventKind,
        for video: VideoAsset,
        detail: String? = nil,
        context: ModelContext
    ) {
        let event = StatusEvent(
            kind: kind,
            detail: detail,
            accountName: video.account?.displayName ?? "Unknown account",
            driveFileID: video.driveFileID,
            videoName: video.name,
            video: video
        )
        context.insert(event)
    }
}
