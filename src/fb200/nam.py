"""Runtime A2-Lite transfer: PC validates JSON, pedal persists checked weights."""
import json
import struct
import zlib
from pathlib import Path

from fb200.errors import CommunicationError, InvalidArgumentError
from fb200.nam_model import validate

HEADER = 64
WEIGHTS = 1871
PACKET = HEADER + WEIGHTS * 4
SLOTS = 64   # namstore.h: F:0x400000..0x4FFFFF, two 8 KiB banks per slot
MAGIC = 0x4D4E4246


def slot_number(value):
    if not 1 <= value <= SLOTS:
        raise InvalidArgumentError(f"NAM slot must be 1..{SLOTS}")
    return value


def pack(document, name="NAM", kind=0):
    try:
        weights = validate(document)
    except (ValueError, KeyError, TypeError, IndexError, AttributeError, OverflowError) as exc:
        raise InvalidArgumentError(f"unsupported A2-Lite model: {exc}") from exc
    name = "".join(c if "!" <= c <= "~" else "_" for c in name)[:23] or "NAM"
    payload = struct.pack(f"<{WEIGHTS}f", *weights)
    header = bytearray(HEADER)
    struct.pack_into("<IHHIIII24s", header, 0, MAGIC, 1, 2, 48000, WEIGHTS,
                     zlib.crc32(payload), 0, name.encode("ascii"))
    header[52] = kind   # model kind (firmware namstore.h); old firmware needs 0
    struct.pack_into("<I", header, 60, zlib.crc32(header[:60]))
    return bytes(header) + payload


def load(path, name=None):
    path = Path(path)
    try:
        return pack(json.loads(path.read_text(encoding="utf-8")), name or path.stem)
    except (OSError, ValueError) as exc:
        raise InvalidArgumentError(f"cannot read model: {exc}") from exc


def put(con, slot, packet):
    slot_number(slot)
    if len(packet) != PACKET:
        raise InvalidArgumentError(f"NAM packet must have {PACKET} bytes")
    ready = con.command(f"namput {slot} {len(packet)} {zlib.crc32(packet):#x}",
                        [b"nam ready", b"nam: ", b"unknown command"], timeout=5.0)
    if b"nam ready" not in ready:
        raise CommunicationError(f"NAM upload refused: {ready.decode(errors='replace')}")
    for offset in range(0, len(packet), 1024):
        con.write(packet[offset:offset+1024])
    done = con.expect([b"nam done", b"nam aborted"], timeout=30.0)
    if f"nam done ok slot {slot}".encode() not in done:
        raise CommunicationError(f"NAM upload failed: {done.decode(errors='replace')}")


def select(con, slot, save=False):
    if slot != 0:
        slot_number(slot)
    text = con.command(f"namuse {slot}" + (" save" if save else ""),
                       [b"nam use ok", b"nam use FAILED", b"unknown command"],
                       timeout=30.0).decode(errors="replace")
    if f"nam use ok slot {slot}" not in text:
        raise CommunicationError(f"NAM selection failed: {text.strip()}")


def delete(con, slot):
    slot_number(slot)
    text = con.command(f"namdel {slot}", [b"nam delete ok", b"nam delete FAILED", b"unknown command"],
                       timeout=30.0).decode(errors="replace")
    if f"nam delete ok slot {slot}" not in text:
        raise CommunicationError(f"NAM deletion failed: {text.strip()}")


def ls(con):
    text = con.run("namls", max_s=10.0)
    if "nam slots: " not in text:
        raise CommunicationError(f"NAM slots unavailable: {text.strip()}")
    return text
