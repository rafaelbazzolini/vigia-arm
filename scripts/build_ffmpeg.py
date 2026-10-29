#!/usr/bin/env python3
"""Build the independently licensed ARM64 media backend from pinned FFmpeg source."""
import argparse, hashlib, json, os
from pathlib import Path
import subprocess
import tarfile

FLAGS = ['--arch=arm64','--target-os=darwin','--cc=clang','--disable-autodetect','--disable-doc','--disable-debug',
 '--disable-ffplay','--disable-gpl','--disable-nonfree','--disable-everything','--enable-ffmpeg','--enable-ffprobe',
 '--enable-pthreads','--enable-videotoolbox','--enable-audiotoolbox','--enable-securetransport','--enable-zlib',
 '--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox',
 '--enable-protocol=file,pipe,tcp,udp,rtp,http,https,tls',
 '--enable-demuxer=rtsp,rtp,sdp,mov,matroska,h264,hevc,aac,image2,wav,m4v,dhav',
 '--enable-decoder=h264,hevc,mjpeg,mpeg4,aac,pcm_alaw,pcm_mulaw,pcm_s16le,wrapped_avframe,rawvideo',
 '--enable-parser=h264,hevc,aac,mjpeg,mpeg4video', '--enable-muxer=matroska,mp4,mov,h264,m4v,image2pipe,null,wav,s16le',
 '--enable-encoder=mjpeg,pcm_s16le,rawvideo,mpeg4,h264_videotoolbox,aac', '--enable-filter=scale,fps,format,testsrc,testsrc2,sine,anull,null,aresample,hwdownload',
 '--enable-indev=lavfi', '--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata']


def patch(source):
    header = source/'libavformat/rtsp.h'
    text = header.read_text()
    if 'char *vigia_onvif_start;' not in text:
        text = text.replace('    int initial_pause;', '    int initial_pause;\n    char *vigia_onvif_start; /* Vigia: ONVIF replay UTC clock range. */')
        header.write_text(text)
    options = source/'libavformat/rtsp.c'
    text = options.read_text()
    if '"onvif_start"' not in text:
        marker = '    FF_RTP_FLAG_OPTS(RTSPState, rtp_muxer_flags),'
        assert marker in text
        text = text.replace(marker, '    { "onvif_start", "ONVIF replay UTC start (YYYYMMDDTHHMMSSZ)", OFFSET(vigia_onvif_start), AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, DEC },\n'+marker)
        options.write_text(text)
    reader = source/'libavformat/rtspdec.c'
    text = reader.read_text()
    marker = '        ff_rtsp_send_cmd(s, "PLAY", rt->control_uri, cmd, reply, NULL);'
    if 'Vigia ONVIF replay' not in text:
        assert marker in text
        text = text.replace(marker, '''        /* Vigia ONVIF replay: reject header injection; preserve normal RTSP. */
        if (rt->vigia_onvif_start) {
            const char *start = rt->vigia_onvif_start;
            if (strlen(start) != 16 || start[8] != 'T' || start[15] != 'Z')
                return AVERROR(EINVAL);
            for (int k = 0; k < 16; k++)
                if (k != 8 && k != 15 && (start[k] < '0' || start[k] > '9'))
                    return AVERROR(EINVAL);
            snprintf(cmd, sizeof(cmd), "Require: onvif-replay\\r\\nRange: clock=%s-\\r\\nRate-Control: no\\r\\n", start);
        }
'''+marker)
        reader.write_text(text)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    source=args.source.resolve();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    patch(source)
    build=out/'objects';build.mkdir(exist_ok=True)
    subprocess.run([str(source/'configure'),*FLAGS],cwd=build,check=True)
    subprocess.run(['make','-j8'],cwd=build,check=True)
    import shutil
    for name in ('ffmpeg','ffprobe'):shutil.copy2(build/name,out/name)
    shutil.copy2(source/'COPYING.LGPLv2.1',out/'COPYING.LGPLv2.1')
    (out/'BUILD.json').write_text(json.dumps({'upstream':'https://github.com/FFmpeg/FFmpeg/tree/n8.1.2','flags':FLAGS,'modification':'ONVIF replay clock range; scripts/build_ffmpeg.py','architecture':'arm64'},indent=2))
    # Distribute corresponding modified source, including configure/build instructions.
    (source/'VIGIA-BUILD.json').write_text((out/'BUILD.json').read_text())
    with tarfile.open(out/'ffmpeg-8.1.2-vigia-source.tar.gz','w:gz') as tar:
        tar.add(source,arcname='ffmpeg-8.1.2-vigia')

if __name__=='__main__':main()
