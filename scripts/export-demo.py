"""Export only synthetic demo fixtures from the native Mac app for the Windows build."""
import json, os, sqlite3, shutil
from pathlib import Path
from datetime import datetime, timezone, timedelta
root=Path(__file__).resolve().parent.parent
source=Path(os.environ.get('RECALL_DATA_DIR',Path.home()/'Library/Application Support/Recall')).expanduser()
target=root/'shared/demo'
(target/'frames').mkdir(parents=True,exist_ok=True)
db=sqlite3.connect((source/'memory.sqlite').resolve().as_uri()+'?mode=ro',uri=True)
frames=[]
def date(value):
    return (datetime(2001,1,1,tzinfo=timezone.utc)+timedelta(seconds=value)).isoformat()
def region(r):
    return {k[:1].upper()+k[1:]:v for k,v in r.items() if k!='id'}
for (row,) in db.execute('SELECT json FROM frames WHERE demo=1'):
    f=json.loads(row)
    output={'Id':f['id'],'Timestamp':date(f['timestamp']),'AppName':f['appName'],'ProcessName':f['bundleID'],'Title':f['title'],'ImagePath':f['imagePath'],'Text':f['text'],'Regions':[region(r) for r in f['regions']],'MeetingRegions':[region(r) for r in f['meetingRegions']],'Demo':True,'Starred':False,'SessionId':f.get('sessionID'),'MeetingImagePath':f.get('meetingImagePath')}
    frames.append(output)
    for name in [f['imagePath'],f.get('meetingImagePath')]:
        if name: shutil.copy2(source/name,target/name)
(target/'frames.json').write_text(json.dumps(frames,ensure_ascii=False,indent=2))
lines=[]
for (row,) in db.execute("SELECT json FROM transcripts WHERE session='demo-meeting'"):
    f=json.loads(row);lines.append({'Id':f['id'],'SessionId':f['sessionID'],'Timestamp':date(f['timestamp']),'Speaker':f['speaker'],'Text':f['text']})
(target/'transcripts.json').write_text(json.dumps(lines,ensure_ascii=False,indent=2))
print(f'Exported {len(frames)} synthetic frames and {len(lines)} sample transcript lines.')
