import { LightningElement, api } from 'lwc';
import { formatDateTime } from 'c/csUtils';
import { labels, tr } from 'c/csI18n';

const EXAMPLES = ['example1', 'example2', 'example3', 'example4'];

/**
 * csHomePanels: recent searches, saved searches and favourites (screen 1), from getRecentAndSaved.
 *
 * Events: runsearch { id, saved }, favourite { id, favourite }, runexample { text }.
 */
export default class CsHomePanels extends LightningElement {
    @api data;
    @api loading = false;
    @api error;

    /** 'en' or 'fr' (csI18n). */
    @api lang;

    get L() {
        return labels(this.lang);
    }

    map(list, saved) {
        return (list || []).map((s) => ({
            id: s.Id,
            key: `${saved ? 's' : 'r'}-${s.Id}`,
            name: s.Name || s.Natural_Language__c || this.L.untitledSearch,
            detail: [
                s.Natural_Language__c && s.Natural_Language__c !== s.Name ? s.Natural_Language__c : null,
                s.Last_Run__c ? tr('lastRun', { when: formatDateTime(s.Last_Run__c, this.lang) }, this.lang) : null
            ]
                .filter(Boolean)
                .join(' · '),
            runs: s.Run_Count__c ? tr('runsN', { n: s.Run_Count__c }, this.lang) : '',
            isJob: !!s.Job__c,
            saved: saved ? 'true' : 'false',
            favourite: s.Is_Favourite__c === true ? 'true' : 'false',
            starIcon: s.Is_Favourite__c ? 'utility:favorite' : 'utility:favorite_alt',
            starLabel: tr(s.Is_Favourite__c ? 'removeFavourite' : 'addFavourite', { name: s.Name }, this.lang),
            runLabel: tr('runSearchName', { name: s.Name || this.L.searchWord }, this.lang)
        }));
    }

    get favourites() {
        return this.map(this.data && this.data.favourites, true);
    }

    get saved() {
        return this.map(
            ((this.data && this.data.saved) || []).filter((s) => !s.Is_Favourite__c),
            true
        );
    }

    get recent() {
        return this.map(this.data && this.data.recent, false);
    }

    get hasFavourites() {
        return this.favourites.length > 0;
    }

    get hasSaved() {
        return this.saved.length > 0;
    }

    get hasRecent() {
        return this.recent.length > 0;
    }

    get isEmpty() {
        return !this.loading && !this.error && !this.hasFavourites && !this.hasSaved && !this.hasRecent;
    }

    get examples() {
        return EXAMPLES.map((key, i) => ({ id: `e${i}`, text: this.L[key] }));
    }

    get hasAny() {
        return this.hasFavourites || this.hasSaved || this.hasRecent;
    }

    handleExample(event) {
        this.dispatchEvent(new CustomEvent('runexample', { detail: { text: event.currentTarget.dataset.text } }));
    }

    handleRun(event) {
        const { id, saved } = event.currentTarget.dataset;
        this.dispatchEvent(new CustomEvent('runsearch', { detail: { id, saved: saved === 'true' } }));
    }

    handleStar(event) {
        event.stopPropagation();
        const { id, favourite } = event.currentTarget.dataset;
        this.dispatchEvent(
            new CustomEvent('favourite', {
                detail: { id, favourite: favourite !== 'true' }
            })
        );
    }
}
