import Foundation

/// Persists installed games as JSON in Application Support.
///
/// The original implementation used SwiftData, which requires iOS 17.
/// The repository API remains unchanged so the rest of the library pipeline
/// does not need to change.
@MainActor
final class SwiftDataGameLibraryRepository: GameLibraryRepository {

    private let fileURL: URL
    private var records: [InstalledGameEntity] = []
    private var loaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]

            let directory = applicationSupport.appendingPathComponent(
                "JavaOne",
                isDirectory: true
            )

            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            self.fileURL = directory.appendingPathComponent(
                "GameLibrary.json"
            )
        }
    }

    func fetchGames() -> [InstalledGame] {
        loadIfNeeded()

        return records
            .sorted { $0.importedAt > $1.importedAt }
            .map { $0.toDomain() }
    }

    func save(_ game: InstalledGame) {
        loadIfNeeded()

        let record = InstalledGameEntity.fromDomain(game)

        if let index = records.firstIndex(where: { $0.id == game.id }) {
            records[index] = record
        } else {
            records.append(record)
        }

        persist()
    }

    func game(withContentHash contentHash: String) -> InstalledGame? {
        loadIfNeeded()

        return records.first {
            $0.contentHash == contentHash
        }?.toDomain()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode(
                [InstalledGameEntity].self,
                from: data
            )
        } catch {
            records = []
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(records)

            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence errors are intentionally not surfaced by the
            // existing GameLibraryRepository protocol.
        }
    }
}
