import hashlib
import importlib.util
import pathlib
import sqlite3
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'lightroom-deduplicate.lrplugin' / 'collections_readonly.py'
spec = importlib.util.spec_from_file_location('reader', SOURCE)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class CollectionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=pathlib.Path(__file__).resolve().parent)
        self.path = pathlib.Path(self.tmp.name) / 'catalogue-é.lrcat'
        self.db = sqlite3.connect(self.path)
        self.db.executescript('''
        CREATE TABLE Adobe_images(id_local INTEGER PRIMARY KEY);
        CREATE TABLE AgLibraryCollection(id_local INTEGER PRIMARY KEY,name,parent,creationId,systemOnly);
        CREATE TABLE AgLibraryCollectionImage(image,collection);
        CREATE TABLE AgLibraryPublishedCollection(id_local INTEGER PRIMARY KEY,creationId);
        CREATE TABLE AgLibraryPublishedCollectionImage(image,collection);
        ''')
        self.db.executemany('INSERT INTO Adobe_images VALUES (?)', [(i,) for i in range(1, 1100)])
        self.db.executemany('INSERT INTO AgLibraryCollection VALUES (?,?,?,?,?)', [
            (1, 'Albums', None, reader.GROUP, 0),
            (2, '2026', 1, reader.GROUP, 0),
            (3, 'Été\tà Paris\n2026', 2, reader.REGULAR, 0),
            (4, 'Doublons à retirer', None, reader.REGULAR, 0),
            (5, 'Dynamique', None, reader.SMART, 0),
            (6, 'Système', None, reader.REGULAR, 1),
        ])
        self.db.executemany('INSERT INTO AgLibraryCollectionImage VALUES (?,?)',
                            [(i, 3) for i in range(1, 1100)] + [(1, 4), (1, 5), (1, 6)])
        self.db.executemany('INSERT INTO AgLibraryPublishedCollection VALUES (?,?)', [
            (10, 'com.adobe.ag.library.collection.published.built-in'),
            (11, 'com.adobe.ag.library.smart_collection.published')])
        self.db.executemany('INSERT INTO AgLibraryPublishedCollectionImage VALUES (?,?)', [(2, 10), (1, 11)])
        self.db.commit()

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def test_bulk_and_readonly(self):
        before = hashlib.sha256(self.path.read_bytes()).digest()
        result = reader.snapshot(self.path, range(1, 1100))
        self.assertIn('P\t1\t0\n', result)
        self.assertIn('P\t2\t1\n', result)
        self.assertIn('END\t1099\t4\t1100\n', result)
        self.assertNotIn('L\t1\t5\n', result)
        self.assertNotIn('L\t1\t6\n', result)
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).digest())
        self.assertEqual(bytes.fromhex(result.split('C\t3\t2\t')[1].splitlines()[0]).decode(), 'Été\tà Paris\n2026')

    def test_missing_photo_fails(self):
        with self.assertRaisesRegex(ValueError, 'Photos absentes'):
            reader.snapshot(self.path, [999999])

    def test_cycle_fails(self):
        self.db.execute('UPDATE AgLibraryCollection SET parent=3 WHERE id_local=1'); self.db.commit()
        with self.assertRaisesRegex(ValueError, 'Cycle'):
            reader.snapshot(self.path, [1])

    def test_unknown_collection_fails(self):
        self.db.execute("UPDATE AgLibraryCollection SET creationId='unknown' WHERE id_local=3"); self.db.commit()
        with self.assertRaisesRegex(ValueError, 'Type de collection'):
            reader.snapshot(self.path, [1])

    def test_orphan_publication_fails(self):
        self.db.execute('INSERT INTO AgLibraryPublishedCollectionImage VALUES (1,999)'); self.db.commit()
        with self.assertRaises(Exception):
            reader.snapshot(self.path, [1])

    def test_missing_catalog_is_not_created(self):
        absent = self.path.with_name('absent.lrcat')
        with self.assertRaises(sqlite3.OperationalError):
            reader.snapshot(absent, [1])
        self.assertFalse(absent.exists())

    def test_missing_schema_produces_error_not_empty_success(self):
        self.db.execute('DROP TABLE AgLibraryPublishedCollectionImage'); self.db.commit()
        request = self.path.with_suffix('.request')
        output = self.path.with_suffix('.out')
        request.write_text(str(self.path) + '\n1\n', encoding='utf-8')
        self.assertEqual(reader.main(request, output), 1)
        self.assertTrue(output.read_text().startswith('ERROR\t'))


if __name__ == '__main__':
    unittest.main()
