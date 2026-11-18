import { LightningElement, api } from 'lwc';
import autocompleteSkills from '@salesforce/apex/CandidateSearchController.autocompleteSkills';
import { ADDABLE_KINDS, WEIGHTS, READ_ONLY_KINDS, clone, kindLabel, weightShort, nextChipId, facetLabel, exclusionLabel, normalizeError } from 'c/csUtils';

const AUTOCOMPLETE_DEBOUNCE_MS = 250;

/**
 * csSearchBar: natural-language input, editable criteria chips, skill autocomplete (screen 1 and the header of 2A).
 *
 * Events (all detail objects are plain copies):
 * - search        { text }               new natural-language search
 * - criteriachange { criteria, summary } a chip, filter or exclusion changed; the app re-runs the search
 * - save          {}                      save the current search
 * - clear         {}                      back to the home panels
 */
export default class CsSearchBar extends LightningElement {
    @api loading = false;
    @api hasResults = false;
    /** A search has started (results, an error or one in flight): Clear search is offered. */
    @api active = false;
    @api defaultRadius = 15;

    _criteria;
    @api
    get criteria() {
        return this._criteria;
    }
    set criteria(value) {
        this._criteria = value;
        if (value && value.naturalLanguage && !this._textTouched) this.text = value.naturalLanguage;
    }

    @api
    get initialText() {
        return this.text;
    }
    set initialText(value) {
        if (value) {
            this.text = value;
            this._textTouched = false;
        }
    }

    text = '';
    _textTouched = false;

    /** The native textarea has no value attribute: keep it in step with text from here. */
    renderedCallback() {
        const ta = this.template.querySelector('.nl-text');
        if (ta && ta.value !== this.text && this.template.activeElement !== ta) ta.value = this.text || '';
    }

    /** Editor state: null, or { mode: 'add'|'edit', id, kind, value, label, weight, radius, unit, code, withinDays }. */
    editor = null;
    editorError;
    suggestions = [];
    suggestError;
    _suggestTimer;

    // ─── Natural language ───────────────────────────

    handleText(event) {
        this.text = event.target.value;
        this._textTouched = true;
    }

    handleKeydown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.submit();
        }
    }

    submit() {
        const text = (this.text || '').trim();
        if (!text || this.loading) return;
        this._textTouched = false;
        this.dispatchEvent(new CustomEvent('search', { detail: { text } }));
    }

    get hasText() {
        return !!(this.text || '').length;
    }

    /** Shown once there is anything to clear: text, chips or results. */
    get showClear() {
        return this.active || this.hasResults || this.hasText || !!this._criteria;
    }

    /** Clears the text box only; the current results and chips stay. */
    clearText() {
        this.text = '';
        this._textTouched = true;
        const ta = this.template.querySelector('.nl-text');
        if (ta) {
            ta.value = '';
            ta.focus();
        }
    }

    get searchDisabled() {
        return this.loading || !(this.text || '').trim();
    }

    handleSave() {
        this.dispatchEvent(new CustomEvent('save'));
    }

    handleClear() {
        this.text = '';
        this._textTouched = false;
        const ta = this.template.querySelector('.nl-text');
        if (ta) ta.value = '';
        this.editor = null;
        this.suggestions = [];
        this.dispatchEvent(new CustomEvent('clear'));
    }

    // ─── Chips ──────────────────────────────────────

    get hasCriteria() {
        return !!this._criteria;
    }

    get chips() {
        const items = (this._criteria && this._criteria.items) || [];
        return items.map((it) => {
            const readOnly = READ_ONLY_KINDS.has(it.kind);
            const weight = it.weight || 'preferred';
            return {
                id: it.id,
                label: it.label || it.value,
                kind: kindLabel(it.kind),
                weight: weightShort(weight),
                readOnly,
                title: readOnly
                    ? `${kindLabel(it.kind)} from the Textkernel job document${it.raw && it.raw.field ? ` (${it.raw.field})` : ''}. It can be removed but not edited.`
                    : `${kindLabel(it.kind)}: ${it.label || it.value}. Click to edit.`,
                cls: `chip chip-${weight}${readOnly ? ' chip-readonly' : ''}${this.editor && this.editor.id === it.id ? ' chip-active' : ''}`,
                removeLabel: `Remove ${it.label || it.value}`
            };
        });
    }

    get filterChips() {
        const out = [];
        const f = (this._criteria && this._criteria.filters) || {};
        Object.keys(f).forEach((field) => {
            [].concat(f[field] || []).forEach((v) => {
                out.push({
                    key: `${field}|${v}`,
                    field,
                    value: v,
                    label: `${facetLabel(field)}: ${v}`,
                    removeLabel: `Remove filter ${facetLabel(field)} ${v}`
                });
            });
        });
        return out;
    }

    get exclusionChips() {
        const x = (this._criteria && this._criteria.exclusions) || {};
        const out = [];
        if (x.placedWithinDays) {
            out.push({
                key: 'placedWithinDays',
                label: `Not ${exclusionLabel('placedWithinDays', x.placedWithinDays).replace('anyone ', '')}`,
                removeLabel: 'Stop excluding recent placements'
            });
        }
        if (x.pipelineForJob) {
            out.push({
                key: 'pipelineForJob',
                label: 'Hiding candidates already on this job',
                removeLabel: 'Show candidates already on this job'
            });
        }
        return out;
    }

    get hasExtras() {
        return this.filterChips.length > 0 || this.exclusionChips.length > 0;
    }

    get isJobSearch() {
        return !!(this._criteria && this._criteria.jobId);
    }

    get placedDays() {
        const x = (this._criteria && this._criteria.exclusions) || {};
        return x.placedWithinDays || '';
    }

    get pipelineHidden() {
        const x = (this._criteria && this._criteria.exclusions) || {};
        return x.pipelineForJob === true;
    }

    openChip(event) {
        const id = event.currentTarget.dataset.id;
        const it = ((this._criteria && this._criteria.items) || []).find((x) => x.id === id);
        if (!it) return;
        if (READ_ONLY_KINDS.has(it.kind)) {
            this.editor = null;
            return;
        }
        if (this.editor && this.editor.id === id) {
            this.editor = null;
            return;
        }
        this.editor = {
            mode: 'edit',
            id,
            kind: it.kind,
            value: it.value || '',
            label: it.label || '',
            weight: it.weight || 'preferred',
            radius: it.radius ?? this.defaultRadius,
            unit: it.unit || 'mi',
            code: it.code || null,
            withinDays: it.withinDays ?? ''
        };
        this.editorError = null;
        this.suggestions = [];
    }

    removeChip(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const c = clone(this._criteria);
        const removed = c.items.find((x) => x.id === id);
        c.items = c.items.filter((x) => x.id !== id);
        if (this.editor && this.editor.id === id) this.editor = null;
        this.emitChange(c, `Removed ${removed ? removed.label : 'a criterion'}`);
    }

    removeFilter(event) {
        const { field, value } = event.currentTarget.dataset;
        const c = clone(this._criteria);
        const left = [].concat(c.filters[field] || []).filter((v) => v !== value);
        if (left.length) c.filters[field] = left;
        else delete c.filters[field];
        this.emitChange(c, `Removed filter ${facetLabel(field)}: ${value}`);
    }

    removeExclusion(event) {
        const key = event.currentTarget.dataset.key;
        const c = clone(this._criteria);
        c.exclusions = c.exclusions || {};
        delete c.exclusions[key];
        this.emitChange(c, `Stopped excluding ${exclusionLabel(key)}`);
    }

    handlePlacedDays(event) {
        const n = parseInt(event.target.value, 10);
        const c = clone(this._criteria);
        c.exclusions = c.exclusions || {};
        if (Number.isFinite(n) && n > 0) c.exclusions.placedWithinDays = Math.min(n, 3650);
        else delete c.exclusions.placedWithinDays;
        if ((c.exclusions.placedWithinDays || null) === (this.placedDays || null)) return;
        this.emitChange(c, n > 0 ? `Excluding anyone placed in the last ${n} days` : 'Stopped excluding recent placements');
    }

    togglePipeline(event) {
        const c = clone(this._criteria);
        c.exclusions = c.exclusions || {};
        if (event.target.checked) c.exclusions.pipelineForJob = true;
        else delete c.exclusions.pipelineForJob;
        this.emitChange(c, event.target.checked ? 'Hiding candidates already on this job' : 'Showing candidates already on this job');
    }

    // ─── Editor (add or edit one chip) ──────────────

    openAdd() {
        this.editor = {
            mode: 'add',
            id: null,
            kind: 'skill',
            value: '',
            label: '',
            weight: 'preferred',
            radius: this.defaultRadius,
            unit: 'mi',
            code: null,
            withinDays: 28
        };
        this.editorError = null;
        this.suggestions = [];

        Promise.resolve().then(() => {
            const input = this.template.querySelector('[data-field="value"]');
            if (input) input.focus();
        });
    }

    get hasEditor() {
        return !!this.editor;
    }

    get editorTitle() {
        return this.editor && this.editor.mode === 'add' ? 'Add a criterion' : 'Edit criterion';
    }

    get editorSaveLabel() {
        return this.editor && this.editor.mode === 'add' ? 'Add and search' : 'Update and search';
    }

    get isAdd() {
        return this.editor && this.editor.mode === 'add';
    }

    get kindOptions() {
        return ADDABLE_KINDS;
    }

    get weightOptions() {
        return WEIGHTS.map((w) => ({ label: w.label, value: w.value }));
    }

    get isLocation() {
        return this.editor && this.editor.kind === 'location';
    }

    get isAvailability() {
        return this.editor && this.editor.kind === 'availability';
    }

    get showValue() {
        return this.editor && this.editor.kind !== 'availability';
    }

    get valueLabel() {
        if (!this.editor) return 'Value';
        if (this.editor.kind === 'location') return 'Town or postcode';
        if (this.editor.kind === 'skill' || this.editor.kind === 'certification') return `${kindLabel(this.editor.kind)} (type 2+ letters for suggestions)`;
        return kindLabel(this.editor.kind);
    }

    get hasSuggestions() {
        return this.suggestions.length > 0;
    }

    handleEditor(event) {
        const field = event.target.dataset.field;
        const value = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        this.editor = { ...this.editor, [field]: value };
        if (field === 'value') {
            this.editor.code = null;
            this.queueSuggest(value);
        }
        if (field === 'kind') this.suggestions = [];
    }

    queueSuggest(value) {
        clearTimeout(this._suggestTimer);
        const kind = this.editor && this.editor.kind;
        if ((kind !== 'skill' && kind !== 'certification') || !value || value.trim().length < 2) {
            this.suggestions = [];
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._suggestTimer = setTimeout(() => this.suggest(value.trim()), AUTOCOMPLETE_DEBOUNCE_MS);
    }

    async suggest(prefix) {
        try {
            const list = JSON.parse(await autocompleteSkills({ prefix }));
            if (!this.editor || (this.editor.value || '').trim() !== prefix) return;
            this.suggestions = (list || []).map((s) => ({
                id: s.id,
                label: s.description,
                category: s.category
            }));
            this.suggestError = null;
        } catch (e) {
            this.suggestions = [];
            this.suggestError = normalizeError(e);
        }
    }

    pickSuggestion(event) {
        const { id, label } = event.currentTarget.dataset;
        this.editor = { ...this.editor, value: label, label, code: id };
        this.suggestions = [];
    }

    cancelEditor() {
        this.editor = null;
        this.suggestions = [];
        this.editorError = null;
    }

    handleEditorKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.cancelEditor();
        } else if (event.key === 'Enter' && event.target.tagName !== 'BUTTON' && !this.hasSuggestions) {
            event.preventDefault();
            this.saveEditor();
        }
    }

    saveEditor() {
        const e = this.editor;
        if (!e) return;
        const value = (e.value || '').trim();
        if (e.kind !== 'availability' && !value) {
            this.editorError = 'Enter a value.';
            return;
        }
        const radius = Number(e.radius);
        if (e.kind === 'location' && (!Number.isFinite(radius) || radius < 0)) {
            this.editorError = 'Enter a radius in miles.';
            return;
        }
        const days = parseInt(e.withinDays, 10);
        if (e.kind === 'availability' && !(days > 0)) {
            this.editorError = 'Enter a number of days.';
            return;
        }

        const c = clone(this._criteria) || {
            version: 1,
            source: 'user',
            items: [],
            filters: {},
            exclusions: {}
        };
        c.items = c.items || [];
        const item = e.mode === 'edit' ? c.items.find((x) => x.id === e.id) : { id: nextChipId(c), origin: 'user' };
        if (!item) return;
        item.kind = e.kind;
        item.weight = e.weight;
        if (e.kind === 'location') {
            item.value = value;
            item.radius = radius;
            item.unit = e.unit || 'mi';
            item.label = `${value} + ${radius} ${item.unit}`;
        } else if (e.kind === 'availability') {
            item.withinDays = days;
            item.value = String(days);
            item.label = `Available within ${days} days`;
        } else {
            item.value = value;
            item.label = value;
            item.code = e.code || null;
        }
        if (e.mode === 'add') c.items.push(item);
        this.editor = null;
        this.suggestions = [];
        this.emitChange(c, `${e.mode === 'add' ? 'Added' : 'Changed'} ${item.label}`);
    }

    emitChange(criteria, summary) {
        this.dispatchEvent(new CustomEvent('criteriachange', { detail: { criteria, summary } }));
    }
}
