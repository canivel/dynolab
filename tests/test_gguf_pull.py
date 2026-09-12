from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
from dyno.pull import pull_gguf


class GGUFDownloadTests(unittest.TestCase):
    def test_downloads_only_selected_file_at_listed_revision(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def download(repo, filename, revision, local_dir):
                self.assertEqual((repo, filename, revision), ('org/model', 'model-Q4.gguf', 'commit-sha'))
                path = Path(local_dir) / filename
                path.write_bytes(b'GGUFtest')
                return str(path)
            info = SimpleNamespace(sha='commit-sha', siblings=[SimpleNamespace(rfilename='model-Q4.gguf', size=8), SimpleNamespace(rfilename='model-Q8.gguf', size=99)])
            with patch('huggingface_hub.HfApi') as api, patch('huggingface_hub.hf_hub_download', side_effect=download) as fetch, patch.object(Path, 'home', return_value=root):
                api.return_value.model_info.return_value = info
                self.assertEqual(pull_gguf('org/model', 'model-Q4.gguf'), 0)
                self.assertEqual(fetch.call_count, 1)
                self.assertEqual(len(list(root.rglob('*.gguf'))), 1)

    def test_invalid_paths_and_shards_do_not_download(self):
        with patch('huggingface_hub.hf_hub_download') as download:
            for filename in ('../bad.gguf', '/bad.gguf', 'x\\bad.gguf', 'model.safetensors', 'model-00001-of-00002.gguf'):
                with self.assertRaises(ValueError):
                    pull_gguf('org/model', filename)
            download.assert_not_called()

    def test_invalid_download_is_not_reported_complete(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(Path, 'home', return_value=Path(temp)):
            path = Path(temp) / 'bad.gguf'; path.write_bytes(b'HTMLdata')
            with patch('huggingface_hub.HfApi') as api, patch('huggingface_hub.hf_hub_download', return_value=str(path)):
                api.return_value.model_info.return_value = SimpleNamespace(sha='commit', siblings=[SimpleNamespace(rfilename='bad.gguf', size=8)])
                with self.assertRaisesRegex(ValueError, 'not a GGUF'):
                    pull_gguf('org/model', 'bad.gguf')
                self.assertEqual(list(Path(temp).rglob('model.json')), [])
