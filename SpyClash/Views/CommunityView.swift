import SwiftUI
import UIKit
import SocketIO

private struct CommunityProfileSignal: Equatable {
    let profileUserID: String
    let revision: Int
}

private enum CommunityProfileSignalParser {
    static func parse(_ payload: [Any], room: String, recipientUserID: String) -> CommunityProfileSignal? {
        guard let envelope = payload.first as? [String: Any],
              envelope["room"] as? String == room,
              let dataString = envelope["data"] as? String,
              let data = dataString.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["create", "update"].contains(event["type"] as? String),
              let eventData = event["data"] as? [String: Any],
              eventData["recipient_user_id"] as? String == recipientUserID,
              let profileUserID = (eventData["profile_user_id"] as? String)?.nilIfBlank,
              let revision = (eventData["revision"] as? NSNumber)?.intValue else {
            return nil
        }
        return CommunityProfileSignal(profileUserID: profileUserID, revision: revision)
    }
}

@MainActor
private final class CommunityProfileRealtimeService {
    var onSignal: ((CommunityProfileSignal) -> Void)?
    var onCatchUp: (() -> Void)?
    var onNetworkChange: (() -> Void)?

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var room: String?
    private var generation = UUID()
#if SPYCLASH_SUPABASE
    private let socialRealtime = SupabaseSocialRealtimeService()
#endif

    func start(appID: String, token: String, userID: String) {
        stop()
#if SPYCLASH_SUPABASE
        socialRealtime.onChange = { [weak self] signal in
            if signal.table == "app_profile_signals", let profileID = signal.profileUserID {
                self?.onSignal?(CommunityProfileSignal(profileUserID: profileID, revision: signal.revision))
            } else {
                self?.onNetworkChange?()
            }
        }
        socialRealtime.onCatchUp = { [weak self] in self?.onCatchUp?() }
        socialRealtime.start(userID: userID)
        return
#endif
        let room = "entities:\(appID):CommunityProfileSignal"
        let generation = UUID()
        let manager = SocketManager(
            socketURL: URL(string: "https://base44.app")!,
            config: [
                .path("/ws-user-apps/socket.io/"),
                .connectParams(["app_id": appID, "token": token]),
                .forceWebsockets(true),
                .reconnects(true),
                .reconnectAttempts(-1),
                .reconnectWait(1),
                .reconnectWaitMax(8),
                .log(false),
                .handleQueue(.main)
            ]
        )
        let socket = manager.defaultSocket
        socket.on(clientEvent: .connect) { [weak self, weak socket] _, _ in
            guard let self, self.generation == generation else { return }
            socket?.emit("join", room)
            self.onCatchUp?()
        }
        socket.on("update_model") { [weak self] payload, _ in
            guard let self, self.generation == generation,
                  let signal = CommunityProfileSignalParser.parse(payload, room: room, recipientUserID: userID) else { return }
            self.onSignal?(signal)
        }
        self.manager = manager
        self.socket = socket
        self.room = room
        self.generation = generation
        socket.connect()
    }

    func stop() {
#if SPYCLASH_SUPABASE
        socialRealtime.stop()
#endif
        generation = UUID()
        if let room, socket?.status == .connected { socket?.emit("leave", room) }
        socket?.removeAllHandlers()
        socket?.disconnect()
        manager?.disconnect()
        socket = nil
        manager = nil
        room = nil
    }
}

private enum CommunityActionFeedbackPhase: Equatable {
    case waiting
    case success
    case failure
}

private struct CommunityActionFeedback: Equatable {
    let id: String
    var phase: CommunityActionFeedbackPhase
    var waitingTitle: String
    let successTitle: String
}

struct CommunityMeTransitionResolver {
    static func canCommit(selfUserID: String?, activeAction: String?) -> Bool {
        selfUserID?.nilIfBlank != nil && activeAction == nil
    }
}

struct CommunityProfileRequestState: Equatable {
    private(set) var activeRequestID: UUID?

    mutating func begin(_ requestID: UUID = UUID()) -> UUID {
        activeRequestID = requestID
        return requestID
    }

    mutating func invalidate() {
        activeRequestID = nil
    }

    func accepts(_ requestID: UUID) -> Bool {
        activeRequestID == requestID
    }

    func accepts(_ requestID: UUID, signalGeneration: Int, currentSignalGeneration: Int) -> Bool {
        accepts(requestID) && signalGeneration == currentSignalGeneration
    }
}

enum CommunityProfileRelationshipResolver {
    static func resolve(
        profileID: String,
        fallback: CommunityRelationshipSummary?,
        network: CommunityState?
    ) -> CommunityRelationshipSummary? {
        guard let network else { return fallback }
        // A confirmed friendship must win over an old pending profile response
        // or a duplicate request for the same person with a different record ID.
        let record = network.blocked.first { $0.profile.id == profileID }
            ?? network.friends.first { $0.profile.id == profileID }
        guard let record else { return fallback }
        return CommunityRelationshipSummary(
            id: record.id,
            status: record.status,
            direction: record.direction
        )
    }
}

/// An optimistic change only owns one relationship. Rollback restores that
/// relationship without discarding unrelated updates received in the meantime.
struct CommunityOptimisticRelationshipChange: Equatable {
    let actorID: String
    let action: String
    let relationship: CommunityRelationship
    private let previousFriends: [CommunityRelationship]
    private let previousIncoming: [CommunityRelationship]
    private let previousOutgoing: [CommunityRelationship]

    init?(state: CommunityState, action: String, friendshipID: String) {
        let candidates: [CommunityRelationship]
        switch action {
        case "accept", "decline": candidates = state.incoming
        case "remove_friend": candidates = state.friends
        case "cancel_request": candidates = state.outgoing
        default: return nil
        }
        guard let relationship = candidates.first(where: { $0.id == friendshipID }) else { return nil }
        actorID = state.me.id
        self.action = action
        self.relationship = relationship
        previousFriends = state.friends.filter { $0.profile.id == relationship.profile.id }
        previousIncoming = state.incoming.filter { $0.profile.id == relationship.profile.id }
        previousOutgoing = state.outgoing.filter { $0.profile.id == relationship.profile.id }
    }

    func applying(to state: CommunityState) -> CommunityState {
        guard state.me.id == actorID else { return state }
        if let blockedState = preservingBlock(in: state) { return blockedState }
        let targetID = relationship.profile.id
        var friends = state.friends
        if action == "accept" || action == "remove_friend" {
            friends.removeAll { $0.profile.id == targetID }
        }
        if action == "accept" {
            friends.append(CommunityRelationship(id: relationship.id, status: "accepted",
                                                 direction: relationship.direction, profile: relationship.profile))
        }
        let incoming = state.incoming.filter {
            action == "accept" ? $0.profile.id != targetID : !(action == "decline" && $0.id == relationship.id)
        }
        let outgoing = state.outgoing.filter {
            action == "accept" ? $0.profile.id != targetID : !(action == "cancel_request" && $0.id == relationship.id)
        }
        return CommunityState(me: state.me, friends: friends,
                              incoming: incoming, outgoing: outgoing,
                              blocked: state.blocked, incomingRoomInvites: state.incomingRoomInvites)
    }

    func rollingBack(in state: CommunityState) -> CommunityState {
        guard state.me.id == actorID else { return state }
        if let blockedState = preservingBlock(in: state) { return blockedState }
        let targetID = relationship.profile.id
        return CommunityState(me: state.me,
                              friends: state.friends.filter { $0.profile.id != targetID } + previousFriends,
                              incoming: state.incoming.filter { $0.profile.id != targetID } + previousIncoming,
                              outgoing: state.outgoing.filter { $0.profile.id != targetID } + previousOutgoing,
                              blocked: state.blocked, incomingRoomInvites: state.incomingRoomInvites)
    }

    private func preservingBlock(in state: CommunityState) -> CommunityState? {
        let targetID = relationship.profile.id
        guard state.blocked.contains(where: { $0.profile.id == targetID }) else { return nil }
        return CommunityState(me: state.me,
                              friends: state.friends.filter { $0.profile.id != targetID },
                              incoming: state.incoming.filter { $0.profile.id != targetID },
                              outgoing: state.outgoing.filter { $0.profile.id != targetID },
                              blocked: state.blocked, incomingRoomInvites: state.incomingRoomInvites)
    }
}

struct CommunityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    @Binding var selectedTab: CommunityTab
    let dockRequest: CommunityDockRequest
    let externalNetworkState: CommunityState?
    let onAttentionChange: (CommunityState) -> Void
    let onExit: () -> Void
    var initialProfileUserID: String? = nil

    @State private var network: CommunityState?
    @State private var directory: [PublicSpyProfile] = []
    @State private var nextDirectoryOffset: Int?
    @State private var query = ""
    @State private var activeProfile: CommunityProfileDetail?
    @State private var profileCache: [String: CommunityProfileDetail] = [:]
    @State private var profileRequestState = CommunityProfileRequestState()
    @State private var profileHistory: [String] = []
    @State private var commentDraft = ""
    @State private var isInitialLoading = true
    @State private var isDirectoryLoading = false
    @State private var directoryLoadFailed = false
    @State private var isProfileLoading = false
    @State private var didLoadInitialContent = false
    @State private var activeAction: String?
    @State private var isSelfProfileTransitionPending = false
    @State private var actionFeedback: CommunityActionFeedback?
    @State private var deferredExternalNetworkState: CommunityState?
    @State private var resolvedRelationshipIDs: Set<String> = []
    @State private var resolvedRoomInviteIDs: Set<String> = []
    @State private var networkRefreshGeneration = 0
    @State private var mutationGeneration = UUID()
    @State private var optimisticRelationship: CommunityOptimisticRelationshipChange?
    @State private var optimisticDeclinedInviteID: String?
    @State private var realtimeRefreshTask: Task<Void, Never>?
    @State private var realtimeRefreshID = UUID()
    @State private var directoryRequestID: UUID?
    @State private var realtimeRefreshRequested = false
    @State private var realtimeDirectoryRefreshRequested = false
    @State private var profileRefreshPending = false
    @State private var message = ""
    @State private var messageKind: AppToastKind = .success
    @State private var reportTarget: CommunityReportTarget?
    @State private var blockTarget: PublicSpyProfile?
    @State private var unblockTarget: CommunityRelationship?
    @State private var profileRealtime = CommunityProfileRealtimeService()
    @State private var latestProfileRevisions: [String: Int] = [:]
    @State private var profileSignalGenerations: [String: Int] = [:]

    var body: some View {
        PageChrome(
            eyebrow: localized(en: "// COMMUNITY", ru: "// СООБЩЕСТВО", es: "// COMUNIDAD", uk: "// СПІЛЬНОТА"),
            status: localized(en: "OPERATIVE NETWORK", ru: "СЕТЬ ОПЕРАТИВНИКОВ", es: "RED DE OPERATIVOS", uk: "МЕРЕЖА ОПЕРАТИВНИКІВ")
        ) {
            sceneContent
                .padding(.horizontal, 18)
                .padding(.top, 14)
        }
        .background(SpyTheme.black)
        .task {
            let generation = mutationGeneration
            // The shell keeps the last Community dock selection. Re-entering
            // on Me therefore needs the same deferred transition as a cold
            // swipe before network.me has arrived.
            if selectedTab == .me {
                isSelfProfileTransitionPending = true
            }
            if let initialProfileUserID {
                await openProfile(initialProfileUserID, rememberingCurrent: false)
                if !appState.shouldUsePreviewData {
                    await loadInitialNetwork()
                }
                guard !Task.isCancelled, mutationGeneration == generation else { return }
                isInitialLoading = false
                didLoadInitialContent = true
            } else {
                await loadInitialContent()
            }
            guard !Task.isCancelled, mutationGeneration == generation else { return }
            startProfileRealtime()
            await completePendingSelfProfileTransitionIfPossible()
        }
        .onDisappear { stopProfileRealtime() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startProfileRealtime() }
            else { stopProfileRealtime() }
        }
        .task(id: profileRefreshTaskKey) {
            guard let scope = profileRefreshTaskKey else { return }
            while !Task.isCancelled, profileRefreshTaskKey == scope {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard !Task.isCancelled, profileRefreshTaskKey == scope else { return }
                await refreshVisibleProfile()
            }
        }
        .onChange(of: dockRequest.id) { _, _ in
            handleDockAction(dockRequest.tab)
        }
        .onChange(of: externalNetworkState) { _, state in
            guard let state, appState.shouldUsePreviewData || state.me.id == appState.user?.id else { return }
            if activeAction == nil {
                retireResolvedMarkersConfirmed(by: state)
            }
            let sanitizedState = sanitizedNetworkState(state)
            guard sanitizedState != network else { return }
            networkRefreshGeneration += 1
            guard activeAction == nil else {
                deferredExternalNetworkState = sanitizedState
                return
            }
            network = sanitizedState
            reconcileActiveProfileRelationship()
        }
        .onChange(of: network) { _, state in
            if let state {
                onAttentionChange(state)
            }
            Task { await completePendingSelfProfileTransitionIfPossible() }
        }
        .onChange(of: activeAction) { _, action in
            guard action == nil else { return }
            if deferredExternalNetworkState != nil { reconcileNetworkAfterAction() }
            if profileRefreshPending { Task { await refreshVisibleProfile() } }
            Task { await completePendingSelfProfileTransitionIfPossible() }
        }
        .onChange(of: appState.user?.id) { _, _ in
            mutationGeneration = UUID()
            networkRefreshGeneration += 1
            activeAction = nil
            actionFeedback = nil
            optimisticRelationship = nil
            optimisticDeclinedInviteID = nil
            profileRefreshPending = false
            deferredExternalNetworkState = nil
            resolvedRelationshipIDs.removeAll()
            resolvedRoomInviteIDs.removeAll()
            profileCache.removeAll()
            latestProfileRevisions.removeAll()
            profileSignalGenerations.removeAll()
            profileRequestState.invalidate()
            isProfileLoading = false
            activeProfile = nil
            network = nil
            directory = []
            directoryRequestID = nil
            isDirectoryLoading = false
            profileRealtime.stop()
            realtimeRefreshTask?.cancel()
            realtimeRefreshTask = nil
            realtimeRefreshRequested = false
            realtimeDirectoryRefreshRequested = false
            let generation = mutationGeneration
            Task {
                await refreshProfilesAfterAccountChange()
                guard !Task.isCancelled, mutationGeneration == generation else { return }
                startProfileRealtime()
            }
        }
        .onChange(of: message) { _, newMessage in
            publishCommunityToast(newMessage)
        }
        .task(id: query) {
            guard didLoadInitialContent else { return }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await loadDirectory(reset: true)
        }
        .confirmationDialog(
            localized(en: "REPORT CONTENT", ru: "ПОЖАЛОВАТЬСЯ", es: "REPORTAR CONTENIDO", uk: "ПОВІДОМИТИ ПРО ПОРУШЕННЯ"),
            isPresented: reportPromptPresented,
            titleVisibility: .visible,
            presenting: reportTarget
        ) { target in
            ForEach(CommunityReportReason.allCases) { reason in
                Button(reportReasonTitle(reason)) {
                    reportTarget = nil
                    Task { await submitReport(target, reason: reason) }
                }
            }
            Button(localized(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR", uk: "СКАСУВАТИ"), role: .cancel) {
                reportTarget = nil
            }
        } message: { target in
            Text(reportPromptMessage(target))
        }
        .confirmationDialog(
            localized(en: "BLOCK OPERATIVE?", ru: "ЗАБЛОКИРОВАТЬ?", es: "BLOQUEAR OPERATIVO?", uk: "ЗАБЛОКУВАТИ ОПЕРАТИВНИКА?"),
            isPresented: blockPromptPresented,
            titleVisibility: .visible,
            presenting: blockTarget
        ) { target in
            Button(localized(en: "BLOCK AND REMOVE CONTACT", ru: "ЗАБЛОКИРОВАТЬ И УДАЛИТЬ СВЯЗЬ", es: "BLOQUEAR Y ELIMINAR CONTACTO", uk: "ЗАБЛОКУВАТИ Й ВИДАЛИТИ КОНТАКТ"), role: .destructive) {
                blockTarget = nil
                Task { await blockOperative(target) }
            }
            Button(localized(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR", uk: "СКАСУВАТИ"), role: .cancel) {
                blockTarget = nil
            }
        } message: { target in
            Text(localized(
                en: "You and \(target.displayName) will no longer find or open each other's profiles, comment, or send room invites. Existing comments and invites between you are removed.",
                ru: "Вы с \(target.displayName) больше не сможете находить профили друг друга, оставлять записи или отправлять приглашения. Существующие записи и приглашения будут удалены.",
                es: "Tu y \(target.displayName) dejaran de encontrar o abrir sus perfiles, comentar o enviar invitaciones. Se eliminaran los comentarios e invitaciones existentes.",
                uk: "Ви з \(target.displayName) більше не зможете знаходити чи відкривати профілі одне одного, залишати дописи або надсилати запрошення до кімнат. Ваші наявні дописи й запрошення буде видалено."
            ))
        }
        .confirmationDialog(
            localized(en: "UNBLOCK OPERATIVE?", ru: "РАЗБЛОКИРОВАТЬ?", es: "DESBLOQUEAR OPERATIVO?", uk: "РОЗБЛОКУВАТИ ОПЕРАТИВНИКА?"),
            isPresented: unblockPromptPresented,
            titleVisibility: .visible,
            presenting: unblockTarget
        ) { relationship in
            Button(localized(en: "UNBLOCK", ru: "РАЗБЛОКИРОВАТЬ", es: "DESBLOQUEAR", uk: "РОЗБЛОКУВАТИ")) {
                unblockTarget = nil
                Task { await unblockOperative(relationship) }
            }
            Button(localized(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR", uk: "СКАСУВАТИ"), role: .cancel) {
                unblockTarget = nil
            }
        } message: { relationship in
            Text(localized(
                en: "\(relationship.profile.displayName) may find and contact you in Community again.",
                ru: "\(relationship.profile.displayName) снова сможет найти вас и связаться через Сообщество.",
                es: "\(relationship.profile.displayName) podra encontrarte y contactarte en Comunidad otra vez.",
                uk: "\(relationship.profile.displayName) знову зможе знайти тебе та зв’язатися через Спільноту."
            ))
        }
    }

    private var reportPromptPresented: Binding<Bool> {
        Binding(
            get: { reportTarget != nil },
            set: { if !$0 { reportTarget = nil } }
        )
    }

    private var blockPromptPresented: Binding<Bool> {
        Binding(
            get: { blockTarget != nil },
            set: { if !$0 { blockTarget = nil } }
        )
    }

    private var unblockPromptPresented: Binding<Bool> {
        Binding(
            get: { unblockTarget != nil },
            set: { if !$0 { unblockTarget = nil } }
        )
    }

    @ViewBuilder
    private var sceneContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let feedback = actionFeedback, feedback.phase == .waiting {
                HStack(spacing: 9) {
                    SpySpinner(size: 14, accent: SpyTheme.amber)
                    Text(feedback.waitingTitle)
                        .font(SpyTheme.micro)
                        .foregroundStyle(SpyTheme.amber)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("community.pendingAction")
            }
            if let activeProfile {
                profileScene(activeProfile)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if let initialProfileUserID {
                if isInitialLoading || isProfileLoading {
                    SpySpinner(size: 28, accent: SpyTheme.red)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    Button {
                        Task { await openProfile(initialProfileUserID, rememberingCurrent: false) }
                    } label: {
                        Label(localized(en: "RETRY PROFILE", ru: "ЗАГРУЗИТЬ ПРОФИЛЬ ПОВТОРНО", es: "REINTENTAR PERFIL", uk: "ЗАВАНТАЖИТИ ПРОФІЛЬ ПОВТОРНО"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SpyButtonStyle(variant: .outline))
                }
            } else {
                directoryScene
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.smooth(duration: 0.24), value: activeProfile?.profile.id)
    }

    private func publishCommunityToast(_ newMessage: String) {
        guard !newMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard message == newMessage else { return }
            appState.showToast(newMessage, kind: messageKind)
            message = ""
        }
    }

    private var directoryScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                SpySceneKicker(
                    title: localized(en: "PUBLIC DIRECTORY", ru: "ПУБЛИЧНЫЙ КАТАЛОГ", es: "DIRECTORIO PÚBLICO", uk: "ПУБЛІЧНИЙ КАТАЛОГ"),
                    status: localized(en: "DISCOVER", ru: "ПОИСК", es: "DESCUBRIR", uk: "ПОШУК"),
                    accent: SpyTheme.red
                )

                Text(localized(
                    en: "FIND YOUR NEXT OPERATIVE",
                    ru: "НАЙДИ СВОЕГО ОПЕРАТИВНИКА",
                    es: "ENCUENTRA TU OPERATIVO",
                    uk: "ЗНАЙДИ НОВОГО ОПЕРАТИВНИКА"
                ))
                .font(SpyTheme.brandFont(size: 29))
                .tracking(0.8)
                .foregroundStyle(.white)
                .spyFitted(lines: 2, scale: 0.68)

                Text(localized(
                    en: "Search by callsign or SPYID. Every card is the operative's real public identity.",
                    ru: "Ищи по позывному или SPYID. Каждая карточка — настоящая публичная личность игрока.",
                    es: "Busca por alias o SPYID. Cada tarjeta es la identidad pública real del jugador.",
                    uk: "Шукай за позивним або SPYID. Кожна картка показує справжній публічний профіль оперативника."
                ))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(SpyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .spyWebEntrance(delay: 0.02, duration: 0.40, y: 10)

            incomingAttentionSections

            searchField

            HStack {
                Text(localized(en: "OPERATIVES", ru: "ОПЕРАТИВНИКИ", es: "OPERATIVOS", uk: "ОПЕРАТИВНИКИ"))
                    .font(SpyTheme.micro)
                    .tracking(1.2)
                    .foregroundStyle(SpyTheme.dim)

                Spacer()

                Text("\(directory.count)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyTheme.red)
            }

            if directory.isEmpty, !isDirectoryLoading, !isInitialLoading {
                if directoryLoadFailed {
                    directoryUnavailable
                } else {
                    emptyDirectory
                }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(Array(directory.enumerated()), id: \.element.id) { index, profile in
                        Button {
                            Task {
                                await openProfile(
                                    profile.id,
                                    rememberingCurrent: false,
                                    placeholder: profile
                                )
                            }
                        } label: {
                            CommunitySpyCard(profile: profile, language: appState.language, size: .compact)
                        }
                        .buttonStyle(SpyWebPressStyle(pressedScale: 0.985))
                        .accessibilityHint(localized(en: "Open public profile", ru: "Открыть публичный профиль", es: "Abrir perfil publico", uk: "Відкрити публічний профіль"))
                        .spyWebEntrance(delay: min(Double(index) * 0.035, 0.24), duration: 0.42, y: 12, scale: 0.99)
                    }
                }
            }

            if isDirectoryLoading || isInitialLoading {
                HStack(spacing: 9) {
                    SpySpinner(size: 16, accent: SpyTheme.red)
                    Text(localized(en: "SCANNING NETWORK", ru: "СКАНИРОВАНИЕ СЕТИ", es: "ESCANEANDO RED", uk: "СКАНУВАННЯ МЕРЕЖІ"))
                        .font(SpyTheme.micro)
                        .tracking(0.8)
                        .foregroundStyle(SpyTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            } else if let nextDirectoryOffset {
                Button {
                    Task { await loadDirectory(reset: false, offset: nextDirectoryOffset) }
                } label: {
                    commandLabel(
                        localized(en: "LOAD MORE OPERATIVES", ru: "ЗАГРУЗИТЬ ЕЩЕ", es: "CARGAR MAS", uk: "ЗАВАНТАЖИТИ ЩЕ"),
                        icon: "arrow.down"
                    )
                }
                .buttonStyle(SpyButtonStyle(variant: .ghost))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(query.isEmpty ? SpyTheme.muted : SpyTheme.red)
                .accessibilityHidden(true)

            TextField(
                localized(en: "CALLSIGN OR 000-000", ru: "ПОЗЫВНОЙ ИЛИ 000-000", es: "ALIAS O 000-000", uk: "ПОЗИВНИЙ АБО 000-000"),
                text: $query
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .submitLabel(.search)
            .accessibilityLabel(localized(
                en: "Search operatives",
                ru: "Поиск оперативников",
                es: "Buscar operativos",
                uk: "Пошук оперативників"
            ))

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SpyTheme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized(en: "Clear search", ru: "Очистить поиск", es: "Borrar busqueda", uk: "Очистити пошук"))
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, query.isEmpty ? 15 : 4)
        .frame(minHeight: 56)
        .background(SpyTheme.panel)
        .overlay(CutCornerShape(cut: 9).stroke(query.isEmpty ? SpyTheme.strokeStrong : SpyTheme.red.opacity(0.62), lineWidth: 1))
        .clipShape(CutCornerShape(cut: 9))
        .shadow(color: query.isEmpty ? .clear : SpyTheme.red.opacity(0.10), radius: 12)
    }

    private var emptyDirectory: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(SpyTheme.faint)

            Text(localized(en: "NO OPERATIVES FOUND", ru: "ОПЕРАТИВНИКИ НЕ НАЙДЕНЫ", es: "NO SE ENCONTRARON OPERATIVOS", uk: "ОПЕРАТИВНИКІВ НЕ ЗНАЙДЕНО"))
                .font(SpyTheme.micro)
                .tracking(0.8)
                .foregroundStyle(SpyTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private var directoryUnavailable: some View {
        VStack(spacing: 13) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(SpyTheme.red)

            Text(localized(
                en: "OPERATIVE NETWORK TEMPORARILY UNAVAILABLE",
                ru: "СЕТЬ ОПЕРАТИВНИКОВ ВРЕМЕННО НЕДОСТУПНА",
                es: "RED DE OPERATIVOS TEMPORALMENTE NO DISPONIBLE",
                uk: "МЕРЕЖА ОПЕРАТИВНИКІВ ТИМЧАСОВО НЕДОСТУПНА"
            ))
            .font(SpyTheme.micro)
            .tracking(0.7)
            .multilineTextAlignment(.center)
            .foregroundStyle(SpyTheme.muted)

            Button {
                Task { await retryInitialContent() }
            } label: {
                commandLabel(
                    localized(en: "RETRY NETWORK", ru: "ПОВТОРИТЬ", es: "REINTENTAR", uk: "СПРОБУВАТИ ЗНОВУ"),
                    icon: "arrow.clockwise"
                )
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 176)
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.red.opacity(0.38), lineWidth: 1))
    }

    private func profileScene(_ detail: CommunityProfileDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            profileNavigation(detail)

            CommunitySpyCard(profile: detail.profile, language: appState.language)
                .spyWebEntrance(delay: 0, duration: 0.30, y: 8, scale: 0.992)

            if isProfileLoading {
                HStack(spacing: 10) {
                    SpySpinner(size: 18, accent: SpyTheme.red)
                    Text(localized(en: "SYNCING SOCIAL INTEL", ru: "СИНХРОНИЗАЦИЯ СВЯЗЕЙ", es: "SINCRONIZANDO RED", uk: "СИНХРОНІЗАЦІЯ КОНТАКТІВ"))
                        .font(SpyTheme.micro)
                        .tracking(0.8)
                        .foregroundStyle(SpyTheme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke, lineWidth: 1))
                .transition(.opacity)
            } else {
                if detail.isSelf {
                    ownNetworkSections(detail)
                } else {
                    relationshipCommands(detail)
                }

                friendsSection(detail)
                commentsSection(detail)
            }
        }
    }

    private func profileNavigation(_ detail: CommunityProfileDetail) -> some View {
        HStack(spacing: 12) {
            if !detail.isSelf || !profileHistory.isEmpty {
                Button {
                    Task { await returnFromProfile() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(SpyTheme.red)
                        .frame(width: 46, height: 46)
                        .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.red.opacity(0.42), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityLabel(localized(en: "Back to community", ru: "Назад в сообщество", es: "Volver a comunidad", uk: "Назад до Спільноти"))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(detail.isSelf
                    ? localized(en: "MY PUBLIC PROFILE", ru: "МОЙ ПУБЛИЧНЫЙ ПРОФИЛЬ", es: "MI PERFIL PÚBLICO", uk: "МІЙ ПУБЛІЧНИЙ ПРОФІЛЬ")
                    : localized(en: "PUBLIC DOSSIER", ru: "ПУБЛИЧНОЕ ДОСЬЕ", es: "EXPEDIENTE PÚBLICO", uk: "ПУБЛІЧНЕ ДОСЬЄ"))
                    .font(SpyTheme.brandFont(size: 23))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .spyFitted()

                Text(detail.profile.spyID)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(SpyTheme.red)
            }

            Spacer(minLength: 4)
        }
    }

    private func resolvedRelationship(for detail: CommunityProfileDetail) -> CommunityRelationshipSummary? {
        CommunityProfileRelationshipResolver.resolve(
            profileID: detail.profile.id,
            fallback: detail.relationship,
            network: network
        )
    }

    @ViewBuilder
    private func relationshipCommands(_ detail: CommunityProfileDetail) -> some View {
        let relationship = resolvedRelationship(for: detail)
        SpyPanel(accent: relationshipAccent(relationship), motionDelay: 0.05) {
            VStack(alignment: .leading, spacing: 11) {
                SpySceneKicker(
                    title: localized(en: "CONNECTION", ru: "СВЯЗЬ", es: "CONEXION", uk: "ЗВ’ЯЗОК"),
                    status: relationshipTitle(relationship),
                    accent: relationshipAccent(relationship)
                )

                relationshipButtons(detail)

                HStack(spacing: 9) {
                    communityActionButton(
                        localized(en: "REPORT", ru: "ЖАЛОБА", es: "REPORTAR", uk: "ПОСКАРЖИТИСЯ"),
                        icon: "flag.fill",
                        color: SpyTheme.amber
                    ) {
                        reportTarget = .user(detail.profile)
                    }

                    communityActionButton(
                        localized(en: "BLOCK", ru: "БЛОКИРОВАТЬ", es: "BLOQUEAR", uk: "ЗАБЛОКУВАТИ"),
                        icon: "person.crop.circle.badge.xmark",
                        color: SpyTheme.red
                    ) {
                        blockTarget = detail.profile
                    }
                }

                if let room = inviteRoom(for: detail) {
                    communityActionButton(
                        localized(en: "INVITE TO ROOM \(room.code)", ru: "ПРИГЛАСИТЬ В КОМНАТУ \(room.code)", es: "INVITAR A SALA \(room.code)", uk: "ЗАПРОСИТИ ДО КІМНАТИ \(room.code)"),
                        icon: "paperplane.fill", color: SpyTheme.red, filled: true,
                        feedbackID: "invite-\(detail.profile.id)",
                        waitingTitle: localized(en: "SENDING INVITE...", ru: "ОТПРАВЛЯЕМ ПРИГЛАШЕНИЕ...", es: "ENVIANDO INVITACIÓN...", uk: "НАДСИЛАЄМО ЗАПРОШЕННЯ..."),
                        successTitle: localized(en: "INVITE SENT", ru: "ПРИГЛАШЕНИЕ ОТПРАВЛЕНО", es: "INVITACIÓN ENVIADA", uk: "ЗАПРОШЕННЯ НАДІСЛАНО")
                    ) {
                        await inviteToRoom(detail.profile, room: room)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relationshipButtons(_ detail: CommunityProfileDetail) -> some View {
        let relationship = resolvedRelationship(for: detail)

        if relationship == nil || relationship?.status == "declined" {
            communityActionButton(
                localized(en: "ADD OPERATIVE", ru: "ДОБАВИТЬ В ДРУЗЬЯ", es: "AGREGAR OPERATIVO", uk: "ДОДАТИ ОПЕРАТИВНИКА"),
                icon: "person.badge.plus",
                color: SpyTheme.red,
                filled: true,
                feedbackID: "friend-\(detail.profile.id)",
                waitingTitle: localized(en: "SENDING REQUEST...", ru: "ОТПРАВЛЯЕМ ЗАПРОС...", es: "ENVIANDO SOLICITUD...", uk: "НАДСИЛАЄМО ЗАПИТ..."),
                successTitle: localized(en: "REQUEST SENT", ru: "ЗАПРОС ОТПРАВЛЕН", es: "SOLICITUD ENVIADA", uk: "ЗАПИТ НАДІСЛАНО")
            ) {
                await sendFriendRequest(to: detail.profile.id)
            }
        } else if relationship?.status == "accepted" {
            HStack(spacing: 9) {
                connectionStatus(
                    localized(en: "FRIENDS", ru: "В ДРУЗЬЯХ", es: "AMIGOS", uk: "У ДРУЗЯХ"),
                    icon: "checkmark.circle.fill",
                    color: SpyTheme.green
                )

                communityActionButton(
                    localized(en: "REMOVE", ru: "УДАЛИТЬ", es: "ELIMINAR", uk: "ВИДАЛИТИ"),
                    icon: "person.badge.minus",
                    color: SpyTheme.muted,
                    feedbackID: relationship.map { relationshipFeedbackID("remove_friend", $0.id) },
                    waitingTitle: localized(en: "REMOVING...", ru: "УДАЛЯЕМ...", es: "ELIMINANDO...", uk: "ВИДАЛЯЄМО..."),
                    successTitle: localized(en: "REMOVED", ru: "УДАЛЕНО", es: "ELIMINADO", uk: "ВИДАЛЕНО")
                ) {
                    guard let relationship else { return }
                    await relationshipAction("remove_friend", relationship.id)
                }
            }
        } else if let relationship, relationship.status == "pending", relationship.direction == "incoming" {
            HStack(spacing: 9) {
                communityActionButton(
                    localized(en: "ACCEPT", ru: "ПРИНЯТЬ", es: "ACEPTAR", uk: "ПРИЙНЯТИ"),
                    icon: "checkmark",
                    color: SpyTheme.green,
                    filled: true,
                    feedbackID: relationshipFeedbackID("accept", relationship.id),
                    waitingTitle: localized(en: "ACCEPTING...", ru: "ПРИНИМАЕМ...", es: "ACEPTANDO...", uk: "ПРИЙМАЄМО..."),
                    successTitle: localized(en: "ACCEPTED", ru: "ПРИНЯТО", es: "ACEPTADO", uk: "ПРИЙНЯТО")
                ) {
                    await relationshipDecision("accept", relationship.id)
                }

                communityActionButton(
                    localized(en: "DECLINE", ru: "ОТКЛОНИТЬ", es: "RECHAZAR", uk: "ВІДХИЛИТИ"),
                    icon: "xmark",
                    color: SpyTheme.muted,
                    feedbackID: relationshipFeedbackID("decline", relationship.id),
                    waitingTitle: localized(en: "DECLINING...", ru: "ОТКЛОНЯЕМ...", es: "RECHAZANDO...", uk: "ВІДХИЛЯЄМО..."),
                    successTitle: localized(en: "DECLINED", ru: "ОТКЛОНЕНО", es: "RECHAZADO", uk: "ВІДХИЛЕНО")
                ) {
                    await relationshipDecision("decline", relationship.id)
                }
            }
        } else if let relationship, relationship.status == "pending" {
            HStack(spacing: 9) {
                connectionStatus(
                    localized(en: "REQUEST SENT", ru: "ЗАПРОС ОТПРАВЛЕН", es: "SOLICITUD ENVIADA", uk: "ЗАПИТ НАДІСЛАНО"),
                    icon: "clock",
                    color: SpyTheme.amber
                )

                communityActionButton(
                    localized(en: "CANCEL", ru: "ОТМЕНИТЬ", es: "CANCELAR", uk: "СКАСУВАТИ"),
                    icon: "xmark",
                    color: SpyTheme.muted,
                    feedbackID: relationshipFeedbackID("cancel_request", relationship.id),
                    waitingTitle: localized(en: "CANCELLING...", ru: "ОТМЕНЯЕМ...", es: "CANCELANDO...", uk: "СКАСОВУЄМО..."),
                    successTitle: localized(en: "CANCELLED", ru: "ОТМЕНЕНО", es: "CANCELADO", uk: "СКАСОВАНО")
                ) {
                    await relationshipAction("cancel_request", relationship.id)
                }
            }
        }
    }

    @ViewBuilder
    private func ownNetworkSections(_ detail: CommunityProfileDetail) -> some View {
        incomingAttentionSections

        if let network, !network.blocked.isEmpty {
            SpyPanel(accent: SpyTheme.muted, motionDelay: 0.10) {
                VStack(alignment: .leading, spacing: 10) {
                    SpySceneKicker(
                        title: localized(en: "BLOCKED OPERATIVES", ru: "ЗАБЛОКИРОВАННЫЕ", es: "OPERATIVOS BLOQUEADOS", uk: "ЗАБЛОКОВАНІ ОПЕРАТИВНИКИ"),
                        status: "\(network.blocked.count)",
                        accent: SpyTheme.muted
                    )

                    ForEach(network.blocked) { relationship in
                        blockedOperativeRow(relationship)
                    }
                }
            }
        }

        if detail.friends.isEmpty, network?.incoming.isEmpty != false, network?.incomingRoomInvites.isEmpty != false {
            Text(localized(
                en: "YOUR PUBLIC PROFILE IS LIVE. OPERATIVES CAN FIND IT IN THE COMMUNITY DIRECTORY.",
                ru: "ТВОЙ ПУБЛИЧНЫЙ ПРОФИЛЬ АКТИВЕН. ОПЕРАТИВНИКИ МОГУТ НАЙТИ ЕГО В КАТАЛОГЕ.",
                es: "TU PERFIL PÚBLICO ESTÁ ACTIVO. LOS OPERATIVOS PUEDEN ENCONTRARLO EN EL DIRECTORIO.",
                uk: "ТВІЙ ПУБЛІЧНИЙ ПРОФІЛЬ АКТИВНИЙ. ОПЕРАТИВНИКИ МОЖУТЬ ЗНАЙТИ ЙОГО В КАТАЛОЗІ СПІЛЬНОТИ."
            ))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(SpyTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var incomingAttentionSections: some View {
        if let network, !network.incomingRoomInvites.isEmpty {
            SpyPanel(accent: SpyTheme.red, motionDelay: 0.05) {
                VStack(alignment: .leading, spacing: 10) {
                    SpySceneKicker(
                        title: localized(en: "ROOM INVITES", ru: "ПРИГЛАШЕНИЯ В КОМНАТУ", es: "INVITACIONES A SALA", uk: "ЗАПРОШЕННЯ ДО КІМНАТ"),
                        status: "\(network.incomingRoomInvites.count)",
                        accent: SpyTheme.red
                    )

                    ForEach(network.incomingRoomInvites) { invite in
                        roomInviteRow(invite)
                    }
                }
            }
        }

        if let network, !network.incoming.isEmpty {
            SpyPanel(accent: SpyTheme.amber, motionDelay: 0.08) {
                VStack(alignment: .leading, spacing: 10) {
                    SpySceneKicker(
                        title: localized(en: "FRIEND REQUESTS", ru: "ЗАПРОСЫ В ДРУЗЬЯ", es: "SOLICITUDES DE AMISTAD", uk: "ЗАПИТИ В ДРУЗІ"),
                        status: "\(network.incoming.count)",
                        accent: SpyTheme.amber
                    )

                    ForEach(network.incoming) { record in
                        incomingFriendRow(record)
                    }
                }
            }
        }
    }

    private func friendsSection(_ detail: CommunityProfileDetail) -> some View {
        SpyPanel(motionDelay: 0.10) {
            VStack(alignment: .leading, spacing: 10) {
                SpySceneKicker(
                    title: detail.isSelf
                        ? localized(en: "MY FRIENDS", ru: "МОИ ДРУЗЬЯ", es: "MIS AMIGOS", uk: "МОЇ ДРУЗІ")
                        : localized(en: "FRIENDS", ru: "ДРУЗЬЯ", es: "AMIGOS", uk: "ДРУЗІ"),
                    status: "\(detail.friends.count)",
                    accent: SpyTheme.muted
                )

                if detail.friends.isEmpty {
                    Text(localized(en: "NO PUBLIC CONNECTIONS YET", ru: "ПОКА НЕТ ПУБЛИЧНЫХ СВЯЗЕЙ", es: "AÚN NO HAY CONEXIONES PÚBLICAS", uk: "ПУБЛІЧНИХ ЗВ’ЯЗКІВ ЩЕ НЕМАЄ"))
                        .font(SpyTheme.micro)
                        .tracking(0.6)
                        .foregroundStyle(SpyTheme.faint)
                        .frame(minHeight: 48)
                } else {
                    ForEach(detail.friends) { friend in
                        operativeRow(friend) {
                            Task {
                                await openProfile(
                                    friend.id,
                                    rememberingCurrent: true,
                                    placeholder: friend
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func commentsSection(_ detail: CommunityProfileDetail) -> some View {
        SpyPanel(accent: SpyTheme.red.opacity(0.72), motionDelay: 0.14) {
            VStack(alignment: .leading, spacing: 11) {
                SpySceneKicker(
                    title: localized(en: "PROFILE WALL", ru: "СТЕНА ПРОФИЛЯ", es: "MURO DEL PERFIL", uk: "СТІНА ПРОФІЛЮ"),
                    status: "\(detail.comments.count)",
                    accent: SpyTheme.red
                )

                if detail.comments.isEmpty {
                    Text(localized(
                        en: "NO FIELD NOTES YET",
                        ru: "ПОКА НЕТ ЗАПИСЕЙ",
                        es: "AUN NO HAY NOTAS",
                        uk: "ДОПИСІВ ЩЕ НЕМАЄ"
                    ))
                    .font(SpyTheme.micro)
                    .tracking(0.6)
                    .foregroundStyle(SpyTheme.faint)
                    .frame(minHeight: 44)
                } else {
                    ForEach(detail.comments) { comment in
                        commentRow(comment)
                    }
                }

                if !detail.isSelf {
                    commentComposer(target: detail.profile)

                    Text(localized(
                        en: "KEEP FIELD NOTES SAFE. OBJECTIONABLE CONTENT IS FILTERED; USE REPORT OR BLOCK FOR ABUSE.",
                        ru: "СОБЛЮДАЙ ПРАВИЛА. НЕДОПУСТИМЫЙ КОНТЕНТ ФИЛЬТРУЕТСЯ; ДЛЯ НАРУШЕНИЙ ИСПОЛЬЗУЙ ЖАЛОБУ ИЛИ БЛОКИРОВКУ.",
                        es: "MANTEN LAS NOTAS SEGURAS. EL CONTENIDO INACEPTABLE SE FILTRA; USA REPORTAR O BLOQUEAR.",
                        uk: "ДОТРИМУЙСЯ ПРАВИЛ. НЕПРИПУСТИМИЙ ВМІСТ ФІЛЬТРУЄТЬСЯ; У РАЗІ ПОРУШЕНЬ НАДІШЛИ СКАРГУ АБО ЗАБЛОКУЙ КОРИСТУВАЧА."
                    ))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.35)
                    .foregroundStyle(SpyTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func commentComposer(target: PublicSpyProfile) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField(
                localized(en: "Leave a field note...", ru: "Оставить запись...", es: "Dejar una nota...", uk: "Залишити допис..."),
                text: $commentDraft,
                axis: .vertical
            )
            .lineLimit(2...4)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(13)
            .frame(minHeight: 58, alignment: .topLeading)
            .background(SpyTheme.black.opacity(0.76))
            .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.inputBorder, lineWidth: 1))
            .clipShape(CutCornerShape(cut: 7))
            .onChange(of: commentDraft) { _, value in
                if value.count > 280 { commentDraft = String(value.prefix(280)) }
            }

            HStack {
                Text("\(commentDraft.count)/280")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(SpyTheme.faint)

                Spacer()

                Button {
                    Task { await postComment(to: target.id) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "paperplane.fill")
                            .accessibilityHidden(true)
                        Text(localized(en: "POST", ru: "ОТПРАВИТЬ", es: "PUBLICAR", uk: "ОПУБЛІКУВАТИ"))
                    }
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 44)
                    .background(SpyTheme.red)
                    .clipShape(CutCornerShape(cut: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(SpyWebPressStyle())
                .disabled(activeAction != nil || commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 4)
    }

    private func commentRow(_ comment: CommunityProfileComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Task {
                    await openProfile(
                        comment.author.id,
                        rememberingCurrent: true,
                        placeholder: comment.author
                    )
                }
            } label: {
                Text(comment.author.avatar)
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.black)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(SpyWebPressStyle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(comment.author.displayName.uppercased())
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(comment.author.spyID)
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                }

                Text(comment.body)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Text(formattedCommunityDate(comment.createdAt))
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(SpyTheme.faint)
            }

            Spacer(minLength: 4)

            VStack(spacing: 0) {
                if comment.author.id != network?.me.id {
                    Button {
                        reportTarget = .comment(comment)
                    } label: {
                        Image(systemName: "flag")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(SpyTheme.amber)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(activeAction != nil)
                    .accessibilityLabel(localized(en: "Report comment", ru: "Пожаловаться на комментарий", es: "Reportar comentario", uk: "Поскаржитися на допис"))
                }

                if comment.canDelete {
                    Button {
                        Task { await deleteComment(comment.id) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(SpyTheme.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(activeAction != nil)
                    .accessibilityLabel(localized(en: "Delete comment", ru: "Удалить комментарий", es: "Eliminar comentario", uk: "Видалити допис"))
                }
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SpyTheme.stroke).frame(height: 1)
        }
    }

    private func incomingFriendRow(_ record: CommunityRelationship) -> some View {
        VStack(spacing: 9) {
            operativeRow(record.profile) {
                Task {
                    await openProfile(
                        record.profile.id,
                        rememberingCurrent: true,
                        placeholder: record.profile
                    )
                }
            }

            HStack(spacing: 9) {
                communityActionButton(
                    localized(en: "ACCEPT", ru: "ПРИНЯТЬ", es: "ACEPTAR", uk: "ПРИЙНЯТИ"),
                    icon: "checkmark",
                    color: SpyTheme.green,
                    filled: true,
                    feedbackID: relationshipFeedbackID("accept", record.id),
                    waitingTitle: localized(en: "ACCEPTING...", ru: "ПРИНИМАЕМ...", es: "ACEPTANDO...", uk: "ПРИЙМАЄМО..."),
                    successTitle: localized(en: "ACCEPTED", ru: "ПРИНЯТО", es: "ACEPTADO", uk: "ПРИЙНЯТО")
                ) {
                    await relationshipDecision("accept", record.id)
                }

                communityActionButton(
                    localized(en: "DECLINE", ru: "ОТКЛОНИТЬ", es: "RECHAZAR", uk: "ВІДХИЛИТИ"),
                    icon: "xmark",
                    color: SpyTheme.muted,
                    feedbackID: relationshipFeedbackID("decline", record.id),
                    waitingTitle: localized(en: "DECLINING...", ru: "ОТКЛОНЯЕМ...", es: "RECHAZANDO...", uk: "ВІДХИЛЯЄМО..."),
                    successTitle: localized(en: "DECLINED", ru: "ОТКЛОНЕНО", es: "RECHAZADO", uk: "ВІДХИЛЕНО")
                ) {
                    await relationshipDecision("decline", record.id)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func roomInviteRow(_ invite: CommunityRoomInvite) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(invite.sender.avatar)
                    .font(.system(size: 21))
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.black)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(invite.sender.displayName.uppercased())
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(localized(en: "ROOM \(invite.roomCode)", ru: "КОМНАТА \(invite.roomCode)", es: "SALA \(invite.roomCode)", uk: "КІМНАТА \(invite.roomCode)"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                }

                Spacer()
            }

            HStack(spacing: 9) {
                communityActionButton(
                    localized(en: "JOIN", ru: "ВОЙТИ", es: "ENTRAR", uk: "УВІЙТИ"),
                    icon: "arrow.right",
                    color: SpyTheme.red,
                    filled: true,
                    feedbackID: roomInviteFeedbackID("accept", invite.id),
                    waitingTitle: localized(en: "ACCEPTING...", ru: "ПРИНИМАЕМ...", es: "ACEPTANDO...", uk: "ПРИЙМАЄМО..."),
                    successTitle: localized(en: "READY", ru: "ГОТОВО", es: "LISTO", uk: "ГОТОВО")
                ) {
                    await acceptRoomInvite(invite)
                }

                communityActionButton(
                    localized(en: "DECLINE", ru: "ОТКЛОНИТЬ", es: "RECHAZAR", uk: "ВІДХИЛИТИ"),
                    icon: "xmark",
                    color: SpyTheme.muted,
                    feedbackID: roomInviteFeedbackID("decline", invite.id),
                    waitingTitle: localized(en: "DECLINING...", ru: "ОТКЛОНЯЕМ...", es: "RECHAZANDO...", uk: "ВІДХИЛЯЄМО..."),
                    successTitle: localized(en: "DECLINED", ru: "ОТКЛОНЕНО", es: "RECHAZADO", uk: "ВІДХИЛЕНО")
                ) {
                    await declineRoomInvite(invite)
                }
            }
        }
        .padding(11)
        .background(SpyTheme.black.opacity(0.58))
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func operativeRow(_ profile: PublicSpyProfile, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Text(profile.avatar)
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.black)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName.uppercased())
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(profile.spyID)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(SpyTheme.muted)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(SpyTheme.red)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.985))
    }

    private func blockedOperativeRow(_ relationship: CommunityRelationship) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 11) {
                Text(relationship.profile.avatar)
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.black)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(relationship.profile.displayName.uppercased())
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(relationship.profile.spyID)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(SpyTheme.muted)
                }

                Spacer(minLength: 8)

                Image(systemName: "hand.raised.slash.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(SpyTheme.muted)
            }

            Button {
                unblockTarget = relationship
            } label: {
                commandLabel(
                    localized(en: "UNBLOCK", ru: "РАЗБЛОКИРОВАТЬ", es: "DESBLOQUEAR", uk: "РОЗБЛОКУВАТИ"),
                    icon: "lock.open.fill"
                )
                .foregroundStyle(SpyTheme.muted)
                .frame(minHeight: 44)
                .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
            }
            .buttonStyle(SpyWebPressStyle())
            .disabled(activeAction != nil)
        }
        .padding(11)
        .background(SpyTheme.black.opacity(0.58))
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func communityActionButton(
        _ title: String,
        icon: String,
        color: Color,
        filled: Bool = false,
        feedbackID: String? = nil,
        waitingTitle: String? = nil,
        successTitle: String? = nil,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        let feedback = actionFeedback.flatMap { current in
            current.id == feedbackID ? current : nil
        }
        let feedbackColor: Color = switch feedback?.phase {
        case .some(.success): SpyTheme.green
        case .some(.failure): SpyTheme.red
        default: color
        }

        return Button {
            if let feedbackID, let waitingTitle, let successTitle {
                guard beginActionFeedback(
                    id: feedbackID,
                    waitingTitle: waitingTitle,
                    successTitle: successTitle
                ) else { return }
            }
            Task { await action() }
        } label: {
            HStack(spacing: 7) {
                if let feedback {
                    switch feedback.phase {
                    case .waiting:
                        SpySpinner(
                            size: 14,
                            accent: filled ? Color.black.opacity(0.82) : feedbackColor
                        )
                        .accessibilityHidden(true)
                        Text(feedback.waitingTitle)
                            .contentTransition(.numericText())
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .black))
                        Text(feedback.successTitle)
                            .contentTransition(.numericText())
                    case .failure:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .black))
                        Text(localized(en: "RETRY", ru: "ПОВТОРИТЬ", es: "REINTENTAR", uk: "СПРОБУВАТИ ЗНОВУ"))
                            .contentTransition(.numericText())
                    }
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .black))
                    Text(title)
                }
            }
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(0.35)
            .spyFitted(scale: 0.58, alignment: .center)
            .foregroundStyle(filled && feedback?.phase != .failure ? Color.black.opacity(0.82) : feedbackColor)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(filled && feedback?.phase != .failure ? feedbackColor : feedbackColor.opacity(feedback == nil ? 0 : 0.10))
            .overlay(Rectangle().stroke(feedbackColor.opacity(filled ? 0.85 : 0.58), lineWidth: feedback == nil ? 1 : 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(activeAction != nil)
        .opacity(activeAction == nil || activeAction == feedbackID ? 1 : 0.46)
        .animation(.snappy(duration: 0.18), value: feedback)
        .accessibilityLabel(title)
        .accessibilityValue(actionAccessibilityValue(feedback))
    }

    @MainActor
    private func beginActionFeedback(
        id: String,
        waitingTitle: String,
        successTitle: String
    ) -> Bool {
        guard activeAction == nil else { return false }

        networkRefreshGeneration += 1
        profileRequestState.invalidate()
        isProfileLoading = false
        activeAction = id
        withAnimation(.snappy(duration: 0.18)) {
            actionFeedback = CommunityActionFeedback(
                id: id,
                phase: .waiting,
                waitingTitle: waitingTitle,
                successTitle: successTitle
            )
        }
        HapticManager.shared.fire(.buttonPress)
        UIAccessibility.post(notification: .announcement, argument: waitingTitle)
        return true
    }

    @MainActor
    private func updateActionWaitingTitle(_ title: String, id: String) {
        guard activeAction == id, var feedback = actionFeedback, feedback.id == id else { return }
        feedback.waitingTitle = title
        withAnimation(.snappy(duration: 0.18)) {
            actionFeedback = feedback
        }
        UIAccessibility.post(notification: .announcement, argument: title)
    }

    @MainActor
    private func showActionSuccess(_ id: String, message successMessage: String) async {
        guard activeAction == id, var feedback = actionFeedback, feedback.id == id else { return }
        feedback.phase = .success
        withAnimation(.snappy(duration: 0.18)) {
            actionFeedback = feedback
        }
        appState.showToast(successMessage, kind: .success)
        HapticManager.shared.fire(.notification(.success))
        UIAccessibility.post(notification: .announcement, argument: feedback.successTitle)
        // The toast owns the success display; it must not hold the next action
        // or the visible list behind an artificial delay.
    }

    @MainActor
    private func finishActionFeedback(_ id: String) {
        guard activeAction == id || actionFeedback?.id == id else { return }
        activeAction = nil
        withAnimation(.snappy(duration: 0.18)) {
            actionFeedback = nil
        }
    }

    @MainActor
    private func failActionFeedback(_ id: String, error: Error) {
        if isCancellation(error) {
            finishActionFeedback(id)
            reconcileNetworkAfterAction()
            return
        }

        activeAction = nil
        if var feedback = actionFeedback, feedback.id == id {
            feedback.phase = .failure
            withAnimation(.snappy(duration: 0.18)) {
                actionFeedback = feedback
            }
        }
        showError(error)
        UIAccessibility.post(
            notification: .announcement,
            argument: localized(
                en: "Action failed. Try again.",
                ru: "Не удалось. Попробуйте ещё раз.",
                es: "La accion fallo. Intentalo de nuevo.",
                uk: "Не вдалося виконати дію. Спробуйте ще раз."
            )
        )
        reconcileNetworkAfterAction()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard actionFeedback?.id == id, actionFeedback?.phase == .failure else { return }
            withAnimation(.snappy(duration: 0.18)) {
                actionFeedback = nil
            }
        }
    }

    private func actionAccessibilityValue(_ feedback: CommunityActionFeedback?) -> String {
        guard let feedback else { return "" }
        switch feedback.phase {
        case .waiting:
            return localized(en: "In progress", ru: "Выполняется", es: "En progreso", uk: "Виконується")
        case .success:
            return localized(en: "Successful", ru: "Успешно", es: "Completado", uk: "Успішно")
        case .failure:
            return localized(en: "Failed. Try again", ru: "Ошибка. Повторить", es: "Error. Reintentar", uk: "Помилка. Спробуйте ще раз")
        }
    }

    private func relationshipFeedbackID(_ action: String, _ friendshipID: String) -> String {
        "relationship:\(friendshipID):\(action)"
    }

    private func roomInviteFeedbackID(_ action: String, _ inviteID: String) -> String {
        "room-invite:\(inviteID):\(action)"
    }

    private func connectionStatus(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.35)
                .spyFitted(scale: 0.58, alignment: .center)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(color.opacity(0.08))
        .overlay(Rectangle().stroke(color.opacity(0.32), lineWidth: 1))
    }

    private func commandLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.8)
                .spyFitted(scale: 0.60, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func inviteRoom(for detail: CommunityProfileDetail) -> GameRoom? {
        guard detail.relationship?.status.lowercased() == "accepted" else { return nil }
        guard let room = appState.activeRoom, room.normalizedStatus == "waiting" else { return nil }
        return room
    }

    private func handleDockAction(_ tab: CommunityTab) {
        HapticManager.shared.fire(.tabSelection)
        switch tab {
        case .exit:
            onExit()
        case .network:
            isSelfProfileTransitionPending = false
            profileRequestState.invalidate()
            isProfileLoading = false
            selectedTab = .network
            activeProfile = nil
            profileHistory.removeAll()
            commentDraft = ""
        case .me:
            isSelfProfileTransitionPending = true
            profileHistory.removeAll()
            commentDraft = ""
            Task {
                await completePendingSelfProfileTransitionIfPossible()
            }
        }
    }

    @MainActor
    private func completePendingSelfProfileTransitionIfPossible() async {
        guard isSelfProfileTransitionPending,
              CommunityMeTransitionResolver.canCommit(
                  selfUserID: network?.me.id,
                  activeAction: activeAction
              ),
              let profile = network?.me else {
            return
        }

        isSelfProfileTransitionPending = false
        selectedTab = .me
        await openProfile(
            profile.id,
            rememberingCurrent: false,
            placeholder: profile
        )
    }

    private func loadInitialContent() async {
        guard !didLoadInitialContent else { return }
        let generation = mutationGeneration
        isInitialLoading = true
        defer {
            if mutationGeneration == generation {
                isInitialLoading = false
                didLoadInitialContent = true
            }
        }

        if appState.shouldUsePreviewData {
            network = .preview
            directory = CommunityPreview.directory.filter { $0.id != CommunityPreview.night.id }
            nextDirectoryOffset = nil
#if DEBUG
            if let target = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--spyclash-preview-community-profile=") })
                .map({ String($0.dropFirst("--spyclash-preview-community-profile=".count)) }) {
                let userID = target == "me" ? CommunityPreview.me.id : target
                selectedTab = userID == CommunityPreview.me.id ? .me : .network
                activeProfile = CommunityPreview.profile(userID: userID, viewerID: CommunityPreview.me.id)
            }
#endif
            return
        }

        // Render already-known actionable items immediately while the public
        // directory performs its independent network refresh.
        if let externalNetworkState, externalNetworkState.me.id == appState.user?.id {
            network = externalNetworkState
        }

        if SupabaseAppRuntime.isEnabled {
            // Friends and invitations render as soon as their response arrives.
            // The paginated public directory is an independent request.
            async let directoryLoad: Void = loadDirectory(reset: true)
            async let networkLoad: Void = loadInitialNetwork()
            _ = await (directoryLoad, networkLoad)
        } else {
            await loadDirectory(reset: true)
            await loadInitialNetwork()
        }
    }

    private func loadInitialNetwork() async {
        let actorID = appState.user?.id
        let generation = mutationGeneration
        let refreshGeneration = networkRefreshGeneration
        do {
            let loadedState = try await appState.client.communityState()
            guard !Task.isCancelled, appState.user?.id == actorID,
                  mutationGeneration == generation, networkRefreshGeneration == refreshGeneration else { return }
            if activeAction == nil {
                network = sanitizedNetworkState(loadedState)
            } else {
                deferredExternalNetworkState = loadedState
            }
        } catch {
            guard !Task.isCancelled, appState.user?.id == actorID else { return }
            if network == nil { showError(error) }
        }
    }

    @MainActor
    private func startProfileRealtime() {
        guard scenePhase == .active, let token = appState.client.currentAccessToken,
              let userID = appState.user?.id else { return }
        profileRealtime.onSignal = { signal in
            Task { await applyProfileSignal(signal) }
        }
        profileRealtime.onNetworkChange = { scheduleRealtimeRefresh(reloadDirectory: false) }
        profileRealtime.onCatchUp = { scheduleRealtimeRefresh(reloadDirectory: true) }
        profileRealtime.start(appID: Base44Client.appID, token: token, userID: userID)
    }

    @MainActor
    private func stopProfileRealtime() {
        profileRealtime.stop()
        realtimeRefreshID = UUID()
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = nil
        realtimeRefreshRequested = false
        realtimeDirectoryRefreshRequested = false
    }

    @MainActor
    private func scheduleRealtimeRefresh(reloadDirectory: Bool) {
        realtimeRefreshRequested = true
        realtimeDirectoryRefreshRequested = realtimeDirectoryRefreshRequested || reloadDirectory
        guard realtimeRefreshTask == nil else { return }
        let actorID = appState.user?.id
        let generation = mutationGeneration
        let requestID = UUID()
        realtimeRefreshID = requestID
        realtimeRefreshTask = Task { @MainActor in
            defer {
                if mutationGeneration == generation, realtimeRefreshID == requestID { realtimeRefreshTask = nil }
            }
            while realtimeRefreshRequested, !Task.isCancelled,
                  appState.user?.id == actorID, mutationGeneration == generation {
                realtimeRefreshRequested = false
                let refreshDirectory = realtimeDirectoryRefreshRequested
                realtimeDirectoryRefreshRequested = false
                networkRefreshGeneration += 1
                // Only the first page is needed after reconnect. Ordinary
                // relationship events do not redownload the public directory.
                if refreshDirectory, SupabaseAppRuntime.isEnabled {
                    async let directoryLoad: Void = loadDirectory(reset: true)
                    async let profileLoad: Void = refreshVisibleProfile()
                    await refreshNetworkFromServer(generation: networkRefreshGeneration)
                    _ = await (directoryLoad, profileLoad)
                } else if refreshDirectory {
                    await refreshNetworkFromServer(generation: networkRefreshGeneration)
                    guard !Task.isCancelled, appState.user?.id == actorID,
                          mutationGeneration == generation else { return }
                    await loadDirectory(reset: true)
                    guard !Task.isCancelled, appState.user?.id == actorID,
                          mutationGeneration == generation else { return }
                    await refreshVisibleProfile()
                } else {
                    await refreshNetworkFromServer(generation: networkRefreshGeneration)
                }
            }
        }
    }

    private var profileRefreshTaskKey: String? {
        guard SupabaseAppRuntime.isEnabled, !appState.shouldUsePreviewData,
              scenePhase == .active, let actorID = appState.user?.id,
              let profileID = activeProfile?.profile.id else { return nil }
        return "\(actorID):\(profileID)"
    }

    /// Reconnect catches missed non-durable events. The visible-profile fallback
    /// also renews the server's watcher lease without reloading the directory.
    @MainActor
    private func refreshVisibleProfile() async {
        guard scenePhase == .active, !appState.shouldUsePreviewData,
              let profileID = activeProfile?.profile.id else { return }
        guard activeAction == nil else { profileRefreshPending = true; return }
        profileRefreshPending = false
        let actorID = appState.user?.id
        let generation = mutationGeneration
        let requestID = profileRequestState.begin()
        let signalGeneration = profileSignalGenerations[profileID] ?? 0
        do {
            let detail = try await appState.client.communityProfile(userID: profileID)
            guard !Task.isCancelled, appState.user?.id == actorID, mutationGeneration == generation,
                  activeProfile?.profile.id == profileID, profileRequestState.accepts(requestID) else { return }
            guard profileRequestState.accepts(requestID, signalGeneration: signalGeneration,
                                              currentSignalGeneration: profileSignalGenerations[profileID] ?? 0) else {
                isProfileLoading = false
                return
            }
            profileCache[profileID] = detail
            activeProfile = detail
            isProfileLoading = false
            reconcileActiveProfileRelationship()
            if let index = directory.firstIndex(where: { $0.id == profileID }) { directory[index] = detail.profile }
        } catch {
            guard !Task.isCancelled, appState.user?.id == actorID, mutationGeneration == generation,
                  activeProfile?.profile.id == profileID, profileRequestState.accepts(requestID) else { return }
            isProfileLoading = false
            // Keep the current content visible; reconnect or the next visible
            // profile fallback retries without turning a transient error into removal.
        }
    }

    @MainActor
    private func applyProfileSignal(_ signal: CommunityProfileSignal) async {
        guard signal.revision > (latestProfileRevisions[signal.profileUserID] ?? -1) else { return }
        latestProfileRevisions[signal.profileUserID] = signal.revision
        profileSignalGenerations[signal.profileUserID, default: 0] &+= 1
        let actorID = appState.user?.id
        let generation = mutationGeneration
        do {
            let detail = try await appState.client.communityProfile(userID: signal.profileUserID)
            guard !Task.isCancelled, appState.user?.id == actorID, mutationGeneration == generation,
                  latestProfileRevisions[signal.profileUserID] == signal.revision else { return }
            profileCache[signal.profileUserID] = detail
            if let index = directory.firstIndex(where: { $0.id == signal.profileUserID }) {
                directory[index] = detail.profile
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                directory.append(detail.profile)
            }
            if activeProfile?.profile.id == signal.profileUserID {
                activeProfile = detail
                isProfileLoading = false
                reconcileActiveProfileRelationship()
            }
            if network?.me.id == signal.profileUserID {
                scheduleRealtimeRefresh(reloadDirectory: false)
            }
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation,
                  latestProfileRevisions[signal.profileUserID] == signal.revision else { return }
            // A temporary read failure is not proof that the player disappeared.
            latestProfileRevisions[signal.profileUserID] = nil
            if let error = error as? Base44Error, error.statusCode == 404 {
                directory.removeAll { $0.id == signal.profileUserID }
                profileCache[signal.profileUserID] = nil
            }
        }
    }

    @MainActor
    private func refreshProfilesAfterAccountChange() async {
        guard !appState.shouldUsePreviewData, appState.user != nil else { return }

        profileRequestState.invalidate()
        profileCache.removeAll()
        let actorID = appState.user?.id
        let generation = mutationGeneration

        do {
            let refreshedState = try await appState.client.communityState()
            guard !Task.isCancelled, appState.user?.id == actorID, mutationGeneration == generation else { return }
            network = sanitizedNetworkState(refreshedState)
            if selectedTab == .me {
                activeProfile = nil
                isSelfProfileTransitionPending = true
                await completePendingSelfProfileTransitionIfPossible()
            }
        } catch {
            guard !Task.isCancelled, appState.user?.id == actorID, mutationGeneration == generation else { return }
            showError(error)
        }

        guard !Task.isCancelled, appState.user?.id == actorID, mutationGeneration == generation else { return }
        await loadDirectory(reset: true)
        guard !Task.isCancelled, mutationGeneration == generation else { return }
        isInitialLoading = false
        didLoadInitialContent = true
    }

    private func loadDirectory(reset: Bool, offset: Int = 0) async {
        guard reset || !isDirectoryLoading else { return }
        let requestID = UUID()
        let expectedQuery = query
        let actorID = appState.user?.id
        directoryRequestID = requestID
        isDirectoryLoading = true
        defer { if directoryRequestID == requestID { isDirectoryLoading = false } }

        if appState.shouldUsePreviewData {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            directory = CommunityPreview.directory.filter { profile in
                profile.id != CommunityPreview.night.id &&
                    (
                        normalized.isEmpty ||
                            profile.displayName.lowercased().contains(normalized) ||
                            profile.spyID.lowercased().contains(normalized.replacingOccurrences(of: " ", with: ""))
                    )
            }
            nextDirectoryOffset = nil
            return
        }

        do {
            let page = try await appState.client.communityDirectory(query: expectedQuery, offset: offset)
            guard !Task.isCancelled, appState.user?.id == actorID,
                  directoryRequestID == requestID, query == expectedQuery else { return }
            if reset {
                directory = page.profiles
                directoryLoadFailed = false
            } else {
                let known = Set(directory.map(\.id))
                directory.append(contentsOf: page.profiles.filter { !known.contains($0.id) })
            }
            nextDirectoryOffset = page.nextOffset
        } catch is CancellationError {
            return
        } catch {
            guard appState.user?.id == actorID, directoryRequestID == requestID else { return }
            if reset { directoryLoadFailed = true }
            showError(error)
        }
    }

    private func retryInitialContent() async {
        guard !isDirectoryLoading else { return }
        message = ""
        directoryLoadFailed = false
        await loadDirectory(reset: true)
        if network == nil { await loadInitialNetwork() }
    }

    @MainActor
    private func openProfile(
        _ userID: String,
        rememberingCurrent: Bool,
        placeholder: PublicSpyProfile? = nil
    ) async {
        guard activeAction == nil else { return }
        if rememberingCurrent, let currentID = activeProfile?.profile.id, currentID != userID {
            profileHistory.append(currentID)
        }

        let requestID = profileRequestState.begin()
        let actorID = appState.user?.id
        let generation = mutationGeneration
        let signalGeneration = profileSignalGenerations[userID] ?? 0
        commentDraft = ""

        if let cached = profileCache[userID] {
            activeProfile = cached
        } else if let placeholder {
            activeProfile = placeholderDetail(for: placeholder)
        }
        isProfileLoading = profileCache[userID] == nil

        if appState.shouldUsePreviewData {
            if let detail = CommunityPreview.profile(userID: userID, viewerID: network?.me.id) {
                profileCache[userID] = detail
                activeProfile = detail
            }
            isProfileLoading = false
            return
        }

        do {
            let detail = try await appState.client.communityProfile(userID: userID)
            guard profileRequestState.accepts(requestID), !Task.isCancelled,
                  appState.user?.id == actorID, mutationGeneration == generation else { return }
            guard profileRequestState.accepts(requestID, signalGeneration: signalGeneration,
                                              currentSignalGeneration: profileSignalGenerations[userID] ?? 0) else {
                isProfileLoading = false
                return
            }
            profileCache[userID] = detail
            activeProfile = detail
            isProfileLoading = false
        } catch {
            guard profileRequestState.accepts(requestID), appState.user?.id == actorID,
                  mutationGeneration == generation else { return }
            isProfileLoading = false
            showError(error)
            if activeProfile == nil, profileHistory.isEmpty { selectedTab = .network }
        }
    }

    private func placeholderDetail(for profile: PublicSpyProfile) -> CommunityProfileDetail {
        CommunityProfileDetail(
            profile: profile,
            isSelf: profile.id == network?.me.id,
            relationship: nil,
            friends: [],
            comments: []
        )
    }

    private func returnFromProfile() async {
        profileRequestState.invalidate()
        isProfileLoading = false
        commentDraft = ""
        if let previousID = profileHistory.popLast() {
            await openProfile(previousID, rememberingCurrent: false)
        } else if initialProfileUserID != nil {
            onExit()
        } else {
            activeProfile = nil
            selectedTab = .network
        }
    }

    private func reconcileActiveProfileRelationship() {
        guard let detail = activeProfile, let network else { return }
        let record = (network.blocked + network.friends + network.incoming + network.outgoing)
            .first { $0.profile.id == detail.profile.id }
        let relationship = record.map {
            CommunityRelationshipSummary(id: $0.id, status: $0.status, direction: $0.direction)
        }
        let updated = CommunityProfileDetail(
            profile: detail.profile, isSelf: detail.isSelf, relationship: relationship,
            friends: detail.isSelf ? network.friends.map(\.profile) : detail.friends,
            comments: detail.comments
        )
        activeProfile = updated
        profileCache[detail.profile.id] = updated
    }

    private func sendFriendRequest(to userID: String) async {
        let actionID = "friend-\(userID)"
        guard activeAction == actionID else { return }
        let actorID = appState.user?.id
        let generation = mutationGeneration
        do {
            if !appState.shouldUsePreviewData {
                let state = try await appState.client.sendFriendRequest(userID: userID)
                guard appState.user?.id == actorID, mutationGeneration == generation else { return }
                network = sanitizedNetworkState(state)
                reconcileActiveProfileRelationship()
            }
            await showActionSuccess(actionID, message: localized(en: "REQUEST TRANSMITTED", ru: "ЗАПРОС ОТПРАВЛЕН", es: "SOLICITUD ENVIADA", uk: "ЗАПИТ НАДІСЛАНО"))
            finishActionFeedback(actionID)
            reconcileNetworkAfterAction()
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            failActionFeedback(actionID, error: error)
        }
    }

    private func relationshipAction(_ action: String, _ friendshipID: String) async {
        await relationshipDecision(action, friendshipID)
    }

    private func relationshipDecision(_ action: String, _ friendshipID: String) async {
        let actionID = relationshipFeedbackID(action, friendshipID)
        guard activeAction == actionID else { return }
        let actorID = appState.user?.id
        let generation = mutationGeneration
        let change = network.flatMap {
            CommunityOptimisticRelationshipChange(state: $0, action: action, friendshipID: friendshipID)
        }
        optimisticRelationship = change
        if let change, let network {
            withAnimation(.smooth(duration: 0.18)) { self.network = change.applying(to: network) }
            reconcileActiveProfileRelationship()
        }

        do {
            let updatedNetwork: CommunityState?
            if appState.shouldUsePreviewData {
                await Task.yield()
                updatedNetwork = network
            } else {
                updatedNetwork = try await appState.client.communityRelationshipAction(action, friendshipID: friendshipID)
            }
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            optimisticRelationship = nil
            resolvedRelationshipIDs.insert(friendshipID)
            if let updatedNetwork { network = sanitizedNetworkState(updatedNetwork) }
            reconcileActiveProfileRelationship()
            let successMessage: String
            switch action {
            case "accept":
                successMessage = localized(en: "OPERATIVE ADDED", ru: "ОПЕРАТИВНИК ДОБАВЛЕН", es: "OPERATIVO AGREGADO", uk: "ОПЕРАТИВНИКА ДОДАНО")
            case "remove_friend":
                successMessage = localized(en: "OPERATIVE REMOVED", ru: "ДРУГ УДАЛЁН", es: "OPERATIVO ELIMINADO", uk: "ОПЕРАТИВНИКА ВИДАЛЕНО")
            case "cancel_request":
                successMessage = localized(en: "REQUEST CANCELLED", ru: "ЗАПРОС ОТМЕНЁН", es: "SOLICITUD CANCELADA", uk: "ЗАПИТ СКАСОВАНО")
            default:
                successMessage = localized(en: "REQUEST DECLINED", ru: "ЗАПРОС ОТКЛОНЁН", es: "SOLICITUD RECHAZADA", uk: "ЗАПИТ ВІДХИЛЕНО")
            }
            await showActionSuccess(actionID, message: successMessage)
            finishActionFeedback(actionID)
            reconcileNetworkAfterAction()
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            optimisticRelationship = nil
            if let change, let network { self.network = change.rollingBack(in: network) }
            reconcileActiveProfileRelationship()
            failActionFeedback(actionID, error: error)
        }
    }

    private func submitReport(_ target: CommunityReportTarget, reason: CommunityReportReason) async {
        guard activeAction == nil else { return }
        activeAction = "report-\(target.id)"
        let actorID = appState.user?.id
        let generation = mutationGeneration
        networkRefreshGeneration += 1
        defer {
            if appState.user?.id == actorID, mutationGeneration == generation { activeAction = nil }
        }

        if appState.shouldUsePreviewData {
            message = localized(en: "REPORT RECEIVED", ru: "ЖАЛОБА ПРИНЯТА", es: "REPORTE RECIBIDO", uk: "СКАРГУ ПРИЙНЯТО")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
            return
        }

        do {
            let acknowledgement: CommunityActionAcknowledgement
            switch target {
            case let .user(profile):
                acknowledgement = try await appState.client.reportCommunityUser(
                    userID: profile.id,
                    reason: reason
                )
            case let .comment(comment):
                acknowledgement = try await appState.client.reportCommunityComment(
                    commentID: comment.id,
                    reason: reason
                )
            }
            guard appState.user?.id == actorID, mutationGeneration == generation,
                  acknowledgement.ok else { return }
            message = localized(
                en: "REPORT RECEIVED — MODERATION WILL REVIEW IT",
                ru: "ЖАЛОБА ПРИНЯТА — МОДЕРАЦИЯ ПРОВЕРИТ ЕЕ",
                es: "REPORTE RECIBIDO — MODERACION LO REVISARA",
                uk: "СКАРГУ ПРИЙНЯТО — МОДЕРАЦІЯ ЇЇ РОЗГЛЯНЕ"
            )
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            showError(error)
        }
    }

    private func blockOperative(_ profile: PublicSpyProfile) async {
        guard activeAction == nil else { return }
        activeAction = "block-\(profile.id)"
        let actorID = appState.user?.id
        let generation = mutationGeneration
        networkRefreshGeneration += 1
        defer {
            if appState.user?.id == actorID, mutationGeneration == generation { activeAction = nil }
        }

        if appState.shouldUsePreviewData {
            activeProfile = nil
            profileHistory.removeAll()
            directory.removeAll { $0.id == profile.id }
            message = localized(en: "OPERATIVE BLOCKED", ru: "ОПЕРАТИВНИК ЗАБЛОКИРОВАН", es: "OPERATIVO BLOQUEADO", uk: "ОПЕРАТИВНИКА ЗАБЛОКОВАНО")
            messageKind = .success
            return
        }

        do {
            let state = try await appState.client.blockCommunityUser(userID: profile.id)
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            network = state
            activeProfile = nil
            profileHistory.removeAll()
            selectedTab = .network
            commentDraft = ""
            directory.removeAll { $0.id == profile.id }
            message = localized(
                en: "OPERATIVE BLOCKED — COMMENTS AND INVITES REMOVED",
                ru: "ОПЕРАТИВНИК ЗАБЛОКИРОВАН — ЗАПИСИ И ПРИГЛАШЕНИЯ УДАЛЕНЫ",
                es: "OPERATIVO BLOQUEADO — COMENTARIOS E INVITACIONES ELIMINADOS",
                uk: "ОПЕРАТИВНИКА ЗАБЛОКОВАНО — ДОПИСИ ТА ЗАПРОШЕННЯ ВИДАЛЕНО"
            )
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            showError(error)
        }
    }

    private func unblockOperative(_ relationship: CommunityRelationship) async {
        guard activeAction == nil else { return }
        activeAction = "unblock-\(relationship.id)"
        let actorID = appState.user?.id
        let generation = mutationGeneration
        networkRefreshGeneration += 1
        defer {
            if appState.user?.id == actorID, mutationGeneration == generation { activeAction = nil }
        }

        if appState.shouldUsePreviewData {
            message = localized(en: "OPERATIVE UNBLOCKED", ru: "ОПЕРАТИВНИК РАЗБЛОКИРОВАН", es: "OPERATIVO DESBLOQUEADO", uk: "ОПЕРАТИВНИКА РОЗБЛОКОВАНО")
            messageKind = .success
            return
        }

        do {
            let state = try await appState.client.unblockCommunityUser(friendshipID: relationship.id)
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            network = state
            message = localized(en: "OPERATIVE UNBLOCKED", ru: "ОПЕРАТИВНИК РАЗБЛОКИРОВАН", es: "OPERATIVO DESBLOQUEADO", uk: "ОПЕРАТИВНИКА РОЗБЛОКОВАНО")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            showError(error)
        }
    }

    private func postComment(to userID: String) async {
        let body = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeAction == nil, !body.isEmpty else { return }
        activeAction = "comment"
        let actorID = appState.user?.id
        let generation = mutationGeneration
        networkRefreshGeneration += 1
        defer {
            if appState.user?.id == actorID, mutationGeneration == generation { activeAction = nil }
        }

        if appState.shouldUsePreviewData {
            commentDraft = ""
            message = localized(en: "FIELD NOTE POSTED", ru: "ЗАПИСЬ ОПУБЛИКОВАНА", es: "NOTA PUBLICADA", uk: "ДОПИС ОПУБЛІКОВАНО")
            messageKind = .success
            return
        }

        do {
            let detail = try await appState.client.addCommunityComment(userID: userID, comment: body)
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            activeProfile = detail
            commentDraft = ""
            message = localized(en: "FIELD NOTE POSTED", ru: "ЗАПИСЬ ОПУБЛИКОВАНА", es: "NOTA PUBLICADA", uk: "ДОПИС ОПУБЛІКОВАНО")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            showError(error)
        }
    }

    private func deleteComment(_ commentID: String) async {
        guard activeAction == nil else { return }
        activeAction = commentID
        let actorID = appState.user?.id
        let generation = mutationGeneration
        networkRefreshGeneration += 1
        defer {
            if appState.user?.id == actorID, mutationGeneration == generation { activeAction = nil }
        }

        if appState.shouldUsePreviewData { return }

        do {
            let detail = try await appState.client.deleteCommunityComment(commentID: commentID)
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            activeProfile = detail
            HapticManager.shared.fire(.notification(.success))
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            showError(error)
        }
    }

    private func inviteToRoom(_ profile: PublicSpyProfile, room: GameRoom) async {
        let actionID = "invite-\(profile.id)"
        guard activeAction == actionID else { return }
        let actorID = appState.user?.id
        let generation = mutationGeneration
        do {
            if !appState.shouldUsePreviewData {
                let acknowledgement = try await appState.client.inviteCommunityOperative(userID: profile.id, room: room)
                guard appState.user?.id == actorID, mutationGeneration == generation else { return }
                guard acknowledgement.ok else { throw Base44Error(message: localized(en: "Could not send the invite", ru: "Не удалось отправить приглашение", es: "No se pudo enviar la invitación", uk: "Не вдалося надіслати запрошення")) }
            }
            await showActionSuccess(actionID, message: localized(en: "ROOM INVITE SENT", ru: "ПРИГЛАШЕНИЕ ОТПРАВЛЕНО", es: "INVITACIÓN ENVIADA", uk: "ЗАПРОШЕННЯ ДО КІМНАТИ НАДІСЛАНО"))
            finishActionFeedback(actionID)
            reconcileNetworkAfterAction()
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            failActionFeedback(actionID, error: error)
        }
    }

    private func acceptRoomInvite(_ invite: CommunityRoomInvite) async {
        let actionID = roomInviteFeedbackID("accept", invite.id)
        guard activeAction == actionID else { return }
        let actorID = appState.user?.id
        let generation = mutationGeneration

        if appState.shouldUsePreviewData {
            do {
                try await Task.sleep(for: .milliseconds(620))
                updateActionWaitingTitle(
                    localized(en: "JOINING...", ru: "ВХОДИМ...", es: "ENTRANDO...", uk: "ПРИЄДНУЄМОСЯ..."),
                    id: actionID
                )
                try await Task.sleep(for: .milliseconds(620))
                await showActionSuccess(
                    actionID,
                    message: localized(en: "ROOM READY", ru: "КОМНАТА ГОТОВА", es: "SALA LISTA", uk: "КІМНАТА ГОТОВА")
                )
                resolvedRoomInviteIDs.insert(invite.id)
                network = networkRemovingRoomInvite(invite.id, from: network)
                finishActionFeedback(actionID)
                reconcileNetworkAfterAction()
            } catch {
                failActionFeedback(actionID, error: error)
            }
            return
        }

        do {
            var acceptedState = network
            var roomCode = invite.roomCode
            if invite.status.lowercased() != "accepted" {
                let result = try await appState.client.communityRoomInviteAction(
                    "accept_room_invite",
                    inviteID: invite.id
                )
                guard appState.user?.id == actorID, mutationGeneration == generation else { return }
                acceptedState = result.state
                roomCode = result.roomCode ?? invite.roomCode
            }

            updateActionWaitingTitle(
                localized(en: "JOINING...", ru: "ВХОДИМ...", es: "ENTRANDO...", uk: "ПРИЄДНУЄМОСЯ..."),
                id: actionID
            )
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            let joined = await appState.joinRoom(code: roomCode)
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            guard joined else {
                network = acceptedState
                throw Base44Error(message: localized(
                    en: "Could not join the room",
                    ru: "Не удалось войти в комнату",
                    es: "No se pudo entrar a la sala",
                    uk: "Не вдалося увійти до кімнати"
                ))
            }

            resolvedRoomInviteIDs.insert(invite.id)
            let cleanupUserID = appState.user?.id
            if let cleanupUserID {
                persistPendingRoomInviteCleanup(invite.id, userID: cleanupUserID)
            }
            Task { @MainActor in
                guard let cleanupUserID else { return }
                await consumeRoomInviteWithRetry(invite.id, userID: cleanupUserID)
            }

            await showActionSuccess(
                actionID,
                message: localized(en: "ROOM READY", ru: "КОМНАТА ГОТОВА", es: "SALA LISTA", uk: "КІМНАТА ГОТОВА")
            )
            network = networkRemovingRoomInvite(invite.id, from: acceptedState)
            finishActionFeedback(actionID)
            reconcileNetworkAfterAction()
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            failActionFeedback(actionID, error: error)
        }
    }

    private func declineRoomInvite(_ invite: CommunityRoomInvite) async {
        let actionID = roomInviteFeedbackID("decline", invite.id)
        guard activeAction == actionID else { return }
        let actorID = appState.user?.id
        let generation = mutationGeneration
        optimisticDeclinedInviteID = invite.id
        network = networkRemovingRoomInvite(invite.id, from: network)

        do {
            if !appState.shouldUsePreviewData {
                let result = try await appState.client.communityRoomInviteAction("decline_room_invite", inviteID: invite.id)
                guard appState.user?.id == actorID, mutationGeneration == generation else { return }
                resolvedRoomInviteIDs.insert(invite.id)
                network = sanitizedNetworkState(result.state)
                Task { @MainActor in await appState.notificationInbox.refreshSummary() }
            }
            optimisticDeclinedInviteID = nil
            await showActionSuccess(actionID, message: localized(en: "INVITE DECLINED", ru: "ПРИГЛАШЕНИЕ ОТКЛОНЕНО", es: "INVITACIÓN RECHAZADA", uk: "ЗАПРОШЕННЯ ВІДХИЛЕНО"))
            finishActionFeedback(actionID)
            reconcileNetworkAfterAction()
        } catch {
            guard appState.user?.id == actorID, mutationGeneration == generation else { return }
            optimisticDeclinedInviteID = nil
            if let current = network, !current.incomingRoomInvites.contains(where: { $0.id == invite.id }) {
                network = CommunityState(me: current.me, friends: current.friends, incoming: current.incoming,
                                         outgoing: current.outgoing, blocked: current.blocked,
                                         incomingRoomInvites: current.incomingRoomInvites + [invite])
            }
            failActionFeedback(actionID, error: error)
        }
    }

    private func networkRemovingRoomInvite(
        _ inviteID: String,
        from state: CommunityState?
    ) -> CommunityState? {
        guard let state else { return nil }
        return CommunityState(
            me: state.me,
            friends: state.friends,
            incoming: state.incoming,
            outgoing: state.outgoing,
            blocked: state.blocked,
            incomingRoomInvites: state.incomingRoomInvites.filter { $0.id != inviteID }
        )
    }

    private func sanitizedNetworkState(_ state: CommunityState) -> CommunityState {
        let state = optimisticRelationship?.applying(to: state) ?? state
        return CommunityState(
            me: state.me,
            friends: state.friends,
            incoming: state.incoming.filter { !resolvedRelationshipIDs.contains($0.id) },
            outgoing: state.outgoing,
            blocked: state.blocked,
            incomingRoomInvites: state.incomingRoomInvites.filter {
                !resolvedRoomInviteIDs.contains($0.id) && $0.id != optimisticDeclinedInviteID
            }
        )
    }

    private func reconcileNetworkAfterAction() {
        // A deferred snapshot may precede this mutation's commit. Merging it
        // here could resurrect a removed friendship or a declined invitation.
        deferredExternalNetworkState = nil
        guard !appState.shouldUsePreviewData else { return }
        networkRefreshGeneration += 1
        let generation = networkRefreshGeneration
        let actorID = appState.user?.id
        let accountGeneration = mutationGeneration
        Task { @MainActor in
            guard appState.user?.id == actorID, mutationGeneration == accountGeneration else { return }
            await refreshNetworkFromServer(generation: generation)
        }
    }

    @MainActor
    private func refreshNetworkFromServer(generation: Int) async {
        let actorID = appState.user?.id
        let accountGeneration = mutationGeneration
        do {
            let rawState = try await appState.client.communityState()
            guard !Task.isCancelled, generation == networkRefreshGeneration,
                  appState.user?.id == actorID, mutationGeneration == accountGeneration else { return }
            if activeAction == nil {
                retireResolvedMarkersConfirmed(by: rawState)
                network = sanitizedNetworkState(rawState)
                reconcileActiveProfileRelationship()
            } else {
                deferredExternalNetworkState = sanitizedNetworkState(rawState)
            }
        } catch {
            // Mutation already succeeded. The shell poll will retry convergence.
        }
    }

    @MainActor
    private func consumeRoomInviteWithRetry(_ inviteID: String, userID: String) async {
        let delays = [0, 300, 900]
        for (index, delay) in delays.enumerated() {
            guard !Task.isCancelled, appState.user?.id == userID else { return }
            if delay > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
            }
            guard appState.user?.id == userID else { return }

            do {
                _ = try await appState.client.communityRoomInviteAction(
                    "consume_room_invite",
                    inviteID: inviteID
                )
                guard appState.user?.id == userID else { return }
                clearPendingRoomInviteCleanup(inviteID, userID: userID)
                await appState.notificationInbox.refreshSummary()
                guard appState.user?.id == userID else { return }
                networkRefreshGeneration += 1
                await refreshNetworkFromServer(generation: networkRefreshGeneration)
                return
            } catch let error as Base44Error
                where CommunityRoomInviteCleanupPolicy.shouldClearAfterFailure(error) {
                guard appState.user?.id == userID else { return }
                clearPendingRoomInviteCleanup(inviteID, userID: userID)
                await appState.notificationInbox.refreshSummary()
                guard appState.user?.id == userID else { return }
                networkRefreshGeneration += 1
                await refreshNetworkFromServer(generation: networkRefreshGeneration)
                return
            } catch {
                guard index == delays.indices.last else { continue }
                // Keep the invite hidden locally. A future accepted-invite retry is safe.
            }
        }
    }

    private func retireResolvedMarkersConfirmed(by state: CommunityState) {
        let stillIncomingRelationshipIDs = Set(state.incoming.map(\.id))
        let stillAcceptedRoomInviteIDs = Set(
            state.incomingRoomInvites
                .filter { $0.status.lowercased() == "accepted" }
                .map(\.id)
        )
        resolvedRelationshipIDs.formIntersection(stillIncomingRelationshipIDs)
        resolvedRoomInviteIDs.formIntersection(stillAcceptedRoomInviteIDs)
    }

    private func persistPendingRoomInviteCleanup(_ inviteID: String, userID: String) {
        let key = pendingRoomInviteCleanupStorageKey(userID: userID)
        var inviteIDs = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        inviteIDs.insert(inviteID)
        UserDefaults.standard.set(Array(inviteIDs).sorted(), forKey: key)
    }

    private func clearPendingRoomInviteCleanup(_ inviteID: String, userID: String) {
        let key = pendingRoomInviteCleanupStorageKey(userID: userID)
        var inviteIDs = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        inviteIDs.remove(inviteID)
        if inviteIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Array(inviteIDs).sorted(), forKey: key)
        }
    }

    private func pendingRoomInviteCleanupStorageKey(userID: String) -> String {
        "spyclash.community-room-invite-cleanup.\(userID)"
    }

    private func relationshipTitle(_ relationship: CommunityRelationshipSummary?) -> String {
        guard let relationship else {
            return localized(en: "AVAILABLE", ru: "ДОСТУПЕН", es: "DISPONIBLE", uk: "ДОСТУПНИЙ")
        }
        switch relationship.status {
        case "accepted": return localized(en: "CONNECTED", ru: "В ДРУЗЬЯХ", es: "CONECTADO", uk: "У ДРУЗЯХ")
        case "pending": return localized(en: "PENDING", ru: "ОЖИДАНИЕ", es: "PENDIENTE", uk: "ОЧІКУВАННЯ")
        default: return localized(en: "AVAILABLE", ru: "ДОСТУПЕН", es: "DISPONIBLE", uk: "ДОСТУПНИЙ")
        }
    }

    private func relationshipAccent(_ relationship: CommunityRelationshipSummary?) -> Color {
        switch relationship?.status {
        case "accepted": SpyTheme.green
        case "pending": SpyTheme.amber
        default: SpyTheme.red
        }
    }

    private func reportReasonTitle(_ reason: CommunityReportReason) -> String {
        switch reason {
        case .harassment:
            localized(en: "HARASSMENT OR BULLYING", ru: "ТРАВЛЯ ИЛИ ДОМОГАТЕЛЬСТВО", es: "ACOSO O INTIMIDACION", uk: "ПЕРЕСЛІДУВАННЯ АБО ЦЬКУВАННЯ")
        case .hateSpeech:
            localized(en: "HATE SPEECH", ru: "ЯЗЫК НЕНАВИСТИ", es: "DISCURSO DE ODIO", uk: "МОВА ВОРОЖНЕЧІ")
        case .sexualContent:
            localized(en: "SEXUAL CONTENT", ru: "СЕКСУАЛЬНЫЙ КОНТЕНТ", es: "CONTENIDO SEXUAL", uk: "СЕКСУАЛЬНИЙ ВМІСТ")
        case .violenceOrThreats:
            localized(en: "VIOLENCE OR THREATS", ru: "НАСИЛИЕ ИЛИ УГРОЗЫ", es: "VIOLENCIA O AMENAZAS", uk: "НАСИЛЬСТВО АБО ПОГРОЗИ")
        case .spam:
            localized(en: "SPAM", ru: "СПАМ", es: "SPAM", uk: "СПАМ")
        case .impersonation:
            localized(en: "IMPERSONATION", ru: "ВЫДАЧА СЕБЯ ЗА ДРУГОГО", es: "SUPLANTACION", uk: "ВИДАВАННЯ СЕБЕ ЗА ІНШУ ОСОБУ")
        case .other:
            localized(en: "OTHER VIOLATION", ru: "ДРУГОЕ НАРУШЕНИЕ", es: "OTRA INFRACCION", uk: "ІНШЕ ПОРУШЕННЯ")
        }
    }

    private func reportPromptMessage(_ target: CommunityReportTarget) -> String {
        localized(
            en: "Select the reason for reporting \(target.displayName). Reports are private and reviewed by moderation.",
            ru: "Выберите причину жалобы на \(target.displayName). Жалобы конфиденциальны и проверяются модерацией.",
            es: "Selecciona el motivo para reportar a \(target.displayName). Los reportes son privados y revisados por moderacion.",
            uk: "Оберіть причину скарги на \(target.displayName). Скарги конфіденційні та розглядаються модерацією."
        )
    }

    private func formattedCommunityDate(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return raw }
        let formatter = DateFormatter()
        let localeIdentifier: String = switch appState.language {
        case .en: "en_US"
        case .ru: "ru_RU"
        case .es: "es_ES"
        case .uk: "uk_UA"
        }
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date).uppercased()
    }

    private func showError(_ error: Error) {
        guard !isCancellation(error) else { return }
        message = error.localizedDescription.uppercased()
        messageKind = .error
        HapticManager.shared.fire(.notification(.error))
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isCancellation(underlying) {
            return true
        }

        let message = nsError.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["cancelled", "canceled", "отменено", "cancelado", "скасовано"].contains(message)
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
        case .uk: uk
        }
    }
}

private enum CommunityReportTarget: Identifiable {
    case user(PublicSpyProfile)
    case comment(CommunityProfileComment)

    var id: String {
        switch self {
        case let .user(profile): "user-\(profile.id)"
        case let .comment(comment): "comment-\(comment.id)"
        }
    }

    var displayName: String {
        switch self {
        case let .user(profile): profile.displayName
        case let .comment(comment): comment.author.displayName
        }
    }
}

enum CommunityTab: String, CaseIterable, Identifiable {
    case exit
    case network
    case me

    var id: String { rawValue }

    static let swipeCases: [CommunityTab] = [.network, .me]

    func swipeNeighbor(for direction: TabSwipeDirection) -> CommunityTab? {
        guard let index = Self.swipeCases.firstIndex(of: self) else { return nil }

        let targetIndex = switch direction {
        case .previous: index - 1
        case .next: index + 1
        }

        guard Self.swipeCases.indices.contains(targetIndex) else { return nil }
        return Self.swipeCases[targetIndex]
    }

    var symbol: String {
        switch self {
        case .exit: "arrow.backward"
        case .network: "person.2.fill"
        case .me: "person.crop.circle.fill"
        }
    }

    func accessibilityLabel(language: AppLanguage) -> String {
        switch (self, language) {
        case (.exit, .ru): "Вернуться назад"
        case (.network, .ru): "Сообщество"
        case (.me, .ru): "Мой публичный профиль"
        case (.exit, .es): "Volver"
        case (.network, .es): "Comunidad"
        case (.me, .es): "Mi perfil publico"
        case (.exit, .uk): "Повернутися назад"
        case (.network, .uk): "Спільнота"
        case (.me, .uk): "Мій публічний профіль"
        case (.exit, _): "Return"
        case (.network, _): "Community"
        case (.me, _): "My public profile"
        }
    }
}

struct CommunityDockRequest: Equatable {
    let id: Int
    let tab: CommunityTab

    static let initial = CommunityDockRequest(id: 0, tab: .network)

    func next(_ tab: CommunityTab) -> CommunityDockRequest {
        CommunityDockRequest(id: id &+ 1, tab: tab)
    }
}

enum CommunitySpyCardSize {
    case full
    case compact
}

enum CommunitySpyCardMetric {
    case rating
    case games
    case spyRate
    case detectiveRate
}

struct CommunitySpyCardCopy {
    let language: AppLanguage

    func metricTitle(_ metric: CommunitySpyCardMetric) -> String {
        switch (metric, language) {
        case (.rating, .ru): "РЕЙТИНГ"
        case (.games, .ru): "ИГРЫ"
        case (.spyRate, .ru): "ШПИОН"
        case (.detectiveRate, .ru): "ДЕТЕКТИВ"
        case (.rating, .es): "RANGO"
        case (.games, .es): "JUEGOS"
        case (.spyRate, .es): "ESPÍA"
        case (.detectiveRate, .es): "DETECTIVE"
        case (.rating, .uk): "РЕЙТИНГ"
        case (.games, .uk): "ІГРИ"
        case (.spyRate, .uk): "ШПИГУН"
        case (.detectiveRate, .uk): "ДЕТЕКТИВ"
        case (.rating, _): "RATING"
        case (.games, _): "GAMES"
        case (.spyRate, _): "SPY"
        case (.detectiveRate, _): "DETECTIVE"
        }
    }

    func accessibilityLabel(for profile: PublicSpyProfile) -> String {
        switch language {
        case .en:
            "Spy card, \(profile.displayName), Spy ID \(profile.spyID), rating \(profile.rating), \(profile.gamesPlayed) games, spy win rate \(profile.spyWinRate) percent, \(profile.spyGamesWon) wins in \(profile.spyGamesPlayed) games, detective win rate \(profile.detectiveWinRate) percent, \(profile.detectiveGamesWon) wins in \(profile.detectiveGamesPlayed) games"
        case .es:
            "Tarjeta de espía, \(profile.displayName), identificador \(profile.spyID), rango \(profile.rating), \(profile.gamesPlayed) juegos, victorias como espía \(profile.spyWinRate) por ciento, \(profile.spyGamesWon) de \(profile.spyGamesPlayed), victorias como detective \(profile.detectiveWinRate) por ciento, \(profile.detectiveGamesWon) de \(profile.detectiveGamesPlayed)"
        case .ru:
            "Карта оперативника, \(profile.displayName), идентификатор \(profile.spyID), рейтинг \(profile.rating), игр \(profile.gamesPlayed), винрейт за шпиона \(profile.spyWinRate) процентов, побед \(profile.spyGamesWon) из \(profile.spyGamesPlayed), винрейт за детектива \(profile.detectiveWinRate) процентов, побед \(profile.detectiveGamesWon) из \(profile.detectiveGamesPlayed)"
        case .uk:
            "Картка оперативника, \(profile.displayName), ідентифікатор \(profile.spyID), рейтинг \(profile.rating), ігор \(profile.gamesPlayed), відсоток перемог за шпигуна \(profile.spyWinRate), перемог \(profile.spyGamesWon) із \(profile.spyGamesPlayed), відсоток перемог за детектива \(profile.detectiveWinRate), перемог \(profile.detectiveGamesWon) із \(profile.detectiveGamesPlayed)"
        }
    }
}

struct CommunitySpyCard: View {
    let profile: PublicSpyProfile
    let language: AppLanguage
    let size: CommunitySpyCardSize

    init(
        profile: PublicSpyProfile,
        language: AppLanguage,
        size: CommunitySpyCardSize = .full
    ) {
        self.profile = profile
        self.language = language
        self.size = size
    }

    private var accent: Color {
        switch SpyCardAccentID(rawValue: profile.spyCardAccent) ?? .signalRed {
        case .signalRed: SpyTheme.red
        case .clearanceAmber: SpyTheme.amber
        case .verifiedGreen: SpyTheme.green
        }
    }

    private var themeColors: [Color] {
        switch theme {
        case .field:
            [Color.white.opacity(0.085), Color.white.opacity(0.018), Color.black.opacity(0.24)]
        case .blacksite:
            [Color.white.opacity(0.035), Color.black.opacity(0.42), Color.black.opacity(0.82)]
        case .dossier:
            [SpyTheme.red.opacity(0.14), Color.white.opacity(0.025), Color.black.opacity(0.46)]
        }
    }

    private var theme: SpyCardThemeID {
        SpyCardThemeID(rawValue: profile.spyCardTheme) ?? .field
    }

    private var badge: SpyCardBadgeID {
        SpyCardBadgeID(rawValue: profile.spyCardBadge) ?? .operative
    }

    private var copy: CommunitySpyCardCopy {
        CommunitySpyCardCopy(language: language)
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch size {
            case .full:
                fullCard
            case .compact:
                compactCard
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spyCardAccessibilityLabel)
    }

    private var spyCardAccessibilityLabel: String {
        copy.accessibilityLabel(for: profile)
    }

    private var fullCard: some View {
        GeometryReader { proxy in
            let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SpyBrandMark()
                        .frame(width: 28, height: 36)
                        .offset(x: -2)

                    HStack(spacing: 6) {
                        Text(badgeGlyph)
                            .foregroundStyle(accent)
                        Text(badgeTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.6)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(accent.opacity(0.075), in: Capsule())
                    .overlay(Capsule().stroke(accent.opacity(0.30), lineWidth: 0.75))

                    Spacer(minLength: 12)

                    HStack(spacing: 5) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text(publicTitle)
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(accent)
                    }
                }
                .padding(.leading, 13)
                .padding(.trailing, 17)
                .frame(height: 50)

                LinearGradient(colors: [.clear, Color.white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 13) {
                        Text(profile.avatar)
                            .font(.system(size: 29))
                            .frame(width: 52, height: 52)
                            .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.38), lineWidth: 1))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.displayName.uppercased())
                                .font(SpyTheme.brandFont(size: 24))
                                .tracking(0.9)
                                .foregroundStyle(.white)
                                .spyFitted(lines: 1, scale: 0.62)

                            Text("SPYID • \(profile.spyID)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.42))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .top, spacing: 6) {
                        metric(copy.metricTitle(.rating), value: signedRating, color: SpyTheme.red)
                        metric(copy.metricTitle(.games), value: "\(profile.gamesPlayed)", color: SpyTheme.amber)
                        roleMetric(
                            copy.metricTitle(.spyRate),
                            value: "\(profile.spyWinRate)%",
                            wins: profile.spyGamesWon,
                            games: profile.spyGamesPlayed,
                            color: SpyTheme.red
                        )
                        roleMetric(
                            copy.metricTitle(.detectiveRate),
                            value: "\(profile.detectiveWinRate)%",
                            wins: profile.detectiveGamesWon,
                            games: profile.detectiveGamesPlayed,
                            color: SpyTheme.green
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 17)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .frame(width: proxy.size.width, height: proxy.size.width / 1.50)
            .background {
                ZStack {
                    cardShape.fill(.ultraThinMaterial).opacity(profile.spyCardTheme == SpyCardThemeID.field.rawValue ? 1 : 0.46)
                    cardShape.fill(Color.black.opacity(profile.spyCardTheme == SpyCardThemeID.blacksite.rawValue ? 0.78 : 0.34))
                    cardShape.fill(LinearGradient(colors: themeColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    cardShape.fill(RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: proxy.size.width * 0.58))
                    cardShape.fill(RadialGradient(colors: [accent.opacity(0.11), .clear], center: .bottomTrailing, startRadius: 0, endRadius: proxy.size.width * 0.66))
                    SpyCardSurfacePattern(theme: theme, accent: accent)
                        .clipShape(cardShape)
                }
            }
            .clipShape(cardShape)
            .overlay(cardShape.stroke(LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.07), accent.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: accent.opacity(0.10), radius: 18, y: 8)
            .shadow(color: .black.opacity(0.42), radius: 24, y: 14)
        }
        .aspectRatio(1.50, contentMode: .fit)
    }

    private var compactCard: some View {
        GeometryReader { proxy in
            let scale = min(max(proxy.size.width / 180, 0.82), 1.12)
            let cardShape = RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)

            VStack(spacing: 0) {
                HStack(spacing: 5 * scale) {
                    SpyBrandMark()
                        .frame(width: 13 * scale, height: 18 * scale)

                    Text(badgeGlyph)
                        .font(.system(size: 6.5 * scale, weight: .black, design: .monospaced))
                        .foregroundStyle(accent)

                    Spacer(minLength: 4)

                    Circle()
                        .fill(accent)
                        .frame(width: 4 * scale, height: 4 * scale)

                    Text(publicTitle)
                        .font(.system(size: 4.8 * scale, weight: .black, design: .monospaced))
                        .tracking(0.2)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8 * scale)
                .frame(height: 25 * scale)

                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)

                VStack(alignment: .leading, spacing: 4 * scale) {
                    HStack(alignment: .center, spacing: 7 * scale) {
                        Text(profile.avatar)
                            .font(.system(size: 18 * scale))
                            .frame(width: 31 * scale, height: 31 * scale)
                            .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7 * scale).stroke(accent.opacity(0.38), lineWidth: 1))

                        VStack(alignment: .leading, spacing: 2 * scale) {
                            Text(profile.displayName.uppercased())
                                .font(SpyTheme.brandFont(size: 10.5 * scale))
                                .tracking(0.3)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.58)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("SPYID • \(profile.spyID)")
                                .font(.system(size: 4.8 * scale, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .top, spacing: 3 * scale) {
                        compactMetric(copy.metricTitle(.rating), value: signedRating, color: SpyTheme.red)
                        compactMetric(copy.metricTitle(.games), value: "\(profile.gamesPlayed)", color: SpyTheme.amber)
                        compactMetric(copy.metricTitle(.spyRate), value: "\(profile.spyWinRate)%", color: SpyTheme.red)
                        compactMetric(copy.metricTitle(.detectiveRate), value: "\(profile.detectiveWinRate)%", color: SpyTheme.green)
                    }
                }
                .padding(.horizontal, 8 * scale)
                .padding(.top, 6 * scale)
                .padding(.bottom, 7 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.width / 1.50)
            .background {
                ZStack {
                    cardShape.fill(SpyTheme.panel)
                    cardShape.fill(Color.black.opacity(profile.spyCardTheme == SpyCardThemeID.blacksite.rawValue ? 0.72 : 0.28))
                    cardShape.fill(LinearGradient(colors: themeColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    cardShape.fill(RadialGradient(colors: [accent.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: proxy.size.width * 0.82))
                    SpyCardSurfacePattern(theme: theme, accent: accent)
                        .clipShape(cardShape)
                }
            }
            .clipShape(cardShape)
            .overlay(
                cardShape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.06), accent.opacity(0.24)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: accent.opacity(0.08), radius: 10, y: 5)
            .shadow(color: .black.opacity(0.34), radius: 14, y: 8)
        }
        .aspectRatio(1.50, contentMode: .fit)
    }

    private var signedRating: String { "\(profile.rating >= 0 ? "+" : "")\(profile.rating)" }

    private var badgeGlyph: String {
        switch badge {
        case .operative: "◆"
        case .ghost: "◌"
        case .analyst: "⌁"
        case .handler: "▲"
        }
    }

    private var badgeTitle: String {
        switch (badge, language) {
        case (.operative, .ru): "ОПЕРАТИВНИК"
        case (.ghost, .ru): "ПРИЗРАК"
        case (.analyst, .ru): "АНАЛИТИК"
        case (.handler, .ru): "КУРАТОР"
        case (.operative, .es): "OPERATIVO"
        case (.ghost, .es): "FANTASMA"
        case (.analyst, .es): "ANALISTA"
        case (.handler, .es): "CONTROL"
        case (.operative, .uk): "ОПЕРАТИВНИК"
        case (.ghost, .uk): "ПРИВИД"
        case (.analyst, .uk): "АНАЛІТИК"
        case (.handler, .uk): "КУРАТОР"
        case (.operative, _): "OPERATIVE"
        case (.ghost, _): "GHOST"
        case (.analyst, _): "ANALYST"
        case (.handler, _): "HANDLER"
        }
    }

    private var publicTitle: String {
        switch language {
        case .en: "PUBLIC"
        case .ru: "ПУБЛИЧНЫЙ"
        case .es: "PÚBLICO"
        case .uk: "ПУБЛІЧНИЙ"
        }
    }

    private func metric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(SpyTheme.brandFont(size: 20))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundStyle(color.opacity(0.58))
                .spyFitted(scale: 0.60)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roleMetric(
        _ title: String,
        value: String,
        wins: Int,
        games: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(SpyTheme.brandFont(size: 20))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(title)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundStyle(color.opacity(0.68))
                .spyFitted(scale: 0.54)

            Text("\(wins)/\(games)")
                .font(.system(size: 6, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.36))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactMetric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(SpyTheme.brandFont(size: 11))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.60)

            Text(title)
                .font(.system(size: 4.2, weight: .black, design: .monospaced))
                .foregroundStyle(color.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum CommunityPreview {
    static let me = PublicSpyProfile(
        id: "debug-ui-preview-user",
        spyID: "350-911",
        displayName: "Red Raven",
        avatar: "🕵️",
        spyCardTheme: "field",
        spyCardAccent: "signal_red",
        spyCardBadge: "operative",
        rating: 360,
        gamesPlayed: 19,
        gamesWon: 12,
        winRate: 63,
        spyGamesPlayed: 9,
        spyGamesWon: 5,
        spyWinRate: 56,
        detectiveGamesPlayed: 10,
        detectiveGamesWon: 7,
        detectiveWinRate: 70
    )

    static let cipher = PublicSpyProfile(
        id: "preview-cipher",
        spyID: "104-827",
        displayName: "Cipher",
        avatar: "🎭",
        spyCardTheme: "blacksite",
        spyCardAccent: "signal_red",
        spyCardBadge: "ghost",
        rating: 150,
        gamesPlayed: 11,
        gamesWon: 7,
        winRate: 64,
        spyGamesPlayed: 4,
        spyGamesWon: 2,
        spyWinRate: 50,
        detectiveGamesPlayed: 7,
        detectiveGamesWon: 5,
        detectiveWinRate: 71
    )

    static let signal = PublicSpyProfile(
        id: "preview-signal",
        spyID: "777-123",
        displayName: "Signal",
        avatar: "🔥",
        spyCardTheme: "dossier",
        spyCardAccent: "clearance_amber",
        spyCardBadge: "analyst",
        rating: 90,
        gamesPlayed: 3,
        gamesWon: 3,
        winRate: 100,
        spyGamesPlayed: 1,
        spyGamesWon: 1,
        spyWinRate: 100,
        detectiveGamesPlayed: 2,
        detectiveGamesWon: 2,
        detectiveWinRate: 100
    )

    static let night = PublicSpyProfile(
        id: "preview-night",
        spyID: "220-416",
        displayName: "Night Index",
        avatar: "👁️",
        spyCardTheme: "blacksite",
        spyCardAccent: "verified_green",
        spyCardBadge: "handler",
        rating: 210,
        gamesPlayed: 16,
        gamesWon: 10,
        winRate: 63,
        spyGamesPlayed: 7,
        spyGamesWon: 3,
        spyWinRate: 43,
        detectiveGamesPlayed: 9,
        detectiveGamesWon: 7,
        detectiveWinRate: 78
    )

    static let directory = [me, cipher, signal, night]

    static func profile(userID: String, viewerID: String?) -> CommunityProfileDetail? {
        guard let profile = directory.first(where: { $0.id == userID }) else { return nil }
        let isSelf = profile.id == viewerID
        let friends = profile.id == cipher.id ? [signal, night] : [cipher]
        let relationship = isSelf ? nil : CommunityRelationshipSummary(
            id: "preview-relationship-\(profile.id)",
            status: profile.id == cipher.id ? "accepted" : "pending",
            direction: profile.id == signal.id ? "incoming" : "outgoing"
        )
        let comments = isSelf ? [
            CommunityProfileComment(
                id: "preview-comment",
                body: "Calm under pressure. Would queue again.",
                createdAt: "2026-07-14T08:12:00Z",
                author: cipher,
                canDelete: true
            )
        ] : []
        return CommunityProfileDetail(
            profile: profile,
            isSelf: isSelf,
            relationship: relationship,
            friends: friends,
            comments: comments
        )
    }
}

private extension CommunityState {
    static let preview = CommunityState(
        me: CommunityPreview.me,
        friends: [
            CommunityRelationship(
                id: "friend-1",
                status: "accepted",
                direction: "outgoing",
                profile: CommunityPreview.cipher
            )
        ],
        incoming: [
            CommunityRelationship(
                id: "incoming-1",
                status: "pending",
                direction: "incoming",
                profile: CommunityPreview.signal
            )
        ],
        outgoing: [],
        blocked: [
            CommunityRelationship(
                id: "blocked-1",
                status: "blocked",
                direction: "outgoing",
                profile: CommunityPreview.night
            )
        ],
        incomingRoomInvites: [
            CommunityRoomInvite(
                id: "room-invite-1",
                status: "pending",
                roomID: "preview-room",
                roomCode: "S6RC3V",
                createdAt: "2026-07-14T08:10:00Z",
                sender: CommunityPreview.night
            )
        ]
    )
}
