//! golden.zig — regression guard for the Flatlophone synth's rendered audio.
//!
//! Why this lives outside `synth.zig`: the point of a golden guard is to
//! outlive the refactors it protects. M6 (#15/#16/#18) reshapes `VoiceSpec`,
//! `voiceSpec` and the onset tables, and the guard should be the thing that
//! *reports* those changes rather than something rewritten alongside them. It
//! is also its own test target, so the check keeps running while synth.zig's
//! test module is being rewritten.
//!
//! ## Why this does not assert on a SHA-256 of the WAV bytes
//!
//! The obvious guard — pin the exact bytes — was measured, and it does not
//! hold. Rendering `"kujamba karibu"` and hashing the WAV gives
//!
//!     Debug        21c6faa26eb63b958968a6dfe2fcf33073182be7f34c0cef416894c84b045f3d
//!     ReleaseSafe  ab75668fca79a25e8833e6814c02c6c3129961a94670a8b2afdbb59190c56530
//!
//! on the *same machine*, same source, differing sample length unchanged. The
//! synth calls `@exp` and `@sin`, and LLVM contracts and inlines those
//! differently at different optimization levels, so a handful of samples land
//! on the other side of an i16 rounding boundary. Across ~80k samples, any
//! per-sample transform (including quantising) flips a large number of
//! buckets, so there is no cheap way to make an exact hash stable — and a
//! guard that goes red on `-Doptimize=ReleaseSafe`, and would go red again on
//! Linux and on CI, is a guard people learn to ignore.
//!
//! So the asserted fingerprint is built from measurements that *are* stable
//! under codegen, verified by re-running this whole suite in both modes:
//!
//!   | field             | stability                        | what it catches            |
//!   |-------------------|----------------------------------|----------------------------|
//!   | `items`           | exact (integer)                  | syllable splitting         |
//!   | `samples`         | exact (integer)                  | timing / duration          |
//!   | `peak`            | exact                            | overall level, clipping    |
//!   | `zero_crossings`  | exact                            | spectral tilt, buzziness   |
//!   | `envelope_sha256` | exact                            | the waveform itself        |
//!   | `rms_milli`       | within +/-2 of 1e-3 RMS          | coarse level check         |
//!
//! `envelope_sha256` is the strong one: SHA-256 over the per-10ms-window RMS
//! energy, each window rounded to a whole unit. A last-ULP wobble is ~0.003% of
//! full scale and does not move a window's integer RMS, while a reseeded noise
//! generator or a changed vowel table moves many windows. Measured: it is
//! bit-identical across optimization modes, and it catches a one-digit envelope
//! coefficient change, a 10 ms syllable-timing change, and a PRNG salt change.
//!
//! `wav_sha256` is still recorded, as the exact bytes at baseline time. It is
//! documentation and a diagnostic, not an assertion.
//!
//! Re-baselining: run `zig build test` and paste the block it prints over
//! `expected`. No script, no flag to remember.

const std = @import("std");
const synth = @import("synth.zig");
const registry = @import("engine_registry.zig");

/// RMS energy envelope window: 10 ms at the synth's sample rate.
const envelope_window_samples: usize = @as(usize, synth.SAMPLE_RATE) / 100;
/// Slack on the RMS check, in 1e-3 units. The measured codegen spread is 1.
const rms_milli_tolerance: i64 = 2;

pub const Kind = enum {
    /// render via `synth.renderPhraseWav`
    phrase,
    /// render via `synth.renderShuziWav` (a wordless fart, seeded)
    shuzi,
};

pub const Fingerprint = struct {
    /// stable label; used in failure output and as the copy-paste key
    name: []const u8,
    /// M9 (#95): which fart-off engine rendered this. `stock` rows are the
    /// pre-fart-off baseline and keep their original numbers; every other
    /// engine's rows live in `expected_engines`, measured on the same inputs.
    engine: registry.Id = .stock,
    kind: Kind,
    /// the phrase text, or the seed in decimal for `.shuzi`
    input: []const u8,
    /// syllables planned (0 for shuzi, which has no plan)
    items: u32,
    /// total samples in the rendered phrase
    samples: u32,
    /// largest absolute sample
    peak: u32,
    /// sign changes in the sample stream: a cheap proxy for spectral tilt
    zero_crossings: u32,
    /// RMS x 1000, asserted within `rms_milli_tolerance`
    rms_milli: i64,
    /// SHA-256 of the 10 ms windowed RMS envelope — the strong guard
    envelope_sha256: []const u8,
    /// SHA-256 of the exact WAV bytes. Recorded, not asserted: see the header.
    wav_sha256: []const u8,
};

/// The baseline. Any change here is a deliberate, reviewable act.
pub const expected = [_]Fingerprint{
    // the phrase the demo, the docs and the readme all use
    .{ .name = "kujamba karibu", .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 22007, .zero_crossings = 720, .rms_milli = 4173837, .envelope_sha256 = "b689f1368324e2b7abe414e01bdb121730f0bb6e7ffd0bd9a9defcb752f234d1", .wav_sha256 = "21c6faa26eb63b958968a6dfe2fcf33073182be7f34c0cef416894c84b045f3d" },
    // longer, so the fingerprint covers stress placement across several words
    .{ .name = "asante sana kijiji", .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 25998, .zero_crossings = 1134, .rms_milli = 4164752, .envelope_sha256 = "a6b896d1bc43543a6827465d36223fa91cf49cefe4b44460fe7a0272efa55a13", .wav_sha256 = "5973bbb55e662d2d47fdef82c2d4ee4b2ba059aa3d760e7801060e1af1d80c07" },
    // one syllable: the shortest render that still has an onset
    .{ .name = "single syllable", .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 15986, .zero_crossings = 114, .rms_milli = 3958198, .envelope_sha256 = "3c5018bab5a904216360d5629d715d4a23098c8197d13f4331cb7f0a5580b8fe", .wav_sha256 = "a62ad430e53741188447d842344e26e4fdc72bf86793fb5b84143ab0421f80f9" },
    // digits and punctuation are not word characters, so the word splitter
    // has to skip them and still place the syllables correctly
    .{ .name = "punctuation and digits", .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 21565, .zero_crossings = 766, .rms_milli = 4192678, .envelope_sha256 = "46981dc90e5a44a07254e7e492b90d2c99a0675eac67a0c5efcb7177c7a7c245", .wav_sha256 = "ca7703195aa4a5e34da7c7eae0eb1bdfa0b096e206d1f489ec96074077172093" },
    // wordless farts: no plan, and the noise/wobble path M6 will touch
    .{ .name = "shuzi seed 0", .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 18461, .zero_crossings = 180, .rms_milli = 4662515, .envelope_sha256 = "ff3acaee614295f74be4eec9ae8f1ced7e0d9542a5bfb90cf79c18e5e9068f4c", .wav_sha256 = "7e763663eadf675a0c5a26b05f460af57cb89566d68df11fd10b57796556fa8a" },
    .{ .name = "shuzi seed 42", .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 21395, .zero_crossings = 486, .rms_milli = 4081417, .envelope_sha256 = "effa4312bb20886b185c43f4cada609baebbba77b539af351f7d839e71f38a17", .wav_sha256 = "4c0500f416ca522f8bda17db9a1bb3a11f107be23fda353d6e66268d3e44c46a" },
    .{ .name = "shuzi seed 1234567", .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 19089, .zero_crossings = 104, .rms_milli = 4564000, .envelope_sha256 = "369cd4bd42022e93224eb9fb93ba0c0eac937e9f78dfd29a8e6e269498d343eb", .wav_sha256 = "fccfb948356d4697f6bf941a6b5f9dc59fcf712d3438f92919804de9724c20da" },
};

/// The fart-off table (M9, #95): every contestant engine rendering the same
/// seven inputs as `expected`. Each engine gets its own baseline — engines
/// legitimately render different audio, so the guard is per-engine drift, not
/// cross-engine equality.
///
/// Regenerate with `zig run src/gen_engine_goldens.zig` and paste over this
/// table; that file only exists because the rows are machine-measured.
pub const expected_engines = [_]Fingerprint{
    // argon4
    .{ .name = "kujamba karibu", .engine = .argon4, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 29986, .zero_crossings = 540, .rms_milli = 7630818, .envelope_sha256 = "4cc0508f07855d4b00593b63ad846d6869c4b186499bf46d4f17643fb16468c9", .wav_sha256 = "cbf067a4de5454bf5f26a5b5908aaa80304cea7256a55dc47b4ff135dceb3255" },
    .{ .name = "asante sana kijiji", .engine = .argon4, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 30210, .zero_crossings = 914, .rms_milli = 7734677, .envelope_sha256 = "175a12b8cf29ea4ed87289d727b703ae462ff08e0f92153c3003c0889c75d9f8", .wav_sha256 = "e3ac9d137b993a6f3daa9c1e42ac676474097add47bab2b64b77e240b6c1faf4" },
    .{ .name = "single syllable", .engine = .argon4, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 24294, .zero_crossings = 96, .rms_milli = 5497891, .envelope_sha256 = "f8257d45985a3a30f7eb4bf76376ac8eed0d1d16abd4bd3eadecf77d607a415a", .wav_sha256 = "c0fbe3f759e7336e1f47e3be1c714269d0ba8de3ddf5f352c6dee983c1d90377" },
    .{ .name = "punctuation and digits", .engine = .argon4, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 30069, .zero_crossings = 590, .rms_milli = 7789902, .envelope_sha256 = "0cd92231ed4b1f3bcd125a537cd9fe888c77223a00464db7028e16487804c5e5", .wav_sha256 = "ee66e39531f8d95fa614fce54b5e3958aa54c3e499c9ecb59757f4a140946af3" },
    .{ .name = "shuzi seed 0", .engine = .argon4, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 27305, .zero_crossings = 166, .rms_milli = 7326610, .envelope_sha256 = "92d6b1f2bfa7506d0fdf808c86b2dfe1d857b5b35f0b523bf80c9c78c9f78dc1", .wav_sha256 = "0b164510e8de83a83cf9c4cf560bc89764a72a8e2c756bc08fbd9cfaf2c9b5d7" },
    .{ .name = "shuzi seed 42", .engine = .argon4, .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 29683, .zero_crossings = 376, .rms_milli = 6901895, .envelope_sha256 = "c83d14758e7d0b7396b35d9e272640ad7a17f22db0aeb8766fa196faa32447bf", .wav_sha256 = "b2146ecbe664ea18dd90c17b58b532c3fb53cf47ebfa8f4b708e11938deb7e40" },
    .{ .name = "shuzi seed 1234567", .engine = .argon4, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 28388, .zero_crossings = 90, .rms_milli = 6132016, .envelope_sha256 = "290f0edd71134c5909328c0c887652401085a2071d515773f01ad2b097ecac37", .wav_sha256 = "bcaca46ceea8a89366d7fa576c01db51e38d5781c6f40fa7b7b616564124d40e" },
    // astra
    .{ .name = "kujamba karibu", .engine = .astra, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 28353, .zero_crossings = 360, .rms_milli = 8022657, .envelope_sha256 = "406863b4ae0181fec998d7bfd512e2626176893997ead29377e26b1be5fb5d74", .wav_sha256 = "4298a198c143f96913cc8586f3a58b4b2e4abf439312aec53b12d35c69a2a3ec" },
    .{ .name = "asante sana kijiji", .engine = .astra, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 29182, .zero_crossings = 434, .rms_milli = 8116755, .envelope_sha256 = "930a787687bdeded3b9881fc7374edc55652792afa725e76e806339f15454b08", .wav_sha256 = "809e4d5701918e03e23109902b5f75dcdc4614c3dc7aa6acd6d5dbf01170a8b6" },
    .{ .name = "single syllable", .engine = .astra, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 18944, .zero_crossings = 38, .rms_milli = 7337805, .envelope_sha256 = "8877c4f41b7fdc9065f524c52180bd509c7fec52a9a2a59f95ea01875014eebc", .wav_sha256 = "394f890956308a0aa700ee35960af6ebd48e4c460365626cdbb0577a0c5d8efb" },
    .{ .name = "punctuation and digits", .engine = .astra, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 27510, .zero_crossings = 396, .rms_milli = 8086585, .envelope_sha256 = "728b1d8887cd91b71793f2f40f51584de9640d503b5ed1f17ce641e2ed959fcc", .wav_sha256 = "e67dafc745187836eb02499cf27b2b60455d16eb3ce5517cf093fae556fa89bf" },
    .{ .name = "shuzi seed 0", .engine = .astra, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 21479, .zero_crossings = 40, .rms_milli = 8352160, .envelope_sha256 = "5800dbb2c0e6efedd66dc16b25bed24cd2f6c88275759fee0e4a88e0f52480fc", .wav_sha256 = "6fb0d89abee493cdb1103c38eefe7bca6f14c4e7dc7c4ec11f93b495dfe66d68" },
    .{ .name = "shuzi seed 42", .engine = .astra, .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 23753, .zero_crossings = 150, .rms_milli = 7803998, .envelope_sha256 = "f483ff81c33f0599bd2a494de067a2798809755c2195ab0eb0e1ae96f7eb938b", .wav_sha256 = "2035ae5723ce4a0c7f0934487370e107446f6c585b3032d34f713a606307bbb1" },
    .{ .name = "shuzi seed 1234567", .engine = .astra, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 22593, .zero_crossings = 34, .rms_milli = 7949539, .envelope_sha256 = "99b89f8a93f02a890b4dafc11d5fc6adfdf32adaae2f6dd82d9718ffd5d752dc", .wav_sha256 = "8c60e109176409ca4940f0f182137fb1b349d5db0e2b497ebc4e8b9b4e96bb26" },
    // fable
    .{ .name = "kujamba karibu", .engine = .fable, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 27573, .zero_crossings = 3670, .rms_milli = 6350278, .envelope_sha256 = "8d5183f9af87dd9d2e8bd05dc3024500003a6da501de85f44459d0fc346cb0e4", .wav_sha256 = "d0dde7a5f7b73469ce9bc763018cf48f1b7d8f00b4293dc80103010bce77e0fc" },
    .{ .name = "asante sana kijiji", .engine = .fable, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 27613, .zero_crossings = 5688, .rms_milli = 6717711, .envelope_sha256 = "9cdc877e1fdb79c559512ca4a3144ddc0f4f886dfe3eb14eb2129c4830b0e140", .wav_sha256 = "8b41ddc44d9fca8868fadde0da20a02e8387ef1faa9db4e0dc6d200212a9b4cb" },
    .{ .name = "single syllable", .engine = .fable, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 20399, .zero_crossings = 608, .rms_milli = 6325902, .envelope_sha256 = "adf60a56780a7dc44ec9962c899ecf2c2bcccf86cb8433326af94a307f0a5150", .wav_sha256 = "ad2ab19f15886bf87142acde953190ba1e830e81ada8618870c4e917f08df128" },
    .{ .name = "punctuation and digits", .engine = .fable, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 26968, .zero_crossings = 3706, .rms_milli = 6420664, .envelope_sha256 = "dd764c75d9ea936e181ea0552a24850961bd82e7f773ad43d8cedd46c1995730", .wav_sha256 = "a5632660f1b65a8931e96a2cbcdf5b115bd965bdf2dd1038d17167a2157ac3ea" },
    .{ .name = "shuzi seed 0", .engine = .fable, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 17568, .zero_crossings = 530, .rms_milli = 5964317, .envelope_sha256 = "4e660be01c0a2a543d630f1ad8242395926311336ee91d44ac2ed9d0f0ec972b", .wav_sha256 = "cbe36cfbb03bd1a3e98291700de1423de52adf2964261a33fc05e2469911c46a" },
    .{ .name = "shuzi seed 42", .engine = .fable, .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 23303, .zero_crossings = 3336, .rms_milli = 6901176, .envelope_sha256 = "c7ee65ea329eead6d4924792cd5bf4578cd4f88a3b8aa1616fe0f940c2184fed", .wav_sha256 = "1eb1a3416a7134de50d240f6c2017779a684a586f40b1a1d4d5372aead7dce08" },
    .{ .name = "shuzi seed 1234567", .engine = .fable, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 21628, .zero_crossings = 424, .rms_milli = 7770880, .envelope_sha256 = "48bbf97ccbe34f7d7fe6e21f4dd7822f3f3ed5a0c4a9c96d70e42361d67f62bd", .wav_sha256 = "370c3b0b17d46bcb47fe583283f59bea5070dfaee8b6dac3124bbeed6a8a8e39" },
    // gemini38
    .{ .name = "kujamba karibu", .engine = .gemini38, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 18975, .zero_crossings = 796, .rms_milli = 2568370, .envelope_sha256 = "c1f46c089bc0e95e12ca576e66c4005288c5e25fb43bc94780e87845178959ab", .wav_sha256 = "a2b4817759f45304218b8d4561cb39637638c5ae28643bc2bee3eb1701f31736" },
    .{ .name = "asante sana kijiji", .engine = .gemini38, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 21856, .zero_crossings = 1396, .rms_milli = 2544694, .envelope_sha256 = "9933cf570d3a0bae3886a31096050147ae0a327c278312a4ec7c5ff20a091409", .wav_sha256 = "7c7ef82cc8b9f544198f50f0161714167ef72307e40412d39aa728a6b0180e98" },
    .{ .name = "single syllable", .engine = .gemini38, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 11022, .zero_crossings = 70, .rms_milli = 2230465, .envelope_sha256 = "e76fec90e1772f6f04acc9ecac6514e6fd2978d3217f75c494fe5f8c0b189113", .wav_sha256 = "6ec8d71e64aa43b0fa8c411ae9c4d49c5c75d803575ba929fea4276547b02590" },
    .{ .name = "punctuation and digits", .engine = .gemini38, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 19547, .zero_crossings = 824, .rms_milli = 2588646, .envelope_sha256 = "1b418c8747436dddb80a57f29cac402071cef1c5b6b6bf7bad950b3d20b897d5", .wav_sha256 = "aa9a83fd7e3dd911f7974418b0b9dd87842104e3cedc58d4e23d92b85cb4927a" },
    .{ .name = "shuzi seed 0", .engine = .gemini38, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 14969, .zero_crossings = 232, .rms_milli = 2609532, .envelope_sha256 = "962100be43f2738724118d0590ddc2653305e665164ca4bba36f2168fa24b262", .wav_sha256 = "02e5c6196602d08b3019690f8d6d6ee3ce2d22a1b2ddc93bf54ea16ecf9e999e" },
    .{ .name = "shuzi seed 42", .engine = .gemini38, .kind = .shuzi, .input = "42", .items = 0, .samples = 37044, .peak = 19716, .zero_crossings = 648, .rms_milli = 2464258, .envelope_sha256 = "27b49a956e25d373e9278f817c8416119425f463ca15d1c26de6b494f705cb82", .wav_sha256 = "b4f340de6019945b3096c467f2bb3536ae0367ceb9584d58722508397172df0f" },
    .{ .name = "shuzi seed 1234567", .engine = .gemini38, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 14470, .zero_crossings = 150, .rms_milli = 2675549, .envelope_sha256 = "31ecf53b2c2ffd4af9dc36b90f750cfc6ddb4513dca6ecffcb801897a1a77b63", .wav_sha256 = "11d352d67e8fa78199d896c1cea6e0c577b7fc4d556152b9b9120f065e001c0f" },
    // gutphysics
    .{ .name = "kujamba karibu", .engine = .gutphysics, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 30363, .zero_crossings = 506, .rms_milli = 5986684, .envelope_sha256 = "7e58aaaca095a43bf1fe886f685a60ad7a350f7fdb32ce24aff5495cceaef348", .wav_sha256 = "b649a44a194105bbbe18dcd49c119e478ba8ba4a4af4ced080be834d9493622b" },
    .{ .name = "asante sana kijiji", .engine = .gutphysics, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 30566, .zero_crossings = 740, .rms_milli = 6010577, .envelope_sha256 = "e859b8d1f21428b926c64ef3d29d95cad6cdcb40c4ad7067968cf178e66734f9", .wav_sha256 = "0cdc96d4f1da759cf14e69dd107342d6fee8a1b305957be888b10d139525489d" },
    .{ .name = "single syllable", .engine = .gutphysics, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 10408, .zero_crossings = 56, .rms_milli = 2760633, .envelope_sha256 = "973974af21ee04e15e923fb5342876d6ac552ad664c79ac9c0930fbdb01bda35", .wav_sha256 = "9305ba757e8b99fd2489984218ed6b85c847a3e6d82790dfa3d4b2de5a6081f6" },
    .{ .name = "punctuation and digits", .engine = .gutphysics, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 30299, .zero_crossings = 482, .rms_milli = 6009658, .envelope_sha256 = "b9b4ac13b88d37acd2197f94a57341dbf1c4b4e1d3a3c8c07d2307e169b98af7", .wav_sha256 = "7a241463cb7f8872e49808acf09cdb723878cf365f052378522f6dc0081b024c" },
    .{ .name = "shuzi seed 0", .engine = .gutphysics, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 26518, .zero_crossings = 132, .rms_milli = 6834683, .envelope_sha256 = "1ddaa10f1cba6382e8dd325af3b79d077ca08e19d0241722b2ca1e25c1ff5582", .wav_sha256 = "e4e331487eb7955ba84d9b645a1022aff60a256bb56e263d746b279fe9d45263" },
    .{ .name = "shuzi seed 42", .engine = .gutphysics, .kind = .shuzi, .input = "42", .items = 0, .samples = 39249, .peak = 19381, .zero_crossings = 244, .rms_milli = 3565428, .envelope_sha256 = "835944324de7ae5e3dff5e75dde372109c78fbd8c8a9f8dbb27017b56fd91157", .wav_sha256 = "227f50abee92c5eb15ef3c8ae69566526cf93befb6e2b2d82c5237eddb0eff35" },
    .{ .name = "shuzi seed 1234567", .engine = .gutphysics, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 13371, .zero_crossings = 78, .rms_milli = 3278511, .envelope_sha256 = "acf3872cdb1b7268e6f582d5a03837491b3d2a0f0222c291633c8ce27a7c9e18", .wav_sha256 = "88d31701483940a76f36fe38c2b2a8ab21e997b49f6baf468688049475840b5b" },
    // grok47
    .{ .name = "kujamba karibu", .engine = .grok47, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 27751, .zero_crossings = 2294, .rms_milli = 4715630, .envelope_sha256 = "8da6958de17ed58ff6681a38b271ccb5aa036fcae2b6486638efc6283a2b78d4", .wav_sha256 = "3e0805bf6314de12822dff0c0197fdb3a2860cdd9bd3b10a2b29a873095f6141" },
    .{ .name = "asante sana kijiji", .engine = .grok47, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 27651, .zero_crossings = 3554, .rms_milli = 4323263, .envelope_sha256 = "1f80a897f2ccb0499ba9197c319b7c1ad0f4fe543340f148f1383ce551b22094", .wav_sha256 = "30e4ebecde04a5ef3182cca86e6e75fd0d426db49de906da352c64c3db92a8fb" },
    .{ .name = "single syllable", .engine = .grok47, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 11579, .zero_crossings = 292, .rms_milli = 3334161, .envelope_sha256 = "5d729780768389910773873ff769e5bc30385a7b61b27ca1fda965a2f02f00c5", .wav_sha256 = "d7f9cbbdbcc721ff6f75868770d95a8058f7235d4c116984bc17c423ad2d936d" },
    .{ .name = "punctuation and digits", .engine = .grok47, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 27055, .zero_crossings = 2416, .rms_milli = 4688506, .envelope_sha256 = "bf6248a05a0fcf8b23ebb10d8d313f4fcbfc19316326e405e336979e1fa0c0db", .wav_sha256 = "c0f63a86e435e9a9c7e1be7aacddc9c09e2643551c2327964a2ad18e0e421abd" },
    .{ .name = "shuzi seed 0", .engine = .grok47, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 25858, .zero_crossings = 448, .rms_milli = 5602405, .envelope_sha256 = "a35189728c4d2c88f46f9dc010cbfe1a9166c651dc8d61eacf8583f9066937ed", .wav_sha256 = "678329f3e2169c809de55eda965954497ce39f4f6fa21ac5d041f5d2f711acf9" },
    .{ .name = "shuzi seed 42", .engine = .grok47, .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 27168, .zero_crossings = 1094, .rms_milli = 4280234, .envelope_sha256 = "45bde9b62892fb9e35b533b257268dd4e359f2b144939e22a2d8e7cef74db60f", .wav_sha256 = "f6cd87c0769a40f0bc2aef29043f268152861895f5f1a4a53a5d7c3b0794677b" },
    .{ .name = "shuzi seed 1234567", .engine = .grok47, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 18252, .zero_crossings = 398, .rms_milli = 4097970, .envelope_sha256 = "a91324608110fbc4d73e764acf6bc697735efe93f18bfb181e558f81a4dc7337", .wav_sha256 = "5ac58c6a329e8e3eda8c2ed52dc29bae4bc7932806c17e707075e1956dfc37cc" },
    // kimi3
    .{ .name = "kujamba karibu", .engine = .kimi3, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 31129, .zero_crossings = 588, .rms_milli = 6432694, .envelope_sha256 = "f533c4915adef046cf0765d785d24c5db10f2c3163c8471ca9edf8314edfc70a", .wav_sha256 = "0e51ce8907449f915126eace18afef670242139c9eb190613ee25c1b5abf8a9a" },
    .{ .name = "asante sana kijiji", .engine = .kimi3, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 31129, .zero_crossings = 868, .rms_milli = 5598021, .envelope_sha256 = "0b6ab93511d76dda81f8649d0a7e4c9c83cf46d5f3e46288a32c5dedd3a48061", .wav_sha256 = "2fcaaf02957c2e62f9c6a13c118d3d15267d4f21a254a58e98bb279359df378e" },
    .{ .name = "single syllable", .engine = .kimi3, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 20249, .zero_crossings = 50, .rms_milli = 5627401, .envelope_sha256 = "f7e938bf1e6780640243269cd3c5f4394a36bce93482a2428134114a4aec54f0", .wav_sha256 = "253a6b9ce5f66ad21342c9bdfec2f5a1d1c0e05d4cf83c009102d5a0ddabc089" },
    .{ .name = "punctuation and digits", .engine = .kimi3, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 31129, .zero_crossings = 540, .rms_milli = 6616334, .envelope_sha256 = "b4be0744c785c18c02a84b53c992a6e969960e70d3ee3e7c10a004d18fa95e0b", .wav_sha256 = "0c3494c81400fbb39d1b730c54b2c3dcc975934ab81655bfd332cc47190993e3" },
    .{ .name = "shuzi seed 0", .engine = .kimi3, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 31129, .zero_crossings = 168, .rms_milli = 6982702, .envelope_sha256 = "0738cab75f6e3d14eb355c41e9894ca5125418e47c4239ad51d777636ca3b7f0", .wav_sha256 = "b60a369fcec1a6724bc0ffb637d6a802462c0cf9e1907a449391a2be82f7d207" },
    .{ .name = "shuzi seed 42", .engine = .kimi3, .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 31129, .zero_crossings = 332, .rms_milli = 6163666, .envelope_sha256 = "ff789ccec06c97572adae5c58e7e6eb32220698180a98ee9b3c93b5515a0c5e5", .wav_sha256 = "283b01f9d8cb6b6a02d7ff5f9b0d0ec84fef46209ab44870441a1c54f0fe6085" },
    .{ .name = "shuzi seed 1234567", .engine = .kimi3, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 31129, .zero_crossings = 72, .rms_milli = 6692813, .envelope_sha256 = "3a1b01a14384670e064d194c230a59cb314aba4f8361e99e3f990e865782cbf4", .wav_sha256 = "fdf4895c1cdd08d011135b75288f6f45a6cee845fb375177ab51664773645ea8" },
    // mistral4
    .{ .name = "kujamba karibu", .engine = .mistral4, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 31129, .zero_crossings = 1756, .rms_milli = 5243722, .envelope_sha256 = "57f267d9788c7400704098df1eef0364e73331dae8c0654249f7135d26a240b1", .wav_sha256 = "f6fb3adea136335e07a217c0e3d39b94f28968f11ffffca612d96fa375fdb28c" },
    .{ .name = "asante sana kijiji", .engine = .mistral4, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 31129, .zero_crossings = 2822, .rms_milli = 4656114, .envelope_sha256 = "30850e485c58eca4f81561336a4700ea4eb7380329fcae4dd33dc99ab902c643", .wav_sha256 = "dde14edac86d7514ab3f19315dd4e73fc567801b584fce70570f5d31e80f7113" },
    .{ .name = "single syllable", .engine = .mistral4, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 25208, .zero_crossings = 260, .rms_milli = 3840524, .envelope_sha256 = "8a4b1908391f95b2a6b3cbc6ff43e7c673076c3e8ced8185ebb34ae2dda7f7eb", .wav_sha256 = "41d183ab9af1851a1be12e23dc5def9a0674316f551bb8b145739f2ce37adee7" },
    .{ .name = "punctuation and digits", .engine = .mistral4, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 31129, .zero_crossings = 1842, .rms_milli = 5300514, .envelope_sha256 = "221ed6a893f7b335dfc6b00aeb77d6349b74050cdca557fc1eb05506e89a1993", .wav_sha256 = "46b4d5429c264457ec8fa174a75c013554acdb35b1b47a41a4e09d3c854767a6" },
    .{ .name = "shuzi seed 0", .engine = .mistral4, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 26048, .zero_crossings = 254, .rms_milli = 5107948, .envelope_sha256 = "ce9dbec8263ba6f8aa1fd1ddbad612039496089cc5eb0d8d48d72dc4c3a5d424", .wav_sha256 = "635d0297d1e7c1b5c1a71495b8c430dfdb26e68ab51ca3461eb45d953f8d790e" },
    .{ .name = "shuzi seed 42", .engine = .mistral4, .kind = .shuzi, .input = "42", .items = 0, .samples = 37044, .peak = 31129, .zero_crossings = 1338, .rms_milli = 4647417, .envelope_sha256 = "48359d60eb55a09a82cec0decccc1ebc83dc3c407eb7da58d92fc0d3221f4ed4", .wav_sha256 = "1441a65990877452746367b8a147542b5e7f2083b5dd50a25d9b9cfe81b5414c" },
    .{ .name = "shuzi seed 1234567", .engine = .mistral4, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 21506, .zero_crossings = 126, .rms_milli = 4711179, .envelope_sha256 = "3fa067bf7746a7f7cbc0456144c9e634c766c3ccb40e361729f608a68bc53751", .wav_sha256 = "19bc7017ea11659fbe8ac9a3a98411edbdd2f733036a491ab2bd91d1a44ad833" },
    // opus
    .{ .name = "kujamba karibu", .engine = .opus, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 28183, .zero_crossings = 992, .rms_milli = 6529839, .envelope_sha256 = "e9f54458d0ddf591eb888324e924154fdfe251fa6e0059333528a340a24e6895", .wav_sha256 = "39c6440619aa2a75ef8fdc38ce6480c48da30107cd38c07994087c30a28544e4" },
    .{ .name = "asante sana kijiji", .engine = .opus, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 28909, .zero_crossings = 2906, .rms_milli = 5985466, .envelope_sha256 = "a6e540d13112362d7a8147d0cc29327b88c151dc3c4cec14e9290867f3abcc64", .wav_sha256 = "598019ddadffd95c94bcd7eec3b374ea227fcd9f76e5f7eed2742b0fe33ead77" },
    .{ .name = "single syllable", .engine = .opus, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 13813, .zero_crossings = 170, .rms_milli = 3326607, .envelope_sha256 = "9e211dc90d3aeba562db8564fea597ba77bd06002a424a54eaec040774a1fa85", .wav_sha256 = "a7333caf38eec5590006af89220a0cbc26a8f1fd8a510f2e18166e22c9578f26" },
    .{ .name = "punctuation and digits", .engine = .opus, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 27599, .zero_crossings = 950, .rms_milli = 6615932, .envelope_sha256 = "b8278fc07171febcf5adc00caf330a25b04dfcdef5aca3f680691b99f6efcea0", .wav_sha256 = "5696fb9ad740b2e90b039bc9161b2e35a95c184db0d13538772ab0ec27a0c982" },
    .{ .name = "shuzi seed 0", .engine = .opus, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 24357, .zero_crossings = 230, .rms_milli = 4532825, .envelope_sha256 = "5f26c94930dcaa8e987c1bf5328a9d90f64b2564cc34d04e2ed7130fc9ae601f", .wav_sha256 = "dcdef3cfc045a643b5548182edad081a317f7bc3537a82549355ed66dedcb305" },
    .{ .name = "shuzi seed 42", .engine = .opus, .kind = .shuzi, .input = "42", .items = 0, .samples = 33957, .peak = 22294, .zero_crossings = 596, .rms_milli = 5877822, .envelope_sha256 = "5a27a5a122ac1abca07721aad11dd4bd05ddce416962922a4f86d6c7da37637b", .wav_sha256 = "a5913f706b6393302458dfc86d469c2c123fe44efb998f25f36fe6fa5dfef184" },
    .{ .name = "shuzi seed 1234567", .engine = .opus, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 20634, .zero_crossings = 160, .rms_milli = 4274980, .envelope_sha256 = "2eade4fc5bd79de9dd2703d601dbdd3c5c546d85d94ad7524ce5b602dc107805", .wav_sha256 = "cad39873caf47fdd5b26d4fbe3ef09a43e8cdcc376fcc6b3835a267eafbed797" },
    // sol61
    .{ .name = "kujamba karibu", .engine = .sol61, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 26029, .zero_crossings = 480, .rms_milli = 8097826, .envelope_sha256 = "71ac9edea4cc8866b3222a75dbe21e379a4d34254731cb56b6dd47e5752e8892", .wav_sha256 = "fd4e22d801740d400c2d3d8cff3778d2d10e0b2adfbb55d959f8979add2b6ae9" },
    .{ .name = "asante sana kijiji", .engine = .sol61, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 25739, .zero_crossings = 604, .rms_milli = 8289414, .envelope_sha256 = "7cac1201a3bd7e3c6e069c33fd8946f0a943f2a2211a14681ff43d0143faad6f", .wav_sha256 = "6928c6a7e0e0948c0796a0fda3bee530644bfbba830efc5f94e9b1eea5041fd9" },
    .{ .name = "single syllable", .engine = .sol61, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 22127, .zero_crossings = 44, .rms_milli = 7664444, .envelope_sha256 = "092beeb99c499b81afe017078899f70137d218787bb5838f1494f56c00cc97c2", .wav_sha256 = "ea0614ea30da2a561f723db8009bde212908f11e578d605738a8b0e8511626dc" },
    .{ .name = "punctuation and digits", .engine = .sol61, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 26223, .zero_crossings = 408, .rms_milli = 8050603, .envelope_sha256 = "bcaf9efba2e836a171ca32ee2750ce1fda847af3d0103bfa4c98d6236cbad229", .wav_sha256 = "0861235ec197d2478babc30f9838dd2bab93b80fe5295bf9f274b1b35ca833a8" },
    .{ .name = "shuzi seed 0", .engine = .sol61, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 22254, .zero_crossings = 134, .rms_milli = 8181442, .envelope_sha256 = "798b085f0a1d0e03c9117f095a3d4698db90d54119033a67fd4e2b42ae63c0be", .wav_sha256 = "e78fa2593759c72201aa4bb69b2b35024e91d5c6975c14715063d4f20a87ad69" },
    .{ .name = "shuzi seed 42", .engine = .sol61, .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 25736, .zero_crossings = 296, .rms_milli = 7898793, .envelope_sha256 = "36f6cef7eb91f8d68de60c5e050b8f8b20be50b284b967a033df8c13cb81be9c", .wav_sha256 = "146bde8670b20f90c1d9624abcec261d4c1254abbc65dee3e1b7dc9ac737049e" },
    .{ .name = "shuzi seed 1234567", .engine = .sol61, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 22727, .zero_crossings = 68, .rms_milli = 7668315, .envelope_sha256 = "63e922ee01878680fe62b8a8e2712f6f801a35b99f1f95e6def901e056d650ad", .wav_sha256 = "9ddd9972042e678d30c21b53845aafb8e8da029539fd2d7465ce7647877f2095" },
    // sonnet
    .{ .name = "kujamba karibu", .engine = .sonnet, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 30931, .zero_crossings = 3882, .rms_milli = 7433186, .envelope_sha256 = "0403eb7a29001dcc2c165c154583e54a8430cd084e2a3247cbd660780630fc7b", .wav_sha256 = "4835e1d7be92bdbd706487b3e34efa5130f8ab944b749d7edfa06163bda67442" },
    .{ .name = "asante sana kijiji", .engine = .sonnet, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 31107, .zero_crossings = 8078, .rms_milli = 7004470, .envelope_sha256 = "c8d060c354b778b329b477d8e78f8c2aa3f5a6b5cc103f1a5af30c971358e5af", .wav_sha256 = "c26a7f655bec00b73c5d9bb352d33d8d48b2629e0a2e75b3e0615ef94bf19241" },
    .{ .name = "single syllable", .engine = .sonnet, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 30040, .zero_crossings = 622, .rms_milli = 7194811, .envelope_sha256 = "e11322102a6019d12cb58ed02b1ea588b4fee084720e2fc0649107e788bc46b5", .wav_sha256 = "ddc798b152da85bd76ece014767c00ce25707428df40144af69a6f9c41ac4395" },
    .{ .name = "punctuation and digits", .engine = .sonnet, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 31128, .zero_crossings = 3846, .rms_milli = 7177126, .envelope_sha256 = "04a7e5d13e342225eb80dc3ca6ad4c969372cf4247a98be20dd0da6eeb1b513b", .wav_sha256 = "7ea9f9dff4f8a4adeef1b3843389ad259260735c34f0684caf41a3c8d077f274" },
    .{ .name = "shuzi seed 0", .engine = .sonnet, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 30900, .zero_crossings = 640, .rms_milli = 11064764, .envelope_sha256 = "adc2f23b83ebc07303c9133432b33278ff268882220a6807895310f6e8b00ca6", .wav_sha256 = "e1542d0c8e53356e1d4164e2b7e3d23a425cd230a7754ac9ce497f62ec75ae37" },
    .{ .name = "shuzi seed 42", .engine = .sonnet, .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 31129, .zero_crossings = 2212, .rms_milli = 13382513, .envelope_sha256 = "659a4dae47980eb6e70219210c75c2eabb77eef50a51769becde27dbb1213c97", .wav_sha256 = "983053678233f8cb87e6637cd89e22b5b7dbb44d1c4591075a5af9a7e4c098af" },
    .{ .name = "shuzi seed 1234567", .engine = .sonnet, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 20491, .zero_crossings = 550, .rms_milli = 4629417, .envelope_sha256 = "66d3d9c1e559effda2f1d221b0579ce207cf5a4fade5f75db79f891e0e5c5f18", .wav_sha256 = "ac5f70a4d0383fc50dfcedcc462cf6c61cd7c2d63149f072a170fbb0d0714f8a" },
    // swe2
    .{ .name = "kujamba karibu", .engine = .swe2, .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 24150, .zero_crossings = 762, .rms_milli = 3476000, .envelope_sha256 = "92fe8d6422b3b75f7a6608932cf166f73f98e3994bd64a8161571ac859906d97", .wav_sha256 = "76bb10a8866a7a9eda008260a1eeaf8c3d6b24b20a0b50e956832eb4bd2c0ee9" },
    .{ .name = "asante sana kijiji", .engine = .swe2, .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 24673, .zero_crossings = 1010, .rms_milli = 3400639, .envelope_sha256 = "a19b7b7d4a78fe1b14073fdb79db9bdf3b4a65d9c87b4c557cee80d2538c049c", .wav_sha256 = "18cfee0c4528dcd10d5b785802fa6cbddb38c0ee499acfa8fff80490fd415cf8" },
    .{ .name = "single syllable", .engine = .swe2, .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 13951, .zero_crossings = 126, .rms_milli = 2951905, .envelope_sha256 = "57228a6e9351dc398b6ed23b6fbb9e444b1860b2b930afd7fe775e6842464169", .wav_sha256 = "315682e36bc45c071d9e5d1ae526eb4703f61d8b49cbf948de13704953a03f5a" },
    .{ .name = "punctuation and digits", .engine = .swe2, .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 24397, .zero_crossings = 654, .rms_milli = 3348249, .envelope_sha256 = "e9524bd6f61234a9c3721d52584fdef8666ee9e8d2edbfb5f6f80070a6cdda8d", .wav_sha256 = "3f20c84945fadeddc3fe1573d3f1fc391fd14ba8b02d1f59cf84a6705f7f1ae5" },
    .{ .name = "shuzi seed 0", .engine = .swe2, .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 15557, .zero_crossings = 184, .rms_milli = 3710772, .envelope_sha256 = "6f123c3fb9d92c8941a0a781978734236417c5962de516da11816edceb5edb8a", .wav_sha256 = "0b4cb1f8017be6e1f341baf7eb5c3ac8d2906125533f8e39a5b208a2d316a58a" },
    .{ .name = "shuzi seed 42", .engine = .swe2, .kind = .shuzi, .input = "42", .items = 0, .samples = 39249, .peak = 16981, .zero_crossings = 780, .rms_milli = 2939058, .envelope_sha256 = "c7e92b4c9cea9be4afdeae40474d8e3f3ca2686522b7b5244ad3fd5543ccd693", .wav_sha256 = "5b0ff4e6890bb7a50c3cf78a2b982d6d813e3131273155b80c6f19c4cf1c0059" },
    .{ .name = "shuzi seed 1234567", .engine = .swe2, .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 12504, .zero_crossings = 134, .rms_milli = 2973393, .envelope_sha256 = "025f5ffc516d7e0f7a58232d96408186632308c0d8b83ac94497cd4462379de5", .wav_sha256 = "68898945f01109b756600961fe9f2728ac79153550c2f85fc6690dcb572f6bb9" },
};

/// A fingerprint as measured right now, ready to paste into `expected`.
pub const Measured = struct {
    name: []const u8,
    engine: registry.Id = .stock,
    kind: Kind,
    input: []const u8,
    items: u32,
    samples: u32,
    peak: u32,
    zero_crossings: u32,
    rms_milli: i64,
    envelope_sha256: [64]u8,
    wav_sha256: [64]u8,
};

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

/// The PCM data chunk of a canonical 44-byte-header mono WAV, as raw bytes.
/// Read through `sampleAt` rather than `bytesAsSlice` so no alignment
/// assumption sneaks in.
const WavHeaderLen = 44;

fn sampleCount(data: []const u8) usize {
    return data.len / 2;
}

fn sampleAt(data: []const u8, i: usize) i16 {
    return std.mem.readInt(i16, data[2 * i ..][0..2], .little);
}

/// Level, peak and zero crossings of the rendered PCM.
const WaveStats = struct {
    peak: u32,
    zero_crossings: u32,
    rms_milli: i64,
};

fn waveStats(data: []const u8) WaveStats {
    const n = sampleCount(data);
    var acc: f64 = 0;
    var peak: u32 = 0;
    var zero_crossings: u32 = 0;
    var prev: i16 = 0;
    for (0..n) |i| {
        const v = sampleAt(data, i);
        const f: f64 = @floatFromInt(v);
        acc += f * f;
        peak = @max(peak, @as(u32, @intCast(@abs(@as(i32, v)))));
        if (i != 0 and (v >= 0) != (prev >= 0)) zero_crossings += 1;
        prev = v;
    }
    const rms = if (n == 0) 0.0 else std.math.sqrt(acc / @as(f64, @floatFromInt(n)));
    return .{
        .peak = peak,
        .zero_crossings = zero_crossings,
        .rms_milli = @intFromFloat(rms * 1000.0),
    };
}

/// SHA-256 over the per-window RMS envelope, each window rounded to a whole
/// unit. A last-ULP float wobble cannot move a window's integer RMS; a real
/// change to the waveform moves many of them.
fn envelopeHash(alloc: std.mem.Allocator, data: []const u8) !struct { hex: [64]u8, windows: u32 } {
    const n = sampleCount(data);
    var env: std.ArrayList(u32) = .empty;
    defer env.deinit(alloc);
    var off: usize = 0;
    while (off < n) {
        const count = @min(envelope_window_samples, n - off);
        var acc: f64 = 0;
        for (0..count) |k| {
            const f: f64 = @floatFromInt(sampleAt(data, off + k));
            acc += f * f;
        }
        const w = std.math.sqrt(acc / @as(f64, @floatFromInt(count)));
        try env.append(alloc, @intFromFloat(w));
        off += count;
    }
    return .{
        .hex = sha256Hex(std.mem.sliceAsBytes(env.items)),
        .windows = @intCast(env.items.len),
    };
}

/// Render `fp`'s input on `fp.engine` and measure it. `wav` is owned by the
/// caller. Identity knobs: fingerprints pin each engine's *default* voice —
/// the same thing the judged baselines rendered.
pub fn measure(alloc: std.mem.Allocator, fp: Fingerprint) !struct { wav: []u8, out: Measured } {
    const knobs = registry.defaultKnobs(fp.engine);
    const wav = switch (fp.kind) {
        .phrase => try registry.renderPhraseWavWith(alloc, fp.input, knobs),
        .shuzi => try registry.renderShuziWavWith(alloc, try std.fmt.parseInt(u64, fp.input, 10), knobs),
    };
    errdefer alloc.free(wav);

    var items: u32 = 0;
    if (fp.kind == .phrase) {
        items = @intCast(try registry.planItemCount(alloc, fp.input, fp.engine));
    }

    // the data chunk is 2 bytes per mono sample; the header is a fixed 44
    const pcm = wav[@min(WavHeaderLen, wav.len)..];
    const stats = waveStats(pcm);
    const env = try envelopeHash(alloc, pcm);

    return .{ .wav = wav, .out = .{
        .name = fp.name,
        .engine = fp.engine,
        .kind = fp.kind,
        .input = fp.input,
        .items = items,
        .samples = @intCast(sampleCount(pcm)),
        .peak = stats.peak,
        .zero_crossings = stats.zero_crossings,
        .rms_milli = stats.rms_milli,
        .envelope_sha256 = env.hex,
        .wav_sha256 = sha256Hex(wav),
    } };
}

/// One measured row, ready to paste into an `expected` table.
pub fn formatRow(alloc: std.mem.Allocator, out: *std.ArrayList(u8), fp: Fingerprint) !void {
    const m = try measure(alloc, fp);
    defer alloc.free(m.wav);
    var ebuf: [48]u8 = undefined;
    const etag = if (m.out.engine == .stock) "" else std.fmt.bufPrint(&ebuf, ".engine = .{s}, ", .{registry.name(m.out.engine)}) catch "";
    try out.print(alloc, "    .{{ .name = \"{s}\", {s}.kind = .{s}, .input = \"{s}\", .items = {d}, .samples = {d}, .peak = {d}, .zero_crossings = {d}, .rms_milli = {d}, .envelope_sha256 = \"{s}\", .wav_sha256 = \"{s}\" }},\n", .{
        m.out.name, etag,                 @tagName(m.out.kind), m.out.input,           m.out.items,      m.out.samples,
        m.out.peak, m.out.zero_crossings, m.out.rms_milli,      m.out.envelope_sha256, m.out.wav_sha256,
    });
}

/// The `expected` table as a copy-pasteable block, for re-baselining.
pub fn formatBaseline(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(alloc, "pub const expected = [_]Fingerprint{\n");
    for (expected) |fp| try formatRow(alloc, out, fp);
    try out.appendSlice(alloc, "};\n");
}

// --------------------------------------------------------------------------
// tests
// --------------------------------------------------------------------------

const testing = std.testing;

/// Measure every row of one table against the engine it names; report rows
/// that drifted. Returns the drift count.
fn checkTable(alloc: std.mem.Allocator, fps: []const Fingerprint, report: *std.ArrayList(u8)) !usize {
    var drift: usize = 0;
    for (fps) |fp| {
        const m = try measure(alloc, fp);
        defer alloc.free(m.wav);
        const got = m.out;
        const label = if (fp.engine == .stock) fp.name else blk: {
            break :blk try std.fmt.allocPrint(alloc, "{s}: {s}", .{ registry.name(fp.engine), fp.name });
        };
        defer if (fp.engine != .stock) alloc.free(label);

        if (got.items != fp.items or
            got.samples != fp.samples or
            got.peak != fp.peak or
            got.zero_crossings != fp.zero_crossings or
            !std.mem.eql(u8, &got.envelope_sha256, fp.envelope_sha256))
        {
            drift += 1;
            try report.print(alloc, "  {s}\n", .{label});
            try report.print(alloc, "    items        {d: >8} (expected {d})\n", .{ got.items, fp.items });
            try report.print(alloc, "    samples      {d: >8} (expected {d})\n", .{ got.samples, fp.samples });
            try report.print(alloc, "    peak         {d: >8} (expected {d})\n", .{ got.peak, fp.peak });
            try report.print(alloc, "    zero_xing    {d: >8} (expected {d})\n", .{ got.zero_crossings, fp.zero_crossings });
            try report.print(alloc, "    envelope     {s} (expected {s})\n", .{ got.envelope_sha256, fp.envelope_sha256 });
            continue;
        }

        // tolerant by design: this one is only a coarse level check, and the
        // measured codegen spread is 1 unit
        const d = got.rms_milli - fp.rms_milli;
        if (d > rms_milli_tolerance or -d > rms_milli_tolerance) {
            drift += 1;
            try report.print(alloc, "  {s}\n    rms_milli    {d: >8} (expected {d}, +/-{d})\n", .{
                label, got.rms_milli, fp.rms_milli, rms_milli_tolerance,
            });
        }
    }
    return drift;
}

test "the synth still renders audio matching this project's golden fingerprints" {
    const alloc = testing.allocator;
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(alloc);

    var drift = try checkTable(alloc, &expected, &report);
    drift += try checkTable(alloc, &expected_engines, &report);

    if (drift == 0) return;

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(alloc);
    try msg.appendSlice(alloc, "synth golden fingerprints no longer match:\n\n");
    try msg.appendSlice(alloc, report.items);
    try msg.appendSlice(alloc,
        \\
        \\If you changed an engine on purpose, re-baseline: `zig run
        \\src/gen_engine_goldens.zig` prints the per-engine table (paste it over
        \\`expected_engines`); for the stock engine, paste this over `expected`:
        \\
        \\
    );
    var baseline: std.ArrayList(u8) = .empty;
    defer baseline.deinit(alloc);
    try formatBaseline(alloc, &baseline);
    try msg.appendSlice(alloc, baseline.items);
    try msg.appendSlice(alloc,
        \\
        \\If you did NOT change the synth, the guard itself is miscalibrated: the
        \\asserted fields are supposed to be exact across optimization modes and
        \\platforms. Do not paper over it by loosening a tolerance — find out why
        \\they moved. See the header comment for how these were chosen.
        \\
    );
    std.debug.print("{s}", .{msg.items});
    return error.SynthGoldenFingerprintMismatch;
}

test "the exact rendered bytes have not changed since the baseline was taken" {
    // Not an equality check against `wav_sha256` — that is deliberately not
    // asserted, because it is not stable across optimization modes. This only
    // reports the current bytes so a drift is visible in the log, which is how
    // the "exact hash is not a stable invariant" claim in the header was
    // discovered in the first place.
    const alloc = testing.allocator;
    for (expected) |fp| {
        const m = try measure(alloc, fp);
        defer alloc.free(m.wav);
        if (!std.mem.eql(u8, &m.out.wav_sha256, fp.wav_sha256)) {
            std.debug.print("note: exact bytes for '{s}' moved ({s} -> {s}); this is expected across build configs and is not asserted\n", .{
                fp.name, fp.wav_sha256, m.out.wav_sha256,
            });
        }
    }
}

test "the golden table is complete and internally consistent" {
    // A blank expected value is a re-baselining bug waiting to happen, not a
    // passing test: the check above would compare against "".
    for (&[_][]const Fingerprint{ &expected, &expected_engines }) |fps| {
        for (fps, 0..) |fp, i| {
            if (fp.envelope_sha256.len != 64 or fp.wav_sha256.len != 64) {
                std.debug.print("golden: '{s}' has a {d}/{d}-char hash, want 64/64 (re-baseline?)\n", .{
                    fp.name, fp.envelope_sha256.len, fp.wav_sha256.len,
                });
                return error.IncompleteGoldenFingerprint;
            }
            for (fp.envelope_sha256) |c| {
                if (!std.ascii.isHex(c)) {
                    std.debug.print("golden: '{s}' envelope hash is not hex: {c}\n", .{ fp.name, c });
                    return error.IncompleteGoldenFingerprint;
                }
            }
            // (engine, name) is the copy-paste key, so it has to be unique
            for (fps[0..i]) |earlier| {
                if (earlier.engine == fp.engine and std.mem.eql(u8, earlier.name, fp.name)) {
                    std.debug.print("golden: duplicate fingerprint '{s}'\n", .{fp.name});
                    return error.DuplicateGoldenFingerprint;
                }
            }
        }
    }
    // every non-stock engine covers every baseline input
    try testing.expectEqual(expected.len * (registry.all.len - 1), expected_engines.len);
    for (expected_engines) |fp| {
        try testing.expect(fp.engine != .stock);
    }
}
