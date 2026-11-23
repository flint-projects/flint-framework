# flint:engine-template acceptance traceability

Source: `handoff/specs/tier-8/template.md` section 7 (required acceptance; the brief's "section 6"
is numbered 7 in this spec). Test names are unittest names in `tests/*.d` or case names in
`negative/check.py` (run as `python3 engine/template/negative/check.py <dmd|ldc2>`).

| # | Section 7 item | Covering test or fixture | Status |
| --- | --- | --- | --- |
| 1 | field_compile: nested-missing field reports file+line+column | `negative/check.py` case `missing` (`test.html:2:1: template field unknown`) | covered |
| 2 | field_compile: unknown top-level field reports file+line+column | `negative/check.py` case `missing-top` (`test.html:2:3: ...`); `computed` (non-field member) | added |
| 3 | context_compile: interpolation in tag name / attribute name | `negative/check.py` cases `name`, `attribute` | covered |
| 4 | context_compile: unquoted attribute, script, style, on* attribute | `negative/check.py` cases `unquoted`, `script`, `style`, `event` (plus `foreign`, `comment`, `split-tag`, `url-prefix`, `url-suffix`) | covered |
| 5 | xss_escape: quotes, ampersands, angle brackets, UTF-8 escaped exactly once in text/attribute | `tests/contract_tests.d:Template renders nested fields, an include, typed blocks, and escaped URLs`; `tests/escape_fuzz.d:ASCII escaping matches a byte-by-byte reference at every run length and position`; `tests/contract_tests.d:Escaping preserves empty values, non-ASCII text and existing entity spelling as text` | covered |
| 6 | xss_escape: raw TrustedHtml only in text context; never from an ordinary Buffer | `negative/check.py` cases `trusted-attribute`, `trusted-url`; final case `untrusted Buffer conversion rejected` | added (attribute/URL), covered (Buffer conversion) |
| 7 | url_policy: javascript/data/embedded-control URLs fail; relative/http/https/mailto pass | `tests/contract_tests.d:The URL policy allows a fixed scheme set and refuses control or malformed URLs`; render-time refusal in `The count pass preserves arena capacity on short output and invalid input` | covered |
| 8 | include_graph: cycle, absolute path, `../` traversal fail | `negative/check.py` cases `cycle`, `absolute`, `traversal` | covered |
| 9 | include_graph: depth 17 fails (and depth 16 compiles) | `negative/check.py` case `deep` (rejected) and boundary `depth16` (accepted) | covered (17), added (16 boundary) |
| 10 | include_graph: 1 MiB aggregate source cap (section 4) | `negative/check.py` case `expanded-cap` (rejected) and boundary `expanded-exact` (exactly 1 MiB accepted) | covered, added (boundary) |
| 11 | include_graph: shared acyclic includes compile once | `tests/contract_tests.d:Canonical shared includes and the bounded loop are exercised`; `bench/scaling.py` asserts `__flintDocument` distinct instances == leaves + 1 shared partial | covered |
| 12 | output_capacity: exact fit succeeds; one byte short errors with no exposed partial result | `tests/contract_tests.d:The count pass preserves arena capacity on short output and invalid input` | covered |
| 13 | 16 MiB per-render output limit (section 4 / IMPLEMENTATION) | `tests/contract_tests.d:output_limit_boundary: a 16 MiB render succeeds and one more byte is refused before allocation` | added |
| 14 | 100,000-iteration loop limit (section 4 / IMPLEMENTATION) | `tests/contract_tests.d:loop_limit_boundary: exactly 100000 iterations render and one more is refused` | added |
| 15 | Unclosed blocks/contexts rejected with coordinates | `negative/check.py` case `unclosed-block`; `block`, `condition-context`, `root`, `renderer-local`, `loop-scope`, `shadow` | added (`unclosed-block`), covered (rest) |
| 16 | compile_scaling: 1/10/100 templates, cold + incremental time and instance counts | `bench/scaling.py --dmd ... --ldc ... --output DIR` (run in this review: DMD 1/10/100 cold 0.071/0.090/0.250 s, leaf 0.068-0.079 s; LDC cold 0.084/0.120/0.458 s; leaf instances constant 529-530) | covered |
| 17 | render_bench: 1 KiB/64 KiB fixtures, 100k iterations, zero D allocations, exact bytes, arena reset | `bench/harness/template_replay.d` (asserts exact bytes and `GC.stats().allocatedInCurrentThread` delta 0) via the `bench` probes | covered (not rerun in this review) |
| 18 | Fuzz seeds: truncated input, maximum lengths, empty values | `tests/escape_fuzz.d:All byte prefixes either produce bounded HTML or refuse invalid UTF-8` (all prefixes, 1 MiB boundaries); empty escape in `Escaping preserves empty values...` | covered |
| 19 | Fuzz seeds: generation reuse | `tests/contract_tests.d:Arena-backed model values are escaped and expire at arena generation changes`; `generation_reuse: one arena renders repeatedly across resets with identical bytes` | covered, added |
| 20 | Fuzz seeds: cancellation | Not applicable: `render` takes no Context and performs no blocking or native work | n/a |

## Stub review

No always-success or ignored-input paths found. `HtmlTemplate` is a data-only resource descriptor
by contract. `TrustedHtml` has no public constructor from `Buffer` (compile-negative above).

## Verification (this review)

- `rtest acc-cloud template both`: DMD rc=0, LDC rc=0 (2 modules passed).
- `negative/check.py dmd` and `ldc2`: all 28 rejection cases and 2 boundary acceptances pass.
- `tools/gates.py --package template --gate structural`: rc=0.
- `tools/quality.py --path engine/template`: 0 issues.
