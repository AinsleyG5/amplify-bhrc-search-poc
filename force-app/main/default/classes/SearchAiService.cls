/**
 * SearchAiService
 *
 * The three Candidate Search prompts (spec section 7): parse, refine and explain. Prompt text, model, max tokens,
 * timeout and tool schema come from Candidate_Search_Prompt__mdt. The model is reached only through
 * SearchLlmProvider. Every output is validated against its contract before use; an invalid output is retried once
 * with the validation error, then fails with a readable message.
 *
 * Principle: Textkernel decides who matches and the score. The explain output is forced to agree with TK's
 * per-query-part flags (met / notMet) whatever the model says.
 */
public with sharing class SearchAiService {

    public static final String PARSE_PROMPT = 'CandidateSearch_Parse';
    public static final String REFINE_PROMPT = 'CandidateSearch_Refine';
    public static final String EXPLAIN_PROMPT = 'CandidateSearch_Explain';

    public static final Integer MAX_SUMMARY_WORDS = 30;
    public static final String NO_EVIDENCE = 'not on record';

    public class SearchAiException extends Exception {}

    // ═════════════════════════════════════════════════════════════
    // Provider types (SearchLlmProvider cannot hold inner classes)
    // ═════════════════════════════════════════════════════════════

    public class LlmRequest {
        public CandidateSearchConfig.PromptConfig prompt;
        /** Named inputs, in order. Sent to Anthropic as tagged sections, to prompt templates as Input:<name>. */
        public Map<String, String> inputs = new Map<String, String>();
        /** Set on the retry: why the previous output was rejected. */
        public String correction;

        public String userContent() {
            String s = '';
            for (String key : inputs.keySet()) {
                s += '<' + key + '>\n' + (inputs.get(key) == null ? '' : inputs.get(key)) + '\n</' + key + '>\n';
            }
            String language = CsI18n.aiInstruction();
            if (language != null) s += '<OutputLanguage>\n' + language + '\n</OutputLanguage>\n';
            if (String.isNotBlank(correction)) {
                s += '\nYour previous tool call was rejected: ' + correction + '\nCall the tool again with a corrected input.';
            }
            return s;
        }
    }

    public class LlmResponse {
        public String outputJson;
        public String model;
        public Integer inputTokens;
        public Integer outputTokens;
        public Long durationMs;
        public String stopReason;
        public Integer attempts = 1;
    }

    @TestVisible
    private static SearchLlmProvider providerOverride;

    public static SearchLlmProvider provider() {
        if (providerOverride != null) return providerOverride;
        return CandidateSearchConfig.get().llmProvider == 'PromptTemplate'
            ? (SearchLlmProvider) new PromptTemplateLlmProvider()
            : (SearchLlmProvider) new AnthropicLlmProvider();
    }

    /** Usage summed over attempts, for the audit record. */
    public class Usage {
        public String promptName;
        public String model;
        public Integer inputTokens = 0;
        public Integer outputTokens = 0;
        public Long durationMs = 0;
        public Integer attempts = 0;
        /** Exactly what the model returned on the last attempt, before validation. */
        public String proposedJson;

        public void add(LlmResponse r) {
            attempts++;
            model = r.model;
            inputTokens += r.inputTokens == null ? 0 : r.inputTokens;
            outputTokens += r.outputTokens == null ? 0 : r.outputTokens;
            durationMs += r.durationMs == null ? 0 : r.durationMs;
            proposedJson = r.outputJson;
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Parse
    // ═════════════════════════════════════════════════════════════

    public class ParseOutcome {
        public Map<String, Object> criteria;
        public Usage usage;
    }

    public static ParseOutcome parse(String text) {
        if (String.isBlank(text)) throw new SearchAiException('Type what you are looking for first.');
        CandidateSearchConfig cfg = CandidateSearchConfig.get();

        LlmRequest req = new LlmRequest();
        req.prompt = CandidateSearchConfig.prompt(PARSE_PROMPT);
        req.inputs.put('NaturalLanguage', text.trim().abbreviate(2000));
        req.inputs.put('Today', String.valueOf(Date.today()));
        req.inputs.put('DefaultRadiusMiles', String.valueOf(cfg.defaultRadiusMiles));

        ParseOutcome out = new ParseOutcome();
        out.usage = new Usage();
        out.usage.promptName = PARSE_PROMPT;
        out.criteria = (Map<String, Object>) callValidated(req, new ParseValidator(text.trim()), out.usage);
        return out;
    }

    private class ParseValidator implements Validator {
        String text;
        public ParseValidator(String text) {
            this.text = text;
        }
        public Object validate(Map<String, Object> output) {
            CandidateSearchConfig cfg = CandidateSearchConfig.get();
            Map<String, Object> c = CriteriaService.newCriteria('nl');
            c.put('naturalLanguage', text.abbreviate(255));
            List<Object> chips = CriteriaService.items(c);

            if (!(output.get('items') instanceof List<Object>)) throw new CriteriaService.CriteriaException('"items" must be a list.');
            for (Object o : (List<Object>) output.get('items')) {
                if (!(o instanceof Map<String, Object>)) throw new CriteriaService.CriteriaException('Each item must be an object.');
                Map<String, Object> item = (Map<String, Object>) o;
                String kind = CriteriaService.str(item, 'kind');
                if (kind == 'fingerprint' || kind == 'tk_raw') {
                    throw new CriteriaService.CriteriaException('Kind "' + kind + '" cannot be produced by the parser.');
                }
                if (kind == 'location') {
                    if (item.get('radius') == null) item.put('radius', cfg.defaultRadiusMiles);
                    if (item.get('unit') == null) item.put('unit', 'mi');
                }
                item.put('id', CriteriaService.nextId(c));
                item.put('origin', 'nl');
                if (kind == 'skill' || kind == 'certification') item.put('code', null);
                chips.add(item);
            }
            if (output.get('filters') instanceof Map<String, Object>) c.put('filters', output.get('filters'));
            if (output.get('exclusions') instanceof Map<String, Object>) c.put('exclusions', output.get('exclusions'));
            return CriteriaService.validate(c);
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Refine
    // ═════════════════════════════════════════════════════════════

    public class RefineOutcome {
        public Map<String, Object> criteria;
        public List<Object> patch = new List<Object>();
        public List<Map<String, Object>> diff = new List<Map<String, Object>>();
        public String reply;
        public Boolean needsClarification = false;
        public Usage usage;
    }

    public static RefineOutcome refine(Map<String, Object> criteria, String message, String historyJson, String resultSummaryJson) {
        if (String.isBlank(message)) throw new SearchAiException('Type a message first.');

        LlmRequest req = new LlmRequest();
        req.prompt = CandidateSearchConfig.prompt(REFINE_PROMPT);
        req.inputs.put('CriteriaJson', System.JSON.serialize(promptCriteria(criteria)));
        req.inputs.put('Message', message.trim().abbreviate(2000));
        req.inputs.put('HistoryJson', lastTurns(historyJson, 6));
        req.inputs.put('ResultSummaryJson', String.isBlank(resultSummaryJson) ? '[]' : resultSummaryJson);

        Usage usage = new Usage();
        usage.promptName = REFINE_PROMPT;
        RefineOutcome out = (RefineOutcome) callValidated(req, new RefineValidator(criteria), usage);
        out.usage = usage;
        return out;
    }

    private class RefineValidator implements Validator {
        Map<String, Object> criteria;
        public RefineValidator(Map<String, Object> criteria) {
            this.criteria = criteria;
        }
        public Object validate(Map<String, Object> output) {
            RefineOutcome r = new RefineOutcome();
            if (!(output.get('reply') instanceof String) || String.isBlank((String) output.get('reply'))) {
                throw new CriteriaService.CriteriaException('"reply" is required.');
            }
            r.reply = ((String) output.get('reply')).trim();
            r.needsClarification = output.get('needsClarification') == true;
            Object patch = output.get('patch');
            if (patch != null && !(patch instanceof List<Object>)) throw new CriteriaService.CriteriaException('"patch" must be a list.');
            r.patch = r.needsClarification || patch == null ? new List<Object>() : (List<Object>) patch;

            CriteriaService.PatchResult applied = CriteriaService.applyPatch(criteria, r.patch, 'refine');
            r.criteria = applied.criteria;
            r.diff = applied.diff;
            return r;
        }
    }

    /** The criteria the refine prompt sees: no transient trace, no raw TK XML (large, and not editable). */
    @TestVisible
    private static Map<String, Object> promptCriteria(Map<String, Object> criteria) {
        Map<String, Object> copy = (Map<String, Object>) System.JSON.deserializeUntyped(System.JSON.serialize(criteria));
        copy.remove('trace');
        for (Object o : CriteriaService.items(copy)) {
            Map<String, Object> item = (Map<String, Object>) o;
            item.remove('raw');
            item.remove('rawSignature');
        }
        return copy;
    }

    private static String lastTurns(String historyJson, Integer n) {
        if (String.isBlank(historyJson)) return '[]';
        try {
            Object o = System.JSON.deserializeUntyped(historyJson);
            if (!(o instanceof List<Object>)) return '[]';
            List<Object> all = (List<Object>) o;
            List<Object> last = new List<Object>();
            for (Integer i = Math.max(0, all.size() - n); i < all.size(); i++) last.add(all[i]);
            return System.JSON.serialize(last);
        } catch (Exception e) {
            return '[]';
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Explain
    // ═════════════════════════════════════════════════════════════

    /** One candidate as the explain prompt receives it (section 7.3). */
    public class ExplainCandidate {
        public String docId;
        public Decimal score;
        public List<String> met = new List<String>();
        public List<String> notMet = new List<String>();
        public List<String> highlights = new List<String>();
        public Map<String, Object> profile = new Map<String, Object>();
    }

    public class ExplainOutcome {
        /** [{docId, summary, criteria: [{id, met, evidence, source}]}] */
        public List<Map<String, Object>> explanations = new List<Map<String, Object>>();
        public Usage usage;
    }

    public static ExplainOutcome explain(Map<String, Object> criteria, List<ExplainCandidate> candidates) {
        ExplainOutcome out = new ExplainOutcome();
        out.usage = new Usage();
        out.usage.promptName = EXPLAIN_PROMPT;
        if (candidates == null || candidates.isEmpty()) return out;

        Integer batch = CandidateSearchConfig.get().explainBatchSize;
        if (candidates.size() > batch) {
            throw new SearchAiException('Explain at most ' + batch + ' candidates per call.');
        }

        LlmRequest req = new LlmRequest();
        req.prompt = CandidateSearchConfig.prompt(EXPLAIN_PROMPT);
        req.inputs.put('CriteriaJson', System.JSON.serialize(chipSummary(criteria)));
        req.inputs.put('CandidatesJson', System.JSON.serialize(candidates));

        out.explanations = (List<Map<String, Object>>) callValidated(req, new ExplainValidator(candidates), out.usage);
        return out;
    }

    private class ExplainValidator implements Validator {
        Map<String, ExplainCandidate> byDoc = new Map<String, ExplainCandidate>();
        List<ExplainCandidate> ordered;
        public ExplainValidator(List<ExplainCandidate> candidates) {
            ordered = candidates;
            for (ExplainCandidate c : candidates) byDoc.put(c.docId, c);
        }
        public Object validate(Map<String, Object> output) {
            if (!(output.get('explanations') instanceof List<Object>)) {
                throw new CriteriaService.CriteriaException('"explanations" must be a list.');
            }
            Map<String, Map<String, Object>> got = new Map<String, Map<String, Object>>();
            for (Object o : (List<Object>) output.get('explanations')) {
                if (!(o instanceof Map<String, Object>)) continue;
                Map<String, Object> e = (Map<String, Object>) o;
                String docId = CriteriaService.str(e, 'docId');
                if (docId == null || !byDoc.containsKey(docId)) continue;
                got.put(docId, enforce(byDoc.get(docId), e));
            }
            if (got.isEmpty()) {
                throw new CriteriaService.CriteriaException('No explanation matched a docId from CandidatesJson.');
            }
            List<Map<String, Object>> result = new List<Map<String, Object>>();
            for (ExplainCandidate c : ordered) {
                if (got.containsKey(c.docId)) result.add(got.get(c.docId));
            }
            return result;
        }
    }

    /**
     * Makes the explanation agree with TK: one entry per met / notMet id, with met exactly as TK says,
     * evidence "not on record" when blank, summary at most 30 words.
     */
    @TestVisible
    private static Map<String, Object> enforce(ExplainCandidate c, Map<String, Object> e) {
        Map<String, Map<String, Object>> byId = new Map<String, Map<String, Object>>();
        if (e.get('criteria') instanceof List<Object>) {
            for (Object o : (List<Object>) e.get('criteria')) {
                if (o instanceof Map<String, Object>) {
                    Map<String, Object> m = (Map<String, Object>) o;
                    if (m.get('id') != null) byId.put(String.valueOf(m.get('id')), m);
                }
            }
        }

        List<Object> criteria = new List<Object>();
        Boolean contradicted = false;
        for (String id : c.met) criteria.add(criterion(id, true, byId.get(id)));
        for (String id : c.notMet) {
            Map<String, Object> m = byId.get(id);
            if (m != null && m.get('met') == true) contradicted = true;
            criteria.add(criterion(id, false, m));
        }

        String summary = CriteriaService.str(e, 'summary');
        summary = summary == null ? '' : summary.normalizeSpace();
        List<String> words = summary.split(' ');
        if (words.size() > MAX_SUMMARY_WORDS) {
            List<String> kept = new List<String>();
            for (Integer i = 0; i < MAX_SUMMARY_WORDS; i++) kept.add(words[i]);
            summary = String.join(kept, ' ').removeEnd(',').removeEnd('.') + '…';
        }

        Map<String, Object> out = new Map<String, Object>{
            'docId' => c.docId,
            'summary' => summary,
            'criteria' => criteria
        };
        if (contradicted) out.put('correctedByTk', true);
        return out;
    }

    private static Map<String, Object> criterion(String id, Boolean met, Map<String, Object> fromModel) {
        String evidence = fromModel == null ? null : CriteriaService.str(fromModel, 'evidence');
        String source = fromModel == null ? null : CriteriaService.str(fromModel, 'source');
        // A not-met criterion cannot carry evidence that it is met
        if (String.isBlank(evidence) || (!met && fromModel != null && fromModel.get('met') == true)) {
            evidence = NO_EVIDENCE;
            source = null;
        }
        return new Map<String, Object>{
            'id' => id,
            'met' => met,
            'evidence' => evidence.abbreviate(300),
            'source' => source
        };
    }

    /** id, kind, label, weight of each chip: what the explain prompt needs, nothing more. */
    private static List<Object> chipSummary(Map<String, Object> criteria) {
        List<Object> out = new List<Object>();
        for (Object o : CriteriaService.items(criteria)) {
            Map<String, Object> i = (Map<String, Object>) o;
            out.add(new Map<String, Object>{
                'id' => i.get('id'),
                'kind' => i.get('kind'),
                'label' => i.get('label'),
                'weight' => i.get('weight')
            });
        }
        return out;
    }

    // ═════════════════════════════════════════════════════════════
    // Call + validate + retry once
    // ═════════════════════════════════════════════════════════════

    private interface Validator {
        Object validate(Map<String, Object> output);
    }

    private static Object callValidated(LlmRequest req, Validator v, Usage usage) {
        SearchLlmProvider p = provider();
        String lastError;
        for (Integer attempt = 1; attempt <= 2; attempt++) {
            LlmResponse res = p.call(req);
            usage.add(res);
            try {
                if (String.isBlank(res.outputJson)) throw new CriteriaService.CriteriaException('The output was empty.');
                Object parsed = System.JSON.deserializeUntyped(res.outputJson);
                if (!(parsed instanceof Map<String, Object>)) throw new CriteriaService.CriteriaException('The output must be a JSON object.');
                return v.validate((Map<String, Object>) parsed);
            } catch (CriteriaService.CriteriaException e) {
                lastError = e.getMessage();
            } catch (JSONException e) {
                lastError = 'The output was not valid JSON (' + e.getMessage() + ').';
            } catch (TypeException e) {
                lastError = 'The output did not match the contract (' + e.getMessage() + ').';
            } catch (NullPointerException e) {
                lastError = 'The output is missing a required value.';
            }
            req.correction = lastError;
        }
        throw new SearchAiException('The AI answer could not be used (' + req.prompt.name + '): ' + lastError);
    }
}
