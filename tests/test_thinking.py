import unittest
from dyno.lab.thinking import split_thinking


class ThinkingTests(unittest.TestCase):
    def test_truncation_never_becomes_final_answer(self):
        result=split_thinking('Let me consider this.', True, True)
        self.assertEqual(result['status'],'incomplete')
        self.assertIsNone(result['answer'])

    def test_prompt_open_marker_and_text_open_marker(self):
        raw='Some explanation.</think>\nFinal answer.'
        result=split_thinking(raw,True,True)
        self.assertEqual(result['thinking'],'Some explanation.')
        self.assertEqual(raw[result['answer_start']:],'\nFinal answer.')
        self.assertEqual(split_thinking('<think>'+raw,True)['answer'],result['answer'])

    def test_absence_and_ambiguous_markers_are_explicit(self):
        self.assertEqual(split_thinking('Final.',True)['status'],'missing_open_marker')
        self.assertEqual(split_thinking('a</think>b</think>c',True,True)['status'],'ambiguous_markers')
        self.assertIsNone(split_thinking('<think>abc',False)['answer'])
        self.assertEqual(split_thinking('Normal answer',False)['answer'],'Normal answer')
