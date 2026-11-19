//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0

import Get
import JellyfinAPI

struct JellyfinMediaCatalog: MediaCatalog {

    let client: JellyfinClient
    let userID: String

    func libraries() async throws -> MediaCatalogPage {
        try await page(for: Paths.getUserViews(parameters: .init(userID: userID)))
    }

    func items(matching query: MediaCatalogQuery) async throws -> MediaCatalogPage {
        var parameters = Paths.GetItemsParameters(userID: userID)
        parameters.parentID = query.parentID
        parameters.personIDs = query.personIDs.nilIfEmpty
        parameters.studioIDs = query.studioIDs.nilIfEmpty
        parameters.ids = query.ids.nilIfEmpty
        parameters.includeItemTypes = query.itemTypes.compactMap(BaseItemKind.init(rawValue:)).nilIfEmpty
        parameters.fields = query.fields.compactMap(ItemFields.init(rawValue:)).nilIfEmpty
        parameters.enableUserData = query.includeUserData
        parameters.startIndex = query.offset
        parameters.limit = query.limit
        parameters.isRecursive = query.recursive
        parameters.searchTerm = query.searchTerm
        parameters.nameStartsWith = query.nameStartsWith
        parameters.nameLessThan = query.nameLessThan
        parameters.sortBy = query.sortBy.compactMap(ItemSortBy.init(rawValue:)).nilIfEmpty
        parameters.sortOrder = query.sortOrder.compactMap(SortOrder.init(rawValue:)).nilIfEmpty
        parameters.audioLanguages = query.audioLanguages.nilIfEmpty
        parameters.subtitleLanguages = query.subtitleLanguages.nilIfEmpty
        parameters.filters = query.traits.compactMap(ItemTrait.init(rawValue:)).nilIfEmpty
        parameters.genres = query.genres.nilIfEmpty
        parameters.officialRatings = query.officialRatings.nilIfEmpty
        parameters.tags = query.tags.nilIfEmpty
        parameters.years = query.years.nilIfEmpty
        parameters.isMovie = query.categories.contains(.movies) ? true : nil
        parameters.isSeries = query.categories.contains(.series) ? true : nil
        parameters.isNews = query.categories.contains(.news) ? true : nil
        parameters.isKids = query.categories.contains(.kids) ? true : nil
        parameters.isSports = query.categories.contains(.sports) ? true : nil
        return try await page(for: Paths.getItems(parameters: parameters))
    }

    func item(id: String) async throws -> ItemPatch {
        let response = try await client.send(Paths.getItem(itemID: id, userID: userID))
        let patches = try response.patches(scope: .fullItem)
        return patches[patches.startIndex]
    }

    private func page(for request: Request<BaseItemDtoQueryResult>) async throws -> MediaCatalogPage {
        let response = try await client.send(request)
        return try MediaCatalogPage(
            items: response.patches(),
            serverItemCount: response.value.items?.count ?? 0,
            totalCount: response.value.totalRecordCount
        )
    }
}

private extension Array {

    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
