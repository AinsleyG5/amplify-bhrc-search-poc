/**
 * CandidateSearchConfig
 *
 * Typed view of Candidate_Search_Config__mdt (record Default) and Candidate_Search_Prompt__mdt.
 * Every value has a default, so a missing record or a blank field never breaks a search, and tests
 * run without depending on the deployed records.
 *
 * Tests replace the values with CandidateSearchConfig.overrideForTest(...).
 */
public with sharing class CandidateSearchConfig {

    public String tkCandidateEnvironment = 'tksf_bh4sf_tso_cv';
    public String tkCandidateSearchEngine;
    public String tkJobEnvironment = 'tksf_bh4sf_tso_vac';
    public String tkJobSearchEngine = 'vacancies';
    public String tkNamedCredential = 'TK_Candidate_Search';
    public String tkExternalCredential = 'TK_Search_Service_Account';
    public String tkAccessRoles = 'all';
    public String tkExcludeCondition = 'EXCLUDED';
    public List<String> tkResultFields = new List<String>{
        'fullname', 'jobtitles', 'recent_jobtitles', 'city', 'candidate_status',
        'custom_date_1', 'owner_id', 'owner_name', 'it_skills', 'profskills'
    };
    public String tkTitleField = 'FULLTEXT';
    public String tkSkillCodeField = 'it_skills';
    public String tkCertificationCodeField;
    public String tkLanguageField;
    public String tkAvailabilityField;
    public String tkLocationField = 'city';
    public String tkLastPlacementField = 'custom_date_1';
    public Integer tkTimeoutMs = 30000;

    public String skillsNamedCredential = 'Tx_Skills_API';
    public String skillsAutocompletePath = '/v10/skills/v2/autocomplete';
    public String txAccountId = '13430659';
    public List<String> autocompleteLanguages = new List<String>{ 'en' };

    public String llmProvider = 'Anthropic';
    public String anthropicNamedCredential = 'Anthropic_API';

    public String applicationCandidateField = 'TR1__Applicant__c';

    public Integer pageSize = 20;
    public Integer explainBatchSize = 10;
    public Integer defaultRadiusMiles = 15;
    public Integer maxSkillParts = 8;
    public Integer recentSearchesKept = 10;
    public Boolean softJobTitle = true;
    public Boolean addJobLocation = true;
    public Boolean capSkillParts = true;

    private static CandidateSearchConfig current;

    @TestVisible
    private static Boolean readMetadataInTests = false;

    public static CandidateSearchConfig get() {
        if (current == null) {
            current = load();
        }
        return current;
    }

    @TestVisible
    private static void overrideForTest(CandidateSearchConfig cfg) {
        current = cfg;
    }

    private static CandidateSearchConfig load() {
        CandidateSearchConfig cfg = new CandidateSearchConfig();
        Candidate_Search_Config__mdt rec;
        try {
            rec = Candidate_Search_Config__mdt.getInstance('Default');
        } catch (Exception e) {
            rec = null;
        }
        // Tests use the defaults unless they ask for the deployed record, so org config cannot break them
        if (rec == null || (Test.isRunningTest() && !readMetadataInTests)) {
            return cfg;
        }

        cfg.tkCandidateEnvironment = text(rec.TK_Candidate_Environment__c, cfg.tkCandidateEnvironment);
        cfg.tkCandidateSearchEngine = text(rec.TK_Candidate_Search_Engine__c, null);
        cfg.tkJobEnvironment = text(rec.TK_Job_Environment__c, cfg.tkJobEnvironment);
        cfg.tkJobSearchEngine = text(rec.TK_Job_Search_Engine__c, cfg.tkJobSearchEngine);
        cfg.tkNamedCredential = text(rec.TK_Named_Credential__c, cfg.tkNamedCredential);
        cfg.tkExternalCredential = text(rec.TK_External_Credential__c, cfg.tkExternalCredential);
        cfg.tkAccessRoles = text(rec.TK_Access_Roles__c, cfg.tkAccessRoles);
        cfg.tkExcludeCondition = text(rec.TK_Exclude_Condition__c, cfg.tkExcludeCondition);
        if (String.isNotBlank(rec.TK_Result_Fields__c)) {
            cfg.tkResultFields = splitList(rec.TK_Result_Fields__c);
        }
        cfg.tkTitleField = text(rec.TK_Title_Field__c, cfg.tkTitleField);
        cfg.tkSkillCodeField = text(rec.TK_Skill_Code_Field__c, cfg.tkSkillCodeField);
        cfg.tkCertificationCodeField = text(rec.TK_Certification_Code_Field__c, null);
        cfg.tkLanguageField = text(rec.TK_Language_Field__c, null);
        cfg.tkAvailabilityField = text(rec.TK_Availability_Field__c, null);
        cfg.tkLocationField = text(rec.TK_Location_Field__c, cfg.tkLocationField);
        cfg.tkLastPlacementField = text(rec.TK_Last_Placement_Field__c, cfg.tkLastPlacementField);
        cfg.tkTimeoutMs = num(rec.TK_Timeout_Seconds__c, 30) * 1000;

        cfg.skillsNamedCredential = text(rec.Skills_Named_Credential__c, cfg.skillsNamedCredential);
        cfg.skillsAutocompletePath = text(rec.Skills_Autocomplete_Path__c, cfg.skillsAutocompletePath);
        cfg.txAccountId = text(rec.Tx_Account_Id__c, cfg.txAccountId);
        if (String.isNotBlank(rec.Autocomplete_Languages__c)) {
            cfg.autocompleteLanguages = splitList(rec.Autocomplete_Languages__c);
        }

        cfg.llmProvider = text(rec.LLM_Provider__c, cfg.llmProvider);
        cfg.anthropicNamedCredential = text(rec.Anthropic_Named_Credential__c, cfg.anthropicNamedCredential);
        cfg.applicationCandidateField = text(rec.Application_Candidate_Field__c, cfg.applicationCandidateField);

        cfg.pageSize = num(rec.Page_Size__c, cfg.pageSize);
        cfg.explainBatchSize = num(rec.Explain_Batch_Size__c, cfg.explainBatchSize);
        cfg.defaultRadiusMiles = num(rec.Default_Radius_Miles__c, cfg.defaultRadiusMiles);
        cfg.maxSkillParts = num(rec.Max_Skill_Parts__c, cfg.maxSkillParts);
        cfg.recentSearchesKept = num(rec.Recent_Searches_Kept__c, cfg.recentSearchesKept);
        cfg.softJobTitle = rec.Soft_Job_Title__c == true;
        cfg.addJobLocation = rec.Add_Job_Location__c == true;
        cfg.capSkillParts = rec.Cap_Skill_Parts__c == true;
        return cfg;
    }

    // ─── Prompts ───────────────────────────────────────────────

    public class PromptConfig {
        public String name;
        public String systemPrompt;
        public String model;
        public Integer maxTokens;
        public Integer timeoutMs;
        public String toolName;
        public String toolDescription;
        public String toolSchemaJson;
        public String templateName;
    }

    @TestVisible
    private static Map<String, PromptConfig> promptOverrides = new Map<String, PromptConfig>();

    /** Reads one Candidate_Search_Prompt__mdt record by developer name. Throws a readable message when it is missing. */
    public static PromptConfig prompt(String name) {
        if (promptOverrides.containsKey(name)) {
            return promptOverrides.get(name);
        }
        Candidate_Search_Prompt__mdt rec = Candidate_Search_Prompt__mdt.getInstance(name);
        if (rec == null) {
            throw new CandidateSearchException('Prompt ' + name + ' is missing from Candidate Search Prompt custom metadata.');
        }
        PromptConfig p = new PromptConfig();
        p.name = name;
        p.systemPrompt = rec.System_Prompt__c;
        p.model = rec.Model__c;
        p.maxTokens = num(rec.Max_Tokens__c, 1024);
        p.timeoutMs = num(rec.Timeout_Seconds__c, 30) * 1000;
        p.toolName = rec.Tool_Name__c;
        p.toolDescription = rec.Tool_Description__c;
        p.toolSchemaJson = rec.Tool_Schema_JSON__c;
        p.templateName = text(rec.Prompt_Template_Name__c, name);
        return p;
    }

    // ─── Helpers ───────────────────────────────────────────────

    public class CandidateSearchException extends Exception {}

    private static String text(String v, String fallback) {
        return String.isBlank(v) ? fallback : v.trim();
    }

    private static Integer num(Decimal v, Integer fallback) {
        return v == null ? fallback : v.intValue();
    }

    private static List<String> splitList(String v) {
        List<String> out = new List<String>();
        for (String s : v.split(',')) {
            if (String.isNotBlank(s)) out.add(s.trim());
        }
        return out;
    }
}
