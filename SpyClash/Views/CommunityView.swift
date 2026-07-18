import SwiftUI
import UIKit

struct CommunityView: View {
    @Environment(AppState.self) private var appState
    @Namespace private var dockNamespace

    let onExit: () -> Void

    @State private var selectedTab: CommunityTab = .network
    @State private var network: CommunityState?
    @State private var directory: [PublicSpyProfile] = []
    @State private var nextDirectoryOffset: Int?
    @State private var query = ""
    @State private var activeProfile: CommunityProfileDetail?
    @State private var profileCache: [String: CommunityProfileDetail] = [:]
    @State private var profileRequestID: UUID?
    @State private var profileHistory: [String] = []
    @State private var commentDraft = ""
    @State private var isInitialLoading = true
    @State private var isDirectoryLoading = false
    @State private var isProfileLoading = false
    @State private var didLoadInitialContent = false
    @State private var activeAction: String?
    @State private var message = ""
    @State private var messageKind: SpyToast.Kind = .success
    @State private var reportTarget: CommunityReportTarget?
    @State private var blockTarget: PublicSpyProfile?
    @State private var unblockTarget: CommunityRelationship?

    var body: some View {
        ZStack(alignment: .bottom) {
            PageChrome(
                eyebrow: localized(en: "// COMMUNITY", ru: "// СООБЩЕСТВО", es: "// COMUNIDAD"),
                status: localized(en: "OPERATIVE NETWORK", ru: "СЕТЬ ОПЕРАТИВНИКОВ", es: "RED DE OPERATIVOS"),
                showsPageTopEdge: false,
                topReserve: 0
            ) {
                sceneContent
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 92)
            }

            CommunityDock(
                selection: selectedTab,
                namespace: dockNamespace,
                language: appState.language,
                action: handleDockAction
            )
            .zIndex(20)
        }
        .background(SpyTheme.black)
        .task { await loadInitialContent() }
        .task(id: query) {
            guard didLoadInitialContent else { return }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await loadDirectory(reset: true)
        }
        .confirmationDialog(
            localized(en: "REPORT CONTENT", ru: "ПОЖАЛОВАТЬСЯ", es: "REPORTAR CONTENIDO"),
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
            Button(localized(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR"), role: .cancel) {
                reportTarget = nil
            }
        } message: { target in
            Text(reportPromptMessage(target))
        }
        .confirmationDialog(
            localized(en: "BLOCK OPERATIVE?", ru: "ЗАБЛОКИРОВАТЬ?", es: "BLOQUEAR OPERATIVO?"),
            isPresented: blockPromptPresented,
            titleVisibility: .visible,
            presenting: blockTarget
        ) { target in
            Button(localized(en: "BLOCK AND REMOVE CONTACT", ru: "ЗАБЛОКИРОВАТЬ И УДАЛИТЬ СВЯЗЬ", es: "BLOQUEAR Y ELIMINAR CONTACTO"), role: .destructive) {
                blockTarget = nil
                Task { await blockOperative(target) }
            }
            Button(localized(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR"), role: .cancel) {
                blockTarget = nil
            }
        } message: { target in
            Text(localized(
                en: "You and \(target.displayName) will no longer find or open each other's profiles, comment, or send room invites. Existing comments and invites between you are removed.",
                ru: "Вы с \(target.displayName) больше не сможете находить профили друг друга, оставлять записи или отправлять приглашения. Существующие записи и приглашения будут удалены.",
                es: "Tu y \(target.displayName) dejaran de encontrar o abrir sus perfiles, comentar o enviar invitaciones. Se eliminaran los comentarios e invitaciones existentes."
            ))
        }
        .confirmationDialog(
            localized(en: "UNBLOCK OPERATIVE?", ru: "РАЗБЛОКИРОВАТЬ?", es: "DESBLOQUEAR OPERATIVO?"),
            isPresented: unblockPromptPresented,
            titleVisibility: .visible,
            presenting: unblockTarget
        ) { relationship in
            Button(localized(en: "UNBLOCK", ru: "РАЗБЛОКИРОВАТЬ", es: "DESBLOQUEAR")) {
                unblockTarget = nil
                Task { await unblockOperative(relationship) }
            }
            Button(localized(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR"), role: .cancel) {
                unblockTarget = nil
            }
        } message: { relationship in
            Text(localized(
                en: "\(relationship.profile.displayName) may find and contact you in Community again.",
                ru: "\(relationship.profile.displayName) снова сможет найти вас и связаться через Сообщество.",
                es: "\(relationship.profile.displayName) podra encontrarte y contactarte en Comunidad otra vez."
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
            if !message.isEmpty {
                SpyToast(text: message, kind: messageKind)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let activeProfile {
                profileScene(activeProfile)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                directoryScene
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.smooth(duration: 0.24), value: activeProfile?.profile.id)
        .animation(.easeOut(duration: 0.18), value: message)
    }

    private var directoryScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                SpySceneKicker(
                    title: localized(en: "PUBLIC DIRECTORY", ru: "ПУБЛИЧНЫЙ КАТАЛОГ", es: "DIRECTORIO PUBLICO"),
                    status: localized(en: "DISCOVER", ru: "ПОИСК", es: "DESCUBRIR"),
                    accent: SpyTheme.red
                )

                Text(localized(
                    en: "FIND YOUR NEXT OPERATIVE",
                    ru: "НАЙДИ СВОЕГО ОПЕРАТИВНИКА",
                    es: "ENCUENTRA TU OPERATIVO"
                ))
                .font(SpyTheme.brandFont(size: 29))
                .tracking(0.8)
                .foregroundStyle(.white)
                .spyFitted(lines: 2, scale: 0.68)

                Text(localized(
                    en: "Search by callsign or SPYID. Every card is the operative's real public identity.",
                    ru: "Ищи по позывному или SPYID. Каждая карточка — настоящая публичная личность игрока.",
                    es: "Busca por alias o SPYID. Cada tarjeta es la identidad publica real del jugador."
                ))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(SpyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .spyWebEntrance(delay: 0.02, duration: 0.40, y: 10)

            searchField

            HStack {
                Text(localized(en: "OPERATIVES", ru: "ОПЕРАТИВНИКИ", es: "OPERATIVOS"))
                    .font(SpyTheme.micro)
                    .tracking(1.2)
                    .foregroundStyle(SpyTheme.dim)

                Spacer()

                Text("\(directory.count)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyTheme.red)
            }

            if directory.isEmpty, !isDirectoryLoading, !isInitialLoading {
                emptyDirectory
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
                        .accessibilityHint(localized(en: "Open public profile", ru: "Открыть публичный профиль", es: "Abrir perfil publico"))
                        .spyWebEntrance(delay: min(Double(index) * 0.035, 0.24), duration: 0.42, y: 12, scale: 0.99)
                    }
                }
            }

            if isDirectoryLoading || isInitialLoading {
                HStack(spacing: 9) {
                    SpySpinner(size: 16, accent: SpyTheme.red)
                    Text(localized(en: "SCANNING NETWORK", ru: "СКАНИРОВАНИЕ СЕТИ", es: "ESCANEANDO RED"))
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
                        localized(en: "LOAD MORE OPERATIVES", ru: "ЗАГРУЗИТЬ ЕЩЕ", es: "CARGAR MAS"),
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

            TextField(
                localized(en: "CALLSIGN OR 000-000", ru: "ПОЗЫВНОЙ ИЛИ 000-000", es: "ALIAS O 000-000"),
                text: $query
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .submitLabel(.search)

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
                .accessibilityLabel(localized(en: "Clear search", ru: "Очистить поиск", es: "Borrar busqueda"))
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

            Text(localized(en: "NO OPERATIVES FOUND", ru: "ОПЕРАТИВНИКИ НЕ НАЙДЕНЫ", es: "NO SE ENCONTRARON OPERATIVOS"))
                .font(SpyTheme.micro)
                .tracking(0.8)
                .foregroundStyle(SpyTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func profileScene(_ detail: CommunityProfileDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            profileNavigation(detail)

            CommunitySpyCard(profile: detail.profile, language: appState.language)
                .spyWebEntrance(delay: 0, duration: 0.30, y: 8, scale: 0.992)

            if isProfileLoading {
                HStack(spacing: 10) {
                    SpySpinner(size: 18, accent: SpyTheme.red)
                    Text(localized(en: "SYNCING SOCIAL INTEL", ru: "СИНХРОНИЗАЦИЯ СВЯЗЕЙ", es: "SINCRONIZANDO RED"))
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
                .accessibilityLabel(localized(en: "Back to community", ru: "Назад в сообщество", es: "Volver a comunidad"))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(detail.isSelf
                    ? localized(en: "MY PUBLIC PROFILE", ru: "МОЙ ПУБЛИЧНЫЙ ПРОФИЛЬ", es: "MI PERFIL PUBLICO")
                    : localized(en: "PUBLIC DOSSIER", ru: "ПУБЛИЧНОЕ ДОСЬЕ", es: "EXPEDIENTE PUBLICO"))
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

    @ViewBuilder
    private func relationshipCommands(_ detail: CommunityProfileDetail) -> some View {
        SpyPanel(accent: relationshipAccent(detail.relationship), motionDelay: 0.05) {
            VStack(alignment: .leading, spacing: 11) {
                SpySceneKicker(
                    title: localized(en: "CONNECTION", ru: "СВЯЗЬ", es: "CONEXION"),
                    status: relationshipTitle(detail.relationship),
                    accent: relationshipAccent(detail.relationship)
                )

                relationshipButtons(detail)

                HStack(spacing: 9) {
                    communityActionButton(
                        localized(en: "REPORT", ru: "ЖАЛОБА", es: "REPORTAR"),
                        icon: "flag.fill",
                        color: SpyTheme.amber
                    ) {
                        reportTarget = .user(detail.profile)
                    }

                    communityActionButton(
                        localized(en: "BLOCK", ru: "БЛОКИРОВАТЬ", es: "BLOQUEAR"),
                        icon: "person.crop.circle.badge.xmark",
                        color: SpyTheme.red
                    ) {
                        blockTarget = detail.profile
                    }
                }

                if let room = inviteRoom {
                    Button {
                        Task { await inviteToRoom(detail.profile, room: room) }
                    } label: {
                        commandLabel(
                            localized(en: "INVITE TO ROOM \(room.code)", ru: "ПРИГЛАСИТЬ В КОМНАТУ \(room.code)", es: "INVITAR A SALA \(room.code)"),
                            icon: "paperplane.fill"
                        )
                    }
                    .buttonStyle(SpyPrimaryCommandStyle())
                    .disabled(activeAction != nil)
                }
            }
        }
    }

    @ViewBuilder
    private func relationshipButtons(_ detail: CommunityProfileDetail) -> some View {
        let relationship = detail.relationship

        if relationship == nil || relationship?.status == "declined" {
            communityActionButton(
                localized(en: "ADD OPERATIVE", ru: "ДОБАВИТЬ В ДРУЗЬЯ", es: "AGREGAR OPERATIVO"),
                icon: "person.badge.plus",
                color: SpyTheme.red,
                filled: true
            ) {
                await sendFriendRequest(to: detail.profile.id)
            }
        } else if relationship?.status == "accepted" {
            HStack(spacing: 9) {
                connectionStatus(
                    localized(en: "FRIENDS", ru: "В ДРУЗЬЯХ", es: "AMIGOS"),
                    icon: "checkmark.circle.fill",
                    color: SpyTheme.green
                )

                communityActionButton(
                    localized(en: "REMOVE", ru: "УДАЛИТЬ", es: "ELIMINAR"),
                    icon: "person.badge.minus",
                    color: SpyTheme.muted
                ) {
                    guard let relationship else { return }
                    await relationshipAction("remove_friend", relationship.id)
                }
            }
        } else if relationship?.direction == "incoming" {
            HStack(spacing: 9) {
                communityActionButton(
                    localized(en: "ACCEPT", ru: "ПРИНЯТЬ", es: "ACEPTAR"),
                    icon: "checkmark",
                    color: SpyTheme.green,
                    filled: true
                ) {
                    guard let relationship else { return }
                    await relationshipAction("accept", relationship.id)
                }

                communityActionButton(
                    localized(en: "DECLINE", ru: "ОТКЛОНИТЬ", es: "RECHAZAR"),
                    icon: "xmark",
                    color: SpyTheme.muted
                ) {
                    guard let relationship else { return }
                    await relationshipAction("decline", relationship.id)
                }
            }
        } else if let relationship {
            HStack(spacing: 9) {
                connectionStatus(
                    localized(en: "REQUEST SENT", ru: "ЗАПРОС ОТПРАВЛЕН", es: "SOLICITUD ENVIADA"),
                    icon: "clock",
                    color: SpyTheme.amber
                )

                communityActionButton(
                    localized(en: "CANCEL", ru: "ОТМЕНИТЬ", es: "CANCELAR"),
                    icon: "xmark",
                    color: SpyTheme.muted
                ) {
                    await relationshipAction("cancel_request", relationship.id)
                }
            }
        }
    }

    @ViewBuilder
    private func ownNetworkSections(_ detail: CommunityProfileDetail) -> some View {
        if let network, !network.incomingRoomInvites.isEmpty {
            SpyPanel(accent: SpyTheme.red, motionDelay: 0.05) {
                VStack(alignment: .leading, spacing: 10) {
                    SpySceneKicker(
                        title: localized(en: "ROOM INVITES", ru: "ПРИГЛАШЕНИЯ В КОМНАТУ", es: "INVITACIONES A SALA"),
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
                        title: localized(en: "FRIEND REQUESTS", ru: "ЗАПРОСЫ В ДРУЗЬЯ", es: "SOLICITUDES DE AMISTAD"),
                        status: "\(network.incoming.count)",
                        accent: SpyTheme.amber
                    )

                    ForEach(network.incoming) { record in
                        incomingFriendRow(record)
                    }
                }
            }
        }

        if let network, !network.blocked.isEmpty {
            SpyPanel(accent: SpyTheme.muted, motionDelay: 0.10) {
                VStack(alignment: .leading, spacing: 10) {
                    SpySceneKicker(
                        title: localized(en: "BLOCKED OPERATIVES", ru: "ЗАБЛОКИРОВАННЫЕ", es: "OPERATIVOS BLOQUEADOS"),
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
                es: "TU PERFIL PUBLICO ESTA ACTIVO. LOS OPERATIVOS PUEDEN ENCONTRARLO EN EL DIRECTORIO."
            ))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(SpyTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        }
    }

    private func friendsSection(_ detail: CommunityProfileDetail) -> some View {
        SpyPanel(motionDelay: 0.10) {
            VStack(alignment: .leading, spacing: 10) {
                SpySceneKicker(
                    title: detail.isSelf
                        ? localized(en: "MY FRIENDS", ru: "МОИ ДРУЗЬЯ", es: "MIS AMIGOS")
                        : localized(en: "FRIENDS", ru: "ДРУЗЬЯ", es: "AMIGOS"),
                    status: "\(detail.friends.count)",
                    accent: SpyTheme.muted
                )

                if detail.friends.isEmpty {
                    Text(localized(en: "NO PUBLIC CONNECTIONS YET", ru: "ПОКА НЕТ ПУБЛИЧНЫХ СВЯЗЕЙ", es: "AUN NO HAY CONEXIONES PUBLICAS"))
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
                    title: localized(en: "PROFILE WALL", ru: "СТЕНА ПРОФИЛЯ", es: "MURO DEL PERFIL"),
                    status: "\(detail.comments.count)",
                    accent: SpyTheme.red
                )

                if detail.comments.isEmpty {
                    Text(localized(
                        en: "NO FIELD NOTES YET",
                        ru: "ПОКА НЕТ ЗАПИСЕЙ",
                        es: "AUN NO HAY NOTAS"
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
                        es: "MANTEN LAS NOTAS SEGURAS. EL CONTENIDO INACEPTABLE SE FILTRA; USA REPORTAR O BLOQUEAR."
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
                localized(en: "Leave a field note...", ru: "Оставить запись...", es: "Dejar una nota..."),
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
                        Text(localized(en: "POST", ru: "ОТПРАВИТЬ", es: "PUBLICAR"))
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
                    .accessibilityLabel(localized(en: "Report comment", ru: "Пожаловаться на комментарий", es: "Reportar comentario"))
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
                    .accessibilityLabel(localized(en: "Delete comment", ru: "Удалить комментарий", es: "Eliminar comentario"))
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
                    localized(en: "ACCEPT", ru: "ПРИНЯТЬ", es: "ACEPTAR"),
                    icon: "checkmark",
                    color: SpyTheme.green,
                    filled: true
                ) {
                    await relationshipAction("accept", record.id)
                }

                communityActionButton(
                    localized(en: "DECLINE", ru: "ОТКЛОНИТЬ", es: "RECHAZAR"),
                    icon: "xmark",
                    color: SpyTheme.muted
                ) {
                    await relationshipAction("decline", record.id)
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
                    Text(localized(en: "ROOM \(invite.roomCode)", ru: "КОМНАТА \(invite.roomCode)", es: "SALA \(invite.roomCode)"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                }

                Spacer()
            }

            HStack(spacing: 9) {
                communityActionButton(
                    localized(en: "JOIN", ru: "ВОЙТИ", es: "ENTRAR"),
                    icon: "arrow.right",
                    color: SpyTheme.red,
                    filled: true
                ) {
                    await acceptRoomInvite(invite)
                }

                communityActionButton(
                    localized(en: "DECLINE", ru: "ОТКЛОНИТЬ", es: "RECHAZAR"),
                    icon: "xmark",
                    color: SpyTheme.muted
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
                    localized(en: "UNBLOCK", ru: "РАЗБЛОКИРОВАТЬ", es: "DESBLOQUEAR"),
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
                    .tracking(0.35)
                    .spyFitted(scale: 0.58, alignment: .center)
            }
            .foregroundStyle(filled ? Color.black.opacity(0.82) : color)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(filled ? color : Color.clear)
            .overlay(Rectangle().stroke(color.opacity(filled ? 0.85 : 0.48), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(activeAction != nil)
    }

    private func connectionStatus(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
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
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.8)
                .spyFitted(scale: 0.60, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var inviteRoom: GameRoom? {
        guard let room = appState.activeRoom, room.normalizedStatus == "waiting" else { return nil }
        return room
    }

    private func handleDockAction(_ tab: CommunityTab) {
        HapticManager.shared.fire(.tabSelection)
        switch tab {
        case .exit:
            onExit()
        case .network:
            selectedTab = .network
            activeProfile = nil
            profileHistory.removeAll()
            commentDraft = ""
        case .me:
            selectedTab = .me
            profileHistory.removeAll()
            commentDraft = ""
            if let userID = network?.me.id {
                Task {
                    await openProfile(
                        userID,
                        rememberingCurrent: false,
                        placeholder: network?.me
                    )
                }
            }
        }
    }

    private func loadInitialContent() async {
        guard !didLoadInitialContent else { return }
        isInitialLoading = true
        defer {
            isInitialLoading = false
            didLoadInitialContent = true
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

        do {
            async let stateRequest = appState.client.communityState()
            async let directoryRequest = appState.client.communityDirectory()
            let (loadedState, page) = try await (stateRequest, directoryRequest)
            network = loadedState
            directory = page.profiles
            nextDirectoryOffset = page.nextOffset
        } catch {
            showError(error)
        }
    }

    private func loadDirectory(reset: Bool, offset: Int = 0) async {
        guard !isDirectoryLoading else { return }
        isDirectoryLoading = true
        defer { isDirectoryLoading = false }

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
            let page = try await appState.client.communityDirectory(query: query, offset: offset)
            if reset {
                directory = page.profiles
            } else {
                let known = Set(directory.map(\.id))
                directory.append(contentsOf: page.profiles.filter { !known.contains($0.id) })
            }
            nextDirectoryOffset = page.nextOffset
        } catch is CancellationError {
            return
        } catch {
            showError(error)
        }
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

        let requestID = UUID()
        profileRequestID = requestID
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
            guard profileRequestID == requestID, !Task.isCancelled else { return }
            profileCache[userID] = detail
            activeProfile = detail
            isProfileLoading = false
        } catch {
            guard profileRequestID == requestID else { return }
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
        commentDraft = ""
        if let previousID = profileHistory.popLast() {
            await openProfile(previousID, rememberingCurrent: false)
        } else {
            activeProfile = nil
            selectedTab = .network
        }
    }

    private func refreshActiveProfile() async {
        guard let userID = activeProfile?.profile.id else { return }
        if appState.shouldUsePreviewData {
            activeProfile = CommunityPreview.profile(userID: userID, viewerID: network?.me.id)
            return
        }
        activeProfile = try? await appState.client.communityProfile(userID: userID)
    }

    private func sendFriendRequest(to userID: String) async {
        guard activeAction == nil else { return }
        activeAction = "friend-\(userID)"
        defer { activeAction = nil }

        if appState.shouldUsePreviewData {
            message = localized(en: "REQUEST TRANSMITTED", ru: "ЗАПРОС ОТПРАВЛЕН", es: "SOLICITUD ENVIADA")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
            return
        }

        do {
            network = try await appState.client.sendFriendRequest(userID: userID)
            await refreshActiveProfile()
            message = localized(en: "REQUEST TRANSMITTED", ru: "ЗАПРОС ОТПРАВЛЕН", es: "SOLICITUD ENVIADA")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func relationshipAction(_ action: String, _ friendshipID: String) async {
        guard activeAction == nil else { return }
        activeAction = friendshipID
        defer { activeAction = nil }

        if appState.shouldUsePreviewData {
            HapticManager.shared.fire(.notification(.success))
            return
        }

        do {
            network = try await appState.client.communityRelationshipAction(action, friendshipID: friendshipID)
            await refreshActiveProfile()
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func submitReport(_ target: CommunityReportTarget, reason: CommunityReportReason) async {
        guard activeAction == nil else { return }
        activeAction = "report-\(target.id)"
        defer { activeAction = nil }

        if appState.shouldUsePreviewData {
            message = localized(en: "REPORT RECEIVED", ru: "ЖАЛОБА ПРИНЯТА", es: "REPORTE RECIBIDO")
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
            guard acknowledgement.ok else { return }
            message = localized(
                en: "REPORT RECEIVED — MODERATION WILL REVIEW IT",
                ru: "ЖАЛОБА ПРИНЯТА — МОДЕРАЦИЯ ПРОВЕРИТ ЕЕ",
                es: "REPORTE RECIBIDO — MODERACION LO REVISARA"
            )
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func blockOperative(_ profile: PublicSpyProfile) async {
        guard activeAction == nil else { return }
        activeAction = "block-\(profile.id)"
        defer { activeAction = nil }

        if appState.shouldUsePreviewData {
            activeProfile = nil
            profileHistory.removeAll()
            directory.removeAll { $0.id == profile.id }
            message = localized(en: "OPERATIVE BLOCKED", ru: "ОПЕРАТИВНИК ЗАБЛОКИРОВАН", es: "OPERATIVO BLOQUEADO")
            messageKind = .success
            return
        }

        do {
            network = try await appState.client.blockCommunityUser(userID: profile.id)
            activeProfile = nil
            profileHistory.removeAll()
            selectedTab = .network
            commentDraft = ""
            directory.removeAll { $0.id == profile.id }
            message = localized(
                en: "OPERATIVE BLOCKED — COMMENTS AND INVITES REMOVED",
                ru: "ОПЕРАТИВНИК ЗАБЛОКИРОВАН — ЗАПИСИ И ПРИГЛАШЕНИЯ УДАЛЕНЫ",
                es: "OPERATIVO BLOQUEADO — COMENTARIOS E INVITACIONES ELIMINADOS"
            )
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func unblockOperative(_ relationship: CommunityRelationship) async {
        guard activeAction == nil else { return }
        activeAction = "unblock-\(relationship.id)"
        defer { activeAction = nil }

        if appState.shouldUsePreviewData {
            message = localized(en: "OPERATIVE UNBLOCKED", ru: "ОПЕРАТИВНИК РАЗБЛОКИРОВАН", es: "OPERATIVO DESBLOQUEADO")
            messageKind = .success
            return
        }

        do {
            network = try await appState.client.unblockCommunityUser(friendshipID: relationship.id)
            message = localized(en: "OPERATIVE UNBLOCKED", ru: "ОПЕРАТИВНИК РАЗБЛОКИРОВАН", es: "OPERATIVO DESBLOQUEADO")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func postComment(to userID: String) async {
        let body = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeAction == nil, !body.isEmpty else { return }
        activeAction = "comment"
        defer { activeAction = nil }

        if appState.shouldUsePreviewData {
            commentDraft = ""
            message = localized(en: "FIELD NOTE POSTED", ru: "ЗАПИСЬ ОПУБЛИКОВАНА", es: "NOTA PUBLICADA")
            messageKind = .success
            return
        }

        do {
            activeProfile = try await appState.client.addCommunityComment(userID: userID, comment: body)
            commentDraft = ""
            message = localized(en: "FIELD NOTE POSTED", ru: "ЗАПИСЬ ОПУБЛИКОВАНА", es: "NOTA PUBLICADA")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func deleteComment(_ commentID: String) async {
        guard activeAction == nil else { return }
        activeAction = commentID
        defer { activeAction = nil }

        if appState.shouldUsePreviewData { return }

        do {
            activeProfile = try await appState.client.deleteCommunityComment(commentID: commentID)
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func inviteToRoom(_ profile: PublicSpyProfile, room: GameRoom) async {
        guard activeAction == nil else { return }
        activeAction = "invite-\(profile.id)"
        defer { activeAction = nil }

        if appState.shouldUsePreviewData {
            message = localized(en: "ROOM INVITE SENT", ru: "ПРИГЛАШЕНИЕ ОТПРАВЛЕНО", es: "INVITACION ENVIADA")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
            return
        }

        do {
            let acknowledgement = try await appState.client.inviteCommunityOperative(userID: profile.id, room: room)
            guard acknowledgement.ok else { return }
            message = localized(en: "ROOM INVITE SENT", ru: "ПРИГЛАШЕНИЕ ОТПРАВЛЕНО", es: "INVITACION ENVIADA")
            messageKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func acceptRoomInvite(_ invite: CommunityRoomInvite) async {
        guard activeAction == nil else { return }
        activeAction = invite.id
        defer { activeAction = nil }

        if appState.shouldUsePreviewData {
            _ = await appState.joinRoom(code: invite.roomCode)
            return
        }

        do {
            let result = try await appState.client.communityRoomInviteAction("accept_room_invite", inviteID: invite.id)
            network = result.state
            guard let code = result.roomCode, await appState.joinRoom(code: code) else { return }
            let consumed = try await appState.client.communityRoomInviteAction("consume_room_invite", inviteID: invite.id)
            network = consumed.state
        } catch {
            showError(error)
        }
    }

    private func declineRoomInvite(_ invite: CommunityRoomInvite) async {
        guard activeAction == nil else { return }
        activeAction = invite.id
        defer { activeAction = nil }

        if appState.shouldUsePreviewData { return }

        do {
            let result = try await appState.client.communityRoomInviteAction("decline_room_invite", inviteID: invite.id)
            network = result.state
            HapticManager.shared.fire(.notification(.success))
        } catch {
            showError(error)
        }
    }

    private func relationshipTitle(_ relationship: CommunityRelationshipSummary?) -> String {
        guard let relationship else {
            return localized(en: "AVAILABLE", ru: "ДОСТУПЕН", es: "DISPONIBLE")
        }
        switch relationship.status {
        case "accepted": return localized(en: "CONNECTED", ru: "В ДРУЗЬЯХ", es: "CONECTADO")
        case "pending": return localized(en: "PENDING", ru: "ОЖИДАНИЕ", es: "PENDIENTE")
        default: return localized(en: "AVAILABLE", ru: "ДОСТУПЕН", es: "DISPONIBLE")
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
            localized(en: "HARASSMENT OR BULLYING", ru: "ТРАВЛЯ ИЛИ ДОМОГАТЕЛЬСТВО", es: "ACOSO O INTIMIDACION")
        case .hateSpeech:
            localized(en: "HATE SPEECH", ru: "ЯЗЫК НЕНАВИСТИ", es: "DISCURSO DE ODIO")
        case .sexualContent:
            localized(en: "SEXUAL CONTENT", ru: "СЕКСУАЛЬНЫЙ КОНТЕНТ", es: "CONTENIDO SEXUAL")
        case .violenceOrThreats:
            localized(en: "VIOLENCE OR THREATS", ru: "НАСИЛИЕ ИЛИ УГРОЗЫ", es: "VIOLENCIA O AMENAZAS")
        case .spam:
            localized(en: "SPAM", ru: "СПАМ", es: "SPAM")
        case .impersonation:
            localized(en: "IMPERSONATION", ru: "ВЫДАЧА СЕБЯ ЗА ДРУГОГО", es: "SUPLANTACION")
        case .other:
            localized(en: "OTHER VIOLATION", ru: "ДРУГОЕ НАРУШЕНИЕ", es: "OTRA INFRACCION")
        }
    }

    private func reportPromptMessage(_ target: CommunityReportTarget) -> String {
        localized(
            en: "Select the reason for reporting \(target.displayName). Reports are private and reviewed by moderation.",
            ru: "Выберите причину жалобы на \(target.displayName). Жалобы конфиденциальны и проверяются модерацией.",
            es: "Selecciona el motivo para reportar a \(target.displayName). Los reportes son privados y revisados por moderacion."
        )
    }

    private func formattedCommunityDate(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appState.language == .ru ? "ru_RU" : appState.language == .es ? "es_ES" : "en_US")
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
        return ["cancelled", "canceled", "отменено", "cancelado"].contains(message)
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
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

private enum CommunityTab: String, CaseIterable, Identifiable {
    case exit
    case network
    case me

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .exit: "arrow.backward"
        case .network: "person.2.fill"
        case .me: "person.crop.circle.fill"
        }
    }
}

private struct CommunityDock: View {
    let selection: CommunityTab
    let namespace: Namespace.ID
    let language: AppLanguage
    let action: (CommunityTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CommunityTab.allCases) { tab in
                Button {
                    action(tab)
                } label: {
                    let isSelected = tab != .exit && selection == tab
                    Image(systemName: tab.symbol)
                        .font(.system(size: 25, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? SpyTheme.red : Color.white.opacity(tab == .exit ? 0.70 : 0.44))
                        .scaleEffect(isSelected ? 1.10 : 1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Rectangle()
                                    .fill(SpyTheme.red)
                                    .frame(width: 28, height: 2)
                                    .matchedGeometryEffect(id: "community-dock-redline", in: namespace)
                                    .offset(y: -2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(SpyWebPressStyle(pressedScale: 0.90))
                .accessibilityLabel(accessibilityLabel(tab))
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

    private func accessibilityLabel(_ tab: CommunityTab) -> String {
        switch (tab, language) {
        case (.exit, .ru): "Вернуться назад"
        case (.network, .ru): "Сообщество"
        case (.me, .ru): "Мой публичный профиль"
        case (.exit, .es): "Volver"
        case (.network, .es): "Comunidad"
        case (.me, .es): "Mi perfil publico"
        case (.exit, _): "Return"
        case (.network, _): "Community"
        case (.me, _): "My public profile"
        }
    }
}

private enum CommunitySpyCardSize {
    case full
    case compact
}

private struct CommunitySpyCard: View {
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
        switch SpyCardThemeID(rawValue: profile.spyCardTheme) ?? .field {
        case .field:
            [Color.white.opacity(0.085), Color.white.opacity(0.018), Color.black.opacity(0.24)]
        case .blacksite:
            [Color.white.opacity(0.035), Color.black.opacity(0.42), Color.black.opacity(0.82)]
        case .dossier:
            [SpyTheme.red.opacity(0.14), Color.white.opacity(0.025), Color.black.opacity(0.46)]
        }
    }

    private var badge: SpyCardBadgeID {
        SpyCardBadgeID(rawValue: profile.spyCardBadge) ?? .operative
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
        .accessibilityLabel("SPYCARD, \(profile.displayName), SPYID \(profile.spyID)")
    }

    private var fullCard: some View {
        GeometryReader { proxy in
            let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SpyBrandMark()
                        .frame(width: 28, height: 36)
                        .offset(x: -2)

                    HStack(spacing: 5) {
                        Text(badgeGlyph)
                            .foregroundStyle(accent)
                        Text(badgeTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.6)

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

                    HStack(spacing: 9) {
                        metric(metricTitle(.rating), value: signedRating, color: SpyTheme.red)
                        metric(metricTitle(.games), value: "\(profile.gamesPlayed)", color: SpyTheme.amber)
                        metric(metricTitle(.rate), value: "\(profile.winRate)%", color: SpyTheme.green)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
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

                    HStack(spacing: 3 * scale) {
                        compactMetric(metricTitle(.rating), value: signedRating, color: SpyTheme.red)
                        compactMetric(metricTitle(.games), value: "\(profile.gamesPlayed)", color: SpyTheme.amber)
                        compactMetric(metricTitle(.rate), value: "\(profile.winRate)%", color: SpyTheme.green)
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

    private enum Metric { case rating, games, rate }

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
        case .es: "PUBLICO"
        }
    }

    private func metricTitle(_ metric: Metric) -> String {
        switch (metric, language) {
        case (.rating, .ru): "РЕЙТИНГ"
        case (.games, .ru): "ИГРЫ"
        case (.rate, .ru): "ПОБЕДЫ"
        case (.rating, .es): "RANGO"
        case (.games, .es): "JUEGOS"
        case (.rate, .es): "VICTORIAS"
        case (.rating, _): "RATING"
        case (.games, _): "GAMES"
        case (.rate, _): "WIN RATE"
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
        .frame(width: 58, alignment: .leading)
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
        winRate: 63
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
        winRate: 64
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
        winRate: 100
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
        winRate: 63
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
