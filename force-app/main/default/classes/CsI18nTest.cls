@isTest
private class CsI18nTest {

    @isTest
    static void englishByDefaultAndFrenchWhenAsked() {
        System.assertEquals('en', CsI18n.use(null));
        System.assertEquals('Added 1 candidate to J-1.', CsI18n.plural('addedToJob', 1, new List<Object>{ 1, 'J-1' }));
        System.assertEquals('Added 0 candidates to J-1.', CsI18n.plural('addedToJob', 0, new List<Object>{ 0, 'J-1' }));
        System.assertEquals(null, CsI18n.aiInstruction());
        System.assertEquals('en', CsI18n.txOutputLanguage());

        System.assertEquals('fr', CsI18n.use('fr_FR'));
        System.assertEquals('0 candidat ajouté à J-1.', CsI18n.plural('addedToJob', 0, new List<Object>{ 0, 'J-1' }));
        // Apostrophes survive String.format
        System.assertEquals('Un candidat est introuvable ou vous n\'y avez pas accès (003).', CsI18n.t('candidateNoAccess', new List<Object>{ '003' }));
        System.assertEquals('Présélectionné', CsI18n.t('pipeShortlisted'));
        System.assertEquals('unknownKey', CsI18n.t('unknownKey'));
        System.assert(CsI18n.aiInstruction().contains('French'));
        System.assertEquals('fr', CsI18n.txOutputLanguage());
    }

    @isTest
    static void frenchReachesTheAiRequest() {
        CsI18n.use('fr');
        SearchAiService.LlmRequest req = new SearchAiService.LlmRequest();
        req.inputs.put('NaturalLanguage', 'caristes à Lyon');
        System.assert(req.userContent().contains('<OutputLanguage>'), req.userContent());
        CsI18n.use('en');
        System.assert(!req.userContent().contains('<OutputLanguage>'));
    }
}
