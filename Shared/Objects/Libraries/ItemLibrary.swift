//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import JellyfinAPI
import SwiftUI

@MainActor
struct ItemLibrary: MediaLibrary, SearchablePagingLibrary, WithRandomElementLibrary {

    struct Environment: WithDefaultValue {

        var grouping: BaseItemDto.Grouping?
        var filters: ItemFilterCollection

        static let `default`: Self = .init(
            grouping: nil,
            filters: .default
        )
    }

    let environment: Environment?
    let filterViewModel: FilterViewModel
    @SharedBaseItem
    var parent: BaseItemDto

    init(
        parent: BaseItemDto,
        filters: ItemFilterCollection? = nil,
        staticFilters: ItemFilterCollection = .default,
        grouping: BaseItemDto.Grouping? = nil
    ) {
        var filters = filters ?? .default

        if let id = parent.id,
           Defaults[.Customization.Library.rememberFilters],
           staticFilters.union(filters).itemTypes.isEmpty {
            filters = filters.union(StoredValues[.User.libraryFilters(parentID: id)])
        }

        var resolvedGrouping = grouping

        if resolvedGrouping == nil,
           let groupings = parent.groupings,
           Defaults[.Customization.Library.rememberLayout] {
            let storedGrouping = StoredValues[
                .User.libraryGrouping(id: parent.pagingLibraryID, default: groupings.defaultSelection)
            ]

            resolvedGrouping = groupings.elements.first { $0.id == storedGrouping.id }
        }

        self.environment = .init(
            grouping: resolvedGrouping ?? parent.groupings?.defaultSelection,
            filters: staticFilters.union(filters)
        )
        self.filterViewModel = .init(
            parent: parent,
            currentFilters: filters,
            staticFilters: staticFilters
        )
        self.parent = parent
    }

    func makeMenuContent(environment: Binding<Environment>) -> AnyView {
        Group {
            if let groupings = parent.groupings, groupings.elements.isNotEmpty {
                Picker(
                    selection: environment.map(
                        getter: { $0.grouping },
                        setter: { .init(grouping: $0, filters: environment.wrappedValue.filters) }
                    )
                ) {
                    ForEach(groupings.elements) { grouping in
                        Text(grouping.displayTitle)
                            .tag(grouping as BaseItemDto.Grouping?)
                    }
                } label: {
                    Text(L10n.grouping)

                    if let grouping = environment.wrappedValue.grouping {
                        Text(grouping.displayTitle)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .eraseToAnyView()
    }

    func makeLibraryBody(
        viewModel: PagingLibraryViewModel<Self>,
        @ContentBuilder content: @escaping () -> some View
    ) -> AnyView {
        ItemLibraryBody(
            filterViewModel: filterViewModel,
            viewModel: viewModel,
            content: content
        )
        .eraseToAnyView()
    }

    func libraryStyleOptions(environment: Environment) -> LibraryStyleOptions {
        let itemTypes = environment.filters.itemTypes.isEmpty ?
            parent.supportedItemTypes(for: environment.grouping) :
            environment.filters.itemTypes

        return BaseItemKind.libraryStyleOptions(for: itemTypes)
    }

    func retrievePage(
        environment: Environment,
        pageState: LibraryPageState
    ) async throws -> [ItemPatch] {
        let query = attachPage(
            to: attachFilters(
                to: makeBaseItemParameters(environment: environment),
                using: environment.filters
            ),
            pageState: pageState
        )

        return try await retrieveItems(query: query, environment: environment, pageState: pageState)
    }

    func retrieveRandomElement(
        environment: Environment,
        pageState: LibraryPageState
    ) async throws -> ItemPatch? {
        var query = attachFilters(
            to: makeBaseItemParameters(environment: environment),
            using: environment.filters
        )
        query.limit = 1
        query.sortBy = [ItemSortBy.random.rawValue]

        return try await retrieveItems(query: query, environment: environment, pageState: pageState).first
    }

    func retrieveSearchPage(
        query: String,
        environment: Environment,
        pageState: LibraryPageState
    ) async throws -> [ItemPatch] {
        var parameters = attachPage(
            to: attachFilters(
                to: makeBaseItemParameters(environment: environment),
                using: environment.filters
            ),
            pageState: pageState
        )
        parameters.searchTerm = filterViewModel.staticFilters.query ?? query

        return try await retrieveItems(query: parameters, environment: environment, pageState: pageState)
    }

    private func retrieveItems(
        query: MediaCatalogQuery,
        environment: Environment,
        pageState: LibraryPageState
    ) async throws -> [ItemPatch] {
        var query = query
        let groupedFolders: [String]?

        if environment.grouping == .folders,
           parent.libraryType == .userView,
           parent.collectionType == .movies || parent.collectionType == .tvshows {
            groupedFolders = pageState.userSession.userData.configuration?.groupedFolders ?? []
            guard let groupedFolders, groupedFolders.isNotEmpty else { return [] }

            query.parentID = nil
            query.ids = groupedFolders

            if query.sortBy == [ItemSortBy.random.rawValue] {
                query.limit = nil
            }
        } else {
            groupedFolders = nil
        }

        let page = try await pageState.userSession.makeMediaCatalog().items(matching: query)

        return pageState.items(from: page).filter { patch in
            guard let groupedFolders else { return true }

            return groupedFolders.contains(patch.value.id ?? "") &&
                (patch.value.collectionType == nil || patch.value.collectionType == parent.collectionType)
        }
    }

    private func makeBaseItemParameters(environment: Environment) -> MediaCatalogQuery {
        var query = MediaCatalogQuery()
        query.includeUserData = true
        query.fields = PosterSubtitleField.itemFields.map(\.rawValue)
        query.itemTypes = parent.supportedItemTypes(for: environment.grouping).map(\.rawValue)
        query.recursive = parent.isRecursiveCollection(for: environment.grouping)
        query.sortBy = [ItemSortBy.name.rawValue]
        query.sortOrder = [ItemSortOrder.ascending.rawValue]

        guard let parentID = parent.id else { return query }

        switch parent.libraryType {
        case .person:
            query.personIDs = [parentID]

        case .studio:
            query.studioIDs = [parentID]

        default:
            query.parentID = parentID
        }

        return query
    }

    func materialize(_ page: [ItemPatch], pageState: LibraryPageState) throws -> [ItemEntry] {
        try page.compactMap { patch in
            if let type = patch.value.collectionType, !CollectionType.supportedCases.contains(type) {
                return nil
            }
            guard let record = try pageState.userSession.items.merge(patch, token: pageState.itemRequest) else {
                return nil
            }

            return ItemEntry(
                item: record,
                occurrence: patch.value.playlistItemID,
                grouping: patch.value.type == .collectionFolder ? .folders : nil
            )
        }
    }

    func includes(_ element: ItemEntry, environment: Environment) -> Bool {
        element.item.confirmedUserData?.matches(environment.filters.traits) != false
    }

    func shouldRefreshForUserDataChange(environment: Environment) -> Bool {
        environment.filters.traits.contains {
            switch $0 {
            case .isFavorite, .isPlayed, .isUnplayed, .isResumable, .likes, .dislikes, .isFavoriteOrLikes: true
            default: false
            }
        } || environment.filters.sortBy.contains {
            switch $0 {
            case .datePlayed, .playCount, .isUnplayed, .isPlayed, .isFavoriteOrLiked, .seriesDatePlayed: true
            default: false
            }
        }
    }

    private func attachFilters(
        to query: MediaCatalogQuery,
        using filters: ItemFilterCollection
    ) -> MediaCatalogQuery {
        var query = query
        query.audioLanguages = filters.audioLanguages.map(\.value)
        query.traits = filters.traits.map(\.rawValue)
        query.genres = filters.genres.map(\.value)
        query.officialRatings = filters.officialRatings.map(\.value)
        query.sortBy = filters.sortBy.map(\.rawValue)
        query.sortOrder = filters.sortOrder.map(\.rawValue)
        query.subtitleLanguages = filters.subtitleLanguages.map(\.value)
        query.tags = filters.tags.map(\.value)
        query.years = filters.years.compactMap { Int($0.value) }

        query.categories = filters.categories

        if let searchTerm = filters.query {
            query.searchTerm = searchTerm
        }

        if filters.itemTypes.isNotEmpty {
            query.itemTypes = filters.itemTypes.map(\.rawValue)
        }

        if let letter = filters.letter.first {
            if letter.value == "#" {
                query.nameLessThan = "A"
            } else {
                query.nameStartsWith = letter.value
            }
        }

        return query
    }

    private func attachPage(
        to query: MediaCatalogQuery,
        pageState: LibraryPageState
    ) -> MediaCatalogQuery {
        var query = query
        query.limit = pageState.pageSize
        query.offset = pageState.pageOffset
        return query
    }
}

private struct ItemLibraryBody<Content: View>: View {

    @Default(.Customization.Library.enabledDrawerFilters)
    private var enabledDrawerFilters

    @Router
    private var router

    @ObservedObject
    private var viewModel: PagingLibraryViewModel<ItemLibrary>

    private let content: Content
    private let filterViewModel: FilterViewModel

    private var filterTypes: [ItemFilterType] {
        enabledDrawerFilters.filter { !filterViewModel.staticFilters.containsFilters(ofType: $0) }
    }

    init(
        filterViewModel: FilterViewModel,
        viewModel: PagingLibraryViewModel<ItemLibrary>,
        @ContentBuilder content: () -> Content
    ) {
        self.filterViewModel = filterViewModel
        self.viewModel = viewModel
        self.content = content()
    }

    @ContentBuilder
    var body: some View {
        content
            .onFirstAppear {
                Task {
                    await filterViewModel.getQueryFilters()
                }
            }
            .onChange(of: filterViewModel.currentFilters) {
                rememberFilters(from: filterViewModel.currentFilters)
            }
            .onReceive(
                filterViewModel.$currentFilters
                    .map { filterViewModel.staticFilters.union($0) }
                    .removeDuplicates()
                    .debounce(for: 1, scheduler: RunLoop.main)
            ) { filters in
                guard viewModel.environment.filters != filters else { return }

                viewModel.environment.filters = filters
            }
            .onChange(of: viewModel.environment.grouping) { _, grouping in
                guard let grouping, Defaults[.Customization.Library.rememberLayout] else { return }

                StoredValues[
                    .User.libraryGrouping(id: viewModel.library.parent.pagingLibraryID, default: grouping)
                ] = grouping
            }
            #if os(tvOS)
            .filterBar(
                viewModel: filterViewModel,
                types: filterTypes
            )
            #endif
            .letterPickerBar(filterViewModel: filterViewModel)
            #if os(tvOS)
            .background(alignment: .top) {
                if !router.isRootOfPath {
                    FocusedPosterCinematicBackgroundView()
                }
            }
            #else
            .navigationBarFilterDrawer(
                viewModel: filterViewModel,
                types: filterTypes
            )
            #endif
    }

    private func rememberFilters(from filters: ItemFilterCollection) {
        guard let id = viewModel.library.parent.id,
              Defaults[.Customization.Library.rememberFilters],
              filterViewModel.libraryItemTypes.isEmpty
        else { return }

        StoredValues[.User.libraryFilters(parentID: id)] = filters.mutating(\.query, with: nil)
    }
}
