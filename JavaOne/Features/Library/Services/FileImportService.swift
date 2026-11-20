import Foundation

final class FileImportService: ImportService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importJAR(from sourceURL: URL) throws -> InstalledGame {
        guard sourceURL.pathExtension.lowercased() == "jar" else {
            throw ImportServiceError.notAJARFile
        }

        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Files/iCloud providers can return security-scoped URLs that are
        // not safe to pass directly to copyItem(). Read the selected file
        // while the security scope is active, then write the bytes into
        // JavaOne's private Documents/JavaOne/Library directory.
        let jarData: Data
        do {
            jarData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw ImportServiceError.unableToReadJAR(error.localizedDescription)
        }

        guard !jarData.isEmpty else {
            throw ImportServiceError.emptyJARFile
        }

        let gameID = UUID()
        let gameDirectory = try makeGameDirectory(id: gameID)
        let destinationURL = gameDirectory.appendingPathComponent(
            "game.jar",
            isDirectory: false
        )

        do {
            try jarData.write(to: destinationURL, options: [.atomic])
        } catch {
            throw ImportServiceError.unableToSaveJAR(error.localizedDescription)
        }

        return InstalledGame(
            id: gameID,
            title: sourceURL.deletingPathExtension().lastPathComponent,
            jarURL: destinationURL,
            importedAt: Date(),
            contentHash: ""
        )
    }

    private func makeGameDirectory(id: UUID) throws -> URL {
        let libraryRoot = try libraryRootURL()
        let gameDirectory = libraryRoot.appendingPathComponent(
            id.uuidString,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: gameDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ImportServiceError.unableToCreateLibraryDirectory(
                error.localizedDescription
            )
        }

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

        do {
            try fileManager.createDirectory(
                at: libraryRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw ImportServiceError.unableToCreateLibraryDirectory(
                error.localizedDescription
            )
        }

        return libraryRoot
    }
}
