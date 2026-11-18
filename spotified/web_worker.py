"""Run one browser job in an isolated process using the existing downloader."""
import argparse
import json
import signal
import sys
from pathlib import Path

EVENT_PREFIX = 'SPOTIFIED_WEB_EVENT '


def normalize_names(names):
    if not isinstance(names, list):
        return []
    return [name if isinstance(name, str) and name.strip() else 'Unknown track' for name in names]


def emit(kind, **fields):
    print(EVENT_PREFIX + json.dumps({'kind': kind, **fields}), flush=True)


def main():
    def terminate(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser()
    parser.add_argument('--config-dir', type=Path, required=True)
    parser.add_argument('--settings', type=Path)
    parser.add_argument('--format', choices=('copy', 'mp3', 'aac', 'opus'), default='copy')
    parser.add_argument('--preview', action='store_true')
    parser.add_argument('--check-login', action='store_true')
    parser.add_argument('--login', action='store_true')
    parser.add_argument('--client-login', type=int, metavar='PORT')
    parser.add_argument('urls', nargs='*')
    args = parser.parse_args()
    from spotified.config import Config, Spotified, LoginHandler, LogHandler
    config_dir = args.config_dir.resolve()
    options = argparse.Namespace(
        config_location=str(args.settings or config_dir / 'config.json'), debug=False, test_mode=args.preview,
        update_config=False, update_archive=False, verify_library=False,
        credentials_location=str(config_dir / 'credentials.json'),
        api_credentials_location=str(config_dir / 'api_credentials.json'),
        song_archive_location=str(config_dir), download_format=args.format,
        standard_interface=False, print_progress_info=False, print_download_progress=False,
        print_url_progress=False, print_album_progress=False, print_artist_progress=False,
        print_playlist_progress=False, export_zmd=False,
    )
    session = None
    try:
        Config.load(options, create=False)
        Spotified.start_stats()
        from spotified.spotify_connection import install_accesspoint_fallback
        install_accesspoint_fallback(Spotified.PACER.call, attempts=Config.get_retry_attempts() + 1)
        # No hidden interactive login that would strand a browser job. The CLI
        # can refresh an expired login; existing credentials work in both modes.
        if args.client_login:
            from spotified.config import MercuryRequests, SCOPES
            from spotified.spotify_auth import client_login
            LoginHandler.SESSION_BUILDER.login_credentials = client_login(
                MercuryRequests.keymaster_client_id, SCOPES, args.client_login, emit, Spotified.PACER.call)
            LoginHandler.SESSION = LoginHandler.SESSION_BUILDER.create()
        elif args.login:
            from spotified.config import OAuth, MercuryRequests, SCOPES
            oauth = OAuth(MercuryRequests.keymaster_client_id,
                          f'http://127.0.0.1:{Config.get_oauth_port()}/login',
                          lambda url: emit('login_url', url=url)).set_scopes(SCOPES).set_listen_all(True).set_timeout(600)
            LoginHandler.SESSION_BUILDER.login_credentials = oauth.flow()
            LoginHandler.SESSION = LoginHandler.SESSION_BUILDER.create()
        else:
            credentials = LoginHandler.get_creds_from_file(Config.get_credentials_location())
            LoginHandler.login5_cred_login(credentials)
        session = LoginHandler.SESSION
        if session is None:
            raise RuntimeError('Spotify login is missing. Reconnect Spotify from Settings.')
        Spotified.pace_session(session)
        Spotified.SESSION = session
        if Config.permit_client_api():
            LoginHandler.oauth_cred_login(LoginHandler.get_creds_from_file(Config.get_api_credentials_location()))
        _, Spotified.DOWNLOAD_QUALITY, Spotified.DOWNLOAD_BITRATE = Spotified.parse_dl_quality(Config.get_download_qual_pref())
        LoginHandler.save_credentials()
        for name in ('credentials.json', 'api_credentials.json'):
            path = config_dir / name
            if path.is_file():
                path.chmod(0o600)
        emit('account', connected=True)
        if args.login or args.client_login or args.check_login:
            emit('result', status='completed', total=0, completed=0)
            return 0
        Spotified.LOGGER = LogHandler.start_logger(Spotified.DATETIME_LAUNCH)
        from spotified.api import Query, Container
        query = Query(Spotified.DATETIME_LAUNCH).request(args.urls)
        query.handle_zmd_prefetch()
        query.parse_query_metadata(query.fetch_query_metadata())
        query.conditional_metadata()
        entries = [track for group in query.requested_objs for item in group
                   for track in (item.recurse_DLC() if isinstance(item, Container) else [item])]
        targets = {item for item in entries if item is not None}
        missing = sum(item is None for item in entries)
        if not targets:
            raise RuntimeError('No available tracks were found. Check the link and the activity details.')
        emit('metadata', total=len(targets), names=normalize_names([item.name for item in sorted(targets, key=lambda item: item.uri)][:12]))
        query.download()
        completed = sum(item._downloaded for item in targets)
        status = 'previewed' if args.preview else ('completed' if completed == len(targets) and not missing
                                                  else 'partial' if completed else 'failed')
        emit('result', status=status, total=len(targets), completed=completed)
        return 1 if status == 'failed' else 0
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        emit('error', message=str(exc) or type(exc).__name__)
        return 1
    finally:
        if Spotified.LOGGER is not None:
            Spotified.end()
        if session is not None:
            session.close()


if __name__ == '__main__':
    sys.exit(main())
