//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0

#if canImport(EmbyAPI)
import EmbyAPI
import Foundation
import Get
import JellyfinAPI

struct EmbyMediaCatalog: MediaCatalog {

    let client: EmbyClient
    let userID: String

    func libraries() async throws -> MediaCatalogPage {
        let response = try await client.api.getUsersByUseridViews(path: .init(UserId: userID))
        if case .unauthorized = response {
            throw APIError.unacceptableStatusCode(401)
        }
        return try page(response.ok.body.json, operation: "GetUserViews")
    }

    func items(matching query: MediaCatalogQuery) async throws -> MediaCatalogPage {
        var input = Operations.getItems.Input.Query(UserId: userID)
        input.ParentId = query.parentID
        input.PersonIds = list(query.personIDs)
        input.StudioIds = list(query.studioIDs)
        input.Ids = list(query.ids)
        input.IncludeItemTypes = list(query.itemTypes)
        input.Fields = list(query.fields)
        input.EnableUserData = query.includeUserData
        input.StartIndex = query.offset.map { Int32(clamping: $0) }
        input.Limit = query.limit.map { Int32(clamping: $0) }
        input.Recursive = query.recursive
        input.SearchTerm = query.searchTerm
        input.NameStartsWith = query.nameStartsWith
        input.NameLessThan = query.nameLessThan
        input.SortBy = list(query.sortBy.map { $0 == "Name" ? "SortName" : $0 })
        input.SortOrder = list(query.sortOrder)
        input.AudioLanguages = list(query.audioLanguages)
        input.SubtitleLanguages = list(query.subtitleLanguages)
        input.Filters = list(query.traits)
        input.Genres = list(query.genres, separator: "|")
        input.OfficialRatings = list(query.officialRatings, separator: "|")
        input.Tags = list(query.tags, separator: "|")
        input.Years = list(query.years.map(String.init))
        input.IsMovie = query.categories.contains(.movies) ? true : nil
        input.IsSeries = query.categories.contains(.series) ? true : nil
        input.IsNews = query.categories.contains(.news) ? true : nil
        input.IsKids = query.categories.contains(.kids) ? true : nil
        input.IsSports = query.categories.contains(.sports) ? true : nil

        let response = try await client.api.getItems(query: input)
        if case .unauthorized = response {
            throw APIError.unacceptableStatusCode(401)
        }
        return try page(response.ok.body.json, operation: "GetItems")
    }

    func item(id: String) async throws -> ItemPatch {
        let response = try await client.api.getUsersByUseridItemsById(path: .init(UserId: userID, Id: id))
        if case .unauthorized = response {
            throw APIError.unacceptableStatusCode(401)
        }
        if case .notFound = response {
            throw APIError.unacceptableStatusCode(404)
        }
        return try patch(response.ok.body.json, scope: .fullItem, operation: "GetItem")
    }

    func filterOptions(parentID: String?, itemTypes: [BaseItemKind]) async throws -> ItemFilterCollection {
        let api = client.api
        let itemTypes = list(itemTypes.map(\.rawValue))

        async let genres = api.getGenres(
            query: .init(Recursive: true, ParentId: parentID, IncludeItemTypes: itemTypes, UserId: userID)
        )
        async let ratings = api.getOfficialratings(
            query: .init(Recursive: true, ParentId: parentID, IncludeItemTypes: itemTypes, UserId: userID)
        )
        async let tags = api.getTags(
            query: .init(Recursive: true, ParentId: parentID, IncludeItemTypes: itemTypes, UserId: userID)
        )
        async let years = api.getYears(
            query: .init(Recursive: true, ParentId: parentID, IncludeItemTypes: itemTypes, UserId: userID)
        )

        let (genreResponse, ratingResponse, tagResponse, yearResponse) = try await (genres, ratings, tags, years)
        let genreItems = try genreResponse.ok.body.json.Items ?? []
        let ratingItems = try ratingResponse.ok.body.json.Items ?? []
        let tagItems = try tagResponse.ok.body.json.Items ?? []
        let yearItems = try yearResponse.ok.body.json.Items ?? []
        let yearValues = yearItems.compactMap { $0.Name.flatMap(Int.init) ?? $0.Id.flatMap(Int.init) }

        return ItemFilterCollection(
            genres: genreItems.compactMap { $0.Name?.nilIfBlank }.map(ItemGenre.init),
            officialRatings: ratingItems.compactMap { $0.Name?.nilIfBlank }.map(ItemOfficialRating.init),
            tags: tagItems.compactMap { $0.Name?.nilIfBlank }.map(ItemTag.init),
            years: Set(yearValues).sorted(by: >).map(ItemYear.init)
        )
    }

    private func page(_ result: Components.Schemas.CatalogPage, operation: String) throws -> MediaCatalogPage {
        let rows = result.Items ?? []
        var items: [ItemPatch] = []
        var firstFailure: DecodingError?
        for (index, row) in rows.enumerated() {
            do {
                try items.append(patch(row, scope: .partial, operation: operation, row: index))
            } catch let error as DecodingError {
                if firstFailure == nil {
                    firstFailure = error
                }
            }
        }
        if items.isEmpty, let firstFailure {
            throw firstFailure
        }

        return MediaCatalogPage(items: items, serverItemCount: rows.count, totalCount: result.TotalRecordCount)
    }

    private func patch(
        _ item: Components.Schemas.CatalogItem,
        scope: ItemPatch.Scope,
        operation: String,
        row: Int? = nil
    ) throws -> ItemPatch {
        let (value, data) = try EmbyServer.decode(
            BaseItemDto.self,
            from: JSONEncoder().encode(item),
            operation: operation,
            row: row
        )
        guard value.id?.isEmpty == false else {
            let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing item identifier"))
            EmbyServer.logDecodingFailure(error, operation: operation, row: row)
            throw error
        }
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }

        return ItemPatch.decoded(value, object: fields, scope: scope)
    }

    private func list(_ values: [String], separator: String = ",") -> String? {
        values.isEmpty ? nil : values.joined(separator: separator)
    }
}
#endif
