import json,sys
for p in sys.argv[1:]:
    r=json.load(open(p))
    print(f"## {r['extRoot'].split('/')[-1]} {r['scenario']}")
    for s in r['steps']: print(f"  step: {s['label']:<50} model requests so far = {s['requestsSoFar']}")
    for q in r['requests']: print(f"  req#{q['seq']} {q['kind']:<7} {q['scenario']:<24} last={q['lastRole']:<9} digestCopies={q['digestCopies']} lastIsDigest={q['lastIsDigest']} bodyChars={q['bodyChars']}")
    for e in r['entries']:
        if e['compactDigest']: print(f"  persisted {e['type']} customType={e['customType']} chars={e['chars']} truncNotice={e['truncNotice']} hasDigestTail={e['hasTail']}")
    print(f"  compactions={sum(1 for e in r['entries'] if e['type']=='compaction')} reemit-latest={r['reemitLatest']}")
    print()
