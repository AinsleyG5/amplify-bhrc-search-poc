import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getCandidateDetail from '@salesforce/apex/CandidateSearchController.getCandidateDetail';
import describeSkills from '@salesforce/apex/CandidateSearchController.describeSkills';
import { labels, tr } from 'c/csI18n';
import { metAndNotMet, kindLabel, weightLabel, formatDate, highlightSegments, initials, avatarClass, ring, normalizeError, READ_ONLY_KINDS } from 'c/csUtils';

const TABS = [
    { value: 'why', labelKey: 'tabWhy' },
    { value: 'cv', labelKey: 'tabCv' },
    { value: 'profile', labelKey: 'tabProfile' },
    { value: 'skills', labelKey: 'tabSkills' },
    { value: 'activity', labelKey: 'tabActivity' },
    { value: 'jobs', labelKey: 'tabJobs' }
];

/** Textkernel profile fields for the Profile tab, in the portal's order and with its labels. */
const TK_PROFILE = [
    { fields: ['documentdate'], label: 'pLastModified', date: true },
    { fields: ['recent_jobtitles', 'lastjobtitle'], label: 'pRecentPositions' },
    { fields: ['jobtitles'], label: 'pAllPositions' },
    { fields: ['workfield'], label: 'pWorkField' },
    { fields: ['employers'], label: 'pEmployers' },
    { fields: ['experience_years'], label: 'pYears' },
    { fields: ['educationlevel_international'], label: 'pEducation' },
    { fields: ['degree_name'], label: 'pDegrees' },
    { fields: ['degree_institute'], label: 'pInstitutes' },
    { fields: ['it_skills'], label: 'pItSkills', pills: true },
    { fields: ['language_skills'], label: 'pLangSkills', pills: true },
    { fields: ['professional_skills', 'profskills'], label: 'pProfSkills', pills: true },
    { fields: ['soft_skills'], label: 'pCompetencies', pills: true },
    { fields: ['custom_nested_object_1'], label: 'pCertifications', pills: true },
    { fields: ['date_available'], label: 'pAvailable', date: true },
    { fields: ['job_submissions'], label: 'pApplications' },
    { fields: ['current_salary'], label: 'pSalary', number: true },
    { fields: ['salary'], label: 'pDesired', number: true }
];
const PROFILE_LIST_MAX = 12;

/** Textkernel skill codes (KS...) are shown by name, never as codes. */
const SKILL_CODE = /^KS[0-9A-Z]{6,}$/;
/** Internal values that are never shown (nested-object keys, flags). */
const JUNK = /^(custom_(text|date|numeric)_\d+|true|false)$/i;
const SKILL_FIELDS = ['it_skills', 'language_skills', 'professional_skills', 'profskills', 'soft_skills', 'custom_nested_object_1'];
/** Session cache of skill names (Textkernel's terms require lookups to be cached). */
const SKILL_NAMES = { en: new Map(), fr: new Map() };

/** Chip kinds whose values are words to look for in the CV (not locations, dates or Textkernel-generated parts). */
const CV_TERM_KINDS = new Set(['title', 'skill', 'certification', 'keyword', 'language', 'shift']);

const PROFILE_FIELDS = [
    { field: 'TR1__Candidate_Status__c', label: 'sfStatus' },
    { field: 'Date_Available__c', label: 'sfAvailableFrom', date: true },
    { field: 'TR1__Date_Available__c', label: 'sfAvailableFrom', date: true },
    { field: 'TR1__Last_Placement_Date__c', label: 'sfLastPlaced', date: true },
    { field: 'TR1__Candidate_Summary__c', label: 'sfSummary', long: true }
];

/**
 * csCandidatePanel: overlay over the result list (screen 3). Tabs: Why, CV, Profile, Skills, Activity.
 * Escape closes; Up and Down move to the previous or next row.
 *
 * Events: close {}, navigate { delta }, explain { docId }, shortlist { docId }, dismiss { docId }.
 */
export default class CsCandidatePanel extends NavigationMixin(LightningElement) {
    @api criteria;
    @api explanation;
    @api auditId;
    @api canShortlist = false;
    @api position = '';

    /** 'en' or 'fr' (csI18n). Skill names are looked up again in the new language. */
    @api
    get lang() {
        return this._lang;
    }
    set lang(value) {
        const changed = this._lang !== undefined && value !== this._lang;
        this._lang = value;
        if (changed && this._row) this.loadSkillNames();
    }
    _lang;

    get L() {
        return labels(this.lang);
    }

    _row;
    @api
    get row() {
        return this._row;
    }
    set row(value) {
        const changed = !this._row || !value || this._row.docId !== value.docId;
        this._row = value;
        if (changed) {
            this.detail = null;
            this.detailError = null;
            // After this render's other @api values (auditId) are set
            if (value && value.contactId) Promise.resolve().then(() => this.loadDetail(value.contactId));
            if (this.tab === 'profile') Promise.resolve().then(() => this.loadSkillNames());
        }
    }

    tab = 'why';
    detail = null;
    detailError = null;
    detailLoading = false;
    _cache = {};

    @api
    focus() {
        const btn = this.template.querySelector('.close-btn');
        // No scroll jump: the app decides what is in view
        if (btn) btn.focus({ preventScroll: true });
    }

    async loadDetail(contactId) {
        if (this._cache[contactId]) {
            this.detail = this._cache[contactId];
            return;
        }
        this.detailLoading = true;
        try {
            const res = JSON.parse(await getCandidateDetail({ contactId, auditId: this.auditId, lang: this.lang }));
            this._cache[contactId] = res.candidate;
            if (this._row && this._row.contactId === contactId) this.detail = res.candidate;
        } catch (e) {
            if (this._row && this._row.contactId === contactId) this.detailError = normalizeError(e);
        } finally {
            this.detailLoading = false;
        }
    }

    // ─── Header ─────────────────────────────────────

    get name() {
        return (this._row && this._row.name) || this.L.unnamedCandidate;
    }

    get subtitle() {
        const r = this._row || {};
        return [r.title, r.city].filter(Boolean).join(' · ');
    }

    get scoreText() {
        const s = this._row && this._row.scorePct;
        return s === null || s === undefined ? '' : tr('pctMatch', { n: Math.round(s) }, this.lang);
    }

    get initials() {
        return initials(this._row && this._row.name);
    }

    get avatarCls() {
        return `${avatarClass(this._row && (this._row.contactId || this._row.docId))} avatar-lg`;
    }

    get score() {
        return ring(this._row && this._row.scorePct);
    }

    get pipelineLabel() {
        const p = (this._row && this._row.pipeline) || {};
        return p.label || '';
    }

    get hasRecord() {
        return !!(this._row && this._row.contactId);
    }

    get noRecord() {
        return !this.hasRecord;
    }

    get shortlistDisabled() {
        const p = (this._row && this._row.pipeline) || {};
        return !this.hasRecord || p.shortlisted || p.applied || p.placed;
    }

    get dialogLabel() {
        return tr('candidateName', { name: this.name }, this.lang);
    }

    // ─── Tabs ───────────────────────────────────────

    get tabs() {
        return TABS.map((t) => ({
            ...t,
            label: this.L[t.labelKey],
            selected: this.tab === t.value ? 'true' : 'false',
            cls: 'seg-btn tab',
            tabIndex: this.tab === t.value ? '0' : '-1',
            id: `tab-${t.value}`
        }));
    }

    get isWhy() {
        return this.tab === 'why';
    }

    get isProfile() {
        return this.tab === 'profile';
    }

    get isSkills() {
        return this.tab === 'skills';
    }

    get isCv() {
        return this.tab === 'cv';
    }

    /** Words to highlight in the CV: the searchable chips, then the words Textkernel highlighted for this candidate. */
    get cvTerms() {
        const out = [];
        const seen = new Set();
        const add = (t) => {
            const v = String(t || '').trim();
            const k = v.toLowerCase();
            if (v.length < 2 || seen.has(k)) return;
            seen.add(k);
            out.push(v);
        };
        ((this.criteria && this.criteria.items) || []).forEach((it) => {
            if (!CV_TERM_KINDS.has(it.kind) || it.weight === 'excluded') return;
            add(it.value || it.label);
        });
        const h = (this._row && this._row.highlights) || {};
        Object.keys(h).forEach((field) => {
            [].concat(h[field] || []).forEach((snippet) => {
                highlightSegments(snippet)
                    .filter((g) => g.bold)
                    .forEach((g) => add(g.text));
            });
        });
        return out.slice(0, 20);
    }

    get docId() {
        return this._row ? this._row.docId : null;
    }

    get contactId() {
        return this._row ? this._row.contactId : null;
    }

    get isJobs() {
        return this.tab === 'jobs';
    }

    matchToJobs() {
        this.tab = 'jobs';
    }

    /** Fields expanded with "+N more" (label -> true). */
    expanded = {};

    /** Textkernel profile (portal layout): one row per field, duplicates removed, matched words in bold. */
    get tkProfile() {
        const fields = (this._row && this._row.fields) || {};
        const out = [];
        TK_PROFILE.forEach((def) => {
            const raw = [];
            def.fields.forEach((f) => [].concat(fields[f] || []).forEach((v) => raw.push(v)));
            const seen = new Set();
            const values = [];
            raw.forEach((v) => {
                let segs = highlightSegments(v);
                let text = segs
                    .map((g) => g.text)
                    .join('')
                    .trim();
                if (JUNK.test(text)) return;
                if (SKILL_CODE.test(text)) {
                    const name = this.skillNames[text];
                    if (!name) return;
                    text = name;
                    segs = [{ key: 's0', text: name, cls: 'hl-txt' }];
                }
                const key = text.toLowerCase();
                if (!text || seen.has(key)) return;
                seen.add(key);
                let shown = segs;
                if (def.date) shown = [{ key: 's0', text: formatDate(text.substring(0, 10), this.lang) || text, cls: 'hl-txt' }];
                if (def.number && !Number.isNaN(Number(text))) shown = [{ key: 's0', text: Number(text).toLocaleString(), cls: 'hl-txt' }];
                values.push({ key: `${def.label}-${values.length}`, segs: shown, cls: def.pills ? 'tk-pill' : 'tk-val' });
            });
            if (!values.length) return;
            const open = this.expanded[def.label];
            const more = values.length - PROFILE_LIST_MAX;
            out.push({
                key: def.label,
                label: this.L[def.label],
                values: open || more <= 0 ? values : values.slice(0, PROFILE_LIST_MAX),
                moreText: more > 0 ? (open ? this.L.showLess : tr('nMore', { n: more }, this.lang)) : '',
                listCls: def.pills ? 'tk-values tk-pills' : 'tk-values'
            });
        });
        return out;
    }

    get hasTkProfile() {
        return this.tkProfile.length > 0;
    }

    toggleMore(event) {
        const label = event.currentTarget.dataset.label;
        this.expanded = { ...this.expanded, [label]: !this.expanded[label] };
    }

    get isActivity() {
        return this.tab === 'activity';
    }

    selectTab(event) {
        this.tab = event.currentTarget.dataset.tab;
        if (this.tab === 'profile') this.loadSkillNames();
    }

    /** id -> name, copied from the session cache so the profile re-renders when names arrive. */
    skillNames = {};

    async loadSkillNames() {
        const fields = (this._row && this._row.fields) || {};
        const cache = SKILL_NAMES[this.lang === 'fr' ? 'fr' : 'en'];
        const codes = new Set();
        SKILL_FIELDS.forEach((f) =>
            [].concat(fields[f] || []).forEach((v) => {
                const t = String(v)
                    .replace(/<\/?b>/gi, '')
                    .trim();
                if (SKILL_CODE.test(t) && !cache.has(t)) codes.add(t);
            })
        );
        if (codes.size) {
            try {
                const names = JSON.parse(await describeSkills({ skillIdsJson: JSON.stringify([...codes].slice(0, 100)), lang: this.lang }));
                Object.keys(names || {}).forEach((k) => cache.set(k, names[k]));
            } catch {
                // Lookup unavailable (a Textkernel add-on): codes stay hidden rather than shown raw
            }
        }
        this.skillNames = Object.fromEntries(cache);
    }

    handleTabKeydown(event) {
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
        event.preventDefault();
        event.stopPropagation();
        const i = TABS.findIndex((t) => t.value === this.tab);
        const next = TABS[(i + (event.key === 'ArrowRight' ? 1 : TABS.length - 1)) % TABS.length];
        this.tab = next.value;

        Promise.resolve().then(() => {
            const btn = this.template.querySelector(`[data-tab="${next.value}"]`);
            if (btn) btn.focus();
        });
    }

    // ─── Why ────────────────────────────────────────

    get explainState() {
        return this.explanation ? this.explanation.state : 'none';
    }

    get explainPending() {
        return this.explainState === 'pending';
    }

    get explainMissing() {
        return this.explainState === 'none' || this.explainState === 'error';
    }

    get explainErrorText() {
        return this.explanation && this.explanation.state === 'error' ? this.explanation.error : '';
    }

    get summary() {
        return this.explanation && this.explanation.state === 'done' ? this.explanation.summary : '';
    }

    get whyCriteria() {
        const items = (this.criteria && this.criteria.items) || [];
        const { met, notMet } = metAndNotMet(this._row);
        const evidence = {};
        ((this.explanation && this.explanation.criteria) || []).forEach((c) => {
            if (c && c.id) evidence[c.id] = c;
        });
        return items.map((it) => {
            const excluded = it.weight === 'excluded';
            const isMet = met.has(it.id);
            const isNotMet = notMet.has(it.id);
            const ev = evidence[it.id] || {};
            const L = this.L;
            const status = excluded ? L.statusExcluded : isMet ? L.statusMet : isNotMet ? L.statusNotMet : L.statusNotScored;
            return {
                id: it.id,
                label: READ_ONLY_KINDS.has(it.kind) ? it.label || L.jobDescription : it.label || it.value,
                meta: `${kindLabel(it.kind, this.lang)} · ${weightLabel(it.weight, this.lang)}`,
                status,
                cls: `why-item why-${excluded ? 'excluded' : isMet ? 'met' : isNotMet ? 'notmet' : 'na'}`,
                icon: excluded ? 'ban' : isMet ? 'check' : isNotMet ? 'x' : 'minus',
                evidence: ev.evidence || '',
                source: ev.source || '',
                hasEvidence: !!ev.evidence
            };
        });
    }

    get highlights() {
        const h = (this._row && this._row.highlights) || {};
        const out = [];
        Object.keys(h).forEach((field) => {
            [].concat(h[field] || []).forEach((snippet, i) => {
                if (out.length < 8)
                    out.push({
                        id: `${field}-${i}`,
                        field: field.replace(/_/g, ' '),
                        segments: highlightSegments(snippet)
                    });
            });
        });
        return out;
    }

    get hasHighlights() {
        return this.highlights.length > 0;
    }

    handleExplain() {
        this.dispatchEvent(new CustomEvent('explain', { detail: { docId: this._row.docId } }));
    }

    // ─── Profile, skills, activity ──────────────────

    get profileRows() {
        const d = this.detail;
        if (!d) return [];
        const rows = [];
        const L = this.L;
        if (d.title) rows.push({ key: 'title', label: L.sfTitle, value: d.title });
        if (d.city) rows.push({ key: 'city', label: L.sfCity, value: d.city });
        if (d.owner) rows.push({ key: 'owner', label: L.sfOwner, value: d.owner });
        const profile = d.profile || {};
        const seen = new Set();
        PROFILE_FIELDS.forEach((f) => {
            const v = profile[f.field];
            if (v === null || v === undefined || v === '' || seen.has(f.label)) return;
            seen.add(f.label);
            rows.push({
                key: f.field,
                label: L[f.label],
                value: f.date ? formatDate(v, this.lang) : String(v),
                long: !!f.long
            });
        });
        const p = d.pipeline || {};
        if (p.label) rows.push({ key: 'pipeline', label: L.sfOnThisJob, value: p.label });
        return rows;
    }

    get skills() {
        return ((this.detail && this.detail.skills) || []).map((s, i) => ({
            id: `s${i}`,
            label: s
        }));
    }

    get hasSkills() {
        return this.skills.length > 0;
    }

    get notes() {
        return ((this.detail && this.detail.recentNotes) || []).map((n, i) => {
            const m = /^\[([^\]]*)\]\s*([\s\S]*)$/.exec(n);
            return { id: `n${i}`, head: m ? m[1] : '', text: m ? m[2] : n };
        });
    }

    get hasNotes() {
        return this.notes.length > 0;
    }

    get showDetailEmpty() {
        return !this.detailLoading && !this.detailError && !this.detail && this.hasRecord;
    }

    // ─── Actions ────────────────────────────────────

    openRecord() {
        if (!this.hasRecord) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this._row.contactId,
                objectApiName: 'Contact',
                actionName: 'view'
            }
        });
    }

    handleShortlist() {
        this.dispatchEvent(new CustomEvent('shortlist', { detail: { docId: this._row.docId } }));
    }

    handleDismiss() {
        this.dispatchEvent(new CustomEvent('dismiss', { detail: { docId: this._row.docId } }));
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    handlePrev() {
        this.dispatchEvent(new CustomEvent('navigate', { detail: { delta: -1 } }));
    }

    handleNext() {
        this.dispatchEvent(new CustomEvent('navigate', { detail: { delta: 1 } }));
    }

    handleKeydown(event) {
        const tag = (event.target && event.target.tagName) || '';
        if (/INPUT|TEXTAREA|SELECT/.test(tag)) return;
        if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            this.handleClose();
        } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            if (event.target && event.target.getAttribute && event.target.getAttribute('role') === 'tab') return;
            event.preventDefault();
            event.stopPropagation();
            this.dispatchEvent(
                new CustomEvent('navigate', {
                    detail: { delta: event.key === 'ArrowDown' ? 1 : -1 }
                })
            );
        }
    }
}
