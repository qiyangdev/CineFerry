//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(tvOS) && canImport(EmbyAPI)
import FactoryKit
import SwiftUI

struct EmbyConnectView: View {

    @Environment(\.dismiss)
    private var dismiss

    @Environment(\.localUserAuthenticationAction)
    private var authenticate

    @Injected(\.userSessionManager)
    private var userSessionManager: UserSessionManager

    @State
    private var attempt = 0
    @State
    private var pin: EmbyConnect.PIN?
    @State
    private var account: EmbyConnect.Account?
    @State
    private var servers: [EmbyConnect.LinkedServer] = []
    @State
    private var selectedServer: EmbyConnect.LinkedServer?
    @State
    private var message: String?

    let onSignedIn: () -> Void

    @ContentBuilder
    var body: some View {
        VStack(spacing: 24) {
            Text(L10n.embyConnect)
                .font(.title)

            if let account {
                if servers.isEmpty {
                    Text(L10n.embyConnectNoServers)
                } else {
                    Text(L10n.embyConnectChooseServer)
                    ScrollView {
                        VStack {
                            ForEach(servers) { server in
                                Button(server.name) { selectedServer = server }
                                    .disabled(selectedServer != nil)
                            }
                        }
                        .padding(24)
                    }
                    .frame(maxHeight: 320)
                }

                if selectedServer != nil {
                    ProgressView()
                }
                if let message {
                    Text(message)
                }
                Button(L10n.embyConnectNewCode) { attempt += 1 }
                    .disabled(selectedServer != nil)
                    .task(id: selectedServer?.id) {
                        guard let selectedServer else { return }

                        await signIn(to: selectedServer, account: account)
                    }
            } else if let message {
                Text(message)
                Button(L10n.retry) { attempt += 1 }
            } else if let pin {
                Text(L10n.embyConnectInstructions)
                Text(pin.pin)
                    .font(.largeTitle.monospaced())
                    .accessibilityIdentifier("embyConnectPIN")
                Button(L10n.embyConnectNewCode) { attempt += 1 }
            } else {
                ProgressView()
            }

            Button(L10n.cancel, role: .cancel) { dismiss() }
        }
        .multilineTextAlignment(.center)
        .padding(48)
        .task(id: attempt) { await connect() }
    }

    private func connect() async {
        pin = nil
        account = nil
        servers = []
        message = nil

        do {
            let pin = try await EmbyConnect.createPIN()
            try Task.checkCancellation()
            self.pin = pin

            let authorization = try await EmbyConnect.authorize(pin)
            try Task.checkCancellation()
            guard let account = authorization else {
                message = L10n.embyConnectExpired
                return
            }

            let servers = try await EmbyConnect.servers(for: account)
            try Task.checkCancellation()
            self.servers = servers
            self.account = account
        } catch {
            if !Task.isCancelled {
                message = L10n.embyConnectUnavailable
            }
        }
    }

    private func signIn(to server: EmbyConnect.LinkedServer, account: EmbyConnect.Account) async {
        message = nil
        defer { selectedServer = nil }

        do {
            let (url, info, result) = try await EmbyConnect.signIn(to: server, account: account)
            guard let data = result.user, let id = data.id, let name = data.name, let token = result.accessToken else {
                throw ErrorMessage(L10n.unknownError)
            }

            let existingUser = StoredValues[.User.users].first { $0.id == id }
            if let existingUser {
                guard existingUser.serverID == server.systemId else { throw ErrorMessage(L10n.connectionServerMismatch) }

                let policy = existingUser.accessPolicy
                if policy != .none {
                    guard let authenticate else { throw ErrorMessage(L10n.deviceAuthFailed) }

                    let evaluated = try await authenticate(policy: policy, reason: policy.authenticateReason(user: existingUser))
                    if let pin = evaluated as? PinEvaluatedUserAccessPolicy, pin.pin != existingUser.pin {
                        throw ErrorMessage(L10n.incorrectPinForUser(existingUser.username))
                    }
                }
            }
            try Task.checkCancellation()

            let user = existingUser ?? UserState(id: id, serverID: server.systemId, username: name)
            var savedServers = StoredValues[.Server.servers]
            let index = savedServers.firstIndex { $0.id == server.systemId }
            let existingServer = index.map { savedServers[$0] }
            let state = ServerState(
                urls: (existingServer?.urls ?? []).union([url]),
                currentURL: url,
                name: info.serverName ?? server.name,
                id: server.systemId,
                userIDs: Array(Set((existingServer?.userIDs ?? []) + [id]))
            )

            var connections = existingServer?.ensureServerConnections() ?? []
            let connection = connections.first { $0.url == url } ?? ServerConnection(
                id: UUID().uuidString,
                name: url.absoluteString,
                url: url,
                interface: .any,
                priority: connections.count
            )
            if !connections.contains(where: { $0.id == connection.id }) {
                connections.append(connection)
            }
            state.serverConnections = connections
            state.activeServerConnection = connection
            StoredValues[.Server.publicInfo(id: state.id)] = info
            if let index {
                savedServers[index] = state
            } else {
                savedServers.append(state)
            }
            StoredValues[.Server.servers] = savedServers

            user.accessToken = token
            user.data = data
            if existingUser == nil {
                StoredValues[.User.users] = StoredValues[.User.users].appending(user)
            }
            try await userSessionManager.signIn(userID: id)
            onSignedIn()
            dismiss()
        } catch {
            if !Task.isCancelled {
                message = (error as? ErrorMessage)?.localizedDescription ?? L10n.embyConnectServerUnavailable
            }
        }
    }
}
#endif
