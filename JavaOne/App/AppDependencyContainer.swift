import Foundation

/// Composition root that builds and wires application dependencies.
@MainActor
final class AppDependencyContainer {

    private lazy var gameLibraryRepository: GameLibraryRepository =
        SwiftDataGameLibraryRepository()

    private lazy var importService: ImportService = FileImportService()
    private lazy var manifestService: ManifestService = JARManifestService()

    private lazy var importSteps: [any ImportStep] = [
        ManifestStep(manifestService: manifestService),
        HashStep(),
        DuplicateDetectionStep(repository: gameLibraryRepository),
        ArtworkStep()
    ]

    private lazy var importPipeline: ImportPipelineProtocol =
        DefaultImportPipeline(
            importService: importService,
            steps: importSteps
        )

    private lazy var importEngine: ImportEngineProtocol =
        DefaultImportEngine(pipeline: importPipeline)

    private lazy var runtimeHost: RuntimeHostProtocol = makeRuntimeHost()

    private lazy var emulatorBridge: EmulatorBridgeProtocol =
        DefaultEmulatorBridge(runtimeHost: runtimeHost)

    init() {}

    func makeLibraryViewModel() -> LibraryViewModel {
        LibraryViewModel(
            repository: gameLibraryRepository,
            importEngine: importEngine,
            makeEmulatorViewModel: { [self] in
                makeEmulatorViewModel()
            }
        )
    }

    func makeEmulatorBridge() -> EmulatorBridgeProtocol {
        emulatorBridge
    }

    func makeEmulatorViewModel() -> EmulatorViewModel {
        EmulatorViewModel(bridge: emulatorBridge)
    }

    var productionRuntimeHost: RuntimeHostProtocol {
        runtimeHost
    }

    private func makeRuntimeHost() -> RuntimeHostProtocol {
        FreeJ2MERuntimeHost()
    }
}
