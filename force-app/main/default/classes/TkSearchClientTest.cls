@isTest
private class TkSearchClientTest {

    private static List<TkSearchClient.QueryPart> parts() {
        CandidateSearchConfig cfg = new CandidateSearchConfig();
        cfg.tkExcludeCondition = 'EXCLUDED';
        CandidateSearchConfig.overrideForTest(cfg);
        return CriteriaService.toQueryParts(CriteriaService.parse(CandidateSearchTestMocks.criteriaJson())).parts;
    }

    @isTest
    static void searchSendsPagingFieldsAndCredentialMergeField() {
        CandidateSearchTestMocks.docIds = new List<String>{ '00DDp000001z8VW_003Dp00000F4iL5IAJ', '00DDp000001z8VW_003Dp00000F4iL6IAJ' };
        CandidateSearchTestMocks.total = 42;
        CandidateSearchTestMocks.hasMore = true;
        CandidateSearchTestMocks.install();

        TkSearchClient.SearchOptions opts = new TkSearchClient.SearchOptions();
        opts.offset = 20;
        opts.query = 'city:Dagenham+15';
        Test.startTest();
        TkSearchClient.Result r = TkSearchClient.search(parts(), opts);
        Test.stopTest();

        String body = CandidateSearchTestMocks.requests[0].getBody();
        System.assert(body.contains('<request><query>city:Dagenham+15</query><queryParts>'), body);
        System.assert(body.contains('<sear:search>'), body);
        System.assert(body.contains('<resultOffset>20</resultOffset>'), body);
        System.assert(body.contains('<pageSize>20</pageSize>'), body);
        System.assert(body.contains('<resultFields>jobtitles</resultFields>'), body);
        System.assert(body.contains('<synonymExpansionMode>QUERY_AND_QUERYPARTS</synonymExpansionMode>'), body);
        System.assert(body.contains('<password><![CDATA[{!$Credential.TK_Search_Service_Account.Password}]]></password>'), body);
        System.assertEquals('callout:TK_Candidate_Search', CandidateSearchTestMocks.requests[0].getEndpoint());

        System.assertEquals('search', r.method);
        System.assertEquals(42, r.total);
        System.assertEquals(true, r.hasMore);
        System.assertEquals(20, r.offset);
        System.assertEquals(2, r.hits.size());
        TkSearchClient.Hit h = r.hits[0];
        System.assertEquals('003Dp00000F4iL5IAJ', String.valueOf(h.contactId));
        System.assertEquals(0.98, h.score);
        System.assertEquals(98, h.scorePct.intValue());
        System.assertEquals(new List<Decimal>{ 1.0, 0.0 }, h.queryPartScores);
        System.assertEquals('Ethan Kirby', h.fields.get('fullname')[0]);
        System.assertEquals('GB London', h.fields.get('city')[0]);
        System.assertEquals('Certified Forklift Operator', h.fields.get('jobtitles')[0], 'tags stripped from field values');
        System.assertEquals(0, h.fields.get('profskills').size());
        System.assert(h.highlights.get('jobtitles')[0].contains('<b>Certified Forklift Operator</b>'), 'inline highlights kept');
        System.assert(!h.highlights.containsKey('city'));
        System.assertEquals(1, r.facets.size());
        System.assertEquals('candidate_status', r.facets[0].field);
        System.assertEquals(4, r.facets[0].values[0].count);

        // Masked for the request viewer and the audit
        System.assert(r.requestXml.contains('<password>(hidden)</password>'));
        System.assert(r.requestXml.contains('<environment>(hidden)</environment>'));

        // The trimmed item XML parses back for the explain prompt
        TkSearchClient.Hit again = TkSearchClient.parseHitXml(h.xml);
        System.assertEquals(h.docId, again.docId);
        System.assertEquals(h.queryPartScores, again.queryPartScores);
        System.assertEquals(1, again.highlights.get('jobtitles').size());
    }

    @isTest
    static void searchCapsTheResultWindow() {
        CandidateSearchTestMocks.install();
        TkSearchClient.SearchOptions opts = new TkSearchClient.SearchOptions();
        opts.offset = 9990;
        Test.startTest();
        TkSearchClient.Result r = TkSearchClient.search(parts(), opts);
        System.assertEquals(10, r.pageSize);
        opts.offset = 10000;
        try {
            TkSearchClient.search(parts(), opts);
            System.assert(false, 'expected the window error');
        } catch (TkSearchClient.TkException e) {
            System.assert(e.getMessage().contains('10000'));
        }
        Test.stopTest();
    }

    @isTest
    static void searchWithUrlReturnsTheGeneratedParts() {
        CandidateSearchTestMocks.docIds = new List<String>{ '00DDp000001z8VW_003Dp00000F4iL5IAJ' };
        CandidateSearchTestMocks.install();
        Id jobId = Id.valueOf(Schema.getGlobalDescribe().get('TR1__Job__c').getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        String url = TkSearchClient.jobDocUrl(jobId);
        TkSearchClient.Result r = TkSearchClient.searchWithUrl(url, null);
        Test.stopTest();

        System.assert(url.startsWith('doc://tksf_bh4sf_tso_vac/vacancies/' + UserInfo.getOrganizationId().left(15) + '_'), url);
        String body = CandidateSearchTestMocks.requests[0].getBody();
        System.assert(body.contains('<sear:searchWithUrl>'));
        System.assert(body.contains('<url>' + url + '</url>'));
        System.assert(r.requestXml.contains('<url>doc://(index)/'));
        System.assertEquals('searchWithUrl', r.method);
        System.assertEquals(5, r.queryParts.size());
        System.assertEquals('jobtitles', r.queryParts[0].field);
        System.assertEquals('REQUIRED', r.queryParts[0].condition);
        System.assertEquals('[Warehouse Operative]', r.queryParts[0].values[0]);
        System.assertEquals(0.5, r.queryParts[2].weight);
        System.assert(r.queryParts[0].xml.startsWith('<queryParts><field>jobtitles</field>'), r.queryParts[0].xml);
        System.assertEquals('Forklift Truck Operation', r.queryParts[1].synonyms[0], 'synonyms are read');
        System.assert(!r.queryParts[0].xml.contains('synonyms'), 'but not kept in the stored XML: ' + r.queryParts[0].xml);
        System.assertEquals('GB Dagenham+25@51.5397 0.1436', r.queryParts[3].values[0]);
    }

    @isTest
    static void faultsAndHttpErrorsBecomeReadableMessages() {
        CandidateSearchTestMocks.tkFault = true;
        CandidateSearchTestMocks.install();
        Test.startTest();
        try {
            TkSearchClient.search(parts(), null);
            System.assert(false, 'expected an error');
        } catch (TkSearchClient.TkException e) {
            System.assert(e.getMessage().contains('Document not found'), e.getMessage());
        }
        Test.stopTest();

        try {
            TkSearchClient.parseResponse(CandidateSearchTestMocks.fault('Bad environment'));
            System.assert(false, 'expected an error');
        } catch (TkSearchClient.TkException e) {
            System.assert(e.getMessage().contains('Bad environment'));
        }
        for (String bad : new List<String>{ '', 'not xml', '<a/>' }) {
            try {
                TkSearchClient.parseResponse(bad);
                System.assert(false, 'expected an error for ' + bad);
            } catch (TkSearchClient.TkException e) {
                System.assertNotEquals(null, e.getMessage());
            }
        }
        System.assertEquals(null, TkSearchClient.faultText(''));
    }

    @isTest
    static void aQueryStringAloneIsEnough() {
        CandidateSearchTestMocks.install();
        TkSearchClient.SearchOptions opts = new TkSearchClient.SearchOptions();
        opts.query = 'city:Dagenham+15';
        Test.startTest();
        TkSearchClient.search(null, opts);
        Test.stopTest();
        System.assert(CandidateSearchTestMocks.requests[0].getBody().contains('<query>city:Dagenham+15</query>'));
    }

    @isTest
    static void emptyPartsAreRejected() {
        try {
            TkSearchClient.search(new List<TkSearchClient.QueryPart>(), null);
            System.assert(false, 'expected an error');
        } catch (TkSearchClient.TkException e) {
            System.assert(e.getMessage().contains('nothing to search'));
        }
    }

    @isTest
    static void getMetadataReturnsTheRawResponse() {
        CandidateSearchTestMocks.install();
        Test.startTest();
        String xml = TkSearchClient.getMetadata(null);
        Test.stopTest();
        System.assert(xml.contains('jobtitles'));
        System.assert(CandidateSearchTestMocks.requests[0].getBody().contains('<sear:getMetadata>'));
    }

    @isTest
    static void contactIdFromDocId() {
        System.assertEquals('003Dp00000F4iL5IAJ', String.valueOf(TkSearchClient.contactIdFrom('00DDp000001z8VW_003Dp00000F4iL5IAJ')));
        System.assertEquals(null, TkSearchClient.contactIdFrom('00DDp000001z8VW_a1wDp000001g5BiIAI'));
        System.assertEquals(null, TkSearchClient.contactIdFrom(null));
        System.assertEquals(null, TkSearchClient.contactIdFrom('003-not-an-id'));
    }

    @isTest
    static void partXmlBuildsOrReusesXml() {
        TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
        p.field = 'FULLTEXT';
        p.condition = 'FAVORED';
        p.values.add('"R&D"');
        String xml = TkSearchClient.partXml(p);
        System.assertEquals('<queryParts><field>FULLTEXT</field><condition>FAVORED</condition><weight>1.0</weight><items><value>&quot;R&amp;D&quot;</value></items></queryParts>', xml);
        p.xml = '<queryParts>verbatim</queryParts>';
        System.assertEquals(p.xml, TkSearchClient.partXml(p));
    }

    @isTest
    static void httpErrorsSayWhatWasCalledAndWhatToCheck() {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(404);
        res.setStatus('Not Found');
        res.setBody('');
        String msg = TkSearchClient.httpErrorText('TK_Candidate_Search', res);
        System.assert(msg.startsWith('Textkernel returned HTTP 404 Not Found from the TK_Candidate_Search Named Credential (empty response body).'), msg);
        System.assert(msg.contains('TK_Agent_Search_Endpoint'), msg);

        res.setStatusCode(503);
        res.setStatus('Service Unavailable');
        res.setBody('<html><body><h1>ERR_DNS_FAIL</h1><p>Unable to resolve DNS</p></body></html>');
        msg = TkSearchClient.httpErrorText('TK_Candidate_Search', res);
        System.assert(msg.contains('ERR_DNS_FAIL Unable to resolve DNS'), msg);
        System.assert(!msg.contains('<'), msg);
    }
}
