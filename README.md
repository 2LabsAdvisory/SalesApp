# Sales by 2Labs — iOS companion

The phone half of Sales by 2Labs. Swift and SwiftUI, iOS 26 and later, no
third-party dependencies.

The spine is one sentence: **"Hey Siri, take a 2Labs note"** — said into a
locked phone after a meeting, transcribed on the phone, queued if there is no
signal, and in the web app's Notes tab when it lands. This build is FR15: the
native shell, signing in, capture, and the queue. Today, Pipeline and Deal
(FR16) and note review on the phone (FR17) come next.

Design and decisions live outside the repo, in the Cowork folder:
`Mobile App/Feature Requests/FR15 - Mobile companion — native shell, sign-in and capture.md`
is the spec, `Mobile App/mockups/Sales_Mobile_Prototype.html` the screens, and
`ARCHITECTURE.md` §5 and §6a the rules this app lives under.

## Three rules, before changing anything

1. **Same API, no mobile-only backend.** Everything goes through the
   `Sales-Functions` endpoints the web app uses. Anything this app needs is a
   normal endpoint, useful to both clients — nothing iOS-shaped, because
   Android arrives later against the same API.
2. **A phone is not a trusted client.** The app never sends an
   `organization_id` as an input. The session's active org is the only
   source. `X-Sales-Organization` is an assertion the server checks, and a
   mismatch is refused, never obeyed.
3. **The session differs only where a phone forces it.** A device signs in,
   holds a rotating refresh token and a 15-minute access token in the
   Keychain (`AfterFirstUnlockThisDeviceOnly`), and sends the access token as
   a Bearer header. Nothing sensitive goes in `UserDefaults` or a plist.

## Layout

```
SalesApp/
├── App/          entry point, the shared services, the app model (phase, org, Face ID gate)
├── Auth/         Keychain, token store, PKCE, Microsoft sign-in (ASWebAuthenticationSession)
├── API/          the client and the shapes it decodes
├── Capture/      CaptureService (the one way a note enters), the queue, the sender, the recorder
├── Intents/      the Siri App Intent and its phrases
├── Views/        sign-in, org picker, Notes, listening sheet, note detail, account, lock
├── Design/       the 2Labs tokens and the few shared pieces
└── Sales.icon    the app icon (Icon Composer)
SalesAppTests/    Swift Testing: queue, session, decoding, wording
Config/Info.plist API base URL per configuration, the "2Labs" alternative app name
```

Files are picked up by folder: anything added under `SalesApp/` or
`SalesAppTests/` is in the build without touching the project file.

## How a note travels

1. **Said.** Siri (`TakeNoteIntent`, runs locked, never opens the app) or the
   mic button (`SpeechCapture`, on `SpeechAnalyzer`, which runs only on the
   device — there is no server path to fall back to). Audio goes from the mic
   to the analyzer in memory and is never written anywhere.
2. **Saved.** `CaptureService` writes it to `NoteQueue` — a file protected
   `completeUntilFirstUserAuthentication`, so it works while locked — with a
   client-generated id and the org selected at that moment. From here it
   exists, whatever the signal.
3. **Sent.** `NoteSender` uploads one note at a time, in the order said, as a
   background `URLSession` upload. The system carries it while the app is
   suspended or not running and sends it when there is signal. A retry sends
   the same `client_id`, so the server returns the first note rather than
   making a second.
4. **Answered.** Confirmed → removed from the phone. Token lapsed → refresh
   and go again. Session moved to another org → switch back to the note's org
   (membership-checked) and send. Refused for good → kept on the phone, marked
   failed, with a Try again. Nothing is ever dropped to tidy up.

## Running it

Needs Xcode 26 or later and the local API.

```bash
open SalesApp.xcodeproj
```

Debug builds talk to `http://localhost:7071/api` — start the API with
`../SalesBy2Labs/dev.command`, or `func start` in `../Sales-Functions`. The
database needs migration 015 (device sessions). Sign in with a seeded address
(`rob@kestrelsystems.ca`); with `DEV_LOG_OTP=true` the 7-digit code is printed
in the API console.

The simulator may not have Apple's on-device speech model, in which case the
mic says so and stops. To exercise the queue and the sender there, launch with a note:

```bash
xcrun simctl launch booted ca.2labs.sales -SalesCaptureOnLaunch "Coffee with Priya."
```

(Debug builds only.) Siri, Face ID and on-device speech need a real iPhone.

## Tests

```bash
xcodebuild test -project SalesApp.xcodeproj -scheme SalesApp -destination 'platform=iOS Simulator,name=iPhone 17'
```

Simulator builds are signed locally (`CODE_SIGN_IDENTITY = "-"`), which the
Keychain needs; building with signing turned off makes the session tests fail
with `errSecMissingEntitlement`.

## Voice

Senior, calm, vendor-neutral. No emoji, no hype, and no sales-bro language —
in the UI, in Siri's replies, or in comments.
