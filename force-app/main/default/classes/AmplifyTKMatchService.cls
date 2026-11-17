/**
 * ═══════════════════════════════════════════════════════════════
 * AmplifyTkMatchService — WIRED
 *
 * Reuses TKWebServiceController's public plumbing directly:
 *   - makeSOAPRequest()  for the callout
 *   - parseResponse()    for the SOAP XML parsing
 * Same Named Credential (TK_Agent_Search_Endpoint) and custom
 * setting (TK_SOAP_API_Credentials__c) as the Agentforce flow.
 *
 * Initial match for a job has two paths:
 *   1. Indexed job (default): TK's searchWithUrl takes the already
 *      indexed vacancy (doc:// URL) and builds the query itself, so
 *      the job needs no title or city on the Salesforce record.
 *   2. Query search (fallback): builds title / city / keyword query
 *      parts from the job record and sends a plain search. Used when
 *      the job is not indexed yet or the indexed search fails.
 *
 * Query context is structured parts (title, city, radius, keywords,
 * preferences, maxResults) serialized to JSON and round-tripped by the LWC, so
 * refinements are cumulative. Refinements always use the query path.
 *
 * Refinement is deterministic-first (radius / city / keywords /
 * result count parsed directly from the instruction — instant and
 * demo-safe), with an Einstein LLM freeform fallback for anything
 * the parser doesn't recognise.
 * ═══════════════════════════════════════════════════════════════
 */
public with sharing class AmplifyTKMatchService {

    /**
     * Name of the vacancy index. Leave null to derive it from the CV index name
     * in TK_SOAP_API_Credentials__c.Environment__c (…_cv becomes …_vac).
     */
    private static final String VACANCY_ENV_OVERRIDE = null;

    public class TkMatchOutcome {
        public List<TkCandidate> candidates = new List<TkCandidate>();
        public String queryContextJson;
        public String tkQuery;             // what was sent to TK (query string, or the indexed job URL)
        public String requestXml;          // the SOAP request(s) sent, credentials masked, for the debug viewer
    }

    /** Requests sent during the current match, masked. Reset at the start of each match. */
    private static List<String> sentRequests = new List<String>();


    public class TkCandidate {
        public Id contactId;
        public String name;
        public String title;
        public String location;
        public Decimal score;              // 0–100
        public List<String> reasons = new List<String>();
        public String summary;             // TR1__Candidate_Summary__c
        public List<String> skills = new List<String>();
    }

    /** Structured query parts — the round-tripped context. */
    public class TkQueryParts {
        public String jobTitle;
        public String city;
        public Integer radiusMiles;
        public List<String> keywords = new List<String>();
        public Integer maxResults;
        /** Soft preferences. They raise the score of candidates who have them and never filter anyone out. */
        public List<TkPreference> preferences = new List<TkPreference>();
    }

    /**
     * One soft preference, sent to TextKernel as its own FAVORED (or STRONGLY_FAVORED) query part.
     * One part per preference means every preference a candidate satisfies adds to the score.
     */
    public class TkPreference {
        public String term;       // single word, or a phrase such as reach truck
        public Boolean strong;    // true = STRONGLY_FAVORED, otherwise FAVORED
        public String label;      // for display only, e.g. Skill, Certification, Related title
    }

    // ─── Seam 1: initial match for a job (WIRED) ─────────────────

    public static TkMatchOutcome matchForJob(Id jobId, Integer maxResults) {
        TR1__Job__c job = [
            SELECT Id, TR1__Job_Title__c, TR1__City__c,
                   TR1__Account__r.BillingCity
            FROM TR1__Job__c
            WHERE Id = :jobId
            LIMIT 1
        ];

        Integer cap = maxResults == null ? 5 : maxResults;

        // Query parts are best effort now: title and city may be blank on the job record
        TkQueryParts parts = new TkQueryParts();
        parts.jobTitle    = job.TR1__Job_Title__c;
        parts.maxResults  = cap;
        parts.radiusMiles = 10;   // matches the existing Agentforce flow's default

        if (String.isNotBlank(job.TR1__City__c)) {
            parts.city = job.TR1__City__c;
        } else if (job.TR1__Account__r != null && String.isNotBlank(job.TR1__Account__r.BillingCity)) {
            parts.city = job.TR1__Account__r.BillingCity;
        }

        sentRequests = new List<String>();

        // Path 1: the indexed job, one call, no query building
        String docUrl = indexedJobUrl(jobId);
        if (docUrl != null) {
            try {
                List<TKWebServiceController.ResultItem> indexed = searchByIndexedJob(docUrl, cap);
                if (!indexed.isEmpty()) {
                    TkMatchOutcome outcome = new TkMatchOutcome();
                    outcome.queryContextJson = JSON.serialize(parts);
                    outcome.tkQuery = 'Indexed job search: ' + docUrl;
                    outcome.requestXml = String.join(sentRequests, '\n\n');
                    outcome.candidates = decorate(indexed, parts);
                    if (!outcome.candidates.isEmpty()) return outcome;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Indexed job search failed, using query search: ' + e.getMessage());
            }
        }

        // Path 2: query search from the job record
        if (String.isBlank(parts.jobTitle)) {
            throw new CalloutException(
                'This job is not available in the TextKernel index yet and has no job title to search on. '
                + 'Add a job title, or try again once the job has been indexed.'
            );
        }

        return matchForPartsInner(parts);
    }

    // ─── Seam 1b: query search from structured parts ─────────────

    public static TkMatchOutcome matchForParts(TkQueryParts parts) {
        sentRequests = new List<String>();
        return matchForPartsInner(parts);
    }

    private static TkMatchOutcome matchForPartsInner(TkQueryParts parts) {
        TkQueryParts partsUsed = parts;
        List<TKWebServiceController.ResultItem> items = search(parts, 'Search');

        // Same fallback behaviour as the existing class: retry title-only
        if (items.isEmpty() && String.isNotBlank(parts.city)) {
            TkQueryParts titleOnly = clone(parts);
            titleOnly.city = null;
            items = search(titleOnly, 'Retry without city (first search found nobody)');
            if (!items.isEmpty()) partsUsed = titleOnly;
        }

        TkMatchOutcome outcome = new TkMatchOutcome();
        outcome.queryContextJson = JSON.serialize(partsUsed);
        outcome.tkQuery = describeQuery(partsUsed);
        outcome.requestXml = String.join(sentRequests, '\n\n');
        outcome.candidates = decorate(items, partsUsed);
        return outcome;
    }

    // ─── Seam 2: NL refinement (WIRED, deterministic-first) ──────

    public static TkMatchOutcome refine(Id jobId, String instruction, String queryContextJson) {
        TkQueryParts parts;
        if (String.isNotBlank(queryContextJson)) {
            parts = (TkQueryParts) JSON.deserialize(queryContextJson, TkQueryParts.class);
        } else {
            // No context (e.g. component reloaded on an enabled job) — rebuild from the job
            TkMatchOutcome fresh = matchForJob(jobId, 5);
            parts = (TkQueryParts) JSON.deserialize(fresh.queryContextJson, TkQueryParts.class);
        }

        Boolean handled = applyDeterministic(parts, instruction);
        if (!handled) {
            parts = refineViaLlm(parts, instruction);
        }

        // An indexed-job match can start with no title, so refinement needs something to search on
        if (String.isBlank(parts.jobTitle) && (parts.keywords == null || parts.keywords.isEmpty())) {
            throw new CalloutException(
                'There is no job title to build a search from. Add a keyword to search on, for example "add forklift".'
            );
        }

        sentRequests = new List<String>();
        List<TKWebServiceController.ResultItem> items = search(parts, 'Refined search: ' + instruction);

        TkMatchOutcome outcome = new TkMatchOutcome();
        outcome.queryContextJson = JSON.serialize(parts);
        outcome.tkQuery = describeQuery(parts);
        outcome.requestXml = String.join(sentRequests, '\n\n');
        outcome.candidates = decorate(items, parts);
        return outcome;
    }

    /**
     * Handles the phrases that will actually get used on stage,
     * instantly and without an LLM round trip:
     *   "extend the radius by 30 miles" / "increase radius to 50"
     *   "search in Chandler" / "change the city to Mesa"
     *   "add hydraulics" / "include PLC experience"
     *   "show me 10" / "give me 5 more"
     */
    @TestVisible
    private static Boolean applyDeterministic(TkQueryParts parts, String instruction) {
        String lower = instruction.toLowerCase();
        Boolean handled = false;

        // Radius: "by N miles" extends, "to N miles" sets
        Matcher m = Pattern.compile('radius\\s+(?:by|to)?\\s*(\\d+)').matcher(lower);
        if (m.find()) {
            Integer n = Integer.valueOf(m.group(1));
            Integer current = parts.radiusMiles == null ? 10 : parts.radiusMiles;
            parts.radiusMiles = lower.contains(' by ') ? current + n : n;
            handled = true;
        }

        // City: "search in X" / "city to X"
        m = Pattern.compile('(?:search in|city to|change (?:the )?city to|look in)\\s+([a-z\\s]+?)(?:$|,|\\.)').matcher(lower);
        if (m.find()) {
            parts.city = m.group(1).trim().capitalize();
            handled = true;
        }

        // Result count: "show me N" / "N more"
        m = Pattern.compile('(?:show me|give me|return|top)\\s+(\\d+)').matcher(lower);
        if (m.find()) {
            Integer n = Integer.valueOf(m.group(1));
            parts.maxResults = lower.contains(' more')
                ? (parts.maxResults == null ? 5 : parts.maxResults) + n
                : n;
            handled = true;
        }

        // Keywords: "add X" / "include X" / "must have X"
        m = Pattern.compile('(?:add|include|must have|with)\\s+([a-z0-9\\s\\+\\-]+?)(?:\\s+experience)?(?:$|,|\\.)').matcher(lower);
        if (m.find() && !handled) {   // only if nothing else matched, to avoid grabbing "add 10 miles"
            String kw = m.group(1).trim();
            if (String.isNotBlank(kw) && !parts.keywords.contains(kw)) {
                parts.keywords.add(kw);
                handled = true;
            }
        }

        return handled;
    }

    /**
     * LLM fallback: freeform Einstein prompt that returns edited parts
     * as JSON. Same ConnectApi pattern as enrichJobRecord, but without
     * a saved template.
     */
    private static TkQueryParts refineViaLlm(TkQueryParts parts, String instruction) {
        // Keep the prompt small: the preference list is carried through untouched, not edited by the model.
        TkQueryParts slim = clone(parts);
        slim.preferences = new List<TkPreference>();

        String prompt =
            'You convert recruiter instructions into edits to a candidate search query.\n' +
            'Current query parts JSON: ' + JSON.serialize(slim) + '\n' +
            'Instruction: "' + instruction.replace('"', '\\"') + '"\n' +
            'Respond ONLY with the full updated query parts JSON, same schema, no markdown, no commentary.';

        ConnectApi.EinsteinLlmGenerationsInput genInput = new ConnectApi.EinsteinLlmGenerationsInput();
        genInput.promptTextorId = prompt;
        genInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        genInput.additionalConfig.maxTokens = 300;

        try {
            ConnectApi.EinsteinLLMGenerationItemOutput out =
                ConnectApi.EinsteinLLM.generateMessages(genInput).generations[0];
            String raw = out.text.trim();
            // strip accidental fences
            raw = raw.removeStart('```json').removeStart('```').removeEnd('```').trim();
            TkQueryParts edited = (TkQueryParts) JSON.deserialize(raw, TkQueryParts.class);
            edited.preferences = parts.preferences;
            return edited;
        } catch (Exception e) {
            throw new CalloutException('Could not interpret that refinement. Try e.g. "extend the radius by 30 miles".');
        }
    }

    // ─── Search execution (reuses TKWebServiceController plumbing) ─

    private static List<TKWebServiceController.ResultItem> search(TkQueryParts parts, String label) {
        String endpointUrl = 'callout:TK_Agent_Search_Endpoint';
        TK_SOAP_API_Credentials__c credentials = TK_SOAP_API_Credentials__c.getInstance();

        String query = buildQuery(parts);

        String requestBody =
            '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:sear="http://home.textkernel.nl/search">' +
            '<soapenv:Header/>' +
            '<soapenv:Body>' +
            '   <sear:search>' +
            '       <environment>' + credentials.Environment__c + '</environment>' +
            '       <password>' + credentials.Password__c + '</password>' +
            '       <accessRoles>all</accessRoles>' +
            '       <request>' +
            '           <query>' + query.escapeXml() + '</query>' +
            preferencesXml(parts) +
            '       </request>' +
            '   </sear:search>' +
            '</soapenv:Body>' +
            '</soapenv:Envelope>';

        recordRequest(label, requestBody);
        String response = TKWebServiceController.makeSOAPRequest(endpointUrl, requestBody);
        return TKWebServiceController.parseResponse(response);
    }

    /**
     * searchWithUrl: TK takes the indexed vacancy and produces the candidate query itself.
     * Same endpoint, environment and password as the plain search.
     */
    private static List<TKWebServiceController.ResultItem> searchByIndexedJob(String docUrl, Integer maxResults) {
        String endpointUrl = 'callout:TK_Agent_Search_Endpoint';
        TK_SOAP_API_Credentials__c credentials = TK_SOAP_API_Credentials__c.getInstance();

        // Ask for more than needed: results without a matching Contact are dropped in decorate()
        Integer pageSize = Math.min(50, Math.max(20, (maxResults == null ? 5 : maxResults) * 2));

        String requestBody =
            '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:sear="http://home.textkernel.nl/search">' +
            '<soapenv:Header/>' +
            '<soapenv:Body>' +
            '   <sear:searchWithUrl>' +
            '       <environment>' + String.valueOf(credentials.Environment__c).escapeXml() + '</environment>' +
            '       <password>' + String.valueOf(credentials.Password__c).escapeXml() + '</password>' +
            '       <accessRoles>all</accessRoles>' +
            '       <url>' + docUrl.escapeXml() + '</url>' +
            '       <pageSize>' + pageSize + '</pageSize>' +
            '   </sear:searchWithUrl>' +
            '</soapenv:Body>' +
            '</soapenv:Envelope>';

        recordRequest('Indexed job search (searchWithUrl)', requestBody);
        String response = TKWebServiceController.makeSOAPRequest(endpointUrl, requestBody);
        return TKWebServiceController.parseResponse(response);
    }

    /**
     * Keeps a copy of what is about to be sent, for the debug viewer in the LWC.
     * The index name carries the customer's name and the password is a secret,
     * so both are masked before the copy leaves Apex.
     */
    private static void recordRequest(String label, String body) {
        String masked = body
            .replaceAll('<environment>[^<]*</environment>', '<environment>(hidden)</environment>')
            .replaceAll('<password>[^<]*</password>', '<password>(hidden)</password>')
            .replaceAll('<url>doc://[^/<]*/', '<url>doc://(index)/');
        sentRequests.add('<!-- ' + label.replace('--', '- -') + ' -->\n' + masked);
    }

    /**
     * doc://<vacancy index>/vacancies/<18 char org Id>_<18 char job Id>
     * Returns null when the vacancy index name cannot be worked out, so the caller uses the query path.
     */
    @TestVisible
    private static String indexedJobUrl(Id jobId) {
        if (jobId == null) return null;

        String vacancyEnv = VACANCY_ENV_OVERRIDE;
        if (String.isBlank(vacancyEnv)) {
            TK_SOAP_API_Credentials__c credentials = TK_SOAP_API_Credentials__c.getInstance();
            String cvEnv = credentials == null ? null : credentials.Environment__c;
            vacancyEnv = vacancyEnvironmentFor(cvEnv);
        }
        if (String.isBlank(vacancyEnv)) return null;

        return 'doc://' + vacancyEnv + '/vacancies/' + UserInfo.getOrganizationId() + '_' + String.valueOf(jobId);
    }

    /** bhsf_talentrover_morganhunt_cv becomes bhsf_talentrover_morganhunt_vac. */
    @TestVisible
    private static String vacancyEnvironmentFor(String cvEnvironment) {
        if (String.isBlank(cvEnvironment) || !cvEnvironment.endsWith('_cv')) return null;
        return cvEnvironment.removeEnd('_cv') + '_vac';
    }

    /**
     * Structured query parts for the soft preferences, plus the synonym mode that expands them.
     * The query string is interpreted by Search (spelling, location, synonyms) but structured parts are not,
     * so QUERY_AND_QUERYPARTS is what lets a preference such as forklift pick up its synonyms.
     * Returns an empty string when there are no preferences, which leaves the request exactly as before.
     * Element order follows the SearchRequest field order: query, queryParts, then synonymExpansionMode.
     */
    @TestVisible
    private static String preferencesXml(TkQueryParts parts) {
        if (parts == null || parts.preferences == null || parts.preferences.isEmpty()) return '';

        String xml = '';
        for (TkPreference p : parts.preferences) {
            if (p == null || String.isBlank(p.term)) continue;
            xml += '<queryParts>'
                + '<field>FULLTEXT</field>'
                + '<condition>' + (p.strong == true ? 'STRONGLY_FAVORED' : 'FAVORED') + '</condition>'
                + '<weight>1.0</weight>'
                + '<items><value>' + quoteTerm(p.term).escapeXml() + '</value></items>'
                + '</queryParts>';
        }
        if (xml == '') return '';
        return xml + '<synonymExpansionMode>QUERY_AND_QUERYPARTS</synonymExpansionMode>';
    }

    /** Multi word terms are sent as phrases so they match as a sequence, not as loose words. */
    @TestVisible
    private static String quoteTerm(String term) {
        String t = term.replace('"', '').trim();
        return t.contains(' ') ? '"' + t + '"' : t;
    }

    /** What the UI shows: the literal query string, then the soft preferences that sit alongside it. */
    @TestVisible
    private static String describeQuery(TkQueryParts parts) {
        String q = buildQuery(parts);
        if (parts.preferences == null || parts.preferences.isEmpty()) return q;

        List<String> strong = new List<String>();
        List<String> soft = new List<String>();
        for (TkPreference p : parts.preferences) {
            if (p == null || String.isBlank(p.term)) continue;
            if (p.strong == true) strong.add(p.term); else soft.add(p.term);
        }
        if (!strong.isEmpty()) q += '  |  strongly favoured: ' + String.join(strong, ', ');
        if (!soft.isEmpty())   q += '  |  favoured: ' + String.join(soft, ', ');
        return q;
    }

    @TestVisible
    private static String buildQuery(TkQueryParts parts) {
        List<String> tokens = new List<String>();
        if (String.isNotBlank(parts.jobTitle)) tokens.add(parts.jobTitle);
        if (parts.keywords != null && !parts.keywords.isEmpty()) {
            tokens.addAll(parts.keywords);
        }

        String q = String.join(tokens, ' ');
        if (String.isNotBlank(parts.city)) {
            Integer r = parts.radiusMiles == null ? 10 : parts.radiusMiles;
            q = (q + ' city:' + parts.city + '+' + r).trim();
        }
        return q;
    }

    // ─── Decoration: results → display candidates with reasons ───

    /**
     * TK Search returns score + record id only (no facet breakdown in
     * the parsed response), so reasons are derived from real record
     * data compared against what was searched — honest and specific,
     * which is what survives interrogation.
     */
    private static List<TkCandidate> decorate(List<TKWebServiceController.ResultItem> items, TkQueryParts parts) {
        List<TkCandidate> out = new List<TkCandidate>();
        if (items == null || items.isEmpty()) return out;

        Integer cap = parts.maxResults == null ? 5 : parts.maxResults;

        List<String> recordIds = new List<String>();
        for (TKWebServiceController.ResultItem item : items) {
            if (item.salesforceRecordId != null) recordIds.add(item.salesforceRecordId);
        }

        Map<Id, Contact> contactMap = new Map<Id, Contact>([
            SELECT Id, Name, Title, MailingCity, MailingState, TR1__Candidate_Status__c,
                   TR1__Candidate_Summary__c
            FROM Contact
            WHERE Id IN :recordIds
        ]);

        Map<Id, List<String>> skillsByContact = querySkills(contactMap.keySet());

        for (TKWebServiceController.ResultItem item : items) {
            if (out.size() >= cap) break;
            if (item.salesforceRecordId == null) continue;

            Contact c = contactMap.get(item.salesforceRecordId);
            if (c == null) continue;

            TkCandidate cand = new TkCandidate();
            cand.contactId = c.Id;
            cand.name = c.Name;
            cand.title = String.isNotBlank(c.Title) ? c.Title : 'Candidate';
            cand.location = joinLocation(c.MailingCity, c.MailingState);
            cand.score = normaliseScore(item.score);
            cand.reasons = buildReasons(c, parts);
            cand.summary = c.TR1__Candidate_Summary__c;
            cand.skills = skillsByContact.containsKey(c.Id)
                ? skillsByContact.get(c.Id)
                : new List<String>();
            out.add(cand);
        }
        return out;
    }

    private static Decimal normaliseScore(Decimal raw) {
        if (raw == null) return null;
        // Search scores come back as a ratio. Treat anything up to 2 as a ratio, and never show more than 100.
        Decimal pct = raw <= 2 ? raw * 100 : raw;
        return (pct > 100 ? 100 : pct).setScale(0);
    }

    @TestVisible
    private static List<String> buildReasons(Contact c, TkQueryParts parts) {
        List<String> reasons = new List<String>();

        if (String.isNotBlank(c.Title) && String.isNotBlank(parts.jobTitle)) {
            if (c.Title.equalsIgnoreCase(parts.jobTitle)) {
                reasons.add('Current title: ' + c.Title + ' (exact match)');
            } else {
                reasons.add('Current title: ' + c.Title);
            }
        } else if (String.isNotBlank(c.Title)) {
            reasons.add('Current title: ' + c.Title);
        }

        if (String.isNotBlank(parts.city) && String.isNotBlank(c.MailingCity)) {
            Integer r = parts.radiusMiles == null ? 10 : parts.radiusMiles;
            if (c.MailingCity.equalsIgnoreCase(parts.city)) {
                reasons.add('Based in ' + c.MailingCity);
            } else {
                reasons.add(c.MailingCity + ', within ' + r + ' mi search radius');
            }
        }

        if (parts.keywords != null && !parts.keywords.isEmpty()) {
            reasons.add('Profile matched: ' + String.join(parts.keywords, ', '));
        }

        if (String.isNotBlank(c.TR1__Candidate_Status__c)) {
            reasons.add('Status: ' + c.TR1__Candidate_Status__c);
        }

        return reasons;
    }

    /** Related skills per contact, using the master skill display name. */
    private static Map<Id, List<String>> querySkills(Set<Id> contactIds) {
        Map<Id, List<String>> skillsByContact = new Map<Id, List<String>>();
        if (contactIds.isEmpty()) return skillsByContact;

        for (TR1__Skills__c s : [
            SELECT TR1__Master_Skill_Name__c, TR1__Contact__c
            FROM TR1__Skills__c
            WHERE TR1__Contact__c IN :contactIds
            AND TR1__Master_Skill_Name__c != null
            ORDER BY TR1__Master_Skill_Name__c
            LIMIT 500
        ]) {
            if (!skillsByContact.containsKey(s.TR1__Contact__c)) {
                skillsByContact.put(s.TR1__Contact__c, new List<String>());
            }
            skillsByContact.get(s.TR1__Contact__c).add(s.TR1__Master_Skill_Name__c);
        }
        return skillsByContact;
    }

    private static TkQueryParts clone(TkQueryParts src) {
        return (TkQueryParts) JSON.deserialize(JSON.serialize(src), TkQueryParts.class);
    }

    private static String joinLocation(String city, String st) {
        if (String.isNotBlank(city) && String.isNotBlank(st)) return city + ', ' + st;
        if (String.isNotBlank(city)) return city;
        if (String.isNotBlank(st)) return st;
        return '-';
    }

    // ─── Demo fallback (unchanged) ───────────────────────────────

    public static List<TkCandidate> fallbackCandidates(List<Id> contactIds) {
        List<TkCandidate> out = new List<TkCandidate>();
        Decimal score = 94;

        Map<Id, List<String>> skillsByContact = querySkills(new Set<Id>(contactIds));

        for (Contact c : [
            SELECT Id, Name, Title, MailingCity, MailingState, TR1__Candidate_Summary__c
            FROM Contact
            WHERE Id IN :contactIds
        ]) {
            TkCandidate cand = new TkCandidate();
            cand.contactId = c.Id;
            cand.name = c.Name;
            cand.title = String.isNotBlank(c.Title) ? c.Title : 'Candidate';
            cand.location = joinLocation(c.MailingCity, c.MailingState);
            cand.score = score;
            cand.reasons = new List<String>{ 'Shortlisted candidate' };
            cand.summary = c.TR1__Candidate_Summary__c;
            cand.skills = skillsByContact.containsKey(c.Id)
                ? skillsByContact.get(c.Id)
                : new List<String>();
            out.add(cand);
            score -= 3;
        }
        return out;
    }
}