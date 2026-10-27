#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Additional permission: Madeira Converter Exception, version 1; see LICENSE-EXCEPTION.md.
"""Build a local test IPA in an isolated, persistent macOS CI checkout.

Uses the pinned upstream IPA for unchanged Windows farms. Rebuilds DXMT's
Windows renderers and all BCD native code when their source/toolchain keys
change. Rejects guest-runtime changes requiring a new base instead of silently
shipping stale DLLs. No Apple signing account or OTA publishing credentials.
"""
import argparse
import atexit
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import subprocess
import sys
import time
import zipfile

import yaml


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    source = Path(__file__).resolve().parents[1]
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    config_path = Path(os.environ['BCD_CI_CONFIG'])
    config = json.loads(config_path.read_text())
    root = Path(config['workspace']).expanduser()
    root.parent.mkdir(parents=True, exist_ok=True)
    def retain_logs():
        if root.exists():
            for detail in root.glob('*.log'):
                try: shutil.copy2(detail, output / ('detail-' + detail.name))
                except OSError: pass
    atexit.register(retain_logs)
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([str(Path(config['toolchains']) / 'llvm-mingw-20260421-ucrt-macos-universal/bin'),
        '/opt/homebrew/opt/bison/bin', '/opt/homebrew/opt/flex/bin', '/opt/homebrew/bin', env.get('PATH', '')])
    env.update(GITHUB_WORKSPACE=str(root), JOBS=str(config.get('jobs', 8)))
    jobs = env['JOBS']
    def command(argv, cwd=None, log='build.log', extra=None):
        print('+', ' '.join(str(a) for a in argv), flush=True)
        with (output / log).open('a') as f:
            p = subprocess.run([str(a) for a in argv], cwd=cwd or root, env=env | (extra or {}), stdout=f, stderr=subprocess.STDOUT)
        if p.returncode:
            print('\n'.join((output / log).read_text(errors='replace').splitlines()[-35:]), flush=True)
            raise RuntimeError(f'{Path(str(argv[0])).name} failed ({p.returncode}); see {log}')
    def git(*argv, cwd=None):
        return subprocess.check_output(['git', *argv], cwd=cwd or root, env=env, text=True).strip()
    commit = git('rev-parse', 'HEAD', cwd=source)
    if not root.exists():
        command(['git', 'clone', '--no-checkout', str(source), str(root)], cwd=root.parent, log='checkout.log')
        (root / '.bcd-ci-owned').touch()
    if not (root / '.bcd-ci-owned').exists():
        raise RuntimeError('Refusing to reset a workspace not created by this builder')
    command(['git', 'fetch', str(source), commit], log='checkout.log')
    command(['git', 'reset', '--hard', commit], log='checkout.log')
    base = json.loads((root / 'build/dev-ipa/base.json').read_text())
    for module, expected in base['submodules'].items():
        actual = git('ls-tree', 'HEAD', module).split()[2]
        if actual != expected:
            raise RuntimeError(f'{module} pin changed: update the verified upstream IPA base before building')
    guest_paths = ['madeira-d3d12/src', 'madeira-d3d12/include', 'tools/patch-wine-*.py', 'tools/build-xtajit*.sh',
                   'build/fex-arm64ec', 'build/fex-wow64', 'build/wine-pe', 'build/wine-i386']
    changed = git('diff', '--name-only', base['commit'], 'HEAD', '--', *guest_paths)
    if changed:
        raise RuntimeError('Guest runtime inputs changed; this fast development recipe needs a new verified base or a full PE build:\n' + changed)
    command(['git', 'submodule', 'update', '--init', '--depth', '1', 'wine', 'FEX', 'dxmt'], log='checkout.log')
    command(['git', 'submodule', 'update', '--init', '--depth', '1', '--recursive', 'FEX', 'dxmt'], log='checkout.log')
    for folder in ('wine', 'FEX', 'dxmt'):
        command(['git', '-C', folder, 'reset', '--hard', 'HEAD'], log='checkout.log')
    (root / 'toolchains').mkdir(exist_ok=True)
    for name in ('llvm-ios-build', 'llvm-project', 'llvm-mingw-20260421-ucrt-macos-universal', 'gnutls-ios', 'ffmpeg-ios'):
        path = root / 'toolchains' / name
        if not path.exists(): path.symlink_to(Path(config['toolchains']) / name)
    ft = root / 'research/freetype'
    if not ft.exists(): ft.symlink_to(config['freetype'])
    shutil.copy2(config['converter'], root / 'app/Madeira/d3d12/libmetalirconverter.dylib')
    ipa = Path(config['base_ipa'])
    if sha(ipa) != base['ipa_sha256']:
        raise RuntimeError('Upstream IPA base checksum mismatch')
    base_dir = root / '.bcd-ci' / ('base-' + base['release'] + '-' + base['ipa_sha256'][:12])
    if not base_dir.exists():
        base_dir.mkdir(parents=True)
        with zipfile.ZipFile(ipa) as z: z.extractall(base_dir)
    base_app = next((base_dir / 'Payload').glob('*.app'))
    tc = root / 'toolchains'
    for name in ('gnutls', 'hogweed', 'nettle', 'gmp'):
        shutil.copy2(tc / f'gnutls-ios/lib/lib{name}.a', root / f'app/Madeira/lib{name}.a')
    for name in ('avformat', 'avcodec', 'swresample', 'avutil'):
        shutil.copy2(tc / f'ffmpeg-ios/lib/lib{name}.a', root / f'app/Madeira/lib{name}.a')
    (root / 'app/Madeira/x86_64-vcruntime').mkdir(exist_ok=True)
    steps = yaml.safe_load((root / '.github/workflows/build-ipa.yml').read_text())['jobs']['build']['steps']
    def step(name, log):
        script = next(s['run'] for s in steps if s.get('name') == name)
        command(['bash', '-e', '-c', script], log=log)
    state = root / '.bcd-ci/stamps'; state.mkdir(parents=True, exist_ok=True)
    toolchain = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
    cache_report = {}
    def cached(name, paths, artifacts, build):
        key = hashlib.sha256((git('ls-tree', '-r', 'HEAD', '--', 'tools/build-dev-ipa.py', 'build/dev-ipa/base.json', *paths) + '\n' + toolchain + '\n' +
                              json.dumps(config, sort_keys=True)).encode()).hexdigest()
        stamp = state / (name + '.json')
        old = json.loads(stamp.read_text()) if stamp.exists() else {}
        hit = old.get('key') == key and all((root / a).is_file() for a in artifacts)
        print(f'CACHE {name}: {"hit" if hit else "build"}', flush=True)
        cache_report[name] = {'hit': hit, 'key': key}
        if not hit:
            build()
            if not all((root / a).is_file() for a in artifacts): raise RuntimeError(f'{name} did not produce its required files')
            stamp.write_text(json.dumps({'key': key}))
    # ARM64EC's private presenter must start from the pristine DXMT pin.
    cached('d3d11', ['dxmt', 'tools/build-d3d11-dll.sh', 'tools/build-auto-hdr-shaders.sh', 'tools/patch-dxmt-*.py', 'tools/patch-d3d11-*.py'],
           ['build/dxmt-d3d11/d3d11.dll'], lambda: command(['bash', 'tools/build-d3d11-dll.sh'], log='d3d11.log', extra={'D3D11_AUTO_HDR':'1', 'D3D11_NO_SHIP':'1'}))
    workflow = (root / '.github/workflows/build-ipa.yml').read_text()
    # Follow the production workflow's patch order, with each script's real arguments.
    import shlex
    for script, tail in re.findall(r'python3 (tools/patch-(?:wine|ntdll-unix|wineserver|fex|dxmt|airconv|winemetal)-[\w.-]+\.py)([^\n]*)', workflow):
        if '--verify' in tail: continue
        command([sys.executable, script, *shlex.split(tail)], log='patches.log')
    def fex():
        step('Patch FEX IOS_RPM_GUARD for the system-allocator branch', 'fex.log')
        step('Build FEX for iOS', 'fex.log')
    cached('fex', ['FEX', 'tools/patch-fex-ios-probes.py', '.github/workflows/build-ipa.yml'],
           ['FEX/build-ios/FEXCore/Source/libFEXCore.a', 'FEX/build-ios/FEXCore/Source/libFEXCore_Base.a'], fex)
    def wine():
        native = root / 'wine/build-native'; native.mkdir(exist_ok=True)
        command(['../configure', '--disable-tests'], cwd=native, log='wine-configure.log')
        command(['make', '-j'+jobs, 'tools/widl/widl', 'tools/wrc/wrc', 'tools/wmc/wmc', 'tools/winebuild/winebuild', 'tools/winegcc/winegcc', 'tools/make_xftmpl'], cwd=native, log='wine-tools.log')
        step('Configure wine (build-macos, cross)', 'wine-configure.log')
        step('Generate cross-tree headers and patch config.h for iOS SDK', 'wine-configure.log')
        mf = (root / 'wine/build-macos/Makefile').read_text().replace('\\\n', ' ')
        headers = []
        for line in mf.splitlines():
            if line.startswith('include/') and ':' in line:
                headers += [x for x in line.split(':')[0].split() if re.fullmatch(r'include/[\w.-]+\.h', x) and x != 'include/config.h']
        command(['make', '-C', 'wine/build-macos', '-j'+jobs, *dict.fromkeys(headers)], log='wine-headers.log')
        command(['bash', 'build/freetype-ios/build.sh'], log='freetype.log')
        command(['bash', 'build/ntdll-unix/build.sh'], log='ntdll.log')
        command(['bash', 'build/win32u-unix/build.sh'], log='win32u.log')
        step('Build base libwineserver.a from wine/server sources', 'wineserver.log')
        command(['bash', 'build/wineserver/build.sh'], log='wineserver.log')
    cached('wine-native', ['wine', 'build/madeira_cfg.h', 'build/madsync', 'build/ntdll-unix', 'build/win32u-unix', 'build/wineserver', 'build/freetype-ios', 'tools/patch-wine-*.py', 'tools/patch-ntdll-*.py', '.github/workflows/build-ipa.yml'],
           ['app/Madeira/libntdll_unix.a', 'app/Madeira/libwin32u_unix.a', 'app/Madeira/libwineserver.a'], wine)
    def dxmt():
        step('Generate DXMT shader headers', 'dxmt.log')
        command(['bash', 'build/dxmt-ios/build.sh'], log='dxmt.log')
        objects = list((root / 'build/dxmt-ios/obj').glob('*.o'))
        archives = list((tc / 'llvm-ios-build/lib').glob('*.a'))
        command(['xcrun','-sdk','iphoneos','libtool','-static','-o','app/Madeira/libdxmt_combined.a',*objects,*archives],log='dxmt-combine.log')
    cached('dxmt-native', ['dxmt', 'build/dxmt-ios', 'tools/patch-dxmt-*.py', 'tools/patch-airconv-*.py', 'tools/patch-winemetal-*.py', 'build/madeira_cfg.h'],
           ['app/Madeira/libdxmt_combined.a'], dxmt)
    def pe_dxmt():
        b = root / 'wine/build-i386'; b.mkdir(exist_ok=True)
        if not (b / 'config.status').exists():
            command(['../configure','--enable-archs=i386','--without-x','--without-vulkan','--without-freetype','--without-gnutls','--disable-tests','--enable-winegstreamer'],cwd=b,log='i386-configure.log')
        command(['make','-j'+jobs,'tools/winebuild/winebuild','libs/winecrt0/i386-windows/libwinecrt0.a','dlls/ntdll/i386-windows/libntdll.a','dlls/dbghelp/i386-windows/libdbghelp.a'],cwd=b,log='i386-imports.log')
        cross = root / '.bcd-ci/i386.ini'
        mingw = tc / 'llvm-mingw-20260421-ucrt-macos-universal/bin'
        cross.write_text('[binaries]\n'+''.join(f"{k} = '{mingw}/i686-w64-mingw32-{v}'\n" for k,v in {'c':'clang','cpp':'clang++','ar':'ar','strip':'strip','windres':'windres','dlltool':'dlltool'}.items())+"\n[properties]\nneeds_exe_wrapper = true\n[host_machine]\nsystem = 'windows'\ncpu_family = 'x86'\ncpu = 'i686'\nendian = 'little'\n")
        sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
        if not (root / 'dxmt/build-pe-i386/build.ninja').exists():
            command(['meson','setup','--cross-file',cross,'--native-file',root/'dxmt/build-osx.txt','--buildtype','release','-Dwine_build_path='+str(b),'-Dwine_builtin_dll=true','dxmt/build-pe-i386','dxmt'],log='dxmt-i386.log',extra={'SDKROOT':sdk})
        command(['meson','compile','-C','dxmt/build-pe-i386','-j'+jobs],log='dxmt-i386.log',extra={'SDKROOT':sdk})
        command(['bash','tools/build-d3d9-x64-dll.sh'],log='d3d9-x64.log',extra={'D3D9X64_NO_SHIP':'1'})
    cached('dxmt-pe', ['dxmt','wine','build/madeira_cfg.h','tools/patch-dxmt-*.py','tools/patch-winemetal-*.py','tools/d3d9-x64-*','tools/build-d3d9-x64-dll.sh','tools/build-auto-hdr-shaders.sh'],
           ['dxmt/build-pe-i386/src/d3d11/d3d11.dll','dxmt/build-pe-i386/src/d3d9/d3d9.dll','build/dxmt-d3d9-x64/d3d9.dll'], pe_dxmt)
    cached('pairing', ['build/rppairing-ios'], ['app/Madeira/libmadeira_rppairing.a'],
           lambda: command(['bash','build/rppairing-ios/build.sh'],log='pairing.log'))
    for test in ('check-dxmt-auto-hdr.py','check-dxmt-patch-chain.py','check-bcd-hud.py'):
        command([sys.executable,'tests/host/'+test],log='checks.log')
    command([sys.executable,'tools/stikjit-interface-compat.py','app/Frameworks/StikJIT.xcframework'],log='archive.log')
    command(['bash','build/stage-licenses.sh'],log='archive.log')
    build = ''.join(x.strip() for x in (root/'docs/local-build/BUILD-NUMBER').read_text().splitlines() if not x.startswith('#'))
    derived = root / '.bcd-ci/DerivedData'; archive = root / '.bcd-ci/BCD.xcarchive'
    command(['xcodebuild','-project','app/Madeira.xcodeproj','-scheme','Madeira','-sdk','iphoneos','-destination','generic/platform=iOS','-configuration','Debug','-derivedDataPath',derived,'CODE_SIGNING_ALLOWED=NO','MARKETING_VERSION=0.1.'+build,'CURRENT_PROJECT_VERSION='+build,'archive','-archivePath',archive],log='archive.log')
    payload = output/'Payload'; payload.mkdir()
    app = payload/'BCD.app'
    shutil.copytree(archive/'Products/Applications/Madeira.app',app,symlinks=True)
    for name in ('aarch64-windows','arm64ec-windows','i386-windows'):
        if (app/name).exists(): shutil.rmtree(app/name)
        shutil.copytree(base_app/name,app/name,symlinks=True)
    shutil.copy2(root/'build/dxmt-d3d11/d3d11.dll',app/'arm64ec-windows/d3d11-src.dll')
    shutil.copy2(root/'build/dxmt-d3d9-x64/d3d9.dll',app/'arm64ec-windows/d3d9-dxmt.dll')
    strip=tc/'llvm-mingw-20260421-ucrt-macos-universal/bin/i686-w64-mingw32-strip'
    modules={'d3d11/d3d11.dll':'d3d11.dll','dxgi/dxgi.dll':'dxgi.dll','d3d10/d3d10core.dll':'d3d10core.dll','winemetal/winemetal.dll':'winemetal.dll','d3d9/d3d9.dll':'d3d9-emulated.dll','d3d9shim/d3d9shim.dll':'d3d9.dll'}
    for src,dest in modules.items(): command([strip,'-o',app/'i386-windows'/dest,root/'dxmt/build-pe-i386/src'/src],log='package.log')
    shutil.copy2(app/'i386-windows/d3d9.dll',app/'i386-windows/d3d9shim.dll')
    info=plistlib.loads((app/'Info.plist').read_bytes()); info.update(MadeiraCommit=commit,MadeiraRepo='creeper4004/bcd-games',MadeiraBuiltUTC=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    (app/'Info.plist').write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_BINARY))
    runpy.run_path(str(root/'tools/ota-variants.py'))['fakesign'](app)
    command(['codesign','--verify','--deep','--strict',app],log='package.log')
    target=output/f'BCD-dev-{build}-{commit[:8]}.ipa'
    command(['ditto','-c','-k','--norsrc','--noextattr','--noqtn','--noacl','--keepParent','Payload',target],cwd=output,log='package.log')
    digest=sha(target); target.with_suffix('.ipa.sha256').write_text(digest+'  '+target.name+'\n')
    (output/'BUILD-INFO.json').write_text(json.dumps({'commit':commit,'base':base,'version':'0.1.'+build,'configuration':'Debug, iOS arm64, ad-hoc signature for local sideloading','ipa':target.name,'sha256':digest,'xcode':toolchain,'components':cache_report},indent=2)+'\n')
    shutil.rmtree(payload)
    print('READY:',target.name,digest,flush=True)


if __name__ == '__main__':
    main()
