import Foundation
import Testing
@testable import NeolessCloud

/// 录音备份: the last recordings kept on disk, the oldest dropped, owner-only.
@Suite struct RecordingBackupTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("neoless-backup-\(UUID().uuidString)")
    }

    private func audio(_ byte: UInt8, _ type: HubAudioType = .m4a) -> EncodedAudio {
        EncodedAudio(data: Data([byte, byte, byte]), type: type, durationSeconds: 1)
    }

    @Test func keepsTheNewestAndDropsTheRest() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = RecordingBackup(directory: dir, keep: 3)
        var ids: [UUID] = []
        for n in 0..<5 {
            let id = UUID()
            ids.append(id)
            #expect(backup.save(audio(UInt8(n)), id: id))
            // Modification dates a second apart, as recordings are.
            let file = try #require(backup.file(for: id))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + n))],
                                                  ofItemAtPath: file.path)
        }
        // The fifth save pruned with the fourth's date still "now": save once more to prune by the dates set.
        let last = UUID()
        ids.append(last)
        #expect(backup.save(audio(9), id: last))
        #expect(Set(backup.ids) == Set([last, ids[4], ids[3]]))
        #expect(backup.file(for: ids[0]) == nil)
        #expect(backup.load(ids[4])?.data == Data([4, 4, 4]))
        #expect(backup.load(ids[4])?.type == .m4a)
    }

    @Test func ownerOnly() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = RecordingBackup(directory: dir)
        let id = UUID()
        backup.save(audio(1, .wav), id: id)
        let file = try #require(backup.file(for: id))
        #expect(file.pathExtension == "wav")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test func savedAgainReplacesAndRemoveForgets() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backup = RecordingBackup(directory: dir)
        let id = UUID()
        backup.save(audio(1, .wav), id: id)
        backup.save(audio(2, .m4a), id: id)
        #expect(backup.ids == [id])
        #expect(backup.load(id)?.type == .m4a)
        backup.remove(id)
        #expect(backup.file(for: id) == nil)
        backup.save(audio(3), id: UUID())
        backup.removeAll()
        #expect(backup.ids.isEmpty)
    }

    @Test func overflowIsWhatIsPastTheNewest() {
        let base = URL(fileURLWithPath: "/x")
        let entries = (0..<4).map { RecordingBackup.Entry(url: base.appendingPathComponent("\($0)"), date: Date(timeIntervalSince1970: Double($0))) }
        #expect(RecordingBackup.overflow(entries, keep: 2).map(\.url.lastPathComponent) == ["1", "0"])
        #expect(RecordingBackup.overflow(entries, keep: 10).isEmpty)
    }
}
