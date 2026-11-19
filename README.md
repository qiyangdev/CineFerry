# CineFerry

CineFerry is a media client for Jellyfin and Emby. It is based on [Swiftfin](https://github.com/jellyfin/Swiftfin).

| Platform | Minimum OS | Server support |
| --- | --- | --- |
| iOS | 18.6 | Jellyfin and Emby |
| tvOS | 26.1 | Jellyfin |

The iOS baseline covers sign-in, opening a library item from Home, playback, closing the player, and resuming after a cold launch. It also covers switching Emby playback from Auto to a 420 kbps cap. Jellyfin and Emby support different administrative and authentication features.

## Development

Open `CineFerry.xcodeproj` in Xcode and select `CineFerry` for iOS or `CineFerry tvOS` for tvOS. Swift Package Manager uses the versions recorded in `Package.resolved`.

- [Run the iOS dual-service baseline](Documentation/ios-baseline.md)
- [Playback engines](Documentation/players.md)
- [Contributing](Documentation/contributing.md)

The app contains the service adapters and playback policy. [EmbyAPI](https://github.com/qiyangdev/EmbyAPI) provides the Emby API client.

## License

CineFerry is distributed under the [Mozilla Public License 2.0](LICENSE.md). The Swiftfin source notices retain the original contributors’ attribution.
