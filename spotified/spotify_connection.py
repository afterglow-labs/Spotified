"""Bounded, paced access-point failover for the pinned librespot transport."""
import socket

import requests


def connect_accesspoint(address, holder, paced_call, *, attempts=4, connector=None, resolve=None):
    connector = connector or socket.create_connection
    def endpoints():
        response = paced_call(requests.get, 'https://apresolve.spotify.com/',
                              params={'type': 'accesspoint'}, timeout=10)
        response.raise_for_status()
        return response.json().get('accesspoint', [])
    resolve = resolve or endpoints
    candidates = [address]
    tried = set()
    last_error = None
    while candidates and len(tried) < max(1, attempts):
        candidate = candidates.pop(0)
        if candidate in tried:
            continue
        tried.add(candidate)
        host, _, port = candidate.rpartition(':')
        try:
            connection = paced_call(connector, (host, int(port)), timeout=8)
        except OSError as error:
            last_error = error
            if len(tried) == 1 and attempts > 1:
                # Try other advertised endpoints, preferring the standard TLS port.
                candidates = sorted(set(resolve()) - tried, key=lambda endpoint: not endpoint.endswith(':443'))
            continue
        # The timeout only bounds connection establishment, not the audio stream.
        connection.settimeout(None)
        return holder(connection)
    raise ConnectionError('Could not reach Spotify after trying available access points. '
                          'Check the server network and try Check Spotify connection again.') from last_error


def install_accesspoint_fallback(paced_call, attempts=4):
    from librespot.core import Session
    if getattr(Session.ConnectionHolder.create, '_spotified_fallback', False):
        return
    def create(address, conf):
        return connect_accesspoint(address, Session.ConnectionHolder, paced_call, attempts=attempts)
    create._spotified_fallback = True
    Session.ConnectionHolder.create = staticmethod(create)
