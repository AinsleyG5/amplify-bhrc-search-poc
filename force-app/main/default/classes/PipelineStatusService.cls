/**
 * PipelineStatusService
 *
 * For a job and the Contact Ids on a result page: who has applied (with stage), who is shortlisted and who was
 * placed on this job (spec section 8). Three SOQL queries, all dynamic and fail-soft: an object or field that does
 * not exist in the org means that flag is empty, never a failed search.
 *
 * The candidate lookup on TR1__Application_V2__c is configurable (Application_Candidate_Field__c, open item 5).
 * "Placed recently" across all jobs is not checked here: it goes to TK as an excluded date range (section 5).
 */
public with sharing class PipelineStatusService {

    public class Flags {
        public Boolean applied = false;
        public String stage;
        public Boolean shortlisted = false;
        public Boolean placed = false;
        public Date placedDate;
        /** Set by the controller from Contact.TR1__Last_Placement_Date__c. */
        public Boolean placedRecently = false;

        public Boolean hasAny() {
            return applied || shortlisted || placed;
        }

        /** Row tag text, for example "Applied (Interview), Placed 3 Nov". */
        public String label() {
            List<String> parts = new List<String>();
            if (applied) parts.add('Applied' + (String.isBlank(stage) ? '' : ' (' + stage + ')'));
            if (shortlisted) parts.add('Shortlisted');
            if (placed) {
                parts.add('Placed' + (placedDate == null ? '' : ' ' + Datetime.newInstance(placedDate.year(), placedDate.month(), placedDate.day()).format('d MMM')));
            }
            return String.join(parts, ', ');
        }
    }

    /**
     * TR1__Application_V2__c.TR1__Stage__c API value for a shortlisted candidate (the label users see is "Shortlisted").
     * An application at this stage flags as Shortlisted, not Applied; bulkAddToJob creates applications at it.
     */
    public static final String SHORTLIST_STAGE = 'Application';

    /** Messages about flags that could not be read, for the response notices and the debug log. */
    public static List<String> warnings = new List<String>();

    public static Map<Id, Flags> flagsFor(Id jobId, Set<Id> contactIds) {
        Map<Id, Flags> out = new Map<Id, Flags>();
        warnings = new List<String>();
        if (jobId == null || contactIds == null || contactIds.isEmpty()) return out;

        String candField = CandidateSearchConfig.get().applicationCandidateField;

        for (SObject r : safeQuery(
            'TR1__Application_V2__c', new List<String>{ candField, 'TR1__Stage__c' },
            candField, 'Applied', jobId, contactIds, 'CreatedDate DESC'
        )) {
            Flags f = flag(out, (Id) r.get(candField));
            String stage = (String) r.get('TR1__Stage__c');
            if (stage == SHORTLIST_STAGE) {
                f.shortlisted = true;
                continue;
            }
            if (f.applied) continue; // newest first: keep the latest stage
            f.applied = true;
            f.stage = stage;
        }

        for (SObject r : safeQuery(
            'TR1__Opportunity_Discussed__c', new List<String>{ 'TR1__Candidate__c' },
            'TR1__Candidate__c', 'Shortlisted', jobId, contactIds, null
        )) {
            flag(out, (Id) r.get('TR1__Candidate__c')).shortlisted = true;
        }

        for (SObject r : safeQuery(
            'TR1__Closing_Report__c', new List<String>{ 'TR1__Person_Placed__c', 'TR1__Start_Date__c', 'TR1__Booking_Date__c' },
            'TR1__Person_Placed__c', 'Placed', jobId, contactIds, null
        )) {
            Flags f = flag(out, (Id) r.get('TR1__Person_Placed__c'));
            f.placed = true;
            Date d = dateOf(r, 'TR1__Start_Date__c');
            if (d == null) d = dateOf(r, 'TR1__Booking_Date__c');
            if (d != null && (f.placedDate == null || d > f.placedDate)) f.placedDate = d;
        }
        return out;
    }

    private static Flags flag(Map<Id, Flags> out, Id contactId) {
        if (!out.containsKey(contactId)) out.put(contactId, new Flags());
        return out.get(contactId);
    }

    /** Only the fields that exist are selected; a missing object or candidate field skips the flag with a warning. */
    private static List<SObject> safeQuery(
        String objectName, List<String> fields, String candidateField, String flagName,
        Id jobId, Set<Id> contactIds, String orderBy
    ) {
        try {
            Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
            if (t == null) {
                warnings.add(flagName + ' flags are off: ' + objectName + ' is not in this org.');
                return new List<SObject>();
            }
            Map<String, Schema.SObjectField> fm = t.getDescribe().fields.getMap();
            if (!fm.containsKey(candidateField.toLowerCase()) || !fm.containsKey('tr1__job__c')) {
                warnings.add(flagName + ' flags are off: ' + objectName + '.' + candidateField + ' or TR1__Job__c is missing.');
                return new List<SObject>();
            }
            List<String> present = new List<String>();
            for (String f : fields) {
                if (fm.containsKey(f.toLowerCase())) present.add(f);
            }
            String soql = 'SELECT ' + String.join(present, ', ') + ' FROM ' + objectName
                + ' WHERE TR1__Job__c = :jobId AND ' + candidateField + ' IN :contactIds'
                + (orderBy == null ? '' : ' ORDER BY ' + orderBy)
                + ' LIMIT 2000';
            return Database.query(soql);
        } catch (Exception e) {
            warnings.add(flagName + ' flags are off: ' + e.getMessage());
            return new List<SObject>();
        }
    }

    private static Date dateOf(SObject r, String field) {
        try {
            Object v = r.get(field);
            if (v instanceof Date) return (Date) v;
            if (v instanceof Datetime) return ((Datetime) v).date();
        } catch (SObjectException e) {
            return null;
        }
        return null;
    }
}
