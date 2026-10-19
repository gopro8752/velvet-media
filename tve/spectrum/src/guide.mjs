import {BridgeError, providerError} from './http.mjs';

const ENDPOINT = 'https://pi-lite.spectrum.net/epgs/api/smarttv/guide/v4/twctv/grid';
const HOUR = 3600000;
const REFRESH = 15 * 60000;
const RETRY = 60000;
// The Rust adapter limits UTF-8 bytes. Keep complete code points at that same
// boundary, normalize lone surrogates, and remove the full Unicode Cc range.
const text = (value, limit) => {
  if (typeof value !== 'string') return '';
  const bytes = Buffer.from(value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').trim());
  let end = Math.min(bytes.length, limit);
  while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
  return bytes.subarray(0, end).toString('utf8').trimEnd();
};

// Station IDs come from the signed-in catalog, never fuzzy channel-name matches.
// This is a metadata-only operation: no tune, media lease or license is created.
export function normalizePrograms(items, guideId, start, end) {
  if (!Array.isArray(items) || items.length > 1000) throw new BridgeError();
  const programs = new Map();
  for (const item of items) {
    if (!item || String(item.tmsGuideId) !== guideId) continue;
    const title = text(item.title, 400), began = Number(item.startTimeSec) * 1000;
    const duration = Number(item.durationMinutes) * 60000, ended = began + duration;
    if (!title || !Number.isSafeInteger(began) || !Number.isSafeInteger(ended) || duration <= 0 || duration > 24 * HOUR || ended <= start || began >= end) continue;
    const id = text(item.tmsProgramId, 100);
    let imageUrl = null;
    try {
      const image = new URL(item.imageUrl, 'https://cdnimg.spectrum.net');
      image.search = ''; image.hash = '';
      if (typeof item.imageUrl === 'string' && image.origin === 'https://cdnimg.spectrum.net' && image.pathname.startsWith('/imageserver/program/') && !image.username && !image.password && image.href.length <= 2048) imageUrl = image.href;
    } catch {}
    const icons = Array.isArray(item.icons) ? item.icons : [];
    programs.set(began, {
      id: `spectrum:${guideId}:${Math.floor(began / 1000)}:${id}`,
      title, startTime: new Date(began).toISOString(), endTime: new Date(ended).toISOString(),
      description: text(item.shortDesc, 4000) || null,
      episodeTitle: text(item.metadata?.title, 400) || null,
      imageUrl, genres: Array.isArray(item.genres) ? [...new Set(item.genres.map(v => text(v, 80)).filter(Boolean))].slice(0, 12) : [],
      rating: text(item.rating, 32) || null, isLive: icons.includes('Live'), isNew: icons.includes('New'),
    });
  }
  return [...programs.values()].sort((a, b) => a.startTime.localeCompare(b.startTime)).slice(0, 160);
}

export function createGuide(provider, {now = Date.now} = {}) {
  let cache = null, loading = null, attempted = null, failed = false;
  async function window(ids, start, retry = true) {
    const auth = await provider.token(), url = new URL(ENDPOINT);
    url.searchParams.set('tmsIds', ids.join(','));
    url.searchParams.set('hours', '24');
    url.searchParams.set('startDateTime', Math.floor(start / 1000));
    const response = await provider.request({url, headers: {Authorization: `Bearer ${auth.accessToken}`, device_id: auth.deviceId}, maxBytes: 8 * 1024 * 1024, timeoutMs: 12000});
    if (response.status === 401 && retry) {
      if (provider.auth?.accessToken === auth.accessToken) await provider.refresh();
      return window(ids, start, false);
    }
    if (response.status !== 200) throw providerError(response.status, response.body);
    let value;
    try { value = JSON.parse(response.body); } catch { throw new BridgeError(); }
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length > 700) throw new BridgeError();
    return value;
  }
  async function refresh(entries) {
    const start = Math.floor(now() / HOUR) * HOUR;
    const end = start + 24 * HOUR;
    const ids = [...new Set(entries.map(e => e.guideId).filter(id => /^\d{1,12}$/.test(id)))];
    const programs = new Map(ids.map(id => [id, []]));
    for (let i = 0; i < ids.length; i += 350) {
        const batch = ids.slice(i, i + 350), value = await window(batch, start);
        for (const id of batch) {
          if (value[id] === undefined) continue;
          programs.get(id).push(...normalizePrograms(value[id], id, start, end));
        }
    }
    for (const [id, values] of programs) programs.set(id, [...new Map(values.map(p => [p.startTime, p])).values()].sort((a, b) => a.startTime.localeCompare(b.startTime)).slice(0, 160));
    if (![...programs.values()].some(values => values.length)) throw new BridgeError();
    cache = {at: now(), programs}; failed = false;
  }
  return {
    async snapshot(sourceName) {
      const entries = await provider.channels();
      const missingStation = cache && entries.some(e => /^\d{1,12}$/.test(e.guideId) && !cache.programs.has(e.guideId));
      if ((!cache || missingStation || now() - cache.at >= REFRESH) && (attempted === null || now() - attempted >= RETRY) && !loading) {
        attempted = now();
        loading = refresh(entries).catch(() => {failed = true;}).finally(() => {loading = null;});
      }
      // Keep browsing instant during refreshes; cached listings never outlive their end time.
      if (!cache && loading) await loading;
      const timestamp = new Date(now()).toISOString();
      // A reused channel/alias must never inherit the old station's schedule.
      const channels = entries.map(e => ({channelId: e.channel.id, programs: (cache?.programs.get(e.guideId) || []).filter(p => p.endTime > timestamp)}));
      return {enabled: true, sourceName, updatedAt: cache ? new Date(cache.at).toISOString() : null, channels,
        message: failed ? 'Spectrum guide refresh is temporarily unavailable; showing available listings.' : channels.some(c => !c.programs.length) ? 'Listings are unavailable for some channels.' : null};
    },
  };
}
