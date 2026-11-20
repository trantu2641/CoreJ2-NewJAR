import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var viewModel: LibraryViewModel
    @State private var isImportPresented = false

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import Game") {
                            isImportPresented = true
                        }
                    }
                }
                .fileImporter(
                    isPresented: $isImportPresented,
                    allowedContentTypes: Self.jarContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    viewModel.handleImportResult(result)
                }
                .alert("Import Successful", isPresented: successAlertBinding) {
                    Button("OK", role: .cancel) {
                        viewModel.dismissSuccessMessage()
                    }
                } message: {
                    Text(viewModel.successMessage ?? "")
                }
                .alert("Import Failed", isPresented: errorAlertBinding) {
                    Button("OK", role: .cancel) {
                        viewModel.dismissErrorMessage()
                    }
                } message: {
                    Text(viewModel.errorMessage ?? "")
                }
                .background(
                    NavigationLink(
                        destination: emulatorDestination,
                        isActive: gameLaunchIsActiveBinding
                    ) {
                        EmptyView()
                    }
                    .hidden()
                )
        }
        .onAppear {
            viewModel.loadGames()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.games.isEmpty {
            emptyState
        } else {
            gameList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Games")
                .font(.title2.weight(.semibold))

            Text("Import a Java ME game to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let selectedFileName = viewModel.selectedFileName {
                Text(selectedFileName)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var gameList: some View {
        List(viewModel.games) { game in
            Button {
                viewModel.selectGame(game)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text("Tap to play")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var emulatorDestination: some View {
        Group {
            if let game = viewModel.gameToLaunch,
               let emulatorViewModel = viewModel.activeEmulatorViewModel {
                EmulatorView(
                    viewModel: emulatorViewModel,
                    game: game,
                    availableGames: viewModel.games,
                    onClose: {
                        viewModel.dismissEmulator()
                    }
                )
            } else {
                EmptyView()
            }
        }
    }

    private var gameLaunchIsActiveBinding: Binding<Bool> {
        Binding(
            get: { viewModel.gameToLaunch != nil },
            set: { isActive in
                if !isActive {
                    viewModel.dismissEmulator()
                }
            }
        )
    }

    private var successAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.successMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissSuccessMessage()
                }
            }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissErrorMessage()
                }
            }
        )
    }

    private static let jarContentTypes: [UTType] = [
        UTType(exportedAs: "com.javaonelabs.java-archive", conformingTo: .data),
        .data
    ]
}
