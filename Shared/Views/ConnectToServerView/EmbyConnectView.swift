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

    @Router
    private var router

    @Environment(\.localUserAuthenticationAction)
    private var authenticate

    @Injected(\.userSessionManager)
    private var userSessionManager: UserSessionManager

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

    @ContentBuilder
    var body: some View {
        ZStack {
            if let account {
                EmbyConnectServerList(
                    servers: servers,
                    isSigningIn: selectedServer != nil,
                    message: message,
                    onSelect: { selectedServer = $0 }
                )
                .task(id: selectedServer?.id) {
                    guard let selectedServer else { return }

                    await signIn(to: selectedServer, account: account)
                }
            } else if let message {
                ErrorView(error: ErrorMessage(message))
            } else if let pin {
                PairingCodeView(code: pin.pin) {
                    Text(L10n.embyConnectInstructions)
                }
            } else {
                ProgressView()
            }
        }
        .edgePadding()
        .navigationTitle(L10n.embyConnect)
        .task { await connect() }
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
            router.dismiss()
        } catch {
            if !Task.isCancelled {
                message = (error as? ErrorMessage)?.localizedDescription ?? L10n.embyConnectServerUnavailable
            }
        }
    }
}

private struct EmbyConnectServerList: View {

    let servers: [EmbyConnect.LinkedServer]
    let isSigningIn: Bool
    let message: String?
    let onSelect: (EmbyConnect.LinkedServer) -> Void

    @ContentBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if servers.isEmpty {
                Text(L10n.embyConnectNoServers)
            } else {
                Text(L10n.embyConnectChooseServer)
                    .font(.headline)

                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(servers) { server in
                            ConnectToServerView.ServerConnectionButton(name: server.name) {
                                onSelect(server)
                            }
                        }
                    }
                    .padding(16)
                }
                .disabled(isSigningIn)
            }

            if isSigningIn {
                ProgressView()
            }
            if let message {
                Text(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .edgePadding()
    }
}
#endif
