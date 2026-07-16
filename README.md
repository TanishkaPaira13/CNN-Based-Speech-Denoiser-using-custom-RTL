# CNN-Based-Speech-Denoiser-using-custom-RTL

A **real‑time speech denoising system** implemented entirely on the Xilinx ZCU102 FPGA using custom Verilog RTL. The system accelerates a tiny 4‑layer CNN (2,481 parameters) with **line‑buffer‑based sliding‑window convolution** and **pipelined MAC units**, achieving **+7.65 dB segmental SNR improvement** while consuming just **2.5 KB of BRAM**.

No HLS. No NPU. Just the FPGA fabric.

---

## 🚀 Key Features

- **Tiny CNN Architecture** – 4 conv layers, 2,481 trainable parameters, 257×64 spectrogram patches.
- **End‑to‑End Pipeline** – Training on Kaggle (LibriSpeech + UrbanSound8K) → Quantisation (8‑bit fixed‑point) → RTL Implementation → FPGA Deployment.
- **Custom Verilog RTL** – Line buffers, sliding‑window convolution, pipelined MAC units, and BRAM‑based weight storage.
- **AXI Streaming** – High‑throughput pixel transfer between Arm Cortex‑A53 and FPGA via AXI4‑Stream / AXI4‑Lite.
- **Vitis Bare‑Metal C** – STFT/iSTFT, patch streaming, and audio reconstruction on the PS.
- **Offline Python Inference** – Run the same model on Ubuntu (CPU) for validation without FPGA hardware.

---

## 📊 Performance Metrics

| Metric | Value |
|--------|-------|
| **Segmental SNR Improvement** | **+7.65 dB** |
| **Noise Floor Reduction** | **–13.39 dB** |
| **Model Parameters** | 2,481 |
| **BRAM Usage** | 2.5 KB |
| **DSP Slices Used** | 12 |
| **Input Patch Size** | 257 × 64 |
| **Quantisation** | 8‑bit fixed‑point (Q7.8) |

---

## 🧠 Architecture Overview
