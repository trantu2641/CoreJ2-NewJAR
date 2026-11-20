import Foundation

/// Imports JAR files into the on-device JavaOne library using FileManager.
/// The selected document URL is read while its security-scoped access is active,
/// then copied as Data into the app's own Documents directory.
final class FileImportService: ImportService {

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importJAR(from sourceURL: URL) throws -> InstalledGame {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Read the picked file before the security-scoped permission ends.
        let jarData: Data
        do {
            jarData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw ImportServiceError.unableToReadSelectedFile(error.localizedDescription)
        }

        guard !jarData.isEmpty else {
            throw ImportServiceError.invalidJAR("The selected file is empty.")
        }
        guard Self.looksLikeZIPArchive(jarData) else {
            throw ImportServiceError.invalidJAR("The selected file is not a valid JAR/ZIP archive.")
        }

        let gameID = UUID()
        let gameDirectory = try makeGameDirectory(id: gameID)
        let destinationURL = gameDirectory.appendingPathComponent("game.jar", isDirectory: false)

        do {
            try jarData.write(to: destinationURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: gameDirectory)
            throw ImportServiceError.unableToStoreFile(error.localizedDescription)
        }

        return InstalledGame(
            id: gameID,
            title: sourceURL.deletingPathExtension().lastPathComponent,
            jarURL: destinationURL,
            importedAt: Date(),
            contentHash: ""
        )
    }

    private static func looksLikeZIPArchive(_ data: Data) -> Bool {
        // ZIP local file header, empty archive end record, or spanning signature.
        guard data.count >= 4 else { return false }
        let signature = Array(data.prefix(4))
        return signature == [0x50, 0x4B, 0x03, 0x04]
            || signature == [0x50, 0x4B, 0x05, 0x06]
            || signature == [0x50, 0x4B, 0x07, 0x08]
    }

    private func makeGameDirectory(id: UUID) throws -> URL {
        let libraryRoot = try libraryRootURL()
        let gameDirectory = libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: gameDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return gameDirectory
    }

    private func libraryRootURL() throws -> URL {
        guard let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw ImportServiceError.documentsDirectoryUnavailable
        }

        let libraryRoot = documentsURL
            .appendingPathComponent("JavaOne", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)

        try fileManager.createDirectory(
            at: libraryRoot,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return libraryRoot
    }
}
