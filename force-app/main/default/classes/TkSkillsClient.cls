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

    // ═════════════════════════════════════════════════════════════
    // Professions and ontology (Tx Platform v10, same account and key)
    // ═════════════════════════════════════════════════════════════

    public class Profession {
        public Integer codeId;
        public String description;
    }

    public class SuggestedSkill {
        public String id;          // KS code
        public String description;
        public Decimal score;      // 0-1
    }

    /** Job titles from the Professions taxonomy that complete the prefix (POST /v10/professions/autocomplete). */
    public static List<Profession> autocompleteProfessions(String prefix, Integer limitCount) {
        List<Profession> out = new List<Profession>();
        if (String.isBlank(prefix) || prefix.trim().length() < 2) return out;
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        Map<String, Object> value = post('/v10/professions/autocomplete', new Map<String, Object>{
            'Prefix' => prefix.trim(),
            'Languages' => cfg.autocompleteLanguages,
            'Limit' => limitCount == null ? 5 : Math.min(limitCount, 20),
            'OutputLanguage' => 'en'
        });
        for (Object o : listOf(value, 'Professions')) {
            Map<String, Object> m = (Map<String, Object>) o;
            Profession p = new Profession();
            p.codeId = m.get('CodeId') == null ? null : Integer.valueOf(String.valueOf(m.get('CodeId')));
            p.description = (String) m.get('Description');
            if (p.codeId != null && String.isNotBlank(p.description)) out.add(p);
        }
        return out;
    }

    /** Salient skills and certifications for professions (POST /v10/ontology/v2/suggest-skills-from-professions). */
    public static List<SuggestedSkill> suggestSkillsFromProfessions(List<Integer> professionCodeIds, Integer limitCount) {
        if (professionCodeIds == null || professionCodeIds.isEmpty()) return new List<SuggestedSkill>();
        return suggested(post('/v10/ontology/v2/suggest-skills-from-professions', new Map<String, Object>{
            'ProfessionCodeIds' => professionCodeIds,
            'Limit' => limitCount == null ? 12 : Math.min(limitCount, 25),
            'OutputLanguage' => 'en',
            'Types' => new List<String>{ 'Professional', 'Certification', 'IT' }
        }));
    }

    /** Skills closely related to the given skills (POST /v10/ontology/v2/suggest-skills-from-skills). */
    public static List<SuggestedSkill> suggestSkillsFromSkills(List<String> skillIds, Integer limitCount) {
        List<Object> skills = new List<Object>();
        for (String id : skillIds == null ? new List<String>() : skillIds) {
            if (String.isNotBlank(id)) skills.add(new Map<String, Object>{ 'Id' => id, 'Score' => 1 });
        }
        if (skills.isEmpty()) return new List<SuggestedSkill>();
        return suggested(post('/v10/ontology/v2/suggest-skills-from-skills', new Map<String, Object>{
            'Skills' => skills,
            'Limit' => limitCount == null ? 12 : Math.min(limitCount, 25),
            'OutputLanguage' => 'en',
            'Types' => new List<String>{ 'Professional', 'Certification', 'IT' }
        }));
    }

    /**
     * Skill names for KS codes (POST /v10/skills/v2/lookup, up to 100 ids). Textkernel's terms require the response
     * to be cached: the controller method is cacheable and the LWC keeps a session cache. Returns id -> description.
     */
    public static Map<String, String> lookupSkills(List<String> skillIds) {
        Map<String, String> out = new Map<String, String>();
        List<String> ids = new List<String>();
        for (String id : skillIds == null ? new List<String>() : skillIds) {
            if (String.isNotBlank(id) && ids.size() < 100 && !ids.contains(id)) ids.add(id);
        }
        if (ids.isEmpty()) return out;
        Map<String, Object> value = post('/v10/skills/v2/lookup', new Map<String, Object>{ 'SkillIds' => ids, 'OutputLanguage' => 'en' });
        List<Object> items = listOf(value, 'Skills');
        if (items.isEmpty()) {
            for (Object v : value.values()) if (v instanceof List<Object> && items.isEmpty()) items = (List<Object>) v;
        }
        for (Object o : items) {
            if (!(o instanceof Map<String, Object>)) continue;
            Map<String, Object> m = (Map<String, Object>) o;
            String id = (String) m.get('Id');
            String d = (String) m.get('Description');
            if (String.isNotBlank(id) && String.isNotBlank(d)) out.put(id, d);
        }
        return out;
    }

    private static List<SuggestedSkill> suggested(Map<String, Object> value) {
        List<SuggestedSkill> out = new List<SuggestedSkill>();
        for (Object o : listOf(value, 'SuggestedSkills')) {
            Map<String, Object> m = (Map<String, Object>) o;
            SuggestedSkill sk = new SuggestedSkill();
            sk.id = (String) m.get('Id');
            sk.description = (String) m.get('Description');
            sk.score = m.get('Score') == null ? null : Decimal.valueOf(String.valueOf(m.get('Score')));
            if (String.isNotBlank(sk.id) && String.isNotBlank(sk.description)) out.add(sk);
        }
        return out;
    }

    private static List<Object> listOf(Map<String, Object> value, String key) {
        Object v = value == null ? null : value.get(key);
        return v instanceof List<Object> ? (List<Object>) v : new List<Object>();
    }

    /** POSTs JSON to a Tx Platform path and returns the response's Value object. Not cached (Textkernel terms). */
    private static Map<String, Object> post(String path, Map<String, Object> payload) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + cfg.skillsNamedCredential + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setHeader('Tx-AccountId', cfg.txAccountId);
        req.setTimeout(10000);
        req.setBody(System.JSON.serialize(payload));
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            throw new SkillsException('The Textkernel ontology service did not answer: ' + e.getMessage());
        }
        if (res.getStatusCode() == 429) throw new SkillsException('The Textkernel ontology service is busy (rate limit). Try again in a moment.');
        if (res.getStatusCode() < 200 || res.getStatusCode() > 299) {
            throw new SkillsException('The Textkernel ontology service returned HTTP ' + res.getStatusCode() + ' for ' + path + ': ' + String.valueOf(res.getBody()).abbreviate(300));
        }
        Object root = System.JSON.deserializeUntyped(res.getBody());
        Object value = root instanceof Map<String, Object> ? ((Map<String, Object>) root).get('Value') : null;
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : new Map<String, Object>();
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
