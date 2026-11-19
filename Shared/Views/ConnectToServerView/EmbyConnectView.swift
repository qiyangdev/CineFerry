//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(tvOS) && canImport(EmbyAPI)
import JellyfinAPI
import SwiftUI

struct EmbyConnectView: View {

    @Router
    private var router

    let server: ServerState
    let action: (AuthenticationResult) throws -> Void

    @State
    private var pin: EmbyConnect.PIN?
    @State
    private var message: String?

    @ContentBuilder
    var body: some View {
        ZStack {
            if let message {
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
        message = nil
        var failureMessage = L10n.embyConnectUnavailable

        do {
            let pin = try await EmbyConnect.createPIN()
            try Task.checkCancellation()
            self.pin = pin

            guard let account = try await EmbyConnect.authorize(pin) else {
                message = L10n.embyConnectExpired
                return
            }

            let servers = try await EmbyConnect.servers(for: account)
            guard let linkedServer = servers.first(where: { $0.systemId == server.id }) else {
                message = L10n.embyConnectServerNotLinked
                return
            }

            self.pin = nil
            failureMessage = L10n.embyConnectServerUnavailable
            let response = try await EmbyConnect.signIn(
                to: linkedServer,
                at: server.effectiveServerURL,
                account: account
            )
            try Task.checkCancellation()
            try action(response)
            router.dismiss()
        } catch {
            if !Task.isCancelled {
                message = (error as? ErrorMessage)?.localizedDescription ?? failureMessage
            }
        }
    }
}
#endif
