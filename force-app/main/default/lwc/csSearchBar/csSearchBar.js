import { LightningElement, api } from 'lwc';
import autocompleteSkills from '@salesforce/apex/CandidateSearchController.autocompleteSkills';
import suggestProfessions from '@salesforce/apex/CandidateSearchController.suggestProfessions';
import suggestSkillsForProfession from '@salesforce/apex/CandidateSearchController.suggestSkillsForProfession';
import suggestSimilarSkills from '@salesforce/apex/CandidateSearchController.suggestSimilarSkills';
import { ADDABLE_KINDS, WEIGHTS, READ_ONLY_KINDS, clone, kindLabel, weightShort, nextChipId, facetLabel, exclusionLabel, normalizeError } from 'c/csUtils';

const AUTOCOMPLETE_DEBOUNCE_MS = 250;
const TYPEAHEAD_DEBOUNCE_MS = 300;
/** Longer text reads as a sentence for the AI, so only the "Search with AI" row is offered. */
const TYPEAHEAD_MAX_WORDS = 4;
const TYPEAHEAD_MAX_CHARS = 40;

function emptyCriteria() {
    return { version: 1, source: 'user', items: [], filters: {}, exclusions: {} };
}

/**
 * csSearchBar: natural-language input, editable criteria chips, skill autocomplete (screen 1 and the header of 2A).
 *
 * Events (all detail objects are plain copies):
 * - search        { text }               new natural-language search
 * - criteriachange { criteria, summary } a chip, filter or exclusion changed; the app re-runs the search
 * - save          { name }                save the current search under that name
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
        this.autoGrow(ta);
    }

    /** The search box grows with the text (up to the CSS max-height). */
    autoGrow(ta) {
        if (!ta) return;
        ta.style.height = 'auto';
        ta.style.height = `${ta.scrollHeight}px`;
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
        this.autoGrow(event.target);
        this.queueTypeahead(this.text);
    }

    handleKeydown(event) {
        if (this.taOpen) {
            if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                event.preventDefault();
                const n = this.ta.rows.filter((r) => r.selectable).length;
                if (n) this.ta = { ...this.ta, active: (this.ta.active + (event.key === 'ArrowDown' ? 1 : n - 1)) % n };
                return;
            }
            if (event.key === 'Escape') {
                event.preventDefault();
                event.stopPropagation();
                this.closeTypeahead();
                return;
            }
            if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                this.pickRow(this.ta.rows.filter((r) => r.selectable)[this.ta.active]);
                return;
            }
        }
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.submit();
        }
    }

    // ─── Type-ahead: AI search, job titles (Textkernel professions), skills ──

    /** { open, rows: [{ key, kind: 'ai'|'profession'|'skill'|'status', label, sub, data, selectable }], active, loading } */
    ta = { open: false, rows: [], active: 0, loading: false };
    _taTimer;
    _taSeq = 0;

    get taOpen() {
        return this.ta.open && this.ta.rows.length > 0;
    }

    aiRow(text) {
        return { key: 'ai', kind: 'ai', label: text, sub: 'Search with AI', selectable: true };
    }

    queueTypeahead(value) {
        clearTimeout(this._taTimer);
        const t = (value || '').trim();
        if (t.length < 2) {
            this.closeTypeahead();
            return;
        }
        const seq = ++this._taSeq;
        const short = t.split(/\s+/).length <= TYPEAHEAD_MAX_WORDS && t.length <= TYPEAHEAD_MAX_CHARS;
        this.ta = { open: true, rows: [this.aiRow(t)], active: 0, loading: short };
        if (!short) return;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._taTimer = setTimeout(() => this.fetchTypeahead(t, seq), TYPEAHEAD_DEBOUNCE_MS);
    }

    async fetchTypeahead(t, seq) {
        const [prof, skill] = await Promise.allSettled([suggestProfessions({ prefix: t }), autocompleteSkills({ prefix: t })]);
        if (seq !== this._taSeq) return;
        const rows = [this.aiRow(t)];
        if (prof.status === 'fulfilled') {
            JSON.parse(prof.value || '[]')
                .slice(0, 4)
                .forEach((p) => rows.push({ key: `p${p.codeId}`, kind: 'profession', label: p.description, sub: 'Job title', data: p, selectable: true }));
        }
        if (skill.status === 'fulfilled') {
            JSON.parse(skill.value || '[]')
                .slice(0, 4)
                .forEach((k) => rows.push({ key: `s${k.id}`, kind: 'skill', label: k.description, sub: k.category || 'Skill', data: k, selectable: true }));
        }
        const failed = [prof, skill].filter((r) => r.status === 'rejected');
        if (failed.length) {
            rows.push({ key: 'err', kind: 'status', label: `Suggestions unavailable: ${normalizeError(failed[0].reason)}`, selectable: false });
        } else if (rows.length === 1) {
            rows.push({ key: 'none', kind: 'status', label: 'No matching job titles or skills', selectable: false });
        }
        this.ta = { open: this.ta.open, rows, active: 0, loading: false };
    }

    get taRows() {
        let i = -1;
        return this.ta.rows.map((r) => {
            if (r.selectable) i++;
            const active = r.selectable && i === this.ta.active;
            return {
                ...r,
                index: r.selectable ? i : -1,
                cls: `ta-row ta-${r.kind}${active ? ' ta-active' : ''}`,
                selected: active ? 'true' : 'false',
                icon: r.kind === 'ai' ? 'message' : r.kind === 'profession' ? 'briefcase' : r.kind === 'skill' ? 'check' : 'alert'
            };
        });
    }

    get taLoading() {
        return this.ta.loading;
    }

    closeTypeahead() {
        clearTimeout(this._taTimer);
        this._taSeq++;
        this.ta = { open: false, rows: [], active: 0, loading: false };
    }

    /** Keep focus in the text box while clicking a row. */
    keepFocus(event) {
        event.preventDefault();
    }

    handleRowClick(event) {
        const index = Number(event.currentTarget.dataset.index);
        this.pickRow(this.ta.rows.filter((r) => r.selectable)[index]);
    }

    handleBlur() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.closeTypeahead(), 150);
    }

    pickRow(row) {
        if (!row) return;
        if (row.kind === 'ai') {
            this.closeTypeahead();
            this.submit();
            return;
        }
        const c = clone(this._criteria) || emptyCriteria();
        c.items = c.items || [];
        this.closeTypeahead();
        this.clearTextBox();
        if (row.kind === 'profession') {
            c.items.push({
                id: nextChipId(c),
                kind: 'title',
                label: row.label,
                value: row.label,
                weight: 'required',
                origin: 'user',
                professionCode: row.data.codeId
            });
            this.emitChange(c, `Added job title ${row.label}`);
            this.loadStrip('profession', row.data.codeId, row.label);
        } else if (row.kind === 'skill') {
            c.items.push({ id: nextChipId(c), kind: 'skill', label: row.label, value: row.label, code: row.data.id, weight: 'preferred', origin: 'user' });
            this.emitChange(c, `Added skill ${row.label}`);
            this.loadStrip('skill', row.data.id, row.label);
        }
    }

    clearTextBox() {
        this.text = '';
        this._textTouched = true;
        const ta = this.template.querySelector('.nl-text');
        if (ta) ta.value = '';
    }

    // ─── Suggested skills strip (profession -> skills, skill -> similar skills) ──

    /** null, or { title, items: [{ id, label }], loading, error } */
    strip = null;
    _stripSeq = 0;

    async loadStrip(kind, key, label) {
        const seq = ++this._stripSeq;
        this.strip = { title: kind === 'profession' ? `Suggested skills for ${label}` : `Similar to ${label}`, items: [], loading: true, error: null };
        try {
            const res =
                kind === 'profession'
                    ? await suggestSkillsForProfession({ professionCodeId: key })
                    : await suggestSimilarSkills({ skillIdsJson: JSON.stringify([key]) });
            if (seq !== this._stripSeq) return;
            const items = JSON.parse(res || '[]').map((k) => ({ id: k.id, label: k.description }));
            this.strip = { ...this.strip, items, loading: false };
        } catch (e) {
            if (seq === this._stripSeq) this.strip = { ...this.strip, loading: false, error: normalizeError(e) };
        }
    }

    get hasStrip() {
        return !!this.strip;
    }

    get stripItems() {
        const items = (this._criteria && this._criteria.items) || [];
        const codes = new Set(items.map((i) => i.code).filter(Boolean));
        const labels = new Set(items.map((i) => String(i.label || '').toLowerCase()));
        return ((this.strip && this.strip.items) || []).map((k) => {
            const added = codes.has(k.id) || labels.has(k.label.toLowerCase());
            return {
                ...k,
                added,
                cls: `sugg${added ? ' sugg-added' : ''}`,
                icon: added ? 'check' : 'plus',
                title: added ? `${k.label} is in the search` : `Add ${k.label}`
            };
        });
    }

    get stripEmpty() {
        return this.strip && !this.strip.loading && !this.strip.error && !this.strip.items.length;
    }

    get addAllDisabled() {
        return !this.stripItems.some((k) => !k.added);
    }

    addSuggested(event) {
        const id = event.currentTarget.dataset.id;
        const k = this.stripItems.find((x) => x.id === id);
        if (!k || k.added) return;
        this.addSkills([k], `Added skill ${k.label}`);
    }

    addAllSuggested() {
        const todo = this.stripItems.filter((k) => !k.added);
        if (todo.length) this.addSkills(todo, `Added ${todo.length} suggested skill${todo.length === 1 ? '' : 's'}`);
    }

    addSkills(list, summary) {
        const c = clone(this._criteria) || emptyCriteria();
        c.items = c.items || [];
        list.forEach((k) =>
            c.items.push({ id: nextChipId(c), kind: 'skill', label: k.label, value: k.label, code: k.id, weight: 'preferred', origin: 'user' })
        );
        this.emitChange(c, summary);
    }

    closeStrip() {
        this._stripSeq++;
        this.strip = null;
    }

    submit() {
        const text = (this.text || '').trim();
        if (!text || this.loading) return;
        this.closeTypeahead();
        this.strip = null;
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

    // ─── Save (inline popover) ──────────────────────

    saveOpen = false;
    saveName = '';

    get suggestedName() {
        const c = this._criteria || {};
        const fromChips = (c.items || [])
            .map((i) => i.label)
            .slice(0, 3)
            .join(', ');
        return (c.naturalLanguage || fromChips || 'My search').slice(0, 80);
    }

    handleSave() {
        this.saveOpen = !this.saveOpen;
        if (!this.saveOpen) return;
        this.saveName = this.suggestedName;

        Promise.resolve().then(() => {
            const input = this.template.querySelector('.save-input');
            if (input) {
                input.focus();
                input.select();
            }
        });
    }

    handleSaveName(event) {
        this.saveName = event.target.value;
    }

    handleSaveKeydown(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.confirmSave();
        } else if (event.key === 'Escape') {
            event.stopPropagation();
            this.saveOpen = false;
        }
    }

    get saveDisabled() {
        return !(this.saveName || '').trim();
    }

    confirmSave() {
        const name = (this.saveName || '').trim();
        if (!name) return;
        this.saveOpen = false;
        this.dispatchEvent(new CustomEvent('save', { detail: { name } }));
    }

    cancelSave() {
        this.saveOpen = false;
    }

    get searchLabel() {
        return this.loading ? 'Searching' : 'Search';
    }

    handleClear() {
        this.text = '';
        this._textTouched = false;
        const ta = this.template.querySelector('.nl-text');
        if (ta) ta.value = '';
        this.editor = null;
        this.suggestions = [];
        this.saveOpen = false;
        this.strip = null;
        this.closeTypeahead();
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
                dotCls: `dot dot-${weight}`,
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
        return this.editor && this.editor.mode === 'add' ? 'Add criterion' : 'Edit criterion';
    }

    get editorSaveLabel() {
        return this.editor && this.editor.mode === 'add' ? 'Add' : 'Save';
    }

    get isAdd() {
        return this.editor && this.editor.mode === 'add';
    }

    get kindOptions() {
        const kind = this.editor && this.editor.kind;
        return ADDABLE_KINDS.map((k) => ({ ...k, selected: k.value === kind }));
    }

    get weightOptions() {
        const weight = this.editor && this.editor.weight;
        return WEIGHTS.map((w) => ({ label: w.label, value: w.value, pressed: w.value === weight ? 'true' : 'false' }));
    }

    handleWeight(event) {
        this.editor = { ...this.editor, weight: event.currentTarget.dataset.value };
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
        if (this.editor.kind === 'skill' || this.editor.kind === 'certification') return kindLabel(this.editor.kind);
        return kindLabel(this.editor.kind);
    }

    get hasSuggestions() {
        return this.suggestions.length > 0;
    }

    handleEditor(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
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
