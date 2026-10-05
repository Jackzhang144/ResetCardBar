#!/usr/bin/env python3
import sys,json,os,time
mode=os.getenv('RESET_FIXTURE_MODE','normal')
for line in sys.stdin:
    msg=json.loads(line)
    if msg['method']=='initialize':
        print(json.dumps({'id':msg['id'],'result':{}}),flush=True)
    elif msg['method']=='initialized':
        if mode=='eof':
            os.close(1)
            time.sleep(25)
    elif msg['method']=='account/rateLimits/read':
        if mode=='timeout':
            time.sleep(25)
        else:
            print(json.dumps({'method':'account/rateLimits/updated','params':{}}),flush=True)
            data=json.dumps({'id':msg['id'],'result':{'accountId':'fixture','rateLimitResetCredits':{'availableCount':0,'credits':[]}}})+'\n'
            for bit in [data[:4],data[4:15],data[15:]]:
                sys.stdout.write(bit);sys.stdout.flush();time.sleep(.02)
