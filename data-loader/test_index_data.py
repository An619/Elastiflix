"""Unit tests for the catalogue loader.

No real Elasticsearch (or even the elasticsearch/tqdm packages) is required:
the module is loaded with its heavy imports replaced by in-memory fakes.

Run locally with:
    coverage run --include="index-data.py" test_index_data.py
    coverage xml -o coverage-python.xml
"""
import gzip
import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
import unittest.mock as mock


def fake_elasticsearch_module():
    mod = types.ModuleType("elasticsearch")

    class FakeIndices:
        def __init__(self, exists_result=False):
            self._exists = exists_result
            self.created = []
            self.deleted = []

        def exists(self, index):
            return self._exists

        def delete(self, index):
            self.deleted.append(index)

        def create(self, index, mappings):
            self.created.append((index, mappings))

    class FakeElasticsearch:
        exists_result = False

        def __init__(self, hosts, request_timeout):
            self.hosts = hosts
            self.request_timeout = request_timeout
            self.indices = FakeIndices(exists_result=FakeElasticsearch.exists_result)

    mod.Elasticsearch = FakeElasticsearch
    mod.helpers = types.SimpleNamespace(parallel_bulk=fake_parallel_bulk)
    return mod, FakeElasticsearch


def fake_tqdm_module():
    mod = types.ModuleType("tqdm")

    class FakeTqdm:
        def __init__(self, *args, **kwargs):
            self.total = kwargs.get("total")
            self.n = 0

        def update(self, n=1):
            self.n += n

    mod.tqdm = FakeTqdm
    return mod


parallel_bulk_calls = []


def fake_parallel_bulk(client, actions, chunk_size=500):
    actions = list(actions)
    parallel_bulk_calls.append({"chunk_size": chunk_size, "count": len(actions)})
    for action in actions:
        yield True, action


_es_mod, FakeElasticsearch = fake_elasticsearch_module()
_tqdm_mod = fake_tqdm_module()


def load_module():
    spec = importlib.util.spec_from_file_location("index_data", "index-data.py")
    mod = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, {"elasticsearch": _es_mod, "tqdm": _tqdm_mod}):
        spec.loader.exec_module(mod)
    return mod


mod = load_module()


class ActionsGeneratorTest(unittest.TestCase):
    def test_derives_user_score_from_vote_average(self):
        docs = list(mod.actions_generator([{"id": 1, "title": "A", "vote_average": 6.5}], "idx"))
        self.assertEqual(docs[0]["user_score"], 6.5)

    def test_existing_user_score_is_not_overwritten(self):
        docs = list(mod.actions_generator([{"id": 1, "user_score": 9.9, "vote_average": 1.0}], "idx"))
        self.assertEqual(docs[0]["user_score"], 9.9)

    def test_missing_vote_average_stays_missing(self):
        docs = list(mod.actions_generator([{"id": 1, "title": "A"}], "idx"))
        self.assertNotIn("user_score", docs[0])

    def test_id_is_stringified_for_keyword_mapping(self):
        docs = list(mod.actions_generator([{"id": 341689}], "idx"))
        self.assertEqual(docs[0]["id"], "341689")
        self.assertIsInstance(docs[0]["id"], str)

    def test_non_numeric_vote_average_is_ignored(self):
        docs = list(mod.actions_generator([{"id": 2, "vote_average": "n/a"}], "idx"))
        self.assertNotIn("user_score", docs[0])

    def test_index_routing_fields(self):
        docs = list(mod.actions_generator([{"id": 7}], "my-index"))
        self.assertEqual(docs[0]["_index"], "my-index")
        self.assertEqual(docs[0]["_id"], "7")


def run_main():
    """Execute index-data.py's main() inside a temp data folder; returns stdout."""
    with tempfile.TemporaryDirectory() as tmp:
        template = {"template": {"mappings": {"properties": {"title": {"type": "text"}}}}}
        template_path = os.path.join(tmp, "template.json")
        with open(template_path, "w", encoding="utf-8") as fh:
            json.dump(template, fh)
        data_dir = os.path.join(tmp, "movies")
        os.makedirs(data_dir)
        movies = [
            {"id": 1, "title": "Heat", "vote_average": 8.3},
            {"id": 2, "title": "Alien", "vote_average": 8.5},
        ]
        with gzip.open(os.path.join(data_dir, "movies.json.gz"), "wt", encoding="utf-8") as fh:
            json.dump(movies, fh)

        argv = [
            "index-data.py",
            "--es_host", "http://fake:9200",
            "--index_name", "test-index",
            "--template_path", template_path,
            "--data_folder", data_dir,
        ]
        from io import StringIO
        buf = StringIO()
        with mock.patch.object(sys, "argv", argv), mock.patch("sys.stdout", buf):
            mod.main()
        return buf.getvalue()


class MainTest(unittest.TestCase):
    def test_main_deletes_existing_index_before_recreating(self):
        FakeElasticsearch.exists_result = True
        try:
            out = run_main()
        finally:
            FakeElasticsearch.exists_result = False
        self.assertIn("Deleted existing index", out)

    def test_main_creates_index_and_bulks_documents(self):
        out = run_main()
        self.assertIn("Creating index", out)
        self.assertIn("All tasks completed successfully.", out)
        self.assertEqual(parallel_bulk_calls[-1]["count"], 2)
        self.assertEqual(parallel_bulk_calls[-1]["chunk_size"], 500)


if __name__ == "__main__":
    unittest.main()
