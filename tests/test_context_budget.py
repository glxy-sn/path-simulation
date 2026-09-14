import json
import unittest
from explanatory_analysis.context_budget import fit_messages
from explanatory_analysis.local_model import LocalModelRuntime

class BudgetTests(unittest.TestCase):
    def messages(self):
        return [dict(role='system',content='Evidence only'),dict(role='user',content=json.dumps({
            'question':'Compare Table 999','analysisSummary':{'samples':list(range(100000))},
            'areaCatalog':'\n'.join(f'a{i}|Table {i}|table|visits={i}' for i in range(1000)),
            'retrievedEvidence':[{'areaId':'a999','statement':'Relevant fact'}]}))]
    def test_long_recording(self):
        original=self.messages()
        output=fit_messages(original,lambda m:sum(len(x['content']) for x in m),4000)
        self.assertLessEqual(sum(len(x['content']) for x in output),4000)
        data=json.loads(output[-1]['content'])
        self.assertEqual(data['question'],'Compare Table 999')
        self.assertIn('a999|',data['areaCatalog'])
        self.assertTrue(data['contextCoverage']['reduced'])
        self.assertEqual(output[0],original[0])
    def test_large_question(self):
        with self.assertRaisesRegex(ValueError,'Pertanyaan terlalu panjang'):
            fit_messages([dict(role='user',content=json.dumps({'question':'a'*10000}))],lambda m:sum(len(x['content']) for x in m),1000)
    def test_runtime_retry(self):
        class Fake:
            calls=0
            def n_ctx(self): return 12288
            def tokenize(self,text,special=True): return list(text)
            def create_chat_completion(self,**kw):
                self.calls+=1
                if self.calls==1: raise ValueError('Requested tokens exceed context window')
                assert sum(len(m['content']) for m in kw['messages'])+kw['max_tokens']<12288
                return {'choices':[{'message':{'content':'Answer'},'finish_reason':'stop'}]}
        runtime=LocalModelRuntime()
        runtime._llm=Fake()
        self.assertEqual(runtime.generate(self.messages(),4096)['text'],'Answer')
        self.assertEqual(runtime._llm.calls,2)
