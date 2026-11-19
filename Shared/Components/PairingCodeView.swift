//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

struct PairingCodeView<Instructions: View>: View {

    let code: String
    @ContentBuilder
    let instructions: Instructions

    @ContentBuilder
    var body: some View {
        VStack(spacing: 20) {
            BulletedList(spacing: 16) {
                instructions
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(code)
                .tracking(10)
                .font(.largeTitle)
                .monospacedDigit()
                .accessibilityIdentifier("pairingCode")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .edgePadding()
    }
}
