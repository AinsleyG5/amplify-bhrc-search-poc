// Candidate Search: Tx Skills API autocomplete check (open item 4).
// 1. Raw call, so a wrong method, path or domain shows the real HTTP status and body.
// 2. The same call through TkSkillsClient, to check the parser.
//
// Needs: Tx_Skills_Service_Key principal with a ServiceKey parameter, and "Allow Formulas in HTTP Header"
// ticked on the Tx Skills API Named Credential (the Tx-ServiceKey header is a formula).
// Run:  sf apex run --file scripts/apex/txSkills.apex --target-org <alias> > logs\txskills.log

CandidateSearchConfig cfg = CandidateSearchConfig.get();
System.debug('ENDPOINT callout:' + cfg.skillsNamedCredential + cfg.skillsAutocompletePath + '  ACCOUNT ' + cfg.txAccountId);

HttpRequest req = new HttpRequest();
req.setEndpoint('callout:' + cfg.skillsNamedCredential + cfg.skillsAutocompletePath);
req.setMethod('POST');
req.setHeader('Content-Type', 'application/json');
req.setHeader('Accept', 'application/json');
req.setHeader('Tx-AccountId', cfg.txAccountId);
req.setTimeout(10000);
req.setBody('{"Prefix":"fork","Languages":["en"],"Limit":5}');
HttpResponse res = new Http().send(req);
System.debug('RAW STATUS ' + res.getStatusCode() + ' ' + res.getStatus());
System.debug('RAW BODY ' + String.valueOf(res.getBody()).abbreviate(3000));

try {
    for (TkSkillsClient.Skill s : TkSkillsClient.autocomplete('fork', null, 5)) {
        System.debug('PARSED ' + s.id + '  ' + s.description + '  (' + s.category + ')');
    }
} catch (Exception e) {
    System.debug('PARSED ERROR ' + e.getMessage());
}
