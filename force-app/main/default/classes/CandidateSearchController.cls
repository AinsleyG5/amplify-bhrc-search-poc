/**
 * CandidateSearchController
 *
 * @AuraEnabled facade for Candidate Search (spec section 6.1). Lists and nested objects go in and out as JSON
 * strings (Lightning Web Security delivered typed object lists to Apex as blank objects).
 *
 * Each call does at most one prompt call or one TK search, so the UI can render in between
 * (parse, then search; search, then explain). Job match is the exception allowed by the spec: searchWithUrl,
 * then one search with the Apex-refined parts when the refinement changed them.
 *
 * Errors reach the LWC as AuraHandledException with a readable message. A Textkernel failure on runSearch is
 * returned in the response's "error" instead of thrown, so the failed search can still be audited.
 *
 * Built Wednesday: parseQuery, startJobMatch, runSearch, refine, explainResults, autocompleteSkills,
 * getRecentAndSaved, saveSearch, setFavourite, logAction. getCompareData and the bulk actions come with the
 * Thursday front end.
 */
public with sharing class CandidateSearchController {

    // ═════════════════════════════════════════════════════════════
    // Natural language
    // ═════════════════════════════════════════════════════════════

    /**
     * NL text to criteria JSON. On an AI failure the search still works without AI: the text becomes one keyword
     * chip and trace.aiError says why.
     */
    @AuraEnabled
    public static String parseQuery(String text) {
        if (String.isBlank(text)) throw fail('Type what you are looking for first.');
        Map<String, Object> trace = new Map<String, Object>{
            'searchType' => 'Natural language',
            'naturalLanguage' => text.trim(),
            'promptTemplate' => SearchAiService.PARSE_PROMPT
        };
        Map<String, Object> criteria;
        try {
            SearchAiService.ParseOutcome out = SearchAiService.parse(text);
            criteria = out.criteria;
            putUsage(trace, out.usage);
        } catch (Exception e) {
            criteria = CriteriaService.newCriteria('nl');
            criteria.put('naturalLanguage', text.trim().abbreviate(255));
            CriteriaService.items(criteria).add(new Map<String, Object>{
                'id' => 'c1', 'kind' => 'keyword', 'label' => text.trim().abbreviate(CriteriaService.MAX_LABEL),
                'value' => text.trim(), 'weight' => 'required', 'origin' => 'nl'
            });
            trace.put('aiError', 'The AI could not read that search, so it runs as plain keywords. ' + e.getMessage());
        }
        criteria.put('trace', trace);
        return CriteriaService.serialize(criteria);
    }

    // ═════════════════════════════════════════════════════════════
    // Search
    // ═════════════════════════════════════════════════════════════

    /** Runs the criteria. auditId null = page 1 (new audit); otherwise appends the page at offset to that audit. */
    @AuraEnabled
    public static String runSearch(String criteriaJson, Integer offset, Id auditId) {
        Map<String, Object> criteria;
        Map<String, Object> trace;
        try {
            criteria = CriteriaService.parse(criteriaJson);
            trace = CriteriaService.stripTrace(criteria);
            CriteriaService.validate(criteria);
        } catch (CriteriaService.CriteriaException e) {
            throw fail(e.getMessage());
        }

        CriteriaService.BuildResult built = CriteriaService.toQueryParts(criteria);
        if (built.isEmpty()) throw fail('None of the criteria can be sent to Textkernel yet. Add a title, skill or keyword.');

        TkSearchClient.SearchOptions opts = built.options();
        opts.offset = offset == null ? 0 : offset;
        SearchRun run = new SearchRun();
        run.criteria = criteria;
        run.trace = trace;
        run.criteriaIds = built.criteriaIds;
        run.queryCriteriaIds = built.queryCriteriaIds;
        run.excludedCriteriaIds = built.excludedCriteriaIds;
        run.notices.addAll(built.notices);
        run.auditId = auditId;
        if (trace.get('aiError') != null) run.notices.add(String.valueOf(trace.get('aiError')));

        try {
            run.result = TkSearchClient.search(built.parts, opts);
        } catch (TkSearchClient.TkException e) {
            return searchFailed(run, e.getMessage());
        }
        return finish(run);
    }

    /**
     * Job match (spec 3b): searchWithUrl on the indexed job document, chips from the generated parts, Apex
     * refinement, and a second search only when the refinement changed the parts. Falls back to criteria built
     * from the job record when the job is not indexed or the doc:// URL is wrong.
     */
    @AuraEnabled
    public static String startJobMatch(Id jobId) {
        if (jobId == null) throw fail('No job was given.');
        SObject job;
        try {
            job = CriteriaService.loadJob(jobId);
        } catch (Exception e) {
            throw fail(e.getMessage());
        }
        String jobLabel = jobName(job);

        SearchRun run = new SearchRun();
        run.trace = new Map<String, Object>{ 'searchType' => 'Job match' };
        String docUrl = TkSearchClient.jobDocUrl(jobId);
        String indexError;

        try {
            TkSearchClient.Result indexed = TkSearchClient.searchWithUrl(docUrl, null);
            if (indexed.queryParts.isEmpty()) {
                indexError = 'Textkernel did not return the generated query';
            } else {
                Map<String, Object> criteria = CriteriaService.newCriteria('job');
                criteria.put('jobId', jobId);
                criteria.put('tkJobDocId', TkSearchClient.jobDocId(jobId));
                criteria.put('items', CriteriaService.fromTkQueryParts(indexed.queryParts));
                run.criteria = criteria;

                Boolean changed = CriteriaService.refineFromJob(criteria, job);
                CriteriaService.BuildResult built = CriteriaService.toQueryParts(criteria);
                run.notices.addAll(built.notices);
                run.notices.add('Built from the Textkernel job document for ' + jobLabel + '.');
                if (changed) {
                    run.notices.add('Adjusted the generated query (location, skill cap or softer title) and searched again.');
                    run.criteriaIds = built.criteriaIds;
                    run.queryCriteriaIds = built.queryCriteriaIds;
        run.excludedCriteriaIds = built.excludedCriteriaIds;
                    try {
                        run.result = TkSearchClient.search(built.parts, built.options());
                    } catch (TkSearchClient.TkException e) {
                        // The indexed result is still good: show it rather than fail the match
                        run.notices.add('The adjusted search failed (' + e.getMessage() + '), so these are the unadjusted results.');
                        run.result = indexed;
                        run.criteriaIds = idsInOrder(criteria);
                        run.queryCriteriaIds = new List<String>();
                        run.excludedCriteriaIds = new List<String>();
                    }
                    if (run.result !== indexed) {
                        run.result.requestXml = indexed.requestXml + '\n\n' + run.result.requestXml;
                    }
                } else {
                    run.result = indexed;
                    run.criteriaIds = idsInOrder(criteria);
                }
            }
        } catch (TkSearchClient.TkException e) {
            indexError = e.getMessage();
        }

        if (run.result == null) {
            try {
                run.criteria = CriteriaService.fromJobRecord(job);
                run.criteria.put('tkJobDocId', null);
                CriteriaService.validate(run.criteria);
            } catch (CriteriaService.CriteriaException e) {
                throw fail('This job is not in the Textkernel index (' + indexError + ') and ' + e.getMessage());
            }
            CriteriaService.BuildResult built = CriteriaService.toQueryParts(run.criteria);
            run.criteriaIds = built.criteriaIds;
            run.queryCriteriaIds = built.queryCriteriaIds;
        run.excludedCriteriaIds = built.excludedCriteriaIds;
            run.notices.addAll(built.notices);
            run.notices.add('Could not use the Textkernel job document (' + indexError + '). Built the search from the job record for ' + jobLabel + ' instead.');
            try {
                run.result = TkSearchClient.search(built.parts, built.options());
            } catch (TkSearchClient.TkException e) {
                return searchFailed(run, e.getMessage());
            }
        }
        run.recentName = 'Match: ' + jobLabel;
        return finish(run);
    }

    // ═════════════════════════════════════════════════════════════
    // Refine (chat)
    // ═════════════════════════════════════════════════════════════

    /**
     * One chat turn. Returns { criteria, reply, needsClarification, patch, diff }. When the patch is empty
     * (a question, or a clarification) the LWC does not re-run the search. The returned criteria carry a trace
     * so the next runSearch is audited as a Refine with this audit as its parent.
     */
    @AuraEnabled
    public static String refine(String criteriaJson, String message, String historyJson, Id auditId) {
        Map<String, Object> criteria;
        try {
            criteria = CriteriaService.parse(criteriaJson);
            CriteriaService.stripTrace(criteria);
        } catch (CriteriaService.CriteriaException e) {
            throw fail(e.getMessage());
        }

        SearchAiService.RefineOutcome out;
        try {
            out = SearchAiService.refine(criteria, message, historyJson, resultSummary(auditId));
        } catch (Exception e) {
            throw fail('The assistant could not apply that: ' + e.getMessage() + ' You can still edit the chips directly.');
        }

        Map<String, Object> trace = new Map<String, Object>{
            'searchType' => 'Refine',
            'parentAuditId' => auditId,
            'naturalLanguage' => message,
            'aiReply' => out.reply,
            'promptTemplate' => SearchAiService.REFINE_PROMPT
        };
        putUsage(trace, out.usage);
        out.criteria.put('trace', trace);

        return System.JSON.serialize(new Map<String, Object>{
            'criteria' => out.criteria,
            'reply' => out.reply,
            'needsClarification' => out.needsClarification,
            'patch' => out.patch,
            'diff' => out.diff
        });
    }

    /** Top 10 rows of the current audit, for questions about the results. */
    @TestVisible
    private static String resultSummary(Id auditId) {
        if (auditId == null) return '[]';
        List<Object> out = new List<Object>();
        for (Search_Audit_Result__c r : [
            SELECT TK_Doc_Id__c, Rank__c, TK_Score_Pct__c, TK_Query_Part_Scores__c, TK_Criteria_Map__c,
                   Pipeline_Flags__c, AI_Explanation__c, Contact__r.Name, Contact__r.Title, Contact__r.MailingCity
            FROM Search_Audit_Result__c
            WHERE Search_Audit__c = :auditId AND Hidden_By_Exclusion__c = false
            ORDER BY Rank__c ASC LIMIT 10
        ]) {
            Map<String, List<String>> m = SearchAuditService.metAndNotMet(r.TK_Query_Part_Scores__c, r.TK_Criteria_Map__c);
            out.add(new Map<String, Object>{
                'rank' => r.Rank__c,
                'name' => r.Contact__r == null ? null : r.Contact__r.Name,
                'title' => r.Contact__r == null ? null : r.Contact__r.Title,
                'city' => r.Contact__r == null ? null : r.Contact__r.MailingCity,
                'score' => r.TK_Score_Pct__c,
                'met' => m.get('met'),
                'notMet' => m.get('notMet'),
                'pipeline' => r.Pipeline_Flags__c,
                'explanation' => r.AI_Explanation__c
            });
        }
        return System.JSON.serialize(out);
    }

    // ═════════════════════════════════════════════════════════════
    // Explain
    // ═════════════════════════════════════════════════════════════

    /** Explains up to Explain_Batch_Size__c candidates of an audit. Returns [{docId, summary, criteria[]}]. */
    @AuraEnabled
    public static String explainResults(Id auditId, String docIdsJson) {
        if (auditId == null) throw fail('Run the search before asking for explanations.');
        List<String> docIds;
        try {
            docIds = (List<String>) System.JSON.deserialize(String.isBlank(docIdsJson) ? '[]' : docIdsJson, List<String>.class);
        } catch (Exception e) {
            throw fail('docIdsJson must be a JSON list of doc ids.');
        }
        Integer batch = CandidateSearchConfig.get().explainBatchSize;
        if (docIds.size() > batch) {
            List<String> first = new List<String>();
            for (Integer i = 0; i < batch; i++) first.add(docIds[i]);
            docIds = first;
        }
        if (docIds.isEmpty()) return '[]';

        List<Search_Audit__c> audits = [SELECT Id, Criteria_JSON__c FROM Search_Audit__c WHERE Id = :auditId LIMIT 1];
        if (audits.isEmpty()) throw fail('That search is no longer available.');
        Map<String, Object> criteria = CriteriaService.parse(audits[0].Criteria_JSON__c);

        List<SearchAiService.ExplainCandidate> candidates = explainInput(auditId, docIds);
        if (candidates.isEmpty()) {
            throw fail('Those results are still being saved. Try Explain again in a moment.');
        }

        SearchAiService.ExplainOutcome out;
        try {
            out = SearchAiService.explain(criteria, candidates);
        } catch (Exception e) {
            // Thrown, so nothing is written here (it would be rolled back); the LWC shows the message on the rows
            throw fail('Explanations are not available right now: ' + e.getMessage());
        }
        SearchAuditService.recordExplanations(auditId, out.explanations, out.usage);
        return System.JSON.serialize(out.explanations);
    }

    /** Only the fields the explain prompt needs (data governance, section 7.0). */
    @TestVisible
    private static List<SearchAiService.ExplainCandidate> explainInput(Id auditId, List<String> docIds) {
        Set<String> keys = new Set<String>();
        for (String d : docIds) keys.add(SearchAuditService.key(auditId, d));
        List<Search_Audit_Result__c> rows = [
            SELECT TK_Doc_Id__c, Contact__c, TK_Score_Pct__c, TK_Query_Part_Scores__c, TK_Criteria_Map__c, TK_Result_XML__c,
                   Contact__r.Title, Contact__r.MailingCity
            FROM Search_Audit_Result__c
            WHERE Audit_Doc_Key__c IN :keys AND TK_Criteria_Map__c != null
            ORDER BY Rank__c ASC
        ];

        Set<Id> contactIds = new Set<Id>();
        for (Search_Audit_Result__c r : rows) if (r.Contact__c != null) contactIds.add(r.Contact__c);
        Map<Id, List<String>> skills = skillsFor(contactIds);
        Map<Id, List<String>> notes = notesFor(contactIds);

        List<SearchAiService.ExplainCandidate> out = new List<SearchAiService.ExplainCandidate>();
        for (Search_Audit_Result__c r : rows) {
            SearchAiService.ExplainCandidate c = new SearchAiService.ExplainCandidate();
            c.docId = r.TK_Doc_Id__c;
            c.score = r.TK_Score_Pct__c;
            Map<String, List<String>> m = SearchAuditService.metAndNotMet(r.TK_Query_Part_Scores__c, r.TK_Criteria_Map__c);
            c.met = m.get('met');
            c.notMet = m.get('notMet');
            TkSearchClient.Hit h = TkSearchClient.parseHitXml(r.TK_Result_XML__c);
            for (List<String> snippets : h.highlights.values()) {
                for (String s : snippets) {
                    if (c.highlights.size() < 8) c.highlights.add(s.stripHtmlTags().abbreviate(300));
                }
            }
            c.profile.put('title', r.Contact__r == null ? null : r.Contact__r.Title);
            c.profile.put('city', r.Contact__r == null ? null : r.Contact__r.MailingCity);
            c.profile.put('skills', r.Contact__c == null || !skills.containsKey(r.Contact__c) ? new List<String>() : skills.get(r.Contact__c));
            c.profile.put('recentNotes', r.Contact__c == null || !notes.containsKey(r.Contact__c) ? new List<String>() : notes.get(r.Contact__c));
            out.add(c);
        }
        return out;
    }

    private static Map<Id, List<String>> skillsFor(Set<Id> contactIds) {
        Map<Id, List<String>> out = new Map<Id, List<String>>();
        if (contactIds.isEmpty()) return out;
        try {
            for (TR1__Skills__c s : [
                SELECT TR1__Contact__c, TR1__Master_Skill_Name__c FROM TR1__Skills__c
                WHERE TR1__Contact__c IN :contactIds AND TR1__Master_Skill_Name__c != null
                ORDER BY TR1__Master_Skill_Name__c LIMIT 500
            ]) {
                if (!out.containsKey(s.TR1__Contact__c)) out.put(s.TR1__Contact__c, new List<String>());
                if (out.get(s.TR1__Contact__c).size() < 20) out.get(s.TR1__Contact__c).add(s.TR1__Master_Skill_Name__c);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Skills not loaded: ' + e.getMessage());
        }
        return out;
    }

    /** The 3 latest task notes per candidate, with source and date so evidence can cite them. */
    private static Map<Id, List<String>> notesFor(Set<Id> contactIds) {
        Map<Id, List<String>> out = new Map<Id, List<String>>();
        if (contactIds.isEmpty()) return out;
        for (Task t : [
            SELECT WhoId, Subject, Description, ActivityDate, CreatedDate FROM Task
            WHERE WhoId IN :contactIds
            ORDER BY CreatedDate DESC LIMIT 200
        ]) {
            // Description is a long text field, so it cannot be filtered in SOQL: skip blank notes here
            if (String.isBlank(t.Description)) continue;
            if (!out.containsKey(t.WhoId)) out.put(t.WhoId, new List<String>());
            List<String> l = out.get(t.WhoId);
            if (l.size() >= 3) continue;
            Date d = t.ActivityDate != null ? t.ActivityDate : t.CreatedDate.date();
            l.add('[' + (t.Subject == null ? 'Task' : t.Subject.abbreviate(60)) + ', ' + String.valueOf(d) + '] ' + t.Description.abbreviate(400));
        }
        return out;
    }

    // ═════════════════════════════════════════════════════════════
    // Skills autocomplete, recent and saved searches, actions
    // ═════════════════════════════════════════════════════════════

    @AuraEnabled(cacheable=true)
    public static String autocompleteSkills(String prefix) {
        if (String.isBlank(prefix) || prefix.trim().length() < 2) return '[]';
        try {
            return System.JSON.serialize(TkSkillsClient.autocomplete(prefix, null, 10));
        } catch (Exception e) {
            throw fail(e.getMessage());
        }
    }

    @AuraEnabled
    public static String getRecentAndSaved() {
        Id me = UserInfo.getUserId();
        Integer keep = CandidateSearchConfig.get().recentSearchesKept;
        List<Saved_Search__c> recent = [
            SELECT Id, Name, Criteria_JSON__c, Natural_Language__c, Job__c, Is_Favourite__c, Last_Run__c, Run_Count__c
            FROM Saved_Search__c WHERE OwnerId = :me AND Is_Saved__c = false
            ORDER BY Last_Run__c DESC NULLS LAST LIMIT :keep
        ];
        List<Saved_Search__c> saved = [
            SELECT Id, Name, Criteria_JSON__c, Natural_Language__c, Job__c, Is_Favourite__c, Last_Run__c, Run_Count__c
            FROM Saved_Search__c WHERE OwnerId = :me AND Is_Saved__c = true
            ORDER BY Is_Favourite__c DESC, Last_Run__c DESC NULLS LAST LIMIT 100
        ];
        List<Saved_Search__c> favourites = new List<Saved_Search__c>();
        for (Saved_Search__c s : saved) if (s.Is_Favourite__c) favourites.add(s);
        return System.JSON.serialize(new Map<String, Object>{
            'recent' => recent, 'saved' => saved, 'favourites' => favourites
        });
    }

    @AuraEnabled
    public static Id saveSearch(String name, String criteriaJson, Boolean favourite) {
        if (String.isBlank(name)) throw fail('Give the search a name.');
        Map<String, Object> criteria;
        try {
            criteria = CriteriaService.parse(criteriaJson);
            CriteriaService.stripTrace(criteria);
            CriteriaService.validate(criteria);
        } catch (CriteriaService.CriteriaException e) {
            throw fail(e.getMessage());
        }
        String jobId = CriteriaService.str(criteria, 'jobId');
        Saved_Search__c s = new Saved_Search__c(
            Name = name.trim().abbreviate(80),
            Criteria_JSON__c = CriteriaService.serialize(criteria),
            Natural_Language__c = abbreviate(CriteriaService.str(criteria, 'naturalLanguage'), 255),
            Job__c = String.isBlank(jobId) ? null : Id.valueOf(jobId),
            Criteria_Hash__c = CriteriaService.hash(criteria),
            Is_Saved__c = true,
            Is_Favourite__c = favourite == true,
            Last_Run__c = System.now(),
            Run_Count__c = 0
        );
        try {
            insert s;
        } catch (DmlException e) {
            throw fail('Could not save the search. ' + dmlText(e));
        }
        return s.Id;
    }

    @AuraEnabled
    public static void setFavourite(Id savedSearchId, Boolean favourite) {
        if (savedSearchId == null) throw fail('No saved search was given.');
        try {
            update new Saved_Search__c(Id = savedSearchId, Is_Favourite__c = favourite == true);
        } catch (DmlException e) {
            throw fail('Could not update the favourite. ' + dmlText(e));
        }
    }

    /** action: opened, shortlisted, compared, added to pool, dismissed. */
    @AuraEnabled
    public static void logAction(Id auditId, String docId, String action) {
        if (auditId == null || String.isBlank(docId)) return;
        try {
            SearchAuditService.logAction(auditId, docId, action);
        } catch (SearchAuditService.SearchAuditException e) {
            throw fail(e.getMessage());
        } catch (Exception e) {
            // An audit failure never blocks the recruiter
            System.debug(LoggingLevel.WARN, 'Action not logged: ' + e.getMessage());
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Shared search completion
    // ═════════════════════════════════════════════════════════════

    private class SearchRun {
        public Map<String, Object> criteria;
        public Map<String, Object> trace = new Map<String, Object>();
        public List<String> criteriaIds = new List<String>();
        /** Location chips sent in the query string: met by every result. */
        public List<String> queryCriteriaIds = new List<String>();
        /** Excluded chips (and the placed-recently exclusion) sent as -field:value in the query string. */
        public List<String> excludedCriteriaIds = new List<String>();
        public List<String> notices = new List<String>();
        public TkSearchClient.Result result;
        public Id auditId;
        public String recentName;
    }

    /** Audit (page 1 parent sync, children in the Queueable), pipeline flags, rows, SearchResponse JSON. */
    private static String finish(SearchRun s) {
        TkSearchClient.Result r = s.result;
        Boolean firstPage = s.auditId == null;
        String criteriaJson = CriteriaService.serialize(s.criteria);
        Id jobId = idOrNull(CriteriaService.str(s.criteria, 'jobId'));

        Set<Id> contactIds = new Set<Id>();
        for (TkSearchClient.Hit h : r.hits) if (h.contactId != null) contactIds.add(h.contactId);

        Map<Id, PipelineStatusService.Flags> flags = PipelineStatusService.flagsFor(jobId, contactIds);
        s.notices.addAll(PipelineStatusService.warnings);
        Map<Id, Contact> contacts = contactsFor(contactIds);
        Integer recentDays = placedWithinDays(s.criteria);

        Boolean hidePipeline = CriteriaService.exclusions(s.criteria).get('pipelineForJob') == true;
        Set<String> hidden = new Set<String>();
        for (TkSearchClient.Hit h : r.hits) {
            PipelineStatusService.Flags f = h.contactId == null ? null : flags.get(h.contactId);
            if (hidePipeline && f != null && f.hasAny()) hidden.add(h.docId);
        }

        // Page 1: the parent, synchronously, so its Id goes back to the LWC
        if (firstPage) {
            try {
                String aiError = s.trace == null ? null : CriteriaService.str(s.trace, 'aiError');
                Search_Audit__c a = SearchAuditService.newAudit(
                    auditStart(s, criteriaJson, jobId), r, aiError == null ? 'Success' : 'AI error', aiError
                );
                insert a;
                s.auditId = a.Id;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Search audit not created: ' + e.getMessage());
                s.notices.add('This search could not be audited: ' + e.getMessage());
            }
        }

        if (s.auditId != null) {
            try {
                SearchAuditWriter w = new SearchAuditWriter();
                w.auditId = s.auditId;
                w.firstPage = firstPage;
                List<String> auditIds = new List<String>(s.criteriaIds);
                for (String id : s.queryCriteriaIds) auditIds.add('q:' + id);
                for (String id : s.excludedCriteriaIds) auditIds.add('x:' + id);
                w.rows = SearchAuditService.resultRows(s.auditId, r, auditIds, flags, hidden);
                w.appendRequestXml = firstPage ? null : r.requestXml;
                w.rawResponse = firstPage ? r.responseXml : null;
                if (firstPage) w.recent = recent(s, criteriaJson, jobId);
                System.enqueueJob(w);
            } catch (Exception e) {
                SearchAuditService.recordError(s.auditId, 'Audit error', e.getMessage());
            }
        }

        List<Object> rows = new List<Object>();
        Integer pos = 0;
        for (TkSearchClient.Hit h : r.hits) {
            pos++;
            if (hidden.contains(h.docId)) continue;
            Map<String, Object> rowOut = row(h, r.offset + pos, s.criteriaIds, contacts.get(h.contactId), flags.get(h.contactId), recentDays);
            rowOut.put('queryCriteriaIds', s.queryCriteriaIds);
            rowOut.put('excludedCriteriaIds', s.excludedCriteriaIds);
            rows.add(rowOut);
        }

        List<Object> facets = new List<Object>();
        for (TkSearchClient.Facet f : r.facets) {
            List<Object> values = new List<Object>();
            for (TkSearchClient.FacetValue v : f.values) values.add(new Map<String, Object>{ 'value' => v.value, 'count' => v.count });
            facets.add(new Map<String, Object>{ 'field' => f.field, 'values' => values });
        }

        Integer pageSize = r.pageSize == null ? r.hits.size() : r.pageSize;
        return System.JSON.serialize(new Map<String, Object>{
            'auditId' => s.auditId,
            'criteria' => s.criteria,
            'requestXml' => r.requestXml,
            'total' => r.total,
            'hasMore' => r.hasMore,
            'offset' => r.offset,
            'nextOffset' => r.offset + r.hits.size(),
            'pageSize' => pageSize,
            'hiddenCount' => hidden.size(),
            // More than half a page hidden by the pipeline exclusion: the LWC loads the next page straight away (section 8)
            'autoLoadMore' => r.hasMore && hidden.size() * 2 > pageSize,
            'facets' => facets,
            'rows' => rows,
            'notices' => s.notices,
            'error' => null
        });
    }

    /** TK failed: record an audit with Status TK error and return the message instead of throwing (which would roll it back). */
    private static String searchFailed(SearchRun s, String message) {
        Id auditId = s.auditId;
        Map<String, Object> criteria = s.criteria == null ? new Map<String, Object>() : s.criteria;
        if (auditId == null) {
            try {
                Search_Audit__c a = SearchAuditService.newAudit(
                    auditStart(s, CriteriaService.serialize(criteria), idOrNull(CriteriaService.str(criteria, 'jobId'))),
                    null, 'TK error', message
                );
                insert a;
                auditId = a.Id;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Failed search not audited: ' + e.getMessage());
            }
        } else {
            SearchAuditService.recordError(auditId, 'TK error', message);
        }
        return System.JSON.serialize(new Map<String, Object>{
            'auditId' => auditId,
            'criteria' => criteria,
            'total' => 0,
            'hasMore' => false,
            'offset' => 0,
            'rows' => new List<Object>(),
            'facets' => new List<Object>(),
            'notices' => s.notices,
            'error' => 'The search could not run: ' + message
        });
    }

    private static Map<String, Object> row(
        TkSearchClient.Hit h, Integer rank, List<String> criteriaIds, Contact c,
        PipelineStatusService.Flags f, Integer recentDays
    ) {
        List<Integer> flagsOut = new List<Integer>();
        for (Decimal d : h.queryPartScores) flagsOut.add(d != null && d > 0 ? 1 : 0);

        Date lastPlaced = c == null ? null : dateField(c, 'TR1__Last_Placement_Date__c');
        Boolean placedRecently = lastPlaced != null && lastPlaced >= Date.today().addDays(-(recentDays == null ? 30 : recentDays));

        Map<String, Object> pipeline = new Map<String, Object>{
            'applied' => f != null && f.applied,
            'stage' => f == null ? null : f.stage,
            'shortlisted' => f != null && f.shortlisted,
            'placed' => f != null && f.placed,
            'placedDate' => f == null ? null : f.placedDate,
            'placedRecently' => placedRecently,
            'label' => f == null ? null : f.label()
        };

        return new Map<String, Object>{
            'docId' => h.docId,
            'contactId' => h.contactId,
            'rank' => rank,
            'score' => h.score,
            'scorePct' => h.scorePct,
            'queryPartFlags' => flagsOut,
            'queryPartScores' => h.queryPartScores,
            'criteriaIds' => criteriaIds,
            'name' => c != null ? c.Name : firstValue(h.fields, 'fullname'),
            'title' => c != null && String.isNotBlank(c.Title) ? c.Title : firstValue(h.fields, 'recent_jobtitles'),
            'city' => c != null && String.isNotBlank(c.MailingCity) ? c.MailingCity : firstValue(h.fields, 'city'),
            'distance' => null,
            'highlights' => h.highlights,
            'pipeline' => pipeline
        };
    }

    private static SearchAuditService.AuditStart auditStart(SearchRun s, String criteriaJson, Id jobId) {
        Map<String, Object> t = s.trace == null ? new Map<String, Object>() : s.trace;
        SearchAuditService.AuditStart a = new SearchAuditService.AuditStart();
        a.searchType = t.get('searchType') == null ? 'Manual' : String.valueOf(t.get('searchType'));
        a.jobId = jobId;
        a.parentAuditId = idOrNull(CriteriaService.str(t, 'parentAuditId'));
        a.savedSearchId = idOrNull(CriteriaService.str(t, 'savedSearchId'));
        a.naturalLanguage = CriteriaService.str(t, 'naturalLanguage');
        if (a.naturalLanguage == null && s.criteria != null) a.naturalLanguage = CriteriaService.str(s.criteria, 'naturalLanguage');
        a.aiProposedJson = CriteriaService.str(t, 'proposedJson');
        a.aiReply = CriteriaService.str(t, 'aiReply');
        a.promptTemplate = CriteriaService.str(t, 'promptTemplate');
        a.aiModel = CriteriaService.str(t, 'model');
        a.aiInputTokens = intOrNull(t.get('inputTokens'));
        a.aiOutputTokens = intOrNull(t.get('outputTokens'));
        a.aiDurationMs = t.get('durationMs') == null ? null : Long.valueOf(String.valueOf(t.get('durationMs')));
        a.criteriaJson = criteriaJson;
        return a;
    }

    private static SearchAuditWriter.RecentSearch recent(SearchRun s, String criteriaJson, Id jobId) {
        // A search run from a saved search updates that record's run stats, not the recent list
        if (s.trace != null && s.trace.get('savedSearchId') != null) return null;
        SearchAuditWriter.RecentSearch rs = new SearchAuditWriter.RecentSearch();
        rs.criteriaJson = criteriaJson;
        rs.naturalLanguage = CriteriaService.str(s.criteria, 'naturalLanguage');
        rs.jobId = jobId;
        rs.criteriaHash = CriteriaService.hash(s.criteria);
        rs.name = s.recentName;
        if (String.isBlank(rs.name)) rs.name = rs.naturalLanguage;
        if (String.isBlank(rs.name)) {
            List<String> labels = new List<String>();
            for (Object o : CriteriaService.items(s.criteria)) {
                if (labels.size() < 3) labels.add(CriteriaService.str((Map<String, Object>) o, 'label'));
            }
            rs.name = String.join(labels, ', ');
        }
        return rs;
    }

    private static void putUsage(Map<String, Object> trace, SearchAiService.Usage u) {
        if (u == null) return;
        trace.put('proposedJson', u.proposedJson);
        trace.put('model', u.model);
        trace.put('inputTokens', u.inputTokens);
        trace.put('outputTokens', u.outputTokens);
        trace.put('durationMs', u.durationMs);
        trace.put('attempts', u.attempts);
    }

    /** searchWithUrl result: one chip per generated part, in the order TK returned them. */
    private static List<String> idsInOrder(Map<String, Object> criteria) {
        List<String> ids = new List<String>();
        for (Object o : CriteriaService.items(criteria)) ids.add(CriteriaService.str((Map<String, Object>) o, 'id'));
        return ids;
    }

    private static Map<Id, Contact> contactsFor(Set<Id> ids) {
        if (ids.isEmpty()) return new Map<Id, Contact>();
        Boolean hasLastPlacement = Schema.SObjectType.Contact.fields.getMap().containsKey('tr1__last_placement_date__c');
        String soql = 'SELECT Id, Name, Title, MailingCity' + (hasLastPlacement ? ', TR1__Last_Placement_Date__c' : '')
            + ' FROM Contact WHERE Id IN :ids';
        return new Map<Id, Contact>((List<Contact>) Database.query(soql));
    }

    private static Integer placedWithinDays(Map<String, Object> criteria) {
        Object v = CriteriaService.exclusions(criteria).get('placedWithinDays');
        return v == null ? null : Integer.valueOf(String.valueOf(v));
    }

    private static String jobName(SObject job) {
        String title = null;
        try {
            title = (String) job.get('TR1__Job_Title__c');
        } catch (SObjectException e) {
            title = null;
        }
        String name = (String) job.get('Name');
        return String.isBlank(title) ? name : name + ' (' + title + ')';
    }

    private static Date dateField(SObject rec, String field) {
        try {
            Object v = rec.get(field);
            return v instanceof Date ? (Date) v : null;
        } catch (SObjectException e) {
            return null;
        }
    }

    private static String firstValue(Map<String, List<String>> m, String key) {
        return m.containsKey(key) && !m.get(key).isEmpty() ? m.get(key)[0] : null;
    }

    private static Id idOrNull(String s) {
        if (String.isBlank(s)) return null;
        try {
            return Id.valueOf(s);
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer intOrNull(Object v) {
        return v == null ? null : Integer.valueOf(String.valueOf(v));
    }

    private static String abbreviate(String s, Integer max) {
        return s == null ? null : s.abbreviate(max);
    }

    /** Same as EnrichmentApplyController.dmlText (private there). */
    private static String dmlText(DmlException e) {
        List<String> parts = new List<String>();
        for (Integer i = 0; i < e.getNumDml(); i++) {
            List<String> fields = e.getDmlFieldNames(i);
            parts.add((fields.isEmpty() ? '' : '[' + String.join(fields, ', ') + '] ') + e.getDmlMessage(i) + ' (' + e.getDmlType(i) + ')');
        }
        return parts.isEmpty() ? e.getMessage() : String.join(parts, '; ');
    }

    private static AuraHandledException fail(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}
