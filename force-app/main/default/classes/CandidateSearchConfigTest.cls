@isTest
private class CandidateSearchConfigTest {

    @isTest
    static void defaultsMatchTheSpec() {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        System.assertEquals('tksf_bh4sf_tso_cv', cfg.tkCandidateEnvironment);
        System.assertEquals('tksf_bh4sf_tso_vac', cfg.tkJobEnvironment);
        System.assertEquals(20, cfg.pageSize);
        System.assertEquals(10, cfg.explainBatchSize);
        System.assertEquals(15, cfg.defaultRadiusMiles);
        System.assertEquals(8, cfg.maxSkillParts);
        System.assertEquals(10, cfg.recentSearchesKept);
        System.assertEquals('13430659', cfg.txAccountId);
        System.assertEquals('Anthropic', cfg.llmProvider);
        System.assert(!cfg.tkResultFields.contains('*'));
    }

    @isTest
    static void readsTheDeployedRecordWhenAsked() {
        CandidateSearchConfig.readMetadataInTests = true;
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        System.assertNotEquals(null, cfg.tkCandidateEnvironment);
        System.assert(cfg.pageSize > 0);
    }

    @isTest
    static void deployedPromptsHaveAToolAndAModel() {
        for (String name : new List<String>{ SearchAiService.PARSE_PROMPT, SearchAiService.REFINE_PROMPT, SearchAiService.EXPLAIN_PROMPT }) {
            CandidateSearchConfig.PromptConfig p = CandidateSearchConfig.prompt(name);
            System.assertNotEquals(null, p.toolName, name);
            System.assertNotEquals(null, p.model, name);
            System.assert(System.JSON.deserializeUntyped(p.toolSchemaJson) instanceof Map<String, Object>, name);
        }
    }

    @isTest
    static void missingPromptIsReadable() {
        try {
            CandidateSearchConfig.prompt('Nope');
            System.assert(false, 'expected an error');
        } catch (CandidateSearchConfig.CandidateSearchException e) {
            System.assert(e.getMessage().contains('Nope'));
        }
    }
}
