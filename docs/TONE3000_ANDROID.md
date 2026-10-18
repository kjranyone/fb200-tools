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

4. Tap **TONE3000で探す**. Android Custom Tabs opens the official sign-in/catalog
   page with `prompt=select_tone`, `format=nam`, and `architecture=2`. Search,
   favorites, and tone selection remain in the official experience. No custom
   high-rate search API polling is used.
5. Select a variant in the returned tone pack. The app downloads and validates
   the file. Unsupported architectures/rates are rejected before any pedal RPC.
6. Connect the FB200 by Bluetooth and tap **ここへ転送** on slot 1–3. Upload is
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
- `main.dart`: imports into the existing slot workflow. Source attribution is
  held in the current app/device session; the pedal protocol stores a model name
  and weights, not TONE3000 metadata. Reconnecting/restarting does not reconstruct
  cloud provenance for existing slots.

Only the public client ID is persisted in SharedPreferences. Tokens are scoped
to the picker in memory and cleared on exit. API requests use HTTPS, downloads
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
