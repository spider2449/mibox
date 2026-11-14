"""Trace exact stage-one boot-info reads, without running ARM firmware."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / 'phone-tools/backup/2026-11-13/bootloader.img'
    data = source.read_bytes()
    expected = 'a5fae79fe631cf557d06f6fda8bc5ae8bbf1eca5359f9f76b17bafaddd29068b'
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('stage-one source hash mismatch')

    def word(at):
        return struct.unpack_from('<I', data, at)[0]

    def half(at):
        return struct.unpack_from('<H', data, at)[0]

    # Link address is the startup relocation destination, corroborated by vectors.
    base = word(0x98)
    if word(0x16c) - base != 0x124 or word(0x184) - base != 0x154:
        raise ValueError('stage-one link-base/vector mismatch')
    if word(0x3c) != 0xe59f1054 or word(0x90) != 0xfa000b3c:
        raise ValueError('startup relocation/BLX instruction mismatch')
    for at, instruction in {0x2a6c: 0x4b31, 0x2a72: 0x681b, 0x2a74: 0x685e,
                             0x2ab8: 0x2e01, 0x2aba: 0xd800, 0x2abc: 0xb936,
                             0x2ac6: 0x2700, 0x2ad4: 0x2701,
                             0x2058: 0x2d00, 0x205a: 0xd12c}.items():
        if half(at) != instruction:
            raise ValueError(f'audited Thumb instruction mismatch at {at:#x}')
    pointer_slot = word(0x2b34)
    slot_offset = pointer_slot - base
    if not 0 <= slot_offset <= 32764:
        raise ValueError('pointer slot outside stage-one prefix')
    boot_info = word(slot_offset)
    field = boot_info + 4
    entry_report = json.loads((ROOT / 'artifacts/restoration/2026-11-14/loader-entry-branches.json').read_text())
    if entry_report['source_sha256'] != '99f701ac15a155aa07b7204d240b82a0a5c91457513ae1e246146e3f8b8753a2':
        raise ValueError('unexpected stage-two evidence source')
    if field != entry_report['startup_override']['observed_read_address']:
        raise ValueError('stage-one field differs from stage-two read')

    def text(pointer):
        at = pointer - base
        end = data.find(b'\0', at, min(32768, at + 256)) if 0 <= at < 32768 else -1
        if end < 0:
            raise ValueError('diagnostic string outside stage-one prefix')
        return data[at:end].decode('ascii')

    report = {
        'source_sha256': expected, 'prefix_bytes': 32768,
        'prefix_sha256': hashlib.sha256(data[:32768]).hexdigest(),
        'derived_stage1_link_base': base,
        'base_evidence': 'startup relocation destination at file 0x98; vector target offsets 0x124 and 0x154 corroborate',
        'boot_info_pointer_slot': pointer_slot, 'pointer_slot_file_offset': slot_offset,
        'boot_info_pointer_value_in_backup': boot_info,
        'consumed_field_address': field, 'stage2_reads_same_field': True,
        'stage1_load_dispatch': {
            'function_file_offset': 0x2a68,
            'field_value_1': {'callee_file_offset': 0x2102, 'diagnostic': text(word(0x20f4))},
            'field_value_0_or_unsigned_gt_1': {'callee_file_offset': 0x2728, 'diagnostic': text(word(0x20c4))},
            'meaning_limit': 'ext dev and int dev are actual diagnostic labels, not identification of a physical socket or USB loader mode',
        },
        'field_initial_writer': 'UNKNOWN', 'field_runtime_value': 'UNKNOWN',
        'owner_cold_start_trigger': 'UNKNOWN',
        'write_analysis_limit': 'Bounded consumers inspected; no whole-program proof that the field is never modified.',
        'device_access': False, 'firmware_executed': False, 'permanent_install': 'NOT READY',
    }
    references = []
    for path, expected_blob in [
            ('arch/arm/include/asm/arch-m6/romboot.h', '22b47fa4baa9b696378a743fb70e150393315b0f'),
            ('arch/arm/cpu/aml_meson/common/firmware/loaduboot.c', '25df379572a339df43f04c4ba645125f163fcee9'),
            ('arch/arm/cpu/aml_meson/m6/firmware/romboot.c', '75a5c61b372633c8e52232558a8de3b17a1f2a45'),
            ('arch/arm/cpu/aml_meson/m6/firmware/sdio.c', '1ec970898110cf62cc8b3bfdbddfa0fc0682d924')]:
        local = ROOT / 'phone-tools/source-reference' / path.replace('/', '__')
        payload = local.read_bytes()
        # Local text extraction can normalize EOL and terminal newlines.
        body = payload.replace(b'\r\n', b'\n').rstrip(b'\n')
        matches = []
        for terminal in range(5):
            for eol in (b'\n', b'\r\n'):
                original = (body + b'\n' * terminal).replace(b'\n', eol)
                git_hash = hashlib.sha1(b'blob ' + str(len(original)).encode() + b'\0' + original).hexdigest()
                if git_hash == expected_blob:
                    matches.append({'eol': repr(eol), 'terminal_newlines': terminal})
        if not matches:
            raise ValueError(f'reference does not match pinned Git blob: {path}')
        references.append({'path': path, 'git_blob_sha1': expected_blob,
                           'local_sha256': hashlib.sha256(payload).hexdigest(),
                           'text_equivalence_matches': matches,
                           'url': 'https://github.com/codesnake/uboot-amlogic/blob/c0b0b8cc9bd5901ced2e929ea87b99fae52d528c/' + path})
    report['public_references'] = references
    report['reference_interpretation'] = 'Matching layout labels field boot_id; public source is not proven exact Xiaomi source or boot ROM implementation.'
    for at, instruction in {0x1c24: 0x601d, 0x1c44: 0xf1b8, 0x1c46: 0x0f01,
                             0x1c4c: 0xf1b8, 0x1c4e: 0x0f03,
                             0x1c56: 0x0a69, 0x1c58: 0x0a7b,
                             0x1c5e: 0x3b01, 0x1c60: 0x061b,
                             0x1c62: 0xea43, 0x1c64: 0x0000}.items():
        if half(at) != instruction:
            raise ValueError(f'external-reader instruction mismatch at {at:#x}')
    report['external_reader'] = {
        'reader_file_offset': 0x1bb4, 'command_helper_file_offset': 0x1b64,
        'controller_literal_addresses': [word(at) for at in (0x1ca4, 0x1cac, 0x1cb0, 0x1cb4)],
        'read_command_base': word(0x1cbc), 'stop_command_base': word(0x1cc4),
        'read_command_low_byte': word(0x1cbc) & 255,
        'stop_command_low_byte': word(0x1cc4) & 255,
        'initial_media_byte_offset': 32768, 'sector_bytes': 512,
        'maximum_chunk_bytes': 65536,
        'card_type_1_or_3_argument': 'media byte offset shifted right by 9',
        'other_card_type_argument': 'media byte offset',
        'interface_interpretation': 'SD/MMC-style CMD18 read and CMD12 stop; register/command constants agree with pinned Meson6 SDIO reference',
        'physical_slot': 'UNKNOWN', 'boot_rom_external_selection': 'UNKNOWN',
        'limits': 'Static read routine, not a complete card-image format, acceptance policy, tested cold boot or physical restore path.',
    }
    destination = ROOT / 'artifacts/restoration/2026-11-14'
    (destination / 'stage1-boot-info.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    for label, start, stop, thumb in [('startup', 0, 0x194, False),
                                      ('load-dispatch', 0x2a68, 0x2b5c, True),
                                      ('source-diagnostics', 0x204c, 0x20f8, True),
                                      ('external-load', 0x2102, 0x2158, True),
                                      ('external-reader', 0x1b64, 0x1ccc, True)]:
        command = ['arm-linux-gnueabihf-objdump', '-D', '-b', 'binary', '-m', 'arm']
        if thumb:
            command += ['-M', 'force-thumb']
        # Addresses shown as file offsets, to keep link base separate from observations.
        command += [f'--start-address={start:#x}', f'--stop-address={stop:#x}', str(source)]
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        (destination / f'stage1-{label}-disassembly.txt').write_text(result.stdout, encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
