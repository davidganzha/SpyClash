#!/usr/bin/env python3
"""Prepare and optionally test a local-only main Game Center package.

Never reads credentials or calls a cloud API. Inputs are read-only MCP source
exports from the two explicitly pinned live versions. No workspace source is
reverted. The default candidate disables inherited legacy deletion; --public
preserves its runtime gate and includes the reviewed deletion and AI adapters.
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
PUBLIC_MIGRATIONS = ['20261026232916_public_deletion_archive_erasure.sql',
                     '20261026234309_native_game_center_ai_relay.sql']
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
    entry.write_text(content if args.public else content.replace(original, replacement))
    for relative in ['package.json', 'package-lock.json', 'GAME-CENTER-MAIN.md', 'supabase/config.toml',
                     'scripts/game-center-local.mjs', 'tests/app-services/native-game-center-billing.test.mjs']:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CORE / relative, target)
    # All source variants share the generation reservation implementation.
    # Even the optional direct provider requires the provider-call table.
    migrations = MIGRATIONS + PUBLIC_MIGRATIONS
    for name in migrations:
        target = destination / 'supabase/migrations' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CORE / 'supabase/migrations' / name, target)
    for name in ['game-center', 'full-core-engine']:
        shutil.copytree(CORE / 'tests' / name, destination / 'tests' / name)
    base44_deployments = {}
    if args.public:
        for name, source in [
            ('deleteAccountPublic', CORE / 'base44-prepared/deleteAccount'),
            ('nativeGameCenterWordPack', ROOT / 'base44/functions/nativeGameCenterWordPack'),
        ]:
            target = destination / 'base44/functions' / name
            shutil.copytree(source, target)
            configuration = json.loads((target / 'function.jsonc').read_text())
            if name == 'deleteAccountPublic' and configuration['name'] == 'deleteAccount':
                configuration['name'] = name
                write_json(target / 'function.jsonc', configuration)
            if configuration['name'] != name or not (target / configuration['entry']).is_file():
                raise RuntimeError('Invalid prepared Base44 entry: ' + name)
            base44_deployments[name] = {
                'entry': configuration['entry'],
                'files': sorted(str(p.relative_to(destination)) for p in target.rglob('*') if p.is_file()),
            }
        entity = destination / 'base44/entities/account-deletion-receipt.jsonc'
        entity.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / 'base44/entities/account-deletion-receipt.jsonc', entity)
        reference = destination / 'verification/base44-word-generation'
        reference.mkdir(parents=True)
        for name in ['openai-word-pack-provider.ts', 'word-pack-quality.ts']:
            shutil.copyfile(ROOT / 'base44/functions/generateWordPack' / name, reference / name)
        shutil.copytree(CORE / 'tests/app-services', destination / 'tests/app-services', dirs_exist_ok=True)
        # Preserve the production sources exactly. Tests are relocated from the
        # repository's nested CORE directory to this package root.
        for test_file in (destination / 'tests/app-services').rglob('*.mjs'):
            test_file.write_text(test_file.read_text()
                .replace('../../../../base44/', '../../base44/')
                .replace('base44/functions/deleteAccount/', 'base44/functions/deleteAccountPublic/')
                .replace("new URL('../../../../',import.meta.url)", "new URL('../../',import.meta.url)")
                .replace('base44/functions/generateWordPack/', 'verification/base44-word-generation/'))
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
    if args.public:
        (destination/'PACKAGE-README.md').write_text('''# Main Game Center public server package

Local artifact only. No server deployment, key change or account deletion is
performed by this script. The live engine, push, worker and Live Activity policy
remain byte-for-byte frozen. The public app-services entry preserves the runtime
deletion gate; deployment must leave it off until the historical-key verification,
Base44 receipt v2 and account recovery preflight have passed.

Deploy only the manifest's three Supabase functions, four additive migrations,
AccountDeletionReceipt entity, and two listed Base44 functions after approval.
The new deleteAccountPublic route requires the explicit checkpoint 202 approval;
it retains the existing published deleteAccount function and unrelated drafts.
Never deploy the source checkout or an ejected/copied Base44 app. The target is
the original app 69a0e57fa939f578082f8091 and Supabase bbkfsgnordtdiblgdzkg.
Runtime secrets and rollout flags are separate from the source archive.

Verification covers this exact source overlay. Test-only relative Base44 imports
are adjusted for the package directory layout; production sources are unchanged.
Synthetic Apple signatures/provider fixtures do not establish physical-device
acceptance or actual paid service availability.
''')
    files = {str(p.relative_to(destination)):sha(p.read_bytes()) for p in sorted(destination.rglob('*')) if p.is_file()}
    manifest = {'format':1, 'target_project':'bbkfsgnordtdiblgdzkg', 'bundle_id':'com.spyclash.ios',
                'source_git_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                'baselines':exports, 'frozen_live_files':FROZEN,
                'audience':'public' if args.public else 'internal-candidate',
                'generated_entrypoint_override':{} if args.public else {'APP_MAIN_ACCOUNT_DELETION_ENABLED':'false'},
                'migration_order':migrations, 'deployments':deployments, 'files':files,
                'base44_app_id':'69a0e57fa939f578082f8091' if args.public else None,
                'base44_functions':base44_deployments,
                'base44_entities':['base44/entities/account-deletion-receipt.jsonc'] if args.public else []}
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
        if args.public:
            commands.append(['node','--experimental-transform-types','--test','--test-concurrency=1',
                             'tests/app-services/main-account-deletion.test.mjs',
                             'tests/app-services/deletion-archive.test.mjs',
                             'tests/app-services/native-ai-relay.test.mjs'])
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
    parser.add_argument('--public',action='store_true',help='Include the reviewed public deletion and managed AI prerequisites; never deploys.')
    prepare(parser.parse_args())
