#!/usr/bin/env python3
"""Package app, matching FFmpeg source and original project sources; no user profile."""
import argparse,hashlib,plistlib,shutil,subprocess,tempfile,zipfile
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--build',type=Path,required=True)
parser.add_argument('--out',type=Path,default=Path('build-release'))
args=parser.parse_args();root=Path(__file__).resolve().parents[1]
build=args.build.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
app=build/'VigiaARM.app'
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if 'VigiaDataDirectory' in info:raise SystemExit('Refusing a development profile build')
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
with tempfile.TemporaryDirectory(prefix='vigia-package-') as directory:
    package=Path(directory)/'VigiaARM-1.0.0-beta.1-macOS-arm64';package.mkdir()
    shutil.copytree(app,package/'VigiaARM.app',copy_function=shutil.copy2)
    for executable in ['MacOS/VigiaARM','Helpers/ffmpeg','Helpers/ffprobe']:
        if not ((package/'VigiaARM.app/Contents'/executable).stat().st_mode & 0o111):
            raise SystemExit('Executable permission missing: '+executable)
    shutil.copyfile(build/'ffmpeg-8.1.2-vigia-source.tar.gz',package/'ffmpeg-8.1.2-vigia-source.tar.gz')
    for name in ['README.md','LICENSE','THIRD_PARTY_NOTICES.md','CHANGELOG.md']:shutil.copyfile(root/name,package/name)
    shutil.copytree(root/'docs',package/'docs')
    archive=out/'VigiaARM-1.0.0-beta.1-macOS-arm64.zip'
    subprocess.run(['/usr/bin/ditto','-c','-k','--keepParent','--norsrc',str(package),str(archive)],check=True)
files=[p for p in subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0') if p]
with zipfile.ZipFile(out/'VigiaARM-1.0.0-beta.1-source.zip','w',zipfile.ZIP_DEFLATED) as z:
    for name in files:z.write(root/name,'vigia-arm/'+name)
archives=sorted(out.glob('*.zip'))
(out/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in archives))
print('\n'.join(str(p) for p in archives))
