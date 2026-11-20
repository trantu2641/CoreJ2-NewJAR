import SwiftUI

@main
struct JavaOneApp: App {

    @StateObject private var libraryViewModel: LibraryViewModel

    init() {
        let dependencies = AppDependencyContainer()
        _libraryViewModel = StateObject(
            wrappedValue: dependencies.makeLibraryViewModel()
        )
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(viewModel: libraryViewModel)
        }
    }
}
