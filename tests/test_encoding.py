import json
from pathlib import Path
from shutil import which
import subprocess

import pytest

from spotified.encoding import encoding_options
from spotified.api import Track
from spotified.config import Config


def test_original_audio_does_not_apply_quality_or_bitrate():
    assert encoding_options('copy', 'best', '96k') == ['-c:a', 'copy']


@pytest.mark.parametrize('codec,extension,expected_codec,channels', [
    ('libmp3lame', 'mp3', 'mp3', 2),
    ('aac', 'm4a', 'aac', 2),
    ('libopus', 'ogg', 'opus', 2),
    ('libmp3lame', 'mp3', 'mp3', 1),
    ('aac', 'm4a', 'aac', 1),
    ('libopus', 'ogg', 'opus', 1),
    ('libvorbis', 'ogg', 'vorbis', 2),
])
@pytest.mark.skipif(not which('ffmpeg') or not which('ffprobe'), reason='FFmpeg is not installed')
def test_best_quality_encodes_real_audio(tmp_path, codec, extension, expected_codec, channels):
    encoders = subprocess.check_output(['ffmpeg', '-hide_banner', '-encoders'], stderr=subprocess.DEVNULL, text=True)
    if codec not in encoders:
        pytest.skip(f'This FFmpeg build does not include {codec}')
    source = tmp_path / 'source.wav'
    destination = tmp_path / f'converted.{extension}'
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i',
                    'sine=frequency=997:sample_rate=44100:duration=0.3', '-ac', str(channels),
                    str(source)], check=True, capture_output=True)
    track = Track('track:quality-test')
    track._codec = codec
    Config.Values['TRANSCODE_BITRATE'] = 'best'
    assert track.convert_audio_format(source, destination) is not None
    assert not source.exists()
    probe = subprocess.run(['ffprobe','-v','error','-show_entries','stream=codec_name,channels,sample_rate,bit_rate',
                            '-of','json',str(destination)], check=True, capture_output=True, text=True)
    stream = json.loads(probe.stdout)['streams'][0]
    assert stream['codec_name'] == expected_codec
    assert stream['channels'] == channels
    assert int(stream['sample_rate']) == (48000 if codec == 'libopus' else 44100)
    if codec == 'libmp3lame':
        assert int(stream['bit_rate']) == 320000


@pytest.mark.skipif(not which('ffmpeg'), reason='FFmpeg is not installed')
def test_copy_preserves_encoded_audio_packets(tmp_path):
    source = tmp_path / 'original.ogg'
    output = tmp_path / 'copied.ogg'
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i',
                    'sine=frequency=997:sample_rate=48000:duration=0.2', '-c:a','libopus',
                    str(source)], check=True, capture_output=True)
    def packets(path):
        return subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-map','0:a:0',
                                        '-c:a','copy','-f','hash','-hash','sha256','-'])
    expected = packets(source)
    track = Track('track:copy-test')
    track._codec = 'copy'
    Config.Values['TRANSCODE_BITRATE'] = 'best'
    assert track.convert_audio_format(source, output) is not None
    assert packets(output) == expected


def test_source_fallback_selects_best_available_within_account_limit():
    from librespot.audio import SuperAudioFormat
    from librespot.audio.decoders import AudioQuality
    from librespot.proto.Metadata_pb2 import AudioFile
    from spotified.quality import SourceQualityPicker
    normal = AudioFile(format=AudioFile.OGG_VORBIS_96)
    high = AudioFile(format=AudioFile.OGG_VORBIS_160)
    very_high = AudioFile(format=AudioFile.OGG_VORBIS_320)
    premium = SourceQualityPicker(AudioQuality.VERY_HIGH, SuperAudioFormat.VORBIS, AudioQuality.LOSSLESS)
    assert premium.get_file([normal, high]) is high
    assert premium.get_file([normal, high, very_high]) is very_high
    free = SourceQualityPicker(AudioQuality.HIGH, SuperAudioFormat.VORBIS, AudioQuality.HIGH)
    assert free.get_file([very_high, normal, high]) is high
    assert free.get_file([very_high]) is None
    explicit_low = SourceQualityPicker(AudioQuality.NORMAL, SuperAudioFormat.VORBIS, AudioQuality.LOSSLESS)
    assert explicit_low.get_file([high, normal]) is normal
