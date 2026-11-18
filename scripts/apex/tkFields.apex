// Candidate Search: check the field names and date syntax from getMetadata, and the exclude condition (open item 2).
// Each line prints only a match count (no candidate data). 7 callouts.
//
// Run:  sf apex run --file scripts/apex/tkFields.apex --target-org <alias> > logs\tkfields.log
// Expected: ALL > 0; EXCLUDED = ALL - PLACED SINCE 2024 (if EXCLUDED is the right spelling, otherwise an error).

List<List<String>> checks = new List<List<String>>{
    // label, field, condition, value
    new List<String>{ 'ALL (status in list)', 'candidate_status', 'REQUIRED', null },
    new List<String>{ 'PLACED SINCE 2024 (date >= syntax)', 'custom_date_1', 'REQUIRED', '>=2024-01-01' },
    new List<String>{ 'PLACED IN LAST 1000 DAYS (today-N)', 'custom_date_1', 'REQUIRED', '>=today-1000' },
    new List<String>{ 'EXCLUDED placed in last 1000 days', 'custom_date_1', 'EXCLUDED', '>=today-1000' },
    new List<String>{ 'AVAILABLE WITHIN 365 DAYS', 'date_available', 'REQUIRED', '<=today+365' },
    new List<String>{ 'LANGUAGE English', 'language_skills', 'REQUIRED', 'English' },
    new List<String>{ 'CERTIFICATION nested name', 'custom_nested_object_1.custom_text_1', 'REQUIRED', 'Certified Forklift Operator' }
};

for (List<String> c : checks) {
    TkSearchClient.QueryPart p = new TkSearchClient.QueryPart();
    p.field = c[1];
    p.condition = c[2];
    if (c[3] == null) {
        p.values.addAll(new List<String>{ 'Active', 'Available', 'DNU', 'Passive', 'Placed', 'Prospect', 'Screened' });
    } else {
        p.values.add(c[3]);
    }
    // A REQUIRED match-all part keeps EXCLUDED from being the only part
    List<TkSearchClient.QueryPart> parts = new List<TkSearchClient.QueryPart>{ p };
    if (c[2] != 'REQUIRED') {
        TkSearchClient.QueryPart all = new TkSearchClient.QueryPart();
        all.field = 'candidate_status';
        all.condition = 'REQUIRED';
        all.values.addAll(new List<String>{ 'Active', 'Available', 'DNU', 'Passive', 'Placed', 'Prospect', 'Screened' });
        parts.add(0, all);
    }
    try {
        TkSearchClient.SearchOptions o = new TkSearchClient.SearchOptions();
        o.pageSize = 1;
        System.debug('CHECK ' + c[0] + '  ->  ' + TkSearchClient.search(parts, o).total);
    } catch (Exception e) {
        System.debug('CHECK ' + c[0] + '  ->  ERROR ' + e.getMessage().abbreviate(200));
    }
}
