/**
 * AnthropicLlmProvider
 *
 * Calls POST /v1/messages through the Anthropic_API Named Credential. Its External Credential adds the x-api-key
 * header, so no key is held in code or metadata. JSON output is produced with one forced tool per prompt: the
 * tool's input_schema is the output contract, and tool_choice {"type":"tool","name":...} makes the model call it.
 * The tool's input is read from the tool_use block, so there is no free-text JSON parsing.
 */
public with sharing class AnthropicLlmProvider implements SearchLlmProvider {

    public static final String API_VERSION = '2023-06-01';

    public SearchAiService.LlmResponse call(SearchAiService.LlmRequest req) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        CandidateSearchConfig.PromptConfig p = req.prompt;

        Map<String, Object> tool = new Map<String, Object>{
            'name' => p.toolName,
            'description' => p.toolDescription == null ? p.toolName : p.toolDescription,
            'input_schema' => System.JSON.deserializeUntyped(p.toolSchemaJson)
        };
        Map<String, Object> body = new Map<String, Object>{
            'model' => p.model,
            'max_tokens' => p.maxTokens,
            'system' => p.systemPrompt,
            'messages' => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => req.userContent() }
            },
            'tools' => new List<Object>{ tool },
            'tool_choice' => new Map<String, Object>{ 'type' => 'tool', 'name' => p.toolName }
        };

        HttpRequest http = new HttpRequest();
        http.setEndpoint('callout:' + cfg.anthropicNamedCredential + '/v1/messages');
        http.setMethod('POST');
        http.setHeader('Content-Type', 'application/json');
        http.setHeader('anthropic-version', API_VERSION);
        http.setTimeout(Math.min(120000, p.timeoutMs == null ? 30000 : p.timeoutMs));
        http.setBody(System.JSON.serialize(body));

        SearchAiService.LlmResponse out = new SearchAiService.LlmResponse();
        out.model = p.model;
        Long started = System.currentTimeMillis();
        HttpResponse res;
        try {
            res = new Http().send(http);
        } catch (CalloutException e) {
            throw new SearchAiService.SearchAiException('The AI service did not answer in time: ' + e.getMessage());
        }
        out.durationMs = System.currentTimeMillis() - started;

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) System.JSON.deserializeUntyped(res.getBody());
        } catch (Exception e) {
            throw new SearchAiService.SearchAiException('The AI service returned HTTP ' + res.getStatusCode() + ' with an unreadable body.');
        }

        if (res.getStatusCode() != 200) {
            String msg = null;
            if (parsed.get('error') instanceof Map<String, Object>) {
                msg = (String) ((Map<String, Object>) parsed.get('error')).get('message');
            }
            throw new SearchAiService.SearchAiException('The AI service returned HTTP ' + res.getStatusCode() + (msg == null ? '' : ': ' + msg));
        }

        if (parsed.get('usage') instanceof Map<String, Object>) {
            Map<String, Object> usage = (Map<String, Object>) parsed.get('usage');
            out.inputTokens = toInt(usage.get('input_tokens'));
            out.outputTokens = toInt(usage.get('output_tokens'));
        }
        if (parsed.get('model') != null) out.model = String.valueOf(parsed.get('model'));
        out.stopReason = (String) parsed.get('stop_reason');

        if (parsed.get('content') instanceof List<Object>) {
            for (Object block : (List<Object>) parsed.get('content')) {
                if (!(block instanceof Map<String, Object>)) continue;
                Map<String, Object> b = (Map<String, Object>) block;
                if (b.get('type') == 'tool_use' && b.get('name') == p.toolName) {
                    out.outputJson = System.JSON.serialize(b.get('input'));
                    break;
                }
            }
        }
        if (out.outputJson == null) {
            throw new SearchAiService.SearchAiException(out.stopReason == 'max_tokens'
                ? 'The AI answer was cut off (max tokens). Raise Max_Tokens__c on ' + p.name + '.'
                : 'The AI service did not return the ' + p.toolName + ' tool call.');
        }
        return out;
    }

    private static Integer toInt(Object v) {
        return v == null ? null : Integer.valueOf(String.valueOf(v));
    }
}
