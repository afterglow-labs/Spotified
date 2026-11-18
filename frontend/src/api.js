let csrf = '';
export async function api(path, body) {
  const response = await fetch(path, {headers: {'Content-Type': 'application/json', 'X-Spotified-Token': csrf},
    ...(body !== undefined ? {method: 'POST', body: JSON.stringify(body)} : {})});
  const data = await response.json();
  if (!response.ok) { const error = new Error(data.error || 'The server could not complete this request.'); error.status = response.status; throw error; }
  if (data.csrf_token) csrf = data.csrf_token;
  return data;
}
export async function signIn(username, password) {
  const bytes = new TextEncoder().encode(`${username}:${password}`);
  const response = await fetch('/api/session', {method: 'POST', headers: {Authorization: `Basic ${btoa(String.fromCharCode(...bytes))}`}});
  const data = await response.json();
  if (!response.ok) throw new Error(data.error);
}
export const formatName = value => ({copy: 'Original audio', mp3: 'MP3', aac: 'AAC', opus: 'Opus'}[value] || value);
export const qualityName = value => ({auto: 'Auto · Best available', normal: 'Normal · 96 kbps', high: 'High · 160 kbps', very_high: 'Very high · 320 kbps'}[value] || value);
export const time = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
