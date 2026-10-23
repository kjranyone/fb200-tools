"""Time-domain pitch shifter (firmware/audio/src/dsp/fx_pitch.c) on the host."""
import ctypes as ct
import shutil
import subprocess

import numpy as np
import pytest
from test_nam_a2 import FW

FS = 48000
STATE = 16384          # >= sizeof(fx_pitch_t)


@pytest.fixture(scope="module")
def lib(tmp_path_factory):
    if not shutil.which("cc"):
        pytest.skip("no C compiler")
    path = tmp_path_factory.mktemp("fxpitch") / "fxpitch.so"
    subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                    "-I", str(FW / "src"), str(FW / "src/dsp/fx_pitch.c"),
                    str(FW / "src/dsp/math.c"), "-o", str(path), "-lm"], check=True)
    so = ct.CDLL(str(path))
    so.fx_pitch_init.argtypes = [ct.c_void_p, ct.c_float]
    so.fx_pitch_set.argtypes = [ct.c_void_p, ct.c_float, ct.POINTER(ct.c_uint16)]
    so.fx_pitch_process.argtypes = [ct.c_void_p, ct.POINTER(ct.c_float), ct.c_uint]
    return so


def shifter(lib, shift_cents, mix=100, level=50, glide=0, bass=1):
    state = ct.create_string_buffer(STATE)
    lib.fx_pitch_init(state, FS)
    words = (ct.c_uint16 * 8)(2400 + shift_cents, mix, level, glide, bass, 0, 0, 0)
    lib.fx_pitch_set(state, FS, words)
    return state


def run(lib, state, x, block=32):
    y = np.asarray(x, dtype=np.float32).copy()
    for i in range(0, len(y), block):
        n = min(block, len(y) - i)
        lib.fx_pitch_process(state, ct.cast(y.ctypes.data + 4 * i, ct.POINTER(ct.c_float)), n)
    return y


def peak_hz(y):
    # zero-padded 8x: bins fine enough for a 27.5 Hz octave-down
    w = np.hanning(len(y))
    n = 8 * len(y)
    spec = np.abs(np.fft.rfft(y * w, n))
    return np.fft.rfftfreq(n, 1 / FS)[np.argmax(spec)]


@pytest.mark.parametrize("cents,ratio", [(1200, 2.0), (-1200, 0.5), (700, 2 ** (7 / 12))])
@pytest.mark.parametrize("f0", [55.0, 220.0])
def test_sine_moves_by_the_ratio(lib, cents, ratio, f0):
    t = np.arange(FS) / FS
    x = 0.5 * np.sin(2 * np.pi * f0 * t)
    y = run(lib, shifter(lib, cents), x)
    tail = y[FS // 4:]
    assert abs(peak_hz(tail) / (f0 * ratio) - 1) < 0.02
    assert np.isfinite(y).all() and np.max(np.abs(y)) < 1.0


def test_blocks_do_not_change_the_output(lib):
    rng = np.random.default_rng(5)
    t = np.arange(FS // 2) / FS
    x = 0.4 * np.sin(2 * np.pi * 110 * t) + 0.05 * rng.standard_normal(len(t))
    a = run(lib, shifter(lib, 1200), x, 32)
    b = run(lib, shifter(lib, 1200), x, 7)
    c = run(lib, shifter(lib, 1200), x, 1)
    np.testing.assert_array_equal(a, b)
    np.testing.assert_array_equal(a, c)


def test_silence_stays_silent_and_dry_passes(lib):
    y = run(lib, shifter(lib, -1200), np.zeros(FS // 4))
    assert not y.any()
    x = np.sin(2 * np.pi * 440 * np.arange(4800) / FS).astype(np.float32) * 0.3
    y = run(lib, shifter(lib, 1200, mix=0), x)
    np.testing.assert_array_equal(y, x)


def test_unity_shift_is_a_short_delay(lib):
    """No shift: the wet signal is the input delayed by the head's start delay."""
    x = np.zeros(FS // 10, dtype=np.float32)
    x[100] = 0.5
    y = run(lib, shifter(lib, 0), x)
    k = int(np.argmax(np.abs(y)))
    assert 100 < k < 100 + int(0.02 * FS)          # under 20 ms
    assert abs(y[k] - 0.5) < 1e-3
