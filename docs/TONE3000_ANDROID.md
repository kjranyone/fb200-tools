# TONE3000 → Android → FB200

The Android app imports a model using the official TONE3000 Select OAuth flow,
validates the supported 48 kHz fixed A2-Lite shape, and passes the resulting
FBNM packet to the existing Bluetooth slot uploader. Importing never writes to
the pedal. Users explicitly choose a slot, confirm replacement when occupied,
then select/reload the stored model and optionally save its preset binding.

## Initial setup

Use Flutter 3.47.7 / Dart 3.13.5 and the committed lockfile. The existing Android
compile SDK 37 / AGP 9.1.1 / Java 17 configuration is retained.

1. In TONE3000 Settings → API Keys, create/use a **Publishable Key** (`client_id`).
   Do not enter a Secret Key. The app explicitly refuses `t3k_cs_...` values.
2. If redirect URIs are registered for the integration, register exactly
   `fb200nam://oauth/callback`.
3. Open **TONE3000から探す** in the Android app. On first use, enter the public
   identifier. It can also be supplied at build time:

   ```sh
   flutter build apk --debug --dart-define=TONE3000_CLIENT_ID=YOUR_PUBLISHABLE_KEY
   ```

4. Tap **TONE3000で探す** (or the keyboard's Go action after entering the key).
   The publishable key identifies the app; it does **not** sign the user in.
   On the official login page, enter the TONE3000 account's email address,
   tap **Send Code**, and complete the emailed-code login before selecting
   a tone. An empty email field leaves Send Code disabled.
   Android Custom Tabs opens the official sign-in/catalog page with `prompt=select_tone`, `format=nam`, and `architecture=2`. Search,
   favorites, and tone selection remain in the official experience. No custom
   high-rate search API polling is used.
5. Select a variant in the returned tone pack. The app downloads and validates
   the file. Unsupported architectures/rates are rejected before any pedal RPC.
6. Connect the FB200 by Bluetooth and tap **ここへ転送** on an available slot (64 on current firmware). Upload is
   separate from **選択** / **再読み込み** and preset save. Replacing the selected
   slot does not switch the running RAM model until explicit reload.

Browsing and import are available before connecting a pedal. The explicit demo
uses the same validated import and a simulated transfer; it is not radio evidence.
This firmware profile has no cabinet/IR stage; use an Amp + Cab capture or an
external cabinet stage where appropriate.

## Implementation and boundaries

- `mobile/lib/tone3000.dart`: PKCE/state, metadata, A2-only pagination, in-memory
  tokens and refresh, authenticated model download and existing NAM parser.
- `mobile/lib/tone3000_page.dart`: initial configuration, official catalog entry,
  signed-in identity, tone/creator attribution, variant picker and error states.
- `MainActivity.kt` and `ToneCallbackActivity.kt`: Android Custom Tabs and exact
  custom-scheme callback, including browser-back cancellation. Dart verifies
  state and single-use callback before exchanging an authorization code.
- `mobile/lib/tone_library.dart`: secure session store, the device model
  library and the paced bulk downloader.
- `main.dart`: imports into the existing slot workflow, including batch transfer
  into empty slots. Source attribution is
  held in the current app/device session; the pedal protocol stores a model name
  and weights, not TONE3000 metadata. Reconnecting/restarting does not reconstruct
  cloud provenance for existing slots.

Only the public client ID is persisted in SharedPreferences. Since 0.11.0+22
the refresh token is kept in Android Keystore-backed secure storage (see
"Device library and stored session" below); access tokens stay in memory. API requests use HTTPS, downloads
have an 8 MiB limit and timeouts, and cross-origin signed-download redirects do
not receive Bearer credentials. Model files/weights are not bundled in the APK.
The original official logo is retained with its source attribution.

TONE3000 OAuth is implemented for Android. iOS and the web demo retain local
file import; no iOS OAuth or web Bluetooth implementation is claimed.

Read the current [official API](https://www.tone3000.com/api) for registration,
design requirements and shipping terms. This is a development integration;
the app does not claim a commercial partnership or TONE3000 approval.

## Validation

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

Tests cover PKCE/state/callback rejection and cancellation, token refresh,
A2-only model lists, variant selection, incompatible/oversized downloads,
credential stripping on CDN redirects, and import → existing demo-slot upload
without automatic activation. A real TONE3000 account/client ID and physical
Bluetooth transfer still require end-to-end validation; host fakes do not
establish these. The FB200 firmware/USB installation was validated separately
in [NAM_HARDWARE_2026-10-18.md](NAM_HARDWARE_2026-10-18.md).

On 2026-10-18, Flutter analyze passed, all **46 Flutter tests passed**, and
Android debug APK 0.2.0+2 and the web demo built successfully. The APK was
installed on the attached Lenovo TB-J716F (Android 13 / API 33). Launch,
the import/configuration screens, callback intent resolution, nearby-device
permission and Bluetooth discovery were checked. No public client ID was
supplied, so real OAuth login/download was not verified. A subsequent 0.2.1+3
update automatically selects the measured FB200 UART route and physically
verified capabilities and empty-slot listing over Android BLE. Model transfer
remains unverified. No model or preset was changed during this work.

Android 0.3.0+5 adds **QRコードから入力** to setup. Present a QR containing the
raw Publishable Key string; URLs, JSON, whitespace/control characters and Secret
Keys are refused. Cancel/back retains the current key. The camera is released
when leaving the scanner; denial has a settings/manual-input path. No image or
QR payload is logged or uploaded. The first QR version (0.2.2+4) was installed
and camera startup/return checked on the tablet. A real public-key QR and real
OAuth login still need end-to-end validation.

Latest APK: main checkout `out/fb200-manager-0.3.1-debug.apk` (debug-signed).
0.3.1+6 aligns bank labels with the pedal's BANK 0–9 (presets 0A–9D).
The tablet has 0.3.0+5 installed; installing the bank-label correction awaits
USB reconnection or manual APK installation.
65 Flutter tests passed, including QR validation/fill/cancel, legacy framing,
backup/restore and narrow editor/firmware capability gating. Analyze passed.
Logs and inspected Android screenshots: `out/tone3000-evidence/`.

## Login guidance fix (0.10.1+15, 2026-10-21)

A report that entering the publishable key did nothing was inspected on the
connected tablet. The installed app was 0.9.0+13. Its key had been accepted:
the official Custom Tab was showing the TONE3000 account email login, with
an empty email field and disabled Send Code button. No account credentials,
verification emails or tokens were entered or submitted during diagnosis.

The picker now distinguishes key configuration from user login, starts browsing
from the keyboard Go action, keeps the browse button and feedback visible at
the bottom, and explains cancellation instead of returning silently. The
existing PKCE/state verification and key/token handling remain unchanged.
Real account login and download still require the user's email-code step;
unit-test authentication is simulated.

Validation: Flutter analyze passed, all 146 Flutter tests passed, and the debug
APK build passed. The 0.10.1+15 APK was transferred to the tablet at
`/sdcard/Download/fb200-studio-0.10.1-15-debug.apk`; it was not installed.
PC and tablet SHA-256 matched:
`bd79ce9602776a2d14aa98db2ed1c1e96aff3f9784067f35e046ebbae007593c`.
Logs and the inspected login screenshot are in `out/tone3000-fix-20261021/`.

## Device library and stored session (0.11.0+22, 2026-10-22)

Finding models one Select round-trip at a time was slow, so the TONE3000 page
became a library with two tabs.

**TONE3000 tab.** The first sign-in still uses the official Select flow
(emailed code). Its refresh token is then stored with `flutter_secure_storage`
(Android Keystore), bound to the publishable key, and restored on the next
visit. A rejected refresh (HTTP 400/401) or **ログアウト** deletes it; network
failures keep it. Concurrent requests share one refresh so a rotated token is
never replayed. While signed in, the app lists the free-tier endpoints
`tones/favorited`, `tones/downloaded`, `tones/created` (server-side `query` and
`gear`, 25 per page) and `tones/trending`, `tones/latest` (local filter). Only
NAM tones with A2 variants are shown. **全カタログから選ぶ** keeps the official
Select flow as the persistent path to the full catalog.

`tones/search` is outside the non-commercial tier and heavily rate-limited, so it
is compiled out unless `--dart-define=TONE3000_SEARCH=true` is given for a build
covered by a TONE3000 agreement. The partner-only zip download is not used.

**Bulk download.** A tone's download button, the sheet's selection, or the
app-bar action for every tone shown queues per-model downloads (`model_url`,
up to 300 variants listed per request). Two transfers run in parallel and every
API request is paced 650 ms apart (≤ ~92/min, under the documented 100/min);
a `Retry-After` of up to 30 s is honoured once. Each file is parsed with the
same A2-Lite validator before anything is written; incompatible variants are
counted, not stored. Already-saved models are skipped.

**Device tab.** The original `.nam` files are stored gzip-compressed under the
app's private `files/tone3000/` with an atomically replaced `index.json` holding
the tone title, gear, creator and image for attribution. The tab searches
locally and instantly by model, tone, gear or `@creator`, and allows multiple
selection, deletion, and — when a NAM pedal is connected — returning the
selection for transfer. Models can be saved before connecting from the launch
screen (**モデルを探して保存**).

**Transfer.** One returned model keeps the existing explicit slot choice. Several
are previewed as `slot ← model` and, after confirmation, written in order only
to empty slots; occupied slots are never overwritten and the remainder is
reported. Cancelling stops after the current model. Nothing is selected or
saved to a preset automatically.

Auto Backup and device transfer exclude the `flutter_secure_storage`
preferences (`FlutterSecureStorage.xml`, `FlutterSecureKeyStorage.xml` and its
configuration file; the wrapped key cannot be restored on another device) and `files/tone3000/` (re-downloadable,
and large libraries would exceed the 25 MB backup quota).

Validation: `dart format` clean, `flutter analyze` clean, **229 Flutter tests
passed** (session persistence/restore/rejection/sign-out, shared refresh,
free-tier list filtering, search gating, pacing, Retry-After, bulk download with
incompatible/duplicate/cancel cases, memory and file storage round-trips,
library UI, device-tab search/selection, and demo batch transfer into the only
empty slot). Debug APK 0.11.0+22 and the web demo built.

Tablet check (Lenovo TB-J716F, Android 16, real account): the Select flow
returned to a *new* `MainActivity` in a separate task, so the waiting page never
received the tone. Chrome starts `ToneCallbackActivity` in its own task and both
activities have an empty task affinity; the callback now adds
`FLAG_ACTIVITY_NEW_TASK`, which reuses the task rooted at `MainActivity`, and
`CLEAR_TOP` closes the Custom Tab. The callback activity is also excluded from
recents. After the fix: sign-in and selection returned to the open page, the
session survived a force-stop, Trending bulk download stored 30 compatible
models in about 25 s with none rejected, and the download-history shelf and the
device tab listed them. Physical batch transfer to a pedal has not been
verified.
