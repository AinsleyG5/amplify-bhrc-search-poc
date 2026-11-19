// Candidate Search: find the Textkernel exclude condition (open item 2).
// Everyone (1172) minus "placed in the last 1000 days" (66) should leave 1106.
// TK silently treats an unknown condition as REQUIRED (66), so look for the line that prints 1106.
// Prints match counts only. 13 callouts.
//
// Run:  sf apex run --file scripts/apex/tkExclude.apex --target-org <alias> > logs\tkexclude.log

List<String> statuses = new List<String>{ 'Active', 'Available', 'DNU', 'Passive', 'Placed', 'Prospect', 'Screened' };

// 1. Condition enum spellings on a structured part
for (String condition : new List<String>{
    'EXCLUDED', 'EXCLUDE', 'MUST_NOT', 'NOT', 'PROHIBITED', 'NEGATIVE', 'REJECTED', 'FORBIDDEN', 'DISFAVORED', 'STRONGLY_DISFAVORED'
}) {
    TkSearchClient.QueryPart all = new TkSearchClient.QueryPart();
    all.field = 'candidate_status';
    all.condition = 'REQUIRED';
    all.values.addAll(statuses);
    TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
    p.field = 'custom_date_1';
    p.condition = condition;
    p.values.add('>=today-1000');
    TkSearchClient.SearchOptions o = new TkSearchClient.SearchOptions();
    o.pageSize = 1;
    try {
        System.debug('CHECK condition ' + condition + '  ->  ' + TkSearchClient.search(new List<TkSearchClient.QueryPart>{ all, p }, o).total);
    } catch (Exception e) {
        System.debug('CHECK condition ' + condition + '  ->  ERROR ' + e.getMessage().abbreviate(200));
    }
}

// 2. Negation in the free-text query string
for (String q : new List<String>{ '-custom_date_1:>=today-1000', 'NOT custom_date_1:>=today-1000', '!custom_date_1:>=today-1000' }) {
    TkSearchClient.QueryPart all = new TkSearchClient.QueryPart();
    all.field = 'candidate_status';
    all.condition = 'REQUIRED';
    all.values.addAll(statuses);
    TkSearchClient.SearchOptions o = new TkSearchClient.SearchOptions();
    o.pageSize = 1;
    o.query = q;
    try {
        System.debug('CHECK query ' + q + '  ->  ' + TkSearchClient.search(new List<TkSearchClient.QueryPart>{ all }, o).total);
    } catch (Exception e) {
        System.debug('CHECK query ' + q + '  ->  ERROR ' + e.getMessage().abbreviate(200));
    }
}
