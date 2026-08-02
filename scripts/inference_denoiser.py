#!/usr/bin/env python3
"""
Offline Inference for Speech Denoiser (FPGA-trained model)
Loads best_model.pth, denoises a noisy WAV, saves cleaned WAV.
Usage: python inference_denoiser.py --input noisy.wav --output cleaned.wav --model best_model.pth
"""
import os
import argparse
import numpy as np
import torch
import torch.nn as nn
from scipy import signal
import soundfile as sf

# -------------------- CONFIG (MUST MATCH TRAINING) --------------------
SAMPLE_RATE = 16000
N_FFT = 512
HOP_LENGTH = 128
PATCH_HEIGHT = 257   # n_fft//2 + 1
PATCH_WIDTH = 64
STRIDE = 32          # overlap for smooth reconstruction

# -------------------- MODEL ARCHITECTURE (EXACT MATCH) --------------------
class DenoisingCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 8, kernel_size=3, padding=1)
        self.relu1 = nn.ReLU()
        self.conv2 = nn.Conv2d(8, 16, kernel_size=3, padding=1)
        self.relu2 = nn.ReLU()
        self.conv3 = nn.Conv2d(16, 8, kernel_size=3, padding=1)
        self.relu3 = nn.ReLU()
        self.conv4 = nn.Conv2d(8, 1, kernel_size=3, padding=1)

    def forward(self, x):
        x = self.relu1(self.conv1(x))
        x = self.relu2(self.conv2(x))
        x = self.relu3(self.conv3(x))
        x = self.conv4(x)
        return x

# -------------------- STFT / ISTFT WRAPPER --------------------
def stft(audio, fs=SAMPLE_RATE, n_fft=N_FFT, hop_length=HOP_LENGTH):
    f, t, Zxx = signal.stft(audio, fs=fs, nfft=n_fft, nperseg=n_fft, noverlap=n_fft-hop_length)
    return Zxx, f, t

def istft(Zxx, fs=SAMPLE_RATE, n_fft=N_FFT, hop_length=HOP_LENGTH):
    _, x = signal.istft(Zxx, fs=fs, nperseg=n_fft, noverlap=n_fft-hop_length)
    return x

# -------------------- DENOISING ENGINE --------------------
def denoise_audio(model, noisy_audio, sr=SAMPLE_RATE):
    # Compute STFT
    Zxx, _, t = stft(noisy_audio, fs=sr)
    magnitude = np.abs(Zxx)
    phase = np.angle(Zxx)
    log_mag = np.log1p(magnitude)  # log(1 + mag)

    # Pad time dimension to be divisible by stride
    h, w = log_mag.shape
    pad_w = (STRIDE - (w - PATCH_WIDTH) % STRIDE) % STRIDE
    if pad_w > 0:
        log_mag = np.pad(log_mag, ((0, 0), (0, pad_w)), mode='edge')
    h_pad, w_pad = log_mag.shape

    # Prepare output array (accumulator and counter for averaging)
    out_log = np.zeros_like(log_mag)
    count = np.zeros_like(log_mag)

    # Slide over patches
    model.eval()
    with torch.no_grad():
        for start in range(0, w_pad - PATCH_WIDTH + 1, STRIDE):
            # Extract patch: (height, width) -> (1, 1, height, width)
            patch = log_mag[:, start:start+PATCH_WIDTH]
            patch_t = torch.tensor(patch, dtype=torch.float32).unsqueeze(0).unsqueeze(0)
            # Predict
            pred_t = model(patch_t)
            pred = pred_t.squeeze().cpu().numpy()
            # Accumulate
            out_log[:, start:start+PATCH_WIDTH] += pred
            count[:, start:start+PATCH_WIDTH] += 1.0

    # Average overlapping regions
    out_log = out_log / count
    # Remove padding
    if pad_w > 0:
        out_log = out_log[:, :-pad_w]

    # Convert back to magnitude (inverse log1p)
    # conv4 has no activation, so the model can predict small negative
    # log-magnitudes on quiet bins; clip before expm1 or those bins get a
    # negative (sign-flipped) magnitude, which injects noise into the ISTFT.
    clean_mag = np.expm1(np.maximum(out_log, 0.0))

    # Reconstruct using noisy phase
    Zxx_clean = clean_mag * np.exp(1j * phase)
    clean_audio = istft(Zxx_clean, fs=sr)

    return clean_audio

# -------------------- MAIN --------------------
def main():
    parser = argparse.ArgumentParser(description='Denoise a WAV file using trained CNN.')
    parser.add_argument('--input', required=True, help='Path to noisy input WAV')
    parser.add_argument('--output', default='cleaned_output.wav', help='Path to save cleaned WAV')
    parser.add_argument('--model', default='best_model.pth', help='Path to model weights (.pth)')
    args = parser.parse_args()

    if not os.path.exists(args.model):
        raise FileNotFoundError(f"Model not found: {args.model}")
    if not os.path.exists(args.input):
        raise FileNotFoundError(f"Input file not found: {args.input}")

    print(f"Loading model: {args.model}")
    device = torch.device('cpu')
    model = DenoisingCNN()
    model.load_state_dict(torch.load(args.model, map_location='cpu'))
    model.to(device)
    model.eval()
    print("Model loaded successfully.")

    print(f"Loading audio: {args.input}")
    audio, sr = sf.read(args.input)
    if sr != SAMPLE_RATE:
        print(f"Resampling from {sr} to {SAMPLE_RATE}...")
        import scipy.signal as sig
        audio = sig.resample(audio, int(len(audio) * SAMPLE_RATE / sr))
        sr = SAMPLE_RATE
    # Ensure mono
    if audio.ndim > 1:
        audio = np.mean(audio, axis=1)

    print("Denoising...")
    clean_audio = denoise_audio(model, audio, sr=sr)

    print(f"Saving cleaned audio to: {args.output}")
    sf.write(args.output, clean_audio, sr)
    print("Done.")

if __name__ == "__main__":
    main()
