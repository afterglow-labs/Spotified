"""Quality-first encoding presets. Stream copy never changes audio samples."""


def encoding_options(codec, setting='best', source_bitrate=None, channels=2):
    options = ['-c:a', codec]
    if codec == 'copy':
        return options
    if setting == 'best':
        presets = {
            'libmp3lame': ['-b:a', '320k', '-compression_level', '0'],
            'aac': ['-b:a', f'{256 * channels}k', '-aac_coder', 'twoloop'],
            'libopus': ['-b:a', '256k' if channels == 1 else '510k',
                        '-compression_level', '10', '-application', 'audio', '-vbr', 'on'],
            'libfdk_aac': ['-b:a', f'{256 * channels}k', '-afterburner', '1'],
            'libvorbis': ['-q:a', '10'],
        }
        if codec not in presets:
            raise ValueError(f'No best-quality preset for encoder {codec}')
        return options + presets[codec]
    bitrate = source_bitrate if setting in {'auto', ''} else setting
    # libopus rejects stereo-sized bitrates on a mono stream.
    if codec == 'libopus' and channels == 1 and bitrate and bitrate.endswith('k'):
        bitrate = f'{min(int(bitrate[:-1]), 256)}k'
    return options + (['-b:a', bitrate] if bitrate else [])
