import Foundation

/// File-persistence record for an installed Java ME game.
/// Kept separate from the domain model to preserve the existing structure.
struct InstalledGameEntity: Codable {
    let id: UUID
    var title: String
    var jarPath: String
    var importedAt: Date
    var contentHash: String

    init(
        id: UUID,
        title: String,
        jarPath: String,
        importedAt: Date,
        contentHash: String
    ) {
        self.id = id
        self.title = title
        self.jarPath = jarPath
        self.importedAt = importedAt
        self.contentHash = contentHash
    }

    func toDomain() -> InstalledGame {
        InstalledGame(
            id: id,
            title: title,
            jarURL: URL(fileURLWithPath: jarPath),
            importedAt: importedAt,
            contentHash: contentHash
        )
    }

    static func fromDomain(_ game: InstalledGame) -> InstalledGameEntity {
        InstalledGameEntity(
            id: game.id,
            title: game.title,
            jarPath: game.jarURL.path,
            importedAt: game.importedAt,
            contentHash: game.contentHash
        )
    }
}
