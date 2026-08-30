# HTML Report Format

Render the architecture review as a single self-contained HTML file in the OS temp directory. Tailwind and Mermaid both come from CDNs. Mermaid handles graph-shaped diagrams; hand-built divs and inline SVG handle editorial visuals like mass diagrams and cross-sections.

## Scaffold

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Architecture review - {{repo name}}</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script type="module">
      import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
      mermaid.initialize({ startOnLoad: true, theme: "neutral", securityLevel: "loose" });
    </script>
    <style>
      .seam { stroke-dasharray: 4 4; }
      .leak { stroke: #dc2626; }
      .deep { background: linear-gradient(135deg, #0f172a, #1e293b); }
    </style>
  </head>
  <body class="bg-stone-50 text-slate-900 font-sans">
    <main class="max-w-5xl mx-auto px-6 py-12 space-y-12">
      <header>...</header>
      <section id="candidates" class="space-y-10">...</section>
      <section id="top-recommendation">...</section>
    </main>
  </body>
</html>
```

## Header

Repo name, date, and a compact legend: solid box = module, dashed line = seam, red arrow = leakage, thick dark box = deep module. No introduction paragraph.

## Candidate Card

Each candidate is one `article`:

- Title: short, names the deepening.
- Badge row: recommendation strength plus dependency category.
- Files: monospaced list.
- Before / after diagram: the centerpiece.
- Problem: one sentence.
- Solution: one sentence.
- Wins: short bullets using glossary terms.
- ADR callout: one line when applicable.

If the diagram needs a paragraph to be understood, redraw the diagram.

## Diagram Patterns

Use Mermaid `flowchart`, `graph`, or sequence diagrams when the structure is graph-shaped. Use hand-built boxes and arrows when Mermaid's layout obscures the point.

Useful patterns:

- Cross-section: stacked bands showing layered shallowness.
- Mass diagram: interface size versus implementation size.
- Call-graph collapse: before as a spread tree, after as one deep module with internals faded.

## Style Guidance

- Editorial, not corporate-dashboard.
- Generous whitespace.
- One accent color plus red for leakage and amber for warnings.
- Diagrams around 320px tall.
- Use exact vocabulary from `LANGUAGE.md`: module, interface, implementation, depth, deep, shallow, seam, adapter, leverage, locality.
- Avoid component, service, API, signature, boundary, and generic "cleaner code" phrasing.

## Top Recommendation

One larger section. Candidate name, one sentence on why, and an anchor link to its card.
