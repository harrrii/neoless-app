"""ASR worker tests with fake engines: protocol, queueing, lifecycle, the choice of model and
how a recording that mixes Chinese and English is cut, asked and joined. No model is loaded,
so these say nothing about recognition quality (see README.md for the real runs).

Run, in hub/asr, with the worker's Python: python -m unittest -v test_asr_worker
"""
import asyncio
import base64
import io
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
import wave

import numpy as np
from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asr_worker as w  # noqa: E402

SECRET = 'test-secret-0123456789abcdef'


def wav_bytes(samples, rate=16000, channels=1, width=2):
    samples = np.asarray(samples)
    output = io.BytesIO()
    with wave.open(output, 'wb') as audio:
        audio.setnchannels(channels)
        audio.setsampwidth(width)
        audio.setframerate(rate)
        if width == 1:
            audio.writeframes((samples // 256 + 128).astype(np.uint8).tobytes())
        else:
            audio.writeframes(samples.astype('<i2').tobytes())
    return output.getvalue()


def wav_with_format(payload, *, tag, bits, rate=16000, subformat=None):
    """A well-formed mono WAV with any fmt tag (3 = float, 7 = μ-law, 0xFFFE = extensible)."""
    block = bits // 8
    fmt = struct.pack('<HHIIHH', tag, 1, rate, rate * block, block, bits)
    if subformat is not None:  # WAVE_FORMAT_EXTENSIBLE: cbSize, valid bits, channel mask, GUID
        fmt += struct.pack('<HHI', 22, bits, 4) + struct.pack('<H', subformat) + bytes.fromhex(
            '000000001000800000aa00389b71')
    body = (b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt
            + b'data' + struct.pack('<I', len(payload)) + payload)
    return b'RIFF' + struct.pack('<I', len(body)) + body


def avaudiofile_wav(payload, *, finished=False, rate=16000):
    """The layout AVAudioFile writes for mono 16-bit PCM: JUNK(28), fmt(16), FLLR(4008), data.
    Until the writer is released the data size is 0 and the RIFF size ends at the data header
    (byte for byte what macOS 26 gives for a file read while its AVAudioFile is alive)."""
    fmt = struct.pack('<HHIIHH', 1, 1, rate, rate * 2, 2, 16)
    head = (b'WAVE' + b'JUNK' + struct.pack('<I', 28) + bytes(28) + b'fmt ' + struct.pack('<I', 16) + fmt
            + b'FLLR' + struct.pack('<I', 4008) + bytes(4008) + b'data')
    size = len(payload) if finished else 0
    return b'RIFF' + struct.pack('<I', len(head) + 4 + size) + head + struct.pack('<I', size) + payload


def tone(seconds=1.0, rate=16000, frequency=440.0, amplitude=0.3):
    t = np.arange(round(seconds * rate)) / rate
    return (np.sin(2 * np.pi * frequency * t) * amplitude * 32767).astype(np.int16)


def silence(seconds=1.0, rate=16000):
    return np.zeros(round(seconds * rate), dtype=np.int16)


def encode_hints(words, padded=False):
    text = base64.urlsafe_b64encode(json.dumps(words, ensure_ascii=False).encode('utf-8')).decode()
    return text if padded else text.rstrip('=')


class FakeEngine:
    name = 'Fake-ASR-test'

    def __init__(self, text='明天下午三点开会'):
        self.text = text
        self.is_loaded = False
        self.loads = self.unloads = 0
        self.calls = []            # (samples, hints)
        self.threads = set()
        self.block = None          # threading.Event: transcribe waits for it
        self.started = threading.Event()
        self.load_block = None     # threading.Event: load waits for it
        self.load_started = threading.Event()
        self.fail_load = self.fail_transcribe = False
        self.active = self.max_active = 0
        self.lock = threading.Lock()

    @property
    def loaded(self):
        return self.is_loaded

    def load(self):
        self.threads.add(threading.get_ident())
        self.load_started.set()
        if self.load_block is not None:
            self.load_block.wait(5)
        if self.fail_load:
            raise RuntimeError('model files missing')
        self.loads += 1
        self.is_loaded = True

    def unload(self):
        self.threads.add(threading.get_ident())
        self.unloads += 1
        self.is_loaded = False

    def transcribe(self, samples, hints):
        self.threads.add(threading.get_ident())
        with self.lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        try:
            self.calls.append((samples, list(hints)))
            self.started.set()
            if self.block is not None:
                self.block.wait(5)
            if self.fail_transcribe:
                raise RuntimeError('metal error')
            return self.text
        finally:
            with self.lock:
                self.active -= 1


class WorkerTestCase(unittest.IsolatedAsyncioTestCase):
    idle_seconds = 600.0
    max_queue = w.MAX_QUEUE
    max_body = w.MAX_BODY_BYTES

    async def asyncSetUp(self):
        self.logs = []
        patcher = unittest.mock.patch.object(w, 'log', self.logs.append)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.engine = FakeEngine()
        self.recognizer = w.Recognizer(self.engine, idle_seconds=self.idle_seconds, max_queue=self.max_queue)
        self.server = TestServer(w.make_app(self.recognizer, SECRET, max_body=self.max_body))
        await self.server.start_server(**w.SERVER_OPTIONS)
        self.client = TestClient(self.server)
        await self.client.start_server()

    async def asyncTearDown(self):
        if self.engine.block is not None:
            self.engine.block.set()
        if self.engine.load_block is not None:
            self.engine.load_block.set()
        await self.client.close()

    async def post(self, body=None, *, secret=SECRET, content_type='audio/wav', hints=None, headers=None):
        sent = {}
        if secret is not None:
            sent['X-Neoless-Worker'] = secret
        if content_type is not None:
            sent['Content-Type'] = content_type
        if hints is not None:
            sent['X-Hints'] = hints if isinstance(hints, str) else encode_hints(hints)
        sent.update(headers or {})
        body = wav_bytes(tone()) if body is None else body
        if isinstance(body, bytes) and len(body) > 1 << 20:
            body = io.BytesIO(body)  # aiohttp warns about big raw bytes bodies
        response = await self.client.post('/recognize', data=body, headers=sent)
        return response.status, await response.json()

    async def warm(self, choice=None, *, secret=SECRET):
        sent = {} if secret is None else {'X-Neoless-Worker': secret}
        if choice is not None:
            sent['X-Model'] = choice
        response = await self.client.post('/warm', headers=sent)
        return response.status, await response.json()

    async def health(self):
        response = await self.client.get('/health')
        self.assertEqual(response.status, 200)
        return await response.json()

    async def wait_until(self, condition, timeout=3.0):
        deadline = time.monotonic() + timeout
        while not condition():
            if time.monotonic() > deadline:
                self.fail('condition not reached in time')
            await asyncio.sleep(0.01)

    def assertError(self, result, status, code, retryable=False):
        self.assertEqual(result[0], status, result)
        self.assertEqual(result[1]['code'], code)
        self.assertIs(result[1]['retryable'], retryable)
        self.assertIsInstance(result[1]['error'], str)
        self.assertTrue(result[1]['error'])


class AuthTests(WorkerTestCase):
    async def test_correct_secret_recognizes(self):
        status, body = await self.post(hints=['开会'])
        self.assertEqual(status, 200)
        self.assertEqual(body['raw'], '明天下午三点开会')
        self.assertEqual(body['status'], 'ok')
        self.assertEqual(body['model'], 'Fake-ASR-test')
        self.assertEqual(body['segments'], 1)
        self.assertIsInstance(body['asrMs'], int)
        self.assertIsInstance(body['loadMs'], int)
        self.assertIsInstance(body['queueMs'], int)
        self.assertEqual(body['audioSeconds'], 1.0)
        self.assertTrue(self.logs)
        self.assertFalse([line for line in self.logs if '开会' in line])  # no words in the log

    async def test_missing_or_wrong_secret_is_rejected_before_the_engine(self):
        self.assertError(await self.post(secret=None), 401, 'unauthorized')
        self.assertError(await self.post(secret='wrong-secret-0123456789'), 401, 'unauthorized')
        self.assertError(await self.post(secret=SECRET + 'x'), 401, 'unauthorized')
        self.assertError(await self.post(secret=''), 401, 'unauthorized')
        self.assertEqual(self.engine.calls, [])
        self.assertEqual(self.engine.loads, 0)

    async def test_browser_origin_and_foreign_host_are_forbidden(self):
        self.assertError(await self.post(headers={'Origin': 'https://example.com'}), 403, 'forbidden')
        self.assertError(await self.post(headers={'Host': 'evil.example:18801'}), 403, 'forbidden')
        response = await self.client.get('/health', headers={'Host': 'rebound.example'})
        self.assertEqual(response.status, 403)
        self.assertEqual(self.engine.calls, [])

    async def test_loopback_host_names_are_accepted(self):
        for host in ('localhost:18801', 'LOCALHOST', '[::1]:18801', '127.0.0.1'):
            status, _ = await self.post(headers={'Host': host})
            self.assertEqual(status, 200, host)

    async def test_unknown_route_and_method_answer_json(self):
        response = await self.client.get('/nope')
        self.assertEqual(response.status, 404)
        self.assertEqual((await response.json())['code'], 'not_found')
        response = await self.client.get('/recognize')
        self.assertEqual(response.status, 405)
        self.assertEqual((await response.json())['code'], 'method_not_allowed')


class ValidationTests(WorkerTestCase):
    async def test_content_type_must_be_wav(self):
        self.assertError(await self.post(content_type='audio/mp4'), 415, 'unsupported_type')
        self.assertError(await self.post(content_type='application/octet-stream'), 415, 'unsupported_type')
        for accepted in ('audio/wav', 'audio/x-wav', 'audio/wave'):
            status, _ = await self.post(content_type=accepted)
            self.assertEqual(status, 200, accepted)

    async def test_unreadable_bodies(self):
        self.assertError(await self.post(b''), 400, 'bad_audio')
        self.assertError(await self.post(b'not a wav file at all'), 400, 'bad_audio')
        self.assertError(await self.post(wav_bytes(tone())[:20]), 400, 'bad_audio')
        self.assertEqual(self.engine.calls, [])

    def test_damaged_headers_only_raise_request_errors(self):
        good = wav_bytes(tone(0.5))
        unfinished = avaudiofile_wav(tone(0.5).astype('<i2').tobytes())
        rng = np.random.default_rng(7)
        cases = [good[:n] for n in range(0, 60)] + [unfinished[:n] for n in range(4080, 4110)]
        for _ in range(3000):
            damaged = bytearray(good[:400])
            for index in rng.integers(4, 60, size=rng.integers(1, 6)):
                damaged[index] = int(rng.integers(0, 256))
            cases.append(bytes(damaged))
        for _ in range(1000):  # the sizes AVAudioFile fills in late, and the chunks around them
            damaged = bytearray(unfinished[:4400])
            for index in rng.choice([*range(4, 8), *range(72, 80), *range(4088, 4100)], size=rng.integers(1, 4)):
                damaged[index] = int(rng.integers(0, 256))
            cases.append(bytes(damaged))
        for data in cases:
            try:
                w.read_audio(data)
            except w.RequestError as error:
                self.assertIn(error.code, ('bad_audio', 'unsupported_audio', 'too_long'))

    async def test_unsupported_formats(self):
        stereo = np.repeat(tone(), 2)
        self.assertError(await self.post(wav_bytes(stereo, channels=2)), 415, 'unsupported_audio')
        self.assertError(await self.post(wav_bytes(tone(), width=1)), 415, 'unsupported_audio')
        self.assertError(await self.post(wav_bytes(tone(rate=96000), rate=96000)), 415, 'unsupported_audio')
        self.assertError(await self.post(wav_bytes(tone(rate=6000), rate=6000)), 415, 'unsupported_audio')
        # Readable WAVs that are not integer PCM: float32 (AVAudioFile's default), μ-law,
        # extensible float. The wave module calls these "unknown format"; still a 415.
        floats = (tone().astype(np.float32) / 32768).astype('<f4').tobytes()
        self.assertError(await self.post(wav_with_format(floats, tag=3, bits=32)), 415, 'unsupported_audio')
        self.assertError(await self.post(wav_with_format(bytes(16000), tag=7, bits=8)), 415, 'unsupported_audio')
        self.assertError(await self.post(wav_with_format(floats, tag=0xFFFE, bits=32, subformat=3)),
                         415, 'unsupported_audio')
        self.assertEqual(self.engine.calls, [])
        # Extensible 16-bit PCM is plain PCM.
        pcm = tone().astype('<i2').tobytes()
        status, body = await self.post(wav_with_format(pcm, tag=0xFFFE, bits=16, subformat=1))
        self.assertEqual(status, 200, body)
        self.assertEqual(len(self.engine.calls[-1][0]), 16000)

    async def test_ten_minute_boundary(self):
        status, body = await self.post(wav_bytes(silence(600, rate=8000), rate=8000))
        self.assertEqual(status, 200)
        self.assertEqual(body['audioSeconds'], 600.0)
        self.assertError(await self.post(wav_bytes(np.zeros(600 * 8000 + 1, np.int16), rate=8000)),
                         413, 'too_long')

    async def test_short_or_silent_audio_is_no_speech_without_loading(self):
        for samples in (silence(1.0), tone(0.19), np.zeros(0, np.int16), np.full(16000, 2, np.int16)):
            status, body = await self.post(wav_bytes(samples))
            self.assertEqual(status, 200)
            self.assertEqual((body['raw'], body['status'], body['asrMs']), ('', 'no_speech', 0))
            self.assertEqual((body['model'], body['segments']), ('Fake-ASR-test', 0))
        self.assertEqual(self.engine.loads, 0)
        self.assertEqual(self.engine.calls, [])
        status, body = await self.post(wav_bytes(tone(0.2)))
        self.assertEqual(body['status'], 'ok')

    async def test_empty_transcript_is_empty_status(self):
        self.engine.text = '   '
        status, body = await self.post()
        self.assertEqual(status, 200)
        self.assertEqual((body['raw'], body['status']), ('', 'empty'))

    async def test_streaming_wav_with_unset_length_is_read_by_its_data(self):
        data = bytearray(wav_bytes(tone(1.0)))
        data[40:44] = (0x7FFFFFFF).to_bytes(4, 'little')  # data chunk size left "unknown"
        status, body = await self.post(bytes(data))
        self.assertEqual(status, 200, body)
        self.assertEqual(len(self.engine.calls[-1][0]), 16000)

    async def test_avaudiofile_header_read_before_the_writer_is_released(self):
        # AVAudioFile fills in the sizes only when it is released (no close() before macOS 15):
        # read inside the writer's scope, the file says data size 0 with the samples after it.
        pcm = tone(1.0).astype('<i2').tobytes()
        unfinished = avaudiofile_wav(pcm)
        self.assertEqual((len(unfinished), unfinished[4:8], unfinished[4088:4096]),
                         (36096, (4088).to_bytes(4, 'little'), b'data' + bytes(4)))
        expected = tone(1.0).astype(np.float32) / 32768
        for data in (unfinished, avaudiofile_wav(pcm, finished=True)):
            status, body = await self.post(data)
            self.assertEqual((status, body['status'], body['audioSeconds']), (200, 'ok', 1.0), body)
            np.testing.assert_array_equal(self.engine.calls[-1][0], expected)
        self.assertEqual(len([line for line in self.logs if 'not finished' in line]), 1)
        # An odd last byte (a sample still being written) is dropped.
        status, body = await self.post(avaudiofile_wav(pcm + b'\x01'))
        self.assertEqual((status, body['audioSeconds']), (200, 1.0), body)

    async def test_unfinished_header_keeps_the_usual_answers(self):
        status, body = await self.post(avaudiofile_wav(b''))  # nothing written yet
        self.assertEqual((status, body['status'], body['audioSeconds']), (200, 'no_speech', 0.0))
        status, body = await self.post(avaudiofile_wav(silence(1.0).tobytes()))
        self.assertEqual((status, body['status'], body['audioSeconds']), (200, 'no_speech', 1.0))
        status, body = await self.post(avaudiofile_wav(silence(600, 8000).tobytes(), rate=8000))
        self.assertEqual((status, body['audioSeconds']), (200, 600.0))
        self.assertError(await self.post(avaudiofile_wav(np.zeros(600 * 8000 + 1, np.int16).tobytes(), rate=8000)),
                         413, 'too_long')
        floats = avaudiofile_wav(bytes(32000))
        floats = floats[:56] + struct.pack('<H', 3) + floats[58:]  # fmt tag 3: float
        self.assertError(await self.post(floats), 415, 'unsupported_audio')
        self.assertEqual(self.engine.calls, [])

    async def test_empty_data_chunk_with_bytes_after_it_is_never_silence_by_mistake(self):
        pcm = tone(1.0).astype('<i2').tobytes()
        # The RIFF size claims more than the file holds: what follows cannot be told apart.
        for riff in (0xFFFFFFFF, 0x7FFFFFFF, 4088 + len(pcm) + 2):
            data = bytearray(avaudiofile_wav(pcm))
            data[4:8] = riff.to_bytes(4, 'little')
            self.assertError(await self.post(bytes(data)), 400, 'bad_audio')
        # A finished header whose data chunk is empty and followed by another chunk is just empty.
        info = b'INFO' + b'ISFT' + struct.pack('<I', 4) + b'neo\0'
        data = bytearray(avaudiofile_wav(b'', finished=True) + b'LIST' + struct.pack('<I', len(info)) + info)
        data[4:8] = (len(data) - 8).to_bytes(4, 'little')
        status, body = await self.post(bytes(data))
        self.assertEqual((status, body['status'], body['audioSeconds']), (200, 'no_speech', 0.0))
        self.assertEqual(self.engine.calls, [])


class BodyLimitTests(WorkerTestCase):
    max_body = 4096

    async def test_body_over_the_limit_is_rejected(self):
        self.assertError(await self.post(wav_bytes(tone(1.0))), 413, 'too_large')
        status, _ = await self.post(wav_bytes(tone(0.25, rate=8000), rate=8000))
        self.assertEqual(status, 200)

    async def test_chunked_body_over_the_limit_is_rejected(self):
        data = wav_bytes(tone(1.0))

        async def chunks():
            for start in range(0, len(data), 1000):
                yield data[start:start + 1000]

        self.assertError(await self.post(chunks()), 413, 'too_large')
        self.assertEqual(self.engine.calls, [])


class ResampleTests(WorkerTestCase):
    def dominant_frequency(self, samples):
        spectrum = np.abs(np.fft.rfft(samples))
        return np.argmax(spectrum) * w.SAMPLE_RATE / len(samples)

    async def test_other_rates_reach_the_engine_at_16_khz(self):
        for rate, seconds in ((48000, 1.0), (44100, 1.0), (22050, 0.5), (8000, 0.5), (16000, 1.0)):
            status, body = await self.post(wav_bytes(tone(seconds, rate, frequency=1000), rate=rate))
            self.assertEqual(status, 200, rate)
            self.assertAlmostEqual(body['audioSeconds'], seconds, places=3)
            samples = self.engine.calls[-1][0]
            self.assertEqual(samples.dtype, np.float32)
            self.assertEqual(len(samples), round(seconds * 16000), rate)
            self.assertAlmostEqual(self.dominant_frequency(samples), 1000, delta=3, msg=rate)

    def test_resample_keeps_level_and_drops_what_16_khz_cannot_hold(self):
        source = tone(1.0, 48000, frequency=1000).astype(np.float32) / 32768
        output = w.resample(source, 48000)
        self.assertAlmostEqual(float(np.sqrt(np.mean(output ** 2))), float(np.sqrt(np.mean(source ** 2))), delta=0.005)
        for rate in (48000, 44100):
            high = tone(1.0, rate, frequency=12000).astype(np.float32) / 32768  # above 8 kHz: must vanish
            # Away from the first and last few samples, where a tone that starts at full
            # strength rings through the filter (real recordings start and end quietly).
            self.assertLess(float(np.max(np.abs(w.resample(high, rate)[16:-16]))), 0.001, rate)

    def test_awkward_lengths_and_rates_take_no_longer(self):
        # A whole-recording FFT took 26 s for 441 × a prime number of samples at 44.1 kHz and
        # 18 s for 300.49 s at 48 kHz. Resampling must stay linear in the length.
        for rate, count in ((44100, 441 * 30011), (48000, 14423311), (48000, 48000 * 60 + 17),
                            (44056, 44056 * 60 + 1), (8001, 8001 * 60 + 1)):
            started = time.monotonic()
            output = w.resample(np.zeros(count, np.float32), rate)
            self.assertLess(time.monotonic() - started, 3.0, (rate, count))
            self.assertEqual(len(output), round(count * 16000 / rate))
            self.assertEqual(output.dtype, np.float32)

    async def test_resampling_is_not_counted_as_recognition(self):
        original = w.resample

        def slow_resample(samples, rate):
            time.sleep(0.3)
            return original(samples, rate)

        with unittest.mock.patch.object(w, 'resample', slow_resample):
            status, body = await self.post(wav_bytes(tone(1.0, 48000), rate=48000))
        self.assertEqual(status, 200, body)
        self.assertLess(body['asrMs'], 250)
        self.assertEqual(len(self.engine.calls[-1][0]), 16000)

    def test_output_lands_exactly_on_the_16_khz_grid(self):
        for rate, count in ((48000, 48001), (44100, 44107), (8000, 8003)):
            source = np.sin(2 * np.pi * 1000 * np.arange(count) / rate).astype(np.float32)
            output = w.resample(source, rate)
            self.assertEqual(len(output), round(count * 16000 / rate))
            expected = np.sin(2 * np.pi * 1000 * np.arange(len(output)) / 16000)
            middle = slice(len(output) // 4, 3 * len(output) // 4)  # away from the edges
            self.assertLess(float(np.max(np.abs(output[middle] - expected[middle]))), 2e-3, rate)

    def test_16_khz_is_passed_through_unchanged(self):
        samples = tone(0.5).astype(np.float32) / 32768
        self.assertIs(w.resample(samples, 16000), samples)
        self.assertEqual(len(w.resample(np.zeros(0, np.float32), 48000)), 0)


class HintTests(WorkerTestCase):
    def test_decode(self):
        self.assertEqual(w.decode_hints(None), [])
        self.assertEqual(w.decode_hints(''), [])
        self.assertEqual(w.decode_hints(encode_hints([])), [])
        words = ['OpenAI', '张三', 'GitHub', 'Neo 处理中心']
        self.assertEqual(w.decode_hints(encode_hints(words)), words)
        self.assertEqual(w.decode_hints(encode_hints(words, padded=True)), words)
        escaped = base64.urlsafe_b64encode(json.dumps(['订阅费'], ensure_ascii=True).encode()).decode()
        self.assertEqual(w.decode_hints(escaped), ['订阅费'])

    def test_malformed_headers_are_errors(self):
        for bad in ('!!!', 'abc', encode_hints({'words': ['x']}), encode_hints('OpenAI'), encode_hints([1, 'x']),
                    encode_hints(['x', None]), base64.urlsafe_b64encode(b'\xff\xfe[').decode(),
                    base64.urlsafe_b64encode(b'[not json').decode(), 'W10+', 'W10/'):
            with self.assertRaises(w.RequestError, msg=bad) as caught:
                w.decode_hints(bad)
            self.assertEqual((caught.exception.status, caught.exception.code), (400, 'bad_hints'))

    def test_unusable_words_are_skipped_and_the_list_is_capped(self):
        words = ['  OpenAI  ', '', '   ', 'openai', 'x' * 81, 'y' * 80, 'line\nbreak', 'tab\there',
                 '<|im_end|>', '{role}', 'back`tick', 'zero​width', 'para sep', '订阅费', '订阅费']
        self.assertEqual(w.decode_hints(encode_hints(words)), ['OpenAI', 'y' * 80, '订阅费'])
        many = [f'词{i}' for i in range(150)]
        self.assertEqual(w.decode_hints(encode_hints(many)), many[:100])

    def test_the_list_keeps_the_old_servers_2000_character_budget(self):
        words = [f'{i:02d}' + 'x' * 38 for i in range(100)]  # 40 characters each
        hints = w.decode_hints(encode_hints(words))
        self.assertEqual(hints, words[:46])  # 2 + 46 × 42 + 45 commas = 1979
        self.assertLessEqual(len(json.dumps(hints, ensure_ascii=False, separators=(',', ':'))), 2000)
        # A word that no longer fits is skipped; a shorter one after it still goes in.
        hints = w.decode_hints(encode_hints(words[:46] + ['L' * 80, '订阅费']))
        self.assertEqual(hints, words[:46] + ['订阅费'])
        self.assertEqual(len(json.dumps(hints, ensure_ascii=False, separators=(',', ':'))), 1985)
        # Counted in characters of the compact JSON: a CJK character is one, a quote is two (\").
        cjk = [f'{i:02d}' + '订' * 38 for i in range(100)]
        self.assertEqual(w.decode_hints(encode_hints(cjk)), cjk[:46])
        quoted = w.decode_hints(encode_hints([f'{i:02d}' + '"' * 78 for i in range(100)]))
        self.assertEqual(len(quoted), 12)  # 2 + 12 × 160 + 11 = 1933; one more is 2094

    async def test_hints_reach_the_engine_in_order(self):
        status, _ = await self.post(hints=['OpenAI', '订阅费用'])
        self.assertEqual(status, 200)
        self.assertEqual(self.engine.calls[-1][1], ['OpenAI', '订阅费用'])
        await self.post()
        self.assertEqual(self.engine.calls[-1][1], [])

    async def test_bad_hints_header_is_rejected_before_the_engine(self):
        self.assertError(await self.post(hints='***'), 400, 'bad_hints')
        self.assertEqual(self.engine.calls, [])

    async def test_largest_allowed_hint_list_fits_in_the_header(self):
        words = [chr(0x4E00 + i) * 80 for i in range(100)]  # 100 × 80 CJK characters
        escaped = base64.urlsafe_b64encode(json.dumps(words, ensure_ascii=True).encode()).decode()
        self.assertGreater(len(escaped), 8190)  # bigger than aiohttp's default header limit
        status, body = await self.post(hints=escaped)
        self.assertEqual(status, 200, body)
        self.assertEqual(self.engine.calls[-1][1], words[:24])  # 2 + 24 × 82 + 23 = 1993 characters


class QueueTests(WorkerTestCase):
    max_queue = 3

    async def test_requests_run_one_at_a_time_on_one_thread(self):
        self.engine.block = threading.Event()
        tasks = [asyncio.create_task(self.post(hints=[f'词{i}'])) for i in range(3)]
        await self.wait_until(lambda: self.recognizer.pending == 3)
        self.assertTrue(await asyncio.to_thread(self.engine.started.wait, 2))
        health = await self.health()
        self.assertEqual(health['pending'], 3)
        self.assertEqual(len(self.engine.calls), 1)  # the others wait in the queue
        self.engine.block.set()
        results = await asyncio.gather(*tasks)
        self.assertEqual([status for status, _ in results], [200, 200, 200])
        self.assertEqual(self.engine.max_active, 1)
        self.assertEqual(len(self.engine.threads), 1)
        self.assertEqual(sorted(hints[0] for _, hints in self.engine.calls), ['词0', '词1', '词2'])
        self.assertTrue(any(body['queueMs'] > 0 for _, body in results))
        self.assertEqual(self.recognizer.pending, 0)

    async def test_full_queue_answers_busy(self):
        self.engine.block = threading.Event()
        tasks = [asyncio.create_task(self.post()) for _ in range(3)]
        await self.wait_until(lambda: self.recognizer.pending == 3)
        self.assertError(await self.post(), 503, 'busy', retryable=True)
        status, body = await self.post(wav_bytes(silence()))  # no_speech never queues
        self.assertEqual((status, body['status']), (200, 'no_speech'))
        self.engine.block.set()
        self.assertEqual([status for status, _ in await asyncio.gather(*tasks)], [200, 200, 200])
        status, _ = await self.post()
        self.assertEqual(status, 200)

    async def test_a_client_that_gives_up_does_not_break_the_queue(self):
        self.engine.block = threading.Event()
        abandoned = asyncio.create_task(self.post())
        self.assertTrue(await asyncio.to_thread(self.engine.started.wait, 2))
        abandoned.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await abandoned
        await asyncio.sleep(0.3)  # let the server see the closed connection and cancel its handler
        self.assertEqual(self.recognizer.pending, 1)  # the job itself keeps running
        self.assertTrue((await self.health())['loaded'])
        self.engine.block.set()
        await self.wait_until(lambda: self.recognizer.pending == 0)
        status, body = await self.post()
        self.assertEqual((status, body['status']), (200, 'ok'))


class FailureTests(WorkerTestCase):
    async def test_load_failure_is_reported_and_recovers(self):
        self.engine.fail_load = True
        self.assertError(await self.post(), 503, 'model_unavailable')
        health = await self.health()
        self.assertFalse(health['ok'])
        self.assertFalse(health['loaded'])
        self.assertTrue(health['problem'])
        self.engine.fail_load = False
        status, body = await self.post()
        self.assertEqual((status, body['status']), (200, 'ok'))
        health = await self.health()
        self.assertTrue(health['ok'])
        self.assertNotIn('problem', health)

    async def test_recognition_failure_is_retryable_and_the_worker_keeps_going(self):
        self.engine.fail_transcribe = True
        self.assertError(await self.post(), 500, 'asr_failed', retryable=True)
        self.engine.fail_transcribe = False
        status, _ = await self.post()
        self.assertEqual(status, 200)
        self.assertEqual(self.recognizer.pending, 0)


class HealthTests(WorkerTestCase):
    async def test_health_needs_no_secret_and_tracks_the_model(self):
        only = {'largeModel': 'Fake-ASR-test', 'autoUses': 'large'}  # one model: no smallModel
        self.assertEqual(await self.health(), {'ok': True, 'model': 'Fake-ASR-test', 'loaded': False, 'pending': 0, **only})
        status, body = await self.post()
        self.assertEqual(status, 200)
        self.assertGreaterEqual(body['loadMs'], 0)
        self.assertEqual(await self.health(), {'ok': True, 'model': 'Fake-ASR-test', 'loaded': True, 'pending': 0, **only})
        self.assertEqual(self.engine.loads, 1)
        await self.post()
        self.assertEqual(self.engine.loads, 1)  # stays loaded between requests

    async def test_preload(self):
        await self.recognizer.preload()
        self.assertTrue((await self.health())['loaded'])
        status, body = await self.post()
        self.assertEqual((status, body['loadMs']), (200, 0))


class IdleUnloadTests(WorkerTestCase):
    idle_seconds = 0.2

    async def test_unloads_after_idle_and_reloads_on_the_next_request(self):
        await self.post()
        self.assertTrue(self.engine.loaded)
        await self.wait_until(lambda: not self.engine.loaded)
        self.assertEqual(self.engine.unloads, 1)
        self.assertFalse((await self.health())['loaded'])
        status, body = await self.post()
        self.assertEqual((status, body['status']), (200, 'ok'))
        self.assertEqual(self.engine.loads, 2)
        self.assertEqual(len(self.engine.threads), 1)  # load, recognize and unload share the thread

    async def test_no_unload_while_a_request_is_in_flight(self):
        await self.post()
        self.engine.block = threading.Event()
        self.engine.started.clear()
        task = asyncio.create_task(self.post())
        self.assertTrue(await asyncio.to_thread(self.engine.started.wait, 2))
        await asyncio.sleep(0.5)
        self.assertTrue(self.engine.loaded)
        self.assertEqual(self.engine.unloads, 0)
        self.engine.block.set()
        self.assertEqual((await task)[0], 200)
        await self.wait_until(lambda: not self.engine.loaded)

    async def test_each_request_restarts_the_idle_clock(self):
        for _ in range(4):
            await self.post()
            await asyncio.sleep(0.05)
        self.assertEqual(self.engine.unloads, 0)
        await self.wait_until(lambda: not self.engine.loaded)

    def test_queued_unload_is_skipped_when_a_request_arrived(self):
        self.engine.is_loaded = True
        self.recognizer.pending = 1
        self.recognizer._unload_if_idle()
        self.assertTrue(self.engine.loaded)
        self.recognizer.pending = 0
        self.recognizer._unload_if_idle()
        self.assertFalse(self.engine.loaded)


class KeepLoadedTests(WorkerTestCase):
    idle_seconds = 0

    async def test_zero_idle_keeps_the_model(self):
        await self.post()
        await asyncio.sleep(0.3)
        self.assertTrue(self.engine.loaded)
        self.assertIsNone(self.recognizer._idle_timer)


class WarmTests(WorkerTestCase):
    """/warm: the hub asks for the model while the user is still speaking."""

    async def test_needs_the_secret(self):
        self.assertError(await self.warm(secret=None), 401, 'unauthorized')
        self.assertError(await self.warm(secret='wrong-secret-0123456789'), 401, 'unauthorized')
        response = await self.client.get('/warm')
        self.assertEqual(response.status, 405)
        await asyncio.sleep(0.05)
        self.assertEqual((self.engine.loads, self.recognizer.pending), (0, 0))

    async def test_answers_at_once_and_loads_in_the_background(self):
        self.engine.load_block = threading.Event()
        started = time.monotonic()
        status, body = await self.warm()
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual((status, body), (200, {'ok': True, 'model': 'Fake-ASR-test', 'loaded': False, 'warming': True}))
        self.assertTrue(await asyncio.to_thread(self.engine.load_started.wait, 2))
        health = await self.health()
        self.assertEqual((health['loaded'], health['pending']), (False, 1))
        self.engine.load_block.set()
        await self.wait_until(lambda: self.recognizer.pending == 0)
        self.assertTrue((await self.health())['loaded'])
        self.assertEqual(self.engine.loads, 1)
        self.assertTrue([line for line in self.logs if line.startswith('warm asked=auto model=Fake-ASR-test')])
        # Already in memory: nothing is loaded again.
        status, body = await self.warm()
        self.assertEqual((status, body['loaded']), (200, True))
        await self.wait_until(lambda: self.recognizer.pending == 0)
        self.assertEqual(self.engine.loads, 1)

    async def test_a_recognition_during_the_warm_up_waits_for_that_same_load(self):
        self.engine.load_block = threading.Event()
        await self.warm()
        self.assertTrue(await asyncio.to_thread(self.engine.load_started.wait, 2))
        recognition = asyncio.create_task(self.post())
        await self.wait_until(lambda: self.recognizer.pending == 2)
        await asyncio.sleep(0.2)
        self.assertFalse(recognition.done())
        self.assertEqual(self.engine.calls, [])
        self.engine.load_block.set()
        status, body = await recognition
        self.assertEqual((status, body['status']), (200, 'ok'))
        self.assertEqual(self.engine.loads, 1)         # loaded once, by the warm-up
        self.assertEqual(body['loadMs'], 0)            # the recognition found it loaded
        self.assertGreater(body['queueMs'], 100)       # and waited for that load in the queue
        self.assertEqual(len(self.engine.threads), 1)  # on the one inference thread

    async def test_one_warm_up_at_a_time(self):
        self.engine.load_block = threading.Event()
        for _ in range(3):
            status, body = await self.warm()
            self.assertEqual((status, body['warming']), (200, True))
        self.assertEqual(self.recognizer.pending, 1)
        self.engine.load_block.set()
        await self.wait_until(lambda: self.recognizer.pending == 0)
        self.assertEqual(self.engine.loads, 1)

    async def test_a_failed_load_is_reported_like_any_other(self):
        self.engine.fail_load = True
        self.assertEqual((await self.warm())[0], 200)
        await self.wait_until(lambda: self.recognizer.pending == 0)
        health = await self.health()
        self.assertFalse(health['ok'])
        self.assertTrue(health['problem'])
        self.engine.fail_load = False
        status, body = await self.post()               # the recognition tries again
        self.assertEqual((status, body['status']), (200, 'ok'))
        self.assertTrue((await self.health())['ok'])


class WarmQueueTests(WorkerTestCase):
    max_queue = 3

    async def test_a_warm_up_never_takes_a_place_a_recognition_needs(self):
        self.engine.block = threading.Event()
        first = [asyncio.create_task(self.post()) for _ in range(2)]
        await self.wait_until(lambda: self.recognizer.pending == 2)
        self.assertEqual((await self.warm())[1]['warming'], True)
        self.assertEqual(self.recognizer.pending, 3)
        third = asyncio.create_task(self.post())       # the warm-up does not count: still room
        await self.wait_until(lambda: self.recognizer.pending == 4)
        self.assertError(await self.post(), 503, 'busy', retryable=True)
        self.engine.block.set()
        results = await asyncio.gather(*first, third)
        self.assertEqual([status for status, _ in results], [200, 200, 200])
        await self.wait_until(lambda: self.recognizer.pending == 0)

    async def test_with_the_queue_full_it_is_skipped(self):
        self.engine.block = threading.Event()
        tasks = [asyncio.create_task(self.post()) for _ in range(3)]
        await self.wait_until(lambda: self.recognizer.pending == 3)
        status, body = await self.warm()
        self.assertEqual((status, body['warming']), (200, False))
        self.assertEqual(self.recognizer.pending, 3)
        self.engine.block.set()
        await asyncio.gather(*tasks)


class WarmIdleTests(WorkerTestCase):
    idle_seconds = 0.3

    async def test_a_warm_up_restarts_the_idle_clock(self):
        await self.post()
        for _ in range(6):
            await asyncio.sleep(0.1)
            self.assertEqual((await self.warm())[0], 200)
        self.assertEqual(self.engine.unloads, 0)       # 0.6 s, twice the idle time, and still loaded
        await self.wait_until(lambda: not self.engine.loaded)
        # Unloaded after idle: the next warm-up loads it again, before any recognition.
        await self.warm()
        await self.wait_until(lambda: self.engine.loaded)
        self.assertEqual(self.engine.loads, 2)


class SecretTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.path = self.root / 'neoless-hub' / 'worker-secret'

    def mode(self, path):
        return stat.S_IMODE(os.stat(path).st_mode)

    def test_created_private_when_missing_and_stable_afterwards(self):
        value = w.load_or_create_secret(self.path)
        self.assertGreaterEqual(len(value), 40)
        self.assertRegex(value, r'^[A-Za-z0-9_-]+$')
        self.assertEqual(self.mode(self.path.parent), 0o700)
        self.assertEqual(self.mode(self.path), 0o600)
        self.assertEqual(self.path.read_text(), value)
        self.assertEqual(w.load_or_create_secret(self.path), value)
        self.assertEqual([p.name for p in self.path.parent.iterdir()], ['worker-secret'])  # no temp left

    def test_existing_secret_is_kept_trimmed_and_tightened_in_the_hub_folder(self):
        self.path.parent.mkdir(mode=0o755)
        os.chmod(self.path.parent, 0o755)
        self.path.write_text('  hub-made-secret-value-1234\n')
        os.chmod(self.path, 0o644)
        self.assertEqual(w.load_or_create_secret(self.path, hub_folder=self.path.parent), 'hub-made-secret-value-1234')
        self.assertEqual(self.mode(self.path), 0o600)
        self.assertEqual(self.mode(self.path.parent), 0o700)
        self.assertEqual(Path(w.DEFAULT_SECRET_FILE).parent, Path(w.HUB_DATA_FOLDER))

    def test_other_existing_folders_keep_their_permissions(self):
        # `--secret-file ~/worker-secret` must not make the home folder 0700.
        folder = self.root / 'home'
        folder.mkdir()
        os.chmod(folder, 0o755)
        value = w.load_or_create_secret(folder / 'worker-secret', hub_folder=self.path.parent)
        self.assertEqual(self.mode(folder), 0o755)
        self.assertEqual(self.mode(folder / 'worker-secret'), 0o600)
        self.assertEqual(w.load_or_create_secret(folder / 'worker-secret'), value)  # the real hub folder is not it
        self.assertEqual(self.mode(folder), 0o755)
        # A folder the worker makes itself is private, its parents are left alone.
        nested = folder / 'made' / 'here'
        w.load_or_create_secret(nested / 'worker-secret', hub_folder=self.path.parent)
        self.assertEqual(self.mode(nested), 0o700)
        self.assertEqual(self.mode(folder), 0o755)

    def test_folders_other_users_can_write_are_refused(self):
        folder = self.root / 'shared'
        folder.mkdir()
        for mode in (0o775, 0o757, 0o777):
            os.chmod(folder, mode)
            with self.assertRaises(w.SecretError, msg=oct(mode)):
                w.load_or_create_secret(folder / 'worker-secret', hub_folder=self.path.parent)
            self.assertEqual(self.mode(folder), mode)
            self.assertEqual(list(folder.iterdir()), [])
        os.chmod(folder, 0o1777)  # sticky, as /tmp: others cannot replace our file
        value = w.load_or_create_secret(folder / 'worker-secret', hub_folder=self.path.parent)
        self.assertEqual(self.mode(folder), 0o1777)
        self.assertEqual((folder / 'worker-secret').read_text(), value)

    def test_symlink_empty_and_short_secrets_are_refused(self):
        self.path.parent.mkdir(mode=0o700)
        target = self.root / 'elsewhere'
        target.write_text('x' * 40)
        self.path.symlink_to(target)
        with self.assertRaises(w.SecretError):
            w.load_or_create_secret(self.path)
        self.path.unlink()
        for content in ('', 'short'):
            self.path.write_text(content)
            with self.assertRaises(w.SecretError):
                w.load_or_create_secret(self.path)

    def test_concurrent_creation_agrees_on_one_value(self):
        results, barrier = [], threading.Barrier(8)

        def create():
            barrier.wait()
            results.append(w.load_or_create_secret(self.path))

        threads = [threading.Thread(target=create) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(len(set(results)), 1)
        self.assertEqual(self.path.read_text(), results[0])


class CommandLineTests(unittest.TestCase):
    def test_defaults(self):
        args = w.parse_args([], environ={})
        self.assertEqual(args.port, 18801)
        self.assertEqual(args.idle_unload, 600)
        self.assertEqual(args.secret_file, '~/Library/Application Support/neoless-hub/worker-secret')
        self.assertEqual(args.model, 'mlx-community/Qwen3-ASR-0.6B-4bit')
        self.assertFalse(args.preload)

    def test_environment_and_flags(self):
        env = {'NEOLESS_ASR_PORT': '18850', 'NEOLESS_ASR_IDLE_SECONDS': '0', 'NEOLESS_ASR_SECRET_FILE': '/tmp/s',
               'NEOLESS_ASR_PRELOAD': '1'}
        args = w.parse_args([], environ=env)
        self.assertEqual((args.port, args.idle_unload, args.secret_file, args.preload), (18850, 0, '/tmp/s', True))
        args = w.parse_args(['--port', '18860', '--idle-unload', '30'], environ=env)
        self.assertEqual((args.port, args.idle_unload), (18860, 30))
        # One call per recording, as before 1.3, is a switch; the default checks for mixed languages.
        self.assertFalse(w.parse_args([], environ={}).single_call)
        self.assertTrue(w.parse_args(['--single-call'], environ={}).single_call)
        self.assertTrue(w.parse_args([], environ={'NEOLESS_ASR_SINGLE_CALL': '1'}).single_call)

    def test_invalid_values_exit(self):
        for argv, env in (([], {'NEOLESS_ASR_PORT': 'abc'}), (['--port', '70000'], {}),
                          (['--idle-unload', '-1'], {}), (['--model', 'someone/unpinned-model'], {})):
            with self.assertRaises(SystemExit, msg=(argv, env)), \
                    unittest.mock.patch('sys.stderr', io.StringIO()):
                w.parse_args(argv, environ=env)


class EngineTests(unittest.TestCase):
    def test_offline_and_lazy(self):
        self.assertEqual(os.environ['HF_HUB_OFFLINE'], '1')
        engine = w.QwenEngine()
        self.assertEqual(engine.name, 'Qwen3-ASR-0.6B-4bit')
        self.assertFalse(engine.loaded)
        engine.unload()  # nothing loaded: no-op, no MLX import needed
        self.assertEqual(w.MODEL_REVISIONS[w.DEFAULT_MODEL], '313d850181767edf09f00a9c289becca70e58cd0')

    def test_unpinned_models_are_refused(self):
        with self.assertRaises(ValueError):
            w.resolve_model('someone/unpinned-model')
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(w.resolve_model(directory), str(Path(directory).resolve()))


class QuietLogTestCase(unittest.TestCase):
    """Collects the worker's log lines instead of printing them."""

    def setUp(self):
        self.logs = []
        patcher = unittest.mock.patch.object(w, 'log', self.logs.append)
        patcher.start()
        self.addCleanup(patcher.stop)


class AdaptiveEngineTests(QuietLogTestCase):
    """The small model stands in for ten minutes after the large one was too slow for the machine."""

    class Engine:
        def __init__(self, name, clock, cost):
            self.name, self.clock, self.cost = name, clock, cost
            self.is_loaded, self.calls = False, 0

        @property
        def loaded(self):
            return self.is_loaded

        def load(self):
            self.is_loaded = True

        def unload(self):
            self.is_loaded = False

        def transcribe(self, samples, hints):
            self.calls += 1
            self.clock.now += self.cost()
            return self.name  # plain text is fine: the AdaptiveEngine makes a Transcript of it

    class Clock:
        now = 1000.0

        def __call__(self):
            return self.now

    def make(self, primary_cost):
        clock = self.Clock()
        cost = {'value': primary_cost}
        primary = self.Engine('large', clock, lambda: cost['value'])
        fallback = self.Engine('small', clock, lambda: 0.5)
        return w.AdaptiveEngine(primary, fallback, clock=clock), primary, fallback, clock, cost

    def audio(self, seconds):
        return [0.0] * int(w.SAMPLE_RATE * seconds)

    def heard(self, engine, seconds, choice='auto'):
        """Who answered a request asking for `choice`, as the Recognizer asks."""
        return engine.transcribe(self.audio(seconds), [], engine.select(choice)).model

    def test_keeps_the_large_model_while_it_keeps_up(self):
        engine, primary, fallback, _, _ = self.make(2.5)       # 10 s of audio in 2.5 s
        for _ in range(3):
            heard = engine.transcribe(self.audio(10), [])
            self.assertEqual((heard.text, heard.model, heard.segments), ('large', 'large', 1))
        self.assertEqual((primary.calls, fallback.calls, engine.name), (3, 0, 'large'))

    def test_a_slow_answer_hands_over_to_the_small_model_and_frees_the_large_one(self):
        engine, primary, fallback, clock, _ = self.make(25.0)   # 12 s of audio in 25 s: the Neo is swapping
        self.assertEqual(self.heard(engine, 12), 'large')
        self.assertEqual(engine.name, 'small')
        self.assertEqual(self.logs, ['slow: 25.0s for 12.0s of audio; using small for 600s'])
        self.assertEqual(self.heard(engine, 12), 'small')
        self.assertFalse(primary.loaded)
        self.assertTrue(fallback.loaded and engine.loaded)
        clock.now += 300
        self.assertEqual(self.heard(engine, 12), 'small')

    def test_the_large_model_gets_another_try_after_the_rest(self):
        engine, primary, fallback, clock, cost = self.make(25.0)
        engine.transcribe(self.audio(12), [])
        clock.now += 601
        cost['value'] = 3.0                                     # the machine has room again
        self.assertEqual(engine.name, 'large')
        self.assertEqual(self.heard(engine, 12), 'large')
        self.assertEqual(self.heard(engine, 12), 'large')
        self.assertFalse(fallback.loaded)

    def test_short_recordings_and_model_loading_are_not_judged(self):
        engine, primary, _, clock, _ = self.make(2.9)           # 2 s clip: too short to say anything
        engine.transcribe(self.audio(2), [])
        self.assertEqual(engine.name, 'large')
        original = primary.load
        primary.load = lambda: (setattr(clock, 'now', clock.now + 30), original())[1]   # a slow load
        primary.unload()
        engine.transcribe(self.audio(10), [])
        self.assertEqual(engine.name, 'large')

    def test_unload_frees_both_and_the_command_line_takes_a_fallback(self):
        engine, primary, fallback, _, _ = self.make(1.0)
        engine.load()
        engine.unload()
        self.assertFalse(primary.loaded or fallback.loaded or engine.loaded)
        models = list(w.MODEL_REVISIONS)
        args = w.parse_args(['--model', models[-1], '--fallback-model', models[0]], environ={})
        self.assertEqual(args.fallback_model, models[0])
        same = w.parse_args(['--model', models[0], '--fallback-model', models[0]], environ={})
        self.assertEqual(same.fallback_model, '')
        self.assertEqual(w.parse_args([], environ={'NEOLESS_ASR_FALLBACK_MODEL': models[0],
                                                        'NEOLESS_ASR_MODEL': models[-1]}).fallback_model, models[0])


class ModelChoiceTests(QuietLogTestCase):
    """A request can ask for the large or the small model, whatever "auto" would use."""

    make = AdaptiveEngineTests.make
    audio = AdaptiveEngineTests.audio
    heard = AdaptiveEngineTests.heard
    Engine, Clock = AdaptiveEngineTests.Engine, AdaptiveEngineTests.Clock

    def test_header_values(self):
        for header, choice in ((None, 'auto'), ('', 'auto'), ('auto', 'auto'), ('large', 'large'), ('small', 'small'),
                               (' Large ', 'large'), ('SMALL', 'small'), ('huge', 'auto'), ('1.7B', 'auto')):
            self.assertEqual(w.model_choice(header), choice, header)

    def test_large_answers_even_while_it_rests_and_small_whenever_asked(self):
        engine, primary, fallback, clock, cost = self.make(25.0)
        self.assertEqual(self.heard(engine, 12, 'small'), 'small')    # not resting, still the small one
        self.assertFalse(primary.loaded)
        self.assertEqual(self.heard(engine, 12, 'auto'), 'large')     # too slow: rests from here on
        self.assertEqual(engine.describe(), {'largeModel': 'large', 'smallModel': 'small', 'autoUses': 'small'})
        self.assertEqual(self.heard(engine, 12, 'auto'), 'small')
        cost['value'] = 2.0
        self.assertEqual(self.heard(engine, 12, 'large'), 'large')    # asked for by name: the rest does not matter
        self.assertTrue(primary.loaded and not fallback.loaded)       # one model in memory
        self.assertEqual(self.heard(engine, 12, 'auto'), 'small')     # and "auto" still rests
        self.assertTrue(fallback.loaded and not primary.loaded)
        clock.now += 601
        self.assertEqual(engine.describe()['autoUses'], 'large')
        self.assertEqual(self.heard(engine, 12, 'auto'), 'large')

    def test_a_slow_answer_asked_for_by_name_still_tells_auto_to_rest(self):
        engine, _, _, _, _ = self.make(25.0)
        self.assertEqual(self.heard(engine, 12, 'large'), 'large')
        self.assertEqual(engine.name, 'small')

    def test_with_one_model_every_choice_is_that_model(self):
        clock = self.Clock()
        only = self.Engine('only', clock, lambda: 25.0)
        engine = w.AdaptiveEngine(only, clock=clock)
        for choice in ('auto', 'large', 'small', 'auto'):
            self.assertEqual(self.heard(engine, 12, choice), 'only')   # slow, and nothing to hand over to
        self.assertEqual(engine.describe(), {'largeModel': 'only', 'autoUses': 'large'})
        self.assertEqual((engine.name, engine.loaded), ('only', True))
        engine.unload()
        self.assertFalse(engine.loaded)


class TwoModelCase(WorkerTestCase):
    """The worker with a large and a small model."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.large, self.small = FakeEngine('大模型的结果'), FakeEngine('小模型的结果')
        self.large.name, self.small.name = 'Fake-large', 'Fake-small'
        self.clock = AdaptiveEngineTests.Clock()
        self.adaptive = w.AdaptiveEngine(self.large, self.small, clock=self.clock)
        self.recognizer = w.Recognizer(self.adaptive, idle_seconds=self.idle_seconds)
        await self.client.close()
        self.server = TestServer(w.make_app(self.recognizer, SECRET))
        await self.server.start_server(**w.SERVER_OPTIONS)
        self.client = TestClient(self.server)
        await self.client.start_server()

    async def ask(self, choice=None, body=None):
        status, answer = await self.post(body, headers={} if choice is None else {'X-Model': choice})
        self.assertEqual(status, 200, answer)
        return answer



class TwoModelWorkerTests(TwoModelCase):
    """X-Model per request, and /health says what there is."""

    async def test_each_request_gets_the_model_it_asks_for(self):
        self.assertEqual(await self.health(), {'ok': True, 'model': 'Fake-large', 'loaded': False, 'pending': 0,
                                               'largeModel': 'Fake-large', 'smallModel': 'Fake-small', 'autoUses': 'large'})
        answer = await self.ask()                       # no header: an older hub
        self.assertEqual((answer['raw'], answer['model']), ('大模型的结果', 'Fake-large'))
        answer = await self.ask('small')
        self.assertEqual((answer['raw'], answer['model']), ('小模型的结果', 'Fake-small'))
        self.assertTrue(self.small.loaded and not self.large.loaded)   # one model in memory
        self.assertTrue((await self.health())['loaded'])
        self.assertEqual((await self.health())['model'], 'Fake-large')  # what "auto" uses, not what is loaded
        for choice in ('auto', 'LARGE', 'something-newer'):
            self.assertEqual((await self.ask(choice))['model'], 'Fake-large', choice)
        self.assertTrue(self.large.loaded and not self.small.loaded)
        self.assertEqual((self.large.loads, self.small.loads), (2, 1))
        self.assertTrue([line for line in self.logs if 'model=Fake-small asked=small' in line])

    async def test_while_the_large_model_rests(self):
        self.adaptive._resting_until = self.clock.now + 600
        health = await self.health()
        self.assertEqual((health['model'], health['autoUses']), ('Fake-small', 'small'))
        self.assertEqual((await self.ask())['model'], 'Fake-small')
        self.assertEqual((await self.ask('large'))['model'], 'Fake-large')
        self.assertEqual((await self.ask('small'))['model'], 'Fake-small')
        # Silence never reaches a model; the answer still names the one that was asked for.
        quiet = await self.ask('large', wav_bytes(silence()))
        self.assertEqual((quiet['status'], quiet['model'], quiet['segments']), ('no_speech', 'Fake-large', 0))
        self.assertEqual((await self.ask(None, wav_bytes(silence())))['model'], 'Fake-small')


    async def test_a_model_that_cannot_load_fails_only_the_requests_that_need_it(self):
        self.small.fail_load = True
        self.assertError(await self.post(headers={'X-Model': 'small'}), 503, 'model_unavailable')
        self.assertFalse((await self.health())['ok'])
        self.assertEqual((await self.ask('large'))['model'], 'Fake-large')
        self.assertTrue((await self.health())['ok'])


class TwoModelWarmTests(TwoModelCase):
    """A warm-up loads the model the recognition after it will use."""

    async def warmed(self, choice=None):
        status, body = await self.warm(choice)
        self.assertEqual(status, 200, body)
        await self.wait_until(lambda: self.recognizer.pending == 0)
        return body

    async def test_the_model_asked_for_and_auto_as_it_is_now(self):
        self.assertEqual((await self.warmed('small'))['model'], 'Fake-small')
        self.assertTrue(self.small.loaded and not self.large.loaded)
        self.assertEqual((await self.warmed())['model'], 'Fake-large')     # auto: the large one, as usual
        self.assertTrue(self.large.loaded and not self.small.loaded)      # one model in memory
        # While the large model rests, auto is the small one: that is what is loaded.
        self.adaptive._resting_until = self.clock.now + 600
        self.assertEqual((await self.warmed('auto'))['model'], 'Fake-small')
        self.assertTrue(self.small.loaded and not self.large.loaded)
        self.assertEqual((await self.warmed('large'))['model'], 'Fake-large')  # by name, rest or not
        answer = await self.ask('large')
        self.assertEqual((answer['model'], answer['loadMs']), ('Fake-large', 0))
        self.assertEqual((self.large.loads, self.small.loads), (2, 2))
        self.assertTrue([line for line in self.logs if 'warm asked=small model=Fake-small' in line])


class TwoModelIdleTests(TwoModelCase):
    idle_seconds = 0.2

    async def test_a_model_asked_for_by_name_is_unloaded_after_idle_too(self):
        await self.ask('small')
        self.assertTrue(self.small.loaded)
        await self.wait_until(lambda: not self.small.loaded)
        self.assertFalse((await self.health())['loaded'])
        self.assertGreaterEqual((await self.ask('small'))['loadMs'], 0)
        self.assertEqual(self.small.loads, 2)
        self.assertEqual(len(self.small.threads | self.large.threads), 1)  # still one inference thread


# ---------------------------------------------------------------- mixed languages

RATE = w.SAMPLE_RATE


def sound(seconds, level=0.3):
    """Something as loud as speech: a 250 Hz square wave whose every sample is ±level."""
    count = round(seconds * RATE)
    return (np.where((np.arange(count) // 32) % 2 == 0, level, -level)).astype(np.float32)


def quiet(seconds):
    return np.zeros(round(seconds * RATE), np.float32)


def seconds_of(pieces):
    return [(round(piece.start / RATE, 2), round(piece.end / RATE, 2)) for piece in pieces]


class SegmentationTests(unittest.TestCase):
    def test_cut_in_the_middle_of_each_pause(self):
        samples = np.concatenate([quiet(0.5), sound(2.0), quiet(0.4), sound(1.0), quiet(1.0), sound(3.0), quiet(0.3)])
        pieces = w.split_at_pauses(samples)
        self.assertEqual(seconds_of(pieces), [(0.0, 2.7), (2.7, 4.4), (4.4, 8.2)])
        self.assertEqual([round(piece.onset / RATE, 2) for piece in pieces], [0.5, 2.9, 4.9])
        self.assertEqual([round(piece.finish / RATE, 2) for piece in pieces], [2.5, 3.9, 7.9])
        self.assertEqual([round(piece.speech, 2) for piece in pieces], [2.0, 1.0, 3.0])
        self.assertEqual([round(piece.gap, 2) for piece in pieces], [0.0, 0.4, 1.0])
        # Nothing is left out: the pieces cover the recording, silence at both ends included.
        self.assertEqual((pieces[0].start, pieces[-1].end), (0, len(samples)))
        self.assertEqual(sum(piece.end - piece.start for piece in pieces), len(samples))

    def test_only_pauses_of_a_fifth_of_a_second_count(self):
        for pause, expected in ((0.12, 1), (0.18, 1), (0.22, 2), (0.3, 2)):
            samples = np.concatenate([sound(1.5), quiet(pause), sound(1.5)])
            self.assertEqual(len(w.split_at_pauses(samples)), expected, pause)
        self.assertEqual(len(w.split_at_pauses(np.concatenate([sound(1.5), quiet(0.3), sound(1.5)]), min_pause=0.5)), 1)

    def test_no_speech_no_pieces(self):
        self.assertEqual(w.split_at_pauses(np.zeros(0, np.float32)), [])
        self.assertEqual(w.split_at_pauses(quiet(3.0)), [])
        self.assertEqual(w.split_at_pauses(quiet(0.01)), [])
        whole = w.split_at_pauses(sound(2.0))
        self.assertEqual(seconds_of(whole), [(0.0, 2.0)])

    def test_the_threshold_follows_the_recording(self):
        rng = np.random.default_rng(5)
        parts = [quiet(0.3), sound(2.0, 0.3), quiet(0.5), sound(2.0, 0.2), quiet(0.5), sound(1.5, 0.3), quiet(0.3)]
        clean = np.concatenate(parts)
        expected = seconds_of(w.split_at_pauses(clean))
        self.assertEqual(len(expected), 3)
        # A quiet recording and one with room noise are cut in the same places.
        self.assertEqual(seconds_of(w.split_at_pauses(clean * 0.02)), expected)
        noisy = clean + rng.normal(0, 0.004, len(clean)).astype(np.float32)
        self.assertEqual(seconds_of(w.split_at_pauses(noisy)), expected)
        # Noise as loud as a third of the speech: no pause can be told, so nothing is cut.
        drowned = clean + rng.normal(0, 0.1, len(clean)).astype(np.float32)
        self.assertEqual(seconds_of(w.split_at_pauses(drowned)), [(0.0, round(len(clean) / RATE, 2))])
        # A short loud click does not hide the pauses of quieter speech (it is a piece of its own, 20 ms long).
        clicked = clean * 0.2
        clicked[100:260] = 0.9
        self.assertEqual([round(piece.speech, 2) for piece in w.split_at_pauses(clicked)], [0.02, 2.0, 2.0, 1.5])

    def test_frame_levels(self):
        levels = w.frame_levels(np.concatenate([sound(0.1, 0.5), quiet(0.1), sound(0.005)]))
        self.assertEqual(len(levels), 10)  # 20 ms frames; the last 5 ms are not a frame
        np.testing.assert_allclose(levels[:5], 0.5, rtol=1e-5)
        np.testing.assert_array_equal(levels[5:], 0)
        self.assertEqual(len(w.frame_levels(np.zeros(100, np.float32))), 0)
        self.assertEqual(w.speech_frames(levels).tolist(), [True] * 5 + [False] * 5)
        self.assertEqual(len(w.speech_frames(np.zeros(0, np.float32))), 0)

    def test_probe_window_is_the_start_of_the_piece_with_quiet_edges(self):
        samples = np.concatenate([quiet(1.0), sound(5.0), quiet(0.4), sound(0.6), quiet(0.2)])
        first, second = w.split_at_pauses(samples)
        lead, tail = round(w.EDGE_LEAD_SECONDS * RATE), round(w.EDGE_TAIL_SECONDS * RATE)
        window = w.probe_window(samples, first)
        # 0.3 s of the recording before the speech, 2 s of speech, and silence put around both.
        self.assertEqual(len(window), lead + round(0.3 * RATE) + 2 * RATE + tail)
        self.assertEqual(window.dtype, np.float32)
        np.testing.assert_array_equal(window[:lead + round(0.3 * RATE)], 0)
        np.testing.assert_array_equal(window[-tail:], 0)
        self.assertEqual(float(np.abs(window[lead + round(0.3 * RATE):-tail]).min()), np.float32(0.3))
        # A short piece: all of it, never anything of its neighbours.
        window = w.probe_window(samples, second)
        self.assertEqual(len(window), lead + (second.end - second.start) + tail)
        self.assertEqual(int(np.count_nonzero(window)), round(0.6 * RATE))

    def test_tail_window_is_the_last_second_of_the_piece_with_quiet_edges(self):
        samples = np.concatenate([quiet(1.0), sound(5.0), quiet(0.4), sound(0.6), quiet(0.2)])
        first, second = w.split_at_pauses(samples)
        lead, tail = round(w.EDGE_LEAD_SECONDS * RATE), round(w.EDGE_TAIL_SECONDS * RATE)
        window = w.tail_window(samples, first)
        # The last second of speech, the 0.2 s of the pause after it that belong to the piece, silence around both.
        self.assertEqual(len(window), lead + RATE + round(0.2 * RATE) + tail)
        self.assertEqual(int(np.count_nonzero(window)), RATE)
        np.testing.assert_array_equal(window[:lead], 0)
        self.assertEqual(float(np.abs(window[lead:lead + RATE]).min()), np.float32(0.3))
        # A piece shorter than that: all of it, never anything of its neighbours.
        window = w.tail_window(samples, second)
        self.assertEqual(len(window), lead + (second.end - second.start) + tail)
        self.assertEqual(int(np.count_nonzero(window)), round(0.6 * RATE))

    def test_quiet_edges(self):
        padded = w.with_quiet_edges(sound(1.0))
        self.assertEqual(len(padded), round((1.0 + w.EDGE_LEAD_SECONDS + w.EDGE_TAIL_SECONDS) * RATE))
        self.assertEqual((padded[0], padded[-1], padded.dtype), (0, 0, np.float32))


def room(seconds, level=0.0008, seed=11):
    """The faint noise of a room, as a microphone records a pause (a `say` clip has exact zeros there)."""
    return np.random.default_rng(seed).normal(0, level, round(seconds * RATE)).astype(np.float32)


def in_a_room(samples, level=0.0008):
    return samples + room(len(samples) / RATE, level)


class ChunkTests(unittest.TestCase):
    """Audio longer than 30 s is cut by the worker, so that no chunk without speech reaches the model."""

    def seconds(self, bounds):
        return [(round(start / RATE, 2), round(end / RATE, 2)) for start, end in bounds]

    def sentences(self, count, seconds=3.0, pause=0.3):
        return in_a_room(np.concatenate([part for _ in range(count) for part in (sound(seconds), quiet(pause))]))

    def test_up_to_thirty_seconds_is_one_chunk(self):
        for samples in (sound(12.0), in_a_room(sound(30.0)), np.zeros(0, np.float32)):
            self.assertEqual(w.chunk_bounds(samples), [(0, len(samples))])

    def test_a_stretch_with_its_quiet_edges_is_one_chunk(self):
        # 29.7 s in one language: with the silence put around it, 30.2 s. The quietest tenth of a second near
        # its end is that silence, and a cut there would leave 0.15 s of zeros as a chunk of their own.
        stretch = self.sentences(9)
        self.assertEqual(round(len(stretch) / RATE, 1), 29.7)
        padded = w.with_quiet_edges(stretch)
        self.assertEqual(w.chunk_bounds(padded), [(0, len(padded))])
        # A piece without a pause, too long to cut any shorter: one chunk as well (up to 35 s).
        long_piece = w.with_quiet_edges(in_a_room(sound(33.0)))
        self.assertEqual(w.chunk_bounds(long_piece), [(0, len(long_piece))])
        # And what the worker itself cuts at a pause never gets that far: with its edges it is 30 s at most.
        longest = w.with_quiet_edges(sound(w.MAX_STRETCH_SECONDS))
        self.assertEqual(len(longest), round(w.ASR_CHUNK_SECONDS * RATE))
        self.assertEqual(w.chunk_bounds(longest), [(0, len(longest))])

    def test_longer_audio_is_cut_at_its_quietest_place_near_every_thirty_seconds(self):
        samples = in_a_room(np.concatenate([sound(27.0), quiet(0.6), sound(27.0), quiet(0.6), sound(6.8)]))
        bounds = w.chunk_bounds(samples)
        self.assertEqual(len(bounds), 3)
        (_, first), (second, third), (fourth, end) = bounds
        self.assertTrue(27.0 * RATE <= first <= 27.6 * RATE and 54.6 * RATE <= third <= 55.2 * RATE, self.seconds(bounds))
        self.assertEqual((bounds[0][0], second, fourth, end), (0, first, third, len(samples)))  # nothing is left out

    def test_no_chunk_begins_where_nothing_more_is_said(self):
        # Speech, then the microphone stays on: what follows is no chunk of its own, and past 35 s it is left out.
        samples = in_a_room(np.concatenate([sound(28.0), quiet(12.0)]))
        self.assertEqual(self.seconds(w.chunk_bounds(samples)), [(0.0, 35.0)])
        # Exactly the case above with a real recording's own quiet end instead of added silence.
        samples = in_a_room(np.concatenate([sound(31.0), quiet(0.4)]))
        self.assertEqual(w.chunk_bounds(samples), [(0, len(samples))])

    def test_a_chunk_without_speech_is_left_out(self):
        samples = in_a_room(np.concatenate([sound(28.0), quiet(42.0), sound(10.0)]))   # half a minute of thinking
        bounds = w.chunk_bounds(samples)
        self.assertEqual(len(bounds), 2, self.seconds(bounds))
        (start, first), (second, end) = bounds
        self.assertTrue(start == 0 and 28 * RATE <= first <= 35 * RATE and end == len(samples))
        self.assertTrue(first + 25 * RATE <= second <= 70 * RATE, self.seconds(bounds))

    def test_with_noise_as_loud_as_speech_it_cuts_as_mlx_audio_does(self):
        samples = in_a_room(sound(40.0), level=0.2)   # everything counts as speech
        bounds = w.chunk_bounds(samples)
        self.assertEqual(len(bounds), 2)
        self.assertEqual((bounds[0][0], bounds[0][1], bounds[1][1]), (0, bounds[1][0], len(samples)))
        self.assertTrue(25 * RATE <= bounds[0][1] <= 35 * RATE)

    def test_mlx_audio_takes_each_chunk_as_it_is(self):
        """With mlx_audio's own cutting (no model is loaded): what it does to a stretch with quiet edges, and
        that the chunk length `QwenEngine.hear` gives it keeps it from cutting."""
        try:
            from mlx_audio.stt.models.qwen3_asr.qwen3_asr import split_audio_into_chunks
        except Exception as exc:  # another mlx_audio, or none: nothing to compare with
            self.skipTest(f'mlx_audio is not here: {type(exc).__name__}')
        padded = w.with_quiet_edges(self.sentences(9))
        theirs = split_audio_into_chunks(padded, RATE, chunk_duration=w.ASR_CHUNK_SECONDS)
        self.assertEqual(len(theirs), 2)
        self.assertFalse(np.any(theirs[-1][0]))            # one second of zeros, for which the models write something
        for samples in (padded, in_a_room(np.concatenate([sound(27.0), quiet(0.6), sound(27.0), quiet(0.6), sound(6.8)]))):
            for start, end in w.chunk_bounds(samples):
                chunk = samples[start:end]
                kept = split_audio_into_chunks(chunk, RATE, chunk_duration=max(w.ASR_CHUNK_SECONDS, len(chunk) / RATE))
                self.assertEqual(len(kept), 1)
                self.assertEqual(len(kept[0][0]), len(chunk))
                self.assertTrue(np.any(chunk))


class ProbeLanguageTests(unittest.TestCase):
    def test_the_tag_and_the_first_words(self):
        cases = {
            'language Chinese<asr_text>明天下午三点': 'Chinese',
            'language Chinese<asr_text>': 'Chinese',
            'language Chinese': 'Chinese',                              # the tag was not finished in time
            'language Chinese<asr_text>OpenAI': 'Chinese',              # the model said so; a term comes first
            'language English<asr_text>Keep everything the same': 'English',
            ' language English<asr_text> Sounds good to me.': 'English',
            'language English<asr_text>Kubernetes orchestration': 'English',  # cut off: more was coming
            'language English<asr_text>Hidden Markov model for': 'English',
            # Up to three words that are the whole answer are a word or a term, not an English sentence.
            'language English<asr_text>OK.': None,
            'language English<asr_text>Thank you.': None,
            'language English<asr_text>Claude Code。': None,
            'language English<asr_text>Hidden Markov model.': None,
            " language English<asr_text> Let's do it.": None,
            'language English<asr_text>Um': None,
            # The 1.7B model tags Chinese with English words in it as English, and writes Chinese:
            'language English<asr_text>我觉得这个 feature 应': 'Chinese',
            'language English<asr_text>OpenAI 的模型': 'Chinese',
            # English needs words; a tag alone (or cut off) decides nothing.
            'language English<asr_text>': None,
            'language English': None,
            'language English<asr_text>123。': None,
            # Noise, another language, or an answer that is no answer.
            'language None<asr_text>': None,
            'language Japanese<asr_text>明日の午後': None,
            'language Cantonese<asr_text>聽日下晝': None,
            'ology.For example, the': None,
            'Keep everything the same': None,
            '': None,
        }
        for head, language in cases.items():
            self.assertEqual(w.probe_language(head), language, head)

    def test_how_a_piece_that_starts_in_english_ends(self):
        cases = {
            # "As far as I know 他明天不来": the end is Chinese, whatever the model made of the start.
            'language Chinese<asr_text>明天不来。': 'Chinese',
            'language Chinese<asr_text>Short，我们赢了。': 'Chinese',
            'language Chinese': 'Chinese',
            'language English<asr_text>明天不来': 'Chinese',
            # An English sentence ends in English; a word is enough here.
            'language English<asr_text>Before lunch.': 'English',
            ' language English<asr_text> Documentation.': 'English',
            'language English<asr_text>Until next': 'English',
            # Nothing to go by: the piece cannot be named.
            'language English<asr_text>': None,
            'language English': None,
            'language None<asr_text>': None,
            'language Vietnamese<asr_text>A M A.': None,
            'language Japanese<asr_text>明日の午後': None,
            'ology': None,
            'ology.For Chinese input, use Chinese input method.': None,
            '': None,
        }
        for tail, language in cases.items():
            self.assertEqual(w.tail_language(tail), language, tail)


def piece(start, end, speech=None, gap=0.3):
    """A piece from `start` to `end` seconds, all of it speech unless said otherwise."""
    speech = end - start if speech is None else speech
    return w.Piece(round(start * RATE), round(end * RATE), round(start * RATE), speech, gap, round(end * RATE))


class StretchTests(unittest.TestCase):
    def stretches(self, pieces, languages, **options):
        return [(round(stretch.start / RATE, 2), round(stretch.end / RATE, 2), stretch.language)
                for stretch in w.language_stretches(pieces, languages, **options)]

    def test_each_language_its_own_stretch_and_neighbours_together(self):
        pieces = [piece(0, 3), piece(3, 6), piece(6, 9), piece(9, 12)]
        self.assertEqual(self.stretches(pieces, ['English', 'Chinese', 'English', 'Chinese']),
                         [(0, 3, 'English'), (3, 6, 'Chinese'), (6, 9, 'English'), (9, 12, 'Chinese')])
        self.assertEqual(self.stretches(pieces, ['Chinese', 'Chinese', 'English', 'English']),
                         [(0, 6, 'Chinese'), (6, 12, 'English')])
        self.assertEqual(self.stretches(pieces, ['Chinese'] * 4), [(0, 12, 'Chinese')])
        self.assertEqual(self.stretches([piece(0, 3)], ['English']), [(0, 3, 'English')])
        self.assertEqual(self.stretches([piece(0, 3)], [None]), [(0, 3, None)])
        self.assertEqual(self.stretches([], []), [])

    def test_a_short_piece_joins_the_neighbour_in_its_own_language(self):
        # "…也一样，" pause 0.30 "谢谢。" pause 0.25 "Keep everything…": the shorter pause is on the wrong side.
        pieces = [piece(0, 3), piece(3, 3.7, gap=0.30), piece(3.7, 7, gap=0.25)]
        self.assertEqual(self.stretches(pieces, ['Chinese', 'Chinese', 'English']), [(0, 3.7, 'Chinese'), (3.7, 7, 'English')])
        pieces = [piece(0, 3), piece(3, 3.7, gap=0.25), piece(3.7, 7, gap=0.30)]
        self.assertEqual(self.stretches(pieces, ['English', 'Chinese', 'Chinese']), [(0, 3, 'English'), (3, 7, 'Chinese')])

    def test_a_short_piece_never_stands_alone(self):
        # "OK" between two Chinese sentences, "谢谢" after an English one, a filler before one.
        pieces = [piece(0, 3), piece(3, 3.6), piece(3.6, 7)]
        self.assertEqual(self.stretches(pieces, ['Chinese', 'English', 'Chinese']), [(0, 7, 'Chinese')])
        self.assertEqual(self.stretches([piece(0, 3), piece(3, 3.6)], ['English', 'Chinese']), [(0, 3.6, 'English')])
        self.assertEqual(self.stretches([piece(0, 0.5), piece(0.5, 4)], ['Chinese', 'English']), [(0, 4, 'English')])
        # Between two languages, in neither: across the shorter pause.
        pieces = [piece(0, 3), piece(3, 3.6, gap=0.5), piece(3.6, 7, gap=0.2)]
        self.assertEqual(self.stretches(pieces, ['Chinese', None, 'English']), [(0, 3, 'Chinese'), (3, 7, 'English')])
        pieces = [piece(0, 3), piece(3, 3.6, gap=0.2), piece(3.6, 7, gap=0.5)]
        self.assertEqual(self.stretches(pieces, ['Chinese', None, 'English']), [(0, 3.6, 'Chinese'), (3.6, 7, 'English')])
        # What counts is the speech in it, not its length with the silence around.
        pieces = [piece(0, 3), w.Piece(3 * RATE, 6 * RATE, 4 * RATE, 0.6, 1.0, round(4.6 * RATE)), piece(6, 9, gap=1.5)]
        self.assertEqual(self.stretches(pieces, ['Chinese', 'English', 'Chinese']), [(0, 9, 'Chinese')])

    def test_a_piece_without_a_language_goes_with_a_neighbour_however_long(self):
        pieces = [piece(0, 3), piece(3, 8, gap=0.2), piece(8, 11, gap=0.6)]
        self.assertEqual(self.stretches(pieces, ['Chinese', None, 'English']), [(0, 8, 'Chinese'), (8, 11, 'English')])
        self.assertEqual(self.stretches(pieces, [None, None, 'English']), [(0, 11, 'English')])

    def test_short_pieces_add_up(self):
        # Three short English pieces in a row are a sentence said haltingly, next to a Chinese one.
        pieces = [piece(0, 0.7), piece(0.7, 1.4), piece(1.4, 2.1), piece(2.1, 6)]
        self.assertEqual(self.stretches(pieces, ['English', 'English', 'English', 'Chinese']),
                         [(0, 2.1, 'English'), (2.1, 6, 'Chinese')])
        # All short, one language each: the longer side gives the language.
        self.assertEqual(self.stretches([piece(0, 0.5), piece(0.5, 1.2)], ['English', 'Chinese']), [(0, 1.2, 'Chinese')])

    def test_nothing_chinese_or_english_stays_whole(self):
        pieces = [piece(0, 20), piece(20, 40), piece(40, 61)]
        self.assertEqual(self.stretches(pieces, [None, None, None]), [(0, 61, None)])  # not cut at 30 s either

    def test_a_long_stretch_is_cut_at_a_pause(self):
        pieces = [piece(index * 8, index * 8 + 8) for index in range(9)]  # 72 s in one language
        self.assertEqual(self.stretches(pieces, ['Chinese'] * 9),
                         [(0, 24, 'Chinese'), (24, 48, 'Chinese'), (48, 72, 'Chinese')])
        self.assertEqual(self.stretches(pieces, ['Chinese'] * 9, max_seconds=100), [(0, 72, 'Chinese')])
        # 29.5 s: with the half second of silence put around it a stretch is exactly the 30 s of one chunk.
        pieces = [piece(0, 14.75), piece(14.75, 29.5), piece(29.5, 29.8), piece(29.8, 40)]
        self.assertEqual(self.stretches(pieces, ['Chinese'] * 4), [(0, 29.5, 'Chinese'), (29.5, 40, 'Chinese')])
        # A piece that is longer than the limit by itself is left to mlx_audio's own chunking.
        pieces = [piece(0, 10), piece(10, 55), piece(55, 60)]
        self.assertEqual(self.stretches(pieces, ['English'] * 3), [(0, 10, 'English'), (10, 55, 'English'), (55, 60, 'English')])
        # Other languages around it change nothing about where a stretch ends.
        pieces = [piece(0, 20), piece(20, 40), piece(40, 45), piece(45, 65)]
        self.assertEqual(self.stretches(pieces, ['Chinese', 'Chinese', 'English', 'Chinese']),
                         [(0, 20, 'Chinese'), (20, 40, 'Chinese'), (40, 45, 'English'), (45, 65, 'Chinese')])


class JoinTests(unittest.TestCase):
    def test_spacing_between_chinese_and_english(self):
        cases = [
            (['我们把例会改到星期四下午吧。', 'Please send me the report before lunch.', '这个周末的天气应该会很不错。'],
             '我们把例会改到星期四下午吧。Please send me the report before lunch. 这个周末的天气应该会很不错。'),
            (['Keep everything the same.', 'And send me the peak force.'], 'Keep everything the same. And send me the peak force.'),
            (['昨天下午我在整理这个项目，', '还修了两个小问题。'], '昨天下午我在整理这个项目，还修了两个小问题。'),
            (['把数据都整理出来', '然后发给我'], '把数据都整理出来然后发给我'),            # no punctuation is invented
            (['send me the report', '然后我们去吃饭'], 'send me the report 然后我们去吃饭'),
            (['新版本可以测试了', 'Please try it.'], '新版本可以测试了 Please try it.'),
            (['一共 3', '个'], '一共 3 个'),
            (['Hello', '，world'], 'Hello，world'),
            (['  明天见。 ', '', '   ', ' See you. '], '明天见。See you.'),
            (['', ' '], ''),
            ([], ''),
            (['只有一段'], '只有一段'),
        ]
        for texts, joined in cases:
            self.assertEqual(w.join_texts(texts), joined, texts)


class FakeModel:
    """Stands in for the model behind `hear` and `probe`, with Qwen3-ASR's habit: one language per
    call, and what is spoken in another language is left out. Each sentence of a recording made by
    `recording()` has its own loudness, by which the fake knows what it is given."""

    def __init__(self, sentences):
        self.sentences = sentences  # [(language, text)], in the order they are spoken
        self.heard = []             # (indices of the sentences in the audio, language asked, hints, samples)
        self.probed = []            # the windows of each probe call
        self.heads = {}             # sentence index -> what `probe` answers instead of the truth
        self.tails = {}             # the same, when asked how a piece ends (default: as `heads`)

    # The end of a piece is asked with a window of at most this (`tail_window`); the start of a piece of
    # more than a second and a half with a longer one, which is how this fake tells them apart.
    TAIL_SAMPLES = round((w.EDGE_LEAD_SECONDS + w.TAIL_SECONDS + 2 * w.EDGE_TAIL_SECONDS) * w.SAMPLE_RATE)

    @staticmethod
    def level(index):
        return 0.2 + 0.02 * index

    def present(self, samples):
        levels = np.round((np.abs(samples[samples != 0]) - 0.2) / 0.02).astype(int)
        _, first = np.unique(levels, return_index=True)
        return [int(levels[position]) for position in sorted(first)]

    def probe(self, windows):
        self.probed.append(windows)
        heads = []
        for window in windows:
            index = self.present(window)[0]
            language, text = self.sentences[index]
            head = self.heads.get(index, f'language {language}<asr_text>{text[:24]}')  # the first words
            heads.append(self.tails.get(index, head) if len(window) <= self.TAIL_SAMPLES else head)
        return heads

    def hear(self, samples, hints, language):
        present = self.present(samples)
        self.heard.append((present, language, list(hints), samples))
        if not present:
            return ''
        language = language or self.sentences[present[0]][0]
        return ''.join(text for spoken, text in (self.sentences[index] for index in present) if spoken == language)


def recording(*parts):
    """Sentences (seconds of speech, numbered in order) and pauses (negative seconds), as samples."""
    pieces, index = [], 0
    for part in parts:
        if part < 0:
            pieces.append(quiet(-part))
        else:
            pieces.append(sound(part, FakeModel.level(index)))
            index += 1
    return np.concatenate(pieces)


class MixedTests(unittest.TestCase):
    ZH1, EN1, ZH2, EN2 = '我们把例会改到星期四下午吧。', 'Please send me the report.', '这个周末天气不错。', 'The battery lasts three hours.'

    def run_mixed(self, model, samples, hints=()):
        return w.transcribe_mixed(samples, list(hints), model.hear, model.probe)

    def test_each_sentence_in_its_own_language(self):
        model = FakeModel([('Chinese', self.ZH1), ('English', self.EN1), ('Chinese', self.ZH2), ('English', self.EN2)])
        samples = recording(-0.2, 3.0, -0.4, 2.5, -0.4, 2.5, -0.4, 3.0, -0.2)
        # One call, as before: the model takes the first sentence's language and the rest of it only.
        self.assertEqual(model.hear(samples, [], None), self.ZH1 + self.ZH2)
        model.heard.clear()
        heard = self.run_mixed(model, samples, ['OpenAI', '例会'])
        self.assertEqual(heard.text, f'{self.ZH1}{self.EN1} {self.ZH2}{self.EN2}')
        self.assertEqual(heard.segments, 4)
        self.assertEqual([(present, language) for present, language, _, _ in model.heard],
                         [([0], 'Chinese'), ([1], 'English'), ([2], 'Chinese'), ([3], 'English')])
        self.assertTrue(all(hints == ['OpenAI', '例会'] for _, _, hints, _ in model.heard))  # every call gets them
        # Asked: how the four pieces begin, then how the two that begin in English end.
        self.assertEqual([len(windows) for windows in model.probed], [4, 2])
        self.assertEqual(heard.probes, 6)
        # Each stretch is given with quiet edges, and together they are the whole recording.
        lead, tail = round(w.EDGE_LEAD_SECONDS * RATE), round(w.EDGE_TAIL_SECONDS * RATE)
        for _, _, _, audio in model.heard:
            np.testing.assert_array_equal(audio[:lead], 0)
            np.testing.assert_array_equal(audio[-tail:], 0)
        self.assertEqual(sum(len(audio) - lead - tail for _, _, _, audio in model.heard), len(samples))

    def test_english_first(self):
        model = FakeModel([('English', self.EN1), ('Chinese', self.ZH1), ('English', self.EN2), ('Chinese', self.ZH2)])
        heard = self.run_mixed(model, recording(2.5, -0.5, 3.0, -0.3, 3.0, -0.6, 2.5))
        self.assertEqual(heard.text, f'{self.EN1} {self.ZH1}{self.EN2} {self.ZH2}')

    def test_one_language_is_one_call_for_the_whole_recording(self):
        model = FakeModel([('Chinese', '昨天下午我在整理项目，'), ('Chinese', '删掉了旧的脚本，'), ('Chinese', '还修了两个小问题。')])
        samples = recording(-0.3, 3.0, -0.3, 2.0, -0.35, 3.0, -0.3)
        heard = self.run_mixed(model, samples, ['脚本'])
        self.assertEqual((heard.text, heard.segments), ('昨天下午我在整理项目，删掉了旧的脚本，还修了两个小问题。', 1))
        self.assertEqual(([len(windows) for windows in model.probed], heard.probes), ([3], 3))   # no English: asked once
        self.assertEqual(len(model.heard), 1)
        present, language, hints, audio = model.heard[0]
        self.assertEqual((present, language, hints), ([0, 1, 2], 'Chinese', ['脚本']))
        self.assertIs(audio, samples)  # the recording as it came, nothing put around it

    def test_no_pause_or_little_speech_is_one_call_and_nothing_is_asked(self):
        for samples in (recording(-0.2, 6.0, -0.2),                 # one sentence, no pause
                        recording(5.0, -0.15, 3.0),                 # a pause too short to count
                        recording(0.8, -0.5, 0.9),                  # less than two seconds of speech
                        recording(4.0, -0.5, 0.2),                  # the second piece is only a click
                        quiet(2.0)):                                # nothing at all
            model = FakeModel([('English', 'One.'), ('Chinese', '二。')])
            heard = self.run_mixed(model, samples)
            self.assertEqual(model.probed, [])
            self.assertEqual(len(model.heard), 1)
            self.assertIsNone(model.heard[0][1])                    # the model picks the language, as before
            self.assertIs(model.heard[0][3], samples)
            self.assertEqual((heard.segments, heard.probes), (1, 0))

    def test_a_click_is_not_asked_for_its_language(self):
        model = FakeModel([('Chinese', '第一句。'), ('Chinese', '咔'), ('English', 'The second sentence is in English.')])
        heard = self.run_mixed(model, recording(3.0, -0.5, 0.2, -0.3, 3.0))
        self.assertEqual(len(model.probed[0]), 2)
        self.assertEqual([(present, language) for present, language, _, _ in model.heard],
                         [([0], 'Chinese'), ([1, 2], 'English')])   # across the shorter pause
        self.assertEqual(heard.text, '第一句。The second sentence is in English.')

    def test_a_short_thanks_stays_with_its_sentence(self):
        model = FakeModel([('Chinese', '最后那一组也一样，'), ('Chinese', '谢谢。'), ('English', 'Keep everything the same.')])
        heard = self.run_mixed(model, recording(2.0, -0.30, 0.6, -0.24, 2.5))
        self.assertEqual(heard.text, '最后那一组也一样，谢谢。Keep everything the same.')
        self.assertEqual([present for present, _, _, _ in model.heard], [[0, 1], [2]])
        # The two long pieces were asked first; two languages, so the short one was asked as well; then how
        # the English one ends.
        self.assertEqual([len(windows) for windows in model.probed], [2, 1, 1])

    def test_short_pieces_are_not_asked_while_the_long_ones_agree(self):
        model = FakeModel([('Chinese', '我觉得，'), ('Chinese', '这个方案还可以，'), ('English', 'OK.'), ('Chinese', '明天再看一下细节。')])
        samples = recording(0.7, -0.3, 2.5, -0.4, 0.5, -0.4, 3.0)
        heard = self.run_mixed(model, samples)
        self.assertEqual([len(windows) for windows in model.probed], [2])          # the two long ones only
        self.assertEqual((len(model.heard), model.heard[0][1], heard.segments), (1, 'Chinese', 1))
        self.assertIs(model.heard[0][3], samples)

    def test_halting_speech_is_asked_piece_by_piece(self):
        # No piece is a second long, but together they are two sentences in two languages.
        model = FakeModel([('English', 'Let me '), ('English', 'think about '), ('English', 'it. '),
                           ('Chinese', '我先'), ('Chinese', '看一下'), ('Chinese', '数据。')])
        heard = self.run_mixed(model, recording(0.7, -0.3, 0.8, -0.3, 0.6, -0.6, 0.7, -0.3, 0.8, -0.3, 0.7))
        self.assertEqual([len(windows) for windows in model.probed], [6])
        self.assertEqual([(present, language) for present, language, _, _ in model.heard],
                         [([0, 1, 2], 'English'), ([3, 4, 5], 'Chinese')])
        self.assertEqual(heard.text, 'Let me think about it. 我先看一下数据。')

    def test_a_term_said_between_pauses_is_not_an_english_sentence(self):
        for term in ('Claude Code.', 'Hidden Markov model.'):
            model = FakeModel([('Chinese', '我今天用'), ('Chinese', ' Claude Code '), ('Chinese', '写了一个脚本。')])
            model.heads[1] = f'language English<asr_text>{term}'
            samples = recording(1.2, -0.3, 1.3, -0.3, 2.0)
            heard = self.run_mixed(model, samples)
            self.assertEqual((heard.text, heard.segments, model.heard[0][1]), ('我今天用 Claude Code 写了一个脚本。', 1, 'Chinese'))
            self.assertIs(model.heard[0][3], samples)   # one sentence, not three with a full stop each
            self.assertEqual(len(model.probed), 1)      # and nothing more to ask about it

    def test_english_that_runs_into_chinese_is_chinese(self):
        # "As far as I know 他明天不来", no pause in it: the piece starts as English and ends as Chinese.
        model = FakeModel([('Chinese', '我们把例会改到星期四下午吧。'), ('English', 'As far as I know '), ('Chinese', '他明天不来。'),
                           ('English', 'Please send me the report.')])
        samples = recording(3.0, -0.4, 2.0, 1.5, -0.5, 2.5)
        self.assertEqual(len(w.split_at_pauses(samples)), 3)
        heard = self.run_mixed(model, samples)
        self.assertEqual([len(windows) for windows in model.probed], [3, 2])
        # Its Chinese is not handed to the model as English (which translates it), and the English sentence still is.
        self.assertEqual([(present, language) for present, language, _, _ in model.heard],
                         [([0, 1, 2], 'Chinese'), ([3], 'English')])
        self.assertEqual((heard.segments, heard.probes), (2, 5))
        # A recording of nothing but such pieces is Chinese throughout: one call, with that language.
        model = FakeModel([('English', 'To be honest with you '), ('Chinese', '我不太喜欢。'),
                           ('English', 'Long story short '), ('Chinese', '我们赢了。')])
        samples = recording(2.0, 1.2, -0.45, 1.6, 1.2)
        heard = self.run_mixed(model, samples)
        self.assertEqual([(present, language) for present, language, _, _ in model.heard], [([0, 1, 2, 3], 'Chinese')])
        self.assertIs(model.heard[0][3], samples)

    def test_an_end_the_model_cannot_name_leaves_the_piece_to_its_neighbours(self):
        sentences = [('Chinese', '扎克伯格以前说过，'), ('English', 'Move fast and break things 这句话有问题。'), ('Chinese', '我们稳一点。')]
        for tail in ('ology', 'language None<asr_text>', 'language English<asr_text>'):
            model = FakeModel(sentences)
            model.tails[1] = tail
            samples = recording(2.0, -0.35, 4.0, -0.35, 2.0)
            self.run_mixed(model, samples)
            self.assertEqual([(present, language) for present, language, _, _ in model.heard], [([0, 1, 2], 'Chinese')], tail)
        # Next to English it stays English.
        model = FakeModel([('English', 'Please send me the report.'), ('English', 'Keep everything the same.')])
        model.tails[1] = 'ology'
        self.run_mixed(model, recording(2.5, -0.4, 2.5))
        self.assertEqual([(present, language) for present, language, _, _ in model.heard], [([0, 1], 'English')])

    def test_a_long_recording_is_asked_after_its_longest_pauses_only(self):
        sentences = [('Chinese', '第一句。'), ('Chinese', '第二句。'), ('Chinese', '第三句。'),
                     ('English', 'The fourth one is in English. '), ('English', 'And so is the fifth one.'),
                     ('Chinese', '第六句。'), ('Chinese', '第七句。'), ('Chinese', '第八句。')]
        samples = recording(2.0, -0.3, 2.0, -0.3, 2.0, -0.8, 2.0, -0.3, 2.0, -0.8, 2.0, -0.3, 2.0, -0.5, 2.0)
        with unittest.mock.patch.object(w, 'MAX_PROBES', 4):
            model = FakeModel(sentences)
            heard = self.run_mixed(model, samples)
        # The first piece and the three after the longest pauses; then how the English one of them ends.
        self.assertEqual([[model.present(window)[0] for window in windows] for windows in model.probed], [[0, 3, 5, 7], [3]])
        self.assertEqual(heard.probes, 5)
        # The pieces that were not asked go with the one before them: across the shorter pause.
        self.assertEqual([(present, language) for present, language, _, _ in model.heard],
                         [([0, 1, 2], 'Chinese'), ([3, 4], 'English'), ([5, 6, 7], 'Chinese')])
        self.assertEqual(heard.text, '第一句。第二句。第三句。The fourth one is in English. And so is the fifth one. 第六句。第七句。第八句。')
        # Up to the limit every long piece is asked, as always.
        model = FakeModel(sentences)
        self.run_mixed(model, samples)
        self.assertEqual([len(windows) for windows in model.probed], [8, 2])

    def test_chinese_with_english_words_tagged_english_is_still_chinese(self):
        model = FakeModel([('Chinese', '我今天用 Codex 写了一个脚本，'), ('Chinese', '然后让 OpenAI 的模型分析了一下。')])
        model.heads[1] = 'language English<asr_text>然后让 OpenAI 的'
        heard = self.run_mixed(model, recording(3.0, -0.3, 4.0))
        self.assertEqual((len(model.heard), model.heard[0][1], heard.segments), (1, 'Chinese', 1))

    def test_another_language_is_left_to_the_model(self):
        model = FakeModel([('Japanese', '明日の午後、'), ('Japanese', '会議があります。')])
        samples = recording(3.0, -0.4, 3.0)
        heard = self.run_mixed(model, samples)
        self.assertEqual(heard.text, '明日の午後、会議があります。')
        self.assertEqual((len(model.heard), model.heard[0][1]), (1, None))
        self.assertIs(model.heard[0][3], samples)

    def test_a_piece_the_model_cannot_name_goes_with_its_neighbour(self):
        model = FakeModel([('Chinese', '第一句。'), ('Chinese', '第二句。'), ('English', 'The third one is in English.')])
        for head in ('language None<asr_text>', 'ology.For example', 'language English'):
            model.heads[1] = head
            model.heard.clear()
            heard = self.run_mixed(model, recording(3.0, -0.3, 2.0, -0.5, 3.0))
            self.assertEqual(heard.text, '第一句。第二句。The third one is in English.', head)
            self.assertEqual([(present, language) for present, language, _, _ in model.heard],
                             [([0, 1], 'Chinese'), ([2], 'English')])

    def test_a_long_recording_in_one_language_is_cut_at_pauses(self):
        sentences = [('Chinese', f'第{index}句。') for index in range(9)]
        model = FakeModel(sentences)
        parts = []
        for _ in sentences:
            parts += [7.5, -0.5]
        heard = self.run_mixed(model, recording(*parts[:-1]))  # 71.5 s
        self.assertEqual(heard.text, ''.join(text for _, text in sentences))
        self.assertEqual(heard.segments, 3)
        self.assertEqual([present for present, _, _, _ in model.heard], [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
        self.assertTrue(all(len(audio) <= (w.MAX_STRETCH_SECONDS + 1) * RATE for _, _, _, audio in model.heard))

    def test_a_stretch_that_gives_no_text_is_skipped(self):
        model = FakeModel([('Chinese', '第一句。'), ('English', ''), ('Chinese', '第三句。')])
        model.heads[1] = 'language English<asr_text>It was a'
        heard = self.run_mixed(model, recording(3.0, -0.4, 2.0, -0.4, 3.0))
        self.assertEqual((heard.text, heard.segments), ('第一句。第三句。', 3))
        model = FakeModel([('Chinese', ''), ('English', '')])
        model.heads = {0: 'language Chinese<asr_text>', 1: 'language English<asr_text>It was a'}
        self.assertEqual(self.run_mixed(model, recording(3.0, -0.4, 3.0)).text, '')

    def test_a_failing_call_fails_the_recognition(self):
        model = FakeModel([('Chinese', '第一句。'), ('English', 'The second one.')])

        def broken(windows):
            raise RuntimeError('metal error')

        with self.assertRaises(RuntimeError):
            w.transcribe_mixed(recording(3.0, -0.4, 3.0), [], model.hear, broken)


class QwenEngineTests(QuietLogTestCase):
    """The engine around a stand-in for mlx_audio's model: which calls it makes. No model, no MLX."""

    class Result:
        def __init__(self, text, language):
            self.text, self.language = text, [language]

    class Model:
        def __init__(self, batched=True):
            self.batched, self.batches, self.calls = batched, [], []

        def generate(self, **options):
            self.calls.append(options)
            if options['max_tokens'] == w.PROBE_TOKENS:      # a probe, one window
                return QwenEngineTests.Result('Keep everything', 'English')
            return QwenEngineTests.Result(' 明天下午三点开会。 ', 'Chinese')

        def __getattr__(self, name):
            if name == '_generate_chunks_batched' and self.batched is True:
                return self._batch
            raise AttributeError(name)

        def _batch(self, chunks, *, max_tokens, sampler, logits_processors, language, system_prompt, batch_size, verbose):
            self.batches.append((len(chunks), max_tokens, batch_size, language, system_prompt))
            if self.fail is not None:
                raise self.fail
            return [f'language Chinese<asr_text>第{index}'for index, _ in enumerate(chunks)], [], [], []

        fail = None

    class Cache:
        clears = 0

        def clear_cache(self):
            self.clears += 1

    def engine(self, model, mixed=True):
        engine = w.QwenEngine(mixed=mixed)
        engine._model, engine._mx = model, self.Cache()
        return engine

    def test_hear_is_one_call_with_the_language_and_the_hints(self):
        model = self.Model()
        engine = self.engine(model)
        samples = sound(1.0)
        self.assertEqual(engine.hear(samples, ['OpenAI'], 'English'), '明天下午三点开会。')
        self.assertEqual(engine.hear(samples, [], None), '明天下午三点开会。')
        first, second = model.calls
        self.assertIs(first['audio'], samples)
        self.assertEqual((first['language'], first['hotwords'], first['max_tokens'], first['chunk_duration']),
                         ('English', ['OpenAI'], w.ASR_MAX_TOKENS, w.ASR_CHUNK_SECONDS))
        self.assertEqual((second['language'], second['hotwords']), (None, []))
        self.assertEqual(engine._mx.clears, 2)

    def test_hear_cuts_long_audio_itself_and_mlx_audio_takes_each_chunk_whole(self):
        model = self.Model()
        engine = self.engine(model)
        samples = in_a_room(np.concatenate([sound(27.0), quiet(1.0), sound(27.0)]))
        self.assertEqual(engine.hear(samples, ['OpenAI'], None), '明天下午三点开会。 明天下午三点开会。')
        first, second = model.calls
        self.assertEqual(len(first['audio']) + len(second['audio']), len(samples))
        self.assertTrue(27.0 * RATE <= len(first['audio']) <= 28.0 * RATE)
        # The model picked the language of the first chunk; the second is written in it too (as in mlx_audio).
        self.assertEqual((first['language'], second['language']), (None, 'Chinese'))
        self.assertEqual((first['hotwords'], second['hotwords']), (['OpenAI'], ['OpenAI']))
        self.assertEqual((first['chunk_duration'], second['chunk_duration']), (w.ASR_CHUNK_SECONDS, w.ASR_CHUNK_SECONDS))
        # A stretch of 29.7 s with its quiet edges: one call for all of it, and mlx_audio is told not to cut it
        # (it would cut off the silence at the end and ask the model what was said in it).
        model = self.Model()
        padded = w.with_quiet_edges(in_a_room(sound(29.7)))
        self.engine(model).hear(padded, [], 'Chinese')
        self.assertEqual(len(model.calls), 1)
        self.assertIs(model.calls[0]['audio'], padded)
        self.assertEqual(model.calls[0]['chunk_duration'], len(padded) / RATE)
        self.assertGreater(model.calls[0]['chunk_duration'], w.ASR_CHUNK_SECONDS)

    def test_probes_are_asked_side_by_side_twelve_at_a_time(self):
        model = self.Model()
        engine = self.engine(model)
        heads = engine.probe([sound(1.0)] * 30)
        self.assertEqual(len(heads), 30)
        self.assertEqual(heads[0], 'language Chinese<asr_text>第0')
        tokens = w.PROBE_TOKENS
        self.assertEqual(model.batches, [(12, 12 * tokens, 12, None, None), (12, 12 * tokens, 12, None, None),
                                         (6, 6 * tokens, 6, None, None)])   # no hints, no language: the model says
        self.assertEqual(model.calls, [])
        self.assertEqual(engine.probe([]), [])

    def test_without_batched_decoding_each_window_is_asked_alone(self):
        for model in (self.Model(batched=False), self.Model()):
            if model.batched:
                model.fail = TypeError('got an unexpected keyword argument')   # another mlx_audio
            engine = self.engine(model)
            heads = engine.probe([sound(1.0)] * 3)
            # mlx_audio took the tag off; `probe_language` gets it back.
            self.assertEqual(heads, ['language English<asr_text>Keep everything'] * 3)
            self.assertEqual([w.probe_language(head) for head in heads], ['English'] * 3)
            self.assertEqual([(call['language'], call['max_tokens'], 'hotwords' in call) for call in model.calls],
                             [(None, w.PROBE_TOKENS, False)] * 3)
            self.assertFalse(engine._batched)
            engine.probe([sound(1.0)] * 2)
            self.assertLessEqual(len(model.batches), 1)                        # not tried again
            self.assertEqual(len([line for line in self.logs if 'one by one' in line]), 1)
            self.logs.clear()

    def test_a_failed_batch_is_asked_again_one_by_one_and_tried_next_time(self):
        model = self.Model()
        model.fail = RuntimeError('metal error')
        engine = self.engine(model)
        self.assertEqual(len(engine.probe([sound(1.0)] * 3)), 3)
        self.assertTrue(engine._batched)
        model.fail = None
        self.assertEqual(engine.probe([sound(1.0)] * 2), ['language Chinese<asr_text>第0', 'language Chinese<asr_text>第1'])

    def test_an_unfinished_tag_from_a_single_call_is_kept_as_it_is(self):
        model = self.Model(batched=False)
        model.generate = lambda **options: self.Result('language Cant', 'English')   # mlx_audio's default when it finds no tag
        engine = self.engine(model)
        self.assertEqual(engine.probe([sound(1.0)]), ['language Cant'])
        self.assertIsNone(w.probe_language('language Cant'))

    def test_transcribe_names_the_model_and_single_call_asks_nothing(self):
        samples = recording(3.0, -0.4, 3.0)
        model = self.Model()
        heard = self.engine(model).transcribe(samples, ['OpenAI'])
        self.assertEqual((heard.text, heard.segments, heard.model), ('明天下午三点开会。', 1, 'Qwen3-ASR-0.6B-4bit'))
        self.assertEqual(len(model.batches), 1)                                 # the two pieces were asked
        self.assertEqual((model.calls[0]['language'], model.calls[0]['hotwords']), ('Chinese', ['OpenAI']))
        model = self.Model()
        heard = self.engine(model, mixed=False).transcribe(samples, [])
        self.assertEqual((heard.text, heard.model, model.batches, len(model.calls)), ('明天下午三点开会。', 'Qwen3-ASR-0.6B-4bit', [], 1))
        self.assertIsNone(model.calls[0]['language'])


class JudgedAcrossPiecesTests(QuietLogTestCase):
    """The large model is judged on the whole recognition of a recording, every call it took, against what
    that recording needed: its length, the windows asked for their language and the stretches."""

    class Engine:
        """Recognises as the real engine does (`transcribe_mixed`); each call costs clock time."""

        def __init__(self, name, clock, hear_cost, probe_cost):
            self.name, self.clock, self.hear_cost, self.probe_cost = name, clock, hear_cost, probe_cost
            self.loaded, self.calls = False, 0
            self.model = FakeModel([('Chinese', '第一句。'), ('English', 'The second one is English.'),
                                    ('Chinese', '第三句。'), ('English', 'The fourth one is English too.')])

        def load(self):
            self.loaded = True

        def unload(self):
            self.loaded = False

        def hear(self, samples, hints, language):
            self.calls += 1
            self.clock.now += self.hear_cost
            return self.model.hear(samples, hints, language)

        def probe(self, windows):
            self.clock.now += self.probe_cost
            return self.model.probe(windows)

        def transcribe(self, samples, hints):
            return w.transcribe_mixed(samples, hints, self.hear, self.probe)

    def make(self, hear_cost, probe_cost=0.5):
        clock = AdaptiveEngineTests.Clock()
        primary = self.Engine('large', clock, hear_cost, probe_cost)
        fallback = self.Engine('small', clock, 0.2, 0.1)
        return w.AdaptiveEngine(primary, fallback, clock=clock), primary

    # 12 s, four stretches; asked: how the four pieces begin, then how the two English ones end (two rounds).
    SAMPLES = recording(3.0, -0.4, 2.6, -0.4, 2.6, -0.4, 2.6)

    def test_the_limit_counts_what_the_recording_needed(self):
        engine, _ = self.make(1.0)
        # One call: 0.6 of the length and a second, as before 1.3.
        self.assertAlmostEqual(engine.slow_limit(12, w.Transcript('')), 8.2)
        # Six windows asked at 0.6 s each, three more stretches at a second each.
        self.assertAlmostEqual(engine.slow_limit(12, w.Transcript('', segments=4, probes=6)), 14.8)
        self.assertAlmostEqual(engine.slow_limit(47.9, w.Transcript('', segments=2, probes=15)), 39.74)
        # The hints are in the prompt of every call: 3 ms a character for each further one.
        hints = ['OpenAI', 'Cloudflare'] * 50                      # ", ".join: 998 characters
        self.assertAlmostEqual(engine.slow_limit(12, w.Transcript(''), hints), 8.2)
        self.assertAlmostEqual(engine.slow_limit(12, w.Transcript('', segments=4, probes=6), hints), 14.8 + 3 * 2.994)

    def test_four_quick_calls_are_not_slow(self):
        engine, primary = self.make(1.5)                         # 2 × 0.5 + 4 × 1.5 = 7 s
        heard = engine.transcribe(self.SAMPLES, [])
        self.assertEqual((heard.text, heard.segments, heard.probes, heard.model, primary.calls),
                         ('第一句。The second one is English. 第三句。The fourth one is English too.', 4, 6, 'large', 4))
        self.assertEqual(engine.name, 'large')

    def test_a_recording_with_pauses_is_given_the_time_its_calls_need(self):
        # 13.8 s for 12 s of audio is what four stretches and six windows may take (14.8 s); for one call
        # it would be far too slow (8.2 s), and before the limit counted them it sent every such recording
        # to the small model.
        engine, _ = self.make(3.2)                               # 2 × 0.5 + 4 × 3.2 = 13.8 s
        self.assertEqual(engine.transcribe(self.SAMPLES, []).model, 'large')
        self.assertEqual((engine.name, self.logs), ('large', []))

    def test_calls_that_are_each_fast_enough_add_up_to_too_slow(self):
        engine, _ = self.make(3.6)                               # 2 × 0.5 + 4 × 3.6 = 15.4 s
        self.assertEqual(engine.transcribe(self.SAMPLES, []).model, 'large')
        self.assertEqual(engine.name, 'small')
        self.assertEqual(engine.transcribe(self.SAMPLES, []).model, 'small')

    def test_asking_the_languages_counts_too(self):
        engine, _ = self.make(1.5, probe_cost=4.5)               # 2 × 4.5 + 4 × 1.5 = 15 s
        engine.transcribe(self.SAMPLES, [])
        self.assertEqual(engine.name, 'small')

    def test_a_long_list_of_hints_gives_every_further_call_more_time(self):
        hints = ['OpenAI', 'Cloudflare'] * 50                    # 3 s more for each of the three further calls
        engine, _ = self.make(5.0)                               # 2 × 0.5 + 4 × 5 = 21 s; the limit is 23.8 s
        engine.transcribe(self.SAMPLES, hints)
        self.assertEqual(engine.name, 'large')
        engine, _ = self.make(5.0)
        engine.transcribe(self.SAMPLES, [])                      # without hints the same is too slow (14.8 s)
        self.assertEqual(engine.name, 'small')


class KeepForEvaluationTests(unittest.TestCase):
    """NEOLESS_ASR_KEEP_DIR: recordings are kept only when someone asks for it."""

    def test_nothing_is_kept_by_default(self):
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(os.environ):
            os.environ.pop('NEOLESS_ASR_KEEP_DIR', None)
            before = set(os.listdir(tempfile.gettempdir()))
            w.keep_for_evaluation(b'RIFF-not-kept')
            self.assertEqual(os.listdir(directory), [])
            self.assertEqual(set(os.listdir(tempfile.gettempdir())) - before, set())

    def test_opted_in_keeps_the_newest_few_for_the_owner_only(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = os.path.join(directory, 'kept')
            settings = {'NEOLESS_ASR_KEEP_DIR': folder, 'NEOLESS_ASR_KEEP_MAX': '2'}
            with unittest.mock.patch.dict(os.environ, settings):
                for index in range(4):
                    w.keep_for_evaluation(b'RIFF' + bytes([index]))
            names = os.listdir(folder)
            self.assertEqual(len(names), 2)
            self.assertTrue(all(name.endswith('.wav') for name in names))
            self.assertEqual(stat.S_IMODE(os.stat(folder).st_mode), 0o700)
            for name in names:
                self.assertEqual(stat.S_IMODE(os.stat(os.path.join(folder, name)).st_mode), 0o600)

    def test_a_folder_that_cannot_be_used_never_breaks_recognition(self):
        with tempfile.NamedTemporaryFile() as not_a_folder, \
                unittest.mock.patch.dict(os.environ, {'NEOLESS_ASR_KEEP_DIR': not_a_folder.name}):
            w.keep_for_evaluation(b'RIFF')   # no exception


class FetchModelTests(unittest.TestCase):
    """fetch_model.py: the one command that may download. Hugging Face is stubbed; nothing is fetched."""

    def setUp(self):
        import fetch_model
        self.fetch = fetch_model
        self.environment = unittest.mock.patch.dict(os.environ)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def run_main(self, argv):
        output = io.StringIO()
        with unittest.mock.patch('sys.stdout', output):
            status = self.fetch.main(argv)
        return status, output.getvalue()

    def test_check_never_downloads(self):
        with unittest.mock.patch.object(w, 'resolve_model', return_value='/cache/model') as resolve, \
                unittest.mock.patch.object(self.fetch, 'download') as download:
            self.assertEqual(self.run_main(['--check']), (0, f'{w.DEFAULT_MODEL}: cached\n'))
            resolve.assert_called_once_with(w.DEFAULT_MODEL)
            download.assert_not_called()
        with unittest.mock.patch.object(w, 'resolve_model', side_effect=OSError('not in the cache')):
            self.assertEqual(self.run_main(['--check']), (1, f'{w.DEFAULT_MODEL}: not cached\n'))
        self.assertEqual(os.environ['HF_HUB_OFFLINE'], '1')

    def test_download_asks_for_the_pinned_revision_and_files(self):
        import huggingface_hub
        model = 'mlx-community/Qwen3-ASR-1.7B-4bit'
        with unittest.mock.patch.object(huggingface_hub, 'snapshot_download', return_value='/cache/model') as snapshot:
            status, output = self.run_main(['--model', model])
        self.assertEqual(status, 0)
        snapshot.assert_called_once_with(repo_id=model, revision=w.MODEL_REVISIONS[model], allow_patterns=w.MODEL_FILES)
        self.assertIn(w.MODEL_REVISIONS[model], output)
        # Only this command lifts the offline switch, and only in its own process.
        self.assertEqual(os.environ['HF_HUB_OFFLINE'], '0')

    def test_only_pinned_models(self):
        with self.assertRaises(SystemExit), unittest.mock.patch('sys.stderr', io.StringIO()):
            self.fetch.main(['--model', 'someone/unpinned-model'])


if __name__ == '__main__':
    unittest.main()
