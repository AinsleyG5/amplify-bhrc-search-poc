import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { loadStyle } from 'lightning/platformResourceLoader';
import MONTSERRAT from '@salesforce/resourceUrl/Montserrat';
import { labels, getLang } from 'c/csI18n';

/**
 * csHomeLauncher: mini search box for the Home page. Opens the Candidate Search tab with the text in c__q,
 * and candidateSearchApp runs it.
 */
export default class CsHomeLauncher extends NavigationMixin(LightningElement) {
    /** API name of the Candidate Search App Page tab. */
    @api tabApiName = 'Candidate_Search';
    /** Blank shows "Find candidates" in the user's language. */
    @api heading;
    /** Optional logo image URL (for example /resource/AmplifyLogo). Blank shows the Amplify wordmark. */
    @api logoUrl;

    text = '';
    /** The language Candidate Search was last used in (or the user's language). */
    lang = getLang();

    get L() {
        return labels(this.lang);
    }

    get headingText() {
        // The App Builder default (English) shows in the user's language
        return this.heading && this.heading !== 'Find candidates' ? this.heading : this.L.findCandidates;
    }

    connectedCallback() {
        loadStyle(this, MONTSERRAT).catch(() => {
            // The fallback font stack still renders
        });
    }

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
