//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import Logging

/// Resolves one item identity and its configuration into a playable item.
@MainActor
enum MediaPlayerItemResolver {

    static func resolve(
        _ intent: PlaybackIntent,
        for profile: PlaybackProfile,
        userSession: UserSession
    ) async throws -> MediaPlayerItem {
        try Task.checkCancellation()
        guard var initialItem = intent.entry.value else { throw ItemStore.StoreError.itemUnavailable }

        if initialItem.type == .program {
            guard let channel = try await initialItem.getChannel(for: initialItem, userSession: userSession) else {
                throw ErrorMessage(L10n.unknownError)
            }

            initialItem = channel
        }

        let logger = Logger.cineFerry()

        guard let itemID = initialItem.id else {
            logger.critical("No item ID!")
            throw ErrorMessage(L10n.unknownError)
        }

        let storedItem = try await userSession.getFullItem(initialItem)
        guard var item = storedItem.value, intent.entry.value != nil else { throw ItemStore.StoreError.itemUnavailable }

        if item.type == .audio, item.mediaType == nil {
            item.mediaType = .audio
        }

        var configuration = intent.configuration
        guard let initialMediaSource = configuration.mediaSource(in: item) else {
            throw ErrorMessage("Unable to find media source for item")
        }

        configuration.prepare(for: item, source: initialMediaSource, profile: profile)
        let maxBitrate = try await getMaxBitrate(configuration: configuration, userSession: userSession)
        let deviceProfile = profile.deviceProfile(
            configuration: configuration,
            maxBitrate: maxBitrate,
            mediaSource: initialMediaSource
        )

        var playbackInfo = PlaybackInfoDto()
        playbackInfo.isAutoOpenLiveStream = true

        if profile.requiresHLS {
            guard item.mediaType == .video else { throw ErrorMessage(L10n.remotePlaybackUnavailable) }

            playbackInfo.enableDirectPlay = false
            playbackInfo.enableDirectStream = false
            playbackInfo.enableTranscoding = true
        }

        playbackInfo.deviceProfile = deviceProfile
        playbackInfo.liveStreamID = initialMediaSource.liveStreamID
        playbackInfo.maxStreamingBitrate = maxBitrate
        playbackInfo.userID = userSession.user.id
        playbackInfo.audioStreamIndex = configuration.audioStreamIndex
        playbackInfo.subtitleStreamIndex = configuration.subtitleStreamIndex

        if !item.isLiveStream, initialMediaSource.type != .placeholder {
            playbackInfo.mediaSourceID = initialMediaSource.id
        }

        let request = Paths.getPostedPlaybackInfo(
            itemID: itemID,
            playbackInfo
        )

        try userSession.items.validate()
        let client = userSession.client

        var playback: PlaybackInfoResponse
        #if canImport(EmbyAPI)
        if userSession.server.isEmby {
            playback = try await EmbyServer.playbackInfo(
                playbackInfo,
                itemID: itemID,
                client: userSession.makeEmbyClient()
            )
        } else {
            playback = try await Task { try await client.send(request) }.value.value
        }
        #else
        playback = try await Task { try await client.send(request) }.value.value
        #endif

        do {
            try Task.checkCancellation()
            try userSession.items.validate()

            guard storedItem.value != nil, intent.entry.value != nil else { throw ItemStore.StoreError.itemUnavailable }
            guard var mediaSource = selectSource(from: playback, matching: initialMediaSource, logger: logger) else {
                throw ErrorMessage("Unable to find media source for item")
            }

            #if canImport(EmbyAPI)
            if userSession.server.isEmby,
               item.mediaType == .video,
               !item.isLiveStream,
               initialMediaSource.liveStreamID == nil,
               mediaSource.liveStreamID == nil,
               configuration.compatibilityMode != .directPlay,
               configuration.requestedBitrate != .auto,
               mediaSource.transcodingURL == nil,
               let sourceBitrate = mediaSource.bitrate ?? initialMediaSource.bitrate,
               sourceBitrate > maxBitrate {
                // Emby can offer the original even when it exceeds a requested playback cap.
                playbackInfo.mediaSourceID = mediaSource.id ?? playbackInfo.mediaSourceID
                playback = try await EmbyServer.playbackInfo(
                    playbackInfo,
                    itemID: itemID,
                    client: userSession.makeEmbyClient(),
                    requiresVideoTranscoding: true
                )
                try Task.checkCancellation()
                try userSession.items.validate()
                guard storedItem.value != nil, intent.entry.value != nil else { throw ItemStore.StoreError.itemUnavailable }

                let transcodedSource = selectSource(from: playback, matching: mediaSource, logger: logger)
                guard let transcodedSource, transcodedSource.transcodingURL != nil else {
                    let errorCode = playback.errorCode?.rawValue ?? "none"
                    let serverSupportsTranscoding = transcodedSource?.isSupportsTranscoding.map(String.init) ?? "unknown"
                    let userAllowsTranscoding = userSession.userData.policy?.enableVideoPlaybackTranscoding.map(String.init) ?? "unknown"
                    logger.warning(
                        "Emby capped playback returned no transcoding URL",
                        metadata: [
                            "errorCode": .string(errorCode),
                            "serverSupportsTranscoding": .string(serverSupportsTranscoding),
                            "userAllowsTranscoding": .string(userAllowsTranscoding),
                        ]
                    )
                    throw ErrorMessage(L10n.containerBitrateExceedsLimit)
                }

                mediaSource = transcodedSource
            }
            #endif

            item.runTimeTicks = mediaSource.runTimeTicks ?? item.runTimeTicks

            guard let playSessionID = playback.playSessionID else {
                throw ErrorMessage("No associated play session ID")
            }

            var playbackURL = try Self.streamURL(
                item: item,
                mediaSource: mediaSource,
                playSessionID: playSessionID,
                userSession: userSession,
                logger: logger
            )

            if profile.requiresHLS {
                guard mediaSource.transcodingURL != nil,
                      playbackURL.pathExtension.lowercased() == "m3u8",
                      let authenticatedURL = RemotePlaybackURL.authenticated(playbackURL, accessToken: client.accessToken)
                else { throw ErrorMessage(L10n.remotePlaybackUnavailable) }

                playbackURL = authenticatedURL
            }

            configuration.finish(source: mediaSource, initialSource: initialMediaSource)

            let chapters = item.fullChapterInfo(using: client)
            let temporaryFiles = PlaybackTemporaryFiles(accessToken: client.accessToken)

            let previewImageProvider = PreviewImageProvider(
                option: configuration.previewImageScrubbing,
                item: item,
                mediaSourceID: mediaSource.id,
                chapters: chapters,
                client: client,
                resolveImage: temporaryFiles.image(for:)
            )

            return .init(
                baseItem: item,
                mediaSource: mediaSource,
                playSessionID: playSessionID,
                url: playbackURL,
                configuration: configuration,
                deviceProfile: deviceProfile,
                chapters: chapters,
                temporaryFiles: temporaryFiles,
                previewImageProvider: previewImageProvider,
                thumbnailProvider: { await storedItem.value?.getNowPlayingImage() }
            )
        } catch {
            closeLiveStreams(playback.mediaSources ?? [], userSession: userSession)
            throw error
        }
    }

    private static func selectSource(
        from playback: PlaybackInfoResponse,
        matching initialMediaSource: MediaSourceInfo,
        logger: Logger
    ) -> MediaSourceInfo? {
        guard let mediaSources = playback.mediaSources else { return nil }

        if let tag = initialMediaSource.eTag,
           let matchingTag = mediaSources.first(property: \.eTag, equalTo: tag) {
            return matchingTag
        }

        if let initialID = initialMediaSource.id,
           let matchingMediaSource = mediaSources.first(property: \.id, equalTo: initialID) {
            return matchingMediaSource
        }

        for source in mediaSources {
            if let openToken = source.openToken,
               let id = source.id,
               openToken.contains(id) {
                return source
            }
        }

        logger.warning("Unable to find matching media source, defaulting to first media source")
        return mediaSources.first
    }

    private static func getMaxBitrate(
        configuration: MediaPlaybackConfiguration,
        userSession: UserSession
    ) async throws -> Int {
        guard configuration.requestedBitrate == .auto else { return configuration.requestedBitrate.rawValue }

        let testSize = configuration.bitrateTestSize
        let start = ContinuousClock.now
        _ = try await userSession.send(Paths.getBitrateTestBytes(size: testSize.rawValue))

        let seconds = max(start.duration(to: .now).seconds, 0.001)
        let measuredBitrate = Double(testSize.rawValue * 8) / seconds

        return Int(clamp(
            measuredBitrate,
            min: Double(PlaybackBitrate.kbps420.rawValue),
            max: Double(Int32.max)
        ))
    }

    /// An abandoned resolution can have opened a live stream before a player ever loads its URL.
    private static func closeLiveStreams(_ mediaSources: [MediaSourceInfo], userSession: UserSession) {
        let streamIDs = Set(mediaSources.compactMap(\.liveStreamID))
        guard streamIDs.isNotEmpty else { return }

        let client = userSession.client

        Task {
            for streamID in streamIDs {
                _ = try? await client.send(Paths.closeLiveStream(liveStreamID: streamID))
            }
        }
    }

    private static func streamURL(
        item: BaseItemDto,
        mediaSource: MediaSourceInfo,
        playSessionID: String,
        userSession: UserSession,
        logger: Logger
    ) throws -> URL {
        guard let itemID = item.id else {
            throw ErrorMessage("No item ID while building online media player item!")
        }

        #if canImport(EmbyAPI)
        if userSession.server.isEmby, item.mediaType == .video || item.mediaType == .audio {
            return try EmbyServer.streamURL(
                itemID: itemID,
                isAudio: item.mediaType == .audio,
                source: mediaSource,
                playSessionID: playSessionID,
                baseURL: userSession.server.effectiveServerURL,
                accessToken: userSession.user.accessToken
            )
        }
        #endif

        if let transcodingPath = mediaSource.transcodingURL {
            logger.trace("Using transcoding URL for item \(itemID)")

            guard let url = userSession.client.url(path: transcodingPath) else {
                throw ErrorMessage("Unable to make transcoding URL")
            }

            return url
        }

        if item.mediaType == .video {
            logger.trace("Making video stream URL for item \(itemID)")

            let videoStreamParameters = Paths.GetVideoStreamParameters(
                isStatic: true,
                tag: mediaSource.eTag ?? item.etag,
                playSessionID: playSessionID,
                mediaSourceID: mediaSource.id ?? itemID,
                liveStreamID: mediaSource.liveStreamID
            )

            let videoStreamRequest = Paths.getVideoStream(
                itemID: itemID,
                parameters: videoStreamParameters
            )

            guard let videoStreamURL = userSession.client.url(with: videoStreamRequest, queryAPIKey: true)
            else { throw ErrorMessage("Unable to make video stream URL") }

            return videoStreamURL
        }

        if item.mediaType == .audio {
            logger.trace("Making audio stream URL for item \(itemID)")

            let parameters = Paths.GetAudioStreamParameters(
                isStatic: true,
                tag: mediaSource.eTag ?? item.etag,
                playSessionID: playSessionID,
                mediaSourceID: mediaSource.id ?? itemID,
                liveStreamID: mediaSource.liveStreamID
            )

            let request = Paths.getAudioStream(itemID: itemID, parameters: parameters)
            guard let url = userSession.client.url(with: request, queryAPIKey: true) else {
                throw ErrorMessage("Unable to make audio stream URL")
            }

            return url
        }

        throw ErrorMessage("Unsupported playback media type")
    }
}
