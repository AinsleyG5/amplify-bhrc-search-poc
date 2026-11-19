// Candidate Search: does Textkernel's View Document Service give us the CV as HTML? (CV tab, next step 3/4)
// 1. Reads the WSDL to find the service namespace.
// 2. Finds one candidate with a normal search.
// 3. Calls viewDocument for that candidate and prints the size and the start of the HTML (demo data only).
// Needs the TK_View_Document Named Credential deployed (same External Credential as TK_Candidate_Search).
//
// Run (PowerShell, from the repo folder):
//   sf apex run --file scripts/apex/tkViewDoc.apex --target-org <alias> | Out-File -Encoding utf8 logs\tkviewdoc.log
//   Select-String -Path logs\tkviewdoc.log -Pattern 'VIEW ' | ForEach-Object { $_.Line }

CandidateSearchConfig cfg = CandidateSearchConfig.get();

// 1. Namespace from the WSDL
String ns = 'http://home.textkernel.nl/viewdocument';
try {
    HttpRequest w = new HttpRequest();
    w.setEndpoint('callout:TK_View_Document?wsdl');
    w.setMethod('GET');
    w.setTimeout(20000);
    HttpResponse wr = new Http().send(w);
    String wsdl = wr.getBody();
    System.debug('VIEW WSDL status ' + wr.getStatusCode() + ', length ' + (wsdl == null ? 0 : wsdl.length()));
    Matcher m = Pattern.compile('targetNamespace="([^"]+)"').matcher(wsdl == null ? '' : wsdl);
    if (m.find()) ns = m.group(1);
    Matcher ops = Pattern.compile('<(?:wsdl:)?operation name="([^"]+)"').matcher(wsdl == null ? '' : wsdl);
    Set<String> names = new Set<String>();
    while (ops.find()) names.add(ops.group(1));
    System.debug('VIEW WSDL operations ' + names);
} catch (Exception e) {
    System.debug('VIEW WSDL ERROR ' + e.getMessage());
}
System.debug('VIEW namespace ' + ns);

// 2. One candidate document id
TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
p.field = 'candidate_status';
p.condition = 'REQUIRED';
p.values.addAll(new List<String>{ 'Active', 'Available', 'Placed', 'Prospect' });
TkSearchClient.SearchOptions o = new TkSearchClient.SearchOptions();
o.pageSize = 1;
TkSearchClient.Result r = TkSearchClient.search(new List<TkSearchClient.QueryPart>{ p }, o);
String docId = r.hits.isEmpty() ? null : r.hits[0].docId;
System.debug('VIEW docId ' + docId);

// 3. viewDocument
String body = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:v="' + ns + '">'
    + '<soapenv:Header/><soapenv:Body><v:viewDocument>'
    + '<environment>' + cfg.tkCandidateEnvironment + '</environment>'
    + '<password><![CDATA[{!$Credential.' + cfg.tkExternalCredential + '.Password}]]></password>'
    + '<searchEngine>candidates</searchEngine>'
    + '<documentID>' + docId + '</documentID>'
    + '<accessRoles>' + cfg.tkAccessRoles + '</accessRoles>'
    + '</v:viewDocument></soapenv:Body></soapenv:Envelope>';
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:TK_View_Document');
req.setMethod('POST');
req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
req.setHeader('SOAPAction', '""');
req.setTimeout(30000);
req.setBody(body);
HttpResponse res = new Http().send(req);
String out = res.getBody();
System.debug('VIEW status ' + res.getStatusCode() + ', length ' + (out == null ? 0 : out.length()));
for (Integer i = 0; out != null && i < Math.min(out.length(), 4500); i += 1500) {
    System.debug('VIEW body ' + out.substring(i, Math.min(out.length(), i + 1500)));
}
