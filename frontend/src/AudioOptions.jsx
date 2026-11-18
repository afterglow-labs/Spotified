import React from 'react';
import {formatName, qualityName} from './api';

export const qualities = ['auto', 'normal', 'high', 'very_high'];
export const bitrates = ['best', 'auto', '96k', '128k', '160k', '192k', '256k', '320k'];
export const bitrateName = value => value === 'best' ? 'Best quality for this format' : value === 'auto' ? 'Follow source-quality target' : `${value.slice(0,-1)} kbps`;

export default function AudioOptions({values, onChange, defaults=false}) {
  return <div className="audio-options">
    <label>{defaults ? 'Default audio format' : 'Format'}<select aria-label={defaults ? 'Default audio format' : 'Format'} value={values.format} onChange={e => onChange('format', e.target.value)}>{['copy','mp3','aac','opus'].map(f => <option key={f} value={f}>{formatName(f)}</option>)}</select></label>
    <label>Source quality<select aria-label="Source quality" value={values.quality} onChange={e => onChange('quality', e.target.value)}>{qualities.map(q => <option key={q} value={q}>{qualityName(q)}</option>)}</select></label>
    <label>Encoding quality<select aria-label="Encoding quality" value={values.bitrate} disabled={values.format === 'copy'} onChange={e => onChange('bitrate', e.target.value)}>{bitrates.map(b => <option key={b} value={b}>{bitrateName(b)}</option>)}</select></label>
  </div>;
}
