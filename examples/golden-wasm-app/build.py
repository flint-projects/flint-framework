#!/usr/bin/env python3
"""Build the browser module against actual implemented BetterC package sources."""
import argparse,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
# examples/<app> in the monorepo; a flint checkout named by FLINT_ROOT otherwise (flint-framework).
import os
candidate=HERE.parents[2]
ROOT=Path(os.environ['FLINT_ROOT']) if os.environ.get('FLINT_ROOT') else candidate
def source(name):
    # In the monorepo every package is under packages/; in flint-framework the engines are under engine/.
    for path in (ROOT/'packages'/name/'source', HERE.parents[1]/'engine'/name.removeprefix('engine-')/'source'):
        if path.is_dir():return path
    return ROOT/'packages'/name/'source'
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--ldc',default='ldc2');ap.add_argument('--profile',choices=['O3','Oz'],default='Oz');ap.add_argument('--output',type=Path,default=HERE/'build/app.wasm');a=ap.parse_args()
    required=['arena','engine-wasm-bridge','engine-ui-signals']
    for n in required:
        if not list(source(n).rglob('*.d')):raise SystemExit(n+': implement Milestone4 dependencies before linking this template')
    a.output.parent.mkdir(parents=True,exist_ok=True)
    flags=[a.ldc,'-betterC','-mtriple=wasm32-unknown-unknown-wasm','-mattr=+bulk-memory','-'+a.profile,'-preview=dip1000','-boundscheck=on','-checkaction=halt','-link-internally','-i=flint','-L--no-entry','-L--export-memory','-of='+str(a.output),'-I'+str(HERE/'source')]
    flags += ['-I'+str(source(n)) for n in required]
    flags += ['-L--export='+n for n in ['flint_init','flint_tick','flint_buffer_ptr','flint_buffer_len']]
    flags += [str(p) for p in sorted((HERE/'source').rglob('*.d'))]
    subprocess.run(flags,check=True)
    print(a.output)
if __name__=='__main__':main()
