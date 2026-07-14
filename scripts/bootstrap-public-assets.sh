#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sounds="$root/SpyClash/Resources/Sounds"
mkdir -p "$sounds"

python3 - "$sounds" <<'PY'
import pathlib
import struct
import sys
import wave

destination = pathlib.Path(sys.argv[1])
names = [
    "apple-access-surge.wav",
    "apple-fragment-lock.wav",
    "ui-allow.wav",
    "ui-click.wav",
    "ui-copy-confirm.wav",
    "ui-countdown-go.wav",
    "ui-countdown-tick.wav",
    "ui-denied.wav",
    "ui-echo-blip.wav",
    "ui-game-start.wav",
    "ui-hard-deny.wav",
    "ui-holographic-tick.wav",
    "ui-navigation-shift.wav",
    "ui-player-join.wav",
    "ui-player-leave.wav",
    "ui-qr-card-flip.wav",
    "ui-ready-lock.wav",
    "ui-result-detectives.wav",
    "ui-result-spy.wav",
    "ui-role-reveal.wav",
    "ui-secret-reveal.wav",
    "ui-success.wav",
    "ui-toggle-off.wav",
    "ui-toggle-on.wav",
    "ui-turn-pass.wav",
    "ui-vote-cast.wav",
    "ui-vote-locked.wav",
]

sample_rate = 44_100
frames = sample_rate // 20
silence = struct.pack("<h", 0) * frames

created = 0
for name in names:
    path = destination / name
    if path.exists():
        continue
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(silence)
    created += 1

print(f"Public asset bootstrap complete: {created} placeholder sound(s) created.")
PY
