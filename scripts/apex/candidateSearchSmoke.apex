// Candidate Search: Wednesday done-when check (CANDIDATE_SEARCH_SPEC.md section 13).
// NL text -> criteria -> TK results -> audit with one result row per candidate -> explain the top 10.
//
// Run:  sf apex run --file scripts/apex/candidateSearchSmoke.apex --target-org <alias>
// Then: run the second block (EXPLAIN) with the audit Id this prints, once the Queueable has written the rows.
//
// Needs: the three Named Credentials with their External Credential principals filled in Setup
// (TK password, Tx service key, Anthropic API key: <SET IN EXTERNAL CREDENTIAL>), the TK_Candidate_Search URL set,
// and the Candidate_Search_User permission set assigned to the running user.

String text = 'Forklift-certified warehouse operatives within 15 miles of Dagenham';

String criteriaJson = CandidateSearchController.parseQuery(text);
System.debug('CRITERIA ' + criteriaJson);

String responseJson = CandidateSearchController.runSearch(criteriaJson, 0, null);
Map<String, Object> res = (Map<String, Object>) System.JSON.deserializeUntyped(responseJson);
System.debug('ERROR ' + res.get('error'));
System.debug('AUDIT ' + res.get('auditId') + '  TOTAL ' + res.get('total') + '  HAS MORE ' + res.get('hasMore'));
System.debug('NOTICES ' + res.get('notices'));
for (Object o : (List<Object>) res.get('rows')) {
    Map<String, Object> r = (Map<String, Object>) o;
    System.debug(r.get('rank') + '. ' + r.get('name') + '  ' + r.get('scorePct') + '%  flags ' + r.get('queryPartFlags') + '  ' + r.get('criteriaIds'));
}

/* ---- EXPLAIN: paste the audit Id, then run this block on its own ----
Id auditId = 'a0X000000000000';
List<String> docIds = new List<String>();
for (Search_Audit_Result__c r : [SELECT TK_Doc_Id__c FROM Search_Audit_Result__c WHERE Search_Audit__c = :auditId ORDER BY Rank__c LIMIT 10]) {
    docIds.add(r.TK_Doc_Id__c);
}
System.debug('ROWS ' + docIds.size());
System.debug(CandidateSearchController.explainResults(auditId, System.JSON.serialize(docIds)));
*/

/* ---- OPEN ITEMS 1 and 3: getMetadata on both environments ----
System.debug(TkSearchClient.getMetadata('tksf_bh4sf_tso_cv').abbreviate(100000));
System.debug(TkSearchClient.getMetadata('tksf_bh4sf_tso_vac').abbreviate(100000));
*/

/* ---- JOB MATCH ----
System.debug(CandidateSearchController.startJobMatch('a1wDp000001g5BiIAI'));
*/
