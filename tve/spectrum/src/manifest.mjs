import { randomBytes } from 'node:crypto';
import { BridgeError, cdnUrl } from './http.mjs';

const LIMIT = Object.freeze({ bytes: 2 * 1024 * 1024, resources: 4096, templates: 256,
  keys: 256, references: 4096, nodes: 20000, depth: 64, grace: 120000 });
const KINDS = new Set(['dash', 'hls', 'segment']);
const UINT = /^(?:0|[0-9]{1,20})$/;
const U64 = 18446744073709551615n;
const fail = () => { throw new BridgeError('source_unavailable', 503); };
const badResource = () => { throw new BridgeError('session_ended', 404); };

function unsigned(value) {
  if (!UINT.test(value) || BigInt(value) > U64) fail();
  return BigInt(value);
}
function text(bytes) {
  if (!Buffer.isBuffer(bytes)) bytes = Buffer.from(bytes);
  if (!bytes.length || bytes.length > LIMIT.bytes) fail();
  let value;
  try { value = new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { fail(); }
  if (/[\0-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)) fail();
  return value.replace(/^\uFEFF/, '');
}
function xmlDecode(value) {
  let at = 0, result = '';
  while (at < value.length) {
    const found = value.indexOf('&', at);
    if (found < 0) return result + value.slice(at);
    result += value.slice(at, found);
    const match = /^&([a-z]{2,4}|#[0-9]{1,10}|#x[0-9a-fA-F]{1,8});/.exec(value.slice(found, found + 16));
    if (!match) fail();
    const named = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>' };
    if (Object.hasOwn(named, match[1])) result += named[match[1]];
    else {
      if (match[1][0] !== '#') fail();
      const point = match[1][1] === 'x' ? Number.parseInt(match[1].slice(2), 16) : Number(match[1].slice(1));
      if (!Number.isInteger(point) || point > 0x10ffff || point === 0 ||
          (point < 32 && ![9, 10, 13].includes(point)) || (point >= 0xd800 && point <= 0xdfff)) fail();
      result += String.fromCodePoint(point);
    }
    at = found + match[0].length;
  }
  return result;
}
const xmlEncode = value => String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// A bounded XML indexer, not an external-entity-capable DOM. Edits are applied to
// source ranges so ContentProtection/PSSH data are never reserialized or changed.
function parseXml(source) {
  if (/<!DOCTYPE|<!ENTITY/i.test(source)) fail();
  const roots = [], nodes = [], stack = [];
  const name = /^[A-Za-z_][A-Za-z0-9_.:-]*/;
  let at = 0;
  while (at < source.length) {
    if (source[at] !== '<') {
      const end = source.indexOf('<', at);
      const chunk = source.slice(at, end < 0 ? source.length : end);
      xmlDecode(chunk);
      if (!stack.length && chunk.trim()) fail();
      at = end < 0 ? source.length : end; continue;
    }
    if (source.startsWith('<!--', at)) {
      const end = source.indexOf('-->', at + 4);
      if (end < 0 || source.slice(at + 4, end).includes('--')) fail();
      at = end + 3; continue;
    }
    if (source.startsWith('<![CDATA[', at)) {
      const end = source.indexOf(']]>', at + 9);
      if (!stack.length || end < 0) fail();
      at = end + 3; continue;
    }
    if (source.startsWith('<?', at)) {
      const end = source.indexOf('?>', at + 2);
      if (at !== 0 || end < 0 || !/^<\?xml\s/.test(source.slice(at, end))) fail();
      at = end + 2; continue;
    }
    if (source.startsWith('</', at)) {
      const close = /^<\/([A-Za-z_][A-Za-z0-9_.:-]*)\s*>/.exec(source.slice(at));
      const node = stack.pop();
      if (!close || !node || node.name !== close[1]) fail();
      node.closeStart = at; node.end = at + close[0].length;
      at = node.end; continue;
    }
    const start = at++;
    const match = name.exec(source.slice(at));
    if (!match) fail();
    const node = { name: match[0], local: match[0].split(':').at(-1), start,
      attrs: new Map(), children: [], parent: stack.at(-1) };
    at += match[0].length;
    while (at < source.length) {
      const ws = /^\s*/.exec(source.slice(at))[0]; at += ws.length;
      if (source.startsWith('/>', at)) { node.selfClosing = true; at += 2; break; }
      if (source[at] === '>') { at++; break; }
      if (!ws) fail();
      const attr = name.exec(source.slice(at));
      if (!attr || node.attrs.has(attr[0]) || node.attrs.size >= 64) fail();
      at += attr[0].length;
      const equal = /^\s*=\s*(["'])/.exec(source.slice(at));
      if (!equal) fail();
      at += equal[0].length;
      const valueStart = at, end = source.indexOf(equal[1], at);
      if (end < 0 || end - at > 32768 || source.slice(at, end).includes('<')) fail();
      const value = xmlDecode(source.slice(at, end));
      node.attrs.set(attr[0], { name: attr[0], value, start: valueStart, end });
      at = end + 1;
    }
    if (at > source.length || source[at - 1] !== '>') fail();
    node.openEnd = at;
    if (node.selfClosing) { node.closeStart = at; node.end = at; }
    (node.parent ? node.parent.children : roots).push(node); nodes.push(node);
    if (nodes.length > LIMIT.nodes) fail();
    if (!node.selfClosing) { stack.push(node); if (stack.length > LIMIT.depth) fail(); }
  }
  if (stack.length || roots.length !== 1 || roots[0].local !== 'MPD') fail();
  return { root: roots[0], nodes };
}
function xmlText(source, node) {
  if (node.children.length || node.selfClosing) fail();
  return xmlDecode(source.slice(node.openEnd, node.closeStart).replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g,
    (_, value) => xmlEncode(value))).trim();
}
function within(node, local) {
  for (let at = node; at; at = at.parent) if (at.local === local) return true;
  return false;
}
function applyEdits(source, edits) {
  edits.sort((a, b) => a.start - b.start || a.end - b.end);
  let at = 0, result = '';
  for (const edit of edits) {
    if (edit.start < at) fail();
    result += source.slice(at, edit.start) + edit.value; at = edit.end;
  }
  return Buffer.from(result + source.slice(at));
}

function hlsAttributes(value) {
  const result = new Map(); let at = 0;
  while (at < value.length) {
    const name = /^([A-Z0-9-]+)=/.exec(value.slice(at));
    if (!name || result.has(name[1])) fail();
    at += name[0].length;
    const quoted = value[at] === '"', start = at + (quoted ? 1 : 0);
    let end = quoted ? value.indexOf('"', start) : value.indexOf(',', start);
    if (!quoted && end < 0) end = value.length;
    if (end < 0 || end === start || /[\r\n]/.test(value.slice(start, end))) fail();
    result.set(name[1], { value: value.slice(start, end), start, end, quoted });
    at = end + (quoted ? 1 : 0);
    if (at < value.length) { if (value[at] !== ',' || at + 1 === value.length) fail(); at++; }
  }
  return result;
}
function fairPlayKey(uri) {
  // Spectrum currently advertises skds://; skd:// is also a standard FPS form.
  // Both remain opaque metadata here, never network fetch destinations.
  if (!/^skds?:\/\//i.test(uri) || uri.length > 8192 || /[\x00-\x20\x7f#\\"]/.test(uri)) fail();
  const queryAt = uri.indexOf('?');
  if (queryAt < 7) fail();
  const query = uri.slice(queryAt + 1);
  const values = query.split('&').filter(field => /^ContentId=/i.test(field))
    .map(field => field.slice(field.indexOf('=') + 1));
  if (values.length !== 1 || !values[0] || Buffer.byteLength(values[0]) > 200 ||
      [...new URLSearchParams(query).keys()].some(key => /^(?:streamSessionId|contentType)$/i.test(key))) fail();
  return { query, contentId: values[0] };
}

export function createMediaRegistry({ id, format, extraHosts = [], now = Date.now } = {}) {
  if (!/^[a-f0-9]{48}$/.test(id || '') || !['widevine', 'fairplay'].includes(format) ||
      typeof now !== 'function' || !Array.isArray(extraHosts) || extraHosts.length > 32 ||
      extraHosts.some(host => typeof host !== 'string' || !/^(?:\*\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(host))) fail();
  const prefix = `/live/streams/${id}/`;
  let state = { resources: new Map(), resourceIndex: new Map(), templates: new Map(), templateIndex: new Map(),
    keys: new Map(), keyIndex: new Map() };
  const time = () => { const value = now(); if (!Number.isFinite(value)) fail(); return value; };
  const copy = () => Object.fromEntries(Object.entries(state).map(([name, entries]) =>
    [name, new Map([...entries].map(([key, value]) => [key, typeof value === 'object' ? { ...value } : value]))]));
  const url = (value, base) => {
    if (typeof value !== 'string' && !(value instanceof URL)) fail();
    const raw = String(value);
    if (raw.length > 16384 || /[\x00-\x20\x7f\\]/.test(raw) || raw.includes('{$')) fail();
    try { return cdnUrl(base ? new URL(raw, base) : raw, extraHosts).href; } catch { fail(); }
  };
  function room(map, index, maximum, stamp) {
    if (map.size < maximum) return;
    let oldest;
    for (const [key, entry] of map) {
      // A master can be read once while its unselected ABR renditions remain
      // usable much later. Never expire those manifest capabilities as segments.
      if (entry.kind && entry.kind !== 'segment') continue;
      if (stamp - entry.seen >= LIMIT.grace && (!oldest || entry.seen < oldest[1].seen)) oldest = [key, entry];
    }
    if (!oldest) fail();
    map.delete(oldest[0]); index.delete(oldest[1].identity);
  }
  function registerInto(target, value, kind, stamp) {
    if (!KINDS.has(kind)) fail();
    const upstream = url(value), identity = kind + '\0' + upstream;
    const existing = target.resourceIndex.get(identity);
    if (existing) { target.resources.get(existing).seen = stamp; return existing; }
    room(target.resources, target.resourceIndex, LIMIT.resources, stamp);
    const key = randomBytes(16).toString('hex') + ({ dash: '.mpd', hls: '.m3u8', segment: '.bin' })[kind];
    target.resources.set(key, { url: upstream, kind, identity, seen: stamp }); target.resourceIndex.set(identity, key);
    return key;
  }
  function keyInto(target, uri, stamp) {
    if (format !== 'fairplay') fail();
    const data = fairPlayKey(uri), identity = uri;
    let reference = target.keyIndex.get(identity);
    if (reference) target.keys.get(reference).seen = stamp;
    else {
      room(target.keys, target.keyIndex, LIMIT.keys, stamp);
      reference = randomBytes(16).toString('hex');
      target.keys.set(reference, { ...data, identity, seen: stamp }); target.keyIndex.set(identity, reference);
    }
    return `skd://velvet/${reference}?ContentId=${data.contentId}`;
  }
  function templateInto(target, template, base, representation, stamp) {
    if (typeof template !== 'string' || template.length > 16384 || template.includes('__VELVET_DASH_')) fail();
    const variables = [];
    let literal = '', at = 0;
    while (at < template.length) {
      if (template[at] !== '$') { literal += template[at++]; continue; }
      if (template[at + 1] === '$') { literal += '$'; at += 2; continue; }
      const end = template.indexOf('$', at + 1);
      if (end < 0) fail();
      const token = template.slice(at + 1, end);
      const match = /^(RepresentationID|Bandwidth|Time|Number)(?:%0([1-9][0-9]?)d)?$/.exec(token);
      if (!match || (match[2] && (match[1] === 'RepresentationID' || Number(match[2]) > 20))) fail();
      const width = Number(match[2] || 0);
      if (match[1] === 'RepresentationID') {
        const value = representation.attrs.get('id')?.value;
        // Spectrum's actual IDs include '=' (for example audio=128000).
        // No slash, percent escape, query separator or authority delimiter is allowed.
        if (!value || !/^[A-Za-z0-9_-][A-Za-z0-9_.:=-]{0,127}$/.test(value) || value.includes('..')) fail();
        literal += value;
      } else if (match[1] === 'Bandwidth') {
        const value = representation.attrs.get('bandwidth')?.value;
        if (!value) fail();
        literal += unsigned(value).toString().padStart(width, '0');
      } else {
        if (variables.length >= 8) fail();
        const marker = `__VELVET_DASH_${variables.length}__`;
        variables.push({ name: match[1], width, marker, token: `$${token}$` }); literal += marker;
      }
      at = end + 1;
    }
    const upstream = url(literal, base);
    if (!variables.length) return prefix + registerInto(target, upstream, 'segment', stamp);
    const parsed = new URL(upstream);
    if (variables.some(v => parsed.hostname.includes(v.marker.toLowerCase()) || !upstream.includes(v.marker))) fail();
    const identity = JSON.stringify([upstream, variables.map(v => [v.name, v.width])]);
    let reference = target.templateIndex.get(identity);
    if (reference) target.templates.get(reference).seen = stamp;
    else {
      room(target.templates, target.templateIndex, LIMIT.templates, stamp);
      reference = randomBytes(16).toString('hex');
      target.templates.set(reference, { url: upstream, variables, identity, seen: stamp }); target.templateIndex.set(identity, reference);
    }
    return prefix + 't' + reference + variables.map(v => '-' + v.token).join('') + '.bin';
  }

  function rewriteHls(source, base, target, stamp) {
    if (format !== 'fairplay' || !/^#EXTM3U(?:\r?\n|$)/.test(source)) fail();
    const lines = source.split(/\r?\n/);
    if (lines.length > 32768) fail();
    let pending = false, references = 0;
    const isMaster = lines.some(line => line.startsWith('#EXT-X-STREAM-INF:'));
    const registerRef = (value, kind) => {
      if (++references > LIMIT.references) fail();
      return prefix + registerInto(target, url(value, base), kind, stamp);
    };
    const tags = new Map([['EXT-X-MAP', 'segment'], ['EXT-X-MEDIA', 'hls'], ['EXT-X-I-FRAME-STREAM-INF', 'hls'],
      ['EXT-X-IMAGE-STREAM-INF', 'hls'], ['EXT-X-PART', 'segment'], ['EXT-X-PRELOAD-HINT', 'segment'], ['EXT-X-RENDITION-REPORT', 'hls']]);
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index];
      if (line.length > 32768) fail();
      if (!line || line === '#EXTM3U') continue;
      if (!line.startsWith('#')) {
        if (isMaster && !pending) fail();
        lines[index] = registerRef(line, pending ? 'hls' : 'segment'); pending = false; continue;
      }
      if (line.startsWith('#EXT-X-DEFINE:') || line.startsWith('#EXT-X-CONTENT-STEERING:')) fail();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        if (pending) fail();
        const attrs = hlsAttributes(line.slice('#EXT-X-STREAM-INF:'.length));
        if ([...attrs.keys()].some(name => name.includes('URI') || name === 'URL')) fail();
        pending = true; continue;
      }
      const colon = line.indexOf(':');
      if (colon < 0) continue;
      const tag = line.slice(1, colon);
      const isKey = tag === 'EXT-X-KEY' || tag === 'EXT-X-SESSION-KEY';
      if (!tags.has(tag) && !isKey) {
        if (/(?:^|,)(?:[A-Z0-9-]*URI|URL)=/.test(line.slice(colon + 1))) fail();
        continue;
      }
      const attrs = hlsAttributes(line.slice(colon + 1)), uri = attrs.get('URI');
      if ([...attrs.keys()].some(name => name !== 'URI' && (name.endsWith('URI') || name === 'URL'))) fail();
      if (!uri) {
        if ((tag === 'EXT-X-MEDIA' && ['CLOSED-CAPTIONS', 'AUDIO', 'VIDEO'].includes(attrs.get('TYPE')?.value)) ||
            (isKey && attrs.get('METHOD')?.value === 'NONE')) continue;
        fail();
      }
      if (!uri.quoted) fail();
      let replacement;
      if (isKey) {
        const method = attrs.get('METHOD')?.value, keyFormat = attrs.get('KEYFORMAT')?.value;
        if (method === 'SAMPLE-AES' && keyFormat === 'com.apple.streamingkeydelivery') {
          if (++references > LIMIT.references) fail();
          replacement = keyInto(target, uri.value, stamp);
        } else if (method === 'AES-128' && (!keyFormat || keyFormat === 'identity')) replacement = registerRef(uri.value, 'segment');
        else fail();
      } else replacement = registerRef(uri.value, tags.get(tag));
      lines[index] = line.slice(0, colon + 1 + uri.start) + replacement + line.slice(colon + 1 + uri.end);
    }
    if (pending) fail();
    return Buffer.from(lines.join('\n'));
  }

  function rewriteDash(source, manifestUrl, target, stamp) {
    if (format !== 'widevine') fail();
    const { nodes } = parseXml(source), edits = [], bases = new Map();
    const descriptors = new Set(['SegmentTemplate', 'SegmentList', 'SegmentBase']);
    const isDescriptor = node => descriptors.has(node.local);
    const registerRef = (value, kind, base) => prefix + registerInto(target, url(value, base), kind, stamp);
    function baseFor(node) {
      if (bases.has(node)) return bases.get(node);
      let base = node.parent ? baseFor(node.parent) : manifestUrl;
      const choices = node.children.filter(child => child.local === 'BaseURL');
      if (choices.length > 8) fail();
      // BaseURL alternatives are equivalent transport choices; use the first one
      // from the manifest, and require every advertised choice to be an allowed CDN.
      for (let index = choices.length - 1; index >= 0; index--) {
        const candidate = url(xmlText(source, choices[index]), base);
        if (index === 0) base = candidate;
      }
      bases.set(node, base); return base;
    }
    function renderDescriptor(node, rep) {
      const chain = [];
      for (let ancestor = rep; ancestor; ancestor = ancestor.parent) {
        const choices = ancestor.children.filter(isDescriptor);
        if (choices.length > 1) fail();
        if (choices.length && choices[0].local !== node.local) break;
        if (choices.length) chain.unshift(choices[0]);
      }
      const attrs = new Map(); let children = [];
      for (const current of chain) {
        for (const [name, value] of current.attrs) attrs.set(name, value.value);
        if (current.local === 'SegmentList') {
          for (const child of current.children) if (!['SegmentTimeline', 'Initialization', 'SegmentURL', 'RepresentationIndex', 'BitstreamSwitching'].includes(child.local)) fail();
          const groups = new Set(current.children.map(child => child.local));
          children = children.filter(child => !groups.has(child.local)).concat(current.children);
        } else {
          for (const child of current.children) if (!['SegmentTimeline', 'Initialization', 'RepresentationIndex', 'BitstreamSwitching'].includes(child.local)) fail();
          const groups = new Set(current.children.map(child => child.local));
          children = children.filter(child => !groups.has(child.local)).concat(current.children);
        }
      }
      const base = baseFor(rep);
      if (node.local === 'SegmentTemplate') {
        if (!attrs.has('media')) fail();
        for (const name of ['media', 'initialization', 'index', 'bitstreamSwitching'])
          if (attrs.has(name)) attrs.set(name, templateInto(target, attrs.get(name), base, rep, stamp));
      }
      const renderedChildren = children.map(child => {
        if (child.local === 'SegmentTimeline') return source.slice(child.start, child.end);
        if (child.children.length) fail();
        const values = [...child.attrs].map(([name, attr]) => {
          const value = ['sourceURL', 'media', 'index'].includes(name) ? registerRef(attr.value, 'segment', base) : attr.value;
          return ` ${name}="${xmlEncode(value)}"`;
        }).join('');
        return `<${child.name}${values}/>`;
      }).join('');
      return `<${node.name}${[...attrs].map(([name, value]) => ` ${name}="${xmlEncode(value)}"`).join('')}>${renderedChildren}</${node.name}>`;
    }
    const representations = nodes.filter(node => node.local === 'Representation' && !within(node, 'ContentProtection'));
    if (!representations.length || representations.length > 256) fail();
    for (const node of nodes) {
      if (within(node, 'ContentProtection')) continue;
      if ([...node.attrs].some(([name]) => name === 'xml:base' || name === 'href' || name.endsWith(':href'))) fail();
      const urlAttributes = { SegmentTemplate: ['media', 'initialization', 'index', 'bitstreamSwitching'],
        SegmentURL: ['media', 'index'], Initialization: ['sourceURL'], RepresentationIndex: ['sourceURL'], BitstreamSwitching: ['sourceURL'] };
      for (const [name] of node.attrs) {
        if (['sourceURL', 'media', 'index', 'initialization', 'bitstreamSwitching', 'src', 'url'].includes(name) &&
            !urlAttributes[node.local]?.includes(name)) fail();
      }
      if (node.local === 'SegmentTimeline' && node.children.some(child => child.local !== 'S')) fail();
      if (node.local === 'UTCTiming' && /^https?:/.test(node.attrs.get('value')?.value || '')) fail();
      if (node.local === 'BaseURL' || isDescriptor(node)) {
        if (!node.parent || within(node.parent, 'SegmentTemplate') || within(node.parent, 'SegmentList') || within(node.parent, 'SegmentBase')) fail();
        edits.push({ start: node.start, end: node.end, value: '' });
      } else if (node.local === 'Location' || node.local === 'PatchLocation') {
        if (node.local === 'PatchLocation') fail();
        edits.push({ start: node.openEnd, end: node.closeStart, value: xmlEncode(registerRef(xmlText(source, node), 'dash', baseFor(node.parent))) });
      }
    }
    for (const rep of representations) {
      let descriptor;
      for (let ancestor = rep; ancestor && !descriptor; ancestor = ancestor.parent) descriptor = ancestor.children.find(isDescriptor);
      let inserted = descriptor ? renderDescriptor(descriptor, rep) : '';
      if (!descriptor || descriptor.local === 'SegmentBase') {
        const base = baseFor(rep);
        if (new URL(base).pathname.endsWith('/')) fail();
        const prefixName = rep.name.includes(':') ? rep.name.slice(0, rep.name.indexOf(':') + 1) : '';
        inserted = `<${prefixName}BaseURL>${xmlEncode(registerRef(base, 'segment'))}</${prefixName}BaseURL>` + inserted;
      }
      if (rep.selfClosing) edits.push({ start: rep.start, end: rep.end,
        value: source.slice(rep.start, rep.openEnd - 2) + '>' + inserted + `</${rep.name}>` });
      else edits.push({ start: rep.openEnd, end: rep.openEnd, value: inserted });
    }
    return applyEdits(source, edits);
  }

  return Object.freeze({
    register(value, kind) { return registerInto(state, value, kind, time()); },
    rewrite(bytes, finalUpstreamURL, kind) {
      const source = text(bytes), base = url(finalUpstreamURL), next = copy(), stamp = time();
      const result = kind === 'dash' ? rewriteDash(source, base, next, stamp) :
        kind === 'hls' ? rewriteHls(source, base, next, stamp) : fail();
      if (result.length > LIMIT.bytes * 2) fail();
      state = next; return result;
    },
    resolve(key) {
      if (typeof key !== 'string' || key.length > 240) badResource();
      const stamp = time();
      const resource = state.resources.get(key);
      if (resource) { resource.seen = stamp; return { url: resource.url, kind: resource.kind }; }
      const match = /^t([a-f0-9]{32})((?:-[0-9]{1,20}){1,8})\.bin$/.exec(key);
      const template = match && state.templates.get(match[1]);
      if (!template) badResource();
      const values = match[2].slice(1).split('-'), bindings = new Map();
      if (values.length !== template.variables.length) badResource();
      let upstream = template.url;
      try {
        for (let index = 0; index < values.length; index++) {
          const spec = template.variables[index], number = unsigned(values[index]);
          if (bindings.has(spec.name) && bindings.get(spec.name) !== number) badResource();
          bindings.set(spec.name, number);
          upstream = upstream.replace(spec.marker, number.toString().padStart(spec.width, '0'));
        }
        upstream = url(upstream);
      } catch { badResource(); }
      template.seen = stamp; return { url: upstream, kind: 'segment' };
    },
    key(reference) {
      const entry = typeof reference === 'string' && state.keys.get(reference);
      if (!entry) return undefined;
      entry.seen = time(); return { query: entry.query, contentId: entry.contentId };
    },
  });
}
