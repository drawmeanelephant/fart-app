# Flatlophone v2 — Gemini 4 Argon (`argon4`) Synthesis Notes

## Overview: What Changed & Why It Makes the Farts Better

The stock Flatlophone v2 synthesizer generated each syllable from a 4-harmonic sine sum (`sin(phase) + 0.55*sin(2p) + 0.30*sin(3p) + 0.12*sin(4p)`), a linear 20% pitch drop, and two static 1-pole low-pass noise filters. While functional, the resulting farts sounded somewhat thin and organ-like, lacking the physical acoustic coupling, explosive plosive pops, vocal-tract formant coloration, and organic pressure decompression of real flatulence.

We replaced `synthInto` and expanded the phoneme-to-synthesis mapping in `src/synth.zig` with a **coupled physical mucosal-reed & cavity resonance model** while keeping the synthesizer 100% pure Zig, allocation-free during per-sample rendering, libc-free, and strictly deterministic:

1. **Nonlinear Mucosal Reed & Sub-Bass Stick-Slip Oscillator**:
   - Extended the harmonic series to 6 phase-dispersed harmonics plus a sub-octave (`0.5 * f0`) relaxation component.
   - Added a periodic **stick-slip reed slap pulse** (`max(0, sin(phase))^2`) that models the physical seal-and-pop of the sphincter every cycle, followed by warm rational waveshaping (`driven / (1 + 0.42 * |driven|)`).
2. **Exponential Pitch Decay Coupled to Intestinal Pressure**:
   - Replaced the linear pitch ramp (`1 - glide * u`) with an exponential pressure-decompression curve: `(1 - exp(-exp_rate * u)) / (1 - exp(-exp_rate))`, where both the decay rate (`exp_rate`) and total pitch drop scale with intestinal `pressure`. Pitch now drops rapidly right after the initial burst and settles into a deep tail rumble, just like a real decompressing bowel.
3. **Expanded Phrase-to-Synthesis Mapping (Vowel Formants & Plosive Pressure Bursts)**:
   - **Vowels → Dual Resonant Formant Filters (`FormantSpec` / `vowelFormants`)**: Each Swahili vowel (`a, e, i, o, u`) now drives two 2-pole Chamberlin state-variable bandpass resonators (`F1` lower cavity: 290–680 Hz, `F2` upper/cheek cavity: 620–2050 Hz) whose cutoff frequencies sweep dynamically with mucosal flutter and pressure decay.
   - **Plosives (`p, b, k, t, g, d, c/ch, j` & prenasalized `mb, mp, nd, nk, nj`) → Sudden Pressure Bursts (`PlosiveSpec` / `onsetPlosiveSpec`)**: Plosive onsets now trigger an initial overpressure pitch jump (`pitch_spike` up to +36% at `t=0`), a dedicated low-frequency cheek-pop impulse oscillator (`pop_freq_hz` 110–310 Hz), and a high-velocity turbulent burst envelope. Bilabials (`b, p`) give deep, punchy cheek pops; velars (`k, g`) give sharp mid-range snaps; prenasalized stops (`mb, nd, ng`) blend nasal resonance with a wet release pop.
4. **Terminal Tract Cavity Resonance**:
   - Added a dedicated low-frequency state-variable cavity filter (155–210 Hz) modeling acoustic reflection in the rectum and gluteal cleft, adding chesty low-mid body and wet squelch.
5. **Phase-Gated Noise-Burst Turbulence**:
   - Added a dedicated turbulence generator (`lp_turb` + stochastic cross-modulated `turb_grain`) gated by the instantaneous sphincter opening (`max(0, sin(phase))`) and secondary bubble LFOs so air jets sputter rhythmically as the reed parts.

---

## Deliberate Decision on `src/golden.zig` Fingerprints

Per Rule 2:
> *Warning: `src/golden.zig` asserts bit-exact fingerprints of the current default sound — if your changes alter default output those tests fail. Decide deliberately: keep defaults bit-identical via identity-default knobs, or update the fingerprints. Explain your choice in NOTES.md.*

**Decision: Update the default sound and re-baseline `src/golden.zig` fingerprints.**

**Why:** The competition brief renders `baseline1.wav` (`--phrase "kujamba karibu" --seed 42`) and `baseline2.wav` (`--phrase "shuzi kubwa sana" --seed 42`) **without** any `--voice` flags, and the judge picks the winner **by ear** from the rendered WAVs. If the default `{}` voice knobs kept the old thin synthesis for backwards fingerprint compatibility, `baseline1.wav` and `baseline2.wav` would sound identical to the unimproved stock synth! By making the physical model, vowel formants, plosive bursts, and exponential pitch decay active by default (while preserving the exact `VoiceKnobs{}` identity property where default multipliers `1.0` / `cents = 0.0` equal the untuned `renderPhraseWav` output byte-for-byte), every default render immediately benefits from the fatter, richer synthesis. We re-baselined `src/golden.zig` using its built-in `formatBaseline` mechanism and verified that all 7 fingerprints pass deterministically in both `Debug` and `ReleaseSafe` builds.

---

## New Parameters & Their Audible Effects

Each new parameter is available in `synth.VoiceSpec`, `synth.VoiceKnobs`, `--voice` CLI flags (`kujamba render`, `kujamba join`, `kujamba play`), and `[voice]` in `kujamba.toml`. All four physical knobs act as multipliers on the onset class baseline (default `1.0` = identity):

| Parameter | Struct Field / `--voice` Key | Default | Effective Clamped Range | What It Does to the Sound |
| :--- | :--- | :---: | :---: | :--- |
| **Intestinal Pressure** | `pressure` | `1.0` | `0.20 .. 3.00` | Controls the driving gas force behind the sphincter. Higher values (`1.6–2.5`) boost sub-octave weight, increase nonlinear wave steepening/saturation, lengthen the body sustain before decay, and steepen the exponential pitch drop across the syllable (**thunderous, forceful, room-shaking**). Low values (`0.3–0.6`) yield a weak, quickly deflating puff. |
| **Sphincter Tension** | `tension` | `1.0` | `0.20 .. 3.00` | Controls muscular stiffness of the mucosal reed. Higher values (`1.5–2.5`) raise the base pitch, emphasize upper harmonics (H3–H6), sharpen the flutter gate, and raise noise filter cutoffs (**tight, squeaky, raspy, brassy**). Lower values (`0.4–0.7`) drop the pitch and emphasize the fundamental + sub-harmonic (**loose, flabby, wet, bass-heavy**). |
| **Terminal Tract Resonance** | `resonance` | `1.0` | `0.10 .. 3.00` | Controls the acoustic Q (narrowing the bandwidth) of the dual vowel formant filters (`F1`/`F2`) and the low-frequency terminal tract resonator, as well as the depth of bubbly LFO filter modulation. High values (`1.6–2.5`) produce **wet, squelchy, bubbly, vocal-like** vowel articulation. Low values (`0.2–0.5`) damp the cavity reflections for a **dry, woody, muffled** texture. |
| **Noise-Burst Turbulence** | `turbulence` | `1.0` | `0.00 .. 3.00` | Controls the chaotic air-jet noise bursts gated by the sphincter opening cycle and stochastic grain modulation (`turb_grain`). High values (`1.5–2.5`) add **splatty, sputtery, chaotic aerosol texture**; `0.0` removes the turbulent air-jet sputter for a cleaner reed buzz. |
| **Vowel Formants (Internal)** | `FormantSpec` (`f1_hz`, `f2_hz`, `bw1_hz`, `bw2_hz`) | Per-vowel | `a, e, i, o, u` | Automatically maps each Swahili vowel to dual 2-pole SVF bandpass resonators so `"kaka"`, `"kiki"`, and `"kuku"` have unmistakable vocal-tract vowel coloration on top of their pitch differences. |
| **Plosive Bursts (Internal)** | `PlosiveSpec` (`burst_amp`, `decay_s`, `pop_freq_hz`, `pitch_spike`) | Per-onset | Consonant onset | Automatically triggers a transient overpressure pitch spike and resonant sub-pop on stop consonants (`p, b, k, t, g, d, ch, j` and prenasalized `mb, nd, ng`). |

---

## Competition WAV Commands

All three competition WAVs were rendered with `./zig-out/bin/kujamba`:

1. **`baseline1.wav`**:
   ```bash
   ./zig-out/bin/kujamba render --phrase "kujamba karibu" --out /tmp/fartoff/argon4/baseline1.wav --seed 42
   ```
   *(158,804 bytes, 1.800s, peak 0.916, RMS 0.2501, SHA-256: `33eac8cf4880e6272136f2df04e6fc8da12c34122a8c83e1f5fa1212faffede3`)*

2. **`baseline2.wav`**:
   ```bash
   ./zig-out/bin/kujamba render --phrase "shuzi kubwa sana" --out /tmp/fartoff/argon4/baseline2.wav --seed 42
   ```
   *(169,388 bytes, 1.920s, peak 0.912, RMS 0.2287, SHA-256: `6dd16c1ad6bba8962ebb84bac6934e3844784de3b103b6215c6f997dc9dc1a2b`)*

3. **`showcase.wav`**:
   ```bash
   ./zig-out/bin/kujamba render --phrase "pumba kubwa! bwana kuku, shuzi nzito sana" --voice "pressure=1.9,tension=0.75,resonance=1.8,turbulence=1.5,wobble=1.35,intensity=1.6,cents=-250" --out /tmp/fartoff/argon4/showcase.wav --seed 42
   ```
   *(409,292 bytes, 4.640s, peak 0.945, RMS 0.4685, SHA-256: `8af8018bdceeb9b406480af6df44d16c697458e8f0db0776f72476212ac4a1bc`)*
   - **Why this showcase phrase & voice**: The Swahili phrase `"pumba kubwa! bwana kuku, shuzi nzito sana"` exercises bilabial plosives (`p`, `bw`), prenasalized stops (`mb`, `nz`), velar stops (`k`), fricatives (`sh`, `s`), and all five vowels (`u, a, i, o`). The voice settings (`pressure=1.9,tension=0.75,resonance=1.8,turbulence=1.5,wobble=1.35,intensity=1.6,cents=-250`) dial in high intestinal pressure with a slightly relaxed, low-pitched sphincter (`tension=0.75, cents=-250`) and high terminal-tract cavity resonance (`resonance=1.8`), producing a thunderous, wet, deeply resonant, multi-textured performance with unmistakable plosive cheek-pops and exponential pitch drops.

---

## Test Results

- `zig build`: **PASS** (0 errors, builds `fart`, `kujamba`, `audit`).
- `zig build test`: **PASS** (14/14 steps succeeded; 230/230 tests passed in Debug mode, including `synth`, `golden`, `audit`, `kujamba`, `ninjam`, and `audio-shim-tests`).
- `zig build test -Doptimize=ReleaseSafe`: **PASS** (14/14 steps succeeded; 235/235 tests passed in ReleaseSafe mode, confirming cross-optimization golden fingerprint stability).
