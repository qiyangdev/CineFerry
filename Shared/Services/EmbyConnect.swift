//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

#if os(tvOS) && canImport(EmbyAPI)
import Foundation
import JellyfinAPI

enum EmbyConnect {

    struct PIN: Decodable {

        let pin: String
        let deviceId: String
    }

    struct LinkedServer: Decodable {

        let systemId: String
        let accessKey: String
    }

    struct Account: Decodable {

        let userId: String
        let accessToken: String
    }

    private struct PINStatus: Decodable {

        let isConfirmed: Bool
        let isExpired: Bool?
    }

    private struct ServerToken: Decodable {

        let localUserId: String
        let accessToken: String
    }

    private struct HTTPFailure: Error {

        let status: Int
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)

    static func createPIN() async throws -> PIN {
        // A distinct device challenge prevents a canceled attempt from sharing a PIN with its replacement.
        let pin: PIN = try await cloud("pin", form: [.init(name: "deviceId", value: UUID().uuidString)])
        guard !pin.pin.isEmpty, !pin.deviceId.isEmpty else { throw URLError(.cannotParseResponse) }

        return pin
    }

    static func authorize(_ pin: PIN) async throws -> Account? {
        let parameters: [URLQueryItem] = [.init(name: "deviceId", value: pin.deviceId), .init(name: "pin", value: pin.pin)]
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(300)
        while clock.now < deadline {
            try await Task.sleep(for: .seconds(3))
            let status: PINStatus
            do {
                status = try await cloud("pin", query: parameters)
            } catch let error as HTTPFailure where [404, 410].contains(error.status) {
                return nil
            }
            if status.isExpired == true {
                return nil
            }
            if status.isConfirmed {
                let account: Account = try await cloud("pin/authenticate", form: parameters)
                guard !account.userId.isEmpty, !account.accessToken.isEmpty else { throw URLError(.cannotParseResponse) }

                return account
            }
        }
        return nil
    }

    static func servers(for account: Account) async throws -> [LinkedServer] {
        try await cloud(
            "servers",
            query: [.init(name: "userId", value: account.userId)],
            token: account.accessToken
        )
    }

    static func signIn(
        to server: LinkedServer,
        at url: URL,
        account: Account
    ) async throws -> AuthenticationResult {
        let info = try await EmbyServer.probe(url)
        guard info.id == server.systemId else { throw ErrorMessage(L10n.connectionServerMismatch) }

        var exchange = URLRequest(url: url.appending(path: "Connect/Exchange").appending(queryItems: [
            .init(name: "format", value: "json"),
            .init(name: "ConnectUserId", value: account.userId),
        ]))
        exchange.timeoutInterval = 8
        try EmbyServer.client(url: url).authenticate(&exchange)
        exchange.setValue(server.accessKey, forHTTPHeaderField: "X-Emby-Token")
        let token: ServerToken = try await send(exchange)
        guard !token.localUserId.isEmpty, !token.accessToken.isEmpty else { throw URLError(.cannotParseResponse) }

        return try await EmbyServer.authenticatedUser(
            at: url,
            userID: token.localUserId,
            accessToken: token.accessToken,
            serverID: server.systemId
        )
    }

    private static func cloud<T: Decodable>(
        _ endpoint: String,
        query: [URLQueryItem] = [],
        form: [URLQueryItem]? = nil,
        token: String? = nil
    ) async throws -> T {
        let url = URL(string: "https://connect.emby.media/service/\(endpoint)")!.appending(queryItems: query)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request.setValue("CineFerry/\(version)", forHTTPHeaderField: "X-Application")
        request.setValue(token, forHTTPHeaderField: "X-Connect-UserToken")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = form
            request.httpBody = components.percentEncodedQuery?.replacing("+", with: "%2B").data(using: .utf8)
        }

        return try await send(request)
    }

    private static func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(response.statusCode) else { throw HTTPFailure(status: response.statusCode) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last?.stringValue ?? ""
            return ConnectKey(stringValue: key.prefix(1).lowercased() + key.dropFirst())
        }
        return try decoder.decode(T.self, from: data)
    }

    private struct ConnectKey: CodingKey {

        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
#endif
