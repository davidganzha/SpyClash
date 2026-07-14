import SwiftUI
import UIKit

struct CommunityView: View {
    @Environment(AppState.self) private var appState

    @State private var network: CommunityState?
    @State private var query = ""
    @State private var searchResult: CommunitySearchResult?
    @State private var isLoading = false
    @State private var activeAction: String?
    @State private var message = ""
    @State private var messageKind: SpyToast.Kind = .success

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PageChrome(
                eyebrow: localized(en: "// COMMUNITY", ru: "// СООБЩЕСТВО", es: "// COMUNIDAD"),
                status: localized(en: "SPY NETWORK", ru: "СЕТЬ SPY", es: "RED SPY"),
                showsPageTopEdge: false,
                topReserve: 0
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    identityPanel
                    searchPanel

                    if let searchResult {
                        searchResultPanel(searchResult)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let network {
                        if !network.incoming.isEmpty {
                            relationshipSection(
                                title: localized(en: "INCOMING", ru: "ВХОДЯЩИЕ", es: "ENTRANTES"),
                                records: network.incoming,
                                mode: .incoming
                            )
                        }

                        relationshipSection(
                            title: localized(en: "OPERATIVES", ru: "ОПЕРАТИВНИКИ", es: "OPERATIVOS"),
                            records: network.friends,
                            mode: .friends
                        )

                        if !network.outgoing.isEmpty {
                            relationshipSection(
                                title: localized(en: "PENDING", ru: "ОЖИДАЮТ", es: "PENDIENTES"),
                                records: network.outgoing,
                                mode: .outgoing
                            )
                        }
                    }

                    if !message.isEmpty {
                        SpyToast(text: message, kind: messageKind)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 52)
                .animation(.smooth(duration: 0.24), value: searchResult?.profile.id)
            }

            closeButton
        }
        .task { await load() }
    }

    private var closeButton: some View {
        Button {
            HapticManager.shared.fire(.navigation)
            appState.presentedSheet = nil
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(SpyTheme.muted)
                .frame(width: 46, height: 46)
                .background(SpyTheme.dark)
                .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.strokeStrong, lineWidth: 1))
                .clipShape(CutCornerShape(cut: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .padding(.top, 6)
        .padding(.trailing, 18)
        .accessibilityLabel(localized(en: "Close", ru: "Закрыть", es: "Cerrar"))
    }

    private var identityPanel: some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0.04) {
            VStack(alignment: .leading, spacing: 13) {
                SpySceneKicker(
                    title: localized(en: "YOUR SPY ID", ru: "ТВОЙ SPY ID", es: "TU SPY ID"),
                    status: localized(en: "PUBLIC", ru: "ПУБЛИЧНЫЙ", es: "PUBLICO"),
                    accent: SpyTheme.red
                )

                if let me = network?.me {
                    HStack(alignment: .center, spacing: 12) {
                        Text(me.avatar)
                            .font(.system(size: 28))
                            .frame(width: 50, height: 50)
                            .background(SpyTheme.black)
                            .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(me.displayName.uppercased())
                                .font(SpyTheme.brandFont(size: 21))
                                .tracking(0.8)
                                .foregroundStyle(.white)
                                .spyFitted()

                            Text(me.spyID)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(SpyTheme.red)
                                .spyFitted()
                        }

                        Spacer(minLength: 4)

                        Button {
                            UIPasteboard.general.string = me.spyID
                            message = localized(en: "SPY ID COPIED", ru: "SPY ID СКОПИРОВАН", es: "SPY ID COPIADO")
                            messageKind = .success
                            HapticManager.shared.fire(.notification(.success), sound: .copyConfirm)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(SpyTheme.red)
                                .frame(width: 44, height: 44)
                                .overlay(Rectangle().stroke(SpyTheme.red.opacity(0.42), lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SpyWebPressStyle())
                    }
                } else {
                    loadingLine
                }

                Text(localized(
                    en: "Share this ID to let another operative find you without exposing private account data.",
                    ru: "Передай этот ID, чтобы тебя нашли без раскрытия личных данных аккаунта.",
                    es: "Comparte este ID para que te encuentren sin revelar datos privados de tu cuenta."
                ))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(SpyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var searchPanel: some View {
        SpyPanel(motionDelay: 0.10) {
            VStack(alignment: .leading, spacing: 12) {
                SpySceneKicker(
                    title: localized(en: "FIND OPERATIVE", ru: "НАЙТИ ОПЕРАТИВНИКА", es: "BUSCAR OPERATIVO"),
                    status: nil,
                    accent: SpyTheme.muted
                )

                HStack(spacing: 8) {
                    TextField("000-000", text: $query)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(SpyTheme.black)
                        .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.inputBorder, lineWidth: 1))
                        .clipShape(CutCornerShape(cut: 7))
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                        .onChange(of: query) { _, newValue in
                            let formatted = SpyID.formatInput(newValue)
                            if query != formatted { query = formatted }
                            searchResult = nil
                        }
                        .accessibilityLabel(localized(en: "Six digit SPY ID", ru: "Шестизначный SPY ID", es: "SPY ID de seis digitos"))

                    Button {
                        Task { await search() }
                    } label: {
                        Group {
                            if activeAction == "search" {
                                SpySpinner(size: 18, accent: .white)
                            } else {
                                Image(systemName: "scope")
                                    .font(.system(size: 19, weight: .black))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 52)
                        .background(SpyTheme.red)
                        .clipShape(CutCornerShape(cut: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(activeAction != nil || SpyID.normalize(query) == nil)
                }
            }
        }
    }

    private func searchResultPanel(_ result: CommunitySearchResult) -> some View {
        SpyPanel(accent: relationshipAccent(result), motionDelay: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SpySceneKicker(
                    title: localized(en: "SEARCH RESULT", ru: "РЕЗУЛЬТАТ ПОИСКА", es: "RESULTADO"),
                    status: relationshipStatus(result),
                    accent: relationshipAccent(result)
                )

                operativeIdentity(result.profile)

                if canSendRequest(result) {
                    Button {
                        Task { await sendRequest(to: result.profile.spyID) }
                    } label: {
                        SpyPrimaryCommandLabel(
                            title: localized(en: "SEND REQUEST", ru: "ДОБАВИТЬ В ДРУЗЬЯ", es: "ENVIAR SOLICITUD"),
                            detail: nil,
                            systemImage: "person.badge.plus"
                        )
                    }
                    .buttonStyle(SpyPrimaryCommandStyle())
                    .disabled(activeAction != nil)
                }
            }
        }
    }

    private func relationshipSection(
        title: String,
        records: [CommunityRelationship],
        mode: RelationshipMode
    ) -> some View {
        SpyPanel(accent: mode == .incoming ? SpyTheme.amber : SpyTheme.red, motionDelay: 0.16) {
            VStack(alignment: .leading, spacing: 10) {
                SpySceneKicker(
                    title: "\(title) // \(records.count)",
                    status: nil,
                    accent: mode == .incoming ? SpyTheme.amber : SpyTheme.muted
                )

                if records.isEmpty {
                    Text(localized(
                        en: "NO OPERATIVES LINKED YET",
                        ru: "ПОКА НЕТ СВЯЗАННЫХ ОПЕРАТИВНИКОВ",
                        es: "AUN NO HAY OPERATIVOS VINCULADOS"
                    ))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(SpyTheme.faint)
                    .padding(.vertical, 12)
                } else {
                    ForEach(records) { record in
                        relationshipRow(record, mode: mode)
                    }
                }
            }
        }
    }

    private func relationshipRow(_ record: CommunityRelationship, mode: RelationshipMode) -> some View {
        VStack(spacing: 10) {
            operativeIdentity(record.profile)

            HStack(spacing: 8) {
                switch mode {
                case .incoming:
                    actionButton(
                        localized(en: "ACCEPT", ru: "ПРИНЯТЬ", es: "ACEPTAR"),
                        icon: "checkmark",
                        color: SpyTheme.green
                    ) { await relationshipAction("accept", record.id) }
                    actionButton(
                        localized(en: "DECLINE", ru: "ОТКЛОНИТЬ", es: "RECHAZAR"),
                        icon: "xmark",
                        color: SpyTheme.muted
                    ) { await relationshipAction("decline", record.id) }
                case .outgoing:
                    actionButton(
                        localized(en: "CANCEL REQUEST", ru: "ОТМЕНИТЬ ЗАПРОС", es: "CANCELAR SOLICITUD"),
                        icon: "xmark",
                        color: SpyTheme.muted
                    ) { await relationshipAction("cancel_request", record.id) }
                case .friends:
                    actionButton(
                        localized(en: "REMOVE", ru: "УДАЛИТЬ", es: "ELIMINAR"),
                        icon: "person.badge.minus",
                        color: SpyTheme.red
                    ) { await relationshipAction("remove_friend", record.id) }
                }
            }
        }
        .padding(12)
        .background(SpyTheme.black.opacity(0.72))
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func operativeIdentity(_ profile: PublicSpyProfile) -> some View {
        HStack(spacing: 11) {
            Text(profile.avatar)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(SpyTheme.black)
                .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName.uppercased())
                    .font(SpyTheme.brandFont(size: 19))
                    .tracking(0.7)
                    .foregroundStyle(.white)
                    .spyFitted()

                Text(profile.spyID)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted()
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(profile.gamesPlayed)")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyTheme.red)
                Text(localized(en: "ONLINE", ru: "ОНЛАЙН", es: "ONLINE"))
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(SpyTheme.faint)
            }
        }
    }

    private func actionButton(
        _ title: String,
        icon: String,
        color: Color,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
                Text(title)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.5)
                    .spyFitted(scale: 0.58, alignment: .center)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(Rectangle().stroke(color.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(activeAction != nil)
    }

    private var loadingLine: some View {
        HStack(spacing: 10) {
            SpySpinner(size: 18, accent: SpyTheme.red)
            Text(localized(en: "SYNCING NETWORK", ru: "СИНХРОНИЗАЦИЯ СЕТИ", es: "SINCRONIZANDO RED"))
                .font(SpyTheme.micro)
                .tracking(0.8)
                .foregroundStyle(SpyTheme.muted)
        }
        .frame(minHeight: 52)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if appState.shouldUsePreviewData {
            network = .preview
            return
        }

        do {
            network = try await appState.client.communityState()
        } catch {
            // Initial synchronization is passive. Surface the failure without
            // sounding an alarm for an action the user did not initiate.
            message = error.localizedDescription.uppercased()
            messageKind = .error
        }
    }

    private func search() async {
        guard activeAction == nil else { return }
        guard let spyID = SpyID.normalize(query) else {
            message = localized(
                en: "ENTER A SIX-DIGIT SPY ID",
                ru: "ВВЕДИ ШЕСТИЗНАЧНЫЙ SPY ID",
                es: "INTRODUCE UN SPY ID DE SEIS DIGITOS"
            )
            messageKind = .error
            HapticManager.shared.fire(.notification(.error))
            return
        }
        activeAction = "search"
        defer { activeAction = nil }
        searchResult = nil
        message = ""

        do {
            searchResult = try await appState.client.searchCommunity(spyID: spyID)
            HapticManager.shared.fire(.tabSelection, sound: .echoBlip)
        } catch {
            showError(error)
        }
    }

    private func sendRequest(to spyID: String) async {
        guard activeAction == nil else { return }
        activeAction = "send"
        defer { activeAction = nil }
        do {
            network = try await appState.client.sendFriendRequest(spyID: spyID)
            searchResult = try await appState.client.searchCommunity(spyID: spyID)
            message = localized(en: "REQUEST TRANSMITTED", ru: "ЗАПРОС ОТПРАВЛЕН", es: "SOLICITUD ENVIADA")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success), sound: .allow)
        } catch {
            showError(error)
        }
    }

    private func relationshipAction(_ action: String, _ friendshipID: String) async {
        guard activeAction == nil else { return }
        activeAction = friendshipID
        defer { activeAction = nil }
        do {
            network = try await appState.client.communityRelationshipAction(action, friendshipID: friendshipID)
            if searchResult?.relationship?.id == friendshipID {
                searchResult = try? await appState.client.searchCommunity(spyID: searchResult?.profile.spyID ?? "")
            }
            let cue: HapticManager.SoundCue = action == "accept" ? .playerJoin : .playerLeave
            HapticManager.shared.fire(.notification(.success), sound: cue)
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        message = error.localizedDescription.uppercased()
        messageKind = .error
        HapticManager.shared.fire(.notification(.error))
    }

    private func canSendRequest(_ result: CommunitySearchResult) -> Bool {
        guard !result.isSelf else { return false }
        guard let relationship = result.relationship else { return true }
        return relationship.status == "declined"
    }

    private func relationshipStatus(_ result: CommunitySearchResult) -> String {
        if result.isSelf { return localized(en: "YOU", ru: "ЭТО ТЫ", es: "ERES TU") }
        guard let relationship = result.relationship else {
            return localized(en: "AVAILABLE", ru: "ДОСТУПЕН", es: "DISPONIBLE")
        }
        switch relationship.status {
        case "accepted": return localized(en: "CONNECTED", ru: "В ДРУЗЬЯХ", es: "CONECTADO")
        case "pending": return localized(en: "PENDING", ru: "ОЖИДАНИЕ", es: "PENDIENTE")
        default: return localized(en: "AVAILABLE", ru: "ДОСТУПЕН", es: "DISPONIBLE")
        }
    }

    private func relationshipAccent(_ result: CommunitySearchResult) -> Color {
        result.relationship?.status == "accepted" ? SpyTheme.green : SpyTheme.red
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
        }
    }
}

private enum RelationshipMode: Equatable {
    case incoming
    case outgoing
    case friends
}

private extension CommunityState {
    static let previewProfile = PublicSpyProfile(
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
        winRate: 64
    )

    static let preview = CommunityState(
        me: PublicSpyProfile(
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
            winRate: 63
        ),
        friends: [
            CommunityRelationship(id: "friend-1", status: "accepted", direction: "outgoing", profile: previewProfile)
        ],
        incoming: [
            CommunityRelationship(
                id: "incoming-1",
                status: "pending",
                direction: "incoming",
                profile: PublicSpyProfile(
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
                    winRate: 100
                )
            )
        ],
        outgoing: []
    )
}
