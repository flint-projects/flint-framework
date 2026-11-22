#!/usr/bin/env python3
"""Compile the actual renderer under the stable negative diagnostic categories."""
import argparse
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DRIVER = """module negative_template;
import flint.arena : RequestArena;
import flint.templates : TrustedHtml, render;
struct Child { string present; }
struct Model {
    string text;
    string url;
    Child child;
    TrustedHtml raw;
    @property string getter() const @safe nothrow @nogc { return "computed"; }
}
auto run(const ref Model model, ref scope RequestArena arena) @safe nothrow @nogc {
    return render!("test.html", Model)(model, arena);
}
"""
CASES = (
    ("missing", "\n{{model.child.missing}}", "test.html:2:1: template field unknown"),
    ("missing-top", "ab\n  {{model.absent}}", "test.html:2:3: template field unknown"),
    ("trusted-attribute", '<p title="{{model.raw}}">', "expected escaped attribute value"),
    ("trusted-url", '<a href="{{model.raw}}">', "expected escaped attribute value"),
    ("computed", "{{model.getter}}", "unknown or non-field model member"),
    ("name", "<{{model.text}}>", "interpolation is forbidden"),
    ("attribute", '<b {{model.text}}="ok">', "interpolation is forbidden"),
    ("unquoted", "<b title={{model.text}}>", "interpolation is forbidden"),
    ("script", "<script>{{model.text}}</script>", "interpolation is forbidden"),
    ("style", "<style>{{model.text}}</style>", "interpolation is forbidden"),
    ("event", '<p OnClick="{{model.text}}">', "interpolation is forbidden"),
    ("url-prefix", '<a href="/base/{{model.url}}">', "interpolation is forbidden"),
    ("url-suffix", '<a href="{{model.url}}/tail">', "dynamic URL must occupy"),
    ("foreign", '<svg title="{{model.text}}"></svg>', "foreign graphics markup"),
    ("comment", "<!-->{{model.text}}", "abrupt HTML comment"),
    ("block", "{% if model.text %}yes{% end %}", "expected a boolean field"),
    ("condition-context", '<p title="{% if model.text %}x{% end %}">', "must occur in HTML text"),
    ("absolute", '{% include "/blocked.html" %}', "invalid include resource path"),
    ("traversal", '{% include "a/../blocked.html" %}', "invalid include resource path"),
    ("cycle", '{% include "./test.html" %}', "template include cycle"),
    ("deep", '{% include "n1.html" %}', "include depth exceeds 16"),
    ("expanded-cap", '{% include "a.html" %}{% include "a.html" %}', "expanded template exceeds"),
    ("root", "{{text}}", "must start with model or a loop binding"),
    ("renderer-local", "{{fileName}}", "must start with model or a loop binding"),
    ("loop-scope", "{% for item in model.text %}{% end %}{{item}}", "must start with model or a loop binding"),
    ("shadow", "{% for item in model.text %}{% for item in model.text %}{% end %}{% end %}", "invalid template loop binding"),
    ("unclosed-block", "{% if model.child.present %}x", "unclosed template block"),
    ("split-tag", '{% include "lt.html" %}script>{{model.text}}</script>', "incomplete HTML markup"),
)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler")
    args = cli.parse_args()
    packages = ROOT / "packages"
    imports = ["-I" + str(packages / n / "source") for n in ("arena", "serde", "template")]
    with tempfile.TemporaryDirectory(prefix="flint-template-negative-") as temp:
        directory = Path(temp)
        for index in range(1, 18):
            source = "leaf"
            if index < 17:
                source = '{% include "n' + str(index + 1) + '.html" %}'
            (directory / f"n{index}.html").write_text(source)
        (directory / "a.html").write_text("x" * 524_288)
        (directory / "lt.html").write_text("<")
        boundary_root = '{% include "a.html" %}{% include "b.html" %}'
        (directory / "b.html").write_text("y" * (1_048_576 - 524_288 - len(boundary_root)))
        driver = directory / "driver.d"
        driver.write_text(DRIVER)
        command = [args.compiler, "-preview=dip1000", "-c", "-o-", *imports, "-J" + temp, driver]
        for name, template, diagnostic in CASES:
            (directory / "test.html").write_text(template)
            result = subprocess.run(command, capture_output=True, text=True, timeout=15)
            assert result.returncode != 0 and diagnostic in result.stderr, (name, result.stderr)
            print(f"{name} rejected")
        # Boundaries just inside the limits must compile: include depth 16 and exactly 1 MiB expanded.
        for name, template in (("depth16", '{% include "n2.html" %}'), ("expanded-exact", boundary_root)):
            (directory / "test.html").write_text(template)
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, (name, result.stderr)
            print(f"{name} accepted")
        driver.write_text("""module negative_trust;
import flint.arena : Buffer;
import flint.templates : TrustedHtml;
TrustedHtml invalid(Buffer normal) @safe { return TrustedHtml(normal); }
""")
        refused = subprocess.run(command, capture_output=True, text=True, timeout=15)
        assert refused.returncode and "@disable" in refused.stderr, refused.stderr
        print("untrusted Buffer conversion rejected")


if __name__ == "__main__":
    main()
