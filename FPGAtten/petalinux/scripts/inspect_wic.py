#!/usr/bin/env python3
"""Read-only structural validation for the published FPGAtten SD image."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


EXPECTED_BOOT_FILES = {"BOOT.BIN", "BOOT.SCR", "IMAGE", "SYSTEM.DTB"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"WIC_VERIFY_FAIL: {message}")


def read_at(stream, offset: int, size: int) -> bytes:
    stream.seek(offset)
    data = stream.read(size)
    require(len(data) == size, f"short read at byte offset {offset}")
    return data


def parse_partitions(mbr: bytes) -> list[dict[str, int]]:
    require(mbr[510:512] == b"\x55\xaa", "missing MBR signature")
    partitions = []
    for index in range(4):
        entry = mbr[446 + index * 16 : 462 + index * 16]
        status, part_type, start_lba, sectors = struct.unpack_from(
            "<B3xB3xII", entry
        )
        if part_type or start_lba or sectors:
            partitions.append(
                {
                    "index": index + 1,
                    "status": status,
                    "type": part_type,
                    "start_lba": start_lba,
                    "sectors": sectors,
                }
            )
    return partitions


def fat32_root_names(stream, partition: dict[str, int]) -> tuple[str, set[str]]:
    offset = partition["start_lba"] * 512
    boot = read_at(stream, offset, 512)
    bytes_per_sector = struct.unpack_from("<H", boot, 11)[0]
    sectors_per_cluster = boot[13]
    reserved_sectors = struct.unpack_from("<H", boot, 14)[0]
    fat_count = boot[16]
    fat_sectors = struct.unpack_from("<I", boot, 36)[0]
    root_cluster = struct.unpack_from("<I", boot, 44)[0]
    volume_label = boot[71:82].decode("ascii", "replace").rstrip()

    require(boot[82:90].rstrip() == b"FAT32", "partition 1 is not FAT32")
    require(bytes_per_sector == 512, "unexpected FAT bytes-per-sector")
    require(sectors_per_cluster > 0, "invalid FAT sectors-per-cluster")
    require(fat_count > 0 and fat_sectors > 0, "invalid FAT table geometry")

    fat_offset = offset + reserved_sectors * bytes_per_sector
    data_offset = offset + (
        reserved_sectors + fat_count * fat_sectors
    ) * bytes_per_sector

    def cluster_offset(cluster: int) -> int:
        return data_offset + (cluster - 2) * sectors_per_cluster * bytes_per_sector

    names: set[str] = set()
    visited: set[int] = set()
    cluster = root_cluster
    while 2 <= cluster < 0x0FFFFFF8:
        require(cluster not in visited, "FAT root directory cluster loop")
        visited.add(cluster)
        cluster_data = read_at(
            stream,
            cluster_offset(cluster),
            sectors_per_cluster * bytes_per_sector,
        )
        end_of_directory = False
        for position in range(0, len(cluster_data), 32):
            entry = cluster_data[position : position + 32]
            first = entry[0]
            if first == 0x00:
                end_of_directory = True
                break
            if first == 0xE5 or entry[11] in (0x08, 0x0F):
                continue
            base = entry[0:8].decode("ascii", "replace").rstrip()
            extension = entry[8:11].decode("ascii", "replace").rstrip()
            names.add(base if not extension else f"{base}.{extension}")
        if end_of_directory:
            break
        fat_entry = read_at(stream, fat_offset + cluster * 4, 4)
        cluster = struct.unpack("<I", fat_entry)[0] & 0x0FFFFFFF
    return volume_label, names


def ext4_label(stream, partition: dict[str, int]) -> str:
    offset = partition["start_lba"] * 512 + 1024
    superblock = read_at(stream, offset, 1024)
    require(struct.unpack_from("<H", superblock, 56)[0] == 0xEF53,
            "partition 2 is not EXT4")
    return superblock[120:136].split(b"\0", 1)[0].decode("utf-8", "replace")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    args = parser.parse_args()

    require(args.image.is_file(), f"image not found: {args.image}")
    image_bytes = args.image.stat().st_size
    require(image_bytes % 512 == 0, "image size is not sector aligned")
    with args.image.open("rb") as stream:
        partitions = parse_partitions(read_at(stream, 0, 512))
        require(len(partitions) == 2, "expected exactly two MBR partitions")
        boot, rootfs = partitions
        require(boot["index"] == 1 and rootfs["index"] == 2,
                "expected partition numbers 1 and 2")
        require(boot["status"] == 0x80, "BOOT partition is not active")
        require(boot["type"] in (0x0B, 0x0C), "BOOT partition is not FAT32")
        require(boot["sectors"] == 1_048_576,
                "BOOT partition is not exactly 512 MiB")
        require(rootfs["type"] == 0x83, "RootFS partition type is not Linux")
        require(rootfs["sectors"] > 0, "RootFS partition is empty")
        require(boot["start_lba"] + boot["sectors"] == rootfs["start_lba"],
                "BOOT and RootFS partitions are not adjacent")
        require(rootfs["start_lba"] + rootfs["sectors"] == image_bytes // 512,
                "RootFS does not end at the image boundary")

        boot_label, boot_files = fat32_root_names(stream, boot)
        rootfs_label = ext4_label(stream, rootfs)

    require(boot_label == "BOOT", f"unexpected BOOT label: {boot_label!r}")
    require(rootfs_label == "RootFS",
            f"unexpected RootFS label: {rootfs_label!r}")
    require(boot_files == EXPECTED_BOOT_FILES,
            "BOOT files differ: " + ", ".join(sorted(boot_files)))

    print("WIC_LAYOUT_PASS=1")
    print(f"WIC_BYTES={image_bytes}")
    print(f"BOOT_START_LBA={boot['start_lba']}")
    print(f"BOOT_SECTORS={boot['sectors']}")
    print(f"BOOT_LABEL={boot_label}")
    print("BOOT_FILES=" + ",".join(sorted(boot_files)))
    print(f"ROOTFS_START_LBA={rootfs['start_lba']}")
    print(f"ROOTFS_SECTORS={rootfs['sectors']}")
    print(f"ROOTFS_LABEL={rootfs_label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
