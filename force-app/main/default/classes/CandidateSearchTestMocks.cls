/**
 * CandidateSearchTestMocks
 *
 * One HttpCalloutMock for every Candidate Search callout, routed by Named Credential:
 *   callout:TK_Candidate_Search  SOAP search / searchWithUrl / getMetadata
 *   callout:Tx_Skills_API        skills autocomplete
 *   callout:Anthropic_API        Messages API, answering with the forced tool's input
 * No test calls a real Textkernel, Tx or Anthropic endpoint.
 */
@isTest
public class CandidateSearchTestMocks implements HttpCalloutMock {

    public static List<HttpRequest> requests = new List<HttpRequest>();

    /** Doc ids returned by the TK mock, in rank order. */
    public static List<String> docIds = new List<String>();
    /** Per-query-part scores per hit (same for every hit when one list is given). */
    public static List<String> partScores = new List<String>{ '1.0', '0.0' };
    public static Integer total;
    public static Boolean hasMore = false;
    /** Generated parts echoed by searchWithUrl. */
    /** Shape confirmed by job match on tksf_bh4sf_tso_vac: synonyms per item, coordinates on city, FULLTEXT keywords. */
    public static String echoedPartsXml =
        '<queryParts><field>jobtitles</field><condition>REQUIRED</condition><weight>1.0</weight><items><value>[Warehouse Operative]</value><synonyms>Warehouse Worker</synonyms><synonyms>Picker</synonyms></items></queryParts>'
        + '<queryParts><field>it_skills</field><condition>FAVORED</condition><weight>1.0</weight><items><value>KS1234567890ABCDEFGH</value><synonyms>Forklift Truck Operation</synonyms></items></queryParts>'
        + '<queryParts><field>text_fingerprint</field><condition>FAVORED</condition><weight>0.5</weight><items><value>Document</value></items></queryParts>'
        + '<queryParts><field>city</field><condition>STRONGLY_FAVORED</condition><weight>1.0</weight><items><value>GB Dagenham+25@51.5397 0.1436</value></items></queryParts>'
        + '<queryParts><field>FULLTEXT</field><condition>FAVORED</condition><weight>1.0</weight><items><value>continuous improvement</value><synonyms>Kaizen</synonyms></items></queryParts>';
    public static Integer tkStatus = 200;
    public static Boolean tkFault = false;
    public static Boolean searchWithUrlFault = false;

    /** Anthropic tool input by tool name (JSON). A list gives successive answers for retries. */
    public static Map<String, List<String>> toolInputs = new Map<String, List<String>>();
    public static Integer anthropicStatus = 200;

    public static String skillsBody = '{"Value":{"Skills":[{"Id":"KS120076FGP5WGWYMP0F","Description":"Forklift Truck Operation","Category":"Logistics"}]}}';
    public static Integer skillsStatus = 200;
    public static String viewDocumentHtml = '<div><p>CV</p></div>';

    public static void install() {
        Test.setMock(HttpCalloutMock.class, new CandidateSearchTestMocks());
    }

    public HttpResponse respond(HttpRequest req) {
        requests.add(req);
        String endpoint = req.getEndpoint();
        HttpResponse res = new HttpResponse();
        if (endpoint.startsWith('callout:TK_Candidate_Search')) {
            res.setHeader('Content-Type', 'text/xml');
            res.setStatusCode(tkStatus);
            String body = req.getBody();
            Boolean withUrl = body.contains('<sear:searchWithUrl>');
            if (tkFault || (withUrl && searchWithUrlFault)) {
                res.setStatusCode(500);
                res.setBody(fault('Document not found'));
            } else if (body.contains('<sear:getMetadata>')) {
                res.setBody(envelope('getMetadataResponse', '<fields><name>jobtitles</name></fields>'));
            } else {
                res.setBody(searchResponse(withUrl));
            }
        } else if (endpoint.startsWith('callout:TK_View_Document')) {
            res.setStatusCode(200);
            res.setBody(envelope('viewDocumentResponse', '<return>' + viewDocumentHtml.escapeXml() + '</return>'));
        } else if (endpoint.startsWith('callout:Tx_Skills_API')) {
            res.setStatusCode(skillsStatus);
            if (endpoint.contains('/professions/autocomplete')) {
                res.setBody('{"Value":{"Professions":[{"CodeId":2357,"Description":"Forklift Operator"}]}}');
            } else if (endpoint.contains('/ontology/')) {
                res.setBody('{"Value":{"SuggestedSkills":[{"Id":"KS120076FGP5WGWYMP0F","Description":"Forklift Truck Operation","Score":0.92},{"Id":"KS440W865GC4VRBW6LJP","Description":"Reach Truck","Score":0.81}]}}');
            } else {
                res.setBody(skillsBody);
            }
        } else if (endpoint.startsWith('callout:Anthropic_API')) {
            res.setStatusCode(anthropicStatus);
            if (anthropicStatus != 200) {
                res.setBody('{"type":"error","error":{"type":"invalid_request_error","message":"bad request"}}');
                return res;
            }
            // Structured outputs: the answer is a text block. The prompt is identified from the system prompt
            // (usePrompts() puts the prompt name in it); toolInputs stays keyed by the schema's old tool name.
            Map<String, Object> body = (Map<String, Object>) System.JSON.deserializeUntyped(req.getBody());
            String systemPrompt = String.valueOf(body.get('system'));
            String tool = systemPrompt.contains(SearchAiService.PARSE_PROMPT) ? 'set_criteria'
                : systemPrompt.contains(SearchAiService.REFINE_PROMPT) ? 'update_criteria' : 'explain_candidates';
            List<String> queue = toolInputs.get(tool);
            String input = queue == null || queue.isEmpty() ? '{}' : (queue.size() > 1 ? queue.remove(0) : queue[0]);
            res.setBody(System.JSON.serialize(new Map<String, Object>{
                'id' => 'msg_test', 'type' => 'message', 'role' => 'assistant', 'model' => body.get('model'),
                'content' => new List<Object>{
                    new Map<String, Object>{ 'type' => 'thinking', 'thinking' => '', 'signature' => 'sig' },
                    new Map<String, Object>{ 'type' => 'text', 'text' => input }
                },
                'stop_reason' => 'end_turn',
                'usage' => new Map<String, Object>{ 'input_tokens' => 120, 'output_tokens' => 45 }
            }));
        } else {
            res.setStatusCode(404);
            res.setBody('Unknown endpoint ' + endpoint);
        }
        return res;
    }

    public static String searchResponse(Boolean withUrl) {
        String items = '';
        for (String d : docIds) {
            items += '<resultItems><docID>' + d + '</docID><score>0.98</score>';
            for (String s : partScores) items += '<queryPartScores>' + s + '</queryPartScores>';
            // Shape confirmed against tksf_bh4sf_tso_cv: fieldValues entries, highlighting inline with <b>
            items += '<fieldValues>'
                + '<entry><key>profskills</key><value/></entry>'
                + '<entry><key>jobtitles</key><value><item><value>&lt;b&gt;Certified Forklift Operator&lt;/b&gt;</value></item></value></entry>'
                + '<entry><key>city</key><value><item><value>GB London</value></item></value></entry>'
                + '<entry><key>fullname</key><value><item><value>Ethan Kirby</value></item></value></entry>'
                + '</fieldValues>'
                + '</resultItems>';
        }
        Integer t = total == null ? docIds.size() : total;
        String body = '<matchSize>' + t + '</matchSize><hasMoreResults>' + hasMore + '</hasMoreResults>' + items
            + '<facets><field>candidate_status</field><items><value>Available</value><count>4</count></items>'
            + '<items><value>Placed</value><count>2</count></items></facets>'
            + (withUrl ? '<query>' + echoedPartsXml + '</query>' : '');
        return envelope(withUrl ? 'searchWithUrlResponse' : 'searchResponse', '<return>' + body + '</return>');
    }

    public static String envelope(String op, String body) {
        return '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
            + '<ns2:' + op + ' xmlns:ns2="http://home.textkernel.nl/search">' + body + '</ns2:' + op + '>'
            + '</soap:Body></soap:Envelope>';
    }

    public static String fault(String msg) {
        return '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><soap:Fault>'
            + '<faultcode>soap:Server</faultcode><faultstring>' + msg + '</faultstring></soap:Fault></soap:Body></soap:Envelope>';
    }

    /** "00D…_003…" for a Contact, the format seen in the index. */
    public static String docIdFor(Id contactId) {
        return UserInfo.getOrganizationId().left(15) + '_' + contactId;
    }

    public static List<Contact> contacts(Integer n) {
        List<Contact> cs = new List<Contact>();
        for (Integer i = 0; i < n; i++) {
            cs.add(new Contact(FirstName = 'Test' + i, LastName = 'Candidate' + i, Title = 'Warehouse Operative', MailingCity = 'Dagenham'));
        }
        insert cs;
        docIds = new List<String>();
        for (Contact c : cs) docIds.add(docIdFor(c.Id));
        return cs;
    }

    // ─── Prompts, independent of the deployed custom metadata ───

    public static void usePrompts() {
        for (String name : new List<String>{ SearchAiService.PARSE_PROMPT, SearchAiService.REFINE_PROMPT, SearchAiService.EXPLAIN_PROMPT }) {
            CandidateSearchConfig.PromptConfig p = new CandidateSearchConfig.PromptConfig();
            p.name = name;
            p.systemPrompt = 'Test prompt ' + name;
            p.model = name == SearchAiService.EXPLAIN_PROMPT ? 'claude-sonnet-5-5' : 'claude-haiku-5-5';
            p.maxTokens = 1024;
            p.timeoutMs = 30000;
            p.toolName = name == SearchAiService.PARSE_PROMPT ? 'set_criteria'
                : name == SearchAiService.REFINE_PROMPT ? 'update_criteria' : 'explain_candidates';
            p.toolDescription = 'test';
            p.toolSchemaJson = '{"type":"object","properties":{"items":{"type":"array","maxItems":25,"items":{"type":"object","properties":{"label":{"type":"string","maxLength":120},"value":{"description":"any"}}}}}}';
            p.effort = name == SearchAiService.EXPLAIN_PROMPT ? 'medium' : 'low';
            p.templateName = name;
            CandidateSearchConfig.promptOverrides.put(name, p);
        }
    }

    public static final String PARSE_OUTPUT = '{"items":['
        + '{"kind":"title","label":"Warehouse Operative","value":"Warehouse Operative","weight":"required"},'
        + '{"kind":"certification","label":"Certified Forklift Operator","value":"Certified Forklift Operator","weight":"strongly_preferred"},'
        + '{"kind":"location","label":"Dagenham + 15 mi","value":"Dagenham","weight":"required"}'
        + '],"filters":{"candidate_status":["Available"]}}';

    public static String criteriaJson() {
        return '{"version":1,"source":"nl","naturalLanguage":"Forklift-certified warehouse operatives within 15 miles of Dagenham",'
            + '"jobId":null,"tkJobDocId":null,"items":['
            + '{"id":"c1","kind":"title","label":"Warehouse Operative","value":"Warehouse Operative","weight":"required","origin":"nl"},'
            + '{"id":"c2","kind":"certification","label":"Certified Forklift Operator","value":"Certified Forklift Operator","code":null,"weight":"strongly_preferred","origin":"nl"},'
            + '{"id":"c3","kind":"location","label":"Dagenham + 15 mi","value":"Dagenham","radius":15,"unit":"mi","weight":"required","origin":"nl"}'
            + '],"filters":{"candidate_status":["Available"]},"exclusions":{"pipelineForJob":true,"placedWithinDays":30}}';
    }
}
