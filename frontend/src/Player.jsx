import React, {useRef, useState} from 'react';
import {SkipBack, SkipForward, X} from 'lucide-react';

export default function Player({playback, onPlay, onClose, notify}) {
  const {tracks, index, revision} = playback;
  const track = tracks[index];
  const audio = useRef(null);
  const [canRestart, setCanRestart] = useState(false);
  const hasNext = index + 1 < tracks.length;

  function previous() {
    if (audio.current.currentTime > 3) audio.current.currentTime = 0;
    else if (index > 0) onPlay(tracks, index - 1);
  }
  function next() {
    if (hasNext) onPlay(tracks, index + 1);
  }

  return <div className="player" aria-label="Music player">
    <div className="playing-track"><strong>{track.title}</strong><small>{track.artist}</small></div>
    <span className="transport">
      <button className="icon-button" aria-label="Previous song" title="Previous song" disabled={index === 0 && !canRestart} onClick={previous}><SkipBack size={20}/></button>
      <button className="icon-button" aria-label="Next song" title="Next song" disabled={!hasNext} onClick={next}><SkipForward size={20}/></button>
    </span>
    <audio key={revision} ref={audio} src={track.href} controls autoPlay onEnded={next}
      onLoadedMetadata={() => setCanRestart(false)} onTimeUpdate={e => setCanRestart(e.currentTarget.currentTime > 3)}
      onError={() => notify('This audio format could not be played. Download the file to play it in another player, or choose MP3 for future downloads.')}/>
    <button className="icon-button" onClick={onClose} aria-label="Close player"><X size={18}/></button>
  </div>;
}
