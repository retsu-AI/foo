#!/usr/bin/env python3
"""Check offline navigation, complete sources, and the v1 package inventory."""

import hashlib
from html.parser import HTMLParser
import json
import unittest
from urllib.parse import unquote, urlsplit

import markdown

import build


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.ids = set()
        self.links = []
        self.assets = []
        self.documents = {}
        self.current = None
        self.text = []
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])
        if tag in {"script", "img", "link"} and ("src" in attrs or "href" in attrs):
            self.assets.append(attrs.get("src", attrs.get("href")))
        if tag == "section" and attrs.get("class") == "document":
            self.current = attrs["id"]
            self.documents[self.current] = []

    def handle_endtag(self, tag):
        if tag == "section":
            self.current = None

    def handle_data(self, value):
        self.text.append(value)
        if self.current:
            self.documents[self.current].append(value)


def words(values):
    return " ".join("".join(values).split())


class PlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = build.build()
        cls.page = Page(cls.output)

    def test_complete_sources_and_original_anchors(self):
        original = {"overview", "design", "protocols", "execution", "testing", "evidence"}
        self.assertTrue({f"doc-{key}" for key in original} <= self.page.ids)
        self.assertEqual(set(self.page.documents), {f"doc-{key}" for _, key, _ in build.DOCS})
        for name, key, _ in build.DOCS:
            with self.subTest(source=name):
                rendered = markdown.markdown((build.ROOT / name).read_text(),
                                             extensions=["tables", "fenced_code", "sane_lists", "toc"])
                self.assertTrue(words(self.page.documents[f"doc-{key}"]).endswith(words(Page(rendered).text)))
        self.assertIn(f"{len(build.DOCS)} complete documents", self.output)
        self.assertEqual(self.page.assets, [])

    def test_local_files_and_fragments_resolve(self):
        for href in self.page.links:
            with self.subTest(href=href):
                link = urlsplit(href)
                if link.scheme or link.netloc:
                    continue
                if not link.path:
                    self.assertIn(unquote(link.fragment), self.page.ids)
                    continue
                target = (build.ROOT / unquote(link.path)).resolve()
                self.assertTrue(target.is_file(), f"missing local target {target}")
                if link.fragment:
                    source = self.output if target == build.ROOT / "index.html" else target.read_text()
                    if target.suffix == ".md":
                        source = markdown.markdown(source, extensions=["toc"])
                    self.assertIn(unquote(link.fragment), Page(source).ids)

    def test_links_use_each_document_directory(self):
        for name, href in (("../README.md", "architecture.md#system-shape"),
                           ("README.md", "../architecture.md#system-shape"),
                           ("../adr/README.md", "../architecture.md#system-shape")):
            with self.subTest(source=name):
                parser = build.RewriteLinks((build.ROOT / name).resolve(), "source")
                parser.feed(f'<a href="{href}">Architecture</a>')
                self.assertEqual(Page("".join(parser.parts)).links, ["#doc-design--system-shape"])
        parser = build.RewriteLinks((build.ROOT / "../adr/README.md").resolve(), "decisions")
        parser.feed('<a href="../../src/contracts/README.md#lifetimes-and-effects">Contracts</a>')
        self.assertEqual(Page("".join(parser.parts)).links,
                         ["../../src/contracts/README.md#lifetimes-and-effects"])

    def test_package_identity_and_dependencies_are_preserved(self):
        packages = json.loads((build.ROOT / "work-packages.json").read_text())["packages"]
        snapshot = [(p["id"], p["dependencies"], p.get("completion_dependencies", []), p["linear"])
                    for p in packages]
        fingerprint = hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest()
        self.assertEqual(fingerprint, "2ed448000cce1b0742192a73a8de6f1f1c5205edbf54a44956689dafe94740e1",
                         "v1 package IDs, dependencies, or Linear mappings changed")
        self.assertEqual([p["id"] for p in packages], [f"F{i:02}" for i in range(14)])
        self.assertEqual([p["status"] for p in packages], ["review"] + ["planned"] * 13)
        self.assertNotIn('data-ready="true"', self.output)

    def test_build_is_deterministic_and_committed_output_is_current(self):
        self.assertEqual(self.output, build.build())
        self.assertEqual(self.output, (build.ROOT / "index.html").read_text())


if __name__ == "__main__":
    unittest.main()
