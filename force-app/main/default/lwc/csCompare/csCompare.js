import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { kindLabel, weightLabel, formatDate, READ_ONLY_KINDS } from 'c/csUtils';

/**
 * csCompare: 2 to 4 candidates side by side (screen 4), from CandidateSearchController.getCompareData.
 * Rows: score, AI summary, one row per criterion (met / not met per Textkernel, with evidence), pipeline,
 * profile fields, skills, latest note.
 *
 * Events: close {}, remove { contactId }.
 */
export default class CsCompare extends NavigationMixin(LightningElement) {
    @api data;
    @api loading = false;
    @api error;

    @api
    focus() {
        const btn = this.template.querySelector('.close-btn');
        if (btn) btn.focus();
    }

    get candidates() {
        return (this.data && this.data.candidates) || [];
    }

    get hasData() {
        return this.candidates.length > 0;
    }

    get gridStyle() {
        return `grid-template-columns: 180px repeat(${Math.max(this.candidates.length, 1)}, minmax(180px, 1fr));`;
    }

    get heads() {
        return this.candidates.map((c) => ({
            key: c.contactId,
            contactId: c.contactId,
            name: c.name,
            sub: [c.title, c.city].filter(Boolean).join(' · '),
            score: c.scorePct === null || c.scorePct === undefined ? '' : `${Math.round(c.scorePct)}%`,
            removeLabel: `Remove ${c.name} from the comparison`,
            openLabel: `Open ${c.name}`
        }));
    }

    get canRemove() {
        return this.candidates.length > 2;
    }

    get rows() {
        const cands = this.candidates;
        const rows = [];
        const cell = (key, text, cls = 'cell', extra = {}) => ({
            key,
            text: text || '–',
            cls,
            ...extra
        });

        rows.push({
            key: 'summary',
            label: 'Why (AI)',
            sub: '',
            cells: cands.map((c) =>
                cell(
                    `${c.contactId}-summary`,
                    c.summary || (c.inSearch ? 'Not explained yet' : 'Not in this search'),
                    c.summary ? 'cell cell-summary' : 'cell cell-muted'
                )
            )
        });

        const criteria = ((this.data && this.data.criteria) || []).filter((it) => it.weight !== 'excluded');
        criteria.forEach((it) => {
            rows.push({
                key: `crit-${it.id}`,
                label: READ_ONLY_KINDS.has(it.kind) ? it.label || 'Job description' : it.label,
                sub: `${kindLabel(it.kind)} · ${weightLabel(it.weight)}`,
                cells: cands.map((c) => {
                    const met = (c.met || []).includes(it.id);
                    const notMet = (c.notMet || []).includes(it.id);
                    const ev = (c.evidence || {})[it.id] || {};
                    const status = met ? 'met' : notMet ? 'notmet' : 'na';
                    return cell(`${c.contactId}-${it.id}`, met ? 'Met' : notMet ? 'Not met' : 'Not scored', `cell cell-${status}`, {
                        icon: met ? 'utility:check' : notMet ? 'utility:close' : 'utility:dash',
                        hasIcon: true,
                        evidence: ev.evidence || ''
                    });
                })
            });
        });

        rows.push({
            key: 'pipeline',
            label: 'On this job',
            sub: '',
            cells: cands.map((c) => cell(`${c.contactId}-pipeline`, (c.pipeline && c.pipeline.label) || 'No'))
        });

        const profileRow = (key, label, fields, date) => {
            const values = cands.map((c) => {
                const p = c.profile || {};
                const f = fields.find((x) => p[x] !== null && p[x] !== undefined && p[x] !== '');
                return f ? (date ? formatDate(p[f]) : String(p[f])) : '';
            });
            if (values.some(Boolean)) {
                rows.push({
                    key,
                    label,
                    sub: '',
                    cells: cands.map((c, i) => cell(`${c.contactId}-${key}`, values[i]))
                });
            }
        };
        profileRow('status', 'Status', ['TR1__Candidate_Status__c'], false);
        profileRow('available', 'Available from', ['Date_Available__c', 'TR1__Date_Available__c'], true);
        profileRow('placed', 'Last placed', ['TR1__Last_Placement_Date__c'], true);

        rows.push({
            key: 'owner',
            label: 'Owner',
            sub: '',
            cells: cands.map((c) => cell(`${c.contactId}-owner`, c.owner))
        });
        rows.push({
            key: 'skills',
            label: 'Skills',
            sub: '',
            cells: cands.map((c) => cell(`${c.contactId}-skills`, (c.skills || []).slice(0, 12).join(', '), 'cell cell-small'))
        });
        rows.push({
            key: 'note',
            label: 'Latest note',
            sub: '',
            cells: cands.map((c) => cell(`${c.contactId}-note`, (c.recentNotes || [])[0], 'cell cell-small'))
        });
        return rows;
    }

    get notices() {
        return ((this.data && this.data.notices) || []).map((n, i) => ({
            id: `n${i}`,
            text: n
        }));
    }

    get hasNotices() {
        return this.notices.length > 0;
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    handleRemove(event) {
        this.dispatchEvent(
            new CustomEvent('remove', {
                detail: { contactId: event.currentTarget.dataset.id }
            })
        );
    }

    openRecord(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: event.currentTarget.dataset.id,
                objectApiName: 'Contact',
                actionName: 'view'
            }
        });
    }

    handleKeydown(event) {
        if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            this.handleClose();
        }
    }
}
