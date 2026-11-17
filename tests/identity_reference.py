#!/usr/bin/env python3
"""Independent reference for the identifiers, used to cross-check the Java port.

This file shares no code with dex/src/com/vd171/copgvd/Identity.java: it
re-implements generateSsaidLocked() from the AOSP source using only the Python
standard library. A mistake in one implementation is therefore not copied into
the other, and `tests/run_host_tests.sh` fails when the two disagree.

    python3 tests/identity_reference.py            # self-check + vectors
    python3 tests/identity_reference.py --vectors  # machine-readable vectors
"""
import hashlib
import hmac
import json
import struct
import sys
import uuid


def generate_ssaid(user_key_hex: str, signatures: list) -> str:
    """AOSP SettingsProvider.generateSsaidLocked()."""
    key = bytes.fromhex(user_key_hex)
    if len(key) not in (16, 32):
        raise ValueError("user key must be 16 or 32 bytes")

    mac = hmac.new(key, digestmod=hashlib.sha256)
    for sig in signatures:
        # m.update(getLengthPrefix(sig)); getLengthPrefix() is
        # ByteBuffer.allocate(4).putInt(len) -- big-endian int32.
        mac.update(struct.pack(">i", len(sig)))
        mac.update(sig)
    # "Only want first 64 bits", upperCase=false -> lower-case hex, 16 chars.
    return mac.digest().hex()[:16]


def gsf_id(seed: str) -> str:
    d = hashlib.sha256(b"gsf:" + seed.encode()).digest()
    v = int.from_bytes(d[:8], "big") & 0x7FFFFFFFFFFFFFFF
    if v < 1_000_000:
        v += 1_000_000_000_000_000
    return str(v)


def aaid(seed: str) -> str:
    d = hashlib.sha256(b"aaid:" + seed.encode()).digest()
    b = bytearray(d[:16])
    b[6] = (b[6] & 0x0F) | 0x40          # version 4
    b[8] = (b[8] & 0x3F) | 0x80          # RFC 4122 variant
    return str(uuid.UUID(bytes=bytes(b)))


# (user key hex, [signature bytes]) -- the third entry exercises the order
# sensitivity and the length prefix; the fourth is a realistic DER length.
VECTORS = [
    ("00112233445566778899aabbccddeeff",
     [b"signature-one"]),
    ("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
     [b"signature-one"]),
    ("AABBCCDDEEFF00112233445566778899",
     [b"sigA", b"signature-B"]),
    ("00" * 32,
     [b"\x30\x82\x04\xb2" + b"\x11" * 1202]),
]


def main() -> int:
    computed = [(key, generate_ssaid(key, sigs)) for key, sigs in VECTORS]

    if "--vectors" in sys.argv:
        print(json.dumps([{"key": k, "ssaid": v} for k, v in computed], indent=2))
        return 0

    print("SSAID reference vectors (AOSP algorithm, stdlib only)")
    for key, value in computed:
        print(f"  key {key[:16]}{'...' if len(key) > 16 else ''}  ->  {value}")

    # Properties the port must preserve, asserted here so a drift in the
    # reference is noticed as well.
    key = "00112233445566778899aabbccddeeff"
    assert generate_ssaid(key, [b"one", b"two"]) != generate_ssaid(key, [b"onetwo"]), \
        "the length prefix must stop concatenation collisions"
    assert generate_ssaid(key, [b"x"]) == generate_ssaid(key, [b"x"]), "deterministic"
    assert len(generate_ssaid(key, [b"x"])) == 16, "truncated to 64 bits"
    assert generate_ssaid(key.upper(), [b"x"]) == generate_ssaid(key, [b"x"]), \
        "key hex case must not matter"
    generate_ssaid("00" * 16, [b"x"])          # legacy 16-byte key is accepted
    try:
        generate_ssaid("00" * 12, [b"x"])
        raise AssertionError("a 12-byte key must be rejected")
    except ValueError:
        pass
    try:
        generate_ssaid("not-hex-at-all", [b"x"])
        raise AssertionError("a non-hex key must be rejected")
    except ValueError:
        pass

    print("generators")
    print(f"  gsf(seed-1)  = {gsf_id('seed-1')}")
    print(f"  aaid(seed-1) = {aaid('seed-1')}")
    print("\nreference self-check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
