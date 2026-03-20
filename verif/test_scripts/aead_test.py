import random
from core_test import ascon_permutation

def run_ascon_aead(key, nonce, ad, data, is_encrypt=True):
    # 1. Initialization
    iv = 0x00001000808c0001;
    k0, k1 = int.from_bytes(key[:8], 'big'), int.from_bytes(key[8:], 'big')
    n0, n1 = int.from_bytes(nonce[:8], 'big'), int.from_bytes(nonce[8:], 'big')
    
    state = [iv, k0, k1, n0, n1]
    state = ascon_permutation(state, 12)
    state[3] ^= k0
    state[4] ^= k1

    # 2. Associated Data (1 block)
    state[0] ^= int.from_bytes(ad[:8], 'big')
    state[1] ^= int.from_bytes(ad[8:], 'big')
    state = ascon_permutation(state, 8)
    state[4] ^= 1 

    # 3. Payload Processing
    d0, d1 = int.from_bytes(data[:8], 'big'), int.from_bytes(data[8:], 'big')
    if is_encrypt:
        res0, res1 = state[0] ^ d0, state[1] ^ d1
        state[0], state[1] = res0, res1 # Update state with Ciphertext
    else:
        res0, res1 = state[0] ^ d0, state[1] ^ d1
        state[0], state[1] = d0, d1 # Update state with Ciphertext
    
    # 4. Finalization
    state[2] ^= k0
    state[3] ^= k1
    state = ascon_permutation(state, 12)
    tag0, tag1 = state[3] ^ k0, state[4] ^ k1
    
    return (res0.to_bytes(8, 'big') + res1.to_bytes(8, 'big')), \
           (tag0.to_bytes(8, 'big') + tag1.to_bytes(8, 'big'))

# Generate 10 mixed vectors
with open("verif/test_vectors/aead_vectors.txt", "w") as f:
    for i in range(10):
        mode = 1 if i < 5 else 0
        k, n, ad, din = [random.randbytes(16) for _ in range(4)]
        dout, tag = run_ascon_aead(k, n, ad, din, bool(mode))
        f.write(f"{mode} {k.hex()} {n.hex()} {ad.hex()} {din.hex()} {dout.hex()} {tag.hex()}\n")
