import { LightningElement, api, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { loadStyle } from 'lightning/platformResourceLoader';
import MONTSERRAT from '@salesforce/resourceUrl/Montserrat';

import parseQuery from '@salesforce/apex/CandidateSearchController.parseQuery';
import startJobMatch from '@salesforce/apex/CandidateSearchController.startJobMatch';
import runSearch from '@salesforce/apex/CandidateSearchController.runSearch';
import refine from '@salesforce/apex/CandidateSearchController.refine';
import explainResults from '@salesforce/apex/CandidateSearchController.explainResults';
import getRecentAndSaved from '@salesforce/apex/CandidateSearchController.getRecentAndSaved';
import saveSearch from '@salesforce/apex/CandidateSearchController.saveSearch';
import setFavourite from '@salesforce/apex/CandidateSearchController.setFavourite';
import getCompareData from '@salesforce/apex/CandidateSearchController.getCompareData';
import bulkAddToJob from '@salesforce/apex/CandidateSearchController.bulkAddToJob';
import bulkAddToTalentPool from '@salesforce/apex/CandidateSearchController.bulkAddToTalentPool';
import logAction from '@salesforce/apex/CandidateSearchController.logAction';

import { PAGE_SIZE, EXPLAIN_BATCH, COMPARE_MIN, COMPARE_MAX, clone, withoutTrace, diffLines, facetLabel, normalizeError, sleep } from 'c/csUtils';

/** Montserrat @font-face rules (Static Resource). Fonts are page-wide, so child components inherit them. */
function loadFont(cmp) {
    loadStyle(cmp, MONTSERRAT).catch(() => {
        // The fallback font stack still renders
    });
}

const EXPLAIN_QUEUE_MS = 400;
const AUTO_LOAD_LIMIT = 5;
const CHAT_HISTORY_TURNS = 6;

/**
 * candidateSearchApp: the Candidate Search App Page (spec section 10). Holds all state; children get data
 * through @api and raise events.
 *
 * Entry points: c__jobId (Match button on the job) and c__q (Home page launcher) in the page state. Both are
 * re-read when they change, so a second Match click from another job works without a reload.
 */
export default class CandidateSearchApp extends LightningElement {
    /** App Builder: logo image URL (for example /resource/AmplifyLogo). Blank shows the Amplify wordmark. */
    @api logoUrl;
    /** App Builder: page title under the logo. */
    @api heading = 'Candidate Search';

    /** [{ id, title, message, variant, cls, icon }] */
    toasts = [];
    _toastId = 0;

    // ─── Search state ──────────────────────────────
    criteria = null;
    /** Undo stack: criteria snapshots (no trace), one per change. */
    history = [];
    auditId = null;
    rows = [];
    total = 0;
    hasMore = false;
    nextOffset = 0;
    facets = [];
    notices = [];
    hiddenCount = 0;
    requestXml = null;
    error = null;
    loading = false;
    loadingMore = false;
    initialText = '';
    started = false;

    /** docId to { state: 'pending'|'done'|'none'|'error', summary, criteria, error }. */
    explanations = {};
    prevRanks = null;
    removedCount = 0;

    // ─── Panels ────────────────────────────────────
    panelDocId = null;
    chatOpen = false;
    chatTurns = [];
    chatBusy = false;
    /** docId to { docId, contactId, name }. */
    selected = {};
    bulkBusy = false;
    compareOpen = false;
    compareData = null;
    compareLoading = false;
    compareError = null;

    // ─── Home ──────────────────────────────────────
    homeData = null;
    homeLoading = false;
    homeError = null;

    _seq = 0;
    _handledKey = null;
    _explainQueue = [];
    _explainTimer;
    _autoLoads = 0;
    _turnId = 0;
    _focusPanel = false;
    _focusChat = false;

    connectedCallback() {
        loadFont(this);
        this.loadHome();
    }

    disconnectedCallback() {
        if (this._onResize) window.removeEventListener('resize', this._onResize);
    }

    /**
     * The workspace fills the window below where it starts (the Salesforce header and the hero vary), so the list,
     * panel and chat scroll inside it and the chat's message box stays on screen.
     */
    fitWorkspace() {
        const ws = this.template.querySelector('.workspace');
        if (!ws || window.innerWidth < 900) {
            if (ws) ws.style.height = '';
            return;
        }
        const top = ws.getBoundingClientRect().top + window.scrollY;
        const h = Math.max(520, window.innerHeight - top - 16);
        if (ws.style.height !== `${h}px`) ws.style.height = `${h}px`;
    }

    renderedCallback() {
        if (!this._onResize) {
            this._onResize = () => this.fitWorkspace();
            window.addEventListener('resize', this._onResize);
        }
        this.fitWorkspace();
        this.placePanel();
        if (this._focusPanel) {
            const panel = this.template.querySelector('c-cs-candidate-panel');
            if (panel) {
                this._focusPanel = false;
                panel.focus();
            }
        }
        if (this._focusChat) {
            const chat = this.template.querySelector('c-cs-refine-chat');
            if (chat) {
                this._focusChat = false;
                chat.focus();
            }
        }
    }

    @wire(CurrentPageReference)
    handlePageRef(ref) {
        const state = (ref && ref.state) || {};
        const jobId = state.c__jobId || null;
        const q = state.c__q || null;
        const key = `${jobId || ''}|${q || ''}`;
        if (key === this._handledKey) return;
        this._handledKey = key;
        if (jobId) {
            this.startJob(jobId);
        } else if (q) {
            this.initialText = q;
            this.searchText(q);
        }
    }

    // ═════════════════════════════════════════════
    // View getters
    // ═════════════════════════════════════════════

    get showHome() {
        return !this.started;
    }

    get hasResults() {
        return this.started && !!this.criteria;
    }

    get workspaceCls() {
        return `workspace${this.chatOpen ? ' with-chat' : ''}${this.hasSelection ? ' with-tray' : ''}${this.panelDocId ? ' with-panel' : ''}`;
    }

    get panelRow() {
        return this.panelDocId ? this.rows.find((r) => r.docId === this.panelDocId) || null : null;
    }

    get panelExplanation() {
        return this.panelDocId ? this.explanations[this.panelDocId] || null : null;
    }

    get panelPosition() {
        const i = this.rows.findIndex((r) => r.docId === this.panelDocId);
        return i < 0 ? '' : `${i + 1} of ${this.total || this.rows.length}`;
    }

    get canShortlist() {
        return !!(this.criteria && this.criteria.jobId);
    }

    get jobId() {
        return (this.criteria && this.criteria.jobId) || null;
    }

    get selectedList() {
        return Object.values(this.selected);
    }

    get selectedIds() {
        return Object.keys(this.selected);
    }

    get hasSelection() {
        return this.selectedIds.length > 0;
    }

    get canUndo() {
        return this.history.length > 0;
    }

    get showChatToggle() {
        return this.hasResults && !this.chatOpen;
    }

    get busy() {
        return this.loading || this.chatBusy;
    }

    // ═════════════════════════════════════════════
    // Home: recent, saved, favourites
    // ═════════════════════════════════════════════

    async loadHome() {
        this.homeLoading = true;
        try {
            this.homeData = JSON.parse(await getRecentAndSaved());
            this.homeError = null;
        } catch (e) {
            this.homeError = normalizeError(e);
        } finally {
            this.homeLoading = false;
        }
    }

    handleRunSaved(event) {
        const { id, saved } = event.detail;
        const d = this.homeData || {};
        const rec = [...(d.saved || []), ...(d.recent || [])].find((s) => s.Id === id);
        if (!rec || !rec.Criteria_JSON__c) {
            this.toast('Search not found', 'That search has no criteria to run.', 'warning');
            return;
        }
        let criteria;
        try {
            criteria = JSON.parse(rec.Criteria_JSON__c);
        } catch (e) {
            this.toast('Search could not be read', normalizeError(e), 'error');
            return;
        }
        criteria.trace = saved ? { searchType: 'Saved search', savedSearchId: id } : { searchType: 'Manual' };
        this.initialText = criteria.naturalLanguage || '';
        this.resetForNewSearch();
        this.execute(criteria, { seq: ++this._seq, compare: false });
    }

    async handleFavourite(event) {
        const { id, favourite } = event.detail;
        try {
            await setFavourite({ savedSearchId: id, favourite });
            await this.loadHome();
        } catch (e) {
            this.toast('Favourite not changed', normalizeError(e), 'error');
        }
    }

    async handleSave(event) {
        const name = ((event.detail && event.detail.name) || '').trim();
        if (!this.criteria || !name) return;
        try {
            await saveSearch({ name, criteriaJson: JSON.stringify(withoutTrace(this.criteria)), favourite: false });
            this.toast('Search saved', `"${name}" is in your saved searches.`, 'success');
            this.loadHome();
        } catch (e) {
            this.toast('Search not saved', normalizeError(e), 'error');
        }
    }

    handleRunExample(event) {
        const text = event.detail.text;
        this.initialText = text;
        this.searchText(text);
    }

    handleClear() {
        this._seq++;
        this.resetForNewSearch();
        this.started = false;
        this.criteria = null;
        this.history = [];
        this.chatOpen = false;
        this.chatTurns = [];
        this.initialText = '';
        this.loading = false;
        this.loadingMore = false;
        this.chatBusy = false;
        this.loadHome();
    }

    // ═════════════════════════════════════════════
    // Searching
    // ═════════════════════════════════════════════

    resetForNewSearch() {
        clearTimeout(this._explainTimer);
        this._explainQueue = [];
        this.started = true;
        this.rows = [];
        this.total = 0;
        this.hasMore = false;
        this.nextOffset = 0;
        this.facets = [];
        this.notices = [];
        this.hiddenCount = 0;
        this.requestXml = null;
        this.error = null;
        this.auditId = null;
        this.explanations = {};
        this.prevRanks = null;
        this.removedCount = 0;
        this.panelDocId = null;
        this.selected = {};
        this.compareOpen = false;
    }

    handleSearch(event) {
        this.searchText(event.detail.text);
    }

    async searchText(text) {
        const seq = ++this._seq;
        this.resetForNewSearch();
        this.history = [];
        this.chatTurns = [];
        this.loading = true;
        try {
            const criteria = JSON.parse(await parseQuery({ text }));
            if (seq !== this._seq) return;
            this.criteria = criteria;
            await this.execute(criteria, { seq, compare: false });
        } catch (e) {
            if (seq !== this._seq) return;
            this.error = normalizeError(e);
            this.loading = false;
        }
    }

    async startJob(jobId) {
        const seq = ++this._seq;
        this.resetForNewSearch();
        this.history = [];
        this.initialText = '';
        this.criteria = null;
        this.chatOpen = true;
        this.chatTurns = [this.turn('system', 'Matching candidates to the job…')];
        this.loading = true;
        try {
            const res = JSON.parse(await startJobMatch({ jobId }));
            if (seq !== this._seq) return;
            this.applyFirstPage(res, null, seq);
            const lines = [...(res.notices || [])];
            lines.push(res.error ? res.error : `${res.total || 0} candidate${res.total === 1 ? '' : 's'}.`);
            this.chatTurns = [this.turn('system', lines.join('\n'))];
        } catch (e) {
            if (seq !== this._seq) return;
            this.error = normalizeError(e);
            this.loading = false;
            this.chatTurns = [this.turn('system', `The job match could not run: ${this.error}`)];
        }
    }

    /**
     * Runs page 1 of the criteria. compare = true marks rank changes against the current result set
     * (after a refine, chip edit, facet or undo).
     */
    async execute(criteria, { seq, compare }) {
        const prev = compare ? this.currentRanks() : null;
        this.loading = true;
        this.error = null;
        this.criteria = withoutTrace(criteria);
        try {
            const res = JSON.parse(
                await runSearch({
                    criteriaJson: JSON.stringify(criteria),
                    offset: 0,
                    auditId: null
                })
            );
            if (seq !== this._seq) return null;
            this.applyFirstPage(res, prev, seq);
            return res;
        } catch (e) {
            if (seq !== this._seq) return null;
            this.error = normalizeError(e);
            this.rows = [];
            this.loading = false;
            return null;
        }
    }

    currentRanks() {
        const ranks = {};
        this.rows.forEach((r) => {
            ranks[r.docId] = r.rank;
        });
        return this.rows.length ? ranks : null;
    }

    applyFirstPage(res, prevRanks, seq) {
        this.auditId = res.auditId || null;
        if (res.criteria) this.criteria = withoutTrace(res.criteria);
        this.rows = res.rows || [];
        this.total = res.total || 0;
        this.hasMore = res.hasMore === true;
        this.nextOffset = res.nextOffset !== undefined ? res.nextOffset : this.rows.length;
        this.facets = res.facets || [];
        this.notices = res.notices || [];
        this.hiddenCount = res.hiddenCount || 0;
        this.requestXml = res.requestXml || null;
        this.error = res.error || null;
        this.explanations = {};
        this._autoLoads = 0;
        this.loading = false;

        this.prevRanks = prevRanks;
        if (prevRanks) {
            const now = new Set(this.rows.map((r) => r.docId));
            this.removedCount = Object.keys(prevRanks).filter((d) => prevRanks[d] <= PAGE_SIZE && !now.has(d)).length;
        } else {
            this.removedCount = 0;
        }
        if (this.panelDocId && !this.rows.some((r) => r.docId === this.panelDocId)) this.panelDocId = null;

        if (!this.error && this.rows.length && this.auditId) this.explainFirstPage(seq);
        if (res.autoLoadMore) this.loadMore(true);
    }

    async handleLoadMore() {
        await this.loadMore(false);
    }

    async loadMore(auto) {
        if (!this.hasMore || this.loadingMore || !this.auditId || !this.criteria) return;
        if (auto) {
            if (this._autoLoads >= AUTO_LOAD_LIMIT) return;
            this._autoLoads++;
        }
        const seq = this._seq;
        let again = false;
        this.loadingMore = true;
        try {
            const res = JSON.parse(
                await runSearch({
                    criteriaJson: JSON.stringify(withoutTrace(this.criteria)),
                    offset: this.nextOffset,
                    auditId: this.auditId
                })
            );
            if (seq !== this._seq) return;
            if (res.error) {
                this.toast('More results could not load', res.error, 'error');
                this.hasMore = false;
                return;
            }
            const have = new Set(this.rows.map((r) => r.docId));
            this.rows = [...this.rows, ...(res.rows || []).filter((r) => !have.has(r.docId))];
            this.hasMore = res.hasMore === true;
            this.nextOffset = res.nextOffset !== undefined ? res.nextOffset : this.nextOffset + PAGE_SIZE;
            this.hiddenCount += res.hiddenCount || 0;
            const known = new Set(this.notices);
            (res.notices || []).forEach((n) => {
                if (!known.has(n)) this.notices = [...this.notices, n];
            });
            again = res.autoLoadMore === true;
        } catch (e) {
            if (seq === this._seq) {
                this.toast('More results could not load', normalizeError(e), 'error');
                this.hasMore = false;
            }
        } finally {
            if (seq === this._seq) this.loadingMore = false;
        }
        // More than half a page hidden by the pipeline exclusion: fetch the next page straight away (section 8)
        if (again && seq === this._seq) this.loadMore(true);
    }

    // ═════════════════════════════════════════════
    // Criteria changes, undo
    // ═════════════════════════════════════════════

    pushHistory() {
        if (this.criteria) this.history = [...this.history, withoutTrace(this.criteria)];
    }

    changeCriteria(criteria, summary) {
        // A chip added from the type-ahead on the home page starts a search
        if (!this.started) this.resetForNewSearch();
        this.pushHistory();
        const next = clone(criteria);
        next.trace = { searchType: 'Manual', parentAuditId: this.auditId };
        if (summary) this.chatTurns = [...this.chatTurns, this.turn('system', summary, { change: true })];
        this.execute(next, { seq: ++this._seq, compare: true });
    }

    handleCriteriaChange(event) {
        this.changeCriteria(event.detail.criteria, event.detail.summary);
    }

    handleFacetChange(event) {
        const { field, values } = event.detail;
        const c = clone(this.criteria);
        c.filters = c.filters || {};
        if (values.length) c.filters[field] = values;
        else delete c.filters[field];
        this.changeCriteria(c, values.length ? `Filter ${facetLabel(field)}: ${values.join(', ')}` : `Cleared filter ${facetLabel(field)}`);
    }

    handleShowHidden() {
        const c = clone(this.criteria);
        c.exclusions = c.exclusions || {};
        delete c.exclusions.pipelineForJob;
        this.changeCriteria(c, 'Showing candidates already on this job');
    }

    handleUndo() {
        if (!this.history.length || this.busy) return;
        const prev = this.history[this.history.length - 1];
        this.history = this.history.slice(0, -1);
        const turns = [...this.chatTurns];
        for (let i = turns.length - 1; i >= 0; i--) {
            if (turns[i].change && !turns[i].undone) {
                turns[i] = { ...turns[i], undone: true };
                break;
            }
        }
        this.chatTurns = [...turns, this.turn('system', 'Undid the last change.')];
        const next = clone(prev);
        next.trace = { searchType: 'Manual', parentAuditId: this.auditId };
        this.execute(next, { seq: ++this._seq, compare: true });
    }

    /** Back to the criteria as first run (the bottom of the undo stack), as one more undoable step. */
    handleReset() {
        if (!this.history.length || this.busy) return;
        const first = this.history[0];
        this.pushHistory();
        this.chatTurns = [...this.chatTurns, this.turn('system', 'Reset to the original search.', { change: true })];
        const next = clone(first);
        next.trace = { searchType: 'Manual', parentAuditId: this.auditId };
        this.execute(next, { seq: ++this._seq, compare: true });
    }

    // ═════════════════════════════════════════════
    // Refine chat
    // ═════════════════════════════════════════════

    turn(role, text, extra = {}) {
        this._turnId++;
        return { id: `t${this._turnId}`, role, text, diff: [], ...extra };
    }

    openChat() {
        this.chatOpen = true;
        this._focusChat = true;
    }

    closeChat() {
        this.chatOpen = false;
    }

    async handleRefine(event) {
        const message = event.detail.message;
        if (!this.criteria) return;
        const history = this.chatTurns
            .filter((t) => t.role === 'user' || t.role === 'assistant')
            .slice(-CHAT_HISTORY_TURNS)
            .map((t) => ({ role: t.role, text: t.text }));
        this.chatTurns = [...this.chatTurns, this.turn('user', message)];
        this.chatBusy = true;
        try {
            const res = JSON.parse(
                await refine({
                    criteriaJson: JSON.stringify(withoutTrace(this.criteria)),
                    message,
                    historyJson: JSON.stringify(history),
                    auditId: this.auditId
                })
            );
            const changed = !res.needsClarification && (res.patch || []).length > 0;
            this.chatTurns = [
                ...this.chatTurns,
                this.turn('assistant', res.reply || (changed ? 'Done.' : ''), {
                    diff: diffLines(res.diff),
                    change: changed
                })
            ];
            if (changed) {
                this.pushHistory();
                const out = await this.execute(res.criteria, {
                    seq: ++this._seq,
                    compare: true
                });
                if (out) {
                    this.chatTurns = [
                        ...this.chatTurns,
                        this.turn('system', out.error ? out.error : `${out.total || 0} candidate${out.total === 1 ? '' : 's'}.`)
                    ];
                }
            }
        } catch (e) {
            this.chatTurns = [...this.chatTurns, this.turn('system', normalizeError(e))];
        } finally {
            this.chatBusy = false;
        }
    }

    // ═════════════════════════════════════════════
    // Explanations
    // ═════════════════════════════════════════════

    setExplanations(docIds, value) {
        const next = { ...this.explanations };
        docIds.forEach((d) => {
            next[d] = typeof value === 'function' ? value(d) : value;
        });
        this.explanations = next;
    }

    async explainFirstPage(seq) {
        const docIds = this.rows.slice(0, PAGE_SIZE).map((r) => r.docId);
        this.setExplanations(docIds, { state: 'pending' });
        for (let i = 0; i < docIds.length; i += EXPLAIN_BATCH) {
            if (seq !== this._seq) return;
            // eslint-disable-next-line no-await-in-loop
            await this.explainBatch(docIds.slice(i, i + EXPLAIN_BATCH), seq, this.auditId, 0);
        }
    }

    /** The audit rows are written by a Queueable, so the first call can arrive before they exist: retry with backoff. */
    async explainBatch(docIds, seq, auditId, attempt) {
        if (!docIds.length) return;
        try {
            const list = JSON.parse(await explainResults({ auditId, docIdsJson: JSON.stringify(docIds) }));
            if (seq !== this._seq) return;
            const got = {};
            (list || []).forEach((e) => {
                got[e.docId] = e;
            });
            const done = docIds.filter((d) => got[d]);
            this.setExplanations(done, (d) => ({
                state: 'done',
                summary: got[d].summary,
                criteria: got[d].criteria || []
            }));
            const missing = docIds.filter((d) => !got[d]);
            if (missing.length) {
                if (attempt < 3) {
                    await sleep(1500 * (attempt + 1));
                    if (seq !== this._seq) return;
                    await this.explainBatch(missing, seq, auditId, attempt + 1);
                } else {
                    this.setExplanations(missing, { state: 'none' });
                }
            }
        } catch (e) {
            if (seq !== this._seq) return;
            const msg = normalizeError(e);
            if (/still being saved/i.test(msg) && attempt < 5) {
                await sleep(1200 * (attempt + 1));
                if (seq !== this._seq) return;
                await this.explainBatch(docIds, seq, auditId, attempt + 1);
                return;
            }
            this.setExplanations(docIds, { state: 'error', error: msg });
        }
    }

    handleExplainRow(event) {
        this.queueExplain(event.detail.docId);
    }

    queueExplain(docId) {
        if (!docId || !this.auditId) return;
        const cur = this.explanations[docId];
        if (cur && (cur.state === 'pending' || cur.state === 'done')) return;
        this.setExplanations([docId], { state: 'pending' });
        if (!this._explainQueue.includes(docId)) this._explainQueue.push(docId);
        clearTimeout(this._explainTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._explainTimer = setTimeout(() => this.flushExplainQueue(), EXPLAIN_QUEUE_MS);
    }

    async flushExplainQueue() {
        const seq = this._seq;
        const auditId = this.auditId;
        while (this._explainQueue.length && seq === this._seq) {
            const batch = this._explainQueue.splice(0, EXPLAIN_BATCH);
            // eslint-disable-next-line no-await-in-loop
            await this.explainBatch(batch, seq, auditId, 0);
        }
    }

    // ═════════════════════════════════════════════
    // Candidate panel
    // ═════════════════════════════════════════════

    handleRowOpen(event) {
        this.openPanel(event.detail.docId);
    }

    /**
     * The drawer starts just under the Salesforce header: this component's distance from the top of the document
     * (the header is fixed, so that offset does not change with scrolling).
     */
    placePanel() {
        const wrap = this.template.querySelector('.panel-wrap');
        if (!wrap || window.innerWidth < 900) return;
        const app = this.template.querySelector('.app');
        const offset = app ? app.getBoundingClientRect().top + window.scrollY : 96;
        const top = `${Math.round(Math.min(Math.max(offset, 16), 200))}px`;
        if (wrap.style.getPropertyValue('--cs-panel-top') !== top) wrap.style.setProperty('--cs-panel-top', top);
    }

    openPanel(docId) {
        const row = this.rows.find((r) => r.docId === docId);
        if (!row) return;
        this.panelDocId = docId;
        this._focusPanel = true;
        const ex = this.explanations[docId];
        if (!ex || ex.state === 'none') this.queueExplain(docId);
        // Rows with a Contact are logged as opened by getCandidateDetail
        if (!row.contactId && this.auditId) this.log(docId, 'opened');
    }

    closePanel() {
        const docId = this.panelDocId;
        this.panelDocId = null;

        Promise.resolve().then(() => {
            const list = this.template.querySelector('c-cs-result-list');
            if (list && docId) list.focusRow(docId);
        });
    }

    handlePanelNavigate(event) {
        const i = this.rows.findIndex((r) => r.docId === this.panelDocId);
        if (i < 0) return;
        const j = i + event.detail.delta;
        if (j >= this.rows.length - 3 && this.hasMore) this.loadMore(false);
        if (j < 0 || j >= this.rows.length) return;
        this.openPanel(this.rows[j].docId);
    }

    async handlePanelShortlist(event) {
        const row = this.rows.find((r) => r.docId === event.detail.docId);
        if (!row || !row.contactId || !this.jobId) return;
        await this.addToJob(this.jobId, [row]);
    }

    handlePanelDismiss(event) {
        const docId = event.detail.docId;
        const i = this.rows.findIndex((r) => r.docId === docId);
        this.log(docId, 'dismissed');
        this.rows = this.rows.filter((r) => r.docId !== docId);
        this.deselect(docId);
        const next = this.rows[i] || this.rows[i - 1];
        if (next) this.openPanel(next.docId);
        else this.panelDocId = null;
    }

    async log(docId, action) {
        if (!this.auditId) return;
        try {
            await logAction({ auditId: this.auditId, docId, action });
        } catch (e) {
            // An audit failure never blocks the recruiter

            console.warn('[CandidateSearch] action not logged', normalizeError(e));
        }
    }

    // ═════════════════════════════════════════════
    // Selection, compare, bulk actions
    // ═════════════════════════════════════════════

    handleRowSelect(event) {
        const { docId, checked } = event.detail;
        if (checked) {
            const r = this.rows.find((x) => x.docId === docId);
            if (r && r.contactId)
                this.selected = {
                    ...this.selected,
                    [docId]: { docId, contactId: r.contactId, name: r.name }
                };
        } else {
            this.deselect(docId);
        }
    }

    handleSelectPage(event) {
        if (event.detail.checked) {
            const next = { ...this.selected };
            this.rows.forEach((r) => {
                if (r.contactId)
                    next[r.docId] = {
                        docId: r.docId,
                        contactId: r.contactId,
                        name: r.name
                    };
            });
            this.selected = next;
        } else {
            this.selected = {};
        }
    }

    deselect(docId) {
        if (!this.selected[docId]) return;
        const next = { ...this.selected };
        delete next[docId];
        this.selected = next;
    }

    handleTrayDeselect(event) {
        this.deselect(event.detail.docId);
    }

    clearSelection() {
        this.selected = {};
    }

    async handleCompare() {
        const list = this.selectedList;
        if (list.length < COMPARE_MIN || list.length > COMPARE_MAX) return;
        this.compareOpen = true;
        this.compareLoading = true;
        this.compareError = null;
        this.compareData = null;
        try {
            this.compareData = JSON.parse(
                await getCompareData({
                    contactIdsJson: JSON.stringify(list.map((s) => s.contactId)),
                    auditId: this.auditId
                })
            );
        } catch (e) {
            this.compareError = normalizeError(e);
        } finally {
            this.compareLoading = false;
        }

        Promise.resolve().then(() => {
            const cmp = this.template.querySelector('c-cs-compare');
            if (cmp) cmp.focus();
        });
    }

    closeCompare() {
        this.compareOpen = false;
    }

    handleCompareRemove(event) {
        const contactId = event.detail.contactId;
        const sel = this.selectedList.find((s) => s.contactId === contactId);
        if (sel) this.deselect(sel.docId);
        if (this.compareData) {
            this.compareData = {
                ...this.compareData,
                candidates: this.compareData.candidates.filter((c) => c.contactId !== contactId)
            };
        }
    }

    stopBackdrop(event) {
        event.stopPropagation();
    }

    async handleAddToJob(event) {
        await this.addToJob(event.detail.jobId, this.selectedList);
    }

    async addToJob(jobId, people) {
        if (!jobId || !people.length) return;
        this.bulkBusy = true;
        try {
            const res = JSON.parse(
                await bulkAddToJob({
                    jobId,
                    contactIdsJson: JSON.stringify(people.map((p) => p.contactId)),
                    auditId: this.auditId
                })
            );
            this.bulkToast(res);
            if (jobId === this.jobId && (res.addedIds || []).length) {
                const added = new Set(res.addedIds);
                this.rows = this.rows.map((r) => {
                    if (!added.has(r.contactId)) return r;
                    const p = r.pipeline || {};
                    return {
                        ...r,
                        pipeline: {
                            ...p,
                            shortlisted: true,
                            label: p.label ? `${p.label}, Shortlisted` : 'Shortlisted'
                        }
                    };
                });
            }
            if ((res.addedIds || []).length) this.clearAdded(res.addedIds);
        } catch (e) {
            this.toast('Not added to the job', normalizeError(e), 'error');
        } finally {
            this.bulkBusy = false;
        }
    }

    async handleAddToPool(event) {
        const poolId = event.detail.poolId;
        const people = this.selectedList;
        if (!poolId || !people.length) return;
        this.bulkBusy = true;
        try {
            const res = JSON.parse(
                await bulkAddToTalentPool({
                    poolId,
                    contactIdsJson: JSON.stringify(people.map((p) => p.contactId)),
                    auditId: this.auditId
                })
            );
            this.bulkToast(res);
            if ((res.addedIds || []).length) this.clearAdded(res.addedIds);
        } catch (e) {
            this.toast('Not added to the talent pool', normalizeError(e), 'error');
        } finally {
            this.bulkBusy = false;
        }
    }

    clearAdded(contactIds) {
        const added = new Set(contactIds);
        const next = {};
        Object.values(this.selected).forEach((s) => {
            if (!added.has(s.contactId)) next[s.docId] = s;
        });
        this.selected = next;
    }

    bulkToast(res) {
        const failed = (res.failed || []).length;
        const details = (res.failed || [])
            .slice(0, 3)
            .map((f) => `${f.name || f.contactId}: ${f.error}`)
            .join('\n');
        this.toast(
            res.added ? 'Added' : 'Nothing added',
            details ? `${res.message}\n${details}` : res.message,
            failed ? 'warning' : res.added ? 'success' : 'info'
        );
    }

    // ─── Parse a CV (existing c-tx-resume-parser in a modal) ──

    parserOpen = false;

    openParser() {
        this.parserOpen = true;

        Promise.resolve().then(() => {
            const btn = this.template.querySelector('.parser-close');
            if (btn) btn.focus();
        });
    }

    /** Closes only on the button or Escape, so a half-finished parse is not lost to a stray click. */
    closeParser() {
        this.parserOpen = false;
        this.loadHome();
    }

    parserKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.closeParser();
        }
    }

    toast(title, message, variant) {
        const id = `toast${++this._toastId}`;
        const icon = variant === 'success' ? 'check' : variant === 'info' ? 'message' : 'alert';
        this.toasts = [...this.toasts.slice(-2), { id, title, message, variant, icon, cls: `toast toast-${variant}` }];
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.removeToast(id), variant === 'error' || variant === 'warning' ? 10000 : 5000);
    }

    removeToast(id) {
        this.toasts = this.toasts.filter((t) => t.id !== id);
    }

    dismissToast(event) {
        this.removeToast(event.currentTarget.dataset.id);
    }

    get hasToasts() {
        return this.toasts.length > 0;
    }

    get heroCls() {
        return `hero${this.started ? ' compact' : ''}`;
    }

    get resultTitle() {
        if (this.loading) return 'Searching…';
        if (!this.criteria) return '';
        if (this.criteria.jobId) return 'Job match';
        return 'Results';
    }
}
