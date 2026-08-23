# Motari

The moto taxi app for MpahMapu, in Flutter.

It carries **the Motari vertical from both ends**. A passenger opens it and asks
for a moto with no account at all; a motari signs in to take the work, get paid
and settle the daily fee. Everything else the platform does (jobs, workers,
employers, admin) stays on the website.

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
| Splash | The moto rides in along a scrolling road while the session is read off the device, signed off with MpahMapu underneath. The scene is drawn rather than an image; only the MpahMapu logo is an asset. |
| Ask | The passenger side, and where the app opens. Map, pickup, an optional destination, a name and a phone number, then the motari on their way. No account, and the ride is remembered on the device so closing the app comes back to it. |
| Register | A motari account from inside the app: details, the emailed code, and straight into work. |
| Permissions | The first screen on every launch. Location is required and the way through is to allow it; notifications and sound are asked for beside it but never block the door. |
| Sign in | Email and password, with the authenticator-code and unverified-email steps handled in place, and a way to register without leaving. |
| Drive | The map, the online switch, the ride offer with its countdown, waiting passengers nearby, and the ride from pickup to payment. |
| Money | Wallet, collected, rides, paid out, the payout history and recent trips. The daily fee lives here around the clock. |
| Settings | Instant payout with its operator and number, carry parcels, an account-number change request, a complaint, and log out. |

### The two sides

The app opens on the passenger side, because most people who open it want a
ride. "I drive" leads to sign in, and a motari who signs in stays signed in, so
after the first time the app opens straight onto the working map.

A passenger needs no account: a name and a phone number are the whole of it. The
ride is held by a token kept on the device, which is what lets them close the app
and come back to a ride already under way.

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
- **A destination off the map is still a destination.** Type-ahead asks
  Nominatim directly — an app can send a User-Agent, which is the reason the web
  needs a proxy and this does not. When nothing matches, the typed text becomes
  the destination and the passenger names their own price, because there is no
  route to measure.
- **Every request carries a price.** The amount is never optional: where there
  is a route to measure, the box opens with that price already in it and the
  passenger may change it; where there is not, they name it outright. Below the
  floor for that kind of trip, the button does not go.
- **A pickup can be typed.** The device fix fills it in when there is one, but a
  phone that never gets a fix still has a field to type into and a map to tap,
  so nobody is stranded by a cold GPS.
- **The icon is the app's own mark**, drawn from the same Material font Flutter
  ships: the orange rounded square and the black moto that the permission and
  sign-in screens show. `tool/make-icon.ps1` redraws every Android density, the
  adaptive layers and the whole iOS set if the brand colour ever moves.

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
