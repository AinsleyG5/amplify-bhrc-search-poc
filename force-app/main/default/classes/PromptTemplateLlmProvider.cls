/**
 * PromptTemplateLlmProvider
 *
 * Keeps the Einstein path available behind the same interface: same inputs, sent as template inputs
 * (Input:NaturalLanguage, Input:CriteriaJson, ...) to the prompt template named in
 * Candidate_Search_Prompt__mdt.Prompt_Template_Name__c, through
 * ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate (same pattern as EnrichmentSkillPromptService).
 *
 * Prompt templates return text, so the answer is read as JSON. The template must ask for the same JSON as the
 * tool schema. For the explain prompt a bare array is accepted and wrapped as {"explanations": [...]}.
 */
public with sharing class PromptTemplateLlmProvider implements SearchLlmProvider {

    public SearchAiService.LlmResponse call(SearchAiService.LlmRequest req) {
        Map<String, ConnectApi.WrappedValue> inputs = new Map<String, ConnectApi.WrappedValue>();
        for (String key : req.inputs.keySet()) {
            ConnectApi.WrappedValue w = new ConnectApi.WrappedValue();
            w.value = req.inputs.get(key);
            inputs.put('Input:' + key, w);
        }

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.isPreview = false;
        input.inputParams = inputs;

        SearchAiService.LlmResponse out = new SearchAiService.LlmResponse();
        out.model = 'PromptTemplate:' + req.prompt.templateName;
        Long started = System.currentTimeMillis();
        String text;
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation gen =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(req.prompt.templateName, input);
            if (gen == null || gen.generations == null || gen.generations.isEmpty()) {
                throw new SearchAiService.SearchAiException('Prompt template ' + req.prompt.templateName + ' returned nothing.');
            }
            text = gen.generations[0].text;
        } catch (SearchAiService.SearchAiException e) {
            throw e;
        } catch (Exception e) {
            throw new SearchAiService.SearchAiException('Prompt template ' + req.prompt.templateName + ' failed: ' + e.getMessage());
        }
        out.durationMs = System.currentTimeMillis() - started;
        out.outputJson = toJson(text, req.prompt.toolName);
        return out;
    }

    @TestVisible
    private static String toJson(String text, String toolName) {
        if (String.isBlank(text)) return null;
        String t = text.trim().removeStart('```json').removeStart('```').removeEnd('```').trim();
        if (t.startsWith('[') && toolName == 'explain_candidates') t = '{"explanations":' + t + '}';
        return t;
    }
}
