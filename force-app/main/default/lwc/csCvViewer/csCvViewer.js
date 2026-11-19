import { LightningElement, api } from 'lwc';
import getCandidateCv from '@salesforce/apex/CandidateSearchController.getCandidateCv';
import getCandidateCvLink from '@salesforce/apex/CandidateSearchController.getCandidateCvLink';
import { normalizeError } from 'c/csUtils';

/** Tags kept as they are (formatting only). Anything else is unwrapped (its text kept) or, if listed in DROP, removed. */
const ALLOWED = new Set([
    'P',
    'DIV',
    'SPAN',
    'B',
    'STRONG',
    'I',
    'EM',
    'U',
    'BR',
    'UL',
    'OL',
    'LI',
    'TABLE',
    'THEAD',
    'TBODY',
    'TR',
    'TD',
    'TH',
    'H1',
    'H2',
    'H3',
    'H4',
    'H5',
    'H6',
    'A',
    'HR',
    'SECTION'
]);
const DROP = new Set([
    'SCRIPT',
    'STYLE',
    'TK_METADATA',
    'IFRAME',
    'OBJECT',
    'EMBED',
    'LINK',
    'META',
    'IMG',
    'SVG',
    'FORM',
    'INPUT',
    'BUTTON',
    'TEXTAREA',
    'SELECT',
    'NOSCRIPT',
    'TEMPLATE',
    'HEAD',
    'TITLE'
]);
const SAFE_HREF = /^(https?:|mailto:|tel:)/i;

/** Session cache of CV HTML by Textkernel doc id (the panel re-creates this component when tabs change). */
const CACHE = new Map();
const CACHE_MAX = 20;

/** Builds a clean copy of the CV: allowed tags only, no attributes except safe links and table spans. */
function sanitize(html) {
    // A separate, inert document: nothing in it runs or loads. Only allowed parts are copied out below.
    const parsed = new DOMParser().parseFromString(String(html || ''), 'text/html');
    const out = document.createDocumentFragment();
    const copy = (src, dest) => {
        src.childNodes.forEach((node) => {
            if (node.nodeType === 3) {
                dest.appendChild(document.createTextNode(node.textContent));
                return;
            }
            if (node.nodeType !== 1) return;
            const tag = node.tagName.toUpperCase();
            if (DROP.has(tag)) return;
            if (!ALLOWED.has(tag)) {
                copy(node, dest);
                return;
            }
            const el = document.createElement(tag.toLowerCase());
            if (tag === 'A') {
                const href = node.getAttribute('href') || '';
                if (SAFE_HREF.test(href.trim())) {
                    el.setAttribute('href', href.trim());
                    el.setAttribute('target', '_blank');
                    el.setAttribute('rel', 'noopener noreferrer');
                }
            }
            if (tag === 'TD' || tag === 'TH') {
                ['colspan', 'rowspan'].forEach((a) => {
                    const v = node.getAttribute(a);
                    if (v && /^\d{1,2}$/.test(v)) el.setAttribute(a, v);
                });
            }
            const align = (node.getAttribute('style') || '').match(/text-align:\s*(center|right)/i);
            if (align) el.setAttribute('data-align', align[1].toLowerCase());
            if (/font-weight:\s*(bold|[6-9]00)/i.test(node.getAttribute('style') || '')) el.setAttribute('data-bold', '1');
            copy(node, el);
            dest.appendChild(el);
        });
    };
    copy(parsed.body, out);
    return out;
}

function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Wraps every match of the terms in <mark class="hit" data-term>. Returns { term: count } (lower-case keys). */
function highlight(root, terms) {
    const counts = {};
    const list = (terms || []).filter((t) => t && t.trim().length > 1).sort((a, b) => b.length - a.length);
    if (!list.length) return counts;
    const re = new RegExp(`(?<![\\p{L}\\p{N}])(${list.map((t) => escapeRegExp(t.trim())).join('|')})(?![\\p{L}\\p{N}])`, 'giu');
    const walker = document.createTreeWalker(root, 4 /* NodeFilter.SHOW_TEXT */);
    const nodes = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) nodes.push(n);
    nodes.forEach((node) => {
        const text = node.textContent;
        re.lastIndex = 0;
        if (!re.test(text)) return;
        re.lastIndex = 0;
        const frag = document.createDocumentFragment();
        let last = 0;
        let m;
        while ((m = re.exec(text)) !== null) {
            if (m.index > last) frag.appendChild(document.createTextNode(text.slice(last, m.index)));
            const mark = document.createElement('mark');
            const key = m[1].toLowerCase();
            mark.className = 'hit';
            mark.setAttribute('data-term', key);
            mark.textContent = m[1];
            frag.appendChild(mark);
            counts[key] = (counts[key] || 0) + 1;
            last = re.lastIndex;
        }
        if (last < text.length) frag.appendChild(document.createTextNode(text.slice(last)));
        node.parentNode.replaceChild(frag, node);
    });
    return counts;
}

/**
 * csCvViewer: the candidate's CV from the Textkernel index (viewDocument), sanitised, with the search terms
 * highlighted. Term chips show how often each term appears and jump to it; Previous / Next step through all
 * matches. "Open original" opens the CV file through the BH4SF presigned link.
 */
export default class CsCvViewer extends LightningElement {
    /** Search terms to highlight (chip values and Textkernel highlight words). */
    @api terms = [];
    @api contactId;

    _docId;
    @api
    get docId() {
        return this._docId;
    }
    set docId(value) {
        if (value === this._docId) return;
        this._docId = value;
        this.load();
    }

    html = null;
    loading = false;
    error = null;
    counts = {};
    total = 0;
    current = -1;
    opening = false;
    openError = null;
    _renderedKey = null;

    async load() {
        const docId = this._docId;
        this.html = null;
        this.error = null;
        this._renderedKey = null;
        if (!docId) return;
        if (CACHE.has(docId)) {
            this.html = CACHE.get(docId);
            return;
        }
        this.loading = true;
        try {
            const res = JSON.parse(await getCandidateCv({ docId }));
            if (docId !== this._docId) return;
            CACHE.set(docId, res.html);
            if (CACHE.size > CACHE_MAX) CACHE.delete(CACHE.keys().next().value);
            this.html = res.html;
        } catch (e) {
            if (docId === this._docId) this.error = normalizeError(e);
        } finally {
            if (docId === this._docId) this.loading = false;
        }
    }

    renderedCallback() {
        const host = this.template.querySelector('.cv-doc');
        if (!host || !this.html) return;
        const key = `${this._docId}|${(this.terms || []).join('\u0001')}`;
        if (key === this._renderedKey) return;
        this._renderedKey = key;
        while (host.firstChild) host.removeChild(host.firstChild);
        const frag = sanitize(this.html);
        const marked = highlight(frag, this.terms);
        host.appendChild(frag);
        this.total = Object.values(marked).reduce((a, b) => a + b, 0);
        // Per-term counts are taken on the text itself, so a short term inside a longer highlighted phrase
        // ("Operative" in "Warehouse Operative") still counts
        // Text runs joined with a space, so words in neighbouring paragraphs do not run together
        const runs = [];
        const walker = document.createTreeWalker(host, 4 /* NodeFilter.SHOW_TEXT */);
        for (let n = walker.nextNode(); n; n = walker.nextNode()) runs.push(n.textContent);
        const text = runs.join(' ');
        const counts = {};
        (this.terms || []).forEach((t) => {
            const v = (t || '').trim();
            if (v.length < 2) return;
            const re = new RegExp(`(?<![\\p{L}\\p{N}])${escapeRegExp(v)}(?![\\p{L}\\p{N}])`, 'giu');
            counts[v.toLowerCase()] = (text.match(re) || []).length;
        });
        this.counts = counts;
        this.current = -1;
    }

    get hasDoc() {
        return !!this.html && !this.loading;
    }

    get termChips() {
        const seen = new Set();
        return (this.terms || [])
            .filter((t) => {
                const k = (t || '').toLowerCase();
                if (!k || seen.has(k)) return false;
                seen.add(k);
                return true;
            })
            .map((t) => {
                const n = this.counts[t.toLowerCase()] || 0;
                return { key: t.toLowerCase(), label: t, count: n, cls: `term${n ? '' : ' term-none'}`, disabled: !n };
            });
    }

    get hasTerms() {
        return this.termChips.length > 0;
    }

    get summary() {
        if (!this.total) return 'No search terms found in this CV';
        const pos = this.current >= 0 ? `${this.current + 1} of ` : '';
        return `${pos}${this.total} match${this.total === 1 ? '' : 'es'}`;
    }

    get navDisabled() {
        return !this.total;
    }

    marks() {
        return Array.from(this.template.querySelectorAll('.cv-doc mark.hit'));
    }

    focusMark(index) {
        const marks = this.marks();
        if (!marks.length) return;
        const i = ((index % marks.length) + marks.length) % marks.length;
        marks.forEach((m) => m.classList.remove('current'));
        marks[i].classList.add('current');
        if (typeof marks[i].scrollIntoView === 'function') marks[i].scrollIntoView({ block: 'center' });
        this.current = i;
    }

    next() {
        this.focusMark(this.current + 1);
    }

    prev() {
        this.focusMark(this.current < 0 ? -1 : this.current - 1);
    }

    jumpToTerm(event) {
        const key = event.currentTarget.dataset.term;
        const marks = this.marks();
        // A highlight that is this term, or a longer phrase that contains it
        const has = (m) => m.getAttribute('data-term') === key || (m.getAttribute('data-term') || '').includes(key);
        const after = marks.findIndex((m, i) => i > this.current && has(m));
        const first = marks.findIndex(has);
        const target = after >= 0 ? after : first;
        if (target >= 0) this.focusMark(target);
    }

    async openOriginal() {
        if (!this.contactId || this.opening) return;
        this.opening = true;
        this.openError = null;
        try {
            const res = JSON.parse(await getCandidateCvLink({ contactId: this.contactId }));
            window.open(res.url, '_blank', 'noopener');
        } catch (e) {
            this.openError = normalizeError(e);
        } finally {
            this.opening = false;
        }
    }

    get openDisabled() {
        return !this.contactId || this.opening;
    }

    retry() {
        CACHE.delete(this._docId);
        this.load();
    }
}
