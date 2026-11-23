#!/usr/bin/env python3
"""Measure separate rendering leaf units and one content-only rebuild."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.measure_builds import template_instances, timed_process


def run(compiler, output, count, profile):
    with tempfile.TemporaryDirectory(prefix="flint-template-scaling-") as tmp:
        directory = Path(tmp)
        shared = directory / "partial.html"
        shared.write_text("<strong>{{model.name}}</strong>")
        model = directory / "model.d"
        model.write_text("module model; struct Record { string name; }\n")
        inputs = []
        sources = []
        for index in range(count):
            template = directory / f"leaf{index}.html"
            template.write_text(f'<section data-id="{index}">{{% include "partial.html" %}}</section>')
            inputs.append(template)
            leaf = directory / f"leaf{index}.d"
            leaf.write_text(f"""module leaf{index};
import flint.arena : Buffer, RequestArena, Result;
import flint.engine.templates : render;
import model : Record;
Result!Buffer show(scope const ref Record record, ref scope RequestArena arena) @safe nothrow @nogc
{{
    return render!"{template.name}"(record, arena);
}}
""")
            sources.append(leaf)
        paths = ["-I" + str(ROOT / "packages" / name / "source") for name in ("arena", "serde", "template")]
        options = ["-preview=dip1000", "-vtemplates", "-lib", "-J" + tmp, "-I" + tmp, *paths]
        identities = [fingerprint(path, shared, compiler, options) for path in inputs]
        cold = compile_(compiler, output, directory, options, model, sources, profile, count, "cold")
        inputs[-1].write_text('<aside>{% include "partial.html" %}</aside>')
        invalidated = [source for path, source, key in zip(inputs, sources, identities)
                       if fingerprint(path, shared, compiler, options) != key]
        assert invalidated == sources[-1:]
        leaf = compile_(compiler, output, directory, options, model, invalidated, profile, count, "leaf")
        return [cold, leaf]


def fingerprint(path, shared, compiler, options):
    digest = hashlib.sha256()
    digest.update(os.fsencode(compiler))
    digest.update(json.dumps(options).encode())
    for resource in (path, shared):
        digest.update(hashlib.sha256(resource.read_bytes()).digest())
    return digest.hexdigest()


def compile_(compiler, output, directory, options, model, units, profile, count, phase):
    log = output / f"{profile}-{count}-{phase}.log"
    library = directory / f"{phase}.a"
    result = timed_process(
        [compiler, *options, "-of=" + str(library), model, *units], directory, os.environ, log
    )
    assert library.stat().st_size > 0
    transcript = log.read_text()
    totals = template_instances(transcript)
    parsed = re.search(r"\((\d+) distinct\).*__flintDocument\(string filename\)", transcript)
    assert parsed and int(parsed.group(1)) == len(units) + 1, transcript
    assert totals > 0
    return {
        "compiler": profile, "templates": count, "phase": phase,
        "compiled_leaves": len(units), "template_instances": totals, **result,
    }


def main():
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--dmd", required=True)
    arguments.add_argument("--ldc", required=True)
    arguments.add_argument("--output", required=True, type=Path)
    args = arguments.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for profile, compiler in (("dmd", args.dmd), ("ldc", args.ldc)):
        for count in (1, 10, 100):
            for result in run(compiler, output, count, profile):
                print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
