#!/usr/bin/env python3
"""Package app, matching FFmpeg source and original project sources; no user profile."""
import argparse,hashlib,plistlib,shutil,subprocess,tempfile,zipfile
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--build',type=Path,required=True)
parser.add_argument('--out',type=Path,default=Path('build-release'))
parser.add_argument('--arch',choices=['arm64','x86_64'],default='arm64')
args=parser.parse_args();root=Path(__file__).resolve().parents[1]
build=args.build.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
version=(root/'VERSION').read_text().strip()
app=build/'VigiaARM.app'
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if 'VigiaDataDirectory' in info:raise SystemExit('Refusing a development profile build')
if info.get('CFBundleShortVersionString')!=version.split('-')[0]:raise SystemExit('App version does not match source VERSION')
for executable in ['MacOS/VigiaARM','Helpers/ffmpeg','Helpers/ffprobe']:
    arches=subprocess.check_output(['/usr/bin/lipo','-archs',str(app/'Contents'/executable)],text=True).split()
    if arches != [args.arch]: raise SystemExit('Unexpected architecture in '+executable)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
with tempfile.TemporaryDirectory(prefix='vigia-package-') as directory:
    package=Path(directory)/f'VigiaARM-{version}-macOS-{args.arch}';package.mkdir()
    shutil.copytree(app,package/'VigiaARM.app',copy_function=shutil.copy2)
    for executable in ['MacOS/VigiaARM','Helpers/ffmpeg','Helpers/ffprobe']:
        if not ((package/'VigiaARM.app/Contents'/executable).stat().st_mode & 0o111):
            raise SystemExit('Executable permission missing: '+executable)
    shutil.copyfile(build/'ffmpeg-8.1.2-vigia-source.tar.gz',package/'ffmpeg-8.1.2-vigia-source.tar.gz')
    for name in ['README.md','LICENSE','THIRD_PARTY_NOTICES.md','CHANGELOG.md']:shutil.copyfile(root/name,package/name)
    shutil.copytree(root/'docs',package/'docs')
    shutil.copytree(root/'LICENSES',package/'LICENSES')
    archive=out/f'VigiaARM-{version}-macOS-{args.arch}.zip'
    subprocess.run(['/usr/bin/ditto','-c','-k','--keepParent','--norsrc',str(package),str(archive)],check=True)
files=[p for p in subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0') if p]
with zipfile.ZipFile(out/f'VigiaARM-{version}-source.zip','w',zipfile.ZIP_DEFLATED) as z:
    for name in files:z.write(root/name,'vigia-arm/'+name)
archives=sorted(out.glob('*.zip'))
(out/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in archives))
print('\n'.join(str(p) for p in archives))
