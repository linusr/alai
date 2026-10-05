# Alai (அலை)

<p align="center"><img src="App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="Alai icon"></p>

**A native iPhone and Apple Watch app for your self-hosted [Alai server](https://github.com/linusr/alai-server).** It also works with other ntfy-compatible servers.

<p align="center"><a href="https://apps.apple.com/app/alai-notify/id6817074096"><img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="40"></a></p>

*Alai* is Tamil for "wave".

> **Unofficial.** Alai is an independent project. It isn't affiliated with or endorsed by the ntfy project. For the
> official app, see [ntfy on the App Store](https://apps.apple.com/us/app/ntfy/id1625396347).

Instant push needs the [Alai server](https://github.com/linusr/alai-server), a hard fork of ntfy with APNs support;
other ntfy servers work through the live stream and background refresh.

## Features

- Topics across multiple servers, with markdown, priorities, tags, attachments and action buttons
- Home screen switches between the topic list and a calendar: a week strip over an hour-by-hour timeline of every topic
- Search across all messages on the device, and iPhone-wide Spotlight results that open the message
- Sync All Messages fetches everything the servers still hold, within their cache duration
- Browse a server's topics: your reservations and access grants, subscriptions synced from the web app and, for admins, every user's grants and topics with recent messages
- Create topics with a reservation (private, read-only, write-only or public for other users)
- Device keys: labeled access tokens with optional expiry, a ready-to-use `curl` command, and revocation
- Home and Lock Screen widgets with recent notifications
- Apple Watch app that fetches messages itself, with complications for the latest message and unread count

## Delivery

| Mode | When | Latency |
|---|---|---|
| APNs push | Alai server with an APNs key for this app's team | Instant |
| Live stream | App in the foreground | Instant |
| Background refresh | App in the background, no APNs | iOS schedules it, from about 15 minutes to hours |

Background refresh posts local notifications for new messages on topics whose server is not registered for APNs, so
both paths never notify twice. Notifications on the iPhone are mirrored to the watch.

## Server compatibility

| Feature | Alai server | Stock ntfy |
|---|---|---|
| Servers, sign-in, subscriptions, history, refresh | ✅ | ✅ |
| Publishing, action buttons, attachments, markdown | ✅ | ✅ |
| Instant push notifications | ✅ | ❌ No `/v1/apns` endpoint; Settings shows "APNs not enabled on server" |

On upstream servers, messages arrive when the app opens or refreshes. Upstream's iOS relay (`upstream-base-url` through
ntfy.sh and Firebase) targets the official ntfy app's bundle ID and does not reach this app.

Push works only between a server and an app build that share an Apple Developer team: the server signs pushes with the
team's APNs key for the app's bundle ID.

Instant push on stock ntfy servers depends on the APNs support being accepted upstream. The server change is
self-contained (the `apns` package and opt-in `apns-*` options) and is a candidate for an upstream pull request; it is
not currently proposed.

## Requirements

- Xcode 27, iOS 26+, watchOS 26+
- An Apple Account for signing. A free account covers everything except APNs push, which needs an auth key from the
  paid Apple Developer Program; without it the app runs on the live stream and background refresh
- [mise](https://mise.jdx.dev), which installs the pinned XcodeGen, and [just](https://just.systems) for the build recipes

## Setup

1. Set your team ID and identifiers in `project.yml`:
   - `DEVELOPMENT_TEAM`: your 10-character team ID (currently `2NDDPG5773`)
   - `APP_BUNDLE_ID` and `APP_GROUP`: identifiers registered to your team
2. In the Apple Developer portal, create an APNs auth key (*Keys → +*, enable Apple Push Notifications service).
3. Configure the server with that key and the app's bundle ID:
   ```yaml
   base-url: "https://ntfy.example.com"
   apns-key-file: "/etc/ntfy/AuthKey_ABC123DEFG.p8"
   apns-key-id: "ABC123DEFG"
   apns-team-id: "DEF123GHIJ"
   apns-bundle-id: "me.4vr.alai"
   apns-file: "/var/cache/ntfy/apns.db"
   ```
4. Generate the Xcode project and open it:
   ```sh
   mise exec -- xcodegen generate
   open Alai.xcodeproj
   ```

To build, install and launch on a connected iPhone, run `just device` (or `just device <udid>` to pick one).
`just --list` shows the other recipes: `build` for the simulator, `test` for NtfyKit, `generate` for the project.

### TestFlight

1. In [App Store Connect](https://appstoreconnect.apple.com), create the app once (*Apps → + → New App*): platform
   iOS, bundle ID `me.4vr.alai`, any unused name and SKU.
2. Run `just testflight`. It archives a Release build numbered with the current UTC time, then uploads it with
   the Apple Account signed in to Xcode.
3. Once processing finishes, add testers under the app's *TestFlight* tab. Internal testers (people on the team)
   need no review.

Debug builds register with the APNs sandbox and Release builds (TestFlight, App Store) with production, matching the
`aps-environment` entitlement of each configuration.

## Layout

| Path | Contents |
|---|---|
| `Packages/NtfyKit` | Shared models, API client, keychain credentials, push payload parsing, notification formatting |
| `App` | iOS app: SwiftData storage, sync, APNs registration, SwiftUI views |
| `NotificationService` | Formats each push, resolves `poll_request` payloads, adds action buttons and images |
| `Widgets` | Home and Lock Screen widgets reading the snapshot the app writes to the app group |
| `Watch` | watchOS app: receives servers and topics from the iPhone, then polls the servers directly |
| `WatchWidgets` | Watch complications |
| `Design/render-icon.swift` | Renders the app icon variants: `swift Design/render-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset` |

The notification service extension never writes the app's database. It drops each message into an app-group inbox,
which the app imports on launch, so the two processes never share a store.

## Development

```sh
swift test --package-path Packages/NtfyKit
xcodebuild -project Alai.xcodeproj -scheme Alai -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Debug builds accept launch arguments that add a server and topics without going through onboarding:

```
-seedServer http://localhost:8080 -seedUser ben -seedPassword pw -seedTopics backups,alerts
-openTopic alerts
-openScreen browse|tokens|devicekey|addtopic
```

The watch app accepts the same `-seed*` arguments. Simulator builds signed without a team are not matched as
WatchConnectivity counterparts, so the phone cannot configure the watch there.

Background refresh does not run in the Simulator, which rejects task requests. On a device, send the app to the
background, pause it in the Xcode debugger and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"me.4vr.alai.refresh"]
```

`xcrun simctl push` delivers to Notification Center without running the notification service extension, so
extension behavior needs a device.

## Credits

Tag-to-emoji mapping from GitHub's [gemoji](https://github.com/github/gemoji) (MIT).

## License

MIT, the same licence as the [ntfy iOS app](https://github.com/binwiederhier/ntfy-ios) whose protocol handling it builds on. See [LICENSE](LICENSE).
