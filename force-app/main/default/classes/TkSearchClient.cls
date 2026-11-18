/**
 * TkSearchClient
 *
 * Textkernel Search SOAP client for Candidate Search: search (structured query parts, paging, explicit result
 * fields), searchWithUrl (TK builds the query from the indexed job document) and getMetadata.
 *
 * Wraps AmplifyTKMatchService for the shared pieces (quoteTerm, normaliseScore, request masking) and adds what
 * that class does not parse: per-query-part scores, requested fields, highlights, facets and the query parts TK
 * echoes back (for searchWithUrl, the generated query).
 *
 * Credentials: the Named Credential (Candidate_Search_Config__mdt.TK_Named_Credential__c) points at the SOAP
 * endpoint and its External Credential holds the service account password, merged into the body with
 * {!$Credential.<External Credential>.Password} inside CDATA (HTMLENCODE is not allowed in callout body formulas),
 * so any character in the password stays valid XML. "Allow formulas in HTTP body" must be on. No password in code.
 *
 * The response is parsed with Dom.Document and is tolerant about element names, because the exact SearchResult
 * element names are still to be confirmed against the pilot service account (spec section 15). Each name list
 * below starts with the expected name.
 */
public with sharing class TkSearchClient {

    public static final String SOAP_NS = 'http://schemas.xmlsoap.org/soap/envelope/';
    public static final String SEARCH_NS = 'http://home.textkernel.nl/search';

    /** TK caps resultOffset + pageSize at 10000, and pageSize at 100 when paging. */
    public static final Integer MAX_WINDOW = 10000;
    public static final Integer MAX_PAGE_SIZE = 100;

    private static final List<String> TOTAL_NAMES = new List<String>{ 'matchSize', 'totalMatches', 'total', 'resultSize', 'totalResults', 'numberOfResults' };
    private static final List<String> HAS_MORE_NAMES = new List<String>{ 'hasMoreResults', 'hasMore' };
    private static final List<String> ITEM_NAMES = new List<String>{ 'resultItems', 'resultItem' };
    private static final List<String> DOC_ID_NAMES = new List<String>{ 'docID', 'docId', 'documentId', 'id' };
    private static final List<String> SCORE_NAMES = new List<String>{ 'score', 'relevance' };
    private static final List<String> PART_SCORE_NAMES = new List<String>{ 'queryPartScores', 'queryPartScore', 'queryPartMatches' };
    private static final List<String> FIELD_VALUE_NAMES = new List<String>{ 'values', 'fields', 'resultFields', 'fieldValues' };
    private static final List<String> HIGHLIGHT_NAMES = new List<String>{ 'highlights', 'highlighting', 'highlight' };
    private static final List<String> FACET_NAMES = new List<String>{ 'facets', 'facet' };
    private static final List<String> QUERY_PART_NAMES = new List<String>{ 'queryParts', 'queryPart' };

    // ═════════════════════════════════════════════════════════════
    // Types
    // ═════════════════════════════════════════════════════════════

    public class QueryPart {
        public String field;
        public String condition;
        public Decimal weight = 1.0;
        public List<String> values = new List<String>();
        /** Synonyms TK attached to the first item (for a KS code, the first one names the skill). */
        public List<String> synonyms = new List<String>();
        /**
         * The part as TK returned it, minus its <synonyms> lists. When set, it is sent back verbatim. Synonyms are
         * dropped because they can run to tens of kilobytes per part (job match on tksf_bh4sf_tso_vac) and TK
         * expands them again from the search itself (synonymExpansionMode QUERY_AND_QUERYPARTS).
         */
        public String xml;
        /** Chip the part came from (not sent to TK). */
        public String criteriaId;
    }

    public class SearchOptions {
        public Integer pageSize;
        public Integer offset = 0;
        public List<String> resultFields;
        /** Free-text query string, sent before the parts. Used for location, which TK only geo-interprets here. */
        public String query;
    }

    public class Hit {
        public String docId;
        public Id contactId;
        public Decimal score;
        public Decimal scorePct;
        public List<Decimal> queryPartScores = new List<Decimal>();
        public Map<String, List<String>> fields = new Map<String, List<String>>();
        public Map<String, List<String>> highlights = new Map<String, List<String>>();
        /** This result item, serialised and trimmed, for Search_Audit_Result__c.TK_Result_XML__c. */
        public String xml;
    }

    public class FacetValue {
        public String value;
        public Integer count;
    }

    public class Facet {
        public String field;
        public List<FacetValue> values = new List<FacetValue>();
    }

    public class Result {
        public String method;
        public Integer total = 0;
        public Boolean hasMore = false;
        public Integer offset = 0;
        public Integer pageSize;
        public List<Hit> hits = new List<Hit>();
        public List<Facet> facets = new List<Facet>();
        /** Query parts echoed by TK. For searchWithUrl these are the parts generated from the job document. */
        public List<QueryPart> queryParts = new List<QueryPart>();
        public String requestXml;
        public String responseXml;
        public Long durationMs;
    }

    public class TkException extends Exception {}

    // ═════════════════════════════════════════════════════════════
    // Operations
    // ═════════════════════════════════════════════════════════════

    public static Result search(List<QueryPart> parts, SearchOptions opts) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        if (opts == null) opts = new SearchOptions();
        if (parts == null) parts = new List<QueryPart>();
        if (parts.isEmpty() && String.isBlank(opts.query)) throw new TkException('There is nothing to search on.');

        Integer pageSize = opts.pageSize == null ? cfg.pageSize : opts.pageSize;
        pageSize = Math.max(1, Math.min(MAX_PAGE_SIZE, pageSize));
        Integer offset = opts.offset == null ? 0 : Math.max(0, opts.offset);
        if (offset + pageSize > MAX_WINDOW) {
            pageSize = MAX_WINDOW - offset;
            if (pageSize <= 0) throw new TkException('Textkernel returns at most ' + MAX_WINDOW + ' results per search. Narrow the search to see more.');
        }
        List<String> resultFields = opts.resultFields == null ? cfg.tkResultFields : opts.resultFields;

        String request = String.isBlank(opts.query) ? '' : '<query>' + opts.query.escapeXml() + '</query>';
        for (QueryPart p : parts) request += partXml(p);
        request += '<pageSize>' + pageSize + '</pageSize>';
        request += '<resultOffset>' + offset + '</resultOffset>';
        for (String f : resultFields) request += '<resultFields>' + f.escapeXml() + '</resultFields>';
        request += '<synonymExpansionMode>QUERY_AND_QUERYPARTS</synonymExpansionMode>';
        if (String.isNotBlank(cfg.tkCandidateSearchEngine)) {
            request += '<searchEngine>' + cfg.tkCandidateSearchEngine.escapeXml() + '</searchEngine>';
        }

        String body = envelope('search',
            credentialXml(cfg.tkCandidateEnvironment)
            + '<request>' + request + '</request>');

        Result r = send('search', body);
        r.offset = offset;
        r.pageSize = pageSize;
        return r;
    }

    /** searchWithUrl does not page: page 2 onwards uses search with the returned queryParts (spec 6.4). */
    public static Result searchWithUrl(String docUrl, Integer pageSize) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        Integer size = pageSize == null ? cfg.pageSize : Math.max(1, Math.min(MAX_PAGE_SIZE, pageSize));
        String body = envelope('searchWithUrl',
            credentialXml(cfg.tkCandidateEnvironment)
            + '<url>' + docUrl.escapeXml() + '</url>'
            + '<pageSize>' + size + '</pageSize>');
        Result r = send('searchWithUrl', body);
        r.pageSize = size;
        return r;
    }

    /** Raw getMetadata response, to confirm queryable field names (open item 3). */
    public static String getMetadata(String environment) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        String body = envelope('getMetadata', credentialXml(String.isBlank(environment) ? cfg.tkCandidateEnvironment : environment));
        HttpResponse res = callout(body);
        return res.getBody();
    }

    /** doc://<job environment>/<job searchEngine>/<org Id>_<job Id> */
    public static String jobDocUrl(Id jobId) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        return 'doc://' + cfg.tkJobEnvironment + '/' + cfg.tkJobSearchEngine + '/' + jobDocId(jobId);
    }

    /** The index uses the 15-character org Id seen in real doc ids (00DDp000001z8VW_a1wDp000001g5BiIAI). */
    public static String jobDocId(Id jobId) {
        return UserInfo.getOrganizationId().left(15) + '_' + String.valueOf(jobId);
    }

    // ═════════════════════════════════════════════════════════════
    // Request building
    // ═════════════════════════════════════════════════════════════

    @TestVisible
    private static String envelope(String operation, String innerXml) {
        return '<soapenv:Envelope xmlns:soapenv="' + SOAP_NS + '" xmlns:sear="' + SEARCH_NS + '">'
            + '<soapenv:Header/>'
            + '<soapenv:Body>'
            + '<sear:' + operation + '>' + innerXml + '</sear:' + operation + '>'
            + '</soapenv:Body>'
            + '</soapenv:Envelope>';
    }

    private static String credentialXml(String environment) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        return '<environment>' + String.valueOf(environment).escapeXml() + '</environment>'
            + '<password><![CDATA[{!$Credential.' + cfg.tkExternalCredential + '.Password}]]></password>'
            + '<accessRoles>' + cfg.tkAccessRoles.escapeXml() + '</accessRoles>';
    }

    public static String partXml(QueryPart p) {
        if (String.isNotBlank(p.xml)) return p.xml;
        String xml = '<queryParts>'
            + '<field>' + String.valueOf(p.field).escapeXml() + '</field>'
            + '<condition>' + String.valueOf(p.condition).escapeXml() + '</condition>'
            + '<weight>' + (p.weight == null ? '1.0' : String.valueOf(p.weight)) + '</weight>';
        for (String v : p.values) xml += '<items><value>' + v.escapeXml() + '</value></items>';
        return xml + '</queryParts>';
    }

    // ═════════════════════════════════════════════════════════════
    // Callout
    // ═════════════════════════════════════════════════════════════

    private static Result send(String method, String body) {
        Long started = System.currentTimeMillis();
        HttpResponse res = callout(body);
        Result r = parseResponse(res.getBody());
        r.method = method;
        r.requestXml = AmplifyTKMatchService.maskRequest(body.replaceAll('<password><!\\[CDATA\\[.*?\\]\\]></password>', '<password></password>'));
        r.durationMs = System.currentTimeMillis() - started;
        return r;
    }

    private static HttpResponse callout(String body) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + cfg.tkNamedCredential);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '""');
        req.setTimeout(Math.min(120000, cfg.tkTimeoutMs));
        req.setBody(body);

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            throw new TkException('Textkernel did not answer: ' + e.getMessage());
        }
        if (res.getStatusCode() != 200) {
            System.debug(LoggingLevel.ERROR, 'TK HTTP ' + res.getStatusCode() + ' from callout:' + cfg.tkNamedCredential + ' body: ' + res.getBody());
            throw new TkException(httpErrorText(cfg.tkNamedCredential, res));
        }
        return res;
    }

    /**
     * Readable HTTP error: status, which Named Credential was called, the SOAP fault or a text snippet of the body,
     * and what to check for the common statuses.
     */
    @TestVisible
    private static String httpErrorText(String namedCredential, HttpResponse res) {
        Integer code = res.getStatusCode();
        String body = res.getBody();
        String detail = faultText(body);
        if (String.isNotBlank(detail) && detail.contains('<')) detail = detail.stripHtmlTags();
        detail = String.isBlank(detail) ? null : detail.normalizeSpace().abbreviate(300);

        String msg = 'Textkernel returned HTTP ' + code + (String.isBlank(res.getStatus()) ? '' : ' ' + res.getStatus())
            + ' from the ' + namedCredential + ' Named Credential'
            + (detail == null ? ' (empty response body).' : ': ' + detail);
        if (!msg.endsWith('.')) msg += '.';

        if (code == 404 || code == 405) {
            msg += ' The URL on that Named Credential does not point at the Textkernel SOAP search service.'
                + ' Check it in Setup: it should be the same URL as TK_Agent_Search_Endpoint, which the Talent Pool viewer uses.';
        } else if (code == 401 || code == 403) {
            msg += ' Check the environment and password on the TK_Search_Service_Account External Credential, and that the user\'s permission set grants its principal.';
        } else if (code >= 500) {
            msg += ' Textkernel or the network is not answering. If the body mentions DNS, the Named Credential URL host is wrong.';
        }
        return msg;
    }

    // ═════════════════════════════════════════════════════════════
    // Response parsing
    // ═════════════════════════════════════════════════════════════

    @TestVisible
    private static Result parseResponse(String xml) {
        Result r = new Result();
        r.responseXml = xml;
        if (String.isBlank(xml)) throw new TkException('Textkernel returned an empty response.');

        Dom.Document doc = new Dom.Document();
        try {
            doc.load(xml);
        } catch (Exception e) {
            throw new TkException('Textkernel returned a response that is not XML: ' + e.getMessage());
        }

        Dom.XmlNode body = child(doc.getRootElement(), new List<String>{ 'Body' });
        if (body == null) throw new TkException('Textkernel response has no SOAP body.');
        Dom.XmlNode fault = child(body, new List<String>{ 'Fault' });
        if (fault != null) throw new TkException('Textkernel error: ' + firstText(fault, new List<String>{ 'faultstring', 'Reason', 'Text' }));

        Dom.XmlNode operation = firstElement(body);
        if (operation == null) throw new TkException('Textkernel response body is empty.');
        Dom.XmlNode ret = child(operation, new List<String>{ 'return' });
        if (ret == null) ret = operation;

        String total = firstText(ret, TOTAL_NAMES);
        String hasMore = firstText(ret, HAS_MORE_NAMES);

        for (Dom.XmlNode n : ret.getChildElements()) {
            String name = n.getName();
            if (ITEM_NAMES.contains(name)) {
                r.hits.add(parseHit(n));
            } else if (FACET_NAMES.contains(name)) {
                r.facets.add(parseFacet(n));
            } else if (QUERY_PART_NAMES.contains(name)) {
                r.queryParts.add(parseQueryPart(n));
            } else if (n.getChildElements().size() > 0) {
                // Echoed query, e.g. <query><queryParts>…</queryParts></query> or <request>…</request>
                for (Dom.XmlNode qp : n.getChildElements()) {
                    if (QUERY_PART_NAMES.contains(qp.getName())) r.queryParts.add(parseQueryPart(qp));
                }
            }
        }

        r.total = total != null && total.isNumeric() ? Integer.valueOf(total) : r.hits.size();
        r.hasMore = hasMore != null ? hasMore.equalsIgnoreCase('true') : r.total > r.hits.size();
        return r;
    }

    private static Hit parseHit(Dom.XmlNode n) {
        Hit h = new Hit();
        h.docId = firstText(n, DOC_ID_NAMES);
        h.contactId = contactIdFrom(h.docId);
        String score = firstText(n, SCORE_NAMES);
        if (score != null) {
            try {
                h.score = Decimal.valueOf(score);
            } catch (Exception e) {
                h.score = null;
            }
        }
        h.scorePct = AmplifyTKMatchService.normaliseScore(h.score);

        for (Dom.XmlNode c : n.getChildElements()) {
            String name = c.getName();
            if (PART_SCORE_NAMES.contains(name)) {
                // Either repeated <queryPartScores>1.0</queryPartScores>, or one element with child values
                List<Dom.XmlNode> kids = c.getChildElements();
                if (kids.isEmpty()) {
                    addDecimal(h.queryPartScores, c.getText());
                } else {
                    for (Dom.XmlNode k : kids) addDecimal(h.queryPartScores, leafText(k));
                }
            } else if (name == 'fieldValues' && !c.getChildElements().isEmpty() && c.getChildElements()[0].getName() == 'entry') {
                addEntries(h, c);
            } else if (FIELD_VALUE_NAMES.contains(name)) {
                addNamedValues(h.fields, c);
            } else if (HIGHLIGHT_NAMES.contains(name)) {
                addNamedValues(h.highlights, c);
            }
        }
        h.xml = serialize(n).abbreviate(131072);
        return h;
    }

    private static Facet parseFacet(Dom.XmlNode n) {
        Facet f = new Facet();
        f.field = firstText(n, new List<String>{ 'field', 'name', 'fieldName' });
        for (Dom.XmlNode c : n.getChildElements()) {
            if (c.getChildElements().isEmpty()) continue;
            FacetValue v = new FacetValue();
            v.value = firstText(c, new List<String>{ 'value', 'name', 'label', 'term' });
            String count = firstText(c, new List<String>{ 'count', 'frequency', 'size', 'docCount' });
            v.count = count != null && count.isNumeric() ? Integer.valueOf(count) : null;
            if (v.value != null) f.values.add(v);
        }
        return f;
    }

    @TestVisible
    private static QueryPart parseQueryPart(Dom.XmlNode n) {
        QueryPart p = new QueryPart();
        p.field = firstText(n, new List<String>{ 'field', 'fieldName' });
        p.condition = firstText(n, new List<String>{ 'condition' });
        String w = firstText(n, new List<String>{ 'weight' });
        if (w != null) {
            try {
                p.weight = Decimal.valueOf(w);
            } catch (Exception e) {
                p.weight = 1.0;
            }
        }
        for (Dom.XmlNode c : n.getChildElements()) {
            String name = c.getName();
            if (name == 'items' || name == 'item') {
                String v = firstText(c, new List<String>{ 'value', 'term' });
                if (v == null && c.getChildElements().isEmpty()) v = leafText(c);
                if (String.isNotBlank(v)) p.values.add(v);
                if (p.synonyms.isEmpty()) {
                    for (Dom.XmlNode s : c.getChildElements()) {
                        if (s.getName() == 'synonyms' && String.isNotBlank(leafText(s))) p.synonyms.add(leafText(s));
                    }
                }
            } else if (name == 'value' || name == 'values') {
                if (String.isNotBlank(leafText(c))) p.values.add(leafText(c));
            }
        }
        p.xml = serialize(n, 'queryParts', new Set<String>{ 'synonyms' });
        return p;
    }

    /** Re-reads a result item stored in Search_Audit_Result__c.TK_Result_XML__c (highlights for the explain prompt). */
    public static Hit parseHitXml(String xml) {
        if (String.isBlank(xml)) return new Hit();
        try {
            Dom.Document doc = new Dom.Document();
            doc.load(xml);
            return parseHit(doc.getRootElement());
        } catch (Exception e) {
            return new Hit();
        }
    }

    /**
     * The real response shape (confirmed against tksf_bh4sf_tso_cv):
     * <fieldValues><entry><key>jobtitles</key><value><item><value>&lt;b&gt;Warehouse&lt;/b&gt; Operative</value></item></value></entry></fieldValues>
     * Highlighting is inline: matched terms are wrapped in <b>. Values with a <b> are copied to the highlights
     * (tags kept, for the UI and the explain prompt); the field values themselves are stored without tags.
     */
    private static void addEntries(Hit h, Dom.XmlNode fieldValues) {
        for (Dom.XmlNode entry : fieldValues.getChildElements()) {
            if (entry.getName() != 'entry') continue;
            String key = firstText(entry, new List<String>{ 'key' });
            if (key == null) continue;
            List<String> raw = new List<String>();
            for (Dom.XmlNode c : entry.getChildElements()) {
                if (c.getName() == 'value') collectLeaves(c, raw);
            }
            List<String> plain = new List<String>();
            for (String v : raw) {
                if (v.contains('<b>')) {
                    if (!h.highlights.containsKey(key)) h.highlights.put(key, new List<String>());
                    h.highlights.get(key).add(v);
                }
                plain.add(v.replace('<b>', '').replace('</b>', ''));
            }
            h.fields.put(key, plain);
        }
    }

    /** <values><field>city</field><items>London</items></values> style: field name, then every other leaf as a value. */
    private static void addNamedValues(Map<String, List<String>> target, Dom.XmlNode n) {
        String field = firstText(n, new List<String>{ 'field', 'name', 'fieldName' });
        if (field == null) field = n.getName();
        if (!target.containsKey(field)) target.put(field, new List<String>());
        for (Dom.XmlNode c : n.getChildElements()) {
            String name = c.getName();
            if (name == 'field' || name == 'name' || name == 'fieldName') continue;
            collectLeaves(c, target.get(field));
        }
    }

    private static void collectLeaves(Dom.XmlNode n, List<String> out) {
        List<Dom.XmlNode> kids = n.getChildElements();
        if (kids.isEmpty()) {
            String t = n.getText();
            if (String.isNotBlank(t)) out.add(t.trim());
            return;
        }
        for (Dom.XmlNode k : kids) collectLeaves(k, out);
    }

    /** Contact Id from "<org Id>_<record Id>". Null when the doc id does not end in a Contact Id. */
    public static Id contactIdFrom(String docId) {
        if (String.isBlank(docId)) return null;
        String tail = docId.contains('_') ? docId.substringAfterLast('_') : docId;
        if (!tail.startsWith('003') || (tail.length() != 15 && tail.length() != 18)) return null;
        try {
            return Id.valueOf(tail);
        } catch (Exception e) {
            return null;
        }
    }

    // ─── Dom helpers ─────────────────────────────────────────────

    private static Dom.XmlNode child(Dom.XmlNode n, List<String> names) {
        if (n == null) return null;
        for (Dom.XmlNode c : n.getChildElements()) {
            if (names.contains(c.getName())) return c;
        }
        return null;
    }

    private static Dom.XmlNode firstElement(Dom.XmlNode n) {
        List<Dom.XmlNode> kids = n.getChildElements();
        return kids.isEmpty() ? null : kids[0];
    }

    private static String firstText(Dom.XmlNode n, List<String> names) {
        for (String name : names) {
            for (Dom.XmlNode c : n.getChildElements()) {
                if (c.getName() == name) {
                    String t = leafText(c);
                    if (t != null) return t;
                }
            }
        }
        return null;
    }

    private static String leafText(Dom.XmlNode n) {
        String t = n.getText();
        return String.isBlank(t) ? null : t.trim();
    }

    private static void addDecimal(List<Decimal> out, String v) {
        if (String.isBlank(v)) return;
        try {
            out.add(Decimal.valueOf(v.trim()));
        } catch (Exception e) {
            out.add(v.trim().equalsIgnoreCase('true') ? 1 : 0);
        }
    }

    @TestVisible
    private static String faultText(String xml) {
        if (String.isBlank(xml)) return null;
        try {
            Dom.Document doc = new Dom.Document();
            doc.load(xml);
            Dom.XmlNode body = child(doc.getRootElement(), new List<String>{ 'Body' });
            Dom.XmlNode fault = child(body, new List<String>{ 'Fault' });
            return fault == null ? null : firstText(fault, new List<String>{ 'faultstring', 'Reason', 'Text' });
        } catch (Exception e) {
            return xml.abbreviate(300);
        }
    }

    /** Dom.XmlNode has no toString: serialise an element without namespace prefixes, so it can be sent back as is. */
    public static String serialize(Dom.XmlNode n) {
        return serialize(n, n.getName());
    }

    private static String serialize(Dom.XmlNode n, String asName) {
        return serialize(n, asName, new Set<String>());
    }

    /** As serialize, leaving out child elements with any of the given names. */
    private static String serialize(Dom.XmlNode n, String asName, Set<String> skip) {
        if (n.getNodeType() == Dom.XmlNodeType.TEXT) return n.getText() == null ? '' : n.getText().escapeXml();
        if (n.getNodeType() != Dom.XmlNodeType.ELEMENT) return '';
        String attrs = '';
        for (Integer i = 0; i < n.getAttributeCount(); i++) {
            String key = n.getAttributeKeyAt(i);
            String ns = n.getAttributeKeyNsAt(i);
            if (key == 'nil' || key == 'type') continue;
            attrs += ' ' + key + '="' + String.valueOf(n.getAttributeValue(key, ns)).escapeXml() + '"';
        }
        String innerXml = '';
        for (Dom.XmlNode c : n.getChildren()) {
            if (c.getNodeType() == Dom.XmlNodeType.ELEMENT && skip.contains(c.getName())) continue;
            innerXml += serialize(c, c.getName(), skip);
        }
        return '<' + asName + attrs + '>' + innerXml + '</' + asName + '>';
    }
}
