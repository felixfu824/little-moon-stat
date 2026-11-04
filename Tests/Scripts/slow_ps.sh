#!/bin/sh
# exec keeps the timeout child PID as the sleeper: SIGKILL + waitpid leaves no orphan.
exec /bin/sleep 3
