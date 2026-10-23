"""AMP knob on the real firmware UI, with simulated controls and model loader."""
import struct

import pytest

from test_proto_host import Harness, PRESET_FLASH, build, frames


@pytest.fixture
def panel():
    h = Harness(build(nam_runtime=True))
    yield h
    h.close()


def scan(h):
    for _ in range(64):
        h.cmd("tick 10")


def binding(h):
    return struct.unpack_from("<HH", h.edit(), 0xDE)


def status(h):
    return tuple(map(int, h.cmd("namstatus")[0].split()[1:]))


def sparse(h):
    h.cmd("namused 2 1")
    h.cmd("namused 64 1")
    scan(h)


def test_sparse_slots_settle_notify_and_save(panel):
    h = panel
    sparse(h)
    stock_amp = h.edit()[0x2E:0x30]
    before = h.flash(PRESET_FLASH, 256)
    h.cmd("knob 2 2000")  # bypass -> slot 2, no immediate load
    assert status(h) == (0, 0)
    assert h.cmd("disp") == ["DISP n02."]
    h.cmd("tick 200")
    h.cmd("knob 2 4095")  # pass over 2 to 64: debounce restarts
    h.cmd("tick 249")
    assert status(h) == (0, 0)
    out = frames(h.cmd("tick 1"))
    assert status(h) == (64, 1)
    assert binding(h) == (0x414E, 64)
    assert h.edit()[0x2E:0x30] == stock_amp
    assert h.flash(PRESET_FLASH, 256) == before  # audition never writes presets
    assert ("b", 0x98, bytes([0])) in out  # Android refreshes its NAM selection
    assert h.cmd("disp") == ["DISP n64"]
    h.cmd("fsw a press")
    h.cmd("fsw a long")
    h.cmd("fsw a release")
    assert h.flash(PRESET_FLASH + 0xDE, 4) == struct.pack("<HH", 0x414E, 64)
    h.cmd("select 1")
    h.cmd("select 0")
    assert binding(h) == (0x414E, 64)  # normal preset recall retains the binding


def test_remote_model_pickup_crossing_and_bypass(panel):
    h = panel
    sparse(h)
    h.cmd("namselect 2")  # physical knob is still in the bypass bin
    h.cmd("knob 2 100")
    h.cmd("tick 300")
    assert status(h) == (2, 1)  # moving away from the stored bin cannot jump
    h.cmd("knob 2 4095")  # crosses the stored bin in one sample
    h.cmd("tick 250")
    assert status(h) == (64, 2)
    h.cmd("knob 2 0")
    h.cmd("tick 250")
    assert status(h) == (0, 3)
    assert binding(h) == (0x414E, 0)
    assert h.cmd("disp") == ["DISP n00"]


def test_app_save_does_not_rearm_caught_nam_selector(panel):
    h = panel
    sparse(h)
    h.cmd("knob 2 4095")
    h.cmd("tick 250")
    assert status(h) == (64, 1)
    edit = h.edit()
    revision = h.cmd("rev")
    h.send(0x97, bytes([0]) + edit)
    assert h.cmd("rev") == revision  # No recall/reload of the current model.
    assert h.flash(PRESET_FLASH, 256) == edit
    # Sample both LED phases: the caught AMP selector stays steadily lit.
    for _ in range(2):
        h.cmd("tick 250")
        assert h.cmd("leds")[0][5 + 3] == "1"
    assert status(h) == (64, 1)


def test_preset_and_remote_edits_cancel_pending_selection(panel):
    h = panel
    sparse(h)
    h.cmd("knob 2 4095")
    h.cmd("select 1")
    h.cmd("tick 300")
    assert status(h) == (0, 0)
    assert binding(h) == (0, 0)
    h.cmd("knob 2 0")  # pick up bypass
    h.cmd("knob 2 4095")
    h.cmd("namselect 2")
    h.cmd("tick 300")
    assert status(h) == (2, 1)
    assert binding(h) == (0x414E, 2)


def test_deleted_slot_cancels_pending_and_rebuilds_catalog(panel):
    h = panel
    sparse(h)
    h.cmd("knob 2 4095")
    h.cmd("namused 64 0")
    scan(h)
    h.cmd("tick 300")
    assert status(h) == (0, 0)
    h.cmd("knob 2 0")
    h.cmd("knob 2 4095")
    h.cmd("tick 250")
    assert status(h) == (2, 1)  # empty 64 is no longer selectable


def test_failed_load_preserves_binding_and_shows_error(panel):
    h = panel
    sparse(h)
    h.cmd("namselect 2")
    h.cmd("namfail 64")
    h.cmd("knob 2 4095")
    h.cmd("tick 250")
    assert status(h) == (2, 2)
    assert binding(h) == (0x414E, 2)
    assert h.cmd("disp") == ["DISP Err"]


def test_upload_lock_cancels_pending_selection(panel):
    h = panel
    sparse(h)
    h.cmd("knob 2 4095")
    h.cmd("nambusy 1")
    h.cmd("tick 300")
    h.cmd("nambusy 0")
    h.cmd("tick 300")
    assert status(h) == (0, 0)


def test_empty_store_and_scan_do_not_change_sound(panel):
    h = panel
    h.cmd("knob 2 4095")
    assert h.cmd("disp") == ["DISP bUS"]
    scan(h)
    h.cmd("knob 2 0")
    h.cmd("tick 300")
    assert status(h) == (0, 0)
    assert h.cmd("disp") == ["DISP n00"]


def test_full_catalog_reaches_last_slot(panel):
    h = panel
    for n in range(1, 65):
        h.cmd(f"namused {n} 1")
    scan(h)
    h.cmd("knob 2 4095")
    h.cmd("tick 250")
    assert status(h) == (64, 1)


def test_stock_profile_keeps_original_amp_selector():
    h = Harness(build())
    try:
        h.cmd("knob 2 0")  # pick up the factory amp 1
        h.cmd("knob 2 4095")
        assert struct.unpack_from("<H", h.edit(), 0x2E)[0] == 10
        assert binding(h) == (0, 0)
    finally:
        h.close()
