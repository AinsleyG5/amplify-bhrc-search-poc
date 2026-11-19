/**
 * SearchAuditService
 *
 * Builds the audit trail for Candidate Search (spec section 9):
 *   Search_Audit__c         one per search execution, inserted synchronously so its Id goes back to the LWC
 *   Search_Audit_Result__c  one per candidate returned, built here and written by SearchAuditWriter (Queueable)
 *
 * Explanations and recruiter actions are written onto the result rows, keyed by Audit_Doc_Key__c.
 */
public with sharing class SearchAuditService {

    public static final Integer LONG_TEXT_MAX = 131072;

    /** What is known about a search before TK answers. */
    public class AuditStart {
        public String searchType = 'Manual';
        public Id jobId;
        public Id parentAuditId;
        public Id savedSearchId;
        public String naturalLanguage;
        public String aiProposedJson;
        public String aiReply;
        public String promptTemplate;
        public String aiModel;
        public Integer aiInputTokens;
        public Integer aiOutputTokens;
        public Long aiDurationMs;
        public String criteriaJson;
    }

    private static final Set<String> SEARCH_TYPES = new Set<String>{ 'Natural language', 'Job match', 'Refine', 'Saved search', 'Manual' };

    /** Page 1: insert the parent synchronously. TK fields are set when the result is known. */
    public static Search_Audit__c newAudit(AuditStart s, TkSearchClient.Result r, String status, String error) {
        Search_Audit__c a = new Search_Audit__c(
            User__c = UserInfo.getUserId(),
            Search_Type__c = SEARCH_TYPES.contains(s.searchType) ? s.searchType : 'Manual',
            Job__c = s.jobId,
            Parent_Audit__c = s.parentAuditId,
            Saved_Search__c = s.savedSearchId,
            Natural_Language__c = abbreviate(s.naturalLanguage, 32768),
            AI_Proposed_Criteria_JSON__c = abbreviate(s.aiProposedJson, LONG_TEXT_MAX),
            AI_Reply__c = abbreviate(s.aiReply, 32768),
            Prompt_Template__c = abbreviate(s.promptTemplate, 80),
            AI_Model__c = abbreviate(s.aiModel, 80),
            AI_Input_Tokens__c = s.aiInputTokens,
            AI_Output_Tokens__c = s.aiOutputTokens,
            AI_Duration_ms__c = s.aiDurationMs,
            Criteria_JSON__c = abbreviate(s.criteriaJson, LONG_TEXT_MAX),
            Status__c = status,
            Error__c = abbreviate(error, 32768),
            Pages_Loaded__c = 0
        );
        if (r != null) {
            a.TK_Method__c = r.method;
            a.TK_Request_XML__c = abbreviate(r.requestXml, LONG_TEXT_MAX);
            a.TK_Total__c = r.total;
            a.TK_Duration_ms__c = r.durationMs;
        }
        return a;
    }

    /** Builds one result row per hit. Rank is across pages: offset + position + 1. */
    public static List<Search_Audit_Result__c> resultRows(
        Id auditId, TkSearchClient.Result r, List<String> criteriaIds,
        Map<Id, PipelineStatusService.Flags> flags, Set<String> hiddenDocIds
    ) {
        List<Search_Audit_Result__c> rows = new List<Search_Audit_Result__c>();
        Integer pos = 0;
        String criteriaMap = String.join(criteriaIds, ',').abbreviate(255);
        for (TkSearchClient.Hit h : r.hits) {
            pos++;
            if (String.isBlank(h.docId)) continue;
            PipelineStatusService.Flags f = h.contactId == null ? null : flags.get(h.contactId);
            rows.add(new Search_Audit_Result__c(
                Search_Audit__c = auditId,
                Audit_Doc_Key__c = key(auditId, h.docId),
                Contact__c = h.contactId,
                TK_Doc_Id__c = h.docId.abbreviate(80),
                Rank__c = r.offset + pos,
                Page_Offset__c = r.offset,
                TK_Score__c = h.score == null ? null : Math.min(h.score, 9.9999).setScale(4),
                TK_Score_Pct__c = h.scorePct,
                TK_Query_Part_Scores__c = joinScores(h.queryPartScores).abbreviate(255),
                TK_Criteria_Map__c = criteriaMap,
                TK_Result_XML__c = abbreviate(h.xml, LONG_TEXT_MAX),
                Pipeline_Flags__c = f == null ? null : f.label().abbreviate(255),
                Hidden_By_Exclusion__c = hiddenDocIds.contains(h.docId)
            ));
        }
        return rows;
    }

    public static String key(Id auditId, String docId) {
        return String.valueOf(auditId) + '_' + docId;
    }

    public static String joinScores(List<Decimal> scores) {
        List<String> s = new List<String>();
        for (Decimal d : scores) s.add(d == null ? '0' : String.valueOf(d.stripTrailingZeros()));
        return String.join(s, ',');
    }

    /**
     * Chip ids met / not met by one result, from the per-query-part scores and the criteria map stored with it.
     * A chip with two parts (skill text + KS code) counts as met when any of its parts scored.
     * Filter and exclusion parts are not chips and are left out. "q:<id>" entries (query string) are always met.
     */
    public static Map<String, List<String>> metAndNotMet(String scoresCsv, String criteriaMapCsv) {
        List<String> scores = String.isBlank(scoresCsv) ? new List<String>() : scoresCsv.split(',');
        List<String> ids = String.isBlank(criteriaMapCsv) ? new List<String>() : criteriaMapCsv.split(',');
        Map<String, Boolean> metById = new Map<String, Boolean>();
        for (Integer i = 0; i < ids.size(); i++) {
            String id = ids[i].trim();
            // q:<id> = sent in the query string (location): every result met it
            if (id.startsWith('q:')) {
                metById.put(id.substring(2), true);
                continue;
            }
            if (id.contains(':')) continue;
            Boolean met = false;
            if (i < scores.size()) {
                try {
                    met = Decimal.valueOf(scores[i].trim()) > 0;
                } catch (Exception e) {
                    met = false;
                }
            }
            metById.put(id, metById.get(id) == true || met);
        }
        Map<String, List<String>> out = new Map<String, List<String>>{ 'met' => new List<String>(), 'notMet' => new List<String>() };
        for (String id : metById.keySet()) out.get(metById.get(id) ? 'met' : 'notMet').add(id);
        return out;
    }

    /** Writes explanations onto the result rows and adds the call's usage to the parent. Never throws. */
    public static void recordExplanations(Id auditId, List<Map<String, Object>> explanations, SearchAiService.Usage usage) {
        try {
            List<Search_Audit_Result__c> rows = new List<Search_Audit_Result__c>();
            for (Map<String, Object> e : explanations) {
                String docId = String.valueOf(e.get('docId'));
                rows.add(new Search_Audit_Result__c(
                    Search_Audit__c = auditId,
                    Audit_Doc_Key__c = key(auditId, docId),
                    TK_Doc_Id__c = docId,
                    AI_Explanation__c = abbreviate(String.valueOf(e.get('summary')), 32768),
                    AI_Evidence_JSON__c = abbreviate(System.JSON.serialize(e.get('criteria')), LONG_TEXT_MAX),
                    AI_Explained_At__c = System.now()
                ));
            }
            if (!rows.isEmpty()) Database.upsert(rows, Search_Audit_Result__c.Audit_Doc_Key__c, false);

            if (usage != null) {
                Search_Audit__c a = [
                    SELECT Id, Explain_Input_Tokens__c, Explain_Output_Tokens__c, Explain_Duration_ms__c
                    FROM Search_Audit__c WHERE Id = :auditId LIMIT 1
                ];
                a.Explain_Model__c = abbreviate(usage.model, 80);
                a.Explain_Input_Tokens__c = nz(a.Explain_Input_Tokens__c) + usage.inputTokens;
                a.Explain_Output_Tokens__c = nz(a.Explain_Output_Tokens__c) + usage.outputTokens;
                a.Explain_Duration_ms__c = nz(a.Explain_Duration_ms__c) + usage.durationMs;
                update a;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Explanations not audited for ' + auditId + ': ' + e.getMessage());
        }
    }

    public static void recordError(Id auditId, String status, String message) {
        try {
            update new Search_Audit__c(Id = auditId, Status__c = status, Error__c = abbreviate(message, 32768));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Audit error not recorded for ' + auditId + ': ' + e.getMessage());
        }
    }

    private static final Map<String, String> ACTIONS = new Map<String, String>{
        'opened' => 'Opened',
        'compared' => 'Compared',
        'shortlisted' => 'Shortlisted',
        'added to pool' => 'Added to pool',
        'addedtopool' => 'Added to pool',
        'pooled' => 'Added to pool',
        'dismissed' => 'Dismissed'
    };

    /**
     * Adds an action to the result row. Upsert, so an action that arrives before the Queueable has written the
     * row creates it (the writer's later upsert fills in the TK fields and leaves the action alone).
     */
    public static void logAction(Id auditId, String docId, String action) {
        logActions(auditId, new Set<String>{ docId }, action);
    }

    /** Bulk logAction: one query and one upsert for all the doc ids (bulk add, compare). */
    public static void logActions(Id auditId, Set<String> docIds, String action) {
        String value = action == null ? null : ACTIONS.get(action.trim().toLowerCase());
        if (value == null) throw new SearchAuditException('Unknown action "' + action + '". Use opened, compared, shortlisted, added to pool or dismissed.');
        if (auditId == null || docIds == null || docIds.isEmpty()) return;

        Map<String, String> docByKey = new Map<String, String>();
        for (String d : docIds) if (String.isNotBlank(d)) docByKey.put(key(auditId, d), d);
        Map<String, Search_Audit_Result__c> existing = new Map<String, Search_Audit_Result__c>();
        for (Search_Audit_Result__c r : [
            SELECT Id, Audit_Doc_Key__c, User_Action__c FROM Search_Audit_Result__c WHERE Audit_Doc_Key__c IN :docByKey.keySet()
        ]) {
            existing.put(r.Audit_Doc_Key__c, r);
        }

        List<Search_Audit_Result__c> rows = new List<Search_Audit_Result__c>();
        for (String k : docByKey.keySet()) {
            Search_Audit_Result__c old = existing.get(k);
            Set<String> actions = new Set<String>();
            if (old != null && String.isNotBlank(old.User_Action__c)) actions.addAll(old.User_Action__c.split(';'));
            actions.add(value);
            Search_Audit_Result__c row = new Search_Audit_Result__c(
                Audit_Doc_Key__c = k,
                User_Action__c = String.join(new List<String>(actions), ';'),
                User_Action_At__c = System.now()
            );
            if (old == null) {
                String docId = docByKey.get(k);
                row.Search_Audit__c = auditId;
                row.TK_Doc_Id__c = docId;
                row.Contact__c = TkSearchClient.contactIdFrom(docId);
            }
            rows.add(row);
        }
        upsert rows Audit_Doc_Key__c;
    }

    public class SearchAuditException extends Exception {}

    private static String abbreviate(String s, Integer max) {
        return s == null ? null : s.abbreviate(max);
    }

    private static Decimal nz(Decimal d) {
        return d == null ? 0 : d;
    }
}
