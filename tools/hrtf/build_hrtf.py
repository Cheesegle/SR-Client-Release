#!/usr/bin/env python3
"""Builds SR Client's HRTF table: the WebAudio "HRTF" panner's kernels.

Krunker plays every positional sound through Howler, whose spatial plugin
uses a WebAudio PannerNode with panningModel "HRTF". Browsers build that
panner from the IRCAM Listen "Composite" subject (Composite.wav, shipped in
WebKit and Chromium). This script repeats the browser's preparation
(HRTFElevation / HRTFKernel / FFTFrame):

  * 240 impulse responses: 24 azimuths (15 degree steps) x 10 elevations
    (-45..90), 256 frames at 44.1 kHz, resampled to 48 kHz (SR's mixer rate)
  * each response loses its average group delay, which becomes a frame delay
    applied by a delay line; it is truncated to 256 frames with a 10 frame
    fade-out (fftSize 512 at 48 kHz)
  * 8 kernels per 15 degrees: the 7 between two measured azimuths are
    interpolated in the frequency domain (magnitude in dB, unwrapped phase)

Output (little endian): "SRHRTF1\\0", u32 elevations, u32 azimuths,
u32 kernel_frames, u32 sample_rate, then per elevation, azimuth and ear
(left, right) the f32 frame delay, then the f32 kernels in the same order.

Usage: python3 build_hrtf.py Composite.wav ../../src/client/data/hrtf_48k.bin
"""
import struct, sys, wave
import numpy as np
from scipy.signal import resample_poly

SOURCE_RATE, RATE = 44100, 48000
RAW_AZIMUTHS, INTERP, ELEVATIONS = 24, 8, list(range(-45, 91, 15))
ELEVATION_TABLE = [0, 15, 30, 45, 60, 75, 90, 315, 330, 345]
MAX_ELEVATIONS = [90, 45, 60, 45, 75, 45, 60, 45, 75, 45, 60, 45, 75, 45, 60, 45, 75, 45, 60, 45, 75, 45, 60, 45]
FFT = 512            # HRTFPanner::FftSizeForSampleRate(48000)
HALF = FFT // 2

def to_packed(spectrum):
    """numpy rfft (n/2+1 bins) -> FFTFrame layout: real[0]=DC, imag[0]=Nyquist."""
    half = len(spectrum) - 1
    re, im = spectrum.real[:half].copy(), spectrum.imag[:half].copy()
    re[0], im[0] = spectrum.real[0], spectrum.real[half]
    return re, im

def from_packed(re, im):
    half = len(re)
    spectrum = np.zeros(half + 1, complex)
    spectrum[1:half] = re[1:] + 1j * im[1:]
    spectrum[0], spectrum[half] = re[0], im[0]
    return spectrum

def wrap(phase):
    if phase > np.pi: phase -= 2 * np.pi
    if phase < -np.pi: phase += 2 * np.pi
    return phase

def add_constant_group_delay(re, im, size, frames):
    adj = -frames * 2 * np.pi / size
    for i in range(1, size // 2):
        mag, phase = np.hypot(re[i], im[i]), np.arctan2(im[i], re[i]) + i * adj
        re[i], im[i] = mag * np.cos(phase), mag * np.sin(phase)

def extract_average_group_delay(samples):
    """HRTFKernel: FFT(analysis size), remove the average group delay, inverse."""
    size = len(samples)
    re, im = to_packed(np.fft.rfft(samples))
    ave_sum = weight_sum = last = 0.0
    for i in range(size // 2):
        mag, phase = np.hypot(re[i], im[i]), np.arctan2(im[i], re[i])
        delta = phase - last
        last = phase
        if delta < -np.pi: delta += 2 * np.pi
        if delta > np.pi: delta -= 2 * np.pi
        ave_sum += mag * delta
        weight_sum += mag
    delay = -(ave_sum / weight_sum) / (2 * np.pi / size)
    if delay > 20: delay -= 20
    add_constant_group_delay(re, im, size, -delay)
    re[0] = 0.0
    return np.fft.irfft(from_packed(re, im), size), delay

def make_kernel(response):
    response = response.copy()
    response[:HALF], delay = extract_average_group_delay(response[:HALF])
    kernel = response[:HALF].copy()
    fade = int(RATE / 4410)
    for i in range(HALF - fade, HALF):
        kernel[i] *= 1 - (i - (HALF - fade)) / fade
    return kernel, delay

def interpolate(k1, k2, x):
    """FFTFrame::CreateInterpolatedFrame: blend in dB and unwrapped phase,
    then keep the first half of the impulse response."""
    re1, im1 = to_packed(np.fft.rfft(k1, FFT))
    re2, im2 = to_packed(np.fft.rfft(k2, FFT))
    re, im = np.zeros(HALF), np.zeros(HALF)
    s1b, s2b = 1 - x, x
    re[0], im[0] = s1b * re1[0] + s2b * re2[0], s1b * im1[0] + s2b * im2[0]
    accum = last1 = last2 = 0.0
    for i in range(1, HALF):
        c1, c2 = complex(re1[i], im1[i]), complex(re2[i], im2[i])
        m1db, m2db = 20 * np.log10(abs(c1)), 20 * np.log10(abs(c2))
        s1, s2 = s1b, s2b
        diff, threshold = m1db - m2db, (5.0 if i > 16 else 2.0)
        if diff < -threshold and m1db < 0: s1 = s1 ** 0.75; s2 = 1 - s1
        elif diff > threshold and m2db < 0: s2 = s2 ** 0.75; s1 = 1 - s2
        mag = 10 ** (0.05 * (s1 * m1db + s2 * m2db))
        p1, p2 = np.angle(c1), np.angle(c2)
        d1, d2 = wrap(p1 - last1), wrap(p2 - last2)
        last1, last2 = p1, p2
        if d1 - d2 > np.pi: blend = s1 * d1 + s2 * (2 * np.pi + d2)
        elif d2 - d1 > np.pi: blend = s1 * (2 * np.pi + d1) + s2 * d2
        else: blend = s1 * d1 + s2 * d2
        accum = wrap(accum + blend)
        re[i], im[i] = mag * np.cos(accum), mag * np.sin(accum)
    return np.fft.irfft(from_packed(re, im), FFT)[:HALF]

def main(source, target):
    with wave.open(source) as w:
        assert w.getframerate() == SOURCE_RATE and w.getnchannels() == 2 and w.getsampwidth() == 2
        data = np.frombuffer(w.readframes(w.getnframes()), '<i2').reshape(-1, 2) / 32768.0
    assert len(data) == 240 * 256
    resampled_frames = int(256 / (SOURCE_RATE / RATE))  # AudioBus::CreateBySampleRateConverting
    kernels = np.zeros((len(ELEVATIONS), RAW_AZIMUTHS * INTERP, 2, HALF), np.float32)
    delays = np.zeros((len(ELEVATIONS), RAW_AZIMUTHS * INTERP, 2), np.float32)
    for e, elevation in enumerate(ELEVATIONS):
        raw = []
        for a in range(RAW_AZIMUTHS):
            actual = min(elevation, MAX_ELEVATIONS[a])
            index = a * len(ELEVATION_TABLE) + ELEVATION_TABLE.index(actual % 360)
            block = data[index * 256:(index + 1) * 256]
            ears = []
            for ear in range(2):
                response = resample_poly(block[:, ear], 160, 147)[:resampled_frames]
                ears.append(make_kernel(response))
            raw.append(ears)
        for a in range(RAW_AZIMUTHS):
            b = (a + 1) % RAW_AZIMUTHS
            for j in range(INTERP):
                x = j / INTERP
                for ear in range(2):
                    k1, d1 = raw[a][ear]
                    k2, d2 = raw[b][ear]
                    kernels[e, a * INTERP + j, ear] = k1 if j == 0 else interpolate(k1, k2, x)
                    delays[e, a * INTERP + j, ear] = d1 if j == 0 else (1 - x) * d1 + x * d2
    with open(target, 'wb') as out:
        out.write(b'SRHRTF1\0' + struct.pack('<4I', len(ELEVATIONS), RAW_AZIMUTHS * INTERP, HALF, RATE))
        out.write(delays.astype('<f4').tobytes())
        out.write(kernels.astype('<f4').tobytes())

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
