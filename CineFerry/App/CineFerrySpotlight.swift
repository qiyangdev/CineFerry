//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreSpotlight
import Foundation

struct CineFerrySpotlight {

    private let mainIndex = CSSearchableIndex(name: "SwiftfinAppIndex")

    func addCineFerryToSpotlight() {
        Task.detached {
            let attributeSet = CSSearchableItemAttributeSet(contentType: UTType.application)
            attributeSet.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "CineFerry"

            let searchableItem = CSSearchableItem(
                uniqueIdentifier: Bundle.main.bundleIdentifier ?? "dev.qiyang.mediaclient",
                domainIdentifier: nil,
                attributeSet: attributeSet
            )

            try? await mainIndex.indexSearchableItems([searchableItem])
        }
    }
}
