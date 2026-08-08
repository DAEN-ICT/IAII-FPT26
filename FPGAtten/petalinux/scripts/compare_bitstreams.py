#!/usr/bin/env python3
"""Compare an XSA-embedded .bit file with a standalone .bit file."""

from __future__ import annotations

import argparse
import hashlib
import zipfile
from pathlib import Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("xsa", type=Path)
    parser.add_argument("standalone_bit", type=Path)
    parser.add_argument("--member", default="GQAv7_z19p.bit")
    args = parser.parse_args()

    with zipfile.ZipFile(args.xsa) as archive:
        embedded = archive.read(args.member)
    standalone = args.standalone_bit.read_bytes()

    sync = bytes.fromhex("aa995566")
    embedded_sync = embedded.find(sync)
    standalone_sync = standalone.find(sync)
    limit = min(len(embedded), len(standalone))
    first = None
    last = None
    differences = 0
    for offset in range(limit):
        if embedded[offset] != standalone[offset]:
            differences += 1
            if first is None:
                first = offset
            last = offset
    differences += abs(len(embedded) - len(standalone))

    print(f"XSA_BIT_SHA256={sha256(embedded)}")
    print(f"STANDALONE_BIT_SHA256={sha256(standalone)}")
    print(f"XSA_BIT_BYTES={len(embedded)}")
    print(f"STANDALONE_BIT_BYTES={len(standalone)}")
    print(f"XSA_SYNC_OFFSET={embedded_sync}")
    print(f"STANDALONE_SYNC_OFFSET={standalone_sync}")
    print(f"DIFFERING_BYTES={differences}")
    print(f"FIRST_DIFFERENCE={first}")
    print(f"LAST_DIFFERENCE={last}")
    if embedded_sync >= 0 and standalone_sync >= 0:
        print(f"XSA_CONFIGURATION_SHA256={sha256(embedded[embedded_sync:])}")
        print(
            "STANDALONE_CONFIGURATION_SHA256="
            f"{sha256(standalone[standalone_sync:])}"
        )
        print(
            "CONFIGURATION_PAYLOAD_IDENTICAL="
            f"{int(embedded[embedded_sync:] == standalone[standalone_sync:])}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
