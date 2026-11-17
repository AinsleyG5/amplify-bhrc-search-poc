public with sharing class EnrichmentSkillPromptService {

    private static final String TEMPLATE_API_NAME   = 'Bullhorn_ExecSearch_Suggested_Records_and_Updates';
    private static final String TEMPLATE_INPUT_NAME = 'TranscriptText';

    /**
     * Name of the prompt template input that receives the record name (the LWC sends it as enrichmentSubject).
     * Leave null if the template only has the TranscriptText input. Set it to the input's name, for example
     * 'EnrichmentSubject', once the template defines one. Passing an input the template does not declare fails the call.
     */
    private static final String TEMPLATE_SUBJECT_INPUT = null;

    @AuraEnabled
    public static String analyzeTranscript(String transcriptText, String enrichmentSubject) {

        if (String.isBlank(transcriptText)) {
            throw fail('TranscriptText is required.');
        }

        // ---- Build Input Parameters ----
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:' + TEMPLATE_INPUT_NAME, wrap(transcriptText));

        if (String.isNotBlank(TEMPLATE_SUBJECT_INPUT) && String.isNotBlank(enrichmentSubject)) {
            inputParams.put('Input:' + TEMPLATE_SUBJECT_INPUT, wrap(enrichmentSubject));
        }

        // ---- Configure Invocation ----
        ConnectApi.EinsteinPromptTemplateGenerationsInput executeTemplateInput =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();

        executeTemplateInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        executeTemplateInput.isPreview = false; // set true if testing in preview mode
        executeTemplateInput.inputParams = inputParams;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation generationsOutput;
        try {
            // ---- Call Prompt Template ----
            generationsOutput = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                TEMPLATE_API_NAME,
                executeTemplateInput
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Prompt Template Error: ' + e.getMessage());
            throw fail('Error generating enrichment suggestions: ' + e.getMessage());
        }

        if (generationsOutput == null
            || generationsOutput.generations == null
            || generationsOutput.generations.isEmpty()) {
            throw fail('No response returned from prompt template ' + TEMPLATE_API_NAME + '.');
        }

        return generationsOutput.generations[0].text;
    }

    private static ConnectApi.WrappedValue wrap(String value) {
        ConnectApi.WrappedValue w = new ConnectApi.WrappedValue();
        w.value = value;
        return w;
    }

    private static AuraHandledException fail(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}