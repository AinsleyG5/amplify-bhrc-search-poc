/**
 * CsI18n: English and French text for the messages Candidate Search returns from Apex (notices, bulk action results,
 * pipeline tags) and the language the AI and Textkernel answer in.
 *
 * The page sends its language ('en' or 'fr') with each call that returns text; the controller sets CsI18n.lang for
 * that transaction. Placeholders are {0}, {1} (String.format).
 */
public with sharing class CsI18n {

    /** 'en' or 'fr' for this transaction. */
    public static String lang = 'en';

    public static String normalize(String value) {
        return String.isNotBlank(value) && value.trim().toLowerCase().startsWith('fr') ? 'fr' : 'en';
    }

    /** Sets the language for this transaction (blank keeps English) and returns it. */
    public static String use(String value) {
        lang = normalize(value);
        return lang;
    }

    public static Boolean isFrench() {
        return lang == 'fr';
    }

    private static final Map<String, List<String>> TEXT = new Map<String, List<String>>{
        'jobDocNotice' => new List<String>{
            'Built from the Textkernel job document for {0}.',
            'Construit à partir du document de poste Textkernel pour {0}.'
        },
        'adjustedQuery' => new List<String>{
            'Adjusted the generated query (location, skill cap or softer title) and searched again.',
            'Requête générée ajustée (lieu, nombre de compétences ou intitulé assoupli), puis relancée.'
        },
        'adjustedFailed' => new List<String>{
            'The adjusted search failed ({0}), so these are the unadjusted results.',
            'La recherche ajustée a échoué ({0}) : voici les résultats non ajustés.'
        },
        'jobDocFallback' => new List<String>{
            'Could not use the Textkernel job document ({0}). Built the search from the job record for {1} instead.',
            'Impossible d\'utiliser le document de poste Textkernel ({0}). La recherche a été construite à partir de la fiche du poste {1}.'
        },
        'compareCriteriaUnreadable' => new List<String>{
            'The criteria for this search could not be read, so met and not met are not shown.',
            'Les critères de cette recherche sont illisibles : les critères remplis ou non ne sont pas affichés.'
        },
        'candidateNoAccess' => new List<String>{
            'A candidate could not be found or you do not have access to it ({0}).',
            'Un candidat est introuvable ou vous n\'y avez pas accès ({0}).'
        },
        'foreignHidden_one' => new List<String>{
            '{0} result from another Salesforce org was hidden.',
            '{0} résultat provenant d\'une autre organisation Salesforce a été masqué.'
        },
        'foreignHidden_other' => new List<String>{
            '{0} results from another Salesforce org were hidden.',
            '{0} résultats provenant d\'une autre organisation Salesforce ont été masqués.'
        },
        'restrictedHidden_one' => new List<String>{
            '{0} result was hidden: you do not have access to that candidate in Salesforce.',
            '{0} résultat a été masqué : vous n\'avez pas accès à ce candidat dans Salesforce.'
        },
        'restrictedHidden_other' => new List<String>{
            '{0} results were hidden: you do not have access to those candidates in Salesforce.',
            '{0} résultats ont été masqués : vous n\'avez pas accès à ces candidats dans Salesforce.'
        },
        'noAccessCandidate' => new List<String>{
            'You do not have access to this candidate in Salesforce.',
            'Vous n\'avez pas accès à ce candidat dans Salesforce.'
        },
        'notAudited' => new List<String>{ 'This search could not be audited: {0}', 'Cette recherche n\'a pas pu être auditée : {0}' },
        'aiParseFailed' => new List<String>{
            'The AI could not read that search, so it runs as plain keywords. {0}',
            'L\'IA n\'a pas pu interpréter cette recherche : elle est lancée en mots-clés. {0}'
        },
        'notExcludable' => new List<String>{
            '"{0}" was not sent: it cannot be excluded yet.',
            '« {0} » n\'a pas été envoyé : ce critère ne peut pas encore être exclu.'
        },
        'locationFilter' => new List<String>{
            '"{0}" is applied as a filter: Textkernel cannot weight a location.',
            '« {0} » est appliqué comme filtre : Textkernel ne peut pas pondérer un lieu.'
        },
        'availabilityNotConfigured' => new List<String>{
            '"{0}" was not sent to Textkernel: the availability date field is not configured yet.',
            '« {0} » n\'a pas été envoyé à Textkernel : le champ de date de disponibilité n\'est pas encore configuré.'
        },
        'addedToJob_one' => new List<String>{ 'Added {0} candidate to {1}.', '{0} candidat ajouté à {1}.' },
        'addedToJob_other' => new List<String>{ 'Added {0} candidates to {1}.', '{0} candidats ajoutés à {1}.' },
        'alreadyOnJobCount' => new List<String>{ '{0} already on the job.', '{0} déjà sur le poste.' },
        'alreadyInPoolCount' => new List<String>{ '{0} already in the pool.', '{0} déjà dans le vivier.' },
        'notFoundCount' => new List<String>{ '{0} not found.', '{0} introuvable(s).' },
        'couldNotAddCount' => new List<String>{ '{0} could not be added.', '{0} n\'a (n\'ont) pas pu être ajouté(s).' },
        'skipNoAccess' => new List<String>{
            'Not found, or you do not have access to this candidate.',
            'Introuvable, ou vous n\'avez pas accès à ce candidat.'
        },
        'skipOnJob' => new List<String>{ 'Already on this job: {0}.', 'Déjà sur ce poste : {0}.' },
        'skipInPool' => new List<String>{ 'Already in this talent pool.', 'Déjà dans ce vivier.' },
        'pipeApplied' => new List<String>{ 'Applied', 'Candidature' },
        'pipeShortlisted' => new List<String>{ 'Shortlisted', 'Présélectionné' },
        'pipePlaced' => new List<String>{ 'Placed', 'Placé' }
    };

    public static String t(String key) {
        return t(key, new List<Object>());
    }

    public static String t(String key, List<Object> args) {
        List<String> pair = TEXT.get(key);
        if (pair == null) return key;
        String text = isFrench() ? pair[1] : pair[0];
        if (args == null || args.isEmpty()) return text;
        List<String> strs = new List<String>();
        for (Object a : args) strs.add(a == null ? '' : String.valueOf(a));
        // String.format treats single quotes as escapes: double them so French apostrophes survive
        return String.format(text.replace('\'', '\'\''), strs);
    }

    /** Picks key_one or key_other for n (French uses the singular for 0 and 1). */
    public static String plural(String key, Integer n, List<Object> args) {
        Boolean one = isFrench() ? Math.abs(n) < 2 : n == 1;
        return t(key + (one ? '_one' : '_other'), args);
    }

    /**
     * Added to every AI request (Anthropic) when the page is in French: human-readable output in French, while ids,
     * enum values and the search values themselves stay as they are.
     */
    public static String aiInstruction() {
        if (!isFrench()) return null;
        return 'Write every human-readable text you return (chip labels, summaries, evidence, replies, notes) in French. '
            + 'Keep ids, docIds, codes, enum values (kind, weight, op, status) and field names exactly as specified. '
            + 'Do not translate search values: keep each value in the language the user wrote it in.';
    }

    /** Textkernel Tx OutputLanguage for taxonomy names. */
    public static String txOutputLanguage() {
        return isFrench() ? 'fr' : 'en';
    }
}
