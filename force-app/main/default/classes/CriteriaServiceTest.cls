@isTest
private class CriteriaServiceTest {

    private static Map<String, Object> sample() {
        return CriteriaService.parse(CandidateSearchTestMocks.criteriaJson());
    }

    private static Map<String, Object> chip(String id, String kind, String value, String weight) {
        return new Map<String, Object>{ 'id' => id, 'kind' => kind, 'label' => value, 'value' => value, 'weight' => weight, 'origin' => 'user' };
    }

    // ─── validate ────────────────────────────────────────────────

    @isTest
    static void validateAcceptsTheContractSample() {
        Map<String, Object> c = CriteriaService.validate(sample());
        System.assertEquals(3, CriteriaService.items(c).size());
    }

    @isTest
    static void validateTrimsLabelsAndFillsIds() {
        Map<String, Object> c = CriteriaService.newCriteria('user');
        Map<String, Object> item = chip(null, 'keyword', 'forklift', 'preferred');
        item.put('label', '  ' + 'x'.repeat(200) + '  ');
        CriteriaService.items(c).add(item);
        CriteriaService.validate(c);
        System.assertEquals(CriteriaService.MAX_LABEL, ((String) item.get('label')).length());
        System.assertEquals('c1', item.get('id'));
    }

    @isTest
    static void validateRejectsBadInput() {
        assertInvalid(new List<Object>{ chip('c1', 'colour', 'red', 'required') }, 'Unknown criterion type');
        assertInvalid(new List<Object>{ chip('c1', 'skill', 'PLC', 'must') }, 'Unknown weight');
        assertInvalid(new List<Object>{ chip('c1', 'skill', ' ', 'required') }, 'has no value');

        Map<String, Object> loc = chip('c1', 'location', 'Dagenham', 'required');
        assertInvalid(new List<Object>{ loc }, 'needs a radius');

        List<Object> many = new List<Object>();
        for (Integer i = 0; i < 26; i++) many.add(chip('c' + i, 'keyword', 'k' + i, 'preferred'));
        assertInvalid(many, 'at most 25');

        assertInvalid(new List<Object>(), 'at least one criterion');
    }

    @isTest
    static void validateChecksExclusions() {
        Map<String, Object> c = sample();
        CriteriaService.exclusions(c).put('placedWithinDays', 0);
        try {
            CriteriaService.validate(c);
            System.assert(false, 'expected an error');
        } catch (CriteriaService.CriteriaException e) {
            System.assert(e.getMessage().contains('between 1 and 3650'), e.getMessage());
        }
    }

    @isTest
    static void filterOnlyIsValid() {
        Map<String, Object> c = CriteriaService.newCriteria('user');
        CriteriaService.filters(c).put('candidate_status', new List<Object>{ 'Available' });
        CriteriaService.validate(c);
    }

    private static void assertInvalid(List<Object> chips, String expected) {
        Map<String, Object> c = CriteriaService.newCriteria('user');
        c.put('items', chips);
        try {
            CriteriaService.validate(c);
            System.assert(false, 'expected an error containing ' + expected);
        } catch (CriteriaService.CriteriaException e) {
            System.assert(e.getMessage().contains(expected), e.getMessage());
        }
    }

    @isTest
    static void parseRejectsNonObjects() {
        for (String bad : new List<String>{ '', '[1,2]', '{not json' }) {
            try {
                CriteriaService.parse(bad);
                System.assert(false, 'expected an error for ' + bad);
            } catch (CriteriaService.CriteriaException e) {
                System.assertNotEquals(null, e.getMessage());
            }
        }
    }

    // ─── toQueryParts ────────────────────────────────────────────

    @isTest
    static void toQueryPartsMapsKindsWeightsFiltersAndExclusions() {
        CriteriaService.BuildResult b = CriteriaService.toQueryParts(sample());

        // title, certification, location, filter, placed-recently exclusion
        System.assertEquals(5, b.parts.size());
        System.assertEquals(new List<String>{ 'c1', 'c2', 'c3', 'filter:candidate_status', 'exclusion:placedWithinDays' }, b.criteriaIds);

        System.assertEquals('FULLTEXT', b.parts[0].field);
        System.assertEquals('REQUIRED', b.parts[0].condition);
        System.assertEquals('"Warehouse Operative"', b.parts[0].values[0]);

        System.assertEquals('STRONGLY_FAVORED', b.parts[1].condition);
        System.assertEquals('"Certified Forklift Operator"', b.parts[1].values[0]);

        System.assertEquals('city', b.parts[2].field);
        System.assertEquals('Dagenham+15', b.parts[2].values[0]);

        System.assertEquals('candidate_status', b.parts[3].field);
        System.assertEquals('REQUIRED', b.parts[3].condition);

        System.assertEquals('custom_date_1', b.parts[4].field);
        System.assertEquals('EXCLUDED', b.parts[4].condition);
        System.assert(b.parts[4].values[0].endsWith(String.valueOf(Date.today())), b.parts[4].values[0]);
    }

    @isTest
    static void skillWithCodeAddsACodePartThatOnlyAddsScore() {
        Map<String, Object> c = CriteriaService.newCriteria('user');
        Map<String, Object> s = chip('c1', 'skill', 'Forklift Truck Operation', 'required');
        s.put('code', 'KS120076FGP5WGWYMP0F');
        CriteriaService.items(c).add(s);
        CriteriaService.BuildResult b = CriteriaService.toQueryParts(c);
        System.assertEquals(2, b.parts.size());
        System.assertEquals('REQUIRED', b.parts[0].condition);
        System.assertEquals('it_skills', b.parts[1].field);
        System.assertEquals('STRONGLY_FAVORED', b.parts[1].condition);
        System.assertEquals(new List<String>{ 'c1', 'c1' }, b.criteriaIds);
    }

    @isTest
    static void excludedKmLocationShiftLanguageAndAvailability() {
        Map<String, Object> c = CriteriaService.newCriteria('user');
        Map<String, Object> loc = chip('c1', 'location', 'RM9 6SA', 'required');
        loc.put('radius', 10);
        loc.put('unit', 'km');
        CriteriaService.items(c).add(loc);
        CriteriaService.items(c).add(chip('c2', 'shift', 'nights', 'excluded'));
        CriteriaService.items(c).add(chip('c3', 'language', 'Polish', 'preferred'));
        Map<String, Object> av = chip('c4', 'availability', null, 'required');
        av.put('withinDays', 28);
        av.put('label', 'Available within 4 weeks');
        CriteriaService.items(c).add(av);

        CriteriaService.BuildResult b = CriteriaService.toQueryParts(c);
        System.assertEquals('RM9 6SA+6', b.parts[0].values[0]);
        System.assertEquals('EXCLUDED', b.parts[1].condition);
        System.assertEquals('Polish', b.parts[2].values[0]);
        // Availability field not configured by default: not sent, with a notice
        System.assertEquals(3, b.parts.size());
        System.assertEquals(1, b.notices.size());

        CandidateSearchConfig cfg = new CandidateSearchConfig();
        cfg.tkAvailabilityField = 'custom_date_2';
        CandidateSearchConfig.overrideForTest(cfg);
        b = CriteriaService.toQueryParts(c);
        System.assertEquals(4, b.parts.size());
        System.assertEquals('custom_date_2', b.parts[3].field);
        System.assert(b.parts[3].values[0].startsWith('1900-01-01..'), b.parts[3].values[0]);
    }

    // ─── fromTkQueryParts ────────────────────────────────────────

    private static List<TkSearchClient.QueryPart> generatedParts() {
        List<TkSearchClient.QueryPart> parts = new List<TkSearchClient.QueryPart>();
        parts.add(tkPart('jobtitles', 'REQUIRED', 'Warehouse Operative'));
        parts.add(tkPart('it_skills', 'FAVORED', 'KS1234567890ABCDEFGH'));
        parts.add(tkPart('city', 'REQUIRED', 'London+10'));
        parts.add(tkPart('text_fingerprint', 'FAVORED', 'forklift warehouse picking'));
        parts.add(tkPart('education_level', 'STRONGLY_FAVORED', '3'));
        return parts;
    }

    private static TkSearchClient.QueryPart tkPart(String field, String condition, String value) {
        TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
        p.field = field;
        p.condition = condition;
        p.values.add(value);
        p.xml = '<queryParts><field>' + field + '</field><condition>' + condition + '</condition><weight>1.0</weight><items><value>' + value + '</value></items></queryParts>';
        return p;
    }

    @isTest
    static void fromTkQueryPartsMapsGeneratedPartsToChips() {
        List<Object> chips = CriteriaService.fromTkQueryParts(generatedParts());
        System.assertEquals(5, chips.size());
        Map<String, Object> title = (Map<String, Object>) chips[0];
        System.assertEquals('title', title.get('kind'));
        System.assertEquals('required', title.get('weight'));
        System.assertEquals('tk_generated', title.get('origin'));
        Map<String, Object> skill = (Map<String, Object>) chips[1];
        System.assertEquals('skill', skill.get('kind'));
        System.assertEquals('KS1234567890ABCDEFGH', skill.get('code'));
        Map<String, Object> loc = (Map<String, Object>) chips[2];
        System.assertEquals('location', loc.get('kind'));
        System.assertEquals('London', loc.get('value'));
        System.assertEquals(10, ((Decimal) loc.get('radius')).intValue());
        System.assertEquals('fingerprint', ((Map<String, Object>) chips[3]).get('kind'));
        System.assertEquals('Job description', ((Map<String, Object>) chips[3]).get('label'));
        System.assertEquals('tk_raw', ((Map<String, Object>) chips[4]).get('kind'));
        System.assertEquals('strongly_preferred', ((Map<String, Object>) chips[4]).get('weight'));
    }

    @isTest
    static void unchangedGeneratedPartsGoBackVerbatim() {
        Map<String, Object> c = CriteriaService.newCriteria('job');
        c.put('items', CriteriaService.fromTkQueryParts(generatedParts()));
        // Round trip through JSON, as the LWC does
        c = CriteriaService.parse(CriteriaService.serialize(c));
        CriteriaService.validate(c);

        CriteriaService.BuildResult b = CriteriaService.toQueryParts(c);
        System.assertEquals(5, b.parts.size());
        for (TkSearchClient.QueryPart p : b.parts) System.assertNotEquals(null, p.xml, p.field);
        System.assert(TkSearchClient.partXml(b.parts[0]).contains('<field>jobtitles</field>'));
        System.assertEquals(new List<String>{ 'c1', 'c2', 'c3', 'c4', 'c5' }, b.criteriaIds);
    }

    @isTest
    static void editedGeneratedLocationIsRebuilt() {
        Map<String, Object> c = CriteriaService.newCriteria('job');
        c.put('items', CriteriaService.fromTkQueryParts(generatedParts()));
        c = CriteriaService.parse(CriteriaService.serialize(c));
        CriteriaService.PatchResult r = CriteriaService.applyPatch(c, '[{"op":"update","id":"c3","set":{"radius":25}}]');
        CriteriaService.BuildResult b = CriteriaService.toQueryParts(r.criteria);
        System.assertEquals(null, b.parts[2].xml);
        System.assertEquals('London+25', b.parts[2].values[0]);
        System.assertEquals('London + 25 mi', CriteriaService.findItem(r.criteria, 'c3').get('label'));
        // Title untouched: still verbatim
        System.assertNotEquals(null, b.parts[0].xml);
    }

    // ─── applyPatch ──────────────────────────────────────────────

    @isTest
    static void applyPatchRunsEveryOpAndLeavesTheInputAlone() {
        Map<String, Object> c = sample();
        String patch = '[' +
            '{"op":"add","item":{"kind":"shift","label":"Nights","value":"nights","weight":"preferred"}},' +
            '{"op":"update","id":"c3","set":{"radius":25}},' +
            '{"op":"remove","id":"c2"},' +
            '{"op":"setExclusion","key":"placedWithinDays","value":60},' +
            '{"op":"setExclusion","key":"pipelineForJob","value":false},' +
            '{"op":"setFilter","key":"candidate_status","values":[]},' +
            '{"op":"setFilter","key":"owner_id","values":["005000000000001"]}' +
        ']';
        CriteriaService.PatchResult r = CriteriaService.applyPatch(c, patch);

        System.assertEquals(7, r.diff.size());
        System.assertEquals(3, CriteriaService.items(r.criteria).size());
        Map<String, Object> added = CriteriaService.findItem(r.criteria, 'c4');
        System.assertEquals('shift', added.get('kind'));
        System.assertEquals('refine', added.get('origin'));
        System.assertEquals(null, CriteriaService.findItem(r.criteria, 'c2'));
        System.assertEquals('Dagenham + 25 mi', CriteriaService.findItem(r.criteria, 'c3').get('label'));
        System.assertEquals(60, CriteriaService.exclusions(r.criteria).get('placedWithinDays'));
        System.assert(!CriteriaService.exclusions(r.criteria).containsKey('pipelineForJob'));
        System.assert(!CriteriaService.filters(r.criteria).containsKey('candidate_status'));
        System.assert(CriteriaService.filters(r.criteria).containsKey('owner_id'));

        // input unchanged
        System.assertEquals(3, CriteriaService.items(c).size());
        System.assertNotEquals(null, CriteriaService.findItem(c, 'c2'));
    }

    @isTest
    static void applyPatchAcceptsTheWholeRefineOutput() {
        CriteriaService.PatchResult r = CriteriaService.applyPatch(sample(), '{"patch":[{"op":"remove","id":"c1"}],"reply":"ok"}');
        System.assertEquals(2, CriteriaService.items(r.criteria).size());
    }

    @isTest
    static void applyPatchRejectsBadOps() {
        assertPatchFails('[{"op":"remove","id":"c99"}]', 'no criterion with id');
        assertPatchFails('[{"op":"explode"}]', 'Unknown patch operation');
        assertPatchFails('[{"op":"update","id":"c1","set":{"origin":"nl"}}]', 'cannot be changed');
        assertPatchFails('[{"op":"setExclusion","key":"moon","value":1}]', 'Unknown exclusion');
        assertPatchFails('[{"op":"add"}]', 'needs an item');
        assertPatchFails('{"a":1}', 'must be a list');
    }

    @isTest
    static void readOnlyChipsCanOnlyBeRemoved() {
        Map<String, Object> c = CriteriaService.newCriteria('job');
        c.put('items', CriteriaService.fromTkQueryParts(generatedParts()));
        try {
            CriteriaService.applyPatch(c, '[{"op":"update","id":"c4","set":{"weight":"required"}}]');
            System.assert(false, 'expected an error');
        } catch (CriteriaService.CriteriaException e) {
            System.assert(e.getMessage().contains('can only be removed'), e.getMessage());
        }
        CriteriaService.PatchResult r = CriteriaService.applyPatch(c, '[{"op":"remove","id":"c4"}]');
        System.assertEquals(4, CriteriaService.items(r.criteria).size());
    }

    private static void assertPatchFails(String patch, String expected) {
        try {
            CriteriaService.applyPatch(sample(), patch);
            System.assert(false, 'expected an error containing ' + expected);
        } catch (CriteriaService.CriteriaException e) {
            System.assert(e.getMessage().containsIgnoreCase(expected), e.getMessage());
        }
    }

    // ─── Job record and refineFromJob ────────────────────────────

    private static SObject fakeJob() {
        SObject job = Schema.getGlobalDescribe().get('TR1__Job__c').newSObject();
        job.put('TR1__Job_Title__c', 'Warehouse Operative');
        job.put('TR1__City__c', 'Dagenham');
        return job;
    }

    @isTest
    static void refineFromJobAddsLocationCapsSkillsAndSoftensTitle() {
        CandidateSearchConfig cfg = new CandidateSearchConfig();
        cfg.maxSkillParts = 1;
        CandidateSearchConfig.overrideForTest(cfg);

        List<TkSearchClient.QueryPart> parts = new List<TkSearchClient.QueryPart>{
            tkPart('jobtitles', 'REQUIRED', 'Warehouse Operative'),
            tkPart('it_skills', 'FAVORED', 'KS1'),
            tkPart('profskills', 'FAVORED', 'picking')
        };
        Map<String, Object> c = CriteriaService.newCriteria('job');
        c.put('items', CriteriaService.fromTkQueryParts(parts));

        System.assert(CriteriaService.refineFromJob(c, fakeJob()));
        List<Object> chips = CriteriaService.items(c);
        System.assertEquals(3, chips.size()); // title, 1 skill, added location
        System.assertEquals('strongly_preferred', ((Map<String, Object>) chips[0]).get('weight'));
        Map<String, Object> loc = (Map<String, Object>) chips[2];
        System.assertEquals('location', loc.get('kind'));
        System.assertEquals('Dagenham', loc.get('value'));
        System.assertEquals('job', loc.get('origin'));

        // Nothing left to change
        System.assert(!CriteriaService.refineFromJob(c, fakeJob()));
    }

    @isTest
    static void refineFromJobRulesCanBeSwitchedOff() {
        CandidateSearchConfig cfg = new CandidateSearchConfig();
        cfg.addJobLocation = false;
        cfg.capSkillParts = false;
        cfg.softJobTitle = false;
        CandidateSearchConfig.overrideForTest(cfg);
        Map<String, Object> c = CriteriaService.newCriteria('job');
        c.put('items', CriteriaService.fromTkQueryParts(generatedParts()));
        System.assert(!CriteriaService.refineFromJob(c, fakeJob()));
    }

    @isTest
    static void fromJobRecordBuildsTitleAndLocation() {
        SObject job = fakeJob();
        Map<String, Object> c = CriteriaService.fromJobRecord(job);
        CriteriaService.validate(c);
        List<Object> chips = CriteriaService.items(c);
        System.assertEquals('title', ((Map<String, Object>) chips[0]).get('kind'));
        System.assertEquals('location', ((Map<String, Object>) chips[1]).get('kind'));
        System.assertEquals('job', c.get('source'));
    }

    // ─── Helpers ─────────────────────────────────────────────────

    @isTest
    static void hashIgnoresChipOrderAndTrace() {
        Map<String, Object> a = sample();
        Map<String, Object> b = sample();
        List<Object> items = CriteriaService.items(b);
        Object first = items.remove(0);
        items.add(first);
        b.put('trace', new Map<String, Object>{ 'searchType' => 'Refine' });
        System.assertEquals(CriteriaService.hash(a), CriteriaService.hash(b));
        System.assertEquals('Refine', CriteriaService.stripTrace(b).get('searchType'));
        System.assert(!b.containsKey('trace'));
    }

    @isTest
    static void conditionAndWeightRoundTrip() {
        for (String w : CriteriaService.WEIGHTS) {
            System.assertEquals(w, CriteriaService.weightFor(CriteriaService.conditionFor(w)));
        }
        System.assertEquals('preferred', CriteriaService.weightFor(null));
        System.assertEquals('"reach truck"', CriteriaService.quote('reach truck'));
    }
}
