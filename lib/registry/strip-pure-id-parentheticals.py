#!/usr/bin/env python3
"""Strip PURE-ID parentheticals from living docs. Conservative by design.

Only touches a parenthetical whose entire content is ids and separators, e.g.
  "... the ship gate (SPEC-016)."        -> "... the ship gate."
  "... composition (SPEC-074 / ID-066)"  -> "... composition"
A mixed parenthetical like "(ADR-0028 P2/P3, kit-hardening SG-08)" is LEFT ALONE and
reported: stripping only the id there leaves "(P2/P3, kit-hardening)", which is worse
than what it replaced. Those need a human sentence, not a regex.
"""
import re, sys, pathlib

ID = r'(?:SPEC|TASK|ADR|SG|DEC|ID|PR)-\d+'
# whole parenthetical is ids + separators only
PURE = re.compile(r'[ \t]*\((?:' + ID + r')(?:[\s,;/&]+(?:and\s+)?(?:' + ID + r'))*\)')
# any parenthetical containing an id (to count the mixed remainder)
ANY = re.compile(r'\((?:[^()]*?)' + ID + r'(?:[^()]*?)\)')

def run(paths, apply_changes):
    tot_pure = tot_mixed = 0
    for p in paths:
        f = pathlib.Path(p)
        if not f.exists():
            print(f"  skip (missing): {p}"); continue
        src = f.read_text()
        out, n = PURE.subn('', src)
        # Tidy, but ONLY where the punctuation ENDS a token. A naive rule turned
        # "any .sh file" into "any.sh file", because a leading-dot filename looks
        # exactly like a stray space before a full stop. Require whitespace or
        # end-of-line after the punctuation mark.
        out = re.sub(r'[ \t]+([.,;:)])(?=\s|$)', r'\1', out)
        # No space-collapsing pass. These docs are full of ASCII diagrams and aligned
        # tables where a run of spaces is layout, not slop. PURE already eats its own
        # leading whitespace, so nothing needs collapsing.
        mixed = len(ANY.findall(out))
        tot_pure += n; tot_mixed += mixed
        if apply_changes and n:
            f.write_text(out)
        print(f"  {p:34s} stripped={n:3d}  mixed_left={mixed:3d}")
    print(f"\n  TOTAL stripped={tot_pure}  mixed parentheticals left for a human={tot_mixed}")

if __name__ == '__main__':
    apply_changes = '--apply' in sys.argv
    files = [a for a in sys.argv[1:] if not a.startswith('--')]
    print("APPLY" if apply_changes else "DRY RUN")
    run(files, apply_changes)
