import React, {useMemo, useState} from 'react';
import {Disc3, Play, Download, ArrowLeft, Search, RefreshCw} from 'lucide-react';
import {time} from './api';

function RecordMark() {
  return <svg width="112" height="112" viewBox="0 0 128 128" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" aria-hidden="true"><circle cx="64" cy="64" r="56"/><circle cx="64" cy="64" r="16"/><circle cx="64" cy="64" r="3"/><path d="M22 51A44 44 0 0 1 51 22M31 54A35 35 0 0 1 54 31M40 57A26 26 0 0 1 57 40M77 106A44 44 0 0 0 106 77M74 97A35 35 0 0 0 97 74M71 88A26 26 0 0 0 88 71"/></svg>;
}

export function Cover({track, large=false}) {
  const [broken, setBroken] = useState(false);
  return <span className={`cover ${large ? 'large' : ''}`}>{track && !broken ? <img src={track.artwork} alt="" loading="lazy" onError={() => setBroken(true)}/> : <Disc3 aria-hidden="true"/>}</span>;
}

export default function Library({view, data, refresh, addMusic, onPlay, busy}) {
  const [search, setSearch] = useState('');
  const [selection, setSelection] = useState(null);
  const tracks = data?.tracks || [];
  const groups = useMemo(() => {
    if (view === 'Playlists') return (data?.playlists || []).map(p => ({...p, items: p.tracks.map(id => tracks.find(t => t.id === id)).filter(Boolean)}));
    if (view === 'Library') return [];
    const grouped = new Map();
    for (const track of tracks) {
      const name = view === 'Artists' ? track.artist : track.album;
      const subtitle = view === 'Albums' ? track.album_artist || track.artist : '';
      const key = name + '\0' + subtitle;
      if (!grouped.has(key)) grouped.set(key, {id: key, name, subtitle, items: []});
      grouped.get(key).items.push(track);
    }
    return [...grouped.values()].sort((a, b) => a.name.localeCompare(b.name));
  }, [data, view]);
  const group = groups.find(g => g.id === selection);
  const query = search.toLocaleLowerCase();
  const rows = (group?.items || tracks).filter(t => [t.title, t.artist, t.album, t.genre, t.folder].join(' ').toLocaleLowerCase().includes(query));
  const visibleGroups = groups.filter(g => `${g.name} ${g.subtitle || ''}`.toLocaleLowerCase().includes(query));
  return <>
    <div className="toolbar"><label className="search"><Search size={18}/><input aria-label="Search your library" placeholder="Search your library" value={search} onChange={e => setSearch(e.target.value)}/></label><button onClick={refresh} disabled={busy}><RefreshCw size={16}/>{busy ? 'Scanning…' : 'Refresh'}</button></div>
    {data?.truncated && <p className="notice">Showing the first 20,000 tracks.</p>}
    {group && <div className="collection-heading"><button onClick={() => setSelection(null)}><ArrowLeft size={16}/>Back</button><h2>{group.name}</h2>{group.href && <a className="button" href={group.href} download>Export M3U8</a>}{group.unavailable > 0 && <p>{group.unavailable} playlist entries are not downloaded.</p>}</div>}
    {!data ? <div className="empty"><Disc3 size={70}/><h2>Reading your library…</h2></div> : !tracks.length && !groups.length ? <div className="empty"><RecordMark/><h2>{view === 'Playlists' ? 'Your playlists live here' : 'Your collection starts here'}</h2><p>Add a Spotify album, playlist, or track.<br/>{view === 'Playlists' ? 'Enable M3U8 export in Settings to keep playlists.' : 'Artists, albums, and artwork will appear here.'}</p><button className="primary" onClick={addMusic}>Add music</button></div> : view !== 'Library' && !group ? <div className="album-grid">{visibleGroups.map(g => <button className="album" key={g.id} onClick={() => setSelection(g.id)}><Cover track={g.items[0]} large/><strong>{g.name}</strong><span>{g.subtitle || `${g.items.length} tracks`}</span></button>)}{!visibleGroups.length && <p className="notice">{view === 'Playlists' && !search ? 'No exported playlists yet. Turn on M3U8 export in Settings.' : 'No matches for this search.'}</p>}</div> : <div className="track-table" role="table" aria-label="Tracks"><div className="track-row table-heading" role="row"><span>Title</span><span>Artist</span><span>Album</span><span>Time</span><span/></div>{rows.map((track, index) => <div className="track-row" role="row" key={`${track.id}-${index}`}><button className="track-title" onClick={() => onPlay(track)} title={`Play ${track.title}`} aria-label={`Play ${track.title}`}><Cover track={track}/><span><strong>{track.title}</strong><small>{track.name}</small></span><Play size={15}/></button><span>{track.artist}</span><span>{track.album}</span><span>{time(track.duration)}</span><a className="icon-button" href={`${track.href}&download=1`} download title={`Download ${track.title}`} aria-label={`Download ${track.title}`}><Download size={17}/></a></div>)}{!rows.length && <p className="notice">No matches for this search.</p>}</div>}
    <footer>{group ? group.items.length : tracks.length} tracks{group ? ` · ${group.name}` : ''}</footer>
  </>;
}
