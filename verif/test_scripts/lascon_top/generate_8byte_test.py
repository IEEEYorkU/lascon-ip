#!/usr/bin/env python3
"""
generate_8byte_test.py

This script generates a specific edge-case test vector for Ascon-AEAD128.
It computes the expected Ciphertext and Tag for a Plaintext of exactly
8 bytes (64 bits, which is exactly half of the 128-bit block size) with
an empty Associated Data (AD).

This edge case is critical because it tests the hardware padding logic
(ST_CT_PAD_0 state) when the Ciphertext ends precisely on a 64-bit
boundary (word 0 boundary).
"""

import sys
import os

# Add the parent verif/test_scripts directory to path to import core_test
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from core_test import ascon_permutation

def run_ascon_aead_8byte(key, nonce, ad, pt):
    # 1. Initialization
    iv = 0x00001000808c0001
    k0, k1 = int.from_bytes(key[:8], 'big'), int.from_bytes(key[8:], 'big')
    n0, n1 = int.from_bytes(nonce[:8], 'big'), int.from_bytes(nonce[8:], 'big')

    state = [iv, k0, k1, n0, n1]
    state = ascon_permutation(state, 12)
    state[3] ^= k0
    state[4] ^= k1

    # 2. Associated Data (Empty)
    # The Ascon spec dictates we XOR 1 into S4 for domain separation,
    # even when AD is empty.
    state[4] ^= 1

    # 3. Payload Processing (PT is exactly 8 bytes)
    d0 = int.from_bytes(pt[:8], 'big')

    # Encrypt
    ct0 = state[0] ^ d0

    # State update
    state[0] = ct0
    # Padding injected into word 1 (the remaining half of the 128-bit block)
    state[1] ^= 0x8000000000000000

    # 4. Finalization
    state[2] ^= k0
    state[3] ^= k1
    state = ascon_permutation(state, 12)
    tag0, tag1 = state[3] ^ k0, state[4] ^ k1

    return ct0.to_bytes(8, 'big'), (tag0.to_bytes(8, 'big') + tag1.to_bytes(8, 'big'))

if __name__ == "__main__":
    key = bytes([0]*16)
    nonce = bytes([0]*16)
    ad = bytes() # Empty AD
    pt = bytes([0]*8) # 8 bytes PT

    ct, tag = run_ascon_aead_8byte(key, nonce, ad, pt)
    print("CT:", ct.hex())
    print("TAG:", tag.hex())
