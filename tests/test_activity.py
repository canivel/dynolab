"""Request phases, prompt-reading progress and the server's activity lines."""
import contextlib
import io
import time
import unittest

from dyno.serve import activity, progress
from dyno.serve.metrics import MetricsRegistry


class Progress(unittest.TestCase):
    def setUp(self):
        self.registry = MetricsRegistry()
        progress.on_begin = lambda new, cached: self.registry.note_reading(new, cached)
        progress.on_advance = self.registry.note_read

    def tearDown(self):
        progress.on_begin = progress.on_advance = None

    def test_phases_and_progress_of_one_request(self):
        record = self.registry.begin_request('qwen')
        self.assertEqual(record.phase, 'queued')
        self.registry.note_started(record)
        self.assertEqual(record.phase, 'reading')
        progress.begin(20_000, 1_000)
        progress.advance(2048)
        progress.advance(2048)
        live = self.registry.live_requests()[0]
        self.assertEqual((live['phase'], live['prompt_to_read'], live['prompt_read'], live['cached_prompt_tokens']),
                         ('reading', 20_000, 4096, 1_000))
        self.registry.note_token(record)
        self.assertEqual(self.registry.live_requests()[0]['phase'], 'generating')
        self.registry.finish_request(record, 'stop')
        self.assertEqual((record.phase, self.registry.live_requests()), ('done', []))

    def test_mlx_lm_cumulative_callback_counts_each_token_once(self):
        record = self.registry.begin_request('qwen'); self.registry.note_started(record)
        progress.begin(5000)
        seen = []
        report = progress.counting(lambda done, total: seen.append(done))
        for done in (0, 2048, 4096, 5000): report(done, 5000)
        report(0, 300); report(300, 300)  # a second prefill (the tail after a checkpoint)
        self.assertEqual(record.prompt_read, 5300)
        self.assertEqual(seen, [0, 2048, 4096, 5000, 0, 300])

    def test_nothing_is_counted_without_a_started_request(self):
        progress.begin(100); progress.advance(50)
        self.assertEqual(self.registry.live_requests(), [])


class Lines(unittest.TestCase):
    def say(self, fn):
        out = io.StringIO()
        with contextlib.redirect_stdout(out): fn()
        return out.getvalue()

    def test_reading_line_shows_progress_rate_and_time_left(self):
        registry = MetricsRegistry(); registry.note_model_loaded('qwen')
        record = registry.begin_request('qwen'); registry.note_started(record)
        registry.note_reading(20_000, 0)
        record.reading_started_at -= 40; record.submitted_at -= 45
        registry.note_read(6000)
        activity._said.clear(); activity._said[record.request_id] = time.perf_counter() - 1000
        text = self.say(lambda: activity.report(registry, time.perf_counter()))
        self.assertIn(f'request {record.request_id} · reading the prompt: 6,000 of 20,000 tokens (30%)', text)
        self.assertRegex(text, r'· 1\d\d tok/s · about \d+ s left · 4\d s')

    def test_quiet_generation_is_called_out(self):
        registry = MetricsRegistry(); registry.note_model_loaded('qwen')
        record = registry.begin_request('qwen'); registry.note_started(record)
        registry.note_token(record); record.last_token_at -= 45
        activity._said.clear(); activity._said[record.request_id] = time.perf_counter() - 1000
        self.assertIn('no new token for 45 s', self.say(lambda: activity.report(registry, time.perf_counter())))

    def test_waiting_for_the_model_to_load(self):
        registry = MetricsRegistry()
        record = registry.begin_request('qwen'); registry.note_started(record)
        activity._said.clear(); activity._said[record.request_id] = time.perf_counter() - 1000
        self.assertIn('loading the model', self.say(lambda: activity.report(registry, time.perf_counter())))

    def test_finished_and_failed_lines(self):
        registry = MetricsRegistry()
        record = registry.begin_request('qwen'); registry.note_started(record)
        for _ in range(11): registry.note_token(record)
        registry.finish_request(record, 'stop')
        self.assertRegex(self.say(lambda: activity.finished(record)), r'request \d+ · stop · 11 tokens')
        bad = registry.begin_request('qwen'); registry.finish_request(bad, 'error', failed=True)
        self.assertIn('failed after', self.say(lambda: activity.finished(bad, 'MemoryError: out of memory')))


if __name__ == '__main__':
    unittest.main()
