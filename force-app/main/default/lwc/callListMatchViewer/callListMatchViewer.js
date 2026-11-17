import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, createRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import NAME_FIELD from '@salesforce/schema/TR1__Call_List__c.Name';
import runPoolMatch from '@salesforce/apex/AmplifyTalentPoolMatchController.runPoolMatch';
import refinePoolMatch from '@salesforce/apex/AmplifyTalentPoolMatchController.refinePoolMatch';
import { buildDemoCandidates, poolKeyFromName } from './callListMatchDemoData';
import { buildEvidence, buildTrace, SIGNAL_LABELS } from './callListMatchEvidence';

/** Order the evidence groups appear in under "Why this match". */
const EVIDENCE_ORDER = ['relevance', 'silver', 'engagement', 'redeploy', 'vms'];

const PAGE_SIZE = 10;
const MAX_RESULTS = 20;
const SKILLS_PREVIEW = 8;

const RERUN_MS = 1400;            // simulated re-run time after a weighting change
const WEIGHT_DEBOUNCE_MS = 700;   // wait for the user to stop dragging before re-running
const LOADING_TICK_MS = 900;

const MATCH_MESSAGES  = ['Searching the talent pool', 'Scoring role relevance', 'Checking silver medalists, engagement and VMS data'];
const WEIGHT_MESSAGES = ['Applying your weighting', 'Re-scoring silver medalists and engagement', 'Checking redeployment and VMS readiness'];
const REFINE_MESSAGES = ['Refining the search', 'Re-scoring candidates'];

const STRONG = 70;
const MID = 40;
const VMS_READY_AT = 80;
const ENGAGED_AT = 70;

/** The attributes the match is built from. Weights are 0 to 100 and shown as a share of the whole. */
const SIGNALS = [
    { key: 'relevance',  label: 'Role relevance',   help: 'Title and skills match against the pool' },
    { key: 'silver',     label: 'Silver medalists', help: 'Shortlisted before and known to be qualified, never quite placed' },
    { key: 'engagement', label: 'Engagement',       help: 'Bullhorn Engagement Score (0 to 100): do they reply to email and SMS' },
    { key: 'redeploy',   label: 'Redeployment',     help: 'Already placed on a similar role with this account' },
    { key: 'vms',        label: 'VMS readiness',    help: 'Share of the required VMS submission data already on file' }
];

const WEIGHT_PRESETS = [
    { id: 'balanced', label: 'Balanced',      weights: { relevance: 40, silver: 20, engagement: 20, redeploy: 10, vms: 10 } },
    { id: 'proven',   label: 'Proven talent', weights: { relevance: 25, silver: 30, engagement: 15, redeploy: 25, vms: 5 } },
    { id: 'engaged',  label: 'Most engaged',  weights: { relevance: 25, silver: 10, engagement: 45, redeploy: 10, vms: 10 } },
    { id: 'vmsfast',  label: 'VMS speed',     weights: { relevance: 25, silver: 10, engagement: 15, redeploy: 5, vms: 45 } }
];

const FILTERS = [
    { key: 'all',        label: 'All',              test: () => true },
    { key: 'silver',     label: 'Silver medalists', test: (c) => c.silver.count > 0 },
    { key: 'redeploy',   label: 'Redeploy targets', test: (c) => c.redeploy.count > 0 },
    { key: 'vms',        label: 'VMS ready',        test: (c) => c.vms != null && c.vms >= VMS_READY_AT },
    { key: 'engaged',    label: 'Highly engaged',   test: (c) => c.engagement != null && c.engagement >= ENGAGED_AT }
];

function initialsOf(name) {
    const parts = (name || '').trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0) return '?';
    if (parts.length === 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function tierOf(pct) {
    if (pct >= STRONG) return 'strong';
    if (pct >= MID) return 'mid';
    if (pct > 0) return 'low';
    return 'none';
}

/** The Candidate Summary is a rich text field. Show it as plain text. */
function plainText(html) {
    if (!html) return '';
    return String(html)
        .replace(/<\s*(br|\/p|\/div|\/li)\s*\/?>/gi, ' ')
        .replace(/<[^>]*>/g, '')
        .replace(/&nbsp;/gi, ' ')
        .replace(/&lt;/gi, '<')
        .replace(/&gt;/gi, '>')
        .replace(/&quot;/gi, '"')
        .replace(/&#0?39;|&apos;/gi, "'")
        .replace(/&amp;/gi, '&')
        .replace(/\s+/g, ' ')
        .trim();
}

/**
 * Lays out the SOAP request(s) one tag per line, indented, so it reads well in the viewer.
 * Leaf elements stay on one line (<field>FULLTEXT</field>). The Apex side prefixes each call
 * with an XML comment label, which also resets the indent.
 */
function prettyXmlLines(xml) {
    if (!xml) return [];
    const tokens = String(xml).match(/<!--[\s\S]*?-->|<\/?[^>]+>|[^<]+/g) || [];
    const lines = [];
    const pad = (d) => '    '.repeat(Math.max(d, 0));
    const isOpen = (t) => /^<[^/!?][^>]*[^/]>$|^<[^/!?>]>$/.test(t);
    const isClose = (t) => /^<\//.test(t);
    const isText = (t) => !t.startsWith('<');
    const name = (t) => (t.match(/^<\/?([^\s>/]+)/) || [])[1];
    let depth = 0;
    for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i];
        if (isText(t) && !t.trim()) continue;
        if (t.startsWith('<!--')) {
            if (lines.length) lines.push('');
            depth = 0;
            lines.push(t.trim());
        } else if (isOpen(t)) {
            const next = tokens[i + 1];
            const after = tokens[i + 2];
            if (next !== undefined && isText(next) && next.trim() && after && isClose(after) && name(after) === name(t)) {
                lines.push(pad(depth) + t + next.trim() + after);
                i += 2;
            } else if (next !== undefined && isClose(next) && name(next) === name(t)) {
                lines.push(pad(depth) + t + next);
                i += 1;
            } else {
                lines.push(pad(depth) + t);
                depth++;
            }
        } else if (isClose(t)) {
            depth--;
            lines.push(pad(depth) + t);
        } else {
            lines.push(pad(depth) + t.trim());
        }
    }
    return lines;
}

export default class CallListMatchViewer extends NavigationMixin(LightningElement) {
    @api recordId; // the Talent Pool (TR1__Call_List__c) this component sits on

    /** Optional App Builder overrides for the TK search. Blank = derive from the pool name. */
    @api searchTitle;
    @api searchCity;

    poolLabel = '';

    // ── Match state ──
    isMatching = false;
    hasRun = false;
    loadingMessage = '';
    dataMode = 'live';          // 'live' or 'demo'
    notice = null;
    queryContextJson = null;
    tkQuery = null;
    requestXml = null;
    requestOpen = false;
    copyLabel = 'Copy';
    masterList = [];
    currentPage = 1;
    activeFilter = 'all';
    addedIds = new Set();
    refineText = '';

    // ── Weighting state ──
    tuneOpen = false;
    weights = { ...WEIGHT_PRESETS[0].weights };

    _initialMatchTriggered = false;
    _loadingTimer;
    _copyTimer;
    _weightTimer;

    @wire(getRecord, { recordId: '$recordId', fields: [NAME_FIELD] })
    wiredRecord({ data }) {
        if (data) {
            this.poolLabel = data.fields.Name.value;
            if (!this._initialMatchTriggered) {
                this._initialMatchTriggered = true;
                this.runMatch();
            }
        }
    }

    disconnectedCallback() {
        clearTimeout(this._copyTimer);
        clearInterval(this._loadingTimer);
        clearTimeout(this._weightTimer);
    }

    // ─────────────────────────────────────────────────────────────
    // Header
    // ─────────────────────────────────────────────────────────────

    get poolDisplayName() {
        return this.poolLabel || 'Talent Pool';
    }

    get buttonLabel() {
        return this.hasRun ? 'Re-run Match' : 'Run Match';
    }

    get resultCountLabel() {
        const n = this.masterList.length;
        return n === 1 ? '1 candidate' : `${n} candidates`;
    }

    get isLive() {
        return this.dataMode === 'live';
    }

    get modeLabel() {
        return this.isLive ? 'Live match' : 'Demo data';
    }

    get modeClass() {
        return this.isLive ? 'mode-badge mode-live' : 'mode-badge mode-demo';
    }

    get hasNotice() {
        return !!this.notice;
    }

    get hasRequestXml() {
        return this.isLive && !!this.requestXml;
    }

    get requestToggleLabel() {
        return this.requestOpen ? 'Hide request sent to TextKernel' : 'Show request sent to TextKernel';
    }

    get requestToggleIcon() {
        return this.requestOpen ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get requestExpanded() {
        return this.requestOpen ? 'true' : 'false';
    }

    get requestPretty() {
        return prettyXmlLines(this.requestXml);
    }

    get requestLines() {
        return this.requestPretty.map((text, i) => ({
            id: `l${i}`,
            text,
            cls: text.trim().startsWith('<!--') ? 'req-line req-comment' : 'req-line'
        }));
    }

    get requestMeta() {
        const n = (this.requestXml.match(/<!--/g) || []).length;
        return n > 1 ? `${n} calls` : '1 call';
    }

    toggleRequest() {
        this.requestOpen = !this.requestOpen;
    }

    async copyRequest() {
        try {
            await navigator.clipboard.writeText(this.requestPretty.join('\n'));
            this.copyLabel = 'Copied';
        } catch (e) {
            this.copyLabel = 'Copy failed';
        }
        clearTimeout(this._copyTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._copyTimer = setTimeout(() => {
            this.copyLabel = 'Copy';
        }, 1500);
    }

    get hasTkQuery() {
        return this.isLive && !!this.tkQuery;
    }

    // ─────────────────────────────────────────────────────────────
    // Retrieval trace: how the list was produced, step by step
    // ─────────────────────────────────────────────────────────────

    get traceSteps() {
        const demo = !this.isLive;
        let evidenceCount = 0;
        let anyDerived = false;
        this.masterList.forEach((c) => {
            const ev = buildEvidence(c, c.apexEvidence, demo);
            evidenceCount += ev.items.length;
            if (ev.derived) anyDerived = true;
        });
        return buildTrace({
            hasTkQuery: this.hasTkQuery,
            candidateCount: this.masterList.length,
            evidenceCount,
            anyDerived,
            demo
        });
    }

    get showTrace() {
        return this.hasRun && !this.isMatching && this.masterList.length > 0;
    }

    get traceCaption() {
        return this.isLive
            ? 'Every score below is traced back to the records it came from.'
            : 'Demo data: the evidence passages shown are illustrative.';
    }

    // ─────────────────────────────────────────────────────────────
    // Matching strategy: weights
    // ─────────────────────────────────────────────────────────────

    get weightTotal() {
        return SIGNALS.reduce((t, s) => t + this.weights[s.key], 0);
    }

    get weightRows() {
        const total = this.weightTotal;
        return SIGNALS.map((s) => {
            const value = this.weights[s.key];
            const share = total > 0 ? Math.round((value / total) * 100) : 0;
            return {
                key: s.key,
                label: s.label,
                help: s.help,
                value,
                share,
                shareLabel: `${share}%`,
                segStyle: `width: ${share}%`,
                segClass: `seg seg-${s.key}`,
                dotClass: `dot dot-${s.key}`
            };
        });
    }

    get weightSummary() {
        return this.weightRows
            .filter((r) => r.share > 0)
            .map((r) => `${r.label} ${r.share}%`)
            .join('  ·  ');
    }

    get presetButtons() {
        return WEIGHT_PRESETS.map((p) => {
            const active = SIGNALS.every((s) => this.weights[s.key] === p.weights[s.key]);
            return { id: p.id, label: p.label, variant: active ? 'brand' : 'neutral' };
        });
    }

    get tuneToggleLabel() {
        return this.tuneOpen ? 'Hide tuning' : 'Tune matching';
    }

    get tuneIcon() {
        return this.tuneOpen ? 'utility:chevronup' : 'utility:chevrondown';
    }

    toggleTune() {
        this.tuneOpen = !this.tuneOpen;
    }

    handleWeightChange(event) {
        const key = event.target.dataset.key;
        this.weights = { ...this.weights, [key]: Number(event.detail.value) };
        this._scheduleWeightRerun();
    }

    handlePreset(event) {
        const preset = WEIGHT_PRESETS.find((p) => p.id === event.currentTarget.dataset.id);
        if (!preset) return;
        this.weights = { ...preset.weights };
        this._scheduleWeightRerun();
    }

    _scheduleWeightRerun() {
        clearTimeout(this._weightTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._weightTimer = setTimeout(() => this._rerunForWeights(), WEIGHT_DEBOUNCE_MS);
    }

    /**
     * Simulated re-run. The search resets (loading stage, back to page 1, rows collapsed)
     * but the same candidates come back in the same order. Real re-scoring plugs in here.
     */
    async _rerunForWeights() {
        if (!this.hasRun || this.isMatching) return;
        this._beginLoading(WEIGHT_MESSAGES);
        await this._wait(RERUN_MS);
        this.currentPage = 1;
        this.masterList = this.masterList.map((c) => ({ ...c, expanded: false, showAllSkills: false }));
        this._endLoading();
    }

    // ─────────────────────────────────────────────────────────────
    // Match: live first, demo data as the safety net
    // ─────────────────────────────────────────────────────────────

    async runMatch() {
        this.hasRun = false;
        this.notice = null;
        this._beginLoading(MATCH_MESSAGES);

        try {
            const res = await runPoolMatch({
                callListId: this.recordId,
                searchTitle: this.searchTitle,
                searchCity: this.searchCity,
                maxResults: MAX_RESULTS
            });
            this._applyLive(res, false);
        } catch (err) {
            this._applyDemo(this._errorText(err));
        } finally {
            this._endLoading();
            this.hasRun = true;
        }
    }

    _applyLive(res, fromRefine) {
        const candidates = (res && res.candidates) || [];

        if (candidates.length === 0) {
            if (fromRefine) {
                this.masterList = [];
                this.queryContextJson = res.queryContextJson || this.queryContextJson;
                this.tkQuery = res.tkQuery || this.tkQuery;
                this.requestXml = res.requestXml || this.requestXml;
                this.notice = 'No candidates matched the refined search. Try loosening it.';
                return;
            }
            this._applyDemo('The live match returned no candidates.');
            return;
        }

        this.dataMode = 'live';
        this.notice = null;
        this.queryContextJson = res.queryContextJson;
        this.tkQuery = res.tkQuery;
        this.requestXml = res.requestXml;
        this.currentPage = 1;
        this.activeFilter = 'all';
        this.masterList = candidates.map((c) => this._fromApex(c));
    }

    _applyDemo(reason) {
        this.dataMode = 'demo';
        this.notice = `Showing demo candidates. ${reason}`;
        this.queryContextJson = null;
        this.tkQuery = null;
        this.requestXml = null;
        this.currentPage = 1;
        this.activeFilter = 'all';
        this.masterList = buildDemoCandidates(poolKeyFromName(this.poolLabel)).map((c) => ({
            ...c,
            expanded: false,
            showAllSkills: false,
            favorited: false
        }));
    }

    _fromApex(c) {
        return {
            id: c.contactId,
            contactId: c.contactId,
            name: c.name,
            title: c.title,
            location: c.location,
            status: c.status || 'Unknown',
            relevance: c.relevance,
            reasons: c.reasons || [],
            summary: plainText(c.summary),
            skills: c.skills || [],
            silver: { count: c.silverCount || 0, detail: c.silverDetail },
            engagement: c.engagementScore == null ? null : Number(c.engagementScore),
            redeploy: { count: c.redeployCount || 0, detail: c.redeployDetail },
            vms: c.vmsPercent == null ? null : Number(c.vmsPercent),
            apexEvidence: c.evidence || [],   // retrieved passages, see callListMatchEvidence.js for the shape
            expanded: false,
            showAllSkills: false,
            favorited: false
        };
    }

    // ─────────────────────────────────────────────────────────────
    // Refine (same natural-language parser as the Job Activator)
    // ─────────────────────────────────────────────────────────────

    get refineDisabled() {
        return this.isMatching || !this.refineText.trim();
    }

    handleRefineChange(event) {
        this.refineText = event.target.value;
    }

    handleRefineKeyup(event) {
        if (event.key === 'Enter') {
            this.refineText = event.target.value;
            if (!this.refineDisabled) this.handleRefine();
        }
    }

    async handleRefine() {
        const instruction = this.refineText.trim();
        if (!instruction) return;

        this.notice = null;
        this._beginLoading(REFINE_MESSAGES);
        try {
            if (this.isLive && this.queryContextJson) {
                const res = await refinePoolMatch({
                    callListId: this.recordId,
                    instruction,
                    queryContextJson: this.queryContextJson
                });
                this._applyLive(res, true);
            } else {
                await this._wait(RERUN_MS); // demo data: refinement is simulated
                this.currentPage = 1;
            }
            this.refineText = '';
        } catch (err) {
            this.notice = this._errorText(err);
        } finally {
            this._endLoading();
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Filters and paging
    // ─────────────────────────────────────────────────────────────

    get filterChips() {
        return FILTERS.map((f) => {
            const count = this.masterList.filter(f.test).length;
            return {
                key: f.key,
                label: `${f.label} (${count})`,
                chipClass: this.activeFilter === f.key ? 'chip chip-active' : 'chip'
            };
        });
    }

    handleFilter(event) {
        this.activeFilter = event.currentTarget.dataset.key;
        this.currentPage = 1;
    }

    get filteredList() {
        const filter = FILTERS.find((f) => f.key === this.activeFilter) || FILTERS[0];
        return this.masterList.filter(filter.test);
    }

    get hasResults() {
        return this.filteredList.length > 0;
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.filteredList.length / PAGE_SIZE));
    }

    get showPagination() {
        return this.filteredList.length > PAGE_SIZE;
    }

    get pageIndicator() {
        return `Page ${this.currentPage} of ${this.totalPages}`;
    }

    get previousDisabled() {
        return this.currentPage <= 1;
    }

    get nextDisabled() {
        return this.currentPage >= this.totalPages;
    }

    goPreviousPage() {
        if (this.currentPage > 1) this.currentPage -= 1;
    }

    goNextPage() {
        if (this.currentPage < this.totalPages) this.currentPage += 1;
    }

    get pagedCandidates() {
        const start = (this.currentPage - 1) * PAGE_SIZE;
        return this.filteredList.slice(start, start + PAGE_SIZE).map((c) => this._decorate(c));
    }

    // ─────────────────────────────────────────────────────────────
    // Row decoration
    // ─────────────────────────────────────────────────────────────

    _decorate(c) {
        const skillsOverflow = c.skills.length > SKILLS_PREVIEW;
        const visibleSkills = c.showAllSkills || !skillsOverflow ? c.skills : c.skills.slice(0, SKILLS_PREVIEW);

        const silverPct = c.silver.count > 0 ? Math.min(100, 50 + 25 * c.silver.count) : 0;
        const engagePct = c.engagement == null ? 0 : c.engagement;
        const redeployPct = c.redeploy.count > 0 ? 100 : 0;
        const vmsPct = c.vms == null ? 0 : c.vms;

        const signals = [
            this._signal('silver', 'Silver medalist', silverPct,
                c.silver.count > 0 ? (c.silver.count > 1 ? `Yes, ${c.silver.count}x` : 'Yes') : 'No'),
            this._signal('engagement', 'Engagement', engagePct,
                c.engagement == null ? 'n/a' : String(Math.round(c.engagement))),
            this._signal('redeploy', 'Redeployment', redeployPct, c.redeploy.count > 0 ? 'Yes' : 'No'),
            this._signal('vms', 'VMS data', vmsPct, c.vms == null ? 'n/a' : `${Math.round(c.vms)}%`)
        ];

        const badges = [];
        if (c.silver.count > 0) badges.push({ key: 'silver', label: 'Silver medalist' });
        if (c.redeploy.count > 0) badges.push({ key: 'redeploy', label: 'Redeploy target' });
        if (c.vms != null && c.vms >= VMS_READY_AT) badges.push({ key: 'vms', label: 'VMS ready' });
        if (c.engagement != null && c.engagement >= ENGAGED_AT) badges.push({ key: 'engaged', label: 'Highly engaged' });

        const insights = [
            {
                key: 'silver', label: 'Silver medalist',
                text: c.silver.count > 0
                    ? (c.silver.detail || `Shortlisted ${c.silver.count} time(s) before.`)
                    : 'No previous shortlists on record.'
            },
            {
                key: 'engagement', label: 'Engagement',
                text: c.engagement == null
                    ? 'No engagement score on this record.'
                    : `Engagement score ${Math.round(c.engagement)} of 100.`
            },
            {
                key: 'redeploy', label: 'Redeployment',
                text: c.redeploy.count > 0
                    ? (c.redeploy.detail || 'Placed with this account before.')
                    : 'Not placed on a similar role with this account before.'
            },
            {
                key: 'vms', label: 'VMS readiness',
                text: c.vms == null
                    ? 'VMS readiness not assessed.'
                    : `${Math.round(c.vms)}% of the required VMS submission data is on file.`
            }
        ];

        // Evidence: group the cited passages under the factor they support
        const ev = buildEvidence(c, c.apexEvidence, !this.isLive);
        const insightText = { relevance: c.reasons.length ? c.reasons.slice(0, 3).join(', ') : 'Title and skills match against the pool.' };
        insights.forEach((i) => { insightText[i.key] = i.text; });
        const evidenceGroups = EVIDENCE_ORDER.map((key) => {
            const items = ev.items.filter((e) => e.signal === key);
            return {
                key: `${c.id}-g-${key}`,
                label: SIGNAL_LABELS[key],
                summary: insightText[key],
                items,
                hasItems: items.length > 0,
                countLabel: items.length === 1 ? '1 passage' : `${items.length} passages`
            };
        });
        const sourceCount = new Set(ev.items.map((e) => e.source)).size;
        const evidenceLabel = ev.items.length === 0 ? 'No evidence on file'
            : `${ev.items.length} evidence point${ev.items.length === 1 ? '' : 's'} from ${sourceCount} source${sourceCount === 1 ? '' : 's'}`;

        const relevance = c.relevance == null ? null : Math.round(c.relevance);
        const scoreTier = relevance == null ? 'none' : relevance >= 85 ? 'strong' : relevance >= 70 ? 'mid' : 'low';
        const added = this.addedIds.has(c.id);

        return {
            ...c,
            initials: initialsOf(c.name),
            statusClass: `status status-${(c.status || '').toLowerCase().replace(/[^a-z]/g, '') || 'unknown'}`,
            scoreLabel: relevance == null ? '-' : `${relevance}%`,
            scoreClass: `score score-${scoreTier}`,
            signals,
            badges: badges.map((b) => ({ ...b, id: `${c.id}-b-${b.key}`, badgeClass: `badge badge-${b.key}` })),
            hasBadges: badges.length > 0,
            reasonPills: c.reasons.slice(0, 3).map((text, i) => ({ id: `${c.id}-r${i}`, text })),
            hasReasons: c.reasons.length > 0,
            insights: insights.map((i) => ({ ...i, id: `${c.id}-i-${i.key}` })),
            evidenceGroups,
            evidenceLabel,
            evidenceDerived: ev.derived,
            evidenceNote: ev.derived
                ? (this.isLive ? 'Built from Bullhorn record data. Retrieved passages appear here once the match returns them.' : 'Illustrative passages for the demo.')
                : 'Passages retrieved for this match, each tagged with its source.',
            hasSummary: !!(c.summary && c.summary.trim()),
            visibleSkills: visibleSkills.map((label, i) => ({ id: `${c.id}-s${i}`, label })),
            hasSkills: c.skills.length > 0,
            skillsOverflow,
            skillsToggleLabel: c.showAllSkills ? 'Show fewer' : `Show all ${c.skills.length}`,
            chevronIcon: c.expanded ? 'utility:chevronup' : 'utility:chevrondown',
            starIcon: c.favorited ? '\u2605' : '\u2606',
            starClass: c.favorited ? 'icon-btn star-btn favorited' : 'icon-btn star-btn',
            addLabel: added ? 'Added' : 'Add to Call List',
            addDisabled: added
        };
    }

    _signal(key, label, pct, valueLabel) {
        return {
            key,
            label,
            valueLabel,
            barStyle: `width: ${pct}%`,
            cellClass: `sig sig-${tierOf(pct)}`
        };
    }

    // ─────────────────────────────────────────────────────────────
    // Row interactions
    // ─────────────────────────────────────────────────────────────

    _patch(id, patchFn) {
        this.masterList = this.masterList.map((c) => (c.id === id ? patchFn(c) : c));
    }

    toggleExpand(event) {
        event.stopPropagation();
        this._patch(event.currentTarget.dataset.id, (c) => ({ ...c, expanded: !c.expanded }));
    }

    toggleFavorite(event) {
        event.stopPropagation();
        this._patch(event.currentTarget.dataset.id, (c) => ({ ...c, favorited: !c.favorited }));
    }

    toggleSkills(event) {
        event.stopPropagation();
        this._patch(event.currentTarget.dataset.id, (c) => ({ ...c, showAllSkills: !c.showAllSkills }));
    }

    handleAction(event) {
        event.stopPropagation();
        const { action, id } = event.currentTarget.dataset;
        const cand = this.masterList.find((c) => c.id === id);
        if (!cand) return;

        if (action === 'addToCallList') {
            this.addCandidateToCallList(cand);
        } else if (action === 'openCandidate') {
            this.openCandidate(cand);
        }
    }

    openCandidate(cand) {
        if (!cand.contactId) {
            this._toast('No linked Contact', `${cand.name} is demo data without a real Contact record.`, 'warning');
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: cand.contactId, objectApiName: 'Contact', actionName: 'view' }
        });
    }

    // Real DML: add the candidate to this Talent Pool via the junction object
    async addCandidateToCallList(cand) {
        if (!this.recordId) {
            this._toast('Missing Call List', 'No Call List record Id is available on this component.', 'error');
            return;
        }
        if (!cand.contactId) {
            this._toast(
                'No linked Contact',
                `${cand.name} is demo data without a real Contact record behind it, so there is nothing to link.`,
                'warning'
            );
            return;
        }
        if (this.addedIds.has(cand.id)) {
            this._toast('Already added', `${cand.name} is already on this call list.`, 'info');
            return;
        }

        try {
            await createRecord({
                apiName: 'TR1__Call_List_Member__c',
                fields: {
                    TR1__Call_List__c: this.recordId,
                    TR1__Contact__c: cand.contactId
                }
            });
            this.addedIds = new Set(this.addedIds).add(cand.id);
            this._toast('Added to call list', `${cand.name} has been added.`, 'success');
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('[callListMatchViewer] createRecord failed for TR1__Call_List_Member__c:', err);
            this._toast('Could not add candidate', this._errorText(err), 'error');
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Loading helpers
    // ─────────────────────────────────────────────────────────────

    _beginLoading(messages) {
        this.isMatching = true;
        let i = 0;
        this.loadingMessage = messages[0];
        clearInterval(this._loadingTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._loadingTimer = setInterval(() => {
            i = (i + 1) % messages.length;
            this.loadingMessage = messages[i];
        }, LOADING_TICK_MS);
    }

    _endLoading() {
        clearInterval(this._loadingTimer);
        this.isMatching = false;
    }

    _wait(ms) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        return new Promise((resolve) => setTimeout(resolve, ms));
    }

    _errorText(err) {
        if (Array.isArray(err?.body)) return err.body.map((e) => e.message).join(', ');
        return err?.body?.message || err?.message || 'Something went wrong.';
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}