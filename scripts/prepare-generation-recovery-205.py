#!/usr/bin/env python3
"""Build an exact, local-only overlay on the reviewed live generation servers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'experiments/supabase-game-core'
PROJECT = 'bbkfsgnordtdiblgdzkg'
APP = '69a0e57fa939f578082f8091'
BASE = '5fb622dc31dee664915a6d51dcb134f391b4ef9f'
LIVE_SHA = '9201d809348553ec44d89a880e5f4fd862ed47b30e6b4916520429d90aa006c5'
OVERLAY = ['app-services/index.ts', 'app-services/native-ai-relay.ts',
           'app-services/native-ai-relay-protocol.ts', 'app-services/native-generation.ts',
           'app-services/router.ts']
MIGRATION = '20261101130901_native_generation_failure_recovery.sql'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)

def json_file(path, value):
    write(path, json.dumps(value, indent=2, sort_keys=True) + '\n')

def baseline(relative):
    return subprocess.check_output(['git', 'show', BASE + ':' + relative], cwd=ROOT).decode()

def prepare(args):
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / '.local').resolve()) or output.exists():
        raise ValueError('Use a new output directory below this worktree .local')
    live = json.loads(args.live_supabase.read_text())
    if live['slug'] != 'app-services' or live['version'] != 16 or live['ezbr_sha256'] != LIVE_SHA or live['verify_jwt'] is not True:
        raise ValueError('Live app-services differs from the reviewed version; review and rebase first')
    original = {file['name']: file['content'] for file in live['files']}
    if len(original) != len(live['files']) or any(Path(p).is_absolute() or '..' in Path(p).parts for p in original):
        raise ValueError('Duplicate or unsafe live source path')
    candidate = dict(original)
    for name in OVERLAY:
        relative = 'experiments/supabase-game-core/supabase/functions/' + name
        if name in original and original[name].rstrip() != baseline(relative).rstrip():
            raise ValueError('Changed live baseline for ' + name)
        if name not in original and name != 'app-services/router.ts':
            raise ValueError('Unexpected new source ' + name)
        candidate[name] = (ROOT / relative).read_text()
    for label, files in [('candidate', candidate), ('rollback', original)]:
        for name, content in files.items():
            write(output / label / 'supabase/functions' / name, content)
        json_file(output / label / 'supabase-deploy.json', {
            'project_id': PROJECT, 'name': 'app-services', 'verify_jwt': True,
            'entrypoint_path': 'app-services/index.ts', 'import_map_path': 'app-services/deno.json',
            'files': [{'name': name, 'content': content} for name, content in sorted(files.items())],
        })
    remote = args.live_base44.resolve()
    configuration = json.loads((remote / 'function.jsonc').read_text())
    if configuration != {'name': 'nativeGameCenterWordPack', 'entry': 'base44/functions/nativeGameCenterWordPack/entry.ts'}:
        raise ValueError('Unexpected Base44 source layout')
    runtime = remote / 'base44/functions/nativeGameCenterWordPack'
    names = {p.name for p in runtime.iterdir() if p.is_file()}
    expected = {'entry.ts', 'handler.ts', 'relay-protocol.ts', 'base44-context.ts', 'openai-word-pack-provider.ts', 'word-pack-quality.ts'}
    if names != expected:
        raise ValueError('Unexpected Base44 runtime files')
    for name in names:
        local_name = 'main.ts' if name == 'entry.ts' else name
        relative = 'base44/functions/nativeGameCenterWordPack/' + local_name
        deployed = (runtime / name).read_text()
        if deployed.rstrip() != baseline(relative).rstrip():
            raise ValueError('Base44 baseline changed: ' + name)
        for label in ['candidate', 'rollback']:
            content = (ROOT / relative).read_text() if label == 'candidate' and name in {'handler.ts', 'relay-protocol.ts'} else deployed
            write(output / label / 'base44/functions/nativeGameCenterWordPack' / name, content)
    for label in ['candidate', 'rollback']:
        json_file(output / label / 'base44/config.jsonc', {'name': 'SpyClash generation recovery'})
        json_file(output / label / 'base44/.app.jsonc', {'id': APP})
        json_file(output / label / 'base44/functions/nativeGameCenterWordPack/function.jsonc', {'name': 'nativeGameCenterWordPack', 'entry': 'entry.ts'})
    write(output / 'candidate' / MIGRATION, (CORE / 'supabase/migrations' / MIGRATION).read_text())
    files = {str(p.relative_to(output)): sha(p.read_bytes()) for p in output.rglob('*') if p.is_file()}
    manifest = {'build': 205, 'base_commit': BASE, 'supabase_project': PROJECT, 'base44_app': APP,
                'live_app_services_version': 16, 'live_app_services_sha': LIVE_SHA,
                'supabase_overlay': OVERLAY, 'migration': MIGRATION, 'files': dict(sorted(files.items())),
                'preserved_live_differences': ['app-services/push.ts', 'app-services/worker.ts', 'full-game-core/engine.ts']}
    json_file(output / 'manifest.json', manifest)
    print(json.dumps({'output': str(output), 'manifest_sha256': sha((output / 'manifest.json').read_bytes()), 'file_count': len(files)}))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live-supabase', type=Path, required=True)
    parser.add_argument('--live-base44', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    prepare(parser.parse_args())
