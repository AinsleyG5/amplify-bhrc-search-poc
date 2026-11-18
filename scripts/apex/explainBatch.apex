// Candidate Search: time the explain prompt on a batch of 10 (open item 6).
// Use the audit Id from a search that returned 10 or more rows (a job match is a good test: many criteria).
// Prints the time and token use, then one line per candidate: met / not met counts and the summary.
//
// Run:  sf apex run --file scripts/apex/explainBatch.apex --target-org <alias> > logs\explain.log

Id auditId = 'a8ykP0000002bhpQAA';   // <- your audit Id

List<String> docIds = new List<String>();
for (Search_Audit_Result__c r : [
    SELECT TK_Doc_Id__c FROM Search_Audit_Result__c
    WHERE Search_Audit__c = :auditId AND Contact__c != null
    ORDER BY Rank__c LIMIT 10
]) {
    docIds.add(r.TK_Doc_Id__c);
}
System.debug('CANDIDATES ' + docIds.size());

Long started = System.currentTimeMillis();
String out = CandidateSearchController.explainResults(auditId, System.JSON.serialize(docIds));
Long ms = System.currentTimeMillis() - started;

Search_Audit__c a = [SELECT Explain_Model__c, Explain_Input_Tokens__c, Explain_Output_Tokens__c, Explain_Duration_ms__c FROM Search_Audit__c WHERE Id = :auditId];
System.debug('TIME ' + ms + ' ms  MODEL ' + a.Explain_Model__c + '  INPUT ' + a.Explain_Input_Tokens__c + '  OUTPUT ' + a.Explain_Output_Tokens__c + ' (totals for this audit)');

for (Object o : (List<Object>) System.JSON.deserializeUntyped(out)) {
    Map<String, Object> e = (Map<String, Object>) o;
    Integer met = 0, notMet = 0, evidence = 0;
    for (Object c : (List<Object>) e.get('criteria')) {
        Map<String, Object> crit = (Map<String, Object>) c;
        if (crit.get('met') == true) met++; else notMet++;
        if (crit.get('evidence') != SearchAiService.NO_EVIDENCE) evidence++;
    }
    System.debug('EXPLAINED ' + e.get('docId') + '  met ' + met + '  not met ' + notMet + '  with evidence ' + evidence
        + (e.get('correctedByTk') == true ? '  (corrected by TK)' : '') + '  |  ' + e.get('summary'));
}
