#!/usr/bin/env python3
"""Build Vigia ARM as a standalone native macOS application."""
import argparse,json,plistlib,shutil,subprocess,struct
from pathlib import Path

def run(args):subprocess.run([str(v) for v in args],check=True)
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend',type=Path,default=Path('build-media'))
    parser.add_argument('--out',type=Path,default=Path('build-app'))
    parser.add_argument('--dev-data',type=Path)
    parser.add_argument('--arch',choices=['arm64','x86_64'],default='arm64')
    args=parser.parse_args();root=Path(__file__).resolve().parents[1]
    version=(root/'VERSION').read_text().strip()
    out=args.out.resolve();backend=args.backend.resolve()
    for name in ['ffmpeg','ffprobe','COPYING.LGPLv2.1','BUILD.json','ffmpeg-8.1.2-vigia-source.tar.gz']:
        if not (backend/name).is_file():raise SystemExit('Missing media input: '+name)
    for name in ['ffmpeg','ffprobe']:
        arches=subprocess.check_output(['/usr/bin/lipo','-archs',str(backend/name)],text=True)
        if args.arch not in arches.split():raise SystemExit('Media backend does not support '+args.arch)
    app=out/'VigiaARM.app';contents=app/'Contents'
    for path in ['MacOS','Helpers','Resources/Licenses']:(contents/path).mkdir(parents=True,exist_ok=True)
    run(['xcrun','swiftc','-swift-version','5','-module-cache-path','/tmp/vigia-swift-cache','-parse-as-library','-O','-target',f'{args.arch}-apple-macosx14.0',*sorted((root/'Sources').glob('*.swift')),'-o',contents/'MacOS/VigiaARM','-framework','SwiftUI','-framework','AppKit','-framework','AVFoundation','-framework','Security','-framework','CryptoKit'])
    for name in ['ffmpeg','ffprobe']:shutil.copy2(backend/name,contents/'Helpers'/name)
    for name in ['COPYING.LGPLv2.1','BUILD.json']:shutil.copy2(backend/name,contents/'Resources/Licenses'/name)
    for name in ['LICENSE','THIRD_PARTY_NOTICES.md','README.md']:
        if (root/name).exists():shutil.copy2(root/name,contents/'Resources/Licenses'/name)
    shutil.copytree(root/'LICENSES',contents/'Resources/Licenses/References',dirs_exist_ok=True)
    shutil.copy2(root/'docs/SERVICE_PORT.md',contents/'Resources/Licenses/SERVICE_PORT.md')
    iconset=out/'AppIcon.iconset'
    run(['xcrun','swift','-module-cache-path','/tmp/vigia-swift-cache',root/'scripts/Icon.swift',iconset])
    # ICNS supports PNG payloads at these standard sizes; package losslessly.
    entries=[]
    for kind,name in [('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('icp6','icon_32x32@2x.png'),('ic07','icon_128x128.png'),('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png')]:
        data=(iconset/name).read_bytes();entries.append(kind.encode()+struct.pack('>I',len(data)+8)+data)
    payload=b''.join(entries)
    (contents/'Resources/AppIcon.icns').write_bytes(b'icns'+struct.pack('>I',len(payload)+8)+payload)
    info={'CFBundleName':'Vigia ARM','CFBundleDisplayName':'Vigia ARM','CFBundleExecutable':'VigiaARM','CFBundleIdentifier':'io.github.rafaelbazzolini.vigia-arm','CFBundlePackageType':'APPL','CFBundleVersion':'1.0.0','CFBundleShortVersionString':'1.0.0','CFBundleIconFile':'AppIcon.icns','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSLocalNetworkUsageDescription':'Descobrir e acessar as câmeras e gravadores cadastrados por você.','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
    if args.dev_data:info['VigiaDataDirectory']=str(args.dev_data.resolve())
    info['CFBundleVersion']=version.split('-beta.')[-1] if '-beta.' in version else '1'
    info['CFBundleShortVersionString']=version.split('-')[0]
    info['VigiaVersion']=version.split('-')[0] + (' Beta' if '-beta' in version else '')
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    # Ad-hoc signature for integrity of the local bundle; not Developer ID/notarization.
    for name in ['ffmpeg','ffprobe']:run(['/usr/bin/codesign','--force','--sign','-',contents/'Helpers'/name])
    # Remove Finder display metadata from this newly generated bundle before signing.
    # This does not remove quarantine or change any system security setting.
    subprocess.run(['/usr/bin/xattr','-d','com.apple.FinderInfo',str(app)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    run(['/usr/bin/codesign','--force','--sign','-',app])
    run(['/usr/bin/codesign','--verify','--deep','--strict',app])
    shutil.copy2(backend/'ffmpeg-8.1.2-vigia-source.tar.gz',out/'ffmpeg-8.1.2-vigia-source.tar.gz')
    print(app)
if __name__=='__main__':main()
