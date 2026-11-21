# Terminal styling and layout

`flint.style` measures UTF-8 in display cells, renders styled boxes, composes blocks, and truncates at grapheme boundaries. Its Unicode properties and grapheme breaks come from the pinned utf8proc 2.12.0 provider with Unicode 18.0.0 tables. The D layer supplies terminal width policy for ambiguous-width text, combining marks, and emoji.

`render(text, style, width, height)` fits the box to an explicit height so vertical alignment can place its contents. The width-only overload derives height from the input and insets. Rendering replaces malformed UTF-8 and raw terminal controls. Joins and truncation recognize the bounded SGR sequences emitted by the renderer and reset styles at row boundaries. Measurement treats those sequences as zero-width. Layouts enforce a 16,384-cell dimension limit and a 16 MiB output limit.

The Linux tests cover the Unicode snapshot, clipping, escape handling, alignment, joins, and deterministic malformed-input seeds up to 1 MiB. The feature and provider-reference probes report processed cells, elapsed time, allocation bytes, and an output checksum for ASCII, CJK, and grapheme-rich input.

```sh
python3 tools/native_build.py --target linux-x86_64-glibc --library utf8proc --phase build --emit-dub
dub test :style --compiler=dmd
dub test :style --compiler=ldc2
python3 tools/gates.py --package style --gate structural
```
