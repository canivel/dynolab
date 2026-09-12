"""Portable, manually started loopback-only RPC worker. No LAN management API."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
from .runtime import clean_env, terminate


def command(binary, device, port):
    binary=Path(binary).expanduser().resolve()
    if not binary.is_file(): raise ValueError('RPC binary does not exist')
    if not re.fullmatch(r'(CUDA|MTL|Metal|Vulkan|HIP|SYCL)\d+',device): raise ValueError('Choose one accelerator device such as CUDA0 or Metal0')
    if type(port) is not int or not 1<=port<=65535: raise ValueError('Invalid port')
    return [str(binary),'--host','127.0.0.1','--port',str(port),'--device',device]


def main(argv=None):
    p=argparse.ArgumentParser(prog='dyno node',description='Trusted-device RPC preview; loopback only, accessed through verified SSH')
    p.add_argument('--binary',required=True)
    p.add_argument('--device',default='CUDA0')
    p.add_argument('--port',type=int,default=50052)
    p.add_argument('--experimental',action='store_true')
    args=p.parse_args(argv)
    if not args.experimental: p.error('--experimental is required')
    process=None
    def stop(*_):
        raise KeyboardInterrupt
    old=signal.signal(signal.SIGTERM,stop)
    try:
        cmd=command(args.binary,args.device,args.port)
        help=subprocess.run([cmd[0],'--help'],capture_output=True,text=True,timeout=15,env=clean_env())
        if '--host' not in help.stdout+help.stderr or '--device' not in help.stdout+help.stderr:
            raise ValueError('RPC binary lacks required host/device options')
        print('RPC worker is loopback-only. Connect through verified SSH on the same LAN. Ctrl-C stops this worker.',flush=True)
        process=subprocess.Popen(cmd,env=clean_env())
        return process.wait()
    except KeyboardInterrupt: return 0
    except (ValueError,OSError,subprocess.SubprocessError) as e:
        print(str(e),flush=True); return 1
    finally:
        terminate(process); signal.signal(signal.SIGTERM,old)
