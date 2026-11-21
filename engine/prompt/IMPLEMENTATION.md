# Flint prompts

Standalone prompts own a single Term session. A nested attempt returns the
terminal owner’s conflict. Cancellation returns cancelled. Public input and
forms can opt into redirected line input through FormOptions. Passwords and
forms with secret fields require a terminal.

Secret owns a thread-confined native allocation. Its read callback may inspect
borrowed bytes during the call. Call clear after use, or place it in scope(exit).
Clear invalidates the handle and wipes the allocation using explicit_bzero.
If a reader calls clear, the allocation retires after that reader returns.
Grouped forms expose secret values only through each answer’s Secret field.
Use clear on the answer slice to wipe every active secret.

The prompt edits the password in native storage and draws a grapheme mask.
Term’s owned paste event delivers the transient input before Prompt consumes
it. Native zeroization covers Prompt’s allocation and key-encoding scratch.
Grouped validation reports the field key. Field keys and selectable values
must be unique. Multi-select accepts an explicit limit up to the choice count.

## Verification

```sh
dub test :prompt --compiler=dmd
dub test :prompt --compiler=ldc2
python3 tools/gates.py --package prompt --gate structural
dub build --root=packages/prompt/fixtures --compiler=ldc2
python3 packages/prompt/fixtures/test_prompt.py packages/prompt/fixtures/build/test-prompt-pty
dub build --root=packages/prompt/bench --compiler=ldc2
packages/prompt/bench/build/probe-prompt --measure
```
