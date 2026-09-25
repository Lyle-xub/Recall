import unittest
from types import SimpleNamespace
from fastapi.testclient import TestClient
from server import create_app

class FakeWhisper:
    def transcribe(self, path, **kwargs):
        return iter([SimpleNamespace(start=1.5, end=3.0, text="Meeting note")]), SimpleNamespace(language="en", duration=4.0)

class ContractTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(create_app(FakeWhisper(), "base"))

    def test_models_and_segment_timestamps(self):
        self.assertEqual(self.client.get('/v1/models').json()['data'][0]['id'], 'whisper-1')
        response = self.client.post('/v1/audio/transcriptions', data={'model':'whisper-1'}, files={'file':('note.wav',b'fixture','audio/wav')})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['segments'][0]['start'], 1.5)
        self.assertEqual(response.json()['text'], 'Meeting note')

    def test_rejects_browser_origins_and_unknown_models(self):
        self.assertEqual(self.client.get('/v1/models', headers={'Origin':'https://example.com'}).status_code, 403)
        self.assertEqual(self.client.post('/v1/audio/transcriptions', data={'model':'unloaded'}, files={'file':('note.wav',b'fixture')}).status_code, 400)

    def test_rejects_oversize_audio(self):
        response=self.client.post('/v1/audio/transcriptions', files={'file':('note.wav',b'0'*(24*1024*1024+1))})
        self.assertEqual(response.status_code, 413)

if __name__ == '__main__':
    unittest.main()
