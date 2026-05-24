from __future__ import annotations

from dataclasses import dataclass

from .common import *


@dataclass
class FSB5Sample:
    index: int
    name: str
    frequency: int
    channels: int
    sample_count: int


@dataclass
class FSB5Info:
    bank_offset: int
    num_samples: int
    total_size: int
    samples: List[FSB5Sample]


def parse_fsb5_bytes(raw: bytes) -> FSB5Info:
    offset = raw.find(b"FSB5")
    if offset < 0:
        die("FSB5 chunk not found inside bank")
    if offset + FSB5_HEADER_SIZE > len(raw):
        die(f"FSB5 header at {offset} is truncated")

    magic, _version, num_samples, sh_size, nt_size, sd_size, _codec, _flags = struct.unpack_from(
        "<4s7I", raw, offset
    )
    if magic != b"FSB5":
        die(f"FSB5 magic mismatch at {offset}: {magic!r}")
    if not (0 < num_samples <= FSB5_MAX_SAMPLES):
        die(f"FSB5 sample count {num_samples} is outside 1..{FSB5_MAX_SAMPLES}")

    total_size = FSB5_HEADER_SIZE + sh_size + nt_size + sd_size
    if offset + total_size > len(raw):
        die(
            "FSB5 chunk reports sizes that do not fit: "
            f"offset={offset}, sh={sh_size}, nt={nt_size}, sd={sd_size}, file={len(raw)}"
        )

    samples: List[FSB5Sample] = []
    sample_headers_offset = offset + FSB5_HEADER_SIZE
    name_table_offset = sample_headers_offset + sh_size
    cursor = sample_headers_offset

    for index in range(num_samples):
        lo, hi = struct.unpack_from("<II", raw, cursor)
        meta = lo | (hi << 32)
        has_extra = meta & 0x1
        freq_index = (meta >> 1) & 0xF
        channel_bits = (meta >> 5) & 0x3
        sample_count = (meta >> 34) & 0x3FFFFFFF
        channels = (
            1 if channel_bits == 0 else 2 if channel_bits == 1 else 6 if channel_bits == 2 else 8
        )
        frequency = FSB5_SAMPLE_RATES.get(freq_index, TARGET_SAMPLE_RATE)
        cursor += 8
        if has_extra:
            while True:
                extra = struct.unpack_from("<I", raw, cursor)[0]
                cursor += 4
                more = extra & 0x1
                size = (extra >> 1) & 0xFFFFFF
                cursor += size
                if not more:
                    break
        samples.append(
            FSB5Sample(
                index=index,
                name="",
                frequency=frequency,
                channels=channels,
                sample_count=sample_count,
            )
        )

    if nt_size > 0:
        name_table = raw[name_table_offset : name_table_offset + nt_size]
        offsets = [
            struct.unpack_from("<I", name_table, 4 * index)[0] for index in range(num_samples)
        ]
        named_samples: List[FSB5Sample] = []
        for sample, name_offset in zip(samples, offsets):
            end = name_table.find(b"\x00", name_offset)
            if end < 0:
                end = len(name_table)
            name = name_table[name_offset:end].decode("utf-8", "replace")
            named_samples.append(
                FSB5Sample(
                    index=sample.index,
                    name=name,
                    frequency=sample.frequency,
                    channels=sample.channels,
                    sample_count=sample.sample_count,
                )
            )
        samples = named_samples

    return FSB5Info(
        bank_offset=offset, num_samples=num_samples, total_size=total_size, samples=samples
    )


def parse_fsb5(path: Path) -> FSB5Info:
    return parse_fsb5_bytes(path.read_bytes())


def extract_embedded_fsb(bank: Path, out_fsb: Path) -> FSB5Info:
    raw = bank.read_bytes()
    info = parse_fsb5_bytes(raw)
    out_fsb.parent.mkdir(parents=True, exist_ok=True)
    out_fsb.write_bytes(raw[info.bank_offset : info.bank_offset + info.total_size])
    return info


def rewrite_fsb5_names(fsb5: bytes, new_names: List[str]) -> bytes:
    if not fsb5.startswith(b"FSB5"):
        die("fsbank output is not an FSB5 file")
    magic, version, num_samples, sh_size, old_nt_size, sd_size, codec, flags = struct.unpack_from(
        "<4s7I", fsb5, 0
    )
    if num_samples != len(new_names):
        die(f"name count {len(new_names)} does not match FSB5 sample count {num_samples}")

    encoded = [name.encode("utf-8") + b"\x00" for name in new_names]
    offsets_size = 4 * num_samples
    strings_size = sum(len(value) for value in encoded)
    unaligned = offsets_size + strings_size
    pad = (-unaligned) % 16
    new_nt_size = unaligned + pad

    offsets = []
    cursor = offsets_size
    for value in encoded:
        offsets.append(cursor)
        cursor += len(value)
    new_name_table = struct.pack(f"<{num_samples}I", *offsets) + b"".join(encoded) + b"\x00" * pad

    sample_headers = fsb5[FSB5_HEADER_SIZE : FSB5_HEADER_SIZE + sh_size]
    sample_data_start = FSB5_HEADER_SIZE + sh_size + old_nt_size
    sample_data = fsb5[sample_data_start : sample_data_start + sd_size]
    new_header = bytearray(fsb5[:FSB5_HEADER_SIZE])
    struct.pack_into("<I", new_header, 16, new_nt_size)
    return bytes(new_header) + sample_headers + new_name_table + sample_data


def find_covering_riff_size_fields(raw: bytes, target_offset: int) -> List[int]:
    positions: List[int] = []

    def walk(start: int, end: int) -> None:
        cursor = start
        while cursor + 8 <= end:
            size = struct.unpack_from("<I", raw, cursor + 4)[0]
            fourcc = raw[cursor : cursor + 4]
            payload_start = cursor + 8
            payload_end = payload_start + size
            if payload_end > end:
                return
            if payload_start <= target_offset < payload_end:
                positions.append(cursor + 4)
                if fourcc in (b"LIST", b"RIFF"):
                    walk(payload_start + 4, payload_end)
            cursor = payload_end + (size & 1)

    if raw[:4] == b"RIFF":
        walk(12, len(raw))
    return positions


def splice_fsb5_into_bank(original_bank: Path, new_fsb5: bytes, out_bank: Path) -> Dict[str, int]:
    raw = original_bank.read_bytes()
    info = parse_fsb5_bytes(raw)
    old_start = info.bank_offset
    old_end = old_start + info.total_size
    delta = len(new_fsb5) - info.total_size
    size_fields = find_covering_riff_size_fields(raw, old_start)
    new_bank = bytearray(raw[:old_start] + new_fsb5 + raw[old_end:])

    if new_bank[:4] == b"RIFF":
        struct.pack_into("<I", new_bank, 4, len(new_bank) - 8)
    for position in size_fields:
        old_size = struct.unpack_from("<I", raw, position)[0]
        struct.pack_into("<I", new_bank, position, old_size + delta)

    out_bank.parent.mkdir(parents=True, exist_ok=True)
    out_bank.write_bytes(bytes(new_bank))
    return {
        "old_fsb5_size": info.total_size,
        "new_fsb5_size": len(new_fsb5),
        "delta": delta,
        "riff_size_fields_updated": len(size_fields),
    }


def bank_name_from_path(path: Path) -> str:
    stem = path.stem
    return stem[:-7] if stem.endswith(".assets") else stem
