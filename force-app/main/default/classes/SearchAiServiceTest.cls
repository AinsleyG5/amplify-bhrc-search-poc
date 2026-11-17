@isTest
private class SearchAiServiceTest {

    /** Answers with queued outputs, one per call. */
    private class FakeProvider implements SearchLlmProvider {
        List<String> outputs;
        public Integer calls = 0;
        public List<SearchAiService.LlmRequest> seen = new List<SearchAiService.LlmRequest>();
        public FakeProvider(List<String> outputs) {
            this.outputs = outputs;
        }
        public SearchAiService.LlmResponse call(SearchAiService.LlmRequest req) {
            seen.add(req);
            SearchAiService.LlmResponse r = new SearchAiService.LlmResponse();
            r.outputJson = outputs[Math.min(calls, outputs.size() - 1)];
            r.model = req.prompt.model;
            r.inputTokens = 100;
            r.outputTokens = 20;
            r.durationMs = 5;
            calls++;
            return r;
        }
    }

    private static FakeProvider use(List<String> outputs) {
        CandidateSearchTestMocks.usePrompts();
        FakeProvider p = new FakeProvider(outputs);
        SearchAiService.providerOverride = p;
        return p;
    }

    // ─── parse ───────────────────────────────────────────────────

    @isTest
    static void parseBuildsValidatedCriteria() {
        FakeProvider p = use(new List<String>{ CandidateSearchTestMocks.PARSE_OUTPUT });
        SearchAiService.ParseOutcome out = SearchAiService.parse('Forklift-certified warehouse operatives near Dagenham, available only');

        List<Object> chips = CriteriaService.items(out.criteria);
        System.assertEquals(3, chips.size());
        Map<String, Object> loc = (Map<String, Object>) chips[2];
        System.assertEquals('c3', loc.get('id'));
        System.assertEquals('nl', loc.get('origin'));
        System.assertEquals(15, loc.get('radius'), 'default radius filled in');
        System.assertEquals('nl', out.criteria.get('source'));
        System.assertEquals(1, out.usage.attempts);
        System.assertEquals(CandidateSearchTestMocks.PARSE_OUTPUT, out.usage.proposedJson);
        System.assert(p.seen[0].userContent().contains('<DefaultRadiusMiles>\n15\n</DefaultRadiusMiles>'));
    }

    @isTest
    static void parseRetriesOnceWithTheValidationError() {
        FakeProvider p = use(new List<String>{ '{"items":[{"kind":"colour","label":"x","value":"x","weight":"required"}]}', CandidateSearchTestMocks.PARSE_OUTPUT });
        SearchAiService.ParseOutcome out = SearchAiService.parse('warehouse operatives');
        System.assertEquals(2, p.calls);
        System.assert(p.seen[1].correction.contains('Unknown criterion type'), p.seen[1].correction);
        System.assertEquals(2, out.usage.attempts);
        System.assertEquals(200, out.usage.inputTokens);
    }

    @isTest
    static void parseFailsReadablyAfterTwoBadAnswers() {
        use(new List<String>{ 'not json' });
        try {
            SearchAiService.parse('warehouse operatives');
            System.assert(false, 'expected an error');
        } catch (SearchAiService.SearchAiException e) {
            System.assert(e.getMessage().contains('could not be used'), e.getMessage());
        }
        use(new List<String>{ '{"items":[{"kind":"fingerprint","label":"x","value":"x","weight":"required"}]}' });
        try {
            SearchAiService.parse('warehouse operatives');
            System.assert(false, 'expected an error');
        } catch (SearchAiService.SearchAiException e) {
            System.assert(e.getMessage().contains('cannot be produced'), e.getMessage());
        }
        try {
            SearchAiService.parse(' ');
            System.assert(false, 'expected an error');
        } catch (SearchAiService.SearchAiException e) {
            System.assertNotEquals(null, e.getMessage());
        }
    }

    // ─── refine ──────────────────────────────────────────────────

    @isTest
    static void refineAppliesThePatch() {
        FakeProvider p = use(new List<String>{
            '{"patch":[{"op":"add","item":{"kind":"shift","label":"Nights","value":"nights","weight":"preferred"}},'
            + '{"op":"update","id":"c3","set":{"radius":25}}],"reply":"Done.","needsClarification":false}'
        });
        Map<String, Object> criteria = CriteriaService.parse(CandidateSearchTestMocks.criteriaJson());
        criteria.put('trace', new Map<String, Object>{ 'x' => 1 });
        SearchAiService.RefineOutcome out = SearchAiService.refine(criteria, 'add nights, widen to 25 miles', '[{"role":"user","text":"hi"}]', null);

        System.assertEquals('Done.', out.reply);
        System.assertEquals(2, out.diff.size());
        System.assertEquals(4, CriteriaService.items(out.criteria).size());
        System.assertEquals('Dagenham + 25 mi', CriteriaService.findItem(out.criteria, 'c3').get('label'));
        String sent = p.seen[0].inputs.get('CriteriaJson');
        System.assert(!sent.contains('"trace"'), sent);
    }

    @isTest
    static void refineQuestionsAndClarificationsChangeNothing() {
        use(new List<String>{ '{"patch":[{"op":"remove","id":"c1"}],"reply":"Which location?","needsClarification":true}' });
        Map<String, Object> criteria = CriteriaService.parse(CandidateSearchTestMocks.criteriaJson());
        SearchAiService.RefineOutcome out = SearchAiService.refine(criteria, 'make it wider', null, '[]');
        System.assert(out.needsClarification);
        System.assertEquals(0, out.patch.size());
        System.assertEquals(3, CriteriaService.items(out.criteria).size());
    }

    @isTest
    static void refineRetriesAPatchWithAnUnknownId() {
        FakeProvider p = use(new List<String>{
            '{"patch":[{"op":"remove","id":"c9"}],"reply":"Removed.","needsClarification":false}',
            '{"patch":[{"op":"remove","id":"c2"}],"reply":"Removed.","needsClarification":false}'
        });
        SearchAiService.RefineOutcome out = SearchAiService.refine(CriteriaService.parse(CandidateSearchTestMocks.criteriaJson()), 'drop the forklift ticket', null, null);
        System.assertEquals(2, p.calls);
        System.assertEquals(2, CriteriaService.items(out.criteria).size());
    }

    @isTest
    static void promptCriteriaDropsRawXml() {
        Map<String, Object> c = CriteriaService.newCriteria('job');
        Map<String, Object> item = new Map<String, Object>{ 'id' => 'c1', 'kind' => 'tk_raw', 'raw' => new Map<String, Object>{ 'xml' => '<x/>' }, 'rawSignature' => 's' };
        CriteriaService.items(c).add(item);
        Map<String, Object> copy = SearchAiService.promptCriteria(c);
        System.assert(!((Map<String, Object>) CriteriaService.items(copy)[0]).containsKey('raw'));
        System.assert(item.containsKey('raw'), 'the original is untouched');
    }

    // ─── explain ─────────────────────────────────────────────────

    private static SearchAiService.ExplainCandidate candidate(String docId) {
        SearchAiService.ExplainCandidate c = new SearchAiService.ExplainCandidate();
        c.docId = docId;
        c.score = 98;
        c.met = new List<String>{ 'c1', 'c3' };
        c.notMet = new List<String>{ 'c2' };
        c.highlights.add('Certified Forklift Operator');
        return c;
    }

    @isTest
    static void explainIsForcedToAgreeWithTextkernel() {
        String longSummary = 'word '.repeat(40).trim();
        use(new List<String>{ '{"explanations":['
            + '{"docId":"d1","summary":"' + longSummary + '","criteria":['
            +   '{"id":"c1","met":false,"evidence":"Warehouse Operative","source":"Profile title"},'
            +   '{"id":"c2","met":true,"evidence":"Certified Forklift Operator","source":"Highlight"}]},'
            + '{"docId":"unknown","summary":"x","criteria":[]}'
            + ']}' });
        Map<String, Object> criteria = CriteriaService.parse(CandidateSearchTestMocks.criteriaJson());
        SearchAiService.ExplainOutcome out = SearchAiService.explain(criteria, new List<SearchAiService.ExplainCandidate>{ candidate('d1'), candidate('d2') });

        System.assertEquals(1, out.explanations.size(), 'unknown docIds dropped, missing ones left out');
        Map<String, Object> e = out.explanations[0];
        System.assertEquals('d1', e.get('docId'));
        System.assert(((String) e.get('summary')).split(' ').size() <= SearchAiService.MAX_SUMMARY_WORDS);
        System.assertEquals(true, e.get('correctedByTk'));

        Map<String, Map<String, Object>> byId = new Map<String, Map<String, Object>>();
        for (Object o : (List<Object>) e.get('criteria')) byId.put((String) ((Map<String, Object>) o).get('id'), (Map<String, Object>) o);
        System.assertEquals(true, byId.get('c1').get('met'), 'TK said met');
        System.assertEquals('Warehouse Operative', byId.get('c1').get('evidence'));
        System.assertEquals(false, byId.get('c2').get('met'), 'TK said not met');
        System.assertEquals(SearchAiService.NO_EVIDENCE, byId.get('c2').get('evidence'));
        System.assertEquals(SearchAiService.NO_EVIDENCE, byId.get('c3').get('evidence'), 'no evidence given');
    }

    @isTest
    static void explainLimitsTheBatch() {
        use(new List<String>{ '{"explanations":[]}' });
        List<SearchAiService.ExplainCandidate> many = new List<SearchAiService.ExplainCandidate>();
        for (Integer i = 0; i < 11; i++) many.add(candidate('d' + i));
        try {
            SearchAiService.explain(CriteriaService.newCriteria('nl'), many);
            System.assert(false, 'expected an error');
        } catch (SearchAiService.SearchAiException e) {
            System.assert(e.getMessage().contains('at most 10'));
        }
        System.assertEquals(0, SearchAiService.explain(CriteriaService.newCriteria('nl'), null).explanations.size());
    }

    @isTest
    static void explainWithNoMatchingDocIdsFails() {
        use(new List<String>{ '{"explanations":[{"docId":"nope","summary":"x","criteria":[]}]}' });
        try {
            SearchAiService.explain(CriteriaService.newCriteria('nl'), new List<SearchAiService.ExplainCandidate>{ candidate('d1') });
            System.assert(false, 'expected an error');
        } catch (SearchAiService.SearchAiException e) {
            System.assert(e.getMessage().contains('No explanation matched'), e.getMessage());
        }
    }
}
