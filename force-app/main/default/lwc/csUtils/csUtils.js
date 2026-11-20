/**
 * csUtils: shared helpers for the Candidate Search components (no template).
 *
 * - normalizeError: same handling as amplifyRecordEnrichmentPanel (body.message, pageErrors, fieldErrors, arrays).
 * - prettyXmlLines: same formatter as the callListMatchViewer request viewer.
 * - Criteria helpers: labels for kinds and weights, chip ids, met / not met per row, rank change tags.
 *
 * Text comes from csI18n. Helpers that return text take an optional lang (default: the page's language); components
 * pass this.lang so they re-render when the language changes.
 */
import { tr, localeFor } from 'c/csI18n';

export const PAGE_SIZE = 20;
/**
 * Candidates per explain call. Small, because a call of 10 could run past the 60-second AI callout timeout and fail
 * every row in it. Batches run EXPLAIN_CONCURRENCY at a time.
 */
export const EXPLAIN_BATCH = 4;
export const EXPLAIN_CONCURRENCY = 3;
export const COMPARE_MIN = 2;
export const COMPARE_MAX = 4;

export const WEIGHTS = [
    { value: 'required', labelKey: 'weightRequired', shortKey: 'weightRequiredShort' },
    { value: 'strongly_preferred', labelKey: 'weightStrong', shortKey: 'weightStrongShort' },
    { value: 'preferred', labelKey: 'weightPreferred', shortKey: 'weightPreferredShort' },
    { value: 'excluded', labelKey: 'weightExcluded', shortKey: 'weightExcludedShort' }
];

/** Kinds a recruiter can add by hand. fingerprint and tk_raw only come from a job document. */
export const ADDABLE_KINDS = [
    { value: 'title', labelKey: 'addKindTitle' },
    { value: 'skill', labelKey: 'addKindSkill' },
    { value: 'certification', labelKey: 'addKindCertification' },
    { value: 'location', labelKey: 'addKindLocation' },
    { value: 'keyword', labelKey: 'addKindKeyword' },
    { value: 'language', labelKey: 'addKindLanguage' },
    { value: 'shift', labelKey: 'addKindShift' },
    { value: 'availability', labelKey: 'addKindAvailability' }
];

const KIND_KEYS = {
    title: 'kindTitle',
    skill: 'kindSkill',
    certification: 'kindCertification',
    location: 'kindLocation',
    keyword: 'kindKeyword',
    language: 'kindLanguage',
    shift: 'kindShift',
    availability: 'kindAvailability',
    fingerprint: 'kindFingerprint',
    tk_raw: 'kindTkRaw'
};

const FACET_KEYS = {
    candidate_status: 'facetStatus',
    owner_name: 'facetOwner',
    owner_id: 'facetOwner',
    city: 'facetCity',
    jobtitles: 'facetJobtitles',
    recent_jobtitles: 'facetRecentTitles',
    it_skills: 'facetItSkills',
    profskills: 'facetSkills',
    languages: 'facetLanguages'
};

export const READ_ONLY_KINDS = new Set(['fingerprint', 'tk_raw']);

export function weights(lang) {
    return WEIGHTS.map((w) => ({ value: w.value, label: tr(w.labelKey, null, lang), short: tr(w.shortKey, null, lang) }));
}

export function addableKinds(lang) {
    return ADDABLE_KINDS.map((k) => ({ value: k.value, label: tr(k.labelKey, null, lang) }));
}

export function kindLabel(kind, lang) {
    return KIND_KEYS[kind] ? tr(KIND_KEYS[kind], null, lang) : kind || '';
}

export function weightLabel(weight, lang) {
    const w = WEIGHTS.find((x) => x.value === weight);
    return w ? tr(w.labelKey, null, lang) : weight || '';
}

export function weightShort(weight, lang) {
    const w = WEIGHTS.find((x) => x.value === weight);
    return w ? tr(w.shortKey, null, lang) : weight || '';
}

export function facetLabel(field, lang) {
    if (FACET_KEYS[field]) return tr(FACET_KEYS[field], null, lang);
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
export function changeTag(prevRanks, docId, rank, lang) {
    if (!prevRanks) return null;
    if (!(docId in prevRanks)) return { label: tr('tagNew', null, lang), cls: 'tag tag-blue', icon: 'plus' };
    const diff = prevRanks[docId] - rank;
    if (diff > 0) return { label: tr('tagUp', { n: diff }, lang), cls: 'tag tag-green', icon: 'arrow-up' };
    if (diff < 0) return { label: tr('tagDown', { n: -diff }, lang), cls: 'tag tag-red', icon: 'arrow-down' };
    return null;
}

/** One line per refine diff entry (CriteriaService.applyPatch). */
export function diffLines(diff, lang) {
    return (diff || []).map((d, i) => {
        const label = d.label || d.key || d.id || '';
        let text;
        if (d.op === 'add') {
            text =
                d.after && d.after.weight
                    ? tr('diffAddedWeight', { label, weight: weightLabel(d.after.weight, lang).toLowerCase() }, lang)
                    : tr('diffAdded', { label }, lang);
        } else if (d.op === 'remove') {
            text = tr('diffRemoved', { label }, lang);
        } else if (d.op === 'update') {
            const parts = [];
            const b = d.before || {};
            const a = d.after || {};
            if (b.weight !== a.weight) parts.push(`${weightLabel(b.weight, lang)} → ${weightLabel(a.weight, lang)}`);
            if (b.radius !== a.radius && a.radius !== undefined) parts.push(`${b.radius ?? '?'} → ${a.radius} ${a.unit || 'mi'}`);
            if (b.value !== a.value && a.value !== undefined && a.kind !== 'location') parts.push(`"${b.value}" → "${a.value}"`);
            text = parts.length ? tr('diffChangedParts', { label, parts: parts.join(', ') }, lang) : tr('diffChanged', { label }, lang);
        } else if (d.op === 'setExclusion') {
            text =
                d.after === undefined || d.after === null
                    ? tr('diffStopExcluding', { what: exclusionLabel(d.key, null, lang) }, lang)
                    : tr('diffExcluding', { what: exclusionLabel(d.key, d.after, lang) }, lang);
        } else if (d.op === 'setFilter') {
            text = d.after
                ? tr('diffFilter', { facet: facetLabel(d.key, lang), values: [].concat(d.after).join(', ') }, lang)
                : tr('diffClearedFilter', { facet: facetLabel(d.key, lang) }, lang);
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

export function exclusionLabel(key, value, lang) {
    if (key === 'placedWithinDays') return value ? tr('exclPlacedDays', { n: value }, lang) : tr('exclRecentPlacements', null, lang);
    if (key === 'pipelineForJob') return tr('exclPipeline', null, lang);
    return key;
}

export function formatDate(value, lang) {
    if (!value) return '';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return String(value);
    return d.toLocaleDateString(localeFor(lang), {
        day: 'numeric',
        month: 'short',
        year: 'numeric'
    });
}

export function formatDateTime(value, lang) {
    if (!value) return '';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return String(value);
    return d.toLocaleString(localeFor(lang), {
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
        return tr('unexpectedError');
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
    { key: 'tk:recent', labelKey: 'colRecent', fields: ['recent_jobtitles', 'lastjobtitle'] },
    { key: 'tk:workfield', labelKey: 'colWorkfield', fields: ['workfield'] },
    { key: 'tk:employers', labelKey: 'colEmployers', fields: ['employers'] },
    { key: 'tk:experience', labelKey: 'colExperience', fields: ['experience_years'], years: true },
    { key: 'tk:education', labelKey: 'colEducation', fields: ['educationlevel_international'] },
    { key: 'tk:degree', labelKey: 'colDegree', fields: ['degree_name'] },
    { key: 'tk:status', labelKey: 'colStatus', fields: ['candidate_status'] },
    { key: 'tk:owner', labelKey: 'colOwner', fields: ['owner_name'] },
    { key: 'tk:available', labelKey: 'colAvailable', fields: ['date_available'], date: true },
    { key: 'tk:modified', labelKey: 'colModified', fields: ['documentdate'], date: true },
    { key: 'tk:salary', labelKey: 'colSalary', fields: ['current_salary'], number: true },
    { key: 'tk:desired', labelKey: 'colDesired', fields: ['salary'], number: true },
    { key: 'tk:applications', labelKey: 'colApplications', fields: ['job_submissions'] }
];
export const DEFAULT_COLUMNS = ['tk:experience', 'tk:education', 'tk:available'];
export const MAX_COLUMNS = 6;

const COLUMN_JUNK = /^(custom_(text|date|numeric)_\d+|true|false)$/i;

/** Plain text of one Textkernel column for a row: values deduplicated, the first two joined, "+N" for the rest. */
export function tkColumnText(row, col, lang) {
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
        if (col.date) return formatDate(v.substring(0, 10), lang) || v;
        if (col.number && !Number.isNaN(Number(v))) return Number(v).toLocaleString(localeFor(lang));
        return col.years && !Number.isNaN(Number(v)) ? tr('colExperienceYears', { n: v }, lang) : v;
    });
    const more = values.length - shown.length;
    return `${shown.join(', ')}${more > 0 ? ` +${more}` : ''}`;
}

/** Display text of a Salesforce column value (getColumnValues returns dates as yyyy-MM-dd). */
export function sfColumnText(value, type, lang) {
    if (value === null || value === undefined || value === '') return '';
    if (type === 'date' || type === 'datetime') return formatDate(value, lang);
    if ((type === 'currency' || type === 'double' || type === 'integer' || type === 'percent') && !Number.isNaN(Number(value))) {
        return Number(value).toLocaleString(localeFor(lang)) + (type === 'percent' ? '%' : '');
    }
    if (value === 'Yes') return tr('yes', null, lang);
    if (value === 'No') return tr('no', null, lang);
    return String(value);
}
