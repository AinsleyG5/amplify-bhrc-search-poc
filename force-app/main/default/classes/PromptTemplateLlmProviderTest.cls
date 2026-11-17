@isTest
private class PromptTemplateLlmProviderTest {

    @isTest
    static void readsJsonFromTemplateText() {
        System.assertEquals('{"items":[]}', PromptTemplateLlmProvider.toJson('```json\n{"items":[]}\n```', 'set_criteria'));
        System.assertEquals('{"explanations":[{"docId":"d"}]}', PromptTemplateLlmProvider.toJson('[{"docId":"d"}]', 'explain_candidates'));
        System.assertEquals(null, PromptTemplateLlmProvider.toJson(' ', 'set_criteria'));
    }

    @isTest
    static void templateFailuresAreReadable() {
        CandidateSearchTestMocks.usePrompts();
        SearchAiService.LlmRequest req = new SearchAiService.LlmRequest();
        req.prompt = CandidateSearchConfig.prompt(SearchAiService.PARSE_PROMPT);
        req.inputs.put('NaturalLanguage', 'forklift drivers');
        try {
            // ConnectApi prompt templates are not available in Apex tests: the call fails and is reported readably
            new PromptTemplateLlmProvider().call(req);
        } catch (SearchAiService.SearchAiException e) {
            System.assert(e.getMessage().contains(SearchAiService.PARSE_PROMPT), e.getMessage());
        }
    }

    @isTest
    static void providerIsChosenByConfig() {
        CandidateSearchConfig cfg = new CandidateSearchConfig();
        cfg.llmProvider = 'PromptTemplate';
        CandidateSearchConfig.overrideForTest(cfg);
        System.assert(SearchAiService.provider() instanceof PromptTemplateLlmProvider);
        cfg.llmProvider = 'Anthropic';
        System.assert(SearchAiService.provider() instanceof AnthropicLlmProvider);
    }
}
