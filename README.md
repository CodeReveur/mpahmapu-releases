# Motari

The moto taxi driver app for MpahMapu, in Flutter.

It carries **only the Motari vertical** — sign in, go online, take rides and
parcels, get paid, settle the daily fee. Everything else the platform does
(jobs, workers, employers, admin) stays on the website.

It talks to the same backend as the web apps, through the same
`/api/rides/driver/**` endpoints, so a motari can move between the phone app and
`/drive` in a browser and see the same state.

## Running it

```bash
flutter pub get

# Against production
flutter run

# Against a backend on your machine (10.0.2.2 is the host from an Android emulator)
flutter run --dart-define=MOTARI_API=http://10.0.2.2:8088
```

`MOTARI_API` defaults to `https://backend.mpahmapu.com`. The app calls the
backend directly — there is no same-origin gateway to hide behind as in the
browser — so a debug build against a plain-HTTP host needs Android's
cleartext exception, which the debug manifest already allows.

## What is in it

| Screen | What it does |
| --- | --- |
| Permissions | The first screen on every launch. Location is required and the way through is to allow it; notifications and sound are asked for beside it but never block the door. |
| Sign in | Email and password, with the authenticator-code and unverified-email steps handled in place. New motari register on the website. |
| Drive | The map, the online switch, the ride offer with its countdown, waiting passengers nearby, and the ride from pickup to payment. |
| Money | Wallet, collected, rides, paid out, the payout history and recent trips. The daily fee lives here around the clock. |
| Settings | Instant payout with its operator and number, carry parcels, an account-number change request, a complaint, and log out. |

### The parts worth knowing

- **One poll drives everything.** `/driver/state` returns presence, the held
  offer, nearby requests, the active ride and the fee together, every five
  seconds — the same contract the web app uses, so neither can drift.
- **The heartbeat is the meter.** While online the app posts its GPS every four
  seconds: it is what makes the motari visible to dispatch, and what measures a
  metered ride. Fixes worse than 5 km are network guesses and are dropped.
- **An offer rings until it is answered**, looping for its whole window — the
  delivery tone for a parcel, the ride tone for a passenger — and stops the
  moment it is accepted, passed or expires.
- **The daily fee is never hidden.** From 16:00 to 08:00 it sits on the map; in
  working hours it is on the Money screen. A paused account shows at any hour.
- **The ride runs itself.** Arriving is the last tap of an ordinary ride: it
  starts when both phones pull away together, the fare is asked for near the
  end, and it completes at the destination. Only a destination the map never
  had still needs a Complete.

## Permissions

The app asks for exactly three things, and says why on the screen that asks.

| | Required | Why |
| --- | --- | --- |
| Location | Yes | Dispatch matches a passenger to the nearest moto. Without it the app has nothing to place, so it will not start. |
| Notifications | No | An offer reaches a motari whose phone is in their pocket, on the lock screen, at call importance. |
| Sound | No | Nothing to allow: the offer rings through the media channel, so the phone only has to be off silent. |

The gate re-checks itself whenever the app comes back from the system settings,
so a motari who leaves to switch something on finds it already caught up. A
motari who turns location off mid-shift is asked again when the app resumes.

Android also declares background location, foreground-service and full-screen
intent so a ring can wake the screen; iOS carries the matching usage strings and
the `location` and `audio` background modes.

## Languages

The same four the website speaks — Kinyarwanda, English, French, Kiswahili —
and Kinyarwanda is what a phone that has never touched the switch reads, as on
the web. The globe sits on the permission and sign-in screens and again in
Settings; the choice is kept on the device and the whole app turns over the
moment it changes.

Every string lives in `lib/i18n.dart`, one map rather than four files, so a new
string cannot quietly ship in English alone. `flutter test` checks that every
key the code asks for is answered in all four.

## Building

```bash
flutter build apk --release      # needs the Android SDK
flutter build ipa                # needs Xcode on macOS
```

Assets in `assets/audio/` are the same notification sounds the web apps use, so
a motari hears the same thing on either.
