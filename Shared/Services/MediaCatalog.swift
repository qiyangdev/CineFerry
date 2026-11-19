//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0

/// Catalog operations requested by the app, independent of an API's request format.
@MainActor
protocol MediaCatalog {

    func libraries() async throws -> MediaCatalogPage
    func items(matching query: MediaCatalogQuery) async throws -> MediaCatalogPage
    func item(id: String) async throws -> ItemPatch
}

struct MediaCatalogPage {

    let items: [ItemPatch]
    let serverItemCount: Int
    let totalCount: Int?
}

struct MediaCatalogQuery {

    var parentID: String?
    var personIDs: [String] = []
    var studioIDs: [String] = []
    var ids: [String] = []
    var itemTypes: [String] = []
    var fields: [String] = []
    var includeUserData: Bool?
    var offset: Int?
    var limit: Int?
    var recursive: Bool?
    var searchTerm: String?
    var nameStartsWith: String?
    var nameLessThan: String?
    var sortBy: [String] = []
    var sortOrder: [String] = []
    var audioLanguages: [String] = []
    var subtitleLanguages: [String] = []
    var traits: [String] = []
    var genres: [String] = []
    var officialRatings: [String] = []
    var tags: [String] = []
    var years: [Int] = []
    var categories: [ChannelCategory] = []
}
