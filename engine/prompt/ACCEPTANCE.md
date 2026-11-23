# flint:engine-prompt acceptance traceability

Source: `handoff/specs/tier-4/prompt.md` section 6. Unit tests run with `dub test :prompt` on DMD and LDC.
PTY rows run `fixtures/test_prompt.py fixtures/build/test-prompt-pty` (build with
`dub build --root=engine/prompt/fixtures`). Compile-negative fixtures run with
`python3 engine/prompt/negative/check.py <dmd|ldc2>`, which also compiles a repaired positive control.
The native wipe boundary is checked by `fixtures/wipe_test.c` (`cc -Wl,--wrap=free fixtures/wipe_test.c`,
also with `-fsanitize=address,undefined`).

| ID | Required item | Covering test(s) | Status |
| --- | --- | --- | --- |
| PROMPT-01 | Ctrl-C at every wizard page returns cancelled | `fixtures/test_prompt.py:form` (Ctrl-C on pages 1-3); `tests/contract_tests.d:PROMPT-01 interrupt, Escape and EOF cancel every wizard page and the cleanup wipes partial secrets` | covered |
| PROMPT-01 | Partial secret answers are wiped | `PROMPT-01 ...` (after the `wipeAnswers` cleanup that `readGroup` runs on cancellation, an observer copy shows the secret closed and public values cleared) | added |
| PROMPT-01 | Terminal modes restored | `fixtures/test_prompt.py:finished` (exact termios, one alternate-screen enter/leave pair) | covered |
| PROMPT-02 | Password paste and editing leave no secret bytes in stdout/stderr | `fixtures/test_prompt.py:password` (paste, backspace, typed `!`); `fixtures/test_prompt.py:form` | covered |
| PROMPT-02 | No secret bytes in rendered output, feedback or Error.message | `tests/contract_tests.d:PROMPT-02 pasted and edited secrets never reach rendered output, feedback or diagnostics` | added |
| PROMPT-03 | Piped stdin into password() returns unsupported without hanging | `fixtures/test_prompt.py:password` (stdin and stdout piped, 4 s timeout; plus stdin piped with a terminal stdout: no escape bytes and unchanged termios) | added (terminal-stdout variant) |
| PROMPT-04 | Duplicate field keys fail with invalidArgument before terminal mutation | `tests/contract_tests.d:Duplicate or over-limit choices and field keys fail before terminal admission`; `PROMPT-04 duplicate values, keys and selection limits fail before any terminal is opened` | covered |
| PROMPT-04 | Duplicate choice values fail | both tests above (`select` and `multiSelect`) | covered |
| PROMPT-04 | Too many selections fail | both tests above (explicit limit and the default 64 over two choices) | covered |
| PROMPT-05 | Secret.clear twice is idempotent | `tests/contract_tests.d:Native secrets erase deleted graphemes and retire safely after a reentrant close`; `fixtures/wipe_test.c` (bytes are zero at `free`) | covered |
| PROMPT-05 | read after clear fails safely | same test and `A scoped consumer exception releases native storage before a later clear` | covered |
| PROMPT-06 | Only public fields populate Answer.value | `tests/contract_tests.d:PROMPT-06 a mixed wizard returns public values only and clear wipes the secret answer`; `fixtures/test_prompt.py:form` page 4 | added |
| PROMPT-06 | clear wipes all secret storage | `PROMPT-06 ...`; `Grouped response cleanup clears secret owners and empty required fields are keyed` | covered |
| Safety | Secret borrow escape and copy rejected at compile time | `negative/borrow_escape.d`, `negative/copy_secret.d` via `negative/check.py` | covered (runner added) |
| Fuzz | Secret edits over byte prefixes 0..256 | `tests/fuzz/secret_fuzz.d:Native secret editing stays bounded across arbitrary byte prefixes`; `fixtures/wipe_test.c` sizes up to 1 MiB + 1 | covered |

Stub review: none found. Off Linux the native secret functions return null/unsupported, which keeps every
secret prompt failing closed.
