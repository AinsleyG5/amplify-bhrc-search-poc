// Candidate Search: which fields does the Textkernel candidate index hold, and is the CV text one we can get back?
// Calls getMetadata once (1 callout) and prints every field definition on one line, with lines that look like
// CV / document text marked with >>>. No candidate data is printed.
//
// Run (Windows, from the repo folder):
//   mkdir logs
//   sf apex run --file scripts/apex/tkCvFields.apex --target-org <alias> > logs\tkcvfields.log
// Then paste the lines that start with RAW, FIELD and >>> (findstr "RAW FIELD >>>" logs\tkcvfields.log).

String xml = TkSearchClient.getMetadata(null);
System.debug('RAW length ' + xml.length());
// The first part of the raw response, so the structure is visible even if the parsing below misses it
for (Integer i = 0; i < Math.min(xml.length(), 6000); i += 1500) {
    System.debug('RAW ' + xml.substring(i, Math.min(xml.length(), i + 1500)));
}

Dom.Document doc = new Dom.Document();
doc.load(xml);
List<Dom.XmlNode> stack = new List<Dom.XmlNode>{ doc.getRootElement() };
Pattern textLike = Pattern.compile('(?i).*(text|document|resume|cv|content|body|fulltext).*');
Integer fields = 0;
while (!stack.isEmpty()) {
    Dom.XmlNode n = stack.remove(stack.size() - 1);
    List<Dom.XmlNode> kids = n.getChildElements();
    // A field definition: an element with a <name> child plus other simple values
    Dom.XmlNode nameNode = null;
    for (Dom.XmlNode k : kids) if (k.getName() == 'name') nameNode = k;
    if (nameNode != null && kids.size() > 1) {
        List<String> parts = new List<String>();
        for (Dom.XmlNode k : kids) {
            if (k.getChildElements().isEmpty()) parts.add(k.getName() + '=' + k.getText());
        }
        String line = n.getName() + ': ' + String.join(parts, ', ');
        String name = nameNode.getText();
        System.debug((textLike.matcher(name).matches() ? '>>> ' : 'FIELD ') + line.abbreviate(400));
        fields++;
    }
    for (Integer i = kids.size() - 1; i >= 0; i--) stack.add(kids[i]);
}
System.debug('FIELD count ' + fields);
