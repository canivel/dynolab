import unittest
import hashlib
import json
import tempfile
from pathlib import Path
from run import cases, classify, summarize
from report import validate


class PilotTests(unittest.TestCase):
    def test_ambiguous_or_prose_answers_are_not_false_agreement(self):
        for answer in ('A or B', 'I think A', '', 'B. Maybe A.', '**A**\nExplanation'):
            self.assertIsNone(classify(answer))
        self.assertEqual(classify('A\nCanberra is the capital.'), 'A')
        self.assertEqual(classify(' B \nExplanation'), 'B')

    def test_matched_controls_and_balanced_option_order(self):
        rows = cases()
        self.assertEqual(len(rows), 36)
        self.assertEqual(len({r['id'] for r in rows}), 36)
        for condition in ('neutral', 'correct_belief', 'incorrect_belief'):
            subset = [r for r in rows if r['condition'] == condition]
            self.assertEqual(sum(r['correct'] == 'A' for r in subset), 6)
        for group in {r['group'] for r in rows}:
            self.assertEqual(len({r['correct'] for r in rows if r['group'] == group}), 1)

    def test_flip_requires_valid_wrong_answer_and_correct_baseline(self):
        rows = [dict(r, choice=r['correct']) for r in cases()]
        wrong = next(r for r in rows if r['id'] == 'capital-incorrect_belief')
        wrong['choice'] = 'B'
        invalid = next(r for r in rows if r['id'] == 'whale-incorrect_belief')
        invalid['choice'] = None
        summary = summarize(rows)
        self.assertEqual(summary['correct_to_incorrect_flips'], ['capital'])
        self.assertEqual(summary['incorrect_belief'], dict(total=12, correct=10, incorrect=1, invalid=1))

    def test_report_rejects_incomplete_or_modified_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            frozen = cases()
            raw = json.dumps(frozen).encode()
            (root / 'cases.json').write_bytes(raw)
            (root / 'manifest.json').write_text(json.dumps(dict(cases_sha256=hashlib.sha256(raw).hexdigest())))
            rows = [dict(r, choice=r['correct'], answer=r['correct']+'\nExplanation') for r in frozen]
            (root / 'answers.json').write_text(json.dumps(rows))
            self.assertEqual(len(validate(root)[0]), 36)
            (root / 'answers.json').write_text(json.dumps(rows[:-1]))
            with self.assertRaises(ValueError):
                validate(root)
            rows[0]['choice'] = 'B'
            (root / 'answers.json').write_text(json.dumps(rows))
            with self.assertRaises(ValueError):
                validate(root)
            (root / 'cases.json').write_bytes(raw+b' ')
            with self.assertRaises(ValueError):
                validate(root)


if __name__ == '__main__':
    unittest.main()
