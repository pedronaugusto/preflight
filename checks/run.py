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
TEST_FILE = re.compile(r"(^|/)([^/]*_test|test_[^/]*|tests|test_root)\.zig$")
IMPORT = re.compile(r'@import\("([^"\n]+\.zig)"\)')
TEST = re.compile(r'^\s*test\s*(?:"(?:\\.|[^"\\])*"\s*)?\{', re.M)


def excluded(path, patterns):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def files(config):
    return sorted({p for root in config.get("sources", ["src"]) for p in Path(root).rglob("*.zig")})


def layout(paths, config):
    """A namespace containing two implementation files has an adjacent entry."""
    errors = []
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


def snippet(source, region, module, want_import=True):
    text = Path(source).read_text(encoding="utf-8")
    marker = f"// --- README:{region} ---"
    parts = text.split(marker)
    if len(parts) != 3:
        raise ValueError(f"{source}: expected two {marker} markers")
    body = textwrap.dedent(parts[1]).strip("\n")
    prefix = ""
    if want_import:
        imports = [line for line in text.splitlines() if line.startswith(f"const {module} = @import(")]
        if len(imports) != 1:
            raise ValueError(f"{source}: expected one import of {module}")
        prefix = imports[0] + "\n\n"
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


def test_blocks(text):
    for start in TEST.finditer(text):
        depth = 0
        body = []
        for line in text[start.start():].splitlines():
            part = lengths.code(line)
            depth += part.count('{') - part.count('}')
            body.append(line)
            if depth == 0:
                break
        yield '\n'.join(body)


def test_imports(paths, config):
    errors = []
    roots = config.get("test_roots", [])
    if not roots:
        return ["test imports: configure test_roots in ci/preflight.json"]
    reached = set()
    pending = [Path(root) for root in roots]
    while pending:
        path = pending.pop()
        path = Path(os.path.normpath(path))
        if path in reached:
            continue
        reached.add(path)
        if not path.is_file():
            errors.append(f"{path}: configured or imported test root is missing")
            continue
        text = path.read_text(encoding="utf-8")
        aliases = dict(re.findall(r'(?:pub )?const (\w+) = @import\("([^"\n]+\.zig)"\)', text))
        for block in test_blocks(text):
            targets = IMPORT.findall(block)
            targets += [aliases[name] for name in re.findall(r'_ = (\w+);', block) if name in aliases]
            pending.extend(path.parent / target for target in targets)
    for path in paths:
        text = path.read_text(encoding="utf-8")
        if TEST.search(text) and path not in reached:
            errors.append(f"{path}: tests are unreachable; name the file in a test block reached by a configured root")
        # Production declarations must never acquire a test-only dependency.
        production = text
        for block in test_blocks(text):
            production = production.replace(block, '')
        for target in IMPORT.findall(production):
            if TEST_FILE.search(target):
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


def ziglint(paths):
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
    sys.stdout.write(result.stdout)
    return [] if result.returncode == 0 else ['ziglint: source rules failed']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    paths = files(config)
    stages = [
        ('ziglint', lambda: ziglint(paths)),
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
