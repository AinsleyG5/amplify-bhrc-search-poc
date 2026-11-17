@isTest
private class PipelineStatusServiceTest {

    @isTest
    static void noJobOrNoContactsMeansNoQueries() {
        System.assert(PipelineStatusService.flagsFor(null, new Set<Id>{ UserInfo.getUserId() }).isEmpty());
        System.assertEquals(0, Limits.getQueries());
    }

    @isTest
    static void runsTheThreeQueriesAndFailsSoft() {
        List<Contact> cs = CandidateSearchTestMocks.contacts(1);
        Id jobId = Id.valueOf(Schema.getGlobalDescribe().get('TR1__Job__c').getDescribe().getKeyPrefix() + '000000000001');
        Map<Id, PipelineStatusService.Flags> flags = PipelineStatusService.flagsFor(jobId, new Map<Id, Contact>(cs).keySet());
        System.assert(flags.isEmpty(), 'nobody is on a job that does not exist');

        CandidateSearchConfig cfg = new CandidateSearchConfig();
        cfg.applicationCandidateField = 'Not_A_Field__c';
        CandidateSearchConfig.overrideForTest(cfg);
        PipelineStatusService.flagsFor(jobId, new Map<Id, Contact>(cs).keySet());
        Boolean warned = false;
        for (String w : PipelineStatusService.warnings) if (w.startsWith('Applied flags are off')) warned = true;
        System.assert(warned, String.valueOf(PipelineStatusService.warnings));
    }

    @isTest
    static void labelsReadLikeTheRowTags() {
        PipelineStatusService.Flags f = new PipelineStatusService.Flags();
        System.assert(!f.hasAny());
        System.assertEquals('', f.label());
        f.applied = true;
        f.stage = 'Interview';
        f.shortlisted = true;
        f.placed = true;
        f.placedDate = Date.newInstance(2026, 11, 3);
        System.assert(f.hasAny());
        System.assertEquals('Applied (Interview), Shortlisted, Placed 3 Nov', f.label());
    }
}
