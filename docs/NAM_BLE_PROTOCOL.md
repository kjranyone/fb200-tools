# NAM mobile control extension, v1

Experimental extension of the existing FB200 app framing, implemented only by
`PROFILE=nam-runtime`. No firmware update action or embedded capture is added.
Read-only capabilities and slot listing were verified over physical Android BLE
on 2026-10-18. Model transfer remains unverified.

## Link and framing

The existing BT201 UART path and `proto_feed(PROTO_BLE, ...)` handle the extension.
USB HID can carry it too. USB CDC keeps its existing `namput` binary upload.
Both paths share one 8192-byte staging buffer and exclude each other during upload.

The app discovers GATT and selects the measured FB200 BT201 UART route:
service `0000fff0-0000-1000-8000-00805f9b34fb`, TX `0000fff1-0000-1000-8000-00805f9b34fb`,
RX `0000fff2-0000-1000-8000-00805f9b34fb`. TX is phone-to-pedal; RX notifications
are pedal-to-phone. FFF1 also advertises notifications but did not return NAM
replies in the physical test. FFF3 is the module's own control endpoint and is
excluded from all pedal writes. Unknown/missing/ambiguous routes fail with a
user-facing unsupported-device message; there is no UUID picker.
Capabilities and list reads must succeed before any mutation; stock firmware
cannot satisfy the NAM handshake. See [physical evidence](NAM_HARDWARE_2026-10-18.md).

Frame: `AA 55 | length:u16LE | command:u8 | payload | CRC16:u16BE`.
Length includes command, excludes framing/CRC, maximum 1018. CRC covers length,
command and payload; polynomial 0x1021, initial 0, final XOR 0xFFFF.
Capabilities request with ID 0x1234: `AA550500E00100341230C2`.

GATT writes use fragments of at most 20 bytes, with response when available,
otherwise a 15 ms interval. Incoming fragments are reassembled with CRC/resync.
UART/GATT boundaries do not need to match FB200 frame boundaries.

## RPC

Request command `0xE0`: `[version=1:u8, operation:u8, id:u16LE, args...]`.
Reply command `0xE1`: `[version=1:u8, operation:u8, id:u16LE, status:u8, data...]`.
Multi-byte fields below are little endian. Maximum request payload is 80 bytes.

| Op | Request args | Successful reply data |
| --- | --- | --- |
| 0 capabilities | empty | rate:u32=48000, weights:u16=1871, slots:u8=64, chunk:u8=64, packet:u16=7548, flags:u16=7, selected:u8 |
| 1 list page (`flags` bit 5) | start:u8 (0-based, < slots) | `[selected:u8][start:u8][count:u8]` then count `{slot:u8, used:u8, name:24 bytes NUL-padded ASCII, payloadCRC:u32}` records from slot start+1, contiguous and in order; count = min((cap-8)/30, slots-start) |
| 2 begin | slot:u8 (1..64), total:u16=7548, wholePacketCRC:u32 | token:u32, received:u16=0 |
| 3 chunk | token:u32, offset:u16, bytes:1..64 | token:u32, received:u16 |
| 4 commit | token:u32 | empty |
| 5 abort | token:u32 | empty |
| 6 select | slot:u8 (0=bypass, 1..64), save:u8 (0/1) | empty |
| 7 delete | slot:u8 (1..64) | empty |
| 8 tuner snapshot (`nam-manager`) | empty | enabled:u8, valid:u8, note:u8 (1..12 A#..A), octave:i8, frequency:f32, cents:f32, confidence:f32 |
| 9 rename (`flags` bit 4) | slot:u8 (1..64), name:24 bytes NUL-padded, 1..23 printable (33..126) | empty |
| 10 level peaks (`flags` bit 10) | empty | input:f32, namInput:f32, output:f32 |
| 11 model kinds (`flags` bit 12) | empty | 64 bytes: header byte 52 of slots 1..64, 0 for an empty slot |
| 12 set kind (`flags` bit 12) | slot:u8 (1..64), kind:u8 | empty |

The store holds 64 slots in F:0x400000..0x4FFFFF (the former long IR store
area; the long IR store is not compiled into NAM profiles). The unpaged op-1
form of the earlier three-slot firmware is gone: a request without the start
byte answers status 1, and older apps report a capability/list mismatch on
this firmware. A full list needs two pages at the target reply cap (33
records per page).

Op 9 rewrites the stored slot header under the new name by re-committing the
unchanged packet to the alternate bank (sequence + 1), so the previous bank
stays valid until the final header write. Weights, payload CRC and the running
RAM model are untouched; the old name stays if the write fails. Status 1 for an
empty/tombstoned slot or an invalid name, 2 while a transfer holds staging,
4 on flash failure. A cached failure replays for the same request id; issue a
new id (and refresh) to retry.

Header byte 52 says what the capture is: 0 unknown, 1 amp + cab (full rig),
2 amp, 3 cab, 4 pedal, 5 outboard, 6 space, 7 experimental. The firmware stores
any value; clients show other codes as unknown. An upload carries it in the
packet header; op 12 re-commits the stored packet with a new kind exactly like
op 9 (same statuses, the name and weights stay), and op 9 keeps the kind.
Firmware without bit 12 rejects a packet whose byte 52 is not 0, so clients
send 0 there.

Flags: bit 0 framed upload, bit 1 select/preset save, bit 2 delete,
bit 3 drum machine + live tuner (`PROFILE=nam-manager`), bit 4 rename (op 9,
both profiles), bit 5 paged list (op 1 takes a start byte; 64 slots), bit 6
looper (`PROFILE=nam-manager`; `D7` control), bit 7 stock cab/MOD/reverb in
the chain after the NAM stage (`nam-manager`; 44.1 kHz IRs resampled to
48 kHz), bit 8 Bluetooth audio mixed into the output (`nam-manager`; SAI3
runs in every profile — the module slaves to our I2S clock, so 48 kHz needs
no resampling), bit 9 NAM tone EQ connected to the audio path (both NAM
profiles), bit 10 level peaks (op 10, both NAM profiles), bit 11 NAM GAIN
spans -18..+18 dB at 0.36 dB per step (both NAM profiles; before, 0.5..2x),
bit 12 model kind byte (ops 11/12, both NAM profiles).
Without bit 9, only the amp words GAIN/VOLUME affect NAM audio;
clients must not offer the other four tone controls as active. Op 8 is read-only;
the existing B8/BA commands still control tuner/rhythm. Its floats are little
endian IEEE-754; invalid/silent readings must not be displayed as a pitch.
Op 10 is read-only too. Each little-endian float is that tap's largest |sample|
(full scale 1.0) since the previous op 10 read, which restarts it from 0: the
instrument input L + R before the input gain, the NAM model's input after
input gain, gate, compressor and GAIN (0 while no model runs), and the output
before the ±0.95 clip. It does not touch the idle timer's input peak.
The base restricted `nam-runtime` reports flags 7|16|32|512|1024|2048|4096 = 7735
(plus bits 3, 6, 7 and 8 for `nam-manager`: 8191) and 64 slots; the earlier three-slot
firmware reported 7 (15 with utilities) without bits 4/5.
Status:
0 success, 1 invalid args/incomplete packet, 2 staging busy, 3 CRC/model validation
failure, 4 storage/selection failure or insufficient capacity, 5 unsupported
version/operation, 6 unknown/expired token or wrong source.

Stop-and-wait: check operation/ID/token/offset; retransmit the **identical request
and ID** after 1 second, at most twice. Firmware caches its last reply by source,
ID and request CRC, so immediate retry of commit/preset-save is idempotent.
Another source can evict this cache; concurrent editors are unsupported. Tokens
are source-bound and do not survive reboot. New IDs containing earlier chunk
bytes are accepted only if those bytes exactly match staging. Gaps, overlaps
past received data, zero/oversized chunks and wrong-source requests are refused.

## Storage and compatibility

Begin/chunk never write flash. Three seconds of inactivity expires staging;
abort, expiry or incomplete commit cannot install a partial model. Commit checks
whole packet CRC, FBNM header, payload CRC, fixed shape/rate and finite float32
weights before using the existing two-bank, header-last store. Delete writes a
persistent tombstone. Flash layout is unchanged; see [NAM_A2_LITE.md](NAM_A2_LITE.md).

Upload leaves the running RAM model intact. **Explicitly select/reload after
upload to hear the replacement.** The app supports reload of the selected slot.
Selection copies weights to RAM, warms with audio/watchdog service, then fades in.
Save binds the slot to the current preset; saving an unchanged selection avoids
an unnecessary reload. Refresh after front-panel preset changes; unsolicited
preset notifications are not synchronized by this initial app.

In the runtime profile, a legacy full preset write (`0x97`) without our marker
preserves bytes 0xDE..0xE1 from the destination preset (or edit buffer for index
0xFF). An explicit NAM marker can change or clear the binding. Existing module
messages retain their original ranges. This is tested protocol preservation,
**not verified physical official-app compatibility**. The official app cannot
upload NAM, and runtime-disabled effects remain disabled despite their controls.

Host tests exercise actual C RPC/NOR, retry, duplicate/out-of-order chunks,
source/token checks, expiry, USB/BLE exclusion, select/save/delete, CRC/NaN and
flash-failure preservation. Full-preset regression uses actual C protocol/UI.
Python/Dart share synthetic model/packet fixtures and stock-frame CRC vectors.
Flutter tests cover cancellation, ACK errors, disconnect and narrow-screen demo.
ARM and flash-busy RAM-call-graph checks remain required.

Validation on 2026-10-17: full Python/C/ARM suite **492 passed, 15 skipped**
(optional official Core oracle enabled), Flutter **27 passed**, Flutter analyze
and Ruff clean. Android debug APK and web build succeeded; iOS was not compiled.
The live firmware retains the 83,976-byte NAM state and 8192-byte upload staging;
total OCRAM allocation is 21,596 of 32,768 bytes. Actual compiled flash-busy
call-graph checks passed. The Makefile's multi-output objcopy rule was split into
separate targets after reproducing concurrent writers under parallel build.

Still required: notification timing under load, flash erase latency,
radio interruptions, Android/iOS/pedal interoperability, physical power cuts,
Cortex-M7 deadline and audio tests. The original development session did not
connect hardware; subsequent installation and read-only BLE checks are recorded
in [NAM_HARDWARE_2026-10-18.md](NAM_HARDWARE_2026-10-18.md).
