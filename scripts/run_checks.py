#!/usr/bin/env python3
"""Compile and run meaningful persistence, backup and protocol tests on macOS."""
from pathlib import Path
import argparse, subprocess, tempfile, sys, shutil, plistlib, json
parser=argparse.ArgumentParser()
parser.add_argument('--arch',choices=['arm64','x86_64'],default='arm64')
parser.add_argument('--fixture',action='store_true',help='Use the local fixture server on 127.0.0.1')
parser.add_argument('--backend',type=Path,help='Also test service video with this DHAV-enabled FFmpeg backend')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vigia-checks-') as directory:
    binary=Path(directory)/'core-tests'
    fixture_args=[];media_args=[]
    if args.backend:
        backend=args.backend.resolve()
        contents=Path(directory)/'ServiceTests.app/Contents'
        for folder in ['MacOS','Helpers']:(contents/folder).mkdir(parents=True,exist_ok=True)
        binary=contents/'MacOS/core-tests'
        (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'vigia.local.tests','CFBundleExecutable':'core-tests','CFBundlePackageType':'APPL'}))
        shutil.copy2(backend/'ffmpeg',contents/'Helpers/ffmpeg')
        jpeg=Path(directory)/'synthetic.jpg'
        subprocess.run([str(backend/'ffmpeg'),'-v','error','-f','lavfi','-i','testsrc2=size=640x360:rate=10','-frames:v','1','-c:v','mjpeg','-f','image2pipe',str(jpeg)],check=True)
        fixture_args=['--jpeg',str(jpeg)];media_args=['--media-directory',directory]
    names=['Models.swift','ServicePort.swift','ServiceMedia.swift','ONVIF.swift','Media.swift','AppState.swift']
    subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path','/tmp/vigia-swift-cache','-parse-as-library','-target',f'{args.arch}-apple-macosx14.0',*[str(root/'Sources'/name) for name in names],str(root/'Tests/CoreTests.swift'),str(root/'Tests/ServicePortTests.swift'),'-o',str(binary),'-framework','SwiftUI','-framework','AppKit','-framework','AVFoundation','-framework','Security','-framework','CryptoKit'],check=True)
    fixture=subprocess.Popen([sys.executable,str(root/'Tests/service_fixture.py'),*fixture_args],stdout=subprocess.PIPE,text=True)
    try:
        port=int(fixture.stdout.readline().strip())
        subprocess.run([str(binary),'--service-port',str(port),*media_args,*(['--fixture'] if args.fixture else [])],check=True)
        if args.backend:
            for name in ['service-recording.mkv','service-manual-stop.mkv','service-recording.mp4']:
                recording=Path(directory)/name
                metadata=json.loads(subprocess.check_output([str(backend/'ffprobe'),'-v','error','-show_streams','-show_format','-of','json',str(recording)],text=True))
                assert metadata['streams'][0]['codec_name']=='mjpeg' and 1<=float(metadata['format']['duration'])<=4, metadata
                subprocess.run([str(backend/'ffmpeg'),'-v','error','-i',str(recording),'-an','-r','10','-fps_mode','cfr','-c:v','rawvideo','-f','null','-'],check=True)
                print('PASS: '+name+' codec/duration verified and full recording decoded')
    finally:
        fixture.terminate();fixture.wait(timeout=5)
