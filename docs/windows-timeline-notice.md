# Timeline recording notice

Normal interface-driven recording pauses no longer display the persistent
"Recording will resume when you close Recall" banner over timeline controls.
The tray continues to show the current recording state. Actual capture faults
still show their actionable error notice; unrelated error messages are retained.
No recording-coordinator behavior was changed.

Release publish passed. Focused native validation with the isolated synthetic
library and simulated capture backend checked the banner is absent while paused
and after reopening, recording resumes after hiding, and injected capture-start
failure still displays its error notice. This small UI fix did not run the full
regression suite. The installer has not been applied to the running installation.
