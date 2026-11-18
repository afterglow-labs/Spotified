import React, {useEffect, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {Library as LibraryIcon, Disc3, UserRound, ListMusic, Download, Settings as SettingsIcon, Plus, Circle, X, Server, Music2} from 'lucide-react';
import {api, signIn} from './api';
import Library from './Library';
import Downloads from './Downloads';
import Settings from './Settings';
import Spotify from './Spotify';
import './styles.css';

const sections = [['Library',LibraryIcon], ['Albums',Disc3], ['Artists',UserRound], ['Playlists',ListMusic], ['Spotify',Music2], ['Downloads',Download], ['Settings',SettingsIcon]];
function Login({connected, notify}) {
  const [username, setUsername] = useState('corey');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  return <div className="login-page"><form onSubmit={async e => {e.preventDefault();setBusy(true);try {await signIn(username,password);setPassword('');connected();} catch (err) {notify(err.message);} finally {setBusy(false);}}}><Music2 size={42}/><h1>Spotified</h1><p>by Afterglow Labs</p><h2>Connect to your music</h2><label>Username<input autoComplete="username" value={username} onChange={e => setUsername(e.target.value)} required/></label><label>Password<input type="password" autoComplete="current-password" value={password} onChange={e => setPassword(e.target.value)} required/></label><button className="primary" disabled={busy}>{busy ? 'Connecting…' : 'Sign in'}</button><small>{location.host}</small></form></div>;
}
function App() {
  const [view, setView] = useState('Library');
  const [state, setState] = useState(null);
  const [library, setLibrary] = useState(null);
  const [settings, setSettings] = useState(null);
  const [error, setError] = useState('');
  const [loggedOut, setLoggedOut] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [track, setTrack] = useState(null);
  const [online, setOnline] = useState(true);
  async function refresh() {try {const next = await api('/api/state');setState(next);setOnline(true);setLoggedOut(false);return next;} catch (e) {if (e.status === 401) {if (window.webkit?.messageHandlers?.connection) window.webkit.messageHandlers.connection.postMessage('reauth'); else setLoggedOut(true);} else setOnline(false);}}
  async function scan() {setScanning(true);try {setLibrary(await api('/api/files'));} catch (e) {setError(e.message);} finally {setScanning(false);}}
  async function boot() {const next = await refresh();if (next) {try {setSettings(await api('/api/settings'));await scan();} catch (e) {setError(e.message);}}}
  useEffect(() => {boot();const interval = setInterval(refresh, 2500);return () => clearInterval(interval);}, []);
  const finished = state?.jobs?.filter(j => ['completed','partial'].includes(j.status)).length || 0;
  useEffect(() => {if (state) scan();}, [finished]);
  const navigate = target => {setView(target);setError('');};
  const subtitles = {Spotify:'Your Spotify, ready to bring home.', Library:'Your music, organized.', Albums:'Every album in your collection.', Artists:'Find your favorite voices.', Playlists:'Your playlists, ready to play.', Downloads:'Bring your music home.', Settings:'Make this collection yours.'};
  return <>{loggedOut ? <Login connected={boot} notify={setError}/> : <div className="app-shell"><aside><div className="brand"><strong>Spotified</strong><span>by Afterglow Labs</span></div><nav aria-label="Main navigation">{sections.map(([name,Icon],i) => <React.Fragment key={name}>{i === 4 && <hr/>}<button aria-label={name} aria-current={view === name ? 'page' : undefined} className={view === name ? 'selected' : ''} onClick={() => navigate(name)}><Icon size={20} strokeWidth={1.7}/><span>{name}</span>{name === 'Downloads' && state?.jobs?.some(j => ['queued','running'].includes(j.status)) && <span className="queue-dot"/>}</button></React.Fragment>)}</nav><button className="server-status" onClick={() => navigate('Settings')}><Circle size={9} className={online && state ? 'online' : 'offline'}/><span>{state?.server || 'Connecting…'}<small>{online ? state?.account?.status === 'connected' ? 'Spotify connected' : state?.account?.status === 'checking' ? 'Checking Spotify…' : 'Spotify needs attention' : 'Server disconnected'}</small></span></button></aside><main><header><div><h1>{view}</h1><p>{subtitles[view]}</p></div>{!['Downloads','Settings','Spotify'].includes(view) && <button className="primary" onClick={() => navigate('Downloads')}><Plus size={18}/>Add music</button>}</header>{!online && <div className="notice error"><Server size={18}/>The server is unavailable. Retrying automatically.<button onClick={boot}>Retry</button>{window.webkit?.messageHandlers?.connection && <button onClick={() => window.webkit.messageHandlers.connection.postMessage('open')}>Change server</button>}</div>}{view === 'Spotify' ? <Spotify settings={settings} refresh={refresh} notify={setError}/> : view === 'Downloads' ? <Downloads jobs={state?.jobs || []} settings={settings} refresh={refresh} notify={setError}/> : view === 'Settings' ? settings && <Settings settings={settings} account={state?.account} server={state?.server} onSaved={setSettings} notify={setError} onDownloads={() => {refresh();navigate('Downloads');}}/> : <Library key={view} view={view} data={library} refresh={scan} busy={scanning} addMusic={() => navigate('Downloads')} onPlay={setTrack}/>}</main>{track && <div className="player"><div><strong>{track.title}</strong><small>{track.artist}</small></div><audio key={track.id} src={track.href} controls autoPlay onError={() => setError('This audio format could not be played. Download the file to play it in another player, or choose MP3 for future downloads.')}/><button className="icon-button" onClick={() => setTrack(null)} aria-label="Close player"><X size={18}/></button></div>}</div>}{error && <div className="toast" role="alert"><span>{error}</span><button className="icon-button" aria-label="Dismiss message" onClick={() => setError('')}><X size={18}/></button></div>}</>;
}
createRoot(document.getElementById('root')).render(<App/>);
