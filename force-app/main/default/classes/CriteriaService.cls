/**
 * CriteriaService
 *
 * The criteria JSON (contract v1, CANDIDATE_SEARCH_SPEC.md section 4) is the single source of truth for a search.
 * This class validates it, turns it into Textkernel query parts, maps TK generated parts back to chips, builds
 * criteria from a job record, applies the Apex job-match refinements and applies chat patches.
 *
 * Criteria are handled as untyped maps (System.JSON.deserializeUntyped) so fields this class does not know
 * about, and the raw TK part carried on tk_generated chips, survive a round trip untouched.
 *
 * Optional transient key "trace": set by parseQuery / refine, read by runSearch for the audit, never stored
 * in Criteria_JSON__c (see stripTrace).
 */
public with sharing class CriteriaService {

    public static final Set<String> KINDS = new Set<String>{
        'title', 'skill', 'certification', 'location', 'keyword', 'language',
        'shift', 'availability', 'fingerprint', 'tk_raw'
    };
    public static final Set<String> WEIGHTS = new Set<String>{
        'required', 'strongly_preferred', 'preferred', 'excluded'
    };
    public static final Set<String> ORIGINS = new Set<String>{
        'nl', 'job', 'refine', 'user', 'tk_generated'
    };
    public static final Set<String> EXCLUSION_KEYS = new Set<String>{ 'pipelineForJob', 'placedWithinDays' };

    public static final Integer MAX_ITEMS = 25;
    public static final Integer MAX_LABEL = 120;

    /** Chip kinds that came from TK verbatim and can only be removed. */
    private static final Set<String> READ_ONLY_KINDS = new Set<String>{ 'fingerprint', 'tk_raw' };

    /** Keys a patch "update" may set. */
    private static final Set<String> UPDATABLE = new Set<String>{
        'label', 'value', 'weight', 'radius', 'unit', 'withinDays', 'code'
    };

    /** TK fields generated for a job document, mapped back to chip kinds (section 5). */
    private static final Set<String> TITLE_FIELDS = new Set<String>{ 'jobtitle', 'jobtitles', 'vacancytitle', 'recent_jobtitles' };
    private static final Set<String> SKILL_FIELDS = new Set<String>{ 'compskills', 'profskills', 'it_skills', 'professional_skills_terms' };
    private static final Set<String> LOCATION_FIELDS = new Set<String>{ 'city', 'location', 'postcode', 'zipcode' };
    private static final String FINGERPRINT_FIELD = 'text_fingerprint';

    public class CriteriaException extends Exception {}

    // ═════════════════════════════════════════════════════════════
    // Parsing and helpers
    // ═════════════════════════════════════════════════════════════

    public static Map<String, Object> parse(String criteriaJson) {
        if (String.isBlank(criteriaJson)) {
            throw new CriteriaException('The search criteria are empty.');
        }
        Object o;
        try {
            o = System.JSON.deserializeUntyped(criteriaJson);
        } catch (Exception e) {
            throw new CriteriaException('The search criteria are not valid JSON: ' + e.getMessage());
        }
        if (!(o instanceof Map<String, Object>)) {
            throw new CriteriaException('The search criteria must be a JSON object.');
        }
        return (Map<String, Object>) o;
    }

    public static String serialize(Map<String, Object> criteria) {
        return System.JSON.serialize(criteria);
    }

    public static Map<String, Object> newCriteria(String source) {
        Map<String, Object> c = new Map<String, Object>();
        c.put('version', 1);
        c.put('source', source);
        c.put('naturalLanguage', null);
        c.put('jobId', null);
        c.put('tkJobDocId', null);
        c.put('items', new List<Object>());
        c.put('filters', new Map<String, Object>());
        c.put('exclusions', new Map<String, Object>());
        return c;
    }

    public static List<Object> items(Map<String, Object> criteria) {
        Object o = criteria.get('items');
        if (o == null) {
            o = new List<Object>();
            criteria.put('items', o);
        }
        if (!(o instanceof List<Object>)) {
            throw new CriteriaException('"items" must be a list.');
        }
        return (List<Object>) o;
    }

    public static Map<String, Object> filters(Map<String, Object> criteria) {
        return objectAt(criteria, 'filters');
    }

    public static Map<String, Object> exclusions(Map<String, Object> criteria) {
        return objectAt(criteria, 'exclusions');
    }

    private static Map<String, Object> objectAt(Map<String, Object> criteria, String key) {
        Object o = criteria.get(key);
        if (o == null) {
            o = new Map<String, Object>();
            criteria.put(key, o);
        }
        if (!(o instanceof Map<String, Object>)) {
            throw new CriteriaException('"' + key + '" must be an object.');
        }
        return (Map<String, Object>) o;
    }

    public static Map<String, Object> findItem(Map<String, Object> criteria, String id) {
        for (Object o : items(criteria)) {
            Map<String, Object> item = (Map<String, Object>) o;
            if (str(item, 'id') == id) return item;
        }
        return null;
    }

    /** Next free chip id: c + (highest numeric suffix + 1). */
    public static String nextId(Map<String, Object> criteria) {
        Integer maxN = 0;
        for (Object o : items(criteria)) {
            String id = str((Map<String, Object>) o, 'id');
            if (id != null && id.startsWith('c') && id.substring(1).isNumeric()) {
                maxN = Math.max(maxN, Integer.valueOf(id.substring(1)));
            }
        }
        return 'c' + (maxN + 1);
    }

    /** Removes and returns the transient trace object. */
    public static Map<String, Object> stripTrace(Map<String, Object> criteria) {
        Object t = criteria.remove('trace');
        return t instanceof Map<String, Object> ? (Map<String, Object>) t : new Map<String, Object>();
    }

    /** Stable hash of what is searched (items, filters, exclusions), used to merge repeated recent searches. */
    public static String hash(Map<String, Object> criteria) {
        List<String> parts = new List<String>();
        for (Object o : items(criteria)) {
            Map<String, Object> i = (Map<String, Object>) o;
            parts.add(str(i, 'kind') + '|' + lower(str(i, 'value')) + '|' + str(i, 'weight') + '|' + str(i, 'radius') + '|' + str(i, 'code'));
        }
        parts.sort();
        List<String> f = new List<String>();
        for (String k : filters(criteria).keySet()) f.add(k + '=' + System.JSON.serialize(filters(criteria).get(k)));
        f.sort();
        List<String> x = new List<String>();
        for (String k : exclusions(criteria).keySet()) x.add(k + '=' + String.valueOf(exclusions(criteria).get(k)));
        x.sort();
        String basis = String.join(parts, ';') + '#' + String.join(f, ';') + '#' + String.join(x, ';') + '#' + str(criteria, 'jobId');
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(basis)));
    }

    // ═════════════════════════════════════════════════════════════
    // Validation
    // ═════════════════════════════════════════════════════════════

    /**
     * Checks the contract and normalises in place: trims labels, fills missing ids, defaults the version.
     * Throws CriteriaException with a message that can be shown to the recruiter.
     */
    public static Map<String, Object> validate(Map<String, Object> criteria) {
        if (criteria == null) throw new CriteriaException('The search criteria are empty.');
        if (criteria.get('version') == null) criteria.put('version', 1);
        if (String.valueOf(criteria.get('version')) != '1') {
            throw new CriteriaException('Unsupported criteria version ' + criteria.get('version') + '. Expected 1.');
        }

        List<Object> chips = items(criteria);
        if (chips.size() > MAX_ITEMS) {
            throw new CriteriaException('A search can have at most ' + MAX_ITEMS + ' criteria. This one has ' + chips.size() + '.');
        }

        Set<String> ids = new Set<String>();
        for (Object o : chips) {
            if (!(o instanceof Map<String, Object>)) throw new CriteriaException('Each criterion must be an object.');
            Map<String, Object> item = (Map<String, Object>) o;

            String kind = str(item, 'kind');
            String label = str(item, 'label');
            if (!KINDS.contains(kind)) {
                throw new CriteriaException('Unknown criterion type "' + kind + '"' + (label == null ? '' : ' on "' + label + '"') + '.');
            }
            String weight = str(item, 'weight');
            if (!WEIGHTS.contains(weight)) {
                throw new CriteriaException('Unknown weight "' + weight + '" on "' + (label == null ? kind : label) + '".');
            }
            String origin = str(item, 'origin');
            if (origin != null && !ORIGINS.contains(origin)) {
                throw new CriteriaException('Unknown origin "' + origin + '" on "' + (label == null ? kind : label) + '".');
            }

            if (String.isBlank(str(item, 'value')) && !READ_ONLY_KINDS.contains(kind) && kind != 'availability') {
                throw new CriteriaException('The ' + kind + ' criterion "' + (label == null ? '' : label) + '" has no value.');
            }
            if (kind == 'location' && (item.get('radius') == null || dec(item, 'radius') < 0)) {
                throw new CriteriaException('The location "' + str(item, 'value') + '" needs a radius.');
            }
            if (kind == 'availability' && item.get('withinDays') == null && String.isBlank(str(item, 'value'))) {
                throw new CriteriaException('The availability criterion needs a number of days or a date.');
            }
            if (READ_ONLY_KINDS.contains(kind) && item.get('raw') == null) {
                throw new CriteriaException('The ' + kind + ' criterion "' + (label == null ? '' : label) + '" has lost its Textkernel query part.');
            }

            if (String.isBlank(label)) label = String.isBlank(str(item, 'value')) ? kind : str(item, 'value');
            label = label.trim();
            item.put('label', label.length() > MAX_LABEL ? label.left(MAX_LABEL) : label);

            String id = str(item, 'id');
            if (String.isBlank(id) || ids.contains(id)) {
                id = nextId(criteria);
                while (ids.contains(id)) id = 'c' + (Integer.valueOf(id.substring(1)) + 1);
                item.put('id', id);
            }
            ids.add(id);
        }

        Map<String, Object> f = filters(criteria);
        Integer filterCount = 0;
        for (String key : f.keySet()) {
            Object v = f.get(key);
            if (!(v instanceof List<Object>)) {
                throw new CriteriaException('The filter "' + key + '" must be a list of values.');
            }
            filterCount += ((List<Object>) v).size();
        }

        Map<String, Object> x = exclusions(criteria);
        for (String key : x.keySet()) {
            if (!EXCLUSION_KEYS.contains(key)) throw new CriteriaException('Unknown exclusion "' + key + '".');
        }
        if (x.get('placedWithinDays') != null) {
            Decimal d;
            try {
                d = Decimal.valueOf(String.valueOf(x.get('placedWithinDays')));
            } catch (Exception e) {
                d = -1;
            }
            if (d < 1 || d > 3650) throw new CriteriaException('"Placed within days" must be between 1 and 3650.');
        }

        if (chips.isEmpty() && filterCount == 0) {
            throw new CriteriaException('Add at least one criterion or filter to search on.');
        }
        return criteria;
    }

    // ═════════════════════════════════════════════════════════════
    // Criteria to TK query parts
    // ═════════════════════════════════════════════════════════════

    public class BuildResult {
        public List<TkSearchClient.QueryPart> parts = new List<TkSearchClient.QueryPart>();
        /** Same order as parts: chip id, "filter:<field>" or "exclusion:<key>". */
        public List<String> criteriaIds = new List<String>();
        /**
         * Location goes in the free-text <query> string, not a query part: TK only geo-interprets the query string
         * (confirmed on tksf_bh4sf_tso_cv: city:Dagenham+15 finds 4, a city part "Dagenham+15" finds 0).
         * The query string has no per-part score, so these chips are met by every result.
         */
        public List<String> queryTerms = new List<String>();
        public List<String> queryCriteriaIds = new List<String>();
        /**
         * Excluded chips and placedWithinDays, also sent in the query string as -field:value: TK ignores every
         * condition spelling for exclusion (all behave as REQUIRED), but query negation works
         * (tkExclude.apex: -custom_date_1:>=today-1000 left 1106 of 1172). Stored as x:<id>, never met/not met.
         */
        public List<String> excludedCriteriaIds = new List<String>();
        public List<String> notices = new List<String>();

        public String queryString() {
            return String.join(queryTerms, ' ');
        }

        public Boolean isEmpty() {
            return parts.isEmpty() && queryTerms.isEmpty();
        }

        /** Search options carrying the query string. The caller sets the offset. */
        public TkSearchClient.SearchOptions options() {
            TkSearchClient.SearchOptions o = new TkSearchClient.SearchOptions();
            o.query = queryString();
            return o;
        }

        /** criteriaIds, then "q:<id>" for each query-string chip: stored in TK_Criteria_Map__c. */
        public List<String> auditCriteriaIds() {
            List<String> ids = new List<String>(criteriaIds);
            for (String id : queryCriteriaIds) ids.add('q:' + id);
            for (String id : excludedCriteriaIds) ids.add('x:' + id);
            return ids;
        }
    }

    public static BuildResult toQueryParts(Map<String, Object> criteria) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        BuildResult out = new BuildResult();

        for (Object o : items(criteria)) {
            Map<String, Object> item = (Map<String, Object>) o;
            String id = str(item, 'id');
            String kind = str(item, 'kind');
            String condition = conditionFor(str(item, 'weight'));
            String value = str(item, 'value');

            // Generated by TK and untouched: send exactly what TK produced
            if (item.get('raw') instanceof Map<String, Object> && isUnchangedTkPart(item)) {
                Map<String, Object> raw = (Map<String, Object>) item.get('raw');
                TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
                p.field = str(raw, 'field');
                p.condition = str(raw, 'condition');
                p.weight = raw.get('weight') == null ? 1.0 : dec(raw, 'weight');
                p.values = strings(raw.get('values'));
                p.xml = str(raw, 'xml');
                add(out, p, id);
                continue;
            }

            // Excluded: a negated query-string term, never a part (TK treats every exclude condition as REQUIRED)
            if (str(item, 'weight') == 'excluded') {
                String term = excludedTerm(item, cfg);
                if (term == null) {
                    out.notices.add('"' + str(item, 'label') + '" was not sent: it cannot be excluded yet.');
                } else {
                    out.queryTerms.add(term);
                    out.excludedCriteriaIds.add(id);
                }
                continue;
            }

            if (kind == 'title') {
                add(out, part(cfg.tkTitleField, condition, textValue(cfg.tkTitleField, value)), id);
            } else if (kind == 'skill') {
                add(out, part('FULLTEXT', condition, quote(value)), id);
                String code = str(item, 'code');
                if (String.isNotBlank(code) && String.isNotBlank(cfg.tkSkillCodeField)) {
                    // The text part carries a requirement; the code part only adds score, so a skill held under
                    // another wording is not excluded by a missing code.
                    add(out, part(cfg.tkSkillCodeField, condition == 'REQUIRED' ? 'STRONGLY_FAVORED' : condition, code), id);
                }
            } else if (kind == 'certification') {
                add(out, part('FULLTEXT', condition, quote(value)), id);
                String code = str(item, 'code');
                if (String.isNotBlank(code) && String.isNotBlank(cfg.tkCertificationCodeField)) {
                    add(out, part(cfg.tkCertificationCodeField, condition == 'REQUIRED' ? 'STRONGLY_FAVORED' : condition, code), id);
                }
            } else if (kind == 'location') {
                String label = str(item, 'label');
                if (str(item, 'weight') != 'required') {
                    out.notices.add('"' + label + '" is applied as a filter: Textkernel cannot weight a location.');
                }
                if (String.isNotBlank(str(item, 'geo'))) {
                    // A TK-generated location keeps its coordinates and stays a part, as TK produced it
                    // (US San Francisco CA+25@37.77493 -122.41942); only the radius changes
                    String place = str(item, 'value');
                    Decimal radius = dec(item, 'radius');
                    if (str(item, 'unit') == 'km') radius = radius * 0.621371;
                    String field = item.get('raw') instanceof Map<String, Object> ? str((Map<String, Object>) item.get('raw'), 'field') : cfg.tkLocationField;
                    add(out, part(field, condition, place + '+' + radius.round(System.RoundingMode.HALF_UP) + '@' + str(item, 'geo')), id);
                    continue;
                }
                out.queryTerms.add(locationQuery(item));
                out.queryCriteriaIds.add(id);
            } else if (kind == 'keyword' || kind == 'shift') {
                add(out, part('FULLTEXT', condition, quote(value)), id);
            } else if (kind == 'language') {
                String f = String.isBlank(cfg.tkLanguageField) ? 'FULLTEXT' : cfg.tkLanguageField;
                add(out, part(f, condition, textValue(f, value)), id);
            } else if (kind == 'availability') {
                if (String.isBlank(cfg.tkAvailabilityField)) {
                    out.notices.add('"' + str(item, 'label') + '" was not sent to Textkernel: the availability date field is not configured yet.');
                    continue;
                }
                add(out, part(cfg.tkAvailabilityField, condition, availabilityRange(item)), id);
            } else {
                // fingerprint / tk_raw that were edited (only the weight can change): rebuild from raw with the new condition
                Map<String, Object> raw = item.get('raw') instanceof Map<String, Object>
                    ? (Map<String, Object>) item.get('raw') : new Map<String, Object>();
                TkSearchClient.QueryPart p = part(str(raw, 'field'), condition, null);
                p.values = strings(raw.get('values'));
                add(out, p, id);
            }
        }

        Map<String, Object> f = filters(criteria);
        for (String field : f.keySet()) {
            List<String> values = strings(f.get(field));
            if (values.isEmpty()) continue;
            TkSearchClient.QueryPart p = part(field, 'REQUIRED', null);
            p.values = values;
            add(out, p, 'filter:' + field);
        }

        Map<String, Object> x = exclusions(criteria);
        if (x.get('placedWithinDays') != null && String.isNotBlank(cfg.tkLastPlacementField)) {
            Integer days = Decimal.valueOf(String.valueOf(x.get('placedWithinDays'))).intValue();
            out.queryTerms.add('-' + cfg.tkLastPlacementField + ':>=today-' + days);
            out.excludedCriteriaIds.add('exclusion:placedWithinDays');
        }
        return out;
    }

    public static String conditionFor(String weight) {
        if (weight == 'required') return 'REQUIRED';
        if (weight == 'strongly_preferred') return 'STRONGLY_FAVORED';
        if (weight == 'excluded') return CandidateSearchConfig.get().tkExcludeCondition;
        return 'FAVORED';
    }

    public static String weightFor(String condition) {
        String c = condition == null ? '' : condition.toUpperCase();
        if (c == 'REQUIRED') return 'required';
        if (c == 'STRONGLY_FAVORED') return 'strongly_preferred';
        String configured = CandidateSearchConfig.get().tkExcludeCondition;
        if ((String.isNotBlank(configured) && c == configured.toUpperCase()) || c.startsWith('EXCLU') || c == 'MUST_NOT' || c == 'REJECTED') {
            return 'excluded';
        }
        return 'preferred';
    }

    /** "Dagenham+15". Kilometres are converted to miles (the index radius unit used by the existing flow). */
    @TestVisible
    private static String locationValue(Map<String, Object> item) {
        String place = str(item, 'postcode');
        if (String.isBlank(place)) place = str(item, 'value');
        place = place.replace('+', ' ').trim();
        Decimal radius = item.get('radius') == null ? CandidateSearchConfig.get().defaultRadiusMiles : dec(item, 'radius');
        if (str(item, 'unit') == 'km') radius = radius * 0.621371;
        return place + '+' + radius.round(System.RoundingMode.HALF_UP);
    }

    /** -field:value for an excluded chip, or null when the chip has nothing to negate. */
    @TestVisible
    private static String excludedTerm(Map<String, Object> item, CandidateSearchConfig cfg) {
        String kind = str(item, 'kind');
        String value = str(item, 'value');
        if (kind == 'location') return '-' + locationQuery(item);
        if (kind == 'availability') {
            return String.isBlank(cfg.tkAvailabilityField) ? null : '-' + cfg.tkAvailabilityField + ':' + availabilityRange(item);
        }
        if (kind == 'title') return '-' + fieldTerm(cfg.tkTitleField, value);
        if (kind == 'language') return '-' + fieldTerm(String.isBlank(cfg.tkLanguageField) ? 'FULLTEXT' : cfg.tkLanguageField, value);
        if (kind == 'fingerprint' || kind == 'tk_raw') {
            Map<String, Object> raw = item.get('raw') instanceof Map<String, Object> ? (Map<String, Object>) item.get('raw') : null;
            List<String> values = raw == null ? new List<String>() : strings(raw.get('values'));
            if (values.isEmpty() || kind == 'fingerprint') return null;
            return '-' + fieldTerm(str(raw, 'field'), values[0]);
        }
        return String.isBlank(value) ? null : '-' + fieldTerm('FULLTEXT', value);
    }

    /** "phrase" for FULLTEXT, field:value otherwise (quoted when the value has a space). */
    private static String fieldTerm(String field, String value) {
        if (field == 'FULLTEXT') return quote(value);
        String v = value.trim();
        if (v.contains(' ') && !v.startsWith('"')) v = '"' + v.replace('"', '') + '"';
        return field + ':' + v;
    }

    /** city:Dagenham+15, or city:"RM9 6SA"+15 when the place has a space (quoting not yet confirmed with TK). */
    @TestVisible
    private static String locationQuery(Map<String, Object> item) {
        String v = locationValue(item);
        String place = v.substringBeforeLast('+');
        String radius = v.substringAfterLast('+');
        if (place.contains(' ')) place = '"' + place.replace('"', '') + '"';
        return CandidateSearchConfig.get().tkLocationField + ':' + place + '+' + radius;
    }

    /**
     * Date values use TK's relative date syntax, as the index's own facets do (documentdate: ">=today-365").
     * Available within N days = date_available on or before today+N; an explicit date = on or before that date.
     */
    @TestVisible
    private static String availabilityRange(Map<String, Object> item) {
        if (item.get('withinDays') != null) {
            return '<=today+' + dec(item, 'withinDays').intValue();
        }
        return '<=' + isoDate(Date.valueOf(str(item, 'value')));
    }

    private static String isoDate(Date d) {
        return Datetime.newInstance(d.year(), d.month(), d.day()).format('yyyy-MM-dd');
    }

    private static String textValue(String field, String value) {
        return field == 'FULLTEXT' ? quote(value) : value;
    }

    /** Same rule as AmplifyTKMatchService.quoteTerm: multi-word terms go as phrases. */
    public static String quote(String term) {
        return AmplifyTKMatchService.quoteTerm(term);
    }

    private static Boolean isUnchangedTkPart(Map<String, Object> item) {
        Map<String, Object> raw = (Map<String, Object>) item.get('raw');
        if (String.isBlank(str(raw, 'field'))) return false;
        if (weightFor(str(raw, 'condition')) != str(item, 'weight')) return false;
        if (READ_ONLY_KINDS.contains(str(item, 'kind'))) return true;
        return signature(item) == str(item, 'rawSignature');
    }

    /** What a recruiter can change on a generated chip. Recorded when the chip is created from TK. */
    private static String signature(Map<String, Object> item) {
        return str(item, 'value') + '|' + str(item, 'radius') + '|' + str(item, 'unit') + '|' + str(item, 'code');
    }

    private static TkSearchClient.QueryPart part(String field, String condition, String value) {
        TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
        p.field = field;
        p.condition = condition;
        if (value != null) p.values.add(value);
        return p;
    }

    private static void add(BuildResult out, TkSearchClient.QueryPart p, String criteriaId) {
        p.criteriaId = criteriaId;
        out.parts.add(p);
        out.criteriaIds.add(criteriaId);
    }

    // ═════════════════════════════════════════════════════════════
    // TK generated parts back to chips
    // ═════════════════════════════════════════════════════════════

    /** Maps the query parts TK generated from a job document to chips (origin tk_generated, raw kept). */
    public static List<Object> fromTkQueryParts(List<TkSearchClient.QueryPart> parts) {
        List<Object> out = new List<Object>();
        if (parts == null) return out;
        Integer n = 0;
        for (TkSearchClient.QueryPart p : parts) {
            n++;
            String field = p.field == null ? '' : p.field.toLowerCase();
            String first = p.values.isEmpty() ? '' : p.values[0];
            String display = first.replace('"', '').trim();

            Map<String, Object> item = new Map<String, Object>();
            item.put('id', 'c' + n);
            item.put('origin', 'tk_generated');
            item.put('weight', weightFor(p.condition));

            if (field == FINGERPRINT_FIELD) {
                item.put('kind', 'fingerprint');
                item.put('label', 'Job description');
                item.put('value', null);
            } else if (TITLE_FIELDS.contains(field)) {
                // TK wraps normalised titles in brackets: [Process Engineer]
                String title = display.removeStart('[').removeEnd(']').trim();
                item.put('kind', 'title');
                item.put('label', title);
                item.put('value', title);
            } else if (SKILL_FIELDS.contains(field)) {
                item.put('kind', 'skill');
                if (display.startsWithIgnoreCase('KS') && !display.contains(' ')) {
                    // A KS code: the first synonym TK sent names the skill (KSAXTOY5CH3G8GUTIAUU = Lightning Components)
                    String name = p.synonyms.isEmpty() ? display : p.synonyms[0];
                    item.put('code', display);
                    item.put('label', name);
                    item.put('value', name);
                } else {
                    item.put('label', display);
                    item.put('value', display);
                }
            } else if (LOCATION_FIELDS.contains(field)) {
                // US San Francisco CA+50@37.77493 -122.41942: place, radius, then coordinates after @
                item.put('kind', 'location');
                String placeAndRadius = first.substringBefore('@');
                if (first.contains('@')) item.put('geo', first.substringAfter('@').trim());
                String place = placeAndRadius.contains('+') ? placeAndRadius.substringBeforeLast('+').trim() : placeAndRadius.trim();
                String r = placeAndRadius.contains('+') ? placeAndRadius.substringAfterLast('+').trim() : '';
                Decimal radius = r.isNumeric() ? Decimal.valueOf(r) : CandidateSearchConfig.get().defaultRadiusMiles;
                item.put('value', place);
                item.put('radius', radius);
                item.put('unit', 'mi');
                item.put('label', place + ' + ' + radius + ' mi');
            } else if (field == 'fulltext') {
                // Keywords TK took from the job description: ordinary keyword chips
                List<String> shown = new List<String>();
                for (String v : p.values) shown.add(v.replace('"', '').trim());
                item.put('kind', 'keyword');
                item.put('label', String.join(shown, ', ').abbreviate(MAX_LABEL));
                item.put('value', display);
            } else {
                item.put('kind', 'tk_raw');
                String label = p.values.isEmpty()
                    ? friendlyField(p.field)
                    : friendlyField(p.field) + ': ' + String.join(p.values, ', ');
                item.put('label', label.abbreviate(MAX_LABEL));
                item.put('value', null);
            }
            item.put('rawSignature', signature(item));
            item.put('raw', rawOf(p));
            out.add(item);
        }
        return out;
    }

    private static final Map<String, String> FRIENDLY_FIELDS = new Map<String, String>{
        'workfield' => 'Work field and experience level',
        'experience_years' => 'Years of experience',
        'educationlevel_international' => 'Education level',
        'experiencelevel' => 'Experience level',
        'language_skills' => 'Language',
        'date_available' => 'Available from'
    };

    private static String friendlyField(String field) {
        String f = field == null ? '' : field.toLowerCase();
        return FRIENDLY_FIELDS.containsKey(f) ? FRIENDLY_FIELDS.get(f) : field;
    }

    private static Map<String, Object> rawOf(TkSearchClient.QueryPart p) {
        Map<String, Object> raw = new Map<String, Object>();
        raw.put('field', p.field);
        raw.put('condition', p.condition);
        raw.put('weight', p.weight);
        raw.put('values', new List<String>(p.values));
        raw.put('xml', p.xml);
        return raw;
    }

    // ═════════════════════════════════════════════════════════════
    // Job record: fallback criteria and job-match refinements
    // ═════════════════════════════════════════════════════════════

    private static final List<String> JOB_FIELDS = new List<String>{
        'Id', 'Name', 'TR1__Job_Title__c', 'TR1__City__c', 'TR1__Postal_Code__c', 'TR1__Country__c'
    };

    /** Loads the job with only the fields that exist in this org, so a missing field cannot break the match. */
    public static SObject loadJob(Id jobId) {
        Map<String, Schema.SObjectField> fieldMap = jobId.getSObjectType().getDescribe().fields.getMap();
        List<String> present = new List<String>();
        for (String f : JOB_FIELDS) {
            if (fieldMap.containsKey(f.toLowerCase())) present.add(f);
        }
        List<SObject> rows = Database.query(
            'SELECT ' + String.join(present, ', ') + ' FROM ' + String.valueOf(jobId.getSObjectType()) + ' WHERE Id = :jobId LIMIT 1'
        );
        if (rows.isEmpty()) throw new CriteriaException('Job ' + jobId + ' was not found or you do not have access to it.');
        return rows[0];
    }

    /** Fallback when searchWithUrl fails: criteria from TR1__Job__c fields and the job's skills (PoolBrief pattern). */
    public static Map<String, Object> fromJobRecord(SObject job) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        Map<String, Object> c = newCriteria('job');
        c.put('jobId', job.Id);
        List<Object> chips = items(c);

        String title = field(job, 'TR1__Job_Title__c');
        if (String.isNotBlank(title)) {
            chips.add(item(c, 'title', title, title, 'required', 'job'));
        }

        Map<String, Object> loc = jobLocation(job, cfg.defaultRadiusMiles);
        if (loc != null) {
            loc.put('id', nextId(c));
            chips.add(loc);
        }

        for (JobSkill s : jobSkills(job.Id)) {
            if (chips.size() >= MAX_ITEMS) break;
            Map<String, Object> i = item(c, s.certification ? 'certification' : 'skill', s.name, s.name,
                s.certification ? 'strongly_preferred' : 'preferred', 'job');
            if (String.isNotBlank(s.code)) i.put('code', s.code);
            chips.add(i);
        }

        if (chips.isEmpty()) {
            throw new CriteriaException('The job has no title, location or skills to search on. Add a job title and try again.');
        }
        return c;
    }

    /**
     * Apex refinement of the generated job query (section 5). Each rule is switchable in Candidate_Search_Config__mdt.
     * Returns true when the criteria changed, so the caller re-runs the search with the adjusted parts.
     */
    public static Boolean refineFromJob(Map<String, Object> criteria, SObject job) {
        CandidateSearchConfig cfg = CandidateSearchConfig.get();
        Boolean changed = false;
        List<Object> chips = items(criteria);

        if (cfg.addJobLocation && job != null) {
            Boolean hasLocation = false;
            for (Object o : chips) {
                if (str((Map<String, Object>) o, 'kind') == 'location') hasLocation = true;
            }
            Map<String, Object> loc = hasLocation ? null : jobLocation(job, cfg.defaultRadiusMiles);
            if (loc != null && chips.size() < MAX_ITEMS) {
                loc.put('id', nextId(criteria));
                chips.add(loc);
                changed = true;
            }
        }

        if (cfg.capSkillParts && cfg.maxSkillParts != null) {
            Integer skills = 0;
            for (Integer i = 0; i < chips.size(); i++) {
                Map<String, Object> item = (Map<String, Object>) chips[i];
                if (str(item, 'kind') != 'skill') continue;
                skills++;
                if (skills > cfg.maxSkillParts) {
                    chips.remove(i);
                    i--;
                    changed = true;
                }
            }
        }

        if (cfg.softJobTitle) {
            for (Object o : chips) {
                Map<String, Object> item = (Map<String, Object>) o;
                if (str(item, 'kind') == 'title' && str(item, 'origin') == 'tk_generated' && str(item, 'weight') == 'required') {
                    item.put('weight', 'strongly_preferred');
                    changed = true;
                }
            }
        }
        return changed;
    }

    private static Map<String, Object> jobLocation(SObject job, Integer radius) {
        String postcode = field(job, 'TR1__Postal_Code__c');
        String city = field(job, 'TR1__City__c');
        String place = String.isNotBlank(postcode) ? postcode : city;
        if (String.isBlank(place)) return null;
        Map<String, Object> loc = new Map<String, Object>();
        loc.put('kind', 'location');
        loc.put('value', place.trim());
        loc.put('radius', radius);
        loc.put('unit', 'mi');
        loc.put('label', place.trim() + ' + ' + radius + ' mi');
        loc.put('weight', 'required');
        loc.put('origin', 'job');
        return loc;
    }

    public class JobSkill {
        public String name;
        public String code;
        public Boolean certification = false;
    }

    /** Skills on the job (TR1__Skills__r). Queried dynamically and fails soft: no skills rather than no search. */
    @TestVisible
    private static List<JobSkill> jobSkills(Id jobId) {
        List<JobSkill> out = new List<JobSkill>();
        try {
            Map<String, Schema.SObjectField> f = Schema.getGlobalDescribe().get('TR1__Skills__c').getDescribe().fields.getMap();
            List<String> cols = new List<String>{ 'TR1__Master_Skill_Name__c' };
            if (f.containsKey('tr1__skill_code__c')) cols.add('TR1__Skill_Code__c');
            if (f.containsKey('is_job_certification__c')) cols.add('Is_Job_Certification__c');
            String soql = 'SELECT (SELECT ' + String.join(cols, ', ') + ' FROM TR1__Skills__r WHERE TR1__Master_Skill_Name__c != null LIMIT 50)'
                + ' FROM TR1__Job__c WHERE Id = :jobId';
            for (SObject job : Database.query(soql)) {
                List<SObject> rows = job.getSObjects('TR1__Skills__r');
                if (rows == null) continue;
                // Certifications first, so they survive the item cap
                List<JobSkill> plain = new List<JobSkill>();
                for (SObject s : rows) {
                    JobSkill js = new JobSkill();
                    js.name = (String) s.get('TR1__Master_Skill_Name__c');
                    js.code = cols.contains('TR1__Skill_Code__c') ? (String) s.get('TR1__Skill_Code__c') : null;
                    js.certification = cols.contains('Is_Job_Certification__c') && s.get('Is_Job_Certification__c') == true;
                    if (js.certification) out.add(js); else plain.add(js);
                }
                out.addAll(plain);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Job skills not loaded: ' + e.getMessage());
        }
        return out;
    }

    private static Map<String, Object> item(Map<String, Object> criteria, String kind, String label, String value, String weight, String origin) {
        Map<String, Object> i = new Map<String, Object>();
        i.put('id', nextId(criteria));
        i.put('kind', kind);
        i.put('label', label == null ? null : label.trim().abbreviate(MAX_LABEL));
        i.put('value', value == null ? null : value.trim());
        i.put('weight', weight);
        i.put('origin', origin);
        return i;
    }

    // ═════════════════════════════════════════════════════════════
    // Patches from the refine prompt
    // ═════════════════════════════════════════════════════════════

    public class PatchResult {
        public Map<String, Object> criteria;
        /** One entry per applied op: op, id, kind, label, before, after. */
        public List<Map<String, Object>> diff = new List<Map<String, Object>>();
    }

    /**
     * Applies a patch (chips of ops, section 7.2) to a copy of the criteria. The input is not modified.
     * Ops: add, update, remove, setExclusion, setFilter. Unknown ops or ids throw CriteriaException.
     */
    public static PatchResult applyPatch(Map<String, Object> criteria, String patchJson) {
        Object parsed = String.isBlank(patchJson) ? new List<Object>() : System.JSON.deserializeUntyped(patchJson);
        if (parsed instanceof Map<String, Object> && ((Map<String, Object>) parsed).get('patch') != null) {
            parsed = ((Map<String, Object>) parsed).get('patch');
        }
        if (!(parsed instanceof List<Object>)) throw new CriteriaException('The patch must be a list of operations.');
        return applyPatch(criteria, (List<Object>) parsed, 'refine');
    }

    public static PatchResult applyPatch(Map<String, Object> criteria, List<Object> ops, String origin) {
        PatchResult res = new PatchResult();
        res.criteria = (Map<String, Object>) System.JSON.deserializeUntyped(System.JSON.serialize(criteria));
        List<Object> chips = items(res.criteria);

        for (Object o : ops) {
            if (!(o instanceof Map<String, Object>)) throw new CriteriaException('Each patch operation must be an object.');
            Map<String, Object> op = (Map<String, Object>) o;
            String name = str(op, 'op');
            Map<String, Object> d = new Map<String, Object>{ 'op' => name };

            if (name == 'add') {
                if (!(op.get('item') instanceof Map<String, Object>)) throw new CriteriaException('"add" needs an item.');
                Map<String, Object> item = (Map<String, Object>) op.get('item');
                if (READ_ONLY_KINDS.contains(str(item, 'kind'))) throw new CriteriaException('Textkernel-generated criteria cannot be added by hand.');
                item.put('id', nextId(res.criteria));
                if (str(item, 'origin') == null) item.put('origin', origin);
                if (str(item, 'kind') == 'location' && item.get('radius') == null) {
                    item.put('radius', CandidateSearchConfig.get().defaultRadiusMiles);
                }
                if (str(item, 'kind') == 'location' && item.get('unit') == null) item.put('unit', 'mi');
                chips.add(item);
                d.put('id', item.get('id'));
                d.put('kind', item.get('kind'));
                d.put('label', item.get('label'));
                d.put('after', item);
            } else if (name == 'update') {
                Map<String, Object> item = requireItem(res.criteria, str(op, 'id'));
                if (READ_ONLY_KINDS.contains(str(item, 'kind'))) {
                    throw new CriteriaException('"' + str(item, 'label') + '" comes from the job document and can only be removed.');
                }
                if (!(op.get('set') instanceof Map<String, Object>)) throw new CriteriaException('"update" needs a set object.');
                Map<String, Object> before = item.clone();
                Map<String, Object> setMap = (Map<String, Object>) op.get('set');
                for (String key : setMap.keySet()) {
                    if (!UPDATABLE.contains(key)) throw new CriteriaException('"' + key + '" cannot be changed on a criterion.');
                    item.put(key, setMap.get(key));
                }
                if (str(item, 'kind') == 'location' && (setMap.containsKey('radius') || setMap.containsKey('value')) && !setMap.containsKey('label')) {
                    item.put('label', str(item, 'value') + ' + ' + str(item, 'radius') + ' ' + (str(item, 'unit') == null ? 'mi' : str(item, 'unit')));
                }
                d.put('id', item.get('id'));
                d.put('kind', item.get('kind'));
                d.put('label', item.get('label'));
                d.put('before', before);
                d.put('after', item);
            } else if (name == 'remove') {
                Map<String, Object> item = requireItem(res.criteria, str(op, 'id'));
                for (Integer i = 0; i < chips.size(); i++) {
                    if (chips[i] === item) {
                        chips.remove(i);
                        break;
                    }
                }
                d.put('id', item.get('id'));
                d.put('kind', item.get('kind'));
                d.put('label', item.get('label'));
                d.put('before', item);
            } else if (name == 'setExclusion') {
                String key = str(op, 'key');
                if (!EXCLUSION_KEYS.contains(key)) throw new CriteriaException('Unknown exclusion "' + key + '".');
                Map<String, Object> x = exclusions(res.criteria);
                d.put('key', key);
                d.put('before', x.get(key));
                if (op.get('value') == null || op.get('value') == false) x.remove(key); else x.put(key, op.get('value'));
                d.put('after', x.get(key));
            } else if (name == 'setFilter') {
                String key = str(op, 'key');
                if (String.isBlank(key)) throw new CriteriaException('"setFilter" needs a key.');
                Map<String, Object> f = filters(res.criteria);
                List<String> values = strings(op.get('values'));
                d.put('key', key);
                d.put('before', f.get(key));
                if (values.isEmpty()) f.remove(key); else f.put(key, values);
                d.put('after', f.get(key));
            } else {
                throw new CriteriaException('Unknown patch operation "' + name + '".');
            }
            res.diff.add(d);
        }

        validate(res.criteria);
        return res;
    }

    private static Map<String, Object> requireItem(Map<String, Object> criteria, String id) {
        Map<String, Object> item = String.isBlank(id) ? null : findItem(criteria, id);
        if (item == null) throw new CriteriaException('There is no criterion with id "' + id + '".');
        return item;
    }

    // ═════════════════════════════════════════════════════════════
    // Small typed accessors over untyped maps
    // ═════════════════════════════════════════════════════════════

    public static String str(Map<String, Object> m, String key) {
        if (m == null) return null;
        Object v = m.get(key);
        return v == null ? null : String.valueOf(v);
    }

    public static Decimal dec(Map<String, Object> m, String key) {
        Object v = m.get(key);
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        return Decimal.valueOf(String.valueOf(v));
    }

    public static List<String> strings(Object o) {
        List<String> out = new List<String>();
        if (o instanceof List<Object>) {
            for (Object v : (List<Object>) o) {
                if (v != null && String.isNotBlank(String.valueOf(v))) out.add(String.valueOf(v));
            }
        }
        return out;
    }

    private static String field(SObject rec, String name) {
        try {
            Object v = rec.get(name);
            return v == null ? null : String.valueOf(v);
        } catch (SObjectException e) {
            return null;
        }
    }

    private static String lower(String s) {
        return s == null ? null : s.toLowerCase();
    }
}
