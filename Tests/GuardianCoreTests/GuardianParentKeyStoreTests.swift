import Foundation
import GuardianCore
import Testing

private final class MemorySecretStorage: GuardianSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    init(value: Data? = nil) {
        self.value = value
    }

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { value }
    }

    func insert(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            guard value == nil else { throw GuardianParentKeyError.duplicateItem }
            value = data
        }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { value = nil }
    }
}

@Test func parentKeyIsCreatedOnceAndSharedAcrossConcurrentCallers() async throws {
    let storage = MemorySecretStorage()
    let expected = Data(repeating: 0x7A, count: 32)
    let manager = GuardianParentKeyManager(
        storage: storage,
        generator: { expected }
    )

    let values = try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<20 {
            group.addTask { try await manager.loadOrCreate() }
        }
        var values: [Data] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(Set(values).count == 1)
    #expect(values.first == expected)
    #expect(try storage.read(service: manager.service, account: manager.account) == expected)
}

@Test func parentKeyRejectsMalformedStoredOrGeneratedMaterial() async throws {
    let malformedStorage = MemorySecretStorage(value: Data(repeating: 0x01, count: 31))
    let malformedStored = GuardianParentKeyManager(storage: malformedStorage)
    await #expect(throws: GuardianParentKeyError.invalidKeyMaterial) {
        try await malformedStored.loadOrCreate()
    }

    let malformedGenerated = GuardianParentKeyManager(
        storage: MemorySecretStorage(),
        generator: { Data(repeating: 0x02, count: 33) }
    )
    await #expect(throws: GuardianParentKeyError.invalidKeyMaterial) {
        try await malformedGenerated.loadOrCreate()
    }
}
