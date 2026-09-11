import argparse
import json
import subprocess
from pathlib import Path
from .runtime import lan_interfaces, plan, run


def main(argv=None):
    parser=argparse.ArgumentParser(prog='dyno pool',description='Experimental two-machine LAN pool over SSH; Mac coordinator, loopback RPC worker')
    parser.add_argument('action',choices=['interfaces','plan','probe','start'])
    parser.add_argument('--config',type=Path)
    parser.add_argument('--experimental',action='store_true',help='Acknowledge that RPC is experimental and only for trusted devices')
    args=parser.parse_args(argv)
    try:
        if args.action=='interfaces': print(json.dumps(lan_interfaces(),indent=2)); return 0
        if not args.config: parser.error('--config is required')
        if args.config.stat().st_size>16384: raise ValueError('Configuration exceeds 16 KB')
        config=json.loads(args.config.read_text())
        if args.action=='plan': print(json.dumps(plan(config),indent=2)); return 0
        if not args.experimental: parser.error('probe/start require --experimental for trusted-device testing')
        run(config,probe=args.action=='probe')
        return 0
    except (ValueError,OSError,subprocess.SubprocessError) as e:
        print(json.dumps({'status':'failed','error':str(e)}),flush=True); return 1
