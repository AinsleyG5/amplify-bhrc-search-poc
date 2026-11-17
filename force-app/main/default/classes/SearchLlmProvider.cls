/**
 * SearchLlmProvider
 *
 * The one seam between Candidate Search and a language model. SearchAiService only talks to this interface.
 * Implementations: AnthropicLlmProvider (default) and PromptTemplateLlmProvider (Einstein prompt templates),
 * chosen by Candidate_Search_Config__mdt.LLM_Provider__c.
 *
 * Apex interfaces cannot hold inner classes, so the request and response types live in SearchAiService.
 * The provider returns the tool input (the structured output) as a JSON string; SearchAiService validates it.
 */
public interface SearchLlmProvider {
    SearchAiService.LlmResponse call(SearchAiService.LlmRequest req);
}
