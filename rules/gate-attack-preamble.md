## ATTACK 0 — ONE-ROUND EXHAUSTIVE REVIEW (read first; applies to every item below)
This is the ONLY review round. A second round that finds another defect of a kind you could have found now is a review failure. So:
- Do NOT stop at the first P1/P2. Finish every item and report ALL findings in one pass, severity-ranked.
- Build the matrix BEFORE judging: (a) every route/reader/strategy/format that reaches the changed code, (b) every input class: empty, one row, NULL, BOM, padded/quoted/blank-first-line, mixed case, duplicate-by-case, huge/wide, out-of-range, wrong type, multi-file/glob, restart/replay. For each cell state "verified by code at file:line" or "finding". An empty cell is a finding.
- For every new check/parser/predicate, find the code the real route uses for the same thing and diff the semantics character by character (trim, BOM, quoting, case, blank lines, delimiter). Divergence = finding.
- For every loop on the data path, list what is batch-constant but recomputed per row (lookups by name, allocations, formatted errors).
- For every fix in the diff, ask "what is the sibling site with the same shape?" and grep for it. Unswept sibling = finding.
- For every new test: would it fail if the production change were reverted? If you cannot tell, say so.
- Do not report style. Do not repeat a finding at several sites; list the sites in one finding.
- End with a coverage statement: which matrix cells you verified, which you could not (and why).
