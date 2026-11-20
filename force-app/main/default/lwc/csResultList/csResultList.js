import { LightningElement, api } from 'lwc';
import getColumnOptions from '@salesforce/apex/CandidateSearchController.getColumnOptions';
import getColumnValues from '@salesforce/apex/CandidateSearchController.getColumnValues';
import {
    metAndNotMet,
    changeTag,
    facetLabel,
    prettyXmlLines,
    initials,
    avatarClass,
    ring,
    weightLabel,
    normalizeError,
    READ_ONLY_KINDS,
    TK_COLUMNS,
    DEFAULT_COLUMNS,
    MAX_COLUMNS,
    tkColumnText,
    sfColumnText
} from 'c/csUtils';

/** Per-browser choice of columns (a convenience: the defaults apply when storage is unavailable). */
const COLUMNS_STORAGE_KEY = 'amp.candidateSearch.columns';
const WIDTHS_STORAGE_KEY = 'amp.candidateSearch.columnWidths';
const SF_BATCH = 200;

/**
 * Row grid. Chosen columns sit between the criteria and the summary at their own widths (dragged in the header);
 * candidate, criteria and summary share what is left. When the columns do not fit even squeezed, they drop to a
 * line of cells under each row.
 */
const COL_DEFAULT = 140;
const COL_MIN = 80;
const COL_MAX = 420;
const COL_SQUEEZE_MIN = 96;
const GRID_GAP = 18;
/** Checkbox 22 + score 48 + row padding 40 + row margin 16. */
const GRID_FIXED = 22 + 48 + 40 + 16;
const FLEX_MIN = { who: 200, crit: 150, why: 200 };
const BASE_GRID = `22px minmax(${FLEX_MIN.who}px,1.2fr) minmax(${FLEX_MIN.crit}px,1fr)`;
const TAIL_GRID = `minmax(${FLEX_MIN.why}px,1.3fr) 48px`;

/**
 * csResultList: result rows, infinite scroll, facet filters, selection, request viewer (screen 2A).
 *
 * Inputs come from candidateSearchApp. Events:
 * - loadmore {}                       the sentinel row came into view and there are more results
 * - rowopen { docId }                  open the candidate panel
 * - rowselect { docId, checked }
 * - selectpage { checked }             select or clear every selectable row loaded
 * - explain { docId }                  explain one row on demand
 * - facetchange { field, values }      new selected values for one facet
 * - showhidden {}                      stop hiding candidates already on the job
 *
 * Columns: the user picks up to MAX_COLUMNS fields, from the Textkernel fields already on each row and from the
 * Contact field set Candidate_Search_Columns (values read with getColumnValues for the loaded rows).
 */
export default class CsResultList extends LightningElement {
    @api
    get rows() {
        return this._rows;
    }
    set rows(value) {
        this._rows = value || [];
        this.loadSfValues();
    }
    _rows = [];
    @api criteria;
    @api explanations = {};
    @api selectedIds = [];
    @api activeDocId;
    /** docId to rank from the previous result set (after a refine or edit), or null. */
    @api prevRanks;
    @api removedCount = 0;
    @api total = 0;
    @api hasMore = false;
    @api loading = false;
    @api loadingMore = false;
    @api hiddenCount = 0;
    @api facets = [];
    @api notices = [];
    @api requestXml;
    @api error;

    facetsOpen = false;
    requestOpen = false;
    _observer;

    // ─── Columns ────────────────────────────────────
    columnKeys = DEFAULT_COLUMNS;
    columnsOpen = false;
    /** [{ path, label, type }] from the Contact field set. */
    sfOptions = [];
    /** contactId to { path: value } */
    sfValues = {};
    sfError = null;
    /** contactIds already read for the current set of Salesforce columns. */
    _sfRead = new Set();
    _sfPathsKey = '';
    /** key to width in px, set by dragging a column edge. */
    colWidths = {};
    /** Measured width of the list (0 until measured: columns then show inline). */
    listWidth = 0;
    _resizeObserver;
    _drag = null;

    connectedCallback() {
        try {
            const saved = JSON.parse(window.localStorage.getItem(COLUMNS_STORAGE_KEY));
            if (Array.isArray(saved)) this.columnKeys = saved.filter((k) => typeof k === 'string').slice(0, MAX_COLUMNS);
            const widths = JSON.parse(window.localStorage.getItem(WIDTHS_STORAGE_KEY));
            if (widths && typeof widths === 'object') this.colWidths = widths;
        } catch {
            // No storage (private window, preview): the defaults apply
        }
        this.loadSfOptions();
    }

    observeWidth() {
        if (this._resizeObserver || typeof ResizeObserver === 'undefined') return;
        const el = this.template.querySelector('.list');
        if (!el) return;
        this._resizeObserver = new ResizeObserver((entries) => {
            const w = Math.round(entries[0].contentRect.width);
            if (Math.abs(w - this.listWidth) > 4) this.listWidth = w;
        });
        this._resizeObserver.observe(el);
    }

    colWidth(key) {
        const w = Number(this.colWidths[key]);
        return w ? Math.max(COL_MIN, Math.min(COL_MAX, w)) : COL_DEFAULT;
    }

    /** { mode: 'none' | 'inline' | 'strip', widths: { key: px }, grid } */
    get layout() {
        const defs = this.columnDefs;
        if (!defs.length) return { mode: 'none', widths: {}, grid: `${BASE_GRID} ${TAIL_GRID}` };
        const wanted = defs.map((c) => this.colWidth(c.key));
        const total = wanted.reduce((a, b) => a + b, 0);
        const room = this.listWidth ? this.listWidth - GRID_FIXED - GRID_GAP * (defs.length + 4) - FLEX_MIN.who - FLEX_MIN.crit - FLEX_MIN.why : Infinity;
        if (room < defs.length * COL_SQUEEZE_MIN) return { mode: 'strip', widths: {}, grid: `${BASE_GRID} ${TAIL_GRID}` };
        const scale = total > room ? room / total : 1;
        const widths = {};
        defs.forEach((c, i) => {
            widths[c.key] = Math.floor(wanted[i] * scale);
        });
        return { mode: 'inline', widths, grid: `${BASE_GRID} ${defs.map((c) => `${widths[c.key]}px`).join(' ')} ${TAIL_GRID}` };
    }

    get gridStyle() {
        return `--cs-row-grid:${this.layout.grid}`;
    }

    get showColumnHeader() {
        return this.layout.mode === 'inline' && this.hasRows && !this.loading;
    }

    get headerCols() {
        const { widths } = this.layout;
        return this.columnDefs.map((c) => ({ key: c.key, label: c.label, width: widths[c.key], resizeLabel: `Resize the ${c.label} column` }));
    }

    // Column resizing: drag the edge in the header; double-click puts the default width back

    startResize(event) {
        const key = event.currentTarget.dataset.key;
        this._drag = { key, startX: event.clientX, startWidth: this.layout.widths[key] || this.colWidth(key) };
        if (event.currentTarget.setPointerCapture) event.currentTarget.setPointerCapture(event.pointerId);
        event.preventDefault();
        event.stopPropagation();
    }

    moveResize(event) {
        if (!this._drag) return;
        const width = Math.max(COL_MIN, Math.min(COL_MAX, Math.round(this._drag.startWidth + event.clientX - this._drag.startX)));
        this.colWidths = { ...this.colWidths, [this._drag.key]: width };
    }

    endResize() {
        if (!this._drag) return;
        this._drag = null;
        this.saveWidths();
    }

    resetWidth(event) {
        const next = { ...this.colWidths };
        delete next[event.currentTarget.dataset.key];
        this.colWidths = next;
        this.saveWidths();
    }

    resizeKeydown(event) {
        const key = event.currentTarget.dataset.key;
        const step = event.shiftKey ? 40 : 10;
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
        event.preventDefault();
        const current = this.colWidth(key);
        this.colWidths = { ...this.colWidths, [key]: Math.max(COL_MIN, Math.min(COL_MAX, current + (event.key === 'ArrowRight' ? step : -step))) };
        this.saveWidths();
    }

    saveWidths() {
        try {
            window.localStorage.setItem(WIDTHS_STORAGE_KEY, JSON.stringify(this.colWidths));
        } catch {
            // No storage: widths last until the page reloads
        }
    }

    async loadSfOptions() {
        try {
            this.sfOptions = JSON.parse((await getColumnOptions()) || '[]') || [];
        } catch (e) {
            this.sfOptions = [];
            this.sfError = normalizeError(e);
        }
        this.loadSfValues();
    }

    get columnDefs() {
        const sf = new Map(this.sfOptions.map((o) => [`sf:${o.path}`, o]));
        const tk = new Map(TK_COLUMNS.map((c) => [c.key, c]));
        return this.columnKeys
            .map((key) => {
                if (tk.has(key)) return { key, label: tk.get(key).label, tk: tk.get(key) };
                if (sf.has(key)) return { key, label: sf.get(key).label, sf: sf.get(key) };
                return null;
            })
            .filter((c) => c);
    }

    get sfPaths() {
        return this.columnDefs.filter((c) => c.sf).map((c) => c.sf.path);
    }

    /** Reads the chosen Salesforce fields for loaded rows not read yet (all rows again when the columns change). */
    async loadSfValues() {
        const paths = this.sfPaths;
        if (!paths.length) return;
        const key = paths.join('|');
        if (key !== this._sfPathsKey) {
            this._sfPathsKey = key;
            this._sfRead = new Set();
            this.sfValues = {};
        }
        const ids = [...new Set((this._rows || []).map((r) => r.contactId).filter((id) => id && !this._sfRead.has(id)))];
        if (!ids.length) return;
        ids.forEach((id) => this._sfRead.add(id));
        for (let i = 0; i < ids.length; i += SF_BATCH) {
            const batch = ids.slice(i, i + SF_BATCH);
            try {
                // eslint-disable-next-line no-await-in-loop
                const res = JSON.parse(await getColumnValues({ contactIdsJson: JSON.stringify(batch), pathsJson: JSON.stringify(paths) }));
                if (key !== this._sfPathsKey) return;
                this.sfValues = { ...this.sfValues, ...(res || {}) };
                this.sfError = null;
            } catch (e) {
                batch.forEach((id) => this._sfRead.delete(id));
                this.sfError = normalizeError(e);
            }
        }
    }

    get hasColumns() {
        return this.columnDefs.length > 0;
    }

    get columnsLabel() {
        return this.columnDefs.length ? `Columns (${this.columnDefs.length})` : 'Columns';
    }

    get columnGroups() {
        const chosen = new Set(this.columnKeys);
        const full = chosen.size >= MAX_COLUMNS;
        const opt = (key, label) => ({
            key,
            label,
            checked: chosen.has(key),
            disabled: !chosen.has(key) && full
        });
        const groups = [{ id: 'tk', label: 'From Textkernel', options: TK_COLUMNS.map((c) => opt(c.key, c.label)) }];
        if (this.sfOptions.length) {
            groups.push({ id: 'sf', label: 'From Salesforce', options: this.sfOptions.map((o) => opt(`sf:${o.path}`, o.label)) });
        }
        return groups;
    }

    get columnsHint() {
        return `Pick up to ${MAX_COLUMNS}. Your admin chooses the Salesforce fields (Contact field set "Candidate Search Columns").`;
    }

    toggleColumns() {
        this.columnsOpen = !this.columnsOpen;
    }

    closeColumns() {
        this.columnsOpen = false;
    }

    handleColumnsKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.columnsOpen = false;
            const btn = this.template.querySelector('.columns-toggle');
            if (btn) btn.focus();
        }
    }

    toggleColumn(event) {
        const key = event.target.dataset.key;
        const next = event.target.checked ? [...this.columnKeys.filter((k) => k !== key), key] : this.columnKeys.filter((k) => k !== key);
        this.setColumns(next.slice(0, MAX_COLUMNS));
    }

    resetColumns() {
        this.setColumns(DEFAULT_COLUMNS);
    }

    setColumns(keys) {
        this.columnKeys = keys;
        try {
            window.localStorage.setItem(COLUMNS_STORAGE_KEY, JSON.stringify(keys));
        } catch {
            // No storage: the choice lasts until the page reloads
        }
        this.loadSfValues();
    }

    /** One cell per chosen column, in the user's order. Same column count on every row, so the cells line up. */
    factsFor(r, defs) {
        const vals = (r.contactId && this.sfValues[r.contactId]) || {};
        return defs.map((c) => {
            const text = c.tk ? tkColumnText(r, c.tk) : sfColumnText(vals[c.sf.path], c.sf.type);
            return {
                key: c.key,
                label: c.label,
                text: text || '–',
                cls: text ? 'fact-val' : 'fact-val fact-empty',
                title: text ? `${c.label}: ${text}` : `${c.label}: not recorded`
            };
        });
    }

    // ─── Infinite scroll ────────────────────────────

    renderedCallback() {
        this.observeWidth();
        const sentinel = this.template.querySelector('.sentinel');
        // A page finished loading while the sentinel stayed in view: observe again so it fires once more
        if (sentinel && this._observed === sentinel && this._wasLoadingMore && !this.loadingMore && this._observer) {
            this._observer.unobserve(sentinel);
            this._observer.observe(sentinel);
        }
        this._wasLoadingMore = this.loadingMore;
        if (!sentinel || this._observed === sentinel) return;
        if (this._observer) this._observer.disconnect();
        if (typeof IntersectionObserver === 'undefined') return;
        this._observer = new IntersectionObserver(
            (entries) => {
                if (entries.some((e) => e.isIntersecting) && this.hasMore && !this.loadingMore && !this.loading) {
                    this.dispatchEvent(new CustomEvent('loadmore'));
                }
            },
            { rootMargin: '200px' }
        );
        this._observer.observe(sentinel);
        this._observed = sentinel;
    }

    disconnectedCallback() {
        if (this._resizeObserver) this._resizeObserver.disconnect();
        this._resizeObserver = null;
        if (this._observer) this._observer.disconnect();
        this._observed = null;
    }

    loadMoreClick() {
        this.dispatchEvent(new CustomEvent('loadmore'));
    }

    // ─── Rows ───────────────────────────────────────

    get chipList() {
        return ((this.criteria && this.criteria.items) || []).filter((it) => it.weight !== 'excluded');
    }

    get items() {
        const selected = new Set(this.selectedIds || []);
        const chips = this.chipList;
        const ex = this.explanations || {};
        const defs = this.columnDefs;
        const mode = this.layout.mode;
        const factsCls = `facts facts-${mode}`;
        return (this.rows || []).map((r) => {
            const { met, notMet } = metAndNotMet(r);
            const criteria = chips.map((c) => {
                const isMet = met.has(c.id);
                const isNotMet = notMet.has(c.id);
                const status = isMet ? 'met' : isNotMet ? 'notmet' : 'na';
                const label = READ_ONLY_KINDS.has(c.kind) ? c.label || 'Job description' : c.label || c.value;
                return {
                    id: c.id,
                    label,
                    status,
                    weight: weightLabel(c.weight),
                    cls: `crit-item crit-${status}`,
                    icon: isMet ? 'check' : isNotMet ? 'x' : 'minus',
                    statusText: isMet ? 'Met' : isNotMet ? 'Not met' : 'Not scored',
                    title: `${label}: ${isMet ? 'met' : isNotMet ? 'not met' : 'not scored separately'} (per Textkernel)`
                };
            });
            const pick = (status) => criteria.filter((c) => c.status === status).map((c) => ({ id: c.id, label: c.label, weight: c.weight }));
            const match = { met: pick('met'), notMet: pick('notmet'), na: pick('na') };
            const p = r.pipeline || {};
            const score = ring(r.scorePct);
            return {
                initials: initials(r.name),
                avatarCls: avatarClass(r.contactId || r.docId),
                ringCls: score.cls,
                ringStyle: score.style,
                ringText: score.text,
                key: r.docId,
                docId: r.docId,
                contactId: r.contactId,
                rank: r.rank,
                name: r.name || 'Unnamed candidate',
                title: r.title,
                city: r.city,
                scorePct: r.scorePct,
                criteria,
                match: {
                    ...match,
                    hasMet: match.met.length > 0,
                    hasNotMet: match.notMet.length > 0,
                    hasNa: match.na.length > 0,
                    summary: `${match.met.length} of ${criteria.length} criteria met`
                },
                facts: defs.length ? this.factsFor(r, defs) : null,
                factsCls,
                pipelineLabel: p.label || null,
                placedRecently: p.placedRecently === true,
                changeTag: changeTag(this.prevRanks, r.docId, r.rank),
                explanation: ex[r.docId] || null,
                selected: selected.has(r.docId),
                selectable: !!r.contactId,
                active: this.activeDocId === r.docId
            };
        });
    }

    get hasRows() {
        return (this.rows || []).length > 0;
    }

    get showEmpty() {
        return !this.loading && !this.error && !this.hasRows;
    }

    get countText() {
        const shown = (this.rows || []).length;
        if (!this.total) return shown ? `${shown} candidates` : 'No candidates';
        return `${this.total} candidate${this.total === 1 ? '' : 's'}${shown < this.total ? `, showing ${shown}` : ''}`;
    }

    get hiddenText() {
        return `Show ${this.hiddenCount} hidden`;
    }

    get removedText() {
        return `${this.removedCount} removed since the last search`;
    }

    get hasNotices() {
        return (this.notices || []).length > 0;
    }

    get noticeItems() {
        return (this.notices || []).map((n, i) => ({ id: `n${i}`, text: n }));
    }

    get pageSelected() {
        const sel = new Set(this.selectedIds || []);
        const selectable = (this.rows || []).filter((r) => r.contactId);
        return selectable.length > 0 && selectable.every((r) => sel.has(r.docId));
    }

    get showEnd() {
        return this.hasRows && !this.hasMore && !this.loadingMore;
    }

    handleRowOpen(event) {
        this.dispatchEvent(new CustomEvent('rowopen', { detail: event.detail }));
    }

    handleRowSelect(event) {
        this.dispatchEvent(new CustomEvent('rowselect', { detail: event.detail }));
    }

    handleExplain(event) {
        this.dispatchEvent(new CustomEvent('explain', { detail: event.detail }));
    }

    handleSelectPage(event) {
        this.dispatchEvent(
            new CustomEvent('selectpage', {
                detail: { checked: event.target.checked }
            })
        );
    }

    handleShowHidden() {
        this.dispatchEvent(new CustomEvent('showhidden'));
    }

    @api
    focusRow(docId) {
        const row = this.template.querySelector(`c-cs-result-row[data-doc-id="${docId}"]`);
        if (row) {
            row.focus();
            if (typeof row.scrollIntoView === 'function') row.scrollIntoView({ block: 'nearest' });
        }
    }

    // ─── Facets ─────────────────────────────────────

    get hasFacets() {
        return this.facetGroups.length > 0;
    }

    get facetGroups() {
        const filters = (this.criteria && this.criteria.filters) || {};
        return (this.facets || [])
            .filter((f) => f.values && f.values.length)
            .map((f) => {
                const chosen = new Set([].concat(filters[f.field] || []));
                return {
                    field: f.field,
                    label: facetLabel(f.field),
                    values: f.values.slice(0, 12).map((v) => ({
                        key: `${f.field}|${v.value}`,
                        value: v.value,
                        text: `${v.value} (${v.count})`,
                        pressed: chosen.has(v.value) ? 'true' : 'false',
                        cls: `facet-val${chosen.has(v.value) ? ' facet-on' : ''}`
                    }))
                };
            });
    }

    get activeFilterCount() {
        const filters = (this.criteria && this.criteria.filters) || {};
        return Object.keys(filters).reduce((n, k) => n + [].concat(filters[k] || []).length, 0);
    }

    get facetToggleLabel() {
        return this.activeFilterCount ? `Filters (${this.activeFilterCount})` : 'Filters';
    }

    toggleFacets() {
        this.facetsOpen = !this.facetsOpen;
    }

    toggleFacetValue(event) {
        const { field, value } = event.currentTarget.dataset;
        const filters = (this.criteria && this.criteria.filters) || {};
        const current = [].concat(filters[field] || []);
        const values = current.includes(value) ? current.filter((v) => v !== value) : [...current, value];
        this.dispatchEvent(new CustomEvent('facetchange', { detail: { field, values } }));
    }

    // ─── Request viewer (existing pattern from callListMatchViewer) ──

    get hasRequest() {
        return !!this.requestXml;
    }

    get requestLines() {
        return prettyXmlLines(this.requestXml).map((text, i) => ({
            id: `l${i}`,
            text,
            cls: text.trim().startsWith('<!--') ? 'req-line req-comment' : 'req-line'
        }));
    }

    get requestIcon() {
        return this.requestOpen ? 'chevron-down' : 'chevron-right';
    }

    toggleRequest() {
        this.requestOpen = !this.requestOpen;
    }

    async copyRequest() {
        try {
            await navigator.clipboard.writeText(prettyXmlLines(this.requestXml).join('\n'));
        } catch {
            // Clipboard can be blocked by the browser: nothing else to do
        }
    }
}
