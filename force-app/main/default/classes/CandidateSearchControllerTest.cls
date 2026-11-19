@isTest
private class CandidateSearchControllerTest {

    private static Map<String, Object> obj(String jsonText) {
        return (Map<String, Object>) System.JSON.deserializeUntyped(jsonText);
    }

    /** Done-when check (spec 13, Wednesday): NL text to criteria to TK results, audited with one row per candidate. */
    @isTest
    static void naturalLanguageSearchEndToEnd() {
        CandidateSearchTestMocks.usePrompts();
        List<Contact> cs = CandidateSearchTestMocks.contacts(3);
        CandidateSearchTestMocks.toolInputs.put('set_criteria', new List<String>{ CandidateSearchTestMocks.PARSE_OUTPUT });
        CandidateSearchTestMocks.partScores = new List<String>{ '1.0', '0.0', '1.0' };
        CandidateSearchTestMocks.total = 9;
        CandidateSearchTestMocks.hasMore = true;
        CandidateSearchTestMocks.install();

        Test.startTest();
        String criteriaJson = CandidateSearchController.parseQuery('Forklift-certified warehouse operatives within 15 miles of Dagenham, available only');
        Map<String, Object> criteria = obj(criteriaJson);
        System.assertEquals(3, ((List<Object>) criteria.get('items')).size());
        Map<String, Object> trace = (Map<String, Object>) criteria.get('trace');
        System.assertEquals('Natural language', trace.get('searchType'));
        System.assertEquals(120, trace.get('inputTokens'));

        Map<String, Object> res = obj(CandidateSearchController.runSearch(criteriaJson, 0, null));
        Test.stopTest();

        System.assertEquals(null, res.get('error'));
        System.assertEquals(9, res.get('total'));
        System.assertEquals(true, res.get('hasMore'));
        List<Object> rows = (List<Object>) res.get('rows');
        System.assertEquals(3, rows.size());
        Map<String, Object> row = (Map<String, Object>) rows[0];
        System.assertEquals(cs[0].Id, row.get('contactId'));
        System.assertEquals(1, row.get('rank'));
        System.assertEquals(98, row.get('scorePct'));
        System.assertEquals(new List<Object>{ 1, 0, 1 }, row.get('queryPartFlags'));
        System.assertEquals(new List<Object>{ 'c1', 'c2', 'filter:candidate_status' }, row.get('criteriaIds'));
        System.assertEquals(new List<Object>{ 'c3' }, row.get('queryCriteriaIds'));
        System.assert(CandidateSearchTestMocks.requests[1].getBody().contains('<query>city:Dagenham+15</query>'), 'location goes in the query string');
        System.assertEquals('Test0 Candidate0', row.get('name'));
        System.assertEquals(1, ((List<Object>) res.get('facets')).size());
        System.assert(((Map<String, Object>) res.get('criteria')).get('trace') == null, 'trace is never returned or stored');

        Id auditId = (Id) res.get('auditId');
        Search_Audit__c a = [
            SELECT Search_Type__c, Status__c, TK_Method__c, TK_Total__c, AI_Proposed_Criteria_JSON__c, Criteria_JSON__c,
                   Natural_Language__c, Prompt_Template__c, AI_Input_Tokens__c, Saved_Search__c, TK_Request_XML__c
            FROM Search_Audit__c WHERE Id = :auditId
        ];
        System.assertEquals('Natural language', a.Search_Type__c);
        System.assertEquals('Success', a.Status__c);
        System.assertEquals('search', a.TK_Method__c);
        System.assertEquals(9, a.TK_Total__c);
        System.assertEquals(SearchAiService.PARSE_PROMPT, a.Prompt_Template__c);
        System.assert(a.AI_Proposed_Criteria_JSON__c.contains('Certified Forklift Operator'));
        System.assert(!a.Criteria_JSON__c.contains('"trace"'));
        System.assert(a.TK_Request_XML__c.contains('<password>(hidden)</password>'));
        System.assertNotEquals(null, a.Saved_Search__c, 'logged as a recent search');
        System.assertEquals(3, [SELECT COUNT() FROM Search_Audit_Result__c WHERE Search_Audit__c = :auditId]);
        Search_Audit_Result__c first = [SELECT TK_Criteria_Map__c FROM Search_Audit_Result__c WHERE Search_Audit__c = :auditId ORDER BY Rank__c LIMIT 1];
        System.assertEquals('c1,c2,filter:candidate_status,q:c3', first.TK_Criteria_Map__c);
    }

    /** Builds an audit with result rows the way the writer would, before any callout in the test. */
    private static Id seedAudit(List<Contact> cs) {
        CandidateSearchTestMocks.partScores = new List<String>{ '1.0', '0.0', '1.0', '1.0' };
        TkSearchClient.Result r = TkSearchClient.parseResponse(CandidateSearchTestMocks.searchResponse(false));
        r.method = 'search';
        SearchAuditService.AuditStart s = new SearchAuditService.AuditStart();
        s.criteriaJson = CandidateSearchTestMocks.criteriaJson();
        Search_Audit__c a = SearchAuditService.newAudit(s, r, 'Success', null);
        insert a;
        List<String> ids = CriteriaService.toQueryParts(CriteriaService.parse(s.criteriaJson)).auditCriteriaIds();
        insert SearchAuditService.resultRows(a.Id, r, ids, new Map<Id, PipelineStatusService.Flags>(), new Set<String>());
        insert new Task(WhoId = cs[0].Id, Subject = 'Call', Description = 'Has a forklift licence, happy to do nights.');
        return a.Id;
    }

    @isTest
    static void explainResultsWritesExplanations() {
        CandidateSearchTestMocks.usePrompts();
        List<Contact> cs = CandidateSearchTestMocks.contacts(2);
        Id auditId = seedAudit(cs);
        String d0 = CandidateSearchTestMocks.docIds[0];
        CandidateSearchTestMocks.toolInputs.put('explain_candidates', new List<String>{
            '{"explanations":[{"docId":"' + d0 + '","summary":"Warehouse operative in Dagenham with a forklift ticket.",'
            + '"criteria":[{"id":"c1","met":true,"evidence":"Warehouse Operative","source":"Profile title"},'
            + '{"id":"c2","met":true,"evidence":"Has a forklift licence","source":"Call"}]}]}'
        });
        CandidateSearchTestMocks.install();

        Test.startTest();
        List<Object> out = (List<Object>) System.JSON.deserializeUntyped(
            CandidateSearchController.explainResults(auditId, System.JSON.serialize(CandidateSearchTestMocks.docIds))
        );
        Test.stopTest();

        System.assertEquals(1, out.size());
        Map<String, Object> e = (Map<String, Object>) out[0];
        // TK: c1 met, c2 not met (score 0), c3 met. The model's claim about c2 is overridden.
        for (Object o : (List<Object>) e.get('criteria')) {
            Map<String, Object> c = (Map<String, Object>) o;
            if (c.get('id') == 'c2') {
                System.assertEquals(false, c.get('met'));
                System.assertEquals(SearchAiService.NO_EVIDENCE, c.get('evidence'));
            }
        }
        Search_Audit_Result__c row = [SELECT AI_Explanation__c, AI_Evidence_JSON__c FROM Search_Audit_Result__c WHERE Audit_Doc_Key__c = :SearchAuditService.key(auditId, d0)];
        System.assertEquals('Warehouse operative in Dagenham with a forklift ticket.', row.AI_Explanation__c);

        // Only what the prompt needs was sent: no names, no emails
        String sent = CandidateSearchTestMocks.requests[0].getBody();
        System.assert(!sent.contains('Candidate0'), 'no candidate names are sent');
        System.assert(sent.contains('happy to do nights'), 'recent notes are sent as evidence');
    }

    @isTest
    static void explainResultsHandlesEmptyAndBadInput() {
        System.assertEquals('[]', CandidateSearchController.explainResults(UserInfo.getUserId(), '[]'));
        try {
            CandidateSearchController.explainResults(null, '[]');
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Run the search'));
        }
        try {
            CandidateSearchController.explainResults(UserInfo.getUserId(), '{bad');
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('JSON list'));
        }
    }

    @isTest
    static void secondPageAppendsToTheSameAudit() {
        List<Contact> cs = CandidateSearchTestMocks.contacts(2);
        Id auditId = seedAudit(new List<Contact>{ cs[0] });
        List<Contact> more = new List<Contact>{ new Contact(LastName = 'Page2') };
        insert more;
        CandidateSearchTestMocks.docIds = new List<String>{ CandidateSearchTestMocks.docIdFor(more[0].Id) };
        CandidateSearchTestMocks.install();

        Test.startTest();
        Map<String, Object> res = obj(CandidateSearchController.runSearch(CandidateSearchTestMocks.criteriaJson(), 20, auditId));
        Test.stopTest();

        System.assertEquals(auditId, (Id) res.get('auditId'));
        System.assertEquals(21, ((Map<String, Object>) ((List<Object>) res.get('rows'))[0]).get('rank'));
        System.assert(CandidateSearchTestMocks.requests[0].getBody().contains('<resultOffset>20</resultOffset>'));
        System.assert(CandidateSearchTestMocks.requests[0].getBody().contains('<query>city:Dagenham+15 -custom_date_1:&gt;=today-30</query>'),
            'location and the placed-recently exclusion go in the query string');
        Search_Audit_Result__c r = [SELECT Rank__c, Page_Offset__c FROM Search_Audit_Result__c WHERE Contact__c = :more[0].Id];
        System.assertEquals(21, r.Rank__c);
        System.assertEquals(20, r.Page_Offset__c);
        System.assertEquals(1, [SELECT COUNT() FROM Search_Audit__c]);
    }

    @isTest
    static void refineReturnsPatchedCriteriaWithARefineTrace() {
        CandidateSearchTestMocks.usePrompts();
        List<Contact> cs = CandidateSearchTestMocks.contacts(1);
        Id auditId = seedAudit(cs);
        CandidateSearchTestMocks.toolInputs.put('update_criteria', new List<String>{
            '{"patch":[{"op":"setExclusion","key":"placedWithinDays","value":30}],"reply":"Done. Anyone placed in the last 30 days is excluded.","needsClarification":false}'
        });
        CandidateSearchTestMocks.install();

        Test.startTest();
        Map<String, Object> res = obj(CandidateSearchController.refine(CandidateSearchTestMocks.criteriaJson(), 'drop anyone we placed in the last month', '[]', auditId));
        Test.stopTest();

        System.assertEquals('Done. Anyone placed in the last 30 days is excluded.', res.get('reply'));
        Map<String, Object> trace = (Map<String, Object>) ((Map<String, Object>) res.get('criteria')).get('trace');
        System.assertEquals('Refine', trace.get('searchType'));
        System.assertEquals(String.valueOf(auditId), trace.get('parentAuditId'));
        System.assertEquals(1, ((List<Object>) res.get('diff')).size());
        String sent = CandidateSearchTestMocks.requests[0].getBody();
        System.assert(sent.contains('ResultSummaryJson') && sent.contains('Test0 Candidate0'), 'questions about results are answered from the audit rows');
    }

    @isTest
    static void refineFailureIsReadable() {
        CandidateSearchTestMocks.usePrompts();
        CandidateSearchTestMocks.anthropicStatus = 500;
        CandidateSearchTestMocks.install();
        Test.startTest();
        try {
            CandidateSearchController.refine(CandidateSearchTestMocks.criteriaJson(), 'add nights', null, null);
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('edit the chips directly'), e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void parseQueryFallsBackToKeywordsWhenTheAiFails() {
        CandidateSearchTestMocks.usePrompts();
        CandidateSearchTestMocks.anthropicStatus = 500;
        CandidateSearchTestMocks.install();
        Test.startTest();
        Map<String, Object> criteria = obj(CandidateSearchController.parseQuery('reach truck drivers'));
        Test.stopTest();
        Map<String, Object> chip = (Map<String, Object>) ((List<Object>) criteria.get('items'))[0];
        System.assertEquals('keyword', chip.get('kind'));
        System.assertEquals('reach truck drivers', chip.get('value'));
        System.assert(((String) ((Map<String, Object>) criteria.get('trace')).get('aiError')).contains('plain keywords'));
    }

    @isTest
    static void textkernelFailureIsAuditedAndReturned() {
        CandidateSearchTestMocks.tkFault = true;
        CandidateSearchTestMocks.install();
        Test.startTest();
        Map<String, Object> res = obj(CandidateSearchController.runSearch(CandidateSearchTestMocks.criteriaJson(), 0, null));
        Test.stopTest();
        System.assert(((String) res.get('error')).contains('Document not found'));
        Id auditId = (Id) res.get('auditId');
        Search_Audit__c a = [SELECT Status__c, Error__c FROM Search_Audit__c WHERE Id = :auditId];
        System.assertEquals('TK error', a.Status__c);
    }

    @isTest
    static void resultsFromAnotherOrgAreHiddenAndNeverLinked() {
        List<Contact> cs = CandidateSearchTestMocks.contacts(1);
        CandidateSearchTestMocks.docIds.add('00Dfo000004ft2e_003fo000005QaEkAAK');
        CandidateSearchTestMocks.install();
        Test.startTest();
        Map<String, Object> res = obj(CandidateSearchController.runSearch(CandidateSearchTestMocks.criteriaJson(), 0, null));
        Test.stopTest();
        System.assertEquals(1, ((List<Object>) res.get('rows')).size());
        System.assert(String.valueOf(res.get('notices')).contains('another Salesforce org'), String.valueOf(res.get('notices')));
        Id auditId = (Id) res.get('auditId');
        System.assertEquals('Success', [SELECT Status__c FROM Search_Audit__c WHERE Id = :auditId].Status__c, 'no failed lookups');
        System.assertEquals(2, [SELECT COUNT() FROM Search_Audit_Result__c WHERE Search_Audit__c = :auditId], 'both still audited');
    }

    @isTest
    static void storedCriteriaFitTheField() {
        Map<String, Object> c = CriteriaService.parse(CandidateSearchTestMocks.criteriaJson());
        Map<String, Object> item = (Map<String, Object>) CriteriaService.items(c)[0];
        item.put('raw', new Map<String, Object>{ 'field' => 'jobtitles', 'xml' => 'x'.repeat(140000) });
        String stored = CandidateSearchController.storedCriteriaJson(c);
        System.assert(stored.length() <= SearchAuditService.LONG_TEXT_MAX);
        System.assert(stored.contains('"field":"jobtitles"'), 'chips and fields kept');
    }

    @isTest
    static void invalidCriteriaAreRejected() {
        try {
            CandidateSearchController.runSearch('{"version":1,"items":[]}', 0, null);
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('at least one criterion'), e.getMessage());
        }
    }

    // ─── Job match ───────────────────────────────────────────────

    /** TR1__Job__c belongs to the managed package; if its required fields stop a bare insert, the test says so. */
    private static Id insertJob() {
        SObject job = Schema.getGlobalDescribe().get('TR1__Job__c').newSObject();
        job.put('TR1__Job_Title__c', 'Warehouse Operative');
        job.put('TR1__City__c', 'Dagenham');
        insert job;
        return job.Id;
    }

    @isTest
    static void jobMatchUsesTheIndexedJobAndRefinesIt() {
        List<Contact> cs = CandidateSearchTestMocks.contacts(2);
        Id jobId = insertJob();
        CandidateSearchTestMocks.install();

        Test.startTest();
        Map<String, Object> res = obj(CandidateSearchController.startJobMatch(jobId));
        Test.stopTest();

        // searchWithUrl, then one search because the title was softened and the job location added
        System.assertEquals(2, CandidateSearchTestMocks.requests.size());
        System.assert(CandidateSearchTestMocks.requests[0].getBody().contains('<sear:searchWithUrl>'));
        Map<String, Object> criteria = (Map<String, Object>) res.get('criteria');
        List<Object> chips = (List<Object>) criteria.get('items');
        System.assertEquals('title', ((Map<String, Object>) chips[0]).get('kind'));
        System.assertEquals('strongly_preferred', ((Map<String, Object>) chips[0]).get('weight'));
        System.assertEquals('fingerprint', ((Map<String, Object>) chips[2]).get('kind'));
        System.assertEquals('location', ((Map<String, Object>) chips[3]).get('kind'));
        System.assertEquals(String.valueOf(jobId), criteria.get('jobId'));
        System.assert(String.valueOf(res.get('notices')).contains('Textkernel job document'));
        Id auditId = (Id) res.get('auditId');
        Search_Audit__c a = [SELECT Search_Type__c, Job__c FROM Search_Audit__c WHERE Id = :auditId];
        System.assertEquals('Job match', a.Search_Type__c);
        System.assertEquals(jobId, a.Job__c);
    }

    @isTest
    static void jobMatchFallsBackToTheJobRecord() {
        CandidateSearchTestMocks.contacts(1);
        Id jobId = insertJob();
        CandidateSearchTestMocks.searchWithUrlFault = true;
        CandidateSearchTestMocks.install();

        Test.startTest();
        Map<String, Object> res = obj(CandidateSearchController.startJobMatch(jobId));
        Test.stopTest();

        System.assertEquals(null, res.get('error'));
        System.assert(String.valueOf(res.get('notices')).contains('Built the search from the job record'), String.valueOf(res.get('notices')));
        List<Object> chips = (List<Object>) ((Map<String, Object>) res.get('criteria')).get('items');
        System.assertEquals('job', ((Map<String, Object>) chips[0]).get('origin'));
    }

    // ─── Saved searches, autocomplete, actions ───────────────────

    @isTest
    static void saveFavouriteAndList() {
        Id savedId = CandidateSearchController.saveSearch('Dagenham forklift', CandidateSearchTestMocks.criteriaJson(), false);
        CandidateSearchController.setFavourite(savedId, true);
        insert new Saved_Search__c(Name = 'recent one', Is_Saved__c = false, Last_Run__c = System.now());

        Map<String, Object> lists = obj(CandidateSearchController.getRecentAndSaved());
        System.assertEquals(1, ((List<Object>) lists.get('saved')).size());
        System.assertEquals(1, ((List<Object>) lists.get('favourites')).size());
        System.assertEquals(1, ((List<Object>) lists.get('recent')).size());

        try {
            CandidateSearchController.saveSearch(' ', CandidateSearchTestMocks.criteriaJson(), false);
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('name'));
        }
    }

    @isTest
    static void autocompleteNeedsTwoCharacters() {
        CandidateSearchTestMocks.install();
        System.assertEquals('[]', CandidateSearchController.autocompleteSkills('f'));
        Test.startTest();
        List<Object> skills = (List<Object>) System.JSON.deserializeUntyped(CandidateSearchController.autocompleteSkills('fork'));
        Test.stopTest();
        System.assertEquals('KS120076FGP5WGWYMP0F', ((Map<String, Object>) skills[0]).get('id'));
    }

    @isTest
    static void logActionRecordsAndRejectsUnknownActions() {
        List<Contact> cs = CandidateSearchTestMocks.contacts(1);
        Id auditId = seedAudit(cs);
        CandidateSearchController.logAction(auditId, CandidateSearchTestMocks.docIds[0], 'compared');
        System.assertEquals('Compared', [SELECT User_Action__c FROM Search_Audit_Result__c WHERE Contact__c = :cs[0].Id].User_Action__c);
        try {
            CandidateSearchController.logAction(auditId, CandidateSearchTestMocks.docIds[0], 'liked');
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Unknown action'));
        }
        CandidateSearchController.logAction(null, null, 'opened'); // ignored
    }

    @isTest
    static void searchRecordsOnlyAllowsJobsAndPools() {
        try {
            CandidateSearchController.searchRecords('Contact', 'a');
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('not available'), e.getMessage());
        }
        TR1__Call_List__c pool = new TR1__Call_List__c(Name = 'Forklift drivers pool');
        insert pool;
        List<Object> found = (List<Object>) System.JSON.deserializeUntyped(CandidateSearchController.searchRecords('TR1__Call_List__c', 'forklift'));
        System.assertEquals(1, found.size());
        System.assertEquals(pool.Id, ((Map<String, Object>) found[0]).get('id'));
        found = (List<Object>) System.JSON.deserializeUntyped(CandidateSearchController.searchRecords('TR1__Call_List__c', pool.Id));
        System.assertEquals('Forklift drivers pool', ((Map<String, Object>) found[0]).get('name'));
    }

    @isTest
    static void cvComesFromTextkernelViewDocument() {
        CandidateSearchTestMocks.install();
        CandidateSearchTestMocks.viewDocumentHtml = '<div><p><b>Jane Doe</b></p><p>Certified Forklift Operator</p></div>';
        Test.startTest();
        Map<String, Object> res = (Map<String, Object>) System.JSON.deserializeUntyped(CandidateSearchController.getCandidateCv('00D000000000001_003000000000001AAA'));
        Test.stopTest();
        System.assert(String.valueOf(res.get('html')).contains('Certified Forklift Operator'));
        try {
            CandidateSearchController.getCandidateCv(' ');
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('no Textkernel document'));
        }
    }

    @isTest
    static void cvPickPrefersTheDefaultResume() {
        List<TR1__ContactDocument__c> docs = new List<TR1__ContactDocument__c>{
            new TR1__ContactDocument__c(Name = 'cover.pdf', TR1__Type__c = 'Other'),
            new TR1__ContactDocument__c(Name = 'cv-new.pdf', TR1__Type__c = 'Resume', TR1__isDefault__c = false),
            new TR1__ContactDocument__c(Name = 'cv-default.docx', TR1__Type__c = 'Resume', TR1__isDefault__c = true)
        };
        System.assertEquals('cv-default.docx', CandidateSearchController.pickCv(docs).Name);
        docs.remove(2);
        System.assertEquals('cv-new.pdf', CandidateSearchController.pickCv(docs).Name);
        System.assertEquals(null, CandidateSearchController.pickCv(new List<TR1__ContactDocument__c>()));
    }

    @isTest
    static void professionAndSkillSuggestionsComeFromTheTxOntology() {
        CandidateSearchTestMocks.install();
        Test.startTest();
        List<Object> profs = (List<Object>) System.JSON.deserializeUntyped(CandidateSearchController.suggestProfessions('forklift'));
        List<Object> fromProf = (List<Object>) System.JSON.deserializeUntyped(CandidateSearchController.suggestSkillsForProfession(2357));
        List<Object> similar = (List<Object>) System.JSON.deserializeUntyped(CandidateSearchController.suggestSimilarSkills('["KS120076FGP5WGWYMP0F"]'));
        Test.stopTest();
        System.assertEquals(2357, ((Map<String, Object>) profs[0]).get('codeId'));
        System.assertEquals('Forklift Truck Operation', ((Map<String, Object>) fromProf[0]).get('description'));
        System.assertEquals(2, similar.size());
        Map<String, Object> sent = (Map<String, Object>) System.JSON.deserializeUntyped(CandidateSearchTestMocks.requests[1].getBody());
        System.assertEquals(new List<Object>{ 2357 }, sent.get('ProfessionCodeIds'));
        System.assertEquals('[]', CandidateSearchController.suggestProfessions('f'));
        System.assertEquals('[]', CandidateSearchController.suggestSimilarSkills('[]'));
    }
}
