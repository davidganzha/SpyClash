# SpyClash bundled-audio rights manifest

All 27 release WAV files were added to Git in commit `6daff05` on July 14,
2026. They are original deterministic procedural renders produced by
`scripts/generate-original-sounds.py`; no Splice files, recordings, stock
samples, generated audio assets, or other third-party audio inputs are used.

`python3 scripts/generate-original-sounds.py --check --manifest` reproduced and
verified every checked-in byte on July 16, 2026. `AUDIO_PROVENANCE.md` documents
the synthesis inputs and change-control rule. The table binds that reproducible
source to every shipped file by SHA-256.

| Bundled file | Final SHA-256 | Duration | Source asset / ID | License evidence | Transform notes | Status |
| --- | --- | ---: | --- | --- | --- | --- |
| `apple-access-surge.wav` | `54bb7f49828b7a21612a62f7043f520e75cd0a96aa60d970a3fb0bdc9df2364e` | 4.000 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `apple-fragment-lock.wav` | `1ad61ca33fa5b07a1877eaa1574c2368d59b54df3040714f0c4cfbe480523d6e` | 0.420 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-allow.wav` | `dd4348f4678d85938f5a6eab6af5d38efb48f2d18ce1ec78a2c4b14ce14666c3` | 1.300 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-click.wav` | `9fede7468b43ffb19931110ab6871930953914385e0754f6eb79f3163fccfed8` | 0.200 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-copy-confirm.wav` | `74d7334234aca857841391b32d0f3ee9cd3f1a0c7743946cc7bf0f768ecd404b` | 0.507 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-countdown-go.wav` | `6903c8d473e6f401fc0204f767ed0965c8a1ae72b4ec54a0d444e2de81e5ae8a` | 0.600 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-countdown-tick.wav` | `e92422e9f5e373aa64138be58e480cb3080958bc4684ee89cee71ad2ea5b49ed` | 0.075 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-denied.wav` | `c27e020b9b5791d00c41db7c0bf1ec8af432018d8468f1a2a0a262cb237cb382` | 0.900 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-echo-blip.wav` | `51ea479f1ce11cf072c012d205a01e3c32cb1ba6365a4917d78d245ae82de101` | 0.850 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-game-start.wav` | `3a36aea065173915a8302b0adf04156ee38a482b18ace166985cff3f1e180414` | 1.200 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-hard-deny.wav` | `cd916b4118b2e30a3cfd07784b1e47d63833ccfd08f62bcf404531d3a0fd3c47` | 1.280 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-holographic-tick.wav` | `f97ac72795e6f5f8db3d897f125332a59a1fafb08ae1b2e6a17a3ac856c631d5` | 0.120 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-navigation-shift.wav` | `043267f71e6d451b5d299891e6d624bafe9ecf9422800a7eb74464e51632fe75` | 0.667 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-player-join.wav` | `ac2aafce157f0e87106d56a623c66bbdf364f6c603029c8257c43f98ab2a3637` | 0.550 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-player-leave.wav` | `e1fc5c4574eb3d1be0d3d751f46c7b3ac81c96645fe2b909fa62e7c0318157b5` | 0.550 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-qr-card-flip.wav` | `96783f460446957e5e89688e8b6e9adaa1bd1cfa07fa0762f5ac424707d16935` | 0.600 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-ready-lock.wav` | `5a7969df0047f059e08b5f098928497eba058cba5fcb31d2e3d6b14ae5dd7f28` | 0.230 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-result-detectives.wav` | `070c11cd294577746aeb88f3c6a0d767d8822b5e312288b743282e3bd1535a80` | 1.802 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-result-spy.wav` | `9949f15da14896694c0ff86a5f32fc6c9dac53d645477e3de9ab52e6b27d0f95` | 1.375 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-role-reveal.wav` | `64470def7dbd12a571275bf7190f0751db1616b74f9e4a9e5f3e4f0ee6c5edcd` | 0.646 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-secret-reveal.wav` | `cc1ef9177ba8e237435a517c6b7992704ba21d61c127e1451ac2c546750dbd8b` | 0.875 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-success.wav` | `c4357fe484a07a7068bd0ef7046a60765c08ba36300071b2312c7f5d4c335d96` | 2.250 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-toggle-off.wav` | `b686e5428153e0eb9bc012b8f7e712a74750eb1bdc48bcd04c410d952c5102c3` | 0.110 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-toggle-on.wav` | `60c8bf88a066b6d738f203db81576d8ad1405dd56adeac082b54b6c8e8451797` | 0.090 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-turn-pass.wav` | `d705ea1c05aadc175a99ad7d6676efffa37640c1ec87381497fb255a552dfa06` | 0.624 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-vote-cast.wav` | `a092cac3a3ce9dc9fc79703b8520515f95c707ba9d97cd94e266ff2dbaa42018` | 0.120 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |
| `ui-vote-locked.wav` | `e3aa9eab360ffab76c5899982c2b9d7e2a413d7b26fa1231ada50b6cde27be9c` | 0.320 s | procedural recipe | `AUDIO_PROVENANCE.md` + generator | deterministic render | VERIFIED |

## Completion rule

This technical provenance gate is complete when the generator check succeeds
and all 27 hashes match. The App Store content-rights declaration remains a
legal assertion by the rights holder and must not be signed by an automated
agent on the holder's behalf.
