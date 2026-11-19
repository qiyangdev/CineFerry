# CineFerry iOS service baseline

Run this baseline with two disposable iOS simulators and test accounts on separate Jellyfin and Emby servers. The runner builds the shared iOS scheme once and runs each service against its own simulator. It uses the existing iOS XCTest target and selects only the baseline cases.

## Prepare the fixture

1. Start local test instances of [Jellyfin](https://jellyfin.org/docs/general/installation/) and [Emby](https://www.emby.media/support/articles/Installation.html). Use a disposable non-admin account with an empty password on each isolated instance so iOS can run the sign-in test without a system password-save prompt. Enable video playback transcoding for the Emby test account.
2. Generate a sample in a directory both servers can read, or use any unique H.264/AAC MP4 of about 90 seconds with a source bitrate well above 420 kbps.

   ```sh
   ffmpeg -f lavfi -i testsrc2=size=640x360:rate=24 \
     -f lavfi -i sine=frequency=440:sample_rate=48000 \
     -t 90 -c:v libx264 -preset ultrafast -b:v 1600k -minrate 1600k \
     -maxrate 1600k -bufsize 1600k -x264-params nal-hrd=cbr \
     -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart \
     "CineFerry Bitrate Test.mp4"
   ```

3. Add the directory as a library on each server and wait for the sample to appear in the latest items on Home. On the test library or server, set the minimum resume duration to zero and the minimum played percentage to 1%. Reset the test account’s playback progress for the sample before each run.
4. Create two simulators in Xcode, one per service. Start each test with a fresh CineFerry install on its disposable simulator. Find the UUIDs with `xcrun simctl list devices`. To reuse a test simulator, uninstall CineFerry from that simulator before rerunning.
5. Save a JSON file outside the repository and substitute the disposable account and simulator values.

   ```json
   {
     "jellyfin": {
       "url": "http://127.0.0.1:18097",
       "username": "ios-baseline",
       "password": "",
       "title": "CineFerry Bitrate Test",
       "simulator": "<Jellyfin simulator UUID>"
     },
     "emby": {
       "url": "http://127.0.0.1:18096",
       "username": "ios-baseline",
       "password": "",
       "title": "CineFerry Bitrate Test",
       "simulator": "<Emby simulator UUID>"
     }
   }
   ```

   The ports above are examples. Use the address as seen from the simulator, including any server base path. Treat the config and test artifacts as private because the run signs into the test servers.

## Run the baseline

```sh
python3 Tools/iOSBaseline/run.py /path/to/private-fixtures.json
```

Use `--derived-data /path/to/DerivedData` to reuse a CineFerry build directory. Use `--service jellyfin` or `--service emby` to run just that case. The runner prints the directory containing the build log, test logs, and `.xcresult` bundles and returns a failing exit status for a failed or skipped case.

The tests verify that playback time advances, the player closes to the item details, and the same item resumes and advances after a cold launch. The Emby case also verifies that playback continues after selecting 420 kbps and that a fresh playback session returns to Auto. To confirm actual server-side encoding, inspect the Emby playback session or FFmpeg log during the capped phase for `Transcode`, `420000` bps, and video re-encoding.

## Verified environment

Both cases passed on iOS 26.1 (iPhone 17 Pro simulator) and iOS 27.2 with Jellyfin 12.4.0 and Emby 4.10.2.0. The Emby server reported video re-encoding at a 420 kbps total target. The built iOS app declares a minimum OS of 26.1.
