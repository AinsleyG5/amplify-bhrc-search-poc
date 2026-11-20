import { createElement } from 'lwc';
import CandidateSearchApp from 'c/candidateSearchApp';
import { CurrentPageReference } from 'lightning/navigation';

import parseQuery from '@salesforce/apex/CandidateSearchController.parseQuery';
import runSearch from '@salesforce/apex/CandidateSearchController.runSearch';
import refine from '@salesforce/apex/CandidateSearchController.refine';
import explainResults from '@salesforce/apex/CandidateSearchController.explainResults';
import getRecentAndSaved from '@salesforce/apex/CandidateSearchController.getRecentAndSaved';
import getCompareData from '@salesforce/apex/CandidateSearchController.getCompareData';
import getCandidateDetail from '@salesforce/apex/CandidateSearchController.getCandidateDetail';
import startJobMatch from '@salesforce/apex/CandidateSearchController.startJobMatch';
import logAction from '@salesforce/apex/CandidateSearchController.logAction';
import bulkAddToJob from '@salesforce/apex/CandidateSearchController.bulkAddToJob';
import bulkAddToTalentPool from '@salesforce/apex/CandidateSearchController.bulkAddToTalentPool';
import saveSearch from '@salesforce/apex/CandidateSearchController.saveSearch';
import searchRecords from '@salesforce/apex/CandidateSearchController.searchRecords';
import getCandidateCv from '@salesforce/apex/CandidateSearchController.getCandidateCv';
import getCandidateCvLink from '@salesforce/apex/CandidateSearchController.getCandidateCvLink';
import suggestProfessions from '@salesforce/apex/CandidateSearchController.suggestProfessions';
import suggestSkillsForProfession from '@salesforce/apex/CandidateSearchController.suggestSkillsForProfession';
import autocompleteSkills from '@salesforce/apex/CandidateSearchController.autocompleteSkills';
import getColumnOptions from '@salesforce/apex/CandidateSearchController.getColumnOptions';
import getColumnValues from '@salesforce/apex/CandidateSearchController.getColumnValues';

jest.mock('@salesforce/apex/CandidateSearchController.parseQuery', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.startJobMatch', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.runSearch', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.refine', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.explainResults', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.getRecentAndSaved', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.saveSearch', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.setFavourite', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.getCompareData', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.getCandidateDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.bulkAddToJob', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.bulkAddToTalentPool', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.logAction', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.autocompleteSkills', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.searchRecords', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.getCandidateCv', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.getCandidateCvLink', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.suggestProfessions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.suggestSkillsForProfession', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.suggestSimilarSkills', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.describeSkills', () => ({ default: jest.fn(() => Promise.resolve('{}')) }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.matchCandidateToJobs', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.getColumnOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/CandidateSearchController.getColumnValues', () => ({ default: jest.fn() }), { virtual: true });

const CRITERIA = {
    version: 1,
    source: 'nl',
    naturalLanguage: 'forklift operatives near Dagenham',
    items: [
        {
            id: 'c1',
            kind: 'title',
            label: 'Warehouse Operative',
            value: 'Warehouse Operative',
            weight: 'required',
            origin: 'nl'
        },
        {
            id: 'c2',
            kind: 'certification',
            label: 'Forklift',
            value: 'Forklift',
            weight: 'strongly_preferred',
            origin: 'nl'
        },
        {
            id: 'c3',
            kind: 'location',
            label: 'Dagenham + 15 mi',
            value: 'Dagenham',
            radius: 15,
            unit: 'mi',
            weight: 'required',
            origin: 'nl'
        }
    ],
    filters: {},
    exclusions: {}
};

function row(i, extra = {}) {
    return {
        docId: `00D000000000001_003000000000${100 + i}AAA`,
        contactId: `003000000000${100 + i}AAA`,
        rank: i + 1,
        score: 0.9 - i / 100,
        scorePct: 90 - i,
        queryPartFlags: [1, i % 2 ? 0 : 1],
        criteriaIds: ['c1', 'c2'],
        queryCriteriaIds: ['c3'],
        excludedCriteriaIds: [],
        name: `Candidate ${i}`,
        title: 'Warehouse Operative',
        city: 'Dagenham',
        highlights: { FULLTEXT: ['a <b>forklift</b> licence'] },
        pipeline: {
            applied: false,
            shortlisted: false,
            placed: false,
            placedRecently: false,
            label: ''
        },
        ...extra
    };
}

function response(rows, extra = {}) {
    return JSON.stringify({
        auditId: 'a0X000000000001AAA',
        criteria: CRITERIA,
        requestXml: '<search><password>(hidden)</password></search>',
        total: rows.length,
        hasMore: false,
        offset: 0,
        nextOffset: rows.length,
        pageSize: 20,
        hiddenCount: 0,
        autoLoadMore: false,
        facets: [{ field: 'candidate_status', values: [{ value: 'Available', count: 2 }] }],
        rows,
        notices: [],
        error: null,
        ...extra
    });
}

const flush = async (n = 6) => {
    for (let i = 0; i < n; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
};

const shadow = (el, selector) => el.shadowRoot.querySelector(selector);

describe('c-candidate-search-app', () => {
    let element;

    beforeEach(() => {
        jest.clearAllMocks();
        global.IntersectionObserver = class {
            observe() {}
            unobserve() {}
            disconnect() {}
        };
        getRecentAndSaved.mockResolvedValue(JSON.stringify({ recent: [], saved: [], favourites: [] }));
        parseQuery.mockResolvedValue(JSON.stringify({ ...CRITERIA, trace: { searchType: 'Natural language' } }));
        runSearch.mockResolvedValue(response([row(0), row(1), row(2)]));
        explainResults.mockImplementation(({ docIdsJson }) =>
            Promise.resolve(
                JSON.stringify(
                    JSON.parse(docIdsJson).map((d) => ({
                        docId: d,
                        summary: `Summary for ${d}`,
                        criteria: [
                            {
                                id: 'c2',
                                met: true,
                                evidence: 'forklift licence',
                                source: 'Call, 2 Nov'
                            }
                        ]
                    }))
                )
            )
        );
        getCandidateDetail.mockResolvedValue(
            JSON.stringify({
                candidate: {
                    contactId: '003000000000100AAA',
                    name: 'Candidate 0',
                    title: 'Warehouse Operative',
                    city: 'Dagenham',
                    owner: 'Ainsley',
                    skills: ['Forklift'],
                    recentNotes: ['[Call, 2026-11-02] Has a forklift licence'],
                    profile: { TR1__Candidate_Status__c: 'Available' },
                    pipeline: {}
                }
            })
        );
        logAction.mockResolvedValue(null);
        getColumnOptions.mockResolvedValue(JSON.stringify([{ path: 'MobilePhone', label: 'Mobile', type: 'phone' }]));
        getColumnValues.mockResolvedValue('{}');
        window.localStorage.clear();
        element = createElement('c-candidate-search-app', {
            is: CandidateSearchApp
        });
        document.body.appendChild(element);
    });

    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    });

    async function searchFromUrl() {
        CurrentPageReference.emit({
            state: { c__q: 'forklift operatives near Dagenham' }
        });
        await flush(12);
    }

    it('shows the home panels first', async () => {
        await flush();
        expect(getRecentAndSaved).toHaveBeenCalled();
        expect(shadow(element, 'c-cs-home-panels')).not.toBeNull();
        expect(shadow(element, 'c-cs-result-list')).toBeNull();
    });

    it('runs c__q: parse, search, explain, rows render with met flags and summaries', async () => {
        await searchFromUrl();
        expect(parseQuery).toHaveBeenCalledWith({
            text: 'forklift operatives near Dagenham'
        });
        const sent = JSON.parse(runSearch.mock.calls[0][0].criteriaJson);
        expect(sent.trace.searchType).toBe('Natural language');
        expect(runSearch.mock.calls[0][0].offset).toBe(0);

        const list = shadow(element, 'c-cs-result-list');
        expect(list).not.toBeNull();
        const rows = list.shadowRoot.querySelectorAll('c-cs-result-row');
        expect(rows.length).toBe(3);
        expect(rows[0].shadowRoot.querySelector('.name-btn').textContent).toBe('Candidate 0');
        // c1 met, c2 met (row 0), c3 met via the query string
        expect(rows[0].shadowRoot.querySelectorAll('.crit-met').length).toBe(3);
        expect(rows[1].shadowRoot.querySelectorAll('.crit-notmet').length).toBe(1);

        expect(explainResults).toHaveBeenCalledTimes(1);
        expect(rows[0].shadowRoot.querySelector('.summary').textContent).toContain('Summary for');

        // chips render in the search bar
        const bar = shadow(element, 'c-cs-search-bar');
        expect(bar.shadowRoot.querySelectorAll('.chip-body').length).toBe(3);
    });

    it('opens the candidate panel with evidence and the profile', async () => {
        await searchFromUrl();
        const list = shadow(element, 'c-cs-result-list');
        list.shadowRoot.querySelector('c-cs-result-row').shadowRoot.querySelector('.name-btn').click();
        await flush(8);
        const panel = shadow(element, 'c-cs-candidate-panel');
        expect(panel).not.toBeNull();
        expect(getCandidateDetail).toHaveBeenCalledWith({
            contactId: '003000000000100AAA',
            auditId: 'a0X000000000001AAA'
        });
        expect(panel.shadowRoot.querySelector('.p-name').textContent).toBe('Candidate 0');
        expect(panel.shadowRoot.querySelector('.why-evidence').textContent).toContain('forklift licence');

        panel.shadowRoot.querySelector('[data-tab="skills"]').click();
        await flush();
        expect(panel.shadowRoot.querySelector('.skill').textContent).toBe('Forklift');

        // Escape closes
        panel.shadowRoot.querySelector('section').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        await flush();
        expect(shadow(element, 'c-cs-candidate-panel')).toBeNull();
    });

    it('selects two candidates and compares them', async () => {
        getCompareData.mockResolvedValue(
            JSON.stringify({
                auditId: 'a0X000000000001AAA',
                criteria: CRITERIA.items.map(({ id, label, kind, weight }) => ({
                    id,
                    label,
                    kind,
                    weight
                })),
                candidates: [0, 1].map((i) => ({
                    contactId: row(i).contactId,
                    name: `Candidate ${i}`,
                    scorePct: 90 - i,
                    met: ['c1', 'c3'],
                    notMet: ['c2'],
                    evidence: {},
                    skills: [],
                    recentNotes: [],
                    profile: {},
                    pipeline: {},
                    inSearch: true
                })),
                notices: []
            })
        );
        await searchFromUrl();
        const list = shadow(element, 'c-cs-result-list');
        const rows = list.shadowRoot.querySelectorAll('c-cs-result-row');
        [0, 1].forEach((i) => {
            const cb = rows[i].shadowRoot.querySelector('input[type="checkbox"]');
            cb.checked = true;
            cb.dispatchEvent(new CustomEvent('change'));
        });
        await flush();
        const tray = shadow(element, 'c-cs-selection-tray');
        expect(tray).not.toBeNull();
        expect(tray.shadowRoot.querySelector('.t-num').textContent).toBe('2');

        tray.shadowRoot.querySelector('[data-action="compare"]').click();
        await flush(8);
        expect(JSON.parse(getCompareData.mock.calls[0][0].contactIdsJson)).toEqual([row(0).contactId, row(1).contactId]);
        const cmp = shadow(element, 'c-cs-compare');
        expect(cmp.shadowRoot.querySelectorAll('.g-head').length).toBe(2);
        expect(cmp.shadowRoot.querySelectorAll('.cell-notmet').length).toBe(2);
    });

    it('refines from the chat, re-runs the search and marks rank changes', async () => {
        await searchFromUrl();
        refine.mockResolvedValue(
            JSON.stringify({
                criteria: { ...CRITERIA, trace: { searchType: 'Refine' } },
                reply: 'Widened to 25 miles.',
                needsClarification: false,
                patch: [{ op: 'update', id: 'c3', set: { radius: 25 } }],
                diff: [
                    {
                        op: 'update',
                        id: 'c3',
                        label: 'Dagenham + 25 mi',
                        before: { radius: 15, weight: 'required' },
                        after: { radius: 25, weight: 'required', kind: 'location' }
                    }
                ]
            })
        );
        runSearch.mockResolvedValue(response([row(1, { rank: 1 }), row(0, { rank: 2 }), row(5, { rank: 3 })]));

        shadow(element, '[data-action="open-chat"]').click();
        await flush();
        const chat = shadow(element, 'c-cs-refine-chat');
        chat.dispatchEvent(new CustomEvent('refine', { detail: { message: 'widen to 25 miles' } }));
        await flush(14);

        expect(refine).toHaveBeenCalled();
        expect(runSearch).toHaveBeenCalledTimes(2);
        expect(JSON.parse(runSearch.mock.calls[1][0].criteriaJson).trace.searchType).toBe('Refine');
        const turns = chat.shadowRoot.querySelectorAll('.turn');
        expect(turns.length).toBeGreaterThanOrEqual(2);
        expect(chat.shadowRoot.querySelector('.diff').textContent).toContain('15 → 25');

        const rows = shadow(element, 'c-cs-result-list').shadowRoot.querySelectorAll('c-cs-result-row');
        const tags = [...rows].map((r) => (r.shadowRoot.querySelector('.tags .tag') || {}).textContent);
        expect(tags).toEqual(['Up 1', 'Down 1', 'New']);
        expect(shadow(element, 'c-cs-result-list').shadowRoot.querySelector('.removed').textContent).toContain('1 removed');
    });

    it('starts a job match from c__jobId and opens the chat with the notice', async () => {
        startJobMatch.mockResolvedValue(
            response([row(0)], {
                criteria: { ...CRITERIA, jobId: 'a1w000000000001AAA' },
                notices: ['Built from the Textkernel job document for J-0142.']
            })
        );
        CurrentPageReference.emit({ state: { c__jobId: 'a1w000000000001AAA' } });
        await flush(12);
        expect(startJobMatch).toHaveBeenCalledWith({ jobId: 'a1w000000000001AAA' });
        const chat = shadow(element, 'c-cs-refine-chat');
        expect(chat).not.toBeNull();
        expect(chat.shadowRoot.querySelector('.bubble').textContent).toContain('Built from the Textkernel job document for J-0142.');
        expect(chat.shadowRoot.querySelector('.bubble').textContent).toContain('1 candidate.');
    });

    it('removing a chip re-runs as Manual, and undo restores it', async () => {
        await searchFromUrl();
        const bar = shadow(element, 'c-cs-search-bar');
        bar.shadowRoot.querySelector('.chip-x[data-id="c2"]').click();
        await flush(10);
        const second = JSON.parse(runSearch.mock.calls[1][0].criteriaJson);
        expect(second.items.map((i) => i.id)).toEqual(['c1', 'c3']);
        expect(second.trace).toEqual({
            searchType: 'Manual',
            parentAuditId: 'a0X000000000001AAA'
        });

        shadow(element, '[data-action="undo"]').click();
        await flush(10);
        const third = JSON.parse(runSearch.mock.calls[2][0].criteriaJson);
        expect(third.items.map((i) => i.id)).toEqual(['c1', 'c2', 'c3']);
    });

    it('loads the next page with the offset and audit id when the list asks', async () => {
        runSearch.mockResolvedValueOnce(response([row(0), row(1)], { total: 4, hasMore: true, nextOffset: 2 }));
        await searchFromUrl();
        runSearch.mockResolvedValueOnce(
            response([row(2, { rank: 3 }), row(3, { rank: 4 })], {
                total: 4,
                hasMore: false,
                offset: 2,
                nextOffset: 4
            })
        );
        shadow(element, 'c-cs-result-list').dispatchEvent(new CustomEvent('loadmore'));
        await flush(8);
        const call = runSearch.mock.calls[1][0];
        expect(call.offset).toBe(2);
        expect(call.auditId).toBe('a0X000000000001AAA');
        expect(JSON.parse(call.criteriaJson).trace).toBeUndefined();
        expect(shadow(element, 'c-cs-result-list').shadowRoot.querySelectorAll('c-cs-result-row').length).toBe(4);
    });

    it('shortlists from the panel on a job match and tags the row', async () => {
        startJobMatch.mockResolvedValue(
            response([row(0), row(1)], {
                criteria: { ...CRITERIA, jobId: 'a1w000000000001AAA' }
            })
        );
        bulkAddToJob.mockResolvedValue(
            JSON.stringify({
                added: 1,
                addedIds: [row(0).contactId],
                skipped: [],
                failed: [],
                message: 'Added 1 candidate to J-0142.'
            })
        );
        CurrentPageReference.emit({ state: { c__jobId: 'a1w000000000001AAA' } });
        await flush(12);
        const list = shadow(element, 'c-cs-result-list');
        list.shadowRoot.querySelector('c-cs-result-row').shadowRoot.querySelector('.name-btn').click();
        await flush(8);
        const panel = shadow(element, 'c-cs-candidate-panel');
        panel.shadowRoot.querySelector('[data-action="shortlist"]').click();
        await flush(8);
        expect(bulkAddToJob).toHaveBeenCalledWith({
            jobId: 'a1w000000000001AAA',
            contactIdsJson: JSON.stringify([row(0).contactId]),
            auditId: 'a0X000000000001AAA'
        });
        const tag = list.shadowRoot.querySelector('c-cs-result-row').shadowRoot.querySelector('.tag-amber');
        expect(tag.textContent).toBe('Shortlisted');
    });

    it('Clear search goes back to the home panels; Reset changes returns to the first criteria', async () => {
        runSearch.mockImplementation(({ criteriaJson }) => {
            const { trace, ...criteria } = JSON.parse(criteriaJson); // eslint-disable-line no-unused-vars
            return Promise.resolve(response([row(0), row(1)], { criteria }));
        });
        await searchFromUrl();
        const bar = shadow(element, 'c-cs-search-bar');
        bar.shadowRoot.querySelector('.chip-x[data-id="c2"]').click();
        await flush(10);
        bar.shadowRoot.querySelector('.chip-x[data-id="c3"]').click();
        await flush(10);
        expect(JSON.parse(runSearch.mock.calls[2][0].criteriaJson).items.map((i) => i.id)).toEqual(['c1']);

        shadow(element, '[data-action="reset"]').click();
        await flush(10);
        expect(JSON.parse(runSearch.mock.calls[3][0].criteriaJson).items.map((i) => i.id)).toEqual(['c1', 'c2', 'c3']);

        bar.shadowRoot.querySelector('[data-action="clear"]').click();
        await flush(6);
        expect(shadow(element, 'c-cs-result-list')).toBeNull();
        expect(shadow(element, 'c-cs-home-panels')).not.toBeNull();
        expect(bar.shadowRoot.querySelectorAll('.chip-body').length).toBe(0);
        expect(bar.shadowRoot.querySelector('.nl-text').value).toBe('');
    });

    it('saves the search from the inline popover with the typed name', async () => {
        saveSearch.mockResolvedValue('a0Y000000000001AAA');
        await searchFromUrl();
        const bar = shadow(element, 'c-cs-search-bar');
        bar.shadowRoot.querySelector('[data-action="save"]').click();
        await flush();
        const input = bar.shadowRoot.querySelector('.save-input');
        expect(input.value).toBe('forklift operatives near Dagenham');
        input.value = 'Dagenham forklift';
        input.dispatchEvent(new CustomEvent('input'));
        bar.shadowRoot.querySelector('[data-action="confirm-save"]').click();
        await flush(8);
        expect(saveSearch.mock.calls[0][0].name).toBe('Dagenham forklift');
        expect(JSON.parse(saveSearch.mock.calls[0][0].criteriaJson).trace).toBeUndefined();
        expect(shadow(element, '.toast-success')).not.toBeNull();
    });

    it('adds the selection to a talent pool picked in the tray', async () => {
        searchRecords.mockResolvedValue(JSON.stringify([{ id: 'a0P000000000001AAA', name: 'Forklift pool', sub: null }]));
        bulkAddToTalentPool.mockResolvedValue(
            JSON.stringify({ added: 1, addedIds: [row(0).contactId], skipped: [], failed: [], message: 'Added 1 candidate to Forklift pool.' })
        );
        await searchFromUrl();
        const cb = shadow(element, 'c-cs-result-list').shadowRoot.querySelector('c-cs-result-row').shadowRoot.querySelector('input[type="checkbox"]');
        cb.checked = true;
        cb.dispatchEvent(new CustomEvent('change'));
        await flush();
        const tray = shadow(element, 'c-cs-selection-tray');
        tray.shadowRoot.querySelector('[data-action="add-pool"]').click();
        await flush(6);
        expect(searchRecords).toHaveBeenCalledWith({ objectApiName: 'TR1__Call_List__c', term: '' });
        tray.shadowRoot.querySelector('.opt').click();
        await flush();
        tray.shadowRoot.querySelector('[data-action="confirm"]').click();
        await flush(8);
        expect(bulkAddToTalentPool).toHaveBeenCalledWith({
            poolId: 'a0P000000000001AAA',
            contactIdsJson: JSON.stringify([row(0).contactId]),
            auditId: 'a0X000000000001AAA'
        });
        expect(shadow(element, 'c-cs-selection-tray')).toBeNull();
    });

    it('shows the CV from Textkernel, cleaned, with the search terms highlighted', async () => {
        getCandidateCv.mockResolvedValue(
            JSON.stringify({
                docId: row(0).docId,
                html:
                    '<div><tk_metadata name="author" value="x"> </tk_metadata><p style="text-align:center"><b>Candidate 0</b></p>' +
                    '<p onclick="alert(1)">Warehouse Operative since 2019. Certified Forklift Operator, forklift licence.</p>' +
                    '<script>window.hacked = true</script><a href="javascript:alert(1)">bad link</a><img src="x.png"></div>'
            })
        );
        getCandidateCvLink.mockResolvedValue(JSON.stringify({ url: 'https://files.example.com/cv.pdf?sig=1', name: 'cv.pdf', extension: 'pdf' }));
        window.open = jest.fn();
        await searchFromUrl();
        shadow(element, 'c-cs-result-list').shadowRoot.querySelector('c-cs-result-row').shadowRoot.querySelector('.name-btn').click();
        await flush(8);
        const panel = shadow(element, 'c-cs-candidate-panel');
        panel.shadowRoot.querySelector('[data-tab="cv"]').click();
        await flush(10);
        expect(getCandidateCv).toHaveBeenCalledWith({ docId: row(0).docId });
        const viewer = panel.shadowRoot.querySelector('c-cs-cv-viewer');
        const doc = viewer.shadowRoot.querySelector('.cv-doc');
        expect(doc.querySelector('script')).toBeNull();
        expect(doc.querySelector('img')).toBeNull();
        expect(doc.querySelector('tk_metadata')).toBeNull();
        expect(doc.querySelector('[onclick]')).toBeNull();
        expect(doc.querySelector('a').getAttribute('href')).toBeNull();
        expect(window.hacked).toBeUndefined();
        const marks = [...doc.querySelectorAll('mark.hit')].map((m) => m.textContent);
        expect(marks).toEqual(['Warehouse Operative', 'Forklift', 'forklift']);
        const chips = [...viewer.shadowRoot.querySelectorAll('.term')].map((t) => t.textContent);
        expect(chips).toContain('Forklift2');

        viewer.shadowRoot.querySelector('[data-action="open-original"]').click();
        await flush(6);
        expect(getCandidateCvLink).toHaveBeenCalledWith({ contactId: row(0).contactId });
        expect(window.open).toHaveBeenCalledWith('https://files.example.com/cv.pdf?sig=1', '_blank', 'noopener');
    });

    it('type-ahead: picking a job title adds a title chip, searches, and suggests skills to add', async () => {
        jest.useFakeTimers();
        suggestProfessions.mockResolvedValue(JSON.stringify([{ codeId: 2357, description: 'Forklift Operator' }]));
        autocompleteSkills.mockResolvedValue(JSON.stringify([{ id: 'KS1', description: 'Forklift Truck Operation', category: 'Logistics' }]));
        suggestSkillsForProfession.mockResolvedValue(
            JSON.stringify([
                { id: 'KS1', description: 'Forklift Truck Operation', score: 0.9 },
                { id: 'KS2', description: 'Reach Truck', score: 0.8 }
            ])
        );
        runSearch.mockImplementation(({ criteriaJson }) => {
            const { trace, ...criteria } = JSON.parse(criteriaJson); // eslint-disable-line no-unused-vars
            return Promise.resolve(response([row(0)], { criteria }));
        });
        await flush();
        const bar = shadow(element, 'c-cs-search-bar');
        const box = bar.shadowRoot.querySelector('.nl-text');
        box.value = 'forklift op';
        box.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(bar.shadowRoot.querySelectorAll('.ta-row').length).toBeGreaterThanOrEqual(1);
        jest.advanceTimersByTime(350);
        jest.useRealTimers();
        await flush(8);
        expect(suggestProfessions).toHaveBeenCalledWith({ prefix: 'forklift op' });
        const labels = [...bar.shadowRoot.querySelectorAll('.ta-row .ta-label')].map((l) => l.textContent);
        expect(labels).toEqual(['forklift op', 'Forklift Operator', 'Forklift Truck Operation']);

        bar.shadowRoot.querySelector('.ta-profession').click();
        await flush(12);
        const sent = JSON.parse(runSearch.mock.calls[0][0].criteriaJson);
        expect(sent.items[0]).toEqual(expect.objectContaining({ kind: 'title', value: 'Forklift Operator', professionCode: 2357, weight: 'required' }));
        expect(shadow(element, 'c-cs-result-list')).not.toBeNull();
        expect(suggestSkillsForProfession).toHaveBeenCalledWith({ professionCodeId: 2357 });
        expect(bar.shadowRoot.querySelector('.strip-title').textContent).toBe('Suggested skills for Forklift Operator');

        bar.shadowRoot.querySelector('.strip-all').click();
        await flush(12);
        const second = JSON.parse(runSearch.mock.calls[1][0].criteriaJson);
        expect(second.items.map((i) => i.code).filter(Boolean)).toEqual(['KS1', 'KS2']);
        expect(bar.shadowRoot.querySelectorAll('.sugg-added').length).toBe(2);
    });

    it('opens the CV parser in a modal from the banner and closes it with Escape', async () => {
        await flush();
        shadow(element, '[data-action="parse"]').click();
        await flush();
        expect(shadow(element, 'c-tx-resume-parser')).not.toBeNull();
        shadow(element, '.parser-modal').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        await flush();
        expect(shadow(element, 'c-tx-resume-parser')).toBeNull();
    });

    it('sends email to the selection through the packaged flow, and closes when the flow finishes', async () => {
        await searchFromUrl();
        const cb = shadow(element, 'c-cs-result-list').shadowRoot.querySelector('c-cs-result-row').shadowRoot.querySelector('input[type="checkbox"]');
        cb.checked = true;
        cb.dispatchEvent(new CustomEvent('change'));
        await flush();
        shadow(element, 'c-cs-selection-tray').shadowRoot.querySelector('[data-action="email"]').click();
        await flush();
        const flow = shadow(element, 'lightning-flow');
        expect(flow).not.toBeNull();
        expect(flow.flowApiName).toBe('TR1__AEF_Send_Email');
        expect(flow.flowInputVariables).toEqual([
            { name: 'recipientIds', type: 'String', value: [row(0).contactId] },
            { name: 'isAsyncSelection', type: 'Boolean', value: false }
        ]);
        flow.dispatchEvent(new CustomEvent('statuschange', { detail: { status: 'FINISHED' } }));
        await flush();
        expect(shadow(element, 'lightning-flow')).toBeNull();
        expect(shadow(element, '.toast-title').textContent).toBe('Email sent');
    });

    it('splits an explain batch that timed out and retries the halves', async () => {
        explainResults.mockImplementation(({ docIdsJson }) => {
            const ids = JSON.parse(docIdsJson);
            if (ids.length > 1) return Promise.reject({ body: { message: 'Explanations are not available right now: Read timed out' } });
            return Promise.resolve(JSON.stringify([{ docId: ids[0], summary: `Summary for ${ids[0]}`, criteria: [] }]));
        });
        await searchFromUrl();
        await flush(20);
        const rows = shadow(element, 'c-cs-result-list').shadowRoot.querySelectorAll('c-cs-result-row');
        const summaries = [...rows].map((r) => (r.shadowRoot.querySelector('.summary') || {}).textContent);
        expect(summaries).toEqual([`Summary for ${row(0).docId}`, `Summary for ${row(1).docId}`, `Summary for ${row(2).docId}`]);
        expect(explainResults.mock.calls.map((c) => JSON.parse(c[0].docIdsJson).length)).toEqual([3, 2, 1, 1, 1]);
    });

    it('adds a task for the selection through the packaged Power Note flow', async () => {
        await searchFromUrl();
        const cb = shadow(element, 'c-cs-result-list').shadowRoot.querySelector('c-cs-result-row').shadowRoot.querySelector('input[type="checkbox"]');
        cb.checked = true;
        cb.dispatchEvent(new CustomEvent('change'));
        await flush();
        shadow(element, 'c-cs-selection-tray').shadowRoot.querySelector('[data-action="task"]').click();
        await flush();
        const flow = shadow(element, 'lightning-flow');
        expect(flow.flowApiName).toBe('TR1__AEF_Create_Power_Note');
        expect(flow.flowInputVariables).toEqual([
            { name: 'recordIds', type: 'String', value: [row(0).contactId] },
            { name: 'isAsyncSelection', type: 'Boolean', value: false }
        ]);
        expect(shadow(element, '.parser-head h2').textContent).toBe('Add a task for 1 candidate');
        flow.dispatchEvent(new CustomEvent('statuschange', { detail: { status: 'FINISHED' } }));
        await flush();
        expect(shadow(element, 'lightning-flow')).toBeNull();
    });

    it('shows the default Textkernel columns, and adds a Salesforce column picked in the column chooser', async () => {
        runSearch.mockResolvedValue(response([row(0, { fields: { experience_years: ['7'], educationlevel_international: ['Secondary'] } }), row(1)]));
        getColumnValues.mockResolvedValue(JSON.stringify({ '003000000000100AAA': { MobilePhone: '07700 900123' } }));
        await searchFromUrl();
        const list = shadow(element, 'c-cs-result-list');
        const firstRow = () => list.shadowRoot.querySelector('c-cs-result-row').shadowRoot;
        const cells = () =>
            [...firstRow().querySelectorAll('.fact')].map((f) => `${f.querySelector('.fact-label').textContent}=${f.querySelector('.fact-val').textContent}`);
        expect(cells()).toEqual(['Experience=7 yrs', 'Education level=Secondary', 'Date available=–']);
        expect(getColumnValues).not.toHaveBeenCalled();

        list.shadowRoot.querySelector('[data-action="columns"]').click();
        await flush();
        const mobile = list.shadowRoot.querySelector('input[data-key="sf:MobilePhone"]');
        mobile.checked = true;
        mobile.dispatchEvent(new CustomEvent('change'));
        await flush(8);
        expect(getColumnValues).toHaveBeenCalledWith({
            contactIdsJson: JSON.stringify(['003000000000100AAA', '003000000000101AAA']),
            pathsJson: JSON.stringify(['MobilePhone'])
        });
        expect(cells()).toEqual(['Experience=7 yrs', 'Education level=Secondary', 'Date available=–', 'Mobile=07700 900123']);
        expect(JSON.parse(window.localStorage.getItem('amp.candidateSearch.columns'))).toEqual([
            'tk:experience',
            'tk:education',
            'tk:available',
            'sf:MobilePhone'
        ]);
    });

    it('puts the chosen columns in a header with resizable edges, and keeps the widths', async () => {
        await searchFromUrl();
        const list = shadow(element, 'c-cs-result-list').shadowRoot;
        const labels = [...list.querySelectorAll('.col-head .col-label')].map((n) => n.textContent.trim());
        expect(labels).toEqual(['Candidate', 'Criteria', 'Experience', 'Education level', 'Date available', 'Summary', 'Match']);
        const handle = list.querySelector('.col-resize[data-key="tk:experience"]');
        handle.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', shiftKey: true }));
        await flush();
        expect(JSON.parse(window.localStorage.getItem('amp.candidateSearch.columnWidths'))).toEqual({ 'tk:experience': 180 });
        expect(list.querySelector('.rows').getAttribute('style')).toContain('180px');
    });

    it('hovering the score lists what matched and what did not', async () => {
        await searchFromUrl();
        const rows = shadow(element, 'c-cs-result-list').shadowRoot.querySelectorAll('c-cs-result-row');
        const second = rows[1].shadowRoot;
        second.querySelector('.score').dispatchEvent(new CustomEvent('mouseenter'));
        await flush();
        const pop = second.querySelector('.match-pop');
        expect(pop.classList.contains('match-pop-open')).toBe(true);
        const texts = (sel) => [...pop.querySelectorAll(`${sel} .mp-text`)].map((n) => n.textContent);
        expect(texts('.mp-met')).toEqual(['Warehouse Operative', 'Dagenham + 15 mi']);
        expect(texts('.mp-not')).toEqual(['Forklift']);
        expect(pop.querySelector('.mp-sub').textContent).toContain('2 of 3 criteria met');
    });

    it('Refine with AI bounces after the first search only', async () => {
        await searchFromUrl();
        const btn = shadow(element, '[data-action="open-chat"]');
        expect(btn.textContent).toContain('Refine with AI');
        expect(btn.classList.contains('bounce')).toBe(true);
        btn.dispatchEvent(new CustomEvent('animationend'));
        await flush();
        expect(shadow(element, '[data-action="open-chat"]').classList.contains('bounce')).toBe(false);
    });
});
