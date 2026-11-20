/**
 * csUtils: shared helpers for the Candidate Search components (no template).
 *
 * - normalizeError: same handling as amplifyRecordEnrichmentPanel (body.message, pageErrors, fieldErrors, arrays).
 * - prettyXmlLines: same formatter as the callListMatchViewer request viewer.
 * - Criteria helpers: labels for kinds and weights, chip ids, met / not met per row, rank change tags.
 */

export const PAGE_SIZE = 20;
export const EXPLAIN_BATCH = 10;
export const COMPARE_MIN = 2;
export const COMPARE_MAX = 4;

export const WEIGHTS = [
    { value: 'required', label: 'Must have', short: 'Must' },
    { value: 'strongly_preferred', label: 'Strongly preferred', short: 'Strong' },
    { value: 'preferred', label: 'Nice to have', short: 'Nice' },
    { value: 'excluded', label: 'Exclude', short: 'Exclude' }
];

/** Kinds a recruiter can add by hand. fingerprint and tk_raw only come from a job document. */
export const ADDABLE_KINDS = [
    { value: 'title', label: 'Job title' },
    { value: 'skill', label: 'Skill' },
    { value: 'certification', label: 'Certification' },
    { value: 'location', label: 'Location' },
    { value: 'keyword', label: 'Keyword' },
    { value: 'language', label: 'Language' },
    { value: 'shift', label: 'Shift' },
    { value: 'availability', label: 'Available within (days)' }
];

const KIND_LABELS = {
    title: 'Title',
    skill: 'Skill',
    certification: 'Certification',
    location: 'Location',
    keyword: 'Keyword',
    language: 'Language',
    shift: 'Shift',
    availability: 'Availability',
    fingerprint: 'Job description',
    tk_raw: 'Textkernel'
};

const FACET_LABELS = {
    candidate_status: 'Status',
    owner_name: 'Owner',
    owner_id: 'Owner',
    city: 'City',
    jobtitles: 'Job titles',
    recent_jobtitles: 'Recent titles',
    it_skills: 'IT skills',
    profskills: 'Skills',
    languages: 'Languages'
};

export const READ_ONLY_KINDS = new Set(['fingerprint', 'tk_raw']);

export function kindLabel(kind) {
    return KIND_LABELS[kind] || kind || '';
}

export function weightLabel(weight) {
    const w = WEIGHTS.find((x) => x.value === weight);
    return w ? w.label : weight || '';
}

export function weightShort(weight) {
    const w = WEIGHTS.find((x) => x.value === weight);
    return w ? w.short : weight || '';
}

export function facetLabel(field) {
    if (FACET_LABELS[field]) return FACET_LABELS[field];
    return String(field || '')
        .replace(/_/g, ' ')
        .replace(/^\w/, (c) => c.toUpperCase());
}

export function clone(o) {
    return o === undefined ? undefined : JSON.parse(JSON.stringify(o));
}

export function sleep(ms) {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Next free chip id (c + number), above every id already used. */
export function nextChipId(criteria) {
    let max = 0;
    ((criteria && criteria.items) || []).forEach((it) => {
        const m = /^c(\d+)$/.exec(it.id || '');
        if (m) max = Math.max(max, Number(m[1]));
    });
    return `c${max + 1}`;
}

/** Criteria copy without the trace (the trace only travels on the first runSearch after parse or refine). */
export function withoutTrace(criteria) {
    const c = clone(criteria) || {};
    delete c.trace;
    return c;
}

/**
 * Per row: which chips TK says are met and not met.
 * criteriaIds[i] maps queryPartFlags[i] to a chip ("filter:..." and "exclusion:..." entries are skipped).
 * Location chips sent in the query string (queryCriteriaIds) are met by every result.
 */
export function metAndNotMet(row) {
    const met = new Set();
    const notMet = new Set();
    const ids = (row && row.criteriaIds) || [];
    const flags = (row && row.queryPartFlags) || [];
    ids.forEach((id, i) => {
        if (!id || id.includes(':')) return;
        if (flags[i] === 1) met.add(id);
        else if (flags[i] === 0) notMet.add(id);
    });
    ((row && row.queryCriteriaIds) || []).forEach((id) => met.add(id));
    met.forEach((id) => notMet.delete(id));
    return { met, notMet };
}

/** "Up 2", "Down 1", "New" against the previous page-1 ranks (docId to rank). */
export function changeTag(prevRanks, docId, rank) {
    if (!prevRanks) return null;
    if (!(docId in prevRanks)) return { label: 'New', cls: 'tag tag-blue', icon: 'plus' };
    const diff = prevRanks[docId] - rank;
    if (diff > 0) return { label: `Up ${diff}`, cls: 'tag tag-green', icon: 'arrow-up' };
    if (diff < 0) return { label: `Down ${-diff}`, cls: 'tag tag-red', icon: 'arrow-down' };
    return null;
}

/** One line per refine diff entry (CriteriaService.applyPatch). */
export function diffLines(diff) {
    return (diff || []).map((d, i) => {
        const label = d.label || d.key || d.id || '';
        let text;
        if (d.op === 'add') {
            text = `Added ${label}` + (d.after && d.after.weight ? ` (${weightLabel(d.after.weight).toLowerCase()})` : '');
        } else if (d.op === 'remove') {
            text = `Removed ${label}`;
        } else if (d.op === 'update') {
            const parts = [];
            const b = d.before || {};
            const a = d.after || {};
            if (b.weight !== a.weight) parts.push(`${weightLabel(b.weight)} → ${weightLabel(a.weight)}`);
            if (b.radius !== a.radius && a.radius !== undefined) parts.push(`${b.radius ?? '?'} → ${a.radius} ${a.unit || 'mi'}`);
            if (b.value !== a.value && a.value !== undefined && a.kind !== 'location') parts.push(`"${b.value}" → "${a.value}"`);
            text = `Changed ${label}` + (parts.length ? `: ${parts.join(', ')}` : '');
        } else if (d.op === 'setExclusion') {
            text = d.after === undefined || d.after === null ? `Stopped excluding ${exclusionLabel(d.key)}` : `Excluding ${exclusionLabel(d.key, d.after)}`;
        } else if (d.op === 'setFilter') {
            text = d.after ? `Filter ${facetLabel(d.key)}: ${[].concat(d.after).join(', ')}` : `Cleared filter ${facetLabel(d.key)}`;
        } else {
            text = `${d.op} ${label}`;
        }
        return {
            id: `d${i}`,
            text,
            cls: `diff diff-${d.op === 'remove' ? 'remove' : d.op === 'add' ? 'add' : 'change'}`
        };
    });
}

export function exclusionLabel(key, value) {
    if (key === 'placedWithinDays') return value ? `anyone placed in the last ${value} days` : 'recent placements';
    if (key === 'pipelineForJob') return 'candidates already on this job';
    return key;
}

export function formatDate(value) {
    if (!value) return '';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return String(value);
    return d.toLocaleDateString(undefined, {
        day: 'numeric',
        month: 'short',
        year: 'numeric'
    });
}

export function formatDateTime(value) {
    if (!value) return '';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return String(value);
    return d.toLocaleString(undefined, {
        day: 'numeric',
        month: 'short',
        hour: '2-digit',
        minute: '2-digit'
    });
}

/** Strips tags except <b>, for TK highlight snippets shown with lightning-formatted-rich-text. */
export function safeHighlight(html) {
    return String(html || '')
        .replace(/<(?!\/?b>)[^>]*>/gi, '')
        .trim();
}

export function normalizeError(err) {
    console.error('[CandidateSearch] Raw error:', err);
    try {
        if (typeof err === 'string') return err;
        const body = err && err.body;
        if (Array.isArray(body)) {
            const msgs = body.map((b) => b && b.message).filter(Boolean);
            if (msgs.length) return msgs.join('; ');
        }
        const parts = [];
        if (body && body.message) parts.push(body.message);
        ((body && body.pageErrors) || []).forEach((p) => p && p.message && parts.push(p.message));
        Object.keys((body && body.fieldErrors) || {}).forEach((field) => {
            (body.fieldErrors[field] || []).forEach((fe) => parts.push(`${field}: ${fe.message}${fe.statusCode ? ` (${fe.statusCode})` : ''}`));
        });
        if (parts.length) return parts.join('; ');
        if (err && err.message) return err.message;
        return JSON.stringify(err);
    } catch {
        return 'Unexpected error';
    }
}

/** Pretty-prints the masked SOAP request (from callListMatchViewer). */
export function prettyXmlLines(xml) {
    if (!xml) return [];
    const tokens = String(xml).match(/<!--[\s\S]*?-->|<\/?[^>]+>|[^<]+/g) || [];
    const lines = [];
    const pad = (d) => '    '.repeat(Math.max(d, 0));
    const isOpen = (t) => /^<[^/!?][^>]*[^/]>$|^<[^/!?>]>$/.test(t);
    const isClose = (t) => /^<\//.test(t);
    const isText = (t) => !t.startsWith('<');
    const name = (t) => (t.match(/^<\/?([^\s>/]+)/) || [])[1];
    let depth = 0;
    for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i];
        if (isText(t) && !t.trim()) continue;
        if (t.startsWith('<!--')) {
            if (lines.length) lines.push('');
            depth = 0;
            lines.push(t.trim());
        } else if (isOpen(t)) {
            const next = tokens[i + 1];
            const after = tokens[i + 2];
            if (next !== undefined && isText(next) && next.trim() && after && isClose(after) && name(after) === name(t)) {
                lines.push(pad(depth) + t + next.trim() + after);
                i += 2;
            } else if (next !== undefined && isClose(next) && name(next) === name(t)) {
                lines.push(pad(depth) + t + next);
                i += 1;
            } else {
                lines.push(pad(depth) + t);
                depth++;
            }
        } else if (isClose(t)) {
            depth--;
            lines.push(pad(depth) + t);
        } else {
            lines.push(pad(depth) + t.trim());
        }
    }
    return lines;
}

/** "Ethan Kirby" -> "EK". */
export function initials(name) {
    const parts = String(name || '')
        .trim()
        .split(/\s+/)
        .filter(Boolean);
    if (!parts.length) return '?';
    return ((parts[0][0] || '') + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase();
}

/** Stable avatar colour class from a key (doc id or name). */
export function avatarClass(key) {
    let h = 0;
    const s = String(key || '');
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 997;
    return `avatar hue-${h % 6}`;
}

/** Score ring: class and style for a 0-100 score. */
export function ring(scorePct) {
    const n = scorePct === null || scorePct === undefined || Number.isNaN(Number(scorePct)) ? null : Math.round(Number(scorePct));
    const p = n === null ? 0 : Math.max(0, Math.min(100, n));
    return {
        cls: `ring ${p >= 80 ? 'high' : p >= 50 ? 'mid' : 'low'}`,
        style: `--p:${p}`,
        text: n === null ? '–' : `${n}`
    };
}

/**
 * TK highlight HTML ("a <b>forklift</b> licence") as text segments, so it renders without innerHTML:
 * [{ key, text, bold }].
 */
export function highlightSegments(html) {
    const clean = safeHighlight(html);
    const out = [];
    const re = /<b>([\s\S]*?)<\/b>/gi;
    let last = 0;
    let m;
    let i = 0;
    while ((m = re.exec(clean)) !== null) {
        if (m.index > last) out.push({ key: `s${i++}`, text: decode(clean.slice(last, m.index)), bold: false });
        out.push({ key: `s${i++}`, text: decode(m[1]), bold: true });
        last = re.lastIndex;
    }
    if (last < clean.length) out.push({ key: `s${i++}`, text: decode(clean.slice(last)), bold: false });
    return out.map((s) => ({ ...s, cls: s.bold ? 'hl-hit' : 'hl-txt' }));
}

function decode(s) {
    return String(s)
        .replace(/<\/?b>/gi, '')
        .replace(/&amp;/g, '&')
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'");
}

// ─── Result list columns ────────────────────────

/**
 * Textkernel fields users can add as result columns. They come back with every search (TK_Result_Fields__c plus
 * CandidateSearchConfig.PROFILE_RESULT_FIELDS), so they cost no extra call.
 */
export const TK_COLUMNS = [
    { key: 'tk:recent', label: 'Recent position', fields: ['recent_jobtitles', 'lastjobtitle'] },
    { key: 'tk:workfield', label: 'Work field', fields: ['workfield'] },
    { key: 'tk:employers', label: 'Employers', fields: ['employers'] },
    { key: 'tk:experience', label: 'Experience', fields: ['experience_years'], suffix: ' yrs' },
    { key: 'tk:education', label: 'Education level', fields: ['educationlevel_international'] },
    { key: 'tk:degree', label: 'Degree', fields: ['degree_name'] },
    { key: 'tk:status', label: 'Candidate status', fields: ['candidate_status'] },
    { key: 'tk:owner', label: 'Owner', fields: ['owner_name'] },
    { key: 'tk:available', label: 'Date available', fields: ['date_available'], date: true },
    { key: 'tk:modified', label: 'CV last modified', fields: ['documentdate'], date: true },
    { key: 'tk:salary', label: 'Current salary', fields: ['current_salary'], number: true },
    { key: 'tk:desired', label: 'Desired salary', fields: ['salary'], number: true },
    { key: 'tk:applications', label: 'Applications', fields: ['job_submissions'] }
];
export const DEFAULT_COLUMNS = ['tk:experience', 'tk:education', 'tk:available'];
export const MAX_COLUMNS = 6;

const COLUMN_JUNK = /^(custom_(text|date|numeric)_\d+|true|false)$/i;

/** Plain text of one Textkernel column for a row: values deduplicated, the first two joined, "+N" for the rest. */
export function tkColumnText(row, col) {
    const fields = (row && row.fields) || {};
    const seen = new Set();
    const values = [];
    col.fields.forEach((f) =>
        [].concat(fields[f] || []).forEach((v) => {
            const text = highlightSegments(v)
                .map((s) => s.text)
                .join('')
                .trim();
            if (!text || COLUMN_JUNK.test(text) || seen.has(text.toLowerCase())) return;
            seen.add(text.toLowerCase());
            values.push(text);
        })
    );
    if (!values.length) return '';
    const shown = values.slice(0, 2).map((v) => {
        if (col.date) return formatDate(v.substring(0, 10)) || v;
        if (col.number && !Number.isNaN(Number(v))) return Number(v).toLocaleString();
        return col.suffix && !Number.isNaN(Number(v)) ? `${v}${col.suffix}` : v;
    });
    const more = values.length - shown.length;
    return `${shown.join(', ')}${more > 0 ? ` +${more}` : ''}`;
}

/** Display text of a Salesforce column value (getColumnValues returns dates as yyyy-MM-dd). */
export function sfColumnText(value, type) {
    if (value === null || value === undefined || value === '') return '';
    if (type === 'date' || type === 'datetime') return formatDate(value);
    if ((type === 'currency' || type === 'double' || type === 'integer' || type === 'percent') && !Number.isNaN(Number(value))) {
        return Number(value).toLocaleString() + (type === 'percent' ? '%' : '');
    }
    return String(value);
}
