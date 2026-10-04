"""Repository checks in their build order; configuration belongs to the caller."""
import argparse
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import textwrap

import casts
import lengths

ZIGLINT = "80d2b08a7eb4aa9c96e2b2183716b347dcacb64b"
TEST_FILE = re.compile(r"(^|/)([^/]*_tests?|test_[^/]*|tests|test_root)\.zig$")
IMPORT = re.compile(r'@import\("([^"\n]+\.zig)"\)')
TEST = re.compile(r'^\s*test\s*(?:"(?:\\.|[^"\\])*"\s*)?\{', re.M)


def excluded(path, patterns):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def files(config):
    return sorted({p for root in config.get("sources", ["src"]) for p in Path(root).rglob("*.zig")})


def layout(paths, config):
    """A namespace containing two implementation files has an adjacent entry."""
    errors = []
    exceptions = config.get('layout_exceptions', {})
    directories = {}
    for path in paths:
        name = path.as_posix()
        if TEST_FILE.search(name) or excluded(name, config.get("test_support", ["src/testing/*"])):
            continue
        directories.setdefault(path.parent, []).append(path)
    roots = {Path(root) for root in config.get("sources", ["src"])}
    for directory, members in sorted(directories.items()):
        if directory in roots or len(members) < 2:
            continue
        entries = [p for p in directory.parent.glob("*.zig") if p.stem.lower() == directory.name.lower()]
        exception = exceptions.get(directory.as_posix())
        if exception and exception.get('reason', '').strip() and sorted(p.as_posix() for p in members) == sorted(exception['files']):
            continue
        if len(entries) != 1:
            errors.append(f"{directory}: namespace has {len(members)} files; give it one adjacent {directory.name}.zig entry")
    return errors


def cast_policy(paths, config):
    errors = []
    exemptions = config.get("vendored", {})
    if any(not reason.strip() for reason in exemptions.values()):
        return ["vendored: each exemption needs its provenance and verification"]
    for path in paths:
        name = path.as_posix()
        if casts.TEST_FILE.search(name) or name in exemptions:
            continue
        errors.extend(f"{item}: cast needs // safe: <reason> on its line" for item in casts.findings(path))
    return errors


def function_lengths(paths, config):
    errors = []
    exemptions = config.get("function_exceptions", {})
    for path in paths:
        if path.as_posix() in config.get("vendored", {}):
            continue
        for name, line, count in lengths.functions(path):
            limit = config.get("function_limit", 120)
            for pattern, bound in config.get("function_limits", {}).items():
                if fnmatch.fnmatchcase(path.as_posix(), pattern):
                    limit = min(limit, bound)
            label = f"{path.as_posix()}:{name}"
            exception = exemptions.get(label)
            if exception and (not exception.get("reason", "").strip() or count > exception["lines"]):
                errors.append(f"{label}: exception is missing its reason or has grown")
            elif count > limit and not exception:
                errors.append(f"{path}:{line}: {name} is {count} lines (limit {limit})")
    return errors


def snippet(source, region, module, want_import=True, imports=None):
    text = Path(source).read_text(encoding="utf-8")
    marker = f"// --- README:{region} ---"
    parts = text.split(marker)
    if len(parts) != 3:
        raise ValueError(f"{source}: expected two {marker} markers")
    body = textwrap.dedent(parts[1]).strip("\n")
    prefix = ""
    if want_import:
        names = imports if imports is not None else [module]
        lines = [line for line in text.splitlines() if any(line.startswith(f"const {name} = @import(") for name in names)]
        if len(lines) != len(names):
            raise ValueError(f"{source}: expected one import of {module}")
        prefix = "\n".join(lines) + "\n\n"
    return "```zig\n" + prefix + body + "\n```\n"


BLOCK = re.compile(r"<!-- BEGIN GENERATED (?P<command>[^>]+?) -->\n(?P<body>.*?)<!-- END GENERATED[^>]*-->", re.S)


def docs(config):
    errors = []
    generators = config.get("docs", {})
    seen = set()
    for path in sorted(Path('.').glob('*.md')):
        for block in BLOCK.finditer(path.read_text(encoding="utf-8")):
            command = block["command"].strip()
            generator = generators.get(command)
            if generator is None:
                errors.append(f"{path}: generated block {command!r} has no ci/ configuration")
                continue
            seen.add(command)
            if "command" in generator:
                run = subprocess.run(generator["command"], capture_output=True, text=True)
                if run.returncode:
                    errors.append(f"{path}: generator failed: {run.stderr}")
                    continue
                wanted = run.stdout.replace("\r\n", "\n").rstrip("\n") + "\n"
            else:
                wanted = snippet(**generator)
            if wanted != block["body"]:
                errors.append(f"{path}: generated block {command!r} differs from its example")
    for command in generators.keys() - seen:
        errors.append(f"docs: configured block {command!r} is absent")
    return errors


def code_mask(text):
    """Blank literals and comments without moving code offsets."""
    lines = []
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith("\\\\"):
            lines.append(''.join('\n' if c == '\n' else ' ' for c in line))
            continue
        out = list(line)
        quote = None
        escaped = False
        for index, char in enumerate(line):
            if quote:
                out[index] = ' '
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
            elif char == '/' and line[index:index + 2] == '//':
                out[index:] = ['\n' if c == '\n' else ' ' for c in line[index:]]
                break
            elif char in ('"', "'"):
                quote = char
                out[index] = ' '
        lines.append(''.join(out))
    return ''.join(lines)


def imports(text):
    mask = code_mask(text)
    return [match.group(1) for match in IMPORT.finditer(text) if mask[match.start():].startswith('@import')]


def test_blocks(text):
    mask = code_mask(text)
    for start in re.finditer(r'^\s*test\s*\{', mask, re.M):
        opening = mask.index('{', start.start())
        depth = 0
        for end in range(opening, len(mask)):
            depth += (mask[end] == '{') - (mask[end] == '}')
            if depth == 0:
                yield text[start.start():end + 1]
                break


def test_imports(paths, config):
    errors = []
    roots = config.get("test_roots", [])
    if not roots:
        return ["test imports: configure test_roots in ci/preflight.json"]
    reached = set()
    pending = [Path(root) for root in roots]
    support = config.get('test_support', ['src/testing/*'])
    while pending:
        path = Path(os.path.normpath(pending.pop()))
        if path in reached:
            continue
        reached.add(path)
        if not path.is_file():
            errors.append(f"{path}: configured or imported test root is missing")
            continue
        text = path.read_text(encoding="utf-8")
        mask = code_mask(text)
        aliases = {}
        for match in re.finditer(r'(?:pub )?const (\w+) = @import\("([^"\n]+\.zig)"\)', text):
            if mask[match.start():].lstrip().startswith(('const ', 'pub const ')):
                aliases[match[1]] = match[2]
        for block in test_blocks(text):
            targets = imports(block)
            names = set(re.findall(r'\b\w+\b', code_mask(block)))
            if 'refAllDecls' in names or 'refAllDeclsRecursive' in names:
                names.update(aliases)
            targets += [target for alias, target in aliases.items() if alias in names]
            pending.extend(path.parent / target for target in targets)
    for path in paths:
        text = path.read_text(encoding="utf-8")
        if list(test_blocks(text)) and path not in reached:
            errors.append(f"{path}: tests are unreachable; name the file in a test block reached by a configured root")
        production = text
        for block in test_blocks(text):
            production = production.replace(block, '')
        if TEST_FILE.search(path.as_posix()) or excluded(path.as_posix(), support):
            continue
        for target in imports(production):
            resolved = os.path.normpath(path.parent / target).replace(os.sep, '/')
            if TEST_FILE.search(target) and not excluded(resolved, support):
                errors.append(f"{path}: production declaration imports test file {target}")
    return errors


def retry(command, cwd=None):
    import time
    for attempt in range(3):
        result = subprocess.run(command, cwd=cwd)
        if result.returncode == 0:
            return
        if attempt < 2:
            time.sleep(5 << attempt)
    raise RuntimeError(f"command failed after three attempts: {command}")


DIAGNOSTIC = re.compile(r'^(Z[0-9]+): (.+?):([0-9]+): (.*?)(?=^Z[0-9]+: |\Z)', re.M | re.S)


def ziglint_diagnostics(output):
    return [{'rule': match[1], 'path': match[2].replace('\\', '/'),
             'line': int(match[3]), 'detail': match[4].strip()} for match in DIAGNOSTIC.finditer(output)]


def ziglint_findings(output, exceptions):
    from collections import Counter
    if any(not item.get('reason', '').strip() for item in exceptions):
        return ['ziglint: each exception needs a reason']
    allowed = Counter((item['rule'], item['path'], item['source'], item['detail']) for item in exceptions)
    diagnostics = ziglint_diagnostics(output)
    if output.strip() and not diagnostics:
        return [output.strip()]
    prefix = output[:output.find(diagnostics[0]['rule'] + ':')] if diagnostics else ''
    if prefix.strip():
        return [prefix.strip()]
    errors = []
    for item in diagnostics:
        path = Path(item['path'])
        source = path.read_text(encoding='utf-8').splitlines()[item['line'] - 1].strip() if path.is_file() else ''
        key = (item['rule'], item['path'], source, item['detail'])
        if allowed[key]:
            allowed[key] -= 1
        else:
            errors.append(f"{item['rule']}: {item['path']}:{item['line']}: {item['detail']}")
    return errors


def ziglint(paths, config):
    executable = os.environ.get("PREFLIGHT_ZIGLINT")
    if executable is None:
        cache = Path(os.environ.get("PREFLIGHT_TOOL_CACHE", ".zig-cache/preflight-tools")) / ZIGLINT
        executable = str((cache / 'bin' / ('ziglint.exe' if os.name == 'nt' else 'ziglint')).resolve())
        if not Path(executable).exists():
            source = cache / 'src'
            source.mkdir(parents=True, exist_ok=True)
            subprocess.run(['git', 'init', '-q', str(source)], check=True)
            retry(['git', 'fetch', '--depth', '1', 'https://github.com/rockorager/ziglint', ZIGLINT], cwd=source)
            subprocess.run(['git', 'checkout', '--detach', ZIGLINT], cwd=source, check=True)
            retry(['zig', 'build', '-Doptimize=ReleaseSafe', '--prefix', str(cache.resolve())], cwd=source)
    result = subprocess.run([executable, '--ignore', 'Z024', *map(str, paths)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    exceptions = json.loads(Path(config['ziglint_exceptions']).read_text()) if config.get('ziglint_exceptions') else []
    errors = ziglint_findings(result.stdout, exceptions)
    if result.returncode and not result.stdout.strip():
        errors.append('ziglint: command failed without diagnostics')
    if exceptions and not errors:
        print('ziglint: existing exceptions checked; no new findings')
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--render')
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    if args.render:
        key = 'zig build docs -- ' + args.render
        generator = config.get('docs', {}).get(key)
        if not generator:
            parser.error(f'no documentation region {args.render!r}')
        if 'command' in generator:
            return subprocess.run(generator['command']).returncode
        print(snippet(**generator), end='')
        return 0
    paths = files(config)
    stages = [
        ('ziglint', lambda: ziglint([Path(p) for p in config.get('ziglint_paths', ['src', 'examples', 'ci', 'build.zig']) if Path(p).exists()], config)),
        ('namespace layout', lambda: layout(paths, config)),
        ('cast reasons', lambda: cast_policy(paths + [Path('build.zig')], config)),
        ('function length', lambda: function_lengths(paths, config)),
        ('documentation', lambda: docs(config)),
        ('test imports', lambda: test_imports(paths, config)),
    ]
    for name, check in stages:
        print(f'preflight: {name}', flush=True)
        errors = check()
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
    for command in config.get('extra_checks', []):
        subprocess.run(command, check=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
