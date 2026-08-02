#!/usr/bin/env python3
"""
host_pipeline.py
Host PC side of the ZCU102 CNN denoiser pipeline.

Steps:
  1. Load noisy WAV (16 kHz mono)
  2. STFT → log-magnitude spectrogram (257 freq bins × T time frames)
  3. Extract overlapping 257×64 patches (stride 32 frames)
  4. Quantize float32 → Q3.12 int16
  5. Send each patch to ZCU102 via UDP (port 5001), fragmented
  6. Receive denoised patches from ZCU102
  7. Dequantize Q3.12 → float32
  8. Reconstruct spectrogram from overlapping patches (overlap-add)
  9. Recover phase from original noisy STFT, apply ISTFT → time-domain
 10. Save denoised WAV
 11. Run PESQ + STOI vs. clean reference

Usage:
  python3 host_pipeline.py --noisy noisy.wav --clean clean_ref.wav \
          --output denoised_out.wav --zcu-ip 192.168.1.10

Dependencies (in your venv):
  numpy, scipy, soundfile, pesq, pystoi
"""

import argparse
import socket
import struct
import sys
import time

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

# ── Constants (must match RTL / ps_driver) ───────────────────────────────
SAMPLE_RATE    = 16000
N_FFT          = 512
HOP_LENGTH     = 128
PATCH_H        = 257          # freq bins (N_FFT//2 + 1)
PATCH_W        = 64           # time frames per patch
PATCH_STRIDE   = 32           # overlap stride (in frames)
PATCH_SAMPLES  = PATCH_H * PATCH_W   # 16448 int16 per patch

UDP_PORT       = 5001
UDP_PAYLOAD_S  = 512          # int16 samples per UDP payload
PKTS_PER_PATCH = (PATCH_SAMPLES + UDP_PAYLOAD_S - 1) // UDP_PAYLOAD_S  # 33

Q_FRAC         = 12           # Q3.12 fractional bits
Q_SCALE        = float(1 << Q_FRAC)  # 4096.0

RECV_TIMEOUT_S = 5.0          # seconds to wait for a reply patch

# UDP header flags
FLAG_LAST_PKT   = 1 << 0
FLAG_END_STREAM = 1 << 1
FLAG_OUTPUT     = 1 << 2


# ── Signal processing helpers ─────────────────────────────────────────────

def load_mono_16k(path):
    """Load a WAV file as float32 mono @ 16 kHz."""
    audio, sr = sf.read(path, dtype='float32', always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        from scipy.signal import resample_poly
        from math import gcd
        g = gcd(SAMPLE_RATE, sr)
        audio = resample_poly(audio, SAMPLE_RATE // g, sr // g).astype(np.float32)
    return audio


def stft(audio):
    """Return complex STFT (257 × T), Hann window."""
    window = np.hanning(N_FFT)
    frames = 1 + (len(audio) - N_FFT) // HOP_LENGTH
    if frames <= 0:
        raise ValueError(f"Audio too short for STFT (need > {N_FFT} samples)")
    spec = np.zeros((N_FFT // 2 + 1, frames), dtype=np.complex64)
    for i in range(frames):
        seg = audio[i * HOP_LENGTH: i * HOP_LENGTH + N_FFT] * window
        spec[:, i] = np.fft.rfft(seg, n=N_FFT)
    return spec   # (257, T)


def istft(spec, orig_len):
    """Reconstruct waveform from complex STFT using overlap-add."""
    window  = np.hanning(N_FFT)
    T       = spec.shape[1]
    out_len = N_FFT + (T - 1) * HOP_LENGTH
    out     = np.zeros(out_len, dtype=np.float64)
    win_sum = np.zeros(out_len, dtype=np.float64)

    for i in range(T):
        frame = np.fft.irfft(spec[:, i], n=N_FFT)
        start = i * HOP_LENGTH
        out[start: start + N_FFT] += frame * window
        win_sum[start: start + N_FFT] += window ** 2

    # Normalize by window squared sum (avoid divide-by-zero)
    win_sum = np.maximum(win_sum, 1e-8)
    out /= win_sum
    return out[:orig_len].astype(np.float32)


def extract_patches(mag):
    """
    Split log-magnitude spectrogram (257 × T) into overlapping 257×64 patches.
    Returns list of (patch_array, col_start) tuples.
    mag: float32 (257, T)
    """
    T = mag.shape[1]
    patches = []
    col = 0
    while col + PATCH_W <= T:
        patches.append((mag[:, col: col + PATCH_W].copy(), col))
        col += PATCH_STRIDE
    # Include the tail (zero-pad if needed)
    if col < T:
        p = np.zeros((PATCH_H, PATCH_W), dtype=np.float32)
        p[:, : T - col] = mag[:, col:]
        patches.append((p, col))
    return patches


def reconstruct_spec(patches_out, T):
    """
    Overlap-add denoised patches back into a full (257, T) spectrogram.
    patches_out: list of (patch_array float32 (257,64), col_start)
    """
    spec_sum = np.zeros((PATCH_H, T), dtype=np.float64)
    weight   = np.zeros((PATCH_H, T), dtype=np.float64)
    # Simple rectangular window per patch
    for patch, col_start in patches_out:
        end = min(col_start + PATCH_W, T)
        w   = end - col_start
        spec_sum[:, col_start:end] += patch[:, :w]
        weight[:, col_start:end]   += 1.0
    weight = np.maximum(weight, 1.0)
    return (spec_sum / weight).astype(np.float32)


def float_to_q3_12(arr):
    """float32 → int16 Q3.12, saturated."""
    scaled = np.round(arr.ravel().astype(np.float64) * Q_SCALE)
    scaled = np.clip(scaled, -32768, 32767)
    return scaled.astype(np.int16)


def q3_12_to_float(arr_int16):
    """int16 Q3.12 → float32."""
    return (arr_int16.astype(np.float64) / Q_SCALE).astype(np.float32)


# ── UDP transport ─────────────────────────────────────────────────────────

def make_header(patch_id, pkt_id, num_pkts, flags):
    return struct.pack('<HHHH', patch_id, pkt_id, num_pkts, flags)


def parse_header(data):
    return struct.unpack('<HHHH', data[:8])  # patch_id, pkt_id, num_pkts, flags


def send_patch(sock, zcu_addr, patch_id, samples_int16):
    """Fragment and send one patch (int16 array PATCH_SAMPLES long)."""
    total = len(samples_int16)
    n_pkts = (total + UDP_PAYLOAD_S - 1) // UDP_PAYLOAD_S

    for pkt in range(n_pkts):
        offset = pkt * UDP_PAYLOAD_S
        chunk  = samples_int16[offset: offset + UDP_PAYLOAD_S]
        flags  = FLAG_LAST_PKT if pkt == n_pkts - 1 else 0
        hdr    = make_header(patch_id, pkt, n_pkts, flags)
        payload = hdr + chunk.tobytes()
        sock.sendto(payload, zcu_addr)


def send_end_of_stream(sock, zcu_addr, patch_id):
    hdr = make_header(patch_id, 0, 0, FLAG_END_STREAM)
    sock.sendto(hdr, zcu_addr)


def recv_patch(sock, expected_patch_id, n_samples):
    """
    Reassemble a denoised patch from the ZCU102.
    Returns int16 array of length n_samples, or None on timeout.
    """
    buf = {}  # pkt_id → bytes
    num_pkts_expected = None
    deadline = time.time() + RECV_TIMEOUT_S

    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            print(f"  [WARN] Timeout waiting for patch {expected_patch_id}")
            return None

        sock.settimeout(remaining)
        try:
            data, _ = sock.recvfrom(8 + UDP_PAYLOAD_S * 2 + 16)
        except socket.timeout:
            print(f"  [WARN] Timeout waiting for patch {expected_patch_id}")
            return None

        if len(data) < 8:
            continue

        patch_id, pkt_id, num_pkts, flags = parse_header(data)
        if patch_id != expected_patch_id:
            continue  # stale packet from previous patch

        payload_bytes = data[8:]
        buf[pkt_id] = payload_bytes

        if num_pkts_expected is None and num_pkts > 0:
            num_pkts_expected = num_pkts

        if num_pkts_expected is not None and len(buf) >= num_pkts_expected:
            break

    # Reassemble in order
    out = bytearray()
    for i in range(num_pkts_expected):
        out.extend(buf.get(i, bytes(UDP_PAYLOAD_S * 2)))
    samples = np.frombuffer(out[:n_samples * 2], dtype=np.int16).copy()
    return samples


# ── Evaluation ────────────────────────────────────────────────────────────

def run_evaluation(clean, noisy, denoised, sr):
    """Print PESQ, STOI, global SNR, speech-band SNR."""
    try:
        from pesq import pesq
        from pystoi import stoi

        def snr_db(ref, sig):
            noise = ref - sig
            n_ref = np.mean(ref ** 2)
            n_noise = np.mean(noise ** 2)
            if n_noise < 1e-12:
                return 99.0
            return 10 * np.log10(n_ref / n_noise)

        def speech_band_snr(ref, sig, lo=300, hi=3400):
            nyq = sr / 2.0
            sos = butter(6, [lo / nyq, hi / nyq], btype='bandpass', output='sos')
            r_f = sosfilt(sos, ref.astype(np.float64))
            s_f = sosfilt(sos, sig.astype(np.float64))
            noise = r_f - s_f
            n_ref = np.mean(r_f ** 2)
            n_noise = np.mean(noise ** 2)
            if n_noise < 1e-12:
                return 99.0
            return 10 * np.log10(n_ref / n_noise)

        # Align lengths
        n = min(len(clean), len(noisy), len(denoised))
        c, ny, dn = clean[:n], noisy[:n], denoised[:n]

        print("\n── Evaluation Results ───────────────────────────────")
        for label, sig in [("Noisy    ", ny), ("Denoised ", dn)]:
            pesq_score = pesq(sr, c, sig, 'wb')
            stoi_score = stoi(c, sig, sr, extended=False)
            gsnr       = snr_db(c, sig)
            sbsnr      = speech_band_snr(c, sig)
            print(f"  {label}:  PESQ={pesq_score:+.3f}  STOI={stoi_score:.4f}"
                  f"  SNR={gsnr:+.1f}dB  SB-SNR={sbsnr:+.1f}dB")
        print("─────────────────────────────────────────────────────\n")

    except ImportError as e:
        print(f"[WARN] Evaluation skipped (missing library): {e}")


# ── Main pipeline ─────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Host PC pipeline for ZCU102 CNN denoiser (UDP)")
    parser.add_argument('--noisy',   required=True,       help='Noisy input WAV')
    parser.add_argument('--clean',   default=None,        help='Clean reference WAV (for evaluation)')
    parser.add_argument('--output',  default='denoised_output.wav', help='Output WAV path')
    parser.add_argument('--zcu-ip',  default='192.168.1.10',       help='ZCU102 IP address')
    parser.add_argument('--port',    type=int, default=UDP_PORT,    help='UDP port')
    parser.add_argument('--dry-run', action='store_true',
                        help='Skip UDP comms, zero-fill denoised patches (test mode)')
    args = parser.parse_args()

    print(f"Loading noisy WAV: {args.noisy}")
    noisy_audio = load_mono_16k(args.noisy)
    print(f"  {len(noisy_audio)/SAMPLE_RATE:.2f}s @ {SAMPLE_RATE}Hz")

    # STFT
    print("Computing STFT ...")
    noisy_spec = stft(noisy_audio)          # complex (257, T)
    noisy_mag  = np.abs(noisy_spec)         # float32 (257, T)
    noisy_phase = np.angle(noisy_spec)       # float32 (257, T)
    T = noisy_mag.shape[1]
    print(f"  Spectrogram: {PATCH_H}×{T} ({T * HOP_LENGTH / SAMPLE_RATE:.2f}s coverage)")

    # Log-magnitude (model was trained on log |S| presumably; adjust if linear)
    log_mag = np.log1p(noisy_mag)

    # Extract patches
    patches_in = extract_patches(log_mag)   # list of (float32 (257,64), col_start)
    n_patches  = len(patches_in)
    print(f"  Patches: {n_patches} (stride={PATCH_STRIDE}, width={PATCH_W})")

    # Open UDP socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('', 0))  # any local port
    zcu_addr = (args.zcu_ip, args.port)

    if not args.dry_run:
        print(f"\nSending to ZCU102 at {args.zcu_ip}:{args.port} ...")
    else:
        print("\nDry-run mode: skipping UDP, zeroing denoised patches")

    patches_out = []   # list of (float32 (257,64), col_start)
    t_start = time.time()

    for idx, (patch, col_start) in enumerate(patches_in):
        # Quantize flat array
        flat_f32   = patch.ravel()        # (16448,)
        flat_q12   = float_to_q3_12(flat_f32)

        if not args.dry_run:
            # Send patch
            send_patch(sock, zcu_addr, patch_id=idx, samples_int16=flat_q12)

            # Receive denoised patch
            recv_int16 = recv_patch(sock, expected_patch_id=idx,
                                    n_samples=PATCH_SAMPLES)
            if recv_int16 is None:
                print(f"  [ERR] No reply for patch {idx}, substituting zeros")
                recv_int16 = np.zeros(PATCH_SAMPLES, dtype=np.int16)
        else:
            recv_int16 = np.zeros(PATCH_SAMPLES, dtype=np.int16)

        # Dequantize and reshape
        denoised_flat = q3_12_to_float(recv_int16)   # float32 (16448,)
        denoised_patch = denoised_flat.reshape(PATCH_H, PATCH_W)
        patches_out.append((denoised_patch, col_start))

        if (idx + 1) % 20 == 0 or idx == n_patches - 1:
            elapsed = time.time() - t_start
            print(f"  [{idx+1}/{n_patches}] {elapsed:.1f}s elapsed")

    # End-of-stream
    if not args.dry_run:
        send_end_of_stream(sock, zcu_addr, patch_id=n_patches)

    sock.close()

    print("\nReconstructing spectrogram from patches ...")
    denoised_log_mag = reconstruct_spec(patches_out, T)   # (257, T)
    denoised_mag = np.expm1(np.maximum(denoised_log_mag, 0.0))  # inverse log1p

    # Reconstruct complex spectrogram: denoised magnitude × original phase
    denoised_spec = denoised_mag * np.exp(1j * noisy_phase)

    print("Running ISTFT ...")
    denoised_audio = istft(denoised_spec, orig_len=len(noisy_audio))

    # Normalise to prevent clipping
    peak = np.max(np.abs(denoised_audio))
    if peak > 0.98:
        denoised_audio = denoised_audio * (0.98 / peak)

    print(f"Saving denoised WAV: {args.output}")
    sf.write(args.output, denoised_audio, SAMPLE_RATE, subtype='PCM_16')

    total_time = time.time() - t_start
    print(f"Done. Total time: {total_time:.1f}s  "
          f"({total_time/(len(noisy_audio)/SAMPLE_RATE):.2f}x real-time)")

    # Evaluation
    if args.clean:
        print(f"\nLoading clean reference: {args.clean}")
        clean_audio = load_mono_16k(args.clean)
        run_evaluation(clean_audio, noisy_audio, denoised_audio, SAMPLE_RATE)
    else:
        print("(No clean reference provided; skipping PESQ/STOI evaluation)")


if __name__ == '__main__':
    main()
