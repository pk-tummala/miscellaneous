"""
local_event_vs_poll.py
----------------------
A RUNNABLE proof of the one idea behind the AWS architecture in this folder:
reacting to a file the moment it LANDS (event-driven) beats CHECKING for it on a
timer (polling).

It uses the Linux kernel's inotify facility (via inotify_simple) — the same kind of
push notification that S3 -> EventBridge gives you in the cloud. No AWS account
needed. The two runs below are deliberately controlled so the output is the same
every time.
"""
import os, time, shutil
from inotify_simple import INotify, flags

BASE    = os.path.dirname(os.path.abspath(__file__))
LANDING = os.path.join(BASE, "data", "landing")
SAMPLE  = os.path.join(BASE, "config", "sample_listing.json")

def land_file():
    """Copy the sample file into the landing zone — i.e. a file 'arrives'."""
    shutil.copy(SAMPLE, os.path.join(LANDING, "sample_listing.json"))

def clear():
    shutil.rmtree(LANDING, ignore_errors=True)
    os.makedirs(LANDING, exist_ok=True)

bar = "=" * 70

print(bar)
print("REACTING TO A FILE THAT LANDS:  polling  vs  event-driven")
print(bar)

# --- 1. POLLING: a timer checks the landing zone every interval ---------------
# Controlled scenario: the file arrives during the 4th interval, so the poller
# does 3 idle checks first and only notices it on poll 4.
print("\n" + "-" * 70)
print("POLLING  (a cron-style timer checks the landing zone)")
print("-" * 70)
clear()
interval, poll, idle = 1, 0, 0
while True:
    poll += 1
    if poll == 4:                 # the file lands during this interval
        land_file()
    if os.path.exists(os.path.join(LANDING, "sample_listing.json")):
        print(f"  poll {poll}: found sample_listing.json  ->  start the job")
        break
    idle += 1
    print(f"  poll {poll}: landing zone empty — sleep {interval}s and check again")
    time.sleep(interval)
print(f"  => {idle} idle checks before it was noticed. Each check ran on a timer,")
print(f"     whether or not anything had arrived — and the file waited up to a full")
print(f"     interval to be picked up.")

# --- 2. EVENT-DRIVEN: the OS notifies us the instant a file lands -------------
print("\n" + "-" * 70)
print("EVENT-DRIVEN  (the OS pushes a notification the moment a file lands)")
print("-" * 70)
clear()
ino = INotify()
ino.add_watch(LANDING, flags.CREATE)
print("  watching landing/ ... blocked here, using no CPU, no timer")
land_file()                        # a file arrives
events = ino.read()                # returns immediately with the create event
created = [e.name for e in events if e.name]
print(f"  event received: {created[0]} created  ->  start the job immediately")
print(f"  => 0 idle checks. The watch woke the instant the file landed.")
ino.close()

print("\n" + bar)
print("Same picture, in the cloud (this folder's AWS build):")
print("  polling      = a cron job that lists an S3 prefix on a schedule, plus a")
print("                 cluster sitting idle between runs.")
print("  event-driven = S3 emits an 'Object Created' event to EventBridge, which")
print("                 starts a Step Functions run that fires an EMR Serverless")
print("                 job. Nothing polls; nothing idles; the file lands and the")
print("                 pipeline wakes up. See aws/ and the README.")
print(bar)
