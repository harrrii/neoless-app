#!/usr/bin/env python3
"""Real-model comparison for recordings that mix Chinese and English: one call per recording
(the worker before 1.3, `--single-call`) against the worker's default, for each model.

It loads the real models, one at a time, so on a small Mac do not run it next to a build.
Run it with the worker's Python (the one that has mlx and mlx_audio):

    python hub/asr/compare.py --say /tmp/neoless-asr-mix

`--say FOLDER` makes the test clips there with `say` (voices Tingting and Samantha; invented
sentences, nobody's dictation) and compares on them (`--only NAME…` for some of them); WAV files
given as arguments (mono 16-bit PCM, 16 kHz) are compared too. Prints one JSON line per clip,
model and strategy: the text, how many stretches were recognised on their own, how many windows
were asked for their language, the seconds (the fastest of `--repeat` runs: a Mac that does other things is rarely
idle) and `slowLimit`, the seconds after which the worker would call the large model too slow
for this Mac. Nothing is sent anywhere and no worker is started.
"""
import argparse
import json
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asr_worker as w  # noqa: E402

MODELS = {'large': 'mlx-community/Qwen3-ASR-1.7B-4bit', 'small': 'mlx-community/Qwen3-ASR-0.6B-4bit'}

EN = {'build': "I think the new build is ready for testing.",
      'review': "Let's move the weekly review to Thursday afternoon.",
      'report': "Please send me the report before lunch.",
      'battery': "The battery on my laptop only lasts three hours.",
      'meeting': "The meeting starts at three o'clock",
      'cleanup': "Yesterday I spent most of the afternoon cleaning up the project. I removed the old scripts, "
                 "updated the documentation, and fixed two small bugs in the settings page. "
                 "Tomorrow I want to start working on the new keyboard shortcuts.",
      'feedback': "One more thing before we finish. The design team asked for feedback on the new onboarding "
                  "flow, so please try it this week and write down anything that feels confusing."}
ZH = {'例会': "我们把每周的例会改到星期四下午吧。",
      '测试': "我觉得新版本已经可以开始测试了。",
      '报告': "记得午饭之前把报告发给我。",
      '天气': "这个周末的天气应该会很不错。",
      '咖啡': "楼下新开了一家咖啡店，味道还可以。",
      '晚饭': "然后我们一起去吃晚饭",
      '谢谢': "谢谢。",
      '术语': "我今天用 Codex 写了一个脚本，然后让 OpenAI 的模型帮我检查了一下 JSON 格式。",
      '一句': "我觉得这个 feature 应该在下个 sprint 之前 ship 出去不然 deadline 就来不及了",
      '整理': "昨天下午我基本上都在整理这个项目。我删掉了一些旧的脚本，更新了文档，还修了设置页面里的两个小问题。"
              "明天我想开始做新的快捷键功能。",
      '搬家': "另外还有一件事情要提醒大家。下个月公司要搬到新的办公室，搬家那几天网络可能会不太稳定，"
              "重要的文件请提前备份好。",
      # One voice for both languages, as one person speaks: English that runs into Chinese without a pause,
      # an English term and an English sentence between the pauses of Chinese ones.
      'honest': "To be honest with you 我不太喜欢",
      'know': "As far as I know 他明天不来",
      'short': "Long story short 我们赢了",
      'honest-long': "To be honest with you 我觉得还是老版本更好用一点",
      'know-long': "As far as I know 这个功能下周才会上线",
      '用的是': "我们这个项目用的是",
      'markov': "Hidden Markov Model",
      '后处理': "来做语音识别的后处理",
      '说过': "扎克伯格以前说过",
      'quote': "move fast and break things 这句话现在看其实是有问题的",
      '稳一点': "我们还是应该稳一点",
      '老板': "我昨天问了一下老板。",
      'wait': "He said we should wait until next week.",
      '放一放': "所以这个事情先放一放。"}
# name: (parts in order, seconds of silence between them[, the level of a faint noise under all of it:
# a `say` clip has exact zeros in its pauses, a microphone never does])
CLIPS = {'en-zh': (['build', '报告'], 0.45),
         'zh-en': (['天气', 'review'], 0.45),
         'three-switches': (['例会', 'report', '天气', 'battery'], 0.45),
         'three-switches-short-pauses': (['例会', 'report', '天气', 'battery'], 0.25),
         'terms': (['术语'], 0.0),
         'english-paragraph': (['cleanup'], 0.0),
         'chinese-paragraph': (['整理'], 0.0),
         'one-sentence-no-pause': (['一句'], 0.0),
         'two-voices-no-pause': (['meeting', '晚饭'], 0.06),
         'english-then-thanks': (['report', '谢谢'], 0.4),
         'sixty-seconds': (['整理', 'feedback', '咖啡', 'battery', '搬家', 'cleanup', '测试'], 0.6),
         'english-lead-ins': (['例会', 'honest', 'know', 'short', '天气'], 0.45),
         'english-lead-ins-only': (['honest-long', 'know-long', '报告'], 0.45),
         'term-between-pauses': (['用的是', 'markov', '后处理'], 0.35),
         'quote-then-chinese': (['说过', 'quote', '稳一点'], 0.35),
         'english-sentence-same-voice': (['老板', 'wait', '放一放'], 0.45),
         'long-chinese-room-noise': (['整理', '搬家', '咖啡', '天气', '例会', '测试', '报告', '整理', '搬家'], 0.45, 0.0008)}
HINTS = {'terms': ['Codex', 'OpenAI', 'JSON'],
         'long-chinese-room-noise': ['Codex', 'OpenAI', 'JSON', 'neoless', 'Typeless', 'Cloudflare', 'GitHub',
                                     'Xcode', 'SwiftUI', '例会']}


def read_wav(path) -> np.ndarray:
    with wave.open(str(path), 'rb') as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, w.SAMPLE_RATE):
            raise SystemExit(f'{path}: need mono 16-bit PCM at 16 kHz')
        return np.frombuffer(audio.readframes(audio.getnframes()), dtype='<i2').astype(np.float32) / 32768.0


def write_wav(path, samples: np.ndarray) -> None:
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(w.SAMPLE_RATE)
        audio.writeframes((np.clip(samples, -1, 1) * 32767).astype('<i2').tobytes())


def spoken(folder: Path, name: str, voice: str, text: str) -> np.ndarray:
    """`text` said by `voice`, without the silence `say` puts around it."""
    aiff, wav = folder / f'part-{name}.aiff', folder / f'part-{name}.wav'
    subprocess.run(['say', '-v', voice, '-o', str(aiff), text], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', f'LEI16@{w.SAMPLE_RATE}', '-c', '1', str(aiff), str(wav)], check=True)
    samples = read_wav(wav)
    aiff.unlink()
    wav.unlink()
    loud = np.flatnonzero(w.frame_levels(samples) > 0.004)
    margin = round(0.02 * w.SAMPLE_RATE)
    return samples[max(0, loud[0] * w.FRAME_SAMPLES - margin):(loud[-1] + 1) * w.FRAME_SAMPLES + margin]


def make_clips(folder: Path, only=None) -> list[Path]:
    folder.mkdir(parents=True, exist_ok=True)
    chosen = {name: clip for name, clip in CLIPS.items() if not only or name in only}
    needed = {part for order, *_ in chosen.values() for part in order}
    parts = {name: spoken(folder, name, 'Samantha', text) for name, text in EN.items() if name in needed}
    parts.update({name: spoken(folder, name, 'Tingting', text) for name, text in ZH.items() if name in needed})
    edge = np.zeros(round(0.2 * w.SAMPLE_RATE), np.float32)
    paths = []
    for name, (order, pause, *noise) in chosen.items():
        pieces = [edge]
        for index, part in enumerate(order):
            if index:
                pieces.append(np.zeros(round(pause * w.SAMPLE_RATE), np.float32))
            pieces.append(parts[part])
        samples = np.concatenate(pieces + [edge])
        if noise:
            samples = samples + np.random.default_rng(7).normal(0, noise[0], len(samples)).astype(np.float32)
        write_wav(folder / f'{name}.wav', samples)
        paths.append(folder / f'{name}.wav')
    return paths


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('wav', nargs='*', help='WAV files to compare on (mono 16-bit PCM, 16 kHz)')
    parser.add_argument('--say', metavar='FOLDER', help='make the test clips in this folder with `say` and use them')
    parser.add_argument('--only', nargs='+', metavar='NAME', choices=sorted(CLIPS), help='with --say: only these clips')
    parser.add_argument('--models', nargs='+', choices=sorted(MODELS), default=['small', 'large'])
    parser.add_argument('--hints', nargs='*', default=None, help='X-Hints for every clip (default: only the terms clip has some)')
    parser.add_argument('--repeat', type=int, default=2, help='runs per clip and strategy; the fastest is reported (default 2)')
    args = parser.parse_args()
    paths = (make_clips(Path(args.say), args.only) if args.say else []) + [Path(path) for path in args.wav]
    if not paths:
        parser.error('give WAV files or --say FOLDER')
    clips = [(path.stem, read_wav(path)) for path in paths]
    judge = w.AdaptiveEngine(None)   # only for its limit
    for key in args.models:
        engines = {'single call': w.QwenEngine(MODELS[key], mixed=False), 'mixed': w.QwenEngine(MODELS[key])}
        started = time.monotonic()
        engines['mixed'].load()
        engines['single call']._model, engines['single call']._mx = engines['mixed']._model, engines['mixed']._mx
        print(json.dumps({'model': engines['mixed'].name, 'loadSeconds': round(time.monotonic() - started, 2)}), flush=True)
        engines['mixed'].hear(clips[0][1][:2 * w.SAMPLE_RATE], [])  # the first call after loading is slower
        for name, samples in clips:
            hints = args.hints if args.hints is not None else HINTS.get(name, [])
            for strategy, engine in engines.items():
                seconds, heard = [], None
                for _ in range(max(1, args.repeat)):
                    started = time.monotonic()
                    heard = engine.transcribe(samples, hints)
                    seconds.append(time.monotonic() - started)
                audio_seconds = len(samples) / w.SAMPLE_RATE
                print(json.dumps({'clip': name, 'audioSeconds': round(audio_seconds, 1),
                                  'model': engine.name, 'strategy': strategy, 'segments': heard.segments,
                                  'probes': heard.probes, 'seconds': round(min(seconds), 2),
                                  'slowLimit': round(judge.slow_limit(audio_seconds, heard, hints), 1),
                                  'hints': len(hints), 'text': heard.text},
                                 ensure_ascii=False), flush=True)
        engines['single call']._model = None
        engines['mixed'].unload()


if __name__ == '__main__':
    main()
