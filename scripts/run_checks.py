#!/usr/bin/env python3
"""Compile and run meaningful persistence, backup and protocol tests on macOS."""
from pathlib import Path
import argparse, subprocess, tempfile
parser=argparse.ArgumentParser()
parser.add_argument('--fixture',action='store_true',help='Use the local fixture server on 127.0.0.1')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vigia-checks-') as directory:
    binary=Path(directory)/'core-tests'
    names=['Models.swift','ONVIF.swift','Media.swift','AppState.swift']
    subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path','/tmp/vigia-swift-cache','-parse-as-library','-target','arm64-apple-macosx14.0',*[str(root/'Sources'/name) for name in names],str(root/'Tests/CoreTests.swift'),'-o',str(binary),'-framework','SwiftUI','-framework','AppKit','-framework','AVFoundation','-framework','Security','-framework','CryptoKit'],check=True)
    subprocess.run([str(binary),*(['--fixture'] if args.fixture else [])],check=True)
