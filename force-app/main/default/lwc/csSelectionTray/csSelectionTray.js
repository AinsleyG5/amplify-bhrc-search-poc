import { LightningElement, api } from 'lwc';
import { COMPARE_MIN, COMPARE_MAX } from 'c/csUtils';

/**
 * csSelectionTray: bottom tray for the selected candidates. Compare (2 to 4), add to job, add to talent pool.
 *
 * selected: [{ docId, contactId, name }]
 * Events: compare {}, addtojob { jobId }, addtopool { poolId }, deselect { docId }, clear {}.
 */
export default class CsSelectionTray extends LightningElement {
    @api selected = [];
    @api busy = false;

    _jobId;
    @api
    get jobId() {
        return this._jobId;
    }
    set jobId(value) {
        this._jobId = value;
        if (value && !this.pickedJobId) this.pickedJobId = value;
    }

    mode = null; // null | 'job' | 'pool'
    pickedJobId;
    pickedPoolId;

    jobDisplayInfo = {
        primaryField: 'Name',
        additionalFields: ['TR1__Job_Title__c']
    };
    poolDisplayInfo = { primaryField: 'Name' };

    get count() {
        return (this.selected || []).length;
    }

    get countText() {
        return `${this.count} selected`;
    }

    get people() {
        return (this.selected || []).slice(0, 6).map((s) => ({
            ...s,
            removeLabel: `Remove ${s.name} from the selection`
        }));
    }

    get moreText() {
        const more = this.count - 6;
        return more > 0 ? `+${more} more` : '';
    }

    get compareDisabled() {
        return this.busy || this.count < COMPARE_MIN || this.count > COMPARE_MAX;
    }

    get compareTitle() {
        if (this.count < COMPARE_MIN) return `Select ${COMPARE_MIN} to ${COMPARE_MAX} candidates to compare`;
        if (this.count > COMPARE_MAX) return `Compare takes at most ${COMPARE_MAX} candidates`;
        return 'Compare side by side';
    }

    get isJobMode() {
        return this.mode === 'job';
    }

    get isPoolMode() {
        return this.mode === 'pool';
    }

    get confirmJobDisabled() {
        return this.busy || !this.pickedJobId;
    }

    get confirmPoolDisabled() {
        return this.busy || !this.pickedPoolId;
    }

    get addJobLabel() {
        return `Shortlist ${this.count} on job`;
    }

    get addPoolLabel() {
        return `Add ${this.count} to pool`;
    }

    handleCompare() {
        this.dispatchEvent(new CustomEvent('compare'));
    }

    showJob() {
        this.mode = this.mode === 'job' ? null : 'job';
    }

    showPool() {
        this.mode = this.mode === 'pool' ? null : 'pool';
    }

    handleJobPick(event) {
        this.pickedJobId = event.detail.recordId;
    }

    handlePoolPick(event) {
        this.pickedPoolId = event.detail.recordId;
    }

    confirmJob() {
        this.dispatchEvent(new CustomEvent('addtojob', { detail: { jobId: this.pickedJobId } }));
        this.mode = null;
    }

    confirmPool() {
        this.dispatchEvent(new CustomEvent('addtopool', { detail: { poolId: this.pickedPoolId } }));
        this.mode = null;
    }

    handleDeselect(event) {
        this.dispatchEvent(
            new CustomEvent('deselect', {
                detail: { docId: event.currentTarget.dataset.id }
            })
        );
    }

    handleClear() {
        this.mode = null;
        this.dispatchEvent(new CustomEvent('clear'));
    }
}
