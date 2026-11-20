import { LightningElement, api } from 'lwc';
import { labels, tr } from 'c/csI18n';

/**
 * csResultRow: one candidate row (screen 2A). Below 900px it renders as a card (screen 2B layout).
 * The view model is built by csResultList; the row only renders it and raises events.
 *
 * Events: rowopen { docId }, rowselect { docId, checked }, explain { docId }.
 */
export default class CsResultRow extends LightningElement {
    @api item;

    /** 'en' or 'fr' (csI18n). */
    @api lang;

    get L() {
        return labels(this.lang);
    }

    matchOpen = false;
    /** Opens the breakdown upwards when there is no room below the score. */
    matchUp = false;

    @api
    focus() {
        const btn = this.template.querySelector('.name-btn');
        if (btn) btn.focus();
    }

    get rowCls() {
        const i = this.item || {};
        return `row${i.active ? ' row-active' : ''}${i.selected ? ' row-selected' : ''}`;
    }

    get scoreStyle() {
        const pct = Math.max(0, Math.min(100, Number(this.item && this.item.scorePct) || 0));
        return `width:${pct}%`;
    }

    get scoreText() {
        const s = this.item && this.item.scorePct;
        return s === null || s === undefined ? '–' : `${Math.round(s)}%`;
    }

    get selectLabel() {
        return tr('selectName', { name: this.item && this.item.name }, this.lang);
    }

    get openLabel() {
        return tr('openName', { name: this.item && this.item.name }, this.lang);
    }

    get explainPending() {
        return this.item && this.item.explanation && this.item.explanation.state === 'pending';
    }

    get explainDone() {
        return this.item && this.item.explanation && this.item.explanation.state === 'done';
    }

    get explainError() {
        return this.item && this.item.explanation && this.item.explanation.state === 'error';
    }

    get explainAvailable() {
        const e = this.item && this.item.explanation;
        return !e || e.state === 'none';
    }

    get summary() {
        return this.item && this.item.explanation ? this.item.explanation.summary : '';
    }

    get errorText() {
        return this.item && this.item.explanation ? this.item.explanation.error : '';
    }

    get checkboxDisabled() {
        return !(this.item && this.item.selectable);
    }

    get checkboxTitle() {
        return this.item && this.item.selectable ? this.selectLabel : tr('noSfRecord', null, this.lang);
    }

    get scoreLabel() {
        const i = this.item || {};
        return tr('scoreLabel', { score: i.ringText || '', summary: (i.match && i.match.summary) || '' }, this.lang);
    }

    get matchSub() {
        const i = this.item || {};
        return `${this.L.tkMatch} · ${(i.match && i.match.summary) || ''}`;
    }

    get matchPopCls() {
        return `match-pop${this.matchOpen ? ' match-pop-open' : ''}${this.matchUp ? ' match-pop-up' : ''}`;
    }

    showMatch(event) {
        const rect = event.currentTarget.getBoundingClientRect();
        this.matchUp = rect.bottom + 300 > (window.innerHeight || 0) && rect.top > 300;
        this.matchOpen = true;
    }

    hideMatch() {
        this.matchOpen = false;
    }

    scoreKeydown(event) {
        if (event.key === 'Escape') {
            this.matchOpen = false;
        } else if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleOpen(event);
        }
    }

    handleOpen(event) {
        if (event) event.stopPropagation();
        this.dispatchEvent(new CustomEvent('rowopen', { detail: { docId: this.item.docId } }));
    }

    /** Anywhere on the row opens the candidate (the name button stays the keyboard target). */
    handleRowClick() {
        this.handleOpen();
    }

    handleSelect(event) {
        event.stopPropagation();
        this.dispatchEvent(
            new CustomEvent('rowselect', {
                detail: { docId: this.item.docId, checked: event.target.checked }
            })
        );
    }

    handleExplain(event) {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent('explain', { detail: { docId: this.item.docId } }));
    }

    stop(event) {
        event.stopPropagation();
    }
}
