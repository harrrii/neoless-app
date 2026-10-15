import Foundation
import NeolessCore

extension DataFileStore {
    /// ~/Library/Application Support/`folder`, owner-only (0700; `DataFileStore` writes its files 0600):
    /// "neoless" for the Mac app, `Hub.dataFolderName` for the hub.
    public static func applicationSupport(_ folder: String) -> DataFileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // createDirectory leaves an existing directory's permissions alone.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return DataFileStore(directory: dir)
    }
}
