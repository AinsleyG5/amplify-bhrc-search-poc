/**
 * TkSkillsClient
 *
 * Skill autocomplete against the Tx Platform v10 Skills API ({domain}/v10/skills/v2/autocomplete).
 * Headers: Tx-AccountId from Candidate_Search_Config__mdt (not secret) and Tx-ServiceKey, which the
 * External Credential behind the Named Credential adds. No key in code.
 *
 * Open item 4: the HTTP method, request body and regional domain are still to be confirmed with one Postman call.
 * This sends POST with { Prefix, Languages, Limit } and reads the response tolerantly (any list of objects with
 * an id and a description, at Value.Skills, Value, Skills or the top level).
 */
public with sharing class TkSkillsClient {

    public class Skill {
        public String id;          // KS code id, e.g. KS120076FGP5WGWYMP0F
        public String description; // display name
        public String category;
    }

    public class SkillsException extends Exception {}

    public static List<Skill> autocomplete(String prefix, List<String> languages, Integer limitCount) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        if (String.isBlank(prefix) || prefix.trim().length() < 2) return new List<Skill>();

        Map<String, Object> body = new Map<String, Object>{
            'Prefix' => prefix.trim(),
            'Languages' => languages == null || languages.isEmpty() ? cfg.autocompleteLanguages : languages,
            'Limit' => limitCount == null ? 10 : Math.min(limitCount, 50)
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + cfg.skillsNamedCredential + cfg.skillsAutocompletePath);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setHeader('Tx-AccountId', cfg.txAccountId);
        req.setTimeout(10000);
        req.setBody(System.JSON.serialize(body));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            throw new SkillsException('The skills service did not answer: ' + e.getMessage());
        }
        if (res.getStatusCode() == 429) {
            throw new SkillsException('The skills service is busy (rate limit). Try again in a moment.');
        }
        if (res.getStatusCode() < 200 || res.getStatusCode() > 299) {
            throw new SkillsException('The skills service returned HTTP ' + res.getStatusCode() + ': ' + String.valueOf(res.getBody()).abbreviate(300));
        }
        return parse(res.getBody());
    }

    @TestVisible
    private static List<Skill> parse(String body) {
        List<Skill> out = new List<Skill>();
        if (String.isBlank(body)) return out;
        Object root = System.JSON.deserializeUntyped(body);
        for (Object o : findList(root, 0)) {
            if (!(o instanceof Map<String, Object>)) continue;
            Map<String, Object> m = (Map<String, Object>) o;
            Skill s = new Skill();
            s.id = pick(m, new List<String>{ 'Id', 'id', 'CodeId', 'code_id', 'Code' });
            s.description = pick(m, new List<String>{ 'Description', 'description', 'Name', 'name', 'Label', 'label' });
            s.category = pick(m, new List<String>{ 'Category', 'category', 'Type', 'type' });
            if (s.description != null) out.add(s);
        }
        return out;
    }

    private static List<Object> findList(Object node, Integer depth) {
        if (node instanceof List<Object>) return (List<Object>) node;
        if (!(node instanceof Map<String, Object>) || depth > 3) return new List<Object>();
        Map<String, Object> m = (Map<String, Object>) node;
        for (String key : new List<String>{ 'Value', 'value', 'Skills', 'skills', 'Results', 'results', 'Data', 'data' }) {
            if (m.containsKey(key)) {
                List<Object> found = findList(m.get(key), depth + 1);
                if (!found.isEmpty()) return found;
            }
        }
        return new List<Object>();
    }

    private static String pick(Map<String, Object> m, List<String> keys) {
        for (String k : keys) {
            Object v = m.get(k);
            if (v instanceof Map<String, Object>) {
                // e.g. "Description": { "en": "Forklift Truck Operation" }
                Map<String, Object> nested = (Map<String, Object>) v;
                if (!nested.isEmpty()) v = nested.values()[0];
            }
            if (v != null && !(v instanceof Map<String, Object>) && !(v instanceof List<Object>)) return String.valueOf(v);
        }
        return null;
    }
}
