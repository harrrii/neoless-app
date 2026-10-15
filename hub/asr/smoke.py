#!/usr/bin/env python3
"""Real-model smoke test: start a worker on a spare port, post WAV files, print the answers, stop it.

It loads the real model (several hundred MB of memory), so on a small Mac do not run it next to
a build. Run it with the worker's Python (the one that has mlx and mlx_audio):

    python hub/asr/smoke.py /tmp/neoless-asr-smoke.wav --hints OpenAI

Each file is posted twice without hints (the first answer includes loading the model) and once
more with --hints when given. With --fallback-model the worker has a large and a small model,
and --ask posts each file once more per X-Model value (auto, large, small). With --idle-unload N
it then waits for the worker to unload the model and posts the first file again, which loads it
anew. The worker uses a throw-away secret file and never touches the hub's real one. Prints one
JSON line per request to stdout; the worker's log goes to stderr.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
# The worker runs with the Python this script runs with, unless --python names another.
DEFAULT_PYTHON = Path(sys.executable)


def port_in_use(port):
    with socket.socket() as probe:
        return probe.connect_ex(('127.0.0.1', port)) == 0


def call(url, data=None, headers=None, timeout=600):
    request = urllib.request.Request(url, data=data, headers=headers or {}, method='POST' if data is not None else 'GET')
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('wav', nargs='+', help='WAV files (mono 16-bit PCM, 8–48 kHz)')
    parser.add_argument('--port', type=int, default=18851, help='a spare loopback port (default 18851)')
    parser.add_argument('--python', default=str(DEFAULT_PYTHON), help='python with mlx / mlx_audio / aiohttp')
    parser.add_argument('--hints', nargs='*', default=[], help='also post once with these X-Hints')
    parser.add_argument('--idle-unload', type=float, default=0, metavar='SECONDS',
                        help='also check unloading after this many idle seconds and loading again')
    parser.add_argument('--model', help="the worker's --model (default: the worker's own default)")
    parser.add_argument('--fallback-model', help="the worker's --fallback-model: a second, smaller model")
    parser.add_argument('--ask', nargs='*', default=[], metavar='CHOICE',
                        help='also post each file with X-Model set to each of these (auto, large, small)')
    parser.add_argument('--single-call', action='store_true', help="the worker's --single-call")
    args = parser.parse_args()
    if port_in_use(args.port):
        raise SystemExit(f'port {args.port} is in use; pick another with --port')
    base = f'http://127.0.0.1:{args.port}'
    with tempfile.TemporaryDirectory(prefix='neoless-asr-smoke-') as scratch:
        secret_file = Path(scratch) / 'hub' / 'worker-secret'
        command = [args.python, str(HERE / 'asr_worker.py'), '--port', str(args.port),
                   '--secret-file', str(secret_file), '--idle-unload', str(args.idle_unload)]
        for flag, value in (('--model', args.model), ('--fallback-model', args.fallback_model)):
            if value:
                command += [flag, value]
        if args.single_call:
            command.append('--single-call')
        worker = subprocess.Popen(command, stdout=sys.stderr, stderr=sys.stderr)
        try:
            deadline = time.monotonic() + 60
            while True:
                if worker.poll() is not None:
                    raise SystemExit(f'worker exited with {worker.returncode}')
                try:
                    status, health = call(base + '/health', timeout=2)
                    if status == 200:
                        break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    raise SystemExit('worker did not start in 60 s')
                time.sleep(0.2)
            print(json.dumps({'health': health}, ensure_ascii=False), flush=True)
            secret = secret_file.read_text().strip()
            hints = base64.urlsafe_b64encode(json.dumps(args.hints, ensure_ascii=False).encode()).decode().rstrip('=')

            def post(path, label, hint_header=None, choice=None):
                headers = {'Content-Type': 'audio/wav', 'X-Neoless-Worker': secret}
                if hint_header:
                    headers['X-Hints'] = hint_header
                if choice:
                    headers['X-Model'] = choice
                started = time.monotonic()
                status, body = call(base + '/recognize', data=Path(path).read_bytes(), headers=headers)
                wall_ms = round((time.monotonic() - started) * 1000)
                print(json.dumps({'file': os.path.basename(path), 'run': label, 'httpStatus': status,
                                  'wallMs': wall_ms, **body}, ensure_ascii=False), flush=True)

            for path in args.wav:
                post(path, 'cold')
                post(path, 'warm')
                if args.hints:
                    post(path, 'hints', hints)
                for choice in args.ask:
                    post(path, f'ask {choice}', hints if args.hints else None, choice)
                    print(json.dumps({'health': call(base + '/health')[1]}, ensure_ascii=False), flush=True)
            print(json.dumps({'health': call(base + '/health')[1]}, ensure_ascii=False), flush=True)
            if args.idle_unload > 0:
                started = time.monotonic()
                while call(base + '/health')[1]['loaded']:
                    if time.monotonic() - started > args.idle_unload + 30:
                        raise SystemExit('model was not unloaded')
                    time.sleep(0.5)
                print(json.dumps({'unloadedAfterSeconds': round(time.monotonic() - started, 1)}), flush=True)
                post(args.wav[0], 'reloaded')
                print(json.dumps({'health': call(base + '/health')[1]}, ensure_ascii=False), flush=True)
        finally:
            worker.send_signal(signal.SIGTERM)
            try:
                worker.wait(timeout=30)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait()
    print(json.dumps({'stopped': True, 'exitCode': worker.returncode, 'portFree': not port_in_use(args.port)}),
          flush=True)


if __name__ == '__main__':
    main()
