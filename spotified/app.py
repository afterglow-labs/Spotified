from argparse import Namespace, Action

from spotified.api import *


def filter_search_query(search_query: str, item_types: tuple[str, ...]) -> dict[str, str | int]:
    aliases = {
        't': TYPE, 'type': TYPE,
        'l': SEARCH_QUERY_SIZE, 'limit': SEARCH_QUERY_SIZE,
        's': SEARCH_QUERY_SIZE, 'size': SEARCH_QUERY_SIZE,
        'o': OFFSET, 'offset': OFFSET,
        'ie': INCLUDE_EXTERNAL, 'include-external': INCLUDE_EXTERNAL,
    }
    params = {TYPE: ','.join(item_types[:4]),
              SEARCH_QUERY_SIZE: clamp(1, Spotified.CONFIG.get_search_query_size(), 1000)}
    pattern = r'(?<!\S)/(type|t|limit|l|size|s|offset|o|include-external|ie)(?=\s|$)'
    matches = list(re.finditer(pattern, search_query))
    params['q'] = search_query[:matches[0].start()].strip() if matches else search_query.strip()
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(search_query)
        value = search_query[match.end():end].strip()
        key = aliases[match[1]]
        if key == TYPE:
            types = [item.strip() for item in value.split(',')]
            if not types or any(item not in item_types for item in types):
                raise ValueError(f'Invalid search type: {value}. Choose from {", ".join(item_types)}')
            params[key] = ','.join(dict.fromkeys(types))
        elif key in {SEARCH_QUERY_SIZE, OFFSET}:
            try:
                params[key] = clamp(1 if key == SEARCH_QUERY_SIZE else 0, int(value),
                                    1000 if key == SEARCH_QUERY_SIZE else 999)
            except ValueError:
                raise ValueError(f'/{match[1]} requires an integer') from None
        elif safe_typecast({key: value}, key, bool):
            params[key] = 'audio'
        else:
            params.pop(key, None)
    return params


def fetch_search_display(search_query: str) -> list[str]:
    table_headers = {
        TRACKS:     ('ID', 'Name', 'Artists'    ),
        ALBUMS:     ('ID', 'Name', 'Artists'    ),
        ARTISTS:    ('ID', 'Name'               ),
        PLAYLISTS:  ('ID', 'Name', 'Owner'      ),
        EPISODES:   ('ID', 'Name', 'Show'       ),
        SHOWS:      ('ID', 'Name', 'Publisher'  ),
    }
    params = filter_search_query(search_query, tuple(t[:-1] for t in table_headers))
    
    search_url = f"{SEARCH_URL}?{MARKET_APPEND}"
    params[LIMIT] = 50 if Spotified.CONFIG.permit_legacy_api() else 10
    items: dict[str, list[dict]] = Spotified.invoke_url_nextable(search_url, stripper=tuple(t for t in table_headers if t[:-1] in params[TYPE]),
                                                              max=params.pop(SEARCH_QUERY_SIZE), params=params)
    
    search_result_uris = []
    for item_type, headers in table_headers.items():
        if not any(items.get(item_type, [])): continue
        resps: list[dict] = [i for i in items[item_type] if i is not None]
        counter = len(search_result_uris) + 1
        if   item_type == TRACKS:
             data = [ [resps.index(t) + counter,
                       str(t[NAME]) + (" [E]" if t[EXPLICIT] else ""),
                       ', '.join([artist[NAME] for artist in t[ARTISTS]]) ] for t in resps]
        elif item_type == ALBUMS:
             data = [ [resps.index(m) + counter,
                       str(m[NAME]),
                       ', '.join([artist[NAME] for artist in m[ARTISTS]]) ] for m in resps]
        elif item_type == ARTISTS:
             data = [ [resps.index(a) + counter,
                       str(a[NAME])                                       ] for a in resps]
        elif item_type == PLAYLISTS:
             data = [ [resps.index(p) + counter,
                       str(p[NAME]),
                       str(p[OWNER][DISPLAY_NAME])                        ] for p in resps]
        if   item_type == EPISODES:
             data = [ [resps.index(e) + counter,
                       str(e[NAME]) + (" [E]" if e[EXPLICIT] else ""),
                       str(e[SHOW][NAME])                                 ] for e in resps]
        elif item_type == SHOWS:
             data = [ [resps.index(s) + counter,
                       str(s[NAME]) + (" [E]" if s[EXPLICIT] else ""),
                       str(s[PUBLISHER])                                  ] for s in resps]
        search_result_uris.extend([i[URI] for i in resps])
        Printer.table(item_type.capitalize(), headers, data)
    
    return search_result_uris


def search_and_select(search: str = ""):
    """ Perform search Queries and allow user to select results """
    while not search or search == ' ':
        search = Printer.get_input('Enter search: ')
    
    if any(Query.bulk_regex_urls(search)):
        Printer.hashtaged(PrintChannel.WARNING, 'URL DETECTED IN SEARCH, TREATING SEARCH AS URL REQUEST')
        Query(Spotified.DATETIME_LAUNCH).request(search).execute()
        return
    
    try:
        search_result_uris = fetch_search_display(search)
    except ValueError as exc:
        Printer.hashtaged(PrintChannel.WARNING, str(exc))
        return
    
    if not search_result_uris:
        Printer.hashtaged(PrintChannel.MANDATORY, 'NO RESULTS FOUND - EXITING...')
        return
    
    uris: list[str] = select(search_result_uris)
    Query(Spotified.DATETIME_LAUNCH).request(' '.join(uris)).execute()


def perform_query(args: Namespace) -> None:
    """ Perform Query according to type """
    try:
        if args.urls or args.file_of_urls:
            urls = ""
            if args.urls:
                urls: str = args.urls
            elif args.file_of_urls:
                if file_has_content(args.file_of_urls):
                    with open(args.file_of_urls, 'r', encoding='utf-8') as file:
                        urls = " ".join([line.strip() for line in file.readlines()])
                else:
                    Printer.hashtaged(PrintChannel.ERROR, f'FILE {args.file_of_urls} NOT FOUND')
            
            if len(urls) > 0:
                Query(Spotified.DATETIME_LAUNCH).request(urls).execute()
        
        elif args.verify_library:
            VerifyLibrary(Spotified.DATETIME_LAUNCH).execute()
        
        elif not Spotified.CONFIG.permit_client_api():
            Printer.hashtaged(PrintChannel.MANDATORY, 'NO DEVELOPER CLIENT - SEARCH AND USERITEM QUERIES NON-FUNCTIONAL')
            return
        
        elif args.liked_songs:
            LikedSong(Spotified.DATETIME_LAUNCH).execute()
        
        elif args.user_playlists:
            UserPlaylist(Spotified.DATETIME_LAUNCH).execute()
        
        elif args.followed_artists:
            FollowedArtist(Spotified.DATETIME_LAUNCH).execute()
        
        elif args.followed_albums:
            SavedAlbum(Spotified.DATETIME_LAUNCH).execute()
        
        elif args.search:
            search_and_select(args.search)
        
        else:
            search_and_select()
    
    except BaseException as e:
        # catch all but do not throw KeyboardInterrupts
        if isinstance(e, KeyboardInterrupt):
            Printer.hashtaged(PrintChannel.MANDATORY, "ABORTING QUERY")
            return
        Spotified.end()
        raise


def client(args: Namespace, modes: list[Action]) -> None:
    """ Perform Queries as needed """
    
    ask_mode = False
    if any([getattr(args, mode.dest) for mode in modes]):
        perform_query(args)
    elif not args.persist:
        # this maintains current behavior when no mode/url present
        Printer.hashtaged(PrintChannel.MANDATORY, "NO MODE SELECTED, DEFAULTING TO SEARCH")
        perform_query(args)
        
        # TODO: decide if this alt behavior should be implemented
        # Printer.hashtaged(PrintChannel.MANDATORY, "NO MODE SELECTED, PLEASE SELECT ONE")
        # ask_mode = True
    
    while args.persist or ask_mode:
        ask_mode = False
        mode_data = [[i+1, mode.dest.upper().replace('_', ' ')] for i, mode in enumerate(modes)]
        Printer.table("Modes", ("ID", "MODE"), [[0, "EXIT"]] + mode_data)
        try:
            selected_mode: Action | None = select([None] + modes, inline_prompt="MODE SELECTION: ", first_ID=0, only_one=True)[0]
        except KeyboardInterrupt:
            selected_mode = None
        
        if selected_mode is None:
            Printer.hashtaged(PrintChannel.MANDATORY, "CLOSING SESSION")
            break
        
        # clear previous run modes
        for mode in modes:
            if mode.nargs:
                setattr(args, mode.dest, None)
            else:
                setattr(args, mode.dest, False)
        
        # set new mode
        if selected_mode.nargs:
            mode_args = Printer.get_input(f"\nMODE ARGUMENTS ({selected_mode.dest.upper().replace('_', ' ')}): ")
            setattr(args, selected_mode.dest, mode_args)
        else:
            setattr(args, selected_mode.dest, True)
        
        Spotified.start_stats()
        perform_query(args)
    
    Spotified.end()
