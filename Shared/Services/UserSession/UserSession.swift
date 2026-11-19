//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import JellyfinAPI
import Pulse
#if canImport(EmbyAPI)
import struct EmbyAPI.EmbyClient
#endif

final class UserSession {

    let server: ServerState
    let user: UserState

    @MainActor
    private(set) lazy var items = ItemStore()

    @MainActor
    private(set) lazy var users = UserStore()

    @MainActor
    private(set) lazy var currentUser: UserRecord = {
        var data = user.data
        data.id = user.id
        data.name ?= user.username
        return (try? users.record(for: data)) ?? UserRecord(id: user.id, value: nil)
    }()

    @MainActor
    var userChanges = Set<AnyCancellable>()

    @MainActor
    var userRefresh: Task<Void, Never>?

    @MainActor
    var itemActionErrors = PassthroughSubject<Error, Never>()

    @MainActor
    var itemChanges: AnyCancellable?

    @MainActor
    private var cachedClient: JellyfinClient?

    #if canImport(EmbyAPI)
    @MainActor
    func makeEmbyClient() throws -> EmbyClient {
        try EmbyServer.client(url: server.effectiveServerURL, userID: user.id, accessToken: user.accessToken)
    }
    #endif

    @MainActor
    var client: JellyfinClient {
        let url = server.effectiveServerURL

        if let cachedClient, cachedClient.configuration.url == url {
            return cachedClient
        }

        // Connection changes replace only the transport, never the user session
        // or the item store retained by views and playback.
        let configuration = JellyfinClient.Configuration.cineFerryConfiguration(url: url, accessToken: user.accessToken)
        let client: JellyfinClient
        #if canImport(EmbyAPI)
        if server.isEmby {
            let delegate = EmbyRequestAdapter(
                client: Result { try makeEmbyClient() },
                userID: user.id
            )
            client = JellyfinClient(
                configuration: configuration,
                delegate: delegate,
                sessionConfiguration: .cineFerry,
                sessionDelegate: EmbyAPIRedirectDelegate()
            )
        } else {
            client = makeJellyfinClient(configuration: configuration)
        }
        #else
        client = makeJellyfinClient(configuration: configuration)
        #endif

        cachedClient = client

        return client
    }

    private func makeJellyfinClient(configuration: JellyfinClient.Configuration) -> JellyfinClient {
        JellyfinClient(
            configuration: configuration,
            sessionConfiguration: .cineFerry,
            sessionDelegate: URLSessionProxyDelegate(logger: NetworkLogger.cineFerry())
        )
    }

    @MainActor
    lazy var serverConnectionManager = ServerConnectionManager()

    lazy var serverSocketManager = ServerSocketManager()

    @MainActor
    private lazy var services: [any UserSessionService] = server.isEmby
        ? [serverConnectionManager]
        : [serverConnectionManager, serverSocketManager]

    init(
        server: ServerState,
        user: UserState
    ) {
        self.server = server
        self.user = user
    }

    @MainActor
    func willStart() async {
        observeItemChanges()
        observeUserChanges()

        for service in services {
            await service.willStart(userSession: self)
        }
    }

    @MainActor
    func didStart() {
        for service in services {
            service.didStart(userSession: self)
        }
    }

    @MainActor
    func willStop() {
        itemChanges = nil
        userChanges.removeAll()
        userRefresh?.cancel()
        userRefresh = nil
        for service in services.reversed() {
            service.willStop(userSession: self)
        }

        items.invalidate()
        users.invalidate()
        itemActionErrors.send(completion: .finished)
    }
}
