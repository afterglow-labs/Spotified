import pytest

from spotified.spotify_connection import connect_accesspoint


def test_refused_accesspoint_falls_back_with_pacing_and_resets_socket_timeout():
    attempts, paced, timeouts = [], [], []
    class Socket:
        def settimeout(self, value): timeouts.append(value)
    def connect(address, timeout):
        attempts.append(address)
        assert timeout == 8
        if len(attempts) == 1: raise ConnectionRefusedError('refused')
        return Socket()
    def pace(operation, *args, **kwargs):
        try: return operation(*args, **kwargs)
        finally: paced.append('wait')
    result = connect_accesspoint('failed.spotify.com:4070', lambda sock: ('holder', sock), pace,
        connector=connect, resolve=lambda: ['failed.spotify.com:4070', 'backup.spotify.com:80', 'backup.spotify.com:443'])
    assert result[0] == 'holder'
    assert attempts == [('failed.spotify.com', 4070), ('backup.spotify.com', 443)]
    assert paced == ['wait', 'wait']
    assert timeouts == [None]


def test_failover_is_bounded_and_does_not_repeat_same_endpoint():
    called = []
    def connect(address, **kwargs):
        called.append(address); raise TimeoutError('unavailable')
    with pytest.raises(ConnectionError, match='Could not reach Spotify'):
        connect_accesspoint('first:80', lambda sock: sock, lambda call, *a, **k: call(*a, **k), attempts=2,
            connector=connect, resolve=lambda: ['first:80', 'second:443', 'third:443'])
    assert len(called) == 2 and len(set(called)) == 2


def test_success_does_not_contact_resolver_and_disabled_retries_stop():
    class Socket:
        def settimeout(self, value): pass
    def never(): pytest.fail('Unexpected resolver request')
    assert isinstance(connect_accesspoint('first:80', lambda sock: sock, lambda call, *a, **k: call(*a, **k),
        connector=lambda *a, **k: Socket(), resolve=never), Socket)
    def refused(*a, **k): raise ConnectionRefusedError('refused')
    with pytest.raises(ConnectionError):
        connect_accesspoint('first:80', lambda sock: sock, lambda call, *a, **k: call(*a, **k),
            attempts=1, connector=refused, resolve=never)
