import SwiftUI

struct AppShellView: View {
    @Environment(AppState.self) private var appState
    @Namespace private var dockNamespace
    @State private var isCommandMenuPresented = ProcessInfo.processInfo.arguments.contains("--spyclash-preview-command-menu-open")

    var body: some View {
        @Bindable var appState = appState
        let contentTab = appState.selectedTab == .game && appState.activeRoom == nil ? AppTab.home : appState.selectedTab
        let dockTabs = AppTab.primaryCases
        let shouldShowShellChrome = !appState.isShellChromeSuppressed
        let shouldShowDock = contentTab.showsBottomDock && shouldShowShellChrome

        ZStack(alignment: .bottom) {
            contentTab
                .makeContentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if shouldShowDock {
                        Color.clear
                            .frame(height: 76)
                            .allowsHitTesting(false)
                    }
                }

            FloatingDock(selection: $appState.selectedTab, tabs: dockTabs, namespace: dockNamespace, language: appState.language)
                .opacity(shouldShowDock ? 1 : 0)
                .offset(y: shouldShowDock ? 0 : 78)
                .allowsHitTesting(shouldShowDock)
                .accessibilityHidden(!shouldShowDock)
                .animation(.easeOut(duration: 0.20), value: shouldShowDock)
        }
        .background(SpyTheme.black)
        .overlay(alignment: .top) {
            WebPullDownCommandMenu(isPresented: $isCommandMenuPresented)
                .opacity(shouldShowShellChrome ? 1 : 0)
                .offset(y: shouldShowShellChrome ? 0 : -140)
                .allowsHitTesting(shouldShowShellChrome)
                .accessibilityHidden(!shouldShowShellChrome)
                .animation(.easeOut(duration: 0.18), value: shouldShowShellChrome)
        }
        .sheet(item: $appState.presentedSheet) { destination in
            switch destination {
            case .qrScanner:
                QRScannerSheet()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
            case .roomQR(let room):
                RoomQRSheet(room: room)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
            case .pricing:
                PricingView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
            case .community:
                CommunityView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
            case .legal(let kind):
                LegalDocumentSheet(kind: kind)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
            }
        }
        .onAppear {
#if DEBUG
            presentPreviewSheetAfterShellMountIfNeeded()
#endif
        }
        .onChange(of: appState.activeRoom?.id) { _, roomID in
            guard roomID == nil, appState.selectedTab == .game else { return }
            appState.selectedTab = .home
        }
    }

#if DEBUG
    private func presentPreviewSheetAfterShellMountIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        let previewSheet = arguments
            .first { $0.hasPrefix("--spyclash-preview-sheet=") }
            .map { String($0.dropFirst("--spyclash-preview-sheet=".count)) }

        guard let previewSheet else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            switch previewSheet {
            case "pricing":
                appState.presentedSheet = .pricing
            case "community":
                appState.presentedSheet = .community
            case "privacy":
                appState.presentedSheet = .legal(.privacy)
            case "terms":
                appState.presentedSheet = .legal(.terms)
            case "roomQR", "room-qr", "qr":
                appState.presentedSheet = .roomQR(appState.activeRoom ?? GameRoom.previewRoom(status: "waiting"))
            case "scanner", "qrScanner", "qr-scanner":
                appState.presentedSheet = .qrScanner
            default:
                break
            }
        }
    }
#endif
}

private struct PullDownCommandMenu: View {
    @Binding var isPresented: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var didFireDragHaptic = false

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let visualTopInset = topInset > 0 ? min(topInset, 54) : 54
            let travelDistance = min(proxy.size.height * 0.62, 500)
            let closedHandleHeight = max(visualTopInset + 88, 142)
            let openHandleHeight: CGFloat = 58
            let visibleHeight = drawerHeight(
                travelDistance: travelDistance,
                closedHandleHeight: closedHandleHeight,
                translation: dragTranslation
            )
            let openProgress = progressFromHeight(
                visibleHeight,
                travelDistance: travelDistance,
                closedHandleHeight: closedHandleHeight
            )
            let contentProgress = smoothStep(clamp((openProgress - 0.08) / 0.78))
            let handleProgress = smoothStep(openProgress)
            let handleHeight = closedHandleHeight - ((closedHandleHeight - openHandleHeight) * handleProgress)
            let restingHeight = isPresented ? closedHandleHeight + travelDistance : closedHandleHeight
            let hasVisibleDrag = abs(visibleHeight - restingHeight) > 0.5
            let isInteracting = hasVisibleDrag || didFireDragHaptic
            let hitAreaHeight = isPresented || openProgress > 0.08 ? proxy.size.height : visibleHeight

            ZStack(alignment: .top) {
                if isPresented || openProgress > 0.08 {
                    Color.black
                        .opacity(0.20 * openProgress)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeMenu()
                        }
                        .transition(.opacity)
                }

                drawerSurface(
                    topInset: visualTopInset,
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight,
                    visibleHeight: visibleHeight,
                    handleHeight: handleHeight,
                    openProgress: openProgress,
                    contentProgress: contentProgress,
                    isInteracting: isInteracting
                )

            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: hitAreaHeight, alignment: .top)
            .transaction { transaction in
                if isInteracting {
                    transaction.animation = nil
                }
            }
        }
        .ignoresSafeArea()
    }

    private func commandMenuGesture(travelDistance: CGFloat, closedHandleHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let directionalTranslation = dragDirectionAdjusted(value.translation.height)
                let meaningfulDrag = abs(directionalTranslation) > 1.5

                if !didFireDragHaptic, meaningfulDrag {
                    didFireDragHaptic = true
                    HapticManager.shared.fire(.tabSelection)
                }

                updateDragTranslation(directionalTranslation)
            }
            .onEnded { value in
                didFireDragHaptic = false

                let predictedHeight = drawerHeight(
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight,
                    translation: dragDirectionAdjusted(value.predictedEndTranslation.height)
                )
                let settledHeight = drawerHeight(
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight,
                    translation: dragDirectionAdjusted(value.translation.height)
                )
                let predictedProgress = progressFromHeight(
                    predictedHeight,
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight
                )
                let settledProgress = progressFromHeight(
                    settledHeight,
                    travelDistance: travelDistance,
                    closedHandleHeight: closedHandleHeight
                )

                setMenuPresented(shouldPresentAfterRelease(predictedProgress: predictedProgress, settledProgress: settledProgress))
            }
    }

    private func drawerSurface(
        topInset: CGFloat,
        travelDistance: CGFloat,
        closedHandleHeight: CGFloat,
        visibleHeight: CGFloat,
        handleHeight: CGFloat,
        openProgress: CGFloat,
        contentProgress: CGFloat,
        isInteracting: Bool
    ) -> some View {
        let drawerCut = 18 + (openProgress * 8)
        let menuHeight = max(320, visibleHeight - 8)
        let shouldRenderMenu = isPresented || openProgress > 0.04

        return ZStack(alignment: .bottom) {
            if shouldRenderMenu {
                CompactCommandMenuPanel(
                    progress: contentProgress,
                    topInset: topInset,
                    close: closeMenu
                )
                    .frame(maxWidth: 430)
                    .frame(height: menuHeight, alignment: .top)
                    .padding(.horizontal, 0)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(contentProgress)
                    .offset(y: reduceMotion ? 0 : -14 + (contentProgress * 14))
                    .allowsHitTesting(contentProgress > 0.86)
            }

            drawerTopChrome(
                progress: openProgress,
                isInteracting: isInteracting
            )
            .frame(height: handleHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .accessibilityLabel(isPresented ? "Close command menu" : "Pull down command menu")
            .highPriorityGesture(commandMenuGesture(travelDistance: travelDistance, closedHandleHeight: closedHandleHeight))
        }
        .frame(maxWidth: .infinity)
        .frame(height: visibleHeight, alignment: .top)
        .background {
            drawerBrandSurface(cut: drawerCut, progress: openProgress)
        }
        .overlay {
            drawerShape(cut: drawerCut)
                .stroke(
                    LinearGradient(
                        colors: [
                            SpyTheme.red.opacity(openProgress > 0.08 ? 0.64 : 0.18),
                            SpyTheme.strokeStrong.opacity(0.78),
                            SpyTheme.red.opacity(openProgress > 0.08 ? 0.38 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .bottom) {
            closedChromeBottomBreak(progress: openProgress)
        }
        .overlay(alignment: .bottom) {
            if openProgress < 0.52 {
                closedChromeMarker(topInset: topInset, progress: openProgress, isInteracting: isInteracting)
                    .frame(height: closedHandleHeight)
                    .opacity(Double(1 - clamp(openProgress * 1.9)))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(drawerShape(cut: drawerCut))
        .shadow(
            color: .black.opacity(0.58 - (openProgress * 0.12)),
            radius: 24 + (openProgress * 12),
            y: 13 + (openProgress * 6)
        )
        .contentShape(Rectangle())
    }

    private func drawerBrandSurface(cut: CGFloat, progress: CGFloat) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let openBias = smoothStep(progress)
            let closedBias = 1 - smoothStep(clamp(progress * 1.7))

            ZStack {
                drawerShape(cut: cut)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 3 / 255, green: 3 / 255, blue: 4 / 255), location: 0.00),
                                .init(color: Color(red: 11 / 255, green: 8 / 255, blue: 9 / 255), location: 0.58),
                                .init(color: Color(red: 2 / 255, green: 2 / 255, blue: 3 / 255), location: 1.00)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.60 * closedBias), location: 0.00),
                        .init(color: Color(red: 10 / 255, green: 6 / 255, blue: 7 / 255).opacity(0.26 * closedBias), location: 0.58),
                        .init(color: .clear, location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(size.height, 152), alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                RadialGradient(
                    colors: [
                        SpyTheme.red.opacity(0.030 + (0.020 * openBias)),
                        SpyTheme.red.opacity(0.010 + (0.010 * openBias)),
                        .clear
                    ],
                    center: UnitPoint(x: 0.20, y: 0.46),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.62
                )

                RadialGradient(
                    colors: [
                        Color(red: 100 / 255, green: 100 / 255, blue: 150 / 255).opacity(0.028),
                        .clear
                    ],
                    center: UnitPoint(x: 0.82, y: 0.22),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.50
                )
                .opacity(0.72 + (0.28 * openBias))

                RadialGradient(
                    colors: [
                        SpyTheme.red.opacity(0.016 + (0.018 * openBias)),
                        .clear
                    ],
                    center: UnitPoint(x: 0.50, y: 0.94),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.42
                )

                Canvas { context, canvasSize in
                    var path = Path()
                    let spacing: CGFloat = 50

                    stride(from: CGFloat.zero, through: canvasSize.width, by: spacing).forEach { x in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                    }
                    stride(from: CGFloat.zero, through: canvasSize.height, by: spacing).forEach { y in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                    }

                    context.stroke(path, with: .color(SpyTheme.red.opacity(0.014 + (0.018 * openBias))), lineWidth: 1)
                }
                .mask {
                    RadialGradient(
                        stops: [
                            .init(color: .black.opacity(0.78), location: 0.20),
                            .init(color: .black.opacity(0.36), location: 0.75),
                            .init(color: .clear, location: 1.00)
                        ],
                        center: .center,
                        startRadius: min(size.width, size.height) * 0.12,
                        endRadius: max(size.width, size.height) * 0.82
                    )
                }

                LinearGradient(
                    colors: [
                        .clear,
                        SpyTheme.red.opacity(0.035 + (0.020 * openBias)),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .offset(y: size.height * 0.33)

                LinearGradient(
                    colors: [
                        SpyTheme.black.opacity(0.00),
                        SpyTheme.black.opacity(0.22 - (0.08 * openBias))
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.035),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(drawerShape(cut: cut))
        }
        .allowsHitTesting(false)
    }

    private var drawerContentFadeMask: some View {
        VStack(spacing: 0) {
            Color.white

            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.00),
                    .init(color: .white.opacity(0.96), location: 0.28),
                    .init(color: .white.opacity(0.74), location: 0.58),
                    .init(color: .white.opacity(0.26), location: 0.86),
                    .init(color: .clear, location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 118)
        }
    }

    private var drawerBottomContentVeil: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: SpyTheme.graphite.opacity(0.00), location: 0.00),
                    .init(color: SpyTheme.graphite.opacity(0.00), location: 0.30),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.10), location: 0.54),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.42), location: 0.78),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.78), location: 0.93),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.92), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blur(radius: 0.35)

            LinearGradient(
                stops: [
                    .init(color: SpyTheme.graphite.opacity(0.00), location: 0.00),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.38), location: 0.46),
                    .init(color: Color(red: 12 / 255, green: 8 / 255, blue: 9 / 255).opacity(0.90), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    SpyTheme.red.opacity(0.00),
                    SpyTheme.red.opacity(0.08),
                    SpyTheme.red.opacity(0.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 76)
            .padding(.bottom, 1)
        }
    }

    private func drawerShape(cut: CGFloat) -> DrawerCutShape {
        DrawerCutShape(cut: cut)
    }

    private func closedChromeBottomBreak(progress: CGFloat) -> some View {
        let alpha = Double(1 - smoothStep(clamp(progress * 2.5)))

        return VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    SpyTheme.red.opacity(0.00),
                    SpyTheme.red.opacity(0.20),
                    SpyTheme.strokeStrong.opacity(0.62),
                    SpyTheme.red.opacity(0.10),
                    SpyTheme.red.opacity(0.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 34)

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.34), location: 0.00),
                    .init(color: Color.black.opacity(0.16), location: 0.40),
                    .init(color: .clear, location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 18)
        }
        .opacity(alpha)
        .allowsHitTesting(false)
    }

    private func drawerTopChrome(progress: CGFloat, isInteracting: Bool) -> some View {
        let gripWidth = 36 + (progress * 18) + (isInteracting ? 8 : 0)
        let gripOpacity = 0.42 + (progress * 0.20) + (isInteracting ? 0.16 : 0)
        let openChromeOpacity = Double(smoothStep(clamp((progress - 0.18) / 0.24)) * (1 - smoothStep(clamp((progress - 0.48) / 0.18))))

        return ZStack(alignment: .bottom) {
            grabberBars(width: gripWidth, opacity: gripOpacity, progress: progress, isInteracting: isInteracting)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .padding(.bottom, 8)
                .opacity(openChromeOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .bottom) {
            bottomChromeFill(progress: progress)
        }
        .contentShape(Rectangle())
    }

    private func closedChromeMarker(topInset: CGFloat, progress: CGFloat, isInteracting: Bool) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                spyClashLogo(fontSize: 18)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white.opacity(0.88))
                    .rotationEffect(.degrees(progress * 180))
                    .frame(width: 40, height: 32)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 28)
            .opacity(Double(1 - clamp(progress * 2.4)))

            grabberBars(
                    width: 38 + (isInteracting ? 8 : 0),
                    opacity: isInteracting ? 0.62 : 0.48,
                    progress: progress,
                    isInteracting: isInteracting
                )

            Text("\(statusLinePrefix)  •  \(statusLineValue)")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(0.22)
                .foregroundStyle(statusLineColor(progress: progress))
                .spyFitted(scale: 0.66, alignment: .center)
                .padding(.horizontal, 18)
                .shadow(color: .black.opacity(0.80), radius: 8, y: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, max(10, topInset + 2))
    }

    private func spyClashLogo(fontSize: CGFloat) -> some View {
        SpyWordmark(fontSize: fontSize)
            .shadow(color: .black.opacity(0.70), radius: 8, y: 3)
    }

    private func grabberBars(width: CGFloat, opacity: CGFloat, progress: CGFloat, isInteracting: Bool) -> some View {
        ZStack {
            Capsule()
                .fill((isInteracting ? SpyTheme.red : Color.white).opacity(opacity))
                .frame(width: width, height: 4)
                .shadow(color: SpyTheme.red.opacity(isInteracting ? 0.40 : 0.12 * progress), radius: 8 + (progress * 7))

            Capsule()
                .fill(Color.white.opacity(0.08 + (progress * 0.12)))
                .frame(width: max(22, width * 0.62), height: 2)
                .offset(y: 9)
        }
        .frame(width: 96, height: 18)
    }

    private func bottomChromeFill(progress: CGFloat) -> some View {
        LinearGradient(
            colors: [.clear, SpyTheme.graphite.opacity(0.08 * smoothStep(progress))],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 8)
        .allowsHitTesting(false)
    }

    private var statusLineValue: String {
        if let room = appState.activeRoom {
            return appState.language.home.statusLabel(room.status).uppercased()
        }
        return "ONLINE"
    }

    private var statusLinePrefix: String {
        localized(en: "STATUS:", ru: "СТАТУС:", es: "ESTADO:")
    }

    private func statusLineColor(progress: CGFloat) -> Color {
        SpyTheme.red
    }

    private func dragDirectionAdjusted(_ translation: CGFloat) -> CGFloat {
        if isPresented {
            min(0, translation)
        } else {
            max(0, translation)
        }
    }

    private func drawerHeight(travelDistance: CGFloat, closedHandleHeight: CGFloat, translation: CGFloat) -> CGFloat {
        let openHeight = closedHandleHeight + travelDistance
        let restingHeight = isPresented ? openHeight : closedHandleHeight
        let rawHeight = restingHeight + translation
        return min(openHeight, max(closedHandleHeight, rawHeight))
    }

    private func progressFromHeight(_ height: CGFloat, travelDistance: CGFloat, closedHandleHeight: CGFloat) -> CGFloat {
        clamp((height - closedHandleHeight) / max(travelDistance, 1))
    }

    private func shouldPresentAfterRelease(predictedProgress: CGFloat, settledProgress: CGFloat) -> Bool {
        if isPresented {
            return !(predictedProgress < 0.74 || settledProgress < 0.80)
        }

        return predictedProgress > 0.18 || settledProgress > 0.12
    }

    private func updateDragTranslation(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            dragTranslation = value
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = clamp(value)
        return clamped * clamped * (3 - (2 * clamped))
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
        }
    }

    private func closeMenu() {
        setMenuPresented(false)
    }

    private func setMenuPresented(_ presented: Bool) {
        if isPresented != presented {
            HapticManager.shared.fire(.buttonPress)
        }

        let animation: Animation = reduceMotion ? .easeOut(duration: 0.18) : settleAnimation
        withAnimation(animation) {
            isPresented = presented
            dragTranslation = 0
        }
    }

    private var settleAnimation: Animation {
        .timingCurve(0.18, 0.86, 0.18, 1.0, duration: 0.34)
    }
}

private struct CompactCommandMenuPanel: View {
    @Environment(AppState.self) private var appState

    let progress: CGFloat
    let topInset: CGFloat
    let close: () -> Void

    private var profileCopy: ProfileCopy {
        appState.language.profile
    }

    var body: some View {
        ZStack {
            menuSurface

            VStack(alignment: .leading, spacing: 0) {
                header
                    .opacity(phase(0.02, 0.24))
                    .offset(y: stagedOffset(0.02, 0.24, distance: -14))

                Spacer(minLength: 34)

                VStack(alignment: .leading, spacing: 4) {
                    menuRow(
                        icon: "👤",
                        title: appState.language.tabTitle(.profile),
                        selected: appState.selectedTab == .profile,
                        phaseStart: 0.22
                    ) {
                        closeThen { appState.selectedTab = .profile }
                    }

                    menuRow(
                        icon: "📦",
                        title: appState.language.tabTitle(.packs),
                        selected: appState.selectedTab == .packs,
                        phaseStart: 0.32
                    ) {
                        closeThen { appState.selectedTab = .packs }
                    }

                    menuRow(
                        icon: "⚡",
                        title: "LIMITLESS",
                        highlighted: true,
                        phaseStart: 0.42
                    ) {
                        closeThen { appState.presentedSheet = .pricing }
                    }

                    Rectangle()
                        .fill(SpyTheme.strokeStrong.opacity(0.58))
                        .frame(height: 1)
                        .padding(.vertical, 11)
                        .opacity(phase(0.50, 0.64))

                    menuRow(
                        icon: "🚪",
                        title: profileCopy.logOut,
                        highlighted: true,
                        phaseStart: 0.54
                    ) {
                        close()
                        appState.logout()
                    }
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 16)

                languageFooter
                    .opacity(phase(0.62, 0.90))
                    .offset(y: stagedOffset(0.62, 0.90, distance: 14))
            }
            .padding(.top, topInset + 24)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var menuSurface: some View {
        ZStack {
            Color.black

            RadialGradient(
                colors: [
                    SpyTheme.red.opacity(0.060),
                    SpyTheme.red.opacity(0.022),
                    .clear
                ],
                center: UnitPoint(x: 0.18, y: 0.44),
                startRadius: 0,
                endRadius: 360
            )

            LinearGradient(
                colors: [
                    .clear,
                    SpyTheme.red.opacity(0.040),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            menuGrid
                .opacity(0.40)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SpyTheme.strokeStrong.opacity(0.38))
                .frame(height: 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SpyTheme.red.opacity(0.90))
                .frame(width: 2)
                .opacity(phase(0.28, 0.62))
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    SpyTheme.red.opacity(0.00),
                    SpyTheme.red.opacity(0.82),
                    SpyTheme.red.opacity(0.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 10)
            .opacity(phase(0.42, 0.80))
        }
        .overlay {
            menuCorners
                .opacity(phase(0.08, 0.36))
        }
    }

    private var menuGrid: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 58

            stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }

            stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(path, with: .color(SpyTheme.red.opacity(0.035)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private var menuCorners: some View {
        VStack {
            HStack {
                CornerStroke(color: Color.white.opacity(0.55))
                    .frame(width: 18, height: 18)
                Spacer()
                CornerStroke(color: Color.white.opacity(0.55))
                    .rotationEffect(.degrees(90))
                    .frame(width: 18, height: 18)
            }

            Spacer()

            HStack {
                CornerStroke(color: SpyTheme.red)
                    .rotationEffect(.degrees(270))
                    .frame(width: 18, height: 18)
                Spacer()
                CornerStroke(color: SpyTheme.red)
                    .rotationEffect(.degrees(180))
                    .frame(width: 18, height: 18)
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            spyClashLogo(fontSize: 30)

            Spacer()

            Button {
                close()
            } label: {
                menuLines
                    .frame(width: 56, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(en: "Close menu", ru: "Закрыть меню", es: "Cerrar menu"))
        }
        .padding(.horizontal, 28)
    }

    private var menuLines: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Capsule()
                .frame(width: 26, height: 3)
            Capsule()
                .frame(width: 26, height: 3)
            Capsule()
                .frame(width: 18, height: 3)
        }
        .foregroundStyle(SpyTheme.red)
        .shadow(color: SpyTheme.red.opacity(0.25), radius: 7)
    }

    private func spyClashLogo(fontSize: CGFloat) -> some View {
        SpyWordmark(fontSize: fontSize)
            .shadow(color: .black.opacity(0.70), radius: 8, y: 3)
    }

    private var languageFooter: some View {
        HStack(spacing: 12) {
            Text(localized(en: "LANG", ru: "ЯЗЫК", es: "IDIOMA"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.22)
                .foregroundStyle(SpyTheme.faint)
                .spyFitted(scale: 0.74)

            HStack(spacing: 6) {
                languageChip(.en)
                languageChip(.es)
                languageChip(.ru)
            }

            Spacer()

            Button {
                close()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 46, height: 40)
                    .background(Color.black.opacity(0.42), in: CutCornerShape(cut: 6))
                    .overlay(CutCornerShape(cut: 6).stroke(SpyTheme.strokeStrong.opacity(0.88), lineWidth: 1))
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(en: "Close menu", ru: "Закрыть меню", es: "Cerrar menu"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SpyTheme.strokeStrong.opacity(0.42))
                .frame(height: 1)
                .padding(.horizontal, 24)
        }
    }

    private func languageChip(_ language: AppLanguage) -> some View {
        Button {
            HapticManager.shared.fire(.buttonPress)
            Task {
                try? await appState.setLanguage(language, syncRemote: appState.user != nil)
            }
        } label: {
            Text(language.shortCode)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(appState.language == language ? .white : SpyTheme.dim)
                .frame(minWidth: 42, minHeight: 36)
                .background(appState.language == language ? SpyTheme.red : Color.clear, in: CutCornerShape(cut: 4))
                .overlay(CutCornerShape(cut: 4).stroke(appState.language == language ? SpyTheme.red : SpyTheme.inputBorder, lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func menuRow(
        icon: String,
        title: String,
        selected: Bool = false,
        highlighted: Bool = false,
        phaseStart: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        let rowProgress = phase(phaseStart, phaseStart + 0.22)

        return Button(action: action) {
            HStack(spacing: 12) {
                Text(icon)
                    .font(.system(size: 24, weight: .black))
                    .frame(width: 35)

                Text(title)
                    .font(.system(size: 19, weight: .black, design: .monospaced))
                    .tracking(title.count > 10 ? 0.10 : 0.22)
                    .spyFitted(lines: 2, scale: 0.62)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .black))
            }
            .foregroundStyle(highlighted || selected ? SpyTheme.red : SpyTheme.bodyText)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .padding(.horizontal, 8)
            .background {
                if highlighted || selected {
                    LinearGradient(
                        colors: [
                            SpyTheme.red.opacity(0.12),
                            SpyTheme.red.opacity(0.032),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(highlighted || selected ? SpyTheme.red : Color.clear)
                    .frame(width: 2, height: 44)
            }
        }
        .buttonStyle(SpyWebPressStyle())
        .opacity(rowProgress)
        .offset(y: stagedOffset(phaseStart, phaseStart + 0.22, distance: 18))
        .contentShape(Rectangle())
    }

    private func closeThen(_ action: @escaping @MainActor () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            action()
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        default: en
        }
    }

    private func phase(_ start: CGFloat, _ end: CGFloat) -> Double {
        guard end > start else { return progress >= end ? 1 : 0 }
        let value = (progress - start) / (end - start)
        return Double(smoothStep(clamp(value)))
    }

    private func stagedOffset(_ start: CGFloat, _ end: CGFloat, distance: CGFloat) -> CGFloat {
        let resolved = CGFloat(phase(start, end))
        return distance * (1 - resolved)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = clamp(value)
        return clamped * clamped * (3 - (2 * clamped))
    }
}

private struct DrawerCutShape: Shape {
    var cut: CGFloat

    func path(in rect: CGRect) -> Path {
        let resolvedCut = min(max(cut, 0), min(rect.width, rect.height) * 0.24)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - resolvedCut))
        path.addLine(to: CGPoint(x: rect.maxX - resolvedCut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + resolvedCut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - resolvedCut))
        path.closeSubpath()

        return path
    }
}

private struct FloatingDock: View {
    @Binding var selection: AppTab
    let tabs: [AppTab]
    let namespace: Namespace.ID
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab
                } label: {
                    DockItem(tab: tab, isSelected: selection.dockRepresentative == tab, namespace: namespace, language: language)
                }
                .buttonStyle(SpyWebPressStyle(pressedScale: 0.90))
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 348)
        .frame(height: 62)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .shadow(color: .black.opacity(0.24), radius: 9, y: 5)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

private struct DockItem: View {
    let tab: AppTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let language: AppLanguage

    var body: some View {
        Image(systemName: tab.symbol)
            .font(.system(size: 25, weight: isSelected ? .bold : .medium))
            .foregroundStyle(isSelected ? SpyTheme.red : Color.white.opacity(0.44))
            .scaleEffect(isSelected ? 1.12 : 1)
            .offset(y: isSelected ? -1 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(SpyTheme.red)
                        .frame(width: 28, height: 2)
                        .matchedGeometryEffect(id: "dock-active-redline", in: namespace)
                        .offset(y: -2)
                }
            }
            .contentShape(Rectangle())
            .animation(.interpolatingSpring(mass: 1, stiffness: 420, damping: 26, initialVelocity: 0), value: isSelected)
            .accessibilityLabel(language.tabTitle(tab))
    }
}

// Native translation of the Base44 Layout.jsx drawer. Its geometry and reveal
// phases intentionally mirror the web source so both shells share one rhythm.
private struct WebPullDownCommandMenu: View {
    @Binding var isPresented: Bool
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragTranslation: CGFloat = 0
    @State private var didFireDragHaptic = false

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 54
            let topBarHeight = topInset + 80
            let menuHeight = proxy.size.height * 0.50
            let revealedHeight = currentRevealHeight(menuHeight: menuHeight)
            let progress = clamp(revealedHeight / max(menuHeight, 1))
            let totalHeight = topBarHeight + revealedHeight
            let isInteracting = abs(dragTranslation) > 0.5 || didFireDragHaptic

            ZStack(alignment: .top) {
                if progress > 0.001 {
                    Color.black
                        .opacity(0.60 * progress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeMenu)
                }

                VStack(spacing: 0) {
                    WebMenuTopBar(progress: progress, topInset: topInset)
                        .frame(height: topBarHeight)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(isPresented ? "Close command menu" : "Pull down command menu")
                        .accessibilityIdentifier("spy-command-menu-drag-handle")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            setPresented(!isPresented)
                        }

                    if revealedHeight > 0.5 || isPresented {
                        WebCommandMenuPanel(progress: progress, close: closeMenu)
                            .frame(height: revealedHeight)
                            .clipped()
                            .allowsHitTesting(progress > 0.92)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: totalHeight, alignment: .top)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    menuDragGesture(menuHeight: menuHeight),
                    including: .all
                )
                .background(Color.black.opacity(0.97))
                .overlay(alignment: .bottom) {
                    ZStack {
                        Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
                            .opacity(1 - progress)
                        SpyTheme.red.opacity(progress)
                    }
                    .frame(height: 1)
                }
                .clipped()
                .shadow(color: .black.opacity(0.42 * progress), radius: 18, y: 10)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: progress > 0.001 ? proxy.size.height : totalHeight, alignment: .top)
            .transaction { transaction in
                if isInteracting {
                    transaction.animation = nil
                }
            }
        }
        .ignoresSafeArea()
    }

    private func menuDragGesture(menuHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let directional = isPresented
                    ? min(0, value.translation.height)
                    : max(0, value.translation.height)

                if !didFireDragHaptic, abs(directional) > 5 {
                    didFireDragHaptic = true
                    HapticManager.shared.fire(.tabSelection)
                }

                var transaction = Transaction()
                transaction.animation = nil
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragTranslation = directional
                }
            }
            .onEnded { value in
                didFireDragHaptic = false

                let predicted = isPresented
                    ? menuHeight + min(0, value.predictedEndTranslation.height)
                    : max(0, value.predictedEndTranslation.height)
                let settled = isPresented
                    ? menuHeight + min(0, value.translation.height)
                    : max(0, value.translation.height)
                let predictedProgress = clamp(predicted / max(menuHeight, 1))
                let settledProgress = clamp(settled / max(menuHeight, 1))

                setPresented(shouldRemainOpen(
                    predictedProgress: predictedProgress,
                    settledProgress: settledProgress
                ))
            }
    }

    private func shouldRemainOpen(predictedProgress: CGFloat, settledProgress: CGFloat) -> Bool {
        if isPresented {
            // Closing is measured from the open edge. A deliberate 24% pull,
            // or a shorter fast pull predicted past 30%, commits the close.
            let deliberateClose = settledProgress < 0.76
            let fastClose = predictedProgress < 0.70
            return !(deliberateClose || fastClose)
        }

        let deliberateOpen = settledProgress > 0.24
        let fastOpen = predictedProgress > 0.30
        return deliberateOpen || fastOpen
    }

    private func currentRevealHeight(menuHeight: CGFloat) -> CGFloat {
        let resting = isPresented ? menuHeight : 0
        return min(menuHeight, max(0, resting + dragTranslation))
    }

    private func closeMenu() {
        setPresented(false)
    }

    private func setPresented(_ presented: Bool) {
        if isPresented != presented {
            HapticManager.shared.fire(.buttonPress)
        }

        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.18)
            : .timingCurve(0.22, 0.61, 0.36, 1, duration: presented ? 0.45 : 0.30)

        withAnimation(animation) {
            isPresented = presented
            dragTranslation = 0
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct WebMenuTopBar: View {
    let progress: CGFloat
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: topInset)

            ZStack {
                HStack(spacing: 0) {
                    wordmark

                    Spacer()

                    toggleIndicator
                        .frame(width: 44, height: 40)
                }
                .padding(.horizontal, 24)

                VStack(spacing: 3) {
                    Capsule()
                        .fill(progress > 0.01 ? SpyTheme.red : Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255))
                        .frame(width: 32, height: 2)
                    Capsule()
                        .fill(progress > 0.01 ? SpyTheme.red : Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255))
                        .frame(width: 20, height: 2)
                }
                .animation(.easeOut(duration: 0.20), value: progress > 0.01)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 6)
            }
            .frame(height: 80)
            .overlay(alignment: .topLeading) {
                WebCornerMark(edges: [.top, .leading], color: Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255))
                    .frame(width: 16, height: 16)
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                WebCornerMark(edges: [.top, .trailing], color: Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255))
                    .frame(width: 16, height: 16)
                    .padding(8)
            }
        }
        .background(Color.black.opacity(0.97))
        .overlay(alignment: .bottom) {
            ZStack {
                Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
                    .opacity(1 - progress)
                SpyTheme.red.opacity(progress)
            }
            .frame(height: 1)
        }
    }

    private var wordmark: some View {
        SpyWordmark(fontSize: 30)
    }

    private var toggleIndicator: some View {
        ZStack {
            Image(systemName: "chevron.down")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white)
                .opacity(Double(clamp(1 - (progress / 0.10))))

            VStack(spacing: 5) {
                menuLine(threshold: 0)
                menuLine(threshold: 0.33)
                menuLine(threshold: 0.66)
            }
            .frame(width: 20)
            .opacity(Double(clamp((progress - 0.05) / 0.05)))
        }
        .accessibilityHidden(true)
    }

    private func menuLine(threshold: CGFloat) -> some View {
        GeometryReader { proxy in
            let fill = clamp((progress - threshold) / 0.34)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255))
                Capsule()
                    .fill(SpyTheme.red)
                    .frame(width: proxy.size.width * fill)
            }
        }
        .frame(height: 2)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct WebCommandMenuPanel: View {
    @Environment(AppState.self) private var appState

    let progress: CGFloat
    let close: () -> Void

    private let itemHeight: CGFloat = 40
    private let totalItems: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                revealItem(index: 0) {
                    menuButton(
                        icon: "👤",
                        title: localized(en: "PROFILE", ru: "ПРОФИЛЬ", es: "PERFIL"),
                        selected: appState.selectedTab == .profile
                    ) {
                        closeThen { appState.selectedTab = .profile }
                    }
                }

                revealItem(index: 1) {
                    menuButton(
                        icon: "📦",
                        title: localized(en: "WORD-PACKS", ru: "ПАКЕТЫ", es: "PAQUETES"),
                        selected: appState.selectedTab == .packs
                    ) {
                        closeThen { appState.selectedTab = .packs }
                    }
                }

                revealItem(index: 2) {
                    menuButton(
                        icon: "◎",
                        title: localized(en: "COMMUNITY", ru: "СООБЩЕСТВО", es: "COMUNIDAD")
                    ) {
                        closeThen { appState.presentedSheet = .community }
                    }
                }

                revealItem(index: 3) {
                    menuButton(icon: "⚡", title: "LIMITLESS", highlighted: true) {
                        closeThen { appState.presentedSheet = .pricing }
                    }
                }

                revealDivider(index: 4)

                revealItem(index: 5) {
                    menuButton(
                        icon: "🚪",
                        title: localized(en: "LOGOUT", ru: "ВЫХОД", es: "SALIR"),
                        highlighted: true
                    ) {
                        close()
                        appState.logout()
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity, alignment: .center)

            languageFooter
                .opacity(Double(footerProgress))
                .offset(y: 10 * (1 - footerProgress))
        }
        .background(Color.black.opacity(0.97))
        .overlay(alignment: .bottomLeading) {
            WebCornerMark(edges: [.bottom, .leading], color: SpyTheme.red)
                .frame(width: 16, height: 16)
        }
        .overlay(alignment: .bottomTrailing) {
            WebCornerMark(edges: [.bottom, .trailing], color: SpyTheme.red)
                .frame(width: 16, height: 16)
        }
    }

    private func revealItem<Content: View>(index: Int, @ViewBuilder content: () -> Content) -> some View {
        let itemProgress = progressForItem(index)

        return content()
            .frame(height: itemHeight)
            .opacity(Double(itemProgress))
            .offset(x: -20 * (1 - itemProgress))
            .frame(height: itemHeight * itemProgress, alignment: .top)
            .clipped()
    }

    private func revealDivider(index: Int) -> some View {
        let itemProgress = progressForItem(index)

        return Rectangle()
            .fill(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
            .frame(height: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .opacity(Double(itemProgress))
            .frame(height: 17 * itemProgress, alignment: .top)
            .clipped()
    }

    private func menuButton(
        icon: String,
        title: String,
        selected: Bool = false,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(icon)
                    .font(.system(size: 20))
                    .frame(width: 28, alignment: .leading)

                Text(title)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .tracking(3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)
            }
            .foregroundStyle(selected || highlighted ? SpyTheme.red : Color(red: 187 / 255, green: 187 / 255, blue: 187 / 255))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: itemHeight, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(selected ? SpyTheme.red : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private var languageFooter: some View {
        HStack(spacing: 12) {
            Text(localized(en: "LANGUAGE", ru: "ЯЗЫК", es: "IDIOMA"))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color(red: 68 / 255, green: 68 / 255, blue: 68 / 255))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            HStack(spacing: 6) {
                languageButton(.en)
                languageButton(.es)
                languageButton(.ru)
            }

            Spacer()

            Button {
                close()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 32, height: 32)
                    .overlay(Rectangle().stroke(Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(en: "Close menu", ru: "Закрыть меню", es: "Cerrar menu"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255))
                .frame(height: 1)
        }
    }

    private func languageButton(_ language: AppLanguage) -> some View {
        Button {
            guard appState.language != language else { return }
            HapticManager.shared.fire(.tabSelection)
            Task {
                try? await appState.setLanguage(language, syncRemote: appState.user != nil)
            }
        } label: {
            Text(language.shortCode)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(appState.language == language ? .white : Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255))
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(appState.language == language ? SpyTheme.red : Color.clear)
                .overlay(Rectangle().stroke(appState.language == language ? SpyTheme.red : Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private var footerProgress: CGFloat {
        clamp((progress - 0.70) / 0.30)
    }

    private func progressForItem(_ index: Int) -> CGFloat {
        clamp((progress * totalItems) - CGFloat(index))
    }

    private func closeThen(_ action: @escaping @MainActor () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            action()
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct WebCornerMark: View {
    let edges: Edge.Set
    let color: Color

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(alignment: .top) {
                if edges.contains(.top) {
                    Rectangle().fill(color).frame(height: 1)
                }
            }
            .overlay(alignment: .bottom) {
                if edges.contains(.bottom) {
                    Rectangle().fill(color).frame(height: 1)
                }
            }
            .overlay(alignment: .leading) {
                if edges.contains(.leading) {
                    Rectangle().fill(color).frame(width: 1)
                }
            }
            .overlay(alignment: .trailing) {
                if edges.contains(.trailing) {
                    Rectangle().fill(color).frame(width: 1)
                }
            }
            .allowsHitTesting(false)
    }
}
