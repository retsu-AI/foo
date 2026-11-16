#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["Markdown==3.11"]
# ///
"""Render the foo plan as one offline HTML file; no foo runtime dependencies."""

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit, urlunsplit

import markdown

ROOT = Path(__file__).resolve().parent
DOCS = [
    ("../README.md", "docs", "Documentation index"),
    ("README.md", "overview", "Plan overview"),
    ("../architecture.md", "design", "Architecture"),
    ("../protocols.md", "protocols", "MCP and ACP"),
    ("execution.md", "execution", "Parallel implementation"),
    ("../testing.md", "testing", "Testing and release"),
    ("evidence.md", "evidence", "Project evidence"),
    ("../adr/README.md", "decisions", "Architecture decisions"),
    ("../adr/0001-external-orchestration.md", "adr-0001", "External orchestration"),
    ("../adr/0002-journal-effect-uncertainty.md", "adr-0002", "Journal effect uncertainty"),
]
DOC_IDS = {(ROOT / name).resolve(): key for name, key, _ in DOCS}


def escape(value):
    return html.escape(str(value), quote=True)


def validate(data):
    if data.get("version") != 1:
        raise ValueError("work-packages.json must have version 1")
    packages = data["packages"]
    ids = [p["id"] for p in packages]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate package ID")
    known = set(ids)
    linear_ids = [p["linear"]["id"] for p in packages if p.get("linear")]
    if len(linear_ids) != len(set(linear_ids)):
        raise ValueError("duplicate Linear issue mapping")
    if data.get("linear_project") and len(linear_ids) != len(packages):
        raise ValueError("every package must link its Linear issue")
    for p in packages:
        for field in ("title", "owner", "status"):
            if not isinstance(p.get(field), str) or not p[field]:
                raise ValueError(f"{p['id']}: missing {field}")
        for field in ("dependencies", "paths", "deliverables", "acceptance", "handoff"):
            if not isinstance(p.get(field), list):
                raise ValueError(f"{p['id']}: {field} must be an array")
        if not p["paths"] or not p["acceptance"]:
            raise ValueError(f"{p['id']}: missing ownership or acceptance")
        for dep in p["dependencies"] + p.get("completion_dependencies", []):
            if dep not in known or dep == p["id"]:
                raise ValueError(f"{p['id']}: invalid dependency {dep}")
    graph = {p["id"]: p["dependencies"] for p in packages}

    def closure(key, visiting=None, include_completion=False):
        visiting = set() if visiting is None else visiting
        if key in visiting:
            raise ValueError(f"dependency cycle at {key}")
        visiting = visiting | {key}
        deps = list(graph[key])
        if include_completion:
            deps += next(p for p in packages if p["id"] == key).get("completion_dependencies", [])
        found = set(deps)
        for dep in deps:
            found |= closure(dep, visiting, include_completion)
        return found

    for key in ids:
        closure(key, include_completion=True)

    def overlaps(left, right):
        a, b = left.rstrip("*"), right.rstrip("*")
        return a == b or (a.endswith("/") and b.startswith(a)) or (b.endswith("/") and a.startswith(b))

    for i, a in enumerate(packages):
        for b in packages[i + 1:]:
            if a["id"] in closure(b["id"]) or b["id"] in closure(a["id"]):
                continue
            for left in a["paths"]:
                for right in b["paths"]:
                    if overlaps(left, right):
                        raise ValueError(f"parallel ownership overlap: {a['id']} {left}, {b['id']} {right}")
    return packages


class RewriteLinks(HTMLParser):
    def __init__(self, source, key):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.key = key
        self.parts = []

    def handle_starttag(self, tag, attrs):
        new = []
        for name, value in attrs:
            if name == "id":
                value = f"doc-{self.key}--{value}"
            elif name == "href" and value:
                link = urlsplit(value)
                if not link.scheme and not link.netloc:
                    if not link.path:
                        value = f"#doc-{self.key}--{link.fragment}"
                    elif link.path.startswith("/"):
                        source = re.sub(r":\d+(?:-\d+)?$", "", unquote(link.path))
                        value = Path(source).as_uri() + (f"#{link.fragment}" if link.fragment else "")
                    else:
                        target = (self.source.parent / unquote(link.path)).resolve()
                        if target in DOC_IDS:
                            value = f"#doc-{DOC_IDS[target]}" + (f"--{link.fragment}" if link.fragment else "")
                        else:
                            path = Path(os.path.relpath(target, ROOT)).as_posix()
                            value = urlunsplit(("", "", path, link.query, link.fragment))
            new.append(name if value is None else f'{name}="{escape(value)}"')
        attrs_text = " " + " ".join(new) if new else ""
        self.parts.append(f"<{tag}{attrs_text}>")

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        self.parts.append(f"</{tag}>")

    def handle_data(self, data):
        self.parts.append(data)

    def handle_entityref(self, name):
        self.parts.append(f"&{name};")

    def handle_charref(self, name):
        self.parts.append(f"&#{name};")


def render_document(name, key, title):
    path = (ROOT / name).resolve()
    source = path.read_text()
    rendered = markdown.markdown(source, extensions=["tables", "fenced_code", "sane_lists", "toc"])
    parser = RewriteLinks(path, key)
    parser.feed(rendered)
    return (f'<section class="document" id="doc-{key}" data-search-section>'
            f'<div class="document-meta"><span>Reference / {escape(title)}</span>'
            f'<a href="{escape(name)}">Markdown source ↗</a></div>'
            + "".join(parser.parts) + "</section>")


def list_html(values):
    return "<ul>" + "".join(f"<li>{escape(v)}</li>" for v in values) + "</ul>"


def refs(values):
    if not values:
        return "None"
    return " ".join(f'<a href="#task-{escape(x)}" data-package="{escape(x)}">{escape(x)}</a>' for x in values)


def render_tasks(packages):
    completed = {p["id"] for p in packages if p["status"] == "complete"}
    output = []
    for p in packages:
        ready = p["status"] == "planned" and set(p["dependencies"]) <= completed
        state = "Ready to start" if ready else ("Planned · prerequisites" if p["status"] == "planned" else p["status"])
        issue = p.get("linear")
        issue_id = issue["id"] if issue else ""
        search = escape(" ".join([p["id"], issue_id, p["title"], p["owner"], *p["paths"], *p["deliverables"]]).lower())
        completion = p.get("completion_dependencies", [])
        extra = f'<p><strong>Finish only after:</strong> {refs(completion)}</p>' if completion else ""
        issue_link = (f'<p><strong>Linear issue:</strong> <a href="{escape(issue["url"])}">'
                      f'{escape(issue_id)} ↗</a></p>') if issue else ""
        owner_label = p["owner"] + (f" · {issue_id}" if issue_id else "")
        output.append(
            f'<details class="task" id="task-{escape(p["id"])}" data-task="{escape(p["id"])}" '
            f'data-search="{search}" data-ready="{str(ready).lower()}">'
            f'<summary><span class="task-id">{escape(p["id"])}</span>'
            f'<span class="task-title">{escape(p["title"])}<small>{escape(owner_label)}</small></span>'
            f'<span class="status {"ready" if ready else ""}">{escape(state)}</span></summary>'
            f'<div class="task-body">{issue_link}<p><strong>Start after:</strong> {refs(p["dependencies"])}</p>{extra}'
            f'<div class="task-columns"><div><h4>Exclusive write paths</h4>{list_html(p["paths"])}'
            f'<h4>Deliverables</h4>{list_html(p["deliverables"])}</div>'
            f'<div><h4>Acceptance</h4>{list_html(p["acceptance"])}'
            f'<h4>Handoff</h4>{list_html(p["handoff"])}</div></div></div></details>'
        )
    return "\n".join(output)


def render_graph(packages):
    by_id = {p["id"]: p for p in packages}
    levels = {}

    def level(key):
        if key not in levels:
            levels[key] = max((level(d) + 1 for d in by_id[key]["dependencies"]), default=0)
        return levels[key]

    for p in packages:
        level(p["id"])
    groups = []
    for i in range(max(levels.values()) + 1):
        nodes = []
        for p in packages:
            if levels[p["id"]] != i:
                continue
            deps = ", ".join(p["dependencies"]) or "Start here"
            finish = p.get("completion_dependencies", [])
            if finish:
                deps += "; finish after " + ", ".join(finish)
            nodes.append(f'<a class="graph-node" href="#task-{escape(p["id"])}" data-package="{escape(p["id"])}">'
                         f'<b>{escape(p["id"])}</b><span>{escape(p["title"])}</span><small>{escape(deps)}</small></a>')
        groups.append(f'<div class="graph-column"><h3>Group {i}</h3>{"".join(nodes)}</div>')
    return "".join(groups)


def build():
    data = json.loads((ROOT / "work-packages.json").read_text())
    packages = validate(data)
    files = [name for name, _, _ in DOCS] + ["work-packages.json", "view.html", "build.py"]
    digest = hashlib.sha256()
    for name in files:
        digest.update(name.encode() + b"\0" + (ROOT / name).read_bytes())
    template = (ROOT / "view.html").read_text()
    replacements = {
        "{{DOCUMENTS}}": "\n".join(render_document(*doc) for doc in DOCS),
        "{{TASKS}}": render_tasks(packages),
        "{{GRAPH}}": render_graph(packages),
        "{{PACKAGE_COUNT}}": str(len(packages)),
        "{{DOCUMENT_COUNT}}": str(len(DOCS)),
        "{{SOURCE_HASH}}": digest.hexdigest(),
        "{{PACKAGE_DATA}}": json.dumps(data, ensure_ascii=False).replace("<", "\\u003c"),
        "{{PROJECT_URL}}": escape(data.get("linear_project", {}).get("url", "#packages")),
    }
    for key, value in replacements.items():
        template = template.replace(key, value)
    if re.search(r"\{\{[A-Z_]+\}\}", template):
        raise ValueError("unresolved template marker")
    return template


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check generated HTML without writing it")
    args = parser.parse_args()
    expected = build()
    output = ROOT / "index.html"
    if args.check:
        if not output.exists() or output.read_text() != expected:
            raise SystemExit("index.html is stale; run nix develop .#ci -c python docs/plan/build.py")
        print("Plan validated: dependency graph, exclusive paths, and generated HTML are current.")
    else:
        output.write_text(expected)
        print(f"Wrote {output} ({len(expected.encode()):,} bytes)")
