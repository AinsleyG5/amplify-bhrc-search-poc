/**
 * Evidence layer for callListMatchViewer.
 *
 * The point of "evidence-based" matching: every score the recruiter sees can be traced
 * back to the passages and records it was grounded in. Each evidence item says WHERE it
 * came from (source) and WHICH factor it supports (signal).
 *
 * Contract for the Apex response (AmplifyTalentPoolMatchController). Per candidate, add:
 *
 *   evidence: [
 *     { source: 'note' | 'transcript' | 'submission' | 'cv' | 'email' | 'placement' | 'vms' | 'engagement' | 'profile',
 *       signal: 'relevance' | 'silver' | 'engagement' | 'redeploy' | 'vms',
 *       text:   'the retrieved passage or record text',
 *       ref:    'optional record id or short reference',
 *       date:   'optional ISO date or display string' }
 *   ]
 *
 * When the live response has no evidence yet, the component derives it from the structured
 * fields it already receives and labels it "Record data", so the UI never overstates what
 * was retrieved.
 */

export const SIGNAL_LABELS = {
    relevance: 'Role relevance',
    silver: 'Silver medalist',
    engagement: 'Engagement',
    redeploy: 'Redeployment',
    vms: 'VMS readiness'
};

export const SOURCE_LABELS = {
    note: 'Recruiter note',
    transcript: 'Call transcript',
    submission: 'Submission feedback',
    cv: 'CV match',
    email: 'Email history',
    placement: 'Placement record',
    vms: 'VMS record',
    engagement: 'Engagement score',
    profile: 'Candidate summary'
};

const MAX_TEXT = 220;

function clip(text) {
    const t = (text || '').trim();
    return t.length > MAX_TEXT ? `${t.slice(0, MAX_TEXT - 1).trimEnd()}\u2026` : t;
}

function toItem(candidateId, i, raw) {
    const source = SOURCE_LABELS[raw.source] ? raw.source : 'profile';
    const signal = SIGNAL_LABELS[raw.signal] ? raw.signal : 'relevance';
    return {
        id: `${candidateId}-e${i}`,
        source,
        signal,
        sourceLabel: SOURCE_LABELS[source],
        signalLabel: SIGNAL_LABELS[signal],
        text: clip(raw.text),
        ref: raw.ref || null,
        date: raw.date || null,
        hasMeta: !!(raw.ref || raw.date),
        meta: [raw.ref, raw.date].filter(Boolean).join('  \u00b7  '),
        sourceClass: `ev-source ev-source-${source}`,
        signalClass: `ev-signal ev-signal-${signal}`
    };
}

/**
 * Returns { items, derived }.
 *  - Apex evidence present: used as is, derived = false
 *  - Otherwise built from the structured fields, derived = true
 *  - demo = true adds illustrative notes and transcripts (only ever used with demo data)
 */
export function buildEvidence(c, apexEvidence, demo) {
    if (Array.isArray(apexEvidence) && apexEvidence.length > 0) {
        return { items: apexEvidence.map((e, i) => toItem(c.id, i, e)), derived: false };
    }

    const raw = [];
    (c.reasons || []).slice(0, 2).forEach((r) => raw.push({ source: 'cv', signal: 'relevance', text: r }));
    if (c.summary && c.summary.trim()) raw.push({ source: 'profile', signal: 'relevance', text: c.summary });

    if (c.silver && c.silver.count > 0) {
        raw.push({ source: 'submission', signal: 'silver', text: c.silver.detail || `Shortlisted ${c.silver.count} time(s) before.` });
    }
    if (c.redeploy && c.redeploy.count > 0) {
        raw.push({ source: 'placement', signal: 'redeploy', text: c.redeploy.detail || 'Placed with this account before.' });
    }
    if (c.engagement != null) {
        raw.push({ source: 'engagement', signal: 'engagement', text: `Bullhorn Engagement Score ${Math.round(c.engagement)} of 100.` });
    }
    if (c.vms != null) {
        raw.push({ source: 'vms', signal: 'vms', text: `${Math.round(c.vms)}% of the required VMS submission data is on file.` });
    }

    if (demo) {
        if (c.engagement != null && c.engagement >= 70) {
            raw.push({ source: 'transcript', signal: 'engagement', text: 'Confirmed on the call that they are open to new roles and can start at short notice.', ref: 'Demo', date: 'Last 30 days' });
        } else if (c.engagement != null && c.engagement >= 50) {
            raw.push({ source: 'email', signal: 'engagement', text: 'Replied to the last outreach and asked for more detail on the shift pattern.', ref: 'Demo', date: 'Last 60 days' });
        }
        if (c.silver && c.silver.count > 0) {
            raw.push({ source: 'note', signal: 'silver', text: 'Client liked the interview but the role went to an internal hire. Keep warm for similar roles.', ref: 'Demo', date: 'Previous search' });
        }
    }

    return { items: raw.map((e, i) => toItem(c.id, i, e)), derived: true };
}

/** The four steps shown in the retrieval trace strip. */
export function buildTrace({ hasTkQuery, candidateCount, evidenceCount, anyDerived, demo }) {
    return [
        { key: 'filter', n: '1', title: 'Filter', value: hasTkQuery ? 'Query built' : 'Pool criteria', hint: 'Title, location and hard requirements narrow the pool' },
        { key: 'retrieve', n: '2', title: 'Retrieve', value: `${candidateCount}`, hint: 'Candidates matched on meaning, not just keywords' },
        { key: 'rank', n: '3', title: 'Re-rank', value: 'Your weighting', hint: 'Silver medalist, engagement, redeployment, VMS readiness' },
        {
            key: 'ground', n: '4', title: 'Ground', value: `${evidenceCount}`,
            hint: demo ? 'Illustrative evidence passages (demo data)'
                : anyDerived ? 'Evidence drawn from Bullhorn record data'
                    : 'Retrieved passages cited against every score'
        }
    ].map((s) => ({ ...s, tileClass: s.key === 'ground' ? 'trace-tile trace-tile-ground' : 'trace-tile' }));
}