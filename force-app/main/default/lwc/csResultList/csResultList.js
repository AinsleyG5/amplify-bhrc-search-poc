import { LightningElement, api } from 'lwc';
import { metAndNotMet, changeTag, facetLabel, prettyXmlLines, READ_ONLY_KINDS } from 'c/csUtils';

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
 */
export default class CsResultList extends LightningElement {
    @api rows = [];
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

    // ─── Infinite scroll ────────────────────────────

    renderedCallback() {
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
                    cls: `crit-item crit-${status}`,
                    icon: isMet ? 'utility:check' : isNotMet ? 'utility:close' : 'utility:dash',
                    statusText: isMet ? 'Met' : isNotMet ? 'Not met' : 'Not scored',
                    title: `${label}: ${isMet ? 'met' : isNotMet ? 'not met' : 'not scored separately'} (per Textkernel)`
                };
            });
            const p = r.pipeline || {};
            return {
                key: r.docId,
                docId: r.docId,
                contactId: r.contactId,
                rank: r.rank,
                name: r.name || 'Unnamed candidate',
                title: r.title,
                city: r.city,
                scorePct: r.scorePct,
                criteria,
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
        return this.requestOpen ? 'utility:chevrondown' : 'utility:chevronright';
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
