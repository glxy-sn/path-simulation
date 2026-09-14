"""Bound structured RAG input without cutting serialized JSON or inventing values."""
import json


def fit_messages(messages, count, budget):
    result = [dict(message) for message in messages]
    context = json.loads(result[-1]['content'])
    original_areas = str(context.get('areaCatalog', '')).splitlines()
    context['contextCoverage'] = {
        'totalAreas': len(original_areas),
        'instruction': 'Context may be reduced. Do not claim exhaustive comparisons when areas or evidence are omitted. Request a narrower question if evidence is insufficient.'
    }

    def encode():
        result[-1]['content'] = json.dumps(context, ensure_ascii=False, separators=(',', ':'))

    def compact(value, limit):
        if isinstance(value, dict):
            return {k: compact(v, limit) for k, v in list(value.items())[:limit]}
        if isinstance(value, list):
            return [compact(v, limit) for v in value[:limit]]
        if isinstance(value, str) and len(value) > limit * 80:
            return value[:limit * 80] + ' [truncated]'
        return value

    encode()
    if count(result) <= budget:
        return result
    context['contextCoverage']['reduced'] = True
    # Keep the user's question and system rules intact while shrinking source data.
    for limit in (32, 16, 8, 4, 2, 1):
        for key in ('analysisSummary', 'coordinateSystem', 'capabilities', 'retrievedEvidence'):
            context[key] = compact(context.get(key), limit)
        context['recentConversation'] = context.get('recentConversation', [])[-min(limit, 2):]
        # Prioritize areas named in retrieved evidence or the question, retain stable order.
        if limit == 32:
            ids = {str(c.get('areaId')) for c in (context.get('retrievedEvidence') or [])}
            question = str(context.get('question', '')).casefold()
            original_areas.sort(key=lambda row: not (row.split('|')[0] in ids or
                (len(row.split('|')) > 1 and row.split('|')[1] and row.split('|')[1].casefold() in question)))
        rows = original_areas[:limit]
        context['areaCatalog'] = '\n'.join(rows)
        context['contextCoverage']['includedAreas'] = len(rows)
        encode()
        if count(result) <= budget:
            return result
    for key in ('recentConversation', 'areaCatalog', 'retrievedEvidence', 'analysisSummary', 'capabilities', 'coordinateSystem'):
        context.pop(key, None)
        context['contextCoverage']['reduced'] = True
        encode()
        if count(result) <= budget:
            return result
    raise ValueError('Pertanyaan terlalu panjang untuk kapasitas model. Ringkas pertanyaan agar tersedia ruang untuk jawaban.')
