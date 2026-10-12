import SwiftUI

struct LabView: View {
    @Bindable var store: LabStore
    @State private var backendURL = "http://127.0.0.1:56321"
    @State private var publishableKey = ""
    @State private var email = ""
    @State private var password = ""
    @State private var loginError = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if store.userID.isEmpty { loginForm }
                    else if store.snapshot.isNull { roomPicker }
                    else { roomContents }
                    if !store.pendingIDs.isEmpty { pendingCommands }
                    diagnostics
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Game Core Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.roomID != nil {
                    Button { Task { if let room = store.roomID { _ = try? await store.refresh(room: room) } } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityIdentifier("refresh-room")
                }
            }
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .task { await store.bootstrap() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ISOLATED TEST BACKEND", systemImage: "testtube.2")
                .font(.caption.weight(.bold)).foregroundStyle(.cyan)
            Text("SpyClash · native multiplayer experiment")
                .font(.title2.weight(.semibold))
            Text("A separate test app with synthetic accounts and simplified game rules.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Label(store.realtime == "subscribed" ? "Live updates connected" : "Live updates: \(store.realtime)",
                      systemImage: store.realtime == "subscribed" ? "wifi" : "wifi.slash")
                Spacer()
                Text("168").monospacedDigit()
            }.font(.caption).foregroundStyle(store.realtime == "subscribed" ? .green : .secondary)
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test connection").font(.headline)
            TextField("Allowed backend URL", text: $backendURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Publishable / anon key", text: $publishableKey)
            TextField("Synthetic email · @example.test", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
            SecureField("Test password", text: $password)
            TextField("Player name", text: $store.name)
            Button("Sign in to test backend") {
                Task {
                    do { try await store.connect(LabConfiguration(backendURL: backendURL, publishableKey: publishableKey, email: email, password: password, name: store.name)) }
                    catch { loginError = safeFailure(error).code }
                }
            }.buttonStyle(.borderedProminent)
            if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.orange) }
            Text("Cloud projects require an exact reference in the compiled test allowlist.")
                .font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder).labCard()
    }

    private var roomPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome, \(store.name)").font(.title2.bold())
            Button("Create test room", action: store.createRoom)
                .buttonStyle(.borderedProminent).accessibilityIdentifier("create-room")
            Divider()
            TextField("Room UUID", text: $store.roomEntry)
                .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("room-id-input")
            Button("Join room", action: store.joinRoom).buttonStyle(.bordered).accessibilityIdentifier("join-room")
        }.disabled(store.busy).labCard()
    }

    @ViewBuilder private var roomContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.phase.capitalized).font(.title.bold())
                Spacer()
                Text("Revision \(store.snapshot["revision"].integer)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(store.roomID ?? "").font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            HStack {
                Button("Copy room ID") { UIPasteboard.general.string = store.roomID }.font(.caption)
                Spacer()
                Text(store.isHost ? "You are the host" : "\(store.name)").font(.caption).foregroundStyle(.cyan)
            }
        }.labCard()

        if ["playing", "voting", "finished"].contains(store.phase) { roleCard }
        if store.phase == "finished" {
            VStack(alignment: .leading, spacing: 8) {
                Text("Round complete").font(.headline)
                Text("\((store.snapshot["winner"].string ?? "unknown").capitalized) win").font(.title2.bold())
                if store.isHost { Button("Return to lobby") { store.performUI("return_to_lobby") }.buttonStyle(.borderedProminent) }
            }.labCard()
        }
        playerList
        controls
    }

    private var roleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("YOUR PRIVATE ROLE", systemImage: "lock.shield").font(.caption.bold()).foregroundStyle(.cyan)
            if store.roleRevealed {
                Text((store.snapshot["own_role"].string ?? "Unknown").capitalized).font(.largeTitle.bold())
                Text(store.snapshot["own_word"].string ?? "Find the word without revealing yourself.")
                    .font(.title3).accessibilityIdentifier("own-word")
                Button("Hide role") { store.roleRevealed = false }.font(.caption)
            } else {
                Text("Keep your screen private.").font(.headline)
                Button("Reveal my role") { store.roleRevealed = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("reveal-role")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).labCard()
    }

    private var playerList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Players · \(store.players.count)").font(.headline)
            ForEach(store.players, id: \.selfID) { player in
                HStack {
                    Image(systemName: player["ready"].bool ? "checkmark.circle.fill" : "person.circle")
                        .foregroundStyle(player["ready"].bool ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player["name"].string ?? "Player").font(.body.weight(.medium))
                        if player["user_id"].string == store.userID { Text("You").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if store.phase == "voting", player["user_id"].string != store.userID {
                        Button("Vote") { store.performUI("vote", payload: ["target_id": player["user_id"]]) }
                            .buttonStyle(.bordered).disabled(store.busy || didVote)
                    }
                }
            }
            if store.phase == "voting" { Text("\(store.snapshot["votes"].array.count) / \(store.players.count) votes cast").font(.caption).foregroundStyle(.secondary) }
        }.labCard()
    }
    private var didVote: Bool { store.snapshot["votes"].array.contains { $0["voter_id"].string == store.userID } }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.phase == "lobby" {
                Button(store.ownReady ? "Mark not ready" : "I'm ready") { store.performUI("set_ready", payload: ["ready": .bool(!store.ownReady)]) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("toggle-ready")
                if store.isHost { Button("Start game") { store.performUI("start_game") }.buttonStyle(.bordered).accessibilityIdentifier("start-game") }
            }
            if store.phase == "playing", store.isHost { Button("Open voting") { store.performUI("open_voting") }.buttonStyle(.borderedProminent) }
            HStack {
                Button("Leave room", role: .destructive) { store.performUI("leave_room") }.accessibilityIdentifier("leave-room")
                Spacer()
                if store.isHost && store.phase != "closed" { Button("Close room", role: .destructive) { store.performUI("close_room") } }
            }.font(.caption)
        }.disabled(store.busy).labCard()
    }

    private var pendingCommands: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Unconfirmed commands", systemImage: "arrow.clockwise.circle").font(.headline).foregroundStyle(.orange)
            Text("A reply may have been lost. Retry preserves the original request ID and intent.").font(.caption)
            ForEach(store.pendingIDs, id: \.self) { id in
                Button("Retry \(store.pending[id]?.action ?? "command")") {
                    Task { _ = try? await store.retry(requestID: id) }
                }.buttonStyle(.bordered)
            }
        }.labCard()
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.status).font(.caption)
            if !store.lastError.isEmpty { Text(store.lastError).font(.caption.monospaced()).foregroundStyle(.orange).accessibilityIdentifier("last-error") }
            Text("\(store.backendLabel) · \(store.signalRevisions.count) native WebSocket signals").font(.caption2).foregroundStyle(.secondary)
            if store.roomID != nil {
                Button(store.realtime == "subscribed" ? "Disconnect live updates" : "Reconnect live updates") {
                    if store.realtime == "subscribed" { store.disconnectRealtime() }
                    else { Task { try? await store.reconnectRealtime() } }
                }.font(.caption)
            }
        }
    }
}

private extension JSONValue { var selfID: String { self["user_id"].string ?? "unknown" } }
private extension View {
    func labCard() -> some View { padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18)) }
}
