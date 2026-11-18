"""Pace download requests, including requests made inside librespot."""
from functools import partial
from threading import RLock


class RequestPacer:
    """Keep concurrent requests from bypassing the post-request delay."""

    def __init__(self, wait):
        self.wait = wait
        self.lock = RLock()

    def call(self, operation, *args, **kwargs):
        with self.lock:
            try:
                result = operation(*args, **kwargs)
            except Exception:
                self.wait(None)
                raise
            # Cancellation interrupts immediately instead of entering another wait.
            self.wait(result)
            return result

    def install(self, session):
        # Adapter.send covers prepared API requests and CDN GETs, and runs
        # before requests follows a redirect. Do not wrap reads/keepalive packets.
        for adapter in set(session.client().adapters.values()):
            if getattr(adapter, '_spotified_paced', False) is not True:
                adapter.send = partial(self.call, adapter.send)
                adapter._spotified_paced = True

        manager = session.audio_key()
        if getattr(manager, '_spotified_paced', False) is True:
            return
        original = manager.get_audio_key

        def get_audio_key(gid, file_id, retry=True):
            # Librespot retries immediately by default. Spotified's bounded
            # stream retry loop supplies the configured exponential backoff.
            return self.call(original, gid, file_id, retry=False)

        manager.get_audio_key = get_audio_key
        manager._spotified_paced = True
