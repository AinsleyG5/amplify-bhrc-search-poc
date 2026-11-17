@isTest
private class SearchAuditServiceTest {

    private static TkSearchClient.Result result(List<String> docIds) {
        CandidateSearchTestMocks.docIds = docIds;
        return TkSearchClient.parseResponse(CandidateSearchTestMocks.searchResponse(false));
    }

    private static Search_Audit__c insertAudit() {
        SearchAuditService.AuditStart s = new SearchAuditService.AuditStart();
        s.searchType = 'Natural language';
        s.naturalLanguage = 'forklift drivers';
        s.criteriaJson = CandidateSearchTestMocks.criteriaJson();
        s.aiInputTokens = 10;
        TkSearchClient.Result r = result(new List<String>());
        r.method = 'search';
        r.requestXml = '<request/>';
        Search_Audit__c a = SearchAuditService.newAudit(s, r, 'Success', null);
        insert a;
        return a;
    }

    @isTest
    static void writerStoresOneRowPerCandidateAndLogsTheRecentSearch() {
        List<Contact> cs = CandidateSearchTestMocks.contacts(2);
        Search_Audit__c a = insertAudit();
        TkSearchClient.Result r = result(CandidateSearchTestMocks.docIds);

        Map<Id, PipelineStatusService.Flags> flags = new Map<Id, PipelineStatusService.Flags>();
        PipelineStatusService.Flags f = new PipelineStatusService.Flags();
        f.applied = true;
        f.stage = 'Interview';
        flags.put(cs[0].Id, f);

        SearchAuditWriter w = new SearchAuditWriter();
        w.auditId = a.Id;
        w.rows = SearchAuditService.resultRows(a.Id, r, new List<String>{ 'c1', 'c2' }, flags, new Set<String>{ CandidateSearchTestMocks.docIds[0] });
        w.rawResponse = 'x'.repeat(SearchAuditWriter.LONG_TEXT_MAX + 1);
        w.recent = new SearchAuditWriter.RecentSearch();
        w.recent.name = 'forklift drivers';
        w.recent.criteriaJson = CandidateSearchTestMocks.criteriaJson();
        w.recent.criteriaHash = 'abc';

        Test.startTest();
        System.enqueueJob(w);
        Test.stopTest();

        List<Search_Audit_Result__c> rows = [
            SELECT Rank__c, Contact__c, TK_Score_Pct__c, TK_Query_Part_Scores__c, TK_Criteria_Map__c, Pipeline_Flags__c, Hidden_By_Exclusion__c, TK_Result_XML__c
            FROM Search_Audit_Result__c WHERE Search_Audit__c = :a.Id ORDER BY Rank__c
        ];
        System.assertEquals(2, rows.size());
        System.assertEquals(1, rows[0].Rank__c);
        System.assertEquals(cs[0].Id, rows[0].Contact__c);
        System.assertEquals('1,0', rows[0].TK_Query_Part_Scores__c);
        System.assertEquals('c1,c2', rows[0].TK_Criteria_Map__c);
        System.assertEquals('Applied (Interview)', rows[0].Pipeline_Flags__c);
        System.assert(rows[0].Hidden_By_Exclusion__c);
        System.assert(!rows[1].Hidden_By_Exclusion__c);
        System.assert(rows[0].TK_Result_XML__c.startsWith('<resultItems>'));

        Search_Audit__c after = [SELECT Status__c, Saved_Search__c, TK_Raw_Response_File__c, Pages_Loaded__c FROM Search_Audit__c WHERE Id = :a.Id];
        System.assertEquals('Success', after.Status__c);
        System.assertEquals(1, after.Pages_Loaded__c);
        System.assertNotEquals(null, after.Saved_Search__c);
        System.assertNotEquals(null, after.TK_Raw_Response_File__c);
        Saved_Search__c recent = [SELECT Name, Is_Saved__c, Run_Count__c FROM Saved_Search__c WHERE Id = :after.Saved_Search__c];
        System.assertEquals(false, recent.Is_Saved__c);
        System.assertEquals(1, recent.Run_Count__c);
    }

    @isTest
    static void laterPagesAppendTheRequestAndRepeatsMergeTheRecentSearch() {
        Search_Audit__c a = insertAudit();
        SearchAuditWriter w = new SearchAuditWriter();
        w.auditId = a.Id;
        w.firstPage = false;
        w.appendRequestXml = '<page2/>';
        w.run();
        System.assert([SELECT TK_Request_XML__c FROM Search_Audit__c WHERE Id = :a.Id].TK_Request_XML__c.endsWith('<page2/>'));

        SearchAuditWriter.RecentSearch r = new SearchAuditWriter.RecentSearch();
        r.name = 'same';
        r.criteriaHash = 'h1';
        Id first = SearchAuditWriter.logRecent(r);
        Id second = SearchAuditWriter.logRecent(r);
        System.assertEquals(first, second);
        System.assertEquals(2, [SELECT Run_Count__c FROM Saved_Search__c WHERE Id = :first].Run_Count__c);
    }

    @isTest
    static void recentSearchesArePruned() {
        CandidateSearchConfig cfg = new CandidateSearchConfig();
        cfg.recentSearchesKept = 2;
        CandidateSearchConfig.overrideForTest(cfg);
        for (Integer i = 0; i < 4; i++) {
            SearchAuditWriter.RecentSearch r = new SearchAuditWriter.RecentSearch();
            r.name = 'search ' + i;
            r.criteriaHash = 'h' + i;
            SearchAuditWriter.logRecent(r);
        }
        System.assertEquals(2, [SELECT COUNT() FROM Saved_Search__c WHERE Is_Saved__c = false]);
    }

    @isTest
    static void rowFailuresMarkTheAuditInsteadOfFailing() {
        Search_Audit__c a = insertAudit();
        SearchAuditWriter w = new SearchAuditWriter();
        w.auditId = a.Id;
        // Contact__c that does not exist: the row fails, the audit records why
        w.rows.add(new Search_Audit_Result__c(Search_Audit__c = a.Id, Audit_Doc_Key__c = a.Id + '_x', TK_Doc_Id__c = 'x',
            Contact__c = Id.valueOf('003000000000000AAA')));
        w.run();
        Search_Audit__c after = [SELECT Status__c, Error__c FROM Search_Audit__c WHERE Id = :a.Id];
        System.assertEquals('Audit error', after.Status__c);
        System.assert(after.Error__c.startsWith('x: '), after.Error__c);
    }

    @isTest
    static void explanationsAndActionsLandOnTheRows() {
        List<Contact> cs = CandidateSearchTestMocks.contacts(1);
        Search_Audit__c a = insertAudit();
        String docId = CandidateSearchTestMocks.docIds[0];

        // An action before the Queueable has written the row creates it
        SearchAuditService.logAction(a.Id, docId, 'opened');
        SearchAuditService.logAction(a.Id, docId, 'Shortlisted');

        SearchAiService.Usage u = new SearchAiService.Usage();
        u.model = 'claude-sonnet-5-5';
        u.inputTokens = 300;
        u.outputTokens = 90;
        u.durationMs = 1200;
        SearchAuditService.recordExplanations(a.Id, new List<Map<String, Object>>{
            new Map<String, Object>{ 'docId' => docId, 'summary' => 'Certified forklift operator in Dagenham.', 'criteria' => new List<Object>() }
        }, u);

        Search_Audit_Result__c row = [SELECT Contact__c, User_Action__c, AI_Explanation__c, AI_Explained_At__c FROM Search_Audit_Result__c WHERE Search_Audit__c = :a.Id];
        System.assertEquals(cs[0].Id, row.Contact__c);
        System.assert(row.User_Action__c.contains('Opened') && row.User_Action__c.contains('Shortlisted'), row.User_Action__c);
        System.assertEquals('Certified forklift operator in Dagenham.', row.AI_Explanation__c);
        System.assertNotEquals(null, row.AI_Explained_At__c);
        Search_Audit__c after = [SELECT Explain_Input_Tokens__c, Explain_Model__c FROM Search_Audit__c WHERE Id = :a.Id];
        System.assertEquals(300, after.Explain_Input_Tokens__c);
        System.assertEquals('claude-sonnet-5-5', after.Explain_Model__c);

        try {
            SearchAuditService.logAction(a.Id, docId, 'liked');
            System.assert(false, 'expected an error');
        } catch (SearchAuditService.SearchAuditException e) {
            System.assert(e.getMessage().contains('Unknown action'));
        }
    }

    @isTest
    static void metAndNotMetGroupsPartsByChip() {
        Map<String, List<String>> m = SearchAuditService.metAndNotMet('1,0,0,1,1', 'c1,c2,c2,filter:candidate_status,c3');
        System.assertEquals(new List<String>{ 'c1', 'c3' }, m.get('met'));
        System.assertEquals(new List<String>{ 'c2' }, m.get('notMet'));
        m = SearchAuditService.metAndNotMet('0,0.4', 'c1,c1');
        System.assertEquals(new List<String>{ 'c1' }, m.get('met'), 'a chip is met when any of its parts scored');
        System.assertEquals(0, SearchAuditService.metAndNotMet(null, null).get('met').size());
        System.assertEquals('1,0.5,0', SearchAuditService.joinScores(new List<Decimal>{ 1.0, 0.50, null }));
    }

    @isTest
    static void recordErrorSetsStatus() {
        Search_Audit__c a = insertAudit();
        SearchAuditService.recordError(a.Id, 'TK error', 'boom');
        System.assertEquals('TK error', [SELECT Status__c FROM Search_Audit__c WHERE Id = :a.Id].Status__c);
    }
}
