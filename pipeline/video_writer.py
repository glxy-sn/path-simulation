"""Single-pass H.264 encoding with a hardware capability probe and atomic publish."""
from functools import lru_cache
import os
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile

import cv2


@lru_cache(maxsize=4)
def select_encoder(ffmpeg):
    for codec in ('h264_videotoolbox','libx264'):
        with tempfile.TemporaryDirectory(prefix='foodcourt-encoder-') as directory:
            try:
                result = subprocess.run([ffmpeg,'-v','error','-f','rawvideo','-pix_fmt','bgr24',
                    '-s','64x64','-r','5','-i','pipe:0','-frames:v','1','-c:v',codec,
                    '-pix_fmt','yuv420p','-y',directory+'/probe.mp4'],
                    input=bytes(64*64*3),capture_output=True,timeout=15)
                if result.returncode == 0:
                    return codec
            except (OSError,subprocess.TimeoutExpired):
                pass
    return None


class VideoWriter:
    def __init__(self,path,fps,size):
        self.path=Path(path)
        self.temp=self.path.with_name(self.path.stem+f'.{os.getpid()}.partial.mp4')
        self.size=size
        self.frames=0
        self.process=None
        self.native=None
        self.log=None
        ff=shutil.which('ffmpeg')
        codec=select_encoder(ff) if ff else None
        if codec:
            self.log=tempfile.TemporaryFile()
            args=[ff,'-y','-v','error','-f','rawvideo','-pix_fmt','bgr24','-s',f'{size[0]}x{size[1]}',
                  '-r',str(fps),'-i','pipe:0','-an','-vf','pad=ceil(iw/2)*2:ceil(ih/2)*2',
                  '-c:v',codec,'-pix_fmt','yuv420p']
            args += ['-preset','veryfast','-crf','20'] if codec=='libx264' else ['-b:v','6M']
            self.process=subprocess.Popen(args+['-movflags','+faststart',str(self.temp)],
                                          stdin=subprocess.PIPE,stderr=self.log,stdout=subprocess.DEVNULL)
        else:
            self.native=cv2.VideoWriter(str(self.temp),cv2.VideoWriter_fourcc(*'mp4v'),fps,size)
            if not self.native.isOpened():
                raise RuntimeError('Video encoder tidak tersedia')
        print(f'[render] encoder={codec or "mp4v"}',flush=True)

    def write(self,frame):
        if (frame.shape[1],frame.shape[0]) != self.size:
            raise ValueError('Frame size changed during encoding')
        if self.process:
            try:
                self.process.stdin.write(frame.tobytes())
            except BrokenPipeError as exc:
                raise RuntimeError('Video encoder stopped before completing output') from exc
        else:
            self.native.write(frame)
        self.frames+=1

    def release(self):
        failed = sys.exc_info()[0] is not None
        try:
            if self.process:
                try: self.process.stdin.close()
                except BrokenPipeError: pass
                try: code=self.process.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
                    raise RuntimeError('Video encoder timed out')
                if code:
                    self.log.seek(0)
                    raise RuntimeError('Video encoder failed: '+self.log.read().decode(errors='replace')[-1500:])
            elif self.native:
                self.native.release()
            if self.frames and not failed:
                os.replace(self.temp,self.path)
        finally:
            if self.log: self.log.close()
            self.temp.unlink(missing_ok=True)
