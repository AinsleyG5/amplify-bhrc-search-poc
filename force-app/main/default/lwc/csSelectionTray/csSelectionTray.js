import { LightningElement, api } from 'lwc';
import searchRecords from '@salesforce/apex/CandidateSearchController.searchRecords';
import { labels, tr } from 'c/csI18n';
import { COMPARE_MIN, COMPARE_MAX, initials, avatarClass, normalizeError } from 'c/csUtils';

const SEARCH_DEBOUNCE_MS = 250;
const OBJECTS = { job: 'TR1__Job__c', pool: 'TR1__Call_List__c' };

/**
 * csSelectionTray: floating tray for the selected candidates. Compare (2 to 4), add to job, add to talent pool.
 * The job and pool pickers search with CandidateSearchController.searchRecords.
 *
 * selected: [{ docId, contactId, name }]
 * Events: compare {}, addtojob { jobId }, addtopool { poolId }, email {}, task {}, deselect { docId }, clear {}.
 */
export default class CsSelectionTray extends LightningElement {
    @api selected = [];
    @api busy = false;
    /** The job of a job match: preselected in the job picker. */
    @api jobId;

    /** 'en' or 'fr' (csI18n). */
    @api lang;

    get L() {
        return labels(this.lang);
    }

    mode = null; // null | 'job' | 'pool'
    query = '';
    results = [];
    searching = false;
    searchError = null;
    picked = null; // { id, name, sub }
    _timer;

    get count() {
        return (this.selected || []).length;
    }

    get countText() {
        return tr('nSelected', { n: this.count }, this.lang);
    }

    get people() {
        return (this.selected || []).slice(0, 5).map((s) => ({
            ...s,
            initials: initials(s.name),
            avatarCls: `${avatarClass(s.contactId || s.docId)} mini`,
            removeLabel: tr('removeFromSelection', { name: s.name }, this.lang)
        }));
    }

    get moreText() {
        const more = this.count - 5;
        return more > 0 ? `+${more}` : '';
    }

    get compareDisabled() {
        return this.busy || this.count < COMPARE_MIN || this.count > COMPARE_MAX;
    }

    get compareTitle() {
        if (this.count < COMPARE_MIN) return tr('compareSelectRange', { min: COMPARE_MIN, max: COMPARE_MAX }, this.lang);
        if (this.count > COMPARE_MAX) return tr('compareAtMost', { max: COMPARE_MAX }, this.lang);
        return this.L.compareSideBySide;
    }

    // ─── Picker ─────────────────────────────────────

    get pickerOpen() {
        return !!this.mode;
    }

    get pickerTitle() {
        return this.mode === 'job' ? this.L.shortlistOnJob : this.L.addToPoolTitle;
    }

    get pickerPlaceholder() {
        return this.mode === 'job' ? this.L.searchJobsPh : this.L.searchPoolsPh;
    }

    get confirmLabel() {
        return tr(this.mode === 'job' ? 'shortlistN' : 'addN', { n: this.count }, this.lang);
    }

    get confirmDisabled() {
        return this.busy || !this.picked;
    }

    get jobBtnCls() {
        return `btn btn-sm tray-btn${this.mode === 'job' ? ' on' : ''}`;
    }

    get poolBtnCls() {
        return `btn btn-sm tray-btn${this.mode === 'pool' ? ' on' : ''}`;
    }

    get resultItems() {
        return this.results.map((r) => ({
            ...r,
            cls: `opt${this.picked && this.picked.id === r.id ? ' opt-on' : ''}`,
            selected: this.picked && this.picked.id === r.id ? 'true' : 'false'
        }));
    }

    get hasResults() {
        return this.results.length > 0;
    }

    get showNoResults() {
        return !this.searching && !this.searchError && !this.hasResults;
    }

    showJob() {
        this.openPicker('job');
    }

    showPool() {
        this.openPicker('pool');
    }

    openPicker(mode) {
        if (this.mode === mode) {
            this.mode = null;
            return;
        }
        this.mode = mode;
        this.query = '';
        this.picked = null;
        this.results = [];
        this.runSearch(mode === 'job' && this.jobId ? this.jobId : '', true);

        Promise.resolve().then(() => {
            const input = this.template.querySelector('.picker-input');
            if (input) input.focus();
        });
    }

    closePicker() {
        this.mode = null;
    }

    handleQuery(event) {
        this.query = event.target.value;
        clearTimeout(this._timer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setTimeout(() => this.runSearch(this.query, false), SEARCH_DEBOUNCE_MS);
    }

    async runSearch(term, preselect) {
        const mode = this.mode;
        if (!mode) return;
        this.searching = true;
        this.searchError = null;
        try {
            const list = JSON.parse(await searchRecords({ objectApiName: OBJECTS[mode], term }));
            if (mode !== this.mode) return;
            this.results = list || [];
            if (preselect && term && this.results.length === 1) this.picked = this.results[0];
            if (preselect && term && !this.results.length) this.runSearch('', false);
        } catch (e) {
            this.searchError = normalizeError(e);
            this.results = [];
        } finally {
            this.searching = false;
        }
    }

    pick(event) {
        const id = event.currentTarget.dataset.id;
        this.picked = this.results.find((r) => r.id === id) || null;
    }

    handlePickerKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.closePicker();
        } else if (event.key === 'Enter' && this.picked) {
            event.preventDefault();
            this.confirm();
        }
    }

    confirm() {
        if (!this.picked) return;
        if (this.mode === 'job') {
            this.dispatchEvent(new CustomEvent('addtojob', { detail: { jobId: this.picked.id } }));
        } else {
            this.dispatchEvent(new CustomEvent('addtopool', { detail: { poolId: this.picked.id } }));
        }
        this.mode = null;
    }

    // ─── Actions ────────────────────────────────────

    handleCompare() {
        this.dispatchEvent(new CustomEvent('compare'));
    }

    handleEmail() {
        this.mode = null;
        this.dispatchEvent(new CustomEvent('email'));
    }

    handleTask() {
        this.mode = null;
        this.dispatchEvent(new CustomEvent('task'));
    }

    handleDeselect(event) {
        this.dispatchEvent(new CustomEvent('deselect', { detail: { docId: event.currentTarget.dataset.id } }));
    }

    handleClear() {
        this.mode = null;
        this.dispatchEvent(new CustomEvent('clear'));
    }
}
