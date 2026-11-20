import Foundation

/// Copies selected game files into JavaOne's internal library.
protocol ImportService {
    /// Imports a JAR from `sourceURL` into the internal library.
    /// - Returns: The installed game created from the copied file.
    /// - Throws: If the library cannot be prepared or the copy fails.
    func importJAR(from sourceURL: URL) throws -> InstalledGame
}

/// Errors produced while importing a game file.
enum ImportServiceError: LocalizedError {
    case documentsDirectoryUnavailable
    case unableToReadSelectedFile(String)
    case invalidJAR(String)
    case unableToStoreFile(String)

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Unable to access the Documents directory."
        case .unableToReadSelectedFile(let reason):
            return "Unable to read the selected JAR: \(reason)"
        case .invalidJAR(let reason):
            return "The selected file cannot be imported: \(reason)"
        case .unableToStoreFile(let reason):
            return "Unable to copy the JAR into the app library: \(reason)"
        }
    }
}
