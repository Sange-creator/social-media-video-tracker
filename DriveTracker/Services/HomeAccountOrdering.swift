import SwiftData
import SwiftUI

@MainActor
enum HomeAccountOrdering {
    static func move(accounts: [TikTokAccount], visibleIDs: [UUID], from offsets: IndexSet,
                     to destination: Int, context: ModelContext) throws {
        var visible = visibleIDs
        visible.move(fromOffsets: offsets, toOffset: destination)
        let membership = Set(visibleIDs)
        var iterator = visible.makeIterator()
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = accounts.map { account in
            guard membership.contains(account.id), let id = iterator.next(), let moved = byID[id] else { return account }
            return moved
        }
        let previous = accounts.map { ($0, $0.sortOrder) }
        for (index, account) in ordered.enumerated() where account.sortOrder != index {
            account.sortOrder = index
        }
        do { try context.save() }
        catch {
            for (account, order) in previous { account.sortOrder = order }
            throw error
        }
    }
}
