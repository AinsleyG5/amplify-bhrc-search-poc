// Candidate Search: raw Textkernel check.
// One simple REQUIRED part, no location, so a 0 here means the parser or the index, not the criteria.
// Prints what TkSearchClient parsed next to the raw SOAP response, to confirm the element names.
//
// Run:  sf apex run --file scripts/apex/tkRaw.apex --target-org <alias> > logs\tkraw.log
// The RAW line contains candidate data from the index: trim it before sharing.

TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
p.field = 'FULLTEXT';
p.condition = 'REQUIRED';
p.values.add('"Warehouse Operative"');

TkSearchClient.Result r = TkSearchClient.search(new List<TkSearchClient.QueryPart>{ p }, null);

System.debug('TOTAL ' + r.total + '  HAS MORE ' + r.hasMore + '  HITS ' + r.hits.size() + '  FACETS ' + r.facets.size() + '  ECHOED PARTS ' + r.queryParts.size() + '  MS ' + r.durationMs);
if (!r.hits.isEmpty()) {
    TkSearchClient.Hit h = r.hits[0];
    System.debug('FIRST ' + h.docId + '  contact ' + h.contactId + '  score ' + h.score + '  parts ' + h.queryPartScores
        + '  fields ' + h.fields.keySet() + '  highlights ' + h.highlights.keySet());
}
System.debug('REQUEST ' + r.requestXml);
System.debug('RAW ' + r.responseXml.abbreviate(15000));

/* ---- OPEN ITEMS 1 and 3: index field names and search engines. Run on its own. ----
System.debug('CV ' + TkSearchClient.getMetadata('tksf_bh4sf_tso_cv').abbreviate(60000));
System.debug('VAC ' + TkSearchClient.getMetadata('tksf_bh4sf_tso_vac').abbreviate(60000));
*/
