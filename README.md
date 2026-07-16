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

- **Training**: PyTorch on Kaggle (Tesla T4 GPU) with LibriSpeech (clean) + UrbanSound8K (noise) mixed at random SNRs (–5 to +15 dB).
- **Quantisation**: 8‑bit Q7.8 fixed‑point with per‑layer scaling. Weights exported as `.mem` hex files for `$readmemh`.
- **RTL Implementation**:
  - `conv_engine.v`: Sequential Conv2D engine with inner loops over input channels and kernel positions.
  - `feature_bram.v`: Dual‑port BRAM for feature maps (257×64×16).
  - `weight_rom.v` / `bias_rom.v`: ROMs for weights and biases.
  - `denoiser_top.v`: Top module chaining 4 layers with ping‑pong BRAM banks.
- **AXI Interfaces**:
  - **AXI4‑Stream**: Pixel streaming (input / output).
  - **AXI4‑Lite**: Control (start, status, IRQ).
- **Software**:
  - **Vitis Bare‑Metal C**: STFT/iSTFT, AXI DMA, and audio reconstruction.
  - **Ubuntu Python Script**: Offline inference for validation (`inference_denoiser.py`).

---
