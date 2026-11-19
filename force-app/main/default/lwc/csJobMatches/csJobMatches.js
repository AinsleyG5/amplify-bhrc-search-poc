import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import matchCandidateToJobs from '@salesforce/apex/CandidateSearchController.matchCandidateToJobs';
import bulkAddToJob from '@salesforce/apex/CandidateSearchController.bulkAddToJob';
import { ring, normalizeError } from 'c/csUtils';

/**
 * csJobMatches: jobs that match the open candidate, ranked by Textkernel (searchWithUrl in the job environment
 * with the candidate's document, like the portal's "Match!"). Open the job, or shortlist the candidate on it.
 */
export default class CsJobMatches extends NavigationMixin(LightningElement) {
    @api contactId;

    _docId;
    @api
    get docId() {
        return this._docId;
    }
    set docId(value) {
        if (value === this._docId) return;
        this._docId = value;
        this.load();
    }

    jobs = [];
    total = 0;
    loading = false;
    error = null;
    /** jobId -> message after a shortlist attempt */
    done = {};
    busyJob = null;

    async load() {
        const docId = this._docId;
        this.jobs = [];
        this.error = null;
        this.done = {};
        if (!docId) return;
        this.loading = true;
        try {
            const res = JSON.parse(await matchCandidateToJobs({ docId }));
            if (docId !== this._docId) return;
            this.jobs = res.jobs || [];
            this.total = res.total || 0;
        } catch (e) {
            if (docId === this._docId) this.error = normalizeError(e);
        } finally {
            if (docId === this._docId) this.loading = false;
        }
    }

    get items() {
        return this.jobs.map((j) => {
            const r = ring(j.scorePct);
            return {
                ...j,
                heading: j.title ? `${j.title}` : j.name,
                sub: [j.title ? j.name : null, j.account, j.city].filter(Boolean).join(' · '),
                ringCls: `${r.cls} sm`,
                ringStyle: r.style,
                ringText: r.text,
                note: this.done[j.jobId] || '',
                busy: this.busyJob === j.jobId,
                shortlistDisabled: !this.contactId || !!this.done[j.jobId] || this.busyJob === j.jobId,
                openLabel: `Open job ${j.name}`,
                shortlistLabel: `Shortlist on ${j.name}`
            };
        });
    }

    get hasJobs() {
        return !this.loading && this.jobs.length > 0;
    }

    get showEmpty() {
        return !this.loading && !this.error && this.jobs.length === 0;
    }

    get countText() {
        return `${this.jobs.length} matching job${this.jobs.length === 1 ? '' : 's'}`;
    }

    openJob(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, objectApiName: 'TR1__Job__c', actionName: 'view' }
        });
    }

    async shortlist(event) {
        const jobId = event.currentTarget.dataset.id;
        if (!this.contactId) return;
        this.busyJob = jobId;
        try {
            const res = JSON.parse(await bulkAddToJob({ jobId, contactIdsJson: JSON.stringify([this.contactId]), auditId: null }));
            this.done = { ...this.done, [jobId]: res.added ? 'Shortlisted' : res.message };
        } catch (e) {
            this.done = { ...this.done, [jobId]: normalizeError(e) };
        } finally {
            this.busyJob = null;
        }
    }
}
