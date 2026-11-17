/**
 * SearchAuditWriter
 *
 * Queueable that writes the slow part of a search audit after the results are on screen (spec section 9):
 * the Search_Audit_Result__c rows (upserted on Audit_Doc_Key__c), the parent's totals and appended request XML,
 * the full TK response as a File when it is too large for a field, and the user's recent-search record (with
 * pruning to the configured number kept).
 *
 * An audit failure never fails the search: errors are caught and written to Status__c / Error__c on the parent.
 */
public with sharing class SearchAuditWriter implements Queueable {

    public class RecentSearch {
        public String name;
        public String criteriaJson;
        public String naturalLanguage;
        public Id jobId;
        public String criteriaHash;
    }

    public Id auditId;
    public List<Search_Audit_Result__c> rows = new List<Search_Audit_Result__c>();
    /** Masked request for this page, appended to TK_Request_XML__c on page 2 onwards. Null on page 1. */
    public String appendRequestXml;
    /** Full TK response; stored as a File only when longer than a Long Text field holds. */
    public String rawResponse;
    public RecentSearch recent;
    public Boolean firstPage = true;

    public static final Integer LONG_TEXT_MAX = 131072;

    public void execute(QueueableContext ctx) {
        run();
    }

    /** Also callable synchronously (tests, anonymous Apex). */
    public void run() {
        Search_Audit__c parent = new Search_Audit__c(Id = auditId);
        List<String> errors = new List<String>();

        try {
            if (!rows.isEmpty()) {
                Database.UpsertResult[] res = Database.upsert(rows, Search_Audit_Result__c.Audit_Doc_Key__c, false);
                for (Integer i = 0; i < res.size(); i++) {
                    if (!res[i].isSuccess()) {
                        errors.add(rows[i].TK_Doc_Id__c + ': ' + res[i].getErrors()[0].getMessage());
                    }
                }
            }
        } catch (Exception e) {
            errors.add('Result rows: ' + e.getMessage());
        }

        try {
            Search_Audit__c current = [
                SELECT Id, Name, TK_Request_XML__c, Pages_Loaded__c, Status__c
                FROM Search_Audit__c WHERE Id = :auditId LIMIT 1
            ];
            parent.Pages_Loaded__c = (current.Pages_Loaded__c == null ? 0 : current.Pages_Loaded__c) + 1;
            if (!firstPage && String.isNotBlank(appendRequestXml)) {
                String xml = (current.TK_Request_XML__c == null ? '' : current.TK_Request_XML__c + '\n\n') + appendRequestXml;
                parent.TK_Request_XML__c = xml.abbreviate(LONG_TEXT_MAX);
            }
            if (firstPage && rawResponse != null && rawResponse.length() > LONG_TEXT_MAX) {
                ContentVersion cv = new ContentVersion(
                    Title = 'TK response ' + current.Name,
                    PathOnClient = 'tk-response-' + current.Name + '.xml',
                    VersionData = Blob.valueOf(rawResponse)
                );
                insert cv;
                parent.TK_Raw_Response_File__c = cv.Id;
            }
            if (firstPage && recent != null) {
                parent.Saved_Search__c = logRecent(recent);
            }
        } catch (Exception e) {
            errors.add(e.getMessage());
        }

        if (!errors.isEmpty()) {
            parent.Status__c = 'Audit error';
            parent.Error__c = String.join(errors, '\n').abbreviate(32768);
        }
        try {
            update parent;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Search audit ' + auditId + ' could not be updated: ' + e.getMessage());
        }
    }

    /** Merges a repeat of the same search into one recent record, then keeps only the newest N recent searches. */
    @TestVisible
    private static Id logRecent(RecentSearch r) {
        Id me = UserInfo.getUserId();
        List<Saved_Search__c> existing = [
            SELECT Id, Run_Count__c FROM Saved_Search__c
            WHERE OwnerId = :me AND Is_Saved__c = false AND Criteria_Hash__c = :r.criteriaHash
            ORDER BY Last_Run__c DESC LIMIT 1
        ];
        Saved_Search__c rec = existing.isEmpty() ? new Saved_Search__c(Run_Count__c = 0) : existing[0];
        rec.Name = String.isBlank(r.name) ? 'Search' : r.name.abbreviate(80);
        rec.Criteria_JSON__c = r.criteriaJson;
        rec.Natural_Language__c = r.naturalLanguage == null ? null : r.naturalLanguage.abbreviate(255);
        rec.Job__c = r.jobId;
        rec.Criteria_Hash__c = r.criteriaHash;
        rec.Is_Saved__c = false;
        rec.Last_Run__c = System.now();
        rec.Run_Count__c = (rec.Run_Count__c == null ? 0 : rec.Run_Count__c) + 1;
        upsert rec;

        Integer keep = CandidateSearchConfig.get().recentSearchesKept;
        List<Saved_Search__c> old = [
            SELECT Id FROM Saved_Search__c
            WHERE OwnerId = :me AND Is_Saved__c = false
            ORDER BY Last_Run__c DESC NULLS LAST
            LIMIT 200 OFFSET :keep
        ];
        if (!old.isEmpty()) Database.delete(old, false);
        return rec.Id;
    }
}
