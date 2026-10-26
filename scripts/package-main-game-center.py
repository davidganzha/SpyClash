#!/usr/bin/env python3
"""Prepare and optionally test a local-only minimal main Game Center package.

Never reads credentials or calls a cloud API. Inputs are read-only MCP source
exports from the two explicitly pinned live versions. No workspace source is
reverted. Only the generated entry point disables inherited legacy deletion.
"""
import argparse
import difflib
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / 'experiments/supabase-game-core'
PINNED = {
    'app-services': (10, '8ad7217a4f3b78897d7ab09e728ede06f59878e4d1573dfd5e23af1fa9cce912'),
    'full-game-core': (7, '08e8ed8cb61a627e2c20868e093b1b15ab424527440e383b7f9f629e9bf20625'),
}
FROZEN = {
    'full-game-core/engine.ts': 'ad286a3595049ea2b7fe443808bd6b03a3bf337fe2c1678bda858902710f3c38',
    'app-services/push.ts': '3aa68c2923ccf5bf1f92e21f3b0c7db38feaaa19bcccb5ebc6d0880f76c66d49',
    'app-services/worker.ts': '39c4fe2a8de896f186fde180a891c98ac95e5b1f60913626bae0f822aa6e77d1',
    'app-services/live-activity-policy.ts': '842d779d6ed126b6876fb7545bd78017938c08bbfc24736c72236780bd62fea0',
}
MIGRATIONS = ['20261013010810_main_account_deletion_intent.sql', '20261026172415_main_game_center_identity.sql']
IMPORT = re.compile(r'''(?:from\s*|import\s*\(\s*|import\s*)["'](\.[^"']+)["']''')

def sha(value):
    return hashlib.sha256(value).hexdigest()

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')

def baseline(directory):
    exports, combined = {}, {}
    for slug, (version, fingerprint) in PINNED.items():
        value = json.loads((directory / f'{slug}-v{version}.json').read_text())
        files = {f['name']: f['content'] for f in value['files']}
        if len(files) != len(value['files']):
            raise RuntimeError('Duplicate exported source path')
        normalized = {'slug':value['slug'], 'version':value['version'], 'ezbr_sha256':value['ezbr_sha256'],
                      'files':{name:sha(content.encode()) for name, content in files.items()}}
        if sha(json.dumps(normalized, sort_keys=True, separators=(',', ':')).encode()) != fingerprint:
            raise RuntimeError(f'{slug}: deployed source differs from the reviewed live version')
        for name, content in files.items():
            if Path(name).is_absolute() or '..' in Path(name).parts:
                raise RuntimeError('Unsafe exported source path')
            if name in combined and combined[name] != content:
                raise RuntimeError(f'Deployed functions disagree on shared file {name}')
            combined[name] = content
        exports[slug] = normalized
    for name, expected in FROZEN.items():
        if sha(combined[name].encode()) != expected:
            raise RuntimeError(f'Frozen live source changed: {name}')
    return exports, combined

def dependency_files(functions, entry):
    pending, found = [entry], set()
    while pending:
        name = pending.pop()
        if name in found:
            continue
        file = (functions / name).resolve()
        if not file.is_relative_to(functions.resolve()) or not file.is_file():
            raise RuntimeError(f'Missing or escaping function dependency: {name}')
        found.add(name)
        for imported in IMPORT.findall(file.read_text()):
            target = (file.parent / imported).resolve()
            if not target.is_relative_to(functions.resolve()):
                raise RuntimeError(f'Escaping function dependency: {imported}')
            pending.append(str(target.relative_to(functions.resolve())))
    return sorted(found)

def prepare(args):
    destination = args.output.resolve()
    if not destination.is_relative_to((ROOT / '.local').resolve()) or destination.name != 'server-source':
        raise RuntimeError('Output must be a server-source directory beneath this worktree .local')
    exports, live = baseline(args.deployed.resolve())
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    functions = destination / 'supabase/functions'
    for name in ['app-services', 'full-game-core', 'game-center-session']:
        shutil.copytree(CORE / 'supabase/functions' / name, functions / name,
                        ignore=shutil.ignore_patterns('node_modules', '.DS_Store'))
    for name in FROZEN:
        (functions / name).write_text(live[name])
    entry = functions / 'app-services/index.ts'
    original = 'const config = Deno.env.toObject();'
    replacement = "const config = {...Deno.env.toObject(), APP_MAIN_ACCOUNT_DELETION_ENABLED:'false'};"
    content = entry.read_text()
    if content.count(original) != 1:
        raise RuntimeError('App entry point changed; review the legacy-deletion pin before packaging')
    entry.write_text(content.replace(original, replacement))
    for relative in ['package.json', 'package-lock.json', 'GAME-CENTER-MAIN.md', 'supabase/config.toml',
                     'scripts/game-center-local.mjs', 'tests/app-services/native-game-center-billing.test.mjs']:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CORE / relative, target)
    for name in MIGRATIONS:
        target = destination / 'supabase/migrations' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CORE / 'supabase/migrations' / name, target)
    for name in ['game-center', 'full-core-engine']:
        shutil.copytree(CORE / 'tests' / name, destination / 'tests' / name)
    deployments, changes, patch = {}, {}, []
    for slug in ['app-services', 'full-game-core', 'game-center-session']:
        names = dependency_files(functions, f'{slug}/index.ts')
        names += [f'{slug}/deno.json', f'{slug}/deno.lock']
        deployments[slug] = {'entrypoint_path':f'{slug}/index.ts', 'import_map_path':f'{slug}/deno.json',
                            'verify_jwt':slug != 'game-center-session', 'files':sorted(set(names))}
        before = exports.get(slug, {}).get('files', {})
        planned = {name:sha((functions/name).read_bytes()) for name in names}
        changed = [name for name in planned if name in before and planned[name] != before[name]]
        added = sorted(set(planned)-set(before))
        changes[slug] = {'deployed_version':exports.get(slug, {}).get('version'), 'changed':sorted(changed),
                         'added':added, 'not_in_planned_dependency_graph':sorted(set(before)-set(planned)),
                         'unchanged':sorted(name for name in planned if before.get(name) == planned[name])}
        for name in sorted(changed + added):
            patch += difflib.unified_diff(live.get(name, '').splitlines(True), (functions/name).read_text().splitlines(True),
                                         fromfile=f'{slug}@live/{name}', tofile=f'{slug}@planned/{name}')
    write_json(destination/'deployed-vs-planned.json', changes)
    (destination/'deployed-vs-planned.patch').write_text(''.join(patch))
    (destination/'PACKAGE-README.md').write_text('''# Minimal main Game Center source package

Generated by scripts/package-main-game-center.py from the reviewed worktree and
pinned app-services v10 / full-game-core v7 read-only exports. No deployment.
The live engine, push, worker and live-activity policy are frozen byte-for-byte.
Host transfer and the pending main-bundle push relay are NOT activated here.
Only the generated app-services entry point pins legacy full-account deletion
off; the same config reaches its maintenance handler. Native GC deletion runs
before that legacy gate. Working-tree source is preserved for a future release.

Apply only the two listed additive migrations, in manifest order, after separate
production approval. For each function deploy exactly the manifest dependency
files and settings, not an arbitrary directory or every file in this archive.
Existing APP_PUSH flags are not modified. Game Center, native billing and AI
still require their separately approved runtime flags and credentials.

Tests run against this exact overlay: 31 genuine local Auth/Postgres GC/AI/history
checks, native billing tests, and 15 existing engine/leaderboard tests. The two
host-transfer tests are intentionally excluded because this live engine does not
implement that pending feature. Test certificates/provider responses are fixtures.
No real Apple sign-in, paid AI call or StoreKit transaction is asserted.
''')
    files = {str(p.relative_to(destination)):sha(p.read_bytes()) for p in sorted(destination.rglob('*')) if p.is_file()}
    manifest = {'format':1, 'target_project':'bbkfsgnordtdiblgdzkg', 'bundle_id':'com.spyclash.ios',
                'source_git_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                'baselines':exports, 'frozen_live_files':FROZEN,
                'generated_entrypoint_override':{'APP_MAIN_ACCOUNT_DELETION_ENABLED':'false'},
                'migration_order':MIGRATIONS, 'deployments':deployments, 'files':files}
    write_json(destination/'deployment-manifest.json',manifest)
    archive = destination.parent / 'server-package.tar.gz'
    with archive.open('wb') as output, gzip.GzipFile(filename='',mode='wb',fileobj=output,mtime=0) as zipped:
        with tarfile.open(fileobj=zipped,mode='w') as tar:
            for path in sorted(destination.rglob('*')):
                if path.is_file():
                    info=tar.gettarinfo(str(path),arcname=str(path.relative_to(destination)))
                    info.mtime=0;info.uid=0;info.gid=0;info.uname='';info.gname='';info.mode=0o644
                    with path.open('rb') as stream:tar.addfile(info,stream)
    digest=sha(archive.read_bytes())
    (archive.parent/'server-package.sha256').write_text(digest+'  '+archive.name+'\n')
    write_json(archive.parent/'server-source-manifest.json',manifest)
    if args.test:
        os.symlink(CORE/'node_modules',destination/'node_modules',target_is_directory=True)
        commands=[['node','scripts/game-center-local.mjs'],
                  ['node','--experimental-transform-types','--test','tests/app-services/native-game-center-billing.test.mjs'],
                  ['node_modules/.bin/deno','test','--config','supabase/functions/full-game-core/deno.json',
                   '--filter','/^(lobby contract|projection preserves|question turns|association order|strict majority|split vote|multi-spy|pause|spy guess|host return|active host departure|legacy explicit|original|database reader)/',
                   'tests/full-core-engine']]
        results=[]
        with (archive.parent/'overlay-verification.log').open('w') as log:
            for command in commands:
                log.write('\nCOMMAND '+json.dumps(command)+'\n');log.flush()
                result=subprocess.run(command,cwd=destination,stdout=log,stderr=subprocess.STDOUT)
                results.append({'command':command,'exit_code':result.returncode})
                if result.returncode:break
        for relative, expected in files.items():
            if sha((destination/relative).read_bytes()) != expected:
                raise RuntimeError('Verification modified packaged source: '+relative)
        write_json(archive.parent/'overlay-verification.json',{'artifact_sha256':digest,'results':results})
        if any(r['exit_code'] for r in results):
            raise RuntimeError('Overlay verification failed; inspect overlay-verification.log')
    print(json.dumps({'archive':str(archive),'sha256':digest,'manifest':str(destination/'deployment-manifest.json'),
                      'verification_passed':bool(args.test),'function_files':{name:len(value['files']) for name,value in deployments.items()}},indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deployed',type=Path,default=ROOT/'.local/gamecenter-main200/deployed-source')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/gamecenter-main200/server-source')
    parser.add_argument('--test',action='store_true')
    prepare(parser.parse_args())
