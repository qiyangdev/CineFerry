//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import FactoryKit
import Foundation
import Get
import JellyfinAPI
import Logging
import OrderedCollections
import Pulse

@MainActor
@Stateful
final class ConnectToServerViewModel: ObservableObject {

    @CasePathable
    enum Action {

        case addConnection(serverState: ServerState)
        case cancel
        case connect(url: String)
        case searchForServers

        var transition: Transition {
            switch self {
            case .addConnection, .searchForServers: .none
            case .cancel: .to(.initial)
            case .connect: .loop(.connecting)
            }
        }
    }

    enum Event {

        case connected(ServerState)
        case duplicateServer(ServerState)
        case error
    }

    enum State {

        case connecting
        case initial
    }

    /// no longer-found servers are not cleared, but not an issue
    @Published
    var localServers: OrderedSet<ServerState> = []

    let logger = Logger.cineFerry()
    var cancellables = Set<AnyCancellable>()

    @Function(\Action.Cases.connect)
    private func connectToServer(_ url: String) async throws {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .objectReplacement)
            .trimmingCharacters(in: ["/"])
        let formattedURL: String
        if let scheme = ["http", "https"].first(where: { address.lowercased().hasPrefix("\($0):/") }) {
            // URL entry can supply a single slash after the scheme.
            let hostAndPath = address.dropFirst(scheme.count + 1).drop(while: { $0 == "/" })
            formattedURL = "\(scheme)://\(hostAndPath)"
        } else {
            formattedURL = address.prepending("http://", if: !address.contains("://"))
        }

        guard let parsedURL = URL(string: formattedURL)
        else {
            throw ErrorMessage(L10n.invalidURL)
        }

        let url = parsedURL.normalizedServerConnectionURL ?? parsedURL

        guard url.host != nil else {
            throw ErrorMessage(L10n.invalidURL)
        }

        let client = JellyfinClient(
            configuration: .cineFerryConfiguration(url: url),
            sessionDelegate: URLSessionProxyDelegate(logger: NetworkLogger.cineFerry())
        )

        let publicInfo: PublicSystemInfo
        let connectionURL: URL
        do {
            let response = try await client.send(Paths.getPublicSystemInfo)
            let resolvedURL = processConnectionURL(initial: url, response: response.response.url)
            #if canImport(EmbyAPI)
            if EmbyServer.matches(response.value) {
                publicInfo = try await EmbyServer.probe(resolvedURL)
            } else {
                publicInfo = response.value
            }
            #else
            publicInfo = response.value
            #endif
            connectionURL = resolvedURL
        } catch {
            #if canImport(EmbyAPI)
            try Task.checkCancellation()
            guard url.lastPathComponent.lowercased() != "emby" else { throw error }

            let embyURL = url.appending(component: "emby")
            guard let info = try? await EmbyServer.probe(embyURL) else { throw error }

            publicInfo = info
            connectionURL = embyURL
            #else
            throw error
            #endif
        }

        guard let name = publicInfo.serverName,
              let id = publicInfo.id
        else {
            logger.critical("Missing server data from network call")
            throw ErrorMessage(L10n.unknownError)
        }

        let newServerState = ServerState(
            urls: [connectionURL],
            currentURL: connectionURL,
            name: name,
            id: id,
            userIDs: []
        )

        let isDuplicateServer = StoredValues[.Server.servers]
            .contains { $0.id == newServerState.id }

        guard !isDuplicateServer else {
            // server has same id, but (possible) new connection URL
            events.send(.duplicateServer(newServerState))
            return
        }

        save(server: newServerState, publicInfo: publicInfo)
        events.send(.connected(newServerState))
    }

    /// In the event of redirects, get the new host URL from response
    private func processConnectionURL(initial url: URL, response: URL?) -> URL {
        let normalizedURL = url.normalizedServerConnectionURL ?? url

        guard let response else { return normalizedURL }

        if url.scheme != response.scheme ||
            url.host != response.host {
            let newURL = response.absoluteString.trimmingSuffix(
                Paths.getPublicSystemInfo.url?.absoluteString ?? ""
            )
            return URL(string: newURL)?.normalizedServerConnectionURL ?? normalizedURL
        }

        return normalizedURL
    }

    private func save(server: ServerState, publicInfo: PublicSystemInfo) {
        let newServers = StoredValues[.Server.servers]
            .appending(server)

        StoredValues[.Server.publicInfo(id: server.id)] = publicInfo
        StoredValues[.Server.servers] = newServers
    }

    /// server has same id, but (possible) new connection URL
    @Function(\Action.Cases.addConnection)
    private func _addConnection(_ server: ServerState) throws {
        guard let existingServer = StoredValues[.Server.servers].first(where: { $0.id == server.id }) else {
            logger.critical("Could not find server to add new url")
            throw ErrorMessage("An internal error has occurred")
        }

        var connections = existingServer.ensureServerConnections()

        let normalizedURL = server.currentURL.normalizedServerConnectionURL ?? server.currentURL

        let connection = connections.first { $0.url == normalizedURL } ?? {
            let connection = ServerConnection(
                id: UUID().uuidString,
                name: normalizedURL.absoluteString,
                url: normalizedURL,
                interface: .any,
                priority: connections.count
            )
            connections.append(connection)
            return connection
        }()

        existingServer.serverConnections = connections

        existingServer.activeServerConnection = connection
        Notifications[.didChangeServerConnection].post(connection)
    }

    @Function(\Action.Cases.searchForServers)
    private func _searchForServers() async {
        do {
            for try await server in JellyfinClient.discover() {
                localServers.append(
                    ServerState(
                        urls: [server.url],
                        currentURL: server.url,
                        name: server.name,
                        id: server.id,
                        userIDs: []
                    )
                )
            }
        } catch {
            logger.error("Local server discovery failed: \(error.localizedDescription)")
        }
    }
}
