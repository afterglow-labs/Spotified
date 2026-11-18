"""Prefer the requested source tier, with an ordered, account-bounded fallback."""
from librespot.audio import SuperAudioFormat
from librespot.audio.decoders import AudioQuality, FormatOnlyAudioQuality


class SourceQualityPicker(FormatOnlyAudioQuality):
    def __init__(self, preferred, format_filter, maximum):
        super().__init__(preferred, format_filter)
        self.maximum = maximum

    def get_file(self, files):
        available = []
        for file in files:
            if not file.HasField('format'):
                continue
            try:
                quality = AudioQuality.get_quality(file.format)
                if SuperAudioFormat.get(file.format) == self.format_filter and quality.value <= self.maximum.value:
                    available.append((quality, file))
            except (RuntimeError, ValueError):
                continue
        for quality, file in available:
            if quality == self.preferred:
                return file
        if available:
            quality, file = max(available, key=lambda entry: entry[0].value)
            self.logger.warning('Requested %s unavailable; using %s', self.preferred.name, quality.name)
            return file
        return None
