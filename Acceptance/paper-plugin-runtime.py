#!/usr/bin/env python3
"""Boot an isolated, throwaway Paper server with exactly the published Check JAR."""
import subprocess
import time
import sys
import re
from pathlib import Path
root=Path(sys.argv[1])
server=root/"paper-1.21.1.jar"
assert server.is_file() and server.stat().st_size>10_000_000, "Paper server download absent"
assert (root/"plugins"/"PiricraftCheckServer-1.0.0.jar").is_file(), "Check JAR absent"
(root/"eula.txt").write_text("eula=true\n")
(root/"server.properties").write_text("online-mode=false\nserver-port=0\nquery.port=0\nmax-players=1\nspawn-protection=0\nview-distance=3\nsimulation-distance=3\n")
with (root/"test-console.txt").open("w",encoding="utf-8") as logfile:
    process=subprocess.Popen(["java","-Xms256M","-Xmx2G","-jar",server.name,"nogui"],
       cwd=root,stdin=subprocess.PIPE,stdout=logfile,stderr=subprocess.STDOUT,text=True)
    result="Server timeout"
    try:
        for i in range(100):
            time.sleep(2)
            logfile.flush()
            data=(root/"test-console.txt").read_text(encoding="utf-8",errors="replace")
            if "Done (" in data and "For help, type" in data:
                result="done"
                break
            if process.poll() is not None:
                result="server exited early"
                break
        process.stdin.write("stop\n")
        process.stdin.flush()
        process.wait(timeout=30)
    except Exception as exc:
        result=f"runtime exception {exc}"
    finally:
        if process.poll() is None:
            process.terminate()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.kill()
data=(root/"test-console.txt").read_text(encoding="utf-8",errors="replace")
print(data[-18_000:])
assert result=="done", "Paper server did not finish enabling ("+result+")"
assert re.search(r"Enabling\s+(?:Piricraft|PiriCraft)Check",data,re.I), "Published Check plugin never enabled"
assert not re.search(r"(Could not load|Error occurred while enabling|Error loading|NoClassDefFoundError|VerifyError|ExceptionInInitializerError)",data,re.I), \
    "Paper plugin classloading or initialization error"
print("PUBLISHED_CHECK_PLUGIN_BOOTED_AND_ENABLED_ON_REAL_PAPER_1_21_1")
