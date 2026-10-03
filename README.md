# Offline Shazam

Identify music on an iPhone or Mac as you listen with Apple's ShazamKit. Offline captures are saved automatically and identified on your next online use. Music Sync delivers recognized songs to Spotify.

## Use

1. Open the enrollment link Music Sync's operator sends you (`just clients issue "<device>"` in the music-sync repo) on the phone and tap **Open in Offline Shazam**. The app checks that Music Sync accepts the connection and stores it in the iOS Keychain; Settings shows which service it is connected to and can disconnect, but the URL and token are never typed in. Allow microphone access and song notifications when prompted.
2. Tap **Capture song**, or use the **Capture song** App Shortcut. Shazam listens and stops recording as soon as it identifies the song. If there is no early match, the app saves the first 12 seconds as a Shazam signature for later identification (Shazam accepts saved signatures of 3 to 12 seconds); recordings shorter than 3 seconds are discarded.
3. Check recent captures for their status: saved for identification, needs connection, sending, retrying, or confirmed **Added to Spotify**. There is no manual sync step. Saving a connection automatically starts delivery of already identified songs.

The capture Shortcut opens the app to use the microphone. For an existing audio-recording Shortcut, add the **Save audio capture** action after **Record Audio**, passing its audio output. Clips must be 3 to 30 seconds and at most 16 MiB; only the first 12 seconds are used. This action waits for signature persistence and a bounded recognition pass before returning; it does not launch detached recognition work.

Live recognition receives the same microphone audio used to generate the offline signature. Captures and recognized metadata are stored before reporting success. A new match is displayed and queued for Spotify delivery before older recognition work. Saved-signature recognition processes at most three captures per invocation, with the new capture first, and queues each match for delivery as it is found. A larger backlog continues on subsequent use. Delivery uses file-backed background URLSession uploads, following the same native iOS mechanism used by Receptor. iOS may continue an enrolled upload while the app is suspended. Recognition of an offline signature needs the app to run again; reconnecting while it stays closed does not guarantee immediate recognition. Swiping the app away cancels background transfers. Running Capture song again explicitly launches the app process in the background on iOS 18+ and resumes saved work; passive reconnect alone cannot override a force quit.

Shazam provides recognition. No Mac or replacement recognition provider is required. When Shazam supplies an ISRC, Music Sync requires that exact recording on Spotify. Otherwise, it uses conservative title and artist matching. A missing Spotify match remains pending rather than adding a different recording.

## Develop and install

Requirements: macOS, Xcode, XcodeGen, just, and an iOS 17+ phone or simulator. Install development tools through your machine's supported package configuration. No third-party Swift packages are required.

```sh
just dev       # Generate the Xcode project and open it
just test      # Unit, native SDK, Keychain, delivery, and UI tests
just check     # Simulator build
IOS_TEAM_ID='<developer-team>' just build
IOS_TEAM_ID='<developer-team>' IOS_PROFILE='<ad-hoc-profile>' IOS_DEVICE_ID='<device-id>' just deploy
```

`project.yml` is the source of truth for the generated Xcode project. Override `IOS_TEST_DESTINATION` to select an installed simulator, and `IOS_DERIVED_DATA` for build output. The default build directory lives in Xcode's DerivedData location, outside the source checkout. Simulator tests use local ad hoc code signing so the real Keychain works; they require no developer account or provisioning profile.

For a device build, sign into your Apple Developer account in Xcode Settings. Set the app's bundle identifier in `project.yml` if building under another publisher. Register that explicit identifier and enable **ShazamKit** under **App Services** in the [Apple Developer account](https://developer.apple.com/help/account/services/shazamkit). ShazamKit is an App ID service, not a code-signing entitlement: do not add a `com.apple.developer.shazamkit` entitlement. For a stable installation, supply an Apple Distribution identity and an Ad Hoc profile for that App ID and phone. The embedded recording Live Activity uses the app identifier with `.activity` appended; provide an Ad Hoc profile covering that identifier and the same phone/certificate through `IOS_ACTIVITY_PROFILE` (a matching wildcard profile is sufficient). `IOS_PROFILE` signs the main app. The local `deploy` recipe builds and installs the app; this repository has no automatic deployment workflow.

Allow microphone access on the phone when prompted. On a replacement phone, reinstall and open a new enrollment link (a new capture-only Music Sync token). Revoke the old device's token through Music Sync. The Keychain credential is device-bound. Local pending captures are not a cross-device sync service.

## Service contract

Music Sync owns the capture API, Spotify account connection, revocable client tokens, and durable delivery receipts. Offline Shazam knows only its HTTPS capture endpoint and its own issued bearer token. It carries no Spotify, Modal, R2, or infrastructure credentials.

A request contains `capture_id` (stable UUID), `title`, `artist`, `apple_music_id`, and `shazam_url`, with optional `isrc`. Success requires a 2xx response with `ok: true`, the same capture UUID, and a nonempty recording ISRC. If Shazam supplied an ISRC, the receipt must agree. Only that acknowledgment produces the green **Added to Spotify** status. Other responses retain the matched metadata for automatic retry; numeric or HTTP-date `Retry-After` is respected, with a minimum 30-second delay. A single timer wakes the next retry while the app can run, and app activation resumes persisted deadlines. Missing credentials prompt setup. A stored authentication rejection is rechecked automatically on app/Shortcut use; an accepted connection clears the old pause and sends waiting songs. Rejected keys and incorrect URLs have specific messages. Connection verification uses an authenticated empty capture payload, expects the service's exact validation response, and cannot add a song. Native background uploads can continue while the app is suspended; iOS controls that execution, and reopening the app resumes unfinished work. Request redirects are rejected. The server durably pins the selected recording before Spotify side effects and deduplicates repeat requests.

Signatures and queue metadata stay in the app's Application Support directory. Live microphone audio is processed in memory; temporary import files are removed after processing. Successful delivery removes the signature while retaining recent song history. Unidentified recordings remain visible and retained. There is no analytics SDK.

The waveform and status icons are from [Tabler](https://icon-sets.iconify.design/tabler/), delivered through Iconify and used under the MIT license.

## Recording and notifications

Tap the capture button again to cancel an accidental recording. Explicit Cancel discards that recording; an interruption retains useful audio for the next use. The Dynamic Island and Lock Screen recording activity also have Cancel. The activity runs only for the requested recording, up to 15 seconds, then shows the result for a few seconds: the song and artist, "No match", or "Saved for later" when offline.

On iOS 18+, the Capture song Shortcut uses the native audio-recording intent and runs without opening the app, including when the app was previously swiped away. Enable Live Activities in the app's system settings. iOS 17 asks to continue in the foreground. Microphone access, native notification authorization and Live Activities are user settings; a replacement phone must be enrolled again with its own Music Sync token.

Recognition waits up to 10 seconds for Spotify delivery before notifying. A confirmed delivery during that window produces one combined notification. Later delivery replaces that notification with an Added to Spotify alert, so each song shows one card. Only a valid Music Sync receipt permits the Spotify confirmation. Denying notifications does not prevent capture or delivery; notification permissions can be changed in iOS Settings.

## Mac app

The same capture, queue and delivery code ships as a native macOS app (macOS 14+) with a Capture window and a menu-bar item (Capture song, pending count, Open, Quit). Open the Mac's own enrollment link; each device gets its own token. There is no Live Activity or Shortcut on the Mac; the app must be running to capture. Allow microphone access and notifications when prompted.

Releasing the Mac app = pushing a tag `vX.Y.Z`: `.github/workflows/release.yml` builds an unsigned Release with `just build-mac`, Developer ID-signs and notarizes it, publishes a GitHub release and bumps the `offline-shazam` cask in the Homebrew tap. Install it declaratively from the tap. `just check-mac` / `just test-mac` are the Mac CI gates; `just run-mac` makes a development-signed local build for a microphone smoke test.
