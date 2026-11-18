import React, {useEffect, useRef, useState} from 'react';
import {ArrowLeft, ChevronRight, Download, Music2, Search, RefreshCw} from 'lucide-react';
import {api} from './api';
import AudioOptions from './AudioOptions';

const views = [['playlists','Your playlists'], ['liked','Liked songs'], ['albums','Saved albums'], ['artists','Followed artists'], ['search','Search Spotify']];
const types = [['track','Songs'], ['album','Albums'], ['playlist','Playlists'], ['artist','Artists']];
export default function Spotify({settings, refresh, notify}) {
  const [view, setView] = useState('playlists');
  const [query, setQuery] = useState('');
  const [term, setTerm] = useState('');
  const [kind, setKind] = useState('track');
  const [trail, setTrail] = useState([]);
  const [page, setPage] = useState(null);
  const [items, setItems] = useState([]);
  const [selected, setSelected] = useState(new Map());
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [review, setReview] = useState(false);
  const [message, setMessage] = useState('');
  const [audio, setAudio] = useState(null);
  const version = useRef(0);
  const current = trail.at(-1);
  const key = JSON.stringify([view, term, kind, current?.uri]);
  const options = audio || {format: settings?.format || 'copy', quality: settings?.quality || 'auto', bitrate: settings?.bitrate || 'best'};
  async function load(offset=0, fresh=false) {
    const generation = ++version.current;
    if (!current && view === 'search' && !term.trim()) {setItems([]);setPage(null);setLoading(false);return;}
    setLoading(true);setError('');
    try {
      const params = new URLSearchParams({view: current ? 'contents' : view, q: term, kind, offset: String(offset), ...(current ? {uri:current.uri} : {}), ...(fresh ? {refresh:'1'} : {})});
      const next = await api(`/api/spotify?${params}`);
      if (generation !== version.current) return;
      setPage(next);
      setItems(previous => [...new Map([...(offset ? previous : []), ...next.items].map(item => [item.uri,item])).values()]);
    } catch(e) {if (generation === version.current) setError(e.message);}
    finally {if (generation === version.current) setLoading(false);}
  }
  useEffect(() => {setItems([]);setPage(null);setSelected(new Map());setReview(false);setMessage('');load();return () => {version.current++;};}, [key]);
  function toggle(item) {
    setSelected(previous => {const next = new Map(previous);if (next.has(item.uri)) next.delete(item.uri);else if (next.size < 200) next.set(item.uri,item);return next;});
  }
  function selectVisible() {
    setSelected(previous => {const next = new Map(previous);for (const item of items) if (item.available && item.kind !== 'artist' && next.size < 200) next.set(item.uri,item);return next;});
  }
  async function save() {
    setSaving(true);setError('');
    try {await api('/api/spotify/import', {uris:[...selected.keys()], ...options});setMessage(`${selected.size} selected item${selected.size === 1 ? '' : 's'} added to Downloads.`);setSelected(new Map());setReview(false);await refresh();}
    catch(e) {notify(e.message);} finally {setSaving(false);}
  }
  return <div className="page-body spotify-browser">
    <p className="hint">Browse your connected Spotify account and choose what to save on your server.</p>
    <div className="spotify-controls"><label>Browse<select aria-label="Browse" value={view} disabled={saving} onChange={e => {setView(e.target.value);setTrail([]);}}>{views.map(([id,title]) => <option key={id} value={id}>{title}</option>)}</select></label>
      <button onClick={() => load(0,true)} disabled={loading || saving || (!current && view === 'search' && !term)} aria-label="Refresh Spotify"><RefreshCw size={18}/></button>
    </div>
    {view === 'search' && !current && <form className="spotify-search" onSubmit={e => {e.preventDefault();if (query.trim() === term) load(0,true);else setTerm(query.trim());}}>
      <label className="search"><Search size={18}/><input aria-label="Search Spotify" placeholder="Song, album, playlist, or artist" maxLength={200} value={query} onChange={e => setQuery(e.target.value)}/></label>
      <label>Type<select aria-label="Search type" value={kind} onChange={e => setKind(e.target.value)}>{types.map(([id,title]) => <option key={id} value={id}>{title}</option>)}</select></label><button className="primary" disabled={!query.trim() || loading}>Search</button>
    </form>}
    {current && <div className="section-heading"><button onClick={() => setTrail(trail.slice(0,-1))} disabled={saving}><ArrowLeft size={18}/>Back</button><h2>{current.name}</h2>{current.kind !== 'artist' && <button onClick={() => toggle(current)} disabled={saving}>{selected.has(current.uri) ? 'Deselect collection' : 'Select whole ' + current.kind}</button>}</div>}
    {error && <div className="notice error" role="alert">{error}<button onClick={() => load(page?.next_offset ?? 0,true)}>Retry</button></div>}
    {message && <p role="status" className="notice">{message}</p>}
    <div className="spotify-selection"><span>{page ? `${page.total.toLocaleString()} items` : 'Spotify'} · {selected.size} selected</span><button disabled={!items.length || saving} onClick={selectVisible}>Select loaded</button><button disabled={!selected.size || saving} onClick={() => setSelected(new Map())}>Clear</button><button className="primary" disabled={!selected.size || saving} onClick={() => setReview(!review)}><Download size={17}/>Save locally</button></div>
    {review && <section className="spotify-review" aria-label="Review local download"><h2>Save {selected.size} selected items</h2><p>Playlists and albums include their songs. Downloads continue on your server when you close Spotified.</p><p className="hint">{[...selected.values()].map(item => item.name).join(' · ')}</p><AudioOptions values={options} onChange={(name,value) => setAudio({...options,[name]:value})}/><div className="form-actions"><button disabled={saving} onClick={() => setReview(false)}>Cancel</button><button className="primary" disabled={saving} onClick={save}>{saving ? 'Adding to queue…' : 'Add to download queue'}</button></div></section>}
    <div className="spotify-results" aria-busy={loading}>{items.map(item => <article className="spotify-row" key={item.uri}>
      {item.kind !== 'artist' && <input type="checkbox" aria-label={`Select ${item.name}`} checked={selected.has(item.uri)} disabled={!item.available || saving || (!selected.has(item.uri) && selected.size >= 200)} onChange={() => toggle(item)}/>}
      <div className="spotify-cover">{item.artwork ? <img src={item.artwork} alt="" loading="lazy" referrerPolicy="no-referrer"/> : <Music2 size={24}/>}</div>
      <div className="spotify-title"><strong>{item.name}</strong><small>{item.subtitle}{!item.available && ' · Unavailable'}</small></div>
      {['album','playlist','artist'].includes(item.kind) && item.available && <button aria-label={`Open ${item.name}`} disabled={saving} onClick={() => setTrail([...trail,item])}><ChevronRight size={18}/></button>}
    </article>)}</div>
    {loading && <p className="notice" role="status">Loading Spotify…</p>}
    {!loading && !error && !items.length && <div className="empty small"><Search size={36}/><p>{view === 'search' && !term ? 'Search Spotify, then choose what to save locally.' : 'No items found.'}</p></div>}
    {page?.next_offset != null && <button onClick={() => load(page.next_offset)} disabled={loading || saving}>Load more</button>}
    {selected.size >= 200 && <p className="hint">Save this selection before choosing more than 200 items.</p>}
  </div>;
}
