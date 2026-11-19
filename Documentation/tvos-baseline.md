# CineFerry tvOS service baseline

The tvOS baseline exercises Jellyfin and Emby on separate Apple TV simulators using the default player. It verifies sign-in, opening a fixture item from Home, an advancing playback clock, returning from the player with the remote, and playback resuming after a cold launch.

## Prepare the fixtures

Use the test servers, sample video and JSON structure from the [iOS baseline fixture guide](ios-baseline.md#prepare-the-fixture). For each service, enter the UUID of a disposable Apple TV simulator. When reusing a test simulator, uninstall CineFerry first, then reset the fixture account’s playback progress.

The sample should appear on Home. If it does not, the tests look for it in the `CineFerry Test` library.

## Run the baseline

```sh
python3 Tools/ServiceBaseline/run.py /path/to/private-tv-fixtures.json --platform tvos
```

Use `--derived-data /path/to/DerivedData` to reuse a build directory. Use `--service jellyfin` or `--service emby` to run a single case. The runner prints the directory containing the build log, test logs and result bundles.

The tests use the player’s elapsed-time accessibility value, require it to advance before and after a cold launch, and confirm that focus returns to the item or Home after closing the player. This checks actual playback separately from screenshot capture.

## Verified environment

Both cases passed on tvOS 26.1 with Jellyfin 12.4.0 and Emby 4.10.2.0. Both servers recorded playback stop events. The 420 kbps quality-switching test is part of the iOS baseline.
