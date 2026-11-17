// REVISION 4: master skills are matched with LIKE on TR1__Master_Skill_Name__c. If you can read this line in the org, this is the current file.
public with sharing class EnrichmentApplyController {

    // Upper bound on skills processed per apply, keeps the SOQL and DML well inside governor limits
    private static final Integer MAX_SKILLS = 15;

    // ============================================================
    // Wire types
    // ============================================================

    public class FieldUpdateRequest {
        @AuraEnabled public String targetField;   // e.g. 'Title' or 'TR1__Desired_Salary__c'
        @AuraEnabled public Object proposedValue; // JSON can send string/number/bool
    }

    public class SkillRequest {
        @AuraEnabled public String name;          // skill name picked up in the transcript
        @AuraEnabled public String altName;      // fuller wording from the transcript, tried first (e.g. 'Certified Forklift Operator')
        @AuraEnabled public String skillType;     // optional, e.g. 'Certification'
    }

    public class SkillResult {
        @AuraEnabled public String requested;     // what the transcript said
        @AuraEnabled public String status;        // Created, Exists, NoMasterSkill or Failed
        @AuraEnabled public String matchedMaster; // master skill name that was linked
        @AuraEnabled public String message;       // human readable detail, logged to the browser console
        @AuraEnabled public Id skillId;
    }

    public class AppliedLogEntry {
        @AuraEnabled public String fieldLabel;
        @AuraEnabled public String previousValue;
        @AuraEnabled public String newValue;
        @AuraEnabled public String updateType;
    }

    // ============================================================
    // Contact field updates
    // ============================================================

    /**
     * Returns notes about anything that was skipped (unknown field, read-only field, bad value),
     * so the LWC can write them to the browser console instead of failing silently.
     */
    @AuraEnabled
    public static List<String> applyContactFieldUpdates(Id contactId, String updatesJson) {
        List<String> notes = new List<String>();
        if (contactId == null) {
            throw fail('ContactId is required.');
        }

        // Sent as a JSON string: a list of objects passed straight from the LWC arrived with blank fields
        List<FieldUpdateRequest> updates = parseUpdates(updatesJson);
        notes.add('Received ' + updates.size() + ' field update(s).');
        if (updates.isEmpty()) {
            return notes;
        }

        Contact c = [SELECT Id FROM Contact WHERE Id = :contactId LIMIT 1];

        // Describe once for validation + type coercion
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Contact.fields.getMap();
        Integer applied = 0;
        List<String> appliedFields = new List<String>();

        for (FieldUpdateRequest u : updates) {
            if (u == null || String.isBlank(u.targetField)) continue;

            String fieldApi = u.targetField.trim();
            Schema.SObjectField f = fieldMap.get(fieldApi.toLowerCase());
            if (f == null) {
                notes.add('Skipped ' + fieldApi + ': there is no such field on Contact.');
                continue;
            }

            Schema.DescribeFieldResult d = f.getDescribe();
            if (!d.isUpdateable()) {
                notes.add('Skipped ' + fieldApi + ': the field is not updateable for this user.');
                continue;
            }

            try {
                c.put(d.getName(), coerceValueForField(d, u.proposedValue));
                applied++;
                appliedFields.add(d.getName());
            } catch (Exception e) {
                notes.add('Skipped ' + fieldApi + ': ' + e.getMessage());
            }
        }

        if (applied == 0) {
            return notes;
        }

        try {
            update c;
        } catch (DmlException e) {
            throw fail('Contact update failed. ' + dmlText(e));
        }
        notes.add('Updated Contact fields: ' + String.join(appliedFields, ', ') + '.');
        return notes;
    }

    private static Object coerceValueForField(Schema.DescribeFieldResult d, Object v) {
        if (v == null) return null;

        Schema.DisplayType t = d.getType();
        String s = String.valueOf(v).trim();

        // Numbers often arrive as "£15", "15,000" or similar, so keep only the numeric characters
        if (t == Schema.DisplayType.Currency || t == Schema.DisplayType.Double
            || t == Schema.DisplayType.Integer || t == Schema.DisplayType.Percent) {
            String numeric = s.replaceAll('[^0-9.\\-]', '');
            if (String.isBlank(numeric)) {
                throw new TypeException('"' + s + '" is not a number.');
            }
            Decimal n = Decimal.valueOf(numeric);
            return t == Schema.DisplayType.Integer ? (Object) n.intValue() : (Object) n;
        }

        // Dates: expect "YYYY-MM-DD", ignore any time part
        if (t == Schema.DisplayType.Date) {
            if (v instanceof Date) return (Date) v;
            return Date.valueOf(s.length() > 10 ? s.substring(0, 10) : s);
        }

        // DateTime: accept "2025-03-15T09:00:00Z" or a bare date
        if (t == Schema.DisplayType.DateTime) {
            String dt = s.replace('T', ' ').replace('Z', '');
            if (dt.length() == 10) dt += ' 00:00:00';
            if (dt.length() > 19) dt = dt.substring(0, 19);
            return DateTime.valueOfGmt(dt);
        }

        // Boolean
        if (t == Schema.DisplayType.Boolean) {
            if (v instanceof Boolean) return (Boolean) v;
            String b = s.toLowerCase();
            return (b == 'true' || b == '1' || b == 'yes');
        }

        // Picklist: a restricted picklist rejects anything that is not an active value, so check first
        if (t == Schema.DisplayType.Picklist) {
            String valid = matchPicklist(d, s);
            if (valid == null) {
                throw new TypeException('"' + s + '" is not an allowed value for this picklist.');
            }
            return valid;
        }
        if (t == Schema.DisplayType.MultiPicklist) {
            return s;
        }

        // Default: text. Trim to the field length so a long summary does not fail the whole update
        Integer maxLen = d.getLength();
        if (maxLen != null && maxLen > 0 && s.length() > maxLen) {
            return s.substring(0, maxLen);
        }
        return s;
    }

    /** The picklist's own spelling of the value, the value as given for an open picklist, or null if it is not allowed. */
    private static String matchPicklist(Schema.DescribeFieldResult d, String wanted) {
        if (String.isBlank(wanted)) return null;
        for (Schema.PicklistEntry pe : d.getPicklistValues()) {
            if (!pe.isActive()) continue;
            if (pe.getValue().equalsIgnoreCase(wanted) || pe.getLabel().equalsIgnoreCase(wanted)) {
                return pe.getValue();
            }
        }
        return d.isRestrictedPicklist() ? null : wanted;
    }

    // ============================================================
    // Skills: TR1__Skills__c linked to a TR1__Master_Skill__c
    // ============================================================

    /**
     * Creates a TR1__Skills__c on the Contact for each requested skill.
     *
     * Every skill must link to an existing master skill, so the name is looked up on the master
     * skill object (exact match first, then a single unambiguous partial match). A skill with no
     * master skill is reported back and NOT created, so there are no orphaned skill records.
     * Skills the Contact already has are skipped.
     *
     * The master skill object and lookup are found by describe, nothing is hardcoded.
     * Returns one result per requested skill; the LWC writes them to the browser console.
     */
    @AuraEnabled
    public static List<SkillResult> applySkillUpdates(Id contactId, String skillsJson) {
        List<SkillResult> results = new List<SkillResult>();
        if (contactId == null) {
            throw fail('ContactId is required.');
        }
        List<SkillRequest> skills = parseSkills(skillsJson);
        if (skills.isEmpty()) {
            return results;
        }

        // 1. Find the master skill lookup on TR1__Skills__c
        Map<String, Schema.SObjectField> skillFields = Schema.SObjectType.TR1__Skills__c.fields.getMap();
        String masterLookup = null;
        String masterObject = null;
        String fallbackLookup = null;
        String fallbackObject = null;
        for (Schema.SObjectField f : skillFields.values()) {
            Schema.DescribeFieldResult fd = f.getDescribe();
            if (fd.getType() != Schema.DisplayType.Reference || fd.getReferenceTo().isEmpty()) continue;
            String target = String.valueOf(fd.getReferenceTo()[0]);
            if (target.equalsIgnoreCase('TR1__Master_Skill__c')) {
                masterLookup = fd.getName();
                masterObject = target;
                break;
            }
            if (fallbackLookup == null && target.toLowerCase().contains('master_skill')) {
                fallbackLookup = fd.getName();
                fallbackObject = target;
            }
        }
        if (masterLookup == null) {
            masterLookup = fallbackLookup;
            masterObject = fallbackObject;
        }
        if (masterLookup == null) {
            throw fail('Could not find a Master Skill lookup on TR1__Skills__c, so skills cannot be created.');
        }

        // 2. Clean and de-duplicate the requested names
        List<SkillRequest> wanted = new List<SkillRequest>();
        List<String> names = new List<String>();
        Set<String> seen = new Set<String>();
        for (SkillRequest r : skills) {
            if (r == null || String.isBlank(r.name)) continue;
            String clean = r.name.trim();
            if (!seen.add(clean.toLowerCase())) continue;
            if (wanted.size() >= MAX_SKILLS) break;
            r.name = clean;
            wanted.add(r);
            names.add(clean);
            if (String.isNotBlank(r.altName)) names.add(r.altName.trim());
        }
        if (wanted.isEmpty()) {
            return results;
        }

        // 3. Gather candidate master skills with LIKE, in a few bulk queries (never one query per skill).
        //    Each significant word of every requested name becomes a '%word%' pattern, and the
        //    best candidate per skill is picked in memory afterwards (see pickMaster).
        //    Sources, best first:
        //      a) TR1__Master_Skill_Name__c on the master skill object, if that object has the field
        //      b) TR1__Master_Skill_Name__c on existing TR1__Skills__c records, taking their master lookup
        //      c) Name on the master skill object
        Set<String> wordSet = new Set<String>();
        for (String n : names) wordSet.addAll(significantWords(n));
        List<String> searchNotes = new List<String>();
        Map<Id, String> candidates = new Map<Id, String>();

        if (!wordSet.isEmpty()) {
            Map<String, Schema.SObjectField> masterFields =
                Schema.describeSObjects(new List<String>{ masterObject })[0].fields.getMap();

            if (masterFields.containsKey('tr1__master_skill_name__c')) {
                collectCandidates(
                    'SELECT Id, TR1__Master_Skill_Name__c FROM ' + masterObject
                    + ' WHERE ' + likeClause('TR1__Master_Skill_Name__c', wordSet) + ' LIMIT 2000',
                    'Id', 'TR1__Master_Skill_Name__c', candidates, searchNotes, masterObject + '.TR1__Master_Skill_Name__c');
            }
            if (skillFields.containsKey('tr1__master_skill_name__c')) {
                collectCandidates(
                    'SELECT ' + masterLookup + ', TR1__Master_Skill_Name__c FROM TR1__Skills__c'
                    + ' WHERE ' + masterLookup + ' != null AND ' + likeClause('TR1__Master_Skill_Name__c', wordSet) + ' LIMIT 5000',
                    masterLookup, 'TR1__Master_Skill_Name__c', candidates, searchNotes, 'TR1__Skills__c.TR1__Master_Skill_Name__c');
            }
            collectCandidates(
                'SELECT Id, Name FROM ' + masterObject
                + ' WHERE ' + likeClause('Name', wordSet) + ' LIMIT 2000',
                'Id', 'Name', candidates, searchNotes, masterObject + '.Name');
        }
        System.debug('[EnrichmentApplyController] Master skill candidates: ' + candidates.size() + ' ' + searchNotes);

        // 4. Skills this Contact already has, by master skill
        Set<Id> alreadyHas = new Set<Id>();
        for (SObject s : Database.query(
            'SELECT ' + masterLookup + ' FROM TR1__Skills__c'
            + ' WHERE TR1__Contact__c = :contactId AND ' + masterLookup + ' != null LIMIT 2000'
        )) {
            alreadyHas.add((Id) s.get(masterLookup));
        }

        // 5. Skill type (e.g. Certification) is only sent when the picklist accepts it
        Schema.DescribeFieldResult typeDescribe = skillFields.containsKey('tr1__type__c')
            ? skillFields.get('tr1__type__c').getDescribe()
            : null;

        List<TR1__Skills__c> toInsert = new List<TR1__Skills__c>();
        List<SkillResult> pending = new List<SkillResult>();
        Set<Id> queuedMasters = new Set<Id>();

        for (SkillRequest r : wanted) {
            SkillResult res = new SkillResult();
            res.requested = r.name;
            results.add(res);

            // The fuller wording from the transcript wins if it matches exactly
            MasterPick pick = null;
            MasterPick altPick = String.isNotBlank(r.altName) ? pickMaster(r.altName, candidates) : null;
            if (altPick != null && altPick.exact) {
                pick = altPick;
            } else {
                MasterPick namePick = pickMaster(r.name, candidates);
                if (namePick != null && namePick.exact) {
                    pick = namePick;
                } else {
                    pick = altPick != null ? altPick : namePick;
                }
            }

            if (pick == null) {
                res.status = 'NoMasterSkill';
                res.message = 'No master skill like "' + r.name + '" was found, so the skill was not created.'
                    + (searchNotes.isEmpty() ? '' : ' Search notes: ' + String.join(searchNotes, '; '));
                continue;
            }
            Boolean approximate = !pick.exact;

            Id masterId = pick.masterId;
            res.matchedMaster = candidates.get(masterId);

            if (alreadyHas.contains(masterId) || queuedMasters.contains(masterId)) {
                res.status = 'Exists';
                res.message = 'The candidate already has "' + res.matchedMaster + '".';
                continue;
            }

            TR1__Skills__c skill = new TR1__Skills__c(TR1__Contact__c = contactId);
            skill.put(masterLookup, masterId);

            String typeNote = '';
            if (typeDescribe != null && String.isNotBlank(r.skillType)) {
                String validType = matchPicklist(typeDescribe, r.skillType);
                if (validType != null) {
                    skill.put('TR1__Type__c', validType);
                    typeNote = ' as ' + validType;
                } else {
                    typeNote = ' (type "' + r.skillType + '" is not an allowed value, left blank)';
                }
            }

            res.message = (approximate ? 'Approximate match: "' + r.name + '" linked to "' + res.matchedMaster + '"' : 'Linked to "' + res.matchedMaster + '"')
                + typeNote + '.';
            queuedMasters.add(masterId);
            toInsert.add(skill);
            pending.add(res);
        }

        if (!toInsert.isEmpty()) {
            List<Database.SaveResult> saved = Database.insert(toInsert, false);
            for (Integer i = 0; i < saved.size(); i++) {
                SkillResult res = pending[i];
                if (saved[i].isSuccess()) {
                    res.status = 'Created';
                    res.skillId = saved[i].getId();
                } else {
                    res.status = 'Failed';
                    List<String> msgs = new List<String>();
                    for (Database.Error err : saved[i].getErrors()) {
                        msgs.add(err.getMessage() + (err.getFields().isEmpty() ? '' : ' [' + String.join(err.getFields(), ', ') + ']')
                            + ' (' + err.getStatusCode() + ')');
                    }
                    res.message = 'Could not save "' + res.matchedMaster + '": ' + String.join(msgs, '; ');
                }
            }
        }
        return results;
    }

    // ============================================================
    // Master skill matching
    // ============================================================

    public class MasterPick {
        public Id masterId;
        public Boolean exact = false;
    }

    private static final Set<String> STOP_WORDS = new Set<String>{
        'and', 'the', 'for', 'with', 'from', 'certified', 'skill', 'skills'
    };

    /** Lower-case words of 3+ letters/digits, minus filler words. Safe to put in a LIKE literal. */
    private static List<String> significantWords(String text) {
        List<String> out = new List<String>();
        if (String.isBlank(text)) return out;
        for (String w : text.toLowerCase().split('[^a-z0-9]+')) {
            if (w.length() >= 3 && !STOP_WORDS.contains(w)) out.add(w);
        }
        return out;
    }

    /** (field LIKE '%w1%' OR field LIKE '%w2%' ...). Words are alphanumeric only, so no escaping issues. */
    private static String likeClause(String field, Set<String> words) {
        List<String> ors = new List<String>();
        for (String w : words) {
            ors.add(field + ' LIKE \'%' + String.escapeSingleQuotes(w) + '%\'');
        }
        return '(' + String.join(ors, ' OR ') + ')';
    }

    /** Runs one candidate query; the first source to name a master skill wins. Failures are noted, not thrown. */
    private static void collectCandidates(String soql, String idField, String nameField,
                                          Map<Id, String> candidates, List<String> notes, String label) {
        try {
            Integer found = 0;
            for (SObject row : Database.query(soql)) {
                Object idValue = row.get(idField);
                Object nameValue = row.get(nameField);
                if (idValue == null || nameValue == null) continue;
                Id masterId = (Id) idValue;
                if (!candidates.containsKey(masterId)) {
                    candidates.put(masterId, String.valueOf(nameValue));
                    found++;
                }
            }
            notes.add(label + ' gave ' + found + ' candidate(s)');
        } catch (Exception e) {
            notes.add(label + ' could not be searched: ' + e.getMessage());
        }
    }

    /**
     * Best master skill for a requested name, in this order:
     *   1. exact name (ignoring case and spacing)
     *   2. master name contains the requested phrase  -> shortest wins ("Reach truck" -> "Reach Truck Licence")
     *   3. requested phrase contains the whole master name -> longest wins ("Certified Forklift Operator" -> "Forklift Operator")
     *   4. master name contains every significant word -> shortest wins ("Counterbalance forklift" -> "Forklift (Counterbalance)")
     */
    private static MasterPick pickMaster(String requested, Map<Id, String> candidates) {
        if (String.isBlank(requested) || candidates.isEmpty()) return null;
        String req = requested.toLowerCase().normalizeSpace();
        String paddedReq = ' ' + req.replaceAll('[^a-z0-9]+', ' ').normalizeSpace() + ' ';
        List<String> words = significantWords(requested);

        Id containsId = null;
        Integer containsLen = null;
        Id withinId = null;
        Integer withinLen = null;
        Id allWordsId = null;
        Integer allWordsLen = null;

        for (Id masterId : candidates.keySet()) {
            String raw = candidates.get(masterId);
            if (String.isBlank(raw)) continue;
            String c = raw.toLowerCase().normalizeSpace();
            if (c.equals(req)) {
                MasterPick exact = new MasterPick();
                exact.masterId = masterId;
                exact.exact = true;
                return exact;
            }
            Integer len = c.length();
            String paddedC = ' ' + c.replaceAll('[^a-z0-9]+', ' ').normalizeSpace() + ' ';
            if (c.contains(req)) {
                if (containsId == null || len < containsLen) { containsId = masterId; containsLen = len; }
            } else if (len >= 5 && paddedReq.contains(paddedC)) {
                if (withinId == null || len > withinLen) { withinId = masterId; withinLen = len; }
            } else if (!words.isEmpty() && containsAllWords(c, words)) {
                if (allWordsId == null || len < allWordsLen) { allWordsId = masterId; allWordsLen = len; }
            }
        }

        Id chosen = containsId != null ? containsId : (withinId != null ? withinId : allWordsId);
        if (chosen == null) return null;
        MasterPick p = new MasterPick();
        p.masterId = chosen;
        return p;
    }

    private static Boolean containsAllWords(String text, List<String> words) {
        for (String w : words) {
            if (!text.contains(w)) return false;
        }
        return true;
    }

    // ============================================================
    // Job lead
    // ============================================================

    @AuraEnabled
    public static Id createJobLead(String name, String companyName, String jobDescription) {

        // ── 1. Resolve or create Account ──────────────────────────────────────
        Id accountId;
        if (String.isNotBlank(companyName)) {
            List<Account> accounts = [
                SELECT Id FROM Account
                WHERE Name LIKE :('%' + companyName + '%')
                LIMIT 1
            ];

            if (!accounts.isEmpty()) {
                accountId = accounts[0].Id;
            } else {
                Account newAccount = new Account(
                    Name           = companyName,
                    TR1__Status__c = 'New Lead'
                );
                try {
                    insert newAccount;
                } catch (DmlException e) {
                    throw fail('Could not create the account "' + companyName + '". ' + dmlText(e));
                }
                accountId = newAccount.Id;
            }
        }

        // ── 2. Resolve Record Type ─────────────────────────────────────────────
        Id recordTypeId = Schema.SObjectType.TR1__Job_Leads__c
            .getRecordTypeInfosByName()
            .get('General Staffing')
            ?.getRecordTypeId();

        // ── 3. Create Job Lead ─────────────────────────────────────────────────
        TR1__Job_Leads__c lead = new TR1__Job_Leads__c(
            Deal_Title__c           = name,
            TR1__Account__c         = accountId,
            RecordTypeId            = recordTypeId,
            TR1__Job_Description__c = jobDescription,
            TR1__Lead_Source__c     = 'Enrichment',
            TR1__Stage__c           = 'Prospecting',
            TR1__Status__c          = 'Open'
        );

        try {
            insert lead;
        } catch (DmlException e) {
            throw fail('Could not create the job lead. ' + dmlText(e));
        }
        return lead.Id;
    }

    // ============================================================
    // Audit log and Power Note
    // ============================================================

    @AuraEnabled
    public static Id logEnrichment(
        Id recordId,
        String objectApiName,
        Id contactId,
        Id jobId,
        String appliedUpdatesJson,
        Integer sourceItemCount,
        String sourceLabel
    ) {
        if (recordId == null || String.isBlank(objectApiName)) {
            throw fail('RecordId and ObjectApiName are required.');
        }

        List<AppliedLogEntry> appliedUpdates = parseApplied(appliedUpdatesJson);

        // The header and the "- " prefix are what RecordEnrichmentController reads to count the updates
        List<String> lines = new List<String>();
        if (appliedUpdates != null) {
            for (AppliedLogEntry entry : appliedUpdates) {
                String line = '- ' + entry.fieldLabel + ': ';
                if (String.isNotBlank(entry.previousValue)) {
                    line += entry.previousValue + ' → ';
                }
                line += entry.newValue;
                if (String.isNotBlank(entry.updateType) && entry.updateType != 'Field Update') {
                    line += ' (' + entry.updateType + ')';
                }
                lines.add(line);
            }
        }
        Integer count = lines.size();

        String description =
            'Enrichment Source: ' + (String.isNotBlank(sourceLabel) ? sourceLabel : 'Unknown') + '\n' +
            'Items Analyzed: ' + (sourceItemCount != null ? String.valueOf(sourceItemCount) : '0') + '\n\n' +
            '--- Updates Applied (' + count + ') ---\n' +
            String.join(lines, '\n');

        Task enrichmentLog = new Task(
            WhoId = contactId,
            WhatId = relatedToFor(recordId, jobId),
            Subject = 'Amplify Enrichment',
            Description = description,
            Status = 'Completed',
            ActivityDate = Date.today(),
            Type = safeTaskType('Enrichment')
        );

        try {
            insert enrichmentLog;
        } catch (DmlException e) {
            throw fail('Could not write the enrichment log. ' + dmlText(e));
        }
        return enrichmentLog.Id;
    }

    @AuraEnabled
    public static Id createPowerNote(
        Id contactId,
        Id jobId,
        String summary,
        List<String> keyPoints,
        String sourceLabel
    ) {
        if (contactId == null) {
            throw fail('ContactId is required to create a Power Note.');
        }

        if (String.isBlank(summary)) {
            throw fail('Summary is required to create a Power Note.');
        }

        // Build the note content
        String noteContent = 'Market Intelligence Summary\n\n';
        noteContent += summary + '\n\n';

        if (keyPoints != null && !keyPoints.isEmpty()) {
            noteContent += 'Key Points:\n';
            for (String point : keyPoints) {
                noteContent += '• ' + point + '\n';
            }
            noteContent += '\n';
        }

        if (String.isNotBlank(sourceLabel)) {
            noteContent += 'Source: ' + sourceLabel;
        }

        // Create a Task as a Power Note
        Task powerNote = new Task(
            WhoId = contactId,
            WhatId = relatedToFor(null, jobId), // null when there is no job context
            Subject = 'Market Intelligence - ' + (String.isNotBlank(sourceLabel) ? sourceLabel : 'Enrichment'),
            Description = noteContent,
            Status = 'Completed',
            ActivityDate = Date.today(),
            Type = safeTaskType('Power Note'),
            Priority = 'Normal'
        );

        try {
            insert powerNote;
        } catch (DmlException e) {
            throw fail('Could not create the Power Note. ' + dmlText(e));
        }
        return powerNote.Id;
    }

    // ============================================================
    // Helpers
    // ============================================================

    private static String str(Map<String, Object> m, String key) {
        Object v = m.get(key);
        return v == null ? null : String.valueOf(v);
    }

    private static List<Map<String, Object>> parseList(String jsonText) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (String.isBlank(jsonText)) return out;
        for (Object o : (List<Object>) System.JSON.deserializeUntyped(jsonText)) {
            if (o instanceof Map<String, Object>) out.add((Map<String, Object>) o);
        }
        return out;
    }

    private static List<FieldUpdateRequest> parseUpdates(String jsonText) {
        List<FieldUpdateRequest> out = new List<FieldUpdateRequest>();
        for (Map<String, Object> m : parseList(jsonText)) {
            FieldUpdateRequest r = new FieldUpdateRequest();
            r.targetField = str(m, 'targetField');
            r.proposedValue = m.get('proposedValue');
            out.add(r);
        }
        return out;
    }

    private static List<SkillRequest> parseSkills(String jsonText) {
        List<SkillRequest> out = new List<SkillRequest>();
        for (Map<String, Object> m : parseList(jsonText)) {
            SkillRequest r = new SkillRequest();
            r.name = str(m, 'name');
            r.altName = str(m, 'altName');
            r.skillType = str(m, 'skillType');
            out.add(r);
        }
        return out;
    }

    private static List<AppliedLogEntry> parseApplied(String jsonText) {
        List<AppliedLogEntry> out = new List<AppliedLogEntry>();
        for (Map<String, Object> m : parseList(jsonText)) {
            AppliedLogEntry e = new AppliedLogEntry();
            e.fieldLabel = str(m, 'fieldLabel');
            e.previousValue = str(m, 'previousValue');
            e.newValue = str(m, 'newValue');
            e.updateType = str(m, 'updateType');
            out.add(e);
        }
        return out;
    }

    /**
     * Task.WhatId cannot point at a Contact, Lead or another activity, and the enrichment component
     * is often sitting on a Contact. Use the record when it is a valid "Related To", otherwise the job.
     */
    private static Id relatedToFor(Id recordId, Id jobId) {
        if (recordId != null) {
            Schema.SObjectType t = recordId.getSobjectType();
            if (t != Contact.SObjectType && t != Lead.SObjectType
                && t != Task.SObjectType && t != Event.SObjectType) {
                return recordId;
            }
        }
        return jobId;
    }

    /** Task.Type is a picklist that may be restricted. Returns the value only if the org accepts it. */
    private static String safeTaskType(String desired) {
        Schema.SObjectField f = Schema.SObjectType.Task.fields.getMap().get('type');
        if (f == null) return null;
        return matchPicklist(f.getDescribe(), desired);
    }

    /** A readable version of a DmlException: which field, what is wrong, and the status code. */
    private static String dmlText(DmlException e) {
        List<String> parts = new List<String>();
        for (Integer i = 0; i < e.getNumDml(); i++) {
            List<String> fields = e.getDmlFieldNames(i);
            parts.add(
                (fields.isEmpty() ? '' : '[' + String.join(fields, ', ') + '] ')
                + e.getDmlMessage(i)
                + ' (' + e.getDmlType(i) + ')'
            );
        }
        return parts.isEmpty() ? e.getMessage() : String.join(parts, '; ');
    }

    private static AuraHandledException fail(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}