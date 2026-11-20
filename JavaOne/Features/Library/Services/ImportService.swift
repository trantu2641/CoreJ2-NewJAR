import Foundation

/// Copies selected game files into JavaOne's internal library.
protocol ImportService {
    func importJAR(from sourceURL: URL) throws -> InstalledGame
}

/// Errors produced while importing a game file.
enum ImportServiceError: LocalizedError {
    case documentsDirectoryUnavailable
    case notAJARFile
    case emptyJARFile
    case unableToReadJAR(String)
    case unableToSaveJAR(String)
    case unableToCreateLibraryDirectory(String)

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Unable to access the Documents directory."

        case .notAJARFile:
            return "The selected file is not a .jar file."

        case .emptyJARFile:
            return "The selected JAR file is empty."

        case .unableToReadJAR(let reason):
            return "Unable to read the JAR file: \(reason)"

        case .unableToSaveJAR(let reason):
            return "Unable to save the JAR into the JavaOne library: \(reason)"

        case .unableToCreateLibraryDirectory(let reason):
            return "Unable to create the JavaOne library folder: \(reason)"
        }
    }
}
