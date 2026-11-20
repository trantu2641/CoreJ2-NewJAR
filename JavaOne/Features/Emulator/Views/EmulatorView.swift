import SwiftUI

/// JarBox-style J2ME emulator surface.
///
/// The emulator is intentionally split into three fixed regions:
/// - Jar tabs / controls at the top
/// - the FreeJ2ME LCD in the middle
/// - the JarBox virtual keypad at the bottom
struct EmulatorView: View {

    // MARK: - Dependencies

    @ObservedObject private var viewModel: EmulatorViewModel
    private let initialGame: InstalledGame
    private let availableGames: [InstalledGame]
    private let onClose: () -> Void

    // MARK: - UI State

    @State private var tabs: [InstalledGame]
    @State private var selectedTabID: UUID
    @State private var isVirtualKeyboardVisible = true
    @FocusState private var isSystemKeyboardFocused: Bool

    // MARK: - Init

    init(
        viewModel: EmulatorViewModel,
        game: InstalledGame,
        availableGames: [InstalledGame] = [],
        onClose: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.initialGame = game
        self.availableGames = availableGames
        self.onClose = onClose
        _tabs = State(initialValue: [game])
        _selectedTabID = State(initialValue: game.id)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                topControlBar
                    .frame(height: 62)
                    .background(Color.black)

                lcdSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                if isVirtualKeyboardVisible {
                    virtualKeyboard
                        .frame(height: keyboardHeight(for: geometry.size))
                        .background(Color.black)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .navigationBarHidden(true)
        .alert(
            "Launch Failed",
            isPresented: launchErrorBinding
        ) {
            Button("OK", role: .cancel) {
                viewModel.dismissLaunchError()
            }
        } message: {
            Text(viewModel.launchErrorMessage ?? "")
        }
        .task(id: selectedTabID) {
            guard let game = selectedGame else { return }
            await viewModel.startSession(for: game)
        }
        .onChange(of: selectedTabID) { _ in
            // The current bridge owns one active runtime. Switching tabs therefore
            // cleanly stops the previous JAR and starts the selected one.
            viewModel.endSession()
        }
        .onDisappear {
            viewModel.endSession()
        }
    }

    // MARK: - Top controls

    private var topControlBar: some View {
        HStack(spacing: 10) {
            tabStrip

            Spacer(minLength: 8)

            addTabMenu()

            controlButton(symbol: "−", accessibility: "Close JAR tab") {
                closeSelectedTab()
            }

            controlButton(
                symbol: "⌨",
                accessibility: "Show or hide virtual J2ME keyboard"
            ) {
                isVirtualKeyboardVisible.toggle()
            }

            controlButton(
                symbol: "A|",
                accessibility: "Show or hide iPhone keyboard"
            ) {
                isSystemKeyboardFocused.toggle()
            }

            controlButton(symbol: "•••", accessibility: "More emulator options") {
                // Reserved for JarBox-compatible runtime options.
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        // A tiny native TextField is kept in the hierarchy so A| can summon
        // the actual iOS keyboard without replacing the J2ME keypad.
        .overlay {
            TextField("", text: .constant(""))
                .focused($isSystemKeyboardFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    Button {
                        selectedTabID = tab.id
                    } label: {
                        Text("\(index + 1)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(selectedTabID == tab.id ? .white : Color.white.opacity(0.75))
                            .frame(width: 76, height: 46)
                            .background(
                                selectedTabID == tab.id
                                    ? Color.blue
                                    : Color.white.opacity(0.16)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("JAR tab \(index + 1): \(tab.title)")
                }
            }
        }
        .frame(maxWidth: 120)
    }

    @ViewBuilder
    private func addTabMenu() -> some View {
        Menu {
            let candidates = availableGames.filter { game in
                !tabs.contains(where: { $0.id == game.id })
            }

            if candidates.isEmpty {
                Text("No other JAR")
            } else {
                ForEach(candidates) { game in
                    Button(game.title) {
                        tabs.append(game)
                        selectedTabID = game.id
                    }
                }
            }
        } label: {
            controlLabel("+")
        }
        .menuStyle(.automatic)
    }

    private func controlButton(
        symbol: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            controlLabel(symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private func controlLabel(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: symbol == "•••" ? 20 : 28, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: 64, height: 46)
            .background(Color.white.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    // MARK: - LCD

    private var lcdSurface: some View {
        GeometryReader { geometry in
            let size = fittedLCDSize(in: geometry.size)

            ZStack {
                Color.black

                lcdContent
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var lcdContent: some View {
        if let cgImage = viewModel.lcdImage {
            Image(decorative: cgImage, scale: 1.0, orientation: .up)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(white: 0.12))
                .overlay {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding()
                }
        }
    }

    // MARK: - JarBox keypad

    private var virtualKeyboard: some View {
        VStack(spacing: 7) {
            keypadRow([
                .text("1"), .text("2"), .text("3"), .text("L"), .empty, .text("R")
            ])
            keypadRow([
                .text("4"), .text("5"), .text("6"), .text("↖"), .text("↑"), .text("↗")
            ])
            keypadRow([
                .text("7"), .text("8"), .text("9"), .text("←"), .text("F"), .text("→")
            ])
            keypadRow([
                .text("*"), .text("0"), .text("#"), .text("↙"), .text("↓"), .text("↘")
            ])
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    private enum KeypadKey: Hashable, Identifiable {
        case text(String)
        case empty

        var id: String {
            switch self {
            case .text(let value): return value
            case .empty: return "empty"
            }
        }
    }

    private func keypadRow(_ keys: [KeypadKey]) -> some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 6
            let width = max(1, (geometry.size.width - spacing * 5) / 6)

            HStack(spacing: spacing) {
                ForEach(keys) { key in
                    switch key {
                    case .text(let value):
                        Button {
                            handleVirtualKey(value)
                        } label: {
                            Text(value)
                                .font(.system(size: 28, weight: .medium, design: .rounded))
                                .foregroundColor(Color(red: 0.03, green: 0.13, blue: 0.48))
                                .frame(width: width, height: geometry.size.height)
                                .background(Color(white: 0.93))
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)

                    case .empty:
                        Color.clear
                            .frame(width: width, height: geometry.size.height)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var selectedGame: InstalledGame? {
        tabs.first(where: { $0.id == selectedTabID }) ?? initialGame
    }

    private func closeSelectedTab() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            onClose()
            return
        }

        if tabs.count == 1 {
            viewModel.endSession()
            onClose()
            return
        }

        let replacementIndex = index == 0 ? 1 : index - 1
        let replacement = tabs[replacementIndex]
        tabs.remove(at: index)
        selectedTabID = replacement.id
    }

    private func handleVirtualKey(_ value: String) {
        // UI-level mapping is deliberately kept in one place. The runtime input
        // sink can be connected here when the FreeJ2ME MobilePlatform input API
        // is wired into the native bridge.
        _ = value
    }

    private func keyboardHeight(for size: CGSize) -> CGFloat {
        let width = size.width
        if width <= 390 { return min(338, size.height * 0.39) }
        if width <= 430 { return min(360, size.height * 0.40) }
        return min(390, size.height * 0.38)
    }

    private var statusMessage: String {
        if viewModel.activeSession != nil {
            return "Waiting for frame…"
        }
        if viewModel.launchErrorMessage != nil {
            return "Launch failed"
        }
        return "Starting…"
    }

    private func fittedLCDSize(in container: CGSize) -> CGSize {
        let aspect: CGFloat
        if let metadata = viewModel.surfaceMetadata, metadata.height > 0 {
            aspect = CGFloat(metadata.width) / CGFloat(metadata.height)
        } else {
            aspect = 240.0 / 320.0
        }

        let maxWidth = container.width
        let maxHeight = container.height
        let widthLimitedHeight = maxWidth / aspect
        if widthLimitedHeight <= maxHeight {
            return CGSize(width: maxWidth, height: widthLimitedHeight)
        }
        return CGSize(width: maxHeight * aspect, height: maxHeight)
    }

    private var accessibilityLabel: String {
        if let metadata = viewModel.surfaceMetadata {
            return "Emulator LCD, \(metadata.width) by \(metadata.height), \(viewModel.receivedFrameCount) frames"
        }
        return "Emulator LCD surface, waiting for frame"
    }

    private var launchErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.launchErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissLaunchError()
                }
            }
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        EmulatorView(
            viewModel: EmulatorViewModel(bridge: PreviewEmulatorBridge()),
            game: InstalledGame(
                id: UUID(),
                title: "Demo",
                jarURL: URL(fileURLWithPath: "/tmp/demo.jar"),
                importedAt: Date(),
                contentHash: "abc"
            )
        )
    }
}

@MainActor
private final class PreviewEmulatorBridge: EmulatorBridgeProtocol {
    private let pipe = RuntimeEventPipe()

    var runtimeEvents: AsyncStream<RuntimeEvent> {
        pipe.events
    }

    func launch(_ configuration: LaunchConfiguration) throws -> EmulatorSession {
        EmulatorSession(configuration: configuration, state: .running)
    }

    func pause(_ session: EmulatorSession) throws {
        session.transition(to: .paused)
    }

    func resume(_ session: EmulatorSession) throws {
        session.transition(to: .running)
    }

    func stop(_ session: EmulatorSession) throws {
        session.transition(to: .stopped)
    }
}
#endif
