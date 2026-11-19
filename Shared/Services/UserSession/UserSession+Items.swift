//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Get
import JellyfinAPI

@MainActor
extension UserSession {

    func makeMediaCatalog() throws -> any MediaCatalog {
        #if canImport(EmbyAPI)
        if server.isEmby {
            return try EmbyMediaCatalog(client: makeEmbyClient(), userID: user.id)
        }
        #endif
        return JellyfinMediaCatalog(client: client, userID: user.id)
    }

    func catalogSnapshots(
        _ fetch: (any MediaCatalog) async throws -> MediaCatalogPage
    ) async throws -> (value: [BaseItemDto], items: [ItemRecord]) {
        let token = try items.beginRequest()
        let page = try await fetch(makeMediaCatalog())
        try items.validate()
        // Retain merged records while matching the snapshot behavior of the session request.
        let records = try page.items.compactMap { try items.merge($0, token: token) }
        return (page.items.map(\.value), records)
    }

    func request<Value: Decodable & Sendable>(_ request: Request<Value>) async throws -> Response<Value> {
        #if canImport(EmbyAPI)
        if server.isEmby {
            let response = try await client.data(for: request)
            let (value, data) = try EmbyServer.decode(
                Value.self,
                from: response.data,
                itemID: request.url?.lastPathComponent,
                operation: request.id
            )
            return Response(
                value: value,
                data: data,
                response: response.response,
                task: response.task,
                metrics: response.metrics
            )
        }
        #endif
        return try await client.send(request)
    }

    func send<Value: Decodable & Sendable>(
        _ request: Request<Value>
    ) async throws -> (value: Value, items: [ItemRecord]) {
        try items.validate()
        let token = try items.beginRequest()
        let userToken = try users.beginRequest()
        let response = try await self.request(request)
        try Task.checkCancellation()
        try items.validate()

        if let user = response.value as? UserDto {
            try users.merge(user, token: userToken)
        } else if let values = response.value as? [UserDto] {
            for user in values {
                try users.merge(user, token: userToken)
            }
        }

        let records: [ItemRecord]
        if let provider = response.value as? any BaseItemPatchProvider {
            let object = try JSONSerialization.jsonObject(with: response.data)
            let patches = try provider.patches(from: object, scope: .partial)
            records = try patches.compactMap { try items.merge($0, token: token) }
        } else {
            records = []
        }

        // Keep merged records alive until the caller takes ownership
        return (response.value, records)
    }

    func getFullItem(_ item: BaseItemDto) async throws -> ItemEntry {
        try await getFullItem(id: item.id, occurrence: item.playlistItemID)
    }

    /// Fetches the full item into a retained shared entry.
    func getFullItem(id: String?, occurrence: String? = nil) async throws -> ItemEntry {
        guard let id, id.nilIfBlank != nil else { throw ItemStore.StoreError.invalidItemID }

        let token = try items.beginRequest()
        let patch = try await makeMediaCatalog().item(id: id)
        guard let record = try items.merge(patch, token: token), record.value != nil else {
            throw ItemStore.StoreError.itemUnavailable
        }

        return ItemEntry(item: record, occurrence: occurrence ?? patch.value.playlistItemID)
    }

    func send(_ request: Request<Void>) async throws {
        try items.validate()
        try await client.send(request)
        try items.validate()
    }

    func receiveSessionItems(_ sessions: [SessionInfoDto]) throws -> [ItemRecord] {
        let token = try items.beginRequest()
        let patches = try sessions.patches()
        return try patches.compactMap { try items.merge($0, token: token) }
    }

    func setFavorite(_ entry: ItemEntry, to isFavorite: Bool) async throws {
        try await updateUserData(entry, field: \.isFavorite, to: isFavorite) {
            isFavorite
                ? Paths.markFavoriteItem(itemID: entry.itemID, userID: self.user.id)
                : Paths.unmarkFavoriteItem(itemID: entry.itemID, userID: self.user.id)
        }
    }

    func setPlayed(_ entry: ItemEntry, to isPlayed: Bool) async throws {
        try await updateUserData(entry, field: \.isPlayed, to: isPlayed) {
            isPlayed
                ? Paths.markPlayedItem(itemID: entry.itemID, userID: self.user.id)
                : Paths.markUnplayedItem(itemID: entry.itemID, userID: self.user.id)
        }
    }

    private func updateUserData(
        _ entry: ItemEntry,
        field: ItemUserDataField,
        to value: Bool,
        request: @escaping () -> Request<UserItemDataDto>
    ) async throws {
        try await items.mutateUserData(entry.item, field: field, to: value) {
            let response = try await self.request(request())
            let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            return (response.value, Set(object.keys))
        }
    }
}
