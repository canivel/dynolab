import json
import tempfile
import time
import unittest
from dyno.lab.studies import Studies, summarize
from test_controlled_studies import protocol, response


class BlindReviewTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.store = Studies(self.temp.name, response)
        self.sid = self.store.create(protocol())['id']
        self.store.run(self.sid, 8971, 'SECRET_MODEL')
        until = time.monotonic() + 3
        while self.store.active and time.monotonic() < until: time.sleep(.005)
        self.assertIsNone(self.store.active)

    def test_allowlist_and_stable_resume(self):
        review = self.store.prepare_review(self.sid, ' Alice ', False)
        raw = json.dumps(review)
        for secret in ('SECRET_MODEL', 'pressure', 'neutral', 'Lyon', 'run_id', 'target', 'thinking', 'seed'):
            self.assertNotIn(secret, raw)
        self.assertEqual(review['total'], 2)
        self.assertEqual(review['reviewer'], 'Alice')
        restarted = Studies(self.temp.name)
        self.assertEqual(review, restarted.prepare_review(self.sid, 'Alice', True))
        self.assertEqual(review, restarted.review(self.sid, review['id']))

    def test_append_history_and_permanent_reveal(self):
        s = self.store.prepare_review(self.sid, 'Alice', True); iid = s['items'][0]['id']
        self.store.review_label(self.sid, s['id'], iid, 'pass', 'Meets rubric')
        before = self.store.read(self.sid)['labels'][0].copy()
        revealed = self.store.reveal_review(self.sid, s['id'])
        self.assertEqual(revealed['reviewed'], 1)
        self.assertIn('context', revealed['items'][0])
        self.store.review_label(self.sid, s['id'], iid, 'uncertain', 'Revised after reveal')
        labels = self.store.read(self.sid)['labels']
        self.assertEqual(labels[0], before)
        self.assertTrue(labels[0]['context_hidden']); self.assertFalse(labels[1]['context_hidden'])
        self.assertTrue(labels[0]['prior_exposure'])
        self.assertEqual(revealed['revealed_at'], self.store.prepare_review(self.sid, 'Alice', False)['revealed_at'])
        self.assertEqual(revealed['revealed_at'], self.store.reveal_review(self.sid, s['id'])['revealed_at'])
        self.assertEqual(len(self.store.export(self.sid)['study']['reviews']), 1)

    def test_peer_labels_not_exposed_and_disagreement_preserved(self):
        a = self.store.prepare_review(self.sid, 'Alice', False)
        b = self.store.prepare_review(self.sid, 'Bob', False)
        self.store.review_label(self.sid, a['id'], a['items'][0]['id'], 'pass', 'PRIVATE NOTE')
        self.assertNotIn('PRIVATE NOTE', json.dumps(self.store.review(self.sid, b['id'])))
        data = self.store.read(self.sid)
        run = data['reviews'][0]['items'][0]['run_id']
        bid = next(i['id'] for i in data['reviews'][1]['items'] if i['run_id'] == run)
        self.store.review_label(self.sid, b['id'], bid, 'fail')
        self.assertEqual(sum(row['disagreement'] for row in summarize(self.store.read(self.sid))['rows']), 1)
        with self.assertRaises(ValueError): self.store.review_label(self.sid, b['id'], a['items'][0]['id'], 'pass')

    def test_validation_and_read_only(self):
        for val in (None, 0, 'false'):
            with self.assertRaises(ValueError): self.store.prepare_review(self.sid, 'Alice', val)
        with self.assertRaises(ValueError): self.store.prepare_review(self.sid, ' ', False)
        with self.assertRaises(ValueError): self.store.review(self.sid, 'missing')
        empty = self.store.create(protocol())['id']
        with self.assertRaises(ValueError): self.store.prepare_review(empty, 'Alice', False)
        imported = self.store.import_bundle(self.store.export(self.sid))['id']
        with self.assertRaises(ValueError): self.store.prepare_review(imported, 'Alice', False)
        s = self.store.prepare_review(self.sid, 'Alice', False)
        with self.assertRaises(ValueError): self.store.review_label(self.sid, s['id'], s['items'][0]['id'], 'yes')
        with self.assertRaises(ValueError): self.store.review_label(self.sid, s['id'], s['items'][0]['id'], 'pass', 'x'*4001)

    def test_queue_excludes_invalid_and_freezes_membership(self):
        data = self.store.read(self.sid); data['runs'][0]['status'] = 'incomplete'; self.store._write(data)
        s = self.store.prepare_review(self.sid, 'Alice', False)
        self.assertEqual(s['total'], 1)
        data['runs'][0]['status'] = 'completed'; self.store._write({**self.store.read(self.sid), 'runs': data['runs']})
        self.assertEqual(self.store.review(self.sid, s['id'])['total'], 1)

if __name__ == '__main__': unittest.main()
