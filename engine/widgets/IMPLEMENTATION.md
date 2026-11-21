# Flint widgets

Widgets consume TUI events and draw through the current Frame. An application
chooses which widget receives input and retains the model’s state. Geometry
clips to the available terminal area, and an origin outside the frame returns
an error.

TextInput and TextArea retain UTF-8 byte limits and edit complete graphemes.
Shift movement extends a selection. A one-line paste converts logical line
breaks to spaces. A multiline paste preserves them as LF. Malformed bytes
display as replacement characters. TextInput password mode masks display.
For explicitly wiped storage, use Prompt’s password API.

Lists case-fold with the pinned Unicode provider when the filter changes.
Keep item IDs stable and replace the items slice whenever the snapshot changes.
The selected index is size_t.max when the snapshot has no selectable result.
Cached views traverse visible indices. Tables render the visible rectangle over
the caller’s row snapshot, and rows with fewer cells receive blank padding.

## Verification

```sh
dub test :widgets --compiler=dmd
dub test :widgets --compiler=ldc2
python3 tools/gates.py --package widgets --gate structural
dub build --root=packages/widgets/fixtures --compiler=ldc2
python3 packages/widgets/fixtures/test_snapshot.py packages/widgets/fixtures/build/test-widgets-pty
dub build --root=packages/widgets/bench --compiler=ldc2
packages/widgets/bench/build/probe-widgets --measure
```
