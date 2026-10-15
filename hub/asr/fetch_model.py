#!/usr/bin/env python3
"""Downloads the pinned Qwen3-ASR model into the Hugging Face cache, once.

The worker itself never reaches the network: it loads only an exact, already-cached revision
(asr_worker.MODEL_REVISIONS). Run this with the worker's Python before the first start:

    python fetch_model.py              the default model
    python fetch_model.py --model mlx-community/Qwen3-ASR-1.7B-4bit
    python fetch_model.py --check      only say whether it is cached (no network); exit 1 if not
"""
import argparse
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asr_worker  # noqa: E402  (sets the Hugging Face offline switches; they are lifted below for a download)


def cached(model: str) -> bool:
    try:
        asr_worker.resolve_model(model)
        return True
    except Exception:
        return False


def download(model: str) -> str:
    # asr_worker switched Hugging Face offline for the worker; this one command is the exception.
    for name in ('HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE'):
        os.environ[name] = '0'
    from huggingface_hub import snapshot_download
    return snapshot_download(repo_id=model, revision=asr_worker.MODEL_REVISIONS[model],
                             allow_patterns=asr_worker.MODEL_FILES)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--model', default=asr_worker.DEFAULT_MODEL, choices=sorted(asr_worker.MODEL_REVISIONS),
                        help=f'default {asr_worker.DEFAULT_MODEL}')
    parser.add_argument('--check', action='store_true', help='only check the cache; never download')
    args = parser.parse_args(argv)
    if args.check:
        ok = cached(args.model)
        print(f'{args.model}: {"cached" if ok else "not cached"}')
        return 0 if ok else 1
    path = download(args.model)
    print(f'{args.model} at revision {asr_worker.MODEL_REVISIONS[args.model]}: {path}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
