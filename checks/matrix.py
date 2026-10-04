"""Build the fast or full matrix from repository-owned facts."""
import argparse
import json
from pathlib import Path

HOSTS = ['ubuntu-latest', 'macos-latest', 'windows-latest']


def balance(shards, count):
    """Longest processing time first; each named case is assigned exactly once."""
    groups = [[] for _ in range(min(count, len(shards)))]
    weights = [0] * len(groups)
    for shard in sorted(shards, key=lambda item: (-item['seconds'], item['name'])):
        index = min(range(len(groups)), key=lambda i: (weights[i], i))
        groups[index].append(shard['name'])
        weights[index] += shard['seconds']
    return groups


def matrix(config, full):
    jobs = []
    shards = config.get('windows_shards', [])
    for host in HOSTS:
        modes = ['Debug', 'ReleaseSafe'] if full else ['Debug']
        if full and host == 'ubuntu-latest':
            modes.append('ReleaseFast')
        for mode in modes:
            cases = balance(shards, config.get('shard_jobs', 5)) if host == 'windows-latest' and shards else [[]]
            for index, group in enumerate(cases):
                jobs.append({'os': host, 'name': f'test ({host}, {mode})' + (f' shard {index + 1}' if group else ''),
                             'step': 'ci', 'args': f'-Doptimize={mode} -Dci-lint=false', 'cases': ' '.join(group),
                             'timeout': config.get('test_timeout', ''), 'setup': True})
    jobs.append({'os': 'ubuntu-latest', 'name': 'source checks and documented snippets', 'step': 'lint',
                 'args': '', 'cases': '', 'timeout': '', 'setup': False})
    if full:
        jobs.append({'os': 'ubuntu-latest', 'name': 'compile (ReleaseSmall)', 'step': config.get('compile_step', 'check'),
                     'args': '-Doptimize=ReleaseSmall', 'cases': '', 'timeout': '', 'setup': False})
        for target in config.get('targets', []):
            target = {'target': target} if isinstance(target, str) else target
            args = '-Dtarget=' + target['target'] + (' -Dcpu=' + target['cpu'] if 'cpu' in target else '')
            jobs.append({'os': 'ubuntu-latest', 'name': 'cross (' + args + ')', 'step': config.get('compile_step', 'check'),
                         'args': args, 'cases': '', 'timeout': '', 'setup': False})
        if config.get('sanitizer'):
            jobs.append({'os': 'ubuntu-latest', 'name': 'ThreadSanitizer (Linux)', 'step': config['sanitizer'],
                         'args': '-Dthread-sanitizer -Doptimize=Debug', 'cases': '',
                         'timeout': '--test-timeout 120s', 'setup': True})
    return {'include': jobs}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default='ci/workflow.json')
    parser.add_argument('--full', action='store_true')
    parser.add_argument('--output')
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    value = json.dumps(matrix(config, args.full), separators=(',', ':'))
    if args.output:
        with open(args.output, 'a') as output:
            output.write('matrix=' + value + '\n')
    else:
        print(value)
