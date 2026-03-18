# Sample files

Files for manual end-to-end testing in Emacs. Open a file, run `M-x flywrite-mode`, and verify diagnostics appear as expected.

| File | Description |
|------|-------------|
| `test00.txt` | Plain text with spelling, grammar, and style errors |
| `test01.md` | Markdown with multiple paragraphs of errors plus clean prose |
| `test02.tex` | LaTeX document with the same error paragraphs (should ignore markup) |
| `test03.tex` | Long LaTeX exam document with heavy markup, lists, and math (stress test for markup suppression) |
| `test04.tex` | Short LaTeX with an itemize list containing a spelling error |
| `test05.md` | Markdown with headings, blockquotes, a code block, and errors (should skip code blocks) |
| `test06.tex` | Minimal LaTeX exam with a solution block (should handle custom environments) |
| `test07.txt` | Two paragraphs: general errors (flagged by `prose`), then academic-only errors (flagged by `academic`) |
