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
import Logging

enum EmbyServer {

    static let productName = "Emby Server"

    static func matches(_ info: PublicSystemInfo) -> Bool {
        if let product = info.productName, !product.isEmpty {
            return product.localizedCaseInsensitiveContains("Emby")
        }
        return info.version?.split(separator: ".").first == "4"
    }

    static func client(
        url: URL,
        userID: String? = nil,
        accessToken: String? = nil
    ) throws -> EmbyClient {
        let configuration = JellyfinClient.Configuration.cineFerryConfiguration(url: url)
        let identity = EmbyClient.Identity(
            client: configuration.client,
            device: configuration.deviceName,
            deviceID: configuration.deviceID,
            version: configuration.version
        )
        let session: EmbyClient.Session? = if let userID, let accessToken {
            .init(userID: userID, accessToken: accessToken)
        } else {
            nil
        }
        return try EmbyClient(serverURL: url, identity: identity, session: session)
    }

    static func probe(_ url: URL) async throws -> PublicSystemInfo {
        let response = try await client(url: url).api.getSystemInfoPublic()
        let info = try response.ok.body.json
        guard let id = info.Id,
              !id.isEmpty,
              let name = info.ServerName,
              !name.isEmpty,
              info.Version?.split(separator: ".").first == "4"
        else { throw ErrorMessage(L10n.unknownError) }

        return PublicSystemInfo(
            id: id,
            localAddress: info.LocalAddress,
            productName: productName,
            serverName: name,
            version: info.Version
        )
    }

    static func signIn(
        at server: ServerState,
        username: String,
        password: String
    ) async throws -> AuthenticationResult {
        let url = server.effectiveServerURL
        let session: EmbyClient.Session
        do {
            session = try await client(url: url).signIn(username: username, password: password)
        } catch let EmbyClient.Error.httpStatus(status) {
            throw APIError.unacceptableStatusCode(status)
        }
        if let serverID = session.serverID, serverID != server.id {
            throw ErrorMessage(L10n.connectionServerMismatch)
        }
        return try await authenticatedUser(at: url, userID: session.userID, accessToken: session.accessToken, serverID: server.id)
    }

    static func authenticatedUser(at url: URL, userID: String, accessToken: String, serverID: String) async throws -> AuthenticationResult {
        let emby = try client(url: url, userID: userID, accessToken: accessToken)
        let response = try await emby.api.getUsersById(path: .init(Id: userID))
        let user = try convertUser(response.ok.body.json)
        guard user.id == userID else { throw ErrorMessage(L10n.unknownError) }

        return AuthenticationResult(accessToken: accessToken, serverID: serverID, user: user)
    }

    static func publicUsers(at url: URL) async throws -> [UserDto] {
        let response = try await client(url: url).api.getUsersPublic()
        return try response.ok.body.json.map(convertUser)
    }

    static func loginDisclaimer(at url: URL) async throws -> String? {
        let response = try await client(url: url).api.getBrandingConfiguration()
        return try response.ok.body.json.LoginDisclaimer
    }

    static func playbackInfo(
        _ body: PlaybackInfoDto,
        itemID: String,
        client: EmbyClient,
        requiresVideoTranscoding: Bool = false
    ) async throws -> PlaybackInfoResponse {
        var payload = try JSONSerialization.encode(body)
        if var profile = payload["DeviceProfile"] as? [String: Any],
           var codecs = profile["CodecProfiles"] as? [[String: Any]] {
            for index in codecs.indices {
                guard var conditions = codecs[index]["Conditions"] as? [[String: Any]] else { continue }

                for condition in conditions.indices where conditions[condition]["Property"] as? String == "VideoRangeType" {
                    conditions[condition]["Property"] = Components.Schemas.ProfileConditionValue.VideoRange.rawValue
                }
                codecs[index]["Conditions"] = conditions
            }
            profile["CodecProfiles"] = codecs
            payload["DeviceProfile"] = profile
        }
        var input = try JSONSerialization.decode(Components.Schemas.PlaybackInfoRequest.self, from: payload)
        input.IsPlayback = true
        if requiresVideoTranscoding {
            input.EnableDirectPlay = false
            input.EnableDirectStream = false
            input.EnableTranscoding = true
            input.AllowVideoStreamCopy = false
        }
        let response = try await client.api.postItemsByIdPlaybackinfo(path: .init(Id: itemID), body: .json(input))
        return try convert(response.ok.body.json, to: PlaybackInfoResponse.self)
    }

    static func streamURL(
        itemID: String,
        isAudio: Bool,
        source: MediaSourceInfo,
        playSessionID: String,
        baseURL: URL,
        accessToken: String?
    ) throws -> URL {
        var components: URLComponents
        if let reference = source.transcodingURL {
            guard let target = URLComponents(string: reference),
                  let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
                  target.host == nil || (target.scheme == base.scheme && target.host == base.host && target.port == base.port),
                  target.user == nil,
                  target.password == nil
            else { throw URLError(.badURL) }

            if target.host != nil || target.percentEncodedPath.hasPrefix(base.percentEncodedPath + "/") {
                components = target.host == nil ? base : target
                components.percentEncodedPath = target.percentEncodedPath
            } else {
                components = base
                let path = "/" + target.percentEncodedPath.drop(while: { $0 == "/" })
                let relativePath = baseURL.lastPathComponent.lowercased() == "emby" && path.hasPrefix("/emby/")
                    ? String(path.dropFirst("/emby".count))
                    : path
                components.percentEncodedPath = base.percentEncodedPath + relativePath
            }
            components.percentEncodedQuery = target.percentEncodedQuery
        } else {
            guard let id = source.id,
                  source.isSupportsDirectPlay == true || source.isSupportsDirectStream == true,
                  let url = URLComponents(
                      url: baseURL.appending(component: isAudio ? "Audio" : "Videos")
                          .appending(component: itemID)
                          .appending(component: "stream"),
                      resolvingAgainstBaseURL: false
                  )
            else { throw ErrorMessage(L10n.unknownError) }

            components = url
            components.queryItems = [
                .init(name: "Static", value: "true"),
                .init(name: "MediaSourceId", value: id),
                .init(name: "PlaySessionId", value: playSessionID),
            ]
        }
        if let accessToken, !(components.queryItems ?? []).contains(where: {
            ["api_key", "apikey"].contains($0.name.lowercased())
        }) {
            let encodedQuery = components.percentEncodedQueryItems ?? []
            var token = URLComponents()
            token.queryItems = [.init(name: "api_key", value: accessToken)]
            components.percentEncodedQueryItems = encodedQuery + (token.percentEncodedQueryItems ?? [])
        }
        guard let url = components.url else { throw URLError(.badURL) }

        return url
    }

    private static func convert<Value: Decodable>(_ input: some Encodable, to type: Value.Type) throws -> Value {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try decode(type, from: encoder.encode(input)).0
    }

    private static func convertUser(_ input: Components.Schemas.UserDto) throws -> UserDto {
        try convert(input, to: UserDto.self)
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        itemID: String? = nil,
        operation: String? = nil,
        row: Int? = nil
    ) throws -> (Value, Data) {
        if let bytes = data as? Value {
            return (bytes, data)
        }
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        let normalized: Any
        if type == UserItemDataDto.self, var userData = object as? [String: Any], let itemID {
            userData["Key"] = userData["Key"] ?? itemID
            normalized = userData
        } else {
            normalized = adaptFields(object)
        }
        let payload = try JSONSerialization.data(withJSONObject: normalized, options: .fragmentsAllowed)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        do {
            return try (decoder.decode(type, from: payload), payload)
        } catch let error as DecodingError {
            logDecodingFailure(error, operation: operation ?? String(describing: type), row: row)
            throw error
        }
    }

    static func logDecodingFailure(_ error: DecodingError, operation: String, row: Int? = nil) {
        let keys: [any CodingKey]
        let reason: String
        switch error {
        case let .typeMismatch(type, context):
            keys = context.codingPath
            reason = "expected \(type)"

        case let .valueNotFound(type, context):
            keys = context.codingPath
            reason = "missing \(type)"

        case let .keyNotFound(key, context):
            keys = context.codingPath + [key]
            reason = "missing field"

        case let .dataCorrupted(context):
            keys = context.codingPath
            reason = "invalid value"

        @unknown default:
            return
        }
        let prefix = row.map { "Items[\($0)]" } ?? ""
        let path = keys.reduce(prefix) { path, key in
            if let index = key.intValue {
                return path + "[\(index)]"
            }
            return path.isEmpty ? key.stringValue : path + "." + key.stringValue
        }
        Logger.cineFerry().warning("Emby decoding failed for \(operation) at \(path) (\(reason))")
    }

    private static func adaptFields(_ value: Any) -> Any {
        if let values = value as? [Any] {
            return values.map(adaptFields)
        }
        guard var fields = (value as? [String: Any])?.mapValues(adaptFields) else { return value }

        if let id = fields["Id"] as? NSNumber {
            fields["Id"] = id.stringValue
        }

        if let streams = fields["MediaStreams"] as? [[String: Any]] {
            fields["MediaStreams"] = streams.map(adaptMediaStream)
        }

        // Emby leaves out fields which the app's Jellyfin DTOs require.
        if var policy = fields["Policy"] as? [String: Any] {
            policy["AuthenticationProviderId"] = policy["AuthenticationProviderId"] ?? ""
            policy["PasswordResetProviderId"] = policy["PasswordResetProviderId"] ?? ""
            fields["Policy"] = policy
        }
        if var userData = fields["UserData"] as? [String: Any], let id = fields["Id"] as? String {
            userData["Key"] = userData["Key"] ?? id
            fields["UserData"] = userData
        }
        return fields
    }

    private static func adaptMediaStream(_ stream: [String: Any]) -> [String: Any] {
        var fields = stream
        if let type = fields["Type"] as? String, JellyfinAPI.MediaStreamType(rawValue: type) == nil {
            fields.removeValue(forKey: "Type")
        }
        if let range = fields["VideoRange"] as? String, JellyfinAPI.VideoRange(rawValue: range) == nil {
            if let standard = JellyfinAPI.VideoRange.allCases.first(where: {
                $0.rawValue.caseInsensitiveCompare(range) == .orderedSame
            }) {
                fields["VideoRange"] = standard.rawValue
            } else {
                let subtypeName = range.replacing("+", with: "Plus")
                let subtype = JellyfinAPI.VideoRangeType.allCases.first {
                    $0.rawValue.caseInsensitiveCompare(subtypeName) == .orderedSame
                }
                fields["VideoRange"] = (subtype?.isHDR == true ? JellyfinAPI.VideoRange.hdr : .unknown).rawValue
                if let subtype, fields["VideoRangeType"] == nil {
                    fields["VideoRangeType"] = subtype.rawValue
                }
            }
        }
        return fields
    }
}

/// Retains the app's existing DTO decoding and partial-item merge behavior for compatible Emby responses.
struct EmbyRequestAdapter: APIClientDelegate {

    let client: Result<EmbyClient, Error>
    let userID: String

    func client(_ client: APIClient, willSendRequest request: inout URLRequest) async throws {
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        try self.client.get().authenticate(&request)
    }

    func client(_ client: APIClient, makeURLForRequest request: Request<some Any>) throws -> URL? {
        guard let original = request.url, original.scheme == nil, original.host == nil else {
            throw URLError(.badURL)
        }

        var path = original.path.split(separator: "/").map(String.init)
        var query = request.query ?? []

        switch request.id {
        case "GetUserViews":
            path = ["Users", userID, "Views"]
        case "GetItem", "GetLatestMedia", "GetLocalTrailers", "GetSpecialFeatures":
            path = ["Users", userID] + path
        case "GetResumeItems":
            path = ["Users", userID, "Items", "Resume"]
        case "MarkFavoriteItem", "UnmarkFavoriteItem":
            path = ["Users", userID, "FavoriteItems"] + path.dropFirst()
        case "MarkPlayedItem", "MarkUnplayedItem":
            path = ["Users", userID, "PlayedItems"] + path.dropFirst()
        default:
            break
        }

        if path.first == "Users", path.dropFirst().first == userID {
            query.removeAll { $0.0.caseInsensitiveCompare("UserId") == .orderedSame }
        } else if request.method == .get,
                  ["Items", "Shows", "Videos"].contains(path.first ?? ""),
                  !query.contains(where: { $0.0.caseInsensitiveCompare("UserId") == .orderedSame }) {
            query.append(("UserId", userID))
        }

        let url = try path.reduce(self.client.get().serverURL) { $0.appending(component: $1) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }

        components.queryItems = query.isEmpty ? nil : query.map(URLQueryItem.init)
        components.percentEncodedQuery = components.percentEncodedQuery?.replacing("+", with: "%2B")
        guard let result = components.url else { throw URLError(.badURL) }

        return result
    }
}

final class EmbyAPIRedirectDelegate: NSObject, URLSessionTaskDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let from = response.url,
              let to = request.url,
              from.scheme == to.scheme,
              from.host == to.host,
              from.port == to.port
        else {
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }
}
#endif
