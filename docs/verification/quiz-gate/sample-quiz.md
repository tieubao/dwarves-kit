# Sample quiz (fixture A, ref d795f9d1ca1874e4f99c1d9326064ef8cb31dae8)

# 5-question understanding quiz for `d795f9d1ca1874e4f99c1d9326064ef8cb31dae8`
# Grounded in the ACTUAL diff + recorded test results, NOT any agent narrative.
# These questions are the payload for the deep-understand mastery gate, they are not scored here.

Q1. Background: this change is read in the order: docs/guide.md docs/specs/SPEC-900-widget.md docs/verification/widget/proof-of-done.md widget.js alpha.js tests/test-widget.sh. Start from `docs/guide.md` -- what existing context does the change build on, and why is that the reader's first stop?
Q2. Goal (off the diff): the change touches these files: docs/guide.md docs/specs/SPEC-900-widget.md docs/verification/widget/proof-of-done.md widget.js alpha.js tests/test-widget.sh. In your own words, what is the goal read OFF THE DIFF -- not off the commit message?
Q3. The new/changed code in `widget.js` introduces: function widget(){ return 42;  }. What does it actually do, and how is it wired into the rest of the change?
Q4. Verification: the recorded test result is: Recorded test result (from docs/verification/widget/proof-of-done.md): | AC1 | widget returns 42 | PASS | Exit: 0 . Does that proof actually exercise this change's behavior, or is there an uncovered path?
Q5. Blast radius / why: why was it resolved this way, and what breaks downstream if you misunderstand `widget.js`?
