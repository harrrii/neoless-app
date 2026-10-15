#!/usr/bin/env python3
"""neoless ASR worker: Qwen3-ASR on MLX for neoless-hub, loopback only.

Contract: docs/hub.md, "ASR worker". The hub posts 16 kHz mono 16-bit WAV with a shared
secret and gets the raw transcript back. One inference thread; requests queue in arrival
order; the model loads on first use (or when the hub asks for it ahead, `/warm`, while the
user is still speaking) and is unloaded after an idle period.

The model is a pinned revision that is already in the Hugging Face cache (fetch_model.py puts it
there once); the worker itself runs with Hugging Face offline. It is loaded with mlx_audio's
`load_model(...)` and called as `generate(language=..., hotwords=...)`: the hub's hints go in as
hot words.

Chinese and English in one recording: Qwen3-ASR writes one language tag per call, and what
is spoken in the other language is then translated or left out. So a recording with pauses
is first asked, piece by piece, which language each piece is in; neighbours in the same
language are recognised together, each stretch with its own language, and the texts are
joined ("mixed languages" below). A recording in one language is still one call (one per 30
seconds: the worker cuts long audio itself, so that no chunk of silence reaches the model).
"""
from __future__ import annotations

import os

# Never reach the network for models: the pinned revisions must already be in the cache.
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'

import argparse  # noqa: E402
import asyncio  # noqa: E402
import base64  # noqa: E402
import binascii  # noqa: E402
import concurrent.futures  # noqa: E402
import functools  # noqa: E402
import gc  # noqa: E402
import hmac  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import re  # noqa: E402
import secrets  # noqa: E402
import stat  # noqa: E402
import sys  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
import unicodedata  # noqa: E402
import wave  # noqa: E402
from dataclasses import dataclass  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
from aiohttp import web  # noqa: E402

VERSION = '1.4.0'
HOST = '127.0.0.1'
DEFAULT_PORT = 18801
DEFAULT_IDLE_SECONDS = 600.0
HUB_DATA_FOLDER = '~/Library/Application Support/neoless-hub'
DEFAULT_SECRET_FILE = f'{HUB_DATA_FOLDER}/worker-secret'

SAMPLE_RATE = 16000
MIN_RATE, MAX_RATE = 8000, 48000
MIN_SECONDS = 0.2            # shorter recordings are answered with no_speech
MAX_SECONDS = 600            # 10 minutes, the same cap as the apps
NO_SPEECH_RMS = 0.00015      # near-silence never reaches the model
MAX_BODY_BYTES = MAX_SECONDS * MAX_RATE * 2 + 65536
MAX_QUEUE = 8                # requests waiting or running; more get 503 busy
MAX_HINTS = 100              # NeolessCore Vocabulary.recognizerHintLimit
MAX_HINT_LENGTH = 80         # NeolessCore Vocabulary.maxWordLength
MAX_HINT_CHARS = 2000        # the whole list, as compact JSON
UPLOAD_TIMEOUT_SECONDS = 60
# 100 hints of 80 characters fit even when the JSON escapes every character as \uXXXX.
SERVER_OPTIONS = {'max_field_size': 131072}
WAV_TYPES = {'audio/wav', 'audio/x-wav', 'audio/wave', 'audio/vnd.wave'}
LOOPBACK_HOSTS = {'127.0.0.1', 'localhost', '[::1]'}

DEFAULT_MODEL = 'mlx-community/Qwen3-ASR-0.6B-4bit'
# Exact revisions: the worker loads only these, from the cache (fetch_model.py downloads one).
MODEL_REVISIONS = {
    'mlx-community/Qwen3-ASR-0.6B-4bit': '313d850181767edf09f00a9c289becca70e58cd0',
    'mlx-community/Qwen3-ASR-1.7B-4bit': '78a389c776a5483b2d0d4ea5494e11012e0d6159',
    'mlx-community/Qwen3-ASR-1.7B-8bit': 'a8379a2e2f9e313c9292cdf1af4055ab56d50d55',
}
MODEL_FILES = ['*.json', '*.safetensors', '*.model', '*.txt', '*.tiktoken']
ASR_MAX_TOKENS = 8192
ASR_CHUNK_SECONDS = 30.0       # one model call hears at most about this much at a time (see `chunk_bounds`)
CHUNK_SEARCH_SECONDS = 5.0     # longer audio is cut at its quietest place this close to every 30 seconds
CHUNK_WINDOW_SECONDS = 0.1     # "quietest": the tenth of a second with the least energy

# Mixed languages (see `transcribe_mixed`).
FRAME_SAMPLES = 320            # 20 ms at 16 kHz: the loudness is measured per frame
MIN_PAUSE_SECONDS = 0.2        # quieter than speech for this long: a place where the language may change
MIN_PROBE_SECONDS = 0.3        # a piece with less speech is not asked for its language
MIN_OWN_SECONDS = 1.0          # a piece with less speech never stands alone: it goes with a neighbour
PROBE_SECONDS = 2.0            # how much of the start of a piece the model hears to say its language
TAIL_SECONDS = 1.0             # and how much of the end of a piece that starts in English
EDGE_LEAD_SECONDS, EDGE_TAIL_SECONDS = 0.3, 0.2  # silence put around audio that was cut out of a recording
# Longer stretches in one language are cut at a pause: with its quiet edges a stretch is still one chunk.
MAX_STRETCH_SECONDS = ASR_CHUNK_SECONDS - (EDGE_LEAD_SECONDS + EDGE_TAIL_SECONDS)
PROBE_TOKENS = 10              # "language Chinese<asr_text>" (3 or 4 tokens) and the first few words
PROBE_BATCH = 12               # pieces asked at once (memory: one short prompt each)
MAX_PROBES = 36                # pieces of one recording asked for their start; a longer one: after its longest pauses
MODEL_CHOICES = ('auto', 'large', 'small')

_BASE64URL = re.compile(r'[A-Za-z0-9_-]*={0,2}')
_HINT_FORBIDDEN = set('{}<>`')


def log(message: str) -> None:
    print(f'neoless-asr: {message}', flush=True)


# ---------------------------------------------------------------- errors


class RequestError(Exception):
    """A request the worker answers with `{"error", "code", "retryable"}`."""

    def __init__(self, status: int, code: str, message: str, retryable: bool = False):
        super().__init__(message)
        self.status, self.code, self.message, self.retryable = status, code, message, retryable


class ModelUnavailable(RequestError):
    def __init__(self):
        super().__init__(503, 'model_unavailable', '识别模型加载失败。')


def json_response(payload: dict, status: int = 200) -> web.Response:
    return web.json_response(payload, status=status, headers={'Cache-Control': 'no-store'},
                             dumps=lambda value: json.dumps(value, ensure_ascii=False))


def error_response(error: RequestError) -> web.Response:
    return json_response({'error': error.message, 'code': error.code, 'retryable': error.retryable},
                         error.status)


# ---------------------------------------------------------------- shared secret


class SecretError(Exception):
    pass


def _read_secret(path: Path) -> str:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as exc:
        if isinstance(exc, FileNotFoundError):
            raise
        raise SecretError(f'无法读取 worker 密钥 {path}：{exc.strerror}') from exc
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise SecretError(f'worker 密钥 {path} 不是普通文件。')
        if info.st_uid != os.getuid():
            raise SecretError(f'worker 密钥 {path} 不是当前用户的文件。')
        if info.st_mode & 0o077:
            os.fchmod(source.fileno(), 0o600)
        value = source.read(4096).decode('utf-8', 'replace').strip()
    if len(value) < 16:
        raise SecretError(f'worker 密钥 {path} 是空的或太短。')
    return value


def _same_folder(directory: Path, folder: str | Path) -> bool:
    try:
        return os.path.samefile(directory, Path(folder).expanduser())
    except OSError:
        return False


def load_or_create_secret(path: str | Path = DEFAULT_SECRET_FILE, hub_folder: str | Path = HUB_DATA_FOLDER) -> str:
    """The shared secret the hub sends in X-Neoless-Worker.

    Created when missing (file 0600) with a random base64url value. The new file appears
    atomically with its content (a hard link of a finished temporary file), so whichever of hub
    and worker starts first creates it and the other reads the same value.

    Only the worker's own folders are made 0700: one it creates, and the hub's data folder
    (0700 by contract; the hub tightens it too). Any other folder given with --secret-file
    keeps its permissions, and one that other users can write to (without the sticky bit, as
    /tmp has) is refused: they could swap the secret.
    """
    path = Path(path).expanduser()
    directory = path.parent
    created = False
    if not directory.exists():
        directory.parent.mkdir(parents=True, exist_ok=True)
        try:
            directory.mkdir(mode=0o700)
            created = True
        except FileExistsError:
            pass  # the hub created it a moment ago
    info = directory.stat()
    if created or (info.st_mode & 0o077 and info.st_uid == os.getuid() and _same_folder(directory, hub_folder)):
        os.chmod(directory, 0o700)
        info = directory.stat()
    if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
        raise SecretError(f'{directory} 别人也能写入，不能放 worker 密钥。')
    if path.is_symlink():
        raise SecretError(f'worker 密钥 {path} 不能是链接。')
    try:
        return _read_secret(path)
    except FileNotFoundError:
        pass
    descriptor, temporary = tempfile.mkstemp(prefix='.worker-secret-', dir=directory)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as destination:
            os.fchmod(destination.fileno(), 0o600)
            destination.write(secrets.token_urlsafe(32))
            destination.flush()
            os.fsync(destination.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            pass  # someone else created it first; use theirs
    finally:
        os.unlink(temporary)
    return _read_secret(path)


# ---------------------------------------------------------------- request decoding


def decode_hints(header: str | None) -> list[str]:
    """X-Hints: base64url (padding optional) of a UTF-8 JSON array of strings.

    A malformed header is an error; single unusable words (empty, longer than 80 characters,
    control characters or prompt markers `{}<>`) are skipped, duplicates dropped, and at most
    the first 100 kept, so a strange dictionary entry never fails a dictation.

    The kept list is also at most 2000 characters as
    compact JSON: mlx_audio puts every hint into the prompt of every 30-second chunk. A word
    that no longer fits is skipped and a shorter one after it can still go in.
    """
    if header is None or not header.strip():
        return []
    text = header.strip()
    if not _BASE64URL.fullmatch(text):
        raise RequestError(400, 'bad_hints', 'X-Hints 不是 base64url。')
    try:
        decoded = base64.urlsafe_b64decode(text.rstrip('=') + '=' * (-len(text.rstrip('=')) % 4))
        value = json.loads(decoded.decode('utf-8'))
    except (binascii.Error, UnicodeDecodeError, ValueError) as exc:
        raise RequestError(400, 'bad_hints', 'X-Hints 不是 JSON 字符串数组。') from exc
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise RequestError(400, 'bad_hints', 'X-Hints 不是 JSON 字符串数组。')
    hints, seen, size = [], set(), 2  # the JSON brackets
    for item in value:
        word = item.strip()
        if not word or len(word) > MAX_HINT_LENGTH:
            continue
        if any(char in _HINT_FORBIDDEN or unicodedata.category(char)[0] == 'C'
               or unicodedata.category(char) in ('Zl', 'Zp') for char in word):
            continue
        key = word.casefold()
        if key in seen:
            continue
        cost = len(json.dumps(word, ensure_ascii=False)) + bool(hints)  # the quoted word and its comma
        if size + cost > MAX_HINT_CHARS:
            continue
        seen.add(key)
        hints.append(word)
        size += cost
        if len(hints) == MAX_HINTS:
            break
    return hints


def model_choice(header: str | None) -> str:
    """X-Model: "auto", "large" or "small" (any case). Missing, empty or anything else is "auto",
    so a hub that knows more choices than this worker still gets an answer."""
    choice = (header or '').strip().lower()
    return choice if choice in MODEL_CHOICES else 'auto'


@dataclass
class Audio:
    samples: np.ndarray  # float32 in [-1, 1), at `rate`
    rate: int

    @property
    def seconds(self) -> float:
        return len(self.samples) / self.rate

    def is_silent(self) -> bool:
        if self.seconds < MIN_SECONDS:
            return True
        return float(np.sqrt(np.mean(np.square(self.samples)))) < NO_SPEECH_RMS


_WAVE_FORMAT_PCM, _WAVE_FORMAT_EXTENSIBLE = 0x0001, 0xFFFE
_KSDATAFORMAT_SUBTYPE_PCM = bytes.fromhex('0100000000001000800000aa00389b71')


def _wav_chunks(data: bytes):
    """(name, payload offset, declared size) of each RIFF chunk after the WAVE id, walked as
    the wave module does, up to and including the first data chunk."""
    offset = 12
    while offset + 8 <= len(data):
        name, size = data[offset:offset + 4], int.from_bytes(data[offset + 4:offset + 8], 'little')
        yield name, offset + 8, size
        if name == b'data':
            return
        offset += 8 + size + (size & 1)


def _wav_is_pcm(data: bytes) -> bool | None:
    """Whether the fmt chunk says integer PCM (plain or extensible); None when there is no
    complete fmt chunk before the data."""
    for name, start, size in _wav_chunks(data):
        if name == b'fmt ':
            body = data[start:start + size]
            if len(body) < 16:
                return None
            tag = int.from_bytes(body[:2], 'little')
            if tag == _WAVE_FORMAT_EXTENSIBLE:
                return body[24:40] == _KSDATAFORMAT_SUBTYPE_PCM if len(body) >= 40 else None
            return tag == _WAVE_FORMAT_PCM
    return None


def _unfinished_data(data: bytes) -> bytes:
    """The samples after a data chunk whose writer has not filled in its size yet; b'' when
    the header is finished.

    AVAudioFile writes the data chunk with size 0 and a RIFF size that ends at that chunk's
    header, and fills both in only when it is released (there is no close() before macOS 15):
    a file read while the writer is alive says 0 frames, and the samples follow. A data chunk
    of 0 bytes with bytes after it that the RIFF size does not account for either is a damaged
    header, not silence.
    """
    found = [(start, size) for name, start, size in _wav_chunks(data) if name == b'data']
    if not found or found[0][1] != 0 or found[0][0] >= len(data):
        return b''
    start = found[0][0]
    riff_end = 8 + int.from_bytes(data[4:8], 'little')
    if riff_end <= start:
        return data[start:]
    if riff_end > len(data):
        raise RequestError(400, 'bad_audio', '无法读取 WAV 录音（文件头没写完）。')
    return b''  # a finished header: an empty data chunk, other chunks after it


def read_audio(data: bytes) -> Audio:
    """A mono 16-bit PCM WAV, 8–48 kHz, at most 10 minutes.

    A readable WAV in another format (float, A-law/μ-law, stereo, 8/24/32-bit...) is 415
    unsupported_audio; a file that cannot be read is 400 bad_audio.
    """
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise RequestError(400, 'bad_audio', '不是 WAV 录音。')
    if _wav_is_pcm(data) is False:  # the wave module would only say "unknown format"
        raise RequestError(415, 'unsupported_audio', '需要单声道 16 位 PCM WAV。')
    try:
        with wave.open(io.BytesIO(data), 'rb') as wav:
            channels, width, rate = wav.getnchannels(), wav.getsampwidth(), wav.getframerate()
            if channels != 1 or width != 2 or wav.getcomptype() != 'NONE':
                raise RequestError(415, 'unsupported_audio', '需要单声道 16 位 PCM WAV。')
            if not MIN_RATE <= rate <= MAX_RATE:
                raise RequestError(415, 'unsupported_audio', f'不支持 {rate} Hz，需要 8–48 kHz。')
            limit = MAX_SECONDS * rate + 1  # frames; one more than allowed tells "too long"
            # Read by the limit, not the header: streaming writers may leave the length unset,
            # as a placeholder size (read here to the end) or as 0 (below).
            pcm = wav.readframes(limit)
    except RequestError:
        raise
    except Exception as exc:  # the wave module raises Error, EOFError, RuntimeError... on damaged files
        raise RequestError(400, 'bad_audio', '无法读取 WAV 录音（需要 16 位 PCM）。') from exc
    if not pcm:
        pcm = _unfinished_data(data)[:limit * 2]
        if pcm:
            log('WAV header not finished (data size 0): reading the samples after it')
    frames = len(pcm) // 2
    if frames > MAX_SECONDS * rate:
        raise RequestError(413, 'too_long', '录音超过 10 分钟。')
    samples = np.frombuffer(pcm, dtype='<i2', count=frames).astype(np.float32) / 32768.0
    return Audio(samples, rate)


def resample(samples: np.ndarray, rate: int, target: int = SAMPLE_RATE) -> np.ndarray:
    """Polyphase resampling onto the exact target grid (scipy, which mlx_audio requires).

    Time and memory grow with the length only, whatever the length or rate: about 0.3 s and
    80 MB for 10 minutes at 48 kHz. (A whole-recording FFT is only fast when the length
    factors well; an awkward length or rate held the inference thread for tens of seconds.)
    """
    if rate == target or len(samples) == 0:
        return samples
    from scipy.signal import resample_poly  # on first use: the hub sends 16 kHz
    common = math.gcd(rate, target)
    up, down = target // common, rate // common
    length = max(1, round(len(samples) * up / down))
    return resample_poly(samples, up, down)[:length].astype(np.float32, copy=False)


# ---------------------------------------------------------------- mixed languages
#
# Pure helpers (numpy and text only), then `transcribe_mixed`, which asks the model through two
# functions it is given. Measured on the Neo with `say` clips (README.md): one call for a
# recording that switches language made the 1.7B model answer all in English (Chinese sentences
# translated or dropped) and the 0.6B model lose sentences; a forced language drops the
# sentences in the other one; recognising every pause-separated piece alone keeps the languages
# but cuts terms in two ("MA" / "CD") and ends every clause with a full stop.


@dataclass(frozen=True)
class Piece:
    """A part of a recording between two pauses. The pieces of a recording cover all of it:
    each one ends, and the next begins, in the middle of the pause between them."""
    start: int      # samples
    end: int
    onset: int      # where its speech begins
    speech: float   # seconds of speech in it
    gap: float      # seconds of pause before it (0 for the first)
    finish: int     # where its speech ends


@dataclass(frozen=True)
class Stretch:
    """Neighbouring pieces in one language, recognised in one call. `language` is None when the
    model named neither Chinese nor English for any piece: it then decides, as in a single call."""
    start: int
    end: int
    language: str | None


@dataclass
class Transcript:
    text: str
    segments: int = 1    # how many stretches were recognised on their own
    model: str = ''      # filled in by the engine that answered
    probes: int = 0      # how many windows were asked for their language first


def frame_levels(samples: np.ndarray) -> np.ndarray:
    """RMS of each 20 ms frame (a last incomplete frame is left out)."""
    count = len(samples) // FRAME_SAMPLES
    if count == 0:
        return np.zeros(0, np.float32)
    frames = np.asarray(samples[:count * FRAME_SAMPLES], dtype=np.float32).reshape(count, FRAME_SAMPLES)
    return np.sqrt(np.mean(np.square(frames), axis=1))


def speech_frames(levels: np.ndarray) -> np.ndarray:
    """Which frames carry speech: louder than a threshold the recording sets itself, three times
    its quiet level but between 4 % and 15 % of its loud level. With heavy noise everything
    counts as speech, so nothing is split and the recording is recognised in one call."""
    if len(levels) == 0:
        return np.zeros(0, bool)
    loud, quiet = float(np.percentile(levels, 97)), float(np.percentile(levels, 10))
    threshold = max(min(max(quiet * 3.0, loud * 0.04), loud * 0.15), 1e-4)
    return levels >= threshold


def split_at_pauses(samples: np.ndarray, min_pause: float = MIN_PAUSE_SECONDS) -> list[Piece]:
    """The recording cut in the middle of every pause of at least `min_pause` seconds. Nothing is
    left out: silence at the start and the end belongs to the first and the last piece. No
    speech at all: no pieces."""
    speech = speech_frames(frame_levels(samples))
    voiced = np.flatnonzero(speech)
    if len(voiced) == 0:
        return []
    needed = max(1, round(min_pause * SAMPLE_RATE / FRAME_SAMPLES))
    breaks = np.flatnonzero(np.diff(voiced) > needed)  # more than `needed` quiet frames between them
    firsts = np.concatenate(([voiced[0]], voiced[breaks + 1]))
    lasts = np.concatenate((voiced[breaks], [voiced[-1]])) + 1
    pieces, start = [], 0
    for index, (first, last) in enumerate(zip(firsts, lasts)):
        final = index == len(firsts) - 1
        end = len(samples) if final else int((last + firsts[index + 1]) // 2) * FRAME_SAMPLES
        gap = 0.0 if index == 0 else float(first - lasts[index - 1]) * FRAME_SAMPLES / SAMPLE_RATE
        pieces.append(Piece(start, end, int(first) * FRAME_SAMPLES,
                            float(np.count_nonzero(speech[first:last])) * FRAME_SAMPLES / SAMPLE_RATE, gap,
                            int(last) * FRAME_SAMPLES))
        start = end
    return pieces


def with_quiet_edges(samples: np.ndarray) -> np.ndarray:
    """Audio cut out of a recording, with silence before and after. The models answer badly to
    speech that starts or stops at the very edge: the 0.6B one then sometimes writes English
    filler ("ology. For example") instead of what was said."""
    lead = np.zeros(round(EDGE_LEAD_SECONDS * SAMPLE_RATE), np.float32)
    tail = np.zeros(round(EDGE_TAIL_SECONDS * SAMPLE_RATE), np.float32)
    return np.concatenate((lead, np.asarray(samples, dtype=np.float32), tail))


def chunk_bounds(samples: np.ndarray) -> list[tuple[int, int]]:
    """Where the audio of one model call is cut when it is longer than a chunk (30 s): at the quietest
    tenth of a second within 5 s of every 30, which is how mlx_audio cuts. Two things are not as
    mlx_audio does them, because a chunk without speech makes the models write something as soon
    as the language is given ("嗯。", or the whole list of hints):

    - A cut after which nothing is spoken is not made. The quietest place near the end of a
      recording is often its very end (always, with the silence `with_quiet_edges` puts there),
      and mlx_audio then hands the model a last chunk of a tenth of a second of silence. What
      follows stays with the chunk before it, up to the 35 s a chunk can have; silence beyond
      that is left out.
    - A chunk in which nothing is spoken (half a minute of thinking) is left out."""
    total, limit = len(samples), round(ASR_CHUNK_SECONDS * SAMPLE_RATE)
    if total <= limit:
        return [(0, total)]
    voiced = np.flatnonzero(speech_frames(frame_levels(samples))) * FRAME_SAMPLES  # where speech frames begin

    def spoken(start: int, end: int) -> bool:
        return bool(np.searchsorted(voiced, start) < np.searchsorted(voiced, end))

    search, window = round(CHUNK_SEARCH_SECONDS * SAMPLE_RATE), round(CHUNK_WINDOW_SECONDS * SAMPLE_RATE)
    bounds, start = [], 0
    while total - start > limit:
        low, high = start + limit - search, min(total, start + limit + search)
        sums = np.cumsum(np.concatenate(([0.0], np.square(samples[low:high], dtype=np.float64))))
        cut = low + int(np.argmin(sums[window:] - sums[:-window])) + window // 2
        if not spoken(cut, total):
            return bounds + [(start, high)]
        if spoken(start, cut):
            bounds.append((start, cut))
        start = cut
    return bounds + [(start, total)]


def probe_window(samples: np.ndarray, piece: Piece) -> np.ndarray:
    """What the model hears to name a piece's language: its first two seconds of speech."""
    start = max(piece.start, piece.onset - round(EDGE_LEAD_SECONDS * SAMPLE_RATE))
    end = min(piece.end, piece.onset + round(PROBE_SECONDS * SAMPLE_RATE))
    return with_quiet_edges(samples[start:end])


def tail_window(samples: np.ndarray, piece: Piece) -> np.ndarray:
    """What the model hears to say how a piece ends: its last second of speech."""
    start = max(piece.start, piece.finish - round(TAIL_SECONDS * SAMPLE_RATE))
    end = min(piece.end, piece.finish + round(EDGE_TAIL_SECONDS * SAMPLE_RATE))
    return with_quiet_edges(samples[start:end])


_PROBE_TAG = re.compile(r'\s*language\s+([A-Za-z]+)')
_ENGLISH_WORD = re.compile(r"[A-Za-z][A-Za-z'’-]*")
_SENTENCE_END = tuple('.!?。！？')


def _is_han(char: str) -> bool:
    """A Chinese character (CJK unified ideographs and their extension A)."""
    return 0x4E00 <= ord(char) <= 0x9FFF or 0x3400 <= ord(char) <= 0x4DBF


def _tag_and_text(head: str) -> tuple[str | None, str]:
    """("English", "Keep everything") from "language English<asr_text>Keep everything"."""
    match = _PROBE_TAG.match(head)
    return (match.group(1) if match else None), (head.split('<asr_text>', 1)[1] if '<asr_text>' in head else '')


def probe_language(head: str) -> str | None:
    """'Chinese', 'English' or None from how the model begins its answer for the start of a piece:
    "language Chinese<asr_text>明天下午" (the tag, then the first words).

    The 1.7B model tags a Chinese sentence that has English words in it as English, and then
    still writes it in Chinese: Chinese characters in the first words make it Chinese. (Told to
    write such a sentence in English, it translates it.) English needs the tag and English
    words: four of them, or two when the answer was cut off before the sentence ended. Up to
    three words that are a whole answer ("OK.", "Thank you.", "Hidden Markov model.": a term said
    between two pauses of a Chinese sentence) are not an English sentence. That, another
    language, "language None" for noise, and an answer without a tag are all None: such a piece
    goes with its neighbours.

    English here is not the last word: `transcribe_mixed` also asks how such a piece ends
    (`tail_language`)."""
    tag, text = _tag_and_text(head)
    if tag == 'Chinese':
        return 'Chinese'
    if tag == 'English':
        if any(_is_han(char) for char in text):
            return 'Chinese'
        words = len(_ENGLISH_WORD.findall(text))
        if words >= 4 or (words >= 2 and not text.rstrip().endswith(_SENTENCE_END)):
            return 'English'
    return None


def tail_language(tail: str) -> str | None:
    """The language of a piece whose start is English, from how the model begins its answer for
    the end of it.

    "As far as I know 他明天不来", said without a pause, starts as English, and the 1.7B model even
    writes the start as "As far as I know, he": asked for the whole piece in English, it
    translates the Chinese. The end, heard alone, is Chinese (the tag, or Chinese characters after
    an English tag), and so the piece is: with Chinese given, both models write such a sentence as
    it was said, English words included. An English sentence ends in English ("before lunch.":
    the tag and a word are enough here). Anything else (no tag, noise, another language) is None:
    the piece cannot be named and goes with its neighbours."""
    tag, text = _tag_and_text(tail)
    if tag == 'Chinese' or (tag == 'English' and any(_is_han(char) for char in text)):
        return 'Chinese'
    if tag == 'English' and _ENGLISH_WORD.search(text):
        return 'English'
    return None


def language_stretches(pieces: list[Piece], languages: list[str | None], min_own: float = MIN_OWN_SECONDS,
                       max_seconds: float = MAX_STRETCH_SECONDS) -> list[Stretch]:
    """The pieces grouped into what is recognised together.

    A piece with less than `min_own` seconds of speech (a filler, "谢谢", "OK") or without a
    language never stands alone: the weakest first, it joins the neighbour in its own language,
    or else the one across the shorter pause, and takes that neighbour's language. Neighbours in
    one language then form a stretch; a stretch longer than `max_seconds` is cut at a pause (the last
    one that keeps it shorter; a single piece that is longer stays whole, and `chunk_bounds` cuts it)."""
    groups = [{'language': language, 'speech': piece.speech, 'gap': piece.gap, 'pieces': [piece]}
              for piece, language in zip(pieces, languages)]

    def weak(group) -> bool:
        return group['language'] is None or group['speech'] < min_own

    while len(groups) > 1:
        weakest = min((index for index, group in enumerate(groups) if weak(group)), default=None,
                      key=lambda index: (groups[index]['language'] is not None, groups[index]['speech']))
        if weakest is None:
            break
        group = groups[weakest]
        around = [index for index in (weakest - 1, weakest + 1) if 0 <= index < len(groups)]
        alike = [index for index in around
                 if group['language'] is not None and groups[index]['language'] == group['language']]
        if len(alike) == 1:
            other = alike[0]
        elif len(around) == 1:
            other = around[0]
        else:  # the pause before it against the pause after it
            other = weakest - 1 if group['gap'] <= groups[weakest + 1]['gap'] else weakest + 1
        first, second = sorted((weakest, other))
        left, right = groups[first], groups[second]
        stronger = left if left['language'] is not None and (
            right['language'] is None or left['speech'] >= right['speech']) else right
        groups[first:second + 1] = [{'language': stronger['language'], 'speech': left['speech'] + right['speech'],
                                     'gap': left['gap'], 'pieces': left['pieces'] + right['pieces']}]
    together: list[tuple[str | None, list[Piece]]] = []
    for group in groups:
        if together and together[-1][0] == group['language']:
            together[-1][1].extend(group['pieces'])
        else:
            together.append((group['language'], list(group['pieces'])))
    stretches: list[Stretch] = []
    for language, members in together:
        start = members[0].start
        for piece, following in zip(members, members[1:]):
            # Without a language (nothing was Chinese or English) it stays whole, as in a single call.
            if language is not None and (following.end - start) / SAMPLE_RATE > max_seconds:
                stretches.append(Stretch(start, piece.end, language))
                start = piece.end
        stretches.append(Stretch(start, members[-1].end, language))
    return stretches


def _is_wide_punctuation(char: str) -> bool:
    """Full-width punctuation: CJK symbols and punctuation (U+3000–303F) and the full-width forms
    (U+FF00–FFEF) that are not letters or digits."""
    return (0x3000 <= ord(char) <= 0x303F or 0xFF00 <= ord(char) <= 0xFFEF) and not char.isalnum()


def _is_wide(char: str) -> bool:
    """Chinese characters, kana and full-width punctuation: written next to each other without a space."""
    return _is_han(char) or 0x3000 <= ord(char) <= 0x30FF or 0xFF00 <= ord(char) <= 0xFFEF


def join_texts(texts: list[str]) -> str:
    """The stretches' texts as one: Chinese next to Chinese, and anything next to full-width
    punctuation, without a space ("…下午吧。Please send…"); a space everywhere else
    ("…before lunch. 这个周末…", "…the report 然后…")."""
    joined = ''
    for text in texts:
        text = text.strip()
        if not text:
            continue
        if joined:
            before, after = joined[-1], text[0]
            tight = _is_wide_punctuation(before) or _is_wide_punctuation(after) or (_is_wide(before) and _is_wide(after))
            joined += '' if tight else ' '
        joined += text
    return joined


def transcribe_mixed(samples: np.ndarray, hints: list[str], hear, probe) -> Transcript:
    """Recognises a recording in which Chinese and English may alternate.

    `hear(samples, hints, language)` is one recognition and returns its text; `probe(windows)`
    returns how the model begins its answer for each window (`probe_language` and `tail_language`
    read it).

    - Cut at the pauses. One piece, or less than two seconds of speech in all: one call for the
      whole recording, the model picks the language (as before 1.3; nothing else is asked).
    - Ask the language of the pieces long enough to stand alone, from their first two seconds
      (the hints are not needed for that and are left out). Only when those are in two languages
      do the short pieces matter, for which side they go with, and are asked too. (When there are
      no two long pieces, all are asked at once.) A recording with more than `MAX_PROBES` long
      pieces is asked at the first one and after its longest pauses only; the pieces in between
      go with those.
    - A long piece that starts in English is asked again, for its last second: English that runs
      into Chinese without a pause ("As far as I know 他明天不来") is Chinese (`tail_language`).
    - Group into stretches (`language_stretches`). One stretch: one call for the whole
      recording, with that language. More: one call each, with its language and all the hints,
      the audio with quiet edges; the texts are joined.

    What it cannot do: a switch of language without any pause is not seen (a piece that starts
    and ends in English with Chinese in between is English), a sub-second "谢谢" or "OK" next to
    a sentence in the other language takes that sentence's language, and with noise nearly as loud
    as the voice no pause is found at all (`speech_frames`). All are then up to the model, as in
    a single call. And four or more English words said between two pauses of a Chinese sentence
    are a stretch of their own, so that sentence comes back in three."""
    pieces = split_at_pauses(samples)
    asked = [index for index, piece in enumerate(pieces) if piece.speech >= MIN_PROBE_SECONDS]
    if len(asked) < 2 or sum(piece.speech for piece in pieces) < 2 * MIN_OWN_SECONDS:
        return Transcript(hear(samples, hints, None).strip())  # too little for two stretches
    languages: list[str | None] = [None] * len(pieces)
    probes = 0

    def ask(indices: list[int], window=probe_window, read=probe_language) -> None:
        nonlocal probes
        probes += len(indices)
        heads = probe([window(samples, pieces[index]) for index in indices])
        for index, head in zip(indices, heads):
            languages[index] = read(head)

    long_enough = [index for index in asked if pieces[index].speech >= MIN_OWN_SECONDS]
    if len(long_enough) > MAX_PROBES:
        longest_pauses = sorted(long_enough[1:], key=lambda index: -pieces[index].gap)[:MAX_PROBES - 1]
        ask(sorted(long_enough[:1] + longest_pauses))
    elif len(long_enough) < 2:
        ask(asked)
    else:
        ask(long_enough)
        short = [index for index in asked if pieces[index].speech < MIN_OWN_SECONDS]
        if short and len({languages[index] for index in long_enough} - {None}) > 1:
            ask(short)
    english = [index for index in long_enough if languages[index] == 'English']
    if english:
        ask(english, tail_window, tail_language)
    stretches = language_stretches(pieces, languages)
    if len(stretches) == 1:
        return Transcript(hear(samples, hints, stretches[0].language).strip(), probes=probes)
    texts = [hear(with_quiet_edges(samples[stretch.start:stretch.end]), hints, stretch.language)
             for stretch in stretches]
    return Transcript(join_texts(texts), segments=len(stretches), probes=probes)


# ---------------------------------------------------------------- engine


def resolve_model(name: str) -> str:
    """A local model directory, or the pinned revision already in the Hugging Face cache."""
    if Path(name).is_dir():
        return str(Path(name).resolve())
    revision = MODEL_REVISIONS.get(name)
    if not revision:
        raise ValueError(f'模型 {name} 没有固定版本。')
    from huggingface_hub import snapshot_download
    return snapshot_download(repo_id=name, revision=revision, local_files_only=True,
                             allow_patterns=MODEL_FILES)


class QwenEngine:
    """Qwen3-ASR through mlx_audio. Called only from the worker's one inference thread."""

    def __init__(self, model: str = DEFAULT_MODEL, mixed: bool = True):
        self.model_id = model
        self.name = Path(model.rstrip('/')).name
        self.mixed = mixed          # False: always one call for the whole recording
        self._model = None
        self._mx = None
        self._batched = True        # False once this mlx_audio turned out to have no batched decoding

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        if self._model is not None:
            return
        import mlx.core as mx
        from mlx_audio.stt.utils import load_model
        self._mx = mx
        self._model = load_model(resolve_model(self.model_id))
        mx.clear_cache()

    def unload(self) -> None:
        if self._model is None:
            return
        self._model = None
        gc.collect()
        self._mx.clear_cache()

    def hear(self, samples: np.ndarray, hints: list[str], language: str | None = None) -> str:
        """One recognition: one model call, or one for each chunk of audio longer than 30 s
        (`chunk_bounds`; mlx_audio is told a chunk length that makes it take each as it is).
        `language` None: the model picks one, and as in mlx_audio the first chunk's language is
        given for the chunks after it; their texts are joined with a space, as it joins them."""
        self.load()
        try:
            texts = []
            for start, end in chunk_bounds(samples):
                audio = samples if (start, end) == (0, len(samples)) else samples[start:end]
                result = self._model.generate(audio=audio, language=language, max_tokens=ASR_MAX_TOKENS,
                                              chunk_duration=max(ASR_CHUNK_SECONDS, len(audio) / SAMPLE_RATE),
                                              verbose=False, hotwords=list(hints))
                texts.append(result.text.strip())
                if language is None:
                    language = next(iter(result.language or []), None)
            return ' '.join(text for text in texts if text)
        finally:
            self._mx.clear_cache()

    def probe(self, windows: list[np.ndarray]) -> list[str]:
        """How the model begins its answer for each window: "language English<asr_text>Keep everything"."""
        self.load()
        try:
            heads: list[str] = []
            for start in range(0, len(windows), PROBE_BATCH):
                heads += self._probe(windows[start:start + PROBE_BATCH])
            return heads
        finally:
            self._mx.clear_cache()

    def _probe(self, windows: list[np.ndarray]) -> list[str]:
        if self._batched and len(windows) > 1:
            # mlx_audio decodes the 30-second chunks of one long recording side by side; the same
            # code takes these windows (it pads them to one length). It is not part of its public
            # API, so anything unexpected falls back to one public call per window, which gives
            # the same answers about twice as slowly.
            try:
                from mlx_audio.lm.sample_utils import make_sampler
                sampler = make_sampler(0.0, 1.0, 0.0, min_tokens_to_keep=1, top_k=0)
                texts, *_ = self._model._generate_chunks_batched(
                    [(window, 0.0) for window in windows], max_tokens=PROBE_TOKENS * len(windows),
                    sampler=sampler, logits_processors=None, language=None, system_prompt=None,
                    batch_size=len(windows), verbose=False)
                if len(texts) == len(windows):
                    return [str(text) for text in texts]
                raise TypeError('unexpected answer')
            except (AttributeError, TypeError, ImportError) as exc:
                self._batched = False
                log(f'batched language probe not available ({type(exc).__name__}); asking one by one')
            except Exception as exc:
                log(f'batched language probe failed ({type(exc).__name__}); asking one by one')
        heads = []
        for window in windows:
            result = self._model.generate(audio=window, language=None, max_tokens=PROBE_TOKENS,
                                          chunk_duration=ASR_CHUNK_SECONDS, verbose=False)
            text, language = result.text, (list(result.language or []) or [''])[0]
            # mlx_audio takes the tag off when it is complete; put back what `probe_language` reads.
            # (It also says "English" when the model wrote no tag at all, which cannot be told apart
            # here; the batched way above keeps the answer as the model wrote it.)
            heads.append(text if text.lstrip().startswith('language') else f'language {language}<asr_text>{text}')
        return heads

    def transcribe(self, samples: np.ndarray, hints: list[str]) -> Transcript:
        if not self.mixed:
            return Transcript(self.hear(samples, hints), model=self.name)
        heard = transcribe_mixed(samples, hints, self.hear, self.probe)
        heard.model = self.name
        return heard


class AdaptiveEngine:
    """The better model while this Mac keeps up, the small one while it does not.

    A recognition by `primary` that takes longer than it may (`slow_limit`) means the machine is short
    of memory or busy: for the next `rest_seconds` the small `fallback` model answers instead, then
    `primary` gets another try. What is judged is the whole recognition of one recording (every model
    call it took) against the whole recording and what it needed: `slow_factor` of its length plus a
    second for one call, as before 1.3, and on top `probe_seconds` for every window that was asked for
    its language, and for every further stretch (a model call each) `call_seconds` and `hint_seconds`
    for each character of the hints, which are in the prompt of every call. Measured on the Neo when
    it keeps up, the large model takes about 0.15–0.25 s per second of audio in one call, 0.3–0.5 s
    per window, about half a second for a further call and 2 ms per character of hints (3 s for a
    full list of 100), so a recording with pauses is given about 2.5 times what it needs, as one
    without pauses always was. (Without these the limit was passed by ordinary recordings with
    pauses, which cost two to three times a single call.)

    A request can ask for one of them (`select`): "large" is `primary` even while it rests, "small" is
    `fallback`, "auto" the one described above. Without a `fallback` every choice is `primary`.

    Only one model is kept in memory. Called only from the worker's one inference thread, like the
    engines it wraps."""

    def __init__(self, primary, fallback=None, slow_factor: float = 0.6, rest_seconds: float = 600.0,
                 judged_from_seconds: float = 3.0, clock=time.monotonic, probe_seconds: float = 0.6,
                 call_seconds: float = 1.0, hint_seconds: float = 0.003):
        self.primary, self.fallback = primary, fallback
        self.slow_factor, self.rest_seconds, self.judged_from_seconds = slow_factor, rest_seconds, judged_from_seconds
        self.probe_seconds, self.call_seconds, self.hint_seconds = probe_seconds, call_seconds, hint_seconds
        self._clock = clock
        self._resting_until = 0.0

    @property
    def current(self):
        """The model "auto" uses now."""
        if self.fallback is not None and self._clock() < self._resting_until:
            return self.fallback
        return self.primary

    def select(self, choice: str = 'auto'):
        """The model that answers a request asking for `choice` ("auto", "large" or "small")."""
        if choice == 'large' or self.fallback is None:
            return self.primary
        return self.fallback if choice == 'small' else self.current

    @property
    def name(self) -> str:
        return self.current.name

    @property
    def loaded(self) -> bool:
        """Whether a model is in memory (either one)."""
        return bool(self.primary.loaded) or (self.fallback is not None and bool(self.fallback.loaded))

    def describe(self) -> dict:
        """For /health: what this Mac has, and which of them "auto" uses now."""
        models = {'largeModel': self.primary.name}
        if self.fallback is not None:
            models['smallModel'] = self.fallback.name
        models['autoUses'] = 'small' if self.current is not self.primary else 'large'
        return models

    def load(self, engine=None) -> None:
        """Makes `engine` (default: the one "auto" uses now) the model in memory."""
        engine = engine or self.current
        other = self.primary if engine is self.fallback else self.fallback
        if other is not None and other.loaded:
            other.unload()
        if not engine.loaded:
            engine.load()

    def unload(self) -> None:
        self.primary.unload()
        if self.fallback is not None:
            self.fallback.unload()

    def slow_limit(self, seconds: float, heard: Transcript, hints: list[str] = ()) -> float:
        """How long `primary` may take for a recording of `seconds` that was recognised as `heard` says."""
        further_call = self.call_seconds + self.hint_seconds * len(', '.join(hints))  # as mlx_audio writes them
        return (self.slow_factor * seconds + 1.0 + self.probe_seconds * heard.probes
                + further_call * max(0, heard.segments - 1))

    def transcribe(self, samples, hints: list[str], engine=None) -> Transcript:
        engine = engine or self.current
        self.load(engine)  # not part of what is judged below
        started = self._clock()
        heard = engine.transcribe(samples, hints)
        if not isinstance(heard, Transcript):
            heard = Transcript(str(heard))
        heard.model = heard.model or engine.name
        seconds = len(samples) / SAMPLE_RATE
        if engine is self.primary and self.fallback is not None and seconds >= self.judged_from_seconds:
            took = self._clock() - started
            if took > self.slow_limit(seconds, heard, hints):
                self._resting_until = self._clock() + self.rest_seconds
                log(f'slow: {took:.1f}s for {seconds:.1f}s of audio; using {self.fallback.name} '
                    f'for {self.rest_seconds:g}s')
        return heard


# ---------------------------------------------------------------- recognizer


class Recognizer:
    """Runs the engine on one thread. Requests queue in arrival order; the model loads on first
    use and is unloaded `idle_seconds` after the last request finished (0 keeps it loaded)."""

    def __init__(self, engine, idle_seconds: float = DEFAULT_IDLE_SECONDS, max_queue: int = MAX_QUEUE):
        # Always through an AdaptiveEngine, which picks the model a request asks for; with one
        # model it is the only choice.
        self.engine = engine if isinstance(engine, AdaptiveEngine) else AdaptiveEngine(engine)
        self.idle_seconds = idle_seconds
        self.max_queue = max_queue
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix='neoless-asr')
        self.pending = 0       # submitted jobs not finished yet, the running one included
        self.problem = None    # last model load failure, cleared by the next successful load
        self._loop = None
        self._idle_timer = None
        self._warming = None   # the warm-up job (`warm`) while it waits or runs: at most one at a time

    def health(self) -> dict:
        payload = {'ok': self.problem is None, 'model': self.engine.name,
                   'loaded': bool(self.engine.loaded), 'pending': self.pending, **self.engine.describe()}
        if self.problem:
            payload['problem'] = self.problem
        return payload

    def _submit(self, operation, *args) -> asyncio.Future:
        self._loop = asyncio.get_running_loop()
        self._cancel_idle_timer()
        self.pending += 1
        future = self._loop.run_in_executor(self.executor, operation, *args)
        future.add_done_callback(self._finished)
        return future

    def _finished(self, future) -> None:
        if not future.cancelled():
            future.exception()  # retrieved here, so an abandoned (shielded) job never warns
        self.pending -= 1
        if self.pending == 0:
            self._arm_idle_timer()

    def _arm_idle_timer(self) -> None:
        self._cancel_idle_timer()
        if self.idle_seconds > 0 and self.engine.loaded and self._loop is not None:
            self._idle_timer = self._loop.call_later(self.idle_seconds, self._idle)

    def _cancel_idle_timer(self) -> None:
        if self._idle_timer is not None:
            self._idle_timer.cancel()
            self._idle_timer = None

    def _idle(self) -> None:
        self._idle_timer = None
        if self.pending == 0 and self.engine.loaded:
            self._loop.run_in_executor(self.executor, self._unload_if_idle)

    def _unload_if_idle(self) -> None:
        # On the inference thread, so it never overlaps a recognition. A request that arrived
        # after the timer fired is already counted in `pending`; keep the model for it.
        if self.pending == 0 and self.engine.loaded:
            try:
                self.engine.unload()
                log('model unloaded after idle')
            except Exception as exc:
                log(f'unload failed: {type(exc).__name__}')

    def _load(self, model=None) -> int:
        model = model or self.engine.current
        if model.loaded:
            return 0
        started = time.monotonic()
        try:
            self.engine.load(model)  # the other model, if it was in memory, is unloaded first
        except Exception as exc:
            self.problem = '识别模型加载失败。'
            log(f'model load failed: {type(exc).__name__}: {str(exc)[:300]}')
            raise ModelUnavailable() from exc
        self.problem = None
        load_ms = round((time.monotonic() - started) * 1000)
        log(f'model loaded in {load_ms} ms')
        return load_ms

    def _run(self, samples: np.ndarray, rate: int, hints: list[str], choice: str, queued: float) -> dict:
        started = time.monotonic()
        model = self.engine.select(choice)  # decided once, here: "auto" may change while this runs
        load_ms = self._load(model)
        samples = resample(samples, rate)  # here, one at a time; not part of asrMs
        asr_started = time.monotonic()
        try:
            heard = self.engine.transcribe(samples, hints, model)
        except Exception as exc:
            log(f'recognition failed: {type(exc).__name__}')
            raise RequestError(500, 'asr_failed', '识别失败，请重试。', retryable=True) from exc
        raw = heard.text.strip()
        if heard.probes:
            log(f'languages: windows={heard.probes} stretches={heard.segments}')
        return {'raw': raw, 'status': 'ok' if raw else 'empty',
                'asrMs': round((time.monotonic() - asr_started) * 1000), 'loadMs': load_ms,
                'queueMs': round((started - queued) * 1000), 'model': heard.model, 'segments': heard.segments}

    def _warm(self, choice: str) -> int:
        # On the inference thread, like a recognition: the model is decided here, as `_run` decides
        # it, so a warm-up loads what a recognition right after it would use ("auto" may rest).
        try:
            return self._load(self.engine.select(choice))
        except ModelUnavailable:
            return 0  # reported by /health; the recognition that follows tries again

    @property
    def _warm_waiting(self) -> int:
        return 1 if self._warming is not None and not self._warming.done() else 0

    def warm(self, choice: str = 'auto') -> dict:
        """Gets the model a recognition asking for `choice` would use ready, without waiting for it.

        The load is a job on the inference thread like any other, so a recognition that arrives
        while it runs queues behind it and finds the model loaded: it is never loaded twice. A
        model already in memory is loaded by nobody, but the job still restarts the idle clock
        (and keeps an unload the idle timer already queued from taking the model away). One
        warm-up at a time: another one while it waits or runs changes nothing. It never takes a
        place a recognition needs: it is not counted against `max_queue`, and it is skipped when
        the queue is full (a model that busy is loaded anyway)."""
        model = self.engine.select(choice)
        # `loaded`: that model is in memory as the request arrives. `warming`: a warm-up job waits
        # or runs (this one, or the one that was already there); false only when it was skipped.
        answer = {'ok': True, 'model': model.name, 'loaded': bool(model.loaded), 'warming': True}
        if self._warm_waiting:
            return answer
        if self.pending >= self.max_queue:
            return {**answer, 'warming': False}
        self._warming = self._submit(self._warm, choice)
        return answer

    async def recognize(self, samples: np.ndarray, rate: int, hints: list[str], choice: str = 'auto') -> dict:
        if self.pending - self._warm_waiting >= self.max_queue:
            raise RequestError(503, 'busy', '识别排队已满，请稍后再试。', retryable=True)
        # Shielded: a client that gives up does not cancel the job or its bookkeeping.
        return await asyncio.shield(self._submit(self._run, samples, rate, hints, choice, time.monotonic()))

    async def preload(self) -> None:
        try:
            await self._submit(self._load)
        except ModelUnavailable:
            pass  # reported by /health; the next request tries again

    async def close(self) -> None:
        self._cancel_idle_timer()
        await asyncio.get_running_loop().run_in_executor(
            None, functools.partial(self.executor.shutdown, wait=True))


# ---------------------------------------------------------------- HTTP


def _host_name(host: str) -> str:
    host = host.lower()
    if host.startswith('['):
        return host[:host.find(']') + 1]
    return host.rsplit(':', 1)[0] if host.count(':') == 1 else host


def make_app(recognizer: Recognizer, secret: str, max_body: int = MAX_BODY_BYTES) -> web.Application:
    expected = secret.encode('utf-8')

    @web.middleware
    async def guard(request, handler):
        try:
            # Only the hub on this machine: no browser pages, no DNS-rebound host names.
            if request.headers.get('Origin') is not None or _host_name(request.host) not in LOOPBACK_HOSTS:
                raise RequestError(403, 'forbidden', '只接受本机 neoless-hub 的请求。')
            return await handler(request)
        except RequestError as error:
            return error_response(error)
        except web.HTTPRequestEntityTooLarge:
            return error_response(RequestError(413, 'too_large', '录音文件太大。'))
        except web.HTTPNotFound:
            return error_response(RequestError(404, 'not_found', '没有这个接口。'))
        except web.HTTPMethodNotAllowed:
            return error_response(RequestError(405, 'method_not_allowed', '不支持这个请求方法。'))
        except web.HTTPException:
            raise
        except Exception as exc:
            log(f'request failed: {type(exc).__name__}')
            return error_response(RequestError(500, 'internal', '识别服务出错，请重试。', retryable=True))

    app = web.Application(client_max_size=max_body, middlewares=[guard])

    async def health(_request):
        return json_response(recognizer.health())

    def check_secret(request) -> None:
        supplied = request.headers.get('X-Neoless-Worker', '').encode('utf-8', 'replace')
        if not hmac.compare_digest(supplied, expected):
            raise RequestError(401, 'unauthorized', '缺少或错误的 worker 密钥。')

    async def recognize(request):
        check_secret(request)
        if request.content_type not in WAV_TYPES:
            raise RequestError(415, 'unsupported_type', '需要 audio/wav。')
        hints = decode_hints(request.headers.get('X-Hints'))
        choice = model_choice(request.headers.get('X-Model'))
        if request.content_length is not None and request.content_length > max_body:
            raise RequestError(413, 'too_large', '录音文件太大。')
        try:
            data = await asyncio.wait_for(request.read(), timeout=UPLOAD_TIMEOUT_SECONDS)
        except TimeoutError as exc:
            raise RequestError(400, 'upload_timeout', '录音上传超时。', retryable=True) from exc
        audio = read_audio(data)
        keep_for_evaluation(data)
        if audio.is_silent():
            result = {'raw': '', 'status': 'no_speech', 'asrMs': 0, 'loadMs': 0, 'queueMs': 0,
                      'model': recognizer.engine.select(choice).name, 'segments': 0}
        else:
            result = await recognizer.recognize(audio.samples, audio.rate, hints, choice)
        result['audioSeconds'] = round(audio.seconds, 3)
        log(f"recognize {result['status']} audio={audio.seconds:.1f}s rate={audio.rate} hints={len(hints)} "
            f"model={result['model']} asked={choice} segments={result['segments']} "
            f"queue={result['queueMs']}ms load={result['loadMs']}ms asr={result['asrMs']}ms")
        return json_response(result)

    async def warm(request):
        """Answers at once; the model loads in the background (`Recognizer.warm`)."""
        check_secret(request)
        choice = model_choice(request.headers.get('X-Model'))
        result = recognizer.warm(choice)
        log(f"warm asked={choice} model={result['model']} loaded={result['loaded']} warming={result['warming']}")
        return json_response(result)

    app.router.add_get('/health', health)
    app.router.add_post('/recognize', recognize)
    app.router.add_post('/warm', warm)

    async def cleanup(_app):
        await recognizer.close()

    app.on_cleanup.append(cleanup)
    return app


def keep_for_evaluation(data: bytes) -> None:
    """Opt-in, for comparing models on the user's own voice: with NEOLESS_ASR_KEEP_DIR set, each
    recording is also saved there (0600, newest NEOLESS_ASR_KEEP_MAX kept, older than 7 days removed).
    Off by default; nothing is kept without the variable."""
    folder = os.environ.get('NEOLESS_ASR_KEEP_DIR')
    if not folder:
        return
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        name = time.strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3) + '.wav'
        fd = os.open(os.path.join(folder, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
        limit = max(1, int(os.environ.get('NEOLESS_ASR_KEEP_MAX', '20')))
        kept = sorted(f for f in os.listdir(folder) if f.endswith('.wav'))
        cutoff = time.time() - 7 * 86400
        for index, old in enumerate(kept):
            path = os.path.join(folder, old)
            if index < len(kept) - limit or os.path.getmtime(path) < cutoff:
                os.remove(path)
    except (OSError, ValueError):
        pass  # keeping a copy must never break recognition


# ---------------------------------------------------------------- command line


def parse_args(argv=None, environ=None) -> argparse.Namespace:
    environ = os.environ if environ is None else environ
    parser = argparse.ArgumentParser(description='neoless ASR worker (Qwen3-ASR on MLX), loopback only.')

    def from_env(name, kind, default):
        value = environ.get(name)
        if value is None or value == '':
            return default
        try:
            return kind(value)
        except ValueError:
            parser.error(f'{name}={value!r} is not a valid {kind.__name__}')

    parser.add_argument('--port', type=int, default=from_env('NEOLESS_ASR_PORT', int, DEFAULT_PORT),
                        help=f'port on 127.0.0.1 (env NEOLESS_ASR_PORT, default {DEFAULT_PORT})')
    parser.add_argument('--idle-unload', type=float, metavar='SECONDS',
                        default=from_env('NEOLESS_ASR_IDLE_SECONDS', float, DEFAULT_IDLE_SECONDS),
                        help='unload the model after this many idle seconds, 0 = never '
                             f'(env NEOLESS_ASR_IDLE_SECONDS, default {DEFAULT_IDLE_SECONDS:g})')
    parser.add_argument('--secret-file', default=from_env('NEOLESS_ASR_SECRET_FILE', str, DEFAULT_SECRET_FILE),
                        help=f'shared secret, created if missing (env NEOLESS_ASR_SECRET_FILE, default {DEFAULT_SECRET_FILE})')
    parser.add_argument('--model', default=from_env('NEOLESS_ASR_MODEL', str, DEFAULT_MODEL),
                        help=f'pinned model id or a local model directory (env NEOLESS_ASR_MODEL, default {DEFAULT_MODEL})')
    parser.add_argument('--fallback-model', default=from_env('NEOLESS_ASR_FALLBACK_MODEL', str, ''),
                        help='a smaller model used for ten minutes after --model was too slow for this Mac '
                             '(env NEOLESS_ASR_FALLBACK_MODEL, default: none)')
    parser.add_argument('--single-call', action='store_true',
                        default=environ.get('NEOLESS_ASR_SINGLE_CALL', '') in ('1', 'true', 'yes'),
                        help='one model call per recording, as before 1.3: no check for Chinese and English '
                             'in one recording (env NEOLESS_ASR_SINGLE_CALL=1)')
    parser.add_argument('--preload', action='store_true',
                        default=environ.get('NEOLESS_ASR_PRELOAD', '') in ('1', 'true', 'yes'),
                        help='load the model at start instead of on the first request (env NEOLESS_ASR_PRELOAD=1)')
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error(f'port {args.port} is out of range')
    if args.idle_unload < 0:
        parser.error('--idle-unload must be 0 or more')
    for model in filter(None, (args.model, args.fallback_model)):
        if model not in MODEL_REVISIONS and not Path(model).is_dir():
            parser.error(f'unknown model {model}; use one of {", ".join(MODEL_REVISIONS)} or a local directory')
    if args.fallback_model == args.model:
        args.fallback_model = ''
    return args


def main(argv=None) -> None:
    args = parse_args(argv)
    try:
        secret = load_or_create_secret(args.secret_file)
    except (SecretError, OSError) as exc:
        raise SystemExit(f'neoless-asr: {exc}')
    mixed = not args.single_call
    engine = AdaptiveEngine(QwenEngine(args.model, mixed=mixed),
                            QwenEngine(args.fallback_model, mixed=mixed) if args.fallback_model else None)
    recognizer = Recognizer(engine, idle_seconds=args.idle_unload)
    app = make_app(recognizer, secret)
    if args.preload:
        async def start_preload(app):
            app['preload'] = asyncio.create_task(recognizer.preload())
        app.on_startup.append(start_preload)
    ready = (f'ready on {HOST}:{args.port} model={recognizer.engine.name} '
             + (f'fallback={Path(args.fallback_model).name} ' if args.fallback_model else '') +
             f'idle-unload={args.idle_unload:g}s preload={args.preload} mixed={mixed}')
    web.run_app(app, host=HOST, port=args.port, access_log=None, print=lambda _: log(ready),
                **SERVER_OPTIONS)


if __name__ == '__main__':
    main()
