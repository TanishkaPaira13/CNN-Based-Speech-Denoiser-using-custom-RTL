#!/usr/bin/env python3
"""
Evaluate denoiser output using PESQ and STOI metrics.

Compares:
  - Noisy vs Clean  (baseline degradation)
  - Denoised vs Clean  (model output quality)

Dependencies:
    pip install pesq pystoi soundfile scipy numpy

Usage:
    # Evaluate default files in this directory
    python evaluate_metrics.py

    # Specify custom paths
    python evaluate_metrics.py \
        --clean clean_reference.wav \
        --noisy noisy_test.wav \
        --denoised cleaned_output.wav

    # Run inference first, then evaluate
    python evaluate_metrics.py --run-inference --model best_model.pth
"""

import argparse
import sys
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly, butter, sosfilt
from math import gcd


def load_and_preprocess(path: str, target_sr: int = 16000) -> np.ndarray:
    audio, sr = sf.read(path)
    if audio.ndim > 1:
        audio = np.mean(audio, axis=1)
    if sr != target_sr:
        g = gcd(target_sr, sr)
        audio = resample_poly(audio, target_sr // g, sr // g)
    return audio.astype(np.float64)


def align_lengths(*arrays: np.ndarray) -> list:
    min_len = min(len(a) for a in arrays)
    return [a[:min_len] for a in arrays]


def compute_pesq(ref: np.ndarray, deg: np.ndarray, sr: int = 16000) -> float:
    try:
        from pesq import pesq
    except ImportError:
        print("  [!] pesq not installed. Run: pip install pesq")
        return float("nan")
    mode = "wb" if sr == 16000 else "nb"  # wideband at 16k, narrowband at 8k
    return pesq(sr, ref, deg, mode)


def compute_stoi(ref: np.ndarray, deg: np.ndarray, sr: int = 16000) -> float:
    try:
        from pystoi import stoi
    except ImportError:
        print("  [!] pystoi not installed. Run: pip install pystoi")
        return float("nan")
    return stoi(ref, deg, sr, extended=False)


def compute_snr(ref: np.ndarray, deg: np.ndarray) -> float:
    noise = deg - ref
    signal_power = np.mean(ref ** 2)
    noise_power = np.mean(noise ** 2)
    if noise_power == 0:
        return float("inf")
    return 10 * np.log10(signal_power / noise_power)


def compute_speech_band_snr(ref: np.ndarray, deg: np.ndarray,
                             sr: int = 16000,
                             lo: int = 300, hi: int = 3400) -> float:
    """
    SNR computed only in the speech frequency band (300-3400 Hz).
    More meaningful than global SNR when noise is spectrally skewed
    (e.g. low-frequency rumble has high global power but doesn't mask speech).
    """
    nyq = sr / 2.0
    sos = butter(6, [lo / nyq, hi / nyq], btype='bandpass', output='sos')
    ref_bp  = sosfilt(sos, ref.copy())
    deg_bp  = sosfilt(sos, deg.copy())
    noise   = deg_bp - ref_bp
    sp = np.mean(ref_bp ** 2)
    np_ = np.mean(noise ** 2)
    if np_ == 0:
        return float("inf")
    return 10 * np.log10(sp / np_)


def print_results(label: str, pesq_score: float, stoi_score: float,
                  snr: float, sb_snr: float):
    print(f"\n  {label}")
    print(f"    PESQ     : {pesq_score:+.4f}  (wideband MOS-LQO, range -0.5 to 4.5; higher=better)")
    print(f"    STOI     : {stoi_score:.4f}   (intelligibility 0–1; higher=better)")
    print(f"    SNR      : {snr:+.2f} dB  (global)")
    print(f"    SNR_sb   : {sb_snr:+.2f} dB  (speech band 300-3400 Hz, perceptual)")


def run_inference(model_path: str, input_path: str, output_path: str):
    """Re-run denoiser inference so evaluate always uses fresh output."""
    import subprocess
    cmd = [
        sys.executable, "inference_denoiser.py",
        "--input", input_path,
        "--output", output_path,
        "--model", model_path,
    ]
    print(f"Running inference: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="PESQ + STOI evaluation for speech denoiser output."
    )
    parser.add_argument("--clean",    default="clean_reference.wav",
                        help="Path to clean reference WAV")
    parser.add_argument("--noisy",    default="noisy_test.wav",
                        help="Path to noisy input WAV")
    parser.add_argument("--denoised", default="cleaned_output.wav",
                        help="Path to denoised output WAV")
    parser.add_argument("--model",    default="best_model.pth",
                        help="Model weights path (used with --run-inference)")
    parser.add_argument("--run-inference", action="store_true",
                        help="Run inference_denoiser.py before evaluating")
    parser.add_argument("--sr", type=int, default=16000,
                        help="Target sample rate (default: 16000)")
    args = parser.parse_args()

    if args.run_inference:
        run_inference(args.model, args.noisy, args.denoised)

    print("\n=== Speech Denoiser Evaluation ===")
    print(f"  Clean     : {args.clean}")
    print(f"  Noisy     : {args.noisy}")
    print(f"  Denoised  : {args.denoised}")
    print(f"  Sample rate: {args.sr} Hz")

    print("\nLoading audio files...")
    clean    = load_and_preprocess(args.clean,    args.sr)
    noisy    = load_and_preprocess(args.noisy,    args.sr)
    denoised = load_and_preprocess(args.denoised, args.sr)

    # Align all to shortest length to ensure fair comparison
    clean, noisy, denoised = align_lengths(clean, noisy, denoised)
    print(f"  Audio duration: {len(clean) / args.sr:.2f}s ({len(clean)} samples)")

    # ---- Noisy baseline ----
    print("\nComputing metrics...")
    noisy_pesq   = compute_pesq(clean, noisy,    args.sr)
    noisy_stoi   = compute_stoi(clean, noisy,    args.sr)
    noisy_snr    = compute_snr(clean,  noisy)
    noisy_sb_snr = compute_speech_band_snr(clean, noisy, args.sr)

    # ---- Denoised output ----
    den_pesq   = compute_pesq(clean, denoised, args.sr)
    den_stoi   = compute_stoi(clean, denoised, args.sr)
    den_snr    = compute_snr(clean,  denoised)
    den_sb_snr = compute_speech_band_snr(clean, denoised, args.sr)

    # ---- Report ----
    print("\n" + "=" * 58)
    print_results("Noisy vs Clean  (input quality):",
                  noisy_pesq, noisy_stoi, noisy_snr, noisy_sb_snr)
    print_results("Denoised vs Clean (model output):",
                  den_pesq,   den_stoi,   den_snr,   den_sb_snr)

    print("\n--- Improvement (Denoised - Noisy) ---")
    print(f"    ΔPESQ    : {den_pesq   - noisy_pesq:+.4f}")
    print(f"    ΔSTOI    : {den_stoi   - noisy_stoi:+.4f}")
    print(f"    ΔSNR     : {den_snr    - noisy_snr:+.2f} dB  (global)")
    print(f"    ΔSNR_sb  : {den_sb_snr - noisy_sb_snr:+.2f} dB  (speech band)")
    print("=" * 58)


if __name__ == "__main__":
    main()
