# HRTF table

`src/client/data/hrtf_48k.bin` holds the head-related impulse responses SR
Client's positional audio uses, prepared the same way browsers prepare the
WebAudio "HRTF" panner that Krunker's sounds go through (Howler's spatial
plugin defaults to `panningModel: "HRTF"`).

- `Composite.wav`: the "Composite" subject of the IRCAM Listen HRTF database,
  as distributed with WebKit (`Source/WebCore/platform/audio/resources`) and
  Chromium.
- `build_hrtf.py`: resamples to 48 kHz, extracts frame delays, truncates and
  interpolates the kernels like WebKit/Chromium's HRTFElevation and
  HRTFKernel. Needs Python 3 with numpy and scipy.

Rebuild: `python3 build_hrtf.py Composite.wav ../../src/client/data/hrtf_48k.bin`
