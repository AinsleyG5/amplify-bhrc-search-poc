import { LightningElement, api } from 'lwc';

const SUGGESTIONS = [
    'Widen the radius to 25 miles',
    'Drop anyone we placed in the last month',
    'Nights count in their favour',
    'Why is the top candidate first?'
];

/**
 * csRefineChat: docked refine-by-conversation panel. One message changes the criteria; each turn shows its diff,
 * and Undo pops the last snapshot (the app keeps the stack and re-runs the search).
 *
 * turns: [{ id, role: 'user'|'assistant'|'system', text, diff: [{ id, text, cls }], undone }]
 * Events: refine { message }, undo {}, close {}.
 */
export default class CsRefineChat extends LightningElement {
    @api turns = [];
    @api busy = false;
    @api canUndo = false;

    message = '';
    _lastCount = 0;

    renderedCallback() {
        const n = (this.turns || []).length + (this.busy ? 1 : 0);
        if (n !== this._lastCount) {
            this._lastCount = n;
            const log = this.template.querySelector('.log');
            if (log) log.scrollTop = log.scrollHeight;
        }
    }

    @api
    focus() {
        const input = this.template.querySelector('.msg');
        if (input) input.focus();
    }

    get items() {
        return (this.turns || []).map((t) => ({
            ...t,
            cls: `turn turn-${t.role}${t.undone ? ' turn-undone' : ''}`,
            hasDiff: (t.diff || []).length > 0,
            isUser: t.role === 'user'
        }));
    }

    get isEmpty() {
        return (this.turns || []).length === 0;
    }

    get suggestions() {
        return SUGGESTIONS.map((s, i) => ({ id: `s${i}`, text: s }));
    }

    get sendDisabled() {
        return this.busy || !(this.message || '').trim();
    }

    get undoDisabled() {
        return this.busy || !this.canUndo;
    }

    handleInput(event) {
        this.message = event.target.value;
    }

    handleKeydown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.send();
        }
    }

    useSuggestion(event) {
        this.message = event.currentTarget.dataset.text;
        this.send();
    }

    send() {
        const message = (this.message || '').trim();
        if (!message || this.busy) return;
        this.message = '';
        const input = this.template.querySelector('.msg');
        if (input) input.value = '';
        this.dispatchEvent(new CustomEvent('refine', { detail: { message } }));
    }

    handleUndo() {
        this.dispatchEvent(new CustomEvent('undo'));
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}
