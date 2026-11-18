import { LightningElement, api } from 'lwc';
import { formatDateTime } from 'c/csUtils';

const EXAMPLES = [
    'Forklift-certified warehouse operatives within 15 miles of Dagenham',
    'Reach truck drivers near Thurrock who can start this week',
    'HGV Class 1 drivers in Birmingham who can do nights',
    'Pickers and packers within 10 miles of Milton Keynes, no placement in the last month'
];

/**
 * csHomePanels: recent searches, saved searches and favourites (screen 1), from getRecentAndSaved.
 *
 * Events: runsearch { id, saved }, favourite { id, favourite }, runexample { text }.
 */
export default class CsHomePanels extends LightningElement {
    @api data;
    @api loading = false;
    @api error;

    map(list, saved) {
        return (list || []).map((s) => ({
            id: s.Id,
            key: `${saved ? 's' : 'r'}-${s.Id}`,
            name: s.Name || s.Natural_Language__c || 'Untitled search',
            detail: [
                s.Natural_Language__c && s.Natural_Language__c !== s.Name ? s.Natural_Language__c : null,
                s.Last_Run__c ? `Last run ${formatDateTime(s.Last_Run__c)}` : null
            ]
                .filter(Boolean)
                .join(' · '),
            runs: s.Run_Count__c ? `${s.Run_Count__c} run${s.Run_Count__c === 1 ? '' : 's'}` : '',
            isJob: !!s.Job__c,
            saved: saved ? 'true' : 'false',
            favourite: s.Is_Favourite__c === true ? 'true' : 'false',
            starIcon: s.Is_Favourite__c ? 'utility:favorite' : 'utility:favorite_alt',
            starLabel: s.Is_Favourite__c ? `Remove ${s.Name} from favourites` : `Add ${s.Name} to favourites`,
            runLabel: `Run ${s.Name || 'search'}`
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
        return EXAMPLES.map((text, i) => ({ id: `e${i}`, text }));
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
