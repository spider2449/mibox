"""Reject wrong-architecture and unsafe ELF program headers before execution."""
import struct
import unittest
from docker_payload_elf import inspect_arm


def fixture():
    data = bytearray(84)
    data[:7] = b'\x7fELF\x01\x01\x01'
    struct.pack_into('<HHI', data, 16, 2, 40, 1)
    struct.pack_into('<I', data, 28, 52)
    struct.pack_into('<HH', data, 42, 32, 1)
    struct.pack_into('<IIIII', data, 52, 1, 0, 0, 0, 84)
    return data


class ElfGuards(unittest.TestCase):
    def test_static_arm(self):
        self.assertEqual(inspect_arm(fixture())['machine'], 'ARM')

    def test_wrong_architecture(self):
        data = fixture()
        struct.pack_into('<H', data, 18, 3)
        with self.assertRaises(ValueError):
            inspect_arm(data)

    def test_dynamic_dependencies(self):
        for kind in (2, 3):
            with self.subTest(kind=kind):
                data = fixture()
                struct.pack_into('<I', data, 52, kind)
                with self.assertRaises(ValueError):
                    inspect_arm(data)

    def test_out_of_bounds(self):
        for offset, value in ((28, 4096), (68, 4096)):
            with self.subTest(offset=offset):
                data = fixture()
                struct.pack_into('<I', data, offset, value)
                with self.assertRaises(ValueError):
                    inspect_arm(data)


if __name__ == '__main__':
    unittest.main()
