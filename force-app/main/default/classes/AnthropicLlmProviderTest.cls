@isTest
private class AnthropicLlmProviderTest {

    private static SearchAiService.LlmRequest request() {
        CandidateSearchTestMocks.usePrompts();
        SearchAiService.LlmRequest req = new SearchAiService.LlmRequest();
        req.prompt = CandidateSearchConfig.prompt(SearchAiService.PARSE_PROMPT);
        req.inputs.put('NaturalLanguage', 'forklift drivers');
        return req;
    }

    @isTest
    static void forcesTheToolAndReadsItsInput() {
        CandidateSearchTestMocks.toolInputs.put('set_criteria', new List<String>{ CandidateSearchTestMocks.PARSE_OUTPUT });
        CandidateSearchTestMocks.install();
        Test.startTest();
        SearchAiService.LlmResponse res = new AnthropicLlmProvider().call(request());
        Test.stopTest();

        HttpRequest req = CandidateSearchTestMocks.requests[0];
        System.assertEquals('callout:Anthropic_API/v1/messages', req.getEndpoint());
        System.assertEquals('2023-06-01', req.getHeader('anthropic-version'));
        System.assertEquals(null, req.getHeader('x-api-key'), 'the key comes from the External Credential');
        Map<String, Object> body = (Map<String, Object>) System.JSON.deserializeUntyped(req.getBody());
        System.assertEquals('claude-haiku-5-5', body.get('model'));
        Map<String, Object> choice = (Map<String, Object>) body.get('tool_choice');
        System.assertEquals('tool', choice.get('type'));
        System.assertEquals('set_criteria', choice.get('name'));
        String content = (String) ((Map<String, Object>) ((List<Object>) body.get('messages'))[0]).get('content');
        System.assert(content.contains('<NaturalLanguage>\nforklift drivers\n</NaturalLanguage>'), content);

        Map<String, Object> out = (Map<String, Object>) System.JSON.deserializeUntyped(res.outputJson);
        System.assertEquals(3, ((List<Object>) out.get('items')).size());
        System.assertEquals(120, res.inputTokens);
        System.assertEquals(45, res.outputTokens);
        System.assertEquals('tool_use', res.stopReason);
    }

    @isTest
    static void httpErrorsCarryTheApiMessage() {
        CandidateSearchTestMocks.anthropicStatus = 400;
        CandidateSearchTestMocks.install();
        Test.startTest();
        try {
            new AnthropicLlmProvider().call(request());
            System.assert(false, 'expected an error');
        } catch (SearchAiService.SearchAiException e) {
            System.assert(e.getMessage().contains('HTTP 400') && e.getMessage().contains('bad request'), e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void missingToolCallIsAnError() {
        Test.setMock(HttpCalloutMock.class, new TextOnly());
        Test.startTest();
        try {
            new AnthropicLlmProvider().call(request());
            System.assert(false, 'expected an error');
        } catch (SearchAiService.SearchAiException e) {
            System.assert(e.getMessage().contains('max tokens'), e.getMessage());
        }
        Test.stopTest();
    }

    private class TextOnly implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"content":[{"type":"text","text":"{"}],"stop_reason":"max_tokens","usage":{"input_tokens":1,"output_tokens":1}}');
            return res;
        }
    }
}
