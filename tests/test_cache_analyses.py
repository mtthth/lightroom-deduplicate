import hashlib
import importlib.util
import os
import pathlib
import sqlite3
import tempfile
import unittest

SRC = pathlib.Path(__file__).resolve().parents[1] / 'lightroom-deduplicate.lrplugin/cache_analyses.py'
spec = importlib.util.spec_from_file_location('cache', SRC)
cache = importlib.util.module_from_spec(spec); spec.loader.exec_module(cache)


class CacheTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=pathlib.Path(__file__).resolve().parent)
        self.root = pathlib.Path(self.tmp.name)
        self.db = self.root / 'cache.sqlite3'
        self.source = self.root / 'photo-é.jpg'; self.source.write_bytes(b'original photo')
        self.magick = self.root / 'magick.exe'; self.magick.write_bytes(b'outil')
        for name in ('Empreintes.lua', 'Vignettes.lua'):
            (self.root / name).write_text('version 1', encoding='utf-8')

    def tearDown(self):
        self.tmp.cleanup()

    def request(self, mode, kind, records):
        h = lambda s: str(s).encode('utf-8').hex()
        return '\n'.join(['LRCACHE1', mode+'\t'+kind, h(self.db), h(self.root), h(self.magick), *records, 'END'])+'\n'

    def load(self, kind='F'):
        out = cache.execute(self.request('LOAD', kind, [str(self.source).encode().hex()]))
        row = out.splitlines()[1].split('\t')
        return bytes.fromhex(row[2]).decode() if row[2] != '-' else None, bytes.fromhex(row[3]) if row[3] != '-' else None

    def save(self, token, payload, kind='F'):
        row = str(self.source).encode().hex()+'\t'+token.encode().hex()+'\t'+payload.hex()
        return cache.execute(self.request('SAVE', kind, [row]))

    def test_cold_warm_and_sources_not_modified(self):
        before = self.source.read_bytes()
        token, value = self.load(); self.assertIsNone(value)
        payload = b'brut:'+hashlib.md5(before).hexdigest().encode()
        self.assertIn('END\t1\t0\t1\t0', self.save(token, payload))
        self.assertEqual(self.load(), (token, payload))
        self.assertEqual(self.source.read_bytes(), before)

    def test_signature_binary_and_full_video_hash_roundtrip(self):
        for kind, payload in [('S', b'4624,3472:'+bytes(range(256))*3), ('G', b'complet:'+b'a'*64)]:
            token, _ = self.load(kind)
            self.save(token, payload, kind)
            self.assertEqual(self.load(kind)[1], payload)

    def test_file_size_or_timestamp_invalidates(self):
        token, _ = self.load(); self.save(token, b'brut:'+b'a'*32)
        self.source.write_bytes(b'a much longer photo')
        self.assertIsNone(self.load()[1])

    def test_change_during_calculation_is_not_saved(self):
        token, _ = self.load(); self.source.write_bytes(b'changed')
        self.assertIn('END\t1\t0\t0\t1', self.save(token, b'brut:'+b'a'*32))
        self.assertIsNone(self.load()[1])

    def test_replaced_file_invalidates_even_with_same_size_and_mtime(self):
        token, _ = self.load(); self.save(token, b'brut:'+b'a'*32)
        previous = self.source.stat()
        replacement = self.root/'replacement'
        replacement.write_bytes(b'x'*previous.st_size)
        os.utime(replacement, ns=(previous.st_atime_ns, previous.st_mtime_ns))
        os.replace(replacement, self.source)
        self.assertIsNone(self.load()[1])

    def test_algorithm_change_invalidates(self):
        token, _ = self.load(); self.save(token, b'brut:'+b'a'*32)
        (self.root/'Empreintes.lua').write_text('version 2', encoding='utf-8')
        self.assertIsNone(self.load()[1])

    def test_magick_change_invalidates_signature_only(self):
        f, _ = self.load(); self.save(f, b'brut:'+b'a'*32)
        s, _ = self.load('S'); self.save(s, b'640,480:'+b'\0'*768, 'S')
        self.magick.write_bytes(b'outil version 2')
        self.assertIsNone(self.load('S')[1])
        self.assertIsNotNone(self.load()[1])

    def test_missing_or_invalid_results_are_never_trusted(self):
        token, _ = self.load()
        with self.assertRaises(ValueError): self.save(token, b'brut:incorrect')
        self.source.unlink(); self.assertEqual(self.load(), (None, None))

    def test_corrupt_record_is_a_miss(self):
        token, _ = self.load(); self.save(token, b'brut:'+b'a'*32)
        db = sqlite3.connect(self.db); db.execute("UPDATE entries SET payload=?", (b'broken',)); db.commit(); db.close()
        self.assertIsNone(self.load()[1])

    def test_truncated_request_rejected(self):
        with self.assertRaises(ValueError): cache.execute('LRCACHE1\nLOAD\tF\n')


if __name__ == '__main__': unittest.main()
