"""Fixed A2-Lite numerical, lifecycle, rate and model-conversion checks.

Synthetic weights only: no vendor data or third-party captures in this suite.
"""
import copy
import ctypes as ct
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "firmware" / "audio"
spec = importlib.util.spec_from_file_location("nam_fixed", ROOT / "tools" / "nam_fixed.py")
fixed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixed)


def model():
    return {"architecture": "WaveNet", "sample_rate": 48000, "config": {
        "head_scale": 0.01, "layers": [{
            "input_size": 1, "condition_size": 1, "channels": 3, "bottleneck": 3,
            "kernel_sizes": fixed.KERNELS, "dilations": fixed.DILATIONS,
            "activation": [{"type": "LeakyReLU", "negative_slope": 0.01}] * 23,
            "head": {"out_channels": 1, "kernel_size": 16, "bias": True},
            "layer1x1": {"active": True, "groups": 1}}]},
        "weights": np.random.default_rng(102).uniform(-0.05, 0.05, 1871).tolist()}


def reference(weights, audio):
    """Offline double-precision, whole-signal causal convolutions (no rings).

    This intentionally differs from the streaming C implementation. It exercises
    every tap, dilation, bias, condition mixin, residual and head-scale weight.
    """
    w = np.asarray(weights, dtype=np.float64)
    audio = audio.astype(np.float64)
    x = w[:3, None] * audio
    head = np.zeros_like(x)
    p = 3
    for k, d in zip(fixed.KERNELS, fixed.DILATIONS):
        conv = w[p:p+9*k].reshape(3, 3, k)
        p += 9*k
        z = np.broadcast_to(w[p:p+3, None], x.shape).copy()
        p += 3
        for tap in range(k):
            back = (k-1-tap)*d
            if back < len(audio):
                z[:, back:] += conv[:, :, tap] @ x[:, :len(audio)-back]
        z += w[p:p+3, None] * audio
        p += 3
        z = np.where(z >= 0, z, 0.01*z)
        head += z
        x += w[p:p+9].reshape(3, 3) @ z + w[p+9:p+12, None]
        p += 12
    conv = w[p:p+48].reshape(3, 16)
    y = np.full(len(audio), w[p+48])
    for tap in range(16):
        back = 15-tap
        if back < len(audio):
            y[back:] += conv[:, tap] @ head[:, :len(audio)-back]
    assert p+50 == 1871
    return y * w[-1]


class State(ct.Structure):
    _fields_ = [("weights", ct.c_float * 1871), ("history", ct.c_float * 19110),
                ("position", ct.c_uint16 * 24), ("ready", ct.c_int)]


@pytest.fixture(scope="module")
def kernel(tmp_path_factory):
    if not shutil.which("cc"):
        pytest.skip("host C compiler not installed")
    path = tmp_path_factory.mktemp("nam") / ("nam.dll" if sys.platform == "win32" else "nam.so")
    subprocess.run(["cc", "-O2", "-shared", "-fPIC", "-ffp-contract=off", "-Wall", "-Wextra",
                    "-Werror", "-I", str(FW / "src"), str(FW / "src/dsp/nam_a2.c"),
                    "-o", str(path)], check=True)
    lib = ct.CDLL(str(path))
    lib.nam_a2_init.argtypes = [ct.POINTER(State), ct.POINTER(ct.c_float), ct.c_size_t,
                               ct.c_uint, ct.c_uint]
    lib.nam_a2_reset.argtypes = [ct.POINTER(State)]
    lib.nam_a2_process.argtypes = [ct.POINTER(State), ct.POINTER(ct.c_float), ct.c_uint]
    return lib


def init(kernel, weights, rate=48000):
    state = State()
    array = (ct.c_float * len(weights))(*weights)
    assert kernel.nam_a2_init(ct.byref(state), array, len(weights), rate, 48000) == 0
    return state


def render(kernel, state, audio, chunks=(32,)):
    result = np.asarray(audio, dtype=np.float32).copy()
    i = j = 0
    while i < len(result):
        n = min(chunks[j % len(chunks)], len(result)-i)
        ptr = ct.cast(result.ctypes.data+i*4, ct.POINTER(ct.c_float))
        assert kernel.nam_a2_process(ct.byref(state), ptr, n) == 0
        i += n
        j += 1
    return result


def test_numerical_reference_and_chunking(kernel):
    weights = fixed.validate(model())
    audio = np.random.default_rng(17).uniform(-0.8, 0.8, 7001).astype(np.float32)
    audio[:4] = [1, 0, -1, 0]
    expected = reference(weights, audio)
    state = init(kernel, weights)
    actual = render(kernel, state, audio)
    assert np.max(np.abs(expected-actual)) < 2e-7
    for chunks in ((1,), (7, 32, 3, 1, 29)):
        np.testing.assert_array_equal(actual, render(kernel, init(kernel, weights), audio, chunks))
    kernel.nam_a2_reset(ct.byref(state))
    np.testing.assert_array_equal(actual, render(kernel, state, audio))
    assert ct.sizeof(state) == 83976


def test_invalid_input_and_model(kernel):
    weights = (ct.c_float * 1871)(*fixed.validate(model()))
    state = init(kernel, weights)
    original = bytes(state)
    block = (ct.c_float * 33)(*([0.2]*33))
    assert kernel.nam_a2_process(ct.byref(state), block, 33) == -1
    assert bytes(state) == original and block[0] == ct.c_float(0.2).value
    block[0] = float("nan")
    assert kernel.nam_a2_process(ct.byref(state), block, 1) == -1
    assert bytes(state) == original
    assert kernel.nam_a2_process(ct.byref(state), None, 0) == 0
    for model_rate, engine_rate, count in ((44100, 48000, 1871), (48000, 44100, 1871),
                                          (0, 48000, 1871), (48000, 48000, 1870)):
        assert kernel.nam_a2_init(ct.byref(state), weights, count, model_rate, engine_rate) == -1
        assert state.ready == 0
    for bad in (float("inf"), float("nan")):
        weights[500] = bad
        assert kernel.nam_a2_init(ct.byref(state), weights, 1871, 48000, 48000) == -1


def test_inference_overflow_recovers(kernel):
    state = init(kernel, [3e38] * 1871)
    block = (ct.c_float * 32)(*([1]*32))
    assert kernel.nam_a2_process(ct.byref(state), block, 32) == -2
    assert list(block) == [0]*32
    assert not any(state.history) and not any(state.position)


def test_oldest_dilated_tap_and_head_orientation(kernel):
    weights = [0.0] * 1871
    weights[0] = 1.0  # input rechannel
    layer = 6  # k=6, dilation=239: farthest lookback = 1195
    offset = 3 + sum(9*k+18 for k in fixed.KERNELS[:layer])
    weights[offset] = 1.0  # oldest conv tap, channel 0 -> 0
    head = 3 + sum(9*k+18 for k in fixed.KERNELS)
    weights[head] = 1.0  # oldest head tap: a further 15 samples
    weights[-1] = 1.0
    audio = np.zeros(2500, dtype=np.float32)
    audio[0], audio[1250] = 0.5, -0.5
    output = render(kernel, init(kernel, weights), audio)
    expected = np.zeros_like(audio)
    expected[1210], expected[2460] = 0.5, -0.005
    np.testing.assert_allclose(output, expected, atol=1e-9)


@pytest.mark.skipif(not os.environ.get("FB200_NAM_CORE_REFERENCE"),
                    reason="optional pinned NAM Core oracle not built")
def test_upstream_core_oracle(kernel, tmp_path):
    document = model()
    weights = fixed.validate(document)
    signal = np.random.default_rng(170).uniform(-0.8, 0.8, 7001).astype(np.float32)
    nam = tmp_path / "synthetic.nam"
    nam.write_text(json.dumps(document))
    source, output = tmp_path / "input.f32", tmp_path / "output.f32"
    signal.tofile(source)
    subprocess.run([os.environ["FB200_NAM_CORE_REFERENCE"], str(nam), str(source), str(output)],
                   check=True)
    expected = np.fromfile(output, dtype=np.float32)
    actual = render(kernel, init(kernel, weights), signal)
    np.testing.assert_allclose(actual, expected, rtol=0, atol=2e-7)


@pytest.mark.parametrize("change", [
    lambda m: m.update(sample_rate=44100),
    lambda m: m.pop("sample_rate"),
    lambda m: m["weights"].pop(),
    lambda m: m["weights"].__setitem__(0, float("nan")),
    lambda m: m["weights"].__setitem__(0, 1e40),
    lambda m: m["weights"].__setitem__(0, True),
    lambda m: m["config"].update(condition_dsp={"architecture": "Linear"}),
    lambda m: m["config"]["layers"][0].update(channels=8),
    lambda m: m["config"]["layers"][0].update(gated=True),
    lambda m: m["config"]["layers"][0].update(groups_input=3),
    lambda m: m["config"]["layers"][0].update(conv_pre_film={"active": True}),
    lambda m: m["config"]["layers"][0].update(head={"out_channels": 1, "kernel_size": 16,
                                                    "bias": True, "head_dilation": 2}),
    lambda m: m["config"].update(future_feature=True),
])
def test_converter_rejects_unsupported(change):
    document = model()
    change(document)
    with pytest.raises(ValueError):
        fixed.validate(document)


def test_packed_rate_inheritance():
    bare = model()
    del bare["sample_rate"]
    packed = {"architecture": "SlimmableContainer", "sample_rate": 48000,
              "config": {"submodels": [{"model": bare}]}}
    assert len(fixed.validate(packed)) == 1871
    packed["config"]["submodels"].append({"model": copy.deepcopy(bare)})
    with pytest.raises(ValueError, match="exactly one"):
        fixed.validate(packed)


def test_generated_c_roundtrip(kernel, tmp_path):
    if not shutil.which("cc"):
        pytest.skip("host C compiler not installed")
    path = tmp_path / "capture.nam"
    path.write_text(json.dumps(model()))
    generated = tmp_path / "fixed.c"
    subprocess.run([sys.executable, str(ROOT / "tools/nam_fixed.py"), str(path),
                    "-o", str(generated)], check=True)
    binary = tmp_path / ("fixed.dll" if sys.platform == "win32" else "fixed.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-I", str(FW / "src"), str(generated),
                    "-o", str(binary)], check=True)
    weights = (ct.c_float * 1871).in_dll(ct.CDLL(str(binary)), "nam_fixed_weights")
    assert list(weights) == fixed.validate(model())
    state = init(kernel, weights)
    audio = np.array([0.5, -0.5] * 20, dtype=np.float32)
    np.testing.assert_allclose(render(kernel, state, audio), reference(weights, audio), atol=2e-7)
    # Invalid conversion cannot overwrite a previously validated output.
    old = generated.read_bytes()
    path.write_text('{"architecture":"LSTM"}')
    assert subprocess.run([sys.executable, str(ROOT / "tools/nam_fixed.py"), str(path),
                           "-o", str(generated)], capture_output=True, check=False).returncode != 0
    assert generated.read_bytes() == old
