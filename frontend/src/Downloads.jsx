import React, {useState} from 'react';
import {Download, X, Link2, RotateCcw} from 'lucide-react';
import {api, formatName, qualityName} from './api';
import AudioOptions, {bitrateName} from './AudioOptions';

const restartable = ['cancelled', 'interrupted', 'failed', 'partial'];

export default function Downloads({jobs, settings, refresh, notify}) {
  const [urls, setUrls] = useState('');
  const [audio, setAudio] = useState(null);
  const options = audio || {format: settings?.format || 'copy', quality: settings?.quality || 'auto', bitrate: settings?.bitrate || 'best'};
  const [busy, setBusy] = useState(false);
  const [restarting, setRestarting] = useState(null);
  async function submit(preview) {
    setBusy(true);
    try { await api('/api/jobs', {urls, ...options, preview}); if (!preview) setUrls(''); await refresh(); }
    catch (e) { notify(e.message); } finally { setBusy(false); }
  }
  async function cancel(id) { try { await api(`/api/jobs/${id}/cancel`, {}); await refresh(); } catch (e) { notify(e.message); } }
  async function restart(id) {
    setRestarting(id);
    try { await api(`/api/jobs/${id}/restart`, {}); await refresh(); }
    catch (e) { notify(e.message); } finally { setRestarting(null); }
  }
  return <div className="page-body"><form className="download-form" onSubmit={e => {e.preventDefault(); submit(false);}}>
    <label htmlFor="links"><Link2 size={17}/>Spotify links</label>
    <textarea id="links" autoFocus rows={3} placeholder="Paste an album, playlist, artist, track, or podcast link" value={urls} onChange={e => setUrls(e.target.value)} required/>
    <AudioOptions values={options} onChange={(key,value) => setAudio({...options,[key]:value})}/><div className="form-actions download-actions"><div><button type="button" onClick={() => submit(true)} disabled={!urls.trim() || busy}>Preview</button><button className="primary" disabled={!urls.trim() || busy}><Download size={17}/>Add to queue</button></div></div>
    <p className="hint">Saved on the server in <code>{settings?.music_path}</code>. Preview checks metadata without downloading audio.</p>
  </form>
  <div className="section-heading"><h2>Download queue</h2><span>{jobs.filter(j => ['queued','running'].includes(j.status)).length} active</span></div>
  <p className="hint">Source links are saved with each job. Restart uses the same links and audio choices with your current library settings, skipping tracks already saved.</p>
  {!jobs.length ? <div className="empty small"><Download size={40}/><h2>Ready when you are</h2><p>Add a link to start your collection.</p></div> : jobs.map(job => {
    const activeRetry = jobs.some(j => j.restart_of === job.id && ['queued', 'running'].includes(j.status));
    return <article className="job" key={job.id}>
      <div className="job-heading"><strong>{job.names?.[0] || (job.kind === 'login' ? 'Spotify sign-in' : job.urls?.[0])}</strong><span className={`status ${job.status}`}>{job.status}</span>{['queued','running'].includes(job.status) && <button className="icon-button" onClick={() => cancel(job.id)} aria-label="Cancel job"><X size={18}/></button>}</div>
      <p>{job.message}</p>
      {job.login_url && job.status === 'running' && <a className="button primary" href={job.login_url} target="_blank" rel="noreferrer">Continue to Spotify</a>}
      <div className="job-meta">{job.preview ? 'Metadata preview' : formatName(job.format)}{job.quality && ` · Requested: ${qualityName(job.quality)}`}{job.format !== 'copy' && job.bitrate && job.bitrate !== 'auto' && ` · ${bitrateName(job.bitrate)}`} · {new Date(job.created_at).toLocaleString()}</div>
      {job.urls?.length > 0 && <div className="job-sources"><span>{job.urls.length === 1 ? 'Source link' : 'Source links'}</span>{job.urls.map(url => <a key={url} href={url} target="_blank" rel="noreferrer">{url}</a>)}</div>}
      {job.kind !== 'login' && job.urls?.length > 0 && restartable.includes(job.status) && <div className="job-actions"><button onClick={() => restart(job.id)} disabled={restarting === job.id || activeRetry} aria-label={job.preview ? 'Restart preview' : 'Restart download'}><RotateCcw size={15}/>{activeRetry ? 'Restart queued' : restarting === job.id ? 'Restarting…' : 'Restart'}</button></div>}
      {job.logs?.length > 0 && <details><summary>Activity details</summary><pre>{job.logs.join('\n')}</pre></details>}
    </article>;
  })}
  </div>;
}
