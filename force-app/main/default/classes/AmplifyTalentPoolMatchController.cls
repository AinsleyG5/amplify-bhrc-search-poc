/**
 * AmplifyTalentPoolMatchController
 *
 * Backs the callListMatchViewer LWC on the Talent Pool (TR1__Call_List__c).
 * Reuses AmplifyTkMatchService for the TextKernel search and refinement, then
 * layers the four recruiter-facing signals on top of each candidate:
 *
 *   Silver medalist  prior applications that reached a shortlist-type stage
 *   Engagement       Bullhorn Engagement Score (0 to 100) from the Contact
 *   Redeployment     placed with this Account before on a similar role
 *   VMS readiness    share of required VMS data already on file
 *                    (AmplifyVmsFormService.getCandidateVmsReadiness)
 *
 * Every signal lookup fails soft: if an object, field or stage does not exist in
 * the org the signal comes back empty and the match still works. Check the
 * tuning constants below against your org.
 *
 * The search is shaped by a small brief held on the Talent Pool (see the POOL_ constants below):
 * the title and city gate the search, and skills, related titles and certifications are sent as
 * favoured terms that lift the score of candidates who have them without removing anyone.
 *
 * Search weightings are NOT applied server side yet. The LWC simulates the
 * re-run, so this class takes no weights.
 */
public with sharing class AmplifyTalentPoolMatchController {

    // ═════════════════════════════════════════════════════════════
    // Tuning constants: verify these against your org
    // ═════════════════════════════════════════════════════════════

    /** TR1__Application_V2__c.TR1__Stage__c values that count as "was shortlisted". */
    private static final Set<String> SILVER_STAGES = new Set<String>{
        'Interview', 'Client Submittal', 'Submittal', 'Shortlisted', 'Offer'
    };

    /** First Contact field found from this list is used as the Engagement Score. */
    private static final List<String> ENGAGEMENT_FIELDS = new List<String>{
        'bullhorn__Engagement_Score__c', 'Engagement_Score__c', 'TR1__Engagement_Score__c'
    };

    /** Placement (closing report) object and its fields, queried dynamically so a wrong name cannot break compile. */
    private static final String PLACEMENT_OBJECT   = 'TR1__Closing_Report__c';
    private static final String PLACEMENT_PERSON   = 'TR1__Person_Placed__c';
    private static final String PLACEMENT_JOB      = 'TR1__Job__c';

    /** Each VMS readiness check costs about 4 SOQL queries, so only the top of the list is evaluated. */
    private static final Integer VMS_EVAL_LIMIT = 15;

    private static final Integer DEFAULT_MAX = 20;

    /** Talent Pool (TR1__Call_List__c) fields that shape the search. Create them, or change the names here. */
    private static final String POOL_TITLE_FIELD          = 'Job_Role__c';
    private static final String POOL_RELATED_TITLES_FIELD = 'Related_Titles__c';
    private static final String POOL_CITY_FIELD           = 'Search_City__c';
    private static final String POOL_RADIUS_FIELD         = 'Search_Radius_Miles__c';

    /**
     * Lookup field on TR1__Skills__c that points at the Talent Pool. Skill records linked here are favoured terms.
     * Records whose type is Certification are strongly favoured, everything else is favoured.
     */
    private static final String SKILL_POOL_LOOKUP  = 'Talent_Pool__c';
    private static final String SKILL_TYPE_FIELD   = 'TR1__Type__c';
    private static final String CERTIFICATION_TYPE = 'Certification';

    /** Keeps the query a sensible size. Certifications are added first, so they survive the cap. */
    private static final Integer MAX_PREFERENCES = 12;

    // ═════════════════════════════════════════════════════════════
    // Wire types
    // ═════════════════════════════════════════════════════════════

    public class PoolCandidate {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
        @AuraEnabled public String location;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal relevance;        // TK score, 0 to 100
        @AuraEnabled public List<String> reasons;
        @AuraEnabled public String summary;
        @AuraEnabled public List<String> skills;
        @AuraEnabled public Integer silverCount;
        @AuraEnabled public String silverDetail;
        @AuraEnabled public Decimal engagementScore;  // null when not available
        @AuraEnabled public Integer redeployCount;
        @AuraEnabled public String redeployDetail;
        @AuraEnabled public Decimal vmsPercent;       // null when not assessed
    }

    public class PoolMatchResponse {
        @AuraEnabled public List<PoolCandidate> candidates;
        @AuraEnabled public String queryContextJson;
        @AuraEnabled public String tkQuery;
        @AuraEnabled public String requestXml;
        @AuraEnabled public String accountName;
    }

    // ═════════════════════════════════════════════════════════════
    // Entry points
    // ═════════════════════════════════════════════════════════════

    /**
     * runPoolMatch
     *
     * searchTitle / searchCity are optional overrides (set in App Builder).
     * Without them the search title is derived from the Talent Pool name.
     */
    @AuraEnabled
    public static PoolMatchResponse runPoolMatch(Id callListId, String searchTitle, String searchCity, Integer maxResults) {
        if (callListId == null) throw err('callListId is required.');

        TR1__Call_List__c pool = loadPool(callListId);

        // App Builder overrides win, then the pool's own brief, then whatever can be derived from the pool name.
        PoolBrief brief = loadBrief(callListId);

        AmplifyTkMatchService.TkQueryParts parts = new AmplifyTkMatchService.TkQueryParts();
        parts.jobTitle    = String.isNotBlank(searchTitle) ? searchTitle.trim()
                          : String.isNotBlank(brief.title) ? brief.title
                          : titleFromPoolName(pool.Name);
        parts.city        = String.isNotBlank(searchCity) ? searchCity.trim() : brief.city;
        parts.radiusMiles = brief.radiusMiles != null ? brief.radiusMiles : 10;
        parts.maxResults  = maxResults == null ? DEFAULT_MAX : maxResults;
        parts.preferences = brief.preferences();

        if (String.isBlank(parts.jobTitle)) {
            throw err('The Talent Pool has no name to search on. Set a search title on the component.');
        }

        try {
            return buildResponse(pool, AmplifyTkMatchService.matchForParts(parts));
        } catch (Exception e) {
            throw err('Talent pool match failed: ' + e.getTypeName() + ' - ' + e.getMessage());
        }
    }

    /** Natural-language refinement, same parser as the Job Activator. */
    @AuraEnabled
    public static PoolMatchResponse refinePoolMatch(Id callListId, String instruction, String queryContextJson) {
        if (callListId == null) throw err('callListId is required.');
        if (String.isBlank(instruction)) throw err('No refinement instruction provided.');
        if (String.isBlank(queryContextJson)) throw err('Run the match before refining it.');

        TR1__Call_List__c pool = loadPool(callListId);

        try {
            return buildResponse(pool, AmplifyTkMatchService.refine(null, instruction, queryContextJson));
        } catch (Exception e) {
            throw err('Could not refine the search: ' + e.getMessage());
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Response assembly
    // ═════════════════════════════════════════════════════════════

    private static PoolMatchResponse buildResponse(TR1__Call_List__c pool, AmplifyTkMatchService.TkMatchOutcome outcome) {
        PoolMatchResponse resp = new PoolMatchResponse();
        resp.queryContextJson = outcome.queryContextJson;
        resp.tkQuery          = outcome.tkQuery;
        resp.requestXml       = outcome.requestXml;
        resp.accountName      = pool.Account__r != null ? pool.Account__r.Name : null;

        String searchTitle = null;
        if (String.isNotBlank(outcome.queryContextJson)) {
            AmplifyTkMatchService.TkQueryParts used =
                (AmplifyTkMatchService.TkQueryParts) JSON.deserialize(outcome.queryContextJson, AmplifyTkMatchService.TkQueryParts.class);
            searchTitle = used.jobTitle;
        }

        resp.candidates = enrich(outcome.candidates, pool, searchTitle);
        return resp;
    }

    private static List<PoolCandidate> enrich(List<AmplifyTkMatchService.TkCandidate> tkCandidates, TR1__Call_List__c pool, String searchTitle) {
        List<PoolCandidate> out = new List<PoolCandidate>();
        if (tkCandidates == null || tkCandidates.isEmpty()) return out;

        Set<Id> contactIds = new Set<Id>();
        for (AmplifyTkMatchService.TkCandidate c : tkCandidates) contactIds.add(c.contactId);

        String accountName = pool.Account__r != null ? pool.Account__r.Name : null;
        String engagementField = findEngagementField();

        Map<Id, SObject> contactRows   = queryContacts(contactIds, engagementField);
        Map<Id, List<TR1__Application_V2__c>> silver = querySilver(contactIds);
        Map<Id, List<String>> redeploy = queryRedeployments(contactIds, pool.Account__c, searchTitle);

        Integer evaluated = 0;
        for (AmplifyTkMatchService.TkCandidate c : tkCandidates) {
            PoolCandidate pc = new PoolCandidate();
            pc.contactId = c.contactId;
            pc.name      = c.name;
            pc.title     = c.title;
            pc.location  = c.location;
            pc.relevance = c.score;
            pc.reasons   = c.reasons;
            pc.summary   = c.summary;
            pc.skills    = c.skills;

            SObject row = contactRows.get(c.contactId);
            if (row != null) {
                pc.status = (String) row.get('TR1__Candidate_Status__c');
                if (engagementField != null && row.get(engagementField) != null) {
                    pc.engagementScore = Decimal.valueOf(String.valueOf(row.get(engagementField)));
                }
            }

            // Silver medalist
            List<TR1__Application_V2__c> prior = silver.get(c.contactId);
            pc.silverCount = prior == null ? 0 : prior.size();
            if (pc.silverCount > 0) {
                TR1__Application_V2__c latest = prior[0];
                String jobTitle = latest.TR1__Job__r != null ? latest.TR1__Job__r.TR1__Job_Title__c : null;
                pc.silverDetail = 'Shortlisted before'
                    + (String.isNotBlank(jobTitle) ? ' for ' + jobTitle : '')
                    + ', reached ' + latest.TR1__Stage__c
                    + (pc.silverCount > 1 ? ' (' + (pc.silverCount - 1) + ' more prior shortlist' + (pc.silverCount > 2 ? 's' : '') + ')' : '');
            }

            // Redeployment
            List<String> placed = redeploy.get(c.contactId);
            pc.redeployCount = placed == null ? 0 : placed.size();
            if (pc.redeployCount > 0) {
                String first = placed[0];
                pc.redeployDetail = 'Placed with ' + (accountName == null ? 'this account' : accountName)
                    + (String.isNotBlank(first) ? ' as ' + first : '')
                    + (pc.redeployCount > 1 ? ' (' + pc.redeployCount + ' placements)' : '');
            }

            // VMS readiness, top of the list only
            if (accountName != null && evaluated < VMS_EVAL_LIMIT) {
                evaluated++;
                try {
                    AmplifyVmsFormService.CandidateVmsReadiness r =
                        AmplifyVmsFormService.getCandidateVmsReadiness(c.contactId, accountName, null);
                    if (r != null && r.resolvedTier != 'none') pc.vmsPercent = r.percent;
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'VMS readiness skipped for ' + c.contactId + ': ' + e.getMessage());
                }
            }

            out.add(pc);
        }
        return out;
    }

    // ═════════════════════════════════════════════════════════════
    // Signal lookups (each one fails soft)
    // ═════════════════════════════════════════════════════════════

    private static Map<Id, SObject> queryContacts(Set<Id> contactIds, String engagementField) {
        String soql = 'SELECT Id, TR1__Candidate_Status__c'
            + (engagementField != null ? ', ' + engagementField : '')
            + ' FROM Contact WHERE Id IN :contactIds';
        try {
            return new Map<Id, SObject>(Database.query(soql));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Contact signal lookup skipped: ' + e.getMessage());
            return new Map<Id, SObject>();
        }
    }

    private static Map<Id, List<TR1__Application_V2__c>> querySilver(Set<Id> contactIds) {
        Map<Id, List<TR1__Application_V2__c>> out = new Map<Id, List<TR1__Application_V2__c>>();
        try {
            for (TR1__Application_V2__c app : [
                SELECT TR1__Applicant__c, TR1__Stage__c, TR1__Job__r.TR1__Job_Title__c
                FROM   TR1__Application_V2__c
                WHERE  TR1__Applicant__c IN :contactIds
                AND    TR1__Stage__c IN :SILVER_STAGES
                ORDER BY CreatedDate DESC
                LIMIT 1000
            ]) {
                if (!out.containsKey(app.TR1__Applicant__c)) out.put(app.TR1__Applicant__c, new List<TR1__Application_V2__c>());
                out.get(app.TR1__Applicant__c).add(app);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Silver medalist lookup skipped: ' + e.getMessage());
        }
        return out;
    }

    private static Map<Id, List<String>> queryRedeployments(Set<Id> contactIds, Id accountId, String searchTitle) {
        Map<Id, List<String>> out = new Map<Id, List<String>>();
        if (accountId == null) return out;

        String soql = 'SELECT ' + PLACEMENT_PERSON + ', ' + PLACEMENT_JOB + '__r.TR1__Job_Title__c'
            + ' FROM ' + PLACEMENT_OBJECT
            + ' WHERE ' + PLACEMENT_PERSON + ' IN :contactIds'
            + ' AND ' + PLACEMENT_JOB + '__r.TR1__Account__c = :accountId';
        try {
            for (SObject row : Database.query(soql)) {
                Id contactId = (Id) row.get(PLACEMENT_PERSON);
                SObject job = row.getSObject(PLACEMENT_JOB + '__r');
                String jobTitle = job == null ? null : (String) job.get('TR1__Job_Title__c');
                if (!isSimilarRole(jobTitle, searchTitle)) continue;

                if (!out.containsKey(contactId)) out.put(contactId, new List<String>());
                out.get(contactId).add(jobTitle);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Redeployment lookup skipped: ' + e.getMessage());
        }
        return out;
    }

    // ═════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════

    private static TR1__Call_List__c loadPool(Id callListId) {
        List<TR1__Call_List__c> rows = [
            SELECT Id, Name, Account__c, Account__r.Name
            FROM   TR1__Call_List__c
            WHERE  Id = :callListId
            LIMIT  1
        ];
        if (rows.isEmpty()) throw err('Talent Pool not found.');
        return rows[0];
    }

    /** The search brief held on the Talent Pool. Every part of it is optional. */
    public class PoolBrief {
        public String title;
        public String city;
        public Integer radiusMiles;
        public List<String> relatedTitles  = new List<String>();
        public List<String> certifications = new List<String>();
        public List<String> skills         = new List<String>();

        /** Certifications are strongly favoured. Skills and related titles are favoured. */
        public List<AmplifyTkMatchService.TkPreference> preferences() {
            List<AmplifyTkMatchService.TkPreference> out = new List<AmplifyTkMatchService.TkPreference>();
            add(out, certifications, true,  'Certification');
            add(out, skills,         false, 'Skill');
            add(out, relatedTitles,  false, 'Related title');
            return out;
        }

        private void add(List<AmplifyTkMatchService.TkPreference> out, List<String> terms, Boolean strong, String label) {
            for (String term : terms) {
                if (out.size() >= MAX_PREFERENCES) return;
                AmplifyTkMatchService.TkPreference p = new AmplifyTkMatchService.TkPreference();
                p.term   = term;
                p.strong = strong;
                p.label  = label;
                out.add(p);
            }
        }
    }

    /**
     * Reads the brief with dynamic SOQL, only for fields that exist, so the class compiles and runs
     * before the fields are created and each signal fails soft.
     */
    private static PoolBrief loadBrief(Id poolId) {
        PoolBrief brief = new PoolBrief();

        Map<String, Schema.SObjectField> poolFields = Schema.SObjectType.TR1__Call_List__c.fields.getMap();
        List<String> present = new List<String>();
        for (String f : new List<String>{
            POOL_TITLE_FIELD, POOL_RELATED_TITLES_FIELD, POOL_CITY_FIELD, POOL_RADIUS_FIELD
        }) {
            if (poolFields.containsKey(f.toLowerCase())) present.add(f);
        }

        if (!present.isEmpty()) {
            try {
                SObject row = Database.query(
                    'SELECT ' + String.join(present, ', ') + ' FROM TR1__Call_List__c WHERE Id = :poolId LIMIT 1'
                );
                if (present.contains(POOL_TITLE_FIELD)) {
                    Object role = row.get(POOL_TITLE_FIELD);
                    brief.title = role == null ? null : clean(String.valueOf(role));
                }
                if (present.contains(POOL_CITY_FIELD)) {
                    brief.city = clean((String) row.get(POOL_CITY_FIELD));
                }
                if (present.contains(POOL_RELATED_TITLES_FIELD)) {
                    brief.relatedTitles = splitList((String) row.get(POOL_RELATED_TITLES_FIELD), 6);
                }
                if (present.contains(POOL_RADIUS_FIELD) && row.get(POOL_RADIUS_FIELD) != null) {
                    Integer r = Decimal.valueOf(String.valueOf(row.get(POOL_RADIUS_FIELD))).intValue();
                    brief.radiusMiles = Math.max(1, Math.min(100, r));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Pool brief lookup skipped: ' + e.getMessage());
            }
        }

        // Skills and certifications linked to the pool through the lookup on TR1__Skills__c
        Map<String, Schema.SObjectField> skillFields = Schema.SObjectType.TR1__Skills__c.fields.getMap();
        if (skillFields.containsKey(SKILL_POOL_LOOKUP.toLowerCase())) {
            Boolean hasType = skillFields.containsKey(SKILL_TYPE_FIELD.toLowerCase());
            try {
                Set<String> seen = new Set<String>();
                for (SObject s : Database.query(
                    'SELECT TR1__Master_Skill_Name__c' + (hasType ? ', ' + SKILL_TYPE_FIELD : '')
                    + ' FROM TR1__Skills__c'
                    + ' WHERE ' + SKILL_POOL_LOOKUP + ' = :poolId AND TR1__Master_Skill_Name__c != null'
                    + ' ORDER BY TR1__Master_Skill_Name__c LIMIT 30'
                )) {
                    String name = clean((String) s.get('TR1__Master_Skill_Name__c'));
                    if (name == null || !seen.add(name.toLowerCase())) continue;

                    Object skillType = hasType ? s.get(SKILL_TYPE_FIELD) : null;
                    if (skillType != null && CERTIFICATION_TYPE.equalsIgnoreCase(String.valueOf(skillType))) {
                        brief.certifications.add(name);
                    } else {
                        brief.skills.add(name);
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Pool skills lookup skipped: ' + e.getMessage());
            }
        }
        return brief;
    }

    private static String clean(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    /** One item per line, or separated by commas or semicolons. Blank and repeated items are dropped. */
    @TestVisible
    private static List<String> splitList(String raw, Integer max) {
        List<String> out = new List<String>();
        if (String.isBlank(raw)) return out;

        Set<String> seen = new Set<String>();
        for (String part : raw.split('[\\n\\r;,]+')) {
            String t = part.trim();
            if (t.length() == 0 || !seen.add(t.toLowerCase())) continue;
            out.add(t);
            if (out.size() >= max) break;
        }
        return out;
    }

    private static String findEngagementField() {
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Contact.fields.getMap();
        for (String candidate : ENGAGEMENT_FIELDS) {
            if (fields.containsKey(candidate.toLowerCase())) return candidate;
        }
        return null;
    }

    /** "Delivery Driver Talent Pool" becomes "Delivery Driver". */
    @TestVisible
    private static String titleFromPoolName(String poolName) {
        if (String.isBlank(poolName)) return null;
        String cleaned = poolName.replaceAll('(?i)\\s*(talent\\s+pool|pool|pipeline|call\\s+list|list)\\s*$', '').trim();
        return String.isBlank(cleaned) ? poolName.trim() : cleaned;
    }

    /** Placed role counts as similar when it shares a meaningful word with the search title. */
    @TestVisible
    private static Boolean isSimilarRole(String placedTitle, String searchTitle) {
        if (String.isBlank(searchTitle)) return true;
        if (String.isBlank(placedTitle)) return false;

        Set<String> placed = tokens(placedTitle);
        for (String word : tokens(searchTitle)) {
            if (placed.contains(word)) return true;
        }
        return false;
    }

    private static Set<String> tokens(String text) {
        Set<String> out = new Set<String>();
        for (String w : text.toLowerCase().replaceAll('[^a-z0-9]+', ' ').split(' ')) {
            if (w.length() >= 4) out.add(w);
        }
        return out;
    }

    private static AuraHandledException err(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}