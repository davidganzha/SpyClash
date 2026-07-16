# SpyClash audio provenance

## Scope

The 27 WAV files in `SpyClash/Resources/Sounds/` are generated specifically for SpyClash by `scripts/generate-original-sounds.py`.

The generator creates every PCM sample from:

- mathematical sine, triangle, and soft-square oscillators;
- deterministic frequency sweeps and amplitude envelopes;
- a fixed xorshift32 pseudo-random sequence used as synthesized noise;
- deterministic echo and mixing operations.

No recorded audio, third-party samples, commercial sound libraries, stock media, externally generated audio files, or trained audio models are inputs to the generator. The cue names, synthesis recipes, timing, and source code are maintained as part of this repository.

## Reproduction

Regenerate the complete bank from the repository root:

```bash
python3 scripts/generate-original-sounds.py
```

Verify that every checked-in file is byte-identical to a fresh deterministic render:

```bash
python3 scripts/generate-original-sounds.py --check --manifest
```

The generator rejects unexpected WAV files in the output directory, so this verification also proves that the app sound bank contains exactly the declared 27 cues.

## Technical format

- uncompressed linear PCM WAV;
- mono;
- 48,000 Hz sample rate;
- signed 16-bit little-endian samples;
- deterministic WAV headers with no embedded timestamps or external metadata.

## Change control

Audio changes must be made by editing the synthesis recipes in `scripts/generate-original-sounds.py` and regenerating the WAV files. Imported or manually replaced WAV files will fail the `--check` verification and must not be shipped.
