"""Function spans, ported from tycho: braces in literals do not count."""
import re
START = re.compile(r"^\s*(?:(?:pub|inline|export|extern) )*fn\s+([A-Za-z_][A-Za-z_0-9]*)\b")


def code(line):
    """Braces outside strings, character literals and line comments."""
    if line.lstrip().startswith("\\\\"):
        return ""
    out = []
    quote = None
    escaped = False
    for i, char in enumerate(line):
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char == "/" and line[i : i + 2] == "//":
            break
        if char in ('"', "'"):
            quote = char
        else:
            out.append(char)
    return "".join(out)


def functions(path):
    lines = path.read_text().splitlines()
    for start, line in enumerate(lines):
        match = START.match(line)
        if not match:
            continue
        depth = 0
        opened = False
        for end in range(start, len(lines)):
            part = code(lines[end])
            if "{" in part:
                opened = True
            depth += part.count("{") - part.count("}")
            if opened and depth == 0:
                yield match.group(1), start + 1, end - start + 1
                break


