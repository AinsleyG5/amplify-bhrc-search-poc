import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getCandidateDetail from '@salesforce/apex/CandidateSearchController.getCandidateDetail';
import { metAndNotMet, kindLabel, weightLabel, formatDate, highlightSegments, initials, avatarClass, ring, normalizeError, READ_ONLY_KINDS } from 'c/csUtils';

const TABS = [
    { value: 'why', label: 'Why' },
    { value: 'cv', label: 'CV' },
    { value: 'profile', label: 'Profile' },
    { value: 'skills', label: 'Skills' },
    { value: 'activity', label: 'Activity' }
];

/** Chip kinds whose values are words to look for in the CV (not locations, dates or Textkernel-generated parts). */
const CV_TERM_KINDS = new Set(['title', 'skill', 'certification', 'keyword', 'language', 'shift']);

const PROFILE_FIELDS = [
    { field: 'TR1__Candidate_Status__c', label: 'Status' },
    { field: 'Date_Available__c', label: 'Available from', date: true },
    { field: 'TR1__Date_Available__c', label: 'Available from', date: true },
    { field: 'TR1__Last_Placement_Date__c', label: 'Last placed', date: true },
    { field: 'TR1__Candidate_Summary__c', label: 'Summary', long: true }
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
            const res = JSON.parse(await getCandidateDetail({ contactId, auditId: this.auditId }));
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
        return (this._row && this._row.name) || 'Unnamed candidate';
    }

    get subtitle() {
        const r = this._row || {};
        return [r.title, r.city].filter(Boolean).join(' · ');
    }

    get scoreText() {
        const s = this._row && this._row.scorePct;
        return s === null || s === undefined ? '' : `${Math.round(s)}% match`;
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
        return `Candidate ${this.name}`;
    }

    // ─── Tabs ───────────────────────────────────────

    get tabs() {
        return TABS.map((t) => ({
            ...t,
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

    get isActivity() {
        return this.tab === 'activity';
    }

    selectTab(event) {
        this.tab = event.currentTarget.dataset.tab;
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
            const status = excluded ? 'Excluded' : isMet ? 'Met' : isNotMet ? 'Not met' : 'Not scored';
            return {
                id: it.id,
                label: READ_ONLY_KINDS.has(it.kind) ? it.label || 'Job description' : it.label || it.value,
                meta: `${kindLabel(it.kind)} · ${weightLabel(it.weight)}`,
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
        if (d.title) rows.push({ key: 'title', label: 'Title', value: d.title });
        if (d.city) rows.push({ key: 'city', label: 'City', value: d.city });
        if (d.owner) rows.push({ key: 'owner', label: 'Owner', value: d.owner });
        const profile = d.profile || {};
        const seen = new Set();
        PROFILE_FIELDS.forEach((f) => {
            const v = profile[f.field];
            if (v === null || v === undefined || v === '' || seen.has(f.label)) return;
            seen.add(f.label);
            rows.push({
                key: f.field,
                label: f.label,
                value: f.date ? formatDate(v) : String(v),
                long: !!f.long
            });
        });
        const p = d.pipeline || {};
        if (p.label) rows.push({ key: 'pipeline', label: 'On this job', value: p.label });
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
