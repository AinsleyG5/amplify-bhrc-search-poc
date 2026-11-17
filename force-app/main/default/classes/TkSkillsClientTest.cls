@isTest
private class TkSkillsClientTest {

    @isTest
    static void autocompleteSendsTxHeadersAndParsesSkills() {
        CandidateSearchTestMocks.install();
        Test.startTest();
        List<TkSkillsClient.Skill> skills = TkSkillsClient.autocomplete('fork', null, 5);
        Test.stopTest();

        HttpRequest req = CandidateSearchTestMocks.requests[0];
        System.assertEquals('callout:Tx_Skills_API/v10/skills/v2/autocomplete', req.getEndpoint());
        System.assertEquals('13430659', req.getHeader('Tx-AccountId'));
        System.assertEquals(null, req.getHeader('Tx-ServiceKey'), 'the key comes from the External Credential, never from code');
        Map<String, Object> body = (Map<String, Object>) System.JSON.deserializeUntyped(req.getBody());
        System.assertEquals('fork', body.get('Prefix'));
        System.assertEquals(5, body.get('Limit'));

        System.assertEquals(1, skills.size());
        System.assertEquals('KS120076FGP5WGWYMP0F', skills[0].id);
        System.assertEquals('Forklift Truck Operation', skills[0].description);
        System.assertEquals('Logistics', skills[0].category);
    }

    @isTest
    static void shortPrefixMakesNoCallout() {
        System.assertEquals(0, TkSkillsClient.autocomplete('f', null, 5).size());
        System.assertEquals(0, CandidateSearchTestMocks.requests.size());
    }

    @isTest
    static void parseAcceptsOtherShapes() {
        System.assertEquals('Welding', TkSkillsClient.parse('[{"id":"KS1","name":"Welding"}]')[0].description);
        System.assertEquals('Soudage', TkSkillsClient.parse('{"Skills":[{"Id":"KS1","Description":{"fr":"Soudage"}}]}')[0].description);
        System.assertEquals(0, TkSkillsClient.parse('{"Info":{"Code":"Success"}}').size());
        System.assertEquals(0, TkSkillsClient.parse('').size());
    }

    @isTest
    static void rateLimitAndErrorsAreReadable() {
        CandidateSearchTestMocks.skillsStatus = 429;
        CandidateSearchTestMocks.install();
        Test.startTest();
        try {
            TkSkillsClient.autocomplete('fork', new List<String>{ 'en' }, 5);
            System.assert(false, 'expected an error');
        } catch (TkSkillsClient.SkillsException e) {
            System.assert(e.getMessage().contains('rate limit'));
        }
        CandidateSearchTestMocks.skillsStatus = 401;
        try {
            TkSkillsClient.autocomplete('fork', null, 5);
            System.assert(false, 'expected an error');
        } catch (TkSkillsClient.SkillsException e) {
            System.assert(e.getMessage().contains('401'));
        }
        Test.stopTest();
    }
}
