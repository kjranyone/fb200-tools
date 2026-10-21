# Android connection recovery — 0.10.4+18

The previous disconnect handler cleared the hub's client references, while an
open controller or borrowed library retained a closed transport. There was no
shared recovery state, no path to replace that transport in place, and no
read-only resynchronization of the open routes.

## Connection lifecycle

`ConnectionRecovery` owns one stable `WireTransport`. On loss, every open route
stops device operations and displays the same reconnect state. The app attempts
the same device up to three times (500 ms, 2 s, 4 s delays). It releases the old
GATT connection, discovers/subscribes on the replacement link, then invokes
route resynchronizers **serially**. Device identity, presets, settings, live
edit buffer, NAM capabilities and model slots are read again before operations
are enabled. Failed automatic attempts offer a manual retry. Cancel and close
invalidate pending attempts and cancel an in-progress native connection.

On Android foreground resume the app checks the link. While active and idle,
a read-only version probe runs every 8 seconds. A legacy reply timeout or an
exhausted established NAM request also enters recovery. Optional NAM capability
probing remains compatible with stock firmware that does not answer NAM RPC.

Wire clients and frame subscribers retain their identity across recovery;
partial frames and old request state are discarded. Old completions cannot
clear a newer pending request. Commands, saves and uploads are never replayed
on the replacement connection. Uploads check their original link generation
before each chunk/commit and do not send an old abort token to a new link.

## Edits and interrupted operations

On loss, the controller retains a copy of unsaved edits, including a tone or
model change whose transmission was interrupted. The draft records the preset
that the edit buffer actually belongs to, not a later preset-selection notice.
It stays in the shared session while navigating between the controller and
library. This is session memory, not a persistent on-disk backup.

If the freshly read device buffer already matches, no restoration is required.
Otherwise the controller offers **下書きを本体へ戻す** and **本体の状態を使う**.
Restoration explicitly confirms the preset and audible change, writes only the
live edit buffer, and verifies the readback. Flash persistence still requires
the ordinary Save action. A restore failure retains the draft.

An interrupted model transfer retains the imported source in the library.
Reconnect reads the actual slot list; transfer/commit/save must be requested
again if needed. An interrupted save may already have completed, so the app
reads its outcome instead of issuing a duplicate write automatically.

## Validation

Flutter analyze passed and 177 Flutter tests passed. Added coverage includes:

- stable subscribers, decoder reset, serialized resync, retry limits/manual retry;
- cancellation/late connections, foreground resume, intentional close;
- silent-link heartbeat and optional NAM probing on stock firmware;
- old request completions and blocked GATT upload completion after link replacement;
- open-library recovery, confirmed/interrupted edits, verified explicit restore,
  and automatic recognition of edits retained by firmware without any write.

Logs: `out/recovery-*.log`.


## Physical Android verification — 2026-10-21

Installed 0.10.4+18 on Lenovo TB-J716F / Android 13 and copied the same APK to
`/sdcard/Download/fb200-studio-0.10.4-18-debug.apk` (SHA-256 verified).
The existing FB200 firmware was retained.

With the controller open on **0D Dark**, Bluetooth was disabled on Android,
then enabled again. The shared reconnect overlay appeared, and the app
reconnected and resynchronized automatically without returning to the hub or
manually selecting the pedal. All six NAM control labels/values matched the
pre-disconnect snapshot. No preset selection, save or model transfer was
performed by the verification script.

USB console checks before/after confirmed unchanged CRCs:

| Region | CRC-32 |
| --- | --- |
| User data (`0x60071000`, 198656 bytes) | `c359d9c4` |
| NAM models (`0x60400000`, 1048576 bytes) | `4a2d037c` |

The selected preset also matched, firmware reported `no crash dump`, and the
current Android process had no fatal exception. Interrupted uploads and draft
restoration were validated by automated tests; they were not exercised as
physical flash-write tests in this verification.

[Reconnect overlay](design/fb200-recovery-disconnected-v1.png) ·
[Recovered controller](design/fb200-recovery-recovered-v1.png)

Machine-readable results and original screenshots:
`out/recovery-20261021/verification.json`, `device-before.json`,
`device-after.json`, `before-values.json`, `connected-before.png`,
`disconnected.png`, `recovered.png`.
