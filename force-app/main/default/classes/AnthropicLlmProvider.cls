/**
 * AnthropicLlmProvider
 *
 * Calls POST /v1/messages through the Anthropic_API Named Credential. Its External Credential adds the x-api-key
 * header, so no key is held in code or metadata.
 *
 * JSON output uses structured outputs: output_config.format = { type: "json_schema", schema } constrains the reply
 * to the prompt's schema (Tool_Schema_JSON__c), and the JSON is read from the text block. Forced tool_choice is not
 * used: Claude Sonnet 5.5, Opus 5.5 and Fable 5.1/5.2 return a 400 for tool_choice "tool" / "any".
 *
 * Structured outputs require additionalProperties:false on every object and do not accept length, numeric or
 * array-size limits, so sanitizeSchema() adapts the stored schema before sending. SearchAiService still validates
 * every answer against the contract (max items, label lengths and so on).
 *
 * Thinking is always on for the current models and its tokens count against max_tokens, so Max_Tokens__c must
 * leave room for it. Effort__c (output_config.effort) trades depth for latency per prompt.
 */
public with sharing class AnthropicLlmProvider implements SearchLlmProvider {

    public static final String API_VERSION = '2023-06-01';

    /** JSON Schema keywords structured outputs do not support. They are enforced in Apex instead. */
    private static final Set<String> UNSUPPORTED_KEYWORDS = new Set<String>{
        'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf',
        'minLength', 'maxLength', 'pattern', 'minItems', 'maxItems', 'uniqueItems',
        'minProperties', 'maxProperties'
    };

    public SearchAiService.LlmResponse call(SearchAiService.LlmRequest req) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        CandidateSearchConfig.PromptConfig p = req.prompt;

        Map<String, Object> outputConfig = new Map<String, Object>{
            'format' => new Map<String, Object>{
                'type' => 'json_schema',
                'schema' => sanitizeSchema(System.JSON.deserializeUntyped(p.toolSchemaJson))
            }
        };
        if (String.isNotBlank(p.effort)) outputConfig.put('effort', p.effort.trim().toLowerCase());

        Map<String, Object> body = new Map<String, Object>{
            'model' => p.model,
            'max_tokens' => p.maxTokens,
            'system' => p.systemPrompt,
            'messages' => new List<Object>{
                new Map<String, Object>{ 'role' => 'user', 'content' => req.userContent() }
            },
            'output_config' => outputConfig
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

        if (out.stopReason == 'refusal') {
            String category = null;
            if (parsed.get('stop_details') instanceof Map<String, Object>) {
                category = (String) ((Map<String, Object>) parsed.get('stop_details')).get('category');
            }
            throw new SearchAiService.SearchAiException('The AI service declined this request' + (category == null ? '.' : ' (' + category + ').'));
        }
        if (out.stopReason == 'max_tokens') {
            throw new SearchAiService.SearchAiException('The AI answer was cut off (max tokens). Raise Max_Tokens__c on ' + p.name + '.');
        }

        // Thinking blocks come first; the JSON answer is the text block
        if (parsed.get('content') instanceof List<Object>) {
            for (Object block : (List<Object>) parsed.get('content')) {
                if (!(block instanceof Map<String, Object>)) continue;
                Map<String, Object> b = (Map<String, Object>) block;
                if (b.get('type') == 'text' && b.get('text') != null) {
                    out.outputJson = String.valueOf(b.get('text'));
                    break;
                }
            }
        }
        if (String.isBlank(out.outputJson)) {
            throw new SearchAiService.SearchAiException('The AI service returned no answer for ' + p.name + '.');
        }
        return out;
    }

    /**
     * Adapts a stored JSON Schema for structured outputs: every object gets additionalProperties:false, unsupported
     * keywords are dropped, and a property with no type (refine's setExclusion value) becomes integer | boolean | null.
     */
    @TestVisible
    private static Object sanitizeSchema(Object node) {
        if (node instanceof List<Object>) {
            List<Object> out = new List<Object>();
            for (Object o : (List<Object>) node) out.add(sanitizeSchema(o));
            return out;
        }
        if (!(node instanceof Map<String, Object>)) return node;

        Map<String, Object> m = (Map<String, Object>) node;
        Map<String, Object> out = new Map<String, Object>();
        for (String key : m.keySet()) {
            if (UNSUPPORTED_KEYWORDS.contains(key)) continue;
            Object v = m.get(key);
            if (key == 'properties' && v instanceof Map<String, Object>) {
                Map<String, Object> props = new Map<String, Object>();
                Map<String, Object> source = (Map<String, Object>) v;
                for (String prop : source.keySet()) props.put(prop, untypedToAny(sanitizeSchema(source.get(prop))));
                out.put(key, props);
            } else {
                out.put(key, sanitizeSchema(v));
            }
        }
        if (out.get('type') == 'object' || out.containsKey('properties')) {
            out.put('additionalProperties', false);
        }
        return out;
    }

    private static Object untypedToAny(Object schema) {
        if (!(schema instanceof Map<String, Object>)) return schema;
        Map<String, Object> m = (Map<String, Object>) schema;
        if (m.containsKey('type') || m.containsKey('anyOf') || m.containsKey('enum') || m.containsKey('const') || m.containsKey('$ref')) {
            return m;
        }
        m.put('anyOf', new List<Object>{
            new Map<String, Object>{ 'type' => 'integer' },
            new Map<String, Object>{ 'type' => 'boolean' },
            new Map<String, Object>{ 'type' => 'null' }
        });
        return m;
    }

    private static Integer toInt(Object v) {
        return v == null ? null : Integer.valueOf(String.valueOf(v));
    }
}
