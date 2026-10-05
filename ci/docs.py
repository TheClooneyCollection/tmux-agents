#!/usr/bin/env python3
"""Offline documentation contract checks. Run from any working directory."""
import re
import sys
import unicodedata
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SECTIONS = [
    (1, "tmux-agents", "tmux-agents"),
    (2, "Screenshots", "截图"),
    (2, "Install", "安装"),
    (3, "By hand", "手动安装"),
    (3, "If popups feel slow", "如果 popup 打开很慢"),
    (2, "Configuration", "配置"),
    (2, "Quick start", "快速上手"),
    (2, "Keys", "快捷键"),
    (2, "Commands", "命令"),
    (2, "License", "许可证"),
]
# Explicit translation pairs, not wholesale comment stripping: new or changed
# shell comments must be reviewed and added here alongside both READMEs.
COMMENTS = {
    "# 先加 --dry-run 看看它会做什么": "# --dry-run to see what it does first",
    "# 换成你的 shell；和 --no-config / --norc / -f 的结果对比":
        "# use your shell; compare with --no-config / --norc / -f",
}
errors = []


def check(condition, message):
    if not condition:
        errors.append(message)


def parse(text, label):
    headings, blocks, prose = [], [], []
    fence = None
    body = []
    section = -1
    for line in text.splitlines():
        match = re.match(r"^(`{3,}|~{3,})(.*)$", line)
        if fence:
            if match and match[1][0] == fence[0] and len(match[1]) >= len(fence) and not match[2].strip():
                blocks.append((section, language, "\n".join(body)))
                fence = None
            else:
                body.append(line)
            continue
        if match:
            fence, language = match[1], match[2].strip()
            body = []
            continue
        prose.append(line)
        match = re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        if match:
            headings.append((len(match[1]), match[2]))
            section += 1
    check(fence is None, f"{label}: unclosed code fence")
    return headings, blocks, "\n".join(prose)


def normal_blocks(blocks):
    result = []
    for section, language, body in blocks:
        if language in ("sh", "bash", "shell"):
            for chinese, english in COMMENTS.items():
                body = body.replace(chinese, english)
        result.append((section, language, body))
    return result


def links(prose):
    # Inline links/images, reference definitions, and HTML images/anchors.
    found = re.findall(r"!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+[^)]*)?\)", prose)
    found += re.findall(r"^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)", prose, re.M)
    found += re.findall(r"""(?:src|href)=["']([^"']+)["']""", prose)
    return [item.strip("<>") for item in found]


def anchors(path):
    headings, _, prose = parse(path.read_text(), str(path.relative_to(ROOT)))
    used, result = {}, set()
    for _, heading in headings:
        heading = re.sub(r"<[^>]*>", "", heading).lower()
        # GitHub heading IDs retain hyphens/underscores, remove punctuation,
        # and suffix repeated headings with -1, -2, etc.
        slug = "".join(c for c in heading if c in "-_" or
                       not unicodedata.category(c).startswith(("P", "S")))
        slug = slug.replace(" ", "-")
        count = used.get(slug, 0)
        used[slug] = count + 1
        result.add(slug if not count else f"{slug}-{count}")
    result.update(re.findall(r"""(?:id|name)=["']([^"']+)["']""", prose))
    return result


readmes = [ROOT / "README.md", ROOT / "README.zh-CN.md"]
parsed = [parse(path.read_text(), path.name) for path in readmes]
for index, (headings, _, _) in enumerate(parsed):
    expected = [(level, row[index]) for level, *row in SECTIONS]
    check(headings == expected, f"{readmes[index].name}: section levels/order differ: {headings}")
check(normal_blocks(parsed[0][1]) == normal_blocks(parsed[1][1]),
      "README code blocks differ (including section placement); review explicit comment translations")
# Language switches intentionally point at opposite README files.
def readme_links(prose):
    return [x for x in links(prose) if x not in ("README.md", "README.zh-CN.md")]

check(readme_links(parsed[0][2]) == readme_links(parsed[1][2]), "README links/images differ")
files = sorted(set(readmes + list(ROOT.glob("*.md"))
                   + list((ROOT / "docs").rglob("*.md"))
                   + list((ROOT / "skills").rglob("*.md"))))
for path in files:
    text = path.read_text()
    check("\u2014" not in text, f"{path.relative_to(ROOT)}: em dash")
    _, _, prose = parse(text, str(path.relative_to(ROOT)))
    for target in links(prose):
        url = urlsplit(target)
        if url.scheme or url.netloc:
            continue
        dest = (path.parent / unquote(url.path)).resolve() if url.path else path
        check(dest == ROOT or ROOT in dest.parents, f"{path.relative_to(ROOT)}: link escapes repository: {target}")
        check(dest.exists(), f"{path.relative_to(ROOT)}: broken relative link: {target}")
        if dest.is_file() and dest.suffix == ".md" and url.fragment:
            check(unquote(url.fragment) in anchors(dest),
                  f"{path.relative_to(ROOT)}: broken heading link: {target}")
changelog = (ROOT / "CHANGELOG.md").read_text()
sections = re.findall(r"^## (.+)$", changelog, re.M)
check(bool(sections) and sections[0] == "Unreleased" and sections.count("Unreleased") == 1,
      "CHANGELOG.md must have exactly one Unreleased section before releases")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Documentation checks passed ({len(files)} Markdown files)")
