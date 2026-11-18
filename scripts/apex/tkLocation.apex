// Candidate Search: which location syntax does Textkernel geo-interpret?
// Five searches, each printing only the match count (no candidate data). 5 callouts.
//
// Run:  sf apex run --file scripts/apex/tkLocation.apex --target-org <alias> > logs\tklocation.log

CandidateSearchConfig cfg = CandidateSearchConfig.get();

// A-C: structured query part on the city field (what TkSearchClient sends today)
for (String v : new List<String>{ 'Dagenham+15', 'London+15', 'GB London' }) {
    TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
    p.field = 'city';
    p.condition = 'REQUIRED';
    p.values.add(v);
    try {
        TkSearchClient.Result r = TkSearchClient.search(new List<TkSearchClient.QueryPart>{ p }, null);
        System.debug('PART city=' + v + '  ->  ' + r.total);
    } catch (Exception e) {
        System.debug('PART city=' + v + '  ->  ERROR ' + e.getMessage());
    }
}

// D-E: free-text <query> string, as AmplifyTKMatchService sends location today
for (String q : new List<String>{ 'city:Dagenham+15', '"Warehouse Operative" city:Dagenham+15' }) {
    String body = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:sear="http://home.textkernel.nl/search">'
        + '<soapenv:Header/><soapenv:Body><sear:search>'
        + '<environment>' + cfg.tkCandidateEnvironment + '</environment>'
        + '<password><![CDATA[{!$Credential.' + cfg.tkExternalCredential + '.Password}]]></password>'
        + '<accessRoles>all</accessRoles>'
        + '<request><query>' + q.escapeXml() + '</query><pageSize>1</pageSize></request>'
        + '</sear:search></soapenv:Body></soapenv:Envelope>';
    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:' + cfg.tkNamedCredential);
    req.setMethod('POST');
    req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
    req.setHeader('SOAPAction', '""');
    req.setTimeout(30000);
    req.setBody(body);
    HttpResponse res = new Http().send(req);
    String b = res.getBody();
    String total = b.contains('<matchSize>') ? b.substringBetween('<matchSize>', '</matchSize>') : 'HTTP ' + res.getStatusCode() + ' ' + b.abbreviate(300);
    System.debug('QUERY ' + q + '  ->  ' + total);
}
