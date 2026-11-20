# Manual pages

These pages are Markdown that **dkman** and **dkde-help** render directly (and that
convert to man(7) with any Markdown-to-man tool). Format, set by `template.md`:

- Level-1 headings are the man sections: `# NAME`, `# SYNOPSIS`, `# DESCRIPTION`, ...
  There is no `%` title block.
- The synopsis is an indented code block (four spaces).
- Options and definitions use the `term` / `: definition` form.
- Tables are pipe tables; dkman draws them as grids.
- One paragraph per block, separated by blank lines.
- When installed, a page is named `NAME.SECTION.md` (for example `uname.1.md`), which
  is how dkman finds it next to the system pages. In the repository the file is
  `NAME.md`; the install step adds the section.

`tools/mdman-convert.py PAGE.md > NEW.md` converts an older page (with a `%` title
block, bare ALL-CAPS section lines and tab-separated tables) to this format. Check a
page with `dkman -l docs/manpages/NAME.md`.
