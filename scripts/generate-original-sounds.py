#!/usr/bin/env python3
"""Generate SpyClash's original procedural sound bank.

Every sample is produced from mathematical oscillators, a deterministic
pseudo-random-noise generator, and amplitude envelopes in this file. No
recordings, sample libraries, generated audio assets, or third-party audio
are used. Running the script with the same Python version-independent inputs
produces byte-identical 16-bit PCM WAV files.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import math
from pathlib import Path
import struct
import sys
import wave


SAMPLE_RATE = 48_000
TAU = math.tau

# Durations intentionally cover every playback window in HapticManager.swift.
CUE_DURATIONS = {
    "apple-access-surge.wav": 4.000,
    "apple-fragment-lock.wav": 0.420,
    "ui-allow.wav": 1.300,
    "ui-click.wav": 0.200,
    "ui-copy-confirm.wav": 0.507,
    "ui-countdown-go.wav": 0.600,
    "ui-countdown-tick.wav": 0.075,
    "ui-denied.wav": 0.900,
    "ui-echo-blip.wav": 0.850,
    "ui-game-start.wav": 1.200,
    "ui-hard-deny.wav": 1.280,
    "ui-holographic-tick.wav": 0.120,
    "ui-navigation-shift.wav": 0.667,
    "ui-player-join.wav": 0.550,
    "ui-player-leave.wav": 0.550,
    "ui-qr-card-flip.wav": 0.600,
    "ui-ready-lock.wav": 0.230,
    "ui-result-detectives.wav": 1.802,
    "ui-result-spy.wav": 1.375,
    "ui-role-reveal.wav": 0.646,
    "ui-secret-reveal.wav": 0.875,
    "ui-success.wav": 2.250,
    "ui-toggle-off.wav": 0.110,
    "ui-toggle-on.wav": 0.090,
    "ui-turn-pass.wav": 0.624,
    "ui-vote-cast.wav": 0.120,
    "ui-vote-locked.wav": 0.320,
}


class Noise:
    """Small fixed xorshift32 PRNG used only to synthesize noise."""

    def __init__(self, seed: int) -> None:
        self.state = seed & 0xFFFFFFFF or 0x6D2B79F5

    def sample(self) -> float:
        value = self.state
        value ^= (value << 13) & 0xFFFFFFFF
        value ^= value >> 17
        value ^= (value << 5) & 0xFFFFFFFF
        self.state = value & 0xFFFFFFFF
        return (self.state / 0xFFFFFFFF) * 2.0 - 1.0


def blank(duration: float) -> list[float]:
    return [0.0] * int(round(duration * SAMPLE_RATE))


def smoothstep(value: float) -> float:
    value = min(1.0, max(0.0, value))
    return value * value * (3.0 - 2.0 * value)


def envelope(position: float, duration: float, attack: float, release: float) -> float:
    if position < 0.0 or position >= duration:
        return 0.0
    attack_gain = smoothstep(position / max(attack, 1.0 / SAMPLE_RATE))
    release_gain = smoothstep((duration - position) / max(release, 1.0 / SAMPLE_RATE))
    return min(attack_gain, release_gain)


def waveform(kind: str, phase: float) -> float:
    sine = math.sin(phase)
    if kind == "sine":
        return sine
    if kind == "triangle":
        return (2.0 / math.pi) * math.asin(sine)
    if kind == "soft-square":
        return math.tanh(1.8 * sine) / math.tanh(1.8)
    raise ValueError(f"Unknown waveform: {kind}")


def add_tone(
    target: list[float],
    *,
    start: float,
    duration: float,
    frequency: float,
    end_frequency: float | None = None,
    gain: float = 0.25,
    attack: float = 0.004,
    release: float = 0.050,
    kind: str = "sine",
    decay: float = 0.0,
    vibrato_depth: float = 0.0,
    vibrato_rate: float = 0.0,
) -> None:
    first = max(0, int(round(start * SAMPLE_RATE)))
    count = max(1, int(round(duration * SAMPLE_RATE)))
    last = min(len(target), first + count)
    phase = 0.0
    final_frequency = frequency if end_frequency is None else end_frequency

    for index in range(first, last):
        local = (index - first) / SAMPLE_RATE
        progress = local / max(duration, 1.0 / SAMPLE_RATE)
        base_frequency = frequency + (final_frequency - frequency) * progress
        if vibrato_depth:
            base_frequency += math.sin(TAU * vibrato_rate * local) * vibrato_depth
        phase += TAU * base_frequency / SAMPLE_RATE
        shaped_gain = envelope(local, duration, attack, release)
        if decay:
            shaped_gain *= math.exp(-decay * local)
        target[index] += waveform(kind, phase) * gain * shaped_gain


def add_noise(
    target: list[float],
    *,
    start: float,
    duration: float,
    gain: float,
    seed: int,
    attack: float = 0.001,
    release: float = 0.040,
    low_pass: float = 0.35,
    decay: float = 0.0,
) -> None:
    first = max(0, int(round(start * SAMPLE_RATE)))
    count = max(1, int(round(duration * SAMPLE_RATE)))
    last = min(len(target), first + count)
    generator = Noise(seed)
    filtered = 0.0

    for index in range(first, last):
        local = (index - first) / SAMPLE_RATE
        filtered += low_pass * (generator.sample() - filtered)
        shaped_gain = envelope(local, duration, attack, release)
        if decay:
            shaped_gain *= math.exp(-decay * local)
        target[index] += filtered * gain * shaped_gain


def add_impulse(
    target: list[float],
    *,
    start: float,
    gain: float,
    seed: int,
    duration: float = 0.025,
) -> None:
    add_noise(
        target,
        start=start,
        duration=duration,
        gain=gain,
        seed=seed,
        attack=0.0005,
        release=duration,
        low_pass=0.60,
        decay=35.0,
    )


def add_note_sequence(
    target: list[float],
    notes: list[tuple[float, float]],
    *,
    start: float,
    note_duration: float,
    step: float,
    gain: float,
    kind: str = "sine",
) -> None:
    for offset, (frequency, weight) in enumerate(notes):
        add_tone(
            target,
            start=start + offset * step,
            duration=note_duration,
            frequency=frequency,
            gain=gain * weight,
            attack=0.006,
            release=min(0.12, note_duration * 0.55),
            kind=kind,
            decay=1.8,
        )


def add_echo(target: list[float], delay: float, feedback: float, wet: float) -> None:
    offset = int(round(delay * SAMPLE_RATE))
    if offset <= 0:
        return
    original = target.copy()
    for index in range(offset, len(target)):
        echo = original[index - offset]
        if index >= offset * 2:
            echo += target[index - offset] * feedback
        target[index] += echo * wet


def render_cue(name: str) -> list[float]:
    sound = blank(CUE_DURATIONS[name])

    if name == "apple-fragment-lock.wav":
        # The player intentionally seeks past 58 ms; keep the designed onset there.
        add_impulse(sound, start=0.058, gain=0.38, seed=0xA110C)
        add_tone(sound, start=0.058, duration=0.210, frequency=1180, end_frequency=420,
                 gain=0.28, attack=0.001, release=0.105, kind="triangle", decay=6.0)
        add_tone(sound, start=0.080, duration=0.250, frequency=96, end_frequency=70,
                 gain=0.30, attack=0.003, release=0.150, decay=7.0)
    elif name == "apple-access-surge.wav":
        add_tone(sound, start=0.00, duration=2.90, frequency=48, end_frequency=92,
                 gain=0.24, attack=0.16, release=0.80, kind="soft-square", vibrato_depth=1.2, vibrato_rate=5.2)
        add_tone(sound, start=0.08, duration=2.40, frequency=180, end_frequency=920,
                 gain=0.18, attack=0.09, release=0.52, kind="triangle")
        for index, frequency in enumerate((392.0, 523.25, 659.25, 783.99, 1046.5)):
            add_tone(sound, start=0.44 + index * 0.25, duration=1.25,
                     frequency=frequency, gain=0.11, attack=0.025, release=0.65, decay=0.9)
        add_noise(sound, start=0.18, duration=2.00, gain=0.10, seed=0xACCE55,
                  attack=0.30, release=0.65, low_pass=0.08)
        add_echo(sound, delay=0.19, feedback=0.24, wet=0.22)
    elif name in {"ui-success.wav", "ui-allow.wav"}:
        notes = [(523.25, 1.0), (659.25, 0.92), (783.99, 0.86)]
        start = 0.045 if name == "ui-success.wav" else 0.020
        add_note_sequence(sound, notes, start=start, note_duration=0.72, step=0.16,
                          gain=0.24, kind="triangle")
        add_tone(sound, start=start, duration=min(1.1, len(sound) / SAMPLE_RATE - start),
                 frequency=104.0, end_frequency=156.0, gain=0.12,
                 attack=0.015, release=0.34, decay=2.1)
        add_echo(sound, delay=0.155, feedback=0.17, wet=0.20)
    elif name == "ui-click.wav":
        add_impulse(sound, start=0.070, gain=0.34, seed=0xC11C)
        add_tone(sound, start=0.070, duration=0.095, frequency=2100, end_frequency=720,
                 gain=0.25, attack=0.0005, release=0.055, kind="triangle", decay=12.0)
    elif name == "ui-copy-confirm.wav":
        add_impulse(sound, start=0.010, gain=0.20, seed=0xC0F1)
        add_note_sequence(sound, [(740.0, 1.0), (988.0, 0.88)], start=0.018,
                          note_duration=0.34, step=0.085, gain=0.25, kind="triangle")
    elif name == "ui-countdown-tick.wav":
        add_impulse(sound, start=0.000, gain=0.30, seed=0x71C)
        add_tone(sound, start=0.000, duration=0.072, frequency=1320, end_frequency=980,
                 gain=0.29, attack=0.0005, release=0.046, kind="triangle", decay=18.0)
    elif name == "ui-countdown-go.wav":
        add_impulse(sound, start=0.000, gain=0.34, seed=0x60)
        add_tone(sound, start=0.000, duration=0.58, frequency=180, end_frequency=720,
                 gain=0.28, attack=0.003, release=0.20, kind="soft-square", decay=2.3)
        add_tone(sound, start=0.045, duration=0.50, frequency=720, end_frequency=1080,
                 gain=0.16, attack=0.010, release=0.22)
    elif name in {"ui-denied.wav", "ui-hard-deny.wav"}:
        hard = name == "ui-hard-deny.wav"
        add_impulse(sound, start=0.000, gain=0.38 if hard else 0.24,
                    seed=0xBAD if hard else 0xD311)
        add_tone(sound, start=0.000, duration=0.78 if hard else 0.58,
                 frequency=220 if hard else 330, end_frequency=54 if hard else 92,
                 gain=0.34 if hard else 0.25, attack=0.002, release=0.30,
                 kind="soft-square", decay=1.8)
        add_tone(sound, start=0.025, duration=0.65, frequency=71, end_frequency=48,
                 gain=0.23, attack=0.006, release=0.28, decay=2.0)
        if hard:
            add_noise(sound, start=0.00, duration=0.46, gain=0.16, seed=0xD3AD,
                      release=0.30, low_pass=0.12, decay=4.0)
    elif name == "ui-echo-blip.wav":
        add_tone(sound, start=0.018, duration=0.26, frequency=880, end_frequency=1320,
                 gain=0.28, attack=0.003, release=0.11, kind="triangle", decay=3.0)
        add_echo(sound, delay=0.145, feedback=0.26, wet=0.48)
    elif name == "ui-holographic-tick.wav":
        add_tone(sound, start=0.000, duration=0.105, frequency=2400, end_frequency=3450,
                 gain=0.20, attack=0.001, release=0.060, kind="sine", decay=12.0)
        add_impulse(sound, start=0.000, gain=0.10, seed=0x4010)
    elif name == "ui-navigation-shift.wav":
        add_noise(sound, start=0.00, duration=0.54, gain=0.16, seed=0x5A1F7,
                  attack=0.010, release=0.19, low_pass=0.07, decay=2.1)
        add_tone(sound, start=0.00, duration=0.62, frequency=280, end_frequency=760,
                 gain=0.20, attack=0.006, release=0.22, kind="triangle", decay=1.6)
    elif name in {"ui-player-join.wav", "ui-player-leave.wav"}:
        joining = name == "ui-player-join.wav"
        notes = [(440.0, 1.0), (659.25, 0.88)] if joining else [(659.25, 1.0), (392.0, 0.90)]
        add_note_sequence(sound, notes, start=0.015, note_duration=0.38,
                          step=0.105, gain=0.23, kind="triangle")
        add_impulse(sound, start=0.012, gain=0.10, seed=0xA017 if joining else 0x1EA7)
    elif name == "ui-qr-card-flip.wav":
        add_noise(sound, start=0.00, duration=0.38, gain=0.22, seed=0x0F11,
                  attack=0.004, release=0.16, low_pass=0.20, decay=4.2)
        add_tone(sound, start=0.00, duration=0.50, frequency=1800, end_frequency=240,
                 gain=0.18, attack=0.003, release=0.18, kind="triangle", decay=2.6)
        add_impulse(sound, start=0.31, gain=0.18, seed=0xF11F)
    elif name in {"ui-secret-reveal.wav", "ui-role-reveal.wav"}:
        role = name == "ui-role-reveal.wav"
        add_noise(sound, start=0.00, duration=0.42, gain=0.10,
                  seed=0x5EC if not role else 0xB013, attack=0.03,
                  release=0.20, low_pass=0.06)
        add_tone(sound, start=0.00, duration=len(sound) / SAMPLE_RATE,
                 frequency=110 if role else 82, end_frequency=440 if role else 660,
                 gain=0.24, attack=0.012, release=0.22, kind="triangle")
        add_tone(sound, start=0.18, duration=min(0.52, len(sound) / SAMPLE_RATE - 0.18),
                 frequency=880, end_frequency=1320, gain=0.12,
                 attack=0.015, release=0.23)
    elif name in {"ui-toggle-on.wav", "ui-toggle-off.wav"}:
        enabled = name == "ui-toggle-on.wav"
        add_tone(sound, start=0.00, duration=len(sound) / SAMPLE_RATE,
                 frequency=720 if enabled else 540,
                 end_frequency=1280 if enabled else 250,
                 gain=0.30, attack=0.001, release=0.045,
                 kind="triangle", decay=10.0)
    elif name == "ui-ready-lock.wav":
        add_impulse(sound, start=0.006, gain=0.30, seed=0x10CC)
        add_tone(sound, start=0.006, duration=0.20, frequency=520, end_frequency=110,
                 gain=0.29, attack=0.001, release=0.105, kind="soft-square", decay=8.0)
    elif name == "ui-turn-pass.wav":
        add_tone(sound, start=0.00, duration=0.56, frequency=300, end_frequency=860,
                 gain=0.22, attack=0.006, release=0.19, kind="triangle", decay=1.5)
        add_tone(sound, start=0.15, duration=0.42, frequency=980, end_frequency=620,
                 gain=0.14, attack=0.010, release=0.18)
        add_echo(sound, delay=0.115, feedback=0.12, wet=0.18)
    elif name == "ui-vote-cast.wav":
        add_impulse(sound, start=0.000, gain=0.30, seed=0xCA57)
        add_tone(sound, start=0.000, duration=0.11, frequency=820, end_frequency=260,
                 gain=0.25, attack=0.001, release=0.065, kind="triangle", decay=8.0)
    elif name == "ui-vote-locked.wav":
        add_impulse(sound, start=0.002, gain=0.28, seed=0x10C7)
        add_tone(sound, start=0.002, duration=0.28, frequency=640, end_frequency=94,
                 gain=0.30, attack=0.001, release=0.13, kind="soft-square", decay=5.0)
    elif name == "ui-game-start.wav":
        add_noise(sound, start=0.00, duration=0.55, gain=0.10, seed=0x57A47,
                  attack=0.02, release=0.24, low_pass=0.07)
        add_note_sequence(sound, [(261.63, 0.9), (392.0, 1.0), (523.25, 0.95)],
                          start=0.05, note_duration=0.72, step=0.18,
                          gain=0.24, kind="soft-square")
        add_tone(sound, start=0.00, duration=1.08, frequency=52, end_frequency=104,
                 gain=0.20, attack=0.02, release=0.35, decay=1.1)
    elif name == "ui-result-detectives.wav":
        add_tone(sound, start=0.00, duration=1.50, frequency=65, end_frequency=130,
                 gain=0.17, attack=0.02, release=0.46, decay=0.8)
        add_note_sequence(sound, [(392.0, 1.0), (493.88, 0.92), (587.33, 0.90), (783.99, 0.82)],
                          start=0.06, note_duration=1.00, step=0.19,
                          gain=0.22, kind="triangle")
        add_echo(sound, delay=0.205, feedback=0.18, wet=0.20)
    elif name == "ui-result-spy.wav":
        add_noise(sound, start=0.00, duration=0.70, gain=0.12, seed=0x5F1,
                  attack=0.02, release=0.32, low_pass=0.08)
        add_tone(sound, start=0.00, duration=1.30, frequency=164.81, end_frequency=55,
                 gain=0.28, attack=0.009, release=0.38, kind="soft-square", decay=0.9)
        add_tone(sound, start=0.11, duration=1.06, frequency=233.08, end_frequency=116.54,
                 gain=0.18, attack=0.02, release=0.34, kind="triangle", vibrato_depth=4, vibrato_rate=6.2)
    else:
        raise KeyError(f"No synthesis recipe for {name}")

    return sound


def encode_wav(samples: list[float]) -> bytes:
    peak = max((abs(sample) for sample in samples), default=1.0)
    scale = 0.82 / peak if peak > 0.82 else 1.0
    pcm = bytearray()
    for sample in samples:
        limited = math.tanh(sample * scale * 1.12) / math.tanh(1.12)
        value = int(round(max(-1.0, min(1.0, limited)) * 32767.0))
        pcm.extend(struct.pack("<h", value))

    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(bytes(pcm))
    return output.getvalue()


def expected_files() -> dict[str, bytes]:
    return {name: encode_wav(render_cue(name)) for name in sorted(CUE_DURATIONS)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "SpyClash" / "Resources" / "Sounds",
        help="destination directory for WAV files",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify existing files are byte-identical without writing",
    )
    parser.add_argument(
        "--manifest",
        action="store_true",
        help="print SHA-256 hashes after generating or checking",
    )
    arguments = parser.parse_args()

    generated = expected_files()
    arguments.output.mkdir(parents=True, exist_ok=True)
    mismatches: list[str] = []
    changed = 0

    for name, payload in generated.items():
        path = arguments.output / name
        current = path.read_bytes() if path.exists() else None
        if current != payload:
            mismatches.append(name)
            if not arguments.check:
                path.write_bytes(payload)
                changed += 1
        if arguments.manifest:
            print(f"{hashlib.sha256(payload).hexdigest()}  {name}")

    unexpected = sorted(path.name for path in arguments.output.glob("*.wav") if path.name not in generated)
    if unexpected:
        print("Unexpected WAV files: " + ", ".join(unexpected), file=sys.stderr)
        return 1

    if arguments.check and mismatches:
        print("Sound bank differs from deterministic generator: " + ", ".join(mismatches), file=sys.stderr)
        return 1

    if arguments.check:
        print(f"Verified {len(generated)} deterministic original sound files.")
    else:
        print(f"Generated {len(generated)} original sound files ({changed} changed).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
