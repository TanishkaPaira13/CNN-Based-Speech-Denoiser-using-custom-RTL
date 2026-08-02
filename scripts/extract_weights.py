#!/usr/bin/env python3
"""
Extract and quantize weights from best_model.pth → Verilog .mem files.

Architecture: DenoisingCNN
  conv1: (8,  1,  3,3) weight + (8,)  bias
  conv2: (16, 8,  3,3) weight + (16,) bias
  conv3: (8,  16, 3,3) weight + (8,)  bias
  conv4: (1,  8,  3,3) weight + (1,)  bias

Fixed-point format:
  Weights: Q3.12  → int16, stored as 4-hex-digit signed hex
  Biases:  Q6.24  → int32, stored as 8-hex-digit signed hex

Weight ROM layout per layer:
  ROM[inner_addr * MAX_C_OUT + co] = weight[co, ci, kh, kw]
  where inner_addr = ci*9 + kh*3 + kw
  and MAX_C_OUT = 16 (pad unused with zeros)

Output files (in rtl/):
  weights_L1.mem  biases_L1.mem
  weights_L2.mem  biases_L2.mem
  weights_L3.mem  biases_L3.mem
  weights_L4.mem  biases_L4.mem
"""

import sys, os, zipfile
import numpy as np

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.join(SCRIPT_DIR, '..')
MODEL_PATH  = os.path.join(PROJECT_DIR, '..', 'best_model.pth')
OUT_DIR     = os.path.join(PROJECT_DIR, 'rtl')

FRAC_W   = 12          # fractional bits for weights/features (Q3.12)
FRAC_B   = 24          # fractional bits for bias (Q6.24, matches acc scale)
MAX_C    = 16          # parallel output channels in RTL

LAYERS = [
    # name,     c_out, c_in, weight_blob, bias_blob
    ('L1_conv', 8,   1,  '0', '1'),
    ('L2_conv', 16,  8,  '2', '3'),
    ('L3_conv', 8,  16,  '4', '5'),
    ('L4_conv', 1,   8,  '6', '7'),
]


def load_blobs(model_path):
    blobs = {}
    with zipfile.ZipFile(model_path, 'r') as z:
        for name in z.namelist():
            if 'data/' in name and not name.endswith('/'):
                idx = name.rsplit('/', 1)[-1]
                blobs[idx] = np.frombuffer(z.read(name), dtype=np.float32)
    return blobs


def to_hex_signed(val, nbits):
    """Convert signed integer to hex string with nbits/4 digits."""
    mask = (1 << nbits) - 1
    return format(int(val) & mask, f'0{nbits//4}x')


def write_weight_mem(path, w_flat, c_out, c_in):
    """
    Write weight ROM as hex.
    ROM is organized: for each inner_addr (ci*9+kh*3+kw) in order,
    write MAX_C signed-16-bit values (one per output channel, zero-padded).
    File format: one 16-bit hex value per line (for $readmemh).
    Total entries: c_in*9 * MAX_C
    """
    w_4d = w_flat.reshape(c_out, c_in, 3, 3)   # (c_out, c_in, kH, kW)
    w_q  = np.clip(np.round(w_flat * (1 << FRAC_W)), -32768, 32767).astype(np.int32)
    w_q4 = w_q.reshape(c_out, c_in, 3, 3)

    lines = []
    for ci in range(c_in):
        for kh in range(3):
            for kw in range(3):
                for co in range(MAX_C):
                    if co < c_out:
                        val = int(w_q4[co, ci, kh, kw])
                    else:
                        val = 0
                    lines.append(to_hex_signed(val, 16))

    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f"  {os.path.basename(path)}: {len(lines)} entries ({c_in*9} inner × {MAX_C} ch)")


def write_bias_mem(path, b_flat, c_out):
    """
    Write bias ROM as hex (Q6.24, 32-bit signed).
    MAX_C entries, zero-padded for unused channels.
    """
    b_q = np.clip(np.round(b_flat * (1 << FRAC_B)),
                  -(1 << 31), (1 << 31) - 1).astype(np.int64)
    lines = []
    for co in range(MAX_C):
        val = int(b_q[co]) if co < c_out else 0
        lines.append(to_hex_signed(val, 32))

    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f"  {os.path.basename(path)}: {len(lines)} entries (Q6.24)")


def main():
    if not os.path.exists(MODEL_PATH):
        # Try sibling directory
        alt = os.path.join(SCRIPT_DIR, '..', '..', 'best_model.pth')
        if os.path.exists(alt):
            global MODEL_PATH
            MODEL_PATH = alt
        else:
            print(f"ERROR: best_model.pth not found at {MODEL_PATH}")
            sys.exit(1)

    print(f"Loading model from: {os.path.abspath(MODEL_PATH)}")
    blobs = load_blobs(MODEL_PATH)

    os.makedirs(OUT_DIR, exist_ok=True)

    for (tag, c_out, c_in, widx, bidx) in LAYERS:
        print(f"\nLayer {tag}  (c_out={c_out}, c_in={c_in}):")
        w_flat = blobs[widx]
        b_flat = blobs[bidx]

        w_path = os.path.join(OUT_DIR, f'weights_{tag}.mem')
        b_path = os.path.join(OUT_DIR, f'biases_{tag}.mem')

        write_weight_mem(w_path, w_flat, c_out, c_in)
        write_bias_mem(b_path, b_flat, c_out)

        # Print stats
        w_fp = w_flat
        print(f"  weight range: [{w_fp.min():.4f}, {w_fp.max():.4f}]  "
              f"quant_error: {np.max(np.abs(w_fp - np.clip(np.round(w_fp*(1<<FRAC_W)),-32768,32767)/(1<<FRAC_W))):.6f}")

    print(f"\nDone. All .mem files written to {OUT_DIR}/")
    print("Include in Verilog with: $readmemh(\"weights_L1_conv.mem\", mem)")


if __name__ == '__main__':
    main()
