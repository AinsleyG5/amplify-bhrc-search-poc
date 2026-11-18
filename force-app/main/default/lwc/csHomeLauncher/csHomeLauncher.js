import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

/**
 * csHomeLauncher: mini search box for the Home page. Opens the Candidate Search tab with the text in c__q,
 * and candidateSearchApp runs it.
 */
export default class CsHomeLauncher extends NavigationMixin(LightningElement) {
    /** API name of the Candidate Search App Page tab. */
    @api tabApiName = 'Candidate_Search';
    @api heading = 'Find candidates';

    text = '';

    get disabled() {
        return !(this.text || '').trim();
    }

    handleInput(event) {
        this.text = event.target.value;
    }

    handleKeydown(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.go();
        }
    }

    go() {
        const q = (this.text || '').trim();
        if (!q) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: this.tabApiName },
            state: { c__q: q }
        });
    }

    openTab() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: this.tabApiName }
        });
    }
}
